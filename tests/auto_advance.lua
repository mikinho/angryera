local inRaid = true
local inGroup = true
_G.IsInRaid = function()
    return inRaid
end
_G.IsInGroup = function()
    return inGroup
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
assert(loadfile("modules/encounters.lua"))("AngryEra", app)

local localInstallationId = "ae3i:1:2:3:4"
local function CategorySyncId(counter)
    return localInstallationId .. ":category:" .. counter
end

local isLeader = true
function AngryEra:IsPlayerRaidLeader()
    return isLeader
end

local displayedCalls = {}
local displayResult = true
function AngryEra:DisplayPage(id)
    displayedCalls[#displayedCalls + 1] = id
    if displayResult == true then
        AngryAssign_State.displayed = id
    end
    return displayResult
end

_G.AngryAssign_Categories = {
    [1] = {
        Id = 1,
        Name = "Molten Core",
        SyncId = CategorySyncId(1),
        Vars = "$AUTOADVANCE=true",
    },
    [2] = {
        Id = 2,
        Name = "Onyxia's Lair",
        SyncId = CategorySyncId(2),
        Vars = "",
    },
    [3] = {
        Id = 3,
        Name = "Alternate",
        SyncId = CategorySyncId(3),
        Vars = "$AUTOADVANCE=true",
    },
}
_G.AngryAssign_Pages = {
    [10] = { Id = 10, Name = "Lucifron", CategoryId = 1, Index = 1, Contents = "", Vars = "" },
    [11] = { Id = 11, Name = "Magmadar", CategoryId = 1, Index = 2, Contents = "", Vars = "" },
    [12] = { Id = 12, Name = "Patch", CategoryId = 1, Index = 3, Contents = "", Vars = "$ENCOUNTERID=1112" },
    [13] = { Id = 13, Name = "Ragnaros", CategoryId = 1, Index = 4, Contents = "", Vars = "$AUTOADVANCE=false" },
    [14] = { Id = 14, Name = "Loot", CategoryId = 1, Index = 5, Contents = "", Vars = "" },
    [20] = { Id = 20, Name = "Onyxia", CategoryId = 2, Index = 1, Contents = "", Vars = "" },
    [21] = { Id = 21, Name = "Whelps", CategoryId = 2, Index = 2, Contents = "", Vars = "" },
    [30] = { Id = 30, Name = "Onyxia", CategoryId = 3, Index = 1, Contents = "", Vars = "" },
    [31] = { Id = 31, Name = "Broodlings", CategoryId = 3, Index = 2, Contents = "", Vars = "" },
    [40] = { Id = 40, Name = "Rootless", Contents = "", Vars = "" },
}
_G.AngryAssign_State = { displayed = 10 }

local function Reset(displayedId)
    displayedCalls = {}
    displayResult = true
    AngryAssign_State.displayed = displayedId
end

-- A kill advances from the name-matched page to the next sibling.
Reset(10)
local advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == true and result == 11, "a kill should advance to the next page")
assert(displayedCalls[1] == 11, "the next sibling should be displayed")

-- Wipes never advance.
Reset(10)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 0)
assert(advanced == false and result == "encounter-not-defeated", "a wipe must not advance")
assert(#displayedCalls == 0, "a wipe must not display anything")

-- The encounter name anchors even when a different page is displayed.
Reset(12)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "LUCIFRON", 9, 40, 1)
assert(advanced == true and result == 11, "name matching should be case-insensitive and anchored")
assert(displayedCalls[1] == 11, "the page after the killed boss should be displayed")

-- Advancing onto the already-displayed page is a quiet no-op.
Reset(11)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "already-displayed", "no re-display when already ahead")
assert(#displayedCalls == 0, "no display call when already ahead")

-- $ENCOUNTERID binds pages whose names differ from the encounter.
Reset(11)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 1112, "Patchwerk", 9, 40, 1)
assert(advanced == true and result == 13, "$ENCOUNTERID should anchor the advance")

-- A page-level $AUTOADVANCE=false stops the chain at that boss.
Reset(13)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 672, "Ragnaros", 9, 40, 1)
assert(advanced == false and result == "auto-advance-disabled", "a false page flag should stop the chain")

-- Categories without $AUTOADVANCE never advance.
Reset(20)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 1084, "Whelps", 9, 40, 1)
assert(advanced == false and result == "auto-advance-disabled", "advancement is opt-in per category")

-- Ambiguous name matches prefer the displayed page's category.
Reset(30)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 1084, "Onyxia", 9, 40, 1)
assert(advanced == true and result == 31, "ambiguous names should prefer the displayed category")

-- Ambiguous name matches with no displayed anchor fall back to the displayed page.
Reset(10)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9999, "Onyxia", 9, 40, 1)
assert(advanced == true and result == 11, "an unmatched kill should advance from the displayed page")

-- The last page in a category stays put.
Reset(14)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9999, "Unknown", 9, 40, 1)
assert(advanced == false and result == "no-next-page", "the final page should not advance")

-- Non-leaders in a group never advance.
Reset(10)
isLeader = false
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "not-raid-leader", "only the leader advances in a group")
assert(#displayedCalls == 0, "non-leaders must not display")
isLeader = true

-- Solo players advance their own preview.
Reset(10)
inRaid = false
inGroup = false
isLeader = false
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == true and result == 11, "solo advancement should work without a leader")
inRaid = true
inGroup = true
isLeader = true

-- Rootless displayed pages cannot anchor a fallback.
Reset(40)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9999, "Unknown", 9, 40, 1)
assert(advanced == false and result == "no-anchor-page", "uncategorized pages cannot anchor")

-- Display failures surface instead of silently succeeding.
Reset(10)
displayResult = nil
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "display-failed", "display failures should be reported")

print("Auto advance tests passed.")
