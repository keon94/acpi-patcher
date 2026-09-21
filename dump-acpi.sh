#!/bin/sh

cd acpi/
sudo acpidump -b
sudo acpixtract -a *.dat
sudo iasl -d dsdt.dat ssdt*.dat 2>/dev/null
cd -
