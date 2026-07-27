--- Custom AceGUI TreeGroup container used by AngryEra.
-- Adds search filtering, drag-and-drop ordering, per-row menu actions, and
-- a visible resize handle over the base AceGUI TreeGroup behavior.
-- @module AngryTreeGroup

local Type, Version = "AngryTreeGroup", 5
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then
    return
end

local IsLegion = select(4, GetBuildInfo()) >= 70000

-- Lua APIs
local next, pairs, ipairs, assert, type = next, pairs, ipairs, assert, type
local math_min, math_max, floor = math.min, math.max, floor
local select, tremove, unpack, tconcat = select, table.remove, unpack, table.concat

-- WoW APIs
local CreateFrame, UIParent = CreateFrame, UIParent

-- Global vars/functions that we don't upvalue since they might get hooked, or upgraded
-- List them here for Mikk's FindGlobals script
-- GLOBALS: GameTooltip, FONT_COLOR_CODE_CLOSE

-- Recycling functions
local new, del
do
    local pool = setmetatable({}, { __mode = "k" })
    function new()
        local t = next(pool)
        if t then
            pool[t] = nil
            return t
        else
            return {}
        end
    end
    function del(t)
        for k in pairs(t) do
            t[k] = nil
        end
        pool[t] = true
    end
end

local DEFAULT_TREE_WIDTH = 175
local DEFAULT_TREE_SIZABLE = true

--[[-----------------------------------------------------------------------------
Support functions
-------------------------------------------------------------------------------]]
--- Builds the full unique path key for a line.
-- @tparam table line Tree line entry.
-- @treturn string Unique value using internal `\001` separators.
local function GetButtonUniqueValue(line)
    local parent = line.parent
    if parent and parent.value then
        return GetButtonUniqueValue(parent) .. "\001" .. line.value
    else
        return line.value
    end
end

--- Applies tree-line data and visual state to a row button.
-- @tparam table button Tree row button.
-- @tparam table treeline Flattened line metadata.
-- @tparam boolean selected Whether the row is selected.
-- @tparam boolean canExpand Whether the row has children.
-- @tparam boolean isExpanded Whether children are currently expanded.
local function UpdateButton(button, treeline, selected, canExpand, isExpanded)
    local self = button.obj
    if GameTooltip:IsOwned(button) then
        GameTooltip:Hide()
    end
    local toggle = button.toggle
    local text = treeline.text or ""
    local icon = treeline.icon
    local iconCoords = treeline.iconCoords
    local level = treeline.level
    local value = treeline.value
    local uniquevalue = treeline.uniquevalue
    local disabled = treeline.disabled
    local pinned = treeline.pinned
    local separator = treeline.separator

    button.treeline = treeline
    button.value = value
    button.uniquevalue = uniquevalue
    if selected then
        button:LockHighlight()
        button.selected = true
    else
        button:UnlockHighlight()
        button.selected = false
    end
    button.level = level

    local indent = (level - 1) * 7 + 2
    if separator then
        button:UnlockHighlight()
        button.selected = false
        button.separatorLine:ClearAllPoints()
        button.separatorLine:SetPoint("LEFT", button, "LEFT", indent + 5, 0)
        button.separatorLine:SetPoint("RIGHT", button, "RIGHT", -8, 0)
        button.separatorLine:Show()
        button.icon:SetTexture(nil)
        button.pinBadge:Hide()
        button.menuBtn:Hide()
        button.text:SetText("")
        toggle:Hide()
        button:EnableMouse(false)
        return
    end
    button.separatorLine:Hide()

    toggle:ClearAllPoints()
    toggle:SetPoint("LEFT", indent, 1)

    -- Adjust Text & Icon
    button.text:ClearAllPoints()

    if icon then
        button.icon:SetTexture(icon)
        button.icon:SetPoint("LEFT", indent, 1)
        button.text:SetPoint("LEFT", button.icon, "RIGHT", 2, 0)
    else
        button.icon:SetTexture(nil)
        button.text:SetPoint("LEFT", toggle, "RIGHT", 2, 0)
    end

    if pinned then
        button.pinBadge:Show()
        button.text:SetPoint("RIGHT", button.pinBadge, "LEFT", -3, 0)
    else
        button.pinBadge:Hide()
        button.text:SetPoint("RIGHT", button.menuBtn, "LEFT", -2, 0)
    end

    if disabled then
        button:EnableMouse(false)
        button.text:SetText("|cff808080" .. text .. FONT_COLOR_CODE_CLOSE)
    else
        button.text:SetText(text)
        button:EnableMouse(true)
    end

    if iconCoords then
        button.icon:SetTexCoord(unpack(iconCoords))
    else
        button.icon:SetTexCoord(0, 1, 0, 1)
    end

    -- Initial Menu Button State
    if button.menuBtn then
        if button:IsMouseOver() then
            button.menuBtn:Show()
        else
            button.menuBtn:Hide()
        end
    end

    if type(value) == "number" and value < 0 then
        button:SetNormalFontObject("GameFontNormal")
        button:SetHighlightFontObject("GameFontHighlight")
    else
        button:SetNormalFontObject("GameFontHighlight")
        button:SetHighlightFontObject("GameFontHighlight")
    end

    if self.buttonFont then
        local fontObject = button:GetNormalFontObject()
        button.text:SetFont(self.buttonFont, self.buttonFontSize or 11)
        if fontObject then
            local r, g, b = fontObject:GetTextColor()
            button.text:SetTextColor(r, g, b)
        end
    end

    if canExpand then
        if not isExpanded then
            toggle:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-UP")
            toggle:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-DOWN")
        else
            toggle:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-UP")
            toggle:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-DOWN")
        end
        toggle:Show()
    else
        toggle:Hide()
    end
end

--- Returns true when a level has at least one visible leaf.
-- @tparam table tree Nested tree node list.
-- @treturn boolean visible
local function ShouldDisplayLevel(tree)
    local result = false
    for k, v in ipairs(tree) do
        if v.children == nil and v.visible ~= false then
            result = true
        elseif v.children then
            result = result or ShouldDisplayLevel(v.children)
        end
        if result then
            return result
        end
    end
    return false
end

--- Adds one visible line entry to the flattened tree cache.
-- @tparam table self Widget instance.
-- @tparam table v Source tree node.
-- @tparam table tree Sibling list containing `v`.
-- @tparam number level Display nesting level.
-- @tparam[opt] table parent Parent flattened line.
-- @treturn table line Flattened line entry.
local function addLine(self, v, tree, level, parent)
    local line = new()
    line.value = v.value
    line.text = v.text
    line.icon = v.icon
    line.iconCoords = v.iconCoords
    line.disabled = v.disabled
    line.pinned = v.pinned
    line.separator = v.separator
    line.tree = tree
    line.level = level
    line.parent = parent
    line.visible = v.visible
    line.uniquevalue = GetButtonUniqueValue(line)
    if v.children then
        line.hasChildren = true
    else
        line.hasChildren = nil
    end
    self.lines[#self.lines + 1] = line
    return line
end

--fire an update after one frame to catch the treeframes height
local function FirstFrameUpdate(frame)
    local self = frame.obj
    frame:SetScript("OnUpdate", nil)
    self:RefreshTree()
end

--- Builds a path key from one or more path segments.
-- @tparam string ... Path segments.
-- @treturn string Unique key using internal `\001` separators.
local function BuildUniqueValue(...)
    local n = select("#", ...)
    if n == 1 then
        return ...
    else
        return (...) .. "\001" .. BuildUniqueValue(select(2, ...))
    end
end

--[[-----------------------------------------------------------------------------
Scripts
-------------------------------------------------------------------------------]]
local function Expand_OnClick(frame)
    local button = frame.button
    if button.treeline and button.treeline.separator then
        return
    end
    local self = button.obj
    local status = (self.status or self.localstatus).groups
    status[button.uniquevalue] = not status[button.uniquevalue]
    self:RefreshTree()
end

local function GetMouseFocus()
    if _G.GetMouseFocus then
        return _G.GetMouseFocus()
    else
        local foci = _G.GetMouseFoci and _G.GetMouseFoci()
        return foci and foci[1]
    end
end

local function GetButtonFromFrame(frame)
    while frame do
        if frame.obj and frame.treeline then
            return frame
        end
        frame = frame:GetParent()
        if frame == UIParent then
            break
        end
    end
    return nil
end

local function Drag_OnUpdate(frame)
    local self = frame.obj
    local dragging = self.dragging
    if not dragging then
        return
    end

    local focus = GetMouseFocus()
    local button = GetButtonFromFrame(focus)
    local line = self.draggerLine

    if button and button.obj == self and not button.treeline.separator then
        local top = button:GetTop()
        local bottom = button:GetBottom()
        if not top or not bottom then
            return
        end

        local _, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        y = y / scale

        local range = top - bottom
        local ratio = (y - bottom) / range

        line:ClearAllPoints()
        line:Show()
        line:SetWidth(self.treeframe:GetWidth() - 20)
        line:SetPoint("LEFT", self.treeframe, "LEFT", 10, 0)

        if ratio > 0.75 then
            line:SetPoint("BOTTOM", button, "TOP", 0, 0)
            self.dragPosition = "before"
            line:SetColorTexture(1, 1, 1, 0.5)
            line:SetHeight(2)
        elseif ratio < 0.25 then
            local isExpanded = false
            if
                type(button.treeline.value) == "number"
                and button.treeline.value < 0
                and self.status
                and self.status.groups
                and self.status.groups[button.uniquevalue]
            then
                isExpanded = true
            end

            if isExpanded then
                line:SetPoint("TOP", button, "BOTTOM", 0, 0)
                self.dragPosition = "into_start"
                line:SetColorTexture(1, 1, 1, 0.5)
                line:SetHeight(2)
            else
                line:SetPoint("TOP", button, "BOTTOM", 0, 0)
                self.dragPosition = "after"
                line:SetColorTexture(1, 1, 1, 0.5)
                line:SetHeight(2)
            end
        else
            if type(button.treeline.value) == "number" and button.treeline.value < 0 then
                self.dragPosition = "into"
                line:SetPoint("CENTER", button, "CENTER", 0, 0)
                line:SetColorTexture(0, 1, 0, 0.3)
                line:SetHeight(button:GetHeight())
            else
                line:SetPoint("TOP", button, "BOTTOM", 0, 0)
                self.dragPosition = "after"
                line:SetColorTexture(1, 1, 1, 0.5)
                line:SetHeight(2)
            end
        end
    else
        line:Hide()
        self.dragPosition = nil
    end
end

local function Button_OnDragStart(button)
    if button.treeline and button.treeline.separator then
        return
    end
    local self = button.obj
    self.dragging = button.uniquevalue
    CloseDropDownMenus()
    SetCursor("Interface\\CURSOR\\Point.blp")
    self.treeframe:SetScript("OnUpdate", Drag_OnUpdate)
end

local function Button_OnDragStop(button)
    local self = button.obj
    local source = self.dragging
    self.dragging = nil
    SetCursor(nil)
    self.treeframe:SetScript("OnUpdate", nil)
    if self.draggerLine then
        self.draggerLine:Hide()
    end

    local focus = GetMouseFocus()
    local target = GetButtonFromFrame(focus)

    if
        source
        and target
        and target.obj == self
        and target.treeline
        and not target.treeline.separator
        and self.dragPosition
    then
        self:Fire("OnTreeDragDrop", source, target.uniquevalue, self.dragPosition)
    end
    self.dragPosition = nil
end

local function Button_OnClick(frame, button)
    if frame.treeline and frame.treeline.separator then
        return false
    end
    local self = frame.obj
    local result = self:Fire("OnClick", frame.uniquevalue, frame.selected, button)
    if result ~= false and not frame.selected then
        self:SetSelected(frame.uniquevalue)
        frame.selected = true
        frame:LockHighlight()
        self:RefreshTree()
    end
    AceGUI:ClearFocus()
end

local function Button_OnEnter(frame)
    if frame.treeline and frame.treeline.separator then
        return
    end
    local self = frame.obj
    self:Fire("OnButtonEnter", frame.uniquevalue, frame)

    if frame.menuBtn then
        frame.menuBtn:Show()
    end

    if self.enabletooltips then
        GameTooltip:SetOwner(frame, "ANCHOR_NONE")
        GameTooltip:SetPoint("LEFT", frame, "RIGHT")
        GameTooltip:SetText(frame.text:GetText() or "")
        if frame.treeline and frame.treeline.pinned then
            GameTooltip:AddLine("Pinned locally", 1, 0.82, 0)
        end

        GameTooltip:Show()
    end
end

local function Button_OnLeave(frame)
    if frame.treeline and frame.treeline.separator then
        return
    end
    local self = frame.obj
    self:Fire("OnButtonLeave", frame.uniquevalue, frame)

    if frame.menuBtn and not frame.menuBtn:IsMouseOver() then
        frame.menuBtn:Hide()
    end

    if self.enabletooltips then
        GameTooltip:Hide()
    end
end

local function OnScrollValueChanged(frame, value)
    if frame.obj.noupdate then
        return
    end
    local self = frame.obj
    local status = self.status or self.localstatus
    status.scrollvalue = floor(value + 0.5)
    self:RefreshTree()
    AceGUI:ClearFocus()
end

local function Tree_OnSizeChanged(frame)
    frame.obj:RefreshTree()
end

local function Tree_OnMouseWheel(frame, delta)
    local self = frame.obj
    if self.showscroll then
        local scrollbar = self.scrollbar
        local min, max = scrollbar:GetMinMaxValues()
        local value = scrollbar:GetValue()
        local newvalue = math_min(max, math_max(min, value - delta))
        if value ~= newvalue then
            scrollbar:SetValue(newvalue)
        end
    end
end

local function Dragger_OnLeave(frame)
    frame:SetBackdropColor(1, 1, 1, 0.2)
end

local function Dragger_OnEnter(frame)
    frame:SetBackdropColor(1, 1, 1, 0.8)
end

local function Dragger_OnMouseDown(frame)
    local treeframe = frame:GetParent()
    treeframe:StartSizing("RIGHT")
end

local function Dragger_OnMouseUp(frame)
    local treeframe = frame:GetParent()
    local self = treeframe.obj
    local parentFrame = treeframe:GetParent()
    treeframe:StopMovingOrSizing()
    --treeframe:SetScript("OnUpdate", nil)
    treeframe:SetUserPlaced(false)
    --Without this :GetHeight will get stuck on the current height, causing the tree contents to not resize
    treeframe:SetHeight(0)
    treeframe:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 0, 0)
    treeframe:SetPoint("BOTTOMLEFT", parentFrame, "BOTTOMLEFT", 0, 0)

    local status = self.status or self.localstatus
    status.treewidth = treeframe:GetWidth()

    treeframe.obj:Fire("OnTreeResize", treeframe:GetWidth())
    -- recalculate the content width
    treeframe.obj:OnWidthSet(status.fullwidth)
    -- update the layout of the content
    treeframe.obj:DoLayout()
end

--[[-----------------------------------------------------------------------------
Methods
-------------------------------------------------------------------------------]]
-- AngryTreeGroup widget method table.
-- Methods are attached to the widget instance in `Constructor`.
local methods = {
    ["OnAcquire"] = function(self)
        self:SetTreeWidth(DEFAULT_TREE_WIDTH, DEFAULT_TREE_SIZABLE)
        self:EnableButtonTooltips(true)
        self.frame:SetScript("OnUpdate", FirstFrameUpdate)
    end,

    ["OnRelease"] = function(self)
        self.status = nil
        for k, v in pairs(self.localstatus) do
            if k == "groups" then
                for k2 in pairs(v) do
                    v[k2] = nil
                end
            else
                self.localstatus[k] = nil
            end
        end
        self.localstatus.scrollvalue = 0
        self.localstatus.treewidth = DEFAULT_TREE_WIDTH
        self.localstatus.treesizable = DEFAULT_TREE_SIZABLE
    end,

    ["SetButtonFont"] = function(self, font, size)
        self.buttonFont = font
        self.buttonFontSize = size
        self:RefreshTree()
    end,

    ["EnableButtonTooltips"] = function(self, enable)
        self.enabletooltips = enable
    end,

    -- Creates a reusable row button for one tree line.
    ["CreateButton"] = function(self)
        local num = AceGUI:GetNextWidgetNum("TreeGroupButton")
        local button =
            CreateFrame("Button", ("AceGUI30TreeButton%d"):format(num), self.treeframe, "OptionsListButtonTemplate")
        button.obj = self

        local icon = button:CreateTexture(nil, "OVERLAY")
        icon:SetWidth(14)
        icon:SetHeight(14)
        button.icon = icon

        local separatorLine = button:CreateTexture(nil, "ARTWORK")
        separatorLine:SetHeight(1)
        separatorLine:SetColorTexture(0.45, 0.45, 0.45, 0.8)
        separatorLine:Hide()
        button.separatorLine = separatorLine

        -- Menu Button
        local menuBtn = CreateFrame("Button", nil, button)
        menuBtn:SetWidth(12)
        menuBtn:SetHeight(12)
        menuBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
        menuBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        menuBtn:SetScript("OnClick", function(this)
            if button.treeline and button.treeline.separator then
                return
            end
            self:Fire("OnButtonMenu", button.uniquevalue)
        end)
        menuBtn:SetScript("OnEnter", function(this)
            button:LockHighlight()
        end)
        menuBtn:SetScript("OnLeave", function(this)
            if not button:IsMouseOver() then
                this:Hide()
                if not button.selected then
                    button:UnlockHighlight()
                end
            end
        end)
        menuBtn:SetPoint("RIGHT", button, "RIGHT", -9, 1)
        button.menuBtn = menuBtn

        local pinBadge = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pinBadge:SetWidth(20)
        pinBadge:SetJustifyH("RIGHT")
        pinBadge:SetPoint("RIGHT", menuBtn, "LEFT", -2, 0)
        pinBadge:SetText("PIN")
        pinBadge:SetTextColor(1, 0.82, 0)
        pinBadge:Hide()
        button.pinBadge = pinBadge

        button:RegisterForDrag("LeftButton")
        button:SetScript("OnDragStart", Button_OnDragStart)
        button:SetScript("OnDragStop", Button_OnDragStop)

        button:SetScript("OnClick", Button_OnClick)
        --button:SetScript("OnDoubleClick", Button_OnDoubleClick)
        button:SetScript("OnEnter", Button_OnEnter)
        button:SetScript("OnLeave", Button_OnLeave)

        button.toggle.button = button
        button.toggle:SetScript("OnClick", Expand_OnClick)

        button.text:SetHeight(14) -- Prevents text wrapping

        return button
    end,

    ["SetStatusTable"] = function(self, status)
        assert(type(status) == "table")
        self.status = status
        if not status.groups then
            status.groups = {}
        end
        if not status.scrollvalue then
            status.scrollvalue = 0
        end
        if not status.treewidth then
            status.treewidth = DEFAULT_TREE_WIDTH
        end
        if status.treesizable == nil then
            status.treesizable = DEFAULT_TREE_SIZABLE
        end
        self:SetTreeWidth(status.treewidth, status.treesizable)
        self:RefreshTree()
    end,

    --sets the tree to be displayed
    ["SetTree"] = function(self, tree, filter)
        self.filter = filter
        if tree then
            assert(type(tree) == "table")
        end
        self.tree = tree
        self:RefreshTree()
    end,

    ["BuildLevel"] = function(self, tree, level, parent)
        local groups = (self.status or self.localstatus).groups
        local keywordLower = nil
        if type(self.searchKeyword) == "string" and self.searchKeyword ~= "" then
            keywordLower = self.searchKeyword:lower()
        end

        for i, v in ipairs(tree) do
            if v.children then
                if not self.filter or ShouldDisplayLevel(v.children) then
                    local line = addLine(self, v, tree, level, parent)
                    if groups[line.uniquevalue] then
                        self:BuildLevel(v.children, level + 1, line)
                    end
                end
            elseif
                (v.visible ~= false or not self.filter)
                and (not keywordLower or string.find(tostring(v.text or ""):lower(), keywordLower, 1, true))
            then
                addLine(self, v, tree, level, parent)
            end
        end
    end,

    ["RefreshTree"] = function(self, scrollToSelection)
        local buttons = self.buttons
        local lines = self.lines

        for i, v in ipairs(buttons) do
            v:Hide()
        end
        while lines[1] do
            local t = tremove(lines)
            for k in pairs(t) do
                t[k] = nil
            end
            del(t)
        end

        if not self.tree then
            return
        end
        --Build the list of visible entries from the tree and status tables
        local status = self.status or self.localstatus
        local groupstatus = status.groups
        local tree = self.tree

        local treeframe = self.treeframe

        status.scrollToSelection = status.scrollToSelection or scrollToSelection -- needs to be cached in case the control hasn't been drawn yet (code bails out below)

        self:BuildLevel(tree, 1)

        local numlines = #lines

        local maxlines = (floor(((self.treeframe:GetHeight() or 0) - 20) / 18))
        if maxlines <= 0 then
            return
        end

        local first, last

        scrollToSelection = status.scrollToSelection
        status.scrollToSelection = nil

        if numlines <= maxlines then
            --the whole tree fits in the frame
            status.scrollvalue = 0
            self:ShowScroll(false)
            first, last = 1, numlines
        else
            self:ShowScroll(true)
            --scrolling will be needed
            self.noupdate = true
            self.scrollbar:SetMinMaxValues(0, numlines - maxlines)
            --check if we are scrolled down too far
            if numlines - status.scrollvalue < maxlines then
                status.scrollvalue = numlines - maxlines
            end
            self.noupdate = nil
            first, last = status.scrollvalue + 1, status.scrollvalue + maxlines
            --show selection?
            if scrollToSelection and status.selected then
                local show
                for i, line in ipairs(lines) do -- find the line number
                    if line.uniquevalue == status.selected then
                        show = i
                    end
                end
                if show and (show < first or show > last) then
                    -- scrolling needed!
                    if show < first then
                        status.scrollvalue = show - 1
                    else
                        status.scrollvalue = show - maxlines
                    end
                    first, last = status.scrollvalue + 1, status.scrollvalue + maxlines
                end
            end
            if self.scrollbar:GetValue() ~= status.scrollvalue then
                self.scrollbar:SetValue(status.scrollvalue)
            end
        end

        local buttonnum = 1
        for i = first, last do
            local line = lines[i]
            local button = buttons[buttonnum]
            if not button then
                button = self:CreateButton()

                buttons[buttonnum] = button
                button:SetParent(treeframe)
                button:SetFrameLevel(treeframe:GetFrameLevel() + 1)
                button:ClearAllPoints()
                if buttonnum == 1 then
                    if self.showscroll then
                        button:SetPoint("TOPRIGHT", -22, -10)
                        button:SetPoint("TOPLEFT", 0, -10)
                    else
                        button:SetPoint("TOPRIGHT", 0, -10)
                        button:SetPoint("TOPLEFT", 0, -10)
                    end
                else
                    button:SetPoint("TOPRIGHT", buttons[buttonnum - 1], "BOTTOMRIGHT", 0, 0)
                    button:SetPoint("TOPLEFT", buttons[buttonnum - 1], "BOTTOMLEFT", 0, 0)
                end
            end

            UpdateButton(
                button,
                line,
                status.selected == line.uniquevalue,
                line.hasChildren,
                groupstatus[line.uniquevalue]
            )
            button:Show()
            buttonnum = buttonnum + 1
        end
    end,

    ["SetSelected"] = function(self, value)
        local status = self.status or self.localstatus
        if status.selected ~= value then
            status.selected = value
            self:Fire("OnGroupSelected", value)
        end
    end,

    ["Select"] = function(self, uniquevalue, ...)
        self.filter = false
        local status = self.status or self.localstatus
        local groups = status.groups
        local path = { ... }
        for i = 1, #path do
            groups[tconcat(path, "\001", 1, i)] = true
        end
        status.selected = uniquevalue
        self:RefreshTree(true)
        self:Fire("OnGroupSelected", uniquevalue)
    end,

    ["SelectByPath"] = function(self, ...)
        self:Select(BuildUniqueValue(...), ...)
    end,

    ["SelectByValue"] = function(self, uniquevalue)
        self:Select(uniquevalue, ("\001"):split(uniquevalue))
    end,

    ["ShowScroll"] = function(self, show)
        self.showscroll = show
        if show then
            self.scrollbar:Show()
            if self.buttons[1] then
                self.buttons[1]:SetPoint("TOPRIGHT", self.treeframe, "TOPRIGHT", -22, -10)
            end
        else
            self.scrollbar:Hide()
            if self.buttons[1] then
                self.buttons[1]:SetPoint("TOPRIGHT", self.treeframe, "TOPRIGHT", 0, -10)
            end
        end
    end,

    ["OnWidthSet"] = function(self, width)
        local content = self.content
        local treeframe = self.treeframe
        local status = self.status or self.localstatus
        status.fullwidth = width

        local contentwidth = width - status.treewidth - 20
        if contentwidth < 0 then
            contentwidth = 0
        end
        content:SetWidth(contentwidth)
        content.width = contentwidth

        local maxtreewidth = math_min(400, width - 50)

        if maxtreewidth > 100 and status.treewidth > maxtreewidth then
            self:SetTreeWidth(maxtreewidth, status.treesizable)
        end
        if treeframe.SetResizeBounds then -- WoW 10.0
            treeframe:SetResizeBounds(100, 1, maxtreewidth, 1600)
        else
            treeframe:SetMaxResize(maxtreewidth, 1600)
        end
    end,

    ["OnHeightSet"] = function(self, height)
        local content = self.content
        local contentheight = height - 20
        if contentheight < 0 then
            contentheight = 0
        end
        content:SetHeight(contentheight)
        content.height = contentheight
    end,

    ["SetTreeWidth"] = function(self, treewidth, resizable)
        if not resizable then
            if type(treewidth) == "number" then
                resizable = false
            elseif type(treewidth) == "boolean" then
                resizable = treewidth
                treewidth = DEFAULT_TREE_WIDTH
            else
                resizable = false
                treewidth = DEFAULT_TREE_WIDTH
            end
        end
        self.treeframe:SetWidth(treewidth)
        self.dragger:EnableMouse(resizable)

        local status = self.status or self.localstatus
        status.treewidth = treewidth
        status.treesizable = resizable

        -- recalculate the content width
        if status.fullwidth then
            self:OnWidthSet(status.fullwidth)
        end
    end,

    ["GetTreeWidth"] = function(self)
        local status = self.status or self.localstatus
        return status.treewidth or DEFAULT_TREE_WIDTH
    end,

    ["LayoutFinished"] = function(self, width, height)
        if self.noAutoHeight then
            return
        end
        self:SetHeight((height or 0) + 20)
    end,

    ["SetSearchKeyword"] = function(self, searchKeyword)
        self.searchKeyword = searchKeyword
        self:RefreshTree()
    end,
}

--[[-----------------------------------------------------------------------------
Constructor
-------------------------------------------------------------------------------]]
local PaneBackdrop = {
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 3, right = 3, top = 5, bottom = 3 },
}

local DraggerBackdrop = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = nil,
    tile = true,
    tileSize = 16,
    edgeSize = 0,
    insets = { left = 3, right = 3, top = 7, bottom = 7 },
}

--- Constructs and registers the `AngryTreeGroup` AceGUI widget instance.
-- @treturn table widget AceGUI container instance.
local function Constructor()
    local num = AceGUI:GetNextWidgetNum(Type)
    local frame = CreateFrame("Frame", nil, UIParent)

    local treeframe = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    treeframe:SetPoint("TOPLEFT")
    treeframe:SetPoint("BOTTOMLEFT")
    treeframe:SetWidth(DEFAULT_TREE_WIDTH)
    treeframe:EnableMouseWheel(true)
    treeframe:SetBackdrop(PaneBackdrop)
    treeframe:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    treeframe:SetBackdropBorderColor(0.4, 0.4, 0.4)
    treeframe:SetResizable(true)
    if treeframe.SetResizeBounds then -- WoW 10.0
        treeframe:SetResizeBounds(100, 1, 400, 1600)
    else
        treeframe:SetMinResize(100, 1)
        treeframe:SetMaxResize(400, 1600)
    end
    treeframe:SetScript("OnUpdate", FirstFrameUpdate)
    treeframe:SetScript("OnSizeChanged", Tree_OnSizeChanged)
    treeframe:SetScript("OnMouseWheel", Tree_OnMouseWheel)

    local dragger = CreateFrame("Frame", nil, treeframe, BackdropTemplateMixin and "BackdropTemplate" or nil)
    dragger:SetWidth(8)
    dragger:SetPoint("TOP", treeframe, "TOPRIGHT")
    dragger:SetPoint("BOTTOM", treeframe, "BOTTOMRIGHT")
    dragger:SetBackdrop(DraggerBackdrop)
    dragger:SetBackdropColor(1, 1, 1, 0.2)
    dragger:SetScript("OnEnter", Dragger_OnEnter)
    dragger:SetScript("OnLeave", Dragger_OnLeave)
    dragger:SetScript("OnMouseDown", Dragger_OnMouseDown)
    dragger:SetScript("OnMouseUp", Dragger_OnMouseUp)

    local scrollbar = CreateFrame(
        "Slider",
        ("AceConfigDialogTreeGroup%dScrollBar"):format(num),
        treeframe,
        "UIPanelScrollBarTemplate"
    )
    scrollbar:SetScript("OnValueChanged", nil)
    scrollbar:SetPoint("TOPRIGHT", -10, -26)
    scrollbar:SetPoint("BOTTOMRIGHT", -10, 26)
    scrollbar:SetMinMaxValues(0, 0)
    scrollbar:SetValueStep(1)
    scrollbar:SetValue(0)
    scrollbar:SetWidth(16)
    scrollbar:SetScript("OnValueChanged", OnScrollValueChanged)

    local scrollbg = scrollbar:CreateTexture(nil, "BACKGROUND")
    scrollbg:SetAllPoints(scrollbar)

    if IsLegion then
        scrollbg:SetColorTexture(0, 0, 0, 0.4)
    else
        scrollbg:SetTexture(0, 0, 0, 0.4)
    end

    local border = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    border:SetPoint("TOPLEFT", treeframe, "TOPRIGHT")
    border:SetPoint("BOTTOMRIGHT")
    border:SetBackdrop(PaneBackdrop)
    border:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    border:SetBackdropBorderColor(0.4, 0.4, 0.4)

    -- Drag Feedback Line
    local draggerLine = treeframe:CreateTexture(nil, "OVERLAY")
    draggerLine:SetHeight(2)
    draggerLine:SetColorTexture(1, 1, 1, 1)
    draggerLine:Hide()

    --Container Support
    local content = CreateFrame("Frame", nil, border)
    content:SetPoint("TOPLEFT", 10, -10)
    content:SetPoint("BOTTOMRIGHT", -10, 10)

    local widget = {
        frame = frame,
        lines = {},
        levels = {},
        buttons = {},
        hasChildren = {},
        localstatus = { groups = {}, scrollvalue = 0 },
        filter = false,
        treeframe = treeframe,
        dragger = dragger,
        scrollbar = scrollbar,
        border = border,
        content = content,
        draggerLine = draggerLine,
        type = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end
    treeframe.obj, dragger.obj, scrollbar.obj = widget, widget, widget

    return AceGUI:RegisterAsContainer(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
