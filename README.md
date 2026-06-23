# Cerberus

```
   /\    /\      /\    /\      /\    /\  
  /  \  /  \    /  \  /  \    /  \  /  \
 ( o )  ( O )  ( o )  ( o )  ( O )  ( o )
  \  ~--~  /    \  ~--~  /    \  ~--~  /
   \ wWwW /      \ WwWw /      \ wWwW /
    '----'        '----'        '----'
```

CPU thermal watchdog for [TrueNAS SCALE](https://www.truenas.com/truenas-scale/), designed for the **HPE ProLiant MicroServer Gen10** (AMD Opteron X3000-series APUs: X3216, X3418, X3421).

When temperatures rise, Cerberus progressively stops Docker/TrueNAS apps one per cron cycle in CPU-load order, giving each removal time to take effect before the next action. Once the system cools, apps are restarted in configured dependency order.

## Features

- **Progressive thermal shedding** — stops apps one at a time, busiest CPU consumer first
- **Pinnable apps** — apps in `PIN_LAST` are always shed last, regardless of CPU load (designed for GPU-intensive apps whose thermal contribution appears in package temperature but not in CPU%)
- **Recovery with dependency ordering** — restarts apps tier by tier via `cerberus.tier` Docker labels or the `STARTUP_TIERS` env array
- **Emergency shutdown** — triggers a graceful host shutdown via TrueNAS middleware at a configurable upper threshold
- **Dry-run mode** — `touch /var/run/cerberus.dryrun` to observe without taking any action
- **Per-app exclusions** — via `NEVER_STOP` array or `cerberus.override=true` Docker label
- **Concurrency guard** — flock prevents overlapping cron invocations

## How It Works

Each cron invocation is a single state transition:

```
Normal → [TEMP ≥ STOP_THRESHOLD]     → First breach: build shutdown queue, stop busiest app, write lockfile
Active → [TEMP > last_stop_temp]     → Progressive shed: stop next app from queue, update lockfile
Active → [TEMP ≤ last_stop_temp]     → Holding: log status, no action
Active → [TEMP ≤ COOL_THRESHOLD]     → Recovery: restart stopped apps in tier order, clear state files
Any    → [TEMP ≥ SHUTDOWN_THRESHOLD] → Emergency: graceful system shutdown via middleware, exit
```

CPU load is observed by summing `CPUPerc` across all Docker containers belonging to each TrueNAS app (matched by compose project label, with name-prefix fallback). All start/stop actions use `midclt` to keep the TrueNAS UI, health checks, and internal daemon in sync — Docker is used read-only.

## Prerequisites

The following must be present on the TrueNAS host:

| Tool | Purpose |
|---|---|
| `sensors` (`lm-sensors`) | CPU temperature via the k10temp driver |
| `jq` | JSON parsing |
| `docker` | Read-only CPU observation (`stats`, `ps`) |
| `midclt` | TrueNAS middleware client — app start/stop/query |

## Installation

1. Copy `Scripts/cerberus.sh` to a location on a persistent pool (e.g. `/mnt/pool/apps/scripts/`).
2. Copy `Scripts/EXAMPLE-cerberus.env` to the same directory, rename it `cerberus.env`, and edit it to match your hardware and app layout.
3. Make the script executable:
   ```bash
   chmod +x /mnt/pool/apps/scripts/cerberus.sh
   ```
4. Add a cron job (TrueNAS UI → System → Advanced → Cron Jobs, or `/etc/crontab`):
   ```
   * * * * *  root  /mnt/pool/apps/scripts/cerberus.sh
   ```

## Configuration

All settings live in `cerberus.env` alongside the script. The script runs correctly with an empty or absent env file — all built-in defaults apply.

| Variable | Default | Description |
|---|---|---|
| `STOP_THRESHOLD` | `85` | °C at which thermal shedding begins |
| `SHUTDOWN_THRESHOLD` | `94` | °C at which a graceful host shutdown is triggered |
| `COOL_THRESHOLD` | `74` | °C below which stopped apps are restarted |
| `LOGFILE` | `/var/log/cerberus.log` | Log file path |
| `LOG_RETAIN_DAYS` | `7` | Days of log entries to retain; older entries are pruned each cycle |
| `MAX_SHED` | `0` | Max apps stopped per thermal event (`0` = unlimited) |
| `METRICSFILE` | `/var/run/cerberus.prom` | Prometheus textfile-collector output path — set to match `node_exporter`'s `--collector.textfile.directory`; leave empty to disable |
| `NEVER_STOP` | `()` | App names excluded from the shutdown queue entirely |
| `PIN_LAST` | `()` | App names always shed last, in array order — intended for GPU-intensive apps whose load shows in temperature but not in CPU% |
| `STARTUP_TIERS` | `()` | Recovery restart order — space-separated app names per tier |

After editing `cerberus.env`, delete `/var/run/cerberus.init` so the updated thresholds are re-logged on the next cron cycle.

### Per-app Docker label overrides

Labels can be set directly in an app's compose stack — no env file change required.

| Label | Value | Effect |
|---|---|---|
| `cerberus.override` | any non-empty string | Excludes this app from the shutdown queue (equivalent to `NEVER_STOP`) |
| `cerberus.tier` | integer | Sets recovery restart tier for this app (takes priority over `STARTUP_TIERS`) |

### Recovery ordering

Apps are restarted in this priority order:

1. `cerberus.tier` Docker label (captured at first thermal breach while containers are still running)
2. Position in the `STARTUP_TIERS` array (env file)
3. Tier 9999 catch-all — everything not covered by either of the above

## State Files

Cerberus writes transient state to `/var/run/` (cleared on reboot). These paths are not user-configurable.

| File | Purpose |
|---|---|
| `cerberus.lock` | Temperature (°C) at the last stop action; presence signals an active thermal event |
| `cerberus.queue` | Ordered list of apps still to stop |
| `cerberus.apps` | Apps stopped so far (used for recovery) |
| `cerberus.tiers` | `app tier_number` pairs captured at first breach for use during recovery |
| `cerberus.eventstart` | Epoch timestamp of first thermal breach; used to calculate event duration at recovery |
| `cerberus.init` | Sentinel; absent on first post-boot run to trigger threshold logging |
| `cerberus.dryrun` | Touch file — enables dry-run mode |
| `cerberus.run` | flock file — prevents overlapping cron invocations |

## Dry-Run Mode

```bash
touch /var/run/cerberus.dryrun   # enable
rm    /var/run/cerberus.dryrun   # disable
```

In dry-run mode, all stop/start decisions are logged as `[DRY RUN]` but no apps are actually touched.

## Logging

Logs are appended to `$LOGFILE` (default `/var/log/cerberus.log`) with `YYYY-MM-DD HH:MM:SS` timestamps. Entries older than `LOG_RETAIN_DAYS` days are pruned at the start of each cycle. The log file is created with `640` permissions.

Key events are tagged for easy filtering (e.g. in Loki/Grafana):

| Tag | Meaning |
|---|---|
| `[THERMAL]` | Thermal shed triggered or progressive shed step |
| `[ACTION]` | App stopped or started |
| `[RECOVERY]` | Recovery phase started or completed (includes duration and app count) |
| `[EMERGENCY]` | Shutdown threshold reached — system shutdown initiated |

## Observability

Cerberus can write a [Prometheus textfile-collector](https://github.com/prometheus/node_exporter#textfile-collector) metrics file on every cron cycle. Set `METRICSFILE` in `cerberus.env` to match `node_exporter`'s `--collector.textfile.directory`:

```bash
METRICSFILE="/var/run/cerberus.prom"
```

Metrics exposed:

| Metric | Type | Description |
|---|---|---|
| `cerberus_cpu_temp_celsius` | gauge | Current CPU temperature |
| `cerberus_thermal_event_active` | gauge | `1` if a thermal event is active, `0` otherwise |
| `cerberus_apps_stopped_total` | gauge | Number of apps currently stopped by Cerberus |
| `cerberus_last_breach_temp_celsius` | gauge | Temperature at last thermal breach (`0` if none active) |
| `cerberus_app_stopped{app="..."}` | gauge | Per-app stopped state (`1` = stopped) |

For log-based event analytics (spike timelines, stop/start history), ship the log to [Loki](https://grafana.com/oss/loki/) with Promtail. The `[THERMAL]`, `[ACTION]`, and `[RECOVERY]` tags make event extraction straightforward with LogQL.

## Hardware Notes

Cerberus currently targets the **HPE ProLiant MicroServer Gen10** (AMD Opteron X3216/X3418/X3421). These APUs use the `k10temp` kernel driver and expose a `temp1_input` value that reflects the combined CPU + GPU thermal load — a more complete signal than CPU% alone.

Support for other thermal drivers (`coretemp`, `zenpower`, `nct6775`) is planned. See [TODO.md](TODO.md) for details and how to contribute platform data.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © CTOUT
