# NebGuard

AI guardrails engine for Claude Code.

NebGuard hooks into Claude Code's tool-use lifecycle and enforces safety, quality, and operational checks before tool calls execute. It blocks destructive operations, flags risky commands, and produces an audit trail of every decision so review and compliance work can run after the fact.

## What it catches

The default rule set covers concerns common to any engineering organisation, including:

- Force-pushes and resets against protected branches
- Destructive shell commands (`rm -rf`, history rewrites, working-tree wipes)
- Unbounded `sleep` or `wait` invocations in long-running commands
- Common credential-shaped patterns in committed files
- AI co-author trailers in commit messages
- Bash invocations that bypass safer dedicated tools

Each rule has a documented severity, a bypass condition for legitimate exceptions, and a directive that explains how to proceed when the rule fires.

## Install

In any Claude Code session:

```
/plugin marketplace add nebinfra/claude-plugins
/plugin install nebguard@nebinfra
```

Complete the setup:

```
nebguard setup
```

## Configuration

NebGuard reads its hook configuration from `~/.claude/settings.json` (Claude Code's standard plugin settings file). Per-rule overrides and bypass declarations live alongside the standard Claude Code session settings — no additional config file is required for a working default.

## Issues

Open an issue at <https://github.com/nebinfra/claude-plugins/issues> with the plugin version and a minimum reproducer.
