-- Guards the editor tree's local pin ordering without flattening hierarchy.

local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra, libs = {} }

local function CompareIndexedEntries(left, right)
    local leftIndex = left.Index or left.index
    local rightIndex = right.Index or right.index
    local leftName = left.Name or left.text or ""
    local rightName = right.Name or right.text or ""
    if leftIndex and rightIndex then
        if leftIndex == rightIndex then
            return leftName < rightName
        end
        return leftIndex < rightIndex
    end
    if leftIndex then
        return true
    end
    if rightIndex then
        return false
    end
    return leftName < rightName
end

AngryEra.utils.helpers = {
    CompareIndexedEntries = CompareIndexedEntries,
    EnsureUnitShortName = function(name)
        return name
    end,
    IsCategoryDescendant = function()
        return false
    end,
    IterateGroupMembers = function() end,
    selectedLastValue = function(value)
        return tonumber(value)
    end,
}
AngryEra.utils.colors = {}

app.libs.AceGUI = setmetatable({}, {
    __index = function()
        return function() end
    end,
})
app.libs.DDM = app.libs.AceGUI

AngryAssign_Categories = {
    [101] = { Id = 101, SyncId = "category:101", Name = "C1", Index = 1 },
    [102] = { Id = 102, SyncId = "category:102", Name = "C2", Index = 40 },
    [103] = { Id = 103, SyncId = "category:103", Name = "C3", Index = 20 },
    [104] = { Id = 104, SyncId = "category:104", Name = "C4", Index = 80 },
    [105] = { Id = 105, SyncId = "category:105", Name = "C5", Index = 30, CategoryId = 104 },
    [106] = { Id = 106, SyncId = "category:106", Name = "C6", Index = 2, CategoryId = 104 },
}
AngryAssign_Pages = {
    [11] = { Id = 11, SyncId = "page:11", Name = "P11", Index = 0 },
    [12] = { Id = 12, SyncId = "page:12", Name = "P12", Index = 50 },
    [13] = { Id = 13, SyncId = "page:13", Name = "P13", Index = 10 },
    [14] = { Id = 14, SyncId = "page:14", Name = "P14", Index = 60 },
    [21] = { Id = 21, SyncId = "page:21", Name = "P21", Index = 0, CategoryId = 104 },
    [22] = {
        Id = 22,
        SyncId = "page:22",
        Name = "P22",
        Index = 20,
        CategoryId = 104,
        Vars = "MT=Zessy",
    },
    [23] = { Id = 23, SyncId = "page:23", Name = "P23", Index = 10, CategoryId = 104 },
    [24] = { Id = 24, SyncId = "page:24", Name = "P24", Index = 40, CategoryId = 104 },
    [31] = { Id = 31, SyncId = "page:31", Name = "Same", Index = 5, CategoryId = 101 },
    [32] = { Id = 32, SyncId = "page:32", Name = "Same", Index = 5, CategoryId = 101 },
    [41] = { Id = 41, SyncId = "page:41", Name = "P41", Index = 2, CategoryId = 102 },
    [42] = { Id = 42, SyncId = "page:42", Name = "P42", Index = 1, CategoryId = 102 },
}
AngryAssign_State = {
    displayed = 22,
    tree = {},
}

local pinned = {
    ["category:102"] = true,
    ["category:103"] = true,
    ["category:105"] = true,
    ["page:12"] = true,
    ["page:13"] = true,
    ["page:22"] = true,
    ["page:23"] = true,
    ["page:41"] = true,
    ["page:42"] = true,
}
function AngryEra:IsPinned(entity)
    return pinned[entity.SyncId] == true
end

local printed = {}
function AngryEra:Print(message)
    printed[#printed + 1] = message
end

assert(loadfile("modules/ui/editor.lua"))("AngryEra", app)

local function Values(entries)
    local values = {}
    for _, entry in ipairs(entries) do
        values[#values + 1] = entry.separator and "SEP" or tostring(entry.value)
    end
    return table.concat(values, ",")
end

local function Find(entries, value)
    for _, entry in ipairs(entries) do
        if entry.value == value then
            return entry
        end
    end
end

local function CountSeparators(entries)
    local count = 0
    for _, entry in ipairs(entries) do
        if entry.separator then
            count = count + 1
        end
    end
    return count
end

local function Snapshot(entries, prefix, output)
    prefix = prefix or ""
    output = output or {}
    for _, entry in ipairs(entries) do
        local value = entry.separator and "SEP" or tostring(entry.value)
        local path = prefix == "" and value or prefix .. "/" .. value
        output[#output + 1] = path .. ":" .. tostring(entry.pinned == true)
        if entry.children then
            Snapshot(entry.children, path, output)
        end
    end
    return table.concat(output, "|")
end

local tree = AngryEra:GetTree()
assert(
    Values(tree) == "-103,-102,13,12,SEP,11,-101,14,-104",
    "root siblings should be pinned categories, pinned pages, a separator, then manual unpinned order"
)
assert(CountSeparators(tree) == 1, "a mixed root should contain exactly one separator")

local separator = tree[5]
assert(
    separator.separator == true
        and separator.disabled == true
        and separator.visible == false
        and separator.text == ""
        and separator.pinned ~= true,
    "the separator should be a hidden-from-filtering, noninteractive row"
)

local c4 = assert(Find(tree, -104), "the nested fixture category should remain at root")
assert(
    Values(c4.children) == "-105,23,22,SEP,21,-106,24",
    "nested siblings should use the same pin buckets without hoisting pages"
)
assert(Find(tree, 22) == nil and Find(c4.children, 22), "a pinned nested page should appear only under its parent")

local displayedPinned = assert(Find(c4.children, 22), "the displayed pinned page should be present")
assert(displayedPinned.pinned == true, "the displayed page should retain its independent pin marker")
assert(displayedPinned.icon, "the displayed page should retain its active-page icon")
assert(displayedPinned.text:find("‡", 1, true), "the variable marker should coexist with pin and display state")

local c1 = assert(Find(tree, -101), "the all-unpinned child fixture should be present")
assert(Values(c1.children) == "31,32", "equal names and indices should use entity id as a stable fallback")
assert(CountSeparators(c1.children) == 0, "an all-unpinned sibling list should have no separator")

local c2 = assert(Find(tree, -102), "the all-pinned child fixture should be present")
assert(Values(c2.children) == "42,41", "all-pinned pages should retain their manual order")
assert(CountSeparators(c2.children) == 0, "an all-pinned sibling list should have no separator")

local c3 = assert(Find(tree, -103), "the empty child fixture should be present")
assert(#c3.children == 0, "an empty sibling list should have no separator")

local firstSnapshot = Snapshot(tree)
local secondSnapshot = Snapshot(AngryEra:GetTree())
assert(firstSnapshot == secondSnapshot, "repeated tree builds should be deterministic")
assert(
    AngryAssign_Categories[102].Index == 40 and AngryAssign_Pages[13].Index == 10 and AngryAssign_Pages[22].Index == 20,
    "pin ordering should never mutate saved manual indices"
)

local pinnedPageIndex = AngryAssign_Pages[13].Index
AngryEra:MoveItem("13", "11", "after")
assert(
    AngryAssign_Pages[13].Index == pinnedPageIndex and AngryAssign_Pages[13].CategoryId == nil,
    "a positional drop across fixed pin sections should not mutate hierarchy or order"
)
assert(
    #printed == 1 and printed[1]:find("fixed sections", 1, true),
    "an incompatible cross-section drop should explain how to reorder the item"
)

AngryEra:MoveItem("13", separator.value, "after")
AngryEra:MoveItem(separator.value, "11", "before")
assert(
    AngryAssign_Pages[13].Index == pinnedPageIndex and #printed == 1,
    "the separator should be ignored as either a drag source or target"
)

pinned["page:13"] = nil
tree = AngryEra:GetTree()
assert(
    Values(tree) == "-103,-102,12,SEP,11,-101,13,14,-104",
    "unpinning a page should return it to its manual position below the separator"
)

pinned["category:102"] = nil
pinned["category:103"] = nil
pinned["page:12"] = nil
tree = AngryEra:GetTree()
assert(
    Values(tree) == "11,-101,13,-103,-102,12,14,-104",
    "without root pins, the original mixed manual order should be restored"
)
assert(CountSeparators(tree) == 0, "a root with no pins should have no separator")

print("Tree pin ordering tests passed.")
