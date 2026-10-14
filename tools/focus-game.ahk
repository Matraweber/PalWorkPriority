#Requires AutoHotkey v2.0
; Bring the Palworld window to the front. Sends no keys.
if WinExist('ahk_exe Palworld-Win64-Shipping.exe') {
    WinActivate
    WinWaitActive(, , 3)
}
