#!/usr/bin/env bash
set -euo pipefail

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
remote="origin"
branch=""
message_template='sync({date}): update from {computer} at {time}'
date_format='+%Y-%m-%d'
time_format='+%H:%M:%S'

usage() {
    cat <<'EOF'
Usage:
  sync.sh [options]

Options:
  --repo-path PATH
  --remote NAME
  --branch NAME
  --message-template TEXT
  --date-format FORMAT
  --time-format FORMAT
  --help
EOF
}

while (($# > 0)); do
    case "$1" in
        --repo-path)
            repo_path="${2:?missing value for --repo-path}"
            shift 2
            ;;
        --remote)
            remote="${2:?missing value for --remote}"
            shift 2
            ;;
        --branch)
            branch="${2:?missing value for --branch}"
            shift 2
            ;;
        --message-template)
            message_template="${2:?missing value for --message-template}"
            shift 2
            ;;
        --date-format)
            date_format="${2:?missing value for --date-format}"
            shift 2
            ;;
        --time-format)
            time_format="${2:?missing value for --time-format}"
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

repo_path="$(cd "$repo_path" && pwd -P)"
git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null

if [[ -z "$branch" ]]; then
    branch="$(git -C "$repo_path" branch --show-current)"
fi

if [[ -z "$branch" ]]; then
    printf 'Unable to determine the current branch. Pass --branch explicitly.\n' >&2
    exit 1
fi

if [[ -z "$(git -C "$repo_path" status --porcelain)" ]]; then
    printf 'No changes detected. Nothing to sync.\n'
    exit 0
fi

git -C "$repo_path" add --all

if git -C "$repo_path" diff --cached --quiet; then
    printf 'No staged changes remain after git add. Nothing to sync.\n'
    exit 0
fi

date_value="$(date "$date_format")"
time_value="$(date "$time_format")"
computer_name="$(hostname 2>/dev/null || uname -n)"

commit_message="${message_template//\{date\}/$date_value}"
commit_message="${commit_message//\{time\}/$time_value}"
commit_message="${commit_message//\{computer\}/$computer_name}"

if [[ -z "${commit_message//[[:space:]]/}" ]]; then
    printf 'Resolved commit message is empty.\n' >&2
    exit 1
fi

git -C "$repo_path" commit -m "$commit_message"
git -C "$repo_path" push "$remote" "$branch"

printf "Synced '%s' to '%s/%s' with commit '%s'.\n" "$repo_path" "$remote" "$branch" "$commit_message"
