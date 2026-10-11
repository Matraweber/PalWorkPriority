-- Boundary for COPIED native read results. Does not invoke Engine or the disk.
-- A nil native load or false existence check is never positive absence proof.
-- Missing classification is intentionally unavailable with the V6 API.
local M={}
-- options.max_payload_bytes must exactly match the copied backend advertisement
-- snapshot.max_payload_bytes. Omission on either side means the legacy 64 KiB.
function M.from_native(scope, snapshot, options)
    assert(type(scope)=='string' and #scope>0 and #scope<=256)
    assert(options==nil or type(options)=='table')
    local max_payload_bytes=options and options.max_payload_bytes
    if max_payload_bytes==nil then max_payload_bytes=65536 end
    assert(math.type(max_payload_bytes)=='integer' and max_payload_bytes>=65536
        and max_payload_bytes<=262144,'unsupported payload capacity')
    if type(snapshot)~='table' then return {status='unreadable'} end
    if snapshot.max_payload_bytes~=max_payload_bytes
        and not (snapshot.max_payload_bytes==nil and max_payload_bytes==65536) then
        return {status='unreadable'}
    end
    -- Unknown schema/class/field access failures cannot authorize replacement.
    if snapshot.schema~='PWP-SCRATCH-1' or snapshot.fields_read~=true then
        return {status='unreadable'}
    end
    local r=snapshot.record
    if type(r)~='table' or type(r.session)~='string' or r.session~=scope then
        return {status='unreadable'}
    end
    -- Capacity is not persisted in the native record. A downgrade can encounter
    -- a valid newer save it cannot read; never classify that as replaceable.
    if type(r.payload)=='string' and #r.payload>max_payload_bytes then
        return {status='unreadable'}
    end
    if math.type(r.generation)~='integer' or r.generation<=0 or r.generation>=2147483647
        or type(r.payload)~='string' or type(r.checksum)~='string'
        or #r.checksum~=8 or not r.checksum:match('^[0-9a-f]+$') then
        return {status='invalid'}
    end
    -- Queue verifies the checksum content. Only copy bounded scalar fields;
    -- do not retain the snapshot, record table or any native wrapper.
    return {status='ok',record={session=r.session,generation=r.generation,
        payload=r.payload,checksum=r.checksum}}
end
return M
