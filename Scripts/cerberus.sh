#!/usr/bin/env bash
set -u   # treat unset variables as errors
#
#    /\    /\      /\    /\      /\    /\  
#   /  \  /  \    /  \  /  \    /  \  /  \ 
#  ( o )  ( O )  ( o )  ( o )  ( O )  ( o )
#   \  ~--~  /    \  ~--~  /    \  ~--~  / 
#    \ wWwW /      \ WwWw /      \ wWwW /  
#     '----'        '----'        '----'   
#
# Cerberus — CPU thermal watchdog for TrueNAS SCALE
#
# Targets the HPE ProLiant MicroServer Gen10 (AMD Opteron X3000-series APUs:
# X3216, X3418, X3421).  All Gen10 variants use the k10temp driver and share
# an integrated GPU on the same die as the CPU, so package temperature reflects
# the combined CPU + GPU thermal load — making it a more complete signal than
# docker stats CPU%, which is blind to GPU compute.
#
# On a thermal event, apps are stopped progressively — one per cron cycle —
# in CPU-load order (busiest first).  A full shutdown queue is built once from
# a docker stats snapshot; the front of the queue is only consumed when the
# temperature rises above the level at which the previous app was stopped.
# This gives each removal time to take effect before the next action is taken.
# Apps in PIN_LAST are always shed last in the queue regardless of CPU load.
#
# App state is managed exclusively via the TrueNAS middleware client (midclt)
# to keep UI state, health checks, and the internal daemon fully in sync.
# docker stats is used for read-only CPU observation only — no Docker state
# changes are made directly.
#
# Recovery restarts apps in a fixed dependency order (see STARTUP_TIERS) so
# that each service's dependencies are available before it launches.

# ──────────────────────────── Configuration ────────────────────────────────

# Resolve the directory containing this script to locate the companion env file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source user configuration if present.  All built-in defaults below apply for
# any setting not defined in the env file, so the script runs as-is without one.
ENV_FILE="${SCRIPT_DIR}/cerberus.env"
# shellcheck disable=SC1090,SC1091
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# ── Scalars: env value wins; built-in default applies if not set ─────────────
STOP_THRESHOLD="${STOP_THRESHOLD:-85}"         # °C: shed triggered; first app stopped
SHUTDOWN_THRESHOLD="${SHUTDOWN_THRESHOLD:-94}" # °C: graceful host shutdown via middleware
COOL_THRESHOLD="${COOL_THRESHOLD:-74}"         # °C: restart apps after cooling
LOGFILE="${LOGFILE:-/var/log/cerberus.log}"
MAX_SHED="${MAX_SHED:-0}"                      # max apps per thermal event (0 = unlimited)
LOG_RETAIN_DAYS="${LOG_RETAIN_DAYS:-7}"        # prune log entries older than this many days each cycle
METRICSFILE="${METRICSFILE:-/var/run/cerberus.prom}" # Prometheus textfile-collector output; empty = disabled

# ── Runtime state files (intentional paths; not user-configurable) ───────────
LOCKFILE="/var/run/cerberus.lock"          # stores °C at last stop action
QUEUEFILE="/var/run/cerberus.queue"        # remaining apps to stop, in order
STATEFILE="/var/run/cerberus.apps"         # apps stopped so far (for recovery)
TIERFILE="/var/run/cerberus.tiers"         # cerberus.tier label map, written at shutdown for recovery
EVENTSTART="/var/run/cerberus.eventstart"  # epoch seconds at first breach; used to compute event duration
INITFILE="/var/run/cerberus.init"          # absent on first post-boot run; triggers threshold log
DRYRUNFILE="/var/run/cerberus.dryrun"      # touch to enable dry-run mode (no apps stopped or started)
RUNLOCK="/var/run/cerberus.run"            # run-lock fd; prevents overlapping cron invocations

# ── Arrays: set default only when not already defined by the env file ────────
# Apps that must never be added to the shutdown queue, regardless of CPU load.
# Useful for monitoring, alerting, or any service that must remain running
# during a thermal event to keep the system observable.
if ! declare -p NEVER_STOP &>/dev/null; then
  NEVER_STOP=()
fi

# Apps that are always shed last, regardless of CPU load.
# Useful for GPU-intensive apps (e.g. media servers with hardware transcoding)
# whose thermal contribution appears in package temperature via k10temp but
# not in cgroup CPU accounting — making them appear idle while still driving heat.
# Apps not listed here are sorted by CPU load descending; PIN_LAST apps follow
# in the order they appear in this array.
if ! declare -p PIN_LAST &>/dev/null; then
  PIN_LAST=()
fi

# Startup dependency order used during recovery.  Apps are started tier by tier
# so each service's dependencies are available before it launches.  Apps not
# listed here are started last as a catch-all.
if ! declare -p STARTUP_TIERS &>/dev/null; then
  STARTUP_TIERS=()
fi

# Intended to run every minute via cron:
#   * * * * *  root  /path/to/scripts/cerberus.sh

# Ensure log directory exists; fall back to /tmp if the pool isn't mounted yet
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || LOGFILE="/var/log/cerberus.log"

# ──────────────────────────── Helpers ──────────────────────────────────────

log() {
  local msg
  msg="$(date '+%Y-%m-%d %H:%M:%S')  $1"
  echo "$msg" >> "$LOGFILE"
}

# Prune log entries older than LOG_RETAIN_DAYS on each cycle.
# ISO date format (YYYY-MM-DD) sorts lexicographically, so awk string
# comparison against the cutoff date is exact and requires no date maths.
# Writes to a temp file first so a mid-write failure never truncates the log.
# Also enforces 640 permissions so the log is not world-readable.
rotate_log() {
  if [[ ! -f "$LOGFILE" ]]; then
    touch "$LOGFILE"
    chmod 640 "$LOGFILE" 2>/dev/null || true
    return
  fi
  chmod 640 "$LOGFILE" 2>/dev/null || true
  local cutoff
  cutoff=$(date -d "-${LOG_RETAIN_DAYS} days" '+%Y-%m-%d')
  # shellcheck disable=SC2015
  awk -v cutoff="$cutoff" '$1 >= cutoff' "$LOGFILE" > "${LOGFILE}.tmp" \
    && mv -f "${LOGFILE}.tmp" "$LOGFILE" \
    || rm -f "${LOGFILE}.tmp"
}

# Write a Prometheus textfile-collector metrics file for the current cycle.
# Reads state from disk so it reflects the post-action state accurately.
# Writes atomically via a .tmp file to avoid partial reads by node_exporter.
# Set METRICSFILE to match node_exporter's --collector.textfile.directory.
write_metrics() {
  [[ -z "${METRICSFILE:-}" ]] && return
  local event_active=0 apps_stopped=0 last_breach=0
  [[ -f "$LOCKFILE" ]] && { event_active=1; last_breach=$(< "$LOCKFILE"); }
  [[ ! "$last_breach" =~ ^[0-9]+$ ]] && last_breach=0
  [[ -s "$STATEFILE" ]] && apps_stopped=$(( $(wc -l < "$STATEFILE") ))
  {
    printf '# HELP cerberus_cpu_temp_celsius Current CPU temperature in Celsius\n'
    printf '# TYPE cerberus_cpu_temp_celsius gauge\n'
    printf 'cerberus_cpu_temp_celsius %s\n' "$TEMP"
    printf '# HELP cerberus_thermal_event_active Whether a thermal event is currently active (1=active 0=normal)\n'
    printf '# TYPE cerberus_thermal_event_active gauge\n'
    printf 'cerberus_thermal_event_active %s\n' "$event_active"
    printf '# HELP cerberus_apps_stopped_total Number of apps currently stopped by Cerberus\n'
    printf '# TYPE cerberus_apps_stopped_total gauge\n'
    printf 'cerberus_apps_stopped_total %s\n' "$apps_stopped"
    printf '# HELP cerberus_last_breach_temp_celsius CPU temperature at last thermal breach (0 if none active)\n'
    printf '# TYPE cerberus_last_breach_temp_celsius gauge\n'
    printf 'cerberus_last_breach_temp_celsius %s\n' "$last_breach"
    if [[ -s "$STATEFILE" ]]; then
      printf '# HELP cerberus_app_stopped Whether this app is currently stopped by Cerberus (1=stopped)\n'
      printf '# TYPE cerberus_app_stopped gauge\n'
      while IFS= read -r _mapp; do
        local _safe_app="${_mapp//[^a-zA-Z0-9_\-\.]/}"  # sanitize Prometheus label value
        [[ -n "$_safe_app" ]] && printf 'cerberus_app_stopped{app="%s"} 1\n' "$_safe_app"
      done < "$STATEFILE"
    fi
  } > "${METRICSFILE}.tmp" && mv -f "${METRICSFILE}.tmp" "$METRICSFILE"
}

# Validate that a user-configurable write path resolves within a safe directory.
# Cerberus runs as root via cron — if cerberus.env is stored on a pool share
# accessible to a TrueNAS app, a compromised app could redirect LOGFILE or
# METRICSFILE to any system path, turning the next cron tick into an arbitrary
# file overwrite.  This guard aborts before any write occurs.
#
# Allowed base directories are resolved to their canonical paths at call time so
# the check is transparent to symlinks.  On modern systemd-based distros
# (including TrueNAS SCALE), /var/run is a symlink to /run and /var/log may
# also resolve differently — matching the literal string /var/run/* against a
# realpath-resolved path would always fail on those systems.
validate_writeable_path() {
  local var_name="$1" path="$2"
  local abs_path
  abs_path=$(realpath -m "$path" 2>/dev/null) || abs_path="$path"

  # Resolve each allowed base to its canonical form so symlinks are transparent.
  local _ok=0
  local _base _canon
  for _base in /var/log /var/run /mnt /tmp; do
    _canon=$(realpath -m "$_base" 2>/dev/null) || _canon="$_base"
    case "$abs_path" in
      "${_canon}"/*)
        _ok=1
        break
        ;;
    esac
  done

  if (( _ok == 0 )); then
    # Write to stderr — not log() — to avoid appending to the potentially
    # malicious path before we abort.
    echo "$(date '+%Y-%m-%d %H:%M:%S')  ABORT: ${var_name}='${path}' resolves to '${abs_path}' — outside allowed write paths (/var/log, /var/run, /mnt, /tmp). Fix cerberus.env." >&2
    exit 1
  fi
}

get_temp() {
  # Reads the CPU/APU package temperature via the k10temp driver (AMD Opteron
  # X3000-series).  temp1_input under the first k10temp-pci-* adapter reflects
  # the full package thermal load including integrated GPU activity.
  # sensors -j is used for structured parsing; jq is already a dependency.
  # Under sustained load temp1_input may read several degrees above the physical
  # package limit — configure thresholds in the env file to account for this.
  sensors -j 2>/dev/null \
    | jq -r 'to_entries[] | select(.key | startswith("k10temp")) | .value.temp1.temp1_input | round' 2>/dev/null
}

# Emit the names of all RUNNING apps via the TrueNAS middleware.
# Filter is applied client-side (jq) to avoid dependency on server-side
# filter syntax which changed between TrueNAS SCALE releases.
get_running_apps() {
  midclt call app.query 2>/dev/null \
    | jq -r '.[] | select(.state == "RUNNING") | .name' \
    | tr -d '\000-\037'   # strip control characters to prevent log/label injection
}

# Return 0 if the given app name is in the NEVER_STOP list, 1 otherwise.
is_never_stop() {
  local app="$1" ns
  for ns in "${NEVER_STOP[@]}"; do
    [[ "$ns" == "$app" ]] && return 0
  done
  return 1
}

# Return 0 if the given app name is in the PIN_LAST list, 1 otherwise.
is_pin_last() {
  local app="$1" pl
  for pl in "${PIN_LAST[@]}"; do
    [[ "$pl" == "$app" ]] && return 0
  done
  return 1
}

# One-shot CPU snapshot enriched with docker compose project labels.
# Adds a "Project" field to each NDJSON stats entry so that sum_app_cpu can
# match containers whose names share no common prefix with the TrueNAS app
# name (e.g. app "myapp" whose containers are named
# "myapp-worker-1" / "myapp-worker-2").
# Both docker commands use targeted format templates to fetch only the two
# fields required, avoiding the overhead of full JSON output.
get_enriched_stats() {
  local stats_json
  stats_json=$(docker stats --no-stream \
    --format '{"Name":{{json .Name}},"CPUPerc":{{json .CPUPerc}}}' \
    2>/dev/null)
  [[ -z "$stats_json" ]] && return

  local proj_json
  proj_json=$(docker ps \
    --format '{"Name":{{json .Names}},"Project":{{json (index .Labels "com.docker.compose.project")}},"Override":{{json (index .Labels "cerberus.override")}}}' \
    2>/dev/null)

  if [[ -z "$proj_json" ]]; then
    echo "$stats_json"
    return
  fi

  # Merge: add Project and Override fields to every stats entry in one jq pass.
  # Both inputs are NDJSON; proj_json is parsed into a name→{Project,Override} lookup map.
  jq -rn \
    --arg stats "$stats_json" \
    --arg proj  "$proj_json"  \
    '($proj | split("\n") | map(select(length > 0) | try fromjson catch null) |
        map(select(. != null) | {(.Name): {Project: .Project, Override: .Override}}) | add // {}) as $pm |
     ($stats | split("\n") | map(select(length > 0)) | .[]) |
     (. | try fromjson catch null) |
     if . != null then
       . + {Project: ($pm[.Name].Project // ""), Override: ($pm[.Name].Override // null)}
     else empty end' \
    2>/dev/null \
  || echo "$stats_json"
}

# Sum CPUPerc for all Docker containers belonging to an app.
# Matches by compose project label first (authoritative for both catalog and
# custom apps regardless of container naming conventions), then falls back to
# name-prefix heuristics for containers without project labels.
# Catalog apps: Project == "ix-<app>"
# Custom apps:  Project == "<app>"  (app name is the compose project name)
# $1 = app name; $2 = enriched NDJSON from get_enriched_stats.
sum_app_cpu() {
  jq -rs --arg app "$1" \
    '[.[] | select(
        .Project == $app or
        .Project == ("ix-" + $app) or
        .Name == $app or
        (.Name | startswith($app + "-")) or
        (.Name | startswith("ix-" + $app + "-"))
      ) | .CPUPerc | rtrimstr("%") | tonumber] | add // 0' \
    <<< "$2"
}

# Return 0 if any container for this app has a non-empty cerberus.override label.
# $1 = app name; $2 = enriched NDJSON from get_enriched_stats.
app_has_override() {
  local result
  result=$(jq -rs --arg app "$1" \
    '[.[] | select(
        .Project == $app or
        .Project == ("ix-" + $app) or
        .Name == $app or
        (.Name | startswith($app + "-")) or
        (.Name | startswith("ix-" + $app + "-"))
      ) | .Override // empty] | map(select(length > 0)) | length > 0' \
    <<< "$2" 2>/dev/null)
  [[ "$result" == "true" ]]
}

# Capture cerberus.tier container labels for all running apps and write a
# tier map to TIERFILE for use during recovery (when containers are gone).
# Called once at first thermal breach while all apps are still running.
build_tier_map() {
  local running_apps
  running_apps=$(get_running_apps)
  [[ -z "$running_apps" ]] && return

  local ps_json
  ps_json=$(docker ps \
    --format '{"Name":{{json .Names}},"Project":{{json (index .Labels "com.docker.compose.project")}},"Tier":{{json (index .Labels "cerberus.tier")}}}' \
    2>/dev/null)
  [[ -z "$ps_json" ]] && return

  local tier_lines="" app tier
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    tier=$(jq -rs --arg app "$app" \
      '[.[] | select(
          .Project == $app or
          .Project == ("ix-" + $app) or
          .Name == $app or
          (.Name | startswith($app + "-")) or
          (.Name | startswith("ix-" + $app + "-"))
        ) | .Tier // empty] | map(select(length > 0)) | first // empty' \
      <<< "$ps_json" 2>/dev/null)
    [[ -n "$tier" && "$tier" =~ ^[0-9]+$ ]] && tier_lines+="${app} ${tier}"$'\n'
  done <<< "$running_apps"

  if [[ -n "$tier_lines" ]]; then
    printf '%s' "$tier_lines" > "$TIERFILE"
    log "Cerberus tiers (labels): $(awk '{printf "%s=%s ", $1, $2}' "$TIERFILE")"
  fi
}

# Emit app names in shutdown order: busiest CPU first, PIN_LAST apps always last.
# CPU load is measured by summing CPUPerc across all containers belonging to
# each app — see sum_app_cpu for the matching strategy (project labels first,
# name-prefix heuristics as fallback).
# docker stats and docker ps are used for read-only observation only — no Docker state changes.
get_shutdown_order() {
  local running_apps
  running_apps=$(get_running_apps)
  [[ -z "$running_apps" ]] && return

  # One-shot NDJSON snapshot enriched with compose project labels.
  local stats_json
  stats_json=$(get_enriched_stats)
  [[ -z "$stats_json" ]] && log "docker stats returned empty; CPU ordering unavailable — apps will shed in arbitrary order"

  local sort_buf="" pinned_apps=()
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if is_never_stop "$app"; then
      log "  ${app}: excluded (NEVER_STOP)"
      continue
    fi
    if app_has_override "$app" "$stats_json"; then
      log "  ${app}: excluded (cerberus.override label)"
      continue
    fi
    local cpu
    cpu=$(sum_app_cpu "$app" "$stats_json")
    if is_pin_last "$app"; then
      pinned_apps+=("$app")
      log "  ${app}: ${cpu}% CPU (pinned last)"
      continue
    fi
    log "  ${app}: ${cpu}% CPU"
    sort_buf+="${cpu}"$'\t'"${app}"$'\n'
  done <<< "$running_apps"

  # Emit apps sorted by CPU load descending; PIN_LAST apps always follow in array order.
  printf '%s' "$sort_buf" | sort -t$'\t' -k1 -rn | cut -f2 | grep -v '^$'
  printf '%s\n' "${pinned_apps[@]}"
}

# Invoke a midclt app action (stop|start) with dry-run guard.
# Stopping also appends the app name to STATEFILE for recovery.
app_action() {
  local action="$1" app="$2"
  [[ "$action" != "stop" && "$action" != "start" ]] && { log "Invalid app action '${action}' — aborting."; return 1; }
  if [[ -f "$DRYRUNFILE" ]]; then
    log "[DRY RUN] Would ${action}: ${app}"
    return
  fi
  local verb
  case "$action" in
    stop)  verb="Stopping" ;;
    start) verb="Starting"  ;;
    *)     verb="${action^}ing" ;;
  esac
  log "[ACTION] ${verb} app: ${app}"
  local app_json
  app_json=$(jq -n --arg n "$app" '$n')
  midclt call "app.${action}" "$app_json" >/dev/null 2>&1
  [[ "$action" == "stop" ]] && echo "$app" >> "$STATEFILE"
}

stop_app()  { app_action stop  "$1"; }
start_app() { app_action start "$1"; }

# Remove and return the first entry from QUEUEFILE (atomic queue pop).
pop_queue() {
  local item
  item=$(head -1 "$QUEUEFILE" 2>/dev/null)
  [[ -n "$item" ]] && sed -i '1d' "$QUEUEFILE"
  printf '%s' "$item"
}

# ──────────────────────────── Startup checks ────────────────────────────

validate_writeable_path LOGFILE "$LOGFILE"
[[ -n "${METRICSFILE:-}" ]] && validate_writeable_path METRICSFILE "$METRICSFILE"

rotate_log

for _cmd in sensors jq docker midclt; do
  command -v "$_cmd" &>/dev/null || { log "Missing dependency: $_cmd — aborting."; exit 1; }
done
unset _cmd

exec 9>"$RUNLOCK"
flock -n 9 || { log "Another instance already running — skipping this cycle."; exit 0; }

if [[ ! -f "$INITFILE" ]]; then
  log "Thresholds — STOP: ${STOP_THRESHOLD}°C  SHUTDOWN: ${SHUTDOWN_THRESHOLD}°C  COOL: ${COOL_THRESHOLD}°C"
  (( ${#NEVER_STOP[@]} > 0 )) && log "NEVER_STOP: ${NEVER_STOP[*]}"
  (( ${#PIN_LAST[@]} > 0 )) && log "PIN_LAST: ${PIN_LAST[*]}"
  touch "$INITFILE"
fi

# ──────────────────────────── Main logic ───────────────────────────────────

TEMP=$(get_temp)

if [[ -z "$TEMP" ]]; then
  log "Unable to read CPU temperature — sensors not ready or k10temp not loaded."
  exit 0
fi

if ! [[ "$TEMP" =~ ^[0-9]+$ ]]; then
  log "Unexpected temperature value '${TEMP}' — not a valid integer; aborting."
  exit 1
fi

log "CPU temp = ${TEMP}°C"
write_metrics

# ── Emergency shutdown ──────────────────────────────────────────────────────
if (( TEMP >= SHUTDOWN_THRESHOLD )); then
  log "[EMERGENCY] Temp >= ${SHUTDOWN_THRESHOLD}°C — initiating graceful system shutdown."
  midclt call system.shutdown '{"delay": 0}' 2>/dev/null || /sbin/shutdown -h now
  exit 0
fi

# ── First breach: build queue and stop the busiest app ──────────────────────
if (( TEMP >= STOP_THRESHOLD )) && [[ ! -f "$LOCKFILE" ]]; then
  log "[THERMAL] Temp >= ${STOP_THRESHOLD}°C — thermal shed triggered."
  log "CPU snapshot:"
  : > "$STATEFILE"
  get_shutdown_order > "$QUEUEFILE"
  build_tier_map
  if (( MAX_SHED > 0 )); then
    head -n "$MAX_SHED" "$QUEUEFILE" > "${QUEUEFILE}.tmp" && mv "${QUEUEFILE}.tmp" "$QUEUEFILE"
    log "Queue capped at ${MAX_SHED} app(s) (MAX_SHED)."
  fi
  log "Shutdown queue: $(tr '\n' ' ' < "$QUEUEFILE")"

  next=$(pop_queue)
  if [[ -n "$next" ]]; then
    stop_app "$next"
    echo "$TEMP" > "$LOCKFILE"
    date +%s > "$EVENTSTART"
    log "Monitoring for further rise ($(wc -l < "$QUEUEFILE") app(s) remaining in queue)."
  else
    log "No running apps found — nothing to shed; thermal monitoring continues."
    rm -f "$QUEUEFILE" "$STATEFILE" "$TIERFILE"
  fi
  exit 0
fi

# ── Progressive shed / holding / recovery: lockfile present ─────────────────
if [[ -f "$LOCKFILE" ]]; then
  LAST_STOP_TEMP=$(< "$LOCKFILE")

  if ! [[ "$LAST_STOP_TEMP" =~ ^[0-9]+$ ]]; then
    log "Corrupt lockfile (non-numeric: '${LAST_STOP_TEMP}') — clearing state and aborting cycle."
    rm -f "$LOCKFILE" "$QUEUEFILE" "$STATEFILE" "$TIERFILE" "$EVENTSTART"
    exit 1
  fi

  # Recovery: temperature has dropped below the cool threshold.
  if (( TEMP <= COOL_THRESHOLD )); then
    log "[RECOVERY] Temp <= ${COOL_THRESHOLD}°C — restarting apps in dependency order."

    if [[ -s "$STATEFILE" ]]; then
      declare -A _stopped
      while IFS= read -r app; do
        [[ -n "$app" ]] && _stopped["$app"]=1
      done < "$STATEFILE"

      # Build per-app tier assignments.  cerberus.tier label values (captured in
      # TIERFILE at shutdown time while containers were running) take priority.
      # STARTUP_TIERS provides fallback ordering for unlabelled apps.
      # Everything else starts last (tier 9999).
      declare -A _app_tier

      if [[ -s "$TIERFILE" ]]; then
        while IFS=' ' read -r app _tier_num; do
          [[ -n "$app" && "$_tier_num" =~ ^[0-9]+$ ]] && _app_tier["$app"]="$_tier_num"
        done < "$TIERFILE"
      fi

      for (( _idx = 0; _idx < ${#STARTUP_TIERS[@]}; _idx++ )); do
        for app in ${STARTUP_TIERS[$_idx]}; do
          [[ -n "${_stopped[$app]:-}" && -z "${_app_tier[$app]:-}" ]] \
            && _app_tier["$app"]=$(( _idx + 1 ))
        done
      done

      for app in "${!_stopped[@]}"; do
        [[ -z "${_app_tier[$app]:-}" ]] && _app_tier["$app"]=9999
      done

      # Start apps sorted by tier number (ascending).
      while IFS=$'\t' read -r _ app; do
        [[ -n "$app" ]] && start_app "$app"
      done < <(
        for app in "${!_stopped[@]}"; do
          printf '%s\t%s\n' "${_app_tier[$app]:-9999}" "$app"
        done | sort -t$'\t' -k1 -n
      )

    else
      log "Statefile missing or empty — no apps to restart."
    fi

    _duration_msg=""
    if [[ -f "$EVENTSTART" ]]; then
      _start=$(< "$EVENTSTART")
      _elapsed=$(( $(date +%s) - _start ))
      _mins=$(( _elapsed / 60 ))
      _secs=$(( _elapsed % 60 ))
      _duration_msg=" — duration: ${_mins}m ${_secs}s"
    fi
    _restart_count=0
    [[ -s "$STATEFILE" ]] && _restart_count=$(( $(wc -l < "$STATEFILE") ))
    rm -f "$LOCKFILE" "$QUEUEFILE" "$STATEFILE" "$TIERFILE" "$EVENTSTART"
    log "[RECOVERY] Recovery complete — ${_restart_count} app(s) restarted${_duration_msg}."
    exit 0
  fi

  # Progressive: temperature has risen above the last stop action — stop next.
  if (( TEMP > LAST_STOP_TEMP )) && [[ -s "$QUEUEFILE" ]]; then
    next=$(pop_queue)
    log "[THERMAL] Temp risen to ${TEMP}°C (was ${LAST_STOP_TEMP}°C) — stopping next app."
    stop_app "$next"
    echo "$TEMP" > "$LOCKFILE"
    exit 0
  fi

  # Holding: temp is stable or dropping — no further action needed yet.
  if [[ ! -s "$QUEUEFILE" ]]; then
    log "Temp = ${TEMP}°C — all apps stopped, waiting to cool below ${COOL_THRESHOLD}°C."
  else
    log "Temp = ${TEMP}°C (last action at ${LAST_STOP_TEMP}°C) — holding, $(wc -l < "$QUEUEFILE") app(s) queued."
  fi
  exit 0
fi

# Normal: below STOP_THRESHOLD with no lockfile — nothing to do.
exit 0
