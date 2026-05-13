[CmdletBinding()]
param(
    [string]$RepoPath = (Join-Path $PSScriptRoot '..\..'),
    [string]$Remote = 'origin',
    [string]$Branch,
    [string]$MessageTemplate = 'sync({date}): update from {computer} at {time}',
    [string]$DateFormat = 'yyyy-MM-dd',
    [string]$TimeFormat = 'HH:mm:ss'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $result = Invoke-GitResult -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $details = ($result.Output | Out-String).Trim()
        throw "git $($Arguments -join ' ') failed.`n$details"
    }

    return @($result.Output)
}

function Invoke-GitResult {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Test-RemoteTrackingRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteTrackingRef
    )

    $result = Invoke-GitResult -Arguments @('-C', $resolvedRepoPath, 'rev-parse', '--verify', '--quiet', $RemoteTrackingRef)
    if ($result.ExitCode -eq 0) {
        return $true
    }

    if ($result.ExitCode -eq 1) {
        return $false
    }

    $details = ($result.Output | Out-String).Trim()
    throw "git rev-parse --verify --quiet '$RemoteTrackingRef' failed while checking whether the remote branch exists.`n$details"
}

function Invoke-SafeRebase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteTrackingRef
    )

    $rebaseResult = Invoke-GitResult -Arguments @('-C', $resolvedRepoPath, 'rebase', $RemoteTrackingRef)
    if ($rebaseResult.ExitCode -eq 0) {
        return
    }

    $abortResult = Invoke-GitResult -Arguments @('-C', $resolvedRepoPath, 'rebase', '--abort')
    $rebaseDetails = ($rebaseResult.Output | Out-String).Trim()

    if ($abortResult.ExitCode -ne 0) {
        $abortDetails = ($abortResult.Output | Out-String).Trim()
        throw "git rebase '$RemoteTrackingRef' failed, and git rebase --abort also failed.`n$rebaseDetails`n$abortDetails"
    }

    throw "git rebase '$RemoteTrackingRef' failed. Rebase was aborted; resolve the divergence manually, then rerun sync.`n$rebaseDetails"
}

$resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$repoCheck = Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'rev-parse', '--is-inside-work-tree')
if (($repoCheck | Select-Object -Last 1).Trim() -ne 'true') {
    throw "Path '$resolvedRepoPath' is not a Git worktree."
}

if ([string]::IsNullOrWhiteSpace($Branch)) {
    $branchOutput = Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'branch', '--show-current')
    $Branch = (($branchOutput | Select-Object -Last 1) | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($Branch)) {
    throw 'Unable to determine the current branch. Pass -Branch explicitly.'
}

Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'fetch', '--prune', $Remote) | Out-Null
$remoteTrackingRef = "refs/remotes/$Remote/$Branch"
$remoteTrackingRefExists = Test-RemoteTrackingRef -RemoteTrackingRef $remoteTrackingRef

$statusOutput = Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'status', '--porcelain')
$hasWorkingTreeChanges = -not [string]::IsNullOrWhiteSpace(($statusOutput | Out-String))
$createdCommit = $false

if ($hasWorkingTreeChanges) {
    Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'add', '--all') | Out-Null

    & git -C $resolvedRepoPath diff --cached --quiet
    if ($LASTEXITCODE -eq 1) {
        $now = Get-Date
        $computerName = [System.Environment]::MachineName
        $commitMessage = $MessageTemplate.
            Replace('{date}', $now.ToString($DateFormat)).
            Replace('{time}', $now.ToString($TimeFormat)).
            Replace('{computer}', $computerName)

        if ([string]::IsNullOrWhiteSpace($commitMessage)) {
            throw 'Resolved commit message is empty.'
        }

        Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'commit', '-m', $commitMessage) | Out-Null
        $createdCommit = $true
    }
    elseif ($LASTEXITCODE -ne 0) {
        throw 'git diff --cached --quiet failed while checking staged changes.'
    }
}

$hasPendingLocalCommits = $false
if ($remoteTrackingRefExists) {
    $aheadOutput = Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'rev-list', '--count', "$remoteTrackingRef..HEAD")
    $aheadCountText = (($aheadOutput | Select-Object -Last 1) | Out-String).Trim()
    $aheadCount = 0
    if (-not [int]::TryParse($aheadCountText, [ref]$aheadCount)) {
        throw "Unable to parse local-ahead commit count '$aheadCountText'."
    }

    $hasPendingLocalCommits = $aheadCount -gt 0
}
elseif ($createdCommit) {
    $hasPendingLocalCommits = $true
}

if (-not $hasPendingLocalCommits) {
    if ($hasWorkingTreeChanges) {
        Write-Output 'No staged changes or pending local commits remain. Nothing to sync.'
    }
    else {
        Write-Output 'No changes detected. Nothing to sync.'
    }

    exit 0
}

if ($remoteTrackingRefExists) {
    Invoke-SafeRebase -RemoteTrackingRef $remoteTrackingRef
}

$pushResult = Invoke-GitResult -Arguments @('-C', $resolvedRepoPath, 'push', $Remote, $Branch)
if ($pushResult.ExitCode -ne 0) {
    $initialPushDetails = ($pushResult.Output | Out-String).Trim()

    Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'fetch', '--prune', $Remote) | Out-Null
    $remoteTrackingRefExists = Test-RemoteTrackingRef -RemoteTrackingRef $remoteTrackingRef

    if ($remoteTrackingRefExists) {
        Invoke-SafeRebase -RemoteTrackingRef $remoteTrackingRef
    }

    $retryPushResult = Invoke-GitResult -Arguments @('-C', $resolvedRepoPath, 'push', $Remote, $Branch)
    if ($retryPushResult.ExitCode -ne 0) {
        $retryPushDetails = ($retryPushResult.Output | Out-String).Trim()
        throw "git push '$Remote' '$Branch' failed, and the single safe retry after fetch/rebase also failed.`nInitial push:`n$initialPushDetails`nRetry push:`n$retryPushDetails"
    }
}

if ($createdCommit) {
    Write-Output "Synced '$resolvedRepoPath' to '$Remote/$Branch' with commit '$commitMessage'."
}
else {
    Write-Output "Synced pending local commits from '$resolvedRepoPath' to '$Remote/$Branch'."
}
