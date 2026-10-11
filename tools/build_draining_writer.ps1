param([Parameter(Mandatory=$true)][string]$OutputDirectory,[switch]$RunTests)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$out=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$vc='C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/MSVC/14.50.35717'
$sdk='C:/Program Files (x86)/Windows Kits/10'; $ver='10.0.26100.0'
$env:INCLUDE="$vc/include;$sdk/Include/$ver/ucrt;$sdk/Include/$ver/um;$sdk/Include/$ver/shared"
$env:LIB="$vc/lib/x64;$sdk/Lib/$ver/ucrt/x64;$sdk/Lib/$ver/um/x64"
$env:CL='';$env:_CL_='';$env:LINK='';$env:_LINK_=''
$sources=@('root_capability','owner','record','record_reader','journal','backend','draining_writer','draining_writer_test') | ForEach-Object { "$repo/native/save_core/$_.cpp" }
$tracked=@($sources)+@($sources | ForEach-Object { $_ -replace '\.cpp$','.hpp' } | Where-Object {Test-Path -LiteralPath $_})+@($PSCommandPath)
$before=@{}
foreach($path in $tracked){$before[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
# Also compile the production branch with no test seams.
& "$vc/bin/Hostx64/x64/cl.exe" /nologo /std:c++17 /W4 /WX /EHsc /MD /O2 /DNDEBUG /c "/Fo$out/draining-production.obj" "$repo/native/save_core/draining_writer.cpp"
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
foreach($flavor in @('normal','fault')) {
    $defines=@('/DPWP_DRAINING_WRITER_TESTING')
    if($flavor -eq 'fault'){$defines+=@('/DPWP_JOURNAL_TESTING','/DPWP_DRAINING_LANE_TESTING')}
    & "$vc/bin/Hostx64/x64/cl.exe" /nologo /std:c++17 /W4 /WX /EHsc /MD /O2 /DNDEBUG @defines "/Fo$out/" "/Fe$out/draining-$flavor.exe" @sources /link bcrypt.lib
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
}
if($RunTests){
    foreach($case in @('success','existing','unapproved','blocked','conflict','uncertain','ioerror','warning','capacity','destructor','inert','uncertain-tail','two-streams')){
        $root=Join-Path $out $case
        if(Test-Path -LiteralPath $root){throw "Refusing existing fixture root: $root"}
        New-Item -ItemType Directory -Path $root | Out-Null
        $flavor=if($case -in @('uncertain','uncertain-tail','ioerror','warning','two-streams')){'fault'}else{'normal'}
        & "$out/draining-$flavor.exe" $root $case
        if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
    }
    # Independent byte-for-byte encoder/hash comparison after helper processes exit.
    # No imported production codec and no Python assert (also valid under -O).
    @'
import hashlib, pathlib, struct, sys
out=pathlib.Path(sys.argv[1])
scope='PWP-SCOPE-1:'+32*'1'+':'+32*'2'+':priorities'
def envelope(generation,payload,record_scope=scope):
    scope_bytes=record_scope.encode()
    body=b'PWPJNL1\n'+struct.pack('<HII',len(scope_bytes),generation,len(payload))+scope_bytes+payload
    return body+hashlib.sha256(body).digest()
latest=b'z'*262144
expected={
 'success':{'A':(1,b'exact-init'),'B':(2,latest)},
 'destructor':{'A':(1,b'exact-init'),'B':(2,latest)},
 'existing':{'A':(6,b'exact-init'),'B':(7,latest)},
 'warning':{'A':(6,b'exact-init'),'B':(7,latest)},
 'conflict':{'B':(1,b'external')},
 'uncertain':{'A':(1,b'exact-init')},
 'uncertain-tail':{'A':(1,b'exact-init'),'B':(2,latest)},
 'ioerror':{},'unapproved':{},'capacity':{},
}
for case,slots in expected.items():
    leaves={p.name[-8]:p for p in (out/case).glob('pwp-record-v1-*.record')}
    if set(leaves)!=set(slots): raise RuntimeError('wrong slots: '+case)
    for slot,(gen,payload) in slots.items():
        if leaves[slot].read_bytes()!=envelope(gen,payload): raise RuntimeError('wrong complete bytes: '+case+slot)
two=out/'two-streams'
expected_names=set()
for stream in ('priorities','limits'):
    for slot,gen,prefix in (('A',3,'latest-'),('B',2,'middle-')):
        name='pwp-record-v1-'+32*'1'+'-'+32*'2'+'-'+stream+'-'+slot+'.record'
        expected_names.add(name)
        wire=envelope(gen,(prefix+stream).encode(),scope.rsplit(':',1)[0]+':'+stream)
        if (two/name).read_bytes()!=wire: raise RuntimeError('wrong concurrent complete record: '+name)
if {p.name for p in two.iterdir()}!=expected_names: raise RuntimeError('concurrent artifacts/unexpected slots')
print('PASS independent SHA256 wire encoder: exact slots/headers/scopes/generations/full payloads after process exit')
'@ | python -B -O - $out
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
    foreach($path in $tracked){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $before[$path]){throw "Source changed during build/test: $path"}}
    $receipt=@{passed=$true;installed=$false;game_test=$false;cases=13;independent_full_bytes=$true;source_hashes=$before;binaries=@{}}
    foreach($flavor in @('normal','fault')){$receipt.binaries[$flavor]=(Get-FileHash -LiteralPath "$out/draining-$flavor.exe" -Algorithm SHA256).Hash}
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$out/receipt.json"
}
