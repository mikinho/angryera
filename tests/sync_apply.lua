local app = {
    AngryEra = {},
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/revisions.lua"))("AngryEra", app)
assert(loadfile("modules/sync/scopes.lua"))("AngryEra", app)
assert(loadfile("modules/sync/snapshot.lua"))("AngryEra", app)
assert(loadfile("modules/sync/apply.lua"))("AngryEra", app)

local schema = app.AngryEra.sync.schema
local snapshot = app.AngryEra.sync.snapshot
local apply = app.AngryEra.sync.apply
local assertions = 0

local function Assert(value, message)
    assertions = assertions + 1
    assert(value, message)
end

local function AssertEqual(actual, expected, message)
    assertions = assertions + 1
    assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function AssertError(nextState, summary, errorCode, expected, message)
    Assert(nextState == nil and summary == nil, message .. " should fail")
    AssertEqual(errorCode, expected, message)
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

local function DeepEqual(left, right, seen)
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return left == right
    end
    seen = seen or {}
    if seen[left] then
        return seen[left] == right
    end
    seen[left] = right
    for key, value in pairs(left) do
        if not DeepEqual(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
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
local senderSessionId = "leader_session"

local function SyncId(kind, sequence, ownerId)
    return string.format("%s:%s:%d", ownerId or remoteInstallationId, kind, sequence)
end

local function MessageId(sequence)
    return string.format("%s:%s:%d", remoteInstallationId, senderSessionId, sequence)
end

local function MakeEntity(kind, sequence, parentSyncId, order, overrides)
    local entity = {
        Kind = kind,
        SyncId = SyncId(kind, sequence),
        OwnerId = remoteInstallationId,
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

local function SortEntities(entities)
    table.sort(entities, function(left, right)
        return left.SyncId < right.SyncId
    end)
    return entities
end

local function MakeInitialManifest()
    local root = MakeEntity("category", 1, nil, 1, { Name = "Molten Core" })
    local child = MakeEntity("category", 2, root.SyncId, 1, { Name = "Bosses" })
    local page = MakeEntity("page", 3, child.SyncId, 1, { Name = "Lucifron" })
    local stale = MakeEntity("page", 4, child.SyncId, 2, { Name = "Magmadar" })
    local missingLater = MakeEntity("page", 5, child.SyncId, 3, { Name = "Gehennas" })
    return {
        Schema = schema.VERSION,
        ScopeId = root.SyncId,
        RootSyncId = root.SyncId,
        ManifestId = MessageId(2),
        AuthorityEpoch = MessageId(1),
        ScopeRevision = 1,
        Entities = SortEntities({ root, child, page, stale, missingLater }),
        Tombstones = {},
    }
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

local function LocalRecord(kind, id, sequence, fields)
    local record = {
        Id = id,
        SyncId = SyncId(kind, sequence, localInstallationId),
        OwnerId = localInstallationId,
        Name = fields.Name,
        Vars = "",
        CategoryId = fields.CategoryId,
        Index = fields.Index,
    }
    if kind == "page" then
        record.Contents = fields.Contents or ""
        record.History = fields.History
    end
    return record
end

local function MakeInitialState(manifest)
    local unrelatedHistory = {
        {
            timestamp = 10,
            content = "unrelated old",
            author = "Local-Realm",
        },
    }
    local localCategory = LocalRecord("category", 900, 90, {
        Name = "Personal",
        Index = 7,
    })
    local localPage = LocalRecord("page", 901, 91, {
        Name = "Notes",
        Index = 11,
        Contents = "private",
        History = unrelatedHistory,
    })
    return {
        InstallationId = localInstallationId,
        Pages = {
            [901] = localPage,
        },
        Categories = {
            [900] = localCategory,
        },
        EntityLocal = {
            [localCategory.SyncId] = {
                OwnedLocally = true,
                Pinned = false,
                ManagedScopes = {},
            },
            [localPage.SyncId] = {
                OwnedLocally = true,
                Pinned = true,
                ManagedScopes = {},
            },
        },
        SyncScopes = {
            [manifest.ScopeId] = PendingScope(manifest.ScopeId),
        },
    }
end

local function Context(receivedAt)
    return {
        Sender = "Leader-Realm",
        SenderInstallationId = remoteInstallationId,
        SenderSessionId = senderSessionId,
        ReceivedAt = receivedAt,
    }
end

local function ManifestHash(manifest)
    return assert(schema.BuildManifestHash(manifest, TestHash))
end

local initialManifest = MakeInitialManifest()
local initialState = MakeInitialState(initialManifest)
local initialStateBefore = DeepCopy(initialState)
local initialStage =
    assert(snapshot.Stage(initialManifest, ManifestHash(initialManifest), initialState, Context(1200), TestHash))
local localIds = {
    [SyncId("category", 1)] = 100,
    [SyncId("category", 2)] = 101,
    [SyncId("page", 3)] = 200,
    [SyncId("page", 4)] = 201,
    [SyncId("page", 5)] = 202,
}

local materialized, summary, applyError =
    apply.BuildNextState(initialState, initialStage, { LocalIds = localIds }, TestHash)
Assert(materialized ~= nil and summary ~= nil and applyError == nil, "initial hierarchy should apply")
Assert(DeepEqual(initialState, initialStateBefore), "successful apply must not mutate current state")
AssertEqual(materialized.Categories[100].Index, 12, "new root appends after top-level pages and categories")
AssertEqual(materialized.Categories[100].CategoryId, nil, "new root is top-level")
AssertEqual(materialized.Categories[101].CategoryId, 100, "child category maps ParentSyncId")
AssertEqual(materialized.Categories[101].Index, 1, "child category maps wire order")
AssertEqual(materialized.Pages[200].CategoryId, 101, "page maps ParentSyncId")
AssertEqual(materialized.Pages[201].Index, 2, "page maps wire order")
AssertEqual(materialized.Pages[200].UpdateId, materialized.Pages[200].RevisionId, "compatibility hash follows revision")
AssertEqual(materialized.Pages[200].Updated, materialized.Pages[200].UpdatedAt, "compatibility time follows revision")
Assert(materialized.Pages[200].CatVars == nil, "legacy inherited variables are not retained")
Assert(materialized.Pages[901] ~= initialState.Pages[901], "unrelated records are detached")
Assert(materialized.Pages[901].History ~= initialState.Pages[901].History, "unrelated local record history is detached")
AssertEqual(materialized.Pages[901].Contents, "private", "unrelated page is preserved")
AssertEqual(materialized.EntityLocal[SyncId("page", 3)].OwnedLocally, false, "remote provenance is local-only")
AssertEqual(materialized.EntityLocal[SyncId("page", 3)].Pinned, false, "new remote pin defaults false")
Assert(
    materialized.EntityLocal[SyncId("page", 3)].ManagedScopes[initialManifest.ScopeId],
    "incoming page records managed scope"
)
AssertEqual(materialized.SyncScopes[initialManifest.ScopeId].AuthoritySender, "Leader-Realm", "scope authority commits")
AssertEqual(materialized.SyncScopes[initialManifest.ScopeId].AppliedAt, 1200, "scope metadata commits received time")
AssertEqual(#summary.Created.Categories, 2, "category creation summary")
AssertEqual(#summary.Created.Pages, 3, "page creation summary")
Assert(summary.ChangedSyncIds[SyncId("page", 3)], "changed set includes created page")
Assert(summary.SelectedDirtyConflict == nil, "clean initial apply has no editor conflict")

initialState.Pages[901].History[1].content = "mutated input"
initialStage.Manifest.Entities[1].Name = "mutated stage"
AssertEqual(materialized.Pages[901].History[1].content, "unrelated old", "later input mutation cannot alias output")
Assert(materialized.Categories[100].Name ~= "mutated stage", "later staged mutation cannot alias output")

local nextInput = DeepCopy(materialized)
nextInput.Categories[100].CategoryId = 900
nextInput.Categories[100].Index = 4.5
nextInput.Pages[200].Backup = "manual backup"
nextInput.Pages[200].UpdateId = "legacy-stale"
nextInput.Pages[200].Updated = 1
nextInput.Pages[200].History = {}
for index = 1, 10 do
    nextInput.Pages[200].History[index] = {
        timestamp = 100 - index,
        content = "history " .. index,
        author = "Old-Realm",
    }
end
nextInput.EntityLocal[SyncId("page", 3)].Pinned = true
nextInput.Pages[202] = nil
nextInput.EntityLocal[SyncId("page", 5)] = nil

local nextManifest = DeepCopy(initialManifest)
nextManifest.ScopeRevision = 2
nextManifest.ManifestId = MessageId(3)
nextManifest.Entities = {}
for _, entity in ipairs(initialManifest.Entities) do
    if entity.SyncId ~= SyncId("page", 4) and entity.SyncId ~= SyncId("page", 5) then
        local nextEntity = DeepCopy(entity)
        if nextEntity.SyncId == SyncId("page", 3) then
            nextEntity.Revision = 2
            nextEntity.UpdatedAt = 1300
            nextEntity.Contents = "Tank: New Player"
            nextEntity.RevisionId = assert(schema.BuildEntityRevisionId(nextEntity, TestHash))
        end
        nextManifest.Entities[#nextManifest.Entities + 1] = nextEntity
    end
end
SortEntities(nextManifest.Entities)

local nextStage = assert(snapshot.Stage(nextManifest, ManifestHash(nextManifest), nextInput, Context(1400), TestHash))
local nextInputBefore = DeepCopy(nextInput)
local updated, updateSummary, updateError = apply.BuildNextState(nextInput, nextStage, {
    Editor = {
        SelectedPageId = 200,
        Dirty = true,
    },
}, TestHash)
Assert(updated ~= nil and updateSummary ~= nil and updateError == nil, "newer snapshot should apply")
Assert(DeepEqual(nextInput, nextInputBefore), "newer apply must not mutate current state")
AssertEqual(updated.Categories[100].CategoryId, 900, "existing root parent overlay is preserved")
AssertEqual(updated.Categories[100].Index, 4.5, "existing root order overlay is preserved")
AssertEqual(updated.Pages[200].Contents, "Tank: New Player", "incoming stored revision is applied")
AssertEqual(updated.Pages[200].Backup, "manual backup", "manual backup is preserved")
AssertEqual(updated.Pages[200].UpdateId, updated.Pages[200].RevisionId, "stale compatibility hash is replaced")
AssertEqual(updated.Pages[200].Updated, 1300, "stale compatibility timestamp is replaced")
AssertEqual(#updated.Pages[200].History, 10, "automatic history stays bounded")
AssertEqual(updated.Pages[200].History[1].content, "Tank: Player", "previous stored content enters history")
AssertEqual(updated.Pages[200].History[1].author, "Leader-Realm", "history uses staged sender")
AssertEqual(updated.Pages[200].History[1].timestamp, 1400, "history uses staged receive time")
Assert(updated.Pages[200].History ~= nextInput.Pages[200].History, "updated page history cannot alias current state")
Assert(updated.EntityLocal[SyncId("page", 3)].Pinned, "existing local pin is preserved")
Assert(updated.Pages[201] ~= nil, "present stale candidate is retained without deletion")
Assert(updated.Pages[202] == nil, "already missing candidate is not fabricated")
Assert(
    updated.EntityLocal[SyncId("page", 4)].ManagedScopes[initialManifest.ScopeId],
    "retained stale record keeps provenance"
)
Assert(
    updated.EntityLocal[SyncId("page", 5)].ManagedScopes[initialManifest.ScopeId],
    "missing stale record receives provenance"
)
AssertEqual(#updated.SyncScopes[initialManifest.ScopeId].CleanupCandidates, 2, "cleanup preview commits")
AssertEqual(updated.SyncScopes[initialManifest.ScopeId].ScopeRevision, 2, "scope commits after entity work")
AssertEqual(#updateSummary.Updated.Pages, 1, "only changed stored page is summarized")
Assert(updateSummary.ChangedSyncIds[SyncId("page", 3)], "changed set includes updated page")
Assert(updateSummary.SelectedDirtyConflict ~= nil, "dirty selected page surfaces conflict")
AssertEqual(updateSummary.SelectedDirtyConflict.IncomingRevision, 2, "conflict reports incoming revision")
Assert(updateSummary.SelectedDirtyConflict.PreserveDraft, "conflict tells runtime to preserve draft")
Assert(updated.Editor == nil, "runtime editor state is never persisted")

local updatedForNoOp = DeepCopy(updated)
updated.SyncScopes[initialManifest.ScopeId].CleanupCandidates[1].Cause = "mutated output"
Assert(
    updateSummary.CleanupCandidates[1].Cause ~= "mutated output",
    "summary cleanup candidates do not alias next state"
)

local noOpStage =
    assert(snapshot.Stage(nextManifest, ManifestHash(nextManifest), updatedForNoOp, Context(1600), TestHash))
Assert(noOpStage.NoOp, "exact materialized snapshot stages as no-op")
local noOpState, noOpSummary, noOpError = apply.BuildNextState(updatedForNoOp, noOpStage, nil, TestHash)
Assert(noOpState ~= nil and noOpSummary ~= nil and noOpError == nil, "no-op apply succeeds")
Assert(noOpSummary.NoOp and not noOpSummary.Applied, "no-op summary avoids a commit")
AssertEqual(
    noOpState.SyncScopes[initialManifest.ScopeId].AppliedAt,
    updatedForNoOp.SyncScopes[initialManifest.ScopeId].AppliedAt,
    "no-op does not rewrite applied time"
)
Assert(noOpState.Pages[200] ~= updatedForNoOp.Pages[200], "no-op output remains detached")

local collisionState = MakeInitialState(initialManifest)
local collisionStage =
    assert(snapshot.Stage(initialManifest, ManifestHash(initialManifest), collisionState, Context(1200), TestHash))
local invalidState, invalidSummary, invalidError = apply.BuildNextState(collisionState, collisionStage, {
    LocalIds = {
        [initialManifest.RootSyncId] = 900,
    },
}, TestHash)
AssertError(invalidState, invalidSummary, invalidError, "local-id-allocation-collision", "caller allocation collision")

local duplicateAllocationState = MakeInitialState(initialManifest)
local duplicateAllocationStage = assert(
    snapshot.Stage(initialManifest, ManifestHash(initialManifest), duplicateAllocationState, Context(1200), TestHash)
)
invalidState, invalidSummary, invalidError = apply.BuildNextState(duplicateAllocationState, duplicateAllocationStage, {
    LocalIds = {
        [SyncId("category", 1)] = 100,
        [SyncId("category", 2)] = 100,
    },
}, TestHash)
AssertError(invalidState, invalidSummary, invalidError, "local-id-allocation-collision", "duplicate caller allocations")

local fallbackState = MakeInitialState(initialManifest)
local fallbackStage =
    assert(snapshot.Stage(initialManifest, ManifestHash(initialManifest), fallbackState, Context(1200), TestHash))
local fallbackApplied, fallbackSummary, fallbackError =
    apply.BuildNextState(fallbackState, fallbackStage, nil, TestHash)
Assert(fallbackApplied ~= nil and fallbackSummary ~= nil and fallbackError == nil, "fallback allocation should apply")
AssertEqual(fallbackSummary.RootLocalId, 1, "fallback allocation uses lowest free category id")
AssertEqual(fallbackApplied.Categories[2].CategoryId, 1, "fallback reserves each category allocation")
AssertEqual(fallbackApplied.Pages[1].CategoryId, 2, "page ids use an independent local namespace")
Assert(fallbackApplied.Pages[2] ~= nil and fallbackApplied.Pages[3] ~= nil, "fallback reserves each page allocation")

local tamperedStage = DeepCopy(fallbackStage)
tamperedStage.EntityIds[1] = tamperedStage.EntityIds[2]
local fallbackBeforeTamper = DeepCopy(fallbackState)
invalidState, invalidSummary, invalidError = apply.BuildNextState(fallbackState, tamperedStage, nil, TestHash)
AssertError(invalidState, invalidSummary, invalidError, "staged-plan-mismatch", "tampered staged membership")
Assert(DeepEqual(fallbackState, fallbackBeforeTamper), "failed staged-plan validation leaves current state untouched")

local directCycleState = DeepCopy(nextInput)
directCycleState.Categories[100].CategoryId = 101
local directCycleStage =
    assert(snapshot.Stage(nextManifest, ManifestHash(nextManifest), directCycleState, Context(1400), TestHash))
invalidState, invalidSummary, invalidError = apply.BuildNextState(directCycleState, directCycleStage, nil, TestHash)
AssertError(invalidState, invalidSummary, invalidError, "root-placement-inside-scope", "root overlay direct cycle")

local indirectCycleState = DeepCopy(nextInput)
indirectCycleState.Categories[900].CategoryId = 101
local indirectCycleStage =
    assert(snapshot.Stage(nextManifest, ManifestHash(nextManifest), indirectCycleState, Context(1400), TestHash))
invalidState, invalidSummary, invalidError = apply.BuildNextState(indirectCycleState, indirectCycleStage, nil, TestHash)
AssertError(invalidState, invalidSummary, invalidError, "root-placement-inside-scope", "root overlay indirect cycle")

local externalCycleState = DeepCopy(nextInput)
externalCycleState.Categories[902] = LocalRecord("category", 902, 92, {
    Name = "Cyclic",
    CategoryId = 900,
    Index = 1,
})
externalCycleState.Categories[900].CategoryId = 902
local externalCycleStage =
    assert(snapshot.Stage(nextManifest, ManifestHash(nextManifest), externalCycleState, Context(1400), TestHash))
invalidState, invalidSummary, invalidError = apply.BuildNextState(externalCycleState, externalCycleStage, nil, TestHash)
AssertError(invalidState, invalidSummary, invalidError, "root-placement-cycle", "preexisting root ancestor cycle")

print(string.format("Synchronization apply tests passed (%d assertions).", assertions))
