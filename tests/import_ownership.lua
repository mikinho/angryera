local nextId = 10
local replacedPages = 0
local replacedCategories = 0
local deletedCategoryChildren = 0
local displayHierarchyRefreshes = 0
local importedPageUpdatedCalls = 0
local importedProposal
local allowRemoteCanonicalEdit = false

AngryAssign_Pages = {}
AngryAssign_Categories = {}

_G.time = function()
    return 123
end

local AngryEra = {
    utils = {
        json = {},
        serialization = {},
        helpers = {
            CompareIndexedEntries = function(a, b)
                return (a.Index or 0) < (b.Index or 0)
            end,
        },
    },
}

function AngryEra:CanEditEntityLocally(entity)
    return entity and (entity.LocallyOwned == true or allowRemoteCanonicalEdit)
end

function AngryEra:IsLocallyOwned(entity)
    return entity and entity.LocallyOwned == true
end

function AngryEra:GetUniqueEntityName(name, entityType)
    local records = entityType == "Page" and AngryAssign_Pages or AngryAssign_Categories
    local candidate = name
    local suffix = 1
    local found = true
    while found do
        found = false
        for _, record in pairs(records) do
            if record.Name == candidate then
                found = true
                candidate = string.format("%s (%d)", name, suffix)
                suffix = suffix + 1
                break
            end
        end
    end
    return candidate
end

function AngryEra:Hash(name, contents, vars)
    return table.concat({ name or "", contents or "", vars or "" }, ":")
end

function AngryEra:NewLocalPageRecord(fields)
    local page = {}
    for key, value in pairs(fields) do
        page[key] = value
    end
    page.Id = nextId
    page.SyncId = "local:page:" .. nextId
    page.LocallyOwned = true
    nextId = nextId + 1
    return page
end

function AngryEra:NewLocalCategoryRecord(fields)
    local category = {}
    for key, value in pairs(fields) do
        category[key] = value
    end
    category.Id = nextId
    category.SyncId = "local:category:" .. nextId
    category.LocallyOwned = true
    nextId = nextId + 1
    return category
end

function AngryEra:ReplacePageRecord(id, fields)
    replacedPages = replacedPages + 1
    local page = self:NewLocalPageRecord(fields)
    page.Id = id
    page.SyncId = AngryAssign_Pages[id].SyncId
    return page
end

function AngryEra:ReplaceCategoryRecord(id, fields)
    replacedCategories = replacedCategories + 1
    local category = self:NewLocalCategoryRecord(fields)
    category.Id = id
    category.SyncId = AngryAssign_Categories[id].SyncId
    return category
end

function AngryEra:DeleteCategoryChildren(_, suppressDisplayRefresh)
    assert(suppressDisplayRefresh == true, "bulk category replacement should defer active display refresh")
    deletedCategoryChildren = deletedCategoryChildren + 1
    return true
end

function AngryEra:UpdateTree() end
function AngryEra:RefreshDisplayedPageAfterHierarchyMutation()
    displayHierarchyRefreshes = displayHierarchyRefreshes + 1
end

function AngryEra:UpdateContents(id, contents)
    if allowRemoteCanonicalEdit and AngryAssign_Pages[id] and AngryAssign_Pages[id].LocallyOwned == false then
        importedProposal = importedProposal or {}
        importedProposal.Contents = contents
        return true, "scheduled", true
    end
    AngryAssign_Pages[id].Contents = contents
    return true, nil, false
end

function AngryEra:UpdatePageVars(id, vars)
    if allowRemoteCanonicalEdit and AngryAssign_Pages[id] and AngryAssign_Pages[id].LocallyOwned == false then
        importedProposal = importedProposal or {}
        importedProposal.Vars = vars
        return true, "scheduled", true
    end
    AngryAssign_Pages[id].Vars = vars
    return true, nil, false
end

function AngryEra:RenamePage(id, name)
    if allowRemoteCanonicalEdit and AngryAssign_Pages[id] and AngryAssign_Pages[id].LocallyOwned == false then
        importedProposal = importedProposal or {}
        importedProposal.Name = name
        return true, "scheduled", true
    end
    AngryAssign_Pages[id].Name = name
    return true, nil, false
end

function AngryEra:PageUpdated()
    importedPageUpdatedCalls = importedPageUpdatedCalls + 1
end

local app = {
    AngryEra = AngryEra,
    libs = {
        AceGUI = {},
        libS = {},
        libD = {},
    },
}

assert(loadfile("modules/ui/import_export.lua"))("AngryEra", app)

AngryAssign_Pages[1] = {
    Id = 1,
    Name = "Remote Page",
    Contents = "remote",
    SyncId = "remote:page:1",
    LocallyOwned = false,
}

local forkedPageId = AngryEra:DoImportPage({
    Name = "Remote Page",
    Contents = "imported",
}, nil, 1)
assert(forkedPageId ~= 1, "An uneditable remote page should import as a new local record")
assert(AngryAssign_Pages[1].Contents == "remote", "Import must not replace remote page content in place")
assert(AngryAssign_Pages[forkedPageId].Name == "Remote Page (1)", "A local page fork should have a unique name")
assert(AngryAssign_Pages[forkedPageId].LocallyOwned, "The imported page fork should be locally owned")
assert(replacedPages == 0, "Forking a remote page must not use identity-preserving replacement")

AngryAssign_Pages[2] = {
    Id = 2,
    Name = "Local Page",
    Contents = "old",
    SyncId = "local:page:2",
    LocallyOwned = true,
}
local replacedPageId = AngryEra:DoImportPage({
    Name = "Local Page",
    Contents = "new",
}, nil, 2)
assert(replacedPageId == 2, "A locally owned page should remain replaceable")
assert(AngryAssign_Pages[2].Contents == "new", "Local page replacement should apply imported content")
assert(replacedPages == 1, "Local page replacement should preserve its identity")

AngryAssign_Pages[5] = {
    Id = 5,
    Name = "Active Remote Page",
    Contents = "canonical",
    Vars = "MT=Leader",
    Index = 9,
    SyncId = "remote:page:5",
    LocallyOwned = false,
}
allowRemoteCanonicalEdit = true
local proposedPageId, proposalResult, proposed = AngryEra:DoImportPage({
    Name = "Imported Active Page",
    Contents = "assistant draft",
    Vars = "MT=Assistant",
    Index = 1,
}, nil, 5)
assert(proposedPageId == 5 and proposalResult == "scheduled" and proposed, "active remote import should propose")
assert(
    AngryAssign_Pages[5].Name == "Active Remote Page"
        and AngryAssign_Pages[5].Contents == "canonical"
        and AngryAssign_Pages[5].Vars == "MT=Leader"
        and AngryAssign_Pages[5].Index == 9,
    "a proposed import must not mutate canonical fields or receiver-private order"
)
assert(
    importedProposal
        and importedProposal.Name == "Imported Active Page"
        and importedProposal.Contents == "assistant draft"
        and importedProposal.Vars == "MT=Assistant",
    "the active remote import should retain every desired canonical field"
)
assert(replacedPages == 1, "a proposed remote import must not replace its canonical record")

local applied, applyResult, updateProposed = AngryEra:ApplyImportedPageUpdate(5, "second draft", 2)
assert(applied and applyResult == "scheduled" and updateProposed, "legacy import updates should expose proposals")
assert(AngryAssign_Pages[5].Index == 9, "a proposed legacy import must not mutate Index")
assert(importedPageUpdatedCalls == 0, "a proposed legacy import must not call PageUpdated")
allowRemoteCanonicalEdit = false

AngryAssign_Categories[3] = {
    Id = 3,
    Name = "Remote Category",
    SyncId = "remote:category:3",
    LocallyOwned = false,
}
local forkedCategoryId = AngryEra:DoImportCategory({
    Name = "Remote Category",
    Vars = "MT=ForkedTank",
    Children = {},
}, nil, 3)
assert(forkedCategoryId ~= 3, "An uneditable remote category should import as a new local record")
assert(
    AngryAssign_Categories[forkedCategoryId].Name == "Remote Category (1)",
    "A local category fork should have a unique name"
)
assert(AngryAssign_Categories[forkedCategoryId].LocallyOwned, "The imported category fork should be locally owned")
assert(
    AngryAssign_Categories[forkedCategoryId].Vars == "MT=ForkedTank",
    "A category fork should retain imported variables"
)
assert(deletedCategoryChildren == 0, "Remote descendants must not be deleted before the fork decision")
assert(replacedCategories == 0, "Forking a remote category must not preserve its remote identity")

AngryAssign_Categories[4] = {
    Id = 4,
    Name = "Local Category",
    SyncId = "local:category:4",
    LocallyOwned = true,
}
local replacedCategoryId = AngryEra:DoImportCategory({
    Name = "Local Category",
    Vars = "MT=ReplacementTank",
    Children = {},
}, nil, 4)
assert(replacedCategoryId == 4, "A locally owned category should remain replaceable")
assert(AngryAssign_Categories[4].Vars == "MT=ReplacementTank", "Category replacement should retain variables")
assert(deletedCategoryChildren == 1, "Replacing a local category should clear its prior descendants")
assert(replacedCategories == 1, "Local category replacement should preserve its identity")
assert(displayHierarchyRefreshes == 4, "Each top-level import should refresh active hierarchy state exactly once")

print("Import ownership tests passed.")
