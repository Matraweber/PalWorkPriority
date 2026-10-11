param([Parameter(Mandatory=$true)][string]$OutputDirectory, [switch]$CoreOnly)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$out = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$compilerRoot = 'C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/MSVC/14.50.35717'
$sdk = 'C:/Program Files (x86)/Windows Kits/10'
$version = '10.0.26100.0'
$env:INCLUDE = "$compilerRoot/include;$sdk/Include/$version/ucrt;$sdk/Include/$version/um;$sdk/Include/$version/shared"
$env:LIB = "$compilerRoot/lib/x64;$sdk/Lib/$version/ucrt/x64;$sdk/Lib/$version/um/x64"
$argsList = @('/nologo','/std:c++17','/W4','/WX','/EHsc','/MD')
if ($CoreOnly) {
    $argsList += @('/c', ('/Fo'+$out+'\initialization-no-hooks.obj'), "$repo/native/save_core/initialization.cpp")
} else {
    $argsList += @('/DPWP_INITIALIZATION_TESTING', ('/Fo'+$out+'\'), ('/Fe'+$out+'\initialization-test.exe'),
        "$repo/native/save_core/initialization.cpp", "$repo/native/save_core/test_cli.cpp", '/link','bcrypt.lib')
}
& "$compilerRoot/bin/Hostx64/x64/cl.exe" @argsList
exit $LASTEXITCODE
