#Requires AutoHotkey v2.0
#SingleInstance Ignore
key := A_Args.Length ? A_Args[1] : ''
if !(key = 'f' || key = 'c' || key = 'v')
    ExitApp 2
wins := WinGetList('ahk_exe Palworld-Win64-Shipping.exe')
if wins.Length != 1
    ExitApp 3
WinActivate 'ahk_id ' wins[1]
if !WinWaitActive('ahk_id ' wins[1], , 5)
    ExitApp 4
vk := GetKeyVK(key)
sc := GetKeySC(key)
OnExit (*) => DllCall('keybd_event', 'UChar', vk, 'UChar', sc, 'UInt', 2, 'UPtr', 0)
DllCall('keybd_event', 'UChar', vk, 'UChar', sc, 'UInt', 0, 'UPtr', 0)
Sleep 850
DllCall('keybd_event', 'UChar', vk, 'UChar', sc, 'UInt', 2, 'UPtr', 0)
