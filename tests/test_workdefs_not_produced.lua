-- workdefs: item ids that only look like base products by substring (seen in
-- game 2026-10-22, the picker said "Group limit applies" on Pal souls).
local workdefs = require('workdefs')

-- Real products keep their work type.
assert(workdefs.work_for_item('Stone') == 'Mining')
assert(workdefs.work_for_item('IronOre') == 'Mining')
assert(workdefs.work_for_item('CopperOre') == 'Mining')
assert(workdefs.work_for_item('Pal_crystal_S') == 'Mining')
assert(workdefs.work_for_item('Wood') == 'Deforest')
assert(workdefs.work_for_item('Fiber') == 'Deforest')

-- Look-alikes are made by no base work, and offer no work to cycle through.
for _, id in ipairs({ 'PAL_Growth_Stone_L', 'PAL_Growth_Stone_XL', 'PalUpgradeStone',
        'PalUpgradeStone3', 'ThrowStone', 'SkillUnlock_Manticore', 'SkillUnlock_Manticore_Dark',
        'AIcore', 'CarbonFiber', 'PredatorCrystal', 'PalCrystal_Ex' }) do
    assert(workdefs.work_for_item(id) == nil, id .. ' still claimed by ' .. tostring(workdefs.work_for_item(id)))
    assert(#workdefs.works_for_item(id) == 0, id .. ' still offers a work type')
end
-- Asked twice: the memo keeps the answer.
assert(workdefs.work_for_item('PAL_Growth_Stone_L') == nil)
-- Every ore deposit in the game's item list counts as a rock drop, so its
-- item can get a Mining limit; a non-rock Mining item cannot.
for _, id in ipairs({ 'Stone', 'CopperOre', 'Pal_crystal_S', 'Coal', 'Sulfur', 'Quartz',
        'Chromium', 'ManganeseOre', 'SkyIslandOre', 'WorldTreeOre', 'MeteorDrop' }) do
    assert(workdefs.rock_drop(id), id .. ' is not a rock drop')
end
assert(not workdefs.rock_drop('Thermal_Core') and not workdefs.rock_drop('AIcore'))
-- They reach the picker as Mining at all (round-4 regression review, P3-3).
for _, id in ipairs({ 'Chromium', 'MeteorDrop' }) do assert(workdefs.work_for_item(id) == 'Mining', id) end
-- A cooked Sandwich is not mined because its id contains "sand".
assert(workdefs.work_for_item('Sandwich') == 'EmitFlame', tostring(workdefs.work_for_item('Sandwich')))
print('workdefs: look-alike ids are not base products; real ones keep their work')
