-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/snapshot.lua
--
-- Side-effect-free validation and staging for selected-category snapshots.
-- Runtime authorization and SavedVariables commits intentionally live elsewhere.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity
local schema = AngryEra.sync and AngryEra.sync.schema
local scopes = AngryEra.sync and AngryEra.sync.scopes
local revisions = AngryEra.sync and AngryEra.sync.revisions

if not identity or type(identity.ValidateInstallationId) ~= "function" then
    error("AngryEra identity must load before synchronization snapshots")
end
if not schema or type(schema.ValidateManifest) ~= "function" then
    error("AngryEra synchronization schema must load before snapshots")
end
if not scopes or type(scopes.ValidateScopeRecord) ~= "function" then
    error("AngryEra synchronization scopes must load before snapshots")
end
if not revisions or type(revisions.LocalToWire) ~= "function" then
    error("AngryEra synchronization revisions must load before snapshots")
end

AngryEra.sync.snapshot = {}
local snapshot = AngryEra.sync.snapshot

local MAX_CANDIDATES = schema.LIMITS.EntityCount + schema.LIMITS.TombstoneCount

local function IsInteger(value, minimum, maximum)
    return type(value) == "number"
        and value == value
        and value >= minimum
        and value <= maximum
        and value == math.floor(value)
end

local function IsPlainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function IsRevisionId(value)
    return type(value) == "string" and #value == schema.LIMITS.RevisionIdBytes and value:match("^fcs32:[0-9a-f]+$")
end

local function IsSender(value)
    if
        type(value) ~= "string"
        or value == ""
        or #value > schema.LIMITS.AuthorBytes
        or value:find("%s") ~= nil
        or value:find("-", 1, true) == nil
        or value:sub(1, 1) == "-"
        or value:sub(-1) == "-"
    then
        return false
    end
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 32 or byte == 127 then
            return false
        end
    end
    return true
end

local function ParseMessageId(value)
    if type(value) ~= "string" then
        return nil
    end
    local installationId, sessionId, sequenceText = value:match("^(.*):([^:]+):([0-9]+)$")
    local sequence = tonumber(sequenceText)
    if
        identity.ValidateInstallationId(installationId)
        and type(sessionId) == "string"
        and sessionId ~= ""
        and #sessionId <= schema.LIMITS.SessionIdBytes
        and sessionId:match("^[A-Za-z0-9][A-Za-z0-9_-]*$")
        and IsInteger(sequence, 1, schema.LIMITS.Revision)
        and sequenceText == tostring(sequence)
    then
        return installationId, sessionId, sequence
    end
    return nil
end

local function Clone(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[Clone(key, seen)] = Clone(item, seen)
    end
    return copy
end

local function ValidateDenseArray(values, maximum)
    return schema.ValidateDenseArray(values, maximum, 0)
end

local function ValidateEntityIdArray(values)
    local count, arrayError = ValidateDenseArray(values, schema.LIMITS.EntityCount)
    if not count then
        return nil, arrayError
    end

    local seen = {}
    local previous
    for index = 1, count do
        local syncId = values[index]
        if not identity.ValidateSyncId(syncId) then
            return nil, "invalid-entity-id"
        end
        if previous and previous >= syncId then
            return nil, "entity-ids-not-canonical"
        end
        seen[syncId] = true
        previous = syncId
    end
    return seen
end

local function ValidateCandidate(candidate)
    if not IsPlainTable(candidate) then
        return false, "invalid-cleanup-candidate"
    end
    for key in pairs(candidate) do
        if
            key ~= "Kind"
            and key ~= "SyncId"
            and key ~= "Cause"
            and key ~= "FirstSeenScopeRevision"
            and key ~= "TombstoneRevisionId"
        then
            return false, "cleanup-candidate-unknown-field"
        end
    end
    if candidate.Kind ~= "page" and candidate.Kind ~= "category" then
        return false, "invalid-cleanup-kind"
    end
    if not identity.ValidateSyncId(candidate.SyncId, candidate.Kind) then
        return false, "invalid-cleanup-sync-id"
    end
    if candidate.Cause ~= "absent" and candidate.Cause ~= "tombstone" then
        return false, "invalid-cleanup-cause"
    end
    if not IsInteger(candidate.FirstSeenScopeRevision, 1, schema.LIMITS.ScopeRevision) then
        return false, "invalid-cleanup-revision"
    end
    if candidate.TombstoneRevisionId ~= nil and not IsRevisionId(candidate.TombstoneRevisionId) then
        return false, "invalid-cleanup-tombstone-revision"
    end
    if candidate.Cause == "tombstone" and candidate.TombstoneRevisionId == nil then
        return false, "missing-cleanup-tombstone-revision"
    end
    if candidate.Cause == "absent" and candidate.TombstoneRevisionId ~= nil then
        return false, "unexpected-cleanup-tombstone-revision"
    end
    return true
end

local function IndexCandidates(values)
    local count, arrayError = ValidateDenseArray(values, MAX_CANDIDATES)
    if not count then
        return nil, arrayError
    end

    local indexed = {}
    local previous
    for index = 1, count do
        local candidate = values[index]
        local valid, validationError = ValidateCandidate(candidate)
        if not valid then
            return nil, validationError
        end
        if previous and previous >= candidate.SyncId then
            return nil, "cleanup-candidates-not-canonical"
        end
        indexed[candidate.SyncId] = candidate
        previous = candidate.SyncId
    end
    return indexed
end

local function IndexTombstones(values, hashCallback)
    local count, arrayError = ValidateDenseArray(values, schema.LIMITS.TombstoneCount)
    if not count then
        return nil, arrayError
    end

    local indexed = {}
    local previous
    for index = 1, count do
        local tombstone = values[index]
        local valid, validationError = schema.ValidateTombstone(tombstone, hashCallback)
        if not valid then
            return nil, validationError
        end
        if previous and previous >= tombstone.SyncId then
            return nil, "tombstones-not-canonical"
        end
        indexed[tombstone.SyncId] = tombstone
        previous = tombstone.SyncId
    end
    return indexed
end

local function ValidateCurrentScope(scopeId, scope, hashCallback)
    if not IsPlainTable(scope) or scope.ScopeId ~= scopeId or scope.Enabled ~= true then
        return nil, "scope-not-enabled"
    end
    local validScope, scopeError = scopes.ValidateScopeRecord(scope, hashCallback)
    if not validScope then
        return nil, "invalid-current-scope-" .. scopeError
    end
    if not IsInteger(scope.ScopeRevision, 0, schema.LIMITS.ScopeRevision) then
        return nil, "invalid-current-scope-revision"
    end

    local entityIds, entityError = ValidateEntityIdArray(scope.EntityIds)
    if not entityIds then
        return nil, "invalid-current-scope-entities-" .. entityError
    end
    local candidates, candidateError = IndexCandidates(scope.CleanupCandidates)
    if not candidates then
        return nil, "invalid-current-scope-candidates-" .. candidateError
    end
    local tombstones, tombstoneError = IndexTombstones(scope.Tombstones, hashCallback)
    if not tombstones then
        return nil, "invalid-current-scope-tombstones-" .. tombstoneError
    end

    if scope.ScopeRevision == 0 then
        if next(entityIds) ~= nil or next(candidates) ~= nil or next(tombstones) ~= nil then
            return nil, "invalid-pending-scope-membership"
        end
    else
        local epochInstallationId, epochSessionId = ParseMessageId(scope.AuthorityEpoch)
        local manifestInstallationId, manifestSessionId = ParseMessageId(scope.ManifestId)
        if
            not IsSender(scope.AuthoritySender)
            or not identity.ValidateInstallationId(scope.AuthorityInstallationId)
            or epochInstallationId ~= scope.AuthorityInstallationId
            or manifestInstallationId ~= scope.AuthorityInstallationId
            or epochSessionId ~= manifestSessionId
            or not IsRevisionId(scope.ManifestHash)
        then
            return nil, "invalid-current-scope-authority"
        end
    end

    return {
        EntityIds = entityIds,
        Candidates = candidates,
        Tombstones = tombstones,
    }
end

local function IndexLocalRecords(currentState)
    if not IsPlainTable(currentState.Pages) or not IsPlainTable(currentState.Categories) then
        return nil, "invalid-current-records"
    end

    local bySyncId = {}
    for _, collection in ipairs({
        { Kind = "category", Records = currentState.Categories },
        { Kind = "page", Records = currentState.Pages },
    }) do
        for localId, record in pairs(collection.Records) do
            if
                not IsInteger(localId, 1, schema.LIMITS.LocalId)
                or not IsPlainTable(record)
                or record.Id ~= localId
                or not identity.ValidateSyncId(record.SyncId, collection.Kind)
                or not identity.ValidateInstallationId(record.OwnerId)
            then
                return nil, "invalid-current-" .. collection.Kind
            end
            local ownerId = identity.ParseSyncId(record.SyncId)
            if ownerId ~= record.OwnerId then
                return nil, "invalid-current-owner"
            end
            if bySyncId[record.SyncId] then
                return nil, "duplicate-current-sync-id"
            end
            bySyncId[record.SyncId] = {
                Kind = collection.Kind,
                Record = record,
            }
        end
    end
    return bySyncId
end

local function ValidateContext(context)
    if not IsPlainTable(context) then
        return false, "invalid-snapshot-context"
    end
    for key in pairs(context) do
        if
            key ~= "Sender"
            and key ~= "SenderInstallationId"
            and key ~= "SenderSessionId"
            and key ~= "ReceivedAt"
            and key ~= "AllowAuthorityTransition"
        then
            return false, "snapshot-context-unknown-field"
        end
    end
    if not IsSender(context.Sender) then
        return false, "invalid-snapshot-sender"
    end
    if not identity.ValidateInstallationId(context.SenderInstallationId) then
        return false, "invalid-snapshot-installation"
    end
    if
        type(context.SenderSessionId) ~= "string"
        or context.SenderSessionId == ""
        or #context.SenderSessionId > schema.LIMITS.SessionIdBytes
        or context.SenderSessionId:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") == nil
    then
        return false, "invalid-snapshot-session"
    end
    if not IsInteger(context.ReceivedAt, 0, schema.LIMITS.Timestamp) then
        return false, "invalid-snapshot-time"
    end
    if context.AllowAuthorityTransition ~= nil and type(context.AllowAuthorityTransition) ~= "boolean" then
        return false, "invalid-authority-transition"
    end
    return true
end

local function CheckScopeOverlap(currentState, scopeId, incomingIds, hashCallback)
    if not IsPlainTable(currentState.SyncScopes) then
        return false, "invalid-current-scopes"
    end

    local scopeCount = 0
    for otherScopeId, otherScope in pairs(currentState.SyncScopes) do
        scopeCount = scopeCount + 1
        if scopeCount > scopes.LIMITS.ScopeCount then
            return false, "too-many-sync-scopes"
        end
        if otherScopeId ~= scopeId then
            if not identity.ValidateSyncId(otherScopeId, "category") or not IsPlainTable(otherScope) then
                return false, "invalid-overlapping-scope"
            end
            local validScope, scopeError = scopes.ValidateScopeRecord(otherScope, hashCallback)
            if not validScope or otherScope.ScopeId ~= otherScopeId then
                return false, "invalid-overlapping-scope-" .. (scopeError or "scope-key-mismatch")
            end
            local retainedScope = otherScope.Enabled == true or otherScope.ScopeRevision > 0
            if retainedScope then
                local otherIds, idError = ValidateEntityIdArray(otherScope.EntityIds)
                if not otherIds then
                    return false, "invalid-overlapping-scope-" .. idError
                end
                local otherCandidates, candidateError = IndexCandidates(otherScope.CleanupCandidates)
                if not otherCandidates then
                    return false, "invalid-overlapping-scope-" .. candidateError
                end
                local otherTombstones, tombstoneError = IndexTombstones(otherScope.Tombstones, hashCallback)
                if not otherTombstones then
                    return false, "invalid-overlapping-scope-" .. tombstoneError
                end
                for syncId in pairs(incomingIds) do
                    if otherIds[syncId] or otherCandidates[syncId] or otherTombstones[syncId] then
                        return false, "entity-managed-by-another-scope"
                    end
                end
            end
        end
    end
    return true
end

local function CheckLocalProvenance(currentState, scopeId, incomingIds)
    if not IsPlainTable(currentState.EntityLocal) then
        return false, "invalid-current-provenance"
    end

    for syncId in pairs(incomingIds) do
        local ownerId = identity.ParseSyncId(syncId)
        if ownerId == currentState.InstallationId then
            return false, "local-namespace-collision"
        end

        local localState = currentState.EntityLocal[syncId]
        if localState ~= nil then
            if not IsPlainTable(localState) then
                return false, "invalid-current-provenance"
            end
            if localState.OwnedLocally == true then
                return false, "locally-owned-collision"
            end
            if localState.ManagedScopes ~= nil then
                if not IsPlainTable(localState.ManagedScopes) then
                    return false, "invalid-current-managed-scopes"
                end
                for managedScopeId, managed in pairs(localState.ManagedScopes) do
                    if type(managed) ~= "boolean" or not identity.ValidateSyncId(managedScopeId, "category") then
                        return false, "invalid-current-managed-scopes"
                    end
                    if managed and managedScopeId ~= scopeId then
                        return false, "entity-managed-by-another-scope"
                    end
                end
            end
        end
    end
    return true
end

local function CheckEntityRevisions(manifest, scopeIndex, currentIndex)
    for _, incoming in ipairs(manifest.Entities) do
        if scopeIndex.Tombstones[incoming.SyncId] then
            return false, "tombstoned-entity-resurrection"
        end
        local current = currentIndex[incoming.SyncId]
        if current then
            if current.Kind ~= incoming.Kind or current.Record.OwnerId ~= incoming.OwnerId then
                return false, "immutable-entity-identity"
            end
            if not IsInteger(current.Record.Revision, 1, schema.LIMITS.Revision) then
                return false, "invalid-current-entity-revision"
            end
            if not IsRevisionId(current.Record.RevisionId) then
                return false, "invalid-current-entity-revision-id"
            end
            if incoming.Revision < current.Record.Revision then
                return false, "entity-revision-rollback"
            end
            if incoming.Revision == current.Record.Revision and incoming.RevisionId ~= current.Record.RevisionId then
                return false, "entity-revision-divergence"
            end
        end
    end
    return true
end

local function CandidatesEqual(left, right)
    if #left ~= #right then
        return false
    end
    for index, leftCandidate in ipairs(left) do
        local rightCandidate = right[index]
        if
            not rightCandidate
            or leftCandidate.Kind ~= rightCandidate.Kind
            or leftCandidate.SyncId ~= rightCandidate.SyncId
            or leftCandidate.Cause ~= rightCandidate.Cause
            or leftCandidate.FirstSeenScopeRevision ~= rightCandidate.FirstSeenScopeRevision
            or leftCandidate.TombstoneRevisionId ~= rightCandidate.TombstoneRevisionId
        then
            return false
        end
    end
    return true
end

local function BuildMaterializedContext(manifest, currentIndex)
    local categories = {}
    local pages = {}
    local rootCategoryId
    for _, incoming in ipairs(manifest.Entities) do
        local current = currentIndex[incoming.SyncId]
        if not current then
            return nil
        end
        if incoming.Kind == "category" then
            categories[current.Record.Id] = current.Record
            if incoming.SyncId == manifest.RootSyncId then
                rootCategoryId = current.Record.Id
            end
        else
            pages[current.Record.Id] = current.Record
        end
    end
    if not rootCategoryId then
        return nil
    end
    return revisions.BuildSiblingOrders(categories, pages, rootCategoryId)
end

local function WireRecordsEqual(left, right)
    local leftCanonical = schema.CanonicalEntityInput(left)
    local rightCanonical = schema.CanonicalEntityInput(right)
    return leftCanonical ~= nil
        and leftCanonical == rightCanonical
        and left.Revision == right.Revision
        and left.RevisionId == right.RevisionId
        and left.UpdatedAt == right.UpdatedAt
        and left.UpdatedBy == right.UpdatedBy
end

local function HasScopeProvenance(currentState, syncId, scopeId)
    local localState = currentState.EntityLocal[syncId]
    return IsPlainTable(localState)
        and localState.OwnedLocally ~= true
        and IsPlainTable(localState.ManagedScopes)
        and localState.ManagedScopes[scopeId] == true
end

local function IsMaterialized(manifest, currentScope, currentState, currentIndex, cleanupCandidates, hashCallback)
    if #currentScope.EntityIds ~= #manifest.Entities or #currentScope.Tombstones ~= #manifest.Tombstones then
        return false
    end
    local context = BuildMaterializedContext(manifest, currentIndex)
    if not context then
        return false
    end
    for index, incoming in ipairs(manifest.Entities) do
        if currentScope.EntityIds[index] ~= incoming.SyncId then
            return false
        end
        if not HasScopeProvenance(currentState, incoming.SyncId, manifest.ScopeId) then
            return false
        end
        local current = currentIndex[incoming.SyncId]
        if
            not current
            or current.Kind ~= incoming.Kind
            or current.Record.Revision ~= incoming.Revision
            or current.Record.RevisionId ~= incoming.RevisionId
        then
            return false
        end
        local currentWire = revisions.LocalToWire(incoming.Kind, current.Record, context, hashCallback)
        if not currentWire or not WireRecordsEqual(currentWire, incoming) then
            return false
        end
    end
    for index, incoming in ipairs(manifest.Tombstones) do
        local retained = currentScope.Tombstones[index]
        local incomingCanonical = schema.CanonicalTombstoneInput(incoming)
        local retainedCanonical = retained and schema.CanonicalTombstoneInput(retained)
        if
            not retained
            or retained.SyncId ~= incoming.SyncId
            or retained.Revision ~= incoming.Revision
            or retained.RevisionId ~= incoming.RevisionId
            or incomingCanonical == nil
            or retainedCanonical ~= incomingCanonical
        then
            return false
        end
    end
    for _, candidate in ipairs(cleanupCandidates) do
        if not HasScopeProvenance(currentState, candidate.SyncId, manifest.ScopeId) then
            return false
        end
    end
    return CandidatesEqual(currentScope.CleanupCandidates, cleanupCandidates)
end

local function CheckTombstoneRevisions(manifest, scopeIndex, currentIndex)
    local incomingTombstones = {}
    for _, incoming in ipairs(manifest.Tombstones) do
        incomingTombstones[incoming.SyncId] = true
        local retained = scopeIndex.Tombstones[incoming.SyncId]
        if retained then
            local incomingCanonical = schema.CanonicalTombstoneInput(incoming)
            local retainedCanonical = schema.CanonicalTombstoneInput(retained)
            if incoming.RevisionId ~= retained.RevisionId or incomingCanonical ~= retainedCanonical then
                return false, "terminal-tombstone-changed"
            end
        end

        local current = currentIndex[incoming.SyncId]
        if current and (scopeIndex.EntityIds[incoming.SyncId] or scopeIndex.Candidates[incoming.SyncId]) then
            if not IsInteger(current.Record.Revision, 1, schema.LIMITS.Revision) then
                return false, "invalid-current-entity-revision"
            end
            if not IsRevisionId(current.Record.RevisionId) then
                return false, "invalid-current-entity-revision-id"
            end
            if incoming.Revision <= current.Record.Revision then
                return false, "tombstone-revision-rollback"
            end
            if
                incoming.Revision == current.Record.Revision + 1
                and incoming.BaseRevisionId ~= current.Record.RevisionId
            then
                return false, "tombstone-base-revision-mismatch"
            end
        end
    end
    for syncId in pairs(scopeIndex.Tombstones) do
        if not incomingTombstones[syncId] then
            return false, "retained-tombstone-omitted"
        end
    end
    return true
end

local function BuildCleanupCandidates(manifest, scopeIndex, currentIndex)
    local incomingIds = {}
    for _, entity in ipairs(manifest.Entities) do
        incomingIds[entity.SyncId] = true
    end

    local tombstones = {}
    for _, tombstone in ipairs(manifest.Tombstones) do
        tombstones[tombstone.SyncId] = tombstone
    end

    local candidates = {}
    local function RetainCandidate(syncId, existingCandidate)
        if incomingIds[syncId] then
            return true
        end

        local tombstone = tombstones[syncId]
        local current = currentIndex[syncId]
        local _, syncKind = identity.ParseSyncId(syncId)
        local kind = tombstone and tombstone.Kind
            or (current and current.Kind)
            or (existingCandidate and existingCandidate.Kind)
            or syncKind
        if not kind then
            return false, "unknown-stale-entity"
        end

        local firstSeenScopeRevision = existingCandidate and existingCandidate.FirstSeenScopeRevision
            or manifest.ScopeRevision
        local candidate = {
            Kind = kind,
            SyncId = syncId,
            Cause = tombstone and "tombstone" or (existingCandidate and existingCandidate.Cause) or "absent",
            FirstSeenScopeRevision = firstSeenScopeRevision,
            TombstoneRevisionId = tombstone and tombstone.RevisionId
                or (existingCandidate and existingCandidate.TombstoneRevisionId),
        }
        if candidate.Cause == "tombstone" and candidate.TombstoneRevisionId == nil then
            return false, "missing-staged-tombstone-revision"
        end
        candidates[syncId] = candidate
        return true
    end

    for syncId, candidate in pairs(scopeIndex.Candidates) do
        local retained, retainError = RetainCandidate(syncId, candidate)
        if not retained then
            return nil, retainError
        end
    end
    for syncId in pairs(scopeIndex.EntityIds) do
        if not candidates[syncId] then
            local retained, retainError = RetainCandidate(syncId, nil)
            if not retained then
                return nil, retainError
            end
        end
    end

    local ordered = {}
    for _, candidate in pairs(candidates) do
        ordered[#ordered + 1] = candidate
    end
    if #ordered > MAX_CANDIDATES then
        return nil, "too-many-cleanup-candidates"
    end
    table.sort(ordered, function(a, b)
        return a.SyncId < b.SyncId
    end)
    return ordered
end

local function CheckAuthority(manifest, expectedHash, currentScope, context)
    local manifestInstallationId, manifestSessionId = ParseMessageId(manifest.ManifestId)
    local epochInstallationId, epochSessionId = ParseMessageId(manifest.AuthorityEpoch)
    if
        manifestInstallationId ~= context.SenderInstallationId
        or epochInstallationId ~= context.SenderInstallationId
    then
        return nil, "manifest-authority-installation-mismatch"
    end
    if manifestSessionId ~= context.SenderSessionId or epochSessionId ~= context.SenderSessionId then
        return nil, "manifest-authority-session-mismatch"
    end

    if currentScope.ScopeRevision == 0 then
        return false
    end

    if manifest.AuthorityEpoch == currentScope.AuthorityEpoch then
        if
            context.Sender ~= currentScope.AuthoritySender
            or context.SenderInstallationId ~= currentScope.AuthorityInstallationId
        then
            return nil, "manifest-authority-sender-mismatch"
        end
        if manifest.ScopeRevision < currentScope.ScopeRevision then
            return nil, "scope-revision-rollback"
        end
        if manifest.ScopeRevision == currentScope.ScopeRevision then
            if expectedHash == currentScope.ManifestHash and manifest.ManifestId == currentScope.ManifestId then
                return false, nil, true
            end
            return nil, "scope-revision-divergence"
        end
        return false
    end

    if context.AllowAuthorityTransition ~= true then
        return nil, "authority-transition-required"
    end
    if manifest.ScopeRevision <= currentScope.ScopeRevision then
        return nil, "scope-revision-rollback"
    end
    return true
end

--- Validates a complete manifest against current local state and returns a detached plan.
-- This function never mutates the manifest, current state, scope metadata, or local records.
-- @tparam table manifest Valid protocol-v3 selected-category manifest.
-- @tparam string expectedHash Sender-declared canonical manifest hash.
-- @tparam table currentState Plain snapshot of local pages, categories, provenance, and scopes.
-- @tparam table context Authenticated sender metadata and authority-transition decision.
-- @tparam function hashCallback Fixed production FCS32 callback.
-- @treturn table|nil staged
-- @treturn string|nil errorCode
function snapshot.Stage(manifest, expectedHash, currentState, context, hashCallback)
    if not IsRevisionId(expectedHash) then
        return nil, "invalid-expected-manifest-hash"
    end
    local validManifest, manifestError = schema.ValidateManifest(manifest, hashCallback)
    if not validManifest then
        return nil, "invalid-manifest-" .. manifestError
    end
    local actualHash, hashError = schema.BuildManifestHash(manifest, hashCallback)
    if not actualHash then
        return nil, "manifest-hash-" .. hashError
    end
    if actualHash ~= expectedHash then
        return nil, "manifest-hash-mismatch"
    end

    if not IsPlainTable(currentState) or not identity.ValidateInstallationId(currentState.InstallationId) then
        return nil, "invalid-current-state"
    end
    local validContext, contextError = ValidateContext(context)
    if not validContext then
        return nil, contextError
    end
    if not IsPlainTable(currentState.SyncScopes) then
        return nil, "invalid-current-scopes"
    end

    local currentScope = currentState.SyncScopes[manifest.ScopeId]
    local scopeIndex, scopeError = ValidateCurrentScope(manifest.ScopeId, currentScope, hashCallback)
    if not scopeIndex then
        return nil, scopeError
    end
    local currentIndex, indexError = IndexLocalRecords(currentState)
    if not currentIndex then
        return nil, indexError
    end

    local incomingIds = {}
    local orderedEntityIds = {}
    for index, entity in ipairs(manifest.Entities) do
        incomingIds[entity.SyncId] = true
        orderedEntityIds[index] = entity.SyncId
    end
    for _, tombstone in ipairs(manifest.Tombstones) do
        incomingIds[tombstone.SyncId] = true
    end

    local cleanupCandidates, cleanupError = BuildCleanupCandidates(manifest, scopeIndex, currentIndex)
    if not cleanupCandidates then
        return nil, cleanupError
    end
    for _, candidate in ipairs(cleanupCandidates) do
        incomingIds[candidate.SyncId] = true
    end

    local overlapValid, overlapError = CheckScopeOverlap(currentState, manifest.ScopeId, incomingIds, hashCallback)
    if not overlapValid then
        return nil, overlapError
    end
    local provenanceValid, provenanceError = CheckLocalProvenance(currentState, manifest.ScopeId, incomingIds)
    if not provenanceValid then
        return nil, provenanceError
    end
    local revisionsValid, revisionError = CheckEntityRevisions(manifest, scopeIndex, currentIndex)
    if not revisionsValid then
        return nil, revisionError
    end
    local tombstonesValid, tombstoneError = CheckTombstoneRevisions(manifest, scopeIndex, currentIndex)
    if not tombstonesValid then
        return nil, tombstoneError
    end

    local authorityTransition, authorityError, matchingMetadata =
        CheckAuthority(manifest, expectedHash, currentScope, context)
    if authorityTransition == nil then
        return nil, authorityError
    end

    return {
        Schema = schema.VERSION,
        ScopeId = manifest.ScopeId,
        Sender = context.Sender,
        SenderInstallationId = context.SenderInstallationId,
        SenderSessionId = context.SenderSessionId,
        ReceivedAt = context.ReceivedAt,
        AuthorityTransition = authorityTransition,
        NoOp = matchingMetadata == true
            and IsMaterialized(manifest, currentScope, currentState, currentIndex, cleanupCandidates, hashCallback),
        ManifestHash = expectedHash,
        Manifest = Clone(manifest),
        EntityIds = orderedEntityIds,
        CleanupCandidates = cleanupCandidates,
    }
end
