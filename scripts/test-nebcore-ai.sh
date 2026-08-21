#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

python3 - "$REPO_ROOT" "$TEST_ROOT" <<'PY'
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
test_root = pathlib.Path(sys.argv[2])
plugin = root / "plugins" / "nebcore-ai"
claude = json.loads((plugin / ".claude-plugin" / "plugin.json").read_text())
codex = json.loads((plugin / ".codex-plugin" / "plugin.json").read_text())
marketplace = json.loads((root / ".agents" / "plugins" / "marketplace.json").read_text())
mcp = json.loads((plugin / ".mcp.json").read_text())
hooks = json.loads((plugin / "codex" / "hooks.json").read_text())
readme = (plugin / "README.md").read_text()

assert codex["name"] == plugin.name
assert codex["name"] == claude["name"]
assert codex["version"] == claude["version"] == "6.17.1"
assert codex["mcpServers"] == "./.mcp.json"
assert codex["hooks"] == "./codex/hooks.json"
assert "hooks" not in claude
assert not (plugin / "hooks" / "hooks.json").exists()
assert marketplace == {
    "name": "nebinfra",
    "interface": {"displayName": "NebInfra"},
    "plugins": [{
        "name": "nebcore-ai",
        "source": {"source": "local", "path": "./plugins/nebcore-ai"},
        "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
        "category": "Productivity",
    }],
}
assert mcp == {"mcpServers": {"nebcore-ai": {
    "command": "nebcli",
    "args": ["mcp"],
}}}
assert not (plugin / "bin" / "nebcli").exists()

session_start = hooks["hooks"]["SessionStart"]
assert len(session_start) == 1
assert session_start[0]["matcher"] == "startup"
commands = session_start[0]["hooks"]
assert commands == [{
    "command": '/bin/bash "${PLUGIN_ROOT}/codex/session-start.sh"',
    "commandWindows": "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command . ([IO.Path]::Combine($env:PLUGIN_ROOT,'codex','session-start.ps1'))",
    "statusMessage": "Checking NebCore AI prerequisites",
    "timeout": 15,
    "type": "command",
}]
assert '"' not in commands[0]["commandWindows"]

serialized = json.dumps({"plugin": codex, "marketplace": marketplace, "mcp": mcp, "hooks": hooks}).lower()
for forbidden in ("access_token", "refresh_token", "api_key", "password", "bearer"):
    assert forbidden not in serialized
for required in (
    "Codex CLI 0.149.0",
    "nebcli` 6.13.0",
    "## Install in Codex",
    "## Upgrade in Codex",
    "## Remove from Codex",
    "## Authentication",
    "## Host diagnostics",
    "## Troubleshooting",
    "/plugins",
    "/hooks",
    "[features] hooks = false",
    "allow_managed_hooks_only = true",
    "does not hash or attest",
    "16,384 bytes",
    "12-second budget",
    "15-second outer timeout",
    "start a new session",
):
    assert required in readme

fake_bin = test_root / "bin"
fake_bin.mkdir()
fake = fake_bin / "nebcli"
fake.write_text(
    "#!/bin/sh\n"
    "printf '%s\\n' \"$*\" >\"$NEBCORE_TEST_CALLS\"\n"
    "printf '%s\\n' 'nebcore-test-mcp-invoked' >&2\n"
    "exit 17\n"
)
fake.chmod(0o755)
calls = test_root / "calls"
env = os.environ.copy()
env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
env["NEBCORE_TEST_CALLS"] = str(calls)
server = mcp["mcpServers"]["nebcore-ai"]
completed = subprocess.run(
    [server["command"], *server["args"]],
    env=env,
    capture_output=True,
    text=True,
    check=False,
)
assert completed.returncode == 17
assert calls.read_text() == "mcp\n"
assert completed.stderr == "nebcore-test-mcp-invoked\n"
PY

"$REPO_ROOT/scripts/test-nebcore-ai-posix.sh"

printf 'PASS: nebcore-ai Codex plugin contract\n'
