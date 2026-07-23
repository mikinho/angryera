-- -------------------------------------------------------------------------------
-- Angry Era: modules/api.lua
--
-- Public displayed-note API for WeakAuras and other addons.
-- The display pipeline reports every rebuild here; snapshots are stored for
-- pull-based consumers and ANGRYERA_NOTE_UPDATE fires when the note changes.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local variables = AngryEra.utils.variables

if not variables or type(variables.PartitionResolvedVariables) ~= "function" then
    error("AngryEra variable helpers must load before the note API")
end

AngryEra.NOTE_API_VERSION = 1
AngryEra.NOTE_UPDATE_EVENT = "ANGRYERA_NOTE_UPDATE"

local MAX_CLONE_DEPTH = 64

local function IsPlainTable(value)
    return type(value) == "table"
end

local function CloneValue(value, depth)
    if not IsPlainTable(value) then
        return value
    end

    local json = AngryEra.utils.json
    if json and value == json.JSON_NULL then
        return value
    end

    depth = depth or 0
    if depth >= MAX_CLONE_DEPTH then
        return nil
    end

    local copy = {}
    for key, entry in pairs(value) do
        copy[key] = CloneValue(entry, depth + 1)
    end
    return copy
end

local function ResolveCategoryName(self, syncId)
    if type(syncId) ~= "string" or type(self.GetCategoryBySyncId) ~= "function" then
        return nil
    end
    local ok, category = pcall(self.GetCategoryBySyncId, self, syncId)
    if not ok or not IsPlainTable(category) or type(category.Name) ~= "string" then
        return nil
    end
    return category.Name
end

local function ResolveLocalCategory(page)
    if type(page.CategoryId) ~= "number" or not IsPlainTable(AngryAssign_Categories) then
        return nil, nil
    end
    local category = AngryAssign_Categories[page.CategoryId]
    if not IsPlainTable(category) or type(category.Name) ~= "string" then
        return nil, nil
    end
    return category.Name, type(category.SyncId) == "string" and category.SyncId or nil
end

local function ResolveActiveReference(self, page)
    if
        type(page.SyncId) ~= "string"
        or type(self.GetActiveDisplayReference) ~= "function"
        or type(self.GetActivePageRenderContext) ~= "function"
    then
        return nil, nil
    end

    local referenceOk, reference = pcall(self.GetActiveDisplayReference, self)
    if not referenceOk or not IsPlainTable(reference) or reference.SyncId ~= page.SyncId then
        return nil, nil
    end

    local contextOk, context = pcall(
        self.GetActivePageRenderContext,
        self,
        reference.SyncId,
        reference.RevisionId,
        reference.ContextRevisionId
    )
    if not contextOk or not IsPlainTable(context) then
        return reference, nil
    end
    return reference, context
end

local function BuildAncestors(self, context)
    local ancestors = {}
    local layers = IsPlainTable(context) and context.AncestorVariableLayers or nil
    if not IsPlainTable(layers) then
        return ancestors
    end

    for index = 1, #layers do
        local layer = layers[index]
        if IsPlainTable(layer) and type(layer.SyncId) == "string" then
            ancestors[#ancestors + 1] = {
                SyncId = layer.SyncId,
                Name = ResolveCategoryName(self, layer.SyncId),
            }
        end
    end
    return ancestors
end

local function BuildSnapshot(self, context)
    local page = context.Page
    local publicVariables, meta = variables.PartitionResolvedVariables(context.MergedVariables or {})
    local reference, activeContext = ResolveActiveReference(self, page)
    local ancestors = BuildAncestors(self, activeContext)

    local categorySyncId = type(page.ParentSyncId) == "string" and page.ParentSyncId or nil
    local categoryName = ResolveCategoryName(self, categorySyncId)
    if categoryName == nil and #ancestors > 0 then
        categoryName = ancestors[#ancestors].Name
        categorySyncId = categorySyncId or ancestors[#ancestors].SyncId
    end
    if categoryName == nil and categorySyncId == nil then
        categoryName, categorySyncId = ResolveLocalCategory(page)
    end

    local localId = IsPlainTable(AngryAssign_State) and AngryAssign_State.displayed or nil

    return {
        LocalId = type(localId) == "number" and localId or nil,
        SyncId = type(page.SyncId) == "string" and page.SyncId or nil,
        RevisionId = reference and reference.RevisionId or nil,
        ContextRevisionId = reference and reference.ContextRevisionId or nil,
        Name = type(page.Name) == "string" and page.Name or nil,
        Category = categoryName,
        CategorySyncId = categorySyncId,
        Ancestors = ancestors,
        Raw = type(page.Contents) == "string" and page.Contents or "",
        Rendered = type(context.RenderedText) == "string" and context.RenderedText or "",
        UpdatedAt = type(page.UpdatedAt) == "number" and page.UpdatedAt or nil,
        UpdatedBy = type(page.UpdatedBy) == "string" and page.UpdatedBy or nil,
        Vars = publicVariables or {},
        Meta = meta or {},
    }
end

local function SnapshotChanged(previous, snapshot)
    if previous == nil and snapshot == nil then
        return false
    end
    if previous == nil or snapshot == nil then
        return true
    end
    return previous.SyncId ~= snapshot.SyncId
        or previous.RevisionId ~= snapshot.RevisionId
        or previous.ContextRevisionId ~= snapshot.ContextRevisionId
        or previous.Rendered ~= snapshot.Rendered
        or previous.Category ~= snapshot.Category
end

local function EmitNoteEvent(self, snapshot)
    local syncId = snapshot and snapshot.SyncId or nil
    local name = snapshot and snapshot.Name or nil
    local category = snapshot and snapshot.Category or nil

    if IsPlainTable(WeakAuras) and type(WeakAuras.ScanEvents) == "function" then
        pcall(WeakAuras.ScanEvents, AngryEra.NOTE_UPDATE_EVENT, syncId, name, category)
    end
    if type(self.SendMessage) == "function" then
        pcall(self.SendMessage, self, AngryEra.NOTE_UPDATE_EVENT, syncId, name, category)
    end
end

--- Records the latest displayed-note render and announces meaningful changes.
-- Called by the display pipeline after every rebuild; `context` is nil when the
-- display cleared. The stored snapshot always tracks the latest render, while
-- ANGRYERA_NOTE_UPDATE fires only when identity, content, or category changed.
-- @tparam table|nil context `{ Page = wireOrLocalPage, RenderedText = string, MergedVariables = table }`.
-- @treturn boolean announced
function AngryEra:NotifyDisplayedNoteChanged(context)
    local snapshot
    if IsPlainTable(context) and IsPlainTable(context.Page) then
        snapshot = BuildSnapshot(self, context)
    end

    local previous = self._displayedNoteSnapshot
    self._displayedNoteSnapshot = snapshot
    if not SnapshotChanged(previous, snapshot) then
        return false
    end

    EmitNoteEvent(self, snapshot)
    return true
end

--- Returns a detached snapshot of the displayed note, or nil when cleared.
-- Fields: LocalId, SyncId, RevisionId, ContextRevisionId, Name, Category,
-- CategorySyncId, Ancestors (root-to-parent `{ SyncId, Name? }`), Raw,
-- Rendered, UpdatedAt, UpdatedBy, Vars, and Meta.
-- @treturn table|nil note
function AngryEra:GetDisplayedNote()
    local snapshot = self._displayedNoteSnapshot
    if not IsPlainTable(snapshot) then
        return nil
    end
    return CloneValue(snapshot)
end

--- Returns detached resolved template variables for the displayed note.
-- Metadata (`$`) entries are excluded; see `GetDisplayedMeta`.
-- @treturn table|nil vars
function AngryEra:GetDisplayedVars()
    local snapshot = self._displayedNoteSnapshot
    if not IsPlainTable(snapshot) then
        return nil
    end
    return CloneValue(snapshot.Vars)
end

--- Returns detached `$` metadata for the displayed note, prefix stripped.
-- @treturn table|nil meta
function AngryEra:GetDisplayedMeta()
    local snapshot = self._displayedNoteSnapshot
    if not IsPlainTable(snapshot) then
        return nil
    end
    return CloneValue(snapshot.Meta)
end
