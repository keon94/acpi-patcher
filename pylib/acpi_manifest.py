"""Reading and querying captured ACPI table manifests."""

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Self

from .acpi_table import AcpiTable, TableKind
from .errors import AcpiError


MANIFEST_VERSION = "acpi-patcher-manifest-v1"
SAFE_NAME = re.compile(r"^[A-Za-z0-9._+-]+$")


@dataclass(frozen=True, slots=True)
class AcpiManifest:
    path: Path
    tables: tuple[AcpiTable, ...]

    @classmethod
    def read(cls, path: Path) -> Self:
        if not path.is_file():
            raise AcpiError(f"ACPI manifest not found: {path}; run dump-acpi.sh first")

        tables: list[AcpiTable] = []
        keys: set[str] = set()
        orders: set[int] = set()
        version_found = False
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), 1
        ):
            if not line or line.startswith("#"):
                version_found |= line == f"# {MANIFEST_VERSION}"
                continue
            fields = line.split("\t")
            if len(fields) != 5:
                raise AcpiError(
                    f"manifest line {line_number} must have five tab-separated fields"
                )
            order_text, key, kind_text, raw_text, dsl_text = fields
            try:
                order = int(order_text)
                kind = TableKind(kind_text)
            except ValueError as error:
                raise AcpiError(
                    f"invalid manifest data on line {line_number}: {line!r}"
                ) from error
            if order in orders:
                raise AcpiError(f"duplicate manifest order: {order}")
            if not key or SAFE_NAME.fullmatch(key) is None:
                raise AcpiError(
                    f"invalid manifest table key on line {line_number}: {key!r}"
                )
            if key in keys:
                raise AcpiError(f"duplicate manifest table key: {key}")
            orders.add(order)
            keys.add(key)
            tables.append(
                AcpiTable(
                    order,
                    key,
                    kind,
                    cls._manifest_file(path, raw_text, "raw table"),
                    cls._manifest_file(path, dsl_text, "DSL table")
                    if dsl_text
                    else None,
                )
            )

        if not version_found:
            raise AcpiError(
                f"unsupported ACPI manifest format: {path}; rerun dump-acpi.sh"
            )
        if not tables:
            raise AcpiError(f"ACPI manifest is empty: {path}")
        return cls(path, tuple(sorted(tables, key=lambda table: table.order)))

    @staticmethod
    def _manifest_file(manifest: Path, value: str, label: str) -> Path:
        relative = Path(value)
        if relative.is_absolute() or ".." in relative.parts:
            raise AcpiError(f"unsafe {label} path in manifest: {value}")
        result = manifest.parent / relative
        if not result.is_file():
            raise AcpiError(f"manifest {label} file does not exist: {result}")
        return result

    def require(self, key: str) -> AcpiTable:
        try:
            return next(table for table in self.tables if table.key == key)
        except StopIteration as error:
            raise AcpiError(
                f"table key is not present in {self.path}: {key}"
            ) from error
