local app = {
    AngryEra = {
        utils = {},
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/api.lua"))("AngryEra", app)

local AngryEra = app.AngryEra
local json = app.AngryEra.utils.json
local variables = app.AngryEra.utils.variables

assert(AngryEra.NOTE_API_VERSION == 1, "The note API version should be published")
assert(AngryEra.NOTE_UPDATE_EVENT == "ANGRYERA_NOTE_UPDATE", "The note event name should be published")

local rootSyncId = "ae3i:1:2:3:4:category:1"
local parentSyncId = "ae3i:1:2:3:4:category:2"
local unknownSyncId = "ae3i:1:2:3:4:category:9"
local pageSyncId = "ae3i:1:2:3:4:page:7"

local categoriesBySyncId = {
    [rootSyncId] = { Id = 1, Name = "Naxxramas", SyncId = rootSyncId },
    [parentSyncId] = { Id = 2, Name = "Military Quarter", SyncId = parentSyncId },
}

local scanEvents = {}
local messages = {}
local layoutObservations = {}
local reference = {
    SyncId = pageSyncId,
    Revision = 1,
    RevisionId = "rev-1",
    ContextRevisionId = "ctx-1",
}
local renderContext = {
    Page = { SyncId = pageSyncId },
    AncestorVariableLayers = {
        { SyncId = rootSyncId, Vars = "" },
        { SyncId = parentSyncId, Vars = "" },
    },
}

_G.WeakAuras = {
    ScanEvents = function(event, ...)
        scanEvents[#scanEvents + 1] = { event = event, ... }
    end,
}
_G.AngryAssign_State = { displayed = 12 }
_G.AngryAssign_Categories = {
    [2] = { Id = 2, Name = "Military Quarter", SyncId = parentSyncId },
    [5] = { Id = 5, Name = "Local Folder" },
}

function AngryEra:GetCategoryBySyncId(syncId)
    return categoriesBySyncId[syncId]
end

function AngryEra:GetActiveDisplayReference()
    return reference
end

function AngryEra:GetActivePageRenderContext(syncId, revision, revisionId, contextRevisionId)
    assert(syncId == reference.SyncId, "The render context should be requested by reference tuple")
    assert(revision == reference.Revision, "The numeric reference revision should be requested")
    assert(revisionId == reference.RevisionId, "The reference revision should be requested")
    assert(contextRevisionId == reference.ContextRevisionId, "The reference context revision should be requested")
    return renderContext
end

function AngryEra:SendMessage(event, ...)
    messages[#messages + 1] = { event = event, ... }
end

function AngryEra:ObserveDisplayedRaidLayout(snapshot)
    layoutObservations[#layoutObservations + 1] = snapshot or false
end

local wirePage = {
    SyncId = pageSyncId,
    Revision = 1,
    ParentSyncId = parentSyncId,
    Name = "Patchwerk",
    Contents = "## {page}\n\nMT: {{MT}}",
    UpdatedAt = 1234567890,
    UpdatedBy = "Zessy-Pagle",
}
local deepJsonValue = "\"bottom\""
for _ = 1, 96 do
    deepJsonValue = "{\"level\":" .. deepJsonValue .. "}"
end
local parsedDeepVariables, deepParseError = variables.MergeVariableLayers({}, "{\"Deep\":" .. deepJsonValue .. "}")
assert(parsedDeepVariables and not deepParseError, "The variable parser should accept nesting deeper than 64")

local structuredMeta = {
    assignments = {
        tanks = { "Zessy", "Kwayteow" },
    },
    optional = json.JSON_NULL,
}
local cyclicValue = {}
cyclicValue.self = cyclicValue
local mergedVariables = {
    MT = "Zessy",
    Cycle = cyclicValue,
    Deep = parsedDeepVariables.Deep,
    NullValue = json.JSON_NULL,
    ["$encounter"] = "Patchwerk",
    ["$phase"] = 2,
    ["$strategy"] = structuredMeta,
    ["$null"] = json.JSON_NULL,
}

local announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Zessy",
    MergedVariables = mergedVariables,
})
assert(announced == true, "The first render should announce")
assert(#scanEvents == 1 and #messages == 1, "Both event channels should fire once")
assert(
    #layoutObservations == 1
        and layoutObservations[1].SyncId == pageSyncId
        and layoutObservations[1].ContextRevisionId == "ctx-1",
    "the exact displayed-note snapshot should also reach the raid-layout observer"
)
assert(scanEvents[1].event == "ANGRYERA_NOTE_UPDATE", "The WeakAuras event name should match")
assert(scanEvents[1][1] == pageSyncId, "The event should carry the page sync id")
assert(scanEvents[1][2] == "Patchwerk", "The event should carry the page name")
assert(scanEvents[1][3] == "Military Quarter", "The event should carry the category name")
assert(messages[1].event == "ANGRYERA_NOTE_UPDATE", "The addon message name should match")

local note = AngryEra:GetDisplayedNote()
assert(note, "A displayed note should be available")
assert(note.LocalId == 12, "The local display id should be exposed")
assert(note.SyncId == pageSyncId, "The page sync id should be exposed")
assert(note.Revision == 1, "The active numeric revision should be exposed")
assert(note.RevisionId == "rev-1", "The active revision should be exposed")
assert(note.ContextRevisionId == "ctx-1", "The active context revision should be exposed")
assert(note.Name == "Patchwerk", "The page name should be exposed")
assert(note.Category == "Military Quarter", "The direct category name should resolve by sync id")
assert(note.CategorySyncId == parentSyncId, "The direct category sync id should be exposed")
assert(#note.Ancestors == 2, "Every ancestor layer should be exposed")
assert(note.Ancestors[1].SyncId == rootSyncId and note.Ancestors[1].Name == "Naxxramas", "Root ancestors resolve")
assert(note.Ancestors[2].Name == "Military Quarter", "Parent ancestors resolve")
assert(note.Raw == wirePage.Contents, "Raw contents should be exposed")
assert(note.Rendered == "PATCHWERK - MT: Zessy", "Rendered text should be exposed")
assert(note.UpdatedAt == 1234567890 and note.UpdatedBy == "Zessy-Pagle", "Revision audit fields should be exposed")
assert(note.Vars.MT == "Zessy", "Public variables should be exposed")
assert(note.Vars.Cycle ~= cyclicValue, "Cyclic public values should detach from their source")
assert(note.Vars.Cycle.self == note.Vars.Cycle, "Cyclic public values should retain their topology")
assert(note.Vars.NullValue ~= json.JSON_NULL, "The internal JSON null singleton should not escape")
assert(AngryEra:IsDisplayedNull(note.Vars.NullValue), "Public JSON null markers should be recognizable")
assert(note.Vars["$encounter"] == nil, "Metadata should not leak into public variables")
assert(note.Meta.encounter == "Patchwerk" and note.Meta.phase == 2, "Metadata should be exposed with prefix stripped")
assert(note.Meta.strategy ~= structuredMeta, "Structured metadata should detach from the source")
assert(note.Meta.strategy.assignments.tanks[2] == "Kwayteow", "Structured metadata should be published")
assert(AngryEra:IsDisplayedNull(note.Meta.strategy.optional), "Nested metadata nulls should be recognizable")
assert(AngryEra:IsDisplayedNull(note.Meta.null), "Top-level metadata nulls should be recognizable")

local deepCursor = note.Vars.Deep
for _ = 1, 96 do
    assert(type(deepCursor) == "table", "Deep parser values should not be truncated by the getter")
    deepCursor = deepCursor.level
end
assert(deepCursor == "bottom", "The deepest parser value should survive the detached copy")

local meta = AngryEra:GetDisplayedMeta()
local vars = AngryEra:GetDisplayedVars()
assert(meta.encounter == "Patchwerk", "GetDisplayedMeta should expose stripped metadata")
assert(vars.MT == "Zessy" and vars["$phase"] == nil, "GetDisplayedVars should exclude metadata")
assert(AngryEra:IsDisplayedNull(meta.null), "The metadata getter should preserve public null semantics")

note.Meta.encounter = "Mutated"
note.Meta.strategy.assignments.tanks[1] = "Mutated"
note.Vars.MT = "Mutated"
note.Ancestors[1].Name = "Mutated"
note.Vars.NullValue.consumerMutation = true
structuredMeta.assignments.tanks[1] = "Source mutation"
local secondNote = AngryEra:GetDisplayedNote()
assert(secondNote.Meta.encounter == "Patchwerk", "Snapshot metadata should be detached per call")
assert(secondNote.Meta.strategy.assignments.tanks[1] == "Zessy", "Structured metadata should be deeply detached")
assert(secondNote.Vars.MT == "Zessy", "Snapshot variables should be detached per call")
assert(secondNote.Ancestors[1].Name == "Naxxramas", "Snapshot ancestors should be detached per call")
assert(
    AngryEra:IsDisplayedNull(secondNote.Vars.NullValue) and secondNote.Vars.NullValue.consumerMutation == nil,
    "Mutating a public null marker should not affect later getters"
)
assert(secondNote.Vars.NullValue ~= note.Vars.NullValue, "Every getter should own its public null markers")
assert(json.JSON_NULL.consumerMutation == nil, "Public null mutations should not reach the codec singleton")
structuredMeta.assignments.tanks[1] = "Zessy"

local invalidVariableKey = {}
local observationsBeforeInvalid = #layoutObservations
local rejected, rejectionError = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Zessy",
    MergedVariables = {
        Nested = {
            [invalidVariableKey] = "unsupported",
        },
    },
})
assert(rejected == false, "Invalid variable graphs should not announce")
assert(rejectionError == "invalid-variables", "Invalid variable graphs should report their partition error")
assert(AngryEra:GetDisplayedVars().MT == "Zessy", "A rejected graph should preserve the previous snapshot")
assert(#scanEvents == 1 and #messages == 1, "A rejected graph should not publish an event")
assert(
    #layoutObservations == observationsBeforeInvalid,
    "a rejected graph must not replace the raid-layout display observation"
)

local invalidContextAnnounced, invalidContextError = AngryEra:NotifyDisplayedNoteChanged({})
assert(invalidContextAnnounced == false, "Invalid render contexts should not announce")
assert(invalidContextError == "invalid-context", "Invalid render contexts should report invalid-context")
assert(AngryEra:GetDisplayedVars().MT == "Zessy", "An invalid render context should preserve the previous snapshot")
assert(#scanEvents == 1 and #messages == 1, "An invalid render context should not publish an event")

announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Zessy",
    MergedVariables = mergedVariables,
})
assert(announced == false, "An identical render should not announce")
assert(#scanEvents == 1 and #messages == 1, "Duplicate renders should not repeat events")
assert(
    #layoutObservations == observationsBeforeInvalid + 1,
    "an identical render should still revalidate pending layout work against the active tuple"
)

announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Kwayteow",
    MergedVariables = mergedVariables,
})
assert(announced == true, "A rendered-text change should announce")
assert(#scanEvents == 2, "Roster-driven render changes should fire the event")

categoriesBySyncId[parentSyncId].Name = "Renamed Quarter"
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Kwayteow",
    MergedVariables = mergedVariables,
})
assert(announced == true, "A category rename should announce")
assert(scanEvents[3][3] == "Renamed Quarter", "The renamed category should be carried by the event")

categoriesBySyncId[rootSyncId].Name = "Renamed Naxxramas"
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Kwayteow",
    MergedVariables = mergedVariables,
})
assert(announced == true, "A non-direct ancestor rename should announce")
assert(#scanEvents == 4, "The ancestor rename should fire both event pathways once")
assert(AngryEra:GetDisplayedNote().Ancestors[1].Name == "Renamed Naxxramas", "The renamed ancestor should publish")

wirePage.UpdatedBy = "Kwayteow-Pagle"
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Kwayteow",
    MergedVariables = mergedVariables,
})
assert(announced == true, "A published audit-field change should announce")
assert(#scanEvents == 5, "The audit-field change should fire the event")

structuredMeta.assignments.tanks[1] = "Thorn"
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Kwayteow",
    MergedVariables = mergedVariables,
})
assert(announced == true, "A metadata-only change should announce")
assert(#scanEvents == 6, "The metadata-only change should fire the event")
assert(AngryEra:GetDisplayedMeta().strategy.assignments.tanks[1] == "Thorn", "Changed metadata should publish")

announced = AngryEra:NotifyDisplayedNoteChanged(nil)
assert(announced == true, "Clearing the display should announce")
assert(layoutObservations[#layoutObservations] == false, "clearing the display should cancel page-bound layout work")
assert(AngryEra:GetDisplayedNote() == nil, "A cleared display should expose no note")
assert(AngryEra:GetDisplayedVars() == nil, "A cleared display should expose no variables")
assert(AngryEra:GetDisplayedMeta() == nil, "A cleared display should expose no metadata")
assert(scanEvents[7][1] == nil and scanEvents[7][2] == nil, "The cleared event should carry nil identifiers")

announced = AngryEra:NotifyDisplayedNoteChanged(nil)
assert(announced == false, "A repeated clear should not announce")
assert(#scanEvents == 7, "Repeated clears should not repeat events")

-- JSON null and an empty object are distinct published values.
local nullObjectVariables = { Shape = json.JSON_NULL }
local nullObjectEventCount = #scanEvents
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK",
    MergedVariables = nullObjectVariables,
})
assert(announced == true, "Restoring a note with a JSON null should announce")

nullObjectVariables.Shape = {}
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK",
    MergedVariables = nullObjectVariables,
})
assert(announced == true, "Changing JSON null to an empty object should announce")
assert(
    not AngryEra:IsDisplayedNull(AngryEra:GetDisplayedVars().Shape),
    "An empty object should not publish as JSON null"
)

nullObjectVariables.Shape = json.JSON_NULL
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK",
    MergedVariables = nullObjectVariables,
})
assert(announced == true, "Changing an empty object back to JSON null should announce")
assert(#scanEvents == nullObjectEventCount + 3, "Each null/object transition should fire the event")
assert(
    AngryEra:IsDisplayedNull(AngryEra:GetDisplayedVars().Shape),
    "The restored JSON null should publish as a null marker"
)

-- Local fallback: the active reference belongs to a different page.
local localPage = {
    SyncId = "ae3i:1:2:3:4:page:8",
    CategoryId = 5,
    Name = "Scratch",
    Contents = "notes",
}
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = localPage,
    RenderedText = "notes",
    MergedVariables = {},
})
assert(announced == true, "A locally rendered page should announce")
local localNote = AngryEra:GetDisplayedNote()
assert(
    localNote.Revision == nil and localNote.RevisionId == nil and localNote.ContextRevisionId == nil,
    "Mismatched references should be ignored"
)
assert(#localNote.Ancestors == 0, "Mismatched references should expose no ancestors")
assert(localNote.Category == "Local Folder", "Local categories should resolve through CategoryId")
assert(localNote.CategorySyncId == nil, "Local categories without sync ids should expose none")

-- Unknown ancestors keep their sync ids without names.
renderContext.AncestorVariableLayers[2] = { SyncId = unknownSyncId, Vars = "" }
AngryEra:NotifyDisplayedNoteChanged(nil)
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK",
    MergedVariables = {},
})
assert(announced == true, "A restored display should announce")
local partialNote = AngryEra:GetDisplayedNote()
assert(partialNote.Ancestors[2].SyncId == unknownSyncId, "Unknown ancestors should keep their sync id")
assert(partialNote.Ancestors[2].Name == nil, "Unknown ancestors should expose no name")
assert(partialNote.Category == "Renamed Quarter", "The direct parent should still resolve by ParentSyncId")

local exactRenderContext = renderContext
renderContext = nil
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK",
    MergedVariables = {},
    AncestorVariableLayers = exactRenderContext.AncestorVariableLayers,
})
assert(announced == true, "A local fallback after an exact-context miss should announce")
local fallbackIdentityNote = AngryEra:GetDisplayedNote()
assert(
    fallbackIdentityNote.Revision == nil
        and fallbackIdentityNote.RevisionId == nil
        and fallbackIdentityNote.ContextRevisionId == nil,
    "A local fallback should not retain stale exact-revision identifiers"
)
renderContext = exactRenderContext

-- Valid aggregate graphs above the former 8,192-table copy/equality guard must
-- remain readable and must not generate duplicate change events.
local largeVariables = {}
for index = 1, 9000 do
    largeVariables["Large" .. tostring(index)] = {}
end
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK",
    MergedVariables = largeVariables,
})
assert(announced == true, "A valid large aggregate should publish")
local largePublicVariables, largeGetterError = AngryEra:GetDisplayedVars()
assert(largePublicVariables and not largeGetterError, "A valid large aggregate should remain readable")
assert(type(largePublicVariables.Large9000) == "table", "The complete large aggregate should reach consumers")
announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK",
    MergedVariables = largeVariables,
})
assert(announced == false, "An unchanged large aggregate should not announce again")

-- Event channels degrade independently.
local scanCountBefore = #scanEvents
_G.WeakAuras = nil
AngryEra:NotifyDisplayedNoteChanged(nil)
assert(#messages >= 1, "The addon message channel should work without WeakAuras")
assert(#scanEvents == scanCountBefore, "A missing WeakAuras global should be tolerated")

local messageCountBefore = #messages
AngryEra.SendMessage = nil
_G.WeakAuras = {
    ScanEvents = function(event, ...)
        scanEvents[#scanEvents + 1] = { event = event, ... }
    end,
}
AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK",
    MergedVariables = {},
})
assert(#scanEvents == scanCountBefore + 1, "WeakAuras should fire without AceEvent")
assert(#messages == messageCountBefore, "A missing SendMessage mixin should be tolerated")

print("Note API tests passed.")
