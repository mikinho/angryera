-- Guards the page context menu wiring. The menu is a positional table shared
-- between every right-click, so an entry added in the middle used to leave the
-- ids and permission flags below it attached to the wrong rows.

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

local pinned = {}
function AngryEra:IsPinned(page)
    return pinned[page.Id] == true
end

function AngryEra:SetPinned(page, value)
    pinned[page.Id] = value == true
    return true
end

function AngryEra:Print() end

AngryAssign_Pages = {
    [11] = { Id = 11, Name = "Loatheb", CategoryId = 4 },
    [12] = { Id = 12, Name = "Export", CategoryId = nil },
}
AngryAssign_Categories = {
    [4] = { Id = 4, Name = "Naxxramas" },
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

local menu = AngryEra_PageMenu(11)
assert(menu, "right-clicking a page returns a menu")
assert(menu[1].text == "Loatheb", "the title names the page")

local labels = { "Rename", "Delete", "Pin", "Edit Variables", "Edit Group Layout", "Export", "Category" }
for _, label in ipairs(labels) do
    local entry = Entry(menu, label)
    assert(entry, "the menu offers " .. label)
    assert(entry.arg1 == 11, label .. " acts on the clicked page")
end

-- The regression: Export owns the only nested list, and a menu entry added
-- above it left this lookup on an entry that had no menuList at all.
local export = Entry(menu, "Export")
assert(type(export.menuList) == "table" and #export.menuList > 0, "Export offers formats")
for _, item in ipairs(export.menuList) do
    assert(item.arg1 == 11, "an export format acts on the clicked page")
end

local category = Entry(menu, "Category")
assert(type(category.menuList) == "table", "Category offers a list")
assert(category.disabled == false, "a page with categories can be moved")

-- Every entry that edits the page is gated on the same permission.
editable = false
menu = AngryEra_PageMenu(11)
for _, label in ipairs({ "Rename", "Edit Variables", "Edit Group Layout" }) do
    assert(Entry(menu, label).disabled == true, label .. " is closed to a read-only page")
end
assert(Entry(menu, "Export").disabled ~= true, "a read-only page can still be exported")
assert(Entry(menu, "Pin").disabled ~= true, "a read-only received page can still be pinned locally")
editable = true

-- Pinning is local state and the reused menu changes its action to match.
Entry(menu, "Pin").func(nil, 11)
assert(pinned[11], "Pin protects the clicked page")
menu = AngryEra_PageMenu(11)
assert(Entry(menu, "Unpin"), "a pinned page offers Unpin")
Entry(menu, "Unpin").func(nil, 11)
assert(not pinned[11], "Unpin releases the clicked page")

-- The menu is reused between clicks, so a second page must not inherit the
-- first page's id.
menu = AngryEra_PageMenu(12)
assert(menu[1].text == "Export", "the title follows the clicked page")
for _, label in ipairs({ "Rename", "Delete", "Pin", "Edit Variables", "Edit Group Layout", "Export", "Category" }) do
    assert(Entry(menu, label).arg1 == 12, label .. " follows the clicked page")
end
assert(Entry(menu, "Export").menuList[1].arg1 == 12, "an export format follows the clicked page")

assert(AngryEra_PageMenu(99) == nil, "a missing page has no menu")

print("Page menu tests passed.")
