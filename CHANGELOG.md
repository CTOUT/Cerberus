# Changelog

All notable changes to Cerberus are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

---

## [v1.0.0] — 2026-06-23

### Added

- Standardized repository configurations (.editorconfig, Prettier)
- Automated CSpell dictionaries and validation workflows
- Automated GitHub Release workflows

### Added

- Prometheus textfile-collector output (`write_metrics()`) — exposes `cerberus_cpu_temp_celsius`, `cerberus_thermal_event_active`, `cerberus_apps_stopped_total`, `cerberus_last_breach_temp_celsius`, and per-app `cerberus_app_stopped` gauge metrics each cron cycle
- `METRICSFILE` configuration variable — set to match `node_exporter`'s textfile directory; leave empty to disable
- `cerberus.eventstart` state file — records epoch timestamp at first thermal breach for event duration calculation
- Event duration and app count logged at recovery complete: `[RECOVERY] Recovery complete — N app(s) restarted — duration: Xm Ys.`
- Structured log event tags: `[THERMAL]`, `[ACTION]`, `[RECOVERY]`, `[EMERGENCY]` — enables LogQL filtering in Loki/Grafana
- `PIN_LAST` array — configurable list of apps always shed last in a thermal event, in array order; replaces the previous hardcoded app exception

### Changed

- `LOG_RETAIN_DAYS` default raised from `3` to `7` days — reduces risk of losing event logs before post-incident review

### Fixed

- `validate_writeable_path()` — on modern systemd-based distros (including TrueNAS SCALE), `/var/run` is a symlink to `/run`; resolving the configured path with `realpath` and then matching against the literal string `/var/run/*` always failed, causing a false-positive ABORT on every invocation when `METRICSFILE` was set. Allowed base directories are now also resolved to their canonical paths before comparison, making the check symlink-transparent.

### Security

- `validate_writeable_path()` — validates `LOGFILE` and `METRICSFILE` resolve within safe directories (`/var/log`, `/var/run`, `/mnt`, `/tmp`) before any write; aborts to stderr to avoid writing to a malicious path
- `get_running_apps()` strips control characters (`tr -d '\000-\037'`) — prevents log injection and Prometheus label injection via crafted TrueNAS app names
- `write_metrics()` sanitizes app names to `[a-zA-Z0-9_\-.]` before writing Prometheus label values
- `write_metrics()` re-validates `last_breach` as a non-negative integer — prevents malformed Prometheus output on corrupt lockfile
- `app_action()` guards against unknown action verbs — future-proofs against unintended callers

## [1.0.0] — 2025

### Added

- `cerberus.sh` — CPU thermal watchdog for TrueNAS SCALE on HPE ProLiant MicroServer Gen10 (AMD Opteron X3000-series)
- Progressive thermal shedding: stops apps one per cron cycle in CPU-load order (busiest first), PIN_LAST apps always last
- Emergency graceful host shutdown via TrueNAS middleware (`midclt`) at configurable upper threshold
- Recovery with dependency ordering via `cerberus.tier` Docker labels and `STARTUP_TIERS` env array
- Per-app exclusions via `NEVER_STOP` array and `cerberus.override` Docker label
- Dry-run mode (`touch /var/run/cerberus.dryrun`)
- Run-lock concurrency guard (`flock`) to prevent overlapping cron invocations
- Log rotation: entries older than `LOG_RETAIN_DAYS` days pruned each cycle; `640` permissions enforced
- `EXAMPLE-cerberus.env` configuration template
