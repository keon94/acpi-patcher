"""Command-line adapter for ACPI table preparation."""

import os
import sys
import traceback

from pathlib import Path

import typer

from .acpi_manifest import AcpiManifest
from .acpi_overrider import AcpiTableOverrider
from .errors import AcpiError


class ErrorHandlingTyper(typer.Typer):
    def __call__(self, *args, **kwargs):
        try:
            # Run the Typer application normally
            super().__call__(*args, **kwargs)
        except (AcpiError, OSError, ValueError) as e:
            typer.echo(f"error: {e}", err=True, color=True)
            _, _, tb = sys.exc_info()
            sys.stderr.writelines(self.__cleanup_stacktrace__(traceback.extract_tb(tb)))
            sys.exit(1)

    @staticmethod
    def __cleanup_stacktrace__(frames):
        current_file = os.path.abspath(__file__)
        start_index = 0
        for i, frame in enumerate(reversed(frames)):
            if os.path.abspath(frame.filename) == current_file:
                start_index = len(frames) - i - 1
                break

        # 4. Filter frames and print the clean stack trace
        filtered_frames = frames[start_index:]
        return traceback.format_list(filtered_frames)


app = ErrorHandlingTyper(help=__doc__, no_args_is_help=True)


@app.callback()
def main() -> None:
    pass


@app.command(name="prepare-dsl-overrides")
def prepare_acpi_table_overrides(
    manifest: Path = typer.Option(..., "--manifest"),
    output_dir: Path = typer.Option(..., "--output-dir"),
    output_manifest: Path = typer.Option(..., "--output-manifest"),
    replacement: list[str] = typer.Option([], "--replacement", metavar="TABLE_KEY=AML"),
    replacement_file: Path | None = typer.Option(None, "--replacement-file"),
) -> None:
    overrides = AcpiTableOverrider(AcpiManifest.read(manifest), output_dir)
    overrides.add_specs(replacement)
    if replacement_file is not None:
        overrides.add_file(replacement_file)
    overrides.prepare().write_manifest(output_manifest)


if __name__ == "__main__":
    app()
