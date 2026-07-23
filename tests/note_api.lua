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
local reference = {
    SyncId = pageSyncId,
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

function AngryEra:GetActivePageRenderContext(syncId, revisionId, contextRevisionId)
    assert(syncId == reference.SyncId, "The render context should be requested by reference tuple")
    assert(revisionId == reference.RevisionId, "The reference revision should be requested")
    assert(contextRevisionId == reference.ContextRevisionId, "The reference context revision should be requested")
    return renderContext
end

function AngryEra:SendMessage(event, ...)
    messages[#messages + 1] = { event = event, ... }
end

local wirePage = {
    SyncId = pageSyncId,
    ParentSyncId = parentSyncId,
    Name = "Patchwerk",
    Contents = "## {page}\n\nMT: {{MT}}",
    UpdatedAt = 1234567890,
    UpdatedBy = "Zessy-Pagle",
}
local mergedVariables = {
    MT = "Zessy",
    NullValue = json.JSON_NULL,
    ["$encounter"] = "Patchwerk",
    ["$phase"] = 2,
}

local announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Zessy",
    MergedVariables = mergedVariables,
})
assert(announced == true, "The first render should announce")
assert(#scanEvents == 1 and #messages == 1, "Both event channels should fire once")
assert(scanEvents[1].event == "ANGRYERA_NOTE_UPDATE", "The WeakAuras event name should match")
assert(scanEvents[1][1] == pageSyncId, "The event should carry the page sync id")
assert(scanEvents[1][2] == "Patchwerk", "The event should carry the page name")
assert(scanEvents[1][3] == "Military Quarter", "The event should carry the category name")
assert(messages[1].event == "ANGRYERA_NOTE_UPDATE", "The addon message name should match")

local note = AngryEra:GetDisplayedNote()
assert(note, "A displayed note should be available")
assert(note.LocalId == 12, "The local display id should be exposed")
assert(note.SyncId == pageSyncId, "The page sync id should be exposed")
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
assert(note.Vars.NullValue == json.JSON_NULL, "JSON null identity should survive the snapshot clone")
assert(note.Vars["$encounter"] == nil, "Metadata should not leak into public variables")
assert(note.Meta.encounter == "Patchwerk" and note.Meta.phase == 2, "Metadata should be exposed with prefix stripped")

local meta = AngryEra:GetDisplayedMeta()
local vars = AngryEra:GetDisplayedVars()
assert(meta.encounter == "Patchwerk", "GetDisplayedMeta should expose stripped metadata")
assert(vars.MT == "Zessy" and vars["$phase"] == nil, "GetDisplayedVars should exclude metadata")

note.Meta.encounter = "Mutated"
note.Vars.MT = "Mutated"
note.Ancestors[1].Name = "Mutated"
local secondNote = AngryEra:GetDisplayedNote()
assert(secondNote.Meta.encounter == "Patchwerk", "Snapshot metadata should be detached per call")
assert(secondNote.Vars.MT == "Zessy", "Snapshot variables should be detached per call")
assert(secondNote.Ancestors[1].Name == "Naxxramas", "Snapshot ancestors should be detached per call")

announced = AngryEra:NotifyDisplayedNoteChanged({
    Page = wirePage,
    RenderedText = "PATCHWERK - MT: Zessy",
    MergedVariables = mergedVariables,
})
assert(announced == false, "An identical render should not announce")
assert(#scanEvents == 1 and #messages == 1, "Duplicate renders should not repeat events")

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

announced = AngryEra:NotifyDisplayedNoteChanged(nil)
assert(announced == true, "Clearing the display should announce")
assert(AngryEra:GetDisplayedNote() == nil, "A cleared display should expose no note")
assert(AngryEra:GetDisplayedVars() == nil, "A cleared display should expose no variables")
assert(AngryEra:GetDisplayedMeta() == nil, "A cleared display should expose no metadata")
assert(scanEvents[4][1] == nil and scanEvents[4][2] == nil, "The cleared event should carry nil identifiers")

announced = AngryEra:NotifyDisplayedNoteChanged(nil)
assert(announced == false, "A repeated clear should not announce")
assert(#scanEvents == 4, "Repeated clears should not repeat events")

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
assert(localNote.RevisionId == nil and localNote.ContextRevisionId == nil, "Mismatched references should be ignored")
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
