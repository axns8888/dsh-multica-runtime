# Test fixture: no network or provider access.
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CallArgs)
if ($CallArgs[0] -eq 'plugin') {
    $dir = Join-Path $env:DSH_HOME 'profiles/multica'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    'candidate' | Set-Content (Join-Path $dir 'candidate.txt')
    if ($env:AXNS_FAKE_MODE -eq 'install_failure') { exit 17 }
    exit 0
}
if ($env:AXNS_FAKE_MODE -eq 'nonzero') { exit 19 }
if ($env:AXNS_FAKE_MODE -eq 'invalid_json') { 'not json'; exit 0 }
if ($env:AXNS_FAKE_MODE -eq 'no_output') { exit 0 }
if ($env:AXNS_FAKE_MODE -eq 'protocol_error') { '{"v":1,"type":"protocol_error","code":"bad"}'; exit 0 }
if ($CallArgs -contains '--probe') {
    $v = if ($env:AXNS_FAKE_MODE -eq 'wrong_version') {'0.0.0'} else {$env:AXNS_FAKE_VERSION}
    @{v=1;type='probe';runtime='dsh';protocol_version=1;plugin_version=$v} | ConvertTo-Json -Compress
    if ($env:AXNS_FAKE_MODE -eq 'duplicate_probe') {'{"v":1,"type":"probe"}'}
} else {
    if ($env:AXNS_FAKE_MODE -eq 'empty_models') {'{"v":1,"type":"models","models":[]}'}
    elseif ($env:AXNS_FAKE_MODE -eq 'invalid_models') {'{"v":1,"type":"models","models":[{"id":"x"}]}'}
    else {'{"v":1,"type":"models","models":[{"id":"test","label":"Test","provider":"fixture"}]}'}
}
