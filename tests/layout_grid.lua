local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

assert(loadfile("modules/layout.lua"))("AngryEra", app)
local layout = AngryEra.utils.layout

-- Stubbed frame API. Regions record only what the widget reads back: size,
-- visibility, text, drag registration, and the parent chain the hit-test walks.
local function NewRegion(parent)
    local region = { parent = parent, shown = true, width = 0, height = 0, dragButtons = {}, scripts = {} }

    function region:SetPoint() end
    function region:ClearAllPoints() end
    function region:SetAllPoints() end
    function region:SetJustifyH() end
    function region:SetBackdrop() end
    function region:SetBackdropColor() end
    function region:SetBackdropBorderColor() end
    function region:SetColorTexture() end
    function region:RegisterForClicks() end
    function region:SetText(text)
        self.text = text or ""
    end
    function region:GetText()
        return self.text or ""
    end
    function region:SetWidth(width)
        self.width = width
    end
    function region:GetWidth()
        return self.width
    end
    function region:SetHeight(height)
        self.height = height
    end
    function region:GetHeight()
        return self.height
    end
    function region:Show()
        self.shown = true
    end
    function region:Hide()
        self.shown = false
    end
    function region:SetShown(shown)
        self.shown = shown and true or false
    end
    function region:IsShown()
        return self.shown
    end
    function region:IsMouseOver()
        return self.mouseOver == true
    end
    function region:GetParent()
        return self.parent
    end
    function region:SetParent(value)
        self.parent = value
    end
    function region:RegisterForDrag(...)
        self.dragButtons = { ... }
    end
    function region:SetScript(name, handler)
        self.scripts[name] = handler
    end
    function region:GetScript(name)
        return self.scripts[name]
    end
    function region:CreateFontString()
        return NewRegion(self)
    end
    function region:CreateTexture()
        return NewRegion(self)
    end

    return region
end

_G.UIParent = NewRegion(nil)
function _G.CreateFrame(_, _, parent)
    return NewRegion(parent or _G.UIParent)
end
function _G.SetCursor() end
function _G.CloseDropDownMenus() end

local hovered
function _G.GetMouseFocus()
    return hovered
end

-- Stubbed AceGUI: capture the constructor and provide the widget base methods
-- RegisterAsWidget normally mixes in.
local registered = {}
local AceGUI = {}

function AceGUI:GetWidgetVersion()
    return 0
end

function AceGUI:RegisterWidgetType(name, constructor)
    registered[name] = constructor
end

function AceGUI:RegisterAsWidget(widget)
    widget.callbacks = {}
    function widget:SetCallback(name, handler)
        self.callbacks[name] = handler
    end
    function widget:Fire(name, ...)
        local handler = self.callbacks[name]
        if handler then
            handler(self, ...)
        end
    end
    function widget:SetWidth(width)
        self.frame:SetWidth(width)
        if self.OnWidthSet then
            self:OnWidthSet(width)
        end
    end
    function widget:SetHeight(height)
        self.frame:SetHeight(height)
    end
    return widget
end

function _G.LibStub(name)
    assert(name == "AceGUI-3.0", "Unexpected library request: " .. tostring(name))
    return AceGUI
end

assert(loadfile("modules/ui/components/angry_layout_grid.lua"))()
local constructor = registered["AngryLayoutGrid"]
assert(type(constructor) == "function", "the grid widget registers itself with AceGUI")

local grid = constructor()
grid:OnAcquire()
grid:SetLayoutEngine(layout)
grid:SetRoster({ "Vhez", "Kaza" })
grid:SetWidth(400)
grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores: X"))

-- The grid always draws eight subgroup boxes, then free groups, then the palette.
local visible = 0
for _, box in ipairs(grid.boxes) do
    if box:IsShown() then
        visible = visible + 1
    end
end
assert(visible == 10, "eight subgroup boxes plus one free group plus the palette are drawn")
assert(grid.boxes[1].header.label:GetText() == "Main", "a bound group titles its subgroup box")
assert(grid.boxes[2].header.label:GetText() == "Group 2", "an unclaimed subgroup box is titled by number")
assert(grid.boxes[9].header.label:GetText() == "Spores", "free groups follow the subgroup boxes")
assert(grid.boxes[10].header.label:GetText() == "Roster", "the palette is drawn last")
assert(grid.frame:GetHeight() > 0, "the grid reports a height for its container")

-- Rows carry the drop target the hit-test reads, and only filled rows drag.
local filled = grid.boxes[1].rows[1]
assert(filled.label:GetText() == "A" and filled.layoutTarget.kind == "slot", "a filled row targets its slot")
assert(filled.layoutTarget.group == 1 and filled.layoutTarget.slot == 1, "a filled row knows its position")
assert(#filled.dragButtons == 1, "a filled row can start a drag")

local blank = grid.boxes[1].rows[3]
assert(blank.label:GetText() == "" and blank.layoutTarget.kind == "empty", "an empty row targets its group")
assert(blank.layoutTarget.group == 1, "an empty row in a claimed box appends to that group")
assert(#blank.dragButtons == 0, "an empty row cannot start a drag")

local unclaimed = grid.boxes[2].rows[1]
assert(unclaimed.layoutTarget.group == nil, "an unclaimed box has no group yet")
assert(unclaimed.layoutTarget.subgroup == 2, "an unclaimed box targets its subgroup")

local paletteTarget = grid.boxes[10].rows[1].layoutTarget
assert(paletteTarget.kind == "palette" and paletteTarget.text == "Vhez", "the palette carries names")

-- Clicks report their position so the host can act on a row without a drag.
local clicked
grid:SetCallback("OnSlotClick", function(_, group, slot, button)
    clicked = { group = group, slot = slot, button = button }
end)
filled:GetScript("OnClick")(filled, "RightButton")
assert(clicked.group == 1 and clicked.slot == 1, "a slot click reports its position")
assert(clicked.button == "RightButton", "a slot click reports the mouse button")

local headerClicked
grid:SetCallback("OnGroupClick", function(_, group, subgroup)
    headerClicked = { group = group, subgroup = subgroup }
end)
local header = grid.boxes[2].header
header:GetScript("OnClick")(header, "LeftButton")
assert(headerClicked.group == nil and headerClicked.subgroup == 2, "a header click reports its subgroup")

local emptyClicked
grid:SetCallback("OnEmptyClick", function(_, group, subgroup)
    emptyClicked = { group = group, subgroup = subgroup }
end)
headerClicked = nil
blank:GetScript("OnClick")(blank, "LeftButton")
assert(emptyClicked.group == 1 and emptyClicked.subgroup == 1, "an empty row click reports its box")
assert(not headerClicked, "clicking blank space does not act on the group itself")

-- Drives one drag gesture and returns the descriptors the widget reported.
local function Drag(source, target, mouseOver)
    local drag, drop
    grid:SetCallback("OnLayoutDrop", function(_, firedDrag, firedDrop)
        drag, drop = firedDrag, firedDrop
    end)
    hovered = source
    source:GetScript("OnDragStart")(source)
    hovered = target
    grid.frame.mouseOver = mouseOver == true
    local update = grid.frame:GetScript("OnUpdate")
    if update then
        update(grid.frame)
    end
    source:GetScript("OnDragStop")(source)
    hovered = nil
    return drag, drop
end

-- Dragging a member onto another group's slot reports a slot-to-slot move.
local drag, drop = Drag(grid.boxes[9].rows[1], grid.boxes[1].rows[2])
assert(drag.kind == "slot" and drag.group == 2 and drag.slot == 1, "the drag reports the source slot")
assert(drop.kind == "slot" and drop.group == 1 and drop.slot == 2, "the drop reports the destination slot")
local ok, moved = layout.ApplyDrop(grid.model, drag, drop)
assert(ok and table.concat(moved.groups[1].slots, ",") == "A,X,B", "the reported gesture inserts at the target")

-- Dropping into an unclaimed subgroup box reports the subgroup to create.
drag, drop = Drag(grid.boxes[9].rows[1], grid.boxes[3].rows[1])
assert(drop.kind == "subgroup" and drop.subgroup == 3, "an unclaimed box reports its subgroup")
ok, moved = layout.ApplyDrop(grid.model, drag, drop)
assert(ok and moved.groups[3].subgroup == 3 and moved.groups[3].slots[1] == "X", "the gesture creates the bound group")

-- Dropping onto a claimed box's empty row appends to that group.
drag, drop = Drag(grid.boxes[9].rows[1], grid.boxes[1].rows[3])
assert(drop.kind == "group" and drop.group == 1, "an empty row in a claimed box appends to it")

-- A palette entry drags in as raw text, and dragging back onto the palette removes.
drag, drop = Drag(grid.boxes[10].rows[2], grid.boxes[1].rows[3])
assert(drag.kind == "text" and drag.text == "Kaza", "the palette drags a name as text")

drag, drop = Drag(grid.boxes[1].rows[1], grid.boxes[10].rows[1])
assert(drop.kind == "remove", "dropping onto the palette removes the slot")
ok, moved = layout.ApplyDrop(grid.model, drag, drop)
assert(ok and table.concat(moved.groups[1].slots, ",") == "B", "the reported gesture removes the slot")

-- Releasing on empty space inside the grid cancels; releasing away from it removes.
drag, drop = Drag(grid.boxes[1].rows[1], nil, true)
assert(drag == nil and drop == nil, "a release inside the grid over no target is cancelled")

drag, drop = Drag(grid.boxes[1].rows[1], nil, false)
assert(drop and drop.kind == "remove", "a release away from the grid removes the slot")

drag, drop = Drag(grid.boxes[10].rows[1], nil, false)
assert(drag == nil, "a palette entry released over nothing is not a removal")

-- A container that re-applies the width after every redraw, the way AceGUI's
-- flow layout does, must settle rather than recurse.
local passes = 0
grid.parent = {
    DoLayout = function()
        passes = passes + 1
        assert(passes < 10, "redrawing the grid settles instead of recursing")
        grid:SetWidth(passes == 1 and 360 or grid.frame:GetWidth())
    end,
}
grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores: X"))
assert(passes == 2, "a width change redraws once more and then settles")
assert(grid.frame:GetWidth() == 360, "the grid keeps the width its container assigned")
grid.parent = nil

-- Release clears the drag state so a stale gesture cannot fire later.
grid:OnRelease()
assert(grid.dragging == nil and grid.dropTarget == nil, "release clears the pending drag")
assert(grid.frame:GetScript("OnUpdate") == nil, "release stops the drag update loop")

print("Layout grid tests passed.")
