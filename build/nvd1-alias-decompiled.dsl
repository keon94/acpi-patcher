/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of build/nvd1-alias.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x00000088 (136)
 *     Revision         0x02
 *     Checksum         0x5D
 *     OEM ID           "KEON"
 *     OEM Table ID     "NVD1FIX"
 *     OEM Revision     0x00000001 (1)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "SSDT", 2, "KEON", "NVD1FIX", 0x00000001)
{
    External (_SB_.PCI0.GPP0.PEGP, DeviceObj)
    External (_SB_.PCI0.LPC0.EC0_.NVD1, FieldUnitObj)

    Scope (\_SB.PCI0.GPP0.PEGP)
    {
        Alias (\_SB.PCI0.LPC0.EC0.NVD1, NVD1)
    }
}

