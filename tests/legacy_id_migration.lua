local helpers = {
    PlayerFullName = function()
        return "Viewer-Realm"
    end,
}

local AngryEra = {
    utils = {
        helpers = helpers,
    },
}
local app = {
    AngryEra = AngryEra,
    libs = {},
}

function _G.time()
    return 1000
end

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/entities.lua"))("AngryEra", app)

local localInstallationId = "ae3i:1:2:3:4"
local rootCategorySyncId = localInstallationId .. ":category:1"
local nestedCategorySyncId = localInstallationId .. ":category:2"
local pageSyncId = localInstallationId .. ":page:3"
local rootPageSyncId = localInstallationId .. ":page:4"
local lowHashPageSyncId = localInstallationId .. ":page:5"

_G.AngryAssign_Meta = {
    SchemaVersion = 1,
    InstallationId = localInstallationId,
    EntityCounter = 10,
    NextEntitySequence = 10,
    Migrations = {},
    EntityLocal = {},
    SyncScopes = {},
}
_G.AngryAssign_Categories = {
    [4025479151] = {
        Id = 4025479151,
        Name = "Naxxramas",
        SyncId = rootCategorySyncId,
        OwnerId = localInstallationId,
    },
    [2999999999] = {
        Id = 2999999999,
        Name = "Military Quarter",
        SyncId = nestedCategorySyncId,
        OwnerId = localInstallationId,
        CategoryId = 4025479151,
    },
}
_G.AngryAssign_Pages = {
    [3221957842] = {
        Id = 3221957842,
        Name = "Patchwerk",
        SyncId = pageSyncId,
        OwnerId = localInstallationId,
        CategoryId = 2999999999,
        Contents = "body",
    },
    [2147500000] = {
        Id = 2147500000,
        Name = "Root Page",
        SyncId = rootPageSyncId,
        OwnerId = localInstallationId,
        Contents = "root",
    },
    [999999] = {
        Id = 999999,
        Name = "Low Hash",
        SyncId = lowHashPageSyncId,
        OwnerId = localInstallationId,
        CategoryId = 4025479151,
        Contents = "low",
    },
}
_G.AngryAssign_State = {
    displayed = 3221957842,
    tree = {
        selected = "-4025479151\001-2999999999\0013221957842",
        groups = {
            [-4025479151] = true,
            ["-4025479151\001-2999999999"] = true,
            [4025479151] = true,
            [-12] = true,
        },
    },
}

local migrated = AngryEra:MigrateLegacyLocalIds()
assert(migrated == 5, "all pre-sequential ids should normalize, got " .. tostring(migrated))

assert(AngryAssign_Pages[3221957842] == nil, "hashed page keys should be removed")
assert(AngryAssign_Categories[4025479151] == nil, "hashed category keys should be removed")

local patchwerk
local lowHashPage
for id, page in pairs(AngryAssign_Pages) do
    assert(id <= 3, "page ids should form a compact sequential range")
    assert(page.Id == id, "page records should carry their new id")
    if page.Name == "Patchwerk" then
        patchwerk = page
    end
    if page.Name == "Low Hash" then
        lowHashPage = page
    end
end
assert(patchwerk, "migrated pages should survive")
assert(lowHashPage and lowHashPage.Id ~= 999999, "low-valued FCS32 ids should also normalize")

local rootCategory
local nestedCategory
for id, category in pairs(AngryAssign_Categories) do
    assert(id <= 2, "category ids should form a compact sequential range")
    assert(category.Id == id, "category records should carry their new id")
    if category.Name == "Naxxramas" then
        rootCategory = category
    end
    if category.Name == "Military Quarter" then
        nestedCategory = category
    end
end
assert(rootCategory and nestedCategory, "migrated categories should survive")
assert(nestedCategory.CategoryId == rootCategory.Id, "nested parent references should be rewritten")
assert(patchwerk.CategoryId == nestedCategory.Id, "page parent references should be rewritten")
assert(lowHashPage.CategoryId == rootCategory.Id, "low-hash pages should follow migrated parents")

assert(AngryAssign_State.displayed == patchwerk.Id, "the displayed page id should be rewritten")
local expectedSelected =
    table.concat({ "-" .. rootCategory.Id, "-" .. nestedCategory.Id, tostring(patchwerk.Id) }, "\001")
assert(AngryAssign_State.tree.selected == expectedSelected, "tree selection paths should be rewritten")
assert(AngryAssign_State.tree.groups[-rootCategory.Id] == true, "numeric group keys should be rewritten")
assert(
    AngryAssign_State.tree.groups["-" .. rootCategory.Id .. "\001-" .. nestedCategory.Id] == true,
    "group path keys should be rewritten"
)
assert(AngryAssign_State.tree.groups[rootCategory.Id] == true, "positive legacy category keys should be rewritten")
assert(AngryAssign_State.tree.groups[-12] == true, "unknown keys should be preserved")
assert(AngryAssign_Meta.Migrations.SequentialLocalIds == 1, "the durable migration marker should be written last")

assert(AngryEra:MigrateLegacyLocalIds() == 0, "the migration should be idempotent")

local allocated = AngryEra:AllocateLocalEntityId("page")
assert(AngryAssign_Pages[allocated] == nil, "allocation should return a free id")
assert(allocated <= 1000000, "new ids should be sequential, got " .. tostring(allocated))

local created = AngryEra:NewLocalPageRecord({ Name = "Fresh", Contents = "" })
assert(created.Id <= 1000000, "new records should receive sequential ids")
assert(type(created.SyncId) == "string", "new records should receive identities")

-- Positive tree selection values are pages even when a category shared the
-- same legacy numeric id and moves to a different destination.
local collidingId = 2000000
_G.AngryAssign_Meta = {
    InstallationId = localInstallationId,
    Migrations = {},
}
_G.AngryAssign_Categories = {
    [1] = { Id = 1, SyncId = localInstallationId .. ":category:10" },
    [collidingId] = { Id = collidingId, SyncId = localInstallationId .. ":category:11" },
}
_G.AngryAssign_Pages = {
    [collidingId] = { Id = collidingId, SyncId = localInstallationId .. ":page:12" },
}
_G.AngryAssign_State = {
    displayed = collidingId,
    tree = {
        selected = collidingId,
        groups = {},
    },
}

assert(AngryEra:MigrateLegacyLocalIds() == 2, "cross-kind collisions should normalize")
local selectedPage = AngryAssign_Pages[AngryAssign_State.tree.selected]
assert(selectedPage ~= nil, "positive selection should follow the remapped page")
assert(AngryAssign_State.displayed == selectedPage.Id, "displayed and selected should retain the same page")
assert(
    AngryAssign_Categories[AngryAssign_State.tree.selected] ~= nil,
    "the regression should keep a distinct category at the page's new numeric id"
)
assert(
    AngryAssign_Categories[2] and AngryAssign_Categories[2].SyncId:find(":category:11", 1, true),
    "the colliding category should move independently"
)

-- Dangling parent references are reserved so normalization cannot turn an
-- orphan into an unrelated attachment or self-cycle.
_G.AngryAssign_Meta = {
    InstallationId = localInstallationId,
    Migrations = {},
}
_G.AngryAssign_Categories = {
    [3000000] = {
        Id = 3000000,
        SyncId = localInstallationId .. ":category:20",
        CategoryId = 1,
    },
}
_G.AngryAssign_Pages = {
    [4000000] = {
        Id = 4000000,
        SyncId = localInstallationId .. ":page:21",
        CategoryId = 1,
    },
}
_G.AngryAssign_State = {
    tree = {
        groups = {
            [-2] = false,
        },
    },
}

assert(AngryEra:MigrateLegacyLocalIds() == 2, "dangling-parent records should normalize")
assert(
    AngryAssign_Categories[1] == nil and AngryAssign_Categories[2] == nil,
    "reserved category ids should stay unbound"
)
assert(AngryAssign_Categories[3].CategoryId == 1, "a dangling category parent must not become a self-cycle")
assert(AngryAssign_Pages[1].CategoryId == 1, "a dangling page parent must not attach to a migrated category")
assert(AngryAssign_State.tree.groups[-2] == false, "stale group state should not bind to a migrated category")
assert(AngryEra:AllocateLocalEntityId("category") == 4, "category allocation should reserve dangling references")

-- Dangling persisted UI ids stay reserved instead of silently binding to a
-- migrated or newly allocated entity.
_G.AngryAssign_Meta = {
    InstallationId = localInstallationId,
    Migrations = {},
}
_G.AngryAssign_Categories = {
    [3000000] = { Id = 3000000, SyncId = localInstallationId .. ":category:30" },
}
_G.AngryAssign_Pages = {
    [4000000] = {
        Id = 4000000,
        SyncId = localInstallationId .. ":page:31",
        CategoryId = 3000000,
    },
}
_G.AngryAssign_State = {
    displayed = 1,
    tree = {
        selected = "-1\0011",
        groups = {},
    },
}

assert(AngryEra:MigrateLegacyLocalIds() == 2, "records should normalize around dangling state")
assert(AngryAssign_Pages[1] == nil and AngryAssign_Categories[1] == nil, "dangling ids should remain unbound")
assert(AngryAssign_State.displayed == 1, "a dangling displayed id should remain distinguishable")
assert(AngryAssign_State.tree.selected == "-1\0011", "a dangling selection path should remain distinguishable")
assert(AngryAssign_Pages[2].CategoryId == 2, "parent references should follow reserved-id normalization")
assert(AngryEra:AllocateLocalEntityId("page") == 3, "page allocation should reserve dangling selection state")
assert(AngryEra:AllocateLocalEntityId("category") == 3, "category allocation should reserve dangling selection state")
assert(AngryEra:MigrateLegacyLocalIds() == 0, "reserved-id normalization should be idempotent")

-- A stored group path may end in a positive page id; that value must not be
-- mistaken for a category reservation.
_G.AngryAssign_Categories = {}
for id = 1, 9 do
    AngryAssign_Categories[id] = { Id = id }
end
_G.AngryAssign_Pages = {
    [10] = { Id = 10 },
}
_G.AngryAssign_State = {
    tree = {
        groups = {
            ["-1\00110"] = true,
        },
    },
}
assert(AngryEra:AllocateLocalEntityId("category") == 10, "page path terminals should not reserve category ids")

print("Legacy id migration tests passed.")
