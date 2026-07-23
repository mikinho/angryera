local currentMarkers = {
    target = 8,
    mouseover = 2,
}
local assignments = {}

function _G.GetRaidTargetIndex(unit)
    return currentMarkers[unit]
end

function _G.SetRaidTarget(unit, index)
    assignments[#assignments + 1] = { unit = unit, index = index }
    currentMarkers[unit] = index
end

assert(loadfile("modules/smart_markers.lua"))("AngryEra")

assert(BINDING_HEADER_AngryEra_SMART_MARKERS == "|cff0070DDAngryEra | Smart Markers")
assert(BINDING_NAME_AngryEra_CLEAR_ALL_RAID_TARGETS == "Clear All Raid Targets")
assert(BINDING_NAME_AngryEra_MARK_TARGET_8 == "Assign Skull to Target")
assert(BINDING_NAME_AngryEra_MARK_TARGET_7 == "Assign X to Target")
assert(BINDING_NAME_AngryEra_MARK_MOUSEOVER_1 == "Assign Star to Mouseover")

assert(AngryEra_SetRaidTarget("target", 8) == false, "an unchanged marker should report no change")
assert(#assignments == 0)

assert(AngryEra_SetRaidTarget("mouseover", 3) == true, "a newly assigned marker should report a change")
assert(#assignments == 1)
assert(assignments[1].unit == "mouseover")
assert(assignments[1].index == 3)

assignments = {}
AngryEra_ClearAllRaidTargets()
assert(#assignments == 9)
for position, assignment in ipairs(assignments) do
    assert(assignment.unit == "player")
    assert(assignment.index == 9 - position)
end

print("Smart marker tests passed.")
