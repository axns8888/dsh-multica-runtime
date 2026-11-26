#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonFile($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

# Native exit codes are mandatory; stdout/stderr are separate. Bound every child.
function Invoke-Native([string]$Command, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 180) {
    $resolved = (Get-Command $Command -ErrorAction Stop).Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = (Get-Location).Path
    if ([IO.Path]::GetExtension($resolved) -eq '.ps1') {
        $start.FileName = (Get-Command pwsh).Source
        foreach ($a in @('-NoLogo','-NoProfile','-File',$resolved)) { $start.ArgumentList.Add($a) }
    } elseif ([IO.Path]::GetExtension($resolved) -in @('.cmd','.bat')) {
        throw "Use the .ps1 or executable launcher for $Command, not a batch wrapper"
    } else { $start.FileName = $resolved }
    foreach ($a in $Arguments) { $start.ArgumentList.Add($a) }
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $start
    try {
        if (-not $child.Start()) { throw "Cannot start $Command" }
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit($TimeoutSeconds * 1000)) {
            $child.Kill($true)
            $child.WaitForExit()
            throw "$Command timed out after $TimeoutSeconds seconds"
        }
        $outputText = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($child.ExitCode -ne 0) { throw "$Command exited $($child.ExitCode): $errorText $outputText" }
        return $outputText
    } finally { $child.Dispose() }
}

function Get-DshHome([string]$Configured) {
    if ([string]::IsNullOrWhiteSpace($Configured)) { $Configured = $env:DSH_HOME }
    if ([string]::IsNullOrWhiteSpace($Configured)) { $Configured = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh' }
    if ($Configured -eq '~') { $Configured = [Environment]::GetFolderPath('UserProfile') }
    elseif ($Configured -match '^~[/\\]') { $Configured = Join-Path ([Environment]::GetFolderPath('UserProfile')) $Configured.Substring(2) }
    return [IO.Path]::GetFullPath($Configured)
}

function Assert-Profile([string]$Profile) {
    if ($Profile -cne 'multica') { throw 'This maintenance tool only manages the multica profile' }
}

function Assert-NoLinkedAncestors([string]$Path) {
    # Check ancestors too, including a home/profile root that is a junction.
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing linked path: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }; $cursor = $parent
    }
}

function Assert-NoLinks([string]$Path) {
    Assert-NoLinkedAncestors $Path
    if (Test-Path -LiteralPath $Path) {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing linked backup entry: $($item.FullName)" }
        }
    }
}

function Assert-Contained([string]$Child, [string]$Root) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $childFull = [IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Path outside intended root: $childFull" }
}


# Atomic renames preserve the original dependency tree and refuse existing destinations.
function Move-ProfileDirectory([string]$Source, [string]$Destination) {
    Assert-NoLinkedAncestors $Source
    Assert-NoLinkedAncestors $Destination
    [IO.Directory]::Move([IO.Path]::GetFullPath($Source), [IO.Path]::GetFullPath($Destination))
}

function Protect-StateDirectory([string]$Path) {
    if ($IsWindows) {
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagation = [Security.AccessControl.PropagationFlags]::None
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        foreach ($sid in @($userSid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, $propagation, $allow)
            $security.AddAccessRule($rule)
        }
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $security)
    } else { $null = Invoke-Native 'chmod' @('700',$Path) }
}
