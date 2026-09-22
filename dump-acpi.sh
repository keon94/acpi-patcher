#!/bin/sh
set -eu

# Capture the ACPI tables exposed by the running kernel.
#
# Generated layout:
#   acpi/raw/       exact binary tables
#   acpi/dsl/       iasl-decompiled ASL sources for namespace tables
#   acpi/.manifest  table metadata and load order consumed by patch-acpi
#
# The manifest is authoritative: patch targets are the table keys recorded
# here, not names guessed by the installer. Hand-written patches are never
# modified.

LC_ALL=C
export LC_ALL

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ACPI_DIR="$SCRIPT_DIR/acpi"
RAW_DIR="$ACPI_DIR/raw"
DSL_DIR="$ACPI_DIR/dsl"
MANIFEST="$ACPI_DIR/.manifest"
TABLE_DIR=${TABLE_DIR:-/sys/firmware/acpi/tables}
TMP_DIR=$(mktemp -d)

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup() {
    [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

need_command iasl
[ -d "$TABLE_DIR" ] || die "$TABLE_DIR is unavailable; are ACPI tables exposed?"

STAGE_RAW="$TMP_DIR/raw"
STAGE_DSL="$TMP_DIR/dsl"
STAGE_LOG="$TMP_DIR/log"
STAGE_MANIFEST="$TMP_DIR/manifest"
mkdir -p "$STAGE_RAW" "$STAGE_DSL" "$STAGE_LOG"
printf '# acpi-patcher-manifest-v1\n' >"$STAGE_MANIFEST"
printf '# order\tkey\tkind\traw\tdsl\n' >>"$STAGE_MANIFEST"

table_names="$TMP_DIR/table-names"
find "$TABLE_DIR" -maxdepth 1 -type f -printf '%f\n' | sort -V >"$table_names"
[ -s "$table_names" ] || die "no ACPI tables found in $TABLE_DIR"

table_count=0
order=0
while IFS= read -r name; do
    table="$TABLE_DIR/$name"
    [ -f "$table" ] || continue
    if [ "$(id -u)" -eq 0 ]; then
        install -m0644 "$table" "$STAGE_RAW/$name"
    else
        sudo install -m0644 "$table" "$STAGE_RAW/$name"
        sudo chown "$(id -u):$(id -g)" "$STAGE_RAW/$name"
    fi

    # FACS is a data structure, not an AML namespace. Preserve it in raw/;
    # no ASL source is associated with it and it will not be staged for an
    # ACPI table upgrade.
    if [ "$name" = FACS ]; then
        printf '%04d\t%s\tdata\traw/%s\t\n' "$order" "$name" "$name" >>"$STAGE_MANIFEST"
        printf 'Preserving non-ASL table %s\n' "$name"
    else
        printf 'Decompiling %s\n' "$name"
        log="$STAGE_LOG/$name.log"
        if ! iasl -d -p "$STAGE_DSL/$name" "$STAGE_RAW/$name" >"$log" 2>&1; then
            cat "$log" >&2
            die "iasl failed while decompiling $name"
        fi
        [ -s "$STAGE_DSL/$name.dsl" ] || die "iasl did not produce $STAGE_DSL/$name.dsl"
        printf '%04d\t%s\taml\traw/%s\tdsl/%s.dsl\n' \
            "$order" "$name" "$name" "$name" >>"$STAGE_MANIFEST"
    fi
    order=$((order + 1))
    table_count=$((table_count + 1))
done <"$table_names"

[ "$table_count" -gt 0 ] || die "no ACPI tables found in $TABLE_DIR"

# Remove only files recorded by the previous run. Untracked files under acpi/
# are preserved so users can keep notes or additional local material there.
if [ -r "$MANIFEST" ]; then
    while IFS='	' read -r old_order old_key old_kind old_raw old_dsl; do
        case "$old_raw" in
            raw/*) rm -f "$ACPI_DIR/$old_raw" ;;
        esac
        case "$old_dsl" in
            dsl/*) rm -f "$ACPI_DIR/$old_dsl" ;;
        esac
    done <"$MANIFEST"
fi

mkdir -p "$RAW_DIR" "$DSL_DIR"
while IFS='	' read -r row_order row_key row_kind row_raw row_dsl; do
    case "$row_raw" in
        raw/*) install -m0644 "$STAGE_RAW/${row_raw#raw/}" "$ACPI_DIR/$row_raw" ;;
    esac
    case "$row_dsl" in
        dsl/*) install -m0644 "$STAGE_DSL/${row_dsl#dsl/}" "$ACPI_DIR/$row_dsl" ;;
    esac
done <"$STAGE_MANIFEST"

install -m0644 "$STAGE_MANIFEST" "$MANIFEST"

printf 'Captured %s ACPI tables.\n' "$table_count"
printf 'Raw tables: %s\n' "$RAW_DIR"
printf 'Decompiled ASL: %s\n' "$DSL_DIR"
printf 'Manifest: %s\n' "$MANIFEST"
