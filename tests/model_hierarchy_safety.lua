local selectedPath
local selectedValue
local removedCategories = {}
local removedPages = {}

local AngryEra = {
    utils = {
        helpers = {
            selectedLastValue = function(value)
                return value
            end,
            tReverse = function(value)
                return value
            end,
            IsCategoryDescendant = function()
                return false
            end,
            ExtractAndValidateName = function(value)
                return value
            end,
        },
    },
    window = {
        tree = {
            SelectByPath = function(_, ...)
                selectedPath = { ... }
            end,
            SelectByValue = function(_, value)
                selectedValue = value
            end,
            SetSelected = function()
                selectedValue = nil
            end,
        },
    },
}

local app = {
    AngryEra = AngryEra,
    libs = {
        libC = {
            fcs32init = function()
                return 0
            end,
            fcs32update = function(value)
                return value
            end,
            fcs32final = function()
                return "hash"
            end,
        },
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/models.lua"))("AngryEra", app)

function AngryEra:RemoveCategoryRecord(id)
    removedCategories[#removedCategories + 1] = id
    AngryAssign_Categories[id] = nil
end

function AngryEra:RemovePageRecord(id)
    removedPages[#removedPages + 1] = id
    AngryAssign_Pages[id] = nil
end

function AngryEra:ClearDisplayed()
    AngryAssign_State.displayed = nil
end

AngryAssign_State = {
    tree = {
        groups = {},
        selected = nil,
    },
}

AngryAssign_Categories = {
    [1] = { Id = 1, CategoryId = 2 },
    [2] = { Id = 2, CategoryId = 1 },
}
AngryAssign_Pages = {
    [10] = { Id = 10, CategoryId = 1 },
}

local selected = AngryEra:SetSelectedId(10)
assert(not selected, "Selecting through a cyclic hierarchy should fail safely")
assert(selectedValue == 10 and selectedPath == nil, "Cycle fallback should select the page without walking parents")

local deleted, deleteError = AngryEra:DeleteCategoryChildren(1)
assert(not deleted and deleteError == "category-cycle", "Cyclic descendant deletion should fail before mutation")
assert(AngryAssign_Categories[1] and AngryAssign_Categories[2], "Cycle failure must not partially delete categories")
assert(AngryAssign_Pages[10], "Cycle failure must not partially delete pages")
assert(#removedCategories == 0 and #removedPages == 0, "Cycle failure must not invoke removals")

AngryAssign_Categories = {
    [1] = { Id = 1 },
    [2] = { Id = 2, CategoryId = 1 },
    [3] = { Id = 3, CategoryId = 2 },
}
AngryAssign_Pages = {
    [10] = { Id = 10, CategoryId = 1 },
    [11] = { Id = 11, CategoryId = 3 },
}
AngryAssign_State.displayed = 11
removedCategories = {}
removedPages = {}
selectedPath = nil

selected = AngryEra:SetSelectedId(11)
assert(selected, "A valid hierarchy should select successfully")
assert(
    selectedPath[1] == -1 and selectedPath[2] == -2 and selectedPath[3] == -3 and selectedPath[4] == 11,
    "Selection path should be root-to-page"
)

deleted, deleteError = AngryEra:DeleteCategoryChildren(1)
assert(deleted and not deleteError, "A valid descendant tree should delete")
assert(AngryAssign_Categories[1], "DeleteCategoryChildren should retain the requested root")
assert(not AngryAssign_Categories[2] and not AngryAssign_Categories[3], "Every descendant category should be removed")
assert(not AngryAssign_Pages[10] and not AngryAssign_Pages[11], "Pages throughout the subtree should be removed")
assert(AngryAssign_State.displayed == nil, "Deleting the displayed page should clear the display")
assert(removedCategories[1] == 3 and removedCategories[2] == 2, "Descendant categories should be removed leaf-first")

print("Model hierarchy safety tests passed.")
