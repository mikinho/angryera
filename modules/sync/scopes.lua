-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/scopes.lua
--
-- Persisted selected-category synchronization scope state.
-- This module validates SavedVariables independently from network authorization
-- and never performs cleanup or applies a manifest.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity
local schema = AngryEra.sync and AngryEra.sync.schema

if not identity or type(identity.ParseSyncId) ~= "function" then
    error("AngryEra identity must load before synchronization scopes")
end
if not schema or type(schema.ValidateTombstone) ~= "function" then
    error("AngryEra synchronization schema must load before synchronization scopes")
end

AngryEra.sync.scopes = {}
local scopes = AngryEra.sync.scopes

scopes.VERSION = 1
scopes.LIMITS = {
    ScopeCount = 64,
    EntityIds = schema.LIMITS.EntityCount,
    Tombstones = schema.LIMITS.TombstoneCount,
    CleanupCandidates = schema.LIMITS.EntityCount + schema.LIMITS.TombstoneCount,
}

local SCOPE_KEYS = {
    Schema = true,
    ScopeId = true,
    Enabled = true,
    AutoCleanup = true,
    AuthoritySender = true,
    AuthorityInstallationId = true,
    AuthorityEpoch = true,
    ScopeRevision = true,
    ManifestId = true,
    ManifestHash = true,
    AppliedAt = true,
    EntityIds = true,
    Tombstones = true,
    CleanupCandidates = true,
}

local SCOPE_REQUIRED_KEYS = {
    "Schema",
    "ScopeId",
    "Enabled",
    "AutoCleanup",
    "ScopeRevision",
    "EntityIds",
    "Tombstones",
    "CleanupCandidates",
}

local CLEANUP_CANDIDATE_KEYS = {
    Kind = true,
    SyncId = true,
    Cause = true,
    FirstSeenScopeRevision = true,
    TombstoneRevisionId = true,
}

local CLEANUP_CANDIDATE_REQUIRED_KEYS = {
    "Kind",
    "SyncId",
    "Cause",
    "FirstSeenScopeRevision",
}

local TOMBSTONE_COPY_KEYS = {
    "Kind",
    "SyncId",
    "OwnerId",
    "Revision",
    "RevisionId",
    "BaseRevisionId",
    "DeletedAt",
    "DeletedBy",
    "DeletedScopeRevision",
}

local function IsInteger(value, minimum, maximum)
    return type(value) == "number"
        and value == value
        and value >= minimum
        and value <= maximum
        and value == math.floor(value)
end

local function ValidatePlainTable(value, errorCode)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false, errorCode
    end
    return true
end

local function ValidateKnownKeys(value, knownKeys, requiredKeys, prefix)
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
    return true
end

local function ValidateCanonicalSyncId(value, expectedKind)
    if type(value) ~= "string" or #value > schema.LIMITS.SyncIdBytes then
        return false
    end

    local installationId, kind, sequence = identity.ParseSyncId(value)
    return installationId ~= nil
        and (expectedKind == nil or kind == expectedKind)
        and IsInteger(sequence, 1, schema.LIMITS.Revision)
        and value == string.format("%s:%s:%d", installationId, kind, sequence)
end

local function ParseMessageId(value)
    if type(value) ~= "string" or value == "" or #value > schema.LIMITS.MessageIdBytes then
        return nil
    end

    local installationId, sessionId, sequenceText = value:match("^(.*):([^:]+):([0-9]+)$")
    local sequence = tonumber(sequenceText)
    if
        not identity.ValidateInstallationId(installationId)
        or type(sessionId) ~= "string"
        or sessionId == ""
        or #sessionId > schema.LIMITS.SessionIdBytes
        or sessionId:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") == nil
        or not IsInteger(sequence, 1, schema.LIMITS.Revision)
        or sequenceText ~= tostring(sequence)
    then
        return nil
    end
    return installationId, sessionId
end

local function ValidateRevisionId(value)
    return type(value) == "string"
        and #value == schema.LIMITS.RevisionIdBytes
        and value:match("^fcs32:[0-9a-f]+$") ~= nil
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

local function ValidateAuthoritySender(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= schema.LIMITS.AuthorBytes
        and not ContainsControlByte(value)
        and not value:find("%s")
        and value:sub(1, 1) ~= "-"
        and value:sub(-1) ~= "-"
        and value:find("-", 1, true) ~= nil
end

local function CopyTombstone(tombstone)
    local copy = {}
    for _, key in ipairs(TOMBSTONE_COPY_KEYS) do
        copy[key] = tombstone[key]
    end
    return copy
end

local function CopyCandidate(candidate)
    return {
        Kind = candidate.Kind,
        SyncId = candidate.SyncId,
        Cause = candidate.Cause,
        FirstSeenScopeRevision = candidate.FirstSeenScopeRevision,
        TombstoneRevisionId = candidate.TombstoneRevisionId,
    }
end

local function CopyScopeRecord(record)
    local copy = {
        Schema = record.Schema,
        ScopeId = record.ScopeId,
        Enabled = record.Enabled,
        AutoCleanup = record.AutoCleanup,
        AuthoritySender = record.AuthoritySender,
        AuthorityInstallationId = record.AuthorityInstallationId,
        AuthorityEpoch = record.AuthorityEpoch,
        ScopeRevision = record.ScopeRevision,
        ManifestId = record.ManifestId,
        ManifestHash = record.ManifestHash,
        AppliedAt = record.AppliedAt,
        EntityIds = {},
        Tombstones = {},
        CleanupCandidates = {},
    }
    for index, syncId in ipairs(record.EntityIds) do
        copy.EntityIds[index] = syncId
    end
    for index, tombstone in ipairs(record.Tombstones) do
        copy.Tombstones[index] = CopyTombstone(tombstone)
    end
    for index, candidate in ipairs(record.CleanupCandidates) do
        copy.CleanupCandidates[index] = CopyCandidate(candidate)
    end
    return copy
end

local function ValidateCleanupCandidate(candidate, scopeRevision)
    local plain, plainError = ValidatePlainTable(candidate, "invalid-cleanup-candidate")
    if not plain then
        return false, plainError
    end
    local known, knownError =
        ValidateKnownKeys(candidate, CLEANUP_CANDIDATE_KEYS, CLEANUP_CANDIDATE_REQUIRED_KEYS, "cleanup-candidate")
    if not known then
        return false, knownError
    end
    if candidate.Kind ~= "page" and candidate.Kind ~= "category" then
        return false, "invalid-cleanup-candidate-kind"
    end
    if not ValidateCanonicalSyncId(candidate.SyncId, candidate.Kind) then
        return false, "invalid-cleanup-candidate-sync-id"
    end
    if candidate.Cause ~= "absent" and candidate.Cause ~= "tombstone" then
        return false, "invalid-cleanup-candidate-cause"
    end
    if not IsInteger(candidate.FirstSeenScopeRevision, 1, scopeRevision) then
        return false, "invalid-cleanup-candidate-revision"
    end
    if candidate.Cause == "absent" then
        if candidate.TombstoneRevisionId ~= nil then
            return false, "unexpected-cleanup-tombstone-revision-id"
        end
    elseif not ValidateRevisionId(candidate.TombstoneRevisionId) then
        return false, "invalid-cleanup-tombstone-revision-id"
    end
    return true
end

local function ValidateScopeRecordInternal(record, hashCallback)
    local plain, plainError = ValidatePlainTable(record, "invalid-scope")
    if not plain then
        return false, plainError
    end
    local known, knownError = ValidateKnownKeys(record, SCOPE_KEYS, SCOPE_REQUIRED_KEYS, "scope")
    if not known then
        return false, knownError
    end
    if record.Schema ~= scopes.VERSION then
        return false, "invalid-scope-schema"
    end
    if not ValidateCanonicalSyncId(record.ScopeId, "category") then
        return false, "invalid-scope-id"
    end
    if type(record.Enabled) ~= "boolean" then
        return false, "invalid-scope-enabled"
    end
    if type(record.AutoCleanup) ~= "boolean" then
        return false, "invalid-scope-auto-cleanup"
    end
    if not IsInteger(record.ScopeRevision, 0, schema.LIMITS.ScopeRevision) then
        return false, "invalid-scope-revision"
    end

    local entityCount, entityArrayError = schema.ValidateDenseArray(record.EntityIds, scopes.LIMITS.EntityIds, 0)
    if not entityCount then
        return false, "scope-entity-ids-" .. entityArrayError
    end
    local tombstoneCount, tombstoneArrayError =
        schema.ValidateDenseArray(record.Tombstones, scopes.LIMITS.Tombstones, 0)
    if not tombstoneCount then
        return false, "scope-tombstones-" .. tombstoneArrayError
    end
    local cleanupCount, cleanupArrayError =
        schema.ValidateDenseArray(record.CleanupCandidates, scopes.LIMITS.CleanupCandidates, 0)
    if not cleanupCount then
        return false, "scope-cleanup-candidates-" .. cleanupArrayError
    end

    if record.ScopeRevision == 0 then
        if
            record.AuthoritySender ~= nil
            or record.AuthorityInstallationId ~= nil
            or record.AuthorityEpoch ~= nil
            or record.ManifestId ~= nil
            or record.ManifestHash ~= nil
            or record.AppliedAt ~= nil
        then
            return false, "pending-scope-has-applied-metadata"
        end
        if entityCount ~= 0 or tombstoneCount ~= 0 or cleanupCount ~= 0 then
            return false, "pending-scope-has-records"
        end
        return true
    end

    if not ValidateAuthoritySender(record.AuthoritySender) then
        return false, "invalid-authority-sender"
    end
    if not identity.ValidateInstallationId(record.AuthorityInstallationId) then
        return false, "invalid-authority-installation-id"
    end
    local epochInstallationId, epochSessionId = ParseMessageId(record.AuthorityEpoch)
    if epochInstallationId ~= record.AuthorityInstallationId then
        return false, "invalid-authority-epoch"
    end
    local manifestInstallationId, manifestSessionId = ParseMessageId(record.ManifestId)
    if manifestInstallationId ~= record.AuthorityInstallationId then
        return false, "invalid-scope-manifest-id"
    end
    if epochSessionId ~= manifestSessionId then
        return false, "authority-session-mismatch"
    end
    if not ValidateRevisionId(record.ManifestHash) then
        return false, "invalid-scope-manifest-hash"
    end
    if not IsInteger(record.AppliedAt, 0, schema.LIMITS.Timestamp) then
        return false, "invalid-scope-applied-at"
    end

    local entityIds = {}
    local previousSyncId
    for index = 1, entityCount do
        local syncId = record.EntityIds[index]
        if not ValidateCanonicalSyncId(syncId) then
            return false, "invalid-scope-entity-id"
        end
        if previousSyncId and previousSyncId >= syncId then
            return false, "scope-entity-ids-not-canonical"
        end
        previousSyncId = syncId
        entityIds[syncId] = true
    end
    if not entityIds[record.ScopeId] then
        return false, "scope-root-not-retained"
    end

    local tombstones = {}
    previousSyncId = nil
    for index = 1, tombstoneCount do
        local tombstone = record.Tombstones[index]
        local validTombstone, tombstoneError = schema.ValidateTombstone(tombstone, hashCallback)
        if not validTombstone then
            return false, "scope-tombstone-" .. tostring(tombstoneError)
        end
        if previousSyncId and previousSyncId >= tombstone.SyncId then
            return false, "scope-tombstones-not-canonical"
        end
        previousSyncId = tombstone.SyncId
        if entityIds[tombstone.SyncId] then
            return false, "scope-entity-tombstone-collision"
        end
        if tombstone.DeletedScopeRevision > record.ScopeRevision then
            return false, "scope-future-tombstone"
        end
        tombstones[tombstone.SyncId] = tombstone
    end

    local cleanupIds = {}
    previousSyncId = nil
    for index = 1, cleanupCount do
        local candidate = record.CleanupCandidates[index]
        local validCandidate, candidateError = ValidateCleanupCandidate(candidate, record.ScopeRevision)
        if not validCandidate then
            return false, "scope-" .. candidateError
        end
        if previousSyncId and previousSyncId >= candidate.SyncId then
            return false, "scope-cleanup-candidates-not-canonical"
        end
        previousSyncId = candidate.SyncId
        if cleanupIds[candidate.SyncId] then
            return false, "duplicate-cleanup-candidate"
        end
        cleanupIds[candidate.SyncId] = true
        if entityIds[candidate.SyncId] then
            return false, "scope-entity-cleanup-collision"
        end

        local retainedTombstone = tombstones[candidate.SyncId]
        if candidate.Cause == "tombstone" then
            if not retainedTombstone or retainedTombstone.RevisionId ~= candidate.TombstoneRevisionId then
                return false, "cleanup-tombstone-not-retained"
            end
        elseif retainedTombstone then
            return false, "cleanup-cause-mismatch"
        end
    end

    return true
end

--- Creates a disabled, empty selected-category scope record.
-- Enabling hierarchy synchronization is always a separate explicit action.
-- @tparam string scopeId Canonical category SyncId.
-- @treturn table|nil record
-- @treturn string|nil errorCode
function scopes.NewScopeRecord(scopeId)
    if not ValidateCanonicalSyncId(scopeId, "category") then
        return nil, "invalid-scope-id"
    end
    return {
        Schema = scopes.VERSION,
        ScopeId = scopeId,
        Enabled = false,
        AutoCleanup = false,
        ScopeRevision = 0,
        EntityIds = {},
        Tombstones = {},
        CleanupCandidates = {},
    }
end

--- Validates a complete persisted synchronization scope without mutating it.
-- @tparam table record Persisted scope record.
-- @tparam[opt] function hashCallback Tombstone FCS32 callback. Required when tombstones are retained.
-- @treturn boolean valid
-- @treturn string|nil errorCode
function scopes.ValidateScopeRecord(record, hashCallback)
    return ValidateScopeRecordInternal(record, hashCallback)
end

--- Validates and copies a persisted scope.
-- Malformed records with a recoverable canonical scope key become disabled,
-- empty records so stale metadata cannot claim entities or enable cleanup.
-- @tparam any record Persisted scope record.
-- @tparam[opt] string expectedScopeId Canonical storage key.
-- @tparam[opt] function hashCallback Tombstone FCS32 callback.
-- @treturn table|nil normalizedRecord
-- @treturn boolean accepted Whether the original record was valid.
-- @treturn string|nil errorCode
function scopes.NormalizeScopeRecord(record, expectedScopeId, hashCallback)
    if expectedScopeId ~= nil and not ValidateCanonicalSyncId(expectedScopeId, "category") then
        return nil, false, "invalid-expected-scope-id"
    end

    local valid, validationError = ValidateScopeRecordInternal(record, hashCallback)
    if valid and (expectedScopeId == nil or record.ScopeId == expectedScopeId) then
        return CopyScopeRecord(record), true
    end

    if valid then
        validationError = "scope-key-mismatch"
    end
    local recoverableScopeId = expectedScopeId
    if
        recoverableScopeId == nil
        and type(record) == "table"
        and ValidateCanonicalSyncId(record.ScopeId, "category")
    then
        recoverableScopeId = record.ScopeId
    end
    if not recoverableScopeId then
        return nil, false, validationError or "invalid-scope-id"
    end

    return scopes.NewScopeRecord(recoverableScopeId), false, validationError
end

--- Normalizes a local ManagedScopes map.
-- Only canonical category SyncIds mapped to the literal boolean true survive.
-- @tparam any managedScopes Existing local-only map.
-- @tparam[opt] table allowedScopes Optional set of allowed scope IDs.
-- @treturn table normalized
function scopes.NormalizeManagedScopes(managedScopes, allowedScopes)
    local normalized = {}
    if type(managedScopes) ~= "table" or getmetatable(managedScopes) ~= nil then
        return normalized
    end
    for scopeId, managed in pairs(managedScopes) do
        if
            managed == true
            and ValidateCanonicalSyncId(scopeId, "category")
            and (allowedScopes == nil or allowedScopes[scopeId] == true)
        then
            normalized[scopeId] = true
        end
    end
    return normalized
end

local function CopyEntityLocalWithoutManagedScopes(entityLocal)
    local normalized = {}
    if type(entityLocal) ~= "table" or getmetatable(entityLocal) ~= nil then
        return normalized
    end
    for syncId, state in pairs(entityLocal) do
        if type(state) == "table" and getmetatable(state) == nil then
            local stateCopy = {}
            for key, value in pairs(state) do
                if key ~= "ManagedScopes" then
                    stateCopy[key] = value
                end
            end
            stateCopy.ManagedScopes = {}
            normalized[syncId] = stateCopy
        else
            normalized[syncId] = state
        end
    end
    return normalized
end

local function RebuildManagedScopes(entityLocal, scopeStorage, acceptedScopes)
    local normalized = CopyEntityLocalWithoutManagedScopes(entityLocal)

    local function AddMembership(syncId, scopeId)
        local state = normalized[syncId]
        if type(state) ~= "table" or getmetatable(state) ~= nil then
            state = {}
            normalized[syncId] = state
        end
        state.ManagedScopes = scopes.NormalizeManagedScopes(state.ManagedScopes)
        state.ManagedScopes[scopeId] = true
    end

    for scopeId in pairs(acceptedScopes) do
        local scope = scopeStorage[scopeId]
        for _, syncId in ipairs(scope.EntityIds) do
            AddMembership(syncId, scopeId)
        end
        for _, candidate in ipairs(scope.CleanupCandidates) do
            AddMembership(candidate.SyncId, scopeId)
        end
    end
    return normalized
end

--- Normalizes all persisted scopes and reconciles local managed-scope maps.
-- A malformed entry with a canonical storage key is retained only as a
-- disabled empty record. Disabled but otherwise valid records retain metadata
-- and continue to identify their managed entities.
-- @tparam any scopeStorage Existing AngryAssign_Meta.SyncScopes table.
-- @tparam any entityLocal Existing AngryAssign_Meta.EntityLocal table.
-- @tparam[opt] function hashCallback Tombstone FCS32 callback.
-- @treturn table normalizedScopes
-- @treturn table normalizedEntityLocal
-- @treturn table errors Array of `{ScopeId=string|nil, Error=string}`.
function scopes.NormalizeStorage(scopeStorage, entityLocal, hashCallback)
    local normalizedScopes = {}
    local acceptedScopes = {}
    local errors = {}

    if type(scopeStorage) ~= "table" or getmetatable(scopeStorage) ~= nil then
        errors[1] = { Error = "invalid-scope-storage" }
        return normalizedScopes, RebuildManagedScopes(entityLocal, normalizedScopes, acceptedScopes), errors
    end

    local entries = {}
    for key, record in pairs(scopeStorage) do
        if ValidateCanonicalSyncId(key, "category") then
            entries[#entries + 1] = {
                Key = key,
                Record = record,
            }
        else
            errors[#errors + 1] = { Error = "invalid-scope-storage-key" }
        end
    end
    if #entries > scopes.LIMITS.ScopeCount then
        errors[#errors + 1] = { Error = "too-many-sync-scopes" }
        return normalizedScopes, RebuildManagedScopes(entityLocal, normalizedScopes, acceptedScopes), errors
    end
    table.sort(entries, function(left, right)
        return left.Key < right.Key
    end)

    for _, entry in ipairs(entries) do
        local normalized, accepted, normalizationError =
            scopes.NormalizeScopeRecord(entry.Record, entry.Key, hashCallback)
        normalizedScopes[entry.Key] = normalized
        if accepted then
            acceptedScopes[entry.Key] = true
        else
            errors[#errors + 1] = {
                ScopeId = entry.Key,
                Error = normalizationError or "invalid-scope",
            }
        end
    end

    local claims = {}
    local conflicts = {}
    local function Claim(syncId, scopeId)
        local claimedBy = claims[syncId]
        if claimedBy and claimedBy ~= scopeId then
            conflicts[claimedBy] = true
            conflicts[scopeId] = true
        else
            claims[syncId] = scopeId
        end
    end

    for _, entry in ipairs(entries) do
        local scopeId = entry.Key
        local scope = normalizedScopes[scopeId]
        if acceptedScopes[scopeId] then
            for _, syncId in ipairs(scope.EntityIds) do
                Claim(syncId, scopeId)
            end
            for _, tombstone in ipairs(scope.Tombstones) do
                Claim(tombstone.SyncId, scopeId)
            end
            for _, candidate in ipairs(scope.CleanupCandidates) do
                Claim(candidate.SyncId, scopeId)
            end
        end
    end

    for _, entry in ipairs(entries) do
        local scopeId = entry.Key
        if conflicts[scopeId] then
            normalizedScopes[scopeId] = scopes.NewScopeRecord(scopeId)
            acceptedScopes[scopeId] = nil
            errors[#errors + 1] = {
                ScopeId = scopeId,
                Error = "overlapping-sync-scope",
            }
        end
    end

    return normalizedScopes, RebuildManagedScopes(entityLocal, normalizedScopes, acceptedScopes), errors
end

--- Normalizes persisted synchronization scope metadata in place.
-- Callers must supply the canonical FCS32 callback when retained tombstones
-- may be present.
-- @tparam[opt] function hashCallback Tombstone FCS32 callback.
-- @treturn table normalizedScopes
-- @treturn table errors
function AngryEra:NormalizeSyncScopeStorage(hashCallback)
    local meta = self:InitializeIdentityStorage()
    local normalizedScopes, normalizedEntityLocal, errors =
        scopes.NormalizeStorage(meta.SyncScopes, meta.EntityLocal, hashCallback)
    meta.SyncScopes = normalizedScopes
    meta.EntityLocal = normalizedEntityLocal
    return normalizedScopes, errors
end

--- Returns a persisted selected-category scope by canonical ScopeId.
-- @tparam string scopeId Category SyncId.
-- @treturn table|nil record
function AngryEra:GetSyncScope(scopeId)
    if not ValidateCanonicalSyncId(scopeId, "category") or not AngryAssign_Meta then
        return nil
    end
    return type(AngryAssign_Meta.SyncScopes) == "table" and AngryAssign_Meta.SyncScopes[scopeId] or nil
end

local function SetScopeBoolean(self, scopeId, field, value, hashCallback)
    if not ValidateCanonicalSyncId(scopeId, "category") then
        return false, "invalid-scope-id"
    end
    if type(value) ~= "boolean" then
        if field == "Enabled" then
            return false, "invalid-scope-enabled"
        end
        return false, "invalid-scope-auto-cleanup"
    end

    local meta = self:InitializeIdentityStorage()
    local record = meta.SyncScopes[scopeId]
    if record == nil then
        return false, "unknown-sync-scope"
    else
        local accepted
        local validationError
        record, accepted, validationError = scopes.NormalizeScopeRecord(record, scopeId, hashCallback)
        if not accepted then
            return false, validationError
        end
    end

    record[field] = value
    meta.SyncScopes[scopeId] = record
    return true, record
end

--- Explicitly enables or disables selected-category synchronization.
-- Disabling retains valid applied metadata and entity provenance.
-- @tparam string scopeId Category SyncId.
-- @tparam boolean enabled Requested opt-in state.
-- @tparam[opt] function hashCallback Tombstone FCS32 callback.
-- @treturn boolean ok
-- @treturn table|string recordOrError
function AngryEra:SetSyncScopeEnabled(scopeId, enabled, hashCallback)
    return SetScopeBoolean(self, scopeId, "Enabled", enabled, hashCallback)
end

--- Explicitly enables or disables automatic cleanup for one scope.
-- This changes policy metadata only; it never executes cleanup.
-- @tparam string scopeId Category SyncId.
-- @tparam boolean enabled Requested cleanup opt-in state.
-- @tparam[opt] function hashCallback Tombstone FCS32 callback.
-- @treturn boolean ok
-- @treturn table|string recordOrError
function AngryEra:SetSyncScopeAutoCleanup(scopeId, enabled, hashCallback)
    return SetScopeBoolean(self, scopeId, "AutoCleanup", enabled, hashCallback)
end
