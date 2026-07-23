-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/schema.lua
--
-- Pure protocol-v3 synchronization record validation and canonical encoding.
-- This module has no WoW API, SavedVariables, networking, or library dependencies.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity

if not identity or type(identity.ValidateInstallationId) ~= "function" then
    error("AngryEra identity must load before synchronization schema")
end

AngryEra.sync = AngryEra.sync or {}
AngryEra.sync.schema = {}
local schema = AngryEra.sync.schema

schema.VERSION = 1
schema.LIMITS = {
    EntityCount = 512,
    TombstoneCount = 512,
    HierarchyDepth = 32,
    NameBytes = 100,
    ContentsBytes = 20000,
    VarsBytes = 5000,
    AuthorBytes = 128,
    SyncIdBytes = 160,
    MessageIdBytes = 192,
    SessionIdBytes = 64,
    RevisionIdBytes = 14,
    ManifestTextBytes = 512 * 1024,
    Revision = 2147483647,
    ScopeRevision = 2147483647,
    Order = 512,
    Timestamp = 9007199254740991,
}

local ENTITY_COMMON_KEYS = {
    Kind = true,
    SyncId = true,
    OwnerId = true,
    Revision = true,
    RevisionId = true,
    UpdatedAt = true,
    UpdatedBy = true,
    ParentSyncId = true,
    Order = true,
    Name = true,
    Vars = true,
}

local ENTITY_REQUIRED_KEYS = {
    "Kind",
    "SyncId",
    "OwnerId",
    "Revision",
    "UpdatedAt",
    "UpdatedBy",
    "Order",
    "Name",
    "Vars",
}

local TOMBSTONE_KEYS = {
    Kind = true,
    SyncId = true,
    OwnerId = true,
    Revision = true,
    RevisionId = true,
    BaseRevisionId = true,
    DeletedAt = true,
    DeletedBy = true,
    DeletedScopeRevision = true,
}

local TOMBSTONE_REQUIRED_KEYS = {
    "Kind",
    "SyncId",
    "OwnerId",
    "Revision",
    "BaseRevisionId",
    "DeletedAt",
    "DeletedBy",
    "DeletedScopeRevision",
}

local MANIFEST_KEYS = {
    Schema = true,
    ScopeId = true,
    RootSyncId = true,
    ManifestId = true,
    AuthorityEpoch = true,
    ScopeRevision = true,
    Entities = true,
    Tombstones = true,
}

local MANIFEST_REQUIRED_KEYS = {
    "Schema",
    "ScopeId",
    "RootSyncId",
    "ManifestId",
    "AuthorityEpoch",
    "ScopeRevision",
    "Entities",
    "Tombstones",
}

local function IsInteger(value, minimum, maximum)
    return type(value) == "number"
        and value == value
        and value >= minimum
        and value <= maximum
        and value == math.floor(value)
end

local function IsBoundedString(value, maximum, allowEmpty)
    return type(value) == "string" and (allowEmpty or value ~= "") and #value <= maximum
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

local function ValidatePlainTable(value, errorCode)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false, errorCode
    end
    return true
end

local function ValidateKnownKeys(value, knownKeys, requiredKeys, requireRevisionId, prefix)
    for key in pairs(value) do
        if type(key) ~= "string" or not knownKeys[key] then
            return false, prefix .. "-unknown-field"
        end
    end

    for _, key in ipairs(requiredKeys) do
        if rawget(value, key) == nil then
            return false, prefix .. "-missing-" .. key
        end
    end
    if requireRevisionId and rawget(value, "RevisionId") == nil then
        return false, prefix .. "-missing-RevisionId"
    end
    return true
end

local function ValidateCanonicalSyncId(value, expectedKind)
    if not IsBoundedString(value, schema.LIMITS.SyncIdBytes, false) then
        return false
    end

    local installationId, kind, sequence = identity.ParseSyncId(value)
    if
        not installationId
        or kind ~= expectedKind
        or not IsInteger(sequence, 1, schema.LIMITS.Revision)
        or value ~= string.format("%s:%s:%d", installationId, kind, sequence)
    then
        return false
    end
    return true, installationId
end

local function ValidateMessageId(value)
    if not IsBoundedString(value, schema.LIMITS.MessageIdBytes, false) then
        return false
    end

    local installationId, sessionId, sequenceText = value:match("^(.*):([^:]+):([0-9]+)$")
    local sequence = tonumber(sequenceText)
    return identity.ValidateInstallationId(installationId)
        and IsBoundedString(sessionId, schema.LIMITS.SessionIdBytes, false)
        and sessionId:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
        and IsInteger(sequence, 1, schema.LIMITS.Revision)
        and sequenceText == tostring(sequence)
end

local function ValidateRevisionId(value)
    return type(value) == "string"
        and #value == schema.LIMITS.RevisionIdBytes
        and value:match("^fcs32:[0-9a-f]+$") ~= nil
end

local function ValidateAuthor(value)
    return IsBoundedString(value, schema.LIMITS.AuthorBytes, false)
        and not ContainsControlByte(value)
        and not value:find("%s")
        and value:sub(1, 1) ~= "-"
        and value:sub(-1) ~= "-"
        and value:find("-", 1, true) ~= nil
end

local function EncodeString(value)
    return "S" .. tostring(#value) .. ":" .. value
end

local function EncodeInteger(value)
    return "I" .. string.format("%.0f", value) .. ";"
end

local function EncodeOptionalString(value)
    if value == nil then
        return "N;"
    end
    return EncodeString(value)
end

local function HashCanonicalInput(canonicalInput, hashCallback)
    if type(hashCallback) ~= "function" then
        return nil, "invalid-hash-callback"
    end

    local ok, digest = pcall(hashCallback, canonicalInput)
    if not ok or type(digest) ~= "string" or #digest ~= 8 or digest:match("^[0-9a-f]+$") == nil then
        return nil, "hash-failed"
    end
    return "fcs32:" .. digest
end

local function ValidateEntityShape(entity, requireRevisionId)
    local plain, plainError = ValidatePlainTable(entity, "invalid-entity")
    if not plain then
        return false, plainError
    end
    if entity.Kind ~= "page" and entity.Kind ~= "category" then
        return false, "invalid-entity-kind"
    end

    local knownKeys = {}
    for key in pairs(ENTITY_COMMON_KEYS) do
        knownKeys[key] = true
    end
    if entity.Kind == "page" then
        knownKeys.Contents = true
    end

    local known, knownError = ValidateKnownKeys(entity, knownKeys, ENTITY_REQUIRED_KEYS, requireRevisionId, "entity")
    if not known then
        return false, knownError
    end
    if entity.Kind == "page" and rawget(entity, "Contents") == nil then
        return false, "entity-missing-Contents"
    end

    local validSyncId, syncInstallationId = ValidateCanonicalSyncId(entity.SyncId, entity.Kind)
    if not validSyncId then
        return false, "invalid-sync-id"
    end
    if not identity.ValidateInstallationId(entity.OwnerId) then
        return false, "invalid-owner-id"
    end
    if entity.OwnerId ~= syncInstallationId then
        return false, "owner-mismatch"
    end

    if entity.ParentSyncId ~= nil then
        if not ValidateCanonicalSyncId(entity.ParentSyncId, "category") then
            return false, "invalid-parent-sync-id"
        end
        if entity.ParentSyncId == entity.SyncId then
            return false, "self-parent"
        end
    end

    if not IsInteger(entity.Revision, 1, schema.LIMITS.Revision) then
        return false, "invalid-revision"
    end
    if requireRevisionId and not ValidateRevisionId(entity.RevisionId) then
        return false, "invalid-revision-id"
    end
    if entity.RevisionId ~= nil and not ValidateRevisionId(entity.RevisionId) then
        return false, "invalid-revision-id"
    end
    if not IsInteger(entity.UpdatedAt, 0, schema.LIMITS.Timestamp) then
        return false, "invalid-updated-at"
    end
    if not ValidateAuthor(entity.UpdatedBy) then
        return false, "invalid-updated-by"
    end
    if not IsInteger(entity.Order, 1, schema.LIMITS.Order) then
        return false, "invalid-order"
    end
    if
        not IsBoundedString(entity.Name, schema.LIMITS.NameBytes, false)
        or entity.Name:match("^%s*$")
        or entity.Name ~= entity.Name:match("^%s*(.-)%s*$")
        or ContainsControlByte(entity.Name)
    then
        return false, "invalid-name"
    end
    if not IsBoundedString(entity.Vars, schema.LIMITS.VarsBytes, true) then
        return false, "invalid-vars"
    end
    if entity.Kind == "page" and not IsBoundedString(entity.Contents, schema.LIMITS.ContentsBytes, true) then
        return false, "invalid-contents"
    end

    return true
end

--- Returns a length-prefixed canonical input for an entity revision.
-- Revision metadata is intentionally excluded.
-- @tparam table entity Page or category wire record.
-- @treturn string|nil canonicalInput
-- @treturn string|nil errorCode
function schema.CanonicalEntityInput(entity)
    local valid, validationError = ValidateEntityShape(entity, false)
    if not valid then
        return nil, validationError
    end

    local parts = {
        EncodeString("AngryEraEntity"),
        EncodeInteger(schema.VERSION),
        EncodeString(entity.Kind),
        EncodeString(entity.SyncId),
        EncodeString(entity.OwnerId),
        EncodeOptionalString(entity.ParentSyncId),
        EncodeInteger(entity.Order),
        EncodeString(entity.Name),
        EncodeString(entity.Vars),
    }
    if entity.Kind == "page" then
        parts[#parts + 1] = EncodeString(entity.Contents)
    end
    return table.concat(parts)
end

--- Builds a canonical entity RevisionId using a dependency-injected FCS32 callback.
-- The callback receives the canonical input and returns exactly eight lowercase hex digits.
-- @tparam table entity Page or category wire record.
-- @tparam function hashCallback Pure hash callback.
-- @treturn string|nil revisionId
-- @treturn string|nil errorCode
function schema.BuildEntityRevisionId(entity, hashCallback)
    local canonicalInput, canonicalError = schema.CanonicalEntityInput(entity)
    if not canonicalInput then
        return nil, canonicalError
    end
    return HashCanonicalInput(canonicalInput, hashCallback)
end

--- Validates a complete page or category wire record and its RevisionId.
-- @tparam table entity Page or category wire record.
-- @tparam function hashCallback Pure FCS32 callback.
-- @treturn boolean valid
-- @treturn string|nil errorCode
function schema.ValidateEntity(entity, hashCallback)
    local valid, validationError = ValidateEntityShape(entity, true)
    if not valid then
        return false, validationError
    end

    local expectedRevisionId, revisionError = schema.BuildEntityRevisionId(entity, hashCallback)
    if not expectedRevisionId then
        return false, revisionError
    end
    if entity.RevisionId ~= expectedRevisionId then
        return false, "revision-id-mismatch"
    end
    return true
end

local function ValidateTombstoneShape(tombstone, requireRevisionId)
    local plain, plainError = ValidatePlainTable(tombstone, "invalid-tombstone")
    if not plain then
        return false, plainError
    end
    if tombstone.Kind ~= "page" and tombstone.Kind ~= "category" then
        return false, "invalid-tombstone-kind"
    end

    local known, knownError =
        ValidateKnownKeys(tombstone, TOMBSTONE_KEYS, TOMBSTONE_REQUIRED_KEYS, requireRevisionId, "tombstone")
    if not known then
        return false, knownError
    end

    local validSyncId, syncInstallationId = ValidateCanonicalSyncId(tombstone.SyncId, tombstone.Kind)
    if not validSyncId then
        return false, "invalid-tombstone-sync-id"
    end
    if not identity.ValidateInstallationId(tombstone.OwnerId) then
        return false, "invalid-tombstone-owner-id"
    end
    if tombstone.OwnerId ~= syncInstallationId then
        return false, "tombstone-owner-mismatch"
    end
    if not IsInteger(tombstone.Revision, 2, schema.LIMITS.Revision) then
        return false, "invalid-tombstone-revision"
    end
    if requireRevisionId and not ValidateRevisionId(tombstone.RevisionId) then
        return false, "invalid-tombstone-revision-id"
    end
    if tombstone.RevisionId ~= nil and not ValidateRevisionId(tombstone.RevisionId) then
        return false, "invalid-tombstone-revision-id"
    end
    if not ValidateRevisionId(tombstone.BaseRevisionId) then
        return false, "invalid-base-revision-id"
    end
    if not IsInteger(tombstone.DeletedAt, 0, schema.LIMITS.Timestamp) then
        return false, "invalid-deleted-at"
    end
    if not ValidateAuthor(tombstone.DeletedBy) then
        return false, "invalid-deleted-by"
    end
    if not IsInteger(tombstone.DeletedScopeRevision, 1, schema.LIMITS.ScopeRevision) then
        return false, "invalid-deleted-scope-revision"
    end

    return true
end

--- Returns a length-prefixed canonical input for a tombstone revision.
-- @tparam table tombstone Tombstone wire record.
-- @treturn string|nil canonicalInput
-- @treturn string|nil errorCode
function schema.CanonicalTombstoneInput(tombstone)
    local valid, validationError = ValidateTombstoneShape(tombstone, false)
    if not valid then
        return nil, validationError
    end

    return table.concat({
        EncodeString("AngryEraTombstone"),
        EncodeInteger(schema.VERSION),
        EncodeString(tombstone.Kind),
        EncodeString(tombstone.SyncId),
        EncodeString(tombstone.OwnerId),
        EncodeInteger(tombstone.Revision),
        EncodeString(tombstone.BaseRevisionId),
        EncodeInteger(tombstone.DeletedAt),
        EncodeString(tombstone.DeletedBy),
        EncodeInteger(tombstone.DeletedScopeRevision),
    })
end

--- Builds a canonical tombstone RevisionId.
-- @tparam table tombstone Tombstone wire record.
-- @tparam function hashCallback Pure FCS32 callback.
-- @treturn string|nil revisionId
-- @treturn string|nil errorCode
function schema.BuildTombstoneRevisionId(tombstone, hashCallback)
    local canonicalInput, canonicalError = schema.CanonicalTombstoneInput(tombstone)
    if not canonicalInput then
        return nil, canonicalError
    end
    return HashCanonicalInput(canonicalInput, hashCallback)
end

--- Validates a complete tombstone wire record and its RevisionId.
-- @tparam table tombstone Tombstone wire record.
-- @tparam function hashCallback Pure FCS32 callback.
-- @treturn boolean valid
-- @treturn string|nil errorCode
function schema.ValidateTombstone(tombstone, hashCallback)
    local valid, validationError = ValidateTombstoneShape(tombstone, true)
    if not valid then
        return false, validationError
    end

    local expectedRevisionId, revisionError = schema.BuildTombstoneRevisionId(tombstone, hashCallback)
    if not expectedRevisionId then
        return false, revisionError
    end
    if tombstone.RevisionId ~= expectedRevisionId then
        return false, "tombstone-revision-id-mismatch"
    end
    return true
end

--- Validates and counts a dense one-based array with a hard entry limit.
-- @tparam table values Candidate array.
-- @tparam number maximum Maximum entries.
-- @tparam[opt=0] number minimum Minimum entries.
-- @treturn number|nil count
-- @treturn string|nil errorCode
function schema.ValidateDenseArray(values, maximum, minimum)
    if
        type(maximum) ~= "number"
        or maximum < 0
        or maximum ~= math.floor(maximum)
        or type(values) ~= "table"
        or getmetatable(values) ~= nil
    then
        return nil, "invalid-array"
    end

    minimum = minimum or 0
    if type(minimum) ~= "number" or minimum < 0 or minimum ~= math.floor(minimum) or minimum > maximum then
        return nil, "invalid-array-bounds"
    end

    local count = 0
    local highest = 0
    for key in pairs(values) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, "invalid-array-key"
        end
        if key > maximum then
            return nil, "too-many-array-items"
        end
        count = count + 1
        if key > highest then
            highest = key
        end
    end

    if count ~= highest then
        return nil, "sparse-array"
    end
    if count < minimum then
        return nil, "too-few-array-items"
    end
    return count
end

local function CanonicalEntityWireInput(entity)
    local canonicalEntity, canonicalError = schema.CanonicalEntityInput(entity)
    if not canonicalEntity then
        return nil, canonicalError
    end
    return table.concat({
        EncodeString(canonicalEntity),
        EncodeInteger(entity.Revision),
        EncodeString(entity.RevisionId),
        EncodeInteger(entity.UpdatedAt),
        EncodeString(entity.UpdatedBy),
    })
end

local function CanonicalTombstoneWireInput(tombstone)
    local canonicalTombstone, canonicalError = schema.CanonicalTombstoneInput(tombstone)
    if not canonicalTombstone then
        return nil, canonicalError
    end
    return EncodeString(canonicalTombstone) .. EncodeString(tombstone.RevisionId)
end

local function ValidateManifestInternal(manifest, hashCallback)
    local plain, plainError = ValidatePlainTable(manifest, "invalid-manifest")
    if not plain then
        return false, plainError
    end
    local known, knownError = ValidateKnownKeys(manifest, MANIFEST_KEYS, MANIFEST_REQUIRED_KEYS, false, "manifest")
    if not known then
        return false, knownError
    end
    if manifest.Schema ~= schema.VERSION then
        return false, "invalid-manifest-schema"
    end
    if not ValidateCanonicalSyncId(manifest.ScopeId, "category") then
        return false, "invalid-scope-id"
    end
    if manifest.RootSyncId ~= manifest.ScopeId then
        return false, "root-scope-mismatch"
    end
    if not ValidateMessageId(manifest.ManifestId) then
        return false, "invalid-manifest-id"
    end
    if not ValidateMessageId(manifest.AuthorityEpoch) then
        return false, "invalid-authority-epoch"
    end
    if not IsInteger(manifest.ScopeRevision, 1, schema.LIMITS.ScopeRevision) then
        return false, "invalid-scope-revision"
    end

    local entityCount, entityArrayError = schema.ValidateDenseArray(manifest.Entities, schema.LIMITS.EntityCount, 1)
    if not entityCount then
        return false, "manifest-entities-" .. entityArrayError
    end
    local tombstoneCount, tombstoneArrayError =
        schema.ValidateDenseArray(manifest.Tombstones, schema.LIMITS.TombstoneCount, 0)
    if not tombstoneCount then
        return false, "manifest-tombstones-" .. tombstoneArrayError
    end

    local records = {}
    local previousSyncId
    local rootCount = 0
    local totalTextBytes = 0
    for index = 1, entityCount do
        local entity = manifest.Entities[index]
        local validEntity, entityError = schema.ValidateEntity(entity, hashCallback)
        if not validEntity then
            return false, "manifest-entity-" .. entityError
        end
        if previousSyncId and previousSyncId >= entity.SyncId then
            return false, "manifest-entities-not-canonical"
        end
        previousSyncId = entity.SyncId
        records[entity.SyncId] = entity

        totalTextBytes = totalTextBytes + #entity.Name + #entity.Vars
        if entity.Kind == "page" then
            totalTextBytes = totalTextBytes + #entity.Contents
        end
        if totalTextBytes > schema.LIMITS.ManifestTextBytes then
            return false, "manifest-text-too-large"
        end

        if entity.ParentSyncId == nil then
            rootCount = rootCount + 1
            if entity.SyncId ~= manifest.RootSyncId then
                return false, "unexpected-manifest-root"
            end
        end
    end

    if rootCount ~= 1 then
        return false, "invalid-manifest-root-count"
    end
    local root = records[manifest.RootSyncId]
    if not root or root.Kind ~= "category" or root.ParentSyncId ~= nil or root.Order ~= 1 then
        return false, "invalid-manifest-root"
    end

    local siblingCounts = {}
    local siblingOrders = {}
    for _, entity in pairs(records) do
        if entity.SyncId ~= manifest.RootSyncId then
            if entity.ParentSyncId == nil then
                return false, "missing-parent-sync-id"
            end
            local parent = records[entity.ParentSyncId]
            if not parent then
                return false, "missing-parent"
            end
            if parent.Kind ~= "category" then
                return false, "parent-not-category"
            end

            local parentId = entity.ParentSyncId
            siblingCounts[parentId] = (siblingCounts[parentId] or 0) + 1
            siblingOrders[parentId] = siblingOrders[parentId] or {}
            if siblingOrders[parentId][entity.Order] then
                return false, "duplicate-sibling-order"
            end
            siblingOrders[parentId][entity.Order] = true
        end
    end

    for parentId, count in pairs(siblingCounts) do
        local orders = siblingOrders[parentId]
        for order = 1, count do
            if not orders[order] then
                return false, "noncanonical-sibling-order"
            end
        end
    end

    for _, entity in pairs(records) do
        local current = entity
        local seen = {}
        local depth = 1
        while current.ParentSyncId ~= nil do
            if seen[current.SyncId] then
                return false, "hierarchy-cycle"
            end
            seen[current.SyncId] = true
            current = records[current.ParentSyncId]
            depth = depth + 1
            if depth > schema.LIMITS.HierarchyDepth then
                return false, "hierarchy-too-deep"
            end
        end
        if current.SyncId ~= manifest.RootSyncId then
            return false, "disconnected-hierarchy"
        end
    end

    previousSyncId = nil
    for index = 1, tombstoneCount do
        local tombstone = manifest.Tombstones[index]
        local validTombstone, tombstoneError = schema.ValidateTombstone(tombstone, hashCallback)
        if not validTombstone then
            return false, "manifest-tombstone-" .. tombstoneError
        end
        if previousSyncId and previousSyncId >= tombstone.SyncId then
            return false, "manifest-tombstones-not-canonical"
        end
        previousSyncId = tombstone.SyncId
        if records[tombstone.SyncId] then
            return false, "entity-tombstone-collision"
        end
        if tombstone.DeletedScopeRevision > manifest.ScopeRevision then
            return false, "future-tombstone"
        end
    end

    return true
end

--- Validates a complete selected-category manifest.
-- @tparam table manifest Manifest wire record.
-- @tparam function hashCallback Pure FCS32 callback.
-- @treturn boolean valid
-- @treturn string|nil errorCode
function schema.ValidateManifest(manifest, hashCallback)
    return ValidateManifestInternal(manifest, hashCallback)
end

--- Returns a deterministic canonical input for a validated manifest.
-- @tparam table manifest Manifest wire record.
-- @tparam function hashCallback Pure FCS32 callback used to validate contained records.
-- @treturn string|nil canonicalInput
-- @treturn string|nil errorCode
function schema.CanonicalManifestInput(manifest, hashCallback)
    local valid, validationError = ValidateManifestInternal(manifest, hashCallback)
    if not valid then
        return nil, validationError
    end

    local parts = {
        EncodeString("AngryEraManifest"),
        EncodeInteger(schema.VERSION),
        EncodeString(manifest.ScopeId),
        EncodeString(manifest.RootSyncId),
        EncodeString(manifest.ManifestId),
        EncodeString(manifest.AuthorityEpoch),
        EncodeInteger(manifest.ScopeRevision),
        EncodeInteger(#manifest.Entities),
    }
    for _, entity in ipairs(manifest.Entities) do
        local wireInput, wireError = CanonicalEntityWireInput(entity)
        if not wireInput then
            return nil, wireError
        end
        parts[#parts + 1] = EncodeString(wireInput)
    end

    parts[#parts + 1] = EncodeInteger(#manifest.Tombstones)
    for _, tombstone in ipairs(manifest.Tombstones) do
        local wireInput, wireError = CanonicalTombstoneWireInput(tombstone)
        if not wireInput then
            return nil, wireError
        end
        parts[#parts + 1] = EncodeString(wireInput)
    end
    return table.concat(parts)
end

--- Builds a canonical manifest hash after complete structural and graph validation.
-- @tparam table manifest Manifest wire record.
-- @tparam function hashCallback Pure FCS32 callback.
-- @treturn string|nil manifestHash
-- @treturn string|nil errorCode
function schema.BuildManifestHash(manifest, hashCallback)
    local canonicalInput, canonicalError = schema.CanonicalManifestInput(manifest, hashCallback)
    if not canonicalInput then
        return nil, canonicalError
    end
    return HashCanonicalInput(canonicalInput, hashCallback)
end
