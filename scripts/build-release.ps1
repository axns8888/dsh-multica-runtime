#requires -Version 7.4
[CmdletBinding()]
param([string]$OutputDirectory)
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/package-audit.ps1"
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $tools = Get-Content release-toolchain.json -Raw | ConvertFrom-Json
    if ((Invoke-Native 'node' @('--version')).Trim() -cne "v$($tools.node)") { throw 'Node version differs from release-toolchain.json' }
    if ((Invoke-Native 'pnpm' @('--version')).Trim() -cne $tools.pnpm) { throw 'pnpm version differs from release-toolchain.json' }
    if ((Invoke-Native 'git' @('status','--porcelain')).Trim()) { throw 'Commit source changes before building a release' }
    $source = (Invoke-Native 'git' @('rev-parse','HEAD')).Trim()
    $null = Invoke-Native 'git' @('merge-base','--is-ancestor',$tools.upstream,'HEAD')
    $pkg = Get-Content package.json -Raw | ConvertFrom-Json
    $sourceText = Get-Content src/index.ts -Raw
    if (-not $sourceText.Contains("const PLUGIN_VERSION = '$($pkg.version)'")) { throw 'Source/manifest version mismatch' }
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root "artifacts/$($pkg.version)" }
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    if ((Test-Path -LiteralPath $OutputDirectory) -and @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw 'Output directory must be empty' }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $lockHash = (Get-FileHash pnpm-lock.yaml -Algorithm SHA256).Hash.ToLowerInvariant()
    $checks = @()
    foreach ($item in @(
        @{args=@('install','--frozen-lockfile','--ignore-scripts','--store-dir', (Join-Path $root '.local/pnpm-store'),'--state-dir',(Join-Path $root '.local/pnpm-state'));name='frozen install'},
        @{args=@('typecheck');name='typecheck'},
        @{args=@('test');name='tests'},
        @{args=@('build');name='build'}
    )) {
        Write-Host "Running $($item.name)"
        Write-Host (Invoke-Native 'pnpm' $item.args 600)
        $checks += @{command=('pnpm ' + ($item.args -join ' '));status='passed'}
    }
    # Purge stale compiler outputs before the final compile. Restrict removal to repo/dist.
    $dist = Join-Path $root 'dist'
    Assert-Contained $dist $root
    Assert-NoLinks $dist
    if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
    $null = Invoke-Native 'pnpm' @('build') 600
    $null = Invoke-Native 'pnpm' @('pack','--pack-destination',$OutputDirectory) 180
    $archives = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.tgz')
    if ($archives.Count -ne 1) { throw 'Expected one packed archive' }
    $archive = $archives[0]
    $null = Test-RuntimePackage $archive.FullName
    $checks += @{command='pnpm pack; tar content/identity audit';status='passed'}
    if ((Get-FileHash pnpm-lock.yaml -Algorithm SHA256).Hash.ToLowerInvariant() -cne $lockHash) { throw 'Lockfile changed during build' }
    if ((Invoke-Native 'git' @('status','--porcelain')).Trim()) { throw 'Source tree changed during build' }
    $hash = (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $info = [ordered]@{schemaVersion=1;sourceSha=$source;upstreamSha=$tools.upstream;version=$pkg.version;package=$pkg.name;node=$tools.node;pnpm=$tools.pnpm;lockfileSha256=$lockHash;platform=[Runtime.InteropServices.RuntimeInformation]::OSDescription;commands=$checks;packageAudit='passed';archive=$archive.Name;sha256=$hash;inference='not_verified'}
    $infoPath = Join-Path $OutputDirectory 'build-info.json'
    Write-JsonFile $info $infoPath
    @("$hash  $($archive.Name)", "$((Get-FileHash -LiteralPath $infoPath -Algorithm SHA256).Hash.ToLowerInvariant())  build-info.json") | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding utf8NoBOM
    [pscustomobject]@{archive=$archive.FullName;sha256=$hash;sourceSha=$source;status='passed'}
} finally { Pop-Location }
