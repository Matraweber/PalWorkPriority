# Drives Pocketpair's Palworld Mod Uploader through UI Automation. Called by
# tools/workshop_upload.py upload; see there. Stops at the Change Notes
# window unless -Submit (press OK, wait for Steam) or -DryRun (press Cancel).
# Any other dialog stops the run with its text; nothing is clicked in it.
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$NotesFile,
    [string]$Directory = 'PalWorkPriority',
    [switch]$Submit,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

function Cond($property, $value) { New-Object System.Windows.Automation.PropertyCondition($property, $value) }
function ById($root, $id) { $root.FindFirst($Scope::Descendants, (Cond $AE::AutomationIdProperty $id)) }
function WaitFor([scriptblock]$probe, [int]$seconds, [string]$what) {
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        $found = & $probe
        if ($found) { return $found }
        Start-Sleep -Milliseconds 300
    }
    throw "Timed out after $seconds s waiting for $what."
}
function Windows($procId) {
    $all = $AE::RootElement.FindAll($Scope::Children, (Cond $AE::ProcessIdProperty $procId))
    foreach ($w in $all) { $w; $w.FindAll($Scope::Children, (Cond $AE::ControlTypeProperty ([System.Windows.Automation.ControlType]::Window))) }
}
function Texts($window) {
    ($window.FindAll($Scope::Descendants, (Cond $AE::ControlTypeProperty ([System.Windows.Automation.ControlType]::Text))) |
        ForEach-Object { $_.Current.Name }) -join ' '
}
function Value($element) { $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
function Press($button) { $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Say($text) { Write-Host ('{0:HH:mm:ss} {1}' -f (Get-Date), $text) }

$notes = [IO.File]::ReadAllText($NotesFile)
$proc = Get-Process PalworldModUploader -ErrorAction SilentlyContinue | Select-Object -First 1
if ($proc) { throw 'The uploader is already open. Close it first, so it reads the staged Workshop directory.' }
$proc = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
Say "Uploader started (process $($proc.Id))."

# The main window, unless Steam refuses (a message box comes first).
$main = WaitFor {
    foreach ($w in Windows $proc.Id) {
        if (ById $w 'ModsDataGrid') { return $w }
        if ($w.Current.Name -and $w.Current.Name -ne 'Palworld Mod Uploader') { throw "Uploader says: $($w.Current.Name): $(Texts $w)" }
    }
} 60 'the uploader window'

$grid = ById $main 'ModsDataGrid'
$row = WaitFor {
    foreach ($r in $grid.FindAll($Scope::Children, (Cond $AE::ControlTypeProperty ([System.Windows.Automation.ControlType]::DataItem)))) {
        if ($r.FindFirst($Scope::Descendants, (Cond $AE::NameProperty $Directory))) { return $r }
    }
} 60 "the $Directory row (Workshop directory: $(Value (ById $main 'WorkshopDirTextBox')))"
$row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()

$shown = WaitFor { $v = Value (ById $main 'VersionTextBox'); if ($v) { $v } } 10 'the mod details'
$package = Value (ById $main 'PackageNameTextBox')
if ($shown -ne $Version -or $package -ne 'PalWorkPriority') { throw "Selected mod shows $package $shown, expected PalWorkPriority $Version." }
Say "Selected $Directory ($package $shown)."

$before = @(Windows $proc.Id | ForEach-Object { $_.Current.NativeWindowHandle })
Press (ById $main 'UploadButton')
$dialog = WaitFor {
    foreach ($w in Windows $proc.Id) {
        if ($before -contains $w.Current.NativeWindowHandle) { continue }
        if ($w.Current.Name -eq 'Change Notes') { return $w }
        throw "Uploader stopped with '$($w.Current.Name)': $(Texts $w)"
    }
} 30 'the Change Notes window'

$box = ById $dialog 'ChangeNotesTextBox'
$box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($notes)
$typed = Value $box
if ($typed.Replace("`r", '') -ne $notes.Replace("`r", '')) { throw "The change note did not go in completely ($($typed.Length) of $($notes.Length) characters)." }
Say "Change note filled in ($($notes.Length) characters)."

$buttons = $dialog.FindAll($Scope::Descendants, (Cond $AE::ControlTypeProperty ([System.Windows.Automation.ControlType]::Button)))
$ok = $buttons | Where-Object { $_.Current.Name -eq 'OK' } | Select-Object -First 1
$cancel = $buttons | Where-Object { $_.Current.Name -eq 'Cancel' } | Select-Object -First 1

if ($DryRun) {
    Press $cancel
    $status = WaitFor { $t = (ById $main 'StatusTextBlock').Current.Name; if ($t -match 'canceled') { $t } } 10 'the cancel'
    Say "Dry run: $status Nothing was sent."
    $proc.CloseMainWindow() | Out-Null
    if (-not $proc.WaitForExit(10000)) { throw 'The uploader did not close.' }
    exit 0
}
if (-not $Submit) {
    Say 'Ready. Read the change note in the uploader, then press OK to publish (or Cancel).'
    Say 'Afterwards: python tools/workshop_upload.py check'
    exit 0
}

Press $ok
Say 'OK pressed: uploading to Steam.'
$status = WaitFor {
    $t = (ById $main 'StatusTextBlock').Current.Name
    if ($t -match 'submitted successfully|Error|error|must accept|failed|Failed') { $t }
} 900 "Steam's answer"
Say "Uploader: $status"
if ($status -notmatch 'submitted successfully') { exit 1 }
Say 'Next: python tools/workshop_upload.py check (after Steam has downloaded the update).'
