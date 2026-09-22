"""ACPI table header parsing, validation, and revision updates."""

import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Self

from .errors import AcpiError


ACPI_HEADER_SIZE = 36


@dataclass(frozen=True, slots=True)
class AcpiHeader:
    signature: str
    oem_id: bytes
    table_id: bytes
    oem_revision: int

    @classmethod
    def parse(cls, data: bytes, source: Path | str) -> Self:
        if len(data) < ACPI_HEADER_SIZE:
            raise AcpiError(f"ACPI table is too short: {source}")
        try:
            signature = data[:4].decode("ascii")
        except UnicodeDecodeError as error:
            raise AcpiError(f"ACPI signature is not ASCII: {source}") from error
        if not all(0x20 <= byte <= 0x7E for byte in data[:4]):
            raise AcpiError(f"invalid ACPI signature {signature!r}: {source}")
        length = struct.unpack_from("<I", data, 4)[0]
        if length != len(data):
            raise AcpiError(
                f"ACPI length mismatch in {source}: header={length}, bytes={len(data)}"
            )
        return cls(
            signature, data[10:16], data[16:24], struct.unpack_from("<I", data, 24)[0]
        )

    def validate_replacement(
        self, replacement: Self, source: Path, target: str
    ) -> None:
        for attribute, label in (
            ("signature", "signature"),
            ("oem_id", "OEM ID"),
            ("table_id", "table ID"),
        ):
            if getattr(replacement, attribute) != getattr(self, attribute):
                raise AcpiError(
                    f"replacement {source} does not match table {target} ({label} differs)"
                )

    def upgraded(self, data: bytes, minimum_revision: int) -> bytes:
        result = bytearray(data)
        struct.pack_into("<I", result, 24, max(minimum_revision, self.oem_revision))
        result[9] = 0
        result[9] = (-sum(result)) & 0xFF
        if sum(result) & 0xFF:
            raise AcpiError("unable to repair ACPI checksum")
        return bytes(result)
