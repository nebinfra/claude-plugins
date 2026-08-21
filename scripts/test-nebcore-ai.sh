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
readme = (plugin / "README.md").read_text()

assert codex["name"] == plugin.name
assert codex["name"] == claude["name"]
assert codex["version"] == claude["version"] == "6.17.1"
assert codex["mcpServers"] == "./.mcp.json"
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

serialized = json.dumps({"plugin": codex, "marketplace": marketplace, "mcp": mcp}).lower()
for forbidden in ("access_token", "refresh_token", "api_key", "password", "bearer"):
    assert forbidden not in serialized
for required in (
    "Codex CLI 0.149.0",
    "nebcli` 6.13.0",
    "## Install in Codex",
    "## Upgrade in Codex",
    "## Remove from Codex",
    "## Authentication",
    "## Troubleshooting",
    "no platform URL configured: set PLATFORM_URL env or run `nebcli login`",
    "generic MCP handshake failure",
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

printf 'PASS: nebcore-ai Codex plugin contract\n'
