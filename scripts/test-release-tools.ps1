#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$Checksums,[string]$ReportPath)
. "$PSScriptRoot/common.ps1"
$Package = (Resolve-Path -LiteralPath $Package).Path
$Checksums = (Resolve-Path -LiteralPath $Checksums).Path
$testRoot = Join-Path (Split-Path $PSScriptRoot -Parent) ('.local/tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$fake = Join-Path $PSScriptRoot 'tests/fake-dsh.ps1'
$results = [Collections.Generic.List[object]]::new()
function Assert-True($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add(@{name=$Name;status='passed'}); Write-Host "PASS $Name" }
    catch { $results.Add(@{name=$Name;status='failed';error=$_.Exception.Message}); throw }
}
function Must-Fail([scriptblock]$Body) {
    $failed=$false
    try { $null=& $Body } catch { $failed=$true }
    Assert-True $failed 'Operation unexpectedly passed'
}
$priorMode = $env:AXNS_FAKE_MODE
$priorVersion = $env:AXNS_FAKE_VERSION
. "$PSScriptRoot/package-audit.ps1"
$version = (Test-RuntimePackage $Package).version
$env:AXNS_FAKE_VERSION = $version
try {
    $testHome = Join-Path $testRoot 'home'
    Case 'valid JSONL probe/catalog' {
        $env:AXNS_FAKE_MODE='success'
        $r=& "$PSScriptRoot/verify-runtime.ps1" -DshHome $testHome -DshCommand $fake -ExpectedVersion $version
        Assert-True ($r.status -eq 'passed' -and $r.inference -eq 'not_verified') 'Bad verification result'
    }
    foreach ($mode in @('nonzero','invalid_json','no_output','protocol_error','wrong_version','duplicate_probe','empty_models','invalid_models','stdio_empty','stdio_invalid','stdio_nonzero')) {
        $env:AXNS_FAKE_MODE=$mode
        Case "reject $mode" { Must-Fail { & "$PSScriptRoot/verify-runtime.ps1" -DshHome $testHome -DshCommand $fake -ExpectedVersion $version } }
    }
    $profile = Join-Path $testHome 'profiles/multica'
    New-Item -ItemType Directory -Path $profile -Force | Out-Null
    'private original config' | Set-Content (Join-Path $profile 'preserve.txt')
    $before = (Get-FileHash (Join-Path $profile 'preserve.txt')).Hash
    Case 'SHA256 mismatch leaves profile intact' {
        $badSums = Join-Path $testRoot 'bad-SHA256SUMS.txt'
        (('0'*64) + '  ' + [IO.Path]::GetFileName($Package)) | Set-Content $badSums
        Must-Fail { & "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $badSums -DshHome $testHome -DshCommand $fake }
        Assert-True ((Get-FileHash (Join-Path $profile 'preserve.txt')).Hash -eq $before) 'Original was changed'
        Assert-True (-not (Test-Path (Join-Path $profile 'candidate.txt'))) 'Installer executed with bad hash'
    }
    foreach ($mode in @('install_failure','empty_models','invalid_json')) {
        $env:AXNS_FAKE_MODE=$mode
        Case "automatic restoration on $mode" {
            Must-Fail { & "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $Checksums -DshHome $testHome -DshCommand $fake }
            Assert-True ((Get-FileHash (Join-Path $profile 'preserve.txt')).Hash -eq $before) 'Original not restored'
            Assert-True (-not (Test-Path (Join-Path $profile 'candidate.txt'))) 'Failed candidate still active'
        }
    }
    $env:AXNS_FAKE_MODE='success'
    Case 'install + nested rollback preserves exact original' {
        $a=& "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $Checksums -DshHome $testHome -DshCommand $fake
        $b=& "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $Checksums -DshHome $testHome -DshCommand $fake
        Must-Fail { & "$PSScriptRoot/install-runtime.ps1" -Rollback $a.backupId -DshHome $testHome }
        $null=& "$PSScriptRoot/install-runtime.ps1" -Rollback $b.backupId -DshHome $testHome
        $null=& "$PSScriptRoot/install-runtime.ps1" -Rollback $a.backupId -DshHome $testHome
        Assert-True ((Get-FileHash (Join-Path $profile 'preserve.txt')).Hash -eq $before) 'Rollback lost configuration'
        Assert-True (-not (Test-Path (Join-Path $profile '.axns-install.json'))) 'Original not restored exactly'
    }
    Case 'failed rollback restores active candidate' {
        $r=& "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $Checksums -DshHome $testHome -DshCommand $fake
        $tx=Join-Path $testHome ".axns-runtime/$($r.backupId)"
        $hiddenOriginal=Join-Path $tx 'original-held-for-test'
        Move-ProfileDirectory (Join-Path $tx 'original') $hiddenOriginal
        Must-Fail { & "$PSScriptRoot/install-runtime.ps1" -Rollback $r.backupId -DshHome $testHome }
        Assert-True (Test-Path (Join-Path $profile '.axns-install.json')) 'Candidate was lost after failed rollback'
        $receipt=Get-Content (Join-Path $tx 'receipt.json') -Raw | ConvertFrom-Json
        Assert-True ($receipt.status -eq 'installed') 'Restored active installation lost its receipt state'
        Move-ProfileDirectory $hiddenOriginal (Join-Path $tx 'original')
        $null=& "$PSScriptRoot/install-runtime.ps1" -Rollback $r.backupId -DshHome $testHome
    }
    Case 'rollback of first install restores absence' {
        $emptyHome = Join-Path $testRoot 'empty-home'
        $r=& "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $Checksums -DshHome $emptyHome -DshCommand $fake
        $null=& "$PSScriptRoot/install-runtime.ps1" -Rollback $r.backupId -DshHome $emptyHome
        Assert-True (-not (Test-Path (Join-Path $emptyHome 'profiles/multica'))) 'Absent profile was not restored'
    }
    Case 'serialize concurrent maintenance operations' {
        $operationLock=[IO.File]::Open((Join-Path $testHome '.axns-runtime/operation.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Must-Fail { & "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $Checksums -DshHome $testHome -DshCommand $fake } }
        finally { $operationLock.Dispose() }
    }
    Case 'rollback path traversal rejected' { Must-Fail { & "$PSScriptRoot/install-runtime.ps1" -Rollback '../outside' -DshHome $testHome } }
    Case 'ambiguous checksum entry rejected' {
        $ambiguous = Join-Path $testRoot 'ambiguous-SHA256SUMS.txt'
        $line = ((Get-FileHash $Package).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($Package))
        @($line,$line) | Set-Content $ambiguous
        Must-Fail { & "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $ambiguous -DshHome $testHome -DshCommand $fake }
    }
    Case 'linked profile root rejected' {
        $linkedHome = Join-Path $testRoot 'linked-home'
        $linkTarget = Join-Path $testRoot 'link-target'
        New-Item -ItemType Directory -Path (Join-Path $linkedHome 'profiles'),$linkTarget -Force | Out-Null
        $link = Join-Path $linkedHome 'profiles/multica'
        if ($IsWindows) { New-Item -ItemType Junction -Path $link -Target $linkTarget | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $link -Target $linkTarget | Out-Null }
        Must-Fail { & "$PSScriptRoot/install-runtime.ps1" -Package $Package -Checksums $Checksums -DshHome $linkedHome -DshCommand $fake }
        Assert-True (@(Get-ChildItem -LiteralPath $linkTarget -Force).Count -eq 0) 'Linked target was modified'
    }
    Case 'native child timeout is a failure' {
        Must-Fail { Invoke-Native 'pwsh' @('-NoProfile','-Command','Start-Sleep -Seconds 5') 1 }
    }
    Case 'atomic profile move refuses existing directory' {
        $a = Join-Path $testRoot 'move-a'; $b = Join-Path $testRoot 'move-b'
        New-Item -ItemType Directory -Path $a,$b | Out-Null
        Must-Fail { Move-ProfileDirectory $a $b }
        Assert-True (Test-Path -LiteralPath $a) 'Source moved into existing destination'
    }
    Case 'reject duplicate archive member' {
        $duplicateRoot = Join-Path $testRoot 'duplicate'
        New-Item -ItemType Directory -Path (Join-Path $duplicateRoot 'package') -Force | Out-Null
        $names=@('package.json','README.md','UPSTREAM.md','COMPATIBILITY.md','cordis.patch.yml')
        foreach ($n in $names) { 'fixture' | Set-Content (Join-Path $duplicateRoot "package/$n") }
        $duplicateTar=Join-Path $testRoot 'duplicate.tgz'
        $members=@($names | ForEach-Object { "package/$_" }) + @('package/package.json')
        $null=Invoke-Native 'tar' (@('-czf',$duplicateTar,'-C',$duplicateRoot) + $members)
        $message=''
        try { $null=Test-RuntimePackage $duplicateTar } catch { $message=$_.Exception.Message }
        Assert-True ($message -like 'Duplicate archive member:*') 'Duplicate path not specifically rejected'
    }
    Case 'reject unexpected credential file in tar' {
        $malicious = Join-Path $testRoot 'malicious'
        New-Item -ItemType Directory -Path (Join-Path $malicious 'package') -Force | Out-Null
        foreach ($n in @('package.json','index.js','README.md','cordis.patch.yml','.env')) { 'fixture' | Set-Content (Join-Path $malicious "package/$n") }
        $badTar=Join-Path $testRoot 'malicious.tgz'
        $null=Invoke-Native 'tar' @('-czf',$badTar,'-C',$malicious,'package')
        . "$PSScriptRoot/package-audit.ps1"
        Must-Fail { Test-RuntimePackage $badTar }
    }
    [pscustomobject]@{status='passed';testCount=$results.Count}
} finally {
    $env:AXNS_FAKE_MODE=$priorMode
    $env:AXNS_FAKE_VERSION=$priorVersion
    if ($ReportPath) { Write-JsonFile @($results.ToArray()) $ReportPath }
}
