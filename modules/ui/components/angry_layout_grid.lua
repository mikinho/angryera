--- Custom AceGUI widget that edits a raid group layout by dragging members.
-- Renders the eight raid subgroup boxes plus any free-form groups and a roster
-- palette, and reports every gesture as a drag/drop descriptor pair for
-- `AngryEra.utils.layout.ApplyDrop` to resolve.
-- @module AngryLayoutGrid

local Type, Version = "AngryLayoutGrid", 1
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then
    return
end

-- Lua APIs
local pairs, ipairs, type = pairs, ipairs, type
local ceil, max = math.ceil, math.max

-- WoW APIs
local CreateFrame, UIParent = CreateFrame, UIParent

-- Global vars/functions that we don't upvalue since they might get hooked, or upgraded
-- List them here for Mikk's FindGlobals script
-- GLOBALS: GetMouseFocus, GetMouseFoci, SetCursor, CloseDropDownMenus, BackdropTemplateMixin

local MAX_SUBGROUPS = 8
local MAX_SUBGROUP_SLOTS = 5
local COLUMNS = 4
local ROW_HEIGHT = 15
local HEADER_HEIGHT = 16
local BOX_PADDING = 6
local BOX_SPACING = 4
local SECTION_SPACING = 8

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

local function GetMouseFocus()
    if _G.GetMouseFocus then
        return _G.GetMouseFocus()
    end
    local foci = _G.GetMouseFoci and _G.GetMouseFoci()
    return foci and foci[1]
end

-- Walks up from the hovered frame to the nearest frame carrying a drop target.
local function GetTargetFromFrame(frame)
    while frame do
        if frame.obj and frame.layoutTarget then
            return frame
        end
        frame = frame:GetParent()
        if frame == UIParent then
            break
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
local function DragFromTarget(target)
    if target.kind == "slot" then
        return { kind = "slot", group = target.group, slot = target.slot }
    end
    if target.kind == "palette" then
        return { kind = "text", text = target.text }
    end
    return nil
end

local function Drag_OnUpdate(frame)
    local self = frame.obj
    if not self.dragging then
        return
    end

    local hovered = GetTargetFromFrame(GetMouseFocus())
    local marker = self.dropMarker
    if not hovered or hovered.obj ~= self then
        marker:Hide()
        self.dropTarget = nil
        return
    end

    self.dropTarget = DropFromTarget(hovered.layoutTarget)
    if not self.dropTarget then
        marker:Hide()
        return
    end

    marker:ClearAllPoints()
    marker:SetAllPoints(hovered)
    marker:Show()
end

local function Slot_OnDragStart(frame)
    local self = frame.obj
    local drag = DragFromTarget(frame.layoutTarget)
    if not drag then
        return
    end
    self.dragging = drag
    self.dropTarget = nil
    CloseDropDownMenus()
    SetCursor("Interface\\CURSOR\\Point.blp")
    self.frame:SetScript("OnUpdate", Drag_OnUpdate)
end

local function Slot_OnDragStop(frame)
    local self = frame.obj
    local drag, drop = self.dragging, self.dropTarget
    self.dragging, self.dropTarget = nil, nil
    SetCursor(nil)
    self.frame:SetScript("OnUpdate", nil)
    self.dropMarker:Hide()

    if not drag then
        return
    end
    -- Releasing away from the grid discards the slot; releasing on unused space
    -- inside it cancels, so a misaimed drag never silently drops a member.
    if not drop then
        if self.frame:IsMouseOver() or drag.kind ~= "slot" then
            return
        end
        drop = { kind = "remove" }
    end
    self:Fire("OnLayoutDrop", drag, drop)
end

local function Slot_OnClick(frame, button)
    local self = frame.obj
    local target = frame.layoutTarget
    if target.kind == "slot" then
        self:Fire("OnSlotClick", target.group, target.slot, button)
        return
    end
    if target.kind == "header" then
        self:Fire("OnGroupClick", target.group, target.subgroup, button)
    end
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
    header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    header:SetScript("OnClick", Slot_OnClick)
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
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnClick", Slot_OnClick)
    row:SetScript("OnDragStart", Slot_OnDragStart)
    row:SetScript("OnDragStop", Slot_OnDragStop)
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
            rows = max(ceil(#self.roster / COLUMNS), 1),
            columns = COLUMNS,
        }
    end

    return plan
end

-- Empty rows accept drops but must never start one.
local function FillRow(row, text, target)
    row.layoutTarget = target
    row.label:SetText(text or "")
    row.background:SetShown(text ~= nil)
    if text then
        row:RegisterForDrag("LeftButton")
        return
    end
    row:RegisterForDrag()
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

-- Lays a group box out as one vertical column of slots.
local function DrawBox(self, box, entry)
    local rows = entry.rows
    local empty = { kind = "header", group = entry.group, subgroup = entry.subgroup }

    box.header.label:SetText(entry.title)
    box.header.layoutTarget = empty

    for index = 1, rows do
        local row = AcquireRow(self, box, index)
        local slot = entry.slots[index]

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", box.header, "BOTTOMLEFT", 0, -((index - 1) * ROW_HEIGHT))
        row:SetPoint("TOPRIGHT", box.header, "BOTTOMRIGHT", 0, -((index - 1) * ROW_HEIGHT))
        FillRow(row, slot, slot and { kind = "slot", group = entry.group, slot = index } or empty)
        row:Show()
    end

    HideRowsFrom(box, rows + 1)
    box:SetHeight(BoxHeight(rows))
    box:Show()
end

-- Lays the roster palette out as one wide box of several names per row.
local function DrawPalette(self, box, entry)
    local perRow = entry.columns
    local rows = entry.rows
    local width = (box:GetWidth() - (BOX_PADDING * 2)) / perRow

    box.header.label:SetText(entry.title)
    box.header.layoutTarget = { kind = "palette" }

    for index = 1, rows * perRow do
        local row = AcquireRow(self, box, index)
        local name = entry.slots[index]
        local column = (index - 1) % perRow
        local line = ceil(index / perRow)

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", box.header, "BOTTOMLEFT", column * width, -((line - 1) * ROW_HEIGHT))
        row:SetWidth(width)
        FillRow(row, name, { kind = "palette", text = name })
        row:SetShown(name ~= nil)
    end

    HideRowsFrom(box, (rows * perRow) + 1)
    box:SetHeight(BoxHeight(rows))
    box:Show()
end

--[[-----------------------------------------------------------------------------
Methods
-------------------------------------------------------------------------------]]
local methods = {
    ["OnAcquire"] = function(self)
        self.layout = nil
        self.model = nil
        self.roster = {}
        self.dragging = nil
        self.dropTarget = nil
        self.drawing = nil
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
        self.dragging = nil
        self.dropTarget = nil
        self.drawing = nil
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

    ["OnWidthSet"] = function(self)
        self:Refresh()
    end,

    --- Redraws every box from the current model and roster.
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
        local boxWidth = (width - ((COLUMNS - 1) * BOX_SPACING)) / COLUMNS
        local column, top, rowHeight = 0, 0, 0

        for index, entry in ipairs(plan) do
            local box = AcquireBox(self, index)
            box:ClearAllPoints()

            if entry.palette then
                if column > 0 then
                    top = top + rowHeight + BOX_SPACING
                    column, rowHeight = 0, 0
                end
                top = top + SECTION_SPACING
                box:SetWidth(width)
                box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -top)
                DrawPalette(self, box, entry)
                top = top + box:GetHeight()
            else
                if column >= COLUMNS then
                    top = top + rowHeight + BOX_SPACING
                    column, rowHeight = 0, 0
                end
                box:SetWidth(boxWidth)
                box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", column * (boxWidth + BOX_SPACING), -top)
                DrawBox(self, box, entry)
                rowHeight = max(rowHeight, box:GetHeight())
                column = column + 1
            end
        end

        for index = #plan + 1, #self.boxes do
            self.boxes[index]:Hide()
        end

        local total = top + rowHeight
        self.frame.height = total
        self.frame:SetHeight(total)
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

    local dropMarker = frame:CreateTexture(nil, "OVERLAY")
    SetSolidColor(dropMarker, 0, 1, 0, 0.35)
    dropMarker:Hide()

    local widget = {
        frame = frame,
        dropMarker = dropMarker,
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
