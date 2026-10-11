#Requires AutoHotkey v2.0
#SingleInstance Ignore
if A_Args.Length != 2
    ExitApp 2
x := Integer(A_Args[1]), y := Integer(A_Args[2])
if x < 0 || x > 1280 || y < 0 || y > 720
    ExitApp 2
wins := WinGetList('ahk_exe Palworld-Win64-Shipping.exe')
if wins.Length != 1
    ExitApp 3
WinActivate 'ahk_id ' wins[1]
if !WinWaitActive('ahk_id ' wins[1], , 5)
    ExitApp 4
CoordMode 'Mouse', 'Client'
WinGetClientPos , , &w, &h, 'ahk_id ' wins[1]
MouseMove Round(x*w/1280), Round(y*h/720), 10
Sleep 800
