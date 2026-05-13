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

    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | Out-String).Trim()
        throw "git $($Arguments -join ' ') failed.`n$details"
    }

    return @($output)
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

$statusOutput = Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'status', '--porcelain')
if ([string]::IsNullOrWhiteSpace(($statusOutput | Out-String))) {
    Write-Output 'No changes detected. Nothing to sync.'
    exit 0
}

Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'add', '--all') | Out-Null

& git -C $resolvedRepoPath diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Output 'No staged changes remain after git add. Nothing to sync.'
    exit 0
}

if ($LASTEXITCODE -ne 1) {
    throw 'git diff --cached --quiet failed while checking staged changes.'
}

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
Invoke-Git -Arguments @('-C', $resolvedRepoPath, 'push', $Remote, $Branch) | Out-Null

Write-Output "Synced '$resolvedRepoPath' to '$Remote/$Branch' with commit '$commitMessage'."
