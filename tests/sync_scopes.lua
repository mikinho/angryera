local app = {
    AngryEra = {},
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/scopes.lua"))("AngryEra", app)

local AngryEra = app.AngryEra
local schema = AngryEra.sync.schema
local scopes = AngryEra.sync.scopes
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
    Assert(value == nil or value == false, message .. " should fail")
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

local installationId = "ae3i:1:2:3:4"
local otherInstallationId = "ae3i:a:b:c:d"

local function SyncId(kind, sequence, owner)
    return string.format("%s:%s:%d", owner or installationId, kind, sequence)
end

local function MessageId(sequence, owner)
    return string.format("%s:session_A-1:%d", owner or installationId, sequence)
end

local function MakeTombstone(kind, sequence, scopeRevision, overrides)
    local tombstone = {
        Kind = kind,
        SyncId = SyncId(kind, sequence, otherInstallationId),
        OwnerId = otherInstallationId,
        Revision = 2,
        BaseRevisionId = "fcs32:12345678",
        DeletedAt = 1100,
        DeletedBy = "Leader-Realm",
        DeletedScopeRevision = scopeRevision,
    }
    for key, value in pairs(overrides or {}) do
        tombstone[key] = value
    end
    tombstone.RevisionId = assert(schema.BuildTombstoneRevisionId(tombstone, TestHash))
    return tombstone
end

local rootId = SyncId("category", 1)
local pageId = SyncId("page", 2)
local tombstone = MakeTombstone("page", 90, 2)

local function MakeAppliedScope(overrides)
    local record = {
        Schema = 1,
        ScopeId = rootId,
        Enabled = true,
        AutoCleanup = false,
        AuthoritySender = "Leader-Realm",
        AuthorityInstallationId = installationId,
        AuthorityEpoch = MessageId(9),
        ScopeRevision = 2,
        ManifestId = MessageId(10),
        ManifestHash = "fcs32:abcdef12",
        AppliedAt = 1200,
        EntityIds = {
            rootId,
            pageId,
        },
        Tombstones = {
            DeepCopy(tombstone),
        },
        CleanupCandidates = {
            {
                Kind = "page",
                SyncId = tombstone.SyncId,
                Cause = "tombstone",
                FirstSeenScopeRevision = 2,
                TombstoneRevisionId = tombstone.RevisionId,
            },
        },
    }
    for key, value in pairs(overrides or {}) do
        record[key] = value
    end
    return record
end

AssertEqual(scopes.VERSION, 1, "scope schema version")
AssertEqual(scopes.LIMITS.ScopeCount, 64, "scope count bound")
AssertEqual(scopes.LIMITS.EntityIds, schema.LIMITS.EntityCount, "entity id bound")
AssertEqual(
    scopes.LIMITS.CleanupCandidates,
    schema.LIMITS.EntityCount + schema.LIMITS.TombstoneCount,
    "cleanup candidate bound"
)

local pending, pendingError = scopes.NewScopeRecord(rootId)
Assert(pending and pendingError == nil, "new pending scope succeeds")
AssertEqual(pending.Enabled, false, "selected-category sync defaults disabled")
AssertEqual(pending.AutoCleanup, false, "automatic cleanup defaults disabled")
AssertEqual(pending.ScopeRevision, 0, "pending scope starts at revision zero")
AssertEqual(#pending.EntityIds, 0, "pending scope has no entity claims")
AssertEqual(#pending.Tombstones, 0, "pending scope has no tombstones")
AssertEqual(#pending.CleanupCandidates, 0, "pending scope has no cleanup candidates")

local badPending, badPendingError = scopes.NewScopeRecord(SyncId("page", 1))
AssertError(badPending, badPendingError, "invalid-scope-id", "page cannot identify a scope")
badPending, badPendingError = scopes.NewScopeRecord(installationId .. ":category:01")
AssertError(badPending, badPendingError, "invalid-scope-id", "noncanonical scope id")

local valid, validationError = scopes.ValidateScopeRecord(pending, TestHash)
Assert(valid and validationError == nil, "pending scope validates")

local applied = MakeAppliedScope()
valid, validationError = scopes.ValidateScopeRecord(applied, TestHash)
Assert(valid and validationError == nil, "applied scope validates")

local disabled = MakeAppliedScope({
    Enabled = false,
    AutoCleanup = true,
})
valid, validationError = scopes.ValidateScopeRecord(disabled, TestHash)
Assert(valid and validationError == nil, "disabled scope retains applied metadata")

local normalized, accepted, normalizeError = scopes.NormalizeScopeRecord(disabled, rootId, TestHash)
Assert(normalized and accepted and normalizeError == nil, "valid disabled scope normalizes")
AssertEqual(normalized.Enabled, false, "normalization retains disabled state")
AssertEqual(normalized.AutoCleanup, true, "normalization retains explicit cleanup preference")
AssertEqual(normalized.ManifestId, disabled.ManifestId, "normalization retains manifest metadata")
AssertEqual(#normalized.EntityIds, #disabled.EntityIds, "normalization retains managed ids")
AssertEqual(#normalized.Tombstones, #disabled.Tombstones, "normalization retains tombstones")
Assert(normalized ~= disabled, "normalization copies the scope")
Assert(normalized.EntityIds ~= disabled.EntityIds, "normalization copies entity ids")
Assert(normalized.Tombstones[1] ~= disabled.Tombstones[1], "normalization copies tombstones")
Assert(normalized.CleanupCandidates[1] ~= disabled.CleanupCandidates[1], "normalization copies cleanup candidates")

disabled.EntityIds[1] = "changed"
disabled.Tombstones[1].DeletedBy = "Changed-Realm"
disabled.CleanupCandidates[1].Cause = "absent"
AssertEqual(normalized.EntityIds[1], rootId, "normalized ids do not alias input")
AssertEqual(normalized.Tombstones[1].DeletedBy, "Leader-Realm", "normalized tombstones do not alias input")
AssertEqual(normalized.CleanupCandidates[1].Cause, "tombstone", "normalized candidates do not alias input")

local invalidRecordCases = {
    {
        Name = "unknown field",
        Error = "scope-unknown-field",
        Mutate = function(record)
            record.Future = true
        end,
    },
    {
        Name = "numeric field",
        Error = "scope-unknown-field",
        Mutate = function(record)
            record[1] = true
        end,
    },
    {
        Name = "wrong schema",
        Error = "invalid-scope-schema",
        Mutate = function(record)
            record.Schema = 2
        end,
    },
    {
        Name = "missing enabled",
        Error = "scope-missing-Enabled",
        Mutate = function(record)
            record.Enabled = nil
        end,
    },
    {
        Name = "truthy enabled",
        Error = "invalid-scope-enabled",
        Mutate = function(record)
            record.Enabled = 1
        end,
    },
    {
        Name = "truthy auto cleanup",
        Error = "invalid-scope-auto-cleanup",
        Mutate = function(record)
            record.AutoCleanup = "yes"
        end,
    },
    {
        Name = "page scope",
        Error = "invalid-scope-id",
        Mutate = function(record)
            record.ScopeId = SyncId("page", 1)
        end,
    },
    {
        Name = "zero-padded scope",
        Error = "invalid-scope-id",
        Mutate = function(record)
            record.ScopeId = installationId .. ":category:01"
        end,
    },
    {
        Name = "fractional revision",
        Error = "invalid-scope-revision",
        Mutate = function(record)
            record.ScopeRevision = 1.5
        end,
    },
    {
        Name = "large revision",
        Error = "invalid-scope-revision",
        Mutate = function(record)
            record.ScopeRevision = schema.LIMITS.ScopeRevision + 1
        end,
    },
    {
        Name = "bad sender",
        Error = "invalid-authority-sender",
        Mutate = function(record)
            record.AuthoritySender = "Leader"
        end,
    },
    {
        Name = "bad authority installation",
        Error = "invalid-authority-installation-id",
        Mutate = function(record)
            record.AuthorityInstallationId = "bad"
        end,
    },
    {
        Name = "wrong epoch installation",
        Error = "invalid-authority-epoch",
        Mutate = function(record)
            record.AuthorityEpoch = MessageId(9, otherInstallationId)
        end,
    },
    {
        Name = "bad manifest sequence",
        Error = "invalid-scope-manifest-id",
        Mutate = function(record)
            record.ManifestId = installationId .. ":session_A-1:010"
        end,
    },
    {
        Name = "manifest from another authority session",
        Error = "authority-session-mismatch",
        Mutate = function(record)
            record.ManifestId = installationId .. ":session_B-2:10"
        end,
    },
    {
        Name = "bad manifest hash",
        Error = "invalid-scope-manifest-hash",
        Mutate = function(record)
            record.ManifestHash = "fcs32:ABCDEF12"
        end,
    },
    {
        Name = "negative applied time",
        Error = "invalid-scope-applied-at",
        Mutate = function(record)
            record.AppliedAt = -1
        end,
    },
    {
        Name = "sparse entity ids",
        Error = "scope-entity-ids-sparse-array",
        Mutate = function(record)
            record.EntityIds[3] = record.EntityIds[2]
            record.EntityIds[2] = nil
        end,
    },
    {
        Name = "noncanonical entity id",
        Error = "invalid-scope-entity-id",
        Mutate = function(record)
            record.EntityIds[2] = installationId .. ":page:02"
        end,
    },
    {
        Name = "unsorted entity ids",
        Error = "scope-entity-ids-not-canonical",
        Mutate = function(record)
            record.EntityIds[1], record.EntityIds[2] = record.EntityIds[2], record.EntityIds[1]
        end,
    },
    {
        Name = "missing root",
        Error = "scope-root-not-retained",
        Mutate = function(record)
            record.EntityIds = { pageId }
        end,
    },
    {
        Name = "future tombstone",
        Error = "scope-future-tombstone",
        Mutate = function(record)
            record.Tombstones[1].DeletedScopeRevision = 3
            record.Tombstones[1].RevisionId = assert(schema.BuildTombstoneRevisionId(record.Tombstones[1], TestHash))
        end,
    },
    {
        Name = "entity tombstone collision",
        Error = "scope-entity-tombstone-collision",
        Mutate = function(record)
            record.EntityIds[3] = record.Tombstones[1].SyncId
            table.sort(record.EntityIds)
        end,
    },
    {
        Name = "cleanup entity collision",
        Error = "scope-entity-cleanup-collision",
        Mutate = function(record)
            record.CleanupCandidates[1] = {
                Kind = "page",
                SyncId = pageId,
                Cause = "absent",
                FirstSeenScopeRevision = 2,
            }
        end,
    },
    {
        Name = "unknown cleanup field",
        Error = "scope-cleanup-candidate-unknown-field",
        Mutate = function(record)
            record.CleanupCandidates[1].Future = true
        end,
    },
    {
        Name = "wrong cleanup kind",
        Error = "scope-invalid-cleanup-candidate-kind",
        Mutate = function(record)
            record.CleanupCandidates[1].Kind = "folder"
        end,
    },
    {
        Name = "bad cleanup cause",
        Error = "scope-invalid-cleanup-candidate-cause",
        Mutate = function(record)
            record.CleanupCandidates[1].Cause = "deleted"
        end,
    },
    {
        Name = "future cleanup candidate",
        Error = "scope-invalid-cleanup-candidate-revision",
        Mutate = function(record)
            record.CleanupCandidates[1].FirstSeenScopeRevision = 3
        end,
    },
    {
        Name = "absence with tombstone revision",
        Error = "scope-unexpected-cleanup-tombstone-revision-id",
        Mutate = function(record)
            record.CleanupCandidates[1].Cause = "absent"
        end,
    },
    {
        Name = "unretained cleanup tombstone",
        Error = "cleanup-tombstone-not-retained",
        Mutate = function(record)
            record.Tombstones = {}
        end,
    },
    {
        Name = "mismatched cleanup tombstone",
        Error = "cleanup-tombstone-not-retained",
        Mutate = function(record)
            record.CleanupCandidates[1].TombstoneRevisionId = "fcs32:00000000"
        end,
    },
}

for _, case in ipairs(invalidRecordCases) do
    local invalid = MakeAppliedScope()
    case.Mutate(invalid)
    valid, validationError = scopes.ValidateScopeRecord(invalid, TestHash)
    AssertError(valid, validationError, case.Error, case.Name)
end

local metatableScope = MakeAppliedScope()
setmetatable(metatableScope, {})
valid, validationError = scopes.ValidateScopeRecord(metatableScope, TestHash)
AssertError(valid, validationError, "invalid-scope", "scope metatable")

local missingHash, missingHashError = scopes.ValidateScopeRecord(MakeAppliedScope(), nil)
AssertError(missingHash, missingHashError, "scope-tombstone-invalid-hash-callback", "tombstones require hash")

local noTombstone = MakeAppliedScope({
    Tombstones = {},
    CleanupCandidates = {
        {
            Kind = "page",
            SyncId = SyncId("page", 70, otherInstallationId),
            Cause = "absent",
            FirstSeenScopeRevision = 1,
        },
    },
})
valid, validationError = scopes.ValidateScopeRecord(noTombstone)
Assert(valid and validationError == nil, "scope without tombstones does not need hash callback")

local pendingMetadata = DeepCopy(pending)
pendingMetadata.AuthoritySender = "Leader-Realm"
valid, validationError = scopes.ValidateScopeRecord(pendingMetadata, TestHash)
AssertError(valid, validationError, "pending-scope-has-applied-metadata", "pending authority metadata")

local pendingRecords = DeepCopy(pending)
pendingRecords.EntityIds = { rootId }
valid, validationError = scopes.ValidateScopeRecord(pendingRecords, TestHash)
AssertError(valid, validationError, "pending-scope-has-records", "pending entity claims")

local malformed = MakeAppliedScope({
    Enabled = "yes",
    AutoCleanup = true,
})
normalized, accepted, normalizeError = scopes.NormalizeScopeRecord(malformed, rootId, TestHash)
Assert(normalized and not accepted, "malformed scope has fail-closed replacement")
AssertEqual(normalizeError, "invalid-scope-enabled", "malformed reason retained")
AssertEqual(normalized.Enabled, false, "malformed scope cannot remain enabled")
AssertEqual(normalized.AutoCleanup, false, "malformed scope cannot retain cleanup opt-in")
AssertEqual(normalized.ScopeRevision, 0, "malformed scope loses applied revision")
AssertEqual(#normalized.EntityIds, 0, "malformed scope claims no entities")
AssertEqual(#normalized.Tombstones, 0, "malformed scope retains no tombstones")
AssertEqual(#normalized.CleanupCandidates, 0, "malformed scope retains no cleanup candidates")
AssertEqual(normalized.AuthoritySender, nil, "malformed scope retains no authority")

local otherRootId = SyncId("category", 20, otherInstallationId)
normalized, accepted, normalizeError = scopes.NormalizeScopeRecord(MakeAppliedScope(), otherRootId, TestHash)
Assert(normalized and not accepted, "storage key mismatch has fail-closed replacement")
AssertEqual(normalizeError, "scope-key-mismatch", "storage key mismatch reason")
AssertEqual(normalized.ScopeId, otherRootId, "storage key is the recoverable scope identity")
AssertEqual(#normalized.EntityIds, 0, "storage mismatch claims no entities")

normalized, accepted, normalizeError = scopes.NormalizeScopeRecord({}, nil, TestHash)
AssertError(normalized, normalizeError, "scope-missing-Schema", "unrecoverable malformed scope")
AssertEqual(accepted, false, "unrecoverable record is not accepted")

local managed = scopes.NormalizeManagedScopes({
    [rootId] = true,
    [otherRootId] = false,
    [SyncId("page", 1)] = true,
    [installationId .. ":category:01"] = true,
    future = "yes",
})
AssertEqual(managed[rootId], true, "canonical true managed scope retained")
AssertEqual(managed[otherRootId], nil, "false managed scope removed")
AssertEqual(managed[SyncId("page", 1)], nil, "page managed scope removed")
AssertEqual(managed[installationId .. ":category:01"], nil, "noncanonical managed scope removed")
AssertEqual(managed.future, nil, "nonboolean managed scope removed")

local allowedManaged = scopes.NormalizeManagedScopes({
    [rootId] = true,
    [otherRootId] = true,
}, {
    [otherRootId] = true,
})
AssertEqual(allowedManaged[rootId], nil, "disallowed canonical scope removed")
AssertEqual(allowedManaged[otherRootId], true, "allowed canonical scope retained")

local secondPageId = SyncId("page", 21, otherInstallationId)
local secondScope = MakeAppliedScope({
    ScopeId = otherRootId,
    AuthoritySender = "Other-Realm",
    AuthorityInstallationId = otherInstallationId,
    AuthorityEpoch = MessageId(30, otherInstallationId),
    ManifestId = MessageId(31, otherInstallationId),
    EntityIds = {
        otherRootId,
        secondPageId,
    },
    Tombstones = {},
    CleanupCandidates = {},
})

local staleOnlyId = SyncId("page", 77, otherInstallationId)
local scopeStorage = {
    [rootId] = MakeAppliedScope({
        Enabled = false,
    }),
    [otherRootId] = secondScope,
    bad = MakeAppliedScope(),
}
local entityLocal = {
    [rootId] = {
        OwnedLocally = false,
        Pinned = true,
        ManagedScopes = {
            [rootId] = false,
            bad = true,
        },
    },
    [pageId] = {
        OwnedLocally = false,
        ManagedScopes = {
            [SyncId("category", 88)] = true,
        },
    },
    [secondPageId] = {
        OwnedLocally = false,
        ManagedScopes = {},
    },
    [staleOnlyId] = {
        OwnedLocally = true,
        ManagedScopes = {
            [rootId] = true,
        },
    },
}

local normalizedStorage, normalizedLocal, storageErrors = scopes.NormalizeStorage(scopeStorage, entityLocal, TestHash)
AssertEqual(#storageErrors, 1, "invalid storage key is reported")
AssertEqual(storageErrors[1].Error, "invalid-scope-storage-key", "invalid storage key error")
AssertEqual(normalizedStorage.bad, nil, "invalid storage key is dropped")
AssertEqual(normalizedStorage[rootId].Enabled, false, "valid disabled scope metadata retained")
AssertEqual(normalizedStorage[rootId].ScopeRevision, 2, "disabled scope revision retained")
AssertEqual(normalizedLocal[rootId].Pinned, true, "unrelated local state retained")
AssertEqual(normalizedLocal[rootId].ManagedScopes[rootId], true, "disabled valid scope retains membership")
AssertEqual(normalizedLocal[pageId].ManagedScopes[rootId], true, "first scope membership retained")
AssertEqual(normalizedLocal[secondPageId].ManagedScopes[otherRootId], true, "second scope membership retained")
AssertEqual(
    normalizedLocal[tombstone.SyncId].ManagedScopes[rootId],
    true,
    "cleanup candidate retains managed provenance"
)
AssertEqual(
    normalizedLocal[pageId].ManagedScopes[SyncId("category", 88)],
    nil,
    "stale managed scope membership removed"
)
AssertEqual(normalizedLocal[staleOnlyId].OwnedLocally, true, "retired local ownership retained")
AssertEqual(next(normalizedLocal[staleOnlyId].ManagedScopes), nil, "stale-only membership removed")

local overlappingSecondScope = DeepCopy(secondScope)
overlappingSecondScope.EntityIds = {
    pageId,
    otherRootId,
}
table.sort(overlappingSecondScope.EntityIds)
local overlappingStorage = {
    [rootId] = MakeAppliedScope(),
    [otherRootId] = overlappingSecondScope,
}
normalizedStorage, normalizedLocal, storageErrors = scopes.NormalizeStorage(overlappingStorage, entityLocal, TestHash)
AssertEqual(#storageErrors, 2, "both overlapping scopes are reported")
AssertEqual(storageErrors[1].Error, "overlapping-sync-scope", "first overlap error")
AssertEqual(storageErrors[2].Error, "overlapping-sync-scope", "second overlap error")
AssertEqual(normalizedStorage[rootId].ScopeRevision, 0, "first overlapping scope fails closed")
AssertEqual(normalizedStorage[otherRootId].ScopeRevision, 0, "second overlapping scope fails closed")
AssertEqual(next(normalizedLocal[pageId].ManagedScopes), nil, "overlap claims no managed membership")

local malformedScopeStorage = {
    [rootId] = MakeAppliedScope({
        Enabled = "yes",
        AutoCleanup = true,
        EntityIds = {
            rootId,
            staleOnlyId,
        },
    }),
}
normalizedStorage, normalizedLocal, storageErrors =
    scopes.NormalizeStorage(malformedScopeStorage, entityLocal, TestHash)
AssertEqual(#storageErrors, 1, "malformed scope is reported")
AssertEqual(normalizedStorage[rootId].Enabled, false, "malformed stored scope disabled")
AssertEqual(normalizedStorage[rootId].AutoCleanup, false, "malformed stored cleanup disabled")
AssertEqual(#normalizedStorage[rootId].EntityIds, 0, "malformed stored scope claims no entities")
AssertEqual(next(normalizedLocal[rootId].ManagedScopes), nil, "malformed scope claims no root membership")
AssertEqual(next(normalizedLocal[staleOnlyId].ManagedScopes), nil, "malformed scope claims no stale membership")

normalizedStorage, normalizedLocal, storageErrors = scopes.NormalizeStorage("bad", entityLocal, TestHash)
AssertEqual(next(normalizedStorage), nil, "malformed scope storage resets empty")
AssertEqual(#storageErrors, 1, "malformed scope storage is reported")
AssertEqual(storageErrors[1].Error, "invalid-scope-storage", "malformed storage error")
AssertEqual(next(normalizedLocal[rootId].ManagedScopes), nil, "malformed storage claims no membership")

rawset(_G, "time", function()
    return 2000
end)
AngryAssign_Meta = {
    SchemaVersion = 2,
    InstallationId = installationId,
    NextEntitySequence = 2,
    EntityLocal = entityLocal,
    SyncScopes = scopeStorage,
    Migrations = {},
}

local runtimeScopes, runtimeErrors = AngryEra:NormalizeSyncScopeStorage(TestHash)
AssertEqual(runtimeScopes, AngryAssign_Meta.SyncScopes, "runtime normalization stores scopes")
AssertEqual(#runtimeErrors, 1, "runtime normalization returns diagnostics")
AssertEqual(AngryEra:GetSyncScope(rootId).ScopeId, rootId, "runtime scope lookup")
AssertEqual(AngryEra:GetSyncScope(SyncId("page", 1)), nil, "runtime rejects page scope lookup")

local setOk, setRecord = AngryEra:SetSyncScopeEnabled(rootId, true, TestHash)
Assert(setOk, "runtime enables an existing scope explicitly")
AssertEqual(setRecord.Enabled, true, "runtime enabled state stored")
AssertEqual(setRecord.ScopeRevision, 2, "runtime enable retains metadata")
AssertEqual(#setRecord.EntityIds, 2, "runtime enable retains membership")

setOk, setRecord = AngryEra:SetSyncScopeEnabled(rootId, false, TestHash)
Assert(setOk, "runtime disables an existing scope")
AssertEqual(setRecord.Enabled, false, "runtime disabled state stored")
AssertEqual(setRecord.ScopeRevision, 2, "runtime disable retains metadata")

setOk, setRecord = AngryEra:SetSyncScopeAutoCleanup(rootId, true, TestHash)
Assert(setOk, "runtime explicitly enables cleanup policy")
AssertEqual(setRecord.AutoCleanup, true, "runtime cleanup preference stored")

local setError
setOk, setError = AngryEra:SetSyncScopeEnabled(SyncId("category", 500), true, TestHash)
AssertError(setOk, setError, "unknown-sync-scope", "runtime does not invent arbitrary scopes")
setOk, setError = AngryEra:SetSyncScopeEnabled(rootId, 1, TestHash)
AssertError(setOk, setError, "invalid-scope-enabled", "runtime requires a boolean enabled state")
setOk, setError = AngryEra:SetSyncScopeAutoCleanup(rootId, "yes", TestHash)
AssertError(setOk, setError, "invalid-scope-auto-cleanup", "runtime requires a boolean cleanup state")

AngryAssign_Meta.SyncScopes[rootId].Future = true
setOk, setError = AngryEra:SetSyncScopeEnabled(rootId, true, TestHash)
AssertError(setOk, setError, "scope-unknown-field", "runtime refuses malformed persisted scope")

print(string.format("sync scope tests passed (%d assertions)", assertions))
