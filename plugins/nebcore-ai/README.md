# nebcore-ai

NebCore AI tools for Codex and Claude Code over MCP: issues, Kubernetes,
GitOps, cost, policy, and compliance. Each call is scoped to your account's
permissions.

## Requirements

- Codex CLI 0.149.0 or Claude Code
- `nebcli` 6.13.0 or newer on your PATH
- A one-time `nebcli login`

The plugin contains no credential. It starts `nebcli mcp` directly, and that
process reads your local nebcli login or `NEBCORE_PLATFORM_KEY`.

Before installing, run `nebcli --version` in the same shell that starts the
assistant. Upgrade with `nebcli update` when the version is older than 6.13.0.

## Install in Codex

Add the repository marketplace once:

```bash
codex plugin marketplace add nebinfra/claude-plugins --ref main
```

Start Codex, open `/plugins`, choose the NebInfra marketplace, and install
`nebcore-ai`. Start a new session after installation. Use `/mcp` to inspect the
authorized tool set.

## Upgrade in Codex

```bash
codex plugin marketplace upgrade nebinfra
codex plugin add nebcore-ai@nebinfra
```

Start a new session so Codex loads the updated manifest and MCP process.

## Remove from Codex

```bash
codex plugin remove nebcore-ai@nebinfra
```

Remove the marketplace only when no other NebInfra plugin uses it:

```bash
codex plugin marketplace remove nebinfra
```

## Install in Claude Code

```text
/plugin marketplace add nebinfra/claude-plugins
/plugin install nebcore-ai@nebinfra
```

## Authentication

Run `nebcli login` before starting a new assistant session. Agent environments
may instead provide `NEBCORE_PLATFORM_KEY`. Never add either credential to the
plugin manifest, marketplace, or MCP configuration.

## Troubleshooting

- If the assistant reports that `nebcli` cannot be started, install it from
  <https://docs.nebcore.ai/nebcli> and confirm `nebcli --version` works in the
  same shell.
- If `nebcli --version` is older than 6.13.0, run `nebcli update`, then start a
  new session. The current plugin does not preflight old binaries.
- Direct `nebcli mcp` without a configured login reports
  ``no platform URL configured: set PLATFORM_URL env or run `nebcli login```.
  Run `nebcli login`, then start a new session. Codex 0.149 currently summarizes
  the child stderr as a generic MCP handshake failure.
- For an unexpected tool count, confirm the plugin is enabled, open `/mcp`, and
  remember that the gateway filters tools to the scopes of the active login.

The host reports a missing executable before nebcli can run. This plugin does
not replace that host error with its own message.

Full tool reference: <https://docs.nebcore.ai/nebcli>
