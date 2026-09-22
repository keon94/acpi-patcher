"""ACPI table objects and prepared table metadata."""

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from .acpi_header import AcpiHeader


class TableKind(StrEnum):
    AML = "aml"
    DATA = "data"


@dataclass(frozen=True, slots=True)
class AcpiTable:
    order: int
    key: str
    kind: TableKind
    raw_path: Path
    dsl_path: Path | None

    def prepare_override(self, replacement_path: Path) -> bytes:
        raw_data = self.raw_path.read_bytes()
        raw_header = AcpiHeader.parse(raw_data, self.raw_path)
        source_data = replacement_path.read_bytes()
        source_header = AcpiHeader.parse(source_data, replacement_path)
        raw_header.validate_replacement(source_header, replacement_path, self.key)
        return source_header.upgraded(source_data, raw_header.oem_revision + 1)


@dataclass(frozen=True, slots=True)
class PreparedAcpiTable:
    target: str
    filename: str
    source_path: Path
