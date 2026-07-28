local selectedPath
local selectedValue
local removedCategories = {}
local removedPages = {}
local clearCalls = {}
local displayedRepublishes = {}
local printedMessages = {}

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

function AngryEra:ClearDisplayed(publish)
    clearCalls[#clearCalls + 1] = publish
    AngryAssign_State.displayed = nil
end

function AngryEra:SendDisplay(id, force)
    displayedRepublishes[#displayedRepublishes + 1] = {
        Id = id,
        Force = force,
    }
    return true, "display-message", true
end

function AngryEra:UpdateDisplayed() end
function AngryEra:UpdateTree() end
function AngryEra:Print(message)
    printedMessages[#printedMessages + 1] = message
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

local editorWindow = AngryEra.window
AngryEra.window = nil
AngryAssign_State.tree.selected = 10
assert(AngryEra:SelectedId() == 10, "Persisted selection should be readable before the editor exists")
assert(not AngryEra:SetSelectedId(nil), "Clearing selection without an editor should report no widget selection")
assert(AngryAssign_State.tree.selected == nil, "Clearing selection before editor creation should update saved state")
AngryAssign_State.tree = nil
assert(AngryEra:SelectedId() == nil, "A missing saved tree should have no selected page")
assert(not AngryEra:SetSelectedId(nil), "Clearing a missing saved tree should remain safe")
assert(type(AngryAssign_State.tree) == "table", "Selection clearing should repair the saved tree container")
AngryEra.window = editorWindow

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
assert(#clearCalls == 1 and clearCalls[1] == true, "Recursive deletion should publish one display clear")
assert(removedCategories[1] == 3 and removedCategories[2] == 2, "Descendant categories should be removed leaf-first")

AngryAssign_Categories = {
    [1] = { Id = 1, Name = "Root" },
    [2] = { Id = 2, Name = "Removed Subtree", CategoryId = 1 },
}
AngryAssign_Pages = {
    [20] = { Id = 20, Name = "Displayed", CategoryId = 1 },
    [21] = { Id = 21, Name = "Removed", CategoryId = 2 },
}
AngryAssign_State.displayed = 20
removedCategories = {}
removedPages = {}
displayedRepublishes = {}

deleted, deleteError = AngryEra:DeleteCategoryAndChildren(2)
assert(deleted and not deleteError, "Deleting a non-active sibling subtree should succeed")
assert(AngryAssign_State.displayed == 20, "Sibling subtree deletion should retain the active page")
assert(
    #displayedRepublishes == 1 and displayedRepublishes[1].Id == 20 and displayedRepublishes[1].Force == true,
    "Sibling subtree deletion should republish the displayed page exactly once"
)

AngryAssign_Categories = {}
for id = 1, 32 do
    AngryAssign_Categories[id] = {
        Id = id,
        Name = "Depth " .. id,
        CategoryId = id > 1 and id - 1 or nil,
    }
end
AngryAssign_Pages = {
    [99] = {
        Id = 99,
        Name = "Depth boundary",
        Contents = "",
    },
}
AngryAssign_State.displayed = nil
printedMessages = {}

local assigned, assignError = AngryEra:AssignCategory(99, 31)
assert(assigned and not assignError, "a page should fit at the exact hierarchy depth limit")
assert(AngryAssign_Pages[99].CategoryId == 31, "the exact-limit page move should be retained")

assigned, assignError = AngryEra:AssignCategory(99, 32)
assert(not assigned and assignError == "hierarchy-too-deep", "a page should not exceed the hierarchy depth limit")
assert(AngryAssign_Pages[99].CategoryId == 31, "a rejected page move must preserve its previous parent")
assert(
    printedMessages[#printedMessages]:find("cannot exceed 32 levels", 1, true),
    "an oversized page move should explain the hierarchy limit"
)

AngryAssign_Categories[100] = { Id = 100, Name = "Subtree root" }
AngryAssign_Categories[101] = { Id = 101, Name = "Subtree child", CategoryId = 100 }
assigned, assignError = AngryEra:AssignCategory(-100, 31)
assert(
    not assigned and assignError == "hierarchy-too-deep",
    "moving a category subtree should account for every descendant"
)
assert(AngryAssign_Categories[100].CategoryId == nil, "a rejected subtree move must preserve its previous parent")

assigned, assignError = AngryEra:AssignCategory(-100, 30)
assert(assigned and not assignError, "a category subtree should fit at the exact hierarchy depth limit")
assert(AngryAssign_Categories[100].CategoryId == 30, "the exact-limit subtree move should be retained")

print("Model hierarchy safety tests passed.")
