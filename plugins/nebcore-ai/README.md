# nebcore-ai

NebCore AI tools for Codex and Claude Code over MCP: issues, Kubernetes,
GitOps, cost, policy, and compliance. Each call is scoped to your account's
permissions.

## Requirements

- Codex CLI 0.149.0 or Claude Code
- `nebcli` 6.13.0 or newer on your PATH
- A one-time `nebcli login`

The plugin contains no credential. Its MCP configuration starts `nebcli mcp`
directly, and that process reads your local nebcli login or
`NEBCORE_PLATFORM_KEY`.

Before installing, run `nebcli --version` in the same shell that starts the
assistant. Upgrade with `nebcli update` when the version is older than 6.13.0.

## Install in Codex

Add the repository marketplace once:

```bash
codex plugin marketplace add nebinfra/claude-plugins --ref main
```

Start Codex, open `/plugins`, choose the NebInfra marketplace, and install
`nebcore-ai`. Open `/hooks`, select the `nebcore-ai` plugin `SessionStart`
entry, and review and trust its current command definition. Enable that exact
entry if it is disabled. Start a new session after those conditions hold. Use
`/mcp` to inspect the authorized tool set.

`/plugins` is the supported user setup flow. Do not hand edit the Codex MCP
configuration, `config.toml`, or the installed plugin cache.

## Upgrade in Codex

```bash
codex plugin marketplace upgrade nebinfra
codex plugin add nebcore-ai@nebinfra
```

Open `/hooks` after an upgrade. Review and trust the current command definition
if it is marked new, changed, or review required, enable it if disabled, then
start a new session. Codex trust covers the normalized hook command definition.
It does not hash or attest to the referenced Bash, PowerShell, or embedded C#
source. Those files are protected by the versioned marketplace package and its
reviewed updates.

## Remove from Codex

```bash
codex plugin remove nebcore-ai@nebinfra
```

Remove the marketplace only when no other NebInfra plugin uses it:

```bash
codex plugin marketplace remove nebinfra
```

Start a new session and confirm that neither the `nebcore-ai` hook nor its MCP
server is present.

## Install in Claude Code

```text
/plugin marketplace add nebinfra/claude-plugins
/plugin install nebcore-ai@nebinfra
```

The prerequisite hook is scoped to the non-default path in the Codex manifest.
Claude Code continues to launch the same direct MCP bridge without this hook.

## Authentication

Run `nebcli login` before starting a new assistant session. Agent environments
may instead provide `NEBCORE_PLATFORM_KEY`. Never add either credential to the
plugin manifest, marketplace, MCP configuration, or hook.

## Host diagnostics

The trusted and enabled Codex `SessionStart` hook reports these fixed messages:

- Missing binary: `NebCore AI tools are unavailable because nebcli is not installed. Install nebcli, run nebcli login, then start a new Codex session.`
- Version below 6.13.0: `NebCore AI tools are unavailable because nebcli VERSION is older than the required 6.13.0. Upgrade nebcli, run nebcli login, then start a new Codex session.`
- Missing login: `NebCore AI tools are unavailable because nebcli is not logged in. Run nebcli login, then start a new Codex session.`
- Unsafe version check: `NebCore AI tools are unavailable because the installed nebcli version could not be verified. Upgrade nebcli to 6.13.0 or newer, run nebcli login, then start a new Codex session.`
- Unsafe bridge check: `NebCore AI tools are unavailable because the nebcli prerequisite check did not complete safely. Verify nebcli 6.13.0 or newer, run nebcli login, then start a new Codex session.`

Each hook invocation resolves one executable, invokes `nebcli --version` once,
and runs at most one closed-stdin `nebcli mcp` prerequisite probe. Each child
has a five-second deadline. Standard output and standard error each retain at
most 16,384 bytes. The script reserves two seconds for cleanup inside a
12-second budget, while Codex enforces a 15-second outer timeout. A deadline or
overflow terminates the complete child process tree. The hook never retries,
downloads a binary, scans directories, sends an MCP request, forwards child
output, or reads a credential file.

## Troubleshooting

| `/plugins` and `/hooks` state | Meaning | Recovery |
| --- | --- | --- |
| Plugin absent | The marketplace plugin is not installed | Install it through `/plugins`, inspect the hook in `/hooks`, then start a new session |
| Hook present and review required | The normalized command definition is not trusted | Review and trust the current definition in `/hooks`, then start a new session |
| Hook present and disabled | The plugin remains installed but its diagnostic does not run | Enable that exact `nebcore-ai` `SessionStart` entry in `/hooks`, review it only if required, then start a new session |
| Hook present, trusted, and enabled | The diagnostic is ready for the next session | Start a new session |
| Hook absent after restart while the plugin is enabled | Hooks are suppressed by user or managed configuration | Apply the matching recovery below |

If your user `config.toml` sets `[features] hooks = false`, remove that override
or set it to `true`, restart Codex, open `/hooks`, restore the exact hook's
enablement and current-definition trust if needed, then start a new session.
Reinstalling the plugin is not the recovery for individual disablement.

If managed `requirements.toml` disables hooks or sets
`allow_managed_hooks_only = true`, a user cannot override it. An administrator
must permit hooks and non-managed plugin hooks. After policy reload, open
`/hooks`, restore the exact hook state, and start a new session. Do not copy the
hook into a managed directory or edit MCP configuration. If policy remains
restrictive, the three host diagnostics are unsupported by policy. Run
`nebcli --version`, upgrade to 6.13.0 or newer, run `nebcli login`, and start a
new session without claiming that the plugin diagnostic ran.

For an unexpected tool count, confirm the plugin is enabled, open `/mcp`, and
remember that the gateway filters tools to the scopes of the active login.

Full tool reference: <https://docs.nebcore.ai/nebcli>
