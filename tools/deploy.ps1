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

    Set-Content -Path $ModsTxt -Value $lines -Encoding UTF8
}

if ($Remove) {
    if (Test-Path $Target) {
        Remove-Item -Recurse -Force $Target
        Write-Host "removed $Target"
    } else {
        Write-Host "nothing to remove at $Target"
    }
    Set-ModsTxtEntry -Enabled $false
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

Write-Host "deployed to $Target"
Write-Host "registered $ModName in mods.txt"
Write-Host ""
Write-Host "Launch Palworld, load a save, then type '!pwp status' in chat."
Write-Host "If nothing responds, check UE4SS.log for lines tagged [PalWorkPriority]."
