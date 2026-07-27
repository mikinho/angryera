local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

assert(loadfile("modules/layout.lua"))("AngryEra", app)
local layout = AngryEra.utils.layout

-- Which edge each anchor point pins, per axis. A point that pins neither edge of
-- an axis (a centred one) resolves to nothing there, the way the client leaves
-- it to the region's own size.
local HORIZONTAL = {
    LEFT = "left",
    TOPLEFT = "left",
    BOTTOMLEFT = "left",
    RIGHT = "right",
    TOPRIGHT = "right",
    BOTTOMRIGHT = "right",
}

local VERTICAL = {
    TOP = "top",
    TOPLEFT = "top",
    TOPRIGHT = "top",
    BOTTOM = "bottom",
    BOTTOMLEFT = "bottom",
    BOTTOMRIGHT = "bottom",
}

local AXIS = { left = HORIZONTAL, right = HORIZONTAL, top = VERTICAL, bottom = VERTICAL }
local OPPOSITE = { left = "right", right = "left", top = "bottom", bottom = "top" }
local SIZE = { left = "width", right = "width", top = "height", bottom = "height" }
local SHIFT = { left = "x", right = "x", top = "y", bottom = "y" }
-- Stepping from an edge to its opposite runs right and up.
local DIRECTION = { left = -1, right = 1, top = 1, bottom = -1 }

local EdgeOf

-- Where one anchor point of `region` lands on the axis `edge` belongs to.
local function PointOf(region, point, edge)
    local named = AXIS[edge][point]
    if not named then
        return nil
    end
    return EdgeOf(region, named)
end

-- Resolves an edge from whichever anchor pins it, falling back to the opposite
-- edge and the region's own size. A region nothing has placed reports nothing,
-- the way an unplaced frame does in-game.
function EdgeOf(region, edge, derived)
    if region.rect then
        return region.rect[edge]
    end

    for point, anchor in pairs(region.points) do
        if AXIS[edge][point] == edge then
            local base = PointOf(anchor.relativeTo, anchor.relativePoint, edge)
            if base then
                return base + anchor[SHIFT[edge]]
            end
        end
    end

    if derived then
        return nil
    end

    local opposite = EdgeOf(region, OPPOSITE[edge], true)
    if not opposite then
        return nil
    end
    return opposite + (DIRECTION[edge] * region[SIZE[edge]])
end

-- Stubbed frame API. Regions record what the widget reads back: size,
-- visibility, text, frame level, and enough of the anchor graph for the
-- geometry hit-test to resolve real edges.
local function NewRegion(parent)
    local region = {
        parent = parent,
        shown = true,
        width = 0,
        height = 0,
        frameLevel = parent and (parent.frameLevel or 0) + 1 or 0,
        points = {},
        scripts = {},
        dragButtons = {},
    }

    -- SetPoint(point) / (point, x, y) / (point, relativeTo, relativePoint[, x, y]).
    function region:SetPoint(point, a, b, c, d)
        if a == nil or type(a) == "number" then
            self.points[point] = { relativeTo = self.parent, relativePoint = point, x = a or 0, y = b or 0 }
            return
        end
        self.points[point] = { relativeTo = a, relativePoint = b or point, x = c or 0, y = d or 0 }
    end
    function region:ClearAllPoints()
        self.points = {}
    end
    function region:SetAllPoints(relative)
        local target = relative or self.parent
        self.points = {
            TOPLEFT = { relativeTo = target, relativePoint = "TOPLEFT", x = 0, y = 0 },
            BOTTOMRIGHT = { relativeTo = target, relativePoint = "BOTTOMRIGHT", x = 0, y = 0 },
        }
    end
    function region:GetLeft()
        return EdgeOf(self, "left")
    end
    function region:GetRight()
        return EdgeOf(self, "right")
    end
    function region:GetTop()
        return EdgeOf(self, "top")
    end
    function region:GetBottom()
        return EdgeOf(self, "bottom")
    end
    function region:GetEffectiveScale()
        return 1
    end
    function region:SetFrameLevel(level)
        self.frameLevel = level
    end
    function region:GetFrameLevel()
        return self.frameLevel or 0
    end
    function region:EnableMouse(enabled)
        self.mouseEnabled = enabled and true or false
    end
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
    function region:GetParent()
        return self.parent
    end
    function region:SetParent(value)
        self.parent = value
    end
    function region:SetScript(name, handler)
        self.scripts[name] = handler
    end
    function region:GetScript(name)
        return self.scripts[name]
    end
    function region:RegisterForDrag(...)
        self.dragButtons = { ... }
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
_G.UIParent.rect = { left = 0, bottom = 0, right = 1024, top = 768 }

function _G.CreateFrame(_, _, parent)
    return NewRegion(parent or _G.UIParent)
end
function _G.SetCursor() end
function _G.CloseDropDownMenus() end

local cursorX, cursorY = 0, 0

function _G.GetCursorPosition()
    return cursorX, cursorY
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
    -- AceGUI hands a callback the widget and the event name before anything the
    -- widget fired, and swallows whatever the handler raises. A stub that leaves
    -- the event name out lets a host misread every argument and still pass here,
    -- which is how dragging came to do nothing in game while this suite was green.
    function widget:Fire(name, ...)
        local handler = self.callbacks[name]
        if handler then
            handler(self, name, ...)
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
grid.frame:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 0, 0)
grid:SetLayoutEngine(layout)
grid:SetRoster({ "Vhez", "Kaza" })
grid:SetWidth(400)
grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores/3: X"))

-- The palette is always the last box drawn, so its position never has to be
-- counted out here.
local function PaletteBox()
    for index = #grid.boxes, 1, -1 do
        if grid.boxes[index]:IsShown() then
            return grid.boxes[index]
        end
    end
end

-- The grid always draws the eight raid subgroup boxes, then the palette.
local visible = 0
for _, box in ipairs(grid.boxes) do
    if box:IsShown() then
        visible = visible + 1
    end
end
assert(visible == 9, "eight subgroup boxes plus the palette are drawn")
assert(grid.boxes[1].header.label:GetText() == "Main", "a group titles the subgroup box it holds")
assert(grid.boxes[2].header.label:GetText() == "Group 2", "an unclaimed subgroup box is titled by number")
assert(grid.boxes[3].header.label:GetText() == "Spores", "a named group titles the subgroup it was given")
assert(PaletteBox() == grid.boxes[9], "the palette is drawn last")
assert(PaletteBox().header.label:GetText() == "Unrostered", "the palette holds whoever the layout has not placed")
assert(grid.frame:GetHeight() > 0, "the grid reports a height for its container")

-- Groups run two to a row, odd on the left and even on the right, with the
-- palette standing in a third column beside them.
local palette = PaletteBox()
assert(grid.boxes[1]:GetLeft() == grid.frame:GetLeft(), "the first group opens the left column")
assert(grid.boxes[2]:GetLeft() > grid.boxes[1]:GetLeft(), "an even-numbered group stands in the right column")
assert(grid.boxes[3]:GetLeft() == grid.boxes[1]:GetLeft(), "an odd-numbered group returns to the left column")
assert(grid.boxes[2]:GetTop() == grid.boxes[1]:GetTop(), "the two columns share a top")
assert(grid.boxes[3]:GetTop() < grid.boxes[1]:GetTop(), "the second row of groups sits below the first")
assert(palette:GetLeft() >= grid.boxes[2]:GetRight(), "the palette clears both group columns")
assert(palette:GetRight() <= grid.frame:GetRight(), "the palette stays inside the grid")
assert(palette:GetTop() == grid.frame:GetTop(), "the palette starts at the top of the grid")

-- Rows carry the target the hit-test reads back.
local filled = grid.boxes[1].rows[1]
assert(filled.label:GetText() == "A" and filled.layoutTarget.kind == "slot", "a filled row targets its slot")
assert(filled.layoutTarget.group == 1 and filled.layoutTarget.slot == 1, "a filled row knows its position")

local blank = grid.boxes[1].rows[3]
assert(blank.label:GetText() == "" and blank.layoutTarget.kind == "empty", "an empty row targets its group")
assert(blank.layoutTarget.group == 1, "an empty row in a claimed box appends to that group")

local unclaimed = grid.boxes[2].rows[1]
assert(unclaimed.layoutTarget.group == nil, "an unclaimed box has no group yet")
assert(unclaimed.layoutTarget.subgroup == 2, "an unclaimed box targets its subgroup")

local paletteTarget = palette.rows[1].layoutTarget
assert(paletteTarget.kind == "palette" and paletteTarget.text == "Vhez", "the palette carries names")

-- The middle of a region, where a gesture aimed at it starts or lands.
local function CentreOf(region)
    return (region:GetLeft() + region:GetRight()) / 2, (region:GetTop() + region:GetBottom()) / 2
end

-- The client fires OnClick only for a press that did not become a drag, so a
-- click is that handler on its own.
local function Click(target, button)
    cursorX, cursorY = CentreOf(target)
    target:GetScript("OnClick")(target, button)
end

-- Clicks report their position so the host can act on a row without a drag.
local clicked
grid:SetCallback("OnSlotClick", function(_, event, group, slot, button)
    clicked = { event = event, group = group, slot = slot, button = button }
end)
Click(filled, "RightButton")
assert(clicked.event == "OnSlotClick", "a callback is handed the event name before what was fired")
assert(clicked.group == 1 and clicked.slot == 1, "a slot click reports its position")
assert(clicked.button == "RightButton", "a slot click reports the mouse button")

clicked = nil
Click(filled, "LeftButton")
assert(clicked and clicked.button == "LeftButton", "a left click reaches the same handler")

-- Only a row holding something registers for dragging, so the client starts a
-- gesture on a filled row and a click on an unused one.
assert(#filled.dragButtons == 1, "a filled row can start a drag")
assert(#grid.boxes[1].rows[3].dragButtons == 0, "an empty row cannot start a drag")
assert(#palette.rows[1].dragButtons == 1, "a palette name can start a drag")
assert(filled.mouseEnabled, "rows take mouse input")
assert(grid.boxes[1].header.mouseEnabled, "box titles take mouse input")

local headerClicked
grid:SetCallback("OnGroupClick", function(_, _, group, subgroup)
    headerClicked = { group = group, subgroup = subgroup }
end)
Click(grid.boxes[2].header, "LeftButton")
assert(headerClicked.group == nil and headerClicked.subgroup == 2, "a header click reports its subgroup")

local emptyClicked
grid:SetCallback("OnEmptyClick", function(_, _, group, subgroup)
    emptyClicked = { group = group, subgroup = subgroup }
end)
headerClicked = nil
Click(blank, "LeftButton")
assert(emptyClicked.group == 1 and emptyClicked.subgroup == 1, "an empty row click reports its box")
assert(not headerClicked, "clicking blank space does not act on the group itself")

-- Drives one drag gesture to a point and returns what it reported.
local function GestureTo(source, x, y)
    local drag, drop
    grid:SetCallback("OnLayoutDrop", function(_, _, firedDrag, firedDrop)
        drag, drop = firedDrag, firedDrop
    end)

    cursorX, cursorY = CentreOf(source)
    source:GetScript("OnDragStart")(source)

    cursorX, cursorY = x, y
    local update = grid.frame:GetScript("OnUpdate")
    if update then
        update(grid.frame)
    end

    source:GetScript("OnDragStop")(source)
    return drag, drop
end

local function DragTo(source, target)
    return GestureTo(source, CentreOf(target))
end

-- The regression that made dragging look dead in-game: the marker sat on the
-- widget frame's own draw layer, which a child frame always covers, so a drag
-- gave no feedback at all.
local marked = grid.boxes[1].rows[2]
local source = grid.boxes[3].rows[1]
cursorX, cursorY = CentreOf(source)
source:GetScript("OnDragStart")(source)
assert(not grid.dropMarker:IsShown(), "a gesture that has not moved yet marks nothing")
cursorX, cursorY = CentreOf(marked)
grid.frame:GetScript("OnUpdate")(grid.frame)
assert(grid.dropMarker:IsShown(), "a drag marks where a release would land")
assert(grid.dropMarker:GetTop() == marked:GetTop(), "the marker covers the row under the cursor")
assert(grid.dropMarker:GetFrameLevel() > marked:GetFrameLevel(), "the marker draws above the row it covers")
source:GetScript("OnDragStop")(source)
assert(not grid.dropMarker:IsShown(), "the marker clears when the gesture ends")

-- Dragging a member onto another group's slot reports a slot-to-slot move.
local drag, drop = DragTo(grid.boxes[3].rows[1], grid.boxes[1].rows[2])
assert(drag.kind == "slot" and drag.group == 2 and drag.slot == 1, "the drag reports the source slot")
assert(drop.kind == "slot" and drop.group == 1 and drop.slot == 2, "the drop reports the destination slot")
local ok, moved = layout.ApplyDrop(grid.model, drag, drop)
assert(ok and table.concat(moved.groups[1].slots, ",") == "A,X,B", "the reported gesture inserts at the target")

-- Dropping into an unclaimed subgroup box reports the subgroup to create.
drag, drop = DragTo(grid.boxes[3].rows[1], grid.boxes[4].rows[1])
assert(drop.kind == "subgroup" and drop.subgroup == 4, "an unclaimed box reports its subgroup")
ok, moved = layout.ApplyDrop(grid.model, drag, drop)
assert(ok and moved.groups[3].subgroup == 4 and moved.groups[3].slots[1] == "X", "the gesture creates the bound group")

-- Dropping onto a claimed box's empty row appends to that group.
drag, drop = DragTo(grid.boxes[3].rows[1], blank)
assert(drop.kind == "group" and drop.group == 1, "an empty row in a claimed box appends to it")

-- A palette entry drags in as raw text, and dragging back onto the palette removes.
drag, drop = DragTo(palette.rows[2], blank)
assert(drag.kind == "text" and drag.text == "Kaza", "the palette drags a name as text")

drag, drop = DragTo(filled, palette.rows[1])
assert(drop.kind == "remove", "dropping onto the palette removes the slot")
ok, moved = layout.ApplyDrop(grid.model, drag, drop)
assert(ok and table.concat(moved.groups[1].slots, ",") == "B", "the reported gesture removes the slot")

-- An unused row has nothing to pick up, and travelling off it is not a click on
-- it either.
emptyClicked = nil
drag, drop = DragTo(blank, grid.boxes[2].rows[1])
assert(drag == nil and drop == nil, "an unused row cannot start a drag")
assert(not emptyClicked, "a press that travelled off a row is not a click on it")

-- Releasing on empty space inside the grid cancels; releasing away from it removes.
local insideX = select(1, CentreOf(palette))
local insideY = grid.frame:GetBottom() + 1
assert(insideY < palette:GetBottom(), "the cancel point clears the palette")
drag, drop = GestureTo(filled, insideX, insideY)
assert(drag == nil and drop == nil, "a release inside the grid over no target is cancelled")

local awayX = grid.frame:GetRight() + 50
drag, drop = GestureTo(filled, awayX, grid.frame:GetTop())
assert(drop and drop.kind == "remove", "a release away from the grid removes the slot")

drag, drop = GestureTo(palette.rows[1], awayX, grid.frame:GetTop())
assert(drag == nil, "a palette entry released over nothing is not a removal")

-- The palette offers only members the layout has not named, matched however the
-- slot happens to be spelled.
grid:SetLayoutModel(layout.Parse("Main/1: vhez"))
palette = PaletteBox()
assert(palette.rows[1].layoutTarget.text == "Kaza", "a placed member leaves the palette")
assert(not palette.rows[2]:IsShown(), "the palette shrinks to whoever is left")

grid:SetRoster({ "Vhez", "Kaza", "Ghoal" })
palette = PaletteBox()
assert(palette.rows[2].layoutTarget.text == "Ghoal", "a member joining the raid reaches the palette")

grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores: X"))
palette = PaletteBox()
assert(palette.rows[3].layoutTarget.text == "Ghoal", "clearing a slot returns its member to the palette")

-- The grid measures itself so its container can grow to the whole layout rather
-- than scroll it. Only a change is reported, because a container that resizes in
-- answer re-flows the grid, and re-reporting from that pass would bounce them.
local measured, reports = nil, 0
grid:SetCallback("OnHeightMeasured", function(_, _, height)
    measured, reports = height, reports + 1
end)

-- The eight subgroup boxes stand whether or not a group holds them, so what the
-- layout says never changes how tall the grid is.
grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores: X; Extra: Y; More: Z"))
assert(reports == 0, "a layout with more groups in it is the same eight boxes")

local crowd = {}
for index = 1, 30 do
    crowd[index] = "Spare" .. index
end
grid:SetRoster(crowd)
assert(reports == 1, "a palette taller than the group columns reports its new height")
assert(measured == grid.frame:GetHeight(), "the reported height is the one the grid drew to")
grid:SetCallback("OnHeightMeasured", nil)

grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores: X"))

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

-- Release clears the gesture so a stale press cannot fire later.
grid:OnRelease()
assert(grid.pressed == nil and grid.dragging == nil, "release clears the pending gesture")
assert(grid.dropTarget == nil, "release clears the pending drop")
assert(grid.frame:GetScript("OnUpdate") == nil, "release stops the drag update loop")
assert(grid.measuredHeight == nil, "release forgets the measured height so a reused grid reports to its new host")

print("Layout grid tests passed.")
