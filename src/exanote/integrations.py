"""One-click registration of the read-only Exanote MCP server in Claude Code and Codex.

Registration goes through each tool's own `mcp add` / `mcp remove` command so their config
formats stay theirs to manage; status is read from their config files because that is instant.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

from fastapi import APIRouter, HTTPException

NAME = "exanote"
LEGACY_NAMES = ("open-notes",)  # Registered by builds from before the rename.
router = APIRouter(prefix="/api/integrations")

CLIENTS = {
    "claude": {"name": "Claude Code", "binary": "claude", "install": "https://docs.anthropic.com/en/docs/claude-code"},
    "codex": {"name": "Codex", "binary": "codex", "install": "https://github.com/openai/codex"},
}
# A Mac app does not inherit the shell PATH, so look where these CLIs are usually installed.
SEARCH_DIRS = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin", "~/.bun/bin", "~/.volta/bin", "~/.claude/local"]


def server_command() -> list[str]:
    # -P keeps the client's working directory off sys.path, so a stray file there cannot shadow a module.
    return [sys.executable, "-P", "-m", "exanote.cli", "mcp"]


def server_env() -> dict[str, str]:
    data = os.getenv("EXANOTE_DATA")
    return {"EXANOTE_DATA": data} if data else {}


def _search_path() -> str:
    extra = [str(Path(item).expanduser()) for item in SEARCH_DIRS]
    return os.pathsep.join(extra + os.getenv("PATH", "").split(os.pathsep))


def _binary(client: str) -> str | None:
    name = CLIENTS[client]["binary"]
    found = shutil.which(name, path=_search_path())
    if found:
        return found
    try:  # Last resort: ask the user's login shell (nvm, asdf and similar set PATH there).
        shell = os.getenv("SHELL", "/bin/zsh")
        output = subprocess.run([shell, "-lc", f"command -v {name}"], capture_output=True, text=True, timeout=5).stdout.strip()
        return output if output and Path(output).exists() else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def _registered(client: str, name: str = NAME) -> dict | None:
    try:
        if client == "claude":
            return json.loads((Path.home() / ".claude.json").read_text()).get("mcpServers", {}).get(name)
        codex_home = Path(os.getenv("CODEX_HOME", Path.home() / ".codex"))
        return tomllib.loads((codex_home / "config.toml").read_text()).get("mcp_servers", {}).get(name)
    except (OSError, ValueError):
        return None


def _legacy(client: str) -> list[str]:
    return [name for name in LEGACY_NAMES if _registered(client, name)]


def _status(client: str) -> dict:
    binary = _binary(client)
    entry = _registered(client)
    command = server_command()
    if entry and [entry.get("command"), *entry.get("args", [])] == command and not _legacy(client):
        state = "connected"
    elif entry or _legacy(client):
        state = "outdated"  # Registered, but pointing at an older install or under the old name.
    elif binary:
        state = "disconnected"
    else:
        state = "not_installed"
    return {"id": client, "name": CLIENTS[client]["name"], "state": state, "install_url": CLIENTS[client]["install"]}


def _run(arguments: list[str]) -> subprocess.CompletedProcess:
    environment = {**os.environ, "PATH": _search_path()}
    return subprocess.run(arguments, capture_output=True, text=True, timeout=60, env=environment, cwd=Path.home())


def _remove(client: str, binary: str, name: str = NAME) -> subprocess.CompletedProcess:
    if client == "claude":
        return _run([binary, "mcp", "remove", "--scope", "user", name])
    return _run([binary, "mcp", "remove", name])


def _client(client: str) -> str:
    if client not in CLIENTS:
        raise HTTPException(404, "지원하지 않는 앱입니다.")
    binary = _binary(client)
    if not binary:
        raise HTTPException(409, f"{CLIENTS[client]['name']}이(가) 이 Mac에 설치되어 있지 않아요.")
    return binary


@router.get("")
def integrations():
    command = server_command()
    return {
        "clients": [_status(client) for client in CLIENTS],
        # For other MCP apps (Claude Desktop, Cursor and so on) that take a JSON config.
        "manual": {"mcpServers": {NAME: {"command": command[0], "args": command[1:], **({"env": server_env()} if server_env() else {})}}},
    }


@router.post("/{client}")
def connect(client: str):
    binary = _client(client)
    for name in _legacy(client):
        _remove(client, binary, name)
    if _registered(client):
        _remove(client, binary)  # Replaces an entry that points at an older install.
    environment = [item for key, value in server_env().items() for item in (("-e" if client == "claude" else "--env"), f"{key}={value}")]
    if client == "claude":
        result = _run([binary, "mcp", "add", "--scope", "user", *environment, NAME, "--", *server_command()])
    else:
        result = _run([binary, "mcp", "add", NAME, *environment, "--", *server_command()])
    status = _status(client)
    if result.returncode != 0 or status["state"] != "connected":
        detail = (result.stderr or result.stdout).strip().splitlines()[-1:] or ["알 수 없는 오류"]
        raise HTTPException(500, f"{CLIENTS[client]['name']}에 연결하지 못했어요: {detail[0]}")
    return status


@router.delete("/{client}")
def disconnect(client: str):
    binary = _client(client)
    for name in _legacy(client):
        _remove(client, binary, name)
    if _registered(client):
        result = _remove(client, binary)
        if _registered(client):
            detail = (result.stderr or result.stdout).strip().splitlines()[-1:] or ["알 수 없는 오류"]
            raise HTTPException(500, f"연결을 해제하지 못했어요: {detail[0]}")
    return _status(client)
