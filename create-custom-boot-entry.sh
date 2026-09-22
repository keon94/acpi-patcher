#!/usr/bin/env bash
set -euo pipefail

KVER="${1:-$(uname -r)}"
BOOT_INITRD="/boot/initramfs-${KVER}-acpi-fixes.img"

[[ -r "$BOOT_INITRD" ]] || {
    echo "Missing ACPI-fixes initramfs: $BOOT_INITRD" >&2
    echo "Run initramfs-build.sh first." >&2
    exit 1
}

BASE_ENTRY=""

for entry in /boot/loader/entries/*-"${KVER}".conf; do
    [[ -f "$entry" ]] || continue

    if grep -q '^title Fedora Linux' "$entry" &&
       ! grep -qE 'ACPI fixes|NVD1 ACPI test' "$entry"; then
        BASE_ENTRY="$entry"
        break
    fi
done

[[ -n "$BASE_ENTRY" ]] || {
    echo "Could not find the normal Fedora BLS entry." >&2
    exit 1
}

TEST_ENTRY="/boot/loader/entries/legion-acpi-fixes-${KVER}.conf"

sudo cp "$BASE_ENTRY" "$TEST_ENTRY"

sudo sed -i \
    -e "s/^title .*/title Fedora Linux (${KVER}) - ACPI fixes/" \
    -e "s#initramfs-${KVER}.img#initramfs-${KVER}-acpi-fixes.img#" \
    "$TEST_ENTRY"

if ! sudo grep -q '^options .*acpi_table_upgrade' "$TEST_ENTRY"; then
    sudo sed -i \
        '/^options / s/$/ acpi_table_upgrade/' \
        "$TEST_ENTRY"
fi

sudo grep -E '^(title|initrd|options)' "$TEST_ENTRY"
