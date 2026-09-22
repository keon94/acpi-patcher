# ACPI Table Patcher

This repository provides a small, reversible workflow for experimenting with
ACPI table additions and replacements on Linux. The framework is generic, but
its system integration currently assumes a Fedora-like layout with dracut,
BLS entries, and grubby.

The contents of acpi/ and patches/ are intentionally ignored by Git. They are
machine-specific inputs and must be created locally for each target machine.
The tracked scripts provide the framework; the firmware dump and patch
sources are supplied by the user.

## What it does

dump-acpi.sh captures the tables exposed by the running kernel:

    acpi/raw/       exact binary tables
    acpi/dsl/       iasl-decompiled ASL sources
    acpi/.manifest  table metadata and load order consumed by patch-acpi.sh

It preserves data-only tables such as FACS in acpi/raw/ but does not try to
decompile them. Run it before writing a replacement:

    ./dump-acpi.sh

patch-acpi.sh compiles selected .dsl files, installs their AML output under
/etc/acpi-tables/, configures dracut to include that directory in initramfs
images, and ensures acpi_table_upgrade is present in Fedora boot entries.

The script must be run as root because it changes /etc, /boot, and initramfs
images:

    sudo ./patch-acpi.sh install --path patches/example.dsl

## Additive patches and table replacements

An ordinary .dsl file is an additive AML table. Its compiled output is loaded
in addition to the firmware tables:

    patches/10-add-method.dsl  ->  build/acpi-fixes/10-add-method.aml

A file whose name ends in .override.dsl replaces one table from the ACPI dump.
The portion before .override.dsl must exactly match a key in acpi/.manifest:

    patches/SSDT7.override.dsl

The installer does not infer table order from patch names. The dump manifest
contains the table key, raw file, table kind, and load order; the generic
Python helper uses that metadata when assembling the replacement set.

## Optional Python hooks

For either patch type, an optional Python file may sit next to the DSL with
the same complete basename:

    patches/10-add-method.dsl
    patches/10-add-method.py

    patches/SSDT7.override.dsl
    patches/SSDT7.override.py

The hook must define a concrete `Patch` class:

    from pylib.patch import AcpiPatch, PatchContext

    class Patch(AcpiPatch):
        def apply(self, context: PatchContext) -> None:
            ...

The hook receives a PatchContext with:

| Attribute or method | Purpose |
| --- | --- |
| context.patch_path | selected DSL path |
| context.compiled_aml | compiled AML path; additive hooks may edit it in place |
| context.mode | additive or override |
| context.target | replacement table key, or patch stem for an additive hook |
| context.manifest | typed AcpiManifest when available |
| context.manifest.tables | ordered typed AcpiTable values |
| context.replace_table(key, aml_path) | redirect an override to another compiled AML |
| context.log(message) | print a diagnostic message |

For an override, the overrider uses the compiled AML for the target after the
hook runs unless the hook registered a different file. A hook only calls
context.replace_table() to redirect that replacement or add another table.
Additive hooks may edit their AML in place, but may not register table
replacements.

Hooks execute as root during installation. Treat them as trusted local code.

The Python boundary is deliberately small. patch-acpi.sh remains responsible for
path selection, DSL compilation, installed-file manifests, dracut, kernel
arguments, initramfs regeneration, and rollback. The typed Python package is
used only for replacement-table mechanics and hook execution:

* acpi_header.py parses and updates ACPI table headers;
* acpi_table.py defines captured and prepared ACPI tables;
* acpi_manifest.py reads and queries captured table manifests;
* acpi_overrider.py prepares complete ACPI table override sets;
* patch.py defines DSL patches, hook context, and hook application;
* main.py provides the narrow shell-facing command line.

## Requirements

On Fedora:

    sudo dnf install acpica-tools dracut grubby

The running kernel must support ACPI table upgrades:

    grep CONFIG_ACPI_TABLE_UPGRADE /boot/config-$(uname -r)

Expected:

    CONFIG_ACPI_TABLE_UPGRADE=y

## Selecting patches

--path is required for install and remove/uninstall. It accepts files,
shell-expanded wildcards, and directories. A directory selects its direct
*.dsl children; nested directories are not searched.

Examples:

    # One additive patch
    sudo ./patch-acpi.sh install --path patches/10-add-method.dsl

    # Several explicitly selected patches (the shell expands the wildcard)
    sudo ./patch-acpi.sh install --path patches/*.dsl

    # Every direct DSL file in a directory
    sudo ./patch-acpi.sh install --path patches

    # Rebuild every installed kernel, rather than only the running kernel
    sudo ./patch-acpi.sh install --all-kernels --path patches

    # Remove one patch while preserving other installed patches
    sudo ./patch-acpi.sh uninstall --path patches/10-add-method.dsl

    # Remove all selected patches from every installed kernel
    sudo ./patch-acpi.sh remove --all-kernels --path patches

    # Show installed source patches, AMLs, dracut state, and initramfs coverage
    sudo ./patch-acpi.sh status

Patch paths are tracked by their canonical path in
/etc/acpi-tables/.acpi-fixes-sources. Re-running an identical command is
idempotent: it does not duplicate patches, boot arguments, or manifest rows.

An ordinary install or remove rebuilds only the running kernel's initramfs.
--all-kernels explicitly rebuilds every installed kernel that has both a
kernel image and a module directory. Compilation and validation happen before
system files are changed.

## Typical workflow

1. Capture the firmware tables:

       ./dump-acpi.sh

2. Create one or more local .dsl patches under patches/. Every DSL must
   compile independently with iasl. For a replacement, use the exact
   manifest key in the .override.dsl filename.

3. Install a selected patch set:

       sudo ./patch-acpi.sh install --path patches

4. Inspect and reboot:

       sudo ./patch-acpi.sh status
       cat /proc/cmdline

   The command line should contain acpi_table_upgrade.

## Rollback

To remove the persistent patch set:

    sudo ./patch-acpi.sh uninstall --path patches
    sudo ./patch-acpi.sh remove --all-kernels --path patches

The first command removes the selected source patches from the managed
installation; the second rebuilds all installed kernel images without them.
Unrelated files and boot entries are left alone. Old custom initramfs images
or experimental BLS entries created outside this script must be removed
separately after the normal entry has been tested.

If a patch makes the normal entry unbootable, select an older working kernel or
rescue entry and run the rollback command there. If no installed kernel boots,
use a Fedora live/rescue environment, mount the Fedora root and EFI
filesystems, chroot into the installation, remove
/etc/dracut.conf.d/90-acpi-fixes.conf, remove the AML files listed by
/etc/acpi-tables/.acpi-fixes-manifest, remove acpi_table_upgrade from
/etc/kernel/cmdline, and rebuild the affected images with:

    dracut --regenerate-all --force

## Repository layout

    .
    ├── patch-acpi.sh
    ├── pylib/
    │   ├── acpi_header.py
    │   ├── acpi_manifest.py
    │   ├── acpi_table.py
    │   ├── acpi_overrider.py
    │   ├── patch.py
    │   └── main.py
    ├── dump-acpi.sh
    ├── acpi/
    │   ├── raw/
    │   └── dsl/
    ├── build/
    │   └── acpi-fixes/
    └── patches/
        ├── *.dsl
        └── *.py
