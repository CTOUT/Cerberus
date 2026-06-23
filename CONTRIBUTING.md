# Contributing to Cerberus

Thank you for your interest in contributing.

## Reporting Issues

Open a GitHub issue and include:

- TrueNAS SCALE version
- CPU model and motherboard
- Relevant log lines from `$LOGFILE`
- Output of `sensors -j 2>/dev/null | jq .` (redact any sensitive values)

## Platform Support

Cerberus currently reads CPU temperature via the `k10temp` driver (AMD Opteron X3000-series APUs). Extending support to other platforms requires live `sensors -j` output from the target hardware.

If you are running Cerberus on hardware **other than the HPE ProLiant MicroServer Gen10**, please open an issue with the output of:

```bash
sensors -j 2>/dev/null | jq 'keys'
sensors -j 2>/dev/null | jq 'to_entries[] | {key: .key, fields: (.value | keys)}'
```

See [TODO.md](TODO.md) for a list of thermal drivers and platforms already identified.

## Code Style

Cerberus is a single Bash script. Follow the conventions already in use:

- `#!/usr/bin/env bash` shebang; `set -u` — no `set -e`
- `local` variables declared at the top of every function
- Scalar defaults: `${VAR:-default}` assignment
- Array defaults: `declare -p` guard pattern (see existing code)
- Section headers: `# ── Title ──` dash-ruler style
- Log all significant decisions and state transitions via `log()`
- Tag key log events with `[THERMAL]`, `[ACTION]`, `[RECOVERY]`, or `[EMERGENCY]` prefixes for Loki/LogQL filterability
- All app start/stop actions must go through `app_action()` to enforce the dry-run guard
- **Docker is read-only** — never call `docker stop`, `docker start`, or `docker compose` to change state; always use `midclt`
- Any new user-configurable file-write path must be added to `validate_writeable_path()` calls after the env file is sourced
- Any new per-app state written to `STATEFILE` or `TIERFILE` should also be reflected in `write_metrics()` where a Prometheus gauge makes sense

## Pull Requests

1. Fork the repository and create a focused feature branch.
2. Keep changes scoped — one concern per PR.
3. Add an entry under `[Unreleased]` in `CHANGELOG.md`.
4. Test on a live system where possible, or verify behaviour with dry-run mode (`touch /var/run/cerberus.dryrun`).
5. Open the PR against `main`.
