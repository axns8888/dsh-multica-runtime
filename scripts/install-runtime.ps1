#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName='Local')]
param(
    [Parameter(Mandatory,ParameterSetName='Local')][string]$Package,
    [Parameter(Mandatory,ParameterSetName='Local')][string]$Checksums,
    [Parameter(Mandatory,ParameterSetName='Release')][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(?:-axns\.[0-9]+)?$')][string]$ReleaseTag,
    [Parameter(Mandatory,ParameterSetName='Rollback')][ValidatePattern('^[a-f0-9]{32}$')][string]$Rollback,
    [string]$DshHome, [string]$DshCommand='dsh'
)
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/package-audit.ps1"
$homePath = Get-DshHome $DshHome
$profilePath = Join-Path $homePath 'profiles/multica'
$stateRoot = Join-Path $homePath '.axns-runtime'
Assert-Contained $profilePath $homePath
# Check roots, not pnpm's intentional links inside node_modules; original is moved intact.
foreach ($path in @($homePath, $stateRoot, (Join-Path $homePath 'profiles'), $profilePath)) {
    $cursor = $path
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing linked root: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
Protect-StateDirectory $stateRoot
Assert-NoLinkedAncestors (Join-Path $stateRoot 'operation.lock')
$lock = [IO.File]::Open((Join-Path $stateRoot 'operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$priorHome = $env:DSH_HOME
$priorStore = $env:npm_config_store_dir
$transaction = $null
try {
    $env:DSH_HOME = $homePath
    $env:npm_config_store_dir = Join-Path $stateRoot 'store'
    if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
        $transaction = Join-Path $stateRoot $Rollback
        Assert-Contained $transaction $stateRoot
        Assert-NoLinkedAncestors $transaction
        Assert-NoLinkedAncestors (Join-Path $transaction 'original')
        Assert-NoLinkedAncestors (Join-Path $transaction 'receipt.json')
        $receipt = Get-Content -LiteralPath (Join-Path $transaction 'receipt.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($receipt.home -cne $homePath -or $receipt.id -cne $Rollback -or $receipt.status -cne 'installed') { throw 'Rollback receipt does not match active installation' }
        $marker = Get-Content -LiteralPath (Join-Path $profilePath '.axns-install.json') -Raw | ConvertFrom-Json
        if ($marker.id -cne $Rollback) { throw 'A newer install is active; roll it back first' }
        $retired = Join-Path $transaction 'retired'
        Assert-Contained $retired $transaction
        $restored = $false
        Move-ProfileDirectory $profilePath $retired
        try {
            if ($receipt.originalExisted) { Move-ProfileDirectory (Join-Path $transaction 'original') $profilePath }
            $restored = $true
            $receipt.status = 'rolled_back'; Write-JsonFile $receipt (Join-Path $transaction 'receipt.json')
        } catch {
            $rollbackError = $_
            if (-not $restored) {
                $candidateRestored = $false
                try { Move-ProfileDirectory $retired $profilePath; $candidateRestored = $true } catch { }
                if ($candidateRestored) { throw $rollbackError }
            }
            $receipt.status='recovery_required'
            try { Write-JsonFile $receipt (Join-Path $transaction 'receipt.json') } catch { }
            throw "Rollback requires manual recovery. Close profile users; see docs/INSTALL.zh-CN.md recovery commands. Original: $(Join-Path $transaction 'original'); candidate: $retired; target: $profilePath; transaction: $Rollback"
        }
        [pscustomobject]@{status='rolled_back'; backupId=$Rollback; daemonRestarted=$false}
        return
    }
    if ($PSCmdlet.ParameterSetName -eq 'Release') {
        $download = Join-Path $stateRoot ('download-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $download | Out-Null
        # Fixed owner/repo. Explicit tag only; never follow latest or install automatically.
        $null = Invoke-Native 'gh' @('release','download',$ReleaseTag,'--repo','axns8888/dsh-multica-runtime','--pattern','*.tgz','--pattern','SHA256SUMS.txt','--dir',$download)
        $archives = @(Get-ChildItem -LiteralPath $download -Filter '*.tgz')
        if ($archives.Count -ne 1) { throw 'Release must contain exactly one runtime tgz' }
        $Package = $archives[0].FullName; $Checksums = Join-Path $download 'SHA256SUMS.txt'
    }
    $Package = (Resolve-Path -LiteralPath $Package).Path
    $Checksums = (Resolve-Path -LiteralPath $Checksums).Path
    $leaf = [IO.Path]::GetFileName($Package)
    $matchesForPackage = @()
    foreach ($line in (Get-Content -LiteralPath $Checksums)) {
        if ($line -match '^([a-fA-F0-9]{64}) [ *](.+)$' -and $Matches[2] -ceq $leaf) { $matchesForPackage += $Matches[1].ToLowerInvariant() }
    }
    if ($matchesForPackage.Count -ne 1) { throw 'Expected exactly one SHA256 entry for this archive' }
    $hash = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $matchesForPackage[0]) { throw 'SHA256 mismatch; profile was not changed' }
    $manifest = Test-RuntimePackage $Package
    if ($ReleaseTag -and $manifest.version -cne $ReleaseTag.Substring(1)) { throw 'Release tag and bundle version differ' }
    $id = [guid]::NewGuid().ToString('N')
    $transaction = Join-Path $stateRoot $id
    New-Item -ItemType Directory -Path $transaction | Out-Null
    # Install a private, verified copy, immune to replacement of the caller's tgz.
    $verifiedPackage = Join-Path $transaction $leaf
    Copy-Item -LiteralPath $Package -Destination $verifiedPackage
    if ((Get-FileHash -LiteralPath $verifiedPackage -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) { throw 'Archive changed during copy' }
    $original = Join-Path $transaction 'original'
    $existed = Test-Path -LiteralPath $profilePath
    $receipt = [ordered]@{ id=$id; home=$homePath; originalExisted=$existed; version=$manifest.version; sha256=$hash; status='prepared' }
    Write-JsonFile $receipt (Join-Path $transaction 'receipt.json')
    if ($existed) { Move-ProfileDirectory $profilePath $original }
    try {
        if ($existed) {
            New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
            foreach ($entry in Get-ChildItem -LiteralPath $original -Force) {
                if ($entry.Name -in @('node_modules','.axns-install.json')) { continue }
                Assert-NoLinks $entry.FullName
                Copy-Item -LiteralPath $entry.FullName -Destination $profilePath -Recurse -Force
            }
        }
        $null = Invoke-Native $DshCommand @('plugin','--profile','multica','add',$verifiedPackage,'--ignore-scripts') 600
        $verification = & "$PSScriptRoot/verify-runtime.ps1" -DshHome $homePath -DshCommand $DshCommand -ExpectedVersion $manifest.version
        Write-JsonFile @{id=$id;version=$manifest.version;sha256=$hash} (Join-Path $profilePath '.axns-install.json')
        $receipt.status='installed'; Write-JsonFile $receipt (Join-Path $transaction 'receipt.json')
        [pscustomobject]@{status='installed';version=$manifest.version;sha256=$hash;backupId=$id;verification=$verification;daemonRestarted=$false}
    } catch {
        $installError = $_
        # Recover in a separate try; report truthfully if external locks prevent a rename.
        try {
            if (Test-Path -LiteralPath $profilePath) { Move-ProfileDirectory $profilePath (Join-Path $transaction 'failed') }
            if ($existed) { Move-ProfileDirectory $original $profilePath }
            $receipt.status='failed_restored'; Write-JsonFile $receipt (Join-Path $transaction 'receipt.json')
        } catch {
            $receipt.status='recovery_required'
            try { Write-JsonFile $receipt (Join-Path $transaction 'receipt.json') } catch { }
            throw "Installation failed and restoration requires manual intervention. Original preserved at $original; transaction $id. Recovery error: $($_.Exception.Message)"
        }
        throw $installError
    }
} finally { $env:DSH_HOME = $priorHome; $env:npm_config_store_dir = $priorStore; $lock.Dispose() }
