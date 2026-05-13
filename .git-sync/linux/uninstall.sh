#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
config_path="$script_dir/../git-sync.config.json"

usage() {
    cat <<'EOF'
Usage:
  uninstall.sh [options]

Options:
  --config PATH
  --help
EOF
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
linux = config.get("linux", {})

repo_path = Path(str(repo.get("path", ".."))).expanduser()
if not repo_path.is_absolute():
    repo_path = (config_dir / repo_path).resolve()

values = [
    str(repo_path),
    str(linux.get("cronMarker", "") or ""),
]

sys.stdout.write("\0".join(values))
sys.stdout.write("\0")
PY
)

repo_path="${config_values[0]}"
cron_marker="${config_values[1]}"
repo_name="$(basename "$repo_path")"
if [[ -z "$cron_marker" ]]; then
    cron_marker="git-sync-$repo_name"
fi

managed_token="CODEX_GIT_SYNC_MARKER=$cron_marker"

existing_crontab="$(crontab -l 2>/dev/null || true)"
if [[ -z "$existing_crontab" ]]; then
    printf "No crontab exists. Nothing to restore for '%s'.\n" "$cron_marker"
    exit 0
fi

filtered_crontab="$(
    printf '%s\n' "$existing_crontab" |
        awk \
            -v marker="$cron_marker" \
            -v token="$managed_token" \
            'index($0, "# " marker ":") == 0 && index($0, token) == 0'
)"

if [[ "$filtered_crontab" == "$existing_crontab" ]]; then
    printf "Cron entry '%s' does not exist. Nothing to restore.\n" "$cron_marker"
    exit 0
fi

if [[ -n "${filtered_crontab//$'\n'/}" ]]; then
    printf '%s\n' "$filtered_crontab" | crontab -
else
    crontab -r 2>/dev/null || true
fi

printf "Removed cron entries '%s', including any @reboot startup entry.\n" "$cron_marker"
