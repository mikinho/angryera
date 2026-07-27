-- Guards the category context menu wiring. The menu is a positional table
-- shared between every right-click, so an entry added in the middle used to
-- leave the ids and permission flags below it attached to the wrong rows.

local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra, libs = {} }

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/layout.lua"))("AngryEra", app)

local function EnsureUnitShortName(name)
    return name and name:match("([^-]+)")
end

AngryEra.utils.helpers = {
    EnsureUnitFullName = function(name)
        if name and not name:find("-", 1, true) then
            return name .. "-RealmA"
        end
        return name
    end,
    EnsureUnitShortName = EnsureUnitShortName,
    IterateGroupMembers = function() end,
    CompareIndexedEntries = function(left, right)
        if left.Index ~= right.Index then
            return (left.Index or math.huge) < (right.Index or math.huge)
        end
        return left.Name < right.Name
    end,
    IsCategoryDescendant = function()
        return false
    end,
    selectedLastValue = function(value)
        return tonumber(value) or 0
    end,
}
AngryEra.utils.colors = {}

-- The editor only reaches for these once a window is built, so the menu tests
-- need nothing behind them.
app.libs.AceGUI = setmetatable({}, {
    __index = function()
        return function() end
    end,
})
app.libs.DDM = app.libs.AceGUI

local editable = true
function AngryEra:CanEditEntityLocally()
    return editable
end

AngryAssign_Pages = {}
AngryAssign_Categories = {
    [4] = { Id = 4, Name = "Naxxramas" },
    [5] = { Id = 5, Name = "Temple of Ahn'Qiraj" },
}

assert(loadfile("modules/ui/editor.lua"))("AngryEra", app)

-- Reads the entry a label names, the way a player picks a row by reading it.
local function Entry(menu, text)
    for index = 2, #menu do
        if menu[index].text == text then
            return menu[index]
        end
    end
end

local menu = AngryEra_CategoryMenu(4)
assert(menu, "right-clicking a category returns a menu")
assert(menu[1].text == "Naxxramas", "the title names the category")

local labels = {
    "Rename",
    "Save as Template",
    "Delete",
    "Edit Variables",
    "Edit Group Layout",
    "Export",
    "Category",
}
for _, label in ipairs(labels) do
    local entry = Entry(menu, label)
    assert(entry, "the menu offers " .. label)
    assert(entry.arg1 == 4, label .. " acts on the clicked category")
end

-- A category carries the raid's standard layout, so it edits one the same way
-- a page does rather than only through its raw variables.
assert(Entry(menu, "Edit Group Layout"), "a category can edit its group layout")

-- Export owns the only nested list, and an entry added above it used to leave
-- this lookup on an entry that had no menuList at all.
local export = Entry(menu, "Export")
assert(type(export.menuList) == "table" and #export.menuList > 0, "Export offers formats")
for _, item in ipairs(export.menuList) do
    assert(item.arg1 == 4, "an export format acts on the clicked category")
end

local category = Entry(menu, "Category")
assert(type(category.menuList) == "table", "Category offers a list")
assert(category.disabled == false, "a category with siblings can be moved")

-- Every entry that edits the category is gated on the same permission.
editable = false
menu = AngryEra_CategoryMenu(4)
for _, label in ipairs({ "Rename", "Edit Variables", "Edit Group Layout" }) do
    assert(Entry(menu, label).disabled == true, label .. " is closed to a read-only category")
end
assert(Entry(menu, "Export").disabled ~= true, "a read-only category can still be exported")
editable = true

-- The menu is reused between clicks, so a second category must not inherit the
-- first category's id.
menu = AngryEra_CategoryMenu(5)
assert(menu[1].text == "Temple of Ahn'Qiraj", "the title follows the clicked category")
for _, label in ipairs(labels) do
    assert(Entry(menu, label).arg1 == 5, label .. " follows the clicked category")
end
assert(Entry(menu, "Export").menuList[1].arg1 == 5, "an export format follows the clicked category")

assert(AngryEra_CategoryMenu(99) == nil, "a missing category has no menu")

-- Layout saves are bound to immutable identity and merge only $LAYOUT into the
-- newest Vars rather than the table that happened to be open originally.
local layoutEditor = AngryEra.utils.layout_editor
assert(type(layoutEditor) == "table", "layout editor internals are available")

local providers = layoutEditor.BuildLayoutProviders({
    { FullName = "Alex-RealmA", ShortName = "Alex", Text = "Alex", Available = true },
    { FullName = "Alex-RealmB", ShortName = "Alex", Text = "Alex-RealmB", Available = true },
    { FullName = "Blair-RealmB", ShortName = "Blair", Text = "Blair-RealmB", Available = true },
    { FullName = "Casey-RealmB", ShortName = "Casey", Text = "Casey-RealmB", Available = true },
    { FullName = "Casey-RealmC", ShortName = "Casey", Text = "Casey-RealmC", Available = true },
}, {})
assert(providers.ResolveRosterName("Alex") == "Alex-RealmA", "an unqualified name prefers an exact own-realm member")
assert(providers.ResolveRosterName("Alex-RealmB") == "Alex-RealmB", "a qualified name resolves exactly")
assert(providers.ResolveRosterName("Blair") == "Blair-RealmB", "a unique cross-realm short name resolves safely")
assert(providers.ResolveRosterName("Casey") == nil, "an ambiguous short name without an own-realm match is rejected")

-- A locally owned/background page derives inherited variables from the local
-- category tree. An exact active remote page instead uses the authoritative
-- ancestor layers transmitted with that page, even if its receiver-private
-- placement points somewhere else.
local localCategorySyncId = "ae3i:1:2:3:4:category:40"
local remoteCategorySyncId = "ae3i:5:6:7:8:category:50"
local localPageSyncId = "ae3i:1:2:3:4:page:41"
local remotePageSyncId = "ae3i:5:6:7:8:page:51"
AngryAssign_Categories[40] = {
    Id = 40,
    SyncId = localCategorySyncId,
    Vars = "Inherited=local\nLocalOnly=yes\n$SQUARE=LocalTank\n$LAYOUT=Local/1: {{Inherited}}",
}
AngryAssign_Pages[41] = {
    Id = 41,
    SyncId = localPageSyncId,
    CategoryId = 40,
    Vars = "Role=local-page",
    LocallyOwned = true,
}
AngryAssign_Pages[51] = {
    Id = 51,
    SyncId = remotePageSyncId,
    CategoryId = 40,
    Revision = 7,
    RevisionId = "fcs32:remote7",
    Vars = "Role=canonical\nCanonicalOnly=yes",
    LocallyOwned = false,
}

function AngryEra:IsLocallyOwned(entity)
    return entity.LocallyOwned == true
end

local activeReference
local activeContext
local retainedContext
local contextRequest
function AngryEra:GetActiveDisplayReference()
    return activeReference
end
function AngryEra:GetActivePageRenderContext(syncId, revision, revisionId, contextRevisionId)
    contextRequest = { syncId, revision, revisionId, contextRevisionId }
    return activeContext
end
function AngryEra:GetAuthoritativePageRenderContext()
    return retainedContext
end

local localReference = layoutEditor.ReferenceEntity(41, "page")
local effective =
    layoutEditor.EffectiveLayoutVariables(localReference, AngryAssign_Pages[41], AngryAssign_Pages[41].Vars)
assert(effective.Inherited == "local" and effective.LocalOnly == "yes", "a local page uses its local category chain")
assert(effective.Role == "local-page", "local page variables override their category")
assert(effective["$SQUARE"] == "LocalTank", "local inherited metadata remains effective")
local effectiveSource, inheritedSource =
    layoutEditor.EffectiveLayoutSource(localReference, AngryAssign_Pages[41], AngryAssign_Pages[41].Vars)
assert(effectiveSource == "Local/1: {{Inherited}}", "an inherited layout keeps its raw variable token")
assert(inheritedSource == true, "the editor identifies an inherited layout source")

activeReference = {
    SyncId = remotePageSyncId,
    Revision = 7,
    RevisionId = "fcs32:remote7",
    ContextRevisionId = "fcs32:context7",
}
activeContext = {
    Page = {
        SyncId = remotePageSyncId,
        Revision = 7,
        RevisionId = "fcs32:remote7",
        ParentSyncId = remoteCategorySyncId,
    },
    AncestorVariableLayers = {
        {
            SyncId = remoteCategorySyncId,
            Vars = "{\"Inherited\":\"remote\",\"RemoteOnly\":\"yes\",\"Role\":\"remote-ancestor\",\"$SQUARE\":\"RemoteTank\",\"$LAYOUT\":\"Remote/1: {{Role}}\"}",
        },
    },
}
local remoteReference = layoutEditor.ReferenceEntity(51, "page")
effective = layoutEditor.EffectiveLayoutVariables(remoteReference, AngryAssign_Pages[51], AngryAssign_Pages[51].Vars)
assert(effective.Inherited == "remote" and effective.RemoteOnly == "yes", "a remote page uses transmitted ancestors")
assert(effective.LocalOnly == nil, "a remote page never borrows its receiver-private category variables")
assert(
    effective.Role == "canonical" and effective.CanonicalOnly == "yes",
    "canonical page Vars override remote ancestors"
)
assert(effective["$SQUARE"] == "RemoteTank", "remote inherited metadata remains effective")
effectiveSource, inheritedSource =
    layoutEditor.EffectiveLayoutSource(remoteReference, AngryAssign_Pages[51], AngryAssign_Pages[51].Vars)
assert(effectiveSource == "Remote/1: {{Role}}", "a remote inherited layout keeps its authoritative raw token")
assert(inheritedSource == true, "a remote ancestor layout is marked inherited")
assert(
    contextRequest[1] == remotePageSyncId
        and contextRequest[2] == 7
        and contextRequest[3] == "fcs32:remote7"
        and contextRequest[4] == "fcs32:context7",
    "the editor requests the exact active page tuple"
)

effective = layoutEditor.EffectiveLayoutVariables(
    remoteReference,
    AngryAssign_Pages[51],
    "{\"Role\":\"draft\",\"DraftOnly\":\"yes\"}"
)
assert(effective.Inherited == "remote" and effective.Role == "draft", "assistant draft Vars override remote ancestors")
assert(effective.DraftOnly == "yes" and effective.CanonicalOnly == nil, "the draft replaces canonical page Vars")
effectiveSource, inheritedSource = layoutEditor.EffectiveLayoutSource(
    remoteReference,
    AngryAssign_Pages[51],
    "{\"Role\":\"draft\",\"$LAYOUT\":\"Draft/1: {{Role}}\"}"
)
assert(effectiveSource == "Draft/1: {{Role}}", "a draft layout overrides its remote ancestor without resolving")
assert(inheritedSource == false, "a draft's own layout is not marked inherited")

activeContext = nil
effective = layoutEditor.EffectiveLayoutVariables(remoteReference, AngryAssign_Pages[51], AngryAssign_Pages[51].Vars)
assert(effective.Role == "canonical", "a missing exact context retains canonical page Vars")
assert(effective.LocalOnly == nil, "a missing exact remote context fails closed instead of using local ancestry")

activeReference = nil
retainedContext = {
    Page = {
        SyncId = remotePageSyncId,
        Revision = 7,
        RevisionId = "fcs32:remote7",
        ParentSyncId = remoteCategorySyncId,
    },
    AncestorVariableLayers = {
        {
            SyncId = remoteCategorySyncId,
            Vars = "Inherited=retained\nBackgroundOnly=yes\n$LAYOUT=Background/1: {{Role}}",
        },
    },
}
effective = layoutEditor.EffectiveLayoutVariables(remoteReference, AngryAssign_Pages[51], AngryAssign_Pages[51].Vars)
assert(effective.Inherited == "retained", "a background remote page uses its retained authoritative context")
assert(effective.BackgroundOnly == "yes", "retained background variables reach the editor")
assert(effective.LocalOnly == nil, "a background remote page never borrows its private local placement")
effectiveSource, inheritedSource =
    layoutEditor.EffectiveLayoutSource(remoteReference, AngryAssign_Pages[51], AngryAssign_Pages[51].Vars)
assert(effectiveSource == "Background/1: {{Role}}", "a background remote layout keeps retained raw tokens")
assert(inheritedSource == true, "a retained remote layout is marked inherited")

effective = layoutEditor.EffectiveLayoutVariables(localReference, AngryAssign_Pages[41], AngryAssign_Pages[41].Vars)
assert(effective.Inherited == "local", "a background local page continues to use its category chain")

AngryAssign_Categories[42] = {
    Id = 42,
    SyncId = "ae3i:1:2:3:4:category:42",
    Vars = "{",
}
AngryAssign_Pages[43] = {
    Id = 43,
    SyncId = "ae3i:1:2:3:4:page:43",
    CategoryId = 42,
    Vars = "Role=page-only",
    LocallyOwned = true,
}
local fallbackReference = layoutEditor.ReferenceEntity(43, "page")
local fallbackVariables, fallbackError =
    layoutEditor.EffectiveLayoutVariables(fallbackReference, AngryAssign_Pages[43], AngryAssign_Pages[43].Vars)
assert(fallbackVariables.Role == "page-only", "a damaged ancestor falls back to valid page variables")
assert(fallbackError == "invalid-variables", "the editor preserves the inherited-variable error for visibility")

function AngryEra:Print() end
function AngryEra:CategoryUpdated() end

local updatedPageId, updatedPageVars
local proposalMode = false
local proposalCount = 0
local sharedDraft
function AngryEra:UpdatePageVars(id, vars)
    updatedPageId, updatedPageVars = id, vars
    if proposalMode then
        proposalCount = proposalCount + 1
        sharedDraft.Desired.Vars = vars
        return true, "queued", true
    end
    AngryAssign_Pages[id].Vars = vars
    return true, nil, false
end

function AngryEra:GetSharedPageChangeDraft()
    return sharedDraft
end

AngryAssign_Pages[20] = {
    Id = 20,
    SyncId = "install:page:20",
    Name = "Original",
    Vars = "MT=Old\nNOTE=before",
}
local reference = layoutEditor.ReferenceEntity(20, "page")
AngryAssign_Pages[20] = {
    Id = 20,
    SyncId = "install:page:20",
    Name = "Replacement",
    Vars = "MT=New\nNOTE=after",
}
local saved, saveError, proposed = layoutEditor.SaveSource(reference, "Tanks/1: MT")
assert(saved and not saveError and not proposed, "a replaced record is found again by SyncId")
assert(updatedPageId == 20, "the current local id receives the layout")
assert(updatedPageVars:find("MT=New", 1, true), "a concurrent variable edit is retained")
assert(updatedPageVars:find("NOTE=after", 1, true), "unrelated current variables are retained")
assert(updatedPageVars:find("$LAYOUT=Tanks/1: MT", 1, true), "the new layout is merged")

AngryAssign_Pages[20].Vars = "{\"MT\":\"Json\",\"Enabled\":true,\"Nested\":{\"Value\":3},\"$LAYOUT\":\"Old/1: MT\"}"
saved, saveError, proposed = layoutEditor.SaveSource(reference, "New/1: {{MT}}")
assert(saved and not saveError and not proposed, "a JSON-backed layout save succeeds")
local jsonVars = AngryEra.utils.json.JSON_TryDecode(updatedPageVars)
assert(type(jsonVars) == "table", "a JSON-backed layout remains a JSON object")
assert(jsonVars.MT == "Json" and jsonVars.Enabled == true, "JSON scalar variables survive a layout save")
assert(type(jsonVars.Nested) == "table" and jsonVars.Nested.Value == 3, "JSON object variables survive a layout save")
assert(jsonVars["$LAYOUT"] == "New/1: {{MT}}", "only the JSON layout value changes")

local retired = layoutEditor.ReferenceEntity(20, "page")
AngryAssign_Pages[20] = {
    Id = 20,
    SyncId = "install:page:other",
    Name = "Reused id",
    Vars = "SAFE=yes",
}
saved, saveError = layoutEditor.SaveSource(retired, "Wrong/1: Someone")
assert(not saved and saveError == "layout-target-no-longer-exists", "an id reused by another page is never mutated")
assert(AngryAssign_Pages[20].Vars == "SAFE=yes", "the reused page remains untouched")

AngryAssign_Pages[21] = {
    Id = 21,
    SyncId = "install:page:21",
    Name = "Assistant page",
    Vars = "MT=Canonical",
}
sharedDraft = {
    SyncId = "install:page:21",
    Desired = {
        Name = "Assistant page",
        Vars = "MT=Draft\nOTHER=kept",
        Contents = "",
    },
}
proposalMode = true
reference = layoutEditor.ReferenceEntity(21, "page")
saved, saveError, proposed = layoutEditor.SaveSource(reference, "Tanks/1: {{MT}}")
assert(saved and saveError == "queued" and proposed, "an assistant layout save remains a proposal")
assert(updatedPageVars:find("MT=Draft", 1, true), "the layout merges onto the retained assistant draft")
assert(updatedPageVars:find("OTHER=kept", 1, true), "other draft variables are retained")
saved, saveError, proposed = layoutEditor.SaveSource(reference, "Tanks/1: {{MT}}")
assert(saved and saveError == "proposal-pending" and proposed, "a pending proposal never looks canonical to Apply")
assert(proposalCount == 1, "an unchanged pending draft is not submitted twice")
proposalMode = false
sharedDraft = nil

-- Custom templates preserve category and page Vars and feed page Vars into
-- CreatePage atomically, before the model publishes its initial revision.
AngryAssign_Categories = {
    [30] = {
        Id = 30,
        Name = "Template source",
        Vars = "{\"$LAYOUT\":\"Core/1: Tank\",\"ROLE\":\"main\"}",
    },
}
AngryAssign_Pages = {
    [31] = {
        Id = 31,
        Name = "Second",
        CategoryId = 30,
        Index = 2,
        Contents = "Second note",
        Vars = "MT=Two",
    },
    [32] = {
        Id = 32,
        Name = "First",
        CategoryId = 30,
        Index = 1,
        Contents = "First note",
        Vars = "MT=One\n$LAYOUT=First/1: {{MT}}",
    },
}
AngryAssign_Templates = {}
assert(AngryEra:SaveTemplate("Saved layout", 30), "a category with pages saves as a template")
local template = AngryAssign_Templates[1]
assert(template.vars == AngryAssign_Categories[30].Vars, "category Vars are saved")
assert(
    template.pages[1].name == "First" and template.pages[1].vars == AngryAssign_Pages[32].Vars,
    "page order and Vars are saved"
)
assert(
    template.pages[2].name == "Second" and template.pages[2].vars == AngryAssign_Pages[31].Vars,
    "every page Vars value is saved"
)

AngryAssign_Categories = {}
AngryAssign_Pages = {}
local nextCategoryId = 100
local nextPageId = 200
local createCalls = {}
function AngryEra:NewLocalCategoryRecord(fields)
    local record = {}
    for key, value in pairs(fields) do
        record[key] = value
    end
    record.Id = nextCategoryId
    nextCategoryId = nextCategoryId + 1
    return record
end
function AngryEra:CreatePage(name, content, categoryId, index, suppressRefresh, initialVars)
    local id = nextPageId
    nextPageId = nextPageId + 1
    AngryAssign_Pages[id] = {
        Id = id,
        Name = name,
        Contents = content,
        CategoryId = categoryId,
        Index = index,
        Vars = initialVars,
    }
    createCalls[#createCalls + 1] = {
        Id = id,
        SuppressRefresh = suppressRefresh,
        InitialVars = initialVars,
    }
    return true, nil, id
end
function AngryEra:UpdateTree() end
function AngryEra:UpdateSelected() end
function AngryEra:RefreshDisplayedPageAfterHierarchyMutation() end

local loaded, _, loadedCategoryId = layoutEditor.LoadTemplate(template)
assert(loaded and loadedCategoryId == 100, "the saved template loads into a new category")
assert(AngryAssign_Categories[100].Vars == template.vars, "loaded category Vars round-trip")
assert(createCalls[1].InitialVars == template.pages[1].vars, "first page Vars reach atomic creation")
assert(createCalls[2].InitialVars == template.pages[2].vars, "second page Vars reach atomic creation")
assert(createCalls[1].SuppressRefresh == true, "template pages continue to batch display refresh")

print("Category menu tests passed.")
