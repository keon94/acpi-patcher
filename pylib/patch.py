"""DSL patch objects, hook context, and hook application."""

import importlib.util
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Self

from .acpi_manifest import AcpiManifest
from .acpi_table import TableKind
from .errors import AcpiError


class PatchMode(StrEnum):
    ADDITIVE = "additive"
    OVERRIDE = "override"


@dataclass(frozen=True, slots=True)
class DslPatch:
    target: str
    source_path: Path
    compiled_aml: Path
    hook_path: Path | None = None

    @classmethod
    def read_jobs(cls, path: Path, manifest: AcpiManifest) -> tuple[Self, ...]:
        patches: list[Self] = []
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), 1
        ):
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) != 4:
                raise AcpiError(
                    f"job file line {line_number} must contain target, patch, AML, hook"
                )
            target, source_text, aml_text, hook_text = fields
            if manifest.require(target).kind is not TableKind.AML:
                raise AcpiError(f"job target is not an AML table: {target}")
            source_path = Path(source_text)
            compiled_aml = Path(aml_text)
            hook_path = Path(hook_text) if hook_text else None
            for candidate, label in (
                (source_path, "DSL patch"),
                (compiled_aml, "compiled AML"),
            ):
                if not candidate.is_file():
                    raise AcpiError(f"{label} does not exist: {candidate}")
            if hook_path is not None and not hook_path.is_file():
                raise AcpiError(f"DSL patch hook not found: {hook_path}")
            patches.append(cls(target, source_path, compiled_aml, hook_path))
        return tuple(patches)


@dataclass(slots=True)
class PatchContext:
    patch_path: Path
    compiled_aml: Path
    mode: PatchMode
    target: str
    manifest: AcpiManifest | None
    replacements: dict[str, Path] = field(default_factory=dict)

    def replace_table(
        self, target: str | None = None, aml_path: Path | None = None
    ) -> None:
        table_key = target or self.target
        if self.manifest is None:
            raise AcpiError("table replacement requires an ACPI manifest")
        if self.manifest.require(table_key).kind is not TableKind.AML:
            raise AcpiError(f"replacement target is not an AML table: {table_key}")
        replacement = aml_path or self.compiled_aml
        if not replacement.is_file():
            raise AcpiError(f"replacement AML does not exist: {replacement}")
        self.replacements[table_key] = replacement

    def log(self, message: str) -> None:
        print(f"[{self.patch_path.name}] {message}")


class AcpiPatch(ABC):
    """Contract implemented by the ``Patch`` class in each Python patch file."""

    @abstractmethod
    def apply(self, context: PatchContext) -> None:
        """Apply patch-specific behavior to a compiled DSL patch."""

    @classmethod
    def load(cls, path: Path) -> Self:
        spec = importlib.util.spec_from_file_location(
            f"acpi_patch_{abs(hash(path)):x}", path
        )
        if spec is None or spec.loader is None:
            raise AcpiError(f"cannot load ACPI patch: {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            patch_type = module.Patch
        except AttributeError as error:
            raise AcpiError(f"ACPI patch must define a Patch class: {path}") from error
        if not isinstance(patch_type, type) or not issubclass(patch_type, cls):
            raise AcpiError(f"Patch must inherit from {cls.__name__}: {path}")
        return patch_type()
