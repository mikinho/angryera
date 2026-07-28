-- -------------------------------------------------------------------------------
-- Angry Era: modules/ui/display.lua
--
-- HUD display frame, rendering pipeline, backdrop, glow notification.
-- -------------------------------------------------------------------------------

local appName, app = ...
local AngryEra = app.AngryEra
local helpers = AngryEra.utils.helpers
local colors = AngryEra.utils.colors
local tags = AngryEra.utils.tags
local variableHelpers = AngryEra.utils.variables
local rosterHelpers = AngryEra.utils.roster
local layoutHelpers = AngryEra.utils.layout

local EnsureUnitShortName = helpers.EnsureUnitShortName
local IterateGroupMembers = helpers.IterateGroupMembers
local ColorTable = colors.ColorTable
local HexToRGB = colors.HexToRGB
local ProcessTag = tags.ProcessTag

local lwin = app.libs.lwin
local LSM = app.libs.LSM
local LibMustache = app.libs.LibMustache

local currentGroup = nil
local AUTO_HIDE_REVEAL_SECONDS = 3
local AUTO_HIDE_FADE_SECONDS = 0.2

local function SetDisplayAutoHideAlpha(self, alpha)
    alpha = math.max(0, math.min(tonumber(alpha) or 1, 1))
    if self.display_text and type(self.display_text.SetAlpha) == "function" then
        self.display_text:SetAlpha(alpha)
    end
    if self.mover and type(self.mover.SetAlpha) == "function" then
        self.mover:SetAlpha(alpha)
    end
end

local function DisplayAutoHideState(self)
    local state = self._displayAutoHideState
    if type(state) ~= "table" then
        state = {
            HoldRemaining = 0,
        }
        self._displayAutoHideState = state
    end
    return state
end

local function CaptureDisplayAutoHideContent(self, page, displayedId, renderedText)
    local syncId = type(page) == "table" and rawget(page, "SyncId") or nil
    local identity
    if type(syncId) == "string" and syncId ~= "" then
        identity = "sync:" .. syncId
    elseif displayedId ~= nil then
        identity = "local:" .. tostring(displayedId)
    end

    local state = DisplayAutoHideState(self)
    local changed = state.PageIdentity ~= identity or state.RenderedText ~= renderedText
    state.PageIdentity = identity
    state.RenderedText = renderedText
    return changed, identity
end

local function ClearDisplayAutoHideContent(self)
    local state = DisplayAutoHideState(self)
    state.PageIdentity = nil
    state.RenderedText = nil
end

local function DisplayAutoHideDriver_OnUpdate(driver, elapsed)
    local owner = driver.owner
    if owner and type(owner.UpdateDisplayAutoHide) == "function" then
        owner:UpdateDisplayAutoHide(elapsed)
    end
end

local function IsDisplayAutoHideHovered(self)
    local hover = self.display_auto_hide_hover
    if not hover or type(hover.IsShown) ~= "function" or not hover:IsShown() then
        return false
    end

    -- Poll geometry instead of enabling mouse on an invisible frame, so an
    -- auto-hidden assignment never blocks clicks aimed at the world beneath it.
    if
        type(GetCursorPosition) == "function"
        and type(hover.GetLeft) == "function"
        and type(hover.GetRight) == "function"
        and type(hover.GetBottom) == "function"
        and type(hover.GetTop) == "function"
    then
        local left, right = hover:GetLeft(), hover:GetRight()
        local bottom, top = hover:GetBottom(), hover:GetTop()
        if left and right and bottom and top then
            local x, y = GetCursorPosition()
            local scale = type(hover.GetEffectiveScale) == "function" and hover:GetEffectiveScale() or 1
            scale = type(scale) == "number" and scale > 0 and scale or 1
            if type(x) == "number" and type(y) == "number" then
                x, y = x / scale, y / scale
                return x >= left and x <= right and y >= bottom and y <= top
            end
        end
    end

    return type(hover.IsMouseOver) == "function" and hover:IsMouseOver() or false
end

local function UpdateDisplayAutoHideHoverBounds(self, first, last)
    local hover = self.display_auto_hide_hover
    if not hover then
        return
    end

    hover:ClearAllPoints()
    if
        not first
        or not last
        or self:GetConfig("autoHide") ~= true
        or not self.display_text
        or not self.display_text:IsShown()
    then
        hover:Hide()
        return
    end

    if AngryAssign_State.directionUp then
        hover:SetPoint("TOPLEFT", last, "TOPLEFT", -4, 4)
        hover:SetPoint("BOTTOMRIGHT", first, "BOTTOMRIGHT", 4, -4)
    else
        hover:SetPoint("TOPLEFT", first, "TOPLEFT", -4, 4)
        hover:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", 4, -4)
    end
    hover:Show()
end

--- Advances the assignment display's opt-in hover fade.
-- @tparam number elapsed Seconds since the previous frame.
-- @treturn number alpha Applied display alpha.
function AngryEra:UpdateDisplayAutoHide(elapsed)
    local text = self.display_text
    local state = DisplayAutoHideState(self)
    local driver = self.display_auto_hide_driver
    if self:GetConfig("autoHide") ~= true or not text then
        state.HoldRemaining = 0
        SetDisplayAutoHideAlpha(self, 1)
        if driver then
            driver:SetScript("OnUpdate", nil)
        end
        return 1
    end

    elapsed = type(elapsed) == "number" and math.max(elapsed, 0) or 0
    state.HoldRemaining = math.max((tonumber(state.HoldRemaining) or 0) - elapsed, 0)

    local textShown = type(text.IsShown) ~= "function" or text:IsShown()
    local shouldShow = not textShown or state.HoldRemaining > 0 or IsDisplayAutoHideHovered(self)
    local targetAlpha = shouldShow and 1 or 0
    local currentAlpha = type(text.GetAlpha) == "function" and text:GetAlpha() or 1
    currentAlpha = type(currentAlpha) == "number" and currentAlpha or 1

    if currentAlpha ~= targetAlpha then
        local step = AUTO_HIDE_FADE_SECONDS > 0 and (elapsed / AUTO_HIDE_FADE_SECONDS) or 1
        if currentAlpha < targetAlpha then
            currentAlpha = math.min(currentAlpha + step, targetAlpha)
        else
            currentAlpha = math.max(currentAlpha - step, targetAlpha)
        end
        SetDisplayAutoHideAlpha(self, currentAlpha)
    end
    return currentAlpha
end

--- Reveals an auto-hidden assignment for a short, replaceable hold.
-- @tparam[opt=3] number seconds Hold duration.
-- @treturn boolean revealed Whether auto-hide is enabled and active.
function AngryEra:RevealDisplayForAutoHide(seconds)
    if self:GetConfig("autoHide") ~= true or not self.display_text then
        return false
    end

    local state = DisplayAutoHideState(self)
    state.HoldRemaining = type(seconds) == "number" and math.max(seconds, 0) or AUTO_HIDE_REVEAL_SECONDS
    if self.display_auto_hide_driver then
        self.display_auto_hide_driver:SetScript("OnUpdate", DisplayAutoHideDriver_OnUpdate)
    end
    self:UpdateDisplayAutoHide(0)
    return true
end

--- Applies the current auto-hide option immediately.
-- Disabling always restores full opacity; enabling may preview the behavior.
-- @tparam[opt=false] boolean reveal Start a fresh three-second reveal.
-- @treturn boolean enabled
function AngryEra:RefreshDisplayAutoHide(reveal)
    local enabled = self:GetConfig("autoHide") == true and self.display_text ~= nil
    local state = DisplayAutoHideState(self)
    local driver = self.display_auto_hide_driver
    if not enabled then
        state.HoldRemaining = 0
        SetDisplayAutoHideAlpha(self, 1)
        if driver then
            driver:SetScript("OnUpdate", nil)
        end
        if self.display_auto_hide_hover then
            self.display_auto_hide_hover:Hide()
        end
        return false
    end

    if driver then
        driver:SetScript("OnUpdate", DisplayAutoHideDriver_OnUpdate)
    end
    if reveal == true then
        state.HoldRemaining = AUTO_HIDE_REVEAL_SECONDS
    end
    self:UpdateDisplayAutoHide(0)
    return true
end

-- -------------------------
-- Keybinding globals
-- -------------------------

function AngryEra_ToggleDisplay()
    AngryEra:ToggleDisplay()
end

function AngryEra_ShowDisplay()
    AngryEra:ShowDisplay()
end

function AngryEra_HideDisplay()
    AngryEra:HideDisplay()
end

function AngryEra_PrevPage()
    AngryEra:PrevPage()
end

function AngryEra_NextPage()
    AngryEra:NextPage()
end

function AngryEra_FirstPage()
    AngryEra:FirstPage()
end

-- -------------------------
-- Mover / DragHandle
-- -------------------------

local function DragHandle_MouseDown(frame)
    frame:GetParent():GetParent():StartSizing("RIGHT")
end

local function DragHandle_MouseUp(frame)
    local display = frame:GetParent():GetParent()
    display:StopMovingOrSizing()
    AngryAssign_State.display.width = display:GetWidth()
    lwin.SavePosition(display)
    AngryEra:UpdateBackdrop()
end

local function Mover_MouseDown(frame)
    frame:GetParent():StartMoving()
end

local function Mover_MouseUp(frame)
    local display = frame:GetParent()
    display:StopMovingOrSizing()
    lwin.SavePosition(display)
end

-- -------------------------
-- Display frame
-- -------------------------

--- Resets display frame position, lock state, and direction settings.
function AngryEra:ResetPosition()
    AngryAssign_State.display = {}
    AngryAssign_State.directionUp = false
    AngryAssign_State.locked = false

    self.display_text:Show()
    self.mover:Show()
    self.frame:SetWidth(300)

    lwin.RegisterConfig(self.frame, AngryAssign_State.display)
    lwin.RestorePosition(self.frame)

    self:UpdateDirection()
    self:RefreshDisplayAutoHide(true)
end

--- Shows the on-screen assignment display.
-- @tparam[opt=true] boolean revealAutoHide Start a fresh auto-hide reveal.
function AngryEra:ShowDisplay(revealAutoHide)
    self.display_text:Show()
    self:UpdateBackdrop()
    AngryAssign_State.display.hidden = false
    self:RefreshDisplayAutoHide(revealAutoHide ~= false)
end

--- Hides the on-screen assignment display.
function AngryEra:HideDisplay()
    self.display_text:Hide()
    AngryAssign_State.display.hidden = true
    DisplayAutoHideState(self).HoldRemaining = 0
    if self.display_auto_hide_hover then
        self.display_auto_hide_hover:Hide()
    end
    self:RefreshDisplayAutoHide(false)
end

--- Toggles the on-screen assignment display visibility.
function AngryEra:ToggleDisplay()
    if self.display_text:IsShown() then
        self:HideDisplay()
    else
        self:ShowDisplay()
    end
end

--- Creates and initializes the on-screen assignment frame/mover widgets.
function AngryEra:CreateDisplay()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetPoint("CENTER", 0, 0)
    frame:SetWidth(AngryAssign_State.display.width or 300)
    frame:SetHeight(1)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetClampedToScreen(true)
    if frame.SetResizeBounds then -- WoW 10.0
        frame:SetResizeBounds(180, 1, 830, 1)
    else
        frame:SetMinResize(180, 1)
        frame:SetMaxResize(830, 1)
    end
    frame:SetFrameStrata("MEDIUM")
    self.frame = frame

    lwin.RegisterConfig(frame, AngryAssign_State.display)
    lwin.RestorePosition(frame)

    local text = CreateFrame("ScrollingMessageFrame", nil, frame)
    text:SetIndentedWordWrap(true)
    text:SetJustifyH("LEFT")
    text:SetFading(false)
    text:SetMaxLines(70)
    text:SetHeight(700)
    text:SetHyperlinksEnabled(false)
    self.display_text = text

    local backdrop = text:CreateTexture()
    backdrop:SetDrawLayer("BACKGROUND")
    self.backdrop = backdrop

    local mover = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    mover:SetPoint("LEFT", 0, 0)
    mover:SetPoint("RIGHT", 0, 0)
    mover:SetHeight(16)
    mover:EnableMouse(true)
    mover:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
    mover:SetBackdropColor(0.616, 0.149, 0.114, 0.9)
    mover:SetScript("OnMouseDown", Mover_MouseDown)
    mover:SetScript("OnMouseUp", Mover_MouseUp)
    self.mover = mover
    if AngryAssign_State.locked then
        mover:Hide()
    end

    local label = mover:CreateFontString()
    label:SetFontObject("GameFontNormal")
    label:SetJustifyH("CENTER")
    label:SetPoint("LEFT", 38, 0)
    label:SetPoint("RIGHT", -38, 0)
    label:SetText(AngryEra.Title)

    local direction = CreateFrame("Button", nil, mover)
    direction:SetPoint("LEFT", 2, 0)
    direction:SetWidth(16)
    direction:SetHeight(16)
    direction:SetNormalTexture("Interface\\Buttons\\UI-Panel-QuestHideButton")
    direction:SetPushedTexture("Interface\\Buttons\\UI-Panel-QuestHideButton")
    direction:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    direction:SetScript("OnClick", function()
        AngryEra:ToggleDirection()
    end)
    self.direction_button = direction

    local lock = CreateFrame("Button", nil, mover)
    lock:SetNormalTexture("Interface\\LFGFRAME\\UI-LFG-ICON-LOCK")
    lock:GetNormalTexture():SetTexCoord(0, 0.71875, 0, 0.875)
    lock:SetPoint("LEFT", direction, "RIGHT", 4, 0)
    lock:SetWidth(12)
    lock:SetHeight(14)
    lock:SetScript("OnClick", function()
        AngryEra:ToggleLock()
    end)

    local drag = CreateFrame("Frame", nil, mover)
    drag:SetFrameLevel(mover:GetFrameLevel() + 10)
    drag:SetWidth(16)
    drag:SetHeight(16)
    drag:SetPoint("BOTTOMRIGHT", 0, 0)
    drag:EnableMouse(true)
    drag:SetScript("OnMouseDown", DragHandle_MouseDown)
    drag:SetScript("OnMouseUp", DragHandle_MouseUp)
    drag:SetAlpha(0.5)

    local dragtex = drag:CreateTexture(nil, "OVERLAY")
    dragtex:SetTexture("Interface\\AddOns\\" .. appName .. "\\textures\\draghandle")
    dragtex:SetWidth(16)
    dragtex:SetHeight(16)
    dragtex:SetBlendMode("ADD")
    dragtex:SetPoint("CENTER", drag)

    local glow = text:CreateTexture()
    glow:SetDrawLayer("BORDER")
    glow:SetTexture("Interface\\AddOns\\" .. appName .. "\\textures\\leveluptex")
    glow:SetSize(223, 115)
    glow:SetTexCoord(0.56054688, 0.99609375, 0.24218750, 0.46679688)
    glow:SetVertexColor(HexToRGB(self:GetConfig("glowColor")))
    glow:SetAlpha(0)
    self.display_glow = glow

    local glow2 = text:CreateTexture()
    glow2:SetDrawLayer("BORDER")
    glow2:SetTexture("Interface\\AddOns\\" .. appName .. "\\textures\\leveluptex")
    glow2:SetSize(418, 7)
    glow2:SetTexCoord(0.00195313, 0.81835938, 0.01953125, 0.03320313)
    glow2:SetVertexColor(HexToRGB(self:GetConfig("glowColor")))
    glow2:SetAlpha(0)
    self.display_glow2 = glow2

    -- The display root is one pixel tall and the message frame is always 700
    -- pixels tall. This transparent sibling instead follows the actual rendered
    -- lines, so hover-to-reveal neither misses the note nor claims empty screen.
    local autoHideHover = CreateFrame("Frame", nil, frame)
    autoHideHover:EnableMouse(false)
    autoHideHover:Hide()
    self.display_auto_hide_hover = autoHideHover

    local autoHideDriver = CreateFrame("Frame", nil, frame)
    autoHideDriver:SetAllPoints(frame)
    autoHideDriver.owner = self
    self.display_auto_hide_driver = autoHideDriver

    if AngryAssign_State.display.hidden then
        text:Hide()
    end
    self:UpdateMedia()
    self:UpdateDirection()
    self:RefreshDisplayAutoHide(false)
end

function AngryEra:ToggleLock()
    AngryAssign_State.locked = not AngryAssign_State.locked
    if AngryAssign_State.locked then
        self.mover:Hide()
    else
        self.mover:Show()
    end
    self:RefreshDisplayAutoHide(not AngryAssign_State.locked)
end

function AngryEra:ToggleDirection()
    AngryAssign_State.directionUp = not AngryAssign_State.directionUp
    self:UpdateDirection()
end

function AngryEra:UpdateDirection()
    if AngryAssign_State.directionUp then
        self.display_text:ClearAllPoints()
        self.display_text:SetPoint("BOTTOMLEFT", 0, 8)
        self.display_text:SetPoint("RIGHT", 0, 0)
        self.display_text:SetInsertMode(SCROLLING_MESSAGE_FRAME_INSERT_MODE_BOTTOM)
        self.direction_button:GetNormalTexture():SetTexCoord(0, 0.5, 0.5, 1)
        self.direction_button:GetPushedTexture():SetTexCoord(0.5, 1, 0.5, 1)

        self.display_glow:ClearAllPoints()
        self.display_glow:SetPoint("BOTTOM", 0, -4)
        self.display_glow:SetTexCoord(0.56054688, 0.99609375, 0.24218750, 0.46679688)
        self.display_glow2:ClearAllPoints()
        self.display_glow2:SetPoint("TOP", self.display_glow, "BOTTOM", 0, 6)
    else
        self.display_text:ClearAllPoints()
        self.display_text:SetPoint("TOPLEFT", 0, -8)
        self.display_text:SetPoint("RIGHT", 0, 0)
        self.display_text:SetInsertMode(SCROLLING_MESSAGE_FRAME_INSERT_MODE_TOP)
        self.direction_button:GetNormalTexture():SetTexCoord(0, 0.5, 0, 0.5)
        self.direction_button:GetPushedTexture():SetTexCoord(0.5, 1, 0, 0.5)

        self.display_glow:ClearAllPoints()
        self.display_glow:SetPoint("TOP", 0, 4)
        self.display_glow:SetTexCoord(0.56054688, 0.99609375, 0.46679688, 0.24218750)
        self.display_glow2:ClearAllPoints()
        self.display_glow2:SetPoint("BOTTOM", self.display_glow, "TOP", 0, 0)
    end
    if self.display_text:IsShown() then
        self.display_text:Hide()
        self.display_text:Show()
    end
    self:UpdateDisplayed()
end

function AngryEra:UpdateBackdrop()
    local first, last
    for lineIndex, visibleLine in ipairs(self.display_text.visibleLines) do
        local messageInfo = self.display_text.historyBuffer:GetEntryAtIndex(lineIndex)
        if messageInfo then
            if not first then
                first = visibleLine
            end
            last = visibleLine
        end
    end

    if first and last and self:GetConfig("backdropShow") then
        self.backdrop:ClearAllPoints()
        if AngryAssign_State.directionUp then
            self.backdrop:SetPoint("TOPLEFT", last, "TOPLEFT", -4, 4)
            self.backdrop:SetPoint("BOTTOMRIGHT", first, "BOTTOMRIGHT", 4, -4)
        else
            self.backdrop:SetPoint("TOPLEFT", first, "TOPLEFT", -4, 4)
            self.backdrop:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", 4, -4)
        end
        self.backdrop:SetColorTexture(HexToRGB(self:GetConfig("backdropColor")))
        self.backdrop:Show()
    else
        self.backdrop:Hide()
    end
    UpdateDisplayAutoHideHoverBounds(self, first, last)
end

local editFontName, editFontHeight, editFontFlags
function AngryEra:UpdateMedia()
    local fontName = LSM:Fetch("font", AngryEra:GetConfig("fontName"))
    local fontHeight = AngryEra:GetConfig("fontHeight")
    local fontFlags = AngryEra:GetConfig("fontFlags")

    if fontFlags == "NONE" then
        fontFlags = ""
    end

    self.display_text:SetTextColor(HexToRGB(self:GetConfig("color")))
    self.display_text:SetFont(fontName, fontHeight, fontFlags)
    self.display_text:SetSpacing(AngryEra:GetConfig("lineSpacing"))

    if self.window then
        if self.window.tree then
            self.window.tree:SetButtonFont(fontName, fontHeight)
        end
        if self:GetConfig("editBoxFont") then
            if not editFontName then
                editFontName, editFontHeight, editFontFlags = self.window.text.editBox:GetFont()
            end
            self.window.text.editBox:SetFont(fontName, fontHeight, fontFlags)
        elseif editFontName then
            self.window.text.editBox:SetFont(editFontName, editFontHeight, editFontFlags)
        end
    end

    C_Timer.After(0.01, function()
        self:UpdateBackdrop()
    end)
end

-- -------------------------
-- Glow notification
-- -------------------------

local updateFlasher, updateFlasher2 = nil, nil
function AngryEra:DisplayUpdateNotification()
    if updateFlasher == nil then
        updateFlasher = self.display_glow:CreateAnimationGroup()

        -- Flashing in
        local fade1 = updateFlasher:CreateAnimation("Alpha")
        fade1:SetDuration(0.5)
        fade1:SetFromAlpha(0)
        fade1:SetToAlpha(1)
        fade1:SetOrder(1)

        -- Holding it visible for 1 second
        fade1:SetEndDelay(5)

        -- Flashing out
        local fade2 = updateFlasher:CreateAnimation("Alpha")
        fade2:SetDuration(0.5)
        fade2:SetFromAlpha(1)
        fade2:SetToAlpha(0)
        fade2:SetOrder(3)
    end
    if updateFlasher2 == nil then
        updateFlasher2 = self.display_glow2:CreateAnimationGroup()

        -- Flashing in
        local fade1 = updateFlasher2:CreateAnimation("Alpha")
        fade1:SetDuration(0.5)
        fade1:SetFromAlpha(0)
        fade1:SetToAlpha(1)
        fade1:SetOrder(1)

        -- Holding it visible for 1 second
        fade1:SetEndDelay(5)

        -- Flashing out
        local fade2 = updateFlasher2:CreateAnimation("Alpha")
        fade2:SetDuration(0.5)
        fade2:SetFromAlpha(1)
        fade2:SetToAlpha(0)
        fade2:SetOrder(3)
    end

    updateFlasher:Play()
    updateFlasher2:Play()
end

-- -------------------------
-- Rendering pipeline
-- -------------------------

--- Resets the cached group identifier so the next group-change check re-renders.
function AngryEra:ResetCurrentGroup()
    currentGroup = nil
end

--- Re-renders display when group membership context changes.
function AngryEra:UpdateDisplayedIfNewGroup()
    local newGroup = self:GetCurrentGroup()
    if newGroup ~= currentGroup then
        currentGroup = newGroup
        self:UpdateDisplayed()
    end
end

--- Builds Mustache context from current roster/classes/groups.
-- @treturn table ctx Template context table.
function AngryEra:GetTemplateContext()
    local ctx = {
        classes = {},
        groups = {},
        rosterColors = {},
        me = UnitName("player"),
    }

    -- Initialize structure
    for i = 1, 8 do
        ctx.groups[i] = {}
    end
    local standardClasses =
        { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
    for _, c in ipairs(standardClasses) do
        ctx.classes[c] = {}
    end

    -- Gather Roster
    if not (IsInRaid() or IsInGroup()) then
        -- Solo testing
        local name = UnitName("player")
        local _, class = UnitClass("player")
        if class then
            local unit = { name = name, class = class, colored_name = name } -- Basic fallback
            if RAID_CLASS_COLORS[class] then
                unit.colored_name = "|c" .. RAID_CLASS_COLORS[class].colorStr .. name .. "|r"
                ctx.rosterColors[name] = RAID_CLASS_COLORS[class].colorStr
            end
            if ctx.classes[class] then
                table.insert(ctx.classes[class], unit)
            end
            table.insert(ctx.groups[1], unit)
        end
        return ctx
    end

    IterateGroupMembers(function(rawName, fullName, _, subgroup, class, online, isDead)
        local name = rawName or EnsureUnitShortName(fullName)
        local colorStr = "ffffffff"
        if class and RAID_CLASS_COLORS[class] then
            colorStr = RAID_CLASS_COLORS[class].colorStr
            ctx.rosterColors[name] = colorStr
            local shortName = name:match("([^-]+)")
            if shortName and shortName ~= name then
                ctx.rosterColors[shortName] = colorStr
            end
        end

        local unit = {
            name = name,
            class = class,
            online = online,
            dead = isDead,
            colored_name = "|c" .. colorStr .. name .. "|r",
        }

        local groupIndex = subgroup or 1
        if ctx.groups[groupIndex] then
            table.insert(ctx.groups[groupIndex], unit)
        end

        if class and ctx.classes[class] then
            table.insert(ctx.classes[class], unit)
        end

        return false
    end)

    return ctx
end

-- Builds the roster accessors a `{layout}` expansion needs: present-and-alive
-- class members for `*CLASS` fills, priority resolution, and class coloring.
-- The roster is walked once and cached for this render. `vars` is the merged
-- variable map a `{{Variable}}` slot reads.
local function BuildLayoutProviders(vars)
    local classByName = {}
    local classMembers = {}
    local subgroupMembers = {}
    IterateGroupMembers(function(_, fullName, _, subgroup, memberClass, online, isDead)
        if type(fullName) ~= "string" or type(memberClass) ~= "string" then
            return false
        end
        local class = memberClass:upper()
        local fullLower = fullName:lower()
        local shortLower = fullLower:match("^([^-]+)")
        classByName[fullLower] = class
        if shortLower and classByName[shortLower] == nil then
            classByName[shortLower] = class
        end
        if online and not isDead then
            classMembers[class] = classMembers[class] or {}
            classMembers[class][#classMembers[class] + 1] = fullName
            if type(subgroup) == "number" then
                subgroupMembers[subgroup] = subgroupMembers[subgroup] or {}
                subgroupMembers[subgroup][#subgroupMembers[subgroup] + 1] = fullName
            end
        end
        return false
    end)

    local function Colorize(name)
        if type(name) ~= "string" then
            return name
        end
        local class = classByName[name:lower()] or classByName[name:lower():match("^([^-]+)") or ""]
        local palette = _G.RAID_CLASS_COLORS
        local color = class and palette and palette[class] or nil
        if color and color.colorStr then
            return "|c" .. color.colorStr .. name .. "|r"
        end
        if color and color.r then
            return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
        end
        return name
    end

    return {
        ResolvePriorityValue = rosterHelpers and rosterHelpers.ResolvePriorityValue,
        ClassMembers = function(class)
            return classMembers[class] or {}
        end,
        SubgroupMembers = function(subgroup)
            return subgroupMembers[subgroup] or {}
        end,
        Variables = type(vars) == "table" and vars or nil,
        Colorize = Colorize,
    }
end

--- Renders a page with merged category/page variables and Mustache.
-- @tparam table page Page table.
-- @tparam table ctx Template context table.
-- @tparam[opt] table options Set `UseActiveDisplayContext` for the exact v3 display snapshot.
-- @treturn string text Rendered text.
-- @treturn table mergedVars Merged variable map used for rendering.
-- @treturn string|nil variableError
-- @treturn table renderedPage Exact page record used for rendering.
-- @treturn table ancestorVariableLayers Exact root-to-parent variable layers used for rendering.
-- @treturn boolean rosterReactive Whether the render depends on live roster state.
function AngryEra:RenderPageContent(page, ctx, options)
    local renderedPage = page
    local layers
    local variableError
    if type(options) == "table" and options.UseActiveDisplayContext == true then
        if
            type(self.GetActiveDisplayReference) ~= "function"
            or type(self.GetActivePageRenderContext) ~= "function"
        then
            return "", {}, "active-display-runtime-unavailable", renderedPage, {}
        end

        local referenceCallOk, reference = pcall(self.GetActiveDisplayReference, self)
        if not referenceCallOk or type(reference) ~= "table" then
            return "", {}, "missing-active-display-reference", renderedPage, {}
        end
        if
            reference.SyncId ~= page.SyncId
            or type(reference.Revision) ~= "number"
            or not reference.RevisionId
            or not reference.ContextRevisionId
        then
            return "", {}, "active-display-reference-mismatch", renderedPage, {}
        end

        local contextCallOk, activeContext = pcall(
            self.GetActivePageRenderContext,
            self,
            reference.SyncId,
            reference.Revision,
            reference.RevisionId,
            reference.ContextRevisionId
        )
        if
            not contextCallOk
            or type(activeContext) ~= "table"
            or type(activeContext.Page) ~= "table"
            or type(activeContext.AncestorVariableLayers) ~= "table"
        then
            return "", {}, "missing-active-display-context", renderedPage, {}
        end

        renderedPage = activeContext.Page
        layers = activeContext.AncestorVariableLayers
    end

    local contents = type(renderedPage.Contents) == "string" and renderedPage.Contents or ""
    local text = contents:gsub("||", "|")

    if not layers and renderedPage == page and page.CategoryId then
        local chain, chainError = variableHelpers.CollectCategoryChain(AngryAssign_Categories, page.CategoryId)
        if chain then
            layers, variableError = variableHelpers.BuildAncestorVariableLayers(chain)
        else
            variableError = chainError
        end
    end

    layers = layers or {}

    local mergedVars, mergeError = variableHelpers.MergeVariableLayers(layers, renderedPage.Vars)
    if not mergedVars then
        variableError = variableError or mergeError
        layers = {}
        mergedVars = variableHelpers.MergeVariableLayers({}, renderedPage.Vars) or {}
    end

    local hadPriority = false
    if rosterHelpers and type(rosterHelpers.ApplyPriorityAssignments) == "function" then
        hadPriority = rosterHelpers.ApplyPriorityAssignments(mergedVars)
    end

    local hadLayout = false
    if layoutHelpers and type(layoutHelpers.SourceFromVars) == "function" then
        local layoutSource = layoutHelpers.SourceFromVars(mergedVars)
        if layoutSource then
            text, hadLayout = layoutHelpers.Expand(text, layoutSource, BuildLayoutProviders(mergedVars))
        end
    end

    if LibMustache then
        ctx = ctx or {}
        for k, v in pairs(mergedVars) do
            ctx[k] = v
        end

        local success, result = pcall(LibMustache.render, text, ctx)
        if success then
            text = result
        end
    end

    return text, mergedVars, variableError, renderedPage, layers, hadPriority or hadLayout
end

local ACTIVE_CONTEXT_UNAVAILABLE = {
    ["active-display-runtime-unavailable"] = true,
    ["missing-active-display-reference"] = true,
    ["active-display-reference-mismatch"] = true,
    ["missing-active-display-context"] = true,
}

local function CanRenderPageLocally(self, page)
    if type(page.OwnerId) ~= "string" then
        return true
    end

    if type(self.IsLocallyOwned) == "function" then
        local checked, locallyOwned = pcall(self.IsLocallyOwned, self, page)
        if checked and locallyOwned == true then
            return true
        end
    end

    if type(AngryAssign_Meta) ~= "table" then
        return false
    end
    return page.OwnerId == AngryAssign_Meta.InstallationId
end

--- Renders a page preferring the exact active display snapshot.
-- When the snapshot is unavailable and the page is locally authoritative,
-- rendering falls back to local hierarchy data instead of an empty result.
-- @tparam table page Page table.
-- @tparam table ctx Template context table.
-- @treturn string text Rendered text.
-- @treturn table mergedVars Merged variable map used for rendering.
-- @treturn string|nil variableError
-- @treturn table renderedPage Exact page record used for rendering.
-- @treturn table ancestorVariableLayers Exact root-to-parent variable layers used for rendering.
function AngryEra:RenderPageWithActiveFallback(page, ctx)
    local renderedText, mergedVars, variableError, renderedPage, ancestorVariableLayers, hadPriority =
        self:RenderPageContent(page, ctx, { UseActiveDisplayContext = true })
    if ACTIVE_CONTEXT_UNAVAILABLE[variableError] and CanRenderPageLocally(self, page) then
        return self:RenderPageContent(page, ctx)
    end
    return renderedText, mergedVars, variableError, renderedPage, ancestorVariableLayers, hadPriority
end

--- Applies lightweight markdown transformations used by the display layer.
-- @tparam string text Source text.
-- @treturn string formattedText
function AngryEra:ProcessMarkdown(text)
    -- Process Headers: # Header
    -- Start of string
    text = text:gsub("^(#+)%s+([^\n]+)", function(l, c)
        return "|cffffd200" .. c:upper() .. "|r"
    end)
    -- Start of line
    text = text:gsub("\n(#+)%s+([^\n]+)", function(l, c)
        return "\n|cffffd200" .. c:upper() .. "|r"
    end)

    -- Process Lists: - Item
    -- Start of string
    text = text:gsub("^%-%s+([^\n]+)", "  |cffffd200*|r %1")
    -- Start of line
    text = text:gsub("\n%-%s+([^\n]+)", "\n  |cffffd200*|r %1")

    -- Bold **text** -> White
    text = text:gsub("%*%*(.-)%*%*", "|cffffffff%1|r")

    -- Italic *text* -> Grey (Changed from _text_ to avoid conflicts with icon/texture names)
    -- Prevent matching across newlines to avoid breaking lists or other structures
    text = text:gsub("%*([^\n*]-)%*", "|cffaaaaaa%1|r")

    return text
end

--- Rebuilds and draws the active display page.
function AngryEra:UpdateDisplayed()
    local displayedId = AngryAssign_State.displayed
    local page = AngryAssign_Pages[displayedId]
    if not page then
        self._displayedHasPriority = false
        self.display_text:Clear()
        self:UpdateBackdrop()
        ClearDisplayAutoHideContent(self)
        if type(self.NotifyDisplayedNoteChanged) == "function" then
            pcall(self.NotifyDisplayedNoteChanged, self, nil)
        end
        return
    end

    -- Prepare Highlight Map
    local highlightSet = {}
    local currentGroupStr = "g" .. (self:GetCurrentGroup() or 0)

    for token in string.gmatch(AngryEra:GetConfig("highlight"), "[^%s%p]+") do
        local normalizedToken = token:lower()
        if normalizedToken == "group" then
            highlightSet[currentGroupStr] = true
        else
            highlightSet[normalizedToken] = true
        end
    end

    -- Add Guild Colors
    if self.GuildColors then
        for name, color in pairs(self.GuildColors) do
            highlightSet[name:lower()] = color
        end
    end

    -- Add Roster Colors
    local ctx = self:GetTemplateContext()
    if ctx and ctx.rosterColors then
        for name, color in pairs(ctx.rosterColors) do
            highlightSet[name:lower()] = color
        end
    end

    local highlightHex = self:GetConfig("highlightColor")

    -- Mustache Templating & Merging
    local renderedText, mergedVars, variableError, renderedPage, ancestorVariableLayers, hadPriority =
        self:RenderPageWithActiveFallback(page, ctx)
    self._displayedHasPriority = hadPriority == true
    local text = renderedText or page.Contents or ""

    local hasHighlight = next(highlightSet) ~= nil

    -- Add Variables to Highlight Set (Generic)
    -- Metadata ($) values are machine-facing and never auto-highlighted.
    for k, v in pairs(mergedVars) do
        if not variableHelpers.IsMetaVariableKey(k) and type(v) == "string" and #v > 2 then
            for word in v:gmatch("[^%s%p]+") do
                if #word > 2 then
                    local lowerWord = word:lower()
                    if highlightSet[lowerWord] == nil then
                        highlightSet[lowerWord] = true
                        hasHighlight = true
                    end
                end
            end
        end
    end

    -- Markdown Support
    text = self:ProcessMarkdown(text)

    -- Process Colors (Peel-Back Optimization)
    text = text:gsub("(|c%w+)", function(c)
        local lowerC = c:lower()

        -- Check for exact match first (Fastest)
        if ColorTable[lowerC] then
            return ColorTable[lowerC]
        end

        -- Check for partial matches (e.g. |cmageGrp -> |cmage + Grp)
        -- We loop backwards from the end of the string to find the longest valid color key
        for i = #c - 1, 3, -1 do
            local sub = lowerC:sub(1, i)
            if ColorTable[sub] then
                -- Found a valid color (e.g. |cmage)
                local validColor = ColorTable[sub]
                -- Append the rest of the text (e.g. Grp)
                local remainder = c:sub(i + 1)
                return validColor .. remainder
            end
        end

        -- No match found (likely a standard hex code like |cff000000), return as-is
        return c
    end)

    -- Process Tags (Single Pass)
    -- (%b{}) captures anything balanced between { and }
    text = text:gsub("(%b{})", function(tag)
        return ProcessTag(tag, renderedPage)
    end)

    -- Process Highlights (Word Scan)
    -- Optimization: Only scan if we actually have things to highlight
    if hasHighlight then
        text = text:gsub("([^%s%p]+)", function(word)
            local val = highlightSet[word:lower()]
            if val then
                if type(val) == "string" then
                    return string.format("|c%s%s|r", val, word)
                else
                    return string.format("|cff%s%s|r", highlightHex, word)
                end
            end
            return word -- Return original if no match
        end)
    end

    -- Render
    self.display_text:Clear()
    local lines = { strsplit("\n", text) }
    local lines_count = #lines

    for i = 1, lines_count do
        local line
        if AngryAssign_State.directionUp then
            line = lines[i]
        else
            line = lines[lines_count - i + 1]
        end
        if line == "" then
            line = " "
        end
        self.display_text:AddMessage(line)
    end

    C_Timer.After(0.01, function()
        self:UpdateBackdrop()
    end)

    local displayChanged, displayIdentity = CaptureDisplayAutoHideContent(self, renderedPage, displayedId, text)
    if type(self.NotifyDisplayedNoteChanged) == "function" then
        if ACTIVE_CONTEXT_UNAVAILABLE[variableError] then
            pcall(self.NotifyDisplayedNoteChanged, self, nil)
        else
            pcall(self.NotifyDisplayedNoteChanged, self, {
                Page = renderedPage,
                RenderedText = text,
                MergedVariables = mergedVars,
                AncestorVariableLayers = ancestorVariableLayers,
                VariableError = variableError,
            })
        end
    end
    local autoHideState = DisplayAutoHideState(self)
    if
        displayChanged
        and AngryAssign_State.displayed == displayedId
        and AngryAssign_Pages[displayedId] == page
        and autoHideState.PageIdentity == displayIdentity
        and autoHideState.RenderedText == text
    then
        self:RevealDisplayForAutoHide()
    end
end
