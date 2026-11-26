#requires -Version 7.4
[CmdletBinding()]
param([string]$ToolDirectory)
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/pnpm-toolchain.ps1"
$root = Split-Path $PSScriptRoot -Parent
$tools = Get-Content (Join-Path $root 'release-toolchain.json') -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ToolDirectory)) {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $ToolDirectory = Join-Path $base "axns-pnpm-$($tools.pnpm)"
}
$ToolDirectory = [IO.Path]::GetFullPath($ToolDirectory)
New-Item -ItemType Directory -Path $ToolDirectory -Force | Out-Null
$npm = (Get-Command npm -ErrorAction Stop).Source
Write-Host "Installing pnpm $($tools.pnpm) using npm entry: $npm"
$installOutput = Invoke-Native $npm @('install','--prefix',$ToolDirectory,'--no-save','--ignore-scripts','--no-audit','--no-fund',"pnpm@$($tools.pnpm)") 300
if ($installOutput.Trim()) { Write-Host $installOutput.TrimEnd() }
$entry = Join-Path $ToolDirectory 'node_modules/pnpm/bin/pnpm.mjs'
$node = (Get-Command node -ErrorAction Stop).Source
$null = Resolve-PnpmToolchain -ExpectedVersion $tools.pnpm -PnpmEntry $entry -NodeEntry $node
Write-Output $entry
