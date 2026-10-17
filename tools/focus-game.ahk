#Requires AutoHotkey v2.0
; Bring the Palworld window to the front. Sends no keys.
; If Windows refuses the switch (the foreground lock; on 2026-10-17 the text
; input host held the foreground), click the window's title bar: a click is
; input, so the clicked window becomes active, and the title bar is window
; frame, not game content, so nothing in-game fires.
if !WinExist('ahk_exe Palworld-Win64-Shipping.exe')
    ExitApp 1
id := WinExist()
WinActivate 'ahk_id ' id
if WinWaitActive('ahk_id ' id, , 2)
    ExitApp 0
WinGetPos &wx, &wy, &ww, , 'ahk_id ' id
WinGetClientPos &cx, &cy, , , 'ahk_id ' id
if cy - wy >= 20 {
    CoordMode 'Mouse', 'Screen'
    MouseMove wx + ww // 2, wy + (cy - wy) // 2, 0
    Click
}
ExitApp WinWaitActive('ahk_id ' id, , 2) ? 0 : 2
