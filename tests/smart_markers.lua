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

local mouseover = { exists = false, dead = false, hostile = false }

function _G.UnitExists(unit)
    if unit == "mouseover" then
        return mouseover.exists
    end
    return true
end

function _G.UnitIsDead(unit)
    if unit == "mouseover" then
        return mouseover.dead
    end
    return false
end

function _G.UnitCanAttack(_, unit)
    if unit == "mouseover" then
        return mouseover.hostile
    end
    return false
end

local config = { mouseoverHostileOnly = true }
local angryStub = {
    GetConfig = function(_, key)
        return config[key]
    end,
}

assert(loadfile("modules/smart_markers.lua"))("AngryEra", { AngryEra = angryStub })

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

-- Mouseover marking: hostile-first with fallback to target.
local function ResetMarkState()
    currentMarkers = {}
    assignments = {}
end

-- Default (hostile only): a live hostile mouseover is marked.
config.mouseoverHostileOnly = true
mouseover.exists, mouseover.dead, mouseover.hostile = true, false, true
ResetMarkState()
AngryEra_MarkMouseover(5)
assert(#assignments == 1 and assignments[1].unit == "mouseover", "a hostile mouseover should be marked")

-- Default: a friendly (non-hostile) mouseover falls back to the target.
mouseover.exists, mouseover.dead, mouseover.hostile = true, false, false
ResetMarkState()
AngryEra_MarkMouseover(5)
assert(
    #assignments == 1 and assignments[1].unit == "target",
    "a friendly mouseover should fall back to target when hostile-only"
)

-- Default: no mouseover unit falls back to the target.
mouseover.exists = false
ResetMarkState()
AngryEra_MarkMouseover(5)
assert(#assignments == 1 and assignments[1].unit == "target", "no mouseover unit should fall back to target")

-- Default: a dead hostile mouseover falls back to the target.
mouseover.exists, mouseover.dead, mouseover.hostile = true, true, true
ResetMarkState()
AngryEra_MarkMouseover(5)
assert(#assignments == 1 and assignments[1].unit == "target", "a dead mouseover should fall back to target")

-- Relaxed (setting off): any live mouseover unit is marked, including friendly.
config.mouseoverHostileOnly = false
mouseover.exists, mouseover.dead, mouseover.hostile = true, false, false
ResetMarkState()
AngryEra_MarkMouseover(5)
assert(
    #assignments == 1 and assignments[1].unit == "mouseover",
    "a friendly mouseover should be marked when hostile-only is off"
)

-- Relaxed: a dead mouseover still falls back to the target.
mouseover.exists, mouseover.dead, mouseover.hostile = true, true, false
ResetMarkState()
AngryEra_MarkMouseover(5)
assert(
    #assignments == 1 and assignments[1].unit == "target",
    "a dead mouseover should fall back to target even when relaxed"
)

print("Smart marker tests passed.")
