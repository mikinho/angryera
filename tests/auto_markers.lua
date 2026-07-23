_G.UnitFullName = function()
    return "Viewer", "Pagle"
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
local baseRaidRoster = {
    { name = "Zessy", rank = 0 },
    { name = "Kway-OtherRealm", rank = 0 },
    { name = "Uniq-OtherRealm", rank = 0 },
    { name = "Dup-RealmA", rank = 0 },
    { name = "Dup-RealmB", rank = 0 },
    { name = "Viewer", rank = 2 },
}

local function CopyRaidRoster()
    local copy = {}
    for index, member in ipairs(baseRaidRoster) do
        copy[index] = {
            name = member.name,
            rank = member.rank,
        }
    end
    return copy
end

local raidRoster = CopyRaidRoster()
local partyRoster = {}
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
_G.GetNumSubgroupMembers = function()
    return #partyRoster
end
_G.UnitName = function(unit)
    if unit == "player" then
        return "Viewer", "Pagle"
    end
    local partyIndex = type(unit) == "string" and tonumber(unit:match("^party(%d+)$")) or nil
    local member = partyIndex and partyRoster[partyIndex] or nil
    if member then
        return member.name, member.realm
    end
end
_G.UnitExists = function(unit)
    if unit == "player" then
        return true
    end
    local partyIndex = type(unit) == "string" and tonumber(unit:match("^party(%d+)$")) or nil
    return not inRaid and inGroup and partyIndex ~= nil and partyRoster[partyIndex] ~= nil
end
_G.UnitIsGroupLeader = function()
    return isLeader
end
_G.UnitIsGroupAssistant = function()
    return isAssistant
end

local currentMarkers = {}
local assignments = {}
local markerWritesEnabled = true
local function FullRosterName(name, realm)
    if type(realm) == "string" and realm ~= "" then
        return name .. "-" .. realm
    end
    if name and name:find("-", 1, true) then
        return name
    end
    return name and (name .. "-Pagle") or nil
end

local function UnitIdentity(unit)
    if unit == "player" then
        return "Viewer-Pagle"
    end
    local raidIndex = type(unit) == "string" and tonumber(unit:match("^raid(%d+)$")) or nil
    if raidIndex and raidRoster[raidIndex] then
        return FullRosterName(raidRoster[raidIndex].name)
    end
    local partyIndex = type(unit) == "string" and tonumber(unit:match("^party(%d+)$")) or nil
    if partyIndex and partyRoster[partyIndex] then
        local member = partyRoster[partyIndex]
        return FullRosterName(member.name, member.realm)
    end
    return unit
end

_G.GetRaidTargetIndex = function(unit)
    return currentMarkers[UnitIdentity(unit)]
end
_G.SetRaidTarget = function(unit, index)
    assignments[#assignments + 1] = { unit = unit, index = index }
    if not markerWritesEnabled then
        return
    end
    local identity = UnitIdentity(unit)
    if index == 0 then
        currentMarkers[identity] = nil
        return
    end
    for otherIdentity, markerIndex in pairs(currentMarkers) do
        if markerIndex == index then
            currentMarkers[otherIdentity] = nil
        end
    end
    currentMarkers[identity] = index
end

local AngryEra = {
    utils = {},
}
local app = {
    AngryEra = AngryEra,
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/utils/helpers.lua"))("AngryEra", app)
assert(loadfile("modules/smart_markers.lua"))("AngryEra", app)

local function Reset()
    markerWritesEnabled = true
    isLeader = true
    isAssistant = false
    inRaid = true
    inGroup = true
    AngryEra_ApplyAutoMarkers(nil, nil)
    raidRoster = CopyRaidRoster()
    partyRoster = {}
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

local function CountAssignments(index)
    local count = 0
    for _, assignment in ipairs(assignments) do
        if assignment.index == index then
            count = count + 1
        end
    end
    return count
end

-- The real merge and partition pipeline bridges a public variable into
-- metadata, after which $SQUARE=$MT resolves through the metadata table.
Reset()
local variables = AngryEra.utils.variables
local merged, mergeError = variables.MergeVariableLayers({}, "MT=Zessy\n$MT={{MT}}\n$SQUARE=$MT")
assert(merged and not mergeError, "the marker bridge should merge through the production variable resolver")
local publicVars, markerMeta, partitionError = variables.PartitionResolvedVariables(merged)
assert(publicVars and markerMeta and not partitionError, "the resolved bridge should partition")
assert(publicVars.MT == "Zessy", "the public MT variable should remain available")
assert(markerMeta.MT == "Zessy", "$MT={{MT}} should bridge the public value into metadata")
assert(markerMeta.SQUARE == "$MT", "$SQUARE=$MT should remain a metadata reference")
local applied = AngryEra_ApplyAutoMarkers(markerMeta, publicVars)
assert(applied == 1, "the production marker bridge should apply one marker, got " .. tostring(applied))
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
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" }, nil, "page:one")
assert(applied == 1, "the initial marker assignment should be counted")
local callsAfterFirst = #assignments
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" }, nil, "page:one")
assert(applied == 0, "an unchanged marker should not be counted as applied")
assert(#assignments == callsAfterFirst, "an unchanged marker should not call SetRaidTarget again")

-- A different page starts a new lifecycle even when it inherits the same plan.
currentMarkers["Zessy-Pagle"] = 1
assignments = {}
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" }, nil, "page:two")
assert(applied == 1, "a new page should reapply its inherited marker plan")
assert(FindAssignment(6) == "raid1", "the new page should restore its requested square")

-- A new note reconciles addon-owned markers that it no longer requests.
Reset()
AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" })
assignments = {}
applied = AngryEra_ApplyAutoMarkers({ SKULL = "Kway-OtherRealm" })
assert(applied == 1, "the replacement note should apply its new marker")
assert(
    #assignments == 2 and assignments[1].unit == "raid1" and assignments[1].index == 0,
    "the replacement note should clear its stale square first"
)
assert(assignments[2].unit == "raid2" and assignments[2].index == 8, "the replacement skull should be applied")

-- A blank or cleared display removes the remaining addon-owned marker.
assignments = {}
applied = AngryEra_ApplyAutoMarkers(nil, nil)
assert(applied == 0, "clearing a display should not count marker removals as applications")
assert(
    #assignments == 1 and assignments[1].unit == "raid2" and assignments[1].index == 0,
    "clearing a display should remove its addon-owned marker"
)

-- A manual reassignment revokes ownership and is never cleared or reasserted.
Reset()
AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" })
currentMarkers["Zessy-Pagle"] = 1
assignments = {}
AngryEra_ApplyAutoMarkers(nil, nil)
assert(#assignments == 0, "clearing a note must preserve a marker that someone changed manually")
assert(currentMarkers["Zessy-Pagle"] == 1, "the manual replacement marker should remain")

-- A pre-existing matching marker is a no-op and is never claimed as addon-owned.
Reset()
currentMarkers["Zessy-Pagle"] = 6
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" })
assert(applied == 0 and #assignments == 0, "a pre-existing matching marker should be an unowned no-op")
AngryEra_ApplyAutoMarkers(nil, nil)
assert(#assignments == 0, "a pre-existing matching marker should survive the note being cleared")

-- Ownership follows a stable full name when raid unit tokens are reordered.
Reset()
AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" })
assignments = {}
raidRoster[1], raidRoster[3] = raidRoster[3], raidRoster[1]
AngryEra_ApplyAutoMarkers(nil, nil)
assert(
    #assignments == 1 and assignments[1].unit == "raid3" and assignments[1].index == 0,
    "stale cleanup should find the original player after roster token changes"
)

-- Roster retries apply only targets that have never resolved.
Reset()
applied = AngryEra_ApplyAutoMarkers({
    SQUARE = "Zessy",
    SKULL = "Late-OtherRealm",
})
assert(applied == 1 and FindAssignment(6) == "raid1", "the present target should resolve immediately")
currentMarkers["Zessy-Pagle"] = 1
assignments = {}
raidRoster[#raidRoster + 1] = { name = "Late-OtherRealm", rank = 0 }
applied = AngryEra:RetryDisplayedNoteMarkers()
assert(applied == 1, "a late roster member should resolve on the roster retry")
assert(FindAssignment(8) == "raid7", "the retry should apply the pending skull to the late member")
assert(CountAssignments(6) == 0, "the retry must not reassert an already-resolved square")
assert(currentMarkers["Zessy-Pagle"] == 1, "the retry must preserve a manual marker change")
assignments = {}
applied = AngryEra:RetryDisplayedNoteMarkers()
assert(applied == 0 and #assignments == 0, "resolved markers should not run again on later roster updates")

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

-- Cleanup is deferred while authority is absent and resumes when it returns.
Reset()
AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" }, nil, "page:owned")
assignments = {}
isLeader = false
AngryEra_ApplyAutoMarkers(nil, nil, nil)
assert(#assignments == 0, "losing authority must defer stale marker cleanup")
assert(currentMarkers["Zessy-Pagle"] == 6, "the owned marker remains until cleanup is authorized")
isAssistant = true
applied = AngryEra:RetryDisplayedNoteMarkers()
assert(applied == 0, "deferred cleanup is not counted as a marker application")
assert(currentMarkers["Zessy-Pagle"] == nil, "restored authority should clear the stale owned marker")
assert(#assignments == 1 and assignments[1].index == 0, "restored authority should perform exactly one deferred clear")
isLeader = true
isAssistant = false

-- Failed marker writes remain pending instead of being treated as resolved.
Reset()
markerWritesEnabled = false
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Zessy" }, nil, "page:write-retry")
assert(applied == 0 and #assignments == 1, "a failed assignment should not count as applied")
markerWritesEnabled = true
assignments = {}
applied = AngryEra:RetryDisplayedNoteMarkers()
assert(applied == 1 and FindAssignment(6) == "raid1", "a failed assignment should retry after the API recovers")

-- Failed clears retain ownership and retry rather than leaking a stale marker.
markerWritesEnabled = false
assignments = {}
AngryEra_ApplyAutoMarkers(nil, nil, nil)
assert(currentMarkers["Zessy-Pagle"] == 6, "a failed clear should leave the marker in place")
markerWritesEnabled = true
assignments = {}
applied = AngryEra:RetryDisplayedNoteMarkers()
assert(applied == 0, "a retried clear should not count as an application")
assert(currentMarkers["Zessy-Pagle"] == nil, "a failed clear should be retried once writes recover")
assert(#assignments == 1 and assignments[1].index == 0, "the retained cleanup should issue one clear")

-- Anyone may mark in a party.
Reset()
inRaid = false
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Viewer" })
assert(applied == 1, "party members may mark")
inRaid = true

-- Party iteration preserves UnitName's realm return for exact matching.
Reset()
inRaid = false
partyRoster = {
    { name = "Kway", realm = "OtherRealm" },
}
applied = AngryEra_ApplyAutoMarkers({ SQUARE = "Kway-OtherRealm" })
assert(applied == 1 and FindAssignment(6) == "party1", "qualified cross-realm party names should match exactly")

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
assignments = {}
applied = AngryEra:ApplyDisplayedNoteMarkers()
assert(applied == 0, "a cleared display should apply nothing")
assert(
    #assignments == 1 and assignments[1].unit == "raid1" and assignments[1].index == 0,
    "the displayed-note entry point should clear its stale owned marker"
)

print("Auto marker tests passed.")
