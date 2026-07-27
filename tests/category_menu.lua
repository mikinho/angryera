-- Guards the category context menu wiring. The menu is a positional table
-- shared between every right-click, so an entry added in the middle used to
-- leave the ids and permission flags below it attached to the wrong rows.

local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra, libs = {} }

assert(loadfile("modules/layout.lua"))("AngryEra", app)

local function EnsureUnitShortName(name)
    return name and name:match("([^-]+)")
end

AngryEra.utils.helpers = {
    EnsureUnitShortName = EnsureUnitShortName,
    IterateGroupMembers = function() end,
    IsCategoryDescendant = function()
        return false
    end,
    selectedLastValue = function(value)
        return tonumber(value) or 0
    end,
}
AngryEra.utils.colors = {}

-- The editor only reaches for these once a window is built, so the menu tests
-- need nothing behind them.
app.libs.AceGUI = setmetatable({}, {
    __index = function()
        return function() end
    end,
})
app.libs.DDM = app.libs.AceGUI

local editable = true
function AngryEra:CanEditEntityLocally()
    return editable
end

AngryAssign_Pages = {}
AngryAssign_Categories = {
    [4] = { Id = 4, Name = "Naxxramas" },
    [5] = { Id = 5, Name = "Temple of Ahn'Qiraj" },
}

assert(loadfile("modules/ui/editor.lua"))("AngryEra", app)

-- Reads the entry a label names, the way a player picks a row by reading it.
local function Entry(menu, text)
    for index = 2, #menu do
        if menu[index].text == text then
            return menu[index]
        end
    end
end

local menu = AngryEra_CategoryMenu(4)
assert(menu, "right-clicking a category returns a menu")
assert(menu[1].text == "Naxxramas", "the title names the category")

local labels = {
    "Rename",
    "Save as Template",
    "Delete",
    "Edit Variables",
    "Edit Group Layout",
    "Export",
    "Category",
}
for _, label in ipairs(labels) do
    local entry = Entry(menu, label)
    assert(entry, "the menu offers " .. label)
    assert(entry.arg1 == 4, label .. " acts on the clicked category")
end

-- A category carries the raid's standard layout, so it edits one the same way
-- a page does rather than only through its raw variables.
assert(Entry(menu, "Edit Group Layout"), "a category can edit its group layout")

-- Export owns the only nested list, and an entry added above it used to leave
-- this lookup on an entry that had no menuList at all.
local export = Entry(menu, "Export")
assert(type(export.menuList) == "table" and #export.menuList > 0, "Export offers formats")
for _, item in ipairs(export.menuList) do
    assert(item.arg1 == 4, "an export format acts on the clicked category")
end

local category = Entry(menu, "Category")
assert(type(category.menuList) == "table", "Category offers a list")
assert(category.disabled == false, "a category with siblings can be moved")

-- Every entry that edits the category is gated on the same permission.
editable = false
menu = AngryEra_CategoryMenu(4)
for _, label in ipairs({ "Rename", "Edit Variables", "Edit Group Layout" }) do
    assert(Entry(menu, label).disabled == true, label .. " is closed to a read-only category")
end
assert(Entry(menu, "Export").disabled ~= true, "a read-only category can still be exported")
editable = true

-- The menu is reused between clicks, so a second category must not inherit the
-- first category's id.
menu = AngryEra_CategoryMenu(5)
assert(menu[1].text == "Temple of Ahn'Qiraj", "the title follows the clicked category")
for _, label in ipairs(labels) do
    assert(Entry(menu, label).arg1 == 5, label .. " follows the clicked category")
end
assert(Entry(menu, "Export").menuList[1].arg1 == 5, "an export format follows the clicked category")

assert(AngryEra_CategoryMenu(99) == nil, "a missing category has no menu")

print("Category menu tests passed.")
