local AngryEra = {}
local app = { AngryEra = AngryEra }

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/entities.lua"))("AngryEra", app)

local installationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:a:b:c:d"

AngryAssign_Meta = {
    SchemaVersion = 1,
    InstallationId = installationId,
    NextEntitySequence = 0,
    EntityLocal = {},
    SyncScopes = {},
    Migrations = {
        InstallationIdentity = 1,
    },
}

AngryAssign_Categories = {
    [10] = {
        Id = 10,
        Name = "Legacy Category",
        Vars = "MT=Tank",
    },
    [40] = {
        Id = 40,
        Name = "Preserved Identity",
        SyncId = remoteInstallationId .. ":category:7",
        OwnerId = installationId,
    },
}

AngryAssign_Pages = {
    [10] = {
        Id = 10,
        Name = "Same Numeric Id",
        Contents = "Assignments",
        CategoryId = 10,
    },
    [20] = {
        Id = 20,
        Name = "First Duplicate",
        Contents = "First",
        SyncId = installationId .. ":page:9",
        OwnerId = installationId,
    },
    [30] = {
        Id = 30,
        Name = "Second Duplicate",
        Contents = "Second",
        SyncId = installationId .. ":page:9",
        OwnerId = installationId,
    },
}

function _G.time()
    return 1000
end

local nextLocalId = 100
function AngryEra:Hash()
    nextLocalId = nextLocalId + 1
    return nextLocalId
end

AngryEra:MigrateEntityIdentities()

local category = AngryAssign_Categories[10]
local sameIdPage = AngryAssign_Pages[10]
assert(category.SyncId ~= sameIdPage.SyncId, "Pages and categories with the same numeric id need distinct SyncIds")
assert(AngryEra.identity.ValidateSyncId(category.SyncId, "category"), "Migrated category SyncId should validate")
assert(AngryEra.identity.ValidateSyncId(sameIdPage.SyncId, "page"), "Migrated page SyncId should validate")
assert(category.OwnerId == installationId, "Legacy category should receive local owner provenance")
assert(category.Vars == "MT=Tank", "Migration should preserve category fields")
assert(sameIdPage.CategoryId == 10, "Migration should preserve hierarchy fields")
assert(AngryAssign_Pages[20].SyncId == installationId .. ":page:9", "First valid duplicate should be preserved")
assert(AngryAssign_Pages[30].SyncId ~= AngryAssign_Pages[20].SyncId, "Duplicate SyncIds should be repaired")
assert(AngryAssign_Meta.NextEntitySequence > 9, "Migration should advance past preserved local counters")
assert(AngryAssign_Meta.SchemaVersion == 2, "Entity migration should advance the metadata schema")
assert(AngryAssign_Meta.Migrations.EntityIdentity == 2, "Entity migration marker should be written")
assert(
    AngryAssign_Categories[40].OwnerId == remoteInstallationId,
    "Migration should repair owner provenance to the SyncId namespace"
)

for _, records in ipairs({ AngryAssign_Categories, AngryAssign_Pages }) do
    for _, entity in pairs(records) do
        assert(AngryEra:IsLocallyOwned(entity), "All pre-v3 entities should migrate as locally owned")
    end
end

assert(AngryEra:GetCategoryBySyncId(category.SyncId) == category, "Category SyncId lookup should be rebuilt")
assert(AngryEra:GetPageBySyncId(sameIdPage.SyncId) == sameIdPage, "Page SyncId lookup should be rebuilt")

local migratedSyncIds = {
    category.SyncId,
    AngryAssign_Categories[40].SyncId,
    sameIdPage.SyncId,
    AngryAssign_Pages[20].SyncId,
    AngryAssign_Pages[30].SyncId,
}
local migratedSequence = AngryAssign_Meta.NextEntitySequence
AngryEra:MigrateEntityIdentities()
assert(AngryAssign_Meta.NextEntitySequence == migratedSequence, "Identity migration should be idempotent")
assert(category.SyncId == migratedSyncIds[1], "Idempotent migration should retain category identity")
assert(AngryAssign_Categories[40].SyncId == migratedSyncIds[2], "Valid remote provenance should be retained")
assert(sameIdPage.SyncId == migratedSyncIds[3], "Idempotent migration should retain page identity")
assert(AngryAssign_Pages[20].SyncId == migratedSyncIds[4], "Preserved identity should remain stable")
assert(AngryAssign_Pages[30].SyncId == migratedSyncIds[5], "Repaired identity should remain stable")

local highestActiveLocalSequence = 0
for _, records in ipairs({ AngryAssign_Categories, AngryAssign_Pages }) do
    for _, entity in pairs(records) do
        local entityInstallationId, _, sequence = AngryEra.identity.ParseSyncId(entity.SyncId)
        if entityInstallationId == installationId and sequence > highestActiveLocalSequence then
            highestActiveLocalSequence = sequence
        end
    end
end
AngryAssign_Meta.EntityLocal = {}
AngryAssign_Meta.NextEntitySequence = 0
AngryAssign_Meta.EntitySequenceHighWater = 0
AngryEra:MigrateEntityIdentities()
assert(
    AngryAssign_Meta.NextEntitySequence >= highestActiveLocalSequence
        and AngryAssign_Meta.EntitySequenceHighWater >= highestActiveLocalSequence,
    "Migration should rebuild both counters after local metadata is lost"
)

AngryAssign_Meta.EntityLocal[sameIdPage.SyncId] = nil
AngryEra:MigrateEntityIdentities()
assert(
    AngryEra:IsLocallyOwned(sameIdPage),
    "A current-schema local-namespace record should recover missing ownership metadata"
)

local localPage = AngryEra:NewLocalPageRecord({
    Name = "Local Page",
    Contents = "Text",
    SyncId = remoteInstallationId .. ":page:99",
    OwnerId = remoteInstallationId,
})
AngryAssign_Pages[localPage.Id] = localPage
assert(localPage.OwnerId == installationId, "Local factory must ignore imported owner provenance")
assert(localPage.SyncId ~= remoteInstallationId .. ":page:99", "Local factory must allocate a fresh SyncId")
assert(AngryEra:IsLocallyOwned(localPage), "Local factory should establish local ownership")

local originalSyncId = localPage.SyncId
local originalOwnerId = localPage.OwnerId
local replacement = AngryEra:ReplacePageRecord(localPage.Id, {
    Name = "Replaced Page",
    Contents = "Replacement",
})
AngryAssign_Pages[replacement.Id] = replacement
assert(replacement.SyncId == originalSyncId, "Replacement should preserve immutable SyncId")
assert(replacement.OwnerId == originalOwnerId, "Replacement should preserve immutable OwnerId")
assert(AngryEra:IsLocallyOwned(replacement), "Replacement should preserve local metadata")
assert(AngryEra:GetPageBySyncId(originalSyncId) == replacement, "Replacement should refresh runtime lookup")

local remotePage = {
    Id = 900,
    Name = "Remote Page",
    Contents = "Remote",
}
local remoteWireIdentity = {
    SyncId = remoteInstallationId .. ":page:1",
    OwnerId = remoteInstallationId,
    OwnedLocally = true,
    Pinned = true,
}
local registered, registerError = AngryEra:RegisterRemoteEntityIdentity(remotePage, "page", remoteWireIdentity)
assert(registered, registerError)
AngryAssign_Pages[remotePage.Id] = remotePage
assert(not AngryEra:IsLocallyOwned(remotePage), "Remote identity must not accept local ownership from wire data")
assert(not AngryEra:IsPinned(remotePage), "Remote identity must not accept pin state from wire data")

AngryAssign_Meta.EntityLocal[remotePage.SyncId] = nil
AngryEra:MigrateEntityIdentities()
assert(
    not AngryEra:IsLocallyOwned(remotePage),
    "Idempotent migration must not claim a remote entity with missing state"
)
assert(
    AngryEra:GetLocalEntityState(remotePage).OwnedLocally == nil,
    "Missing remote ownership metadata should remain unknown rather than defaulting to remote"
)

local repairedLocalPage = {
    Id = 950,
    Name = "Late Local Page",
    Contents = "Repair me",
}
AngryAssign_Pages[repairedLocalPage.Id] = repairedLocalPage
AngryEra:MigrateEntityIdentities()
assert(repairedLocalPage.SyncId, "A late record with missing identity should be repaired")
assert(AngryEra:IsLocallyOwned(repairedLocalPage), "A repaired local record should fail safe as locally owned")

local claimedOwner = AngryEra:RegisterRemoteEntityIdentity({ Id = 901 }, "page", {
    SyncId = remoteInstallationId .. ":page:2",
    OwnerId = installationId,
})
assert(not claimedOwner, "OwnerId must match the immutable SyncId namespace")

local localNamespaceCollision = AngryEra:RegisterRemoteEntityIdentity({ Id = 902 }, "page", {
    SyncId = installationId .. ":page:999",
    OwnerId = remoteInstallationId,
})
assert(not localNamespaceCollision, "Remote records must not claim this installation's SyncId namespace")

local collision = AngryEra:RegisterRemoteEntityIdentity({ Id = 903 }, "page", {
    SyncId = replacement.SyncId,
    OwnerId = remoteInstallationId,
})
assert(not collision, "Remote identity must not collide with a locally owned SyncId")

assert(AngryEra:SetPinned(remotePage, true), "Remote entities should support a local pin")
assert(AngryEra:IsPinned(remotePage), "Pinning should be stored locally")
assert(remotePage.Pinned == nil, "Pin state must not be written into wire-visible entity data")

AngryEra:RemovePageRecord(remotePage.Id)
assert(AngryAssign_Meta.EntityLocal[remotePage.SyncId] == nil, "Removed remote metadata should be forgotten")

local retiredSyncId = replacement.SyncId
AngryEra:RemovePageRecord(replacement.Id)
assert(AngryAssign_Meta.EntityLocal[retiredSyncId].DeletedLocally, "Removed local identity should remain retired")

AngryAssign_Pages[9001] = 42
AngryAssign_Pages[9002] = "corrupt"
AngryAssign_Categories[9003] = false
local removed = AngryEra:RemoveInvalidEntityRecords()
assert(removed == 3, "invalid saved records should be dropped before migrations run")
assert(
    AngryAssign_Pages[9001] == nil and AngryAssign_Pages[9002] == nil and AngryAssign_Categories[9003] == nil,
    "dropped records must not remain in storage"
)
assert(AngryEra:RemoveInvalidEntityRecords() == 0, "record cleanup should be idempotent")

AngryAssign_Pages[9004] = 7
AngryAssign_Meta.Migrations.EntityIdentity = nil
AngryEra:RemoveInvalidEntityRecords()
AngryEra:MigrateEntityIdentities()
assert(
    AngryAssign_Meta.Migrations.EntityIdentity ~= nil,
    "identity migration should complete after invalid records are removed"
)

do
    local retained = {}
    for index = 1, 4200 do
        local id = installationId .. ":page:" .. (100000 + index)
        AngryAssign_Meta.EntityLocal[id] = {
            OwnedLocally = true,
            DeletedLocally = true,
            DeletedOrdinal = index == 4200 and 1 or index + 1,
            ManagedScopes = {},
        }
        retained[index] = id
    end
    local pinnedTombstone = installationId .. ":page:1"
    AngryAssign_Meta.EntityLocal[pinnedTombstone] =
        { OwnedLocally = true, DeletedLocally = true, DeletedOrdinal = 0, Pinned = true, ManagedScopes = {} }
    local scopedTombstone = installationId .. ":page:2"
    AngryAssign_Meta.EntityLocal[scopedTombstone] =
        { OwnedLocally = true, DeletedLocally = true, DeletedOrdinal = 0, ManagedScopes = { ["scope:1"] = true } }

    AngryAssign_Meta.NextEntitySequence = 0
    local pruned = AngryEra:PruneDeletedLocalIdentities()
    assert(pruned >= 104, "pruning should evict the tombstones beyond the bound")
    assert(
        AngryAssign_Meta.NextEntitySequence >= 104200,
        "Pruning must first repair the entity counter from retained tombstones"
    )

    local remaining = 0
    for _, state in pairs(AngryAssign_Meta.EntityLocal) do
        if type(state) == "table" and state.DeletedLocally and not state.Pinned then
            local managed = type(state.ManagedScopes) == "table" and next(state.ManagedScopes) ~= nil
            if not managed then
                remaining = remaining + 1
            end
        end
    end
    assert(remaining == 4096, "disposable tombstones must be bounded to the cap")
    assert(AngryAssign_Meta.EntityLocal[retained[1]] == nil, "the oldest tombstone should be evicted first")
    assert(
        AngryAssign_Meta.EntityLocal[retained[4200]] == nil,
        "Pruning may remove the highest sequence when it was retired earliest"
    )
    assert(AngryAssign_Meta.EntityLocal[pinnedTombstone] ~= nil, "a pinned tombstone must never be pruned")
    assert(AngryAssign_Meta.EntityLocal[scopedTombstone] ~= nil, "a scope-managed tombstone must never be pruned")
    assert(AngryEra:PruneDeletedLocalIdentities() == 0, "pruning at the bound should be a no-op")

    AngryAssign_Meta.NextEntitySequence = 0
    local nextSyncId = AngryEra:NextSyncId("page")
    local _, _, nextSequence = AngryEra.identity.ParseSyncId(nextSyncId)
    assert(nextSequence > 104200, "A repaired counter must not reissue a pruned retired SyncId")
end

print("Entity identity tests passed.")
