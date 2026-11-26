#requires -Version 7.4
[CmdletBinding()]
param([string]$DshHome, [string]$DshCommand = 'dsh', [string]$ExpectedVersion,
      [string]$ReportPath, [int]$TimeoutSeconds = 90)
. "$PSScriptRoot/common.ps1"
$previousHome = $env:DSH_HOME
try {
    $env:DSH_HOME = Get-DshHome $DshHome
    $probeOutput = Invoke-Native $DshCommand @('--profile','multica','--probe') $TimeoutSeconds
    $modelsOutput = Invoke-Native $DshCommand @('--profile','multica','--list-models') $TimeoutSeconds
    function Read-Frames([string]$Text) {
        $frames = @()
        foreach ($line in ($Text -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $frame = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop }
            catch { throw 'Non-JSONL output on runtime stdout' }
            if ($frame -isnot [System.Collections.IDictionary] -or $frame.v -ne 1 -or $frame.type -in @('protocol_error','error')) { throw 'Invalid or error protocol frame' }
            $frames += ,$frame
        }
        return ,$frames
    }
    $probes = Read-Frames $probeOutput
    if ($probes.Count -ne 1 -or $probes[0].type -cne 'probe' -or $probes[0].runtime -cne 'dsh' -or $probes[0].protocol_version -ne 1 -or [string]::IsNullOrWhiteSpace($probes[0].plugin_version)) { throw 'Missing/invalid protocol v1 probe' }
    if ($ExpectedVersion -and $probes[0].plugin_version -cne $ExpectedVersion) { throw 'Installed plugin version does not match requested version' }
    $catalog = Read-Frames $modelsOutput
    if ($catalog.Count -ne 1 -or $catalog[0].type -cne 'models' -or $catalog[0].models -isnot [array] -or $catalog[0].models.Count -eq 0) { throw 'Missing or empty model catalog' }
    foreach ($model in $catalog[0].models) {
        foreach ($key in @('id','provider','label')) {
            if ($model[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($model[$key])) { throw "Invalid model field: $key" }
        }
    }
    $report = [ordered]@{ status = 'passed'; probe = 'passed'; protocol = 1; pluginVersion = $probes[0].plugin_version; modelCatalog = 'passed'; modelCount = $catalog[0].models.Count; inference = 'not_verified'; daemonActivation = 'not_verified'; cancellation = 'not_verified'; resume = 'not_verified'; toolResult = 'not_verified' }
    if ($ReportPath) { Write-JsonFile $report $ReportPath }
    [pscustomobject]$report
} catch {
    if ($ReportPath) { Write-JsonFile @{ status='failed'; probeAndCatalog='failed'; inference='not_verified' } $ReportPath }
    throw
} finally { $env:DSH_HOME = $previousHome }
