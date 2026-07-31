local inRaid = true
local inGroup = true
_G.IsInRaid = function()
    return inRaid
end
_G.IsInGroup = function()
    return inGroup
end
_G.RED_FONT_COLOR_CODE = "<red>"

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
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/encounters.lua"))("AngryEra", app)

local localInstallationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:5:6:7:8"
local function CategorySyncId(counter)
    return localInstallationId .. ":category:" .. counter
end
local function PageSyncId(counter)
    return localInstallationId .. ":page:" .. counter
end

local isLeader = true
function AngryEra:IsPlayerRaidLeader()
    return isLeader
end

function AngryEra:IsLocalAngryEraAuthority()
    return isLeader
end

local displayedNote
function AngryEra:GetDisplayedNote()
    return displayedNote
end

local activeReference
function AngryEra:GetActiveDisplayReference()
    return activeReference
end

local activeRenderContext
function AngryEra:GetActivePageRenderContext()
    return activeRenderContext
end

local displayedCalls = {}
local displayOptions = {}
local displayToggleTargets = {}
local displayLocalSuccess = true
local displayPublished = true
local displayPublicationResult = "display-message-id"
function AngryEra:DisplayPage(id, options)
    displayedCalls[#displayedCalls + 1] = id
    displayOptions[#displayOptions + 1] = options
    displayToggleTargets[#displayToggleTargets + 1] = self.lastNonFirstPageId
    if displayLocalSuccess == true then
        AngryAssign_State.displayed = id
        return true, nil, displayPublished, displayPublicationResult
    end
    return nil, "activation-failed", false, "activation-failed"
end

local timers = {}
function AngryEra:ScheduleTimer(method, delay, argument)
    local timer = {
        Method = method,
        Delay = delay,
        Argument = argument,
        Cancelled = false,
    }
    timers[#timers + 1] = timer
    return timer
end

function AngryEra:CancelTimer(timer)
    timer.Cancelled = true
end

local function RunNextTimer()
    for _, timer in ipairs(timers) do
        if not timer.Cancelled and not timer.Ran then
            timer.Ran = true
            return AngryEra[timer.Method](AngryEra, timer.Argument)
        end
    end
    return nil
end

local printedMessages = {}
function AngryEra:Print(message)
    printedMessages[#printedMessages + 1] = message
end

local syncTraces = {}
local syncDebugEnabled = false
function AngryEra:IsSyncDebugEnabled()
    return syncDebugEnabled
end
function AngryEra:SyncDebug(stage, formatText, ...)
    if not syncDebugEnabled then
        return
    end
    syncTraces[#syncTraces + 1] = { Stage = stage, Text = string.format(formatText, ...) }
end

_G.AngryAssign_Meta = {
    InstallationId = localInstallationId,
    EntityLocal = {},
}
_G.AngryAssign_Categories = {
    [1] = {
        Id = 1,
        Name = "Molten Core",
        SyncId = CategorySyncId(1),
        OwnerId = localInstallationId,
        Vars = "$AUTOADVANCE=$true",
    },
    [2] = {
        Id = 2,
        Name = "Onyxia's Lair",
        SyncId = CategorySyncId(2),
        OwnerId = localInstallationId,
        Vars = "",
    },
    [3] = {
        Id = 3,
        Name = "Alternate",
        SyncId = CategorySyncId(3),
        OwnerId = localInstallationId,
        Vars = "$AUTOADVANCE=$true",
    },
    [4] = {
        Id = 4,
        Name = "Naxxramas",
        SyncId = CategorySyncId(4),
        OwnerId = localInstallationId,
        Vars = "$AUTOADVANCE=$true",
    },
}

local function LocalPage(id, name, categoryId, index, vars)
    return {
        Id = id,
        SyncId = PageSyncId(id),
        OwnerId = localInstallationId,
        Name = name,
        CategoryId = categoryId,
        Index = index,
        Contents = "",
        Vars = vars or "",
    }
end

_G.AngryAssign_Pages = {
    [10] = LocalPage(10, "Lucifron", 1, 1),
    [11] = LocalPage(11, "Magmadar", 1, 2),
    [12] = LocalPage(12, "Patch", 1, 3, "$ENCOUNTERID=1112"),
    [13] = LocalPage(13, "Ragnaros", 1, 4, "$AUTOADVANCE=$false"),
    [14] = LocalPage(14, "Loot", 1, 5),
    [20] = LocalPage(20, "Onyxia", 2, 1),
    [21] = LocalPage(21, "Whelps", 2, 2),
    [30] = LocalPage(30, "Onyxia", 3, 1),
    [31] = LocalPage(31, "Broodlings", 3, 2),
    [40] = LocalPage(40, "Rootless", nil, 1),
    [50] = LocalPage(50, "Trash", 4, 1),
    [51] = LocalPage(51, "Anub", 4, 2, "$AUTOADVANCEFIRST=$true"),
    [52] = LocalPage(52, "Grand Widow", 4, 3),
    [53] = LocalPage(53, "Maexxna", 4, 4, "$AUTOADVANCEFIRST=$true"),
}
_G.AngryAssign_State = { displayed = 10 }

local function SetDisplayedNote(displayedId, meta, categorySyncId)
    local page = AngryAssign_Pages[displayedId]
    displayedNote = {
        LocalId = displayedId,
        SyncId = page.SyncId,
        Name = page.Name,
        CategorySyncId = categorySyncId ~= nil and categorySyncId
            or (page.CategoryId and AngryAssign_Categories[page.CategoryId].SyncId or nil),
        Meta = meta or {},
    }
end

local function Reset(displayedId, meta, categorySyncId)
    AngryEra:CancelAutoAdvancePublishRetry()
    displayedCalls = {}
    displayOptions = {}
    displayToggleTargets = {}
    displayLocalSuccess = true
    displayPublished = true
    displayPublicationResult = "display-message-id"
    timers = {}
    printedMessages = {}
    AngryAssign_State.displayed = displayedId
    SetDisplayedNote(displayedId, meta, categorySyncId)
    activeReference = nil
    activeRenderContext = nil
    AngryEra.lastNonFirstPageId = nil
end

local function SetExactActiveContext(ancestorLayers)
    displayedNote.Revision = 1
    displayedNote.RevisionId = "rev-current"
    displayedNote.ContextRevisionId = "ctx-current"
    activeReference = {
        SyncId = displayedNote.SyncId,
        Revision = displayedNote.Revision,
        RevisionId = displayedNote.RevisionId,
        ContextRevisionId = displayedNote.ContextRevisionId,
    }
    activeRenderContext = {
        Page = {
            SyncId = displayedNote.SyncId,
            Revision = displayedNote.Revision,
        },
        AncestorVariableLayers = ancestorLayers,
    }
end

-- An exact displayed-page match advances without searching unrelated categories.
Reset(10, { AUTOADVANCE = true })
local advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == true and result == 11, "a kill should advance to the next page")
assert(displayedCalls[1] == 11, "the next sibling should be displayed")
assert(
    displayOptions[1] and displayOptions[1].ForcePublication == true,
    "encounter auto-advance should force immediate publication"
)

-- Automation flags require typed booleans. Bare text and numeric values must
-- not retain the old truthy behavior.
for _, legacyValue in ipairs({ "true", "TRUE", 1 }) do
    Reset(10, { AUTOADVANCE = legacyValue })
    advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
    assert(
        advanced == false and result == "auto-advance-disabled",
        "untyped auto-advance values should remain disabled"
    )
end

-- A page-level first-page flag stages the normal next boss for the First Page
-- toggle, but publishes only the category's first page.
Reset(51, { AUTOADVANCE = true, AUTOADVANCEFIRST = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9001, "Anub", 9, 40, 1)
assert(advanced == true and result == 52, "first-page staging should retain the normal next-page result")
assert(
    #displayedCalls == 1 and displayedCalls[1] == 50,
    "first-page staging should publish Trash directly without publishing the next boss"
)
assert(AngryAssign_State.displayed == 50, "first-page staging should leave the first page displayed")
assert(AngryEra.lastNonFirstPageId == 52, "the First Page toggle should return to the staged next boss")
assert(displayToggleTargets[1] == 52, "the next boss should be armed before the direct first-page display is observed")
assert(
    displayOptions[1] and displayOptions[1].ForcePublication == true,
    "the direct first-page display should force immediate publication"
)

-- Repeated encounter delivery while Trash is already active may refresh the
-- staged return target, but must never redisplay or toggle either page.
Reset(50, { AUTOADVANCE = true })
for _ = 1, 3 do
    advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9001, "Anub", 9, 40, 1)
    assert(advanced == true and result == 52, "repeated encounter delivery should remain idempotent")
end
assert(#displayedCalls == 0, "an already active first page must never be redisplayed or toggled")
assert(AngryAssign_State.displayed == 50, "repeated encounter delivery should leave Trash displayed")
assert(AngryEra.lastNonFirstPageId == 52, "repeated encounter delivery should retain Grand Widow")

-- Like every automation flag, $AUTOADVANCEFIRST requires a typed boolean.
-- Legacy strings, numbers, and an explicit false retain ordinary next-page
-- auto-advance without arming First Page toggle memory.
for _, disabledValue in ipairs({ "true", "TRUE", 1, false }) do
    Reset(51, { AUTOADVANCE = true, AUTOADVANCEFIRST = disabledValue })
    advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9001, "Anub", 9, 40, 1)
    assert(advanced == true and result == 52, "an untyped or false first-page flag should still auto-advance")
    assert(
        #displayedCalls == 1 and displayedCalls[1] == 52,
        "an untyped or false first-page flag should display the ordinary next boss"
    )
    assert(AngryEra.lastNonFirstPageId == nil, "disabled first-page staging must not arm toggle memory")
end

-- The first-page option does not wrap a completed sequence. There must be a
-- real next sibling to stage before the display or toggle memory changes.
Reset(53, { AUTOADVANCE = true, AUTOADVANCEFIRST = true })
AngryEra.lastNonFirstPageId = 999
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9002, "Maexxna", 9, 40, 1)
assert(advanced == false and result == "no-next-page", "the final boss should stop instead of wrapping")
assert(#displayedCalls == 0, "a final boss must not publish the first page")
assert(AngryAssign_State.displayed == 53, "a final boss should remain displayed")
assert(AngryEra.lastNonFirstPageId == 999, "a no-next result must preserve existing toggle memory")

-- Wipes never advance.
Reset(10, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 0)
assert(advanced == false and result == "encounter-not-defeated", "a wipe must not advance")
assert(#displayedCalls == 0, "a wipe must not display anything")

-- Fallback binding is limited to the displayed page's locally owned category.
Reset(12, { AUTOADVANCE = true, ENCOUNTERID = 1112 })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "LUCIFRON", 9, 40, 1)
assert(advanced == true and result == 11, "a unique local sibling name should anchor the advance")
assert(displayedCalls[1] == 11, "the page after the killed boss should be displayed")

-- Advancing onto the already-displayed page is a quiet no-op.
Reset(11, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "already-displayed", "no re-display when already ahead")
assert(#displayedCalls == 0, "no display call when already ahead")

-- A delayed duplicate after the user toggles from Trash to the staged boss
-- must not pull the raid back to Trash.
Reset(52, { AUTOADVANCE = true })
AngryEra.lastNonFirstPageId = 999
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9001, "Anub", 9, 40, 1)
assert(advanced == false and result == "already-displayed", "an already staged boss should remain displayed")
assert(#displayedCalls == 0, "a delayed staged duplicate must not republish Trash")
assert(AngryAssign_State.displayed == 52, "a delayed staged duplicate must leave the staged boss active")
assert(AngryEra.lastNonFirstPageId == 999, "an already-ahead duplicate must preserve navigation memory")

-- $ENCOUNTERID binds pages whose names differ from the encounter.
Reset(11, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 1112, "Patchwerk", 9, 40, 1)
assert(advanced == true and result == 13, "$ENCOUNTERID should anchor the advance")

-- The exact displayed snapshot wins over receiver-local metadata changes.
local originalCategoryVars = AngryAssign_Categories[1].Vars
AngryAssign_Categories[1].Vars = "$AUTOADVANCE=$false"
Reset(10, { AUTOADVANCE = true })
SetExactActiveContext({
    {
        SyncId = CategorySyncId(1),
        Vars = "$AUTOADVANCE=$true",
    },
})
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == true and result == 11, "stale local category metadata must not override the rendered snapshot")

-- Fallback candidates use the displayed tuple's exact ancestor layers too.
Reset(12, { AUTOADVANCE = true, ENCOUNTERID = 1112 })
SetExactActiveContext({
    {
        SyncId = CategorySyncId(1),
        Vars = "$AUTOADVANCE=$true",
    },
})
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == true and result == 11, "fallback metadata should use exact rendered ancestor layers")
AngryAssign_Categories[1].Vars = originalCategoryVars

-- A rendered page-level false value stops the chain even if local data says true.
Reset(13, { AUTOADVANCE = false })
AngryAssign_Pages[13].Vars = "$AUTOADVANCE=$true"
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 672, "Ragnaros", 9, 40, 1)
assert(advanced == false and result == "auto-advance-disabled", "the exact rendered false flag should stop the chain")
AngryAssign_Pages[13].Vars = "$AUTOADVANCE=$false"

-- Categories without $AUTOADVANCE never advance.
Reset(20, {})
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 1084, "Onyxia", 9, 40, 1)
assert(advanced == false and result == "auto-advance-disabled", "advancement is opt-in per exact display")

-- A private local move after rendering invalidates the displayed sequence.
Reset(10, { AUTOADVANCE = true })
AngryAssign_Pages[10].CategoryId = 2
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "display-sequence-stale", "changed local placement must fail safely")
AngryAssign_Pages[10].CategoryId = 1

-- Remote-owned pages never derive advancement from receiver-private placement.
Reset(10, { AUTOADVANCE = true })
AngryAssign_Pages[10].OwnerId = remoteInstallationId
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(
    advanced == false and result == "display-sequence-unavailable",
    "remote-owned displayed hierarchy must not be reconstructed locally"
)
AngryAssign_Pages[10].OwnerId = localInstallationId

-- Exact active tuple identifiers must still match the rendered snapshot.
Reset(10, { AUTOADVANCE = true })
displayedNote.Revision = 1
displayedNote.RevisionId = "rev-current"
displayedNote.ContextRevisionId = "ctx-current"
activeReference = {
    SyncId = displayedNote.SyncId,
    Revision = displayedNote.Revision,
    RevisionId = "rev-stale",
    ContextRevisionId = "ctx-current",
}
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "display-snapshot-stale", "a stale active tuple must not advance")

-- Fallback matching must use the rendered page name, not a later local rename.
Reset(10, { AUTOADVANCE = true })
AngryAssign_Pages[10].Name = "Shared Boss"
local originalPatchVars = AngryAssign_Pages[12].Vars
AngryAssign_Pages[12].Vars = "$ENCOUNTER=Shared Boss"
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 2221, "Shared Boss", 9, 40, 1)
assert(advanced == true and result == 13, "a private rename must not introduce a second fallback match")
AngryAssign_Pages[10].Name = "Lucifron"
AngryAssign_Pages[12].Vars = originalPatchVars

-- Duplicate id bindings inside the only eligible category are rejected.
AngryAssign_Pages[15] = LocalPage(15, "Duplicate One", 1, 6, "$ENCOUNTERID=2222")
AngryAssign_Pages[16] = LocalPage(16, "Duplicate Two", 1, 7, "$ENCOUNTERID=2222")
Reset(10, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 2222, "Different", 9, 40, 1)
assert(advanced == false and result == "ambiguous-encounter-id", "duplicate encounter ids must be rejected")
AngryAssign_Pages[15] = nil
AngryAssign_Pages[16] = nil

-- Duplicate name bindings are also rejected instead of depending on pairs order.
AngryAssign_Pages[15] = LocalPage(15, "Duplicate", 1, 6, "$ENCOUNTER=Shared Boss")
AngryAssign_Pages[16] = LocalPage(16, "Duplicate", 1, 7, "$ENCOUNTER=Shared Boss")
Reset(10, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 2223, "Shared Boss", 9, 40, 1)
assert(advanced == false and result == "ambiguous-encounter-name", "duplicate encounter names must be rejected")
AngryAssign_Pages[15] = nil
AngryAssign_Pages[16] = nil

-- Binding search has a smaller cap than the cheap sibling-order scan.
AngryAssign_Categories[7] = {
    Id = 7,
    Name = "Search Bound",
    SyncId = CategorySyncId(7),
    OwnerId = localInstallationId,
    Vars = "$AUTOADVANCE=$true",
}
for index = 1, 65 do
    local id = 7000 + index
    AngryAssign_Pages[id] = LocalPage(id, "Search " .. index, 7, index)
end
Reset(7001, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9999, "Unknown", 9, 40, 1)
assert(
    advanced == false and result == "display-sequence-search-too-large",
    "fallback metadata search must have a strict candidate cap"
)
for index = 1, 65 do
    AngryAssign_Pages[7000 + index] = nil
end
AngryAssign_Categories[7] = nil

-- A matching displayed page is authoritative even when another sibling has the same binding.
AngryAssign_Pages[15] = LocalPage(15, "Lucifron", 1, 6)
Reset(10, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == true and result == 11, "the exact displayed match should take precedence")
AngryAssign_Pages[15] = nil

-- Equal index/name siblings use local id as a stable final ordering key.
AngryAssign_Pages[15] = LocalPage(15, "Same", 1, 6)
AngryAssign_Pages[16] = LocalPage(16, "Same", 1, 6)
Reset(14, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 2224, "Loot", 9, 40, 1)
assert(advanced == true and result == 15, "equal siblings should advance deterministically by local id")
AngryAssign_Pages[15] = nil
AngryAssign_Pages[16] = nil

-- Candidate count is bounded before metadata parsing.
AngryAssign_Categories[8] = {
    Id = 8,
    Name = "Oversized",
    SyncId = CategorySyncId(8),
    OwnerId = localInstallationId,
    Vars = "$AUTOADVANCE=$true",
}
for index = 1, 513 do
    local id = 8000 + index
    AngryAssign_Pages[id] = LocalPage(id, "Bound " .. index, 8, index)
end
Reset(8001, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9999, "Unknown", 9, 40, 1)
assert(advanced == false and result == "display-sequence-too-large", "oversized sequences must fail safely")
for index = 1, 513 do
    AngryAssign_Pages[8000 + index] = nil
end
AngryAssign_Categories[8] = nil

-- Aggregate candidate metadata work is bounded even below the page-count cap.
AngryAssign_Categories[9] = {
    Id = 9,
    Name = "Heavy",
    SyncId = CategorySyncId(9),
    OwnerId = localInstallationId,
    Vars = "$AUTOADVANCE=$true",
}
for index = 1, 60 do
    local id = 9000 + index
    AngryAssign_Pages[id] = LocalPage(id, "Heavy " .. index, 9, index, string.rep("x", 5000))
end
Reset(9001, { AUTOADVANCE = true })
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9999, "Unknown", 9, 40, 1)
assert(
    advanced == false and result == "display-sequence-metadata-work-exceeded",
    "aggregate metadata resolution work must be capped"
)
for index = 1, 60 do
    AngryAssign_Pages[9000 + index] = nil
end
AngryAssign_Categories[9] = nil

-- Rootless displayed pages have no authoritative sequence.
Reset(40, { AUTOADVANCE = true }, false)
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9999, "Unknown", 9, 40, 1)
assert(advanced == false and result == "display-sequence-unavailable", "uncategorized pages cannot advance")

-- Non-controllers in a group never advance.
Reset(10, { AUTOADVANCE = true })
isLeader = false
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "not-raid-controller", "only the AngryEra authority advances in a group")
assert(#displayedCalls == 0, "non-controllers must not display")
isLeader = true

-- Solo players advance their own preview.
Reset(10, { AUTOADVANCE = true })
inRaid = false
inGroup = false
isLeader = false
displayPublished = false
displayPublicationResult = "no-channel"
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == true and result == 11, "solo advancement should work without a leader")
assert(#timers == 0 and #printedMessages == 0, "solo preview should not retry or warn about the missing group channel")
inRaid = true
inGroup = true
isLeader = true

-- Local activation plus transport failure is not reported as shared success.
Reset(10, { AUTOADVANCE = true })
displayPublished = false
displayPublicationResult = "transport-failed"
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "display-publish-retrying", "transport failure should enter bounded retry")
assert(AngryAssign_State.displayed == 11, "transport failure should retain the local activation")
assert(#printedMessages == 1 and printedMessages[1]:find("retrying", 1, true), "retry should warn the leader")
SetDisplayedNote(11, { AUTOADVANCE = true })
local duplicateAdvanced, duplicateReason = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(
    duplicateAdvanced == false and duplicateReason == "already-displayed",
    "a duplicate encounter should not replace the pending publication retry"
)
displayPublished = true
local retrySucceeded, retryResult = RunNextTimer()
assert(retrySucceeded == true and retryResult == 11, "a successful retry should confirm shared publication")
assert(#displayedCalls == 2, "retry should republish the already activated page exactly once")
assert(
    displayOptions[1]
        and displayOptions[1].ForcePublication == true
        and displayOptions[2]
        and displayOptions[2].ForcePublication == true,
    "auto-advance and its retry should both force immediate publication"
)
assert(displayOptions[2].AutoAdvanceRetry ~= nil, "an auto-advance publication retry should retain its retry identity")

-- A direct first-page publication retries only that first page. A duplicate
-- encounter after local activation is idempotent and must not replace the
-- original retry or its staged next-boss toggle target.
Reset(51, { AUTOADVANCE = true, AUTOADVANCEFIRST = true })
displayPublished = false
displayPublicationResult = "transport-failed"
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9001, "Anub", 9, 40, 1)
assert(advanced == false and result == "display-publish-retrying", "first-page transport failure should retry")
assert(AngryAssign_State.displayed == 50, "transport failure should retain the local first-page activation")
assert(AngryEra.lastNonFirstPageId == 52, "transport failure should retain the staged next boss")
assert(#displayedCalls == 1 and displayedCalls[1] == 50, "the initial publication should target only Trash")
local stagedRetry = AngryEra._autoAdvancePublishRetry
local stagedTimerCount = #timers
assert(stagedRetry and stagedRetry.PageId == 50, "the publication retry should target the first page")

SetDisplayedNote(50, { AUTOADVANCE = true })
local duplicateStaged, duplicateStagedResult = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9001, "Anub", 9, 40, 1)
assert(
    duplicateStaged == true and duplicateStagedResult == 52,
    "a duplicate staged encounter should be an idempotent success"
)
assert(#displayedCalls == 1, "a duplicate staged encounter must not republish the already displayed first page")
assert(
    AngryEra._autoAdvancePublishRetry == stagedRetry and #timers == stagedTimerCount,
    "a duplicate staged encounter must preserve the pending first-page retry"
)
assert(AngryEra.lastNonFirstPageId == 52, "a duplicate staged encounter should preserve its toggle target")

displayPublished = true
retrySucceeded, retryResult = RunNextTimer()
assert(retrySucceeded == true and retryResult == 50, "a successful retry should publish the first page")
assert(
    #displayedCalls == 2 and displayedCalls[1] == 50 and displayedCalls[2] == 50,
    "the initial attempt and retry must never publish the staged next boss"
)
assert(
    displayOptions[2]
        and displayOptions[2].ForcePublication == true
        and displayOptions[2].AutoAdvanceRetry == stagedRetry,
    "the first-page retry should force publication with its original identity"
)
assert(AngryEra.lastNonFirstPageId == 52, "a successful retry should retain the First Page return target")

-- Replacing the display cancels the pending retry without republishing stale state.
Reset(10, { AUTOADVANCE = true })
displayPublished = false
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "display-publish-retrying", "a retry should be pending")
AngryAssign_State.displayed = 12
local retryAdvanced, retryReason = RunNextTimer()
assert(retryAdvanced == false and retryReason == "retry-cancelled", "changed display should cancel the retry")
assert(#displayedCalls == 1, "a cancelled retry must not republish the stale target")

-- Persistent transport failure stops after the bounded retry budget.
Reset(10, { AUTOADVANCE = true })
displayPublished = false
displayPublicationResult = "still-failing"
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "display-publish-retrying", "persistent failure should start retrying")
retryAdvanced, retryReason = RunNextTimer()
assert(retryAdvanced == false and retryReason == "display-publish-retrying", "the first retry may schedule one more")
retryAdvanced, retryReason = RunNextTimer()
assert(retryAdvanced == false and retryReason == "display-publish-failed", "retry budget should terminate")
assert(#displayedCalls == 3, "publication should make one initial attempt and two retries")

-- Local activation failures surface without scheduling publication retries.
Reset(10, { AUTOADVANCE = true })
displayLocalSuccess = false
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == false and result == "display-failed", "local display failures should be reported")
assert(#timers == 0, "local activation failure must not schedule publication retries")

-- Arming happens before a synchronous display observer, but a local activation
-- failure must roll it back so an unrelated First Page target is not lost.
Reset(51, { AUTOADVANCE = true, AUTOADVANCEFIRST = true })
AngryEra.lastNonFirstPageId = 999
displayLocalSuccess = false
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 9001, "Anub", 9, 40, 1)
assert(advanced == false and result == "display-failed", "a failed direct first-page activation should surface")
assert(#displayedCalls == 1 and displayedCalls[1] == 50, "the failed activation should attempt only Trash")
assert(displayToggleTargets[1] == 52, "the staged next boss should be visible during the display attempt")
assert(AngryAssign_State.displayed == 51, "a failed first-page activation must retain the source boss")
assert(AngryEra.lastNonFirstPageId == 999, "a failed first-page activation must restore prior toggle memory")
assert(#timers == 0, "a failed first-page activation must not schedule a publication retry")

-- Auto-advance decisions are visible through sync debug tracing.
Reset(10, { AUTOADVANCE = true })
syncDebugEnabled = true
syncTraces = {}
advanced, result = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 0)
assert(advanced == false and result == "encounter-not-defeated", "a wipe must not advance")
assert(#syncTraces == 1 and syncTraces[1].Text:find("encounter%-not%-defeated"), "a wipe outcome should be traced")

syncTraces = {}
advanced = AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
assert(advanced == true, "a kill should advance")
assert(#syncTraces == 1 and syncTraces[1].Text:find("advanced=true"), "a successful advance should be traced")

syncDebugEnabled = false
syncTraces = {}
AngryEra:ENCOUNTER_END("ENCOUNTER_END", 663, "Lucifron", 9, 40, 0)
assert(#syncTraces == 0, "tracing must stay silent when debug is disabled")

print("Auto advance tests passed.")
