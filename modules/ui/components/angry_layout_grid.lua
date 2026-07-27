--- Custom AceGUI widget that edits a raid group layout by dragging members.
-- Renders the eight raid subgroup boxes and any free-form groups in two columns
-- with the roster palette beside them, and reports every gesture as a drag/drop
-- descriptor pair for `AngryEra.utils.layout.ApplyDrop` to resolve. Clicks
-- report their position instead, separately for a box title, a filled slot, and
-- an unused row.
-- @module AngryLayoutGrid

local Type, Version = "AngryLayoutGrid", 3
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then
    return
end

-- Lua APIs
local pairs, ipairs, type = pairs, ipairs, type
local max = math.max

-- WoW APIs
local CreateFrame, UIParent = CreateFrame, UIParent

-- Global vars/functions that we don't upvalue since they might get hooked, or upgraded
-- List them here for Mikk's FindGlobals script
-- GLOBALS: GetCursorPosition, IsMouseButtonDown, SetCursor, CloseDropDownMenus, BackdropTemplateMixin

local MAX_SUBGROUPS = 8
local MAX_SUBGROUP_SLOTS = 5
local GROUP_COLUMNS = 2
local ROW_HEIGHT = 15
local HEADER_HEIGHT = 16
local BOX_PADDING = 6
local BOX_SPACING = 4
local DRAG_THRESHOLD = 4
local MARKER_LEVEL = 20

local PaneBackdrop = {
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

--[[-----------------------------------------------------------------------------
Support functions
-------------------------------------------------------------------------------]]
--- Fills a texture with a solid color across client versions.
-- @tparam table texture Texture object.
-- @tparam number r Red channel.
-- @tparam number g Green channel.
-- @tparam number b Blue channel.
-- @tparam number a Alpha channel.
local function SetSolidColor(texture, r, g, b, a)
    if texture.SetColorTexture then
        texture:SetColorTexture(r, g, b, a)
        return
    end
    texture:SetTexture(r, g, b, a)
end

-- Reads the cursor in the same space frame edges are reported in.
local function CursorPosition()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    if not scale or scale == 0 then
        return x, y
    end
    return x / scale, y / scale
end

-- A frame reports edges only once it has been placed, so an unplaced one holds
-- nothing.
local function FrameContains(frame, x, y)
    local left, right = frame:GetLeft(), frame:GetRight()
    local bottom, top = frame:GetBottom(), frame:GetTop()
    if not left or not right or not bottom or not top then
        return false
    end
    return x >= left and x <= right and y >= bottom and y <= top
end

-- The row or title under the cursor within one box.
local function BoxTargetAt(box, x, y)
    for _, row in ipairs(box.rows) do
        if row:IsShown() and FrameContains(row, x, y) then
            return row
        end
    end
    if FrameContains(box.header, x, y) then
        return box.header
    end
    return nil
end

-- Hit-testing walks our own boxes rather than asking the client what the mouse
-- is over, so a drop resolves the same way on every client version.
local function TargetAt(self, x, y)
    for _, box in ipairs(self.boxes) do
        if box:IsShown() and FrameContains(box, x, y) then
            return BoxTargetAt(box, x, y)
        end
    end
    return nil
end

-- Translates a hovered frame's target into a drop descriptor for ApplyDrop.
local function DropFromTarget(target)
    local kind = target.kind
    if kind == "slot" then
        return { kind = "slot", group = target.group, slot = target.slot }
    end
    if kind == "palette" then
        return { kind = "remove" }
    end
    if target.group then
        return { kind = "group", group = target.group }
    end
    if target.subgroup then
        return { kind = "subgroup", subgroup = target.subgroup }
    end
    return nil
end

-- Translates a pressed frame's target into a drag descriptor for ApplyDrop.
-- Titles, unused rows, and unused palette space have nothing to pick up.
local function DragFromTarget(target)
    if target.kind == "slot" then
        return { kind = "slot", group = target.group, slot = target.slot }
    end
    if target.kind == "palette" and target.text then
        return { kind = "text", text = target.text }
    end
    return nil
end

local function FireClick(self, target, button)
    if not target then
        return
    end
    if target.kind == "slot" then
        self:Fire("OnSlotClick", target.group, target.slot, button)
        return
    end
    -- A box's title acts on the group itself; its unused rows act on their
    -- contents, so clicking blank space never renames or deletes anything.
    if target.kind == "empty" then
        self:Fire("OnEmptyClick", target.group, target.subgroup, button)
        return
    end
    if target.kind == "header" then
        self:Fire("OnGroupClick", target.group, target.subgroup, button)
    end
end

-- Marks where a release would land. The marker rides a frame of its own because
-- a child frame draws over every layer of its parent, so a texture on the
-- widget frame would sit under the boxes it is meant to highlight.
local function UpdateMarker(self, x, y)
    local hovered = TargetAt(self, x, y)
    local drop = hovered and DropFromTarget(hovered.layoutTarget)
    self.dropTarget = drop
    if not drop then
        self.dropMarker:Hide()
        return
    end
    self.dropMarker:ClearAllPoints()
    self.dropMarker:SetAllPoints(hovered)
    self.dropMarker:Show()
end

-- Travel past a few pixels is what separates a drag from a click on the row it
-- started over.
local function Travelled(pressed, x, y)
    local dx, dy = x - pressed.x, y - pressed.y
    return (dx * dx) + (dy * dy) >= (DRAG_THRESHOLD * DRAG_THRESHOLD)
end

-- Ends the gesture, reporting a drop when the press travelled and a click when
-- it stayed put.
local function FinishPress(self, x, y)
    local pressed, dragging = self.pressed, self.dragging
    if not pressed then
        return
    end
    if dragging then
        UpdateMarker(self, x, y)
    end

    local drop = self.dropTarget
    self.pressed, self.dragging, self.dropTarget = nil, nil, nil
    self.frame:SetScript("OnUpdate", nil)
    self.dropMarker:Hide()
    SetCursor(nil)

    if not dragging then
        if FrameContains(pressed.frame, x, y) then
            FireClick(self, pressed.target, "LeftButton")
        end
        return
    end

    -- Releasing away from the grid discards the slot; releasing on unused space
    -- inside it cancels, so a misaimed drag never silently drops a member.
    if not drop then
        if FrameContains(self.frame, x, y) or dragging.kind ~= "slot" then
            return
        end
        drop = { kind = "remove" }
    end
    self:Fire("OnLayoutDrop", dragging, drop)
end

local function Drag_OnUpdate(frame)
    local self = frame.obj
    local pressed = self.pressed
    if not pressed then
        frame:SetScript("OnUpdate", nil)
        return
    end

    local x, y = CursorPosition()
    if not self.dragging and pressed.drag and Travelled(pressed, x, y) then
        self.dragging = pressed.drag
        CloseDropDownMenus()
        SetCursor("Interface\\CURSOR\\Point.blp")
    end

    if self.dragging then
        UpdateMarker(self, x, y)
    end

    if IsMouseButtonDown("LeftButton") then
        return
    end
    -- The pressed frame reports the release itself; this catches one the client
    -- swallowed, so a lost button never strands the cursor mid-drag.
    FinishPress(self, x, y)
end

-- Tracking the press ourselves rather than through RegisterForDrag keeps the
-- gesture identical on every client, and lets a row that cannot be dragged
-- still resolve as a click.
local function Target_OnMouseDown(frame, button)
    if button ~= "LeftButton" then
        return
    end
    local target = frame.layoutTarget
    if not target then
        return
    end

    local self = frame.obj
    local x, y = CursorPosition()
    self.pressed = { frame = frame, target = target, drag = DragFromTarget(target), x = x, y = y }
    self.dragging, self.dropTarget = nil, nil
    self.frame:SetScript("OnUpdate", Drag_OnUpdate)
end

local function Target_OnMouseUp(frame, button)
    local self = frame.obj
    if button ~= "LeftButton" then
        FireClick(self, frame.layoutTarget, button)
        return
    end
    FinishPress(self, CursorPosition())
end

--[[-----------------------------------------------------------------------------
Frame pools
-------------------------------------------------------------------------------]]
--- Returns box frame `index`, creating it on first use.
-- @tparam table self Widget.
-- @tparam number index Box index.
-- @treturn table box
local function AcquireBox(self, index)
    local box = self.boxes[index]
    if box then
        return box
    end

    box = CreateFrame("Frame", nil, self.frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetBackdrop(PaneBackdrop)
    box:SetBackdropColor(0.1, 0.1, 0.1, 0.6)
    box:SetBackdropBorderColor(0.4, 0.4, 0.4)

    local header = CreateFrame("Button", nil, box)
    header:SetHeight(HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", BOX_PADDING, -BOX_PADDING)
    header:SetPoint("TOPRIGHT", -BOX_PADDING, -BOX_PADDING)
    header:RegisterForClicks("AnyDown", "AnyUp")
    header:SetScript("OnMouseDown", Target_OnMouseDown)
    header:SetScript("OnMouseUp", Target_OnMouseUp)
    header.obj = self

    local label = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("LEFT")
    label:SetPoint("RIGHT")
    label:SetJustifyH("LEFT")
    header.label = label

    local headerHighlight = header:CreateTexture(nil, "HIGHLIGHT")
    headerHighlight:SetAllPoints()
    SetSolidColor(headerHighlight, 1, 1, 1, 0.1)

    box.header = header
    box.rows = {}
    self.boxes[index] = box
    return box
end

--- Returns row `index` of `box`, creating it on first use.
-- @tparam table self Widget.
-- @tparam table box Box frame.
-- @tparam number index Row index.
-- @treturn table row
local function AcquireRow(self, box, index)
    local row = box.rows[index]
    if row then
        return row
    end

    row = CreateFrame("Button", nil, box)
    row:SetHeight(ROW_HEIGHT)
    row:RegisterForClicks("AnyDown", "AnyUp")
    row:SetScript("OnMouseDown", Target_OnMouseDown)
    row:SetScript("OnMouseUp", Target_OnMouseUp)
    row.obj = self

    local background = row:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    SetSolidColor(background, 1, 1, 1, 0.05)
    row.background = background

    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", 3, 0)
    label:SetPoint("RIGHT", -3, 0)
    label:SetJustifyH("LEFT")
    row.label = label

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    SetSolidColor(highlight, 1, 1, 1, 0.2)

    box.rows[index] = row
    return row
end

--[[-----------------------------------------------------------------------------
Rendering
-------------------------------------------------------------------------------]]
-- Describes every box to draw: the eight subgroup boxes, then free groups, then
-- the roster palette. Boxes are plain descriptors so the draw pass stays dumb.
local function BuildBoxPlan(self)
    local layout = self.layout
    local model = self.model or { groups = {} }
    local view = layout.GridView(model)
    local plan = {}

    for subgroup = 1, MAX_SUBGROUPS do
        local index = view.subgroups[subgroup]
        local group = index and model.groups[index]
        plan[#plan + 1] = {
            title = group and group.name or ("Group " .. subgroup),
            group = index,
            subgroup = subgroup,
            slots = group and group.slots or {},
            rows = MAX_SUBGROUP_SLOTS,
            bound = true,
        }
    end

    for _, index in ipairs(view.free) do
        local group = model.groups[index]
        plan[#plan + 1] = {
            title = group.name .. (group.subgroup and (" (group " .. group.subgroup .. " taken)") or ""),
            group = index,
            slots = group.slots,
            rows = max(#group.slots + 1, MAX_SUBGROUP_SLOTS),
        }
    end

    if #self.roster > 0 then
        plan[#plan + 1] = {
            title = "Roster",
            palette = true,
            slots = self.roster,
            rows = #self.roster,
        }
    end

    return plan
end

local function FillRow(row, text, target)
    row.layoutTarget = target
    row.label:SetText(text or "")
    row.background:SetShown(text ~= nil)
end

local function BoxHeight(rows)
    return HEADER_HEIGHT + (rows * ROW_HEIGHT) + (BOX_PADDING * 2)
end

-- Hides the rows a redraw no longer needs.
local function HideRowsFrom(box, first)
    for index = first, #box.rows do
        box.rows[index]:Hide()
    end
end

-- Stacks `rows` rows under a box title, one per line.
local function StackRows(self, box, rows, Target)
    for index = 1, rows do
        local row = AcquireRow(self, box, index)
        local offset = -((index - 1) * ROW_HEIGHT)

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", box.header, "BOTTOMLEFT", 0, offset)
        row:SetPoint("TOPRIGHT", box.header, "BOTTOMRIGHT", 0, offset)
        Target(row, index)
        row:Show()
    end

    HideRowsFrom(box, rows + 1)
    box:SetHeight(BoxHeight(rows))
    box:Show()
end

-- Lays a group box out as one column of slots.
local function DrawBox(self, box, entry)
    local empty = { kind = "empty", group = entry.group, subgroup = entry.subgroup }

    box.header.label:SetText(entry.title)
    box.header.layoutTarget = { kind = "header", group = entry.group, subgroup = entry.subgroup }

    StackRows(self, box, entry.rows, function(row, index)
        local slot = entry.slots[index]
        FillRow(row, slot, slot and { kind = "slot", group = entry.group, slot = index } or empty)
    end)
end

-- Lays the palette out the same shape as a group box, one name per row.
local function DrawPalette(self, box, entry)
    box.header.label:SetText(entry.title)
    box.header.layoutTarget = { kind = "palette" }

    StackRows(self, box, entry.rows, function(row, index)
        local name = entry.slots[index]
        FillRow(row, name, { kind = "palette", text = name })
    end)
end

--[[-----------------------------------------------------------------------------
Methods
-------------------------------------------------------------------------------]]
local methods = {
    ["OnAcquire"] = function(self)
        self.layout = nil
        self.model = nil
        self.roster = {}
        self.pressed = nil
        self.dragging = nil
        self.dropTarget = nil
        self.drawing = nil
        self.drawnWidth = nil
        self.frame:SetScript("OnUpdate", nil)
        self.dropMarker:Hide()
        self:SetWidth(400)
        self:SetHeight(200)
    end,

    ["OnRelease"] = function(self)
        self.frame:SetScript("OnUpdate", nil)
        self.dropMarker:Hide()
        self.layout = nil
        self.model = nil
        self.roster = {}
        self.pressed = nil
        self.dragging = nil
        self.dropTarget = nil
        self.drawing = nil
        self.drawnWidth = nil
        for _, box in ipairs(self.boxes) do
            box:Hide()
        end
    end,

    --- Supplies the layout engine the widget reads grid structure from.
    -- @tparam table engine `AngryEra.utils.layout`.
    ["SetLayoutEngine"] = function(self, engine)
        self.layout = engine
    end,

    --- Replaces the layout model on display.
    -- @tparam table model Layout model.
    ["SetLayoutModel"] = function(self, model)
        self.model = model
        self:Refresh()
    end,

    --- Replaces the roster palette entries.
    -- @tparam table names Array of short names.
    ["SetRoster"] = function(self, names)
        self.roster = type(names) == "table" and names or {}
        self:Refresh()
    end,

    -- A redraw asks the container to re-flow, and the container answers by
    -- re-applying our width. Redrawing only on a real change settles that loop.
    ["OnWidthSet"] = function(self, width)
        if width and width == self.drawnWidth then
            return
        end
        self:Refresh()
    end,

    --- Redraws every box from the current model and roster.
    -- Groups fill two columns, odd-numbered on the left and even on the right,
    -- and the palette stands in a third column beside them.
    ["Refresh"] = function(self)
        if not self.layout or self.drawing then
            return
        end

        local width = self.frame:GetWidth()
        if not width or width < 1 then
            return
        end

        self.drawing = true
        local plan = BuildBoxPlan(self)
        local columnWidth = (width - (GROUP_COLUMNS * BOX_SPACING)) / (GROUP_COLUMNS + 1)
        local step = columnWidth + BOX_SPACING
        local placed, top, rowHeight, total = 0, 0, 0, 0

        for index, entry in ipairs(plan) do
            local box = AcquireBox(self, index)
            box:ClearAllPoints()
            box:SetWidth(columnWidth)

            if entry.palette then
                box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", GROUP_COLUMNS * step, 0)
                DrawPalette(self, box, entry)
                total = max(total, box:GetHeight())
            else
                local column = placed % GROUP_COLUMNS
                if column == 0 and placed > 0 then
                    top = top + rowHeight + BOX_SPACING
                    rowHeight = 0
                end
                box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", column * step, -top)
                DrawBox(self, box, entry)
                rowHeight = max(rowHeight, box:GetHeight())
                placed = placed + 1
                total = max(total, top + rowHeight)
            end
        end

        for index = #plan + 1, #self.boxes do
            self.boxes[index]:Hide()
        end

        self.frame.height = total
        self.frame:SetHeight(total)
        self.drawnWidth = width
        self.drawing = nil
        if self.parent and self.parent.DoLayout then
            self.parent:DoLayout()
        end
    end,
}

--[[-----------------------------------------------------------------------------
Constructor
-------------------------------------------------------------------------------]]
local function Constructor()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local marker = CreateFrame("Frame", nil, frame)
    marker:SetFrameLevel(frame:GetFrameLevel() + MARKER_LEVEL)
    marker:Hide()

    local markerFill = marker:CreateTexture(nil, "OVERLAY")
    markerFill:SetAllPoints(marker)
    SetSolidColor(markerFill, 0, 1, 0, 0.35)

    local widget = {
        frame = frame,
        dropMarker = marker,
        boxes = {},
        roster = {},
        type = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end
    frame.obj = widget

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
