$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$prereq = Join-Path $repo 'test-results/native-helper-prerequisites-2281fa31'
$src = Join-Path $prereq 'source'
$out = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$vc = 'C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/MSVC/14.50.35717'
$sdk = 'C:/Program Files (x86)/Windows Kits/10'
$ver = '10.0.26100.0'
$env:INCLUDE = "$vc/include;$sdk/Include/$ver/ucrt;$sdk/Include/$ver/um;$sdk/Include/$ver/shared"
$env:LIB = "$vc/lib/x64;$sdk/Lib/$ver/ucrt/x64;$sdk/Lib/$ver/um/x64"
$env:CL = ''
$env:_CL_ = ''
$argsList = @('/nologo','/c','/std:c++latest','/utf-8','/EHsc','/MD','/O2','/DNDEBUG',
    ('/I'+$src+'/deps/first/LuaMadeSimple/include'), ('/I'+$src+'/deps/first/LuaRaw/include'),
    ('/I'+$prereq+'/thirdparty/fmt/include'), ('/Fo'+$out+'/entry.obj'), (Join-Path $PSScriptRoot 'entry.cpp'))
& "$vc/bin/Hostx64/x64/cl.exe" @argsList 2>&1 | Tee-Object (Join-Path $out 'compile.log')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& "$vc/bin/Hostx64/x64/dumpbin.exe" /symbols (Join-Path $out 'entry.obj') | Set-Content (Join-Path $out 'symbols.txt')
exit $LASTEXITCODE

