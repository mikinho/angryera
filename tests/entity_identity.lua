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

AngryEra:MigrateEntityIdentities()
assert(not AngryEra:IsLocallyOwned(remotePage), "Idempotent migration must not claim a registered remote entity")

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

print("Entity identity tests passed.")
