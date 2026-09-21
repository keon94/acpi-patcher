#!/bin/sh

KVER=$(uname -r)
TEST_INITRD="$PWD/build/initramfs-$KVER-nvd1-test.img"

sudo dracut -v \
  --kver "$KVER" \
  --include "$PWD/build/nvd1-alias.aml" /kernel/firmware/acpi/nvd1-alias.aml \
  "$TEST_INITRD"
