[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\git-sync.config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$configDirectory = Split-Path -Parent $resolvedConfigPath
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json

$repoPath = [string]$config.repository.path
if ([string]::IsNullOrWhiteSpace($repoPath)) {
    $repoPath = '..'
}

$syncParams = @{
    RepoPath = Resolve-ConfiguredPath -ConfiguredPath $repoPath -ConfigDirectory $configDirectory
    Remote = if ([string]::IsNullOrWhiteSpace([string]$config.repository.remote)) { 'origin' } else { [string]$config.repository.remote }
    MessageTemplate = if ([string]::IsNullOrWhiteSpace([string]$config.commit.messageTemplate)) {
        'sync({date}): update from {computer} at {time}'
    }
    else {
        [string]$config.commit.messageTemplate
    }
}

$branch = [string]$config.repository.branch
if (-not [string]::IsNullOrWhiteSpace($branch)) {
    $syncParams.Branch = $branch
}

$syncScriptPath = Join-Path $PSScriptRoot 'sync.ps1'
if (-not (Test-Path -LiteralPath $syncScriptPath -PathType Leaf)) {
    throw "Sync script not found at '$syncScriptPath'."
}

& $syncScriptPath @syncParams
