-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/revisions.lua
--
-- Deterministic adapters between local page/category records and protocol-v3
-- wire records. This module does not apply records to SavedVariables or publish
-- network messages.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity
local schema = AngryEra.sync and AngryEra.sync.schema

if not identity or type(identity.ValidateSyncId) ~= "function" then
    error("AngryEra identity must load before synchronization revisions")
end
if not schema or type(schema.BuildEntityRevisionId) ~= "function" then
    error("AngryEra synchronization schema must load before synchronization revisions")
end

AngryEra.sync.revisions = {}
local revisions = AngryEra.sync.revisions

local UINT32_MODULUS = 4294967296
local MAX_LOCAL_ID = 9007199254740991
local MAX_LOCAL_COPY_DEPTH = 16
local MAX_LOCAL_COPY_ITEMS = 1024
local CONTEXT_MARKER = {}
local HEX_DIGITS = "0123456789abcdef"

local REVISION_FIELDS = {
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
}

local PRESERVABLE_LOCAL_FIELDS = {
    Id = true,
    CategoryId = true,
    Index = true,
    Backup = true,
    History = true,
    UpdateId = true,
    Updated = true,
}

local function IsPlainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function IsPositiveInteger(value)
    return IsFiniteNumber(value) and value >= 1 and value <= MAX_LOCAL_ID and value == math.floor(value)
end

local function IsProtocolInteger(value, minimum, maximum)
    return IsFiniteNumber(value) and value >= minimum and value <= maximum and value == math.floor(value)
end

local function EncodeUint32(value)
    local encoded = {}
    value = value % UINT32_MODULUS
    for index = 8, 1, -1 do
        local digit = value % 16
        encoded[index] = HEX_DIGITS:sub(digit + 1, digit + 1)
        value = math.floor(value / 16)
    end
    return table.concat(encoded)
end

--- Creates the production FCS32 callback expected by the synchronization schema.
-- LibCompress returns a signed 32-bit number on some clients, so the result is
-- normalized to exactly eight lowercase hexadecimal digits.
-- @tparam table libC LibCompress instance.
-- @treturn function|nil hashCallback
-- @treturn string|nil errorCode
function revisions.CreateFCS32Callback(libC)
    if
        type(libC) ~= "table"
        or type(libC.fcs32init) ~= "function"
        or type(libC.fcs32update) ~= "function"
        or type(libC.fcs32final) ~= "function"
    then
        return nil, "invalid-fcs32-library"
    end

    return function(value)
        if type(value) ~= "string" then
            error("FCS32 input must be a string")
        end

        local code = libC:fcs32init()
        code = libC:fcs32update(code, value)
        code = libC:fcs32final(code)
        if not IsFiniteNumber(code) or code ~= math.floor(code) or code < -2147483648 or code > UINT32_MODULUS - 1 then
            error("FCS32 result must be an integer")
        end
        return EncodeUint32(code)
    end
end

local function ResolveHashCallback(hashCallback)
    if hashCallback ~= nil then
        if type(hashCallback) ~= "function" then
            return nil, "invalid-hash-callback"
        end
        return hashCallback
    end

    return revisions.CreateFCS32Callback(app.libs and app.libs.libC)
end

local function CompareScopeEntries(a, b)
    local aIndex = rawget(a.Record, "Index")
    local bIndex = rawget(b.Record, "Index")
    if aIndex ~= nil or bIndex ~= nil then
        if aIndex == nil then
            return false
        end
        if bIndex == nil then
            return true
        end
        if aIndex ~= bIndex then
            return aIndex < bIndex
        end
    end

    local aName = rawget(a.Record, "Name")
    local bName = rawget(b.Record, "Name")
    if aName ~= bName then
        return aName < bName
    end
    if a.Kind ~= b.Kind then
        return a.Kind == "category"
    end

    local aSyncId = rawget(a.Record, "SyncId")
    local bSyncId = rawget(b.Record, "SyncId")
    if aSyncId ~= bSyncId then
        return aSyncId < bSyncId
    end
    return a.Id < b.Id
end

local function ValidateIncludedRecord(entry)
    local record = entry.Record
    if not IsPlainTable(record) then
        return false, "invalid-local-record"
    end
    if not IsPositiveInteger(entry.Id) or rawget(record, "Id") ~= entry.Id then
        return false, "invalid-local-id"
    end
    if not identity.ValidateSyncId(rawget(record, "SyncId"), entry.Kind) then
        return false, "invalid-local-sync-id"
    end
    if type(rawget(record, "Name")) ~= "string" then
        return false, "invalid-local-name"
    end

    local index = rawget(record, "Index")
    if index ~= nil and not IsFiniteNumber(index) then
        return false, "invalid-local-index"
    end
    return true
end

local function AppendChildren(records, kind, childrenByParent)
    for id, record in pairs(records) do
        if type(record) == "table" then
            local parentId = rawget(record, "CategoryId")
            if IsPositiveInteger(parentId) then
                local children = childrenByParent[parentId]
                if not children then
                    children = {}
                    childrenByParent[parentId] = children
                end
                children[#children + 1] = {
                    Kind = kind,
                    Id = id,
                    Record = record,
                }
            end
        end
    end
end

local function SnapshotContextFields(record, order, parentSyncId, isRoot)
    return {
        CategoryId = not isRoot and rawget(record, "CategoryId") or nil,
        Index = not isRoot and rawget(record, "Index") or nil,
        Name = not isRoot and rawget(record, "Name") or nil,
        Id = rawget(record, "Id"),
        SyncId = rawget(record, "SyncId"),
        Order = order,
        ParentSyncId = parentSyncId,
        IsRoot = isRoot == true,
    }
end

--- Builds a validated one-shot conversion context for one selected category.
-- Local fractional/nil indices are normalized to dense integer sibling orders.
-- The selected root's local parent and index are intentionally ignored.
-- @tparam table categories Local category table keyed by numeric id.
-- @tparam table pages Local page table keyed by numeric id.
-- @tparam number rootCategoryId Selected local category id.
-- @treturn table|nil context
-- @treturn string|nil errorCode
function revisions.BuildSiblingOrders(categories, pages, rootCategoryId)
    if not IsPlainTable(categories) or not IsPlainTable(pages) then
        return nil, "invalid-local-collections"
    end
    if not IsPositiveInteger(rootCategoryId) then
        return nil, "invalid-root-category-id"
    end

    local root = rawget(categories, rootCategoryId)
    local rootEntry = {
        Kind = "category",
        Id = rootCategoryId,
        Record = root,
    }
    local validRoot, rootError = ValidateIncludedRecord(rootEntry)
    if not validRoot then
        return nil, root and rootError or "missing-root-category"
    end

    local childrenByParent = {}
    AppendChildren(categories, "category", childrenByParent)
    AppendChildren(pages, "page", childrenByParent)

    local context = {
        Categories = categories,
        Pages = pages,
        RootCategoryId = rootCategoryId,
        RootSyncId = root.SyncId,
        CategoryOrders = {
            [rootCategoryId] = 1,
        },
        PageOrders = {},
        CategoryParents = {},
        PageParents = {},
        IncludedCategories = {
            [rootCategoryId] = root,
        },
        IncludedPages = {},
        CategorySnapshots = {
            [rootCategoryId] = SnapshotContextFields(root, 1, nil, true),
        },
        PageSnapshots = {},
        _Marker = CONTEXT_MARKER,
    }

    local syncIds = {
        [root.SyncId] = true,
    }
    local totalRecords = 1

    local function VisitCategory(categoryId, depth)
        local children = childrenByParent[categoryId] or {}
        for _, entry in ipairs(children) do
            local valid, validationError = ValidateIncludedRecord(entry)
            if not valid then
                return false, validationError
            end
            if syncIds[entry.Record.SyncId] then
                return false, "duplicate-local-sync-id"
            end
            syncIds[entry.Record.SyncId] = true
        end

        table.sort(children, CompareScopeEntries)
        if #children > schema.LIMITS.Order then
            return false, "too-many-siblings"
        end

        for order, entry in ipairs(children) do
            totalRecords = totalRecords + 1
            if totalRecords > schema.LIMITS.EntityCount then
                return false, "too-many-scope-entities"
            end

            if entry.Kind == "category" then
                if depth + 1 > schema.LIMITS.HierarchyDepth then
                    return false, "hierarchy-too-deep"
                end
                context.IncludedCategories[entry.Id] = entry.Record
                context.CategoryOrders[entry.Id] = order
                context.CategoryParents[entry.Id] = context.IncludedCategories[categoryId].SyncId
                context.CategorySnapshots[entry.Id] =
                    SnapshotContextFields(entry.Record, order, context.CategoryParents[entry.Id], false)
            else
                if depth + 1 > schema.LIMITS.HierarchyDepth then
                    return false, "hierarchy-too-deep"
                end
                context.IncludedPages[entry.Id] = entry.Record
                context.PageOrders[entry.Id] = order
                context.PageParents[entry.Id] = context.IncludedCategories[categoryId].SyncId
                context.PageSnapshots[entry.Id] =
                    SnapshotContextFields(entry.Record, order, context.PageParents[entry.Id], false)
            end
        end

        for _, entry in ipairs(children) do
            if entry.Kind == "category" then
                local ok, traversalError = VisitCategory(entry.Id, depth + 1)
                if not ok then
                    return false, traversalError
                end
            end
        end
        return true
    end

    local traversed, traversalError = VisitCategory(rootCategoryId, 1)
    if not traversed then
        return nil, traversalError
    end

    local rootParentId = rawget(root, "CategoryId")
    if rootParentId ~= nil and context.IncludedCategories[rootParentId] then
        return nil, "hierarchy-cycle"
    end
    return context
end

local function ContextRecordMatches(record, id, snapshot, order, parentSyncId)
    if
        not IsPlainTable(record)
        or not IsPlainTable(snapshot)
        or snapshot.Id ~= id
        or snapshot.Id ~= rawget(record, "Id")
        or snapshot.SyncId ~= rawget(record, "SyncId")
        or snapshot.Order ~= order
        or snapshot.ParentSyncId ~= parentSyncId
    then
        return false
    end
    if snapshot.IsRoot then
        return true
    end
    return snapshot.CategoryId == rawget(record, "CategoryId")
        and snapshot.Index == rawget(record, "Index")
        and snapshot.Name == rawget(record, "Name")
end

local function ValidateContextCollection(records, included, snapshots, orders, parents)
    for id, record in pairs(included) do
        if
            rawget(records, id) ~= record
            or not ContextRecordMatches(record, id, rawget(snapshots, id), rawget(orders, id), rawget(parents, id))
        then
            return false
        end
    end
    return true
end

local function HasNewScopeChildren(records, included, includedCategories)
    for id, record in pairs(records) do
        if type(record) == "table" and includedCategories[rawget(record, "CategoryId")] then
            if rawget(included, id) ~= record then
                return true
            end
        end
    end
    return false
end

local function ValidateContextFresh(context)
    if
        not IsPlainTable(context.Categories)
        or not IsPlainTable(context.Pages)
        or not IsPlainTable(context.IncludedCategories)
        or not IsPlainTable(context.IncludedPages)
        or not IsPlainTable(context.CategorySnapshots)
        or not IsPlainTable(context.PageSnapshots)
        or not IsPlainTable(context.CategoryOrders)
        or not IsPlainTable(context.PageOrders)
        or not IsPlainTable(context.CategoryParents)
        or not IsPlainTable(context.PageParents)
    then
        return false, "stale-order-context"
    end

    local root = rawget(context.IncludedCategories, context.RootCategoryId)
    if
        not root
        or context.RootSyncId ~= rawget(root, "SyncId")
        or not ContextRecordMatches(
            root,
            context.RootCategoryId,
            rawget(context.CategorySnapshots, context.RootCategoryId),
            rawget(context.CategoryOrders, context.RootCategoryId),
            rawget(context.CategoryParents, context.RootCategoryId)
        )
        or not ValidateContextCollection(
            context.Categories,
            context.IncludedCategories,
            context.CategorySnapshots,
            context.CategoryOrders,
            context.CategoryParents
        )
        or not ValidateContextCollection(
            context.Pages,
            context.IncludedPages,
            context.PageSnapshots,
            context.PageOrders,
            context.PageParents
        )
        or HasNewScopeChildren(context.Categories, context.IncludedCategories, context.IncludedCategories)
        or HasNewScopeChildren(context.Pages, context.IncludedPages, context.IncludedCategories)
    then
        return false, "stale-order-context"
    end
    return true
end

local function GetContextRecord(kind, record, context)
    if kind ~= "page" and kind ~= "category" then
        return nil, "invalid-local-kind"
    end
    if not IsPlainTable(record) then
        return nil, "invalid-local-record"
    end
    if type(context) ~= "table" or rawget(context, "_Marker") ~= CONTEXT_MARKER then
        return nil, "invalid-order-context"
    end
    local fresh, freshError = ValidateContextFresh(context)
    if not fresh then
        return nil, freshError
    end

    local id = rawget(record, "Id")
    if not IsPositiveInteger(id) then
        return nil, "invalid-local-id"
    end

    local included = kind == "page" and context.IncludedPages or context.IncludedCategories
    if rawget(included, id) ~= record then
        return nil, "record-outside-scope"
    end

    return id
end

local function BuildWireCandidate(kind, record, context, metadata)
    local id, contextError = GetContextRecord(kind, record, context)
    if not id then
        return nil, contextError
    end

    local isRoot = kind == "category" and id == context.RootCategoryId
    local orders = kind == "page" and context.PageOrders or context.CategoryOrders
    local parents = kind == "page" and context.PageParents or context.CategoryParents
    local wire = {
        Kind = kind,
        SyncId = rawget(record, "SyncId"),
        OwnerId = rawget(record, "OwnerId"),
        Revision = metadata and metadata.Revision or rawget(record, "Revision"),
        RevisionId = metadata and metadata.RevisionId or rawget(record, "RevisionId"),
        UpdatedAt = metadata and metadata.UpdatedAt or rawget(record, "UpdatedAt"),
        UpdatedBy = metadata and metadata.UpdatedBy or rawget(record, "UpdatedBy"),
        ParentSyncId = rawget(parents, id),
        Order = rawget(orders, id),
        Name = rawget(record, "Name"),
        Vars = rawget(record, "Vars"),
    }
    if isRoot then
        wire.ParentSyncId = nil
        wire.Order = 1
    end
    if wire.Vars == nil then
        wire.Vars = ""
    end
    if kind == "page" then
        wire.Contents = rawget(record, "Contents")
        if wire.Contents == nil then
            wire.Contents = ""
        end
    end
    return wire
end

local function BuildAndHashCandidate(kind, record, context, metadata, hashCallback)
    local wire, wireError = BuildWireCandidate(kind, record, context, metadata)
    if not wire then
        return nil, wireError
    end

    local callback, callbackError = ResolveHashCallback(hashCallback)
    if not callback then
        return nil, callbackError
    end
    local revisionId, revisionError = schema.BuildEntityRevisionId(wire, callback)
    if not revisionId then
        return nil, revisionError
    end
    wire.RevisionId = revisionId
    return wire
end

--- Converts one complete local record to a strict protocol-v3 wire record.
-- The returned table contains no local numeric ids, legacy fields, or provenance.
-- @tparam string kind `"page"` or `"category"`.
-- @tparam table record Local entity record.
-- @tparam table context Result of `BuildSiblingOrders`.
-- @tparam[opt] function hashCallback FCS32-compatible callback.
-- @treturn table|nil wireRecord
-- @treturn string|nil errorCode
function revisions.LocalToWire(kind, record, context, hashCallback)
    local wire, wireError = BuildWireCandidate(kind, record, context)
    if not wire then
        return nil, wireError
    end

    local callback, callbackError = ResolveHashCallback(hashCallback)
    if not callback then
        return nil, callbackError
    end
    local expectedRevisionId, revisionError = schema.BuildEntityRevisionId(wire, callback)
    if not expectedRevisionId then
        return nil, revisionError
    end
    if wire.RevisionId ~= expectedRevisionId then
        return nil, "revision-id-mismatch"
    end
    return wire
end

local function ValidateAudit(audit)
    if not IsPlainTable(audit) then
        return nil, "invalid-revision-audit"
    end
    for key in pairs(audit) do
        if key ~= "UpdatedAt" and key ~= "UpdatedBy" then
            return nil, "revision-audit-unknown-field"
        end
    end
    if rawget(audit, "UpdatedAt") == nil then
        return nil, "revision-audit-missing-UpdatedAt"
    end
    if rawget(audit, "UpdatedBy") == nil then
        return nil, "revision-audit-missing-UpdatedBy"
    end
    return {
        UpdatedAt = audit.UpdatedAt,
        UpdatedBy = audit.UpdatedBy,
    }
end

local function HasCompleteRevisionMetadata(record)
    local present = 0
    for _, field in ipairs(REVISION_FIELDS) do
        if rawget(record, field) ~= nil then
            present = present + 1
        end
    end
    if present == 0 then
        return false, false
    end
    return present == #REVISION_FIELDS, true
end

local function CommitRevisionMetadata(record, wire)
    record.Revision = wire.Revision
    record.RevisionId = wire.RevisionId
    record.UpdatedAt = wire.UpdatedAt
    record.UpdatedBy = wire.UpdatedBy
end

--- Initializes missing revision metadata at numeric revision one.
-- Existing complete metadata is validated and left untouched. Partially present
-- metadata is rejected rather than silently repaired.
-- @tparam string kind `"page"` or `"category"`.
-- @tparam table record Local entity record.
-- @tparam table context Result of `BuildSiblingOrders`.
-- @tparam table audit Exact `UpdatedAt` and `UpdatedBy` values.
-- @tparam[opt] function hashCallback FCS32-compatible callback.
-- @treturn table|nil wireRecord
-- @treturn string|nil errorCode
function revisions.InitializeLocalRevision(kind, record, context, audit, hashCallback)
    if not IsPlainTable(record) then
        return nil, "invalid-local-record"
    end

    local safeAudit, auditError = ValidateAudit(audit)
    if not safeAudit then
        return nil, auditError
    end
    local complete, any = HasCompleteRevisionMetadata(record)
    if any and not complete then
        return nil, "partial-revision-metadata"
    end
    if complete then
        return revisions.LocalToWire(kind, record, context, hashCallback)
    end

    local wire, wireError = BuildAndHashCandidate(kind, record, context, {
        Revision = 1,
        UpdatedAt = safeAudit.UpdatedAt,
        UpdatedBy = safeAudit.UpdatedBy,
    }, hashCallback)
    if not wire then
        return nil, wireError
    end

    CommitRevisionMetadata(record, wire)
    return wire
end

--- Advances numeric revision metadata after local synchronized content changes.
-- The current content need not match the old RevisionId; this helper computes a
-- new content identity and commits all four metadata fields only after success.
-- @tparam string kind `"page"` or `"category"`.
-- @tparam table record Local entity record.
-- @tparam table context Result of `BuildSiblingOrders`.
-- @tparam table audit Exact `UpdatedAt` and `UpdatedBy` values.
-- @tparam[opt] function hashCallback FCS32-compatible callback.
-- @treturn table|nil wireRecord
-- @treturn string|nil errorCode
function revisions.TouchLocalRevision(kind, record, context, audit, hashCallback)
    if not IsPlainTable(record) then
        return nil, "invalid-local-record"
    end

    local complete, any = HasCompleteRevisionMetadata(record)
    if not any or not complete then
        return nil, any and "partial-revision-metadata" or "missing-revision-metadata"
    end

    local currentWire, currentError = BuildWireCandidate(kind, record, context)
    if not currentWire then
        return nil, currentError
    end
    local _, currentShapeError = schema.CanonicalEntityInput(currentWire)
    if currentShapeError then
        return nil, currentShapeError
    end
    if not IsProtocolInteger(record.Revision, 1, schema.LIMITS.Revision - 1) then
        return nil, record.Revision == schema.LIMITS.Revision and "revision-exhausted" or "invalid-revision"
    end

    local safeAudit, auditError = ValidateAudit(audit)
    if not safeAudit then
        return nil, auditError
    end
    local wire, wireError = BuildAndHashCandidate(kind, record, context, {
        Revision = record.Revision + 1,
        UpdatedAt = safeAudit.UpdatedAt,
        UpdatedBy = safeAudit.UpdatedBy,
    }, hashCallback)
    if not wire then
        return nil, wireError
    end

    CommitRevisionMetadata(record, wire)
    return wire
end

local function CopyLocalValue(value, state, depth)
    local valueType = type(value)
    if valueType ~= "table" then
        if valueType == "number" and not IsFiniteNumber(value) then
            return nil, "invalid-local-field-value"
        end
        if valueType == "string" or valueType == "number" or valueType == "boolean" then
            return value
        end
        return nil, "invalid-local-field-value"
    end
    if getmetatable(value) ~= nil then
        return nil, "invalid-local-field-value"
    end
    if depth >= MAX_LOCAL_COPY_DEPTH then
        return nil, "local-field-too-deep"
    end
    if state.Visiting[value] then
        return nil, "cyclic-local-field"
    end

    state.Visiting[value] = true
    local copy = {}
    for key, item in pairs(value) do
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" and keyType ~= "boolean" then
            state.Visiting[value] = nil
            return nil, "invalid-local-field-key"
        end
        state.Items = state.Items + 1
        if state.Items > MAX_LOCAL_COPY_ITEMS then
            state.Visiting[value] = nil
            return nil, "local-fields-too-large"
        end

        local copiedItem, copyError = CopyLocalValue(item, state, depth + 1)
        if copyError then
            state.Visiting[value] = nil
            return nil, copyError
        end
        copy[key] = copiedItem
    end
    state.Visiting[value] = nil
    return copy
end

local function ValidateLocalField(key, value)
    if key == "Id" or key == "CategoryId" then
        return IsPositiveInteger(value)
    end
    if key == "Index" then
        return IsFiniteNumber(value)
    end
    if key == "Backup" then
        return type(value) == "string"
    end
    if key == "History" then
        return type(value) == "table"
    end
    if key == "UpdateId" then
        return type(value) == "string" or IsFiniteNumber(value)
    end
    if key == "Updated" then
        return IsFiniteNumber(value) and value >= 0
    end
    return false
end

--- Maps a validated wire record into local synchronized fields.
-- Numeric placement and other local-only fields are absent unless the caller
-- supplies them explicitly. This lets a scope root retain its private local
-- `CategoryId`/`Index` overlay despite wire `ParentSyncId=nil` and `Order=1`.
-- @tparam table wire Strict page or category wire record.
-- @tparam[opt] table localFields Explicit local-only fields to preserve.
-- @tparam[opt] function hashCallback FCS32-compatible callback.
-- @treturn table|nil localRecord
-- @treturn string|nil errorCode
function revisions.WireToLocal(wire, localFields, hashCallback)
    if not IsPlainTable(wire) then
        return nil, "invalid-entity"
    end
    local safeWire = {}
    for key, value in pairs(wire) do
        safeWire[key] = value
    end

    local callback, callbackError = ResolveHashCallback(hashCallback)
    if not callback then
        return nil, callbackError
    end

    local valid, validationError = schema.ValidateEntity(safeWire, callback)
    if not valid then
        return nil, validationError
    end
    if localFields ~= nil and not IsPlainTable(localFields) then
        return nil, "invalid-local-fields"
    end

    local localRecord = {
        SyncId = safeWire.SyncId,
        OwnerId = safeWire.OwnerId,
        Revision = safeWire.Revision,
        RevisionId = safeWire.RevisionId,
        UpdatedAt = safeWire.UpdatedAt,
        UpdatedBy = safeWire.UpdatedBy,
        Name = safeWire.Name,
        Vars = safeWire.Vars,
    }
    if safeWire.Kind == "page" then
        localRecord.Contents = safeWire.Contents
    end

    local copyState = {
        Items = 0,
        Visiting = {},
    }
    for key, value in pairs(localFields or {}) do
        if type(key) ~= "string" or not PRESERVABLE_LOCAL_FIELDS[key] then
            return nil, "unsupported-local-field"
        end
        if not ValidateLocalField(key, value) then
            return nil, "invalid-local-field"
        end

        local copiedValue, copyError = CopyLocalValue(value, copyState, 0)
        if copyError then
            return nil, copyError
        end
        localRecord[key] = copiedValue
    end
    return localRecord
end
