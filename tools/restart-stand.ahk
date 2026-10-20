#Requires AutoHotkey v2.0
#SingleInstance Ignore
; Double-click while standing at the Monitoring Stand with its grid OPEN.
; --world: stand grid is closed. --title: already on the title menu.
; --check: syntax/config check only. Pause / ScrollLock abort immediately.
; --open-only: already facing the stand in gameplay; hold V without restarting.
; --return-title-only: stand is open; normal return to title, no quit/relaunch.
; Append -select to --stand/--world/--title/--launch to stop at world selection.
; Append -absent instead when PalWorkPriority is removed (G5 mod-absent frame
; captures): no priority.log exists, so readiness is a fixed 60 s wait.
; Use this for multiple-world tests: list order changes with last-played time.
; Window-relative 16:9 calibration. Never kills the game or edits its saves.
GAME := 'D:\Steam\steamapps\common\Palworld'
EXE := GAME '\Pal\Binaries\Win64\Palworld-Win64-Shipping.exe'
GAME_LOG := GAME '\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\priority.log'
REPORT := A_ScriptDir '\restart-stand-last-run.log'
MODE := A_Args.Length ? A_Args[1] : '--stand'
RETURN_ONLY := MODE = '--return-title-only'
if RETURN_ONLY
    MODE := '--stand'
SELECT_WORLD := RegExMatch(MODE, '^--(stand|world|title|launch)-select$') != 0
if SELECT_WORLD
    MODE := SubStr(MODE, 1, StrLen(MODE) - 7)
MOD_ABSENT := RegExMatch(MODE, '^--(stand|world|title|launch)-absent$') != 0
if MOD_ABSENT
    MODE := SubStr(MODE, 1, StrLen(MODE) - 7)
HELD_VK := 0
HELD_SC := 0
if MODE = '--check'
    ExitApp FileExist(EXE) && FileExist(GAME_LOG) ? 0 : 2
if !(MODE = '--stand' || MODE = '--world' || MODE = '--title' || MODE = '--launch' || MODE = '--open-only')
    ExitApp 2
CoordMode 'Mouse', 'Client'
SetKeyDelay 70, 90
SetMouseDelay 80
OnExit ReleaseKeys
Pause::ExitApp
ScrollLock::ExitApp
try {
    Note('Starting ' MODE)
    if MODE = '--open-only' {
        Focus()
        HELD_VK := 0x56
        HELD_SC := 0x2F
        DllCall('keybd_event', 'UChar', 0x56, 'UChar', 0x2F, 'UInt', 0, 'UPtr', 0)
        Sleep 850
        DllCall('keybd_event', 'UChar', 0x56, 'UChar', 0x2F, 'UInt', 2, 'UPtr', 0)
        HELD_VK := 0
        Note('Stand-open key sent without restart. Verify visible priority numbers.')
        ExitApp 0
    }
    oldPid := 0
    if MODE != '--launch' {
      hwnd := GameWindow()
      oldPid := WinGetPID('ahk_id ' hwnd)
      if MODE != '--title' {
        if MODE = '--stand' {
            Key('Escape')
            Sleep 1200
        }
        Key('Escape')
        Sleep 1500
        Point(306, 573) ; Return to title (normal save path)
        Sleep 1200
        Point(552, 477) ; Yes
        Sleep 16000
        if RETURN_ONLY {
            Note('Normal return-to-title sequence sent; no quit or relaunch. Verify lifecycle evidence.')
            ExitApp 0
        }
      }
      Point(639, 634) ; Quit from title
      Sleep 1200
      Point(552, 477)
      ProcessWaitClose(oldPid, 60)
      if ProcessExist(oldPid)
        throw Error('Normal exit did not finish; stopped without killing the game.')
      Note('Old process exited: ' oldPid)
    } else if ProcessExist('Palworld-Win64-Shipping.exe') {
        throw Error('--launch requires the game to be closed.')
    }
    ; A clean install has no priority.log yet: start reading from its beginning.
    offset := (MOD_ABSENT || !FileExist(GAME_LOG)) ? 0 : FileGetSize(GAME_LOG)
    Run EXE, GAME
    if !WinWait('ahk_exe Palworld-Win64-Shipping.exe', , 90)
        throw Error('New game window did not appear.')
    Sleep 25000 ; splash, shader/loading and mod-warning presentation
    hwnd := GameWindow()
    newPid := WinGetPID('ahk_id ' hwnd)
    if newPid = oldPid
        throw Error('No new game process established.')
    Note('New process: ' newPid)
    Point(639, 486) ; Mods Detected: OK
    Sleep 2500
    Point(639, 412) ; Start Game
    Sleep 2500
    if SELECT_WORLD {
        Note('Stopped at world selection. Select the intended world by name; no world click or stand key sent.')
        ExitApp 0
    }
    Point(599, 170) ; Existing first world (Palpagos Islands)
    Sleep 1500
    Point(971, 654) ; Start Game (never Delete World)
    deadline := A_TickCount + 150000
    ready := false
    if MOD_ABSENT {
        ; Without the mod there is no readiness marker. World loads took about
        ; 30 s on 2026-10-19; the fixed wait only has to outlast that.
        Sleep 60000
        if !ProcessExist(newPid)
            throw Error('Game exited during world loading.')
        ready := true
        deadline := 0
    }
    while A_TickCount < deadline {
        if !ProcessExist(newPid)
            throw Error('Game exited during world loading.')
        if !FileExist(GAME_LOG) {
            Sleep 1000
            continue
        }
        f := FileOpen(GAME_LOG, 'r', 'UTF-8')
        f.Pos := offset
        fresh := f.Read()
        f.Close()
        if RegExMatch(fresh, 'PWP_READY[^\r\n]*session=[1-9][0-9]*\b') {
            ready := true
            break
        }
        Sleep 1000
    }
    if !ready
        throw Error('No fresh gameplay readiness marker; no stand key sent.')
    Sleep 12000 ; gameplay readiness precedes completion of the loading fade
    Focus()
    HELD_VK := 0x56
    HELD_SC := 0x2F
    DllCall('keybd_event', 'UChar', 0x56, 'UChar', 0x2F, 'UInt', 0, 'UPtr', 0)
    Sleep 850
    DllCall('keybd_event', 'UChar', 0x56, 'UChar', 0x2F, 'UInt', 2, 'UPtr', 0)
    HELD_VK := 0
    Sleep 3000
    Note(MOD_ABSENT ? 'World presumed ready after the fixed wait (mod absent); stand-open key sent. Verify the stand.' : 'World ready; stand-open key sent. Verify visible priority numbers.')
} catch as err {
    Note('STOPPED: ' err.Message)
    MsgBox err.Message, 'Palworld restart stopped'
    ExitApp 1
}
ExitApp 0

GameWindow() {
    windows := WinGetList('ahk_exe Palworld-Win64-Shipping.exe')
    if windows.Length != 1
        throw Error('Expected exactly one Palworld window.')
    return windows[1]
}
Focus() {
    id := GameWindow()
    wasActive := WinActive('ahk_id ' id)
    loop 3 {
        WinActivate 'ahk_id ' id
        if WinWaitActive('ahk_id ' id, , 2)
            break
        ; Windows refuses a focus change while another process holds the
        ; foreground (on 2026-10-17 the text input host, so every macro run
        ; stopped here). Attaching to that window's input thread for the
        ; moment of the switch lets SetForegroundWindow through.
        fg := DllCall('GetForegroundWindow', 'Ptr')
        fgThread := fg ? DllCall('GetWindowThreadProcessId', 'Ptr', fg, 'Ptr', 0, 'UInt') : 0
        me := DllCall('GetCurrentThreadId', 'UInt')
        attached := fgThread && fgThread != me && DllCall('AttachThreadInput', 'UInt', me, 'UInt', fgThread, 'Int', 1)
        DllCall('BringWindowToTop', 'Ptr', id)
        DllCall('SetForegroundWindow', 'Ptr', id)
        if attached
            DllCall('AttachThreadInput', 'UInt', me, 'UInt', fgThread, 'Int', 0)
        if WinWaitActive('ahk_id ' id, , 2)
            break
        ; The foreground lock only refuses programmatic switches. A click is
        ; input, and the clicked window becomes active, so click the game's
        ; title bar: window frame, not game content, so nothing in-game fires.
        ; Windowed mode only; a borderless/fullscreen window has no title bar.
        WinGetPos &wx, &wy, &ww, , 'ahk_id ' id
        WinGetClientPos &cx, &cy, , , 'ahk_id ' id
        if cy - wy >= 20 {
            ; Screen coordinates for this one click only: every other click
            ; in this script is window-relative (CoordMode at the top), and
            ; leaving Screen set sent them to the wrong places on 2026-10-17.
            CoordMode 'Mouse', 'Screen'
            MouseMove wx + ww // 2, wy + (cy - wy) // 2, 0
            Click
            CoordMode 'Mouse', 'Client'
            if WinWaitActive('ahk_id ' id, , 2)
                break
        }
    }
    if !WinActive('ahk_id ' id)
        throw Error('Game did not receive focus.')
    ; A window that has just become active takes a moment before the game
    ; reads keys again. Without this wait the Escape after a focus click
    ; was lost on 2026-10-17 and the menu clicks that followed fired the
    ; weapon in the world instead of pressing menu buttons.
    if !wasActive
        Sleep 800
    WinGetClientPos , , &w, &h, 'ahk_id ' id
    if w < 800 || h < 450 || Abs(w / h - 16 / 9) > 0.035
        throw Error('This calibration needs a 16:9 game window, at least 800x450.')
    return [w, h]
}
Point(x, y) {
    size := Focus()
    MouseMove Round(x * size[1] / 1280), Round(y * size[2] / 720), 0
    Click 'Down'
    Sleep 120
    Click 'Up'
}
Key(keyName) {
    global HELD_VK, HELD_SC
    Focus()
    if keyName != 'Escape'
        throw Error('Unexpected restart key')
    HELD_VK := 0x1B
    HELD_SC := 0x01
    DllCall('keybd_event', 'UChar', 0x1B, 'UChar', 0x01, 'UInt', 0, 'UPtr', 0)
    Sleep 120
    DllCall('keybd_event', 'UChar', 0x1B, 'UChar', 0x01, 'UInt', 2, 'UPtr', 0)
    HELD_VK := 0
}
Note(message) {
    global REPORT
    FileAppend FormatTime(, 'yyyy-MM-dd HH:mm:ss') ' ' message '`n', REPORT, 'UTF-8'
}
ReleaseKeys(*) {
    global HELD_VK, HELD_SC
    if HELD_VK
        DllCall('keybd_event', 'UChar', HELD_VK, 'UChar', HELD_SC, 'UInt', 2, 'UPtr', 0)
}
