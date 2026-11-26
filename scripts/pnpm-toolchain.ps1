function Resolve-PnpmToolchain([string]$ExpectedVersion, [string]$PnpmEntry, [string]$NodeEntry) {
    if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) { throw 'Expected pnpm version is required' }
    if ([string]::IsNullOrWhiteSpace($NodeEntry)) { $NodeEntry = (Get-Command node -ErrorAction Stop).Source }
    $NodeEntry = [IO.Path]::GetFullPath($NodeEntry)
    $candidates = @(Get-Command pnpm -All -ErrorAction SilentlyContinue)
    Write-Host "Expected pnpm version: $ExpectedVersion"
    if ($candidates.Count -eq 0) { Write-Host 'Get-Command pnpm -All: <no PATH candidates>' }
    foreach ($candidate in $candidates) {
        Write-Host "pnpm candidate: CommandType=$($candidate.CommandType); Source=$($candidate.Source); Name=$($candidate.Name)"
    }

    if ([string]::IsNullOrWhiteSpace($PnpmEntry)) { $PnpmEntry = $env:AXNS_PNPM_ENTRY }
    if ([string]::IsNullOrWhiteSpace($PnpmEntry)) {
        if ($candidates.Count -eq 0) { throw 'pnpm was not found; set AXNS_PNPM_ENTRY to a pinned pnpm entry' }
        $PnpmEntry = $candidates[0].Source
    }
    $entry = [IO.Path]::GetFullPath($PnpmEntry)
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw "Selected pnpm entry does not exist: $entry" }
    $extension = [IO.Path]::GetExtension($entry).ToLowerInvariant()
    if ($extension -in @('.cmd','.bat')) {
        $prefix = Split-Path -Parent $entry
        $cjs = Join-Path $prefix 'node_modules/pnpm/bin/pnpm.mjs'
        if (-not (Test-Path -LiteralPath $cjs -PathType Leaf)) { throw "Cannot safely resolve Windows pnpm wrapper '$entry' to pnpm.cjs; set AXNS_PNPM_ENTRY to the absolute pnpm.mjs path" }
        $entry = [IO.Path]::GetFullPath($cjs)
        $extension = '.cjs'
    }
    if ($extension -notin @('.ps1','.exe','.cjs','.js','.mjs')) { throw "Unsupported pnpm entry '$entry'; use pnpm.ps1, pnpm.exe, or pnpm.mjs" }

    if ($extension -in @('.cjs','.js','.mjs')) {
        $result = Invoke-NativeResult $NodeEntry @($entry,'--version') 60
    } else {
        $result = Invoke-NativeResult $entry @('--version') 60
    }
    $actual = $result.stdout.Trim()
    Write-Host "Selected pnpm entry: $entry"
    Write-Host "pnpm --version stdout: $($result.stdout.TrimEnd())"
    Write-Host "pnpm --version exit code: $($result.exitCode)"
    if ($result.exitCode -ne 0 -or $actual -cne $ExpectedVersion) {
        throw "pnpm version validation failed: expected '$ExpectedVersion'; actual stdout '$actual'; exit code $($result.exitCode); selected entry '$entry'; stderr '$($result.stderr.Trim())'"
    }
    return [pscustomobject]@{ Entry=$entry; Extension=$extension; NodeEntry=$NodeEntry; Version=$actual }
}

function Invoke-PinnedPnpm($Toolchain, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 180) {
    if ($Toolchain.Extension -in @('.cjs','.js','.mjs')) {
        return Invoke-Native $Toolchain.NodeEntry (@($Toolchain.Entry) + $Arguments) $TimeoutSeconds
    }
    return Invoke-Native $Toolchain.Entry $Arguments $TimeoutSeconds
}
