<#
.SYNOPSIS
    Stage checked Lua for local testing, preserving configuration and old code.
.DESCRIPTION
    Requires Python and tools/test_lua.py's Lua 5.4 compile gate. It fails closed.
    Old Scripts and legacy configuration are backed up before code replacement.
    No save, user config, or backup is deleted. This does not build/install a pak.
.PARAMETER Remove
    Disable the mod in mods.txt; preserve all code and player data for restoration.
#>
[CmdletBinding()]
param(
    [string]$GamePath = '',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$ModName = 'PalWorkPriority'
$Source = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$Python = $null
if ([string]::IsNullOrWhiteSpace($GamePath)) {
    foreach ($candidate in 'python', 'python3', 'py') {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { $Python = $command.Source; break }
    }
    if (-not $Python) { throw 'Python is needed to discover the game. Specify -GamePath explicitly.' }
    # A native PowerShell pipeline can decode Python's ANSI stdout using a
    # different console code page. Keep this boundary explicitly UTF-8, with
    # strict decoding and raw framing; never trim a validated filesystem path.
    $discovery = New-Object System.Diagnostics.Process
    $discovery.StartInfo.FileName = $Python
    $discovery.StartInfo.Arguments = '-B "' + (Join-Path $PSScriptRoot 'paths.py') + '" --client-root'
    $discovery.StartInfo.UseShellExecute = $false
    $discovery.StartInfo.CreateNoWindow = $true
    $discovery.StartInfo.RedirectStandardOutput = $true
    $discovery.StartInfo.RedirectStandardError = $true
    $discovery.StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false, $true)
    $discovery.StartInfo.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8:strict'
    try {
        $null = $discovery.Start()
        $stdout = $discovery.StandardOutput.ReadToEndAsync()
        $stderr = $discovery.StandardError.ReadToEndAsync()
        $discovery.WaitForExit()
        $discovered = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        $discoveryExit = $discovery.ExitCode
    } catch {
        throw 'Game discovery output could not be read. Nothing was deployed.'
    } finally {
        $discovery.Dispose()
    }
    $line = [regex]::Match($discovered, '\A([^\r\n]+)(?:\r?\n)?\z')
    if ($discoveryExit -ne 0 -or -not $line.Success) {
        throw 'Game discovery failed. Set PWP_CLIENT_ROOT or specify -GamePath. Nothing was deployed.'
    }
    $GamePath = $line.Groups[1].Value
    # Reject relative/drive-relative paths, controls and invalid path bytes.
    # GetFullPath alone would resolve relative output against the caller's CWD.
    $root = [System.IO.Path]::GetPathRoot($GamePath)
    if ([string]::IsNullOrWhiteSpace($GamePath) -or $GamePath -match '[\x00-\x1f\x7f]' -or
        $GamePath.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0 -or
        $root.Length -le 1 -or $root.EndsWith(':')) {
        throw 'Game discovery failed. Set PWP_CLIENT_ROOT or specify -GamePath. Nothing was deployed.'
    }
}
# .NET Framework also trims trailing Unicode whitespace in GetFullPath.
# A terminal separator preserves the final directory component exactly.
$GameRoot = [System.IO.Path]::GetFullPath($GamePath + '\')
$ModsRoot = Join-Path $GameRoot 'Mods\NativeMods\UE4SS\Mods'
$Target = [System.IO.Path]::GetFullPath((Join-Path $ModsRoot $ModName))
$ModsTxt = Join-Path $ModsRoot 'mods.txt'

function Assert-ContainedPath {
    param([string]$Path, [string]$Within)
    $absolute = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetFullPath($Within + '\').TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($parent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing an operation outside $Within : $absolute"
    }
    # Lexical containment alone does not protect against junctions or symlinks.
    $cursor = $absolute
    while ($cursor -and $cursor.Length -ge $Within.TrimEnd('\').Length) {
        if (Test-Path -LiteralPath $cursor) {
            $entry = Get-Item -LiteralPath $cursor -Force
            if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing an operation through a junction/symlink: $cursor"
            }
        }
        $cursor = Split-Path -Parent $cursor
    }
    return $absolute
}

function Write-Utf8NoBom {
    param([string]$Path, [string[]]$Lines)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $temporary = $Path + '.pwp-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $newline = [System.Environment]::NewLine
    [System.IO.File]::WriteAllText($temporary, ($Lines -join $newline) + $newline, $utf8)
    if (Test-Path -LiteralPath $Path) {
        $backup = $Path + '.pwp-backup-' + [Guid]::NewGuid().ToString('N')
        [System.IO.File]::Replace($temporary, $Path, $backup)
    } else {
        [System.IO.File]::Move($temporary, $Path)
    }
}

function Get-Sha256 {
    param([string]$Path)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return [System.BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '')
    } finally {
        $stream.Dispose()
        $hasher.Dispose()
    }
}

function Set-ModsTxtEntry {
    param([bool]$Enabled)
    $lines = @()
    if (Test-Path -LiteralPath $ModsTxt) { $lines = @(Get-Content -LiteralPath $ModsTxt) }
    $lines = @($lines | Where-Object { $_ -notmatch "^\s*$ModName\s*:" })
    $entry = "$ModName : " + $(if ($Enabled) { '1' } else { '0' })
    # Insert before Keybinds even when it is the first line.
    $output = New-Object 'System.Collections.Generic.List[string]'
    $inserted = $false
    foreach ($line in $lines) {
        if (-not $inserted -and ($line -match 'Built-in keybinds|^\s*Keybinds\s*:')) {
            $output.Add($entry)
            $inserted = $true
        }
        $output.Add($line)
    }
    if (-not $inserted) { $output.Add($entry) }
    Write-Utf8NoBom -Path $ModsTxt -Lines $output.ToArray()
}

if (-not (Test-Path -LiteralPath $ModsRoot -PathType Container)) {
    throw "UE4SS mods folder not found at $ModsRoot. Check -GamePath."
}
$null = Assert-ContainedPath -Path $Target -Within $GameRoot
$null = Assert-ContainedPath -Path $ModsTxt -Within $GameRoot

# General deployment must not mix unreviewed code with a journal writer or
# bypass an interrupted recovery. Absence must be positively established;
# denied/unknown paths and even directories at marker names are refusals.
function Assert-NoSettingsRecovery {
    foreach ($relative in @('.settings-cutover', 'async-trial\launch.lua', 'async-trial\receipt.lua')) {
        $marker = Join-Path $Target $relative
        $null = Assert-ContainedPath -Path $marker -Within $Target
        # DirectoryNotFound can also mean an ancestor is a regular file.
        # Check ancestor types before treating a missing leaf as absence.
        $ancestor = Split-Path -Parent $marker
        while ($ancestor.Length -ge $Target.Length) {
            try {
                $attributes = [System.IO.File]::GetAttributes($ancestor)
                if (-not ($attributes -band [System.IO.FileAttributes]::Directory)) {
                    throw "Invalid settings recovery directory: $ancestor"
                }
            } catch [System.IO.FileNotFoundException] {
                # Continue checking the remaining ancestors.
            } catch [System.IO.DirectoryNotFoundException] {
                # Continue checking the remaining ancestors.
            }
            if ($ancestor -eq $Target) { break }
            $ancestor = Split-Path -Parent $ancestor
        }
        try {
            $null = [System.IO.File]::GetAttributes($marker)
        } catch [System.IO.FileNotFoundException] {
            continue
        } catch [System.IO.DirectoryNotFoundException] {
            continue
        } catch {
            throw "Cannot establish settings recovery marker absence: $marker. Nothing authorized for replacement."
        }
        throw "Active settings recovery or async trial: $marker. Use a reviewed trial upgrade/recovery; preserve its launcher, receipt and journals."
    }
}
Assert-NoSettingsRecovery

if ($Remove) {
    Set-ModsTxtEntry -Enabled $false
    Write-Host "Disabled $ModName. All settings, saves, code and backups were preserved."
    Write-Host 'Restore vanilla Pal work permissions in-game before permanently removing the mod.'
    return
}

$Checker = Join-Path $PSScriptRoot 'test_lua.py'
if (-not (Test-Path -LiteralPath $Checker -PathType Leaf)) {
    throw 'Required Lua compiler gate tools/test_lua.py is missing. Nothing was deployed.'
}
$Python = $null
foreach ($candidate in 'python', 'python3', 'py') {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) { $Python = $command.Source; break }
}
if (-not $Python) { throw 'Python is unavailable. Lua compilation is required; nothing was deployed.' }
Push-Location $Source
try {
    & $Python $Checker '--compile-only'
    $checkResult = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($checkResult -ne 0) { throw 'Lua 5.4 compilation failed. Nothing was deployed.' }

$SourceScripts = Join-Path $Source 'Scripts'
$Code = @(Get-ChildItem -LiteralPath $SourceScripts -Filter '*.lua' -File)
if (-not ($Code | Where-Object { $_.Name -eq 'main.lua' })) { throw 'Scripts/main.lua is missing.' }
foreach ($file in $Code) {
    if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Symlinked Lua source: $($file.Name)" }
}
$SourceHashes = @{}
foreach ($file in $Code) { $SourceHashes[$file.Name] = Get-Sha256 -Path $file.FullName }
$InfoSource = Join-Path $Source 'Info.json'
if (-not (Test-Path -LiteralPath $InfoSource -PathType Leaf)) { throw 'Info.json is missing.' }

Assert-NoSettingsRecovery
New-Item -ItemType Directory -Force -Path $Target | Out-Null
$Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N')
$BackupRoot = Join-Path $Target 'backups'
$Backup = Join-Path $BackupRoot ("deploy-" + $Stamp)
$Stage = Join-Path $Target ('.scripts-stage-' + $Stamp)
$ScriptsTarget = Join-Path $Target 'Scripts'
foreach ($path in @($Backup, $Stage, $ScriptsTarget)) { $null = Assert-ContainedPath -Path $path -Within $Target }
New-Item -ItemType Directory -Path $Stage | Out-Null
foreach ($file in $Code) {
    $copy = Join-Path $Stage $file.Name
    Copy-Item -LiteralPath $file.FullName -Destination $copy
    if ((Get-Sha256 -Path $copy) -ne $SourceHashes[$file.Name]) {
        throw "Source changed while staging $($file.Name); nothing replaced."
    }
}
# Compile again and compare source/staged bytes immediately before replacement.
Push-Location $Source
try { & $Python $Checker '--compile-only'; $checkResult = $LASTEXITCODE } finally { Pop-Location }
if ($checkResult -ne 0) { throw 'Source changed or compilation failed during staging. Nothing replaced.' }
$CurrentCode = @(Get-ChildItem -LiteralPath $SourceScripts -Filter '*.lua' -File)
if ($CurrentCode.Count -ne $Code.Count) { throw 'Lua file list changed during staging.' }
foreach ($file in $CurrentCode) {
    if ((Get-Sha256 -Path $file.FullName) -ne $SourceHashes[$file.Name]) {
        throw "Source changed during compilation: $($file.Name)"
    }
}

Assert-NoSettingsRecovery
New-Item -ItemType Directory -Force -Path $Backup | Out-Null
$LegacyConfig = Join-Path $ScriptsTarget 'config.lua'
$UserConfig = Join-Path $Target 'config.lua'
foreach ($path in @($LegacyConfig, $UserConfig)) { $null = Assert-ContainedPath -Path $path -Within $Target }
if (Test-Path -LiteralPath $LegacyConfig -PathType Leaf) {
    Copy-Item -LiteralPath $LegacyConfig -Destination (Join-Path $Backup 'legacy-config.lua')
    # Main loads this durable path; Scripts/config.lua remains shipped defaults.
    if (-not (Test-Path -LiteralPath $UserConfig)) {
        Copy-Item -LiteralPath $LegacyConfig -Destination $UserConfig
    }
}
if (Test-Path -LiteralPath $UserConfig -PathType Leaf) {
    Copy-Item -LiteralPath $UserConfig -Destination (Join-Path $Backup 'user-config.lua')
}
$InfoTarget = Join-Path $Target 'Info.json'
$null = Assert-ContainedPath -Path $InfoTarget -Within $Target
if (Test-Path -LiteralPath $InfoTarget -PathType Leaf) {
    Copy-Item -LiteralPath $InfoTarget -Destination (Join-Path $Backup 'Info.json')
}
$PreviousScripts = Join-Path $Backup 'Scripts'
$null = Assert-ContainedPath -Path $PreviousScripts -Within $Target
$HadScripts = Test-Path -LiteralPath $ScriptsTarget
# PowerShell 5's directory Move-Item normalizes ancestor names again (including
# Unicode whitespace). These already-checked absolute paths must remain exact.
if ($HadScripts) { [System.IO.Directory]::Move($ScriptsTarget, $PreviousScripts) }
try {
    [System.IO.Directory]::Move($Stage, $ScriptsTarget)
    Copy-Item -LiteralPath $InfoSource -Destination $InfoTarget -Force
    Set-ModsTxtEntry -Enabled $true
} catch {
    # Preserve a failed staged generation too; do not recursively delete anything.
    if (Test-Path -LiteralPath $ScriptsTarget) {
        $FailedScripts = Join-Path $Backup 'failed-Scripts'
        $null = Assert-ContainedPath -Path $FailedScripts -Within $Target
        [System.IO.Directory]::Move($ScriptsTarget, $FailedScripts)
    }
    if ($HadScripts) { [System.IO.Directory]::Move($PreviousScripts, $ScriptsTarget) }
    if (Test-Path -LiteralPath (Join-Path $Backup 'Info.json')) {
        Copy-Item -LiteralPath (Join-Path $Backup 'Info.json') -Destination $InfoTarget -Force
    }
    throw
}
Write-Host "Checked Lua deployed to $Target"
Write-Host "Previous code and configuration preserved at $Backup"
Write-Host 'Fully restart the game. Open Production Limits with Alt+F1.'
Write-Host 'The required pak must already be installed. Avoid a competing Workshop installation.'
