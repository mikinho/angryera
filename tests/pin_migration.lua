-- Guards the one-time migration that introduces local category pins.

local AngryEra = {}
local app = { AngryEra = AngryEra }

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/entities.lua"))("AngryEra", app)

local localInstallationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:a:b:c:d"

function _G.time()
    return 1000
end

local function AssertEqual(actual, expected, message)
    assert(actual == expected, ("%s: expected %s, got %s"):format(message, tostring(expected), tostring(actual)))
end

local function Reset(marker)
    AngryAssign_Meta = {
        SchemaVersion = 2,
        InstallationId = localInstallationId,
        NextEntitySequence = 100,
        EntitySequenceHighWater = 100,
        EntityLocal = {},
        SyncScopes = {},
        Migrations = {
            InstallationIdentity = 1,
            EntityIdentity = 2,
            SequentialLocalIds = 1,
            OwnedCategoryPins = marker,
        },
    }
    AngryAssign_Categories = {}
    AngryAssign_Pages = {}
    AngryAssign_State = { displayed = nil }
    AngryEra.entitySyncIndexes = nil
end

local function AddCategory(id, options)
    options = options or {}
    local ownerId = options.OwnerId or localInstallationId
    local category = {
        Id = id,
        Name = options.Name or ("Category " .. id),
        CategoryId = options.CategoryId,
        SyncId = options.SyncId or ("%s:category:%d"):format(ownerId, id),
        OwnerId = ownerId,
    }
    AngryAssign_Categories[id] = category

    if options.RegisterState ~= false then
        AngryAssign_Meta.EntityLocal[category.SyncId] = {
            OwnedLocally = options.OwnedLocally ~= false,
            Pinned = options.Pinned == true,
            ManagedScopes = {},
        }
    end
    return category
end

local function AddPage(id, pinned)
    local page = {
        Id = id,
        Name = "Page " .. id,
        Contents = "",
        SyncId = ("%s:page:%d"):format(localInstallationId, id),
        OwnerId = localInstallationId,
    }
    AngryAssign_Pages[id] = page
    AngryAssign_Meta.EntityLocal[page.SyncId] = {
        OwnedLocally = true,
        Pinned = pinned == true,
        ManagedScopes = {},
    }
    return page
end

-- A normal migration pins only the highest category in each contiguous
-- locally-owned branch. Remote categories are not pinned, but a local branch
-- beginning immediately below a coherent remote parent is.
Reset()
local localRoot = AddCategory(1)
local nestedLocal = AddCategory(2, { CategoryId = localRoot.Id })
local remoteRoot = AddCategory(3, {
    OwnerId = remoteInstallationId,
    OwnedLocally = false,
})
local localUnderRemote = AddCategory(4, { CategoryId = remoteRoot.Id })
local nestedUnderLocal = AddCategory(5, { CategoryId = localUnderRemote.Id })
local missingParent = AddCategory(6, { CategoryId = 999 })
local cyclicLocal = AddCategory(7, { CategoryId = 8 })
local cyclicRemote = AddCategory(8, {
    CategoryId = cyclicLocal.Id,
    OwnerId = remoteInstallationId,
    OwnedLocally = false,
})
local unknownRemoteParent = AddCategory(9, {
    OwnerId = remoteInstallationId,
    OwnedLocally = false,
    RegisterState = false,
})
local localUnderUnknown = AddCategory(10, { CategoryId = unknownRemoteParent.Id })
local unpinnedPage = AddPage(1, false)

local migrated = AngryEra:MigrateOwnedCategoryPins()
AssertEqual(migrated, 2, "normal migration should pin the two eligible local branch roots")
assert(AngryEra:IsPinned(localRoot), "a locally owned root category should be pinned")
assert(not AngryEra:IsPinned(nestedLocal), "a nested local category should not be redundantly pinned")
assert(not AngryEra:IsPinned(remoteRoot), "an explicitly remote root category should not be pinned")
assert(AngryEra:IsPinned(localUnderRemote), "a local branch below an explicit remote parent should be pinned")
assert(not AngryEra:IsPinned(nestedUnderLocal), "a nested local descendant should remain unpinned")
assert(not AngryEra:IsPinned(missingParent), "a category with a missing parent should fail closed")
assert(not AngryEra:IsPinned(cyclicLocal), "a local category in a cyclic hierarchy should fail closed")
assert(not AngryEra:IsPinned(cyclicRemote), "a remote category in a cyclic hierarchy should remain unpinned")
assert(
    not AngryEra:IsPinned(localUnderUnknown),
    "a local category below a parent of unknown provenance should fail closed"
)
assert(not AngryEra:IsPinned(unpinnedPage), "the category migration should not change page pin state")
AssertEqual(AngryAssign_Meta.Migrations.OwnedCategoryPins, 1, "normal migration should write its durable marker")

assert(AngryEra:SetPinned(localRoot, false), "the fixture should be able to model a later intentional unpin")
AssertEqual(AngryEra:MigrateOwnedCategoryPins(), 0, "the durable marker should make normal migration idempotent")
assert(not AngryEra:IsPinned(localRoot), "normal migration should not undo an intentional post-migration unpin")
assert(AngryEra:IsPinned(localUnderRemote), "idempotence should not disturb an existing category pin")

-- Any live pre-existing pin indicates that the user has already organized the
-- library. Normal migration records completion without adding automatic pins.
Reset()
local skippedRoot = AddCategory(20)
local existingPagePin = AddPage(20, true)
AssertEqual(AngryEra:MigrateOwnedCategoryPins(), 0, "a live pre-existing pin should suppress normal auto-pinning")
assert(not AngryEra:IsPinned(skippedRoot), "normal migration should preserve a beta user's existing organization")
assert(AngryEra:IsPinned(existingPagePin), "normal migration should leave an existing page pin untouched")
AssertEqual(
    AngryAssign_Meta.Migrations.OwnedCategoryPins,
    1,
    "a pre-existing live pin should still complete the one-time migration"
)

-- Retired local-state tombstones are not visible library pins and must not
-- suppress migration of the current library.
Reset()
local tombstoneRoot = AddCategory(30)
local tombstoneSyncId = localInstallationId .. ":category:99"
AngryAssign_Meta.EntityLocal[tombstoneSyncId] = {
    OwnedLocally = true,
    Pinned = true,
    DeletedLocally = true,
    DeletedOrdinal = 1,
    ManagedScopes = {},
}
AssertEqual(AngryEra:MigrateOwnedCategoryPins(), 1, "a pinned tombstone should not count as a live existing pin")
assert(AngryEra:IsPinned(tombstoneRoot), "a pinned tombstone should not block an eligible live category")
assert(AngryAssign_Meta.EntityLocal[tombstoneSyncId].Pinned, "migration should not mutate a pinned tombstone")

-- The tester command uses force mode. It bypasses both the marker and the
-- existing-pin safeguard while remaining additive and idempotent.
Reset(1)
local forcedRoot = AddCategory(40)
local forcedNested = AddCategory(41, { CategoryId = forcedRoot.Id })
local forcedPinnedPage = AddPage(40, true)
local forcedUnpinnedPage = AddPage(41, false)
AssertEqual(AngryEra:MigrateOwnedCategoryPins(true), 1, "force mode should bypass marker and live-pin safeguards")
assert(AngryEra:IsPinned(forcedRoot), "force mode should pin an eligible category")
assert(not AngryEra:IsPinned(forcedNested), "force mode should still exclude nested local categories")
assert(AngryEra:IsPinned(forcedPinnedPage), "force mode should preserve existing page pins")
assert(not AngryEra:IsPinned(forcedUnpinnedPage), "force mode should not create page pins")
AssertEqual(AngryEra:MigrateOwnedCategoryPins(true), 0, "repeated force mode should be a no-op")
AssertEqual(AngryAssign_Meta.Migrations.OwnedCategoryPins, 1, "force mode should retain the migration marker")

-- Empty installations are marked immediately so categories created later are
-- not unexpectedly auto-pinned.
Reset()
AssertEqual(AngryEra:MigrateOwnedCategoryPins(), 0, "an empty installation should require no pin changes")
AssertEqual(AngryAssign_Meta.Migrations.OwnedCategoryPins, 1, "an empty installation should still be marked")
local postMigrationRoot = AddCategory(50)
AssertEqual(AngryEra:MigrateOwnedCategoryPins(), 0, "later categories should not reactivate the migration")
assert(not AngryEra:IsPinned(postMigrationRoot), "a category created after migration should remain manually pinnable")

-- A newer marker belongs to newer code and must never be downgraded. Normal
-- mode skips it; force mode may add pins but still preserves the marker value.
Reset(7)
local newerMarkerRoot = AddCategory(60)
AssertEqual(AngryEra:MigrateOwnedCategoryPins(), 0, "normal mode should honor a newer migration marker")
assert(not AngryEra:IsPinned(newerMarkerRoot), "a newer marker should suppress normal migration")
AssertEqual(AngryAssign_Meta.Migrations.OwnedCategoryPins, 7, "normal mode should not downgrade a newer marker")
AssertEqual(AngryEra:MigrateOwnedCategoryPins(true), 1, "force mode should remain available with a newer marker")
assert(AngryEra:IsPinned(newerMarkerRoot), "force mode should pin the eligible category")
AssertEqual(AngryAssign_Meta.Migrations.OwnedCategoryPins, 7, "force mode should not downgrade a newer marker")

print("Owned category pin migration tests passed.")
