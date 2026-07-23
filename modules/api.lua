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

local MAX_PUBLIC_CLONE_TABLES = 8192
local MAX_PUBLIC_CLONE_ENTRIES = 65536
local MAX_EQUAL_TABLES = 8192
local publicNulls = setmetatable({}, { __mode = "k" })

local function IsPlainTable(value)
    return type(value) == "table"
end

local function NewPublicNull()
    local marker = {}
    publicNulls[marker] = true
    return marker
end

local function CloneValue(value)
    local json = AngryEra.utils.json
    if not IsPlainTable(value) then
        return value
    end

    if json and value == json.JSON_NULL then
        return NewPublicNull()
    end

    local copies = {}
    local pending = {}
    local tableCount = 0
    local entryCount = 0

    local function QueueTable(source)
        if json and source == json.JSON_NULL then
            return NewPublicNull()
        end

        local existing = copies[source]
        if existing then
            return existing
        end

        tableCount = tableCount + 1
        if tableCount > MAX_PUBLIC_CLONE_TABLES then
            return nil, "snapshot-too-complex"
        end

        local copy = {}
        copies[source] = copy
        pending[#pending + 1] = {
            Source = source,
            Copy = copy,
        }
        return copy
    end

    local root, rootError = QueueTable(value)
    if not root then
        return nil, rootError
    end

    while #pending > 0 do
        local work = pending[#pending]
        pending[#pending] = nil

        for key, entry in pairs(work.Source) do
            entryCount = entryCount + 1
            if entryCount > MAX_PUBLIC_CLONE_ENTRIES then
                return nil, "snapshot-too-complex"
            end

            local copiedKey = key
            if IsPlainTable(key) then
                local keyError
                copiedKey, keyError = QueueTable(key)
                if not copiedKey then
                    return nil, keyError
                end
            end

            local copiedEntry = entry
            if IsPlainTable(entry) then
                local entryError
                copiedEntry, entryError = QueueTable(entry)
                if not copiedEntry then
                    return nil, entryError
                end
            end
            work.Copy[copiedKey] = copiedEntry
        end
    end

    return root
end

local function ValuesEqual(left, right)
    if left == right then
        return true
    end
    if type(left) ~= type(right) or not IsPlainTable(left) then
        return false
    end

    local leftToRight = {}
    local rightToLeft = {}
    local json = AngryEra.utils.json
    local pending = {
        {
            Left = left,
            Right = right,
        },
    }
    local tableCount = 0

    while #pending > 0 do
        local work = pending[#pending]
        pending[#pending] = nil
        local leftValue = work.Left
        local rightValue = work.Right

        if leftValue ~= rightValue then
            if json and (rawequal(leftValue, json.JSON_NULL) or rawequal(rightValue, json.JSON_NULL)) then
                return false
            end
            if type(leftValue) ~= type(rightValue) or not IsPlainTable(leftValue) then
                return false
            end

            local mappedRight = leftToRight[leftValue]
            local mappedLeft = rightToLeft[rightValue]
            if mappedRight or mappedLeft then
                if mappedRight ~= rightValue or mappedLeft ~= leftValue then
                    return false
                end
            else
                tableCount = tableCount + 1
                if tableCount > MAX_EQUAL_TABLES then
                    return false
                end

                leftToRight[leftValue] = rightValue
                rightToLeft[rightValue] = leftValue

                for key, entry in pairs(leftValue) do
                    if IsPlainTable(key) then
                        return false
                    end
                    local otherEntry = rawget(rightValue, key)
                    if otherEntry == nil then
                        return false
                    end
                    pending[#pending + 1] = {
                        Left = entry,
                        Right = otherEntry,
                    }
                end
                for key in pairs(rightValue) do
                    if IsPlainTable(key) or rawget(leftValue, key) == nil then
                        return false
                    end
                end
            end
        end
    end

    return true
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
    return not ValuesEqual(previous, snapshot)
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
-- ANGRYERA_NOTE_UPDATE fires when any published snapshot field changes.
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

--- Reports whether a displayed-note API value represents JSON null.
-- Each getter call creates fresh null marker tables so callers may mutate their
-- detached result without changing the codec singleton or future results.
-- @tparam any value Value returned by a displayed-note getter.
-- @treturn boolean isNull
function AngryEra:IsDisplayedNull(value)
    return IsPlainTable(value) and publicNulls[value] == true
end

--- Returns a detached snapshot of the displayed note, or nil when cleared.
-- Fields: LocalId, SyncId, RevisionId, ContextRevisionId, Name, Category,
-- CategorySyncId, Ancestors (root-to-parent `{ SyncId, Name? }`), Raw,
-- Rendered, UpdatedAt, UpdatedBy, Vars, and Meta.
-- JSON null values are fresh marker tables recognized by `IsDisplayedNull`.
-- @treturn table|nil note
-- @treturn string|nil errorCode
function AngryEra:GetDisplayedNote()
    local snapshot = self._displayedNoteSnapshot
    if not IsPlainTable(snapshot) then
        return nil
    end
    return CloneValue(snapshot)
end

--- Returns detached resolved template variables for the displayed note.
-- Metadata (`$`) entries are excluded; see `GetDisplayedMeta`.
-- JSON null values are fresh marker tables recognized by `IsDisplayedNull`.
-- @treturn table|nil vars
-- @treturn string|nil errorCode
function AngryEra:GetDisplayedVars()
    local snapshot = self._displayedNoteSnapshot
    if not IsPlainTable(snapshot) then
        return nil
    end
    return CloneValue(snapshot.Vars)
end

--- Returns detached `$` metadata for the displayed note, prefix stripped.
-- JSON null values are fresh marker tables recognized by `IsDisplayedNull`.
-- @treturn table|nil meta
-- @treturn string|nil errorCode
function AngryEra:GetDisplayedMeta()
    local snapshot = self._displayedNoteSnapshot
    if not IsPlainTable(snapshot) then
        return nil
    end
    return CloneValue(snapshot.Meta)
end
