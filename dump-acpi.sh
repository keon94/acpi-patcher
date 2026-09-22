#!/bin/sh
set -eu

# Capture the firmware's currently loaded ACPI tables into this repository.
#
# Generated layout:
#   acpi/raw/       exact binary tables from /sys/firmware/acpi/tables
#   acpi/dsl/       iasl-decompiled ASL sources
#   acpi/.manifest  files owned by this script
#
# Keep hand-written patches in patches/*.dsl; this script never modifies them.

# Make glob expansion and generated manifests deterministic across locales.
LC_ALL=C
export LC_ALL

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ACPI_DIR="$SCRIPT_DIR/acpi"
RAW_DIR="$ACPI_DIR/raw"
DSL_DIR="$ACPI_DIR/dsl"
MANIFEST="$ACPI_DIR/.manifest"
TABLE_DIR=/sys/firmware/acpi/tables
TMP_DIR=$(mktemp -d)

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup() {
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT HUP INT TERM

need_command iasl
[ -d "$TABLE_DIR" ] || die "$TABLE_DIR is unavailable; are ACPI tables exposed?"

STAGE_RAW="$TMP_DIR/raw"
STAGE_DSL="$TMP_DIR/dsl"
STAGE_LOG="$TMP_DIR/log"
STAGE_MANIFEST="$TMP_DIR/manifest"
mkdir -p "$STAGE_RAW" "$STAGE_DSL" "$STAGE_LOG"
: >"$STAGE_MANIFEST"

# Copy the binary tables first. Reading sysfs tables requires root on some
# systems, so use sudo only for this read operation when necessary.
table_count=0
for table in "$TABLE_DIR"/*; do
    [ -f "$table" ] || continue
    name=$(basename "$table")
    if [ "$(id -u)" -eq 0 ]; then
        install -m0644 "$table" "$STAGE_RAW/$name"
    else
        sudo install -m0644 "$table" "$STAGE_RAW/$name"
        sudo chown "$(id -u):$(id -g)" "$STAGE_RAW/$name"
    fi
    printf 'raw/%s\n' "$name" >>"$STAGE_MANIFEST"
    table_count=$((table_count + 1))
done

[ "$table_count" -gt 0 ] || die "no ACPI tables found in $TABLE_DIR"

# Decompile in the same lexical order as the raw table names. The order does
# not change the contents, but makes logs and generated commits reproducible.
for table in "$STAGE_RAW"/*; do
    [ -f "$table" ] || continue
    name=$(basename "$table")
    stem="$name"
    log="$STAGE_LOG/$name.log"

    # FACS is a data structure, not an AML namespace, so iasl cannot
    # decompile it into ASL. Preserve it in raw/ but skip dsl/.
    if [ "$name" = FACS ]; then
        printf 'Skipping non-ASL table %s\n' "$name"
        continue
    fi

    printf 'Decompiling %s\n' "$name"
    if ! iasl -d -p "$STAGE_DSL/$stem" "$table" >"$log" 2>&1; then
        cat "$log" >&2
        die "iasl failed while decompiling $name"
    fi

    [ -s "$STAGE_DSL/$stem.dsl" ] || die "iasl did not produce $stem.dsl"
    printf 'dsl/%s.dsl\n' "$stem" >>"$STAGE_MANIFEST"
done

# Remove only files recorded by the previous run. Files manually added under
# acpi/ but not in the manifest are preserved.
if [ -r "$MANIFEST" ]; then
    while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        case "$relative" in
            raw/*|dsl/*)
                rm -f "$ACPI_DIR/$relative"
                ;;
            *)
                die "unsafe path in $MANIFEST: $relative"
                ;;
        esac
    done <"$MANIFEST"
fi

mkdir -p "$RAW_DIR" "$DSL_DIR"

while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    case "$relative" in
        raw/*)
            install -m0644 "$STAGE_RAW/${relative#raw/}" "$ACPI_DIR/$relative"
            ;;
        dsl/*)
            install -m0644 "$STAGE_DSL/${relative#dsl/}" "$ACPI_DIR/$relative"
            ;;
    esac
done <"$STAGE_MANIFEST"

install -m0644 "$STAGE_MANIFEST" "$MANIFEST"

printf 'Captured %s ACPI tables.\n' "$table_count"
printf 'Raw tables: %s\n' "$RAW_DIR"
printf 'Decompiled ASL: %s\n' "$DSL_DIR"
