#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
config_path="$script_dir/../git-sync.config.json"

usage() {
    cat <<'EOF'
Usage:
  install.sh [options]

Options:
  --config PATH
  --help
EOF
}

shell_quote() {
    printf '%q' "$1"
}

ensure_gitignore_entry() {
    local repo_root="$1"
    local gitignore_path="$repo_root/.gitignore"

    if [[ -f "$gitignore_path" ]] && grep -Eq '^[[:space:]]*/?\.git-sync/?[[:space:]]*$' "$gitignore_path"; then
        if awk '
            /^[[:space:]]*\/?\.git-sync\/?[[:space:]]*$/ {
                if (previous == "# Local Git sync toolkit") {
                    found = 1
                }
            }
            {
                previous = $0
            }
            END {
                exit(found ? 0 : 1)
            }
        ' "$gitignore_path"; then
            return 1
        fi

        local temp_path
        temp_path="$(mktemp)"
        awk '
            /^[[:space:]]*\/?\.git-sync\/?[[:space:]]*$/ && previous != "# Local Git sync toolkit" && !inserted {
                print "# Local Git sync toolkit"
                inserted = 1
            }
            {
                print
                previous = $0
            }
        ' "$gitignore_path" >"$temp_path"
        mv "$temp_path" "$gitignore_path"
        return 0
    fi

    if [[ -s "$gitignore_path" ]]; then
        printf '\n' >>"$gitignore_path"
    fi

    {
        printf '# Local Git sync toolkit\n'
        printf '/.git-sync/\n'
    } >>"$gitignore_path"

    return 0
}

while (($# > 0)); do
    case "$1" in
        --config)
            config_path="${2:?missing value for --config}"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 command was not found.\n' >&2
    exit 1
fi

if ! command -v crontab >/dev/null 2>&1; then
    printf 'crontab command was not found.\n' >&2
    exit 1
fi

mapfile -d '' -t config_values < <(
    python3 - "$config_path" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser().resolve()
config = json.loads(config_path.read_text(encoding="utf-8"))
config_dir = config_path.parent

repo = config.get("repository", {})
commit = config.get("commit", {})
schedule = config.get("schedule", {})
startup = config.get("startup", {})
linux = config.get("linux", {})

repo_path = Path(str(repo.get("path", ".."))).expanduser()
if not repo_path.is_absolute():
    repo_path = (config_dir / repo_path).resolve()

values = [
    str(config_path),
    str(repo_path),
    str(repo.get("remote", "origin") or "origin"),
    str(repo.get("branch", "") or ""),
    str(commit.get("messageTemplate", "sync({date}): update from {computer} at {time}") or "sync({date}): update from {computer} at {time}"),
    str(schedule.get("mode", "interval") or "interval").strip().lower(),
    str(schedule.get("intervalMinutes", 30)),
    str(schedule.get("dailyTime", "08:30") or "08:30"),
    "true" if bool(startup.get("enabled", False)) else "false",
    str(linux.get("cronMarker", "") or ""),
]

sys.stdout.write("\0".join(values))
sys.stdout.write("\0")
PY
)

resolved_config_path="${config_values[0]}"
repo_path="${config_values[1]}"
remote="${config_values[2]}"
branch="${config_values[3]}"
message_template="${config_values[4]}"
schedule_mode="${config_values[5]}"
interval_minutes="${config_values[6]}"
daily_time="${config_values[7]}"
startup_enabled="${config_values[8]}"
cron_marker="${config_values[9]}"

repo_name="$(basename "$repo_path")"
if [[ -z "$cron_marker" ]]; then
    cron_marker="git-sync-$repo_name"
fi

managed_token="CODEX_GIT_SYNC_MARKER=$cron_marker"
sync_script_path="$script_dir/sync.sh"
if [[ ! -f "$sync_script_path" ]]; then
    printf "Sync script not found at '%s'.\n" "$sync_script_path" >&2
    exit 1
fi

if [[ ! -d "$repo_path" ]]; then
    printf "Repository path '%s' does not exist.\n" "$repo_path" >&2
    exit 1
fi

command_parts=(
    env
    "$managed_token"
    bash
    "$sync_script_path"
    --repo-path
    "$repo_path"
    --remote
    "$remote"
    --message-template
    "$message_template"
)

if [[ -n "$branch" ]]; then
    command_parts+=(--branch "$branch")
fi

cron_command=""
for part in "${command_parts[@]}"; do
    cron_command+="$(shell_quote "$part") "
done
cron_command="${cron_command% }"

case "$schedule_mode" in
    interval)
        if [[ ! "$interval_minutes" =~ ^[0-9]+$ ]] || ((interval_minutes < 1)); then
            printf 'schedule.intervalMinutes must be an integer greater than or equal to 1.\n' >&2
            exit 1
        fi

        schedule_entry="* * * * * if [ \$(( \$(date +\\%s) / 60 \\% $interval_minutes )) -eq 0 ]; then $cron_command; fi"
        schedule_summary="every $interval_minutes minute(s)"
        ;;
    daily)
        if [[ ! "$daily_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            printf 'schedule.dailyTime must use HH:mm 24-hour format.\n' >&2
            exit 1
        fi

        daily_hour="${daily_time%%:*}"
        daily_minute="${daily_time##*:}"
        schedule_entry="$daily_minute $daily_hour * * * $cron_command"
        schedule_summary="daily at $daily_time"
        ;;
    *)
        printf "Unsupported schedule.mode '%s'. Use 'interval' or 'daily'.\n" "$schedule_mode" >&2
        exit 1
        ;;
esac

managed_header="# $cron_marker:managed"
schedule_header="# $cron_marker:schedule"
startup_header="# $cron_marker:startup"
startup_entry="@reboot $cron_command"

existing_crontab="$(crontab -l 2>/dev/null || true)"
filtered_crontab="$(
    printf '%s\n' "$existing_crontab" |
        awk \
            -v marker="$cron_marker" \
            -v token="$managed_token" \
            'index($0, "# " marker ":") == 0 && index($0, token) == 0'
)"

{
    if [[ -n "${filtered_crontab//$'\n'/}" ]]; then
        printf '%s\n' "$filtered_crontab"
    fi
    printf '%s\n' "$managed_header"
    printf '%s\n' "$schedule_header"
    printf '%s\n' "$schedule_entry"
    if [[ "$startup_enabled" == "true" ]]; then
        printf '%s\n' "$startup_header"
        printf '%s\n' "$startup_entry"
    fi
} | crontab -

gitignore_updated="false"
if ensure_gitignore_entry "$repo_path"; then
    gitignore_updated="true"
fi

printf "Installed cron entries from '%s' to run %s. Startup trigger enabled: %s.\n" \
    "$resolved_config_path" \
    "$schedule_summary" \
    "$startup_enabled"
printf ".gitignore updated: %s.\n" "$gitignore_updated"
