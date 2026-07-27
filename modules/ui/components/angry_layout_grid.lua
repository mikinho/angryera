--- Custom AceGUI widget that edits a raid group layout by dragging members.
-- Renders the eight raid subgroup boxes in two columns, with a palette of
-- unrostered members beside them, and reports every gesture as a drag/drop
-- descriptor pair for `AngryEra.utils.layout.ApplyDrop` to resolve. Clicks
-- report their position instead, separately for a box title, a filled slot,
-- and an unused row. The height a redraw settles on is reported too, so a
-- container can grow to the whole grid instead of scrolling it.
--
-- Every callback below is delivered the AceGUI way, as
-- `(widget, event, ...)` -- a handler that reads its first argument as the
-- first value fired here is reading the event name instead, and AceGUI
-- swallows what that goes on to raise.
--
--     OnLayoutDrop(widget, event, drag, drop)
--     OnSlotClick(widget, event, group, slot, button)
--     OnEmptyClick(widget, event, group, subgroup, button)
--     OnGroupClick(widget, event, group, subgroup, button)
--     OnHeightMeasured(widget, event, height)
--
-- @module AngryLayoutGrid

local Type, Version = "AngryLayoutGrid", 7
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
-- GLOBALS: GetCursorPosition, SetCursor, CloseDropDownMenus, BackdropTemplateMixin

local MAX_SUBGROUPS = 8
local MAX_SUBGROUP_SLOTS = 5
local GROUP_COLUMNS = 2
local ROW_HEIGHT = 15
local HEADER_HEIGHT = 16
local BOX_PADDING = 6
local BOX_SPACING = 4
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

-- Translates a row's target into a drag descriptor for ApplyDrop. Titles, unused
-- rows, and unused palette space have nothing to pick up.
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
-- widget frame would sit under the boxes it is meant to highlight. Its level is
-- taken from the frame it covers rather than fixed at construction, since AceGUI
-- reparents the widget after that and rebases every level underneath it.
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
    self.dropMarker:SetFrameLevel(hovered:GetFrameLevel() + MARKER_LEVEL)
    self.dropMarker:Show()
end

-- Ends a drag, reporting where it landed.
local function FinishDrag(self, x, y)
    local dragging = self.dragging
    if not dragging then
        return
    end
    UpdateMarker(self, x, y)

    local drop = self.dropTarget
    self.dragging, self.dropTarget = nil, nil
    self.frame:SetScript("OnUpdate", nil)
    self.dropMarker:Hide()
    SetCursor(nil)

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
    if not self.dragging then
        frame:SetScript("OnUpdate", nil)
        return
    end
    UpdateMarker(self, CursorPosition())
end

-- The client owns the press-to-drag gesture; only the hit-test is ours, so a
-- drop resolves by geometry rather than by asking what the mouse is over.
local function Target_OnDragStart(frame)
    local self = frame.obj
    local dragging = frame.layoutTarget and DragFromTarget(frame.layoutTarget)
    if not dragging then
        return
    end

    self.dragging, self.dropTarget = dragging, nil
    CloseDropDownMenus()
    SetCursor("Interface\\CURSOR\\Point.blp")
    self.frame:SetScript("OnUpdate", Drag_OnUpdate)
end

local function Target_OnDragStop(frame)
    FinishDrag(frame.obj, CursorPosition())
end

local function Target_OnClick(frame, button)
    FireClick(frame.obj, frame.layoutTarget, button)
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
    header:EnableMouse(true)
    header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    header:SetScript("OnClick", Target_OnClick)
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
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnDragStart", Target_OnDragStart)
    row:SetScript("OnDragStop", Target_OnDragStop)
    row:SetScript("OnClick", Target_OnClick)
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
local function NormalizeRosterEntry(value)
    if type(value) == "string" then
        return {
            Text = value,
            FullName = value,
            ShortName = value:match("^([^-]+)") or value,
        }
    end
    if type(value) ~= "table" then
        return nil
    end
    local text = type(value.Text) == "string" and value.Text or value.Name
    local fullName = type(value.FullName) == "string" and value.FullName or text
    if type(text) ~= "string" or text == "" or type(fullName) ~= "string" or fullName == "" then
        return nil
    end
    return {
        Text = text,
        FullName = fullName,
        ShortName = type(value.ShortName) == "string" and value.ShortName
            or (fullName:match("^([^-]+)") or text:match("^([^-]+)") or text),
    }
end

local function NormalizeRoster(values)
    local roster = {}
    for _, value in ipairs(type(values) == "table" and values or {}) do
        local entry = NormalizeRosterEntry(value)
        if entry then
            roster[#roster + 1] = entry
        end
    end
    return roster
end

local function StoreUnique(map, key, entry)
    if key == "" then
        return
    end
    if map[key] == nil then
        map[key] = entry
    elseif map[key] ~= entry then
        map[key] = false
    end
end

-- Builds exact and short-name indexes without guessing when two realms share a
-- short name. Entries themselves are the stable identity for this redraw.
local function IndexRoster(roster)
    local index = { exact = {}, short = {} }
    for _, entry in ipairs(roster) do
        StoreUnique(index.exact, entry.FullName:lower(), entry)
        StoreUnique(index.exact, entry.Text:lower(), entry)
        StoreUnique(index.short, entry.ShortName:lower(), entry)
    end
    return index
end

local function MatchRosterEntry(index, name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local key = name:lower()
    local exact = index.exact[key]
    if exact then
        return exact
    end
    if name:find("-", 1, true) then
        return nil
    end
    local short = index.short[key]
    return short or nil
end

-- Resolves the whole model, then maps each selected name back to one unambiguous
-- roster identity. This keeps class fills, priority lists, subgroup fills, and
-- variable slots out of the palette just like literal names.
local function PlacedRosterEntries(self, model, rosterIndex)
    local placed = {}
    local resolver = self.layout and self.layout.Resolve
    if type(resolver) == "function" then
        local ok, resolved = pcall(resolver, model, self.resolveProviders or {})
        if ok and type(resolved) == "table" then
            for _, group in ipairs(resolved.groups or {}) do
                for _, name in ipairs(group.members or {}) do
                    local entry = MatchRosterEntry(rosterIndex, name)
                    if entry then
                        placed[entry] = true
                    end
                end
            end
        end
    end

    -- Literal slots remain useful when a reduced test/host layout engine has no
    -- resolver. Ambiguous short names deliberately match nothing.
    for _, group in ipairs(model.groups or {}) do
        for _, slot in ipairs(group.slots or {}) do
            local entry = MatchRosterEntry(rosterIndex, slot)
            if entry then
                placed[entry] = true
            end
        end
    end
    return placed
end

-- The palette offers only roster identities the resolved layout has not placed.
local function UnrosteredEntries(self, model)
    local rosterIndex = IndexRoster(self.roster)
    local placed = PlacedRosterEntries(self, model, rosterIndex)
    local entries = {}
    for _, entry in ipairs(self.roster) do
        if not placed[entry] then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

-- Describes every box to draw: the eight subgroup boxes, then the palette.
-- Boxes are plain descriptors so the draw pass stays dumb.
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

    -- Drawn even while empty, so the column keeps its place and a member always
    -- has somewhere to be dragged back to.
    local unrostered = UnrosteredEntries(self, model)
    plan[#plan + 1] = {
        title = "Unrostered",
        palette = true,
        slots = unrostered,
        rows = max(#unrostered, 1),
    }

    return plan
end

-- Only a row holding something registers for dragging, so an unused one still
-- resolves as a click rather than starting a gesture that carries nothing.
local function FillRow(row, text, target)
    row.layoutTarget = target
    row.label:SetText(text or "")
    row.background:SetShown(text ~= nil)

    if DragFromTarget(target) then
        row:RegisterForDrag("LeftButton")
        return
    end
    row:RegisterForDrag()
end

local function BoxHeight(rows)
    return HEADER_HEIGHT + (rows * ROW_HEIGHT) + (BOX_PADDING * 2)
end

-- Publishes the height a redraw settled on. Only a change is announced, because
-- a container that resizes in answer to this re-flows us, and re-announcing the
-- same height from that pass would bounce the two off each other.
local function ReportHeight(self, total)
    if total == self.measuredHeight then
        return
    end
    self.measuredHeight = total
    self:Fire("OnHeightMeasured", total)
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
        local rosterEntry = entry.slots[index]
        local text = rosterEntry and rosterEntry.Text
        FillRow(row, text, { kind = "palette", text = text, fullName = rosterEntry and rosterEntry.FullName })
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
        self.resolveProviders = nil
        self.dragging = nil
        self.dropTarget = nil
        self.drawing = nil
        self.drawnWidth = nil
        self.measuredHeight = nil
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
        self.resolveProviders = nil
        self.dragging = nil
        self.dropTarget = nil
        self.drawing = nil
        self.drawnWidth = nil
        self.measuredHeight = nil
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

    --- Replaces the roster the palette draws from.
    -- Accepts legacy name strings or identity-aware entries with Text,
    -- FullName, and ShortName fields.
    -- @tparam table roster Array of strings or roster-entry tables.
    ["SetRoster"] = function(self, roster)
        self.roster = NormalizeRoster(roster)
        self:Refresh()
    end,

    --- Supplies the live-roster/variable providers used to resolve placed slots.
    -- @tparam table providers Providers accepted by `layout.Resolve`.
    ["SetResolveProviders"] = function(self, providers)
        self.resolveProviders = type(providers) == "table" and providers or nil
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
        ReportHeight(self, total)
    end,
}

--[[-----------------------------------------------------------------------------
Constructor
-------------------------------------------------------------------------------]]
local function Constructor()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local marker = CreateFrame("Frame", nil, frame)
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
