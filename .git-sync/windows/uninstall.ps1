[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\git-sync.config.json'),
    [string]$TaskName,
    [switch]$IgnoreMissing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$configDirectory = Split-Path -Parent $resolvedConfigPath
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json

$repoPath = [string]$config.repository.path
if ([string]::IsNullOrWhiteSpace($repoPath)) {
    $repoPath = '..'
}

$resolvedRepoPath = if ([System.IO.Path]::IsPathRooted($repoPath)) {
    (Resolve-Path -LiteralPath $repoPath).Path
}
else {
    (Resolve-Path -LiteralPath (Join-Path $configDirectory $repoPath)).Path
}

$repoName = Split-Path -Leaf $resolvedRepoPath
if ([string]::IsNullOrWhiteSpace($TaskName)) {
    $TaskName = [string]$config.windows.taskName
}

if ([string]::IsNullOrWhiteSpace($TaskName)) {
    $TaskName = "Git Sync - $repoName"
}

$startupRunValueName = [string]$config.windows.startupRunValueName
if ([string]::IsNullOrWhiteSpace($startupRunValueName)) {
    $startupRunValueName = "GitSync-$repoName"
}

$startupRunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Remove-ItemProperty -Path $startupRunKeyPath -Name $startupRunValueName -ErrorAction SilentlyContinue

$hiddenLauncherPath = Join-Path $PSScriptRoot 'run-hidden.vbs'
if (Test-Path -LiteralPath $hiddenLauncherPath -PathType Leaf) {
    Remove-Item -LiteralPath $hiddenLauncherPath -Force
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    if ($IgnoreMissing) {
        Write-Output "Scheduled task '$TaskName' does not exist. Startup autorun '$startupRunValueName' and the hidden launcher have been removed if present."
        exit 0
    }

    throw "Scheduled task '$TaskName' was not found. Startup autorun '$startupRunValueName' and the hidden launcher have been removed if present."
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Output "Scheduled task '$TaskName', startup autorun '$startupRunValueName', and the hidden launcher have been removed."
