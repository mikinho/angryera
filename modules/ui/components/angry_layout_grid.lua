--- Custom AceGUI widget that edits a raid group layout by dragging members.
-- Renders the eight raid subgroup boxes in two columns, with separately
-- scrolling Unrostered and Variables palettes beside them, and reports every
-- gesture as a drag/drop descriptor pair for
-- `AngryEra.utils.layout.ApplyDrop` to resolve. Clicks report their position
-- instead, separately for a box title, a filled slot, and an unused row. The
-- grid keeps a fixed eight-subgroup canvas with a small top inset so the first
-- pane's border remains visible.
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

local Type, Version = "AngryLayoutGrid", 14
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then
    return
end

-- Lua APIs
local pairs, ipairs, type = pairs, ipairs, type
local sort = table.sort
local floor, max, min = math.floor, math.max, math.min

-- WoW APIs
local CreateFrame, UIParent = CreateFrame, UIParent

-- Global vars/functions that we don't upvalue since they might get hooked, or upgraded
-- List them here for Mikk's FindGlobals script
-- GLOBALS: GetCursorPosition, CloseDropDownMenus, BackdropTemplateMixin
-- GLOBALS: EMPTY, GameFontDarkGraySmall, GameFontHighlightSmall

local MAX_SUBGROUPS = 8
local MAX_SUBGROUP_SLOTS = 5
local GROUP_COLUMNS = 2
local AUXILIARY_COLUMNS = 2
local TOTAL_COLUMNS = GROUP_COLUMNS + AUXILIARY_COLUMNS
local ROW_HEIGHT = 15
local RAID_ROW_HEIGHT = 14
local HEADER_HEIGHT = 16
local BOX_PADDING = 6
local BOX_SPACING = 4
local ROW_TEXT_PADDING = 8
local GRID_TOP_INSET = 2
local GHOST_LEVEL = 10
local MARKER_LEVEL = 20
local SCROLLBAR_WIDTH = 16
local SCROLLBAR_GAP = 4
local SCROLLBAR_END_PADDING = 18
local PALETTE_WHEEL_ROWS = 3
local GROUP_BOX_HEIGHT = HEADER_HEIGHT + (MAX_SUBGROUP_SLOTS * ROW_HEIGHT) + (BOX_PADDING * 2)
local GROUP_ROWS = MAX_SUBGROUPS / GROUP_COLUMNS
local GRID_CONTENT_HEIGHT = (GROUP_ROWS * GROUP_BOX_HEIGHT) + ((GROUP_ROWS - 1) * BOX_SPACING)
local GRID_HEIGHT = GRID_TOP_INSET + GRID_CONTENT_HEIGHT
local PALETTE_VISIBLE_ROWS = floor((GRID_CONTENT_HEIGHT - HEADER_HEIGHT - (BOX_PADDING * 2)) / ROW_HEIGHT)
local widgetSequence = 0
local EMPTY_ROW_LABEL = EMPTY or "Empty"
local RAID_ROW_TEXTURE = "Interface\\RaidFrame\\UI-RaidFrame-GroupButton"
local GOLD_HIGHLIGHT_RED, GOLD_HIGHLIGHT_GREEN, GOLD_HIGHLIGHT_BLUE = 1, 0.82, 0
local GOLD_HIGHLIGHT_FILL_ALPHA = 0.12
local GOLD_HIGHLIGHT_EDGE_SIZE = 1
local GOLD_HIGHLIGHT_CORNER_RADIUS = 2
local GOLD_HIGHLIGHT_CORNER_STEP = GOLD_HIGHLIGHT_CORNER_RADIUS - GOLD_HIGHLIGHT_EDGE_SIZE
local GOLD_HIGHLIGHT_FILL_INSET = 1

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

local function CreateGoldHighlightEdge(owner, layer)
    local edge = owner:CreateTexture(nil, layer)
    SetSolidColor(edge, GOLD_HIGHLIGHT_RED, GOLD_HIGHLIGHT_GREEN, GOLD_HIGHLIGHT_BLUE, 1)
    return edge
end

local function AnchorGoldHighlightFill(fill, owner)
    fill:ClearAllPoints()
    fill:SetPoint("TOPLEFT", owner, "TOPLEFT", GOLD_HIGHLIGHT_FILL_INSET, -GOLD_HIGHLIGHT_FILL_INSET)
    fill:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", -GOLD_HIGHLIGHT_FILL_INSET, GOLD_HIGHLIGHT_FILL_INSET)
end

local function CreateGoldHighlightCorner(owner, layer, point, x, y)
    local corner = CreateGoldHighlightEdge(owner, layer)
    corner:SetPoint(point, owner, point, x, y)
    corner:SetWidth(GOLD_HIGHLIGHT_EDGE_SIZE)
    corner:SetHeight(GOLD_HIGHLIGHT_EDGE_SIZE)
    return corner
end

local function CreateGoldHighlight(owner, fillLayer, edgeLayer)
    local fill = owner:CreateTexture(nil, fillLayer)
    AnchorGoldHighlightFill(fill, owner)
    SetSolidColor(fill, GOLD_HIGHLIGHT_RED, GOLD_HIGHLIGHT_GREEN, GOLD_HIGHLIGHT_BLUE, GOLD_HIGHLIGHT_FILL_ALPHA)

    local top = CreateGoldHighlightEdge(owner, edgeLayer)
    top:SetPoint("TOPLEFT", owner, "TOPLEFT", GOLD_HIGHLIGHT_CORNER_RADIUS, 0)
    top:SetPoint("TOPRIGHT", owner, "TOPRIGHT", -GOLD_HIGHLIGHT_CORNER_RADIUS, 0)
    top:SetHeight(GOLD_HIGHLIGHT_EDGE_SIZE)

    local bottom = CreateGoldHighlightEdge(owner, edgeLayer)
    bottom:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", GOLD_HIGHLIGHT_CORNER_RADIUS, 0)
    bottom:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", -GOLD_HIGHLIGHT_CORNER_RADIUS, 0)
    bottom:SetHeight(GOLD_HIGHLIGHT_EDGE_SIZE)

    local left = CreateGoldHighlightEdge(owner, edgeLayer)
    left:SetPoint("TOPLEFT", owner, "TOPLEFT", 0, -GOLD_HIGHLIGHT_CORNER_RADIUS)
    left:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", 0, GOLD_HIGHLIGHT_CORNER_RADIUS)
    left:SetWidth(GOLD_HIGHLIGHT_EDGE_SIZE)

    local right = CreateGoldHighlightEdge(owner, edgeLayer)
    right:SetPoint("TOPRIGHT", owner, "TOPRIGHT", 0, -GOLD_HIGHLIGHT_CORNER_RADIUS)
    right:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", 0, GOLD_HIGHLIGHT_CORNER_RADIUS)
    right:SetWidth(GOLD_HIGHLIGHT_EDGE_SIZE)

    local topLeft =
        CreateGoldHighlightCorner(owner, edgeLayer, "TOPLEFT", GOLD_HIGHLIGHT_CORNER_STEP, -GOLD_HIGHLIGHT_CORNER_STEP)
    local topRight = CreateGoldHighlightCorner(
        owner,
        edgeLayer,
        "TOPRIGHT",
        -GOLD_HIGHLIGHT_CORNER_STEP,
        -GOLD_HIGHLIGHT_CORNER_STEP
    )
    local bottomLeft = CreateGoldHighlightCorner(
        owner,
        edgeLayer,
        "BOTTOMLEFT",
        GOLD_HIGHLIGHT_CORNER_STEP,
        GOLD_HIGHLIGHT_CORNER_STEP
    )
    local bottomRight = CreateGoldHighlightCorner(
        owner,
        edgeLayer,
        "BOTTOMRIGHT",
        -GOLD_HIGHLIGHT_CORNER_STEP,
        GOLD_HIGHLIGHT_CORNER_STEP
    )

    return fill,
        {
            top = top,
            right = right,
            bottom = bottom,
            left = left,
            topLeft = topLeft,
            topRight = topRight,
            bottomLeft = bottomLeft,
            bottomRight = bottomRight,
        }
end

local function StyleRaidRowTexture(texture)
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT")
    texture:SetPoint("TOPRIGHT")
    texture:SetHeight(RAID_ROW_HEIGHT)
    texture:SetTexture(RAID_ROW_TEXTURE)
    texture:SetTexCoord(0, 0.640625, 0, 0.4375)
    texture:SetBlendMode("BLEND")
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

local function HideDragVisuals(self)
    if self.dragGhost then
        self.dragGhost:Hide()
        self.dragGhost.label:SetText("")
        self.dragGhost:ClearAllPoints()
    end
    if self.dragSourcePlaceholder then
        self.dragSourcePlaceholder:Hide()
        self.dragSourcePlaceholder:ClearAllPoints()
    end
    self.dragSource = nil
    self.dragGrabX = nil
    self.dragGrabY = nil
end

local function CancelDrag(self)
    self.dragging = nil
    self.dropTarget = nil
    self.frame:SetScript("OnUpdate", nil)
    self.dropMarker:Hide()
    self.dropMarker:ClearAllPoints()
    HideDragVisuals(self)
end

local function PositionDragGhost(self, x, y)
    local ghost = self.dragGhost
    if not ghost or not ghost:IsShown() then
        return
    end
    local rootLeft = UIParent:GetLeft() or 0
    local rootBottom = UIParent:GetBottom() or 0
    ghost:ClearAllPoints()
    ghost:SetPoint(
        "TOPLEFT",
        UIParent,
        "BOTTOMLEFT",
        x - (self.dragGrabX or 0) - rootLeft,
        y + (self.dragGrabY or 0) - rootBottom
    )
end

local function ShowDragVisuals(self, source, dragging, x, y)
    local left, right = source:GetLeft(), source:GetRight()
    local top = source:GetTop()
    local width = left and right and right - left or source:GetWidth()
    width = width and width > 0 and width or 1
    left = left or (x - (width / 2))
    top = top or (y + (ROW_HEIGHT / 2))

    self.dragSource = source
    self.dragGrabX = x - left
    self.dragGrabY = top - y

    local ghost = self.dragGhost
    ghost:SetWidth(width)
    ghost:SetHeight(ROW_HEIGHT)
    ghost:SetFrameLevel(source:GetFrameLevel() + GHOST_LEVEL)
    local ghostText = dragging.kind == "text" and dragging.text or source.label:GetText()
    if dragging.kind == "text" and type(ghostText) == "string" then
        ghostText = ghostText:gsub("|", "||")
    end
    ghost.label:SetText(ghostText)
    ghost:Show()
    PositionDragGhost(self, x, y)

    local placeholder = self.dragSourcePlaceholder
    placeholder:Hide()
    placeholder:ClearAllPoints()
    if dragging.kind == "slot" then
        placeholder:SetAllPoints(source)
        placeholder:SetFrameLevel(source:GetFrameLevel() + GHOST_LEVEL - 1)
        placeholder:Show()
    end
end

-- The row or title under the cursor within one box.
local function BoxTargetAt(box, x, y)
    if box.scrollbar and box.scrollbar:IsShown() and FrameContains(box.scrollbar, x, y) then
        return nil
    end
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
    if (target.kind == "palette" or target.kind == "variable") and target.text then
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
    CancelDrag(self)

    -- Releasing away from the grid discards the slot; releasing on unused space
    -- inside it cancels, so a misaimed drag never silently drops a member.
    if not drop then
        local safeFrame = self.safeDropFrame or self.frame
        if FrameContains(safeFrame, x, y) or dragging.kind ~= "slot" then
            return
        end
        drop = { kind = "remove" }
    end
    -- Both palettes are insertion sources. Only an existing layout slot can be
    -- removed by landing on Unrostered; dropping one source onto another is a
    -- harmless cancel instead of an invalid edit callback.
    if drop.kind == "remove" and dragging.kind ~= "slot" then
        return
    end
    self:Fire("OnLayoutDrop", dragging, drop)
end

local function Drag_OnUpdate(frame)
    local self = frame.obj
    if not self.dragging then
        CancelDrag(self)
        return
    end
    local x, y = CursorPosition()
    PositionDragGhost(self, x, y)
    UpdateMarker(self, x, y)
end

-- The client owns the press-to-drag gesture; only the hit-test is ours, so a
-- drop resolves by geometry rather than by asking what the mouse is over.
local function Target_OnDragStart(frame)
    local self = frame.obj
    if self.disabled then
        return
    end
    local dragging = frame.layoutTarget and DragFromTarget(frame.layoutTarget)
    if not dragging then
        return
    end

    CancelDrag(self)
    self.dragging, self.dropTarget = dragging, nil
    CloseDropDownMenus()
    local x, y = CursorPosition()
    ShowDragVisuals(self, frame, dragging, x, y)
    self.frame:SetScript("OnUpdate", Drag_OnUpdate)
end

local function Target_OnDragStop(frame)
    if frame.obj.disabled then
        return
    end
    FinishDrag(frame.obj, CursorPosition())
end

local function Target_OnClick(frame, button)
    if frame.obj.disabled then
        return
    end
    FireClick(frame.obj, frame.layoutTarget, button)
end

-- The palette virtualizes its rows instead of clipping real child frames in a
-- nested ScrollFrame. The grid's drag hit-testing therefore sees only the rows
-- that are actually visible.
local function PaletteScroll_OnValueChanged(scrollbar, value)
    local self = scrollbar.obj
    if not self or self.drawing then
        return
    end
    local paletteKey = scrollbar.paletteKey
    if type(paletteKey) ~= "string" then
        return
    end
    local offset = floor((value or 0) + 0.5)
    self.paletteOffsets = self.paletteOffsets or {}
    if offset == self.paletteOffsets[paletteKey] then
        return
    end
    self.paletteOffsets[paletteKey] = offset
    self:Refresh()
end

local function Palette_OnMouseWheel(box, delta)
    local scrollbar = box and box.scrollbar
    if not scrollbar or not scrollbar:IsShown() then
        return
    end
    local minimum, maximum = scrollbar:GetMinMaxValues()
    local value = scrollbar:GetValue() or 0
    scrollbar:SetValue(min(maximum, max(minimum, value - ((delta or 0) * PALETTE_WHEEL_ROWS))))
end

local function PaletteChild_OnMouseWheel(frame, delta)
    Palette_OnMouseWheel(frame.paletteBox, delta)
end

local function AcquirePaletteScrollbar(self, box, paletteKey)
    if box.scrollbar then
        box.scrollbar.paletteKey = paletteKey
        return box.scrollbar
    end

    local scrollbar = CreateFrame(
        "Slider",
        ("AngryEraLayoutGrid%dBox%dScrollBar"):format(self.sequence, box.index),
        box,
        "UIPanelScrollBarTemplate"
    )
    -- Classic's template installs its own value handler. Clear it before
    -- initialization so setting the initial range/value cannot call FrameXML
    -- with a palette it does not own.
    scrollbar:SetScript("OnValueChanged", nil)
    scrollbar:SetWidth(SCROLLBAR_WIDTH)
    scrollbar:SetMinMaxValues(0, 0)
    scrollbar:SetValueStep(1)
    scrollbar:SetValue(0)
    scrollbar.obj = self
    scrollbar.paletteKey = paletteKey
    scrollbar:SetScript("OnValueChanged", PaletteScroll_OnValueChanged)
    box.scrollbar = scrollbar

    box:EnableMouseWheel(true)
    box:SetScript("OnMouseWheel", Palette_OnMouseWheel)
    box.header:EnableMouseWheel(true)
    box.header.paletteBox = box
    box.header:SetScript("OnMouseWheel", PaletteChild_OnMouseWheel)
    return scrollbar
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
    box.index = index

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
    label:SetPoint("LEFT", background, "LEFT", ROW_TEXT_PADDING, 0)
    label:SetPoint("RIGHT", background, "RIGHT", -ROW_TEXT_PADDING, 0)
    label:SetHeight(ROW_HEIGHT)
    label:SetJustifyH("LEFT")
    if label.SetWordWrap then
        label:SetWordWrap(false)
    end
    if label.SetNonSpaceWrap then
        label:SetNonSpaceWrap(false)
    end
    if label.SetMaxLines then
        label:SetMaxLines(1)
    end
    row.label = label

    local highlight, highlightEdges = CreateGoldHighlight(row, "HIGHLIGHT", "HIGHLIGHT")
    row.highlight = highlight
    row.highlightEdges = highlightEdges

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

local function IsRepresentableVariable(key, value)
    if
        type(key) ~= "string"
        or key == ""
        or key:sub(1, 1) == "$"
        or key:match("^%s*(.-)%s*$") ~= key
        or key:find("[%c{},;]")
    then
        return false
    end
    -- A whole layout slot can safely stand in only for a string expression.
    -- Numeric variables remain valid inside hand-written expressions such as
    -- `*MAGE x{{Count}}`, but dragging `{{Count}}` as a whole slot would name a
    -- nonexistent player.
    return type(value) == "string"
end

local function VariablePreview(value)
    local preview = value:gsub("[%c]", " "):gsub("%s+", " "):gsub("|", "||")
    if preview == "" then
        return "(empty)"
    end
    if value:find("{{", 1, true) then
        return "[unresolved] " .. preview
    end
    return preview
end

local function VariableKeyLess(left, right)
    local leftPrefix, leftSuffix = left:match("^(.-)(%d+)$")
    local rightPrefix, rightSuffix = right:match("^(.-)(%d+)$")
    local leftPrimary = (leftPrefix or left):lower()
    local rightPrimary = (rightPrefix or right):lower()
    if leftPrimary ~= rightPrimary then
        return leftPrimary < rightPrimary
    end

    local leftKind, rightKind = leftSuffix and 1 or 0, rightSuffix and 1 or 0
    if leftKind ~= rightKind then
        return leftKind < rightKind
    end
    if leftSuffix and rightSuffix then
        local leftNumber = leftSuffix:gsub("^0+", "")
        local rightNumber = rightSuffix:gsub("^0+", "")
        leftNumber = leftNumber ~= "" and leftNumber or "0"
        rightNumber = rightNumber ~= "" and rightNumber or "0"
        if #leftNumber ~= #rightNumber then
            return #leftNumber < #rightNumber
        end
        if leftNumber ~= rightNumber then
            return leftNumber < rightNumber
        end
        if #leftSuffix ~= #rightSuffix then
            return #leftSuffix < #rightSuffix
        end
    end

    local leftFolded, rightFolded = left:lower(), right:lower()
    if leftFolded ~= rightFolded then
        return leftFolded < rightFolded
    end
    return left < right
end

-- Returns the exact, case-sensitive variable keys already referenced by layout
-- slots. A token stays occupied while its slot is moved, and becomes available
-- again as soon as that slot is removed.
local function UsedVariableKeys(model)
    local used = {}
    for _, group in ipairs((type(model) == "table" and model.groups) or {}) do
        for _, slot in ipairs(group.slots or {}) do
            if type(slot) == "string" then
                for key in slot:gmatch("{{%s*([^{}]-)%s*}}") do
                    local normalizedKey = key:match("^%s*(.-)%s*$")
                    if normalizedKey ~= "" then
                        used[normalizedKey] = true
                    end
                end
            end
        end
    end
    return used
end

-- Tests a prospective variable with the resolver itself so aliases, priority
-- lists, fills, and short/full realm spellings follow the exact same identity
-- rules as the layout. A probe fill that can select another unplaced member is
-- still useful and remains available.
local function VariableWouldRepeatTarget(self, model, token, value, providers)
    if value == "" then
        return false
    end

    local engine = self.layout
    if type(engine) ~= "table" or type(engine.CopyModel) ~= "function" or type(engine.Resolve) ~= "function" then
        return false
    end

    local probe = engine.CopyModel(model)
    if type(probe) ~= "table" or type(probe.groups) ~= "table" then
        return false
    end
    local probeIndex = #probe.groups + 1
    probe.groups[probeIndex] = { name = "Variable probe", slots = { token } }
    local resolvedOk, resolved = pcall(engine.Resolve, probe, providers)
    if not resolvedOk or type(resolved) ~= "table" then
        return false
    end
    for _, duplicate in ipairs(resolved.duplicates or {}) do
        if
            duplicate.Group == probeIndex
            and type(duplicate.Name) == "string"
            and not duplicate.Name:find("{{", 1, true)
        then
            return true
        end
    end
    return false
end

-- The Variables palette contains unused effective inherited/page string
-- variables. A token disappears once referenced, as do aliases that would
-- resolve to a target already assigned by another slot.
local function VariableEntries(self, model)
    local providers = type(self.resolveProviders) == "table" and self.resolveProviders or {}
    local values = type(providers.Variables) == "table" and providers.Variables or {}
    local used = UsedVariableKeys(model)
    local entries = {}
    for key, value in pairs(values) do
        if IsRepresentableVariable(key, value) and not used[key] then
            local token = "{{" .. key .. "}}"
            if not VariableWouldRepeatTarget(self, model, token, value, providers) then
                entries[#entries + 1] = {
                    Key = key,
                    Text = token,
                    Label = token:gsub("|", "||") .. " = " .. VariablePreview(value),
                }
            end
        end
    end
    sort(entries, function(left, right)
        return VariableKeyLess(left.Key, right.Key)
    end)
    return entries
end

-- Describes every box to draw: the eight subgroup boxes, then both palettes.
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
        palette = "unrostered",
        slots = unrostered,
        rows = max(#unrostered, 1),
    }

    local variableEntries = VariableEntries(self, model)
    plan[#plan + 1] = {
        title = "Variables",
        palette = "variables",
        slots = variableEntries,
        rows = max(#variableEntries, 1),
    }

    return plan
end

-- Only a row holding something registers for dragging, so an unused one still
-- resolves as a click rather than starting a gesture that carries nothing.
local function StyleRow(row, raidStyle)
    if raidStyle then
        StyleRaidRowTexture(row.background)
        AnchorGoldHighlightFill(row.highlight, row)
        SetSolidColor(
            row.highlight,
            GOLD_HIGHLIGHT_RED,
            GOLD_HIGHLIGHT_GREEN,
            GOLD_HIGHLIGHT_BLUE,
            GOLD_HIGHLIGHT_FILL_ALPHA
        )
        row.highlight:SetBlendMode("BLEND")
        return
    end

    row.background:ClearAllPoints()
    row.background:SetAllPoints(row)
    SetSolidColor(row.background, 1, 1, 1, 0.05)
    row.highlight:ClearAllPoints()
    row.highlight:SetAllPoints(row)
    SetSolidColor(row.highlight, 1, 1, 1, 0.2)
    row.highlight:SetBlendMode("BLEND")
end

local function FillRow(row, text, target, isEmpty, raidStyle)
    row.layoutTarget = target
    StyleRow(row, raidStyle)
    row.label:SetText(isEmpty and EMPTY_ROW_LABEL or text or "")
    row.label:SetJustifyH(isEmpty and "CENTER" or "LEFT")
    row.label:SetFontObject(isEmpty and GameFontDarkGraySmall or GameFontHighlightSmall)

    local styled = raidStyle or text ~= nil
    row.background:SetShown(styled)
    row.highlight:SetShown(styled)
    for _, edge in pairs(row.highlightEdges) do
        edge:SetShown(styled and raidStyle)
    end

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
local function StackRows(self, box, rows, Target, rightInset, fixedHeight)
    for index = 1, rows do
        local row = AcquireRow(self, box, index)
        local offset = -((index - 1) * ROW_HEIGHT)

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", box.header, "BOTTOMLEFT", 0, offset)
        row:SetPoint("TOPRIGHT", box.header, "BOTTOMRIGHT", -(rightInset or 0), offset)
        Target(row, index)
        row:Show()
    end

    HideRowsFrom(box, rows + 1)
    box:SetHeight(fixedHeight or BoxHeight(rows))
    box:Show()
end

-- Lays a group box out as one column of slots.
local function DrawBox(self, box, entry)
    local empty = { kind = "empty", group = entry.group, subgroup = entry.subgroup }

    box.header.label:SetText(entry.title)
    box.header.label:SetJustifyH("CENTER")
    box.header.layoutTarget = { kind = "header", group = entry.group, subgroup = entry.subgroup }

    StackRows(self, box, entry.rows, function(row, index)
        local slot = entry.slots[index]
        local displaySlot = type(slot) == "string" and slot:gsub("|", "||") or slot
        FillRow(
            row,
            displaySlot,
            slot and { kind = "slot", group = entry.group, slot = index } or empty,
            slot == nil,
            true
        )
    end)
end

-- Lays either fixed-height palette out with one virtualized entry per row.
local function DrawPalette(self, box, entry)
    box.header.label:SetText(entry.title)
    box.header.label:SetJustifyH("LEFT")
    box.header.layoutTarget = { kind = entry.palette == "unrostered" and "palette" or "variable" }

    local scrollbar = AcquirePaletteScrollbar(self, box, entry.palette)
    scrollbar:ClearAllPoints()
    scrollbar:SetPoint(
        "TOPRIGHT",
        box,
        "TOPRIGHT",
        -BOX_PADDING,
        -(BOX_PADDING + HEADER_HEIGHT + SCROLLBAR_END_PADDING)
    )
    scrollbar:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -BOX_PADDING, BOX_PADDING + SCROLLBAR_END_PADDING)

    local maximum = max(#entry.slots - PALETTE_VISIBLE_ROWS, 0)
    local offset = min(max(floor(self.paletteOffsets[entry.palette] or 0), 0), maximum)
    self.paletteOffsets[entry.palette] = offset
    scrollbar:SetMinMaxValues(0, maximum)
    scrollbar:SetValue(offset)
    scrollbar:SetShown(maximum > 0)

    local rows = max(min(#entry.slots, PALETTE_VISIBLE_ROWS), 1)
    local rightInset = maximum > 0 and (SCROLLBAR_WIDTH + SCROLLBAR_GAP) or 0
    StackRows(self, box, rows, function(row, index)
        local item = entry.slots[offset + index]
        if entry.palette == "variables" then
            FillRow(
                row,
                item and item.Label,
                { kind = "variable", text = item and item.Text, key = item and item.Key },
                false,
                false
            )
        else
            local text = item and item.Text
            FillRow(row, text, { kind = "palette", text = text, fullName = item and item.FullName }, false, false)
        end
        row:EnableMouseWheel(true)
        row.paletteBox = box
        row:SetScript("OnMouseWheel", PaletteChild_OnMouseWheel)
    end, rightInset, GRID_CONTENT_HEIGHT)
end

--[[-----------------------------------------------------------------------------
Methods
-------------------------------------------------------------------------------]]
local methods = {
    ["OnAcquire"] = function(self)
        CancelDrag(self)
        self.layout = nil
        self.model = nil
        self.roster = {}
        self.resolveProviders = nil
        self.dragging = nil
        self.dropTarget = nil
        self.drawing = true
        self.drawnWidth = nil
        self.measuredHeight = nil
        self.safeDropFrame = nil
        self.disabled = false
        self.frame:SetAlpha(1)
        for _, box in ipairs(self.boxes) do
            if box.scrollbar then
                box.scrollbar:SetValue(0)
                box.scrollbar:Hide()
            end
        end
        self.paletteOffsets = {}
        self.drawing = nil
        self:SetWidth(400)
        self:SetHeight(GRID_HEIGHT)
    end,

    ["OnRelease"] = function(self)
        CancelDrag(self)
        self.layout = nil
        self.model = nil
        self.roster = {}
        self.resolveProviders = nil
        self.dragging = nil
        self.dropTarget = nil
        self.drawing = true
        self.drawnWidth = nil
        self.measuredHeight = nil
        self.safeDropFrame = nil
        self.disabled = false
        self.frame:SetAlpha(1)
        for _, box in ipairs(self.boxes) do
            if box.scrollbar then
                box.scrollbar:SetValue(0)
                box.scrollbar:Hide()
            end
            box:Hide()
        end
        self.paletteOffsets = {}
        self.drawing = nil
    end,

    -- Supplies the layout engine the widget reads grid structure from.
    -- @tparam table engine `AngryEra.utils.layout`.
    ["SetLayoutEngine"] = function(self, engine)
        self.layout = engine
    end,

    -- Replaces the layout model on display.
    -- @tparam table model Layout model.
    ["SetLayoutModel"] = function(self, model)
        self.model = model
        self:Refresh()
    end,

    -- Replaces the roster the palette draws from.
    -- Accepts legacy name strings or identity-aware entries with Text,
    -- FullName, and ShortName fields.
    -- @tparam table roster Array of strings or roster-entry tables.
    ["SetRoster"] = function(self, roster)
        self.roster = NormalizeRoster(roster)
        self:Refresh()
    end,

    -- Supplies the live-roster/variable providers used to resolve placed slots.
    -- @tparam table providers Providers accepted by `layout.Resolve`.
    ["SetResolveProviders"] = function(self, providers)
        self.resolveProviders = type(providers) == "table" and providers or nil
        self:Refresh()
    end,

    -- Supplies a containing editor frame whose empty chrome cancels a drag.
    -- A slot is removed only after it leaves this safe frame altogether.
    ["SetSafeDropFrame"] = function(self, frame)
        self.safeDropFrame = frame
    end,

    -- Makes the rendered layout a read-only preview. Palette scrolling remains
    -- available, but clicks and drags cannot emit mutation callbacks.
    -- @tparam boolean disabled
    ["SetDisabled"] = function(self, disabled)
        disabled = disabled and true or false
        if self.disabled == disabled then
            return
        end
        self.disabled = disabled
        if disabled and self.dragging then
            CancelDrag(self)
        end
        self.frame:SetAlpha(disabled and 0.55 or 1)
    end,

    -- A redraw asks the container to re-flow, and the container answers by
    -- re-applying our width. Redrawing only on a real change settles that loop.
    ["OnWidthSet"] = function(self, width)
        if width and width == self.drawnWidth then
            return
        end
        self:Refresh()
    end,

    -- Redraws every box from the current model and roster.
    -- Groups fill two columns, odd-numbered on the left and even on the right.
    -- The fixed-height, independently scrolling Unrostered and Variables
    -- palettes stand in the third and fourth columns.
    ["Refresh"] = function(self)
        if not self.layout or self.drawing then
            return
        end
        if self.dragging then
            CancelDrag(self)
        end

        local width = self.frame:GetWidth()
        if not width or width < 1 then
            return
        end

        self.drawing = true
        local plan = BuildBoxPlan(self)
        local columnWidth = (width - ((TOTAL_COLUMNS - 1) * BOX_SPACING)) / TOTAL_COLUMNS
        local step = columnWidth + BOX_SPACING
        local placed, auxiliary, top, rowHeight = 0, 0, GRID_TOP_INSET, 0

        for index, entry in ipairs(plan) do
            local box = AcquireBox(self, index)
            box:ClearAllPoints()
            box:SetWidth(columnWidth)

            if entry.palette then
                box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", (GROUP_COLUMNS + auxiliary) * step, -GRID_TOP_INSET)
                DrawPalette(self, box, entry)
                auxiliary = auxiliary + 1
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
            end
        end

        for index = #plan + 1, #self.boxes do
            self.boxes[index]:Hide()
        end

        self.frame.height = GRID_HEIGHT
        self.frame:SetHeight(GRID_HEIGHT)
        self.drawnWidth = width
        self.drawing = nil
        if self.parent and self.parent.DoLayout then
            self.parent:DoLayout()
        end
        ReportHeight(self, GRID_HEIGHT)
    end,
}

--[[-----------------------------------------------------------------------------
Constructor
-------------------------------------------------------------------------------]]
local function Constructor()
    widgetSequence = widgetSequence + 1
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local marker = CreateFrame("Frame", nil, frame)
    marker:Hide()
    marker:EnableMouse(false)

    -- The raid-row highlight crop contains ornamental gaps that look like a
    -- broken border when stretched to these wider editor cells. A faint tint
    -- plus four solid edges stays continuous at every cell width.
    local markerFill, markerEdges = CreateGoldHighlight(marker, "ARTWORK", "OVERLAY")
    marker.fill = markerFill
    marker.edges = markerEdges

    local ghost = CreateFrame("Frame", nil, frame)
    ghost:Hide()
    ghost:EnableMouse(false)
    ghost:SetAlpha(0.9)
    ghost:SetHeight(ROW_HEIGHT)
    local ghostBackground = ghost:CreateTexture(nil, "BACKGROUND")
    StyleRaidRowTexture(ghostBackground)
    ghost.background = ghostBackground
    local ghostLabel = ghost:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    ghostLabel:SetPoint("LEFT", ghostBackground, "LEFT", ROW_TEXT_PADDING, 0)
    ghostLabel:SetPoint("RIGHT", ghostBackground, "RIGHT", -ROW_TEXT_PADDING, 0)
    ghostLabel:SetHeight(RAID_ROW_HEIGHT)
    ghostLabel:SetJustifyH("LEFT")
    ghostLabel:SetFontObject(GameFontHighlightSmall)
    if ghostLabel.SetWordWrap then
        ghostLabel:SetWordWrap(false)
    end
    if ghostLabel.SetNonSpaceWrap then
        ghostLabel:SetNonSpaceWrap(false)
    end
    if ghostLabel.SetMaxLines then
        ghostLabel:SetMaxLines(1)
    end
    ghost.label = ghostLabel

    local placeholder = CreateFrame("Frame", nil, frame)
    placeholder:Hide()
    placeholder:EnableMouse(false)
    local placeholderBackground = placeholder:CreateTexture(nil, "BACKGROUND")
    StyleRaidRowTexture(placeholderBackground)
    placeholder.background = placeholderBackground
    local placeholderLabel = placeholder:CreateFontString(nil, "ARTWORK", "GameFontDarkGraySmall")
    placeholderLabel:SetPoint("LEFT", placeholderBackground, "LEFT")
    placeholderLabel:SetPoint("RIGHT", placeholderBackground, "RIGHT")
    placeholderLabel:SetHeight(RAID_ROW_HEIGHT)
    placeholderLabel:SetJustifyH("CENTER")
    placeholderLabel:SetFontObject(GameFontDarkGraySmall)
    placeholderLabel:SetText(EMPTY_ROW_LABEL)
    placeholder.label = placeholderLabel

    local widget = {
        frame = frame,
        dropMarker = marker,
        dragGhost = ghost,
        dragSourcePlaceholder = placeholder,
        boxes = {},
        roster = {},
        sequence = widgetSequence,
        type = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end
    frame.obj = widget

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
