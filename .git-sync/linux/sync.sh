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

git -C "$repo_path" fetch --prune "$remote"

remote_tracking_ref="refs/remotes/$remote/$branch"
remote_tracking_ref_exists=false
if git -C "$repo_path" rev-parse --verify --quiet "$remote_tracking_ref" >/dev/null; then
    remote_tracking_ref_exists=true
else
    remote_ref_exit_code=$?
    if [[ $remote_ref_exit_code -ne 1 ]]; then
        printf "git rev-parse --verify --quiet '%s' failed while checking whether the remote branch exists.\n" "$remote_tracking_ref" >&2
        exit 1
    fi
fi

status_output="$(git -C "$repo_path" status --porcelain)"
has_working_tree_changes=false
created_commit=false
commit_message=""

if [[ -n "$status_output" ]]; then
    has_working_tree_changes=true
    git -C "$repo_path" add --all

    if git -C "$repo_path" diff --cached --quiet; then
        :
    else
        diff_exit_code=$?
        if [[ $diff_exit_code -ne 1 ]]; then
            printf 'git diff --cached --quiet failed while checking staged changes.\n' >&2
            exit 1
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
        created_commit=true
    fi
fi

has_pending_local_commits=false
if [[ "$remote_tracking_ref_exists" == true ]]; then
    ahead_count="$(git -C "$repo_path" rev-list --count "$remote_tracking_ref..HEAD")"
    if [[ ! "$ahead_count" =~ ^[0-9]+$ ]]; then
        printf "Unable to parse local-ahead commit count '%s'.\n" "$ahead_count" >&2
        exit 1
    fi

    if ((ahead_count > 0)); then
        has_pending_local_commits=true
    fi
elif [[ "$created_commit" == true ]]; then
    has_pending_local_commits=true
fi

if [[ "$has_pending_local_commits" != true ]]; then
    if [[ "$has_working_tree_changes" == true ]]; then
        printf 'No staged changes or pending local commits remain. Nothing to sync.\n'
    else
        printf 'No changes detected. Nothing to sync.\n'
    fi

    exit 0
fi

safe_rebase() {
    local target_ref="$1"
    local rebase_output
    local abort_output

    if ! rebase_output="$(git -C "$repo_path" rebase "$target_ref" 2>&1)"; then
        if ! abort_output="$(git -C "$repo_path" rebase --abort 2>&1)"; then
            printf "git rebase '%s' failed, and git rebase --abort also failed.\n%s\n%s\n" "$target_ref" "$rebase_output" "$abort_output" >&2
            exit 1
        fi

        printf "git rebase '%s' failed. Rebase was aborted; resolve the divergence manually, then rerun sync.\n%s\n" "$target_ref" "$rebase_output" >&2
        exit 1
    fi
}

if [[ "$remote_tracking_ref_exists" == true ]]; then
    safe_rebase "$remote_tracking_ref"
fi

if ! initial_push_output="$(git -C "$repo_path" push "$remote" "$branch" 2>&1)"; then
    git -C "$repo_path" fetch --prune "$remote"

    remote_tracking_ref_exists=false
    if git -C "$repo_path" rev-parse --verify --quiet "$remote_tracking_ref" >/dev/null; then
        remote_tracking_ref_exists=true
    else
        remote_ref_exit_code=$?
        if [[ $remote_ref_exit_code -ne 1 ]]; then
            printf "git rev-parse --verify --quiet '%s' failed while checking whether the remote branch exists.\n" "$remote_tracking_ref" >&2
            exit 1
        fi
    fi

    if [[ "$remote_tracking_ref_exists" == true ]]; then
        safe_rebase "$remote_tracking_ref"
    fi

    if ! retry_push_output="$(git -C "$repo_path" push "$remote" "$branch" 2>&1)"; then
        printf "git push '%s' '%s' failed, and the single safe retry after fetch/rebase also failed.\nInitial push:\n%s\nRetry push:\n%s\n" "$remote" "$branch" "$initial_push_output" "$retry_push_output" >&2
        exit 1
    fi
fi

if [[ "$created_commit" == true ]]; then
    printf "Synced '%s' to '%s/%s' with commit '%s'.\n" "$repo_path" "$remote" "$branch" "$commit_message"
else
    printf "Synced pending local commits from '%s' to '%s/%s'.\n" "$repo_path" "$remote" "$branch"
fi
