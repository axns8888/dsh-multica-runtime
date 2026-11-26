#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$Checksums,[string]$ReportPath)
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/pnpm-toolchain.ps1"
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
    Case 'pinned pnpm entry bypasses PATH shadow and is reused for all commands' {
        $shadowDir = Join-Path $testRoot 'shadow'
        New-Item -ItemType Directory -Path $shadowDir -Force | Out-Null
        if ($IsWindows) {
            $shadowEntry = Join-Path $shadowDir 'pnpm.ps1'
            Set-Content -LiteralPath $shadowEntry -Value "Write-Output '6.0.0'" -Encoding utf8NoBOM
        } else {
            $shadowEntry = Join-Path $shadowDir 'pnpm'
            Set-Content -LiteralPath $shadowEntry -Value @('#!/usr/bin/env pwsh', "Write-Output '6.0.0'") -Encoding utf8NoBOM
            [IO.File]::SetUnixFileMode($shadowEntry, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        $fakePnpmDir = Join-Path $testRoot 'fake-pnpm/node_modules/pnpm/bin'
        New-Item -ItemType Directory -Path $fakePnpmDir -Force | Out-Null
        $fakeEntry = Join-Path $fakePnpmDir 'pnpm.cjs'
        $fakeSource = @("const fs = require('node:fs');",'const args = process.argv.slice(2);',"if (args[0] === '--version') console.log(process.env.AXNS_FAKE_PNPM_VERSION || '12.5.1');", "else fs.appendFileSync(process.env.AXNS_FAKE_PNPM_LOG, args[0] + '\n');")
        Set-Content -LiteralPath $fakeEntry -Value $fakeSource -Encoding utf8NoBOM
        $oldPath=$env:PATH; $oldLog=$env:AXNS_FAKE_PNPM_LOG; $oldVersion=$env:AXNS_FAKE_PNPM_VERSION
        try {
            $env:PATH = "$shadowDir$([IO.Path]::PathSeparator)$oldPath"
            $shadowCommand = Get-Command pnpm -ErrorAction Stop
            Assert-True ([IO.Path]::GetFullPath($shadowCommand.Source) -eq [IO.Path]::GetFullPath($shadowEntry)) 'The intentionally wrong PATH pnpm was not selected first'
            $env:AXNS_FAKE_PNPM_LOG = Join-Path $testRoot 'pnpm-calls.txt'
            $env:AXNS_FAKE_PNPM_VERSION = '12.5.1'
            $tool=Resolve-PnpmToolchain -ExpectedVersion '12.5.1' -PnpmEntry $fakeEntry
            foreach($command in @('install','typecheck','test','build','pack')) { $null=Invoke-PinnedPnpm $tool @($command) }
            $calls=@(Get-Content $env:AXNS_FAKE_PNPM_LOG)
            Assert-True ($calls -join ',' -eq 'install,typecheck,test,build,pack') 'Not all lifecycle commands used the fixed pnpm entry'
            Assert-True ($tool.Entry -eq [IO.Path]::GetFullPath($fakeEntry)) 'The selected entry was not the explicit absolute path'
        } finally { $env:PATH=$oldPath; $env:AXNS_FAKE_PNPM_LOG=$oldLog; $env:AXNS_FAKE_PNPM_VERSION=$oldVersion }
    }
    Case 'wrong explicit pnpm version is rejected before project commands' {
        $fakeEntry=Join-Path $testRoot 'fake-pnpm/node_modules/pnpm/bin/pnpm.cjs'
        $oldVersion=$env:AXNS_FAKE_PNPM_VERSION; $oldLog=$env:AXNS_FAKE_PNPM_LOG
        $env:AXNS_FAKE_PNPM_VERSION='9.9.9'
        $env:AXNS_FAKE_PNPM_LOG=Join-Path $testRoot 'wrong-pnpm-calls.txt'
        $message=''
        try { $null=Resolve-PnpmToolchain -ExpectedVersion '12.5.1' -PnpmEntry $fakeEntry } catch { $message=$_.Exception.Message }
        Assert-True ($message -like "*expected '12.5.1'*actual stdout '9.9.9'*selected entry '$([IO.Path]::GetFullPath($fakeEntry))'*") 'Version error omitted expected/actual/entry diagnostics'
        Assert-True (-not (Test-Path $env:AXNS_FAKE_PNPM_LOG)) 'A dependency operation ran after version rejection'
        $env:AXNS_FAKE_PNPM_VERSION=$oldVersion; $env:AXNS_FAKE_PNPM_LOG=$oldLog
    }
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
    Case 'empty catalog explains credential setup and keeps verification failed' {
        $env:AXNS_FAKE_MODE='empty_models'
        $reportPath=Join-Path $testRoot 'empty-model-report.json'
        $message=''
        try { $null=& "$PSScriptRoot/verify-runtime.ps1" -DshHome $testHome -DshCommand $fake -ExpectedVersion $version -ReportPath $reportPath }
        catch { $message=$_.Exception.Message }
        Assert-True ($message -like '*Missing or empty model catalog*daemon account*DSH_HOME*docs/MULTI-MACHINE.zh-CN.md*') 'Missing first-install credential guidance'
        $report=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        Assert-True ($report.status -eq 'failed' -and $report.probe -eq 'passed' -and $report.modelCatalog -eq 'failed' -and $report.stdioHandshake -eq 'not_run') 'Catalog rejection was reported as success or continued to stdio'
        Assert-True ($report.inference -eq 'not_verified') 'Inference was incorrectly verified'
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
    Case 'missing Release fails without replacing existing profile' {
        $shadow=Join-Path $testRoot 'no-release-bin'
        New-Item -ItemType Directory -Path $shadow -Force | Out-Null
        '[Console]::Error.WriteLine("release not found (offline fixture)"); exit 1' | Set-Content (Join-Path $shadow 'gh.ps1') -Encoding utf8NoBOM
        $oldPath=$env:PATH
        $message=''
        try {
            $env:PATH=$shadow + [IO.Path]::PathSeparator + $oldPath
            $null=& "$PSScriptRoot/install-runtime.ps1" -ReleaseTag 'v0.2.0-axns.999999' -DshHome $testHome -DshCommand $fake
        } catch { $message=$_.Exception.Message }
        finally { $env:PATH=$oldPath }
        Assert-True ($message -like '*release not found (offline fixture)*') 'Missing Release did not fail with its actual download error'
        Assert-True ((Get-FileHash (Join-Path $profile 'preserve.txt')).Hash -eq $before) 'Missing Release changed original profile'
        Assert-True (-not (Test-Path (Join-Path $profile 'candidate.txt'))) 'Missing Release started an install'
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
