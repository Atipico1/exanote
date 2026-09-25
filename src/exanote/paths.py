"""Where Exanote keeps audio, models, the IPC token and settings on this Mac."""

from __future__ import annotations

import os
from pathlib import Path

DEFAULT_DATA = Path.home() / ".local/share/exanote"
# The folder used before the rename. The app moves it to DEFAULT_DATA on its first launch
# (see AppPaths.swift); until then the CLI and MCP server keep reading it in place.
LEGACY_DATA = Path.home() / ".local/share/open-notes"


def data_dir() -> Path:
    if override := os.getenv("EXANOTE_DATA"):
        return Path(override)
    if LEGACY_DATA.is_dir() and not DEFAULT_DATA.exists():
        return LEGACY_DATA
    return DEFAULT_DATA


DATA = data_dir()
