#!/bin/sh
set -eu

# Install the experimental ACPI patches for Fedora.
#
# Source patches:
#   patches/*.dsl (processed in LC_ALL=C lexical order)
#
# Persistent installation:
#   /etc/acpi-tables/*.aml (one per source DSL)
#   /etc/dracut.conf.d/90-acpi-fixes.conf
#   /etc/kernel/cmdline (acpi_table_upgrade)

ACTION=${1:-install}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
    printf 'error: this script must run as root; use: sudo %s %s\n' "$0" "$ACTION" >&2
    exit 1
fi

PATCH_DIR=${PATCH_DIR:-"$SCRIPT_DIR/patches"}
BUILD_DIR=${BUILD_DIR:-"$SCRIPT_DIR/build"}
AML_BUILD_DIR="$BUILD_DIR/acpi-fixes"

# When invoked through sudo, keep generated repository artifacts owned by the
# invoking user rather than leaving build/ root-owned.
REPO_OWNER=
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    REPO_OWNER="$SUDO_UID:$SUDO_GID"
fi

SYSTEM_ACPI_DIR=/etc/acpi-tables
SYSTEM_MANIFEST="$SYSTEM_ACPI_DIR/.acpi-fixes-manifest"
DRACUT_CONF=/etc/dracut.conf.d/90-acpi-fixes.conf
KERNEL_CMDLINE=/etc/kernel/cmdline
KERNEL_ARG=acpi_table_upgrade

TMP_DIR=

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

restore_build_ownership() {
    [ -n "$REPO_OWNER" ] || return 0

    case "$BUILD_DIR" in
        "$SCRIPT_DIR"/*)
            chown -R "$REPO_OWNER" "$BUILD_DIR"
            ;;
    esac
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT HUP INT TERM

write_root_file_if_changed() {
    source_file=$1
    destination=$2
    mode=$3

    if [ -f "$destination" ] && cmp -s "$source_file" "$destination"; then
        return 0
    fi

    as_root install -Dm"$mode" "$source_file" "$destination"
}

compile_patches() {
    need_command iasl
    [ -d "$PATCH_DIR" ] || die "patch directory not found: $PATCH_DIR"

    TMP_DIR=$(mktemp -d)
    PATCH_LIST="$TMP_DIR/patch-list"
    AML_STAGE="$TMP_DIR/aml"
    COMPILE_STAGE="$TMP_DIR/compile"
    AML_NAMES_FILE="$TMP_DIR/aml-names"

    mkdir -p "$AML_STAGE" "$COMPILE_STAGE"
    find "$PATCH_DIR" -maxdepth 1 -type f -name '*.dsl' -print |
        LC_ALL=C sort >"$PATCH_LIST"
    [ -s "$PATCH_LIST" ] || die "no .dsl patches found in $PATCH_DIR"

    : >"$AML_NAMES_FILE"
    while IFS= read -r patch; do
        stem=$(basename "$patch" .dsl)
        [ -n "$stem" ] || die "invalid empty patch name: $patch"

        prefix="$COMPILE_STAGE/$stem"
        printf 'Compiling %s\n' "$patch"
        iasl -ve -tc -p "$prefix" "$patch"
        [ -s "$prefix.aml" ] || die "iasl did not produce $stem.aml"

        install -m0644 "$prefix.aml" "$AML_STAGE/$stem.aml"
        printf '%s\n' "$stem.aml" >>"$AML_NAMES_FILE"
    done <"$PATCH_LIST"

    # Keep generated AMLs in the repository as reproducible build artifacts.
    mkdir -p "$AML_BUILD_DIR"

    # Remove stale generated AMLs from a patch that was deleted or renamed.
    for old_aml in "$AML_BUILD_DIR"/*.aml; do
        [ -f "$old_aml" ] || continue
        old_name=$(basename "$old_aml")
        if ! grep -Fxq "$old_name" "$AML_NAMES_FILE"; then
            rm -f "$old_aml"
        fi
    done

    while IFS= read -r aml_name; do
        install -Dm0644 "$AML_STAGE/$aml_name" "$AML_BUILD_DIR/$aml_name"
    done <"$AML_NAMES_FILE"

    restore_build_ownership
}

install_dracut_config() {
    config="$TMP_DIR/90-acpi-fixes.conf"

    cat >"$config" <<EOF
acpi_override="yes"
acpi_table_dir="$SYSTEM_ACPI_DIR"
EOF

    write_root_file_if_changed "$config" "$DRACUT_CONF" 0644
}

install_aml_set() {
    # Remove AMLs managed by an earlier invocation but no longer produced by
    # the current patch directory. This also migrates the old single-file
    # acpi-fixes.aml layout used by the previous script.
    if [ -r "$SYSTEM_MANIFEST" ]; then
        while IFS= read -r old_name; do
            [ -n "$old_name" ] || continue
            case "$old_name" in
                */*|.|..) die "unsafe AML name in $SYSTEM_MANIFEST: $old_name" ;;
            esac
            if ! grep -Fxq "$old_name" "$AML_NAMES_FILE"; then
                as_root rm -f "$SYSTEM_ACPI_DIR/$old_name"
            fi
        done <"$SYSTEM_MANIFEST"
    elif [ -f "$SYSTEM_ACPI_DIR/acpi-fixes.aml" ] &&
        ! grep -Fxq 'acpi-fixes.aml' "$AML_NAMES_FILE"; then
        as_root rm -f "$SYSTEM_ACPI_DIR/acpi-fixes.aml"
    fi

    as_root install -d -m0755 "$SYSTEM_ACPI_DIR"
    while IFS= read -r aml_name; do
        write_root_file_if_changed \
            "$AML_STAGE/$aml_name" \
            "$SYSTEM_ACPI_DIR/$aml_name" \
            0644
    done <"$AML_NAMES_FILE"

    write_root_file_if_changed "$AML_NAMES_FILE" "$SYSTEM_MANIFEST" 0644
}

remove_aml_set() {
    if [ -r "$SYSTEM_MANIFEST" ]; then
        while IFS= read -r aml_name; do
            [ -n "$aml_name" ] || continue
            case "$aml_name" in
                */*|.|..) die "unsafe AML name in $SYSTEM_MANIFEST: $aml_name" ;;
            esac
            as_root rm -f "$SYSTEM_ACPI_DIR/$aml_name"
        done <"$SYSTEM_MANIFEST"
    else
        # Migration fallback for the former single-file installation.
        as_root rm -f "$SYSTEM_ACPI_DIR/acpi-fixes.aml"
    fi
    as_root rm -f "$SYSTEM_MANIFEST" "$DRACUT_CONF"
}

entry_has_kernel_arg() {
    entry=$1
    options=$(awk '
        $1 == "options" {
            sub(/^[^[:space:]]+[[:space:]]+/, "")
            print
            exit
        }
    ' "$entry")

    [ "$(kernel_arg_count "$options")" -eq 1 ]
}

kernel_arg_count() {
    text=$1
    printf '%s\n' "$text" | awk -v arg="$KERNEL_ARG" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == arg) count++
            }
        }
        END { print count + 0 }
    '
}

strip_kernel_arg() {
    text=$1
    printf '%s\n' "$text" | awk -v arg="$KERNEL_ARG" '
        {
            output = ""
            for (i = 1; i <= NF; i++) {
                if ($i == arg) continue
                if (output != "") output = output " "
                output = output $i
            }
            print output
        }
    '
}

append_kernel_arg() {
    value=$(strip_kernel_arg "$1")
    value=$(printf '%s' "$value" | sed 's/[[:space:]]*$//')
    if [ -n "$value" ]; then
        printf '%s %s\n' "$value" "$KERNEL_ARG"
    else
        printf '%s\n' "$KERNEL_ARG"
    fi
}

ensure_kernel_cmdline() {
    current=

    if [ -r "$KERNEL_CMDLINE" ]; then
        current=$(cat "$KERNEL_CMDLINE")
    else
        # Fedora normally has BLS entries but may not have created
        # /etc/kernel/cmdline yet. Seed it from a normal, non-experimental entry.
        base_entry=$(find /boot/loader/entries -maxdepth 1 -type f -name '*.conf' \
            ! -name '*~custom.conf' \
            ! -name '*nvd1*' \
            ! -name '*acpi*' \
            -print 2>/dev/null | sort | head -n 1)

        [ -n "$base_entry" ] || die "cannot derive /etc/kernel/cmdline; create it manually"

        current=$(awk '
            $1 == "options" {
                sub(/^[^[:space:]]+[[:space:]]+/, "")
                print
                exit
            }
        ' "$base_entry")
        [ -n "$current" ] || die "no options line found in $base_entry"
    fi

    desired=$(append_kernel_arg "$current")
    cmdline_tmp="$TMP_DIR/kernel.cmdline"
    printf '%s\n' "$desired" >"$cmdline_tmp"
    write_root_file_if_changed "$cmdline_tmp" "$KERNEL_CMDLINE" 0644
}

ensure_existing_entries() {
    need_update=0

    for entry in /boot/loader/entries/*.conf; do
        [ -f "$entry" ] || continue
        if ! entry_has_kernel_arg "$entry"; then
            need_update=1
            break
        fi
    done

    if [ "$need_update" -eq 1 ]; then
        need_command grubby
        # Normalize rather than blindly appending: this removes duplicates
        # left by older versions or manual edits, then adds exactly one copy.
        as_root grubby --update-kernel=ALL --remove-args="$KERNEL_ARG"
        as_root grubby --update-kernel=ALL --args="$KERNEL_ARG"
    fi
}

regenerate_initramfs_kernel() {
    kver=$1
    vmlinuz="/boot/vmlinuz-$kver"
    image="/boot/initramfs-$kver.img"

    [ -e "$vmlinuz" ] || die "kernel image not found: $vmlinuz"
    printf 'Building %s\n' "$image"
    as_root dracut -v --force --kver "$kver" "$image"
    as_root test -f "$image" || die "dracut did not create initramfs: $image"
}

regenerate_current_initramfs() {
    kver=$(uname -r)
    [ -d "/lib/modules/$kver" ] ||
        die "running kernel modules not found: /lib/modules/$kver"
    regenerate_initramfs_kernel "$kver"
}

regenerate_all_initramfs() {
    found_kernel=0

    for kernel_dir in /lib/modules/*; do
        [ -d "$kernel_dir" ] || continue
        kver=$(basename "$kernel_dir")
        vmlinuz="/boot/vmlinuz-$kver"
        [ -e "$vmlinuz" ] || continue
        found_kernel=1
        regenerate_initramfs_kernel "$kver"
    done

    [ "$found_kernel" -eq 1 ] ||
        die "no installed kernels found under /boot and /lib/modules"
}

verify_current_initramfs() {
    need_command lsinitrd
    image="/boot/initramfs-$(uname -r).img"
    # Initramfs images are normally mode 0600 and root-owned.  Test for
    # existence here; lsinitrd is run through as_root below.
    as_root test -f "$image" || die "current initramfs not found: $image"

    listing="$TMP_DIR/current-initrd.list"
    as_root lsinitrd "$image" >"$listing"
    while IFS= read -r aml_name; do
        if ! grep -Fq "kernel/firmware/acpi/$aml_name" "$listing"; then
            die "ACPI AML was not found in $image: $aml_name"
        fi
    done <"$AML_NAMES_FILE"
}

remove_kernel_arg_from_cmdline() {
    [ -r "$KERNEL_CMDLINE" ] || return 0

    if [ -z "$TMP_DIR" ]; then
        TMP_DIR=$(mktemp -d)
    fi

    cmdline_tmp="$TMP_DIR/kernel.cmdline.remove"
    strip_kernel_arg "$(cat "$KERNEL_CMDLINE")" >"$cmdline_tmp"
    write_root_file_if_changed "$cmdline_tmp" "$KERNEL_CMDLINE" 0644
}


prepare_install() {
    need_command dracut

    compile_patches
    install_dracut_config
    install_aml_set
    ensure_kernel_cmdline
    ensure_existing_entries
}

finish_install() {
    scope=$1

    case "$scope" in
        current)
            printf 'Regenerating initramfs for the running kernel only\n'
            regenerate_current_initramfs
            ;;
        all)
            printf 'Regenerating initramfs for every installed kernel\n'
            regenerate_all_initramfs
            ;;
        *)
            die "unknown initramfs scope: $scope"
            ;;
    esac

    verify_current_initramfs

    printf 'ACPI fixes installed under: %s\n' "$SYSTEM_ACPI_DIR"
    printf 'Dracut config: %s\n' "$DRACUT_CONF"
    printf 'Kernel argument: %s\n' "$KERNEL_ARG"
}

install_action() {
    prepare_install
    finish_install current
}

install_all_action() {
    prepare_install
    finish_install all
}

prepare_remove() {
    need_command dracut

    remove_aml_set
    remove_kernel_arg_from_cmdline

    if command -v grubby >/dev/null 2>&1; then
        as_root grubby --update-kernel=ALL --remove-args="$KERNEL_ARG"
    fi
}

finish_remove() {
    scope=$1

    case "$scope" in
        current)
            printf 'Regenerating initramfs for the running kernel only\n'
            regenerate_current_initramfs
            printf 'ACPI fix removed from the running kernel image.\n'
            printf 'Use %s remove-all to rebuild every installed kernel image.\n' "$0"
            ;;
        all)
            printf 'Regenerating initramfs for every installed kernel\n'
            regenerate_all_initramfs
            printf 'ACPI fix removed from every installed kernel image.\n'
            ;;
        *)
            die "unknown initramfs scope: $scope"
            ;;
    esac
}

remove_action() {
    prepare_remove
    finish_remove current
}

remove_all_action() {
    prepare_remove
    finish_remove all
}

status_action() {
    printf 'Patch directory:  %s\n' "$PATCH_DIR"
    printf 'Generated AMLs:   %s\n' "$AML_BUILD_DIR"
    printf 'Installed AMLs:   %s\n' "$SYSTEM_ACPI_DIR"
    printf 'Dracut config:    %s\n' "$DRACUT_CONF"
    printf 'Kernel cmdline:   %s\n' "$KERNEL_CMDLINE"
    printf '\n'

    if [ -r "$SYSTEM_MANIFEST" ]; then
        printf 'installed AMLs:\n'
        while IFS= read -r aml_name; do
            [ -n "$aml_name" ] || continue
            if [ -f "$SYSTEM_ACPI_DIR/$aml_name" ]; then
                printf '  %s: present\n' "$aml_name"
            else
                printf '  %s: missing\n' "$aml_name"
            fi
        done <"$SYSTEM_MANIFEST"
    else
        printf 'installed AMLs: no manifest\n'
    fi

    if [ -f "$DRACUT_CONF" ]; then
        printf 'dracut config:\n'
        sed 's/^/  /' "$DRACUT_CONF"
    else
        printf 'dracut config: missing\n'
    fi

    if [ -r "$KERNEL_CMDLINE" ]; then
        printf 'future cmdline: '
        cat "$KERNEL_CMDLINE"
    else
        printf 'future cmdline: missing\n'
    fi

    printf 'running cmdline: '
    cat /proc/cmdline
    printf 'current initramfs: '
    if as_root test -f "/boot/initramfs-$(uname -r).img" &&
        command -v lsinitrd >/dev/null 2>&1; then
        listing=$(mktemp)
        as_root lsinitrd "/boot/initramfs-$(uname -r).img" >"$listing"
        if [ -r "$SYSTEM_MANIFEST" ]; then
            while IFS= read -r aml_name; do
                [ -n "$aml_name" ] || continue
                if grep -Fq "kernel/firmware/acpi/$aml_name" "$listing"; then
                    printf '%s: present; ' "$aml_name"
                else
                    printf '%s: missing; ' "$aml_name"
                fi
            done <"$SYSTEM_MANIFEST"
            printf '\n'
        else
            printf 'no manifest\n'
        fi
        rm -f "$listing"
    else
        printf 'unavailable\n'
    fi
}

usage() {
    printf 'Usage: %s {install|install-all|status|remove|remove-all}\n' "$0"
}

case "$ACTION" in
    install) install_action ;;
    install-all) install_all_action ;;
    status) status_action ;;
    remove) remove_action ;;
    remove-all) remove_all_action ;;
    *) usage >&2; exit 2 ;;
esac
