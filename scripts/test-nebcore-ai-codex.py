#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading


CODEX_VERSION = "codex-cli 0.149.0"
PLUGIN_ID = "nebcore-ai@nebinfra"
EXPECTED_TOOLS = {
    "aiserver.slackPostMessage",
    "approvals.get",
    "approvals.request",
    "approvals.withdraw",
    "docs.get",
    "docs.list",
    "docs.put",
    "self.inbox",
    "self.me",
    "self.peer",
    "self.peers",
    "self.usage",
}
DIAGNOSTICS = {
    "missing": "NebCore AI tools are unavailable because nebcli is not installed. Install nebcli, run nebcli login, then start a new Codex session.",
    "old": "NebCore AI tools are unavailable because nebcli 6.12.0 is older than the required 6.13.0. Upgrade nebcli, run nebcli login, then start a new Codex session.",
    "login": "NebCore AI tools are unavailable because nebcli is not logged in. Run nebcli login, then start a new Codex session.",
}


class AppServer:
    def __init__(self, codex: Path, environment: dict[str, str]):
        self.process = subprocess.Popen(
            [str(codex), "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            env=environment,
        )
        self.messages: queue.Queue[dict] = queue.Queue()
        self.stderr: list[str] = []
        self.next_id = 1
        self.stdout_reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self.stdout_reader.start()
        self.stderr_reader.start()
        result = self.request("initialize", {
            "clientInfo": {"name": "nebcore-ai-contract", "version": "1.0.0"},
            "capabilities": {"experimentalApi": True},
        })
        if "/0.149.0 " not in result["userAgent"]:
            raise AssertionError(f"app-server user agent {result['userAgent']!r}")
        self.initialize = result
        self.notify("initialized", {})

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        # REASON: the app-server process owns this stream, and close terminates it within 10 seconds.
        for line in self.process.stdout:
            self.messages.put(json.loads(line))
        self.messages.put({"_eof": True})

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        # REASON: the app-server process owns this stream, and close terminates it within 10 seconds.
        self.stderr.extend(self.process.stderr)

    def _send(self, message: dict) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def notify(self, method: str, params: dict) -> None:
        self._send({"method": method, "params": params})

    def request(self, method: str, params: dict) -> dict:
        request_id = self.next_id
        self.next_id += 1
        self._send({"id": request_id, "method": method, "params": params})
        deferred = []
        # REASON: queue.get bounds each protocol wait at 30 seconds and reports process stderr on EOF.
        while True:
            message = self.messages.get(timeout=30)
            if message.get("_eof"):
                raise RuntimeError("Codex app-server exited: " + "".join(self.stderr))
            if message.get("id") == request_id:
                for item in deferred:
                    self.messages.put(item)
                if "error" in message:
                    raise RuntimeError(f"{method} failed: {message['error']}")
                return message["result"]
            deferred.append(message)

    def receive(self, predicate) -> dict:
        deferred = []
        # REASON: queue.get bounds each protocol wait at 30 seconds and reports process stderr on EOF.
        while True:
            message = self.messages.get(timeout=30)
            if message.get("_eof"):
                raise RuntimeError("Codex app-server exited: " + "".join(self.stderr))
            if predicate(message):
                for item in deferred:
                    self.messages.put(item)
                return message
            deferred.append(message)

    def close(self) -> None:
        self.process.terminate()
        self.process.wait(timeout=10)
        self.stdout_reader.join(timeout=10)
        self.stderr_reader.join(timeout=10)


def run(command: list[str], environment: dict[str, str], cwd: Path | None = None) -> dict:
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"command failed {command!r}: {completed.stdout}{completed.stderr}"
        )
    if not completed.stdout.strip():
        return {}
    return json.loads(completed.stdout)


def git(command: list[str], cwd: Path) -> None:
    completed = subprocess.run(
        ["git", *command], cwd=cwd, text=True, capture_output=True, check=False
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stdout + completed.stderr)


def plugin_hook(server: AppServer, project: Path) -> dict:
    response = server.request("hooks/list", {"cwds": [str(project)]})
    entries = response["data"]
    assert len(entries) == 1, entries
    matches = [
        hook for hook in entries[0]["hooks"]
        if hook["eventName"] == "sessionStart"
        and hook["source"] == "plugin"
        and hook["pluginId"] == PLUGIN_ID
    ]
    assert len(matches) == 1, entries
    return matches[0]


def write_hook_state(server: AppServer, hook: dict, state: dict) -> None:
    server.request("config/batchWrite", {
        "edits": [{
            "keyPath": "hooks.state",
            "value": {hook["key"]: state},
            "mergeStrategy": "upsert",
        }],
        "filePath": None,
        "expectedVersion": None,
        "reloadUserConfig": True,
    })


def trust_all_hooks(server: AppServer, project: Path) -> None:
    response = server.request("hooks/list", {"cwds": [str(project)]})
    hooks = response["data"][0]["hooks"]
    server.request("config/batchWrite", {
        "edits": [{
            "keyPath": "hooks.state",
            "value": {
                hook["key"]: {"trusted_hash": hook["currentHash"]}
                for hook in hooks
            },
            "mergeStrategy": "upsert",
        }],
        "filePath": None,
        "expectedVersion": None,
        "reloadUserConfig": True,
    })


def start_session(
    codex: Path,
    environment: dict[str, str],
    project: Path,
    expected_context: str | None,
) -> dict:
    server = AppServer(codex, environment)
    try:
        thread = server.request("thread/start", {
            "cwd": str(project),
            "ephemeral": True,
        })["thread"]
        server.request("turn/start", {
            "threadId": thread["id"],
            "input": [{"type": "text", "text": "Return ok."}],
        })
        plugin_runs = []
        terminal_status = None
        # REASON: each receive is bounded at 30 seconds. turn/completed is the
        # structured terminal signal even when policy suppresses every hook.
        while True:
            message = server.receive(
                lambda item: item.get("method") in {"hook/completed", "turn/completed"}
            )
            if message["method"] == "turn/completed":
                if message["params"]["threadId"] != thread["id"]:
                    continue
                terminal_status = message["params"]["turn"]["status"]
                break
            run_summary = message["params"]["run"]
            if run_summary["eventName"] == "sessionStart" and run_summary["source"] == "plugin":
                plugin_runs.append(run_summary)
                if expected_context is not None:
                    break
        if expected_context is None:
            assert plugin_runs == [], plugin_runs
            assert terminal_status in {"completed", "failed"}, terminal_status
            return {
                "platformFamily": server.initialize["platformFamily"],
                "platformOs": server.initialize["platformOs"],
                "userAgent": server.initialize["userAgent"],
                "expectedContext": None,
                "pluginRunCount": 0,
                "entries": [],
                "observationMethod": "turn/completed",
                "turnStatus": terminal_status,
            }
        assert len(plugin_runs) == 1, plugin_runs
        contexts = [
            entry["text"] for entry in plugin_runs[0]["entries"]
            if entry["kind"] == "context"
        ]
        assert contexts == [expected_context], contexts
        serialized = json.dumps(plugin_runs)
        assert "secret-version-marker" not in serialized
        assert "secret-bridge-marker" not in serialized
        return {
            "platformFamily": server.initialize["platformFamily"],
            "platformOs": server.initialize["platformOs"],
            "userAgent": server.initialize["userAgent"],
            "expectedContext": expected_context,
            "pluginRunCount": 1,
            "entries": plugin_runs[0]["entries"],
        }
    finally:
        server.close()


def configure_barrier(codex_home: Path) -> None:
    config = codex_home / "config.toml"
    config.write_text(
        """[features]
hooks = true

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "/bin/sh -c true"
commandWindows = "cmd.exe /d /c exit 0"
timeout = 5
""",
        encoding="utf-8",
    )


def observe_install(
    codex: Path,
    project: Path,
    expected_state: str,
    expected_context: str | None,
) -> dict:
    environment = os.environ.copy()
    server = AppServer(codex, environment)
    try:
        hook = plugin_hook(server, project)
        expected = {
            "untrusted": (True, "untrusted"),
            "trusted-enabled": (True, "trusted"),
            "disabled": (False, "trusted"),
        }[expected_state]
        assert (hook["enabled"], hook["trustStatus"]) == expected, hook
        observed_hook = {
            "currentHash": hook["currentHash"],
            "enabled": hook["enabled"],
            "eventName": hook["eventName"],
            "pluginId": hook["pluginId"],
            "source": hook["source"],
            "timeoutSec": hook["timeoutSec"],
            "trustStatus": hook["trustStatus"],
        }
    finally:
        server.close()
    evidence = {
        "hook": observed_hook,
        "state": expected_state,
    }
    if expected_context is not None:
        session_environment = environment.copy()
        session_environment["PATH"] = os.pathsep.join(
            item for item in environment["PATH"].split(os.pathsep)
            if not (Path(item) / ("nebcli.exe" if os.name == "nt" else "nebcli")).exists()
        )
        context = None if expected_context == "none" else DIAGNOSTICS[expected_context]
        evidence["session"] = start_session(
            codex,
            session_environment,
            project,
            context,
        )
    return evidence


def commit_fixture(repo: Path, message: str, allow_empty: bool = False) -> None:
    git(["add", "--", ".agents", ".claude-plugin", "plugins", "scripts"], repo)
    command = [
        "-c", "user.name=NebInfra Test",
        "-c", "user.email=test@nebinfra.com",
        "commit",
    ]
    if allow_empty:
        command.append("--allow-empty")
    git([*command, "-m", message], repo)


def update_fixture_version(repo: Path, version: str) -> None:
    for relative in (
        "plugins/nebcore-ai/.codex-plugin/plugin.json",
        "plugins/nebcore-ai/.claude-plugin/plugin.json",
    ):
        path = repo / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["version"] = version
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex", required=True, type=Path)
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("--marketplace", type=Path)
    parser.add_argument("--fixture-bin", type=Path)
    parser.add_argument("--authenticated-path", type=str)
    parser.add_argument("--remote-ref", type=str)
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--expect-managed-only", action="store_true")
    parser.add_argument(
        "--observe-hook-state",
        choices=("untrusted", "trusted-enabled", "disabled"),
    )
    parser.add_argument(
        "--observe-session",
        choices=("missing", "none"),
    )
    parser.add_argument("--evidence-file", type=Path)
    arguments = parser.parse_args()
    version = subprocess.run(
        [str(arguments.codex), "--version"],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()
    assert version == CODEX_VERSION, version

    if arguments.observe_hook_state:
        assert arguments.evidence_file is not None
        evidence = observe_install(
            arguments.codex,
            arguments.project,
            arguments.observe_hook_state,
            arguments.observe_session,
        )
        evidence["codexVersion"] = version
        arguments.evidence_file.parent.mkdir(parents=True, exist_ok=True)
        arguments.evidence_file.write_text(
            json.dumps(evidence, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"PASS: observed {arguments.observe_hook_state} Codex hook state")
        return

    assert arguments.marketplace is not None
    assert arguments.fixture_bin is not None

    with tempfile.TemporaryDirectory(prefix="nebcore-codex-contract-") as root_text:
        root = Path(root_text)
        codex_home = root / "codex home"
        user_home = root / "user home"
        fixture_repo = root / "marketplace source"
        codex_home.mkdir()
        user_home.mkdir()
        shutil.copytree(
            arguments.marketplace,
            fixture_repo,
            ignore=shutil.ignore_patterns(".git"),
        )
        git(["init", "-b", "main"], fixture_repo)
        commit_fixture(fixture_repo, "fixture: initial marketplace")
        configure_barrier(codex_home)

        base_environment = os.environ.copy()
        base_environment["CODEX_HOME"] = str(codex_home)
        base_environment["HOME"] = str(user_home)
        base_environment["USERPROFILE"] = str(user_home)
        add = run(
            [str(arguments.codex), "plugin", "marketplace", "add", str(fixture_repo), "--json"],
            base_environment,
        )
        assert add["marketplaceName"] == "nebinfra", add
        available = run(
            [str(arguments.codex), "plugin", "list", "--available", "--json"],
            base_environment,
        )
        assert "nebcore-ai" in json.dumps(available), available
        run(
            [str(arguments.codex), "plugin", "add", PLUGIN_ID, "--json"],
            base_environment,
        )

        if arguments.expect_managed_only:
            missing_environment = base_environment.copy()
            missing_environment["PATH"] = os.pathsep.join(
                item for item in os.environ["PATH"].split(os.pathsep)
                if not (Path(item) / ("nebcli.exe" if os.name == "nt" else "nebcli")).exists()
            )
            session = start_session(
                arguments.codex,
                missing_environment,
                arguments.project,
                None,
            )
            session["mode"] = "managed-only"
            server = AppServer(arguments.codex, base_environment)
            try:
                hooks = server.request("hooks/list", {"cwds": [str(arguments.project)]})
                plugin_hooks = [
                    hook for entry in hooks["data"] for hook in entry["hooks"]
                    if hook.get("pluginId") == PLUGIN_ID
                ]
                assert plugin_hooks == [], plugin_hooks
                evidence = {
                    "codexVersion": version,
                    "managedOnly": True,
                    "pluginHookCount": 0,
                    "session": session,
                }
            finally:
                server.close()
            if arguments.evidence_dir:
                arguments.evidence_dir.mkdir(parents=True, exist_ok=True)
                (arguments.evidence_dir / "managed-only.json").write_text(
                    json.dumps(evidence, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            print("PASS: managed policy suppresses the non-managed plugin hook")
            return

        server = AppServer(arguments.codex, base_environment)
        try:
            hook = plugin_hook(server, arguments.project)
            assert hook["enabled"] is True, hook
            assert hook["trustStatus"] == "untrusted", hook
            assert hook["timeoutSec"] == 15, hook
            trust_all_hooks(server, arguments.project)
            trusted = plugin_hook(server, arguments.project)
            assert trusted["trustStatus"] == "trusted", trusted
            original_hash = trusted["currentHash"]
        finally:
            server.close()

        evidence = {"codexVersion": version, "sessions": [], "tools": []}
        for mode, expected in DIAGNOSTICS.items():
            environment = base_environment.copy()
            environment["NEBCORE_FIXTURE_MODE"] = mode
            if mode == "missing":
                environment["PATH"] = os.pathsep.join(
                    item for item in os.environ["PATH"].split(os.pathsep)
                    if not (Path(item) / ("nebcli.exe" if os.name == "nt" else "nebcli")).exists()
                )
            else:
                environment["PATH"] = str(arguments.fixture_bin) + os.pathsep + os.environ["PATH"]
            session = start_session(arguments.codex, environment, arguments.project, expected)
            session["mode"] = mode
            evidence["sessions"].append(session)

        server = AppServer(arguments.codex, base_environment)
        try:
            hook = plugin_hook(server, arguments.project)
            write_hook_state(server, hook, {"enabled": False})
            disabled = plugin_hook(server, arguments.project)
            assert disabled["enabled"] is False, disabled
            assert disabled["trustStatus"] == "trusted", disabled
        finally:
            server.close()
        missing_environment = base_environment.copy()
        missing_environment["PATH"] = os.pathsep.join(
            item for item in os.environ["PATH"].split(os.pathsep)
            if not (Path(item) / ("nebcli.exe" if os.name == "nt" else "nebcli")).exists()
        )
        disabled_session = start_session(arguments.codex, missing_environment, arguments.project, None)
        disabled_session["mode"] = "individual-disabled"
        evidence["sessions"].append(disabled_session)

        server = AppServer(arguments.codex, base_environment)
        try:
            disabled = plugin_hook(server, arguments.project)
            assert disabled["enabled"] is False, disabled
            write_hook_state(server, disabled, {"enabled": True})
            enabled = plugin_hook(server, arguments.project)
            assert enabled["enabled"] is True, enabled
            assert enabled["trustStatus"] == "trusted", enabled
        finally:
            server.close()
        enabled_session = start_session(arguments.codex, missing_environment, arguments.project, DIAGNOSTICS["missing"])
        enabled_session["mode"] = "individual-re-enabled"
        evidence["sessions"].append(enabled_session)

        config_path = codex_home / "config.toml"
        enabled_config = config_path.read_text(encoding="utf-8")
        config_path.write_text(
            enabled_config.replace("hooks = true", "hooks = false", 1),
            encoding="utf-8",
        )
        server = AppServer(arguments.codex, base_environment)
        try:
            suppressed = server.request("hooks/list", {"cwds": [str(arguments.project)]})
            plugin_hooks = [
                hook for entry in suppressed["data"] for hook in entry["hooks"]
                if hook.get("pluginId") == PLUGIN_ID
            ]
            assert plugin_hooks == [], plugin_hooks
        finally:
            server.close()
        suppressed_session = start_session(
            arguments.codex,
            missing_environment,
            arguments.project,
            None,
        )
        suppressed_session["mode"] = "user-hooks-disabled"
        evidence["sessions"].append(suppressed_session)
        config_path.write_text(enabled_config, encoding="utf-8")

        commit_fixture(fixture_repo, "fixture: exact-version upgrade", allow_empty=True)
        run([str(arguments.codex), "plugin", "add", PLUGIN_ID, "--json"], base_environment)

        hooks_path = fixture_repo / "plugins/nebcore-ai/codex/hooks.json"
        hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
        command = hooks["hooks"]["SessionStart"][0]["hooks"][0]
        if os.name == "nt":
            command["commandWindows"] = command["commandWindows"].replace(
                "-Command ", "-Command $env:NEBCORE_COMMAND_FIXTURE=1;"
            )
        else:
            command["command"] = "NEBCORE_COMMAND_FIXTURE=1 " + command["command"]
        hooks_path.write_text(json.dumps(hooks, indent=2) + "\n", encoding="utf-8")
        update_fixture_version(fixture_repo, "6.17.2")
        commit_fixture(fixture_repo, "fixture: changed command")
        run([str(arguments.codex), "plugin", "add", PLUGIN_ID, "--json"], base_environment)
        server = AppServer(arguments.codex, base_environment)
        try:
            modified = plugin_hook(server, arguments.project)
            assert modified["currentHash"] != original_hash, modified
            assert modified["trustStatus"] == "modified", modified
        finally:
            server.close()

        shutil.copy2(
            arguments.marketplace / "plugins/nebcore-ai/codex/hooks.json",
            hooks_path,
        )
        update_fixture_version(fixture_repo, "6.17.3")
        script_name = "session-start.ps1" if os.name == "nt" else "session-start.sh"
        source_script = fixture_repo / "plugins/nebcore-ai/codex" / script_name
        with source_script.open("a", encoding="utf-8") as handle:
            handle.write("\n# package integrity fixture\n")
        script_digest = hashlib.sha256(source_script.read_bytes()).hexdigest()
        commit_fixture(fixture_repo, "fixture: script-only package update")
        install = run([str(arguments.codex), "plugin", "add", PLUGIN_ID, "--json"], base_environment)
        installed_root = Path(install["installedPath"])
        assert hashlib.sha256((installed_root / "codex" / script_name).read_bytes()).hexdigest() == script_digest
        server = AppServer(arguments.codex, base_environment)
        try:
            script_only = plugin_hook(server, arguments.project)
            assert script_only["currentHash"] == original_hash, script_only
            assert script_only["trustStatus"] == "trusted", script_only
        finally:
            server.close()

        if arguments.authenticated_path:
            authenticated_environment = base_environment.copy()
            authenticated_environment["PATH"] = arguments.authenticated_path
            server = AppServer(arguments.codex, authenticated_environment)
            try:
                thread = server.request("thread/start", {
                    "cwd": str(arguments.project),
                    "ephemeral": True,
                })["thread"]
                status = server.request("mcpServerStatus/list", {
                    "cursor": None,
                    "limit": 25,
                    "detail": "toolsAndAuthOnly",
                    "threadId": thread["id"],
                })
                nebcore = [item for item in status["data"] if item["name"] == "nebcore-ai"]
                assert len(nebcore) == 1, status
                assert set(nebcore[0]["tools"]) == EXPECTED_TOOLS, nebcore[0]["tools"]
                assert status["nextCursor"] is None, status
                evidence["tools"] = sorted(nebcore[0]["tools"])
            finally:
                server.close()

        run([str(arguments.codex), "plugin", "remove", PLUGIN_ID, "--json"], base_environment)
        server = AppServer(arguments.codex, base_environment)
        try:
            hooks = server.request("hooks/list", {"cwds": [str(arguments.project)]})
            assert all(
                hook.get("pluginId") != PLUGIN_ID
                for entry in hooks["data"] for hook in entry["hooks"]
            ), hooks
            status = server.request("mcpServerStatus/list", {
                "cursor": None,
                "limit": 25,
                "detail": "toolsAndAuthOnly",
                "threadId": None,
            })
            assert all(item["name"] != "nebcore-ai" for item in status["data"]), status
        finally:
            server.close()
        run(
            [str(arguments.codex), "plugin", "marketplace", "remove", "nebinfra", "--json"],
            base_environment,
        )

        if arguments.remote_ref:
            remote_home = root / "remote codex home"
            remote_user_home = root / "remote user home"
            remote_home.mkdir()
            remote_user_home.mkdir()
            remote_environment = os.environ.copy()
            remote_environment["CODEX_HOME"] = str(remote_home)
            remote_environment["HOME"] = str(remote_user_home)
            remote_environment["USERPROFILE"] = str(remote_user_home)
            remote_add = run([
                str(arguments.codex), "plugin", "marketplace", "add",
                "nebinfra/claude-plugins", "--ref", arguments.remote_ref, "--json",
            ], remote_environment)
            assert remote_add["marketplaceName"] == "nebinfra", remote_add
            run([str(arguments.codex), "plugin", "add", PLUGIN_ID, "--json"], remote_environment)
            upgraded = run([
                str(arguments.codex), "plugin", "marketplace", "upgrade", "nebinfra", "--json",
            ], remote_environment)
            assert upgraded["selectedMarketplaces"] == ["nebinfra"], upgraded
            assert upgraded["errors"] == [], upgraded
            run([str(arguments.codex), "plugin", "add", PLUGIN_ID, "--json"], remote_environment)

        if arguments.evidence_dir:
            arguments.evidence_dir.mkdir(parents=True, exist_ok=True)
            (arguments.evidence_dir / "summary.json").write_text(
                json.dumps(evidence, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

    print("PASS: nebcore-ai Codex 0.149.0 lifecycle contract")


if __name__ == "__main__":
    main()
