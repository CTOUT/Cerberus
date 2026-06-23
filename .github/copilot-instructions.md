# GitHub Copilot Instructions

## Project Overview

Cerberus is a CPU thermal watchdog for **TrueNAS SCALE** (AMD Opteron X3000-series APUs, k10temp driver). It runs every minute via cron and progressively stops Docker/TrueNAS apps during thermal events, then restarts them in dependency order once the system cools. All scripts are **Bash**.

### Scripts

| Script                | Status  | Config file            |
| --------------------- | ------- | ---------------------- |
| `Scripts/cerberus.sh` | Current | `Scripts/cerberus.env` |

`cerberus.sh` is the active script. When making changes, apply them here.

## Architecture

### Thermal state machine (one cron invocation = one state transition)

```
Normal → [TEMP ≥ STOP_THRESHOLD]  → First breach: build QUEUEFILE, stop busiest app, write LOCKFILE
Active → [TEMP > last_stop_temp]  → Progressive shed: pop next app from QUEUEFILE, update LOCKFILE
Active → [TEMP ≤ last_stop_temp]  → Holding: log status, exit
Active → [TEMP ≤ COOL_THRESHOLD]  → Recovery: restart all stopped apps in tier order, clear state files
Any    → [TEMP ≥ SHUTDOWN_THRESHOLD] → Emergency: midclt system.shutdown, exit
```

### State files (all in `/var/run/`, never user-configurable)

- `cerberus.lock` — temperature (°C) at the last stop action; presence signals active thermal event
- `cerberus.queue` — newline-delimited ordered list of apps still to stop
- `cerberus.apps` — newline-delimited list of apps stopped so far (for recovery)
- `cerberus.tiers` — `app tier_number` pairs captured at first breach while containers are running (used during recovery when containers are gone)
- `cerberus.init` — sentinel; absent on first post-boot run to trigger threshold logging
- `cerberus.dryrun` — touchfile; enables dry-run mode (no apps started or stopped)
- `cerberus.run` — flock file; prevents overlapping cron invocations

### App state management principle

**All app start/stop actions go through `midclt`** (`midclt call app.stop` / `midclt call app.start`) to keep TrueNAS UI state, health checks, and its internal daemon in sync. **Docker commands are read-only** (`docker stats`, `docker ps`) — never use `docker stop`, `docker start`, or `docker compose` to change app state.

### Container-to-app matching (in `sum_app_cpu` / `app_has_override`)

Matching is performed in priority order:

1. `com.docker.compose.project == app` (custom apps)
2. `com.docker.compose.project == "ix-<app>"` (TrueNAS catalog apps)
3. Container name exactly equals app name
4. Container name starts with `<app>-`
5. Container name starts with `ix-<app>-`

### Shutdown queue ordering

- Built once per thermal event from a `docker stats` snapshot
- Apps sorted by summed `CPUPerc` descending
- Apps in `PIN_LAST` are always emitted last, in array order, regardless of CPU% (intended for GPU-intensive apps whose load shows in temperature via k10temp but not in cgroup CPU accounting)
- Apps in `NEVER_STOP` and containers with `cerberus.override` label are excluded entirely

### Recovery ordering (cerberus.sh)

1. `cerberus.tier` Docker label values captured in `TIERFILE` at first breach — takes priority
2. `STARTUP_TIERS` array (env-configurable) — fallback for unlabelled apps
3. Tier `9999` catch-all for anything not in either list

## Key Conventions

### Bash style

- `#!/usr/bin/env bash` shebang; `set -u` (unset variable = error). **No `set -e`** — failures in helpers are handled explicitly.
- Local variables declared with `local` at the top of every function.
- Array defaults use the `declare -p` guard pattern so env-file arrays are not overwritten:
  ```bash
  if ! declare -p ARRAY_NAME &>/dev/null; then
    ARRAY_NAME=(...)
  fi
  ```
- Scalar defaults use `${VAR:-default}` assignment.
- Section headers use the `# ── Title ──` dash-ruler style.

### Configuration and env files

- The `.env` companion file is sourced if present; the script is fully functional without it (all built-in defaults apply).
- `.env` files are **gitignored**. `EXAMPLE-cerberus.env` is the committed template — keep it in sync with `cerberus.env` defaults.
- After editing the env file, delete `/var/run/cerberus.init` to re-log thresholds on the next cycle.

### JSON / NDJSON handling

- `sensors -j | jq` for temperature (k10temp driver, `temp1_input` field).
- `docker stats --format` and `docker ps --format` emit **NDJSON** (one JSON object per line). All merging and querying uses `jq -rn` with `split("\n")` pipeline. Do not assume valid JSON across the full output.
- `jq -rn --arg n "$app" '$n'` is used to safely JSON-encode app names before passing them to `midclt`.

### Logging

- Single `log()` helper: prefixes `YYYY-MM-DD HH:MM:SS  message` and appends to `$LOGFILE`.
- Log rotation via `rotate_log()` at the start of every cycle: awk date-string comparison (`$1 >= cutoff`), writes to `.tmp` first to avoid truncation on failure, enforces `chmod 640`.
- Log directory falls back to `/tmp` if the pool is not yet mounted.

### Dry-run mode

Check `[[ -f "$DRYRUNFILE" ]]` before any destructive action. `touch /var/run/cerberus.dryrun` enables it; remove the file to disable. No code path should start or stop apps without passing through `app_action()`.

### Cron deployment

```
* * * * *  root  /mnt/<pool>/apps/scripts/cerberus.sh
```

Run-lock (`flock -n 9`) ensures at most one instance executes at a time; overlapping invocations log a message and exit 0.

## Dependencies

Required on the TrueNAS host: `sensors`, `jq`, `docker`, `midclt`. The startup check validates all four and aborts with a log message if any is missing.
