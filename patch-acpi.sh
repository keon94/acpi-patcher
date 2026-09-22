#!/bin/bash
set -eu

# Install selected ACPI patches on a Fedora-like system.
#
# Source patches are selected explicitly with --path. Files ending in
# .override.dsl replace firmware tables; all other .dsl files are additive.
#
# Persistent installation:
#   /etc/acpi-tables/*.aml (managed additive and replacement tables)
#   /etc/dracut.conf.d/90-acpi-fixes.conf
#   /etc/kernel/cmdline (acpi_table_upgrade)

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYLIB_MAIN="$SCRIPT_DIR/pylib/main.py"

die() {
    # Print the user's custom error message first
    printf 'error: %s\n' "$*" >&2
    echo "Stack trace (most recent call first):" >&2

    # Loop through the bash call stack arrays
    local i
    for ((i=1; i<${#FUNCNAME[@]}; i++)); do
        local func="${FUNCNAME[$i]}"
        local line="${BASH_LINENO[$((i-1))]}"
        local file="${BASH_SOURCE[$i]}"

        # Format the top-level script scope for cleaner reading
        if [ "$func" == "main" ] && [ $i -eq $(( ${#FUNCNAME[@]} - 1 )) ]; then
            func="__main_scope__"
        fi

        printf '  at %s() in %s:%s\n' "$func" "$file" "$line" >&2
    done

    exit 1
}

run_pylib() {
    (cd "$SCRIPT_DIR" && PYTHONDONTWRITEBYTECODE=1 python3 -m pylib.main "$@")
}

ACTION=
ALL_KERNELS=0
TMP_DIR=$(mktemp -d)
PATH_SPECS_FILE="$TMP_DIR/path-specs"

usage() {
    printf 'Usage:\n'
    printf '  %s install [--all-kernels] --path PATH [PATH ...]\n' "$0"
    printf '  %s remove|uninstall [--all-kernels] --path PATH [PATH ...]\n' "$0"
    printf '  %s status\n' "$0"
}

parse_args() {
    [ "$#" -gt 0 ] || { usage >&2; exit 2; }

    ACTION=$1
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --all-kernels)
                ALL_KERNELS=1
                shift
                ;;
            --path)
                shift
                [ "$#" -gt 0 ] || die '--path requires at least one path'
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --*) break ;;
                    esac
                    printf '%s\n' "$1" >>"$PATH_SPECS_FILE"
                    shift
                done
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "unknown option or argument: $1"
                ;;
        esac
    done

    case "$ACTION" in
        install|remove|uninstall)
            [ -s "$PATH_SPECS_FILE" ] ||
                die "$ACTION requires --path PATH [PATH ...]"
            ;;
        status)
            [ "$ALL_KERNELS" -eq 0 ] || die 'status does not accept --all-kernels'
            [ ! -s "$PATH_SPECS_FILE" ] || die 'status does not accept --path'
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

parse_args "$@"

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
SOURCE_MANIFEST="$SYSTEM_ACPI_DIR/.acpi-fixes-sources"
DRACUT_CONF=/etc/dracut.conf.d/90-acpi-fixes.conf
KERNEL_CMDLINE=/etc/kernel/cmdline
KERNEL_ARG=acpi_table_upgrade

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

canonical_path() {
    path=$1
    case "$path" in
        /*) absolute=$path ;;
        *) absolute="$PWD/$path" ;;
    esac

    directory=$(dirname -- "$absolute")
    filename=$(basename -- "$absolute")
    (
        CDPATH= cd -P "$directory" 2>/dev/null || exit 1
        printf '%s/%s\n' "$PWD" "$filename"
    ) || die "cannot resolve path: $path"
}

resolve_patch_paths() {
    resolved="$TMP_DIR/selected-patches"
    expanded="$TMP_DIR/expanded-paths"
    : >"$expanded"

    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        if [ -d "$spec" ]; then
            find "$spec" -maxdepth 1 -type f -name '*.dsl' -print >>"$expanded"
        elif [ -f "$spec" ]; then
            case "$spec" in
                *.dsl) printf '%s\n' "$spec" >>"$expanded" ;;
                *) die "dsl_patch file does not have a .dsl suffix: $spec" ;;
            esac
        else
            case "$spec" in
                *\**|*\?*|*\[*\]*)
                    die "path pattern matched nothing: $spec"
                    ;;
                *)
                    die "dsl_patch path not found: $spec"
                    ;;
            esac
        fi
    done <"$PATH_SPECS_FILE"

    [ -s "$expanded" ] || die 'the selected paths contain no .dsl files'

    while IFS= read -r path; do
        canonical_path "$path"
    done <"$expanded" | LC_ALL=C sort -u >"$resolved"

    [ -s "$resolved" ] || die 'the selected paths contain no .dsl files'
    SELECTED_PATCHES=$resolved
}

patch_mode() {
    case "$1" in
        *.override.dsl) printf 'override\n' ;;
        *) printf 'additive\n' ;;
    esac
}

validate_original_dsl() {
    dsl_patch=$1
    name=$(basename "$dsl_patch" .override.dsl)
    manifest="$SCRIPT_DIR/acpi/.manifest"
    [ -r "$manifest" ] ||
        die "override dsl_patch requires an ACPI manifest; run $SCRIPT_DIR/dump-acpi.sh first"

    # Validates that $name matches an exact filename in the manifest
    if ! grep -Eq "^[^#].*/${name}\.dsl$" "$manifest"; then
        die "Component '$name' is missing or invalid in manifest."
    fi
}

migrate_source_manifest() {
    migrated="$TMP_DIR/migrated-sources"
    : >"$migrated"

    [ -r "$SOURCE_MANIFEST" ] && {
        cat "$SOURCE_MANIFEST" >"$migrated"
        printf '%s\n' "$migrated"
        return 0
    }

    # Older versions tracked only generated AML names. Recover source paths
    # when they still exist under the repository's dsl_patch directory.
    if [ -r "$SYSTEM_MANIFEST" ]; then
        while IFS= read -r aml_name; do
            [ -n "$aml_name" ] || continue
            stem=$(basename "$aml_name" .aml)
            candidate="$PATCH_DIR/$stem.dsl"
            if [ -f "$candidate" ]; then
                printf '%s\t%s\n' "$(patch_mode "$candidate")" "$(canonical_path "$candidate")" >>"$migrated"
            fi
        done <"$SYSTEM_MANIFEST"
    fi

    printf '%s\n' "$migrated"
}

build_desired_sources() {
    action=$1
    current=$(migrate_source_manifest)
    desired="$TMP_DIR/desired-sources"
    selected="$TMP_DIR/selected-canonical"
    : >"$desired"
    : >"$selected"

    while IFS= read -r path; do
        printf '%s\n' "$path" >>"$selected"
    done <"$SELECTED_PATCHES"

    if [ -r "$current" ]; then
        while IFS='	' read -r mode path; do
            [ -n "$path" ] || continue
            keep=1
            while IFS= read -r selected_path; do
                [ "$path" = "$selected_path" ] && keep=0
            done <"$selected"

            if [ "$action" = install ] || [ "$keep" -eq 1 ]; then
                printf '%s\t%s\n' "$mode" "$path" >>"$desired"
            fi
        done <"$current"
    fi

    if [ "$action" = install ]; then
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            printf '%s\t%s\n' "$(patch_mode "$path")" "$path" >>"$desired"
        done <"$selected"
    fi

    # A path is the identity of an installed dsl_patch. Last-write ordering is
    # discarded here so rerunning the same command is idempotent.
    awk -F '	' '!seen[$2]++' "$desired" | LC_ALL=C sort -t '	' -k2,2 >"$desired.sorted"
    DESIRED_SOURCES="$desired.sorted"
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
    need_command python3
    [ -r "$PYLIB_MAIN" ] ||
        die "Python ACPI helper not found: $PYLIB_MAIN"

    resolve_patch_paths
    case "$ACTION" in
        install) build_desired_sources install ;;
        remove|uninstall) build_desired_sources remove ;;
        *) die "cannot build patches for action: $ACTION" ;;
    esac

    PATCH_LIST="$DESIRED_SOURCES"
    AML_STAGE="$TMP_DIR/aml"
    COMPILE_STAGE="$TMP_DIR/compile"
    AML_NAMES_FILE="$TMP_DIR/aml-names"
    OVERRIDE_JOBS="$TMP_DIR/override-jobs"
    OVERRIDE_MANIFEST="$TMP_DIR/override-manifest"

    mkdir -p "$AML_STAGE" "$COMPILE_STAGE"
    : >"$AML_NAMES_FILE"
    : >"$OVERRIDE_JOBS"

    if [ -s "$PATCH_LIST" ]; then
        while IFS='	' read -r mode dsl_patch; do
            [ -n "$dsl_patch" ] || continue
            target_dsl_key=$(basename "$dsl_patch" .dsl)
            [ -n "$target_dsl_key" ] || die "invalid empty dsl_patch name: $dsl_patch"

            output_aml="$COMPILE_STAGE/$target_dsl_key.aml"
            printf 'Compiling %s\n' "$dsl_patch"
            iasl -ve -tc -p "$output_aml" "$dsl_patch"
            [ -s "$output_aml" ] || die "iasl did not produce $output_aml"
            if [ "$mode" = override ]; then
                validate_original_dsl "$dsl_patch"
                python_patcher="${dsl_patch%.dsl}.py"
                if [ -f "$python_patcher" ]; then
                    printf '%s\t%s\t%s\t%s\n' \
                        "$target_dsl_key" "$dsl_patch" "$output_aml" "$python_patcher" >>"$OVERRIDE_JOBS"
                else
                    printf '%s\t%s\t%s\t\n' \
                        "$target_dsl_key" "$dsl_patch" "$output_aml" >>"$OVERRIDE_JOBS"
                fi
            else
                python_patcher="${dsl_patch%.dsl}.py"
                if [ -f "$python_patcher" ]; then
                    run_pylib apply-dsl-dsl_patch \
                        --python_patcher "$python_patcher" \
                        --dsl_patch "$dsl_patch" \
                        --aml "$output_aml" \
                        --mode additive \
                        --target "$target_dsl_key" \
                        --manifest "$SCRIPT_DIR/acpi/.manifest"
                fi
                aml_name="$target_dsl_key.aml"
                if grep -Fqx "$aml_name" "$AML_NAMES_FILE"; then
                    die "two additive patches produce the same AML name: $aml_name"
                fi
                install -m0644 "$output_aml" "$AML_STAGE/$aml_name"
                printf '%s\n' "$aml_name" >>"$AML_NAMES_FILE"
            fi
        done <"$PATCH_LIST"
    fi
    if [ -s "$OVERRIDE_JOBS" ]; then
        manifest="$SCRIPT_DIR/acpi/.manifest"
        [ -r "$manifest" ] ||
            die "override patches require an ACPI manifest; run $SCRIPT_DIR/dump-acpi.sh first"

        override_stage="$TMP_DIR/override"
        override_manifest="$AML_BUILD_DIR/acpi-overrides.manifest"
        mkdir -p "$override_stage" "$AML_BUILD_DIR"
        rm -f "$AML_BUILD_DIR/acpi-overrides.cpio" \
            "$AML_BUILD_DIR/acpi-ordered.cpio" \
            "$AML_BUILD_DIR/acpi-ordered.manifest"

        run_pylib prepare-overrides \
            --manifest "$manifest" \
            --output-dir "$override_stage" \
            --output-manifest "$override_manifest" \
            --job-file "$OVERRIDE_JOBS"

        while IFS='	' read -r target filename source; do
            [ -n "$filename" ] || continue
            installed_name="override-$filename"
            install -m0644 "$override_stage/$filename" "$AML_STAGE/$installed_name"
            printf '%s\n' "$installed_name" >>"$AML_NAMES_FILE"
        done <"$override_manifest"
    else
        rm -f "$AML_BUILD_DIR/acpi-overrides.cpio" "$AML_BUILD_DIR/acpi-overrides.manifest"
        # Remove artifacts produced by an older framework version.
        rm -f "$AML_BUILD_DIR/acpi-ordered.cpio" "$AML_BUILD_DIR/acpi-ordered.manifest"
    fi

    # Keep generated AMLs in the repository as reproducible build artifacts.
    mkdir -p "$AML_BUILD_DIR"

    # Remove stale generated AMLs from a dsl_patch that was deleted or renamed.
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
    # the current dsl_patch directory. This also migrates the old single-file
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
    write_root_file_if_changed "$DESIRED_SOURCES" "$SOURCE_MANIFEST" 0644
}

remove_dracut_config_and_argument() {
    as_root rm -f "$DRACUT_CONF" "$SOURCE_MANIFEST" "$SYSTEM_MANIFEST"
    remove_kernel_arg_from_cmdline
    if command -v grubby >/dev/null 2>&1; then
        as_root grubby --update-kernel=ALL --remove-args="$KERNEL_ARG"
    fi
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
            ! -name '*custom*.conf' \
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
    install_aml_set

    if [ -s "$AML_NAMES_FILE" ]; then
        install_dracut_config
        ensure_kernel_cmdline
        ensure_existing_entries
    else
        remove_dracut_config_and_argument
    fi
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
    if [ "$ALL_KERNELS" -eq 1 ]; then
        finish_install all
    else
        finish_install current
    fi
}

finish_remove() {
    scope=$1

    case "$scope" in
        current)
            printf 'Regenerating initramfs for the running kernel only\n'
            regenerate_current_initramfs
            printf 'Selected ACPI patches removed from the running kernel image.\n'
            printf 'Use %s remove --all-kernels --path ... to rebuild every installed kernel image.\n' "$0"
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
    prepare_install
    if [ "$ALL_KERNELS" -eq 1 ]; then
        finish_remove all
    else
        finish_remove current
    fi
}

status_action() {
    printf 'Patch directory:  %s\n' "$PATCH_DIR"
    printf 'Generated AMLs:   %s\n' "$AML_BUILD_DIR"
    printf 'Installed AMLs:   %s\n' "$SYSTEM_ACPI_DIR"
    printf 'Dracut config:    %s\n' "$DRACUT_CONF"
    printf 'Kernel cmdline:   %s\n' "$KERNEL_CMDLINE"
    printf '\n'

    if [ -r "$SOURCE_MANIFEST" ]; then
        printf 'installed patches:\n'
        while IFS='	' read -r mode path; do
            [ -n "$path" ] || continue
            printf '  [%s] %s\n' "$mode" "$path"
        done <"$SOURCE_MANIFEST"
    else
        printf 'installed patches: no source manifest\n'
    fi

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

case "$ACTION" in
    install) install_action ;;
    status) status_action ;;
    remove|uninstall) remove_action ;;
    *) usage >&2; exit 2 ;;
esac
