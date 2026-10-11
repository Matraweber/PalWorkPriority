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
$env:CL = ''; $env:_CL_ = ''
$base = @('/nologo','/c','/std:c++latest','/utf-8','/EHsc','/MD','/O2','/DNDEBUG','/W4','/WX')
foreach ($unit in @('entry','entry_test','entry_legacy_test','entry_unrooted_test','owner','record','journal','record_reader','root_capability','backend','draining_writer','journal_test','draining_writer_test')) {
    $source = if ($unit -in @('entry_test','entry_legacy_test','entry_unrooted_test')) { Join-Path $PSScriptRoot 'entry_test.cpp' } elseif ($unit -eq 'entry') { Join-Path $PSScriptRoot 'entry.cpp' } else { Join-Path $repo ('native/save_core/'+($unit -replace '_test$','')+'.cpp') }
    $arguments = $base + @(('/Fo'+$out+'/'+$unit+'.obj'), $source, ('/I'+$PSScriptRoot))
    if ($unit -eq 'entry') {
        $arguments += @('/external:W0', ('/external:I'+$src+'/deps/first/LuaMadeSimple/include'),
            ('/external:I'+$src+'/deps/first/LuaRaw/include'), ('/external:I'+$prereq+'/thirdparty/fmt/include'))
    }
    if ($unit -in @('entry_test','entry_legacy_test','entry_unrooted_test')) {
        $arguments += @(('/I'+$PSScriptRoot+'/test-stubs'),'/DPWP_DRAINING_BRIDGE_TEST')
        if ($unit -eq 'entry_legacy_test') { $arguments += '/DPWP_LEGACY_ENTRY_TEST' }
        if ($unit -eq 'entry_unrooted_test') { $arguments += '/DPWP_UNROOTED_ENTRY_TEST' }
    }
    if ($unit -eq 'journal_test') { $arguments += '/DPWP_JOURNAL_TESTING' }
    if ($unit -eq 'draining_writer_test') { $arguments += '/DPWP_DRAINING_WRITER_TESTING' }
    & "$vc/bin/Hostx64/x64/cl.exe" @arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
& "$vc/bin/Hostx64/x64/dumpbin.exe" /symbols (Join-Path $out 'entry.obj') | Set-Content (Join-Path $out 'symbols.txt')
exit $LASTEXITCODE
