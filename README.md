# Automatic Git Sync

This folder is designed to be copied into the root of any Git repository as `.git-sync/`.

After copying it:

- Windows uses `.git-sync/windows/install.ps1` and `.git-sync/windows/uninstall.ps1`.
- Linux uses `.git-sync/linux/install.sh` and `.git-sync/linux/uninstall.sh`.
- Shared behavior is configured in `.git-sync/git-sync.config.json`.

## Portability

The toolkit is portable across repositories because:

- `repository.path` defaults to `..`, which points from `.git-sync/git-sync.config.json` back to the repository root.
- The remote defaults to `origin`.
- The branch defaults to the currently checked-out branch.
- Windows scheduled task names and autorun value names default from the repository folder name when omitted.
- Linux cron markers default from the repository folder name when omitted.

This means copying `.git-sync/` into another repository is usually enough. Adjust the JSON only when you want a different remote, branch, schedule, message format, or explicit task names.

After a successful install, the installer also ensures the repository root `.gitignore` contains:

```gitignore
# Local Git sync toolkit
/.git-sync/
```

If an equivalent `.git-sync` ignore rule already exists, it is left unchanged.

## Limits

- The target repository must already be a valid Git worktree.
- Scheduled pushes require non-interactive Git credentials to work.
- Before pushing, the scripts fetch the selected remote and rebase onto the matching remote-tracking branch when local commits need to be uploaded.
- The scripts never auto-merge or force-push. If rebase hits a conflict, it is aborted and surfaced for manual resolution.
- A clean worktree no longer hides earlier failed uploads: if local commits are still ahead of the remote-tracking branch, they are pushed on the next run.
- If a push races with another device and gets rejected, the scripts fetch, rebase once more when applicable, and retry that push exactly once.
- If two repositories share the same folder name on one machine, set explicit Windows task names and Linux cron markers in the JSON to avoid collisions.
- Windows user autorun is stored in the `Run` registry key. Extremely deep filesystem paths can exceed the registry command length limit and will be rejected during install.

## Configuration

Edit `.git-sync/git-sync.config.json` before installation.

```json
{
  "repository": {
    "path": "..",
    "remote": "origin",
    "branch": ""
  },
  "commit": {
    "messageTemplate": "sync({date}): update from {computer} at {time}"
  },
  "schedule": {
    "mode": "interval",
    "intervalMinutes": 30,
    "dailyTime": "08:30"
  },
  "startup": {
    "enabled": true
  },
  "windows": {
    "taskName": "",
    "startupRunValueName": ""
  },
  "linux": {
    "cronMarker": ""
  }
}
```

Scheduling rules:

- `"mode": "interval"` uses `intervalMinutes`.
- `"mode": "daily"` uses `dailyTime` in `HH:mm` local time.
- `"startup.enabled": true` adds Windows user logon autorun plus Linux `@reboot`.

Commit message placeholders:

- `{date}`
- `{time}`
- `{computer}`

Example generated commit:

```text
sync(2026-05-13): update from WORKSTATION-01 at 14:30:00
```

## Windows

Manual run from the repository root:

```powershell
pwsh -NoProfile -File .\.git-sync\windows\run.ps1
```

Install or update the scheduled task and autorun entry:

```powershell
pwsh -NoProfile -File .\.git-sync\windows\install.ps1 -Force
```

Uninstall the scheduled task and autorun entry:

```powershell
pwsh -NoProfile -File .\.git-sync\windows\uninstall.ps1
```

If the task may already be absent:

```powershell
pwsh -NoProfile -File .\.git-sync\windows\uninstall.ps1 -IgnoreMissing
```

## Linux

Manual run from the repository root:

```bash
bash ./.git-sync/linux/sync.sh
```

Install or update the managed cron entries:

```bash
bash ./.git-sync/linux/install.sh
```

Uninstall only the managed cron entries:

```bash
bash ./.git-sync/linux/uninstall.sh
```

Custom config path:

```bash
bash ./.git-sync/linux/install.sh \
  --config ./.git-sync/git-sync.config.json
```

## Behavior

Both sync implementations:

- Detect repository changes.
- Run `git add --all`.
- Create a commit only when staged changes exist.
- Fetch the selected remote and detect whether the local branch still has commits that need to be uploaded.
- Rebase on the matching remote-tracking branch when local commits need to be uploaded and that branch exists.
- Push to the selected remote and branch.
- Retry one rejected push after one more fetch/rebase cycle.
- Exit cleanly when there is nothing to sync.
