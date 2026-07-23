_G.UnitFullName = function()
    return "Viewer", "Pagle"
end
_G.UnitName = function()
    return "Viewer"
end
_G.UnitExists = function(unit)
    return unit == "player"
end
_G.UnitClass = function()
    return "Warrior", "WARRIOR"
end
_G.UnitIsConnected = function()
    return true
end
_G.UnitIsDeadOrGhost = function()
    return false
end
_G.GetNumSubgroupMembers = function()
    return 0
end

local raidRoster = {
    { name = "Zessy", rank = 0 },
    { name = "Kway-OtherRealm", rank = 0 },
    { name = "Uniq-OtherRealm", rank = 0 },
    { name = "Dup-RealmA", rank = 0 },
    { name = "Dup-RealmB", rank = 0 },
    { name = "Viewer", rank = 2 },
}

local inRaid = true
local inGroup = true
local isLeader = true
local isAssistant = false

_G.IsInRaid = function()
    return inRaid
end
_G.IsInGroup = function()
    return inGroup
end
_G.GetNumGroupMembers = function()
    return #raidRoster
end
_G.GetRaidRosterInfo = function(i)
    local member = raidRoster[i]
    if not member then
        return nil
    end
    return member.name, member.rank, 1, 60, "Warrior", "WARRIOR", "Zone", true, false
end
_G.UnitIsGroupLeader = function()
    return isLeader
end
_G.UnitIsGroupAssistant = function()
    return isAssistant
end

local currentMarkers = {}
local assignments = {}
_G.GetRaidTargetIndex = function(unit)
    return currentMarkers[unit]
end
_G.SetRaidTarget = function(unit, index)
    assignments[#assignments + 1] = { unit = unit, index = index }
    currentMarkers[unit] = index
end

local AngryEra = {
    utils = {},
}
local app = {
    AngryEra = AngryEra,
}

assert(loadfile("modules/utils/helpers.lua"))("AngryEra", app)
assert(loadfile("modules/smart_markers.lua"))("AngryEra", app)

local function Reset()
    currentMarkers = {}
    assignments = {}
end

local function FindAssignment(index)
    for _, assignment in ipairs(assignments) do
        if assignment.index == index then
            return assignment.unit
        end
    end
    return nil
end

-- $SQUARE=$MT resolves through metadata to a same-realm exact match.
Reset()
local applied = AngryEra_ApplyAutoMarkers({
    MT = "Zessy",
    SQUARE = "$MT",
})
assert(applied == 1, "a metadata reference should apply one marker, got " .. tostring(applied))
assert(FindAssignment(6) == "raid1", "square should land on the same-realm exact match")

-- Realm-qualified names match cross-realm members exactly.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    SKULL = "Kway-OtherRealm",
})
assert(applied == 1 and FindAssignment(8) == "raid2", "qualified cross-realm names should match exactly")

-- Unqualified names accept a unique cross-realm match.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    TRIANGLE = "Uniq",
})
assert(applied == 1 and FindAssignment(4) == "raid3", "a unique cross-realm short name should match")

-- Ambiguous unqualified names are skipped, never guessed.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    CIRCLE = "Dup",
})
assert(applied == 0 and #assignments == 0, "ambiguous short names must not mark anyone")

-- A realm qualifier resolves the ambiguity.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    CIRCLE = "Dup-RealmB",
})
assert(applied == 1 and FindAssignment(2) == "raid5", "qualified names should resolve ambiguity")

-- Unknown names and non-string values are ignored.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    MOON = "Nosuch",
    STAR = true,
    DIAMOND = 5,
})
assert(applied == 0 and #assignments == 0, "unknown names and non-strings should be ignored")

-- Bare words prefer template variables, then fall back to literal names.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    MOON = "OT1",
    STAR = "Zessy",
}, {
    OT1 = "Kway-OtherRealm",
})
assert(applied == 2, "variables and literals should both resolve, got " .. tostring(applied))
assert(FindAssignment(5) == "raid2", "bare words should prefer template variables")
assert(FindAssignment(1) == "raid1", "literal names should resolve from the roster")

-- Unresolved $references never fall back to literal matching.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    STAR = "$Missing",
})
assert(applied == 0, "an unresolved metadata reference should not mark")

-- Marker keys match case-insensitively; X and CROSS share one marker.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    square = "Zessy",
    CROSS = "Kway-OtherRealm",
    X = "Uniq",
})
assert(FindAssignment(6) == "raid1", "lowercase marker keys should apply")
assert(applied == 2, "cross and x should share one marker, got " .. tostring(applied))
assert(FindAssignment(7) == "raid2", "the first key in canonical order should win the shared marker")

-- Reapplication is idempotent through the same-index guard.
Reset()
AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" })
local callsAfterFirst = #assignments
AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" })
assert(#assignments == callsAfterFirst, "an unchanged marker should not call SetRaidTarget again")

-- Raid members without marking authority never call SetRaidTarget.
Reset()
isLeader = false
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" })
assert(applied == 0 and #assignments == 0, "raiders without authority must not mark")
isAssistant = true
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" })
assert(applied == 1, "raid assistants may mark")
isLeader = true
isAssistant = false

-- Anyone may mark in a party.
Reset()
inRaid = false
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Viewer" })
assert(applied == 1, "party members may mark")
inRaid = true

-- Solo, the player can still be matched directly.
Reset()
inRaid = false
inGroup = false
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Viewer" })
assert(applied == 1 and FindAssignment(6) == "player", "solo matching should fall back to the player unit")
inRaid = true
inGroup = true

-- The displayed-note entry point pulls metadata and variables from the API.
Reset()
function AngryEra:GetDisplayedMeta()
    return { SQUARE = "$MT", MT = "Zessy" }
end
function AngryEra:GetDisplayedVars()
    return {}
end
applied = AngryEra:ApplyDisplayedNoteMarkers()
assert(applied == 1 and FindAssignment(6) == "raid1", "the note entry point should apply markers")

function AngryEra:GetDisplayedMeta()
    return nil
end
applied = AngryEra:ApplyDisplayedNoteMarkers()
assert(applied == 0, "a cleared display should apply nothing")

print("Auto marker tests passed.")
