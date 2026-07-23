local function TestHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

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
local keptPageSyncId = localInstallationId .. ":page:5"

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
    [7] = {
        Id = 7,
        Name = "Kept",
        SyncId = keptPageSyncId,
        OwnerId = localInstallationId,
        CategoryId = 4025479151,
        Contents = "kept",
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
assert(migrated == 4, "all hashed ids should migrate, got " .. tostring(migrated))

assert(AngryAssign_Pages[3221957842] == nil, "hashed page keys should be removed")
assert(AngryAssign_Categories[4025479151] == nil, "hashed category keys should be removed")

local patchwerk
for id, page in pairs(AngryAssign_Pages) do
    assert(id <= 1000000, "no page id should stay above the legacy threshold")
    assert(page.Id == id, "page records should carry their new id")
    if page.Name == "Patchwerk" then
        patchwerk = page
    end
end
assert(patchwerk, "migrated pages should survive")
assert(AngryAssign_Pages[7].Name == "Kept", "small ids should be preserved")

local rootCategory
local nestedCategory
for id, category in pairs(AngryAssign_Categories) do
    assert(id <= 1000000, "no category id should stay above the legacy threshold")
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
assert(AngryAssign_Pages[7].CategoryId == rootCategory.Id, "kept pages should follow migrated parents")

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

assert(AngryEra:MigrateLegacyLocalIds() == 0, "the migration should be idempotent")

local allocated = AngryEra:AllocateLocalEntityId("page")
assert(AngryAssign_Pages[allocated] == nil, "allocation should return a free id")
assert(allocated <= 1000000, "new ids should be sequential, got " .. tostring(allocated))

local created = AngryEra:NewLocalPageRecord({ Name = "Fresh", Contents = "" })
assert(created.Id <= 1000000, "new records should receive sequential ids")
assert(type(created.SyncId) == "string", "new records should receive identities")

print("Legacy id migration tests passed.")
