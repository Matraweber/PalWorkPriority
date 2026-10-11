param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$out=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$vc='C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/MSVC/14.50.35717'
$sdk='C:/Program Files (x86)/Windows Kits/10'
$ver='10.0.26100.0'
$env:INCLUDE="$vc/include;$sdk/Include/$ver/ucrt;$sdk/Include/$ver/um;$sdk/Include/$ver/shared"
$env:LIB="$vc/lib/x64;$sdk/Lib/$ver/ucrt/x64;$sdk/Lib/$ver/um/x64"
$env:CL='';$env:_CL_=''
& "$vc/bin/Hostx64/x64/cl.exe" /nologo /std:c++17 /W4 /WX /EHsc /MD /O2 /DNDEBUG "/Fo$out/" "/Fe$out/record-test.exe" "$repo/native/save_core/record.cpp" "$repo/native/save_core/record_cli.cpp" /link bcrypt.lib
exit $LASTEXITCODE
