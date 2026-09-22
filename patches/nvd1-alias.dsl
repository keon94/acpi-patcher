DefinitionBlock ("", "SSDT", 2, "KEON", "NVD1FIX", 0x00000001)
{
    External (\_SB.PCI0.GPP0.PEGP, DeviceObj)
    External (\_SB.PCI0.LPC0.EC0.NVD1, FieldUnitObj)

    Scope (\_SB.PCI0.GPP0.PEGP)
    {
        Alias (\_SB.PCI0.LPC0.EC0.NVD1, NVD1)
    }
}
