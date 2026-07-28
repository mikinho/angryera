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
local assignedRoleRows = {
    { Name = "Roselea", FullName = "Roselea-Mankrik", Role = "TANK" },
    { Name = "Eblis", FullName = "Eblis-Mankrik", Role = "HEALER" },
    { Name = "Zessy", FullName = "Zessy-Mankrik", Role = "HEALER" },
    { Name = "Kwayteow", FullName = "Kwayteow-Mankrik", Role = "DPS" },
}
local assignedRoleError
AngryEra.utils.roster = {
    ScanAssignedRoles = function()
        if assignedRoleError then
            return nil, assignedRoleError
        end
        return assignedRoleRows
    end,
}

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

local pinned = {}
function AngryEra:IsPinned(category)
    return pinned[category.Id] == true
end

function AngryEra:SetPinned(category, value)
    pinned[category.Id] = value == true
    return true
end

function AngryEra:Print() end
local treeUpdates = 0

AngryAssign_Pages = {}
AngryAssign_Categories = {
    [4] = { Id = 4, Name = "Naxxramas" },
    [5] = { Id = 5, Name = "Temple of Ahn'Qiraj" },
}

assert(loadfile("modules/ui/editor.lua"))("AngryEra", app)
function AngryEra:UpdateTree()
    treeUpdates = treeUpdates + 1
end

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
    "Pin",
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
assert(Entry(menu, "Pin").disabled ~= true, "a read-only category can still be pinned locally")

Entry(menu, "Pin").func(nil, 4)
assert(pinned[4], "Pin protects the clicked category")
assert(treeUpdates == 1, "pinning a category should refresh the tree exactly once")
menu = AngryEra_CategoryMenu(4)
assert(Entry(menu, "Unpin"), "a pinned category offers Unpin")
Entry(menu, "Unpin").func(nil, 4)
assert(not pinned[4], "Unpin releases the clicked category")
assert(treeUpdates == 2, "unpinning a category should refresh the tree exactly once")
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
assert(
    layoutEditor.NormalizeVariableEditorDraft("") == nil
        and layoutEditor.NormalizeVariableEditorDraft("MT=\nOT1=\nOT2=\nOT3=\nOT4=\nOT5=\nMARK=") == nil,
    "an empty variable draft and its untouched starter template are equivalent"
)
assert(
    layoutEditor.NormalizeVariableEditorDraft("ONE=1\r\nTWO=2") == "ONE=1\nTWO=2",
    "variable dirty checks normalize platform line endings"
)
assert(
    not layoutEditor.GroupLayoutDraftIsDirty(true, "Tanks/1: MT", false, "Tanks/1: MT"),
    "an unchanged direct group layout is clean"
)
assert(
    layoutEditor.GroupLayoutDraftIsDirty(true, "Tanks/1: MT", false, "Tanks/1: OT"),
    "a changed direct group layout is dirty"
)
assert(
    layoutEditor.GroupLayoutDraftIsDirty(true, "Tanks/1: MT", true, "Inherited/1: MT"),
    "selecting inheritance from a direct layout is dirty"
)
assert(
    not layoutEditor.GroupLayoutDraftIsDirty(false, "Inherited/1: MT", true, "Inherited/1: MT"),
    "an unchanged inherited group layout is clean"
)
assert(
    layoutEditor.GroupLayoutDraftIsDirty(false, "Inherited/1: MT", false, "Inherited/1: MT"),
    "creating a direct override is dirty even when its visible source matches inheritance"
)
assert(
    layoutEditor.GroupLayoutDraftIsDirty(
        true,
        "Tanks/1: MT",
        false,
        "Tanks/1: MT",
        "Tanks/1: MT\nunfinished text",
        "Tanks/1: MT"
    ),
    "raw text that parsing would discard still counts as an unsaved group-layout change"
)
assert(
    not layoutEditor.GroupLayoutDraftIsDirty(
        true,
        "Tanks/1: MT",
        false,
        "Tanks/1: MT",
        "Tanks/1: MT\r\nHealers/2: Eblis",
        "Tanks/1: MT\nHealers/2: Eblis"
    ),
    "line-ending normalization alone does not dirty the group-layout text view"
)

local function LayoutTestFrame(width, height)
    local frame = {
        width = width or 0,
        height = height or 0,
        points = {},
    }
    function frame:GetWidth()
        return self.width
    end
    function frame:GetHeight()
        return self.height
    end
    function frame:ClearAllPoints()
        self.points = {}
    end
    function frame:SetPoint(...)
        self.points[#self.points + 1] = { ... }
    end
    function frame:Show()
        self.shown = true
    end
    return frame
end

local function LayoutTestWidget(width, height, side)
    local widget = {
        frame = LayoutTestFrame(width, height),
        userdata = {
            side = side,
        },
    }
    function widget:SetWidth(value)
        self.width = value
        self.frame.width = value
    end
    function widget:SetHeight(value)
        self.height = value
        self.frame.height = value
    end
    function widget:GetUserData(key)
        return self.userdata[key]
    end
    function widget:DoLayout()
        self.layoutCount = (self.layoutCount or 0) + 1
    end
    return widget
end

-- Both dialogs share one exact button geometry. Group Layout leaves Apply at
-- the left, while Variables reserves only the resize target at the far right.
local footerOwner = {
    userdata = {},
}
function footerOwner:GetUserData(key)
    return self.userdata[key]
end
function footerOwner:LayoutFinished(_, height)
    self.layoutHeight = height
end
local footerContent = {
    obj = footerOwner,
}
local footerApply = LayoutTestWidget(1, 1, "left")
local footerCancel = LayoutTestWidget(1, 1)
local footerSave = LayoutTestWidget(1, 1)
layoutEditor.DialogFooterLayout(footerContent, { footerApply, footerCancel, footerSave })
assert(
    footerApply.width == 120
        and footerCancel.width == 120
        and footerSave.width == 120
        and footerApply.height == 24
        and footerCancel.height == 24
        and footerSave.height == 24,
    "dialog footers should standardize every action to 120 by 24 pixels"
)
assert(
    footerApply.frame.points[1][1] == "TOPLEFT" and footerApply.frame.points[1][5] == 0,
    "Apply should anchor at the far left"
)
assert(
    footerSave.frame.points[1][1] == "TOPRIGHT" and footerSave.frame.points[1][4] == 0,
    "Group Layout Save should anchor at the far right"
)
assert(
    footerCancel.frame.points[1][1] == "TOPRIGHT" and footerCancel.frame.points[1][4] == -124,
    "Group Layout Cancel should sit one standardized gap to the left of Save"
)
footerOwner.userdata.rightInset = 13
layoutEditor.DialogFooterLayout(footerContent, { footerApply, footerCancel, footerSave })
assert(
    footerSave.frame.points[1][1] == "TOPRIGHT" and footerSave.frame.points[1][4] == -13,
    "Save should stop immediately before the variable editor resize target"
)
assert(
    footerCancel.frame.points[1][1] == "TOPRIGHT" and footerCancel.frame.points[1][4] == -137,
    "Cancel should sit one standardized gap to the left of Save"
)
assert(footerOwner.layoutHeight == 24, "the shared footer should report its fixed height")

-- AceGUI caches smaller Window content dimensions than the frame actually
-- occupies. The variable layout must use the live size or it leaves a visible
-- strip above the footer.
local variableLayoutOwner = {}
function variableLayoutOwner:LayoutFinished(_, height)
    self.layoutHeight = height
end
local variableLayoutContent = LayoutTestFrame(406, 345)
variableLayoutContent.width = 396
variableLayoutContent.height = 333
variableLayoutContent.obj = variableLayoutOwner
function variableLayoutContent:GetWidth()
    return 406
end
function variableLayoutContent:GetHeight()
    return 345
end
local variableImport = LayoutTestWidget(1, 24)
local variableStatus = LayoutTestWidget(1, 20)
local variableBody = LayoutTestWidget(1, 1)
local variableFooter = LayoutTestWidget(1, 24)
layoutEditor.VariableEditorLayout(
    variableLayoutContent,
    { variableImport, variableStatus, variableBody, variableFooter }
)
assert(
    variableImport.width == 406
        and variableStatus.width == 406
        and variableBody.width == 406
        and variableFooter.width == 406,
    "the variable editor should fill the live Window content width"
)
assert(variableBody.height == 271, "the variable body should fill all space above its footer")
assert(
    variableFooter.frame.points[1][1] == "BOTTOMLEFT"
        and variableFooter.frame.points[1][4] == 0
        and variableFooter.frame.points[1][5] == -3
        and variableFooter.frame.points[2][1] == "BOTTOMRIGHT"
        and variableFooter.frame.points[2][5] == -3,
    "the variable footer should share Group Layout's three-pixel bottom overhang"
)
local variableBodyBottom = 24 + 3 + 20 + 3 + variableBody.height
local variableFooterTop = 345 + 3 - 24
assert(
    variableFooterTop - variableBodyBottom == 3,
    "the variable body and footer should retain the same three-pixel visual gap"
)
assert(variableLayoutOwner.layoutHeight == 345, "the variable editor should report its live content height")

local importedRoleSource, importedRoleSummary = layoutEditor.ImportAssignedRoles("KEEP=yes\nHEALERS*=RAID_HEALER*")
assert(
    importedRoleSource and type(importedRoleSummary) == "table",
    "assigned roles should import into a variable draft"
)
assert(
    importedRoleSummary.TANK == 1 and importedRoleSummary.HEALER == 2 and importedRoleSummary.DPS == 1,
    "the assigned-role import should summarize every generated role"
)
local importedRoleVariables = assert(AngryEra.utils.variables.MergeVariableLayers({}, importedRoleSource))
assert(importedRoleVariables.KEEP == "yes", "assigned-role import should preserve unrelated variables")
assert(
    importedRoleVariables.RAID_TANK1 == "Roselea"
        and importedRoleVariables.RAID_HEALER1 == "Eblis"
        and importedRoleVariables.RAID_HEALER2 == "Zessy"
        and importedRoleVariables.RAID_DPS1 == "Kwayteow",
    "assigned-role import should materialize the canonical RAID role variables"
)
assert(
    importedRoleVariables.HEALERS1 == "Eblis" and importedRoleVariables.HEALERS2 == "Zessy",
    "ordinary variable families should compose from imported RAID roles"
)
assignedRoleRows = {
    { Name = "Roselea", FullName = "Roselea-Mankrik", Role = "TANK" },
    { Name = "Aaron", FullName = "Aaron-Mankrik", Role = "HEALER" },
    { Name = "Eblis", FullName = "Eblis-Mankrik", Role = "HEALER" },
    { Name = "Zessy", FullName = "Zessy-Mankrik", Role = "HEALER" },
    { Name = "Kwayteow", FullName = "Kwayteow-Mankrik", Role = "DPS" },
}
local reimportedRoleSource = assert(layoutEditor.ImportAssignedRoles(importedRoleSource))
local reimportedRoleVariables = assert(AngryEra.utils.variables.MergeVariableLayers({}, reimportedRoleSource))
assert(
    reimportedRoleVariables.RAID_HEALER1 == "Eblis"
        and reimportedRoleVariables.RAID_HEALER2 == "Zessy"
        and reimportedRoleVariables.RAID_HEALER3 == "Aaron",
    "re-import should preserve surviving relative order and append newcomers"
)
assignedRoleRows = {
    { Name = "Roselea", FullName = "Roselea-Mankrik", Role = "TANK" },
    { Name = "Eblis-Mankrik", FullName = "Eblis-Mankrik", Role = "HEALER" },
    { Name = "Eblis-Pagle", FullName = "Eblis-Pagle", Role = "HEALER" },
    { Name = "Zessy", FullName = "Zessy-Mankrik", Role = "HEALER" },
    { Name = "Aaron", FullName = "Aaron-Mankrik", Role = "HEALER" },
    { Name = "Kwayteow", FullName = "Kwayteow-Mankrik", Role = "DPS" },
}
local collisionRoleSource = assert(layoutEditor.ImportAssignedRoles(reimportedRoleSource))
local collisionRoleVariables = assert(AngryEra.utils.variables.MergeVariableLayers({}, collisionRoleSource))
assert(
    collisionRoleVariables.RAID_HEALER1 == "Eblis-Mankrik"
        and collisionRoleVariables.RAID_HEALER2 == "Zessy"
        and collisionRoleVariables.RAID_HEALER3 == "Aaron"
        and collisionRoleVariables.RAID_HEALER4 == "Eblis-Pagle",
    "a new cross-realm collision should preserve the canonical identity and order of surviving members"
)
local conflictingRoleImport, conflictingRoleImportError =
    layoutEditor.ImportAssignedRoles("OTHER1=Someone\nRAID_HEALER*=OTHER*")
assert(
    conflictingRoleImport == nil and conflictingRoleImportError == "conflicting-raid-roster-family",
    "an import should reject a same-layer declaration of its managed RAID family"
)
assignedRoleError = "no-assigned-roles"
local failedRoleImport, failedRoleError = layoutEditor.ImportAssignedRoles("KEEP=unchanged")
assert(
    failedRoleImport == nil and failedRoleError == "no-assigned-roles",
    "a failed assigned-role scan should leave the editor source untouched"
)
assignedRoleError = nil

-- Exercise the actual Edit Variables window callbacks. This guards both the
-- import-as-draft contract and the historical `type` parameter shadow that
-- made the Save callback try to call the "category" string as a function.
local createdWidgets = {}
function app.libs.AceGUI.Create(_, widgetType)
    local widget = {
        Type = widgetType,
        callbacks = {},
        children = {},
        frame = {},
        userdata = {},
    }
    if widgetType == "Window" then
        widget.frame.resizeBounds = {}
        function widget.frame:SetResizeBounds(width, height)
            self.resizeBounds[#self.resizeBounds + 1] = { width, height }
        end
    end
    function widget:SetText(text)
        self.text = text
    end
    function widget:GetText()
        return self.text
    end
    function widget:SetCallback(event, callback)
        self.callbacks[event] = callback
    end
    function widget:AddChild(child)
        self.children[#self.children + 1] = child
    end
    function widget:Hide()
        self.hidden = true
    end
    function widget:SetLayout(value)
        self.layout = value
    end
    function widget:SetWidth(value)
        self.width = value
    end
    function widget:SetHeight(value)
        self.height = value
    end
    function widget:SetFullWidth(value)
        self.fullWidth = value
    end
    function widget:DisableButton(value)
        self.buttonDisabled = value
    end
    function widget:SetUserData(key, value)
        self.userdata[key] = value
    end
    function widget:GetUserData(key)
        return self.userdata[key]
    end
    function widget:DoLayout()
        self.layoutCount = (self.layoutCount or 0) + 1
    end
    for _, method in ipairs({ "SetTitle", "EnableResize", "SetLabel", "SetNumLines" }) do
        widget[method] = function() end
    end
    createdWidgets[#createdWidgets + 1] = widget
    return widget
end
function app.libs.AceGUI:Release(widget)
    widget.released = true
end

_G.UISpecialFrames = {}
local categoryWindowSave
local displayedAfterVariableSave = false
function AngryEra:Print() end
function AngryEra:CategoryUpdated(id)
    categoryWindowSave = id
end
function AngryEra:UpdateDisplayed()
    displayedAfterVariableSave = true
end

Entry(AngryEra_CategoryMenu(5), "Edit Variables").func(nil, 5)
local importButtonWidget
local variableCancelWidget
local variableSaveWidget
local variableEditWidget
local variableWindowWidget
local variableFooterWidget
for _, widget in ipairs(createdWidgets) do
    if widget.Type == "Button" and widget.text == "Import Assigned Raid Roles" then
        importButtonWidget = widget
    elseif widget.Type == "Button" and widget.text == "Cancel" then
        variableCancelWidget = widget
    elseif widget.Type == "Button" and widget.text == "Save" then
        variableSaveWidget = widget
    elseif widget.Type == "MultiLineEditBox" then
        variableEditWidget = widget
    elseif widget.Type == "Window" then
        variableWindowWidget = widget
    elseif widget.Type == "SimpleGroup" and widget.userdata.rightInset then
        variableFooterWidget = widget
    end
end
assert(
    importButtonWidget
        and variableCancelWidget
        and variableSaveWidget
        and variableEditWidget
        and variableWindowWidget
        and variableFooterWidget,
    "the variable editor should build its controls"
)
assert(
    variableCancelWidget.width == 120
        and variableSaveWidget.width == 120
        and variableFooterWidget.height == 24
        and variableFooterWidget.userdata.rightInset == 13,
    "the variable editor should use the standardized footer geometry"
)
assert(variableEditWidget.buttonDisabled == true, "the variable editor should hide its legacy Accept button")
assert(
    variableWindowWidget.layout == "AngryEraVariableEditor" and variableWindowWidget.layoutCount == 1,
    "the variable editor should install and immediately run its responsive layout"
)
assert(
    variableWindowWidget.frame.resizeBounds[1][1] == 320 and variableWindowWidget.frame.resizeBounds[1][2] == 320,
    "the variable editor should retain a usable minimum size"
)
local variableEscapeName = UISpecialFrames[1]
assert(
    variableEscapeName and variableEscapeName:match("^AngryEra_AuxiliaryEditor_Window_"),
    "the variable editor owns one temporary Escape registration"
)
local layoutCountBeforeImport = variableWindowWidget.layoutCount
importButtonWidget.callbacks.OnClick()
assert(
    variableWindowWidget.layoutCount == layoutCountBeforeImport + 1,
    "changing the import status should immediately reflow the variable editor"
)
assert(AngryAssign_Categories[5].Vars == nil, "Import Assigned Raid Roles should change only the open editor draft")
assert(
    variableEditWidget:GetText():find(AngryEra.utils.variables.RAID_ROSTER_DIRECTIVE, 1, true),
    "the import button should place the managed roster in the editor"
)
assignedRoleError = "no-assigned-roles"
local importedDraft = variableEditWidget:GetText()
layoutCountBeforeImport = variableWindowWidget.layoutCount
importButtonWidget.callbacks.OnClick()
assert(
    variableEditWidget:GetText() == importedDraft and variableWindowWidget.layoutCount == layoutCountBeforeImport + 1,
    "a failed role import should preserve the draft and reflow its error status"
)
assignedRoleError = nil
variableSaveWidget.callbacks.OnClick()
assert(
    categoryWindowSave == 5
        and AngryAssign_Categories[5].Vars == variableEditWidget:GetText()
        and displayedAfterVariableSave
        and variableWindowWidget.hidden
        and variableWindowWidget.released,
    "Save should commit the imported draft to the exact category and close the window"
)
local restoredBounds = variableWindowWidget.frame.resizeBounds[#variableWindowWidget.frame.resizeBounds]
assert(
    restoredBounds[1] == 240 and restoredBounds[2] == 240,
    "closing the variable editor should restore the pooled Window's default resize bounds"
)
assert(#UISpecialFrames == 0, "saving removes the variable editor's Escape registration")
assert(_G[variableEscapeName] == nil, "saving releases the variable editor's temporary global frame")
AngryAssign_Categories[5].Vars = nil

local providers = layoutEditor.BuildLayoutProviders({
    { FullName = "Alex-RealmA", ShortName = "Alex", Text = "Alex", Available = true },
    { FullName = "Alex-RealmB", ShortName = "Alex", Text = "Alex-RealmB", Available = true },
    { FullName = "Blair-RealmB", ShortName = "Blair", Text = "Blair-RealmB", Available = true },
    { FullName = "Casey-RealmB", ShortName = "Casey", Text = "Casey-RealmB", Available = true },
    { FullName = "Casey-RealmC", ShortName = "Casey", Text = "Casey-RealmC", Available = true },
}, {})
assert(providers.ResolveRosterName("Alex") == nil, "an unqualified collision is ambiguous even on the player's realm")
assert(providers.ResolveRosterName("Alex-RealmB") == "Alex-RealmB", "a qualified name resolves exactly")
assert(providers.ResolveRosterName("Blair") == "Blair-RealmB", "a unique cross-realm short name resolves safely")
assert(providers.ResolveRosterName("Casey") == nil, "an ambiguous short name without an own-realm match is rejected")

-- A locally owned/background page derives inherited variables from the local
-- category tree. An exact active remote page instead uses the authoritative
-- ancestor layers transmitted with that page, even if its receiver-private
-- placement points somewhere else.
local localCategorySyncId = "ae3i:1:2:3:4:category:40"
local localRootCategorySyncId = "ae3i:1:2:3:4:category:39"
local remoteCategorySyncId = "ae3i:5:6:7:8:category:50"
local localPageSyncId = "ae3i:1:2:3:4:page:41"
local remotePageSyncId = "ae3i:5:6:7:8:page:51"
AngryAssign_Categories[39] = {
    Id = 39,
    SyncId = localRootCategorySyncId,
    Vars = "$LAYOUT=Root/8: RootTank",
}
AngryAssign_Categories[40] = {
    Id = 40,
    SyncId = localCategorySyncId,
    CategoryId = 39,
    Vars = "Inherited=local\nLocalOnly=yes\nPRIEST1=LocalPriest\nHEALER*=PRIEST*\n$SQUARE=LocalTank\n$LAYOUT=Local/1: {{Inherited}}",
}
AngryAssign_Pages[41] = {
    Id = 41,
    SyncId = localPageSyncId,
    CategoryId = 40,
    Vars = "Role=local-page\nPRIEST1=Roselea\nHEALER*=PRIEST*",
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
assert(
    effective.HEALER1 == "Roselea" and effective["HEALER*"] == nil,
    "the layout editor receives concrete family members without declaration pseudo-keys"
)
local validVariables, variableValidationError = layoutEditor.ValidateVariableSource(
    localReference,
    AngryAssign_Pages[41],
    "PRIEST1=Roselea\nPALADIN1=Zessy\nHEALER*=PRIEST*,PALADIN*"
)
assert(validVariables and not variableValidationError, "the editor should accept a valid family before saving")
validVariables, variableValidationError =
    layoutEditor.ValidateVariableSource(localReference, AngryAssign_Pages[41], "A*=B*\nB*=A*")
assert(
    validVariables == false and variableValidationError == "variable-family-cycle",
    "the editor should reject a family cycle before saving"
)
validVariables, variableValidationError =
    layoutEditor.ValidateVariableSource(localReference, AngryAssign_Pages[41], "HEALER* PRIEST*")
assert(
    validVariables == false and variableValidationError == "invalid-variable-line",
    "the editor should reject a mistyped family line instead of silently ignoring it"
)
assert(effective["$SQUARE"] == "LocalTank", "local inherited metadata remains effective")
local effectiveSource, inheritedSource =
    layoutEditor.EffectiveLayoutSource(localReference, AngryAssign_Pages[41], AngryAssign_Pages[41].Vars)
assert(effectiveSource == "Local/1: {{Inherited}}", "an inherited layout keeps its raw variable token")
assert(inheritedSource == true, "the editor identifies an inherited layout source")
assert(
    layoutEditor.InheritedLayoutSource(localReference, AngryAssign_Pages[41]) == "Local/1: {{Inherited}}",
    "the inheritance checkbox previews the nearest ancestor layout"
)
local nestedCategoryReference = layoutEditor.ReferenceEntity(40, "category")
assert(
    layoutEditor.InheritedLayoutSource(nestedCategoryReference, AngryAssign_Categories[40]) == "Root/8: RootTank",
    "a category can inherit its parent category's layout"
)

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
            Vars = "{\"Inherited\":\"remote\",\"RemoteOnly\":\"yes\",\"Role\":\"remote-ancestor\",\"PRIEST1\":\"RemotePriest\",\"HEALER*\":\"PRIEST*\",\"$SQUARE\":\"RemoteTank\",\"$LAYOUT\":\"Remote/1: {{Role}}\"}",
        },
    },
}
local remoteReference = layoutEditor.ReferenceEntity(51, "page")
effective = layoutEditor.EffectiveLayoutVariables(remoteReference, AngryAssign_Pages[51], AngryAssign_Pages[51].Vars)
assert(effective.Inherited == "remote" and effective.RemoteOnly == "yes", "a remote page uses transmitted ancestors")
assert(effective.LocalOnly == nil, "a remote page never borrows its receiver-private category variables")
assert(
    effective.HEALER1 == "RemotePriest" and effective["HEALER*"] == nil,
    "the layout editor expands only the leader's authoritative variable family"
)
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
local updatedCategoryId
function AngryEra:CategoryUpdated(id)
    updatedCategoryId = id
end

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
local savedVariables, savedVariableError, proposedVariables =
    layoutEditor.SaveVariableSource(reference, "MT=VariableEditor\nNOTE=saved", "MT=Old\nNOTE=before")
assert(
    savedVariables and not savedVariableError and not proposedVariables,
    "the variable editor should save through the page update path"
)
assert(
    AngryAssign_Pages[20].Vars == "MT=VariableEditor\nNOTE=saved",
    "the variable editor should commit the validated source"
)
editable = false
savedVariables, savedVariableError = layoutEditor.SaveVariableSource(reference, "MT=Denied")
assert(not savedVariables and savedVariableError == "Permission denied.", "permission loss should block a stale dialog")
assert(
    AngryAssign_Pages[20].Vars == "MT=VariableEditor\nNOTE=saved",
    "a denied variable save should not mutate the page"
)
editable = true

AngryAssign_Pages[20].Vars = "MT=ExternalChange"
savedVariables, savedVariableError =
    layoutEditor.SaveVariableSource(reference, "MT=StaleWindow", "MT=VariableEditor\nNOTE=saved")
assert(
    not savedVariables and savedVariableError == "variable-source-changed",
    "a variable editor should reject a concurrent variable change"
)
assert(AngryAssign_Pages[20].Vars == "MT=ExternalChange", "a concurrent variable edit should remain untouched")

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

saved, saveError, proposed = layoutEditor.SaveSource(reference, nil)
assert(saved and not saveError and not proposed, "saving Inherit removes a JSON-backed local layout override")
jsonVars = AngryEra.utils.json.JSON_TryDecode(updatedPageVars)
assert(jsonVars.MT == "Json" and jsonVars.Enabled == true, "inheritance preserves unrelated JSON variables")
assert(jsonVars["$LAYOUT"] == nil, "inheritance removes the local JSON layout key")

saved, saveError, proposed = layoutEditor.SaveSource(reference, "")
assert(saved and not saveError and not proposed, "an unchecked empty custom layout remains a local override")
jsonVars = AngryEra.utils.json.JSON_TryDecode(updatedPageVars)
assert(jsonVars["$LAYOUT"] == "", "an empty custom layout remains distinct from Inherit")

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
savedVariables, savedVariableError = layoutEditor.SaveVariableSource(retired, "WRONG=yes")
assert(
    not savedVariables and savedVariableError == "layout-target-no-longer-exists",
    "a stale variable editor should reject a reused page id"
)
assert(AngryAssign_Pages[20].Vars == "SAFE=yes", "a stale variable editor should leave the reused page untouched")

local categoryReference = layoutEditor.ReferenceEntity(5, "category")
savedVariables, savedVariableError, proposedVariables =
    layoutEditor.SaveVariableSource(categoryReference, "CATEGORY_ROLE=healers")
assert(
    savedVariables and not savedVariableError and not proposedVariables,
    "the variable editor should save a local category directly"
)
assert(
    AngryAssign_Categories[5].Vars == "CATEGORY_ROLE=healers" and updatedCategoryId == 5,
    "a category variable save should update the exact category"
)

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
saved, saveError, proposed = layoutEditor.SaveSource(reference, nil)
assert(saved and saveError == "queued" and proposed, "an assistant can propose restoring inherited layout")
assert(updatedPageVars:find("MT=Draft", 1, true), "inheritance keeps unrelated assistant draft variables")
assert(not updatedPageVars:find("$LAYOUT", 1, true), "the inheritance proposal removes only the draft layout")
saved, saveError, proposed = layoutEditor.SaveSource(reference, nil)
assert(saved and saveError == "proposal-pending" and proposed, "a pending inherit proposal is not duplicated")
assert(proposalCount == 2, "the inherit proposal is submitted exactly once")
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
