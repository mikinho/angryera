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
    function region:SetAlpha(alpha)
        self.alpha = alpha
    end
    function region:GetAlpha()
        return self.alpha or 1
    end
    function region:EnableMouse(enabled)
        self.mouseEnabled = enabled and true or false
    end
    function region:EnableMouseWheel(enabled)
        self.mouseWheelEnabled = enabled and true or false
    end
    function region:SetJustifyH(value)
        self.justifyH = value
    end
    function region:SetFontObject(value)
        self.fontObject = value
    end
    function region:SetTextColor(...)
        self.textColor = { ... }
    end
    function region:SetBackdrop(value)
        self.backdrop = value
    end
    function region:SetBackdropColor(...)
        self.backdropColor = { ... }
    end
    function region:SetBackdropBorderColor(...)
        self.backdropBorderColor = { ... }
    end
    function region:SetColorTexture(...)
        self.color = { ... }
    end
    function region:SetTexture(value)
        self.texture = value
    end
    function region:SetTexCoord(...)
        self.texCoord = { ... }
    end
    function region:SetBlendMode(value)
        self.blendMode = value
    end
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
    function region:SetMinMaxValues(minimum, maximum)
        self.minimum, self.maximum = minimum, maximum
        if self.value then
            self.value = math.max(minimum, math.min(maximum, self.value))
        end
    end
    function region:GetMinMaxValues()
        return self.minimum or 0, self.maximum or 0
    end
    function region:SetValueStep(step)
        self.valueStep = step
    end
    function region:SetValue(value)
        local minimum, maximum = self:GetMinMaxValues()
        local clamped = math.max(minimum, math.min(maximum, value))
        if clamped == self.value then
            return
        end
        self.value = clamped
        local handler = self:GetScript("OnValueChanged")
        if handler then
            handler(self, clamped)
        end
    end
    function region:GetValue()
        return self.value or 0
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
_G.EMPTY = "Localized Empty"
_G.GameFontDarkGraySmall = "GameFontDarkGraySmall"
_G.GameFontHighlightSmall = "GameFontHighlightSmall"

function _G.CreateFrame(_, _, parent)
    return NewRegion(parent or _G.UIParent)
end
local cursorTexture
function _G.SetCursor(value)
    cursorTexture = value
end
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

function AceGUI.RegisterAsWidget(_, widget)
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
grid:SetWidth(600)
grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores/3: X"))
local safeDropFrame = NewRegion(_G.UIParent)
safeDropFrame.rect = { left = -10, bottom = 250, right = 620, top = 780 }
grid:SetSafeDropFrame(safeDropFrame)

local function BoxByTitle(title)
    for _, box in ipairs(grid.boxes) do
        if box:IsShown() and box.header.label:GetText() == title then
            return box
        end
    end
end

local function PaletteBox()
    return BoxByTitle("Unrostered")
end

local function VariablesBox()
    return BoxByTitle("Variables")
end

-- The grid always draws the eight raid subgroup boxes, then both palettes.
local visible = 0
for _, box in ipairs(grid.boxes) do
    if box:IsShown() then
        visible = visible + 1
    end
end
assert(visible == 10, "eight subgroup boxes plus both palettes are drawn")
assert(grid.boxes[1].header.label:GetText() == "Main", "a group titles the subgroup box it holds")
assert(grid.boxes[2].header.label:GetText() == "Group 2", "an unclaimed subgroup box is titled by number")
assert(grid.boxes[3].header.label:GetText() == "Spores", "a named group titles the subgroup it was given")
assert(PaletteBox() == grid.boxes[9], "the unrostered palette follows the subgroup boxes")
assert(VariablesBox() == grid.boxes[10], "the variables palette is drawn last")
assert(PaletteBox().header.label:GetText() == "Unrostered", "the palette holds whoever the layout has not placed")
assert(VariablesBox().header.label:GetText() == "Variables", "the variables palette holds reusable expressions")
assert(grid.frame:GetHeight() > 0, "the grid reports a height for its container")
assert(
    VariablesBox().rows[1].label:GetText() == ""
        and VariablesBox().rows[1].label.justifyH == "LEFT"
        and VariablesBox().rows[1].label.fontObject == "GameFontHighlightSmall"
        and not VariablesBox().rows[1].background:IsShown()
        and not VariablesBox().rows[1].highlight:IsShown()
        and #VariablesBox().rows[1].dragButtons == 0,
    "an empty palette stays blank instead of borrowing the raid Empty treatment"
)
for index = 1, 8 do
    assert(grid.boxes[index].header.label.justifyH == "CENTER", "raid group titles are centered")
end
assert(PaletteBox().header.label.justifyH == "LEFT", "the Unrostered title stays list-aligned")
assert(VariablesBox().header.label.justifyH == "LEFT", "the Variables title stays list-aligned")

-- Raid boxes mirror the native frame's five explicit roster slots. Empty is
-- display-only: it remains the same non-draggable click/drop target.
for subgroup = 1, 8 do
    local shown = 0
    for _, row in ipairs(grid.boxes[subgroup].rows) do
        if row:IsShown() then
            shown = shown + 1
            if row.layoutTarget.kind == "empty" then
                assert(row.label:GetText() == "Localized Empty", "unused raid rows use the localized Empty label")
                assert(row.label.justifyH == "CENTER", "unused raid rows use the native centered label")
                assert(row.label.fontObject == "GameFontDarkGraySmall", "unused raid rows use the native muted font")
                assert(row.background:IsShown(), "unused raid rows retain their slot background")
                assert(
                    row.background.texture == "Interface\\RaidFrame\\UI-RaidFrame-GroupButton",
                    "raid rows reuse the native slot texture"
                )
                assert(row.background:GetHeight() == 14, "native raid row art leaves a one-pixel slot gap")
                assert(#row.dragButtons == 0, "the Empty label does not turn an unused row into a drag source")
            end
        end
    end
    assert(shown == 5, "every raid subgroup shows exactly five slots")
end

-- The same pooled row fully resets when a slot alternates between occupied and
-- empty across redraws.
local pooledRow = grid.boxes[1].rows[5]
grid:SetLayoutModel(layout.Parse("Full/1: A, B, C, D, E; Spores/3: X"))
assert(
    pooledRow.label:GetText() == "E"
        and pooledRow.label.justifyH == "LEFT"
        and pooledRow.label.fontObject == "GameFontHighlightSmall"
        and #pooledRow.dragButtons == 1,
    "filling a pooled Empty row restores the occupied-row presentation"
)
grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores/3: X"))
assert(
    pooledRow.label:GetText() == "Localized Empty"
        and pooledRow.label.justifyH == "CENTER"
        and pooledRow.label.fontObject == "GameFontDarkGraySmall"
        and #pooledRow.dragButtons == 0,
    "emptying a pooled row restores the native placeholder presentation"
)

-- Groups run two to a row, odd on the left and even on the right, with the
-- two palettes standing beside them.
local palette = PaletteBox()
local variablesPalette = VariablesBox()
assert(grid.boxes[1]:GetLeft() == grid.frame:GetLeft(), "the first group opens the left column")
assert(grid.boxes[2]:GetLeft() > grid.boxes[1]:GetLeft(), "an even-numbered group stands in the right column")
assert(grid.boxes[3]:GetLeft() == grid.boxes[1]:GetLeft(), "an odd-numbered group returns to the left column")
assert(grid.boxes[2]:GetTop() == grid.boxes[1]:GetTop(), "the two columns share a top")
assert(grid.boxes[3]:GetTop() < grid.boxes[1]:GetTop(), "the second row of groups sits below the first")
assert(palette:GetLeft() >= grid.boxes[2]:GetRight(), "the palette clears both group columns")
assert(variablesPalette:GetLeft() >= palette:GetRight(), "Variables stands to the right of Unrostered")
assert(variablesPalette:GetRight() <= grid.frame:GetRight(), "the variables palette stays inside the grid")
assert(palette:GetTop() == grid.frame:GetTop(), "the palette starts at the top of the grid")
assert(variablesPalette:GetTop() == grid.frame:GetTop(), "the variables palette starts at the top of the grid")
assert(palette:GetHeight() == grid.frame:GetHeight(), "the palette is fixed to the complete subgroup canvas")
assert(variablesPalette:GetHeight() == grid.frame:GetHeight(), "Variables shares the fixed subgroup canvas")
assert(not palette.scrollbar:IsShown(), "a short unrostered list needs no scrollbar")
assert(not variablesPalette.scrollbar:IsShown(), "an empty variables list needs no scrollbar")

-- Rows carry the target the hit-test reads back.
local filled = grid.boxes[1].rows[1]
assert(filled.label:GetText() == "A" and filled.layoutTarget.kind == "slot", "a filled row targets its slot")
assert(filled.layoutTarget.group == 1 and filled.layoutTarget.slot == 1, "a filled row knows its position")
assert(filled.label.justifyH == "LEFT", "filled rows keep names left-aligned")
assert(filled.label.fontObject == "GameFontHighlightSmall", "filled rows retain the normal roster font")
assert(filled.label:GetLeft() - filled:GetLeft() == 8, "roster names have a small native-style left inset")

local blank = grid.boxes[1].rows[3]
assert(
    blank.label:GetText() == "Localized Empty" and blank.layoutTarget.kind == "empty",
    "an empty row targets its group"
)
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

-- Inherited layouts remain visible but cannot emit any editing gesture.
clicked, headerClicked, emptyClicked = nil, nil, nil
grid:SetDisabled(true)
assert(grid.disabled and grid.frame:GetAlpha() == 0.55, "disabled layouts are visibly read-only")
Click(filled, "LeftButton")
Click(grid.boxes[2].header, "LeftButton")
Click(blank, "LeftButton")
assert(not clicked and not headerClicked and not emptyClicked, "disabled layouts suppress every click mutation")
local disabledDrag, disabledDrop = DragTo(filled, grid.boxes[3].rows[1])
assert(disabledDrag == nil and disabledDrop == nil, "disabled layouts suppress drag/drop mutations")
assert(cursorTexture == nil and not grid.dropMarker:IsShown(), "disabled dragging never captures the cursor or marker")
grid:SetDisabled(false)
assert(not grid.disabled and grid.frame:GetAlpha() == 1, "an override can re-enable the layout editor")
Click(filled, "LeftButton")
assert(clicked and clicked.button == "LeftButton", "re-enabled layouts emit edits normally")

-- Checking Inherit while a drag is already active cancels it immediately.
cursorX, cursorY = CentreOf(grid.boxes[3].rows[1])
grid.boxes[3].rows[1]:GetScript("OnDragStart")(grid.boxes[3].rows[1])
assert(cursorTexture ~= nil and grid.frame:GetScript("OnUpdate"), "the fixture starts a live drag")
grid:SetDisabled(true)
assert(
    cursorTexture == nil
        and grid.frame:GetScript("OnUpdate") == nil
        and not grid.dropMarker:IsShown()
        and grid.dragging == nil,
    "switching to inherited mode cancels a live drag"
)
grid:SetDisabled(false)

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
local markerFill = grid.dropMarker.fill
assert(
    markerFill.texture == "Interface\\RaidFrame\\UI-RaidFrame-GroupButton",
    "the drop marker reuses the native raid highlight"
)
assert(markerFill.texCoord[3] == 0.5 and markerFill.texCoord[4] == 0.9375, "the drop marker uses the highlight art")
assert(markerFill.blendMode == "ADD", "the native drop marker adds its gold highlight over the target")
assert(markerFill:GetHeight() == 14, "the drop marker matches the native slot art height")
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
local _, appendDrop = DragTo(grid.boxes[3].rows[1], blank)
assert(appendDrop.kind == "group" and appendDrop.group == 1, "an empty row in a claimed box appends to it")

-- A palette entry drags in as raw text, and dragging back onto the palette removes.
local paletteDrag = DragTo(palette.rows[2], blank)
assert(paletteDrag.kind == "text" and paletteDrag.text == "Kaza", "the palette drags a name as text")

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
local insideY = palette.rows[2]:GetBottom() - 1
assert(insideY > palette:GetBottom(), "the cancel point sits in unused palette space")
drag, drop = GestureTo(filled, insideX, insideY)
assert(drag == nil and drop == nil, "a release inside the grid over no target is cancelled")

local controlsY = grid.frame:GetBottom() - 20
drag, drop = GestureTo(filled, insideX, controlsY)
assert(drag == nil and drop == nil, "a release over editor controls outside the grid is cancelled")

local awayX = grid.frame:GetRight() + 50
local _, outsideDrop = GestureTo(filled, awayX, grid.frame:GetTop())
assert(outsideDrop and outsideDrop.kind == "remove", "a release outside the editor removes the slot")

local paletteOutsideDrag = GestureTo(palette.rows[1], awayX, grid.frame:GetTop())
assert(paletteOutsideDrag == nil, "a palette entry released over nothing is not a removal")

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

-- The palette follows the resolved layout, not only literal slot spelling.
-- Priority, class-fill, and variable slots therefore hide the members they
-- currently place.
grid:SetResolveProviders({
    ResolvePriorityValue = function(value)
        if value == "Missing > Vhez" then
            return "Vhez"
        end
        return value
    end,
    ClassMembers = function(class)
        return class == "MAGE" and { "Kaza" } or {}
    end,
    SubgroupMembers = function()
        return {}
    end,
    Variables = {
        alpha = "Vhez",
        Count = 2,
        Empty = "",
        FLEX = "Ghoal",
        NeedsPage = "{{MISSING}}",
        ["Pipe|Role"] = "Vhez",
        Enabled = true,
        Nested = { Name = "Nope" },
        ["$LAYOUT"] = "Main/1: A",
        ["$CUSTOM"] = "metadata",
        [" Bad "] = "trimmed keys cannot round-trip",
        ["Bad,Key"] = "commas split slots",
        ["Bad;Key"] = "semicolons split groups",
        ["Bad{Key"] = "braces break tokens",
    },
})

variablesPalette = VariablesBox()
assert(variablesPalette.rows[1].label:GetText() == "{{alpha}} = Vhez", "variables sort by name")
assert(variablesPalette.rows[2].label:GetText() == "{{Empty}} = (empty)", "empty variables remain available")
assert(variablesPalette.rows[3].label:GetText() == "{{FLEX}} = Ghoal", "string variables show their resolved value")
assert(
    variablesPalette.rows[4].label:GetText() == "{{NeedsPage}} = [unresolved] {{MISSING}}",
    "an unresolved string remains visible and clearly labelled"
)
assert(
    variablesPalette.rows[5].label:GetText() == "{{Pipe||Role}} = Vhez"
        and variablesPalette.rows[5].layoutTarget.text == "{{Pipe|Role}}",
    "pipe characters are escaped only in the variable's display label"
)
assert(
    not variablesPalette.rows[6] or not variablesPalette.rows[6]:IsShown(),
    "metadata, numeric, structured, boolean, and unsafe-key values are excluded"
)
assert(
    variablesPalette.rows[3].layoutTarget.kind == "variable"
        and variablesPalette.rows[3].layoutTarget.text == "{{FLEX}}",
    "a variable row carries its exact reusable token"
)

local variableDrag, variableDrop = DragTo(variablesPalette.rows[3], blank)
assert(variableDrag.kind == "text" and variableDrag.text == "{{FLEX}}", "dragging uses the token, not its value")
assert(variableDrop.kind == "group" and variableDrop.group == 1, "a variable can be dropped into a layout group")
local variableApplied, variableModel = layout.ApplyDrop(grid.model, variableDrag, variableDrop)
assert(
    variableApplied and variableModel.groups[1].slots[3] == "{{FLEX}}",
    "dropping a variable stores its dynamic expression"
)
grid:SetLayoutModel(variableModel)
variablesPalette = VariablesBox()
assert(
    variablesPalette.rows[3].layoutTarget.text == "{{FLEX}}",
    "a variable stays in the source catalog after placement"
)

local variableCancelDrag, variableCancelDrop = DragTo(filled, variablesPalette.rows[3])
assert(
    variableCancelDrag == nil and variableCancelDrop == nil,
    "dropping a layout slot on Variables cancels instead of deleting it"
)
local variableToRosterDrag, variableToRosterDrop = DragTo(variablesPalette.rows[3], PaletteBox().rows[1])
assert(
    variableToRosterDrag == nil and variableToRosterDrop == nil,
    "dropping a reusable variable onto Unrostered cancels"
)
local pipeDrag, pipeDrop = DragTo(variablesPalette.rows[5], grid.boxes[1].rows[4])
local pipeApplied, pipeModel = layout.ApplyDrop(variableModel, pipeDrag, pipeDrop)
assert(pipeApplied and pipeModel.groups[1].slots[4] == "{{Pipe|Role}}", "pipe-key variables store their raw token")
grid:SetLayoutModel(pipeModel)
assert(grid.boxes[1].rows[4].label:GetText() == "{{Pipe||Role}}", "placed pipe tokens render as literal text")

grid:SetLayoutModel(layout.Parse("Main/1: Missing > Vhez, *MAGE, {{FLEX}}"))
palette = PaletteBox()
assert(palette.rows[1].layoutTarget.text == nil, "resolved slots leave no placed member in the palette")
assert(not palette.rows[2]:IsShown(), "an empty resolved palette stays at its one-row minimum")

-- Realm-safe identity resolution also deduplicates a short explicit slot against
-- the full name returned by a class fill. The fill advances to the next member.
grid:SetRoster({
    { Text = "Vhez", FullName = "Vhez-Realm", ShortName = "Vhez" },
    { Text = "Kaza", FullName = "Kaza-Realm", ShortName = "Kaza" },
})
grid:SetResolveProviders({
    ResolveRosterName = function(name)
        local full = {
            vhez = "Vhez-Realm",
            ["vhez-realm"] = "Vhez-Realm",
            kaza = "Kaza-Realm",
            ["kaza-realm"] = "Kaza-Realm",
        }
        return full[name:lower()]
    end,
    ClassMembers = function(class)
        return class == "MAGE" and { "Vhez-Realm", "Kaza-Realm" } or {}
    end,
})
grid:SetLayoutModel(layout.Parse("Main/1: Vhez, *MAGE"))
palette = PaletteBox()
assert(palette.rows[1].layoutTarget.text == nil, "a short slot and full-name fill do not select one member twice")

-- Ambiguous short names are never guessed. The editor can pass qualified
-- display text for both members and only an exact full-name slot removes one.
grid:SetResolveProviders({})
grid:SetRoster({
    { Text = "Alex-RealmA", FullName = "Alex-RealmA", ShortName = "Alex" },
    { Text = "Alex-RealmB", FullName = "Alex-RealmB", ShortName = "Alex" },
})
grid:SetLayoutModel(layout.Parse("Main/1: Alex"))
palette = PaletteBox()
assert(palette.rows[1].layoutTarget.text == "Alex-RealmA", "an ambiguous short slot does not hide the first realm")
assert(palette.rows[2].layoutTarget.text == "Alex-RealmB", "an ambiguous short slot does not hide the second realm")

grid:SetLayoutModel(layout.Parse("Main/1: Alex-RealmB"))
palette = PaletteBox()
assert(palette.rows[1].layoutTarget.text == "Alex-RealmA", "an exact full-name slot hides only its member")
assert(not palette.rows[2]:IsShown(), "the exact full-name match leaves one palette member")

-- The grid always measures to the complete eight-group canvas. A tall
-- unrostered palette scrolls internally instead of changing that height.
local measured, reports = nil, 0
grid:SetCallback("OnHeightMeasured", function(_, _, height)
    measured, reports = height, reports + 1
end)

-- The eight subgroup boxes stand whether or not a group holds them, so what the
-- layout says never changes how tall the grid is.
grid:SetLayoutModel(layout.Parse("Main/1: A, B; Spores: X; Extra: Y; More: Z"))
assert(reports == 0, "a layout with more groups in it is the same eight boxes")

grid:SetRoster({})
palette = PaletteBox()
assert(grid.frame:GetHeight() == 424, "an empty palette keeps all eight subgroup boxes visible")
assert(not palette.scrollbar:IsShown(), "an empty palette hides its scrollbar")

local crowd = {}
for index = 1, 30 do
    crowd[index] = "Spare" .. index
end
grid:SetRoster(crowd)
palette = PaletteBox()
assert(reports == 0 and measured == nil, "a tall palette never asks the outer window to grow")
assert(grid.frame:GetHeight() == 424, "thirty unrostered members keep the subgroup canvas fixed")
assert(palette.scrollbar:IsShown(), "a palette taller than its viewport shows its own scrollbar")
local minimum, maximum = palette.scrollbar:GetMinMaxValues()
assert(minimum == 0 and maximum == 4, "the scrollbar exposes every hidden palette row")
assert(palette.rows[1].layoutTarget.text == "Spare1", "the palette begins with the first unrostered member")
assert(palette.rows[26].layoutTarget.text == "Spare26", "twenty-six palette rows fit beside the groups")

palette.scrollbar:SetValue(maximum)
assert(palette.rows[1].layoutTarget.text == "Spare5", "scrolling advances the first visible roster member")
assert(palette.rows[26].layoutTarget.text == "Spare30", "scrolling to the end exposes the final roster member")
assert(palette.rows[1].layoutTarget.kind == "palette", "a scrolled row retains its palette drag target")
local scrolledDrag = DragTo(palette.rows[1], blank)
assert(scrolledDrag.text == "Spare5", "dragging a scrolled row carries the offset roster member")

local gutterDrag, gutterDrop = GestureTo(filled, CentreOf(palette.scrollbar))
assert(gutterDrag == nil and gutterDrop == nil, "dropping over the scrollbar gutter cancels instead of removing")
local scrollbarTopX = select(1, CentreOf(palette.scrollbar))
local scrollbarTopY = palette.scrollbar:GetTop() - 1
local topGutterDrag, topGutterDrop = GestureTo(filled, scrollbarTopX, scrollbarTopY)
assert(topGutterDrag == nil and topGutterDrop == nil, "the scrollbar arrow area also cancels a drop")

palette.rows[1]:GetScript("OnMouseWheel")(palette.rows[1], 1)
assert(palette.rows[1].layoutTarget.text == "Spare2", "the mouse wheel scrolls the palette without moving the grid")

for index = 31, 40 do
    crowd[index] = "Spare" .. index
end
grid:SetRoster(crowd)
palette = PaletteBox()
minimum, maximum = palette.scrollbar:GetMinMaxValues()
assert(minimum == 0 and maximum == 14, "a full raid-sized palette remains independently scrollable")
palette.scrollbar:SetValue(maximum)
assert(palette.rows[1].layoutTarget.text == "Spare15", "the full palette scrolls to its final viewport")
assert(palette.rows[26].layoutTarget.text == "Spare40", "the fortieth member is reachable without outer scrolling")
assert(grid.frame:GetHeight() == 424, "forty unrostered members still keep every subgroup visible")
grid:SetDisabled(true)
palette.rows[1]:GetScript("OnMouseWheel")(palette.rows[1], 1)
assert(palette.scrollbar:GetValue() == maximum - 3, "an inherited preview remains scrollable without becoming editable")
grid:SetDisabled(false)
palette.scrollbar:SetValue(maximum)

grid:SetResolveProviders({
    Variables = {
        A1B = "Mixed",
        A10 = "TenA",
        A2 = "TwoA",
        HEALER10 = "Ten",
        HEALER2 = "Two",
        HEALER1 = "One",
        HUGE100000000000000000000 = "HugeLater",
        HUGE99999999999999999999 = "HugeEarlier",
    },
})
variablesPalette = VariablesBox()
assert(
    variablesPalette.rows[1].layoutTarget.text == "{{A2}}"
        and variablesPalette.rows[2].layoutTarget.text == "{{A10}}"
        and variablesPalette.rows[3].layoutTarget.text == "{{A1B}}"
        and variablesPalette.rows[4].layoutTarget.text == "{{HEALER1}}"
        and variablesPalette.rows[5].layoutTarget.text == "{{HEALER2}}"
        and variablesPalette.rows[6].layoutTarget.text == "{{HEALER10}}"
        and variablesPalette.rows[7].layoutTarget.text == "{{HUGE99999999999999999999}}"
        and variablesPalette.rows[8].layoutTarget.text == "{{HUGE100000000000000000000}}",
    "numbered variable families sort naturally in the Variables palette"
)

-- Variables virtualize and scroll independently from Unrostered. Moving either
-- viewport must not disturb the other one.
local manyVariables = {}
for index = 1, 30 do
    manyVariables[("ROLE%02d"):format(index)] = "Variable" .. index
end
grid:SetResolveProviders({ Variables = manyVariables })
palette = PaletteBox()
variablesPalette = VariablesBox()
local variableMinimum, variableMaximum = variablesPalette.scrollbar:GetMinMaxValues()
assert(variableMinimum == 0 and variableMaximum == 4, "thirty variables expose every hidden variable row")
assert(palette.scrollbar:GetValue() == 14, "adding variables preserves the Unrostered viewport")
assert(variablesPalette.rows[1].layoutTarget.text == "{{ROLE01}}", "Variables begins with its first token")
assert(variablesPalette.rows[26].layoutTarget.text == "{{ROLE26}}", "twenty-six variable rows fit beside the groups")

variablesPalette.scrollbar:SetValue(variableMaximum)
assert(variablesPalette.rows[1].layoutTarget.text == "{{ROLE05}}", "Variables scrolls to its fifth token")
assert(variablesPalette.rows[26].layoutTarget.text == "{{ROLE30}}", "the final variable is reachable")
assert(palette.scrollbar:GetValue() == 14, "scrolling Variables leaves Unrostered untouched")
local scrolledVariableDrag = DragTo(variablesPalette.rows[1], blank)
assert(
    scrolledVariableDrag.kind == "text" and scrolledVariableDrag.text == "{{ROLE05}}",
    "dragging a scrolled variable carries its exact token"
)

local variableGutterDrag, variableGutterDrop = GestureTo(filled, CentreOf(variablesPalette.scrollbar))
assert(variableGutterDrag == nil and variableGutterDrop == nil, "dropping over the Variables scrollbar gutter cancels")

variablesPalette.rows[1]:GetScript("OnMouseWheel")(variablesPalette.rows[1], 1)
assert(variablesPalette.rows[1].layoutTarget.text == "{{ROLE02}}", "the mouse wheel scrolls Variables")
assert(palette.scrollbar:GetValue() == 14, "wheel-scrolling Variables leaves Unrostered untouched")

grid:SetResolveProviders({ Variables = { ONLY = "OnlyOne" } })
palette = PaletteBox()
variablesPalette = VariablesBox()
assert(not variablesPalette.scrollbar:IsShown(), "shrinking Variables hides its no-longer-needed scrollbar")
assert(variablesPalette.scrollbar:GetValue() == 0, "shrinking Variables clamps its viewport to the beginning")
assert(variablesPalette.rows[1].layoutTarget.text == "{{ONLY}}", "the remaining variable stays available")
assert(palette.scrollbar:GetValue() == 14, "shrinking Variables preserves the Unrostered viewport")

grid:SetRoster({ "OnlyOne" })
palette = PaletteBox()
variablesPalette = VariablesBox()
assert(not palette.scrollbar:IsShown(), "shrinking the roster hides the no-longer-needed scrollbar")
assert(palette.scrollbar:GetValue() == 0, "shrinking the roster clamps the palette back to its beginning")
assert(palette.rows[1].layoutTarget.text == "OnlyOne", "the clamped palette starts with its remaining member")
assert(variablesPalette.rows[1].layoutTarget.text == "{{ONLY}}", "roster changes leave Variables available")
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
cursorX, cursorY = CentreOf(grid.boxes[2].rows[1])
grid.boxes[2].rows[1]:GetScript("OnDragStart")(grid.boxes[2].rows[1])
assert(cursorTexture ~= nil, "a live drag owns the custom cursor")
grid:OnRelease()
assert(grid.pressed == nil and grid.dragging == nil, "release clears the pending gesture")
assert(cursorTexture == nil, "release restores the cursor when a drag was active")
assert(grid.dropTarget == nil, "release clears the pending drop")
assert(grid.frame:GetScript("OnUpdate") == nil, "release stops the drag update loop")
assert(grid.measuredHeight == nil, "release forgets the measured height so a reused grid reports to its new host")
assert(next(grid.paletteOffsets) == nil, "release forgets both palette offsets")
assert(
    not palette.scrollbar:IsShown() and not variablesPalette.scrollbar:IsShown(),
    "release hides both palette scrollbars"
)

print("Layout grid tests passed.")
