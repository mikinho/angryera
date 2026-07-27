local nextId = 10
local replacedPages = 0
local replacedCategories = 0
local deletedCategoryChildren = 0
local displayHierarchyRefreshes = 0
local importedPageUpdatedCalls = 0
local importedProposal
local allowRemoteCanonicalEdit = false
local updatePageVarsCalls = 0

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
    updatePageVarsCalls = updatePageVarsCalls + 1
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
    Vars = "MT=Old",
    SyncId = "local:page:2",
    LocallyOwned = true,
}
local replacedPageId = AngryEra:DoImportPage(
    {
        Name = "Local Page",
        Contents = "new",
        Vars = "MT=New\n$SKULL={{MT}}",
    },
    nil,
    2,
    nil,
    {
        includeVariables = true,
    }
)
assert(replacedPageId == 2, "A locally owned page should remain replaceable")
assert(AngryAssign_Pages[2].Contents == "new", "Local page replacement should apply imported content")
assert(
    AngryAssign_Pages[2].Vars == "MT=New\n$SKULL={{MT}}",
    "Explicit full imports should replace variables and metadata exactly"
)
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
assert(updatePageVarsCalls == 1, "A full remote import should propose its variables")
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

-- Excluding variables preserves the direct variables of an overwritten root,
-- but newly created records have an explicit empty variable source.
AngryAssign_Pages[6] = {
    Id = 6,
    Name = "Local Variables",
    Contents = "old",
    Vars = "KEEP=local\n$AUTOADVANCE=$true",
    SyncId = "local:page:6",
    LocallyOwned = true,
}
local variablesExcludedPageId = AngryEra:DoImportPage(
    {
        Name = "Local Variables",
        Contents = "new",
        Vars = "DROP=imported\n$SKULL=Other",
        VariablesIncluded = true,
    },
    nil,
    6,
    nil,
    {
        includeVariables = false,
    }
)
assert(variablesExcludedPageId == 6, "A variable-free page import should still replace an editable root")
assert(AngryAssign_Pages[6].Contents == "new", "A variable-free page import should still replace content")
assert(
    AngryAssign_Pages[6].Vars == "KEEP=local\n$AUTOADVANCE=$true",
    "An explicit variable-free import should preserve overwritten root variables"
)

local newVariableFreePageId = AngryEra:DoImportPage(
    {
        Name = "No Variables",
        Contents = "new",
        Vars = "DROP=imported",
        VariablesIncluded = true,
    },
    nil,
    nil,
    nil,
    {
        includeVariables = false,
    }
)
assert(
    AngryAssign_Pages[newVariableFreePageId].Vars == "",
    "A new page imported without variables should normalize its variable source to empty"
)

-- A payload-side false flag is authoritative even when the caller requests
-- variables. This is also the path used when sharing a variable-free export.
AngryAssign_Categories[7] = {
    Id = 7,
    Name = "Existing Root",
    Vars = "KEEP=root\n$AUTOAPPLYLAYOUT=$true",
    SyncId = "local:category:7",
    LocallyOwned = true,
}
local replacedVariableFreeCategoryId = AngryEra:DoImportCategory(
    {
        Name = "Existing Root",
        Vars = "DROP=root",
        VariablesIncluded = false,
        Children = {
            {
                Type = "Page",
                Name = "Imported Child Page",
                Contents = "child",
                Vars = "DROP=page",
            },
            {
                Type = "Category",
                Name = "Imported Child Category",
                Vars = "DROP=category",
                Children = {
                    {
                        Type = "Page",
                        Name = "Imported Grandchild Page",
                        Contents = "grandchild",
                        Vars = "DROP=grandchild",
                    },
                },
            },
        },
    },
    nil,
    7,
    nil,
    {
        includeVariables = true,
    }
)
assert(replacedVariableFreeCategoryId == 7, "A payload flag should not prevent category replacement")
assert(
    AngryAssign_Categories[7].Vars == "KEEP=root\n$AUTOAPPLYLAYOUT=$true",
    "A false payload flag should preserve overwritten root variables"
)

local importedChildPage
local importedChildCategory
local importedGrandchildPage
for _, page in pairs(AngryAssign_Pages) do
    if page.Name == "Imported Child Page" then
        importedChildPage = page
    elseif page.Name == "Imported Grandchild Page" then
        importedGrandchildPage = page
    end
end
for _, category in pairs(AngryAssign_Categories) do
    if category.Name == "Imported Child Category" then
        importedChildCategory = category
    end
end
assert(importedChildPage and importedChildPage.Vars == "", "Recreated child pages should receive empty variables")
assert(
    importedChildCategory and importedChildCategory.Vars == "",
    "Recreated child categories should receive empty variables"
)
assert(importedGrandchildPage and importedGrandchildPage.Vars == "", "Variable omission should propagate recursively")

local fullVariableCategoryId = AngryEra:DoImportCategory(
    {
        Name = "Full Variables Root",
        Vars = "{\"ROLE\":\"tank\",\"$AUTOAPPLYLAYOUT\":true}",
        VariablesIncluded = true,
        Children = {
            {
                Type = "Category",
                Name = "Full Variables Child",
                Vars = "HEALER*=PRIEST*,PALADIN*\n$LAYOUT=Healing/1: {{HEALER1}}",
                Children = {
                    {
                        Type = "Page",
                        Name = "Full Variables Page",
                        Contents = "assignment",
                        Vars = "MT=Zessy\n$SKULL={{MT}}",
                    },
                },
            },
        },
    },
    nil,
    nil,
    nil,
    {
        includeVariables = true,
    }
)
assert(
    AngryAssign_Categories[fullVariableCategoryId].Vars == "{\"ROLE\":\"tank\",\"$AUTOAPPLYLAYOUT\":true}",
    "A full category import should retain exact root variables and metadata"
)
local fullVariableChild
for _, category in pairs(AngryAssign_Categories) do
    if category.CategoryId == fullVariableCategoryId and category.Name == "Full Variables Child" then
        fullVariableChild = category
        break
    end
end
assert(
    fullVariableChild and fullVariableChild.Vars == "HEALER*=PRIEST*,PALADIN*\n$LAYOUT=Healing/1: {{HEALER1}}",
    "A full category import should retain exact nested variables and metadata"
)
local fullVariablePage
for _, page in pairs(AngryAssign_Pages) do
    if fullVariableChild and page.CategoryId == fullVariableChild.Id and page.Name == "Full Variables Page" then
        fullVariablePage = page
        break
    end
end
assert(
    fullVariablePage and fullVariablePage.Vars == "MT=Zessy\n$SKULL={{MT}}",
    "A full category import should retain exact descendant page variables and metadata"
)

-- Remote proposals must not include UpdatePageVars when variables are omitted.
AngryAssign_Pages[8] = {
    Id = 8,
    Name = "Remote Variables",
    Contents = "canonical",
    Vars = "KEEP=remote",
    Index = 4,
    SyncId = "remote:page:8",
    LocallyOwned = false,
}
allowRemoteCanonicalEdit = true
importedProposal = nil
local priorUpdatePageVarsCalls = updatePageVarsCalls
local omittedProposalId, omittedProposalResult, omittedProposed = AngryEra:DoImportPage({
    Name = "Remote Variables Updated",
    Contents = "assistant content",
    Vars = "DROP=assistant",
    VariablesIncluded = false,
}, nil, 8)
assert(
    omittedProposalId == 8 and omittedProposalResult == "scheduled" and omittedProposed,
    "A variable-free remote import should still propose canonical name and content"
)
assert(updatePageVarsCalls == priorUpdatePageVarsCalls, "Variable-free proposals must skip UpdatePageVars")
assert(
    AngryAssign_Pages[8].Vars == "KEEP=remote",
    "A variable-free remote proposal must leave canonical variables unchanged"
)
allowRemoteCanonicalEdit = false

-- Legacy payloads have no VariablesIncluded flag and therefore remain full.
local legacyPageId = AngryEra:DoImportPage({
    Name = "Legacy Full Page",
    Contents = "legacy",
    Vars = "MT=Legacy\n$SQUARE={{MT}}",
})
assert(
    AngryAssign_Pages[legacyPageId].Vars == "MT=Legacy\n$SQUARE={{MT}}",
    "A legacy payload without VariablesIncluded should import variables and metadata"
)

AngryAssign_Pages[9] = {
    Id = 9,
    Name = "Legacy Empty Variables",
    Contents = "old",
    Vars = "REMOVE=me",
    SyncId = "local:page:9",
    LocallyOwned = true,
}
AngryEra:DoImportPage({
    Name = "Legacy Empty Variables",
    Contents = "replacement",
}, nil, 9)
assert(
    AngryAssign_Pages[9].Vars == "",
    "A complete legacy replacement without Vars should remain authoritative and clear the old source"
)

print("Import ownership tests passed.")
