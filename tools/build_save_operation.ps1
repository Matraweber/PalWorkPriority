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
$env:CL='';$env:_CL_='';$env:LINK='';$env:_LINK_=''
& "$vc/bin/Hostx64/x64/cl.exe" /nologo /std:c++17 /W4 /WX /EHsc /MD /O2 /DNDEBUG "/Fo$out/" "/Fe$out/operation-test.exe" "$repo/native/save_core/owner.cpp" "$repo/native/save_core/record.cpp" "$repo/native/save_core/journal.cpp" "$repo/native/save_core/operation.cpp" "$repo/native/save_core/operation_test.cpp" /link bcrypt.lib
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
# Separate binary: test-only forwarding seam compiles the actual operation.cpp,
# counts every journal invocation, and enables journal fault-boundary hooks.
# The normal binary above has neither the seam nor PWP_JOURNAL_TESTING.
& "$vc/bin/Hostx64/x64/cl.exe" /nologo /std:c++17 /W4 /WX /EHsc /MD /O2 /DNDEBUG /DPWP_JOURNAL_TESTING /DPWP_OPERATION_TESTING "/Fo$out/" "/Fe$out/operation-fault-test.exe" "$repo/native/save_core/owner.cpp" "$repo/native/save_core/record.cpp" "$repo/native/save_core/journal.cpp" "$repo/native/save_core/operation_test_hooks.cpp" "$repo/native/save_core/operation_test.cpp" /link bcrypt.lib
exit $LASTEXITCODE
