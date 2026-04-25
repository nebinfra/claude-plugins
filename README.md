# NebInfra Claude Code Marketplace

Plugins for the [Claude Code](https://docs.claude.com/claude-code) CLI, built and maintained by [NebInfra](https://nebinfra.com).

## Add this marketplace

In any Claude Code session, run:

```
/plugin marketplace add nebinfra/claude-plugins
```

Then browse and install plugins via the `/plugin` picker, or with:

```
/plugin install <plugin>@nebinfra
```

## Plugins

| Plugin | Description |
| --- | --- |
| [`nebguard`](plugins/nebguard/) | AI guardrails for Claude Code — safety checks before destructive tool calls, with an audit trail |

Each plugin's directory contains its own README with usage and configuration details.

## Reporting issues

For bug reports, feature requests, and questions, open an issue at <https://github.com/nebinfra/claude-plugins/issues>. Please include:

- Plugin name and version
- Claude Code version (`claude --version`)
- A minimum reproducer or the exact command that triggered the problem
