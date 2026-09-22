# Legion ACPI/NVIDIA Runtime-D3 Investigation

Hardware: Lenovo Legion Slim 5 16AHP9 / machine type 83DH

This repository tracks investigation and reversible ACPI override experiments

Initially for NVIDIA Runtime-D3 and ACPI GPS/NVD1 failures, but has been uplifted to be generic to apply any "patches" to the ACPI dump that is expected to already be generated.

Known firmware:
- BIOS: NRCN27WW
- CPU: AMD Ryzen 8845HS
- GPU: NVIDIA RTX 4060 Laptop

Observed errors:
- ACPI cannot resolve `\_SB.PCI0.GPP0.PEGP.GPS.NVD1`
- NVIDIA GPS_2X callback failures
- NVIDIA platform power-management failures
- Discrete GPU often remains PCI runtime-active after use

Never replace the original BIOS or stock initramfs.
All experiments must use separate Fedora boot entries and custom initramfs images.
