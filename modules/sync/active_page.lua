-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/active_page.lua
--
-- Construction, local preparation, and canonical validation for protocol-v3
-- active-page data. This module has no SavedVariables, networking,
-- authorization, or UI effects. Local preparation updates only the supplied
-- page's revision metadata, after the complete payload has validated.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity
local protocol = AngryEra.utils and AngryEra.utils.protocol
local variables = AngryEra.utils and AngryEra.utils.variables
local schema = AngryEra.sync and AngryEra.sync.schema

if not identity or type(identity.ParseSyncId) ~= "function" then
    error("AngryEra identity must load before active-page synchronization")
end
if not protocol or type(protocol.ValidatePayload) ~= "function" then
    error("AngryEra protocol must load before active-page synchronization")
end
if
    not variables
    or type(variables.ValidateAncestorVariableLayers) ~= "function"
    or type(variables.BuildContextRevisionInput) ~= "function"
then
    error("AngryEra variable helpers must load before active-page synchronization")
end
if not schema or type(schema.ValidateEntity) ~= "function" then
    error("AngryEra synchronization schema must load before active-page synchronization")
end
if
    protocol.LIMITS.ActivePageAncestorCount ~= variables.MAX_ANCESTOR_DEPTH
    or protocol.LIMITS.ActivePageAncestorCount ~= schema.LIMITS.HierarchyDepth
    or protocol.LIMITS.ActivePageNameBytes ~= schema.LIMITS.NameBytes
    or protocol.LIMITS.ActivePageContentsBytes ~= schema.LIMITS.ContentsBytes
    or protocol.LIMITS.ActivePageVarsBytes ~= variables.MAX_VARIABLE_BYTES
    or protocol.LIMITS.ActivePageVarsBytes ~= schema.LIMITS.VarsBytes
    or protocol.LIMITS.ActivePageAuthorBytes ~= schema.LIMITS.AuthorBytes
    or protocol.LIMITS.ActivePageSyncIdBytes ~= schema.LIMITS.SyncIdBytes
    or protocol.LIMITS.ActivePageRevisionIdBytes ~= schema.LIMITS.RevisionIdBytes
    or protocol.LIMITS.ActivePageRevision ~= schema.LIMITS.Revision
    or protocol.LIMITS.ActivePageOrder ~= schema.LIMITS.Order
    or protocol.LIMITS.ActivePageTimestamp ~= schema.LIMITS.Timestamp
then
    error("AngryEra protocol and synchronization active-page limits must match")
end

AngryEra.sync.activePage = {}
local activePage = AngryEra.sync.activePage
local EMPTY_CONTEXT_REVISION_ID = "fcs32:00000000"
local MAX_LOCAL_RECORDS = schema.LIMITS.EntityCount * 128
local ABSENT = {}

local PAGE_FIELDS = {
    "Kind",
    "SyncId",
    "OwnerId",
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
    "ParentSyncId",
    "Order",
    "Name",
    "Vars",
    "Contents",
}

local LOCAL_PAGE_SOURCE_FIELDS = {
    "Id",
    "CategoryId",
    "Index",
    "SyncId",
    "OwnerId",
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
    "Name",
    "Vars",
    "Contents",
}

local PREPARATION_OPTION_KEYS = {
    ManagedScopeId = true,
    UpdatedAt = true,
    UpdatedBy = true,
}

local REVISION_FIELDS = {
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
}

local function IsPlainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function IsInteger(value, minimum, maximum)
    return IsFiniteNumber(value) and value >= minimum and value <= maximum and value == math.floor(value)
end

local function IsCanonicalSyncId(value, expectedKind)
    if type(value) ~= "string" or #value > schema.LIMITS.SyncIdBytes then
        return false
    end

    local installationId, kind, sequence = identity.ParseSyncId(value)
    return installationId ~= nil
        and kind == expectedKind
        and IsInteger(sequence, 1, schema.LIMITS.Revision)
        and value == string.format("%s:%s:%d", installationId, kind, sequence)
end

local function ContainsControlByte(value)
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 32 or byte == 127 then
            return true
        end
    end
    return false
end

local function ValidatePreparationOptions(options)
    if not IsPlainTable(options) then
        return nil, "invalid-page-preparation-options"
    end
    for key in pairs(options) do
        if type(key) ~= "string" or not PREPARATION_OPTION_KEYS[key] then
            return nil, "page-preparation-options-unknown-field"
        end
    end
    if rawget(options, "UpdatedAt") == nil then
        return nil, "page-preparation-options-missing-UpdatedAt"
    end
    if rawget(options, "UpdatedBy") == nil then
        return nil, "page-preparation-options-missing-UpdatedBy"
    end
    if not IsInteger(options.UpdatedAt, 0, schema.LIMITS.Timestamp) then
        return nil, "invalid-updated-at"
    end
    if
        type(options.UpdatedBy) ~= "string"
        or options.UpdatedBy == ""
        or #options.UpdatedBy > schema.LIMITS.AuthorBytes
        or ContainsControlByte(options.UpdatedBy)
        or options.UpdatedBy:find("%s")
        or options.UpdatedBy:sub(1, 1) == "-"
        or options.UpdatedBy:sub(-1) == "-"
        or options.UpdatedBy:find("-", 1, true) == nil
    then
        return nil, "invalid-updated-by"
    end
    if options.ManagedScopeId ~= nil and not IsCanonicalSyncId(options.ManagedScopeId, "category") then
        return nil, "invalid-managed-scope-id"
    end
    return {
        ManagedScopeId = options.ManagedScopeId,
        UpdatedAt = options.UpdatedAt,
        UpdatedBy = options.UpdatedBy,
    }
end

local function SnapshotFields(record, fields)
    local snapshot = {}
    for _, field in ipairs(fields) do
        local value = rawget(record, field)
        snapshot[field] = value == nil and ABSENT or value
    end
    return snapshot
end

local function SnapshotsEqual(left, right, fields)
    for _, field in ipairs(fields) do
        if left[field] ~= right[field] then
            return false
        end
    end
    return true
end

local function ValidateSortableLocalRecord(kind, id, record)
    if not IsPlainTable(record) then
        return false, "invalid-local-record"
    end
    if not IsInteger(id, 1, schema.LIMITS.Timestamp) or rawget(record, "Id") ~= id then
        return false, "invalid-local-id"
    end
    if not IsCanonicalSyncId(rawget(record, "SyncId"), kind) then
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

local function CompareLocalEntries(left, right)
    local leftIndex = rawget(left.Record, "Index")
    local rightIndex = rawget(right.Record, "Index")
    if leftIndex ~= nil or rightIndex ~= nil then
        if leftIndex == nil then
            return false
        end
        if rightIndex == nil then
            return true
        end
        if leftIndex ~= rightIndex then
            return leftIndex < rightIndex
        end
    end

    local leftName = rawget(left.Record, "Name")
    local rightName = rawget(right.Record, "Name")
    if leftName ~= rightName then
        return leftName < rightName
    end
    if left.Kind ~= right.Kind then
        return left.Kind == "category"
    end

    local leftSyncId = rawget(left.Record, "SyncId")
    local rightSyncId = rawget(right.Record, "SyncId")
    if leftSyncId ~= rightSyncId then
        return leftSyncId < rightSyncId
    end
    return left.Id < right.Id
end

local function AppendLocalSiblings(records, kind, parentId, entries, syncIds)
    for id, record in pairs(records) do
        if type(record) == "table" and rawget(record, "CategoryId") == parentId then
            local valid, validationError = ValidateSortableLocalRecord(kind, id, record)
            if not valid then
                return false, validationError
            end
            if syncIds[record.SyncId] then
                return false, "duplicate-local-sync-id"
            end
            syncIds[record.SyncId] = true
            entries[#entries + 1] = {
                Kind = kind,
                Id = id,
                Record = record,
            }
        end
    end
    return true
end

local function ValidateGlobalSyncIds(categories, pages)
    local seen = {}
    local recordCount = 0
    for _, records in ipairs({ categories, pages }) do
        for _, record in pairs(records) do
            recordCount = recordCount + 1
            if recordCount > MAX_LOCAL_RECORDS then
                return false, "too-many-local-records"
            end

            local syncId = type(record) == "table" and rawget(record, "SyncId") or nil
            if identity.ValidateSyncId(syncId) then
                if seen[syncId] then
                    return false, "duplicate-local-sync-id"
                end
                seen[syncId] = true
            end
        end
    end
    return true
end

local function DefaultEmptyString(value)
    if value == nil then
        return ""
    end
    return value
end

local function FindManagedRootId(categories, managedScopeId)
    if managedScopeId == nil then
        return nil
    end

    local rootId
    for id, category in pairs(categories) do
        if type(category) == "table" and rawget(category, "SyncId") == managedScopeId then
            if rootId ~= nil then
                return nil, "duplicate-local-sync-id"
            end
            local valid, validationError = ValidateSortableLocalRecord("category", id, category)
            if not valid then
                return nil, validationError
            end
            rootId = id
        end
    end
    if rootId == nil then
        return nil, "managed-scope-not-ancestor"
    end
    return rootId
end

local function BuildAncestorLayers(categories, directParentId, managedScopeId)
    local managedRootId, managedRootError = FindManagedRootId(categories, managedScopeId)
    if managedRootError then
        return nil, nil, managedRootError
    end

    local chain, chainError = variables.CollectCategoryChain(categories, directParentId, {
        maxDepth = schema.LIMITS.HierarchyDepth,
        rootId = managedRootId,
    })
    if not chain then
        if managedScopeId ~= nil and chainError == "root-not-ancestor" then
            return nil, nil, "managed-scope-not-ancestor"
        end
        return nil, nil, chainError
    end

    local boundedChain = {}
    for index = 1, #chain do
        local category = chain[index]
        local categoryId = rawget(category, "Id")
        local valid, validationError = ValidateSortableLocalRecord("category", categoryId, category)
        if not valid or rawget(categories, categoryId) ~= category then
            return nil, nil, validationError or "stale-category-reference"
        end
        boundedChain[#boundedChain + 1] = category
    end

    local layers, layerError = variables.BuildAncestorVariableLayers(boundedChain)
    if not layers then
        return nil, nil, layerError
    end
    local boundarySyncId = #layers > 0 and layers[1].SyncId or nil
    return layers, boundarySyncId
end

local function BuildLocalPageContext(categories, pages, pageId, managedScopeId)
    if not IsPlainTable(categories) or not IsPlainTable(pages) then
        return nil, "invalid-local-collections"
    end
    if not IsInteger(pageId, 1, schema.LIMITS.Timestamp) then
        return nil, "invalid-local-page-id"
    end

    local identitiesValid, identityError = ValidateGlobalSyncIds(categories, pages)
    if not identitiesValid then
        return nil, identityError
    end

    local page = rawget(pages, pageId)
    local validPage, pageError = ValidateSortableLocalRecord("page", pageId, page)
    if not validPage then
        return nil, page and pageError or "missing-local-page"
    end

    local parentId = rawget(page, "CategoryId")
    if parentId ~= nil and not IsInteger(parentId, 1, schema.LIMITS.Timestamp) then
        return nil, "invalid-local-parent-id"
    end

    local layers, boundarySyncId, layerError = BuildAncestorLayers(categories, parentId, managedScopeId)
    if not layers then
        return nil, layerError
    end

    local entries = {}
    local syncIds = {}
    local categoriesValid, categoryError = AppendLocalSiblings(categories, "category", parentId, entries, syncIds)
    if not categoriesValid then
        return nil, categoryError
    end
    local pagesValid, siblingError = AppendLocalSiblings(pages, "page", parentId, entries, syncIds)
    if not pagesValid then
        return nil, siblingError
    end
    if #entries > schema.LIMITS.Order then
        return nil, "too-many-siblings"
    end

    table.sort(entries, CompareLocalEntries)
    local order
    for index, entry in ipairs(entries) do
        if entry.Kind == "page" and entry.Id == pageId and entry.Record == page then
            order = index
            break
        end
    end
    if order == nil then
        return nil, "stale-page-reference"
    end

    return {
        Page = page,
        PageSnapshot = SnapshotFields(page, LOCAL_PAGE_SOURCE_FIELDS),
        ParentSyncId = #layers > 0 and layers[#layers].SyncId or nil,
        Order = order,
        AncestorVariableLayers = layers,
        BoundarySyncId = boundarySyncId,
    }
end

local function ContextsEqual(left, right)
    if
        left.Page ~= right.Page
        or left.ParentSyncId ~= right.ParentSyncId
        or left.Order ~= right.Order
        or left.BoundarySyncId ~= right.BoundarySyncId
        or not SnapshotsEqual(left.PageSnapshot, right.PageSnapshot, LOCAL_PAGE_SOURCE_FIELDS)
        or #left.AncestorVariableLayers ~= #right.AncestorVariableLayers
    then
        return false
    end
    for index, layer in ipairs(left.AncestorVariableLayers) do
        local other = right.AncestorVariableLayers[index]
        if layer.SyncId ~= other.SyncId or layer.Vars ~= other.Vars then
            return false
        end
    end
    return true
end

local function BuildLocalWirePage(page, parentSyncId, order, metadata)
    return {
        Kind = "page",
        SyncId = rawget(page, "SyncId"),
        OwnerId = rawget(page, "OwnerId"),
        Revision = metadata and metadata.Revision or rawget(page, "Revision"),
        RevisionId = metadata and metadata.RevisionId or rawget(page, "RevisionId"),
        UpdatedAt = metadata and metadata.UpdatedAt or rawget(page, "UpdatedAt"),
        UpdatedBy = metadata and metadata.UpdatedBy or rawget(page, "UpdatedBy"),
        ParentSyncId = parentSyncId,
        Order = order,
        Name = rawget(page, "Name"),
        Vars = DefaultEmptyString(rawget(page, "Vars")),
        Contents = DefaultEmptyString(rawget(page, "Contents")),
    }
end

local function CountRevisionFields(page)
    local present = 0
    for _, field in ipairs(REVISION_FIELDS) do
        if rawget(page, field) ~= nil then
            present = present + 1
        end
    end
    return present
end

local function BuildHashedLocalWire(page, parentSyncId, order, metadata, hashCallback)
    local wire = BuildLocalWirePage(page, parentSyncId, order, metadata)
    local revisionId, revisionError = schema.BuildEntityRevisionId(wire, hashCallback)
    if not revisionId then
        return nil, revisionError
    end
    wire.RevisionId = revisionId
    return wire
end

local function StageLocalPageRevision(context, options, hashCallback)
    local page = context.Page
    local present = CountRevisionFields(page)
    if present ~= 0 and present ~= #REVISION_FIELDS then
        return nil, nil, "partial-revision-metadata"
    end

    if present == 0 then
        local initialized, initializationError = BuildHashedLocalWire(page, context.ParentSyncId, context.Order, {
            Revision = 1,
            UpdatedAt = options.UpdatedAt,
            UpdatedBy = options.UpdatedBy,
        }, hashCallback)
        return initialized, initialized and "initialized" or nil, initializationError
    end

    local current = BuildLocalWirePage(page, context.ParentSyncId, context.Order)
    local expectedRevisionId, revisionError = schema.BuildEntityRevisionId(current, hashCallback)
    if not expectedRevisionId then
        return nil, nil, revisionError
    end
    if current.RevisionId == expectedRevisionId then
        return current, "unchanged"
    end
    if not IsInteger(current.Revision, 1, schema.LIMITS.Revision - 1) then
        return nil, nil, current.Revision == schema.LIMITS.Revision and "revision-exhausted" or "invalid-revision"
    end

    local touched, touchError = BuildHashedLocalWire(page, context.ParentSyncId, context.Order, {
        Revision = current.Revision + 1,
        UpdatedAt = options.UpdatedAt,
        UpdatedBy = options.UpdatedBy,
    }, hashCallback)
    return touched, touched and "touched" or nil, touchError
end

local function HashContextInput(canonicalInput, hashCallback)
    if type(hashCallback) ~= "function" then
        return nil, "invalid-hash-callback"
    end

    local ok, digest = pcall(hashCallback, canonicalInput)
    if not ok or type(digest) ~= "string" or #digest ~= 8 or digest:match("^[0-9a-f]+$") == nil then
        return nil, "context-hash-failed"
    end
    return "fcs32:" .. digest
end

local function CopyPage(page)
    local copy = {}
    for _, field in ipairs(PAGE_FIELDS) do
        local value = rawget(page, field)
        if value ~= nil then
            copy[field] = value
        end
    end
    return copy
end

local function BuildValidatedContextRevisionId(safeLayers, pageVariables, hashCallback)
    local canonicalInput, canonicalError = variables.BuildContextRevisionInput(safeLayers, pageVariables)
    if not canonicalInput then
        return nil, canonicalError
    end
    return HashContextInput(canonicalInput, hashCallback)
end

--- Builds the canonical active-page render-context identity.
-- The supplied ancestor layers are validated and copied before hashing.
-- @tparam table ancestorLayers Root-to-direct-parent variable layers.
-- @tparam string pageVariables Raw page variable string.
-- @tparam string|nil parentSyncId Expected direct-parent synchronization ID.
-- @tparam function hashCallback FCS32-compatible callback.
-- @treturn string|nil contextRevisionId
-- @treturn string|nil errorCode
function activePage.BuildContextRevisionId(ancestorLayers, pageVariables, parentSyncId, hashCallback)
    local safeLayers, layerError = variables.ValidateAncestorVariableLayers(ancestorLayers, parentSyncId)
    if not safeLayers then
        return nil, layerError
    end
    return BuildValidatedContextRevisionId(safeLayers, pageVariables, hashCallback)
end

--- Fully validates a protocol-v3 PAGE_UPSERT payload.
-- Structural bounds are checked by the protocol layer; canonical page and
-- render-context hashes are checked here.
-- @tparam table payload PAGE_UPSERT payload.
-- @tparam function hashCallback FCS32-compatible callback.
-- @treturn boolean valid
-- @treturn string|nil errorCode
-- @treturn table|nil detachedPayload
function activePage.ValidatePageUpsertPayload(payload, hashCallback)
    local shallowValid, shallowError = protocol.ValidatePayload("PAGE_UPSERT", payload)
    if not shallowValid then
        return false, shallowError
    end

    local entityValid, entityError = schema.ValidateEntity(payload.Page, hashCallback)
    if not entityValid then
        return false, entityError
    end

    local safeLayers, layerError =
        variables.ValidateAncestorVariableLayers(payload.AncestorVariableLayers, payload.Page.ParentSyncId)
    if not safeLayers then
        return false, layerError
    end

    local expectedContextRevisionId, contextError =
        BuildValidatedContextRevisionId(safeLayers, payload.Page.Vars, hashCallback)
    if not expectedContextRevisionId then
        return false, contextError
    end
    if payload.ContextRevisionId ~= expectedContextRevisionId then
        return false, "context-revision-id-mismatch"
    end
    return true,
        nil,
        {
            Page = CopyPage(payload.Page),
            AncestorVariableLayers = safeLayers,
            ContextRevisionId = expectedContextRevisionId,
        }
end

--- Builds a detached, fully validated protocol-v3 PAGE_UPSERT payload.
-- The returned page and ancestor-layer tables never alias caller-owned tables.
-- @tparam table page Strict canonical page wire record.
-- @tparam table ancestorLayers Root-to-direct-parent variable layers.
-- @tparam function hashCallback FCS32-compatible callback.
-- @treturn table|nil payload
-- @treturn string|nil errorCode
function activePage.BuildPageUpsertPayload(page, ancestorLayers, hashCallback)
    local shallowValid, shallowError = protocol.ValidatePayload("PAGE_UPSERT", {
        Page = page,
        AncestorVariableLayers = ancestorLayers,
        ContextRevisionId = EMPTY_CONTEXT_REVISION_ID,
    })
    if not shallowValid then
        return nil, shallowError
    end

    local entityValid, entityError = schema.ValidateEntity(page, hashCallback)
    if not entityValid then
        return nil, entityError
    end

    local safeLayers, layerError = variables.ValidateAncestorVariableLayers(ancestorLayers, page.ParentSyncId)
    if not safeLayers then
        return nil, layerError
    end

    local contextRevisionId, contextError = BuildValidatedContextRevisionId(safeLayers, page.Vars, hashCallback)
    if not contextRevisionId then
        return nil, contextError
    end

    local payload = {
        Page = CopyPage(page),
        AncestorVariableLayers = safeLayers,
        ContextRevisionId = contextRevisionId,
    }
    return payload
end

--- Prepares one local page for a protocol-v3 PAGE_UPSERT.
-- The page's mixed page/category sibling position is normalized to a dense
-- wire order. Ancestor layers start at `ManagedScopeId` when supplied and
-- verified as an ancestor; otherwise they start at the topmost ancestor.
-- Revision metadata is initialized or touched only after the complete
-- detached payload validates and the local source context is rechecked.
-- @tparam table categories Local category table keyed by numeric id.
-- @tparam table pages Local page table keyed by numeric id.
-- @tparam number pageId Local page id.
-- @tparam table options Exact UpdatedAt/UpdatedBy and optional ManagedScopeId.
-- @tparam function hashCallback FCS32-compatible callback.
-- @treturn table|nil payload
-- @treturn string|nil errorCode
-- @treturn table|nil preparation Detached revision action and boundary summary.
function activePage.PrepareLocalPageUpsert(categories, pages, pageId, options, hashCallback)
    local safeOptions, optionsError = ValidatePreparationOptions(options)
    if not safeOptions then
        return nil, optionsError
    end
    if type(hashCallback) ~= "function" then
        return nil, "invalid-hash-callback"
    end

    local context, contextError = BuildLocalPageContext(categories, pages, pageId, safeOptions.ManagedScopeId)
    if not context then
        return nil, contextError
    end

    local wire, revisionAction, revisionError = StageLocalPageRevision(context, safeOptions, hashCallback)
    if not wire then
        return nil, revisionError
    end
    local payload, payloadError = activePage.BuildPageUpsertPayload(wire, context.AncestorVariableLayers, hashCallback)
    if not payload then
        return nil, payloadError
    end

    local freshContext, freshError = BuildLocalPageContext(categories, pages, pageId, safeOptions.ManagedScopeId)
    if not freshContext then
        return nil, freshError
    end
    if not ContextsEqual(context, freshContext) then
        return nil, "stale-page-context"
    end

    if revisionAction ~= "unchanged" then
        context.Page.Revision = wire.Revision
        context.Page.RevisionId = wire.RevisionId
        context.Page.UpdatedAt = wire.UpdatedAt
        context.Page.UpdatedBy = wire.UpdatedBy
    end

    return payload,
        nil,
        {
            RevisionAction = revisionAction,
            BoundarySyncId = context.BoundarySyncId,
            AncestorCount = #context.AncestorVariableLayers,
            Order = context.Order,
        }
end

--- Prepares a local page using a previously validated authoritative wire context.
-- This is the remote-owned republish path: private local CategoryId/Index fields
-- are deliberately ignored. The base page supplies immutable wire placement,
-- while the current local record supplies editable Name/Vars/Contents.
-- @tparam table page Current local page record.
-- @tparam table basePayload Exact previously received PAGE_UPSERT payload.
-- @tparam table options Exact UpdatedAt/UpdatedBy and optional matching ManagedScopeId.
-- @tparam function hashCallback FCS32-compatible callback.
-- @treturn table|nil payload
-- @treturn string|nil errorCode
-- @treturn table|nil preparation Detached revision action and boundary summary.
function activePage.PrepareLocalPageUpsertFromContext(page, basePayload, options, hashCallback)
    local safeOptions, optionsError = ValidatePreparationOptions(options)
    if not safeOptions then
        return nil, optionsError
    end
    if type(hashCallback) ~= "function" then
        return nil, "invalid-hash-callback"
    end

    local validBase, baseError, safeBase = activePage.ValidatePageUpsertPayload(basePayload, hashCallback)
    if not validBase then
        return nil, baseError
    end
    if not IsPlainTable(page) then
        return nil, "invalid-local-record"
    end
    local pageId = rawget(page, "Id")
    local validPage, pageError = ValidateSortableLocalRecord("page", pageId, page)
    if not validPage then
        return nil, pageError
    end

    local base = safeBase.Page
    for _, field in ipairs({
        "SyncId",
        "OwnerId",
        "Revision",
        "RevisionId",
        "UpdatedAt",
        "UpdatedBy",
    }) do
        if rawget(page, field) ~= rawget(base, field) then
            return nil, "authoritative-base-mismatch"
        end
    end

    local boundarySyncId = #safeBase.AncestorVariableLayers > 0 and safeBase.AncestorVariableLayers[1].SyncId or nil
    if safeOptions.ManagedScopeId ~= nil and safeOptions.ManagedScopeId ~= boundarySyncId then
        return nil, "managed-scope-boundary-mismatch"
    end

    local sourceSnapshot = SnapshotFields(page, LOCAL_PAGE_SOURCE_FIELDS)
    local current = BuildLocalWirePage(page, base.ParentSyncId, base.Order)
    local expectedRevisionId, revisionError = schema.BuildEntityRevisionId(current, hashCallback)
    if not expectedRevisionId then
        return nil, revisionError
    end

    local wire
    local revisionAction
    if current.RevisionId == expectedRevisionId then
        wire = current
        revisionAction = "unchanged"
    else
        if not IsInteger(current.Revision, 1, schema.LIMITS.Revision - 1) then
            return nil, current.Revision == schema.LIMITS.Revision and "revision-exhausted" or "invalid-revision"
        end
        wire, revisionError = BuildHashedLocalWire(page, base.ParentSyncId, base.Order, {
            Revision = current.Revision + 1,
            UpdatedAt = safeOptions.UpdatedAt,
            UpdatedBy = safeOptions.UpdatedBy,
        }, hashCallback)
        if not wire then
            return nil, revisionError
        end
        revisionAction = "touched"
    end

    local payload, payloadError = activePage.BuildPageUpsertPayload(wire, safeBase.AncestorVariableLayers, hashCallback)
    if not payload then
        return nil, payloadError
    end
    if not SnapshotsEqual(sourceSnapshot, SnapshotFields(page, LOCAL_PAGE_SOURCE_FIELDS), LOCAL_PAGE_SOURCE_FIELDS) then
        return nil, "stale-page-context"
    end

    if revisionAction ~= "unchanged" then
        page.Revision = wire.Revision
        page.RevisionId = wire.RevisionId
        page.UpdatedAt = wire.UpdatedAt
        page.UpdatedBy = wire.UpdatedBy
    end

    return payload,
        nil,
        {
            RevisionAction = revisionAction,
            BoundarySyncId = boundarySyncId,
            AncestorCount = #safeBase.AncestorVariableLayers,
            Order = base.Order,
            AuthoritativeContext = true,
        }
end
