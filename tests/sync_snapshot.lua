local app = {
    AngryEra = {},
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/revisions.lua"))("AngryEra", app)
assert(loadfile("modules/sync/scopes.lua"))("AngryEra", app)
assert(loadfile("modules/sync/snapshot.lua"))("AngryEra", app)

local schema = app.AngryEra.sync.schema
local snapshot = app.AngryEra.sync.snapshot
local assertions = 0

local function Assert(value, message)
    assertions = assertions + 1
    assert(value, message)
end

local function AssertEqual(actual, expected, message)
    assertions = assertions + 1
    assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function AssertError(value, errorCode, expectedError, message)
    Assert(value == nil, message .. " should fail")
    AssertEqual(errorCode, expectedError, message)
end

local function DeepCopy(value, seen)
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
        copy[DeepCopy(key, seen)] = DeepCopy(item, seen)
    end
    return copy
end

local function TestHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local localInstallationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:a:b:c:d"
local secondInstallationId = "ae3i:e:f:10:11"

local function SyncId(kind, sequence, ownerId)
    return string.format("%s:%s:%d", ownerId or remoteInstallationId, kind, sequence)
end

local function MessageId(sequence, ownerId, sessionId)
    return string.format("%s:%s:%d", ownerId or remoteInstallationId, sessionId or "leader_session", sequence)
end

local function MakeEntity(kind, sequence, parentSyncId, order, overrides)
    local ownerId = overrides and overrides.OwnerId or remoteInstallationId
    local entity = {
        Kind = kind,
        SyncId = SyncId(kind, sequence, ownerId),
        OwnerId = ownerId,
        Revision = 1,
        UpdatedAt = 1000,
        UpdatedBy = "Leader-Realm",
        ParentSyncId = parentSyncId,
        Order = order,
        Name = kind == "page" and "Assignments" or "Raid",
        Vars = "",
    }
    if kind == "page" then
        entity.Contents = "Tank: Player"
    end
    for key, value in pairs(overrides or {}) do
        entity[key] = value
    end
    entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, TestHash))
    return entity
end

local function MakeTombstone(kind, sequence, revision, baseRevisionId, overrides)
    local ownerId = overrides and overrides.OwnerId or remoteInstallationId
    local tombstone = {
        Kind = kind,
        SyncId = SyncId(kind, sequence, ownerId),
        OwnerId = ownerId,
        Revision = revision,
        BaseRevisionId = baseRevisionId,
        DeletedAt = 1100,
        DeletedBy = "Leader-Realm",
        DeletedScopeRevision = 2,
    }
    for key, value in pairs(overrides or {}) do
        tombstone[key] = value
    end
    tombstone.RevisionId = assert(schema.BuildTombstoneRevisionId(tombstone, TestHash))
    return tombstone
end

local function SortRecords(records)
    table.sort(records, function(a, b)
        return a.SyncId < b.SyncId
    end)
    return records
end

local function MakeManifest(overrides)
    local root = MakeEntity("category", 1, nil, 1)
    local page = MakeEntity("page", 2, root.SyncId, 1)
    local manifest = {
        Schema = schema.VERSION,
        ScopeId = root.SyncId,
        RootSyncId = root.SyncId,
        ManifestId = MessageId(2),
        AuthorityEpoch = MessageId(1),
        ScopeRevision = 1,
        Entities = SortRecords({ root, page }),
        Tombstones = {},
    }
    for key, value in pairs(overrides or {}) do
        manifest[key] = value
    end
    return manifest
end

local function ManifestHash(manifest)
    return assert(schema.BuildManifestHash(manifest, TestHash))
end

local function PendingScope(scopeId)
    return {
        Schema = 1,
        ScopeId = scopeId,
        Enabled = true,
        AutoCleanup = false,
        ScopeRevision = 0,
        EntityIds = {},
        Tombstones = {},
        CleanupCandidates = {},
    }
end

local function AppliedScope(manifest, manifestHash, overrides)
    local entityIds = {}
    for index, entity in ipairs(manifest.Entities) do
        entityIds[index] = entity.SyncId
    end
    local scope = {
        Schema = 1,
        ScopeId = manifest.ScopeId,
        Enabled = true,
        AutoCleanup = false,
        AuthoritySender = "Leader-Realm",
        AuthorityInstallationId = remoteInstallationId,
        AuthorityEpoch = manifest.AuthorityEpoch,
        ScopeRevision = manifest.ScopeRevision,
        ManifestId = manifest.ManifestId,
        ManifestHash = manifestHash,
        AppliedAt = 1000,
        EntityIds = entityIds,
        Tombstones = DeepCopy(manifest.Tombstones),
        CleanupCandidates = {},
    }
    for key, value in pairs(overrides or {}) do
        scope[key] = value
    end
    return scope
end

local function LocalRecord(entity, id)
    return {
        Id = id,
        SyncId = entity.SyncId,
        OwnerId = entity.OwnerId,
        Revision = entity.Revision,
        RevisionId = entity.RevisionId,
        UpdatedAt = entity.UpdatedAt,
        UpdatedBy = entity.UpdatedBy,
        Name = entity.Name,
        Vars = entity.Vars,
        Contents = entity.Contents,
    }
end

local function StateWithScope(manifest, scope)
    local state = {
        InstallationId = localInstallationId,
        Pages = {},
        Categories = {},
        EntityLocal = {},
        SyncScopes = {
            [manifest.ScopeId] = scope,
        },
    }
    local nextCategoryId = 10
    local nextPageId = 20
    local localIds = {}
    for _, entity in ipairs(manifest.Entities) do
        if entity.Kind == "category" then
            localIds[entity.SyncId] = nextCategoryId
            nextCategoryId = nextCategoryId + 1
        else
            localIds[entity.SyncId] = nextPageId
            nextPageId = nextPageId + 1
        end
    end
    for _, entity in ipairs(manifest.Entities) do
        local localId = localIds[entity.SyncId]
        local record = LocalRecord(entity, localId)
        if entity.SyncId ~= manifest.RootSyncId then
            record.CategoryId = localIds[entity.ParentSyncId]
            record.Index = entity.Order
        end
        if entity.Kind == "category" then
            state.Categories[localId] = record
        else
            state.Pages[localId] = record
        end
        state.EntityLocal[entity.SyncId] = {
            OwnedLocally = false,
            Pinned = false,
            ManagedScopes = {
                [manifest.ScopeId] = true,
            },
        }
    end
    return state
end

local function EmptyState(manifest)
    return {
        InstallationId = localInstallationId,
        Pages = {},
        Categories = {},
        EntityLocal = {},
        SyncScopes = {
            [manifest.ScopeId] = PendingScope(manifest.ScopeId),
        },
    }
end

local function Context(overrides)
    local context = {
        Sender = "Leader-Realm",
        SenderInstallationId = remoteInstallationId,
        SenderSessionId = "leader_session",
        ReceivedAt = 1200,
    }
    for key, value in pairs(overrides or {}) do
        context[key] = value
    end
    return context
end

local manifest = MakeManifest()
local manifestHash = ManifestHash(manifest)
local emptyState = EmptyState(manifest)

local staged, stageError = snapshot.Stage(manifest, manifestHash, emptyState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil, "pending opted-in scope should stage")
AssertEqual(staged.ScopeId, manifest.ScopeId, "staged scope identity")
AssertEqual(staged.ManifestHash, manifestHash, "staged manifest hash")
Assert(not staged.AuthorityTransition, "initial authority is not an epoch transition")
Assert(not staged.NoOp, "initial snapshot is not a no-op")
AssertEqual(#staged.EntityIds, 2, "incoming entity membership")
AssertEqual(#staged.CleanupCandidates, 0, "initial snapshot has no cleanup")
Assert(staged.Manifest ~= manifest, "staged manifest is detached")
Assert(staged.Manifest.Entities ~= manifest.Entities, "staged entity array is detached")
Assert(staged.Manifest.Entities[1] ~= manifest.Entities[1], "staged entity is detached")

local originalStagedName = staged.Manifest.Entities[1].Name
manifest.Entities[1].Name = "Mutated after staging"
AssertEqual(staged.Manifest.Entities[1].Name, originalStagedName, "later packet mutation cannot change staged data")
manifest = MakeManifest()
manifestHash = ManifestHash(manifest)
emptyState = EmptyState(manifest)

local invalid, invalidError = snapshot.Stage(manifest, "fcs32:00000000", emptyState, Context(), TestHash)
AssertError(invalid, invalidError, "manifest-hash-mismatch", "mismatched manifest hash")

local disabledState = EmptyState(manifest)
disabledState.SyncScopes[manifest.ScopeId].Enabled = false
invalid, invalidError = snapshot.Stage(manifest, manifestHash, disabledState, Context(), TestHash)
AssertError(invalid, invalidError, "scope-not-enabled", "disabled scope")

local malformedScopeState = EmptyState(manifest)
malformedScopeState.SyncScopes[manifest.ScopeId].AutoCleanup = "yes"
invalid, invalidError = snapshot.Stage(manifest, manifestHash, malformedScopeState, Context(), TestHash)
AssertError(
    invalid,
    invalidError,
    "invalid-current-scope-invalid-scope-auto-cleanup",
    "current scope uses shared strict validation"
)

local unsolicitedState = EmptyState(manifest)
unsolicitedState.SyncScopes[manifest.ScopeId] = nil
invalid, invalidError = snapshot.Stage(manifest, manifestHash, unsolicitedState, Context(), TestHash)
AssertError(invalid, invalidError, "scope-not-enabled", "unsolicited scope")

invalid, invalidError = snapshot.Stage(
    manifest,
    manifestHash,
    emptyState,
    Context({ SenderInstallationId = secondInstallationId }),
    TestHash
)
AssertError(
    invalid,
    invalidError,
    "manifest-authority-installation-mismatch",
    "manifest IDs must bind to authenticated installation metadata"
)

invalid, invalidError =
    snapshot.Stage(manifest, manifestHash, emptyState, Context({ SenderSessionId = "other_session" }), TestHash)
AssertError(
    invalid,
    invalidError,
    "manifest-authority-session-mismatch",
    "manifest IDs must bind to authenticated session metadata"
)

invalid, invalidError =
    snapshot.Stage(manifest, manifestHash, emptyState, Context({ SenderSessionId = "bad:session" }), TestHash)
AssertError(invalid, invalidError, "invalid-snapshot-session", "malformed authenticated session metadata")

local localRoot = MakeEntity("category", 1, nil, 1, {
    OwnerId = localInstallationId,
    UpdatedBy = "Local-Realm",
})
local localNamespaceManifest = MakeManifest({
    ScopeId = localRoot.SyncId,
    RootSyncId = localRoot.SyncId,
    Entities = { localRoot },
})
invalid, invalidError = snapshot.Stage(
    localNamespaceManifest,
    ManifestHash(localNamespaceManifest),
    EmptyState(localNamespaceManifest),
    Context(),
    TestHash
)
AssertError(invalid, invalidError, "local-namespace-collision", "local installation namespace")

local ownedState = EmptyState(manifest)
ownedState.EntityLocal[manifest.RootSyncId] = {
    OwnedLocally = true,
    ManagedScopes = {},
}
invalid, invalidError = snapshot.Stage(manifest, manifestHash, ownedState, Context(), TestHash)
AssertError(invalid, invalidError, "locally-owned-collision", "locally owned identity")

local malformedIndexState = EmptyState(manifest)
malformedIndexState.Categories[10] = {
    Id = 11,
    SyncId = manifest.RootSyncId,
    OwnerId = remoteInstallationId,
}
invalid, invalidError = snapshot.Stage(manifest, manifestHash, malformedIndexState, Context(), TestHash)
AssertError(invalid, invalidError, "invalid-current-category", "malformed local index")

local overlappingState = EmptyState(manifest)
local otherScopeId = SyncId("category", 99, secondInstallationId)
overlappingState.SyncScopes[otherScopeId] = {
    Schema = 1,
    ScopeId = otherScopeId,
    Enabled = false,
    AutoCleanup = false,
    AuthoritySender = "Other-Realm",
    AuthorityInstallationId = secondInstallationId,
    AuthorityEpoch = MessageId(1, secondInstallationId, "other_session"),
    ScopeRevision = 1,
    ManifestId = MessageId(2, secondInstallationId, "other_session"),
    ManifestHash = "fcs32:12345678",
    AppliedAt = 1000,
    EntityIds = {
        manifest.RootSyncId,
        otherScopeId,
    },
    Tombstones = {},
    CleanupCandidates = {},
}
invalid, invalidError = snapshot.Stage(manifest, manifestHash, overlappingState, Context(), TestHash)
AssertError(
    invalid,
    invalidError,
    "entity-managed-by-another-scope",
    "disabled retained scope membership still prevents overlap"
)

overlappingState.SyncScopes[otherScopeId].EntityIds = { otherScopeId }
overlappingState.SyncScopes[otherScopeId].CleanupCandidates = {
    {
        Kind = "category",
        SyncId = manifest.RootSyncId,
        Cause = "absent",
        FirstSeenScopeRevision = 1,
    },
}
invalid, invalidError = snapshot.Stage(manifest, manifestHash, overlappingState, Context(), TestHash)
AssertError(invalid, invalidError, "entity-managed-by-another-scope", "cleanup candidate prevents overlap")

local danglingProvenanceState = EmptyState(manifest)
danglingProvenanceState.EntityLocal[manifest.RootSyncId] = {
    OwnedLocally = false,
    ManagedScopes = {
        [otherScopeId] = true,
    },
}
invalid, invalidError = snapshot.Stage(manifest, manifestHash, danglingProvenanceState, Context(), TestHash)
AssertError(invalid, invalidError, "entity-managed-by-another-scope", "retained provenance prevents overlap")

local excessiveScopeState = EmptyState(manifest)
for sequence = 100, 163 do
    local extraScopeId = SyncId("category", sequence, secondInstallationId)
    excessiveScopeState.SyncScopes[extraScopeId] = PendingScope(extraScopeId)
end
invalid, invalidError = snapshot.Stage(manifest, manifestHash, excessiveScopeState, Context(), TestHash)
AssertError(invalid, invalidError, "too-many-sync-scopes", "malformed current scope storage remains bounded")

local appliedState = StateWithScope(manifest, AppliedScope(manifest, manifestHash))
staged, stageError = snapshot.Stage(manifest, manifestHash, appliedState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil and staged.NoOp, "exact applied manifest should be idempotent")

local mismatchedScopeSessionState = DeepCopy(appliedState)
mismatchedScopeSessionState.SyncScopes[manifest.ScopeId].ManifestId = MessageId(3, nil, "other_session")
invalid, invalidError = snapshot.Stage(manifest, manifestHash, mismatchedScopeSessionState, Context(), TestHash)
AssertError(
    invalid,
    invalidError,
    "invalid-current-scope-authority",
    "persisted manifest and authority epoch sessions must agree"
)

local missingMaterializedState = DeepCopy(appliedState)
missingMaterializedState.Pages[20] = nil
staged, stageError = snapshot.Stage(manifest, manifestHash, missingMaterializedState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil and not staged.NoOp, "missing local record forces idempotent repair")

local contentDriftState = DeepCopy(appliedState)
contentDriftState.Pages[20].Contents = "Corrupted local contents"
staged, stageError = snapshot.Stage(manifest, manifestHash, contentDriftState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil and not staged.NoOp, "content drift forces idempotent repair")

local placementDriftState = DeepCopy(appliedState)
placementDriftState.Pages[20].CategoryId = nil
staged, stageError = snapshot.Stage(manifest, manifestHash, placementDriftState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil and not staged.NoOp, "placement drift forces idempotent repair")

local missingProvenanceState = DeepCopy(appliedState)
missingProvenanceState.EntityLocal[manifest.Entities[2].SyncId] = nil
staged, stageError = snapshot.Stage(manifest, manifestHash, missingProvenanceState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil and not staged.NoOp, "missing provenance forces idempotent repair")

local missingManagedScopesState = DeepCopy(appliedState)
missingManagedScopesState.EntityLocal[manifest.Entities[2].SyncId].ManagedScopes = nil
staged, stageError = snapshot.Stage(manifest, manifestHash, missingManagedScopesState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil and not staged.NoOp, "missing managed scopes force idempotent repair")

local falseManagedScopeState = DeepCopy(appliedState)
falseManagedScopeState.EntityLocal[manifest.Entities[2].SyncId].ManagedScopes[manifest.ScopeId] = false
staged, stageError = snapshot.Stage(manifest, manifestHash, falseManagedScopeState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil and not staged.NoOp, "false managed scope forces idempotent repair")

local divergentScopeManifest = DeepCopy(manifest)
divergentScopeManifest.ManifestId = MessageId(3)
local divergentScopeHash = ManifestHash(divergentScopeManifest)
invalid, invalidError = snapshot.Stage(divergentScopeManifest, divergentScopeHash, appliedState, Context(), TestHash)
AssertError(invalid, invalidError, "scope-revision-divergence", "equal scope revision divergence")

local rollbackState = DeepCopy(appliedState)
rollbackState.SyncScopes[manifest.ScopeId].ScopeRevision = 2
rollbackState.SyncScopes[manifest.ScopeId].ManifestId = MessageId(3)
rollbackState.SyncScopes[manifest.ScopeId].ManifestHash = "fcs32:12345678"
invalid, invalidError = snapshot.Stage(manifest, manifestHash, rollbackState, Context(), TestHash)
AssertError(invalid, invalidError, "scope-revision-rollback", "scope revision rollback")

local wrongSenderState = StateWithScope(manifest, AppliedScope(manifest, manifestHash))
local nextManifest = DeepCopy(manifest)
nextManifest.ScopeRevision = 2
nextManifest.ManifestId = MessageId(3)
local nextManifestHash = ManifestHash(nextManifest)
invalid, invalidError =
    snapshot.Stage(nextManifest, nextManifestHash, wrongSenderState, Context({ Sender = "Other-Realm" }), TestHash)
AssertError(invalid, invalidError, "manifest-authority-sender-mismatch", "same epoch sender binding")

local newEpochManifest = DeepCopy(manifest)
newEpochManifest.AuthorityEpoch = MessageId(10)
newEpochManifest.ManifestId = MessageId(11)
newEpochManifest.ScopeRevision = 1
local newEpochHash = ManifestHash(newEpochManifest)
local oldEpochState = StateWithScope(
    manifest,
    AppliedScope(manifest, manifestHash, {
        ScopeRevision = 5,
        ManifestId = MessageId(9),
        ManifestHash = "fcs32:12345678",
    })
)
oldEpochState.SyncScopes[manifest.ScopeId].CleanupCandidates = {
    {
        Kind = "page",
        SyncId = SyncId("page", 80, secondInstallationId),
        Cause = "absent",
        FirstSeenScopeRevision = 4,
    },
}
invalid, invalidError = snapshot.Stage(newEpochManifest, newEpochHash, oldEpochState, Context(), TestHash)
AssertError(invalid, invalidError, "authority-transition-required", "epoch change requires explicit authorization")
invalid, invalidError = snapshot.Stage(
    newEpochManifest,
    newEpochHash,
    oldEpochState,
    Context({ AllowAuthorityTransition = true }),
    TestHash
)
AssertError(invalid, invalidError, "scope-revision-rollback", "epoch change cannot reset scope revision")

newEpochManifest.ScopeRevision = 6
newEpochHash = ManifestHash(newEpochManifest)
staged, stageError = snapshot.Stage(
    newEpochManifest,
    newEpochHash,
    oldEpochState,
    Context({ AllowAuthorityTransition = true }),
    TestHash
)
Assert(staged ~= nil and stageError == nil and staged.AuthorityTransition, "authorized epoch may advance")
AssertEqual(
    staged.CleanupCandidates[1].FirstSeenScopeRevision,
    4,
    "monotonic authority change preserves cleanup candidate revision"
)

local entityRollbackState = StateWithScope(manifest, AppliedScope(manifest, manifestHash))
entityRollbackState.Categories[10].Revision = 2
local entityNextManifest = DeepCopy(nextManifest)
invalid, invalidError =
    snapshot.Stage(entityNextManifest, ManifestHash(entityNextManifest), entityRollbackState, Context(), TestHash)
AssertError(invalid, invalidError, "entity-revision-rollback", "entity revision rollback")

local entityDivergenceState = StateWithScope(manifest, AppliedScope(manifest, manifestHash))
local divergentEntityManifest = DeepCopy(nextManifest)
for _, entity in ipairs(divergentEntityManifest.Entities) do
    if entity.Kind == "page" then
        entity.Name = "Divergent"
        entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, TestHash))
    end
end
invalid, invalidError = snapshot.Stage(
    divergentEntityManifest,
    ManifestHash(divergentEntityManifest),
    entityDivergenceState,
    Context(),
    TestHash
)
AssertError(invalid, invalidError, "entity-revision-divergence", "equal entity revision divergence")

local oldManifest = MakeManifest()
local oldHash = ManifestHash(oldManifest)
local staleState = StateWithScope(oldManifest, AppliedScope(oldManifest, oldHash))
local rootOnlyManifest = DeepCopy(oldManifest)
rootOnlyManifest.ScopeRevision = 2
rootOnlyManifest.ManifestId = MessageId(3)
rootOnlyManifest.Entities = { DeepCopy(oldManifest.Entities[1]) }
local rootOnlyHash = ManifestHash(rootOnlyManifest)
staged, stageError = snapshot.Stage(rootOnlyManifest, rootOnlyHash, staleState, Context(), TestHash)
Assert(staged ~= nil and stageError == nil, "snapshot removal should stage without deleting")
AssertEqual(#staged.CleanupCandidates, 1, "removed entity becomes one cleanup candidate")
AssertEqual(staged.CleanupCandidates[1].Kind, "page", "stale candidate kind")
AssertEqual(staged.CleanupCandidates[1].Cause, "absent", "absence is previewed")
AssertEqual(staged.CleanupCandidates[1].FirstSeenScopeRevision, 2, "first stale revision is retained")
Assert(staleState.Pages[20] ~= nil, "staging never deletes the stale page")

local candidateOverlapState = DeepCopy(staleState)
candidateOverlapState.SyncScopes[otherScopeId] = DeepCopy(overlappingState.SyncScopes[otherScopeId])
local overlappingEntityIds = {
    otherScopeId,
    oldManifest.Entities[2].SyncId,
}
table.sort(overlappingEntityIds)
candidateOverlapState.SyncScopes[otherScopeId].EntityIds = overlappingEntityIds
candidateOverlapState.SyncScopes[otherScopeId].CleanupCandidates = {}
invalid, invalidError = snapshot.Stage(rootOnlyManifest, rootOnlyHash, candidateOverlapState, Context(), TestHash)
AssertError(
    invalid,
    invalidError,
    "entity-managed-by-another-scope",
    "derived cleanup candidate cannot overlap another scope"
)

local candidateProvenanceState = DeepCopy(staleState)
candidateProvenanceState.EntityLocal[oldManifest.Entities[2].SyncId].ManagedScopes[otherScopeId] = true
invalid, invalidError = snapshot.Stage(rootOnlyManifest, rootOnlyHash, candidateProvenanceState, Context(), TestHash)
AssertError(
    invalid,
    invalidError,
    "entity-managed-by-another-scope",
    "derived cleanup candidate cannot inherit conflicting provenance"
)

local missingStaleState = DeepCopy(staleState)
missingStaleState.Pages[20] = nil
local missingStaleStage = assert(snapshot.Stage(rootOnlyManifest, rootOnlyHash, missingStaleState, Context(), TestHash))
AssertEqual(#missingStaleStage.CleanupCandidates, 1, "missing stale record does not wedge a newer snapshot")
AssertEqual(missingStaleStage.CleanupCandidates[1].Kind, "page", "stale kind derives from canonical SyncId")

local candidateState = DeepCopy(staleState)
candidateState.SyncScopes[oldManifest.ScopeId] = AppliedScope(rootOnlyManifest, rootOnlyHash, {
    EntityIds = DeepCopy(staged.EntityIds),
    CleanupCandidates = DeepCopy(staged.CleanupCandidates),
})
local laterRootOnly = DeepCopy(rootOnlyManifest)
laterRootOnly.ScopeRevision = 3
laterRootOnly.ManifestId = MessageId(4)
local laterRootOnlyHash = ManifestHash(laterRootOnly)
local laterStage = assert(snapshot.Stage(laterRootOnly, laterRootOnlyHash, candidateState, Context(), TestHash))
AssertEqual(#laterStage.CleanupCandidates, 1, "unresolved candidate persists")
AssertEqual(laterStage.CleanupCandidates[1].FirstSeenScopeRevision, 2, "candidate preserves first-seen revision")

local stalePage
for _, entity in ipairs(oldManifest.Entities) do
    if entity.Kind == "page" then
        stalePage = entity
    end
end
local tombstoneManifest = DeepCopy(laterRootOnly)
tombstoneManifest.Tombstones = {
    MakeTombstone("page", 2, 2, stalePage.RevisionId, {
        DeletedScopeRevision = 3,
    }),
}
local tombstoneHash = ManifestHash(tombstoneManifest)
local tombstoneStage = assert(snapshot.Stage(tombstoneManifest, tombstoneHash, candidateState, Context(), TestHash))
AssertEqual(tombstoneStage.CleanupCandidates[1].Cause, "tombstone", "tombstone upgrades stale cause")
AssertEqual(
    tombstoneStage.CleanupCandidates[1].TombstoneRevisionId,
    tombstoneManifest.Tombstones[1].RevisionId,
    "cleanup candidate records tombstone revision"
)

local tombstonedState = StateWithScope(
    tombstoneManifest,
    AppliedScope(tombstoneManifest, tombstoneHash, {
        CleanupCandidates = DeepCopy(tombstoneStage.CleanupCandidates),
    })
)

local omittedTombstoneManifest = DeepCopy(tombstoneManifest)
omittedTombstoneManifest.ScopeRevision = 4
omittedTombstoneManifest.ManifestId = MessageId(5)
omittedTombstoneManifest.Tombstones = {}
invalid, invalidError = snapshot.Stage(
    omittedTombstoneManifest,
    ManifestHash(omittedTombstoneManifest),
    tombstonedState,
    Context(),
    TestHash
)
AssertError(invalid, invalidError, "retained-tombstone-omitted", "terminal tombstones cannot disappear")

local changedTombstoneManifest = DeepCopy(tombstoneManifest)
changedTombstoneManifest.ScopeRevision = 4
changedTombstoneManifest.ManifestId = MessageId(6)
changedTombstoneManifest.Tombstones[1].Revision = 3
changedTombstoneManifest.Tombstones[1].BaseRevisionId = tombstoneManifest.Tombstones[1].RevisionId
changedTombstoneManifest.Tombstones[1].DeletedAt = 1200
changedTombstoneManifest.Tombstones[1].DeletedScopeRevision = 4
changedTombstoneManifest.Tombstones[1].RevisionId =
    assert(schema.BuildTombstoneRevisionId(changedTombstoneManifest.Tombstones[1], TestHash))
invalid, invalidError = snapshot.Stage(
    changedTombstoneManifest,
    ManifestHash(changedTombstoneManifest),
    tombstonedState,
    Context(),
    TestHash
)
AssertError(invalid, invalidError, "terminal-tombstone-changed", "retained tombstones are immutable")

local badBaseManifest = DeepCopy(tombstoneManifest)
badBaseManifest.Tombstones[1].BaseRevisionId = "fcs32:87654321"
badBaseManifest.Tombstones[1].RevisionId =
    assert(schema.BuildTombstoneRevisionId(badBaseManifest.Tombstones[1], TestHash))
invalid, invalidError =
    snapshot.Stage(badBaseManifest, ManifestHash(badBaseManifest), candidateState, Context(), TestHash)
AssertError(invalid, invalidError, "tombstone-base-revision-mismatch", "adjacent tombstone base revision")

local reappearedManifest = DeepCopy(laterRootOnly)
local reappearedPage = DeepCopy(stalePage)
reappearedPage.Revision = 2
reappearedPage.UpdatedAt = 1300
reappearedPage.RevisionId = assert(schema.BuildEntityRevisionId(reappearedPage, TestHash))
reappearedManifest.Entities = SortRecords({ reappearedManifest.Entities[1], reappearedPage })
local reappearedHash = ManifestHash(reappearedManifest)
local reappearedStage = assert(snapshot.Stage(reappearedManifest, reappearedHash, candidateState, Context(), TestHash))
AssertEqual(#reappearedStage.CleanupCandidates, 0, "reappearing entity clears cleanup candidate")

local resurrectionManifest = DeepCopy(reappearedManifest)
resurrectionManifest.ScopeRevision = 4
resurrectionManifest.ManifestId = MessageId(5)
invalid, invalidError =
    snapshot.Stage(resurrectionManifest, ManifestHash(resurrectionManifest), tombstonedState, Context(), TestHash)
AssertError(invalid, invalidError, "tombstoned-entity-resurrection", "tombstones are terminal")

local unknownTombstoneManifest = DeepCopy(nextManifest)
unknownTombstoneManifest.Tombstones = {
    MakeTombstone("page", 50, 2, "fcs32:12345678", {
        DeletedScopeRevision = 2,
    }),
}
local unknownTombstoneState = StateWithScope(manifest, AppliedScope(manifest, manifestHash))
local unknownStage = assert(
    snapshot.Stage(
        unknownTombstoneManifest,
        ManifestHash(unknownTombstoneManifest),
        unknownTombstoneState,
        Context(),
        TestHash
    )
)
AssertEqual(#unknownStage.CleanupCandidates, 0, "unknown tombstone does not target unrelated local records")
AssertEqual(#unknownStage.Manifest.Tombstones, 1, "unknown tombstone is retained in staged manifest")

invalid, invalidError =
    snapshot.Stage(manifest, manifestHash, emptyState, Context({ Sender = "Leader-\nRealm" }), TestHash)
AssertError(invalid, invalidError, "invalid-snapshot-sender", "control byte in authenticated sender")

AssertEqual(
    emptyState.SyncScopes[manifest.ScopeId].ScopeRevision,
    0,
    "successful and failed staging do not mutate scope"
)
AssertEqual(next(emptyState.Categories), nil, "staging does not create categories")
AssertEqual(next(emptyState.Pages), nil, "staging does not create pages")

print(string.format("Synchronization snapshot tests passed (%d assertions).", assertions))
