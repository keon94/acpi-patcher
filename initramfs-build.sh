#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KVER="${1:-$(uname -r)}"

BUILD="$ROOT/build"
SOURCE="$ROOT/patches/nvd1-alias.dsl"
AML="$BUILD/acpi-fixes.aml"
PREFIX_DIR="$BUILD/acpi-early"
PREFIX="$BUILD/acpi-early.cpio"
STOCK="/boot/initramfs-${KVER}.img"
OUTPUT="$BUILD/initramfs-${KVER}-acpi-fixes.img"
BOOT_OUTPUT="/boot/initramfs-${KVER}-acpi-fixes.img"

command -v iasl >/dev/null
command -v cpio >/dev/null
[[ -r "$STOCK" ]] || {
    echo "Missing stock initramfs: $STOCK" >&2
    exit 1
}

mkdir -p "$BUILD"

echo "Compiling ACPI source..."
iasl -ve -tc -p "$BUILD/acpi-fixes" "$SOURCE"

rm -rf "$PREFIX_DIR"
mkdir -p "$PREFIX_DIR/kernel/firmware/acpi"

install -m 0644 \
    "$AML" \
    "$PREFIX_DIR/kernel/firmware/acpi/acpi-fixes.aml"

echo "Creating uncompressed ACPI cpio prefix..."
(
    cd "$PREFIX_DIR"
    find kernel -print | cpio -H newc -o
) > "$PREFIX"

echo "Concatenating ACPI prefix with stock initramfs..."
cat "$PREFIX" "$STOCK" > "$OUTPUT"

sudo install -o root -g root -m 0600 \
    "$OUTPUT" \
    "$BOOT_OUTPUT"

prefix_size=$(stat -c '%s' "$PREFIX")
stock_size=$(stat -c '%s' "$STOCK")
output_size=$(stat -c '%s' "$OUTPUT")

if [[ "$output_size" -ne $((prefix_size + stock_size)) ]]; then
    echo "ERROR: initramfs size verification failed" >&2
    exit 1
fi

echo "Created: $BOOT_OUTPUT"
echo "Size verified: $output_size bytes"
