# Security Policy

## Reporting a vulnerability

Report security issues privately through GitHub: open the [Security tab](https://github.com/nebinfra/claude-plugins/security) of this repository and choose **Report a vulnerability**, or email <security@nebinfra.com>.

Please do not open public issues or pull requests for security reports.

We aim to acknowledge new reports within 3 business days and to keep you informed while we investigate. We follow coordinated disclosure: we ask that you give us a reasonable window to ship a fix before publishing details. There is no paid bounty program at this time; we are happy to credit reporters in the release notes on request.

## Scope

This repository is the NebInfra plugin marketplace for the Claude Code CLI. Everything it distributes runs on developer machines, so it is held to the same bar as the binaries themselves. In scope here:

- Plugin manifests, hook scripts, wrapper scripts, and MCP server configuration shipped under `plugins/`.
- Anything that could make a plugin execute unexpected code, escalate what a hook can do, weaken a policy verdict, or exfiltrate data from the host it runs on.
- Install instructions in this repository that could lead users into an unsafe state.

Vulnerabilities in the underlying binaries that the plugins invoke belong in the product's release repository: [nebinfra/nebguard-dist](https://github.com/nebinfra/nebguard-dist) or [nebinfra/nebcli-dist](https://github.com/nebinfra/nebcli-dist). Issues with the published verification keys belong in [nebinfra/trust](https://github.com/nebinfra/trust).

## How the plugins stay trustworthy

Plugins in this marketplace are thin wrappers: they contain hooks and configuration, not vendored binaries. They invoke the separately installed NebGuard and NebCLI binaries, which are cosign-signed and verifiable against the public keys in [nebinfra/trust](https://github.com/nebinfra/trust). A plugin version is designed to match its binary version and warns when the installed binary is older than the plugin expects.

## Supported versions

Only the latest published version of each plugin is supported. Security fixes ship forward in new plugin versions; there are no backported fixes.
