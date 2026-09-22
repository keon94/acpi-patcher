"""Exceptions raised by the typed ACPI patching core."""


class AcpiError(RuntimeError):
    """A malformed, unsupported, or inconsistent ACPI input."""
