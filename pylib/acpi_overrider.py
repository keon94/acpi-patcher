"""Preparation of complete ACPI table override sets."""

from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path

from .acpi_manifest import AcpiManifest
from .acpi_table import AcpiTable, PreparedAcpiTable, TableKind
from .errors import AcpiError
from .patch import AcpiPatch, DslPatch, PatchContext, PatchMode


@dataclass(frozen=True, slots=True)
class PreparedAcpiTables:
    directory: Path
    tables: tuple[PreparedAcpiTable, ...]

    def write_manifest(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "".join(
                f"{table.target}\t{table.filename}\t{table.source_path}\n"
                for table in self.tables
            ),
            encoding="utf-8",
        )


@dataclass(slots=True)
class AcpiTableOverrider:
    manifest: AcpiManifest
    output_dir: Path
    replacements: dict[str, Path] = field(default_factory=dict)

    def add(self, target: str, aml_path: Path) -> None:
        if self.manifest.require(target).kind is not TableKind.AML:
            raise AcpiError(f"replacement target is not an AML table: {target}")
        if not aml_path.is_file():
            raise AcpiError(f"replacement AML not found for {target}: {aml_path}")
        if target in self.replacements:
            raise AcpiError(f"more than one replacement targets {target}")
        self.replacements[target] = aml_path

    def add_specs(self, specs: Iterable[str]) -> None:
        for spec in specs:
            if "=" not in spec:
                raise AcpiError(f"replacement must be TABLE_KEY=AML: {spec}")
            target, aml_path = spec.split("=", 1)
            self.add(target, Path(aml_path))

    def add_file(self, path: Path) -> None:
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), 1
        ):
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) != 2:
                raise AcpiError(
                    f"replacement file line {line_number} must contain TABLE_KEY and AML path"
                )
            self.add(fields[0], Path(fields[1]))

    def add_patch(self, patch: DslPatch) -> None:
        if patch.target in self.replacements:
            raise AcpiError(f"more than one replacement targets {patch.target}")
        context = PatchContext(
            patch.source_path,
            patch.compiled_aml,
            PatchMode.OVERRIDE,
            patch.target,
            self.manifest,
        )
        if patch.hook_path is not None:
            AcpiPatch.load(patch.hook_path).apply(context)
        context.replacements.setdefault(patch.target, patch.compiled_aml)
        for target, aml_path in context.replacements.items():
            self.add(target, aml_path)

    def prepare(self) -> PreparedAcpiTables:
        self.output_dir.mkdir(parents=True, exist_ok=True)
        for stale in self.output_dir.glob("*.aml"):
            stale.unlink()

        prepared = tuple(
            self._prepare(table)
            for table in self.manifest.tables
            if table.kind is TableKind.AML
        )
        if not prepared:
            raise AcpiError("the ACPI manifest contains no AML tables to stage")
        return PreparedAcpiTables(self.output_dir, prepared)

    def _prepare(self, table: AcpiTable) -> PreparedAcpiTable:
        filename = f"{table.order:04d}-{table.key}.aml"
        (self.output_dir / filename).write_bytes(
            table.prepare_override(self.replacements.get(table.key))
        )
        return PreparedAcpiTable(table.key, filename, table.raw_path)
