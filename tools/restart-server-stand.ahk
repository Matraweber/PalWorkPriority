#Requires AutoHotkey v2.0
#SingleInstance Ignore
; RAM dedicated-server client restart. Start at the stand with its grid OPEN.
; Calibrated RAM entry: second Recent Servers row. Recalibrate if list changes.
; Does not restart GPortal or store a password; uses the game saved-password prompt.
; --world: stand grid is closed. --title: already on the title menu.
; --check: syntax/config check only. Pause / ScrollLock abort immediately.
; --open-only: already facing the stand in gameplay; hold V without restarting.
; Window-relative 16:9 calibration. Never kills the game or edits its saves.
GAME := 'D:\Steam\steamapps\common\Palworld'
EXE := GAME '\Pal\Binaries\Win64\Palworld-Win64-Shipping.exe'
GAME_LOG := GAME '\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\priority.log'
REPORT := A_ScriptDir '\restart-server-last-run.log'
SERVER := EnvGet('PWP_SERVER') || 'server address not set'  ; real address lives only in the Desktop copy; it is only logged
EXPECTED_GUILD := '-357895952-1262986004-1392804764--410933938'
REMOTE := GAME '\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\remote.txt'
MODE := A_Args.Length ? A_Args[1] : '--stand'
HELD_VK := 0
HELD_SC := 0
if MODE = '--self-test' {
    SelfTest()
    ExitApp 0
}
if MODE = '--check'
    ExitApp FileExist(EXE) && FileExist(GAME_LOG) && FileExist(REMOTE) ? 0 : 2
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
    offset := FileGetSize(GAME_LOG)
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
    Point(639, 442) ; Join Multiplayer Game
    Sleep 7000
    Point(198, 269) ; Recent Servers
    ClickServer()
    Sleep 2500
    Point(640, 461) ; Accept game-stored password; no password in this macro
    Sleep 1500
    Point(552, 477) ; Confirm connection
    deadline := A_TickCount + 150000
    ready := false
    while A_TickCount < deadline {
        if !ProcessExist(newPid)
            throw Error('Game exited during server loading.')
        fresh := ReadSince(offset)
        ; Only ask for a diagnostic snapshot after a fresh world transition.
        ; The title screen can itself report authority, so it is not readiness.
        if InStr(fresh, 'world key: World ') {
            responseOffset := FileGetSize(GAME_LOG)
            Probe()
            Sleep 2500
            reply := ReadSince(responseOffset)
            state := ClassifyReply(reply)
            if state = 'ready' {
                ready := true
                break
            }
            if state = 'mismatch'
                throw Error('Unexpected server guild; stopped without opening or editing the stand.')
        }
        Sleep 3000
    }
    if !ready
        throw Error('No fresh matching multiplayer synchronization. Check connection/password; no stand key sent.')
    Sleep 12000 ; gameplay readiness precedes completion of the loading fade
    Key('Escape') ; close/open vanilla pause once to recover post-join focus
    Sleep 900
    Key('Escape')
    Sleep 900
    Focus()
    HELD_VK := 0x56
    HELD_SC := 0x2F
    DllCall('keybd_event', 'UChar', 0x56, 'UChar', 0x2F, 'UInt', 0, 'UPtr', 0)
    Sleep 850
    DllCall('keybd_event', 'UChar', 0x56, 'UChar', 0x2F, 'UInt', 2, 'UPtr', 0)
    HELD_VK := 0
    Sleep 3000
    Note('SERVER_READY endpoint=' SERVER ' guild=' EXPECTED_GUILD ' pid=' newPid)
    Note('Stand-open key sent. Visual confirmation is required; this is not an edit/pass receipt.')
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
        ; Same fallback as restart-stand.ahk (2026-10-17): the foreground lock
        ; refuses programmatic switches while the text input host holds the
        ; foreground, but a click on the title bar is input and activates the
        ; window. Screen coordinates for this one click only.
        WinGetPos &wx, &wy, &ww, , 'ahk_id ' id
        WinGetClientPos &cx, &cy, , , 'ahk_id ' id
        if cy - wy >= 20 {
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
    Sleep 180 ; allow the game to update hover before pressing
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

ReadSince(offset) {
    global GAME_LOG
    f := FileOpen(GAME_LOG, 'r', 'UTF-8')
    if !f
        throw Error('Cannot read client log.')
    if f.Length < offset {
        f.Close()
        throw Error('Client log was truncated; refusing stale readiness.')
    }
    f.Pos := offset
    result := f.Read()
    f.Close()
    return result
}
Probe() {
    global REMOTE
    if !FileExist(REMOTE)
        throw Error('Developer channel was not enabled before launch.')
    temp := REMOTE '.server-macro.tmp'
    f := FileOpen(temp, 'w', 'UTF-8-RAW')
    if !f
        throw Error('Cannot write diagnostic request.')
    f.Write('server-macro-' A_TickCount '`npwp status`npwp net`n')
    f.Close()
    FileMove temp, REMOTE, 1
}

ClassifyReply(reply) {
    global EXPECTED_GUILD
    if !InStr(reply, 'synchronization: client; ready')
        || !InStr(reply, 'authority: client; server owns assignments')
        return 'pending'
    if !RegExMatch(reply, 'server guild: ([^\r\n]+)', &m)
        return 'pending'
    guild := Trim(m[1])
    if guild = 'unavailable'
        return 'pending'
    return guild = EXPECTED_GUILD ? 'ready' : 'mismatch'
}
SelfTest() {
    global EXPECTED_GUILD
    prefix := 'authority: client; server owns assignments`nsynchronization: client; ready`n'
    cases := [
        ['', 'pending'],
        ['PWP_READY session=0 role=authority settings=available', 'pending'],
        ['sync: connecting`nserver guild: unavailable', 'pending'],
        [prefix 'server guild: unavailable', 'pending'],
        [prefix, 'pending'],
        [prefix 'server guild: ' EXPECTED_GUILD '`r`n', 'ready'],
        [prefix 'server guild: wrong', 'mismatch'],
        [prefix 'server guild: ' EXPECTED_GUILD 'extra', 'mismatch'],
        ['synchronization: client; ready`nserver guild: ' EXPECTED_GUILD, 'pending']
    ]
    for row in cases
        if ClassifyReply(row[1]) != row[2]
            throw Error('Readiness regression failed: ' row[2])
    FileAppend 'PASS 9 server readiness cases`n', '*'
}

ClickServer() {
    ; Verified RAM is the second Recent Servers entry on this installation.
    ; The guild handshake below refuses stand input in any other world.
    Point(420, 211)
    Note('Selected calibrated RAM row; awaiting verified guild handshake.')
}
