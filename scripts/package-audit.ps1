#requires -Version 7.4
. "$PSScriptRoot/common.ps1"
function Test-RuntimePackage([string]$Archive) {
    $entries = (Invoke-Native 'tar' @('-tf',$Archive)) -split '\r?\n' | Where-Object { $_ }
    if ($entries.Count -lt 5) { throw 'Incomplete runtime archive' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if (-not $seen.Add($entry)) { throw "Duplicate archive member: $entry" }
        if ($entry -match '(^|/)\.\.(/|$)|\\|^/|[\x00-\x1f]' -or $entry -notmatch '^package/(dist/[a-zA-Z0-9_.-]+\.(js|js\.map|d\.ts|d\.ts\.map)|package\.json|LICENSE|cordis\.patch\.yml|README\.md|UPSTREAM\.md|COMPATIBILITY\.md|docs/(INSTALL|VALIDATION|REVIEW|MULTI-MACHINE|DEPLOY-CHECKLIST|MODEL-SYNC)\.zh-CN\.md)$') { throw "Unexpected package entry: $entry" }
    }
    # No symlinks/hardlinks/devices. The first column is the tar entry type.
    $details = (Invoke-Native 'tar' @('-tvf',$Archive)) -split '\r?\n' | Where-Object { $_ }
    if (@($details | Where-Object { $_[0] -ne '-' }).Count -gt 0) { throw 'Archive contains non-regular files' }
    $manifest = (Invoke-Native 'tar' @('-xOf',$Archive,'package/package.json')) | ConvertFrom-Json -AsHashtable
    if ($manifest.name -cne '@multica-ai/dsh-runtime' -or $manifest.private -ne $true -or $manifest.license -cne 'MIT' -or $manifest.main -cne 'dist/index.js') { throw 'Unexpected bundle identity/license' }
    if ($manifest.ContainsKey('scripts') -and @($manifest.scripts.Keys | Where-Object { $_ -match '^(preinstall|install|postinstall|prepare)$' }).Count -gt 0) { throw 'Install lifecycle scripts are forbidden' }
    if ('package/dist/index.js' -notin $entries -or 'package/cordis.patch.yml' -notin $entries -or 'package/LICENSE' -notin $entries) { throw 'Bundle entrypoint/patch/license missing' }
    $index = Invoke-Native 'tar' @('-xOf',$Archive,'package/dist/index.js')
    if ($index -notmatch ([regex]::Escape("const PLUGIN_VERSION = '$($manifest.version)'"))) { throw 'Runtime version differs from manifest' }
    return $manifest
}
