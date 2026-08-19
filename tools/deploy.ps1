<#
.SYNOPSIS
    Installs Pal Work Priority into a local UE4SS install for testing.

.DESCRIPTION
    Copies Scripts/ into <Palworld>/Mods/NativeMods/UE4SS/Mods/PalWorkPriority
    and registers the mod in mods.txt, keeping the built-in Keybinds entry
    last as UE4SS requires. Safe to run repeatedly.

    This is the developer loop only. Players install the published Workshop
    item instead, which Palworld's own loader deploys from Info.json.

.PARAMETER GamePath
    Palworld install root. Defaults to the usual Steam location.

.PARAMETER Remove
    Uninstall instead: deletes the mod folder and its mods.txt line.

.EXAMPLE
    .\tools\deploy.ps1
.EXAMPLE
    .\tools\deploy.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$GamePath = 'C:\Program Files (x86)\Steam\steamapps\common\Palworld',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$ModName  = 'PalWorkPriority'
$ModsRoot = Join-Path $GamePath 'Mods\NativeMods\UE4SS\Mods'
$Target   = Join-Path $ModsRoot $ModName
$ModsTxt  = Join-Path $ModsRoot 'mods.txt'
$Source   = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $ModsRoot)) {
    throw "UE4SS mods folder not found at $ModsRoot. Check -GamePath, or install UE4SS first."
}

# Windows PowerShell's -Encoding UTF8 writes a byte-order mark. None of the
# files touched here have one: Palworld writes its own JSON and INI without,
# and UE4SS's mods.txt likewise. A BOM in PalModSettings.ini risks the game
# failing to parse its own mod list, so every write goes through here.
function Write-Utf8NoBom {
    param([string]$Path, [string[]]$Lines)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($Lines -join "`r`n") + "`r`n", $utf8)
}

function Set-ModsTxtEntry {
    param([bool]$Enabled)

    if (-not (Test-Path $ModsTxt)) {
        Write-Warning "mods.txt not found at $ModsTxt - skipping registration."
        return
    }

    $lines = @(Get-Content $ModsTxt)
    $lines = @($lines | Where-Object { $_ -notmatch "^\s*$ModName\s*:" })

    if ($Enabled) {
        # The built-in Keybinds entry must stay last, so insert above it.
        $anchor = $lines | Select-String -SimpleMatch -Pattern 'Built-in keybinds' | Select-Object -First 1
        $entry  = "$ModName : 1"

        if ($anchor) {
            $at = $anchor.LineNumber - 1
            $lines = @($lines[0..($at - 1)]) + @($entry) + @($lines[$at..($lines.Count - 1)])
        } else {
            $lines += $entry
        }
    }

    Write-Utf8NoBom -Path $ModsTxt -Lines $lines
}

# Palworld's own mod manager (Options > Mod Management) only lists mods it
# deployed itself. It records each one under Mods/ManagedMods/<PackageName>
# and enables it with an ActiveModList line in PalModSettings.ini.
#
# Writing those by hand makes a locally installed mod appear in that list, so
# it can be toggled in game like a subscribed one. Whether the entry survives
# is up to the manager: it may reconcile against actual Steam subscriptions
# and drop a package it cannot find. Uninstall puts everything back either
# way, and the settings file is backed up before being touched.
$ManagedDir = Join-Path $GamePath "Mods\ManagedMods\$ModName"
$SettingsIni = Join-Path $GamePath 'Mods\PalModSettings.ini'

function Set-ManagedEntry {
    param([bool]$Enabled)

    if ($Enabled) {
        New-Item -ItemType Directory -Force -Path $ManagedDir | Out-Null
        Copy-Item -Force -Path (Join-Path $Source 'Info.json') -Destination $ManagedDir

        $files = Get-ChildItem -Recurse -File (Join-Path $Target 'Scripts') |
            ForEach-Object {
                "Mods/NativeMods/UE4SS/Mods/$ModName/Scripts/" + $_.Name
            }
        $files += "Mods/ManagedMods/$ModName/Info.json"

        # WorkshopId 0 marks this as a local install rather than a subscription.
        $manifest = [ordered]@{
            Files = $files
            Dirs  = @("Mods/NativeMods/UE4SS/Mods/$ModName/Scripts",
                      "Mods/ManagedMods/$ModName")
            Backups = @()
            WorkshopId = 0
            LastInstallTimeUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        Write-Utf8NoBom -Path (Join-Path $ManagedDir 'InstallManifest.json') `
            -Lines ($manifest | ConvertTo-Json -Depth 4)
    } elseif (Test-Path $ManagedDir) {
        Remove-Item -Recurse -Force $ManagedDir
    }

    if (-not (Test-Path $SettingsIni)) {
        Write-Warning "PalModSettings.ini not found; in-game toggle unavailable."
        return
    }

    $backup = "$SettingsIni.bak-pwp"
    if (-not (Test-Path $backup)) { Copy-Item $SettingsIni $backup }

    $lines = @(Get-Content $SettingsIni)
    $lines = @($lines | Where-Object { $_ -ne "ActiveModList=$ModName" })
    if ($Enabled) { $lines += "ActiveModList=$ModName" }
    Write-Utf8NoBom -Path $SettingsIni -Lines $lines
}

if ($Remove) {
    if (Test-Path $Target) {
        Remove-Item -Recurse -Force $Target
        Write-Host "removed $Target"
    } else {
        Write-Host "nothing to remove at $Target"
    }
    Set-ModsTxtEntry -Enabled $false
    Set-ManagedEntry -Enabled $false
    Write-Host "unregistered $ModName"
    return
}

New-Item -ItemType Directory -Force -Path $Target | Out-Null

# Wipe only the code, never priority.log or Discovery.txt sitting alongside it.
$ScriptsTarget = Join-Path $Target 'Scripts'
if (Test-Path $ScriptsTarget) { Remove-Item -Recurse -Force $ScriptsTarget }

Copy-Item -Recurse -Path (Join-Path $Source 'Scripts') -Destination $ScriptsTarget
Copy-Item -Force -Path (Join-Path $Source 'Info.json') -Destination $Target

Set-ModsTxtEntry -Enabled $true
Set-ManagedEntry -Enabled $true

Write-Host "deployed to $Target"
Write-Host "registered $ModName in mods.txt and ManagedMods"
Write-Host ""
Write-Host "Launch Palworld. The mod should appear under Options > Mod Management,"
Write-Host "and F10 runs a pass once you are in a base."
