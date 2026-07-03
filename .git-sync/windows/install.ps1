[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\git-sync.config.json'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-TaskArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return '"' + ($Value -replace '"', '\"') + '"'
}

# Backwards-compatible wrapper for the old (unapproved) verb name
function Quote-TaskArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return (Format-TaskArgument -Value $Value)
}

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfiguredPath,
        [Parameter(Mandatory = $true)]
        [string]$ConfigDirectory
    )

    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        return (Resolve-Path -LiteralPath $ConfiguredPath).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $ConfigDirectory $ConfiguredPath)).Path
}

function Get-DailyTriggerTime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DailyTime
    )

    if ($DailyTime -notmatch '^(?<hour>[01]\d|2[0-3]):(?<minute>[0-5]\d)$') {
        throw "schedule.dailyTime must use HH:mm 24-hour format. Received '$DailyTime'."
    }

    return (Get-Date).Date.
        AddHours([int]$Matches.hour).
        AddMinutes([int]$Matches.minute)
}

function Ensure-GitIgnoreEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $gitIgnorePath = Join-Path $RepositoryPath '.gitignore'
    $ignoreLine = '/.git-sync/'
    $commentLine = '# Local Git sync toolkit'
    $existingLines = @(
        if (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) {
            Get-Content -LiteralPath $gitIgnorePath
        }
    )

    $ignoreLineIndex = -1
    for ($index = 0; $index -lt $existingLines.Count; $index++) {
        $trimmed = $existingLines[$index].Trim()
        if ($trimmed -in @('/.git-sync/', '.git-sync/', '/.git-sync', '.git-sync')) {
            $ignoreLineIndex = $index
            break
        }
    }

    if ($ignoreLineIndex -ge 0) {
        $previousLine = if ($ignoreLineIndex -gt 0) { $existingLines[$ignoreLineIndex - 1].Trim() } else { '' }
        if ($previousLine -eq $commentLine) {
            return $false
        }

        $updatedLines = @()
        if ($ignoreLineIndex -gt 0) {
            $updatedLines += $existingLines[0..($ignoreLineIndex - 1)]
        }
        $updatedLines += $commentLine
        $updatedLines += $existingLines[$ignoreLineIndex..($existingLines.Count - 1)]
        Set-Content -LiteralPath $gitIgnorePath -Value $updatedLines
        return $true
    }

    $linesToAppend = @()
    if ($existingLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($existingLines[-1])) {
        $linesToAppend += ''
    }

    $linesToAppend += $commentLine
    $linesToAppend += $ignoreLine

    if (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) {
        Add-Content -LiteralPath $gitIgnorePath -Value $linesToAppend
    }
    else {
        Set-Content -LiteralPath $gitIgnorePath -Value $linesToAppend
    }

    return $true
}

function Test-ScheduledTaskUsesOurToolkit {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Task,
        [Parameter(Mandatory = $true)]
        [string[]]$ToolkitPaths
    )

    foreach ($taskAction in @($Task.Actions)) {
        $arguments = [string]$taskAction.Arguments
        foreach ($signaturePath in $ToolkitPaths) {
            if ($arguments.IndexOf($signaturePath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }

    return $false
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$configDirectory = Split-Path -Parent $resolvedConfigPath
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json

$repoPath = [string]$config.repository.path
if ([string]::IsNullOrWhiteSpace($repoPath)) {
    $repoPath = '..'
}

$resolvedRepoPath = Resolve-ConfiguredPath -ConfiguredPath $repoPath -ConfigDirectory $configDirectory
$repoName = Split-Path -Leaf $resolvedRepoPath

$taskName = [string]$config.windows.taskName
if ([string]::IsNullOrWhiteSpace($taskName)) {
    $taskName = "Git Sync - $repoName"
}

$scheduleMode = ([string]$config.schedule.mode).Trim().ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($scheduleMode)) {
    $scheduleMode = 'interval'
}

$triggers = @()
switch ($scheduleMode) {
    'interval' {
        $intervalMinutes = [int]$config.schedule.intervalMinutes
        if ($intervalMinutes -lt 1) {
            throw 'schedule.intervalMinutes must be at least 1.'
        }

        $triggers += New-ScheduledTaskTrigger `
            -Once `
            -At ((Get-Date).AddMinutes(1)) `
            -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
    }
    'daily' {
        $dailyTime = [string]$config.schedule.dailyTime
        $triggers += New-ScheduledTaskTrigger `
            -Daily `
            -At (Get-DailyTriggerTime -DailyTime $dailyTime)
    }
    default {
        throw "Unsupported schedule.mode '$scheduleMode'. Use 'interval' or 'daily'."
    }
}

$startupEnabled = [bool]$config.startup.enabled

$configuredSyncScriptPath = Join-Path $PSScriptRoot 'run.ps1'
if (-not (Test-Path -LiteralPath $configuredSyncScriptPath -PathType Leaf)) {
    throw "Configured sync script not found at '$configuredSyncScriptPath'."
}

$pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -ne $pwshCommand) {
    $powerShellPath = $pwshCommand.Source
}
else {
    $windowsPowerShellCommand = Get-Command powershell -ErrorAction Stop
    $powerShellPath = $windowsPowerShellCommand.Source
}

# Build the PowerShell command that performs the sync. We embed it into a VBScript
# launcher (run-hidden.vbs) below: wscript.exe is a GUI-subsystem binary, so it
# creates no console at all, and WshShell.Run(..., 0) launches the child hidden.
# Putting -WindowStyle Hidden directly in the task still flashes a window on each
# run, because the console is created before PowerShell can hide it.
$psInnerArguments = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    (Quote-TaskArgument -Value $configuredSyncScriptPath),
    '-ConfigPath',
    (Quote-TaskArgument -Value $resolvedConfigPath)
) -join ' '
$psCommand = (Quote-TaskArgument -Value $powerShellPath) + ' ' + $psInnerArguments

$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$vbsPath = Join-Path $PSScriptRoot 'run-hidden.vbs'
# VBS escapes a literal double-quote by doubling it.
$vbsCommandLiteral = $psCommand -replace '"', '""'

$vbsTemplate = @'
Option Explicit
' Auto-generated by install.ps1. Launches the Git sync with no visible window.
Dim WshShell
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "__COMMAND__", 0, False
'@
$vbsContent = $vbsTemplate.Replace('__COMMAND__', $vbsCommandLiteral)
# ASCII keeps the launcher BOM-free and readable on every Windows version; the
# embedded paths must therefore be ASCII (true for this repository).
Set-Content -LiteralPath $vbsPath -Value $vbsContent -Encoding ASCII

$action = New-ScheduledTaskAction `
    -Execute $wscriptPath `
    -Argument (Quote-TaskArgument -Value $vbsPath) `
    -WorkingDirectory $resolvedRepoPath

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

$registerParams = @{
    TaskName = $taskName
    Action = $action
    Trigger = $triggers
    Settings = $settings
    Description = "Automatically commit and push repository updates from '$resolvedRepoPath'."
    ErrorAction = 'Stop'
}

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskAlreadyExisted = $null -ne $existingTask
if ($taskAlreadyExisted -and -not $Force -and -not (Test-ScheduledTaskUsesOurToolkit -Task $existingTask -ToolkitPaths @($resolvedConfigPath, $vbsPath))) {
    throw "Scheduled task '$taskName' already exists and does not appear to be managed by this toolkit (expected a reference to '$resolvedConfigPath' or '$vbsPath'). Re-run with -Force to replace it, or set windows.taskName in '$resolvedConfigPath' to a unique name."
}

if ($Force -or $taskAlreadyExisted) {
    $registerParams.Force = $true
}

Register-ScheduledTask @registerParams | Out-Null
$taskOperation = if ($taskAlreadyExisted) { 'updated' } else { 'registered' }

$startupRunValueName = [string]$config.windows.startupRunValueName
if ([string]::IsNullOrWhiteSpace($startupRunValueName)) {
    $startupRunValueName = "GitSync-$repoName"
}

$startupRunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupCommand = (Quote-TaskArgument -Value $wscriptPath) + ' ' + (Quote-TaskArgument -Value $vbsPath)
if ($startupCommand.Length -gt 260) {
    throw "Windows startup command length is $($startupCommand.Length), which exceeds the Run key limit of 260 characters."
}

if ($startupEnabled) {
    New-Item -Path $startupRunKeyPath -Force | Out-Null
    Set-ItemProperty -Path $startupRunKeyPath -Name $startupRunValueName -Value $startupCommand
}
else {
    Remove-ItemProperty -Path $startupRunKeyPath -Name $startupRunValueName -ErrorAction SilentlyContinue
}

$gitIgnoreUpdated = Ensure-GitIgnoreEntry -RepositoryPath $resolvedRepoPath

$scheduleSummary = switch ($scheduleMode) {
    'interval' { "every $intervalMinutes minute(s)" }
    'daily' { "daily at $dailyTime" }
}

Write-Output "Scheduled task '$taskName' $taskOperation from '$resolvedConfigPath' to run $scheduleSummary. User startup autorun enabled: $startupEnabled. .gitignore updated: $gitIgnoreUpdated. Hidden launcher written to '$vbsPath'."
