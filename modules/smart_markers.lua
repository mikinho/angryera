-- -------------------------------------------------------------------------------
-- Angry Era: modules/smart_markers.lua
--
-- Target and mouseover raid-marker keybindings.
-- -------------------------------------------------------------------------------

local appName = ...

local markerNames = {
    [1] = "Star",
    [2] = "Circle",
    [3] = "Diamond",
    [4] = "Triangle",
    [5] = "Moon",
    [6] = "Square",
    [7] = "X",
    [8] = "Skull",
}

_G["BINDING_HEADER_" .. appName .. "_SMART_MARKERS"] = "|cff0070DD" .. appName .. " | Smart Markers"
_G["BINDING_NAME_" .. appName .. "_CLEAR_ALL_RAID_TARGETS"] = "Clear All Raid Targets"

for index = 8, 1, -1 do
    local markerName = markerNames[index]
    _G["BINDING_NAME_" .. appName .. "_MARK_TARGET_" .. index] = "Assign " .. markerName .. " to Target"
    _G["BINDING_NAME_" .. appName .. "_MARK_MOUSEOVER_" .. index] = "Assign " .. markerName .. " to Mouseover"
end

function AngryEra_SetRaidTarget(unit, index)
    if GetRaidTargetIndex(unit) ~= index then
        SetRaidTarget(unit, index)
    end
end

function AngryEra_ClearAllRaidTargets()
    for index = 8, 0, -1 do
        SetRaidTarget("player", index)
    end
end
