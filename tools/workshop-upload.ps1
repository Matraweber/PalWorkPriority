# Drives Pocketpair's Palworld Mod Uploader through UI Automation. Called by
# tools/workshop_upload.py upload; see there. Stops at the Change Notes
# window unless -Submit (press OK, wait for Steam) or -DryRun (press Cancel).
# Any other dialog stops the run with its text; nothing is clicked in it.
# -Submit writes the uploader's final status text to -StatusFile; the Python
# side classifies it (classify_status), so this script exits 0 once it has
# an answer, whatever the answer is.
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$NotesFile,
    [string]$Directory = 'PalWorkPriority',
    [string]$StatusFile,
    [int]$NoteMax = 8000,
    [switch]$Submit,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]
# Status texts the uploader shows while an upload is still running
# (MainWindow.xaml.cs: UploadButton_Click and UpdateProgress).
$Progress = @('Submitting workshop update...', 'Preparing content...', 'Preparing configuration...',
    'Uploading content...', 'Uploading preview...', 'Finalizing submission...', 'Updating...')

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
    foreach ($w in $all) { $w; $w.FindAll($Scope::Children, (Cond $AE::ControlTypeProperty $CT::Window)) }
}
function Texts($window) {
    ($window.FindAll($Scope::Descendants, (Cond $AE::ControlTypeProperty $CT::Text)) |
        ForEach-Object { $_.Current.Name }) -join ' '
}
# A named window of the uploader that was not there before: a message box.
function StopOnDialog($procId, $known, [string]$after) {
    foreach ($w in Windows $procId) {
        if ($known -contains $w.Current.NativeWindowHandle) { continue }
        if ($w.Current.Name) { throw "Uploader stopped with '$($w.Current.Name)': $(Texts $w)$after" }
    }
}
function Value($element) { $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
function Press($button) { $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Say($text) { Write-Host ('{0:HH:mm:ss} {1}' -f (Get-Date), $text) }
function NormPath($p) { if (-not $p) { return '' }; ($p.Trim() -replace '/', '\').TrimEnd('\').ToLowerInvariant() }
function Status() { (ById $main 'StatusTextBlock').Current.Name }
# The cell of $row in grid column $col (GridItemPattern, else by position).
function CellAt($row, [int]$col) {
    $cells = @($row.FindAll($Scope::Children, [System.Windows.Automation.Condition]::TrueCondition))
    foreach ($c in $cells) {
        $p = $null
        if ($c.TryGetCurrentPattern([System.Windows.Automation.GridItemPattern]::Pattern, [ref]$p) -and $p.Current.Column -eq $col) { return $c }
    }
    if ($col -lt $cells.Count) { return $cells[$col] }
}
# What is wrong with the change note the uploader holds, or $null. The
# compare is exact (CRs and case count): Steam stores what the box holds, and
# counts its UTF-8 bytes against NoteMax (k_cchPublishedDocumentChangeDescriptionMax).
function NoteProblem([string]$held, [string]$want, [int]$max) {
    $bytes = [Text.Encoding]::UTF8.GetByteCount($held)
    if ($bytes -gt $max) { return "The uploader holds a change note of $bytes bytes; Steam allows $max." }
    if ($held -cne $want) {
        if ($held.Replace("`r", '') -ceq $want.Replace("`r", '')) {
            return "The uploader changed the line ends of the change note ($bytes bytes held, $([Text.Encoding]::UTF8.GetByteCount($want)) in the file)."
        }
        return "The change note did not go in completely ($($held.Length) of $($want.Length) characters)."
    }
    return $null
}
function CellTexts($cell) {
    if (-not $cell) { return @() }
    $names = @($cell.Current.Name)
    $names += @($cell.FindAll($Scope::Descendants, (Cond $AE::ControlTypeProperty $CT::Text)) | ForEach-Object { $_.Current.Name })
    $p = $null
    if ($cell.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { $names += $p.Current.Value }
    return $names
}

if ($Submit -and -not $StatusFile) { throw '-Submit needs -StatusFile.' }
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
$known = @($main.Current.NativeWindowHandle)

# The grid is filled only after the tool has settled on its Workshop
# directory (OnLoaded, after the Steam subscription query). Rows read before
# that may come from another directory, so wait for the stage path first.
$dirBox = ById $main 'WorkshopDirTextBox'
$want = NormPath $Stage
try {
    WaitFor { StopOnDialog $proc.Id $known ''; (NormPath (Value $dirBox)) -eq $want } 60 'the Workshop directory' | Out-Null
} catch {
    if ($_.Exception.Message -like 'Timed out*') { throw "The uploader shows Workshop directory '$(Value $dirBox)', expected '$Stage'." }
    throw
}
Say "Workshop directory: $(Value $dirBox)"

$grid = ById $main 'ModsDataGrid'
$headers = @($grid.FindAll($Scope::Descendants, (Cond $AE::ControlTypeProperty $CT::HeaderItem)) | ForEach-Object { $_.Current.Name })
$col = [array]::IndexOf($headers, 'Directory')
if ($col -lt 0) { throw "The mod list has no Directory column (columns: $($headers -join ', '))." }
$row = WaitFor {
    StopOnDialog $proc.Id $known ''
    foreach ($r in $grid.FindAll($Scope::Children, (Cond $AE::ControlTypeProperty $CT::DataItem))) {
        if ((CellTexts (CellAt $r $col)) -contains $Directory) { return $r }
    }
} 60 "the row with Directory $Directory (Workshop directory: $(Value $dirBox))"
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
$problem = NoteProblem $typed $notes $NoteMax
if ($problem) { throw $problem }
Say "Change note filled in ($([Text.Encoding]::UTF8.GetByteCount($typed)) bytes)."

$buttons = $dialog.FindAll($Scope::Descendants, (Cond $AE::ControlTypeProperty $CT::Button))
$ok = $buttons | Where-Object { $_.Current.Name -eq 'OK' } | Select-Object -First 1
$cancel = $buttons | Where-Object { $_.Current.Name -eq 'Cancel' } | Select-Object -First 1

if ($DryRun) {
    Press $cancel
    $status = WaitFor { $t = Status; if ($t -match 'canceled') { $t } } 10 'the cancel'
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

# The status text from before OK (for example a startup "Failed to read
# workshop subscriptions") is not Steam's answer: wait for a new text that is
# not one of the progress texts.
$baseline = Status
$known = @(Windows $proc.Id | ForEach-Object { $_.Current.NativeWindowHandle })
Press $ok
Say 'OK pressed: uploading to Steam.'
$late = '. Nothing was clicked in it; look at the uploader, then run check.'
$status = WaitFor {
    StopOnDialog $proc.Id $known $late
    $t = Status
    if ($t -and $t -ne $baseline -and $Progress -notcontains $t) { $t }
} 900 "Steam's answer (the upload may still finish: look at the uploader, then run check)"
# OnItemSubmitted can replace the success text with "Submitted, but ...":
# read once more after a moment and keep the latest final text.
Start-Sleep -Seconds 2
$again = Status
if ($again -and $Progress -notcontains $again) { $status = $again }
[IO.File]::WriteAllText($StatusFile, $status, (New-Object System.Text.UTF8Encoding($false)))
Say "Uploader: $status"
exit 0
