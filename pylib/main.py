"""Command-line adapter for ACPI table preparation and DSL patch hooks."""
import sys
import traceback
from collections.abc import Callable
from pathlib import Path

import typer

from .acpi_manifest import AcpiManifest
from .acpi_overrider import AcpiTableOverrider
from .errors import AcpiError
from .patch import AcpiPatch, DslPatch, PatchContext, PatchMode


app = typer.Typer(help=__doc__, no_args_is_help=True)


def _invoke(operation: Callable[[], None]) -> None:
    try:
        operation()
    except (AcpiError, OSError, ValueError) as error:
        typer.echo(f"error: {error}", err=True)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)


@app.command(name="prepare-overrides")
def prepare_acpi_table_overrides(
    manifest: Path = typer.Option(..., "--manifest"),
    output_dir: Path = typer.Option(..., "--output-dir"),
    output_manifest: Path = typer.Option(..., "--output-manifest"),
    replacement: list[str] = typer.Option([], "--replacement", metavar="TABLE_KEY=AML"),
    replacement_file: Path | None = typer.Option(None, "--replacement-file"),
    job_file: Path | None = typer.Option(None, "--job-file"),
) -> None:
    def prepare() -> None:
        overrides = AcpiTableOverrider(AcpiManifest.read(manifest), output_dir)
        overrides.add_specs(replacement)
        if replacement_file is not None:
            overrides.add_file(replacement_file)
        if job_file is not None:
            for patch in DslPatch.read_jobs(job_file, overrides.manifest):
                overrides.add_patch(patch)
        overrides.prepare().write_manifest(output_manifest)

    _invoke(prepare)


@app.command(name="apply-dsl-patch")
def apply_dsl_patch_command(
    hook: Path = typer.Option(..., "--hook"),
    patch: Path = typer.Option(..., "--patch"),
    aml: Path = typer.Option(..., "--aml"),
    mode: PatchMode = typer.Option(PatchMode.ADDITIVE, "--mode"),
    target: str = typer.Option("", "--target"),
    manifest: Path | None = typer.Option(None, "--manifest"),
) -> None:
    def apply() -> None:
        acpi_manifest = (
            AcpiManifest.read(manifest)
            if manifest is not None and manifest.is_file()
            else None
        )
        context = PatchContext(patch, aml, mode, target, acpi_manifest)
        AcpiPatch.load(hook).apply(context)
        if context.replacements:
            raise AcpiError(
                "additive DSL patches may mutate compiled AML but may not replace tables"
            )

    _invoke(apply)


if __name__ == "__main__":
    app()
