local app = {
    AngryEra = {
        utils = {
            helpers = {
                EnsureUnitShortName = function(value)
                    return value
                end,
                IterateGroupMembers = function() end,
            },
            colors = {
                ColorTable = {},
                HexToRGB = function()
                    return 1, 1, 1, 1
                end,
            },
            tags = {
                ProcessTag = function(value)
                    return value
                end,
            },
            variables = {},
            roster = {},
            layout = {},
        },
    },
    libs = {
        lwin = {},
        LSM = {},
        LibMustache = {},
    },
}

_G.WOW_PROJECT_ID = 1
_G.WOW_PROJECT_CLASSIC = 1
_G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 2
_G.WOW_PROJECT_WRATH_CLASSIC = 3
AngryAssign_Config = {}

assert(loadfile("modules/core/constants.lua"))("AngryEra", app)
assert(loadfile("modules/utils/colors.lua"))("AngryEra", app)
assert(loadfile("modules/ui/settings.lua"))("AngryEra", app)
assert(loadfile("modules/ui/display.lua"))("AngryEra", app)

local AngryEra = app.AngryEra
assert(AngryEra.core.configDefaults.autoHide == false, "auto-hide must remain opt-in by default")
assert(AngryEra:GetConfig("autoHide") == false, "a fresh configuration should use the disabled default")

AngryAssign_State = {
    tree = "corrupt",
    window = false,
    display = {
        hidden = "yes",
        width = math.huge,
    },
    displayed = "page",
    locked = 1,
    directionUp = {},
}
local normalizedState = AngryEra:NormalizeSavedState()
assert(
    type(normalizedState.tree) == "table"
        and type(normalizedState.window) == "table"
        and type(normalizedState.display) == "table",
    "state normalization should restore every nested UI status table"
)
assert(
    normalizedState.display.hidden == false
        and normalizedState.display.width == nil
        and normalizedState.displayed == nil
        and normalizedState.locked == false
        and normalizedState.directionUp == false,
    "state normalization should discard hostile persisted scalar values"
)
AngryAssign_State = {
    tree = {
        groups = {
            good = true,
            bad = "yes",
            [{}] = true,
        },
        scrollvalue = "bottom",
        selected = {},
        treesizable = "yes",
        treewidth = math.huge,
    },
    window = {
        height = {},
        left = 0 / 0,
        top = "top",
        width = "wide",
    },
    display = {
        hidden = false,
        point = "MIDDLEISH",
        scale = -1,
        width = "wide",
        x = math.huge,
        y = {},
    },
}
normalizedState = AngryEra:NormalizeSavedState()
assert(
    normalizedState.tree.groups.good == true
        and normalizedState.tree.groups.bad == nil
        and next(normalizedState.window) == nil
        and normalizedState.display.hidden == false
        and normalizedState.display.point == nil
        and normalizedState.display.x == nil,
    "nested AceGUI and LibWindow state should be rebuilt from safe typed fields only"
)

AngryAssign_Config = {
    autoHide = "yes",
    backdropColor = "zzzzzzzz",
    color = true,
    fontHeight = 1000,
    fontFlags = "GLOW",
    lineSpacing = -2,
    receiveMode = "everyone",
    scale = 0 / 0,
    trustedPublishers = {},
}
assert(AngryEra:SanitizeSavedConfig() == 9, "every invalid known config value should be reset")
assert(
    AngryEra:GetConfig("autoHide") == false
        and AngryEra:GetConfig("backdropColor") == "00000080"
        and AngryEra:GetConfig("color") == "ffffff"
        and AngryEra:GetConfig("fontHeight") == 12
        and AngryEra:GetConfig("receiveMode") == "standard",
    "sanitized settings should fall back to safe defaults"
)
AngryEra:SetConfig("autoHide", false)
assert(AngryAssign_Config.autoHide == nil, "default-equivalent false booleans should remain compact")
AngryEra:SetConfig("autoHide", true)
assert(AngryAssign_Config.autoHide == true, "valid non-default booleans should persist")
AngryEra:SetConfig("fontHeight", "large")
assert(AngryAssign_Config.fontHeight == nil, "SetConfig should reject invalid values too")
AngryAssign_Config.glowColor = "ff0000"
assert(
    AngryEra:SanitizeSavedConfig() == 0 and AngryAssign_Config.glowColor == nil,
    "case-only color defaults should be canonicalized without a redundant persisted override"
)
AngryAssign_Config.hideoncombat = true
AngryAssign_State.display.hidden = true
AngryAssign_Meta = { Migrations = {} }
assert(
    AngryEra:MigrateCombatFadeVisibility()
        and AngryAssign_State.display.hidden == false
        and AngryAssign_Meta.Migrations.CombatFadeVisibility == 1,
    "the combat-fade upgrade should repair the old automatic persisted hide once"
)
AngryAssign_State.display.hidden = true
assert(
    not AngryEra:MigrateCombatFadeVisibility() and AngryAssign_State.display.hidden == true,
    "the durable migration marker should preserve later manual hides"
)
local invalidRed, invalidGreen, invalidBlue, invalidAlpha = AngryEra.utils.colors.HexToRGB(true)
assert(
    invalidRed == 1 and invalidGreen == 1 and invalidBlue == 1 and invalidAlpha == nil,
    "direct color conversion should fail safe even outside config access"
)
AngryAssign_Config = {}

local function NewFrame(shown, alpha)
    local frame = {
        alpha = alpha or 1,
        shown = shown == true,
        scripts = {},
        showCalls = 0,
        hideCalls = 0,
    }

    function frame:SetAlpha(value)
        self.alpha = value
    end

    function frame:GetAlpha()
        return self.alpha
    end

    function frame:IsShown()
        return self.shown
    end

    function frame:Show()
        self.shown = true
        self.showCalls = self.showCalls + 1
    end

    function frame:Hide()
        self.shown = false
        self.hideCalls = self.hideCalls + 1
    end

    function frame:SetScript(name, callback)
        self.scripts[name] = callback
    end

    function frame:RunUpdate(elapsed)
        local callback = self.scripts.OnUpdate
        if callback then
            callback(self, elapsed)
        end
    end

    return frame
end

local function NewHoverFrame()
    local frame = NewFrame(true, 1)
    frame.hovered = false
    frame.points = {}
    frame.left = 100
    frame.right = 200
    frame.bottom = 50
    frame.top = 150
    frame.effectiveScale = 1

    function frame:IsMouseOver()
        return self.hovered
    end

    function frame:ClearAllPoints()
        self.points = {}
    end

    function frame:SetPoint(...)
        self.points[#self.points + 1] = { ... }
    end

    function frame:GetLeft()
        return self.left
    end

    function frame:GetRight()
        return self.right
    end

    function frame:GetBottom()
        return self.bottom
    end

    function frame:GetTop()
        return self.top
    end

    function frame:GetEffectiveScale()
        return self.effectiveScale
    end

    return frame
end

local display = NewFrame(true, 0.25)
local mover = NewFrame(false, 0.25)
local driver = NewFrame(true, 1)
local hover = NewHoverFrame()

AngryEra.display_text = display
AngryEra.mover = mover
AngryEra.display_auto_hide_driver = driver
AngryEra.display_auto_hide_hover = hover
driver.owner = AngryEra

AngryAssign_State = {
    directionUp = false,
    display = {
        hidden = false,
    },
    locked = true,
}

assert(not AngryEra:RefreshDisplayAutoHide(false), "auto-hide should default to disabled")
assert(display:GetAlpha() == 1 and mover:GetAlpha() == 1, "disabled auto-hide should restore full opacity")
assert(driver.scripts.OnUpdate == nil, "disabled auto-hide should not retain an update driver")
assert(not hover:IsShown(), "disabled auto-hide should hide its hover sensor")

AngryAssign_Config.autoHide = true
hover:Show()
assert(AngryEra:RefreshDisplayAutoHide(false), "enabling auto-hide should start its update driver")
assert(type(driver.scripts.OnUpdate) == "function", "enabled auto-hide should poll hover and fade state")
driver:RunUpdate(0.1)
assert(
    math.abs(display:GetAlpha() - 0.5) < 0.000001,
    "an idle display should begin fading out (alpha " .. tostring(display:GetAlpha()) .. ")"
)
driver:RunUpdate(0.1)
assert(display:GetAlpha() == 0, "an idle display should finish fading out")
assert(AngryAssign_State.display.hidden == false, "a cosmetic fade must not persist a manual hide")

hover.hovered = true
driver:RunUpdate(0.1)
assert(display:GetAlpha() == 0.5, "hovering the rendered note should begin fading it in")
driver:RunUpdate(0.1)
assert(display:GetAlpha() == 1, "hovering the rendered note should finish fading it in")

hover.hovered = false
driver:RunUpdate(0.2)
assert(display:GetAlpha() == 0, "leaving the rendered note should fade it out")

assert(AngryEra:RevealDisplayForAutoHide(), "a changed display should start a temporary reveal")
driver:RunUpdate(0.2)
assert(display:GetAlpha() == 1, "a changed display should fade fully in")
driver:RunUpdate(2.79)
assert(display:GetAlpha() == 1, "the changed display should remain visible for about three seconds")
driver:RunUpdate(0.02)
assert(display:GetAlpha() < 1, "the display should begin fading after its reveal expires")

AngryEra:RevealDisplayForAutoHide()
driver:RunUpdate(2.5)
AngryEra:RevealDisplayForAutoHide()
driver:RunUpdate(2.5)
assert(display:GetAlpha() == 1, "a newer display change should replace the previous reveal window")

hover.hovered = true
driver:RunUpdate(1)
assert(display:GetAlpha() == 1, "hover should keep the display visible after the reveal expires")
hover.hovered = false
driver:RunUpdate(0.2)
assert(display:GetAlpha() == 0, "leaving after an expired reveal should fade the display")

local updateBackdrop = AngryEra.UpdateBackdrop
AngryEra.UpdateBackdrop = function() end

AngryAssign_State.locked = true
mover:Hide()
display:SetAlpha(0)
AngryEra:ToggleLock()
assert(not AngryAssign_State.locked and mover:IsShown(), "unlocking should show the display mover")
driver:RunUpdate(2.9)
assert(display:GetAlpha() == 1 and mover:GetAlpha() == 1, "the unlocked mover should remain visible during its preview")
driver:RunUpdate(0.2)
assert(
    display:GetAlpha() < 1 and mover:GetAlpha() < 1,
    "the unlocked mover should auto-hide with the display after its preview"
)
AngryEra:ToggleLock()
assert(AngryAssign_State.locked and not mover:IsShown(), "locking should hide the display mover")

AngryEra:RevealDisplayForAutoHide()
AngryEra:HideDisplay()
assert(AngryAssign_State.display.hidden and not display:IsShown(), "HideDisplay should retain manual visibility state")
assert(AngryEra._displayAutoHideState.HoldRemaining == 0, "manual hiding should cancel a pending reveal")
local displayShowCalls = display.showCalls
driver:RunUpdate(0.2)
assert(display:GetAlpha() == 1, "a manually hidden display should be primed for its next explicit show")
assert(not display:IsShown() and display.showCalls == displayShowCalls, "auto-hide must not override manual visibility")

display:SetAlpha(0)
AngryEra:ShowDisplay()
driver:RunUpdate(0.2)
assert(display:IsShown() and not AngryAssign_State.display.hidden, "ShowDisplay should restore manual visibility")
assert(display:GetAlpha() == 1, "ShowDisplay should reveal an already auto-hidden assignment")

AngryAssign_Config.autoHide = true
hover.hovered = false
AngryEra._displayAutoHideState.HoldRemaining = 0
driver:RunUpdate(0.1)
assert(display:GetAlpha() == 0.5, "the combat regression should begin from a partially faded assignment")
assert(AngryEra:SetDisplayCombatFade(true), "combat fade should activate without hiding the assignment")
assert(
    display:IsShown()
        and AngryAssign_State.display.hidden == false
        and display:GetAlpha() == 0.1
        and mover:GetAlpha() == 0.1,
    "combat fade should cap opacity without persisting or changing visibility"
)
assert(driver.scripts.OnUpdate == nil, "combat fade should pause the auto-hide opacity driver")
assert(not AngryEra:SetDisplayCombatFade(false), "leaving combat should clear the temporary fade")
assert(display:GetAlpha() == 0.5, "leaving combat should restore the exact pre-combat opacity")
assert(type(driver.scripts.OnUpdate) == "function", "leaving combat should resume auto-hide")
assert(AngryEra:SetDisplayCombatFade(true), "combat fade should be safely repeatable")
assert(AngryEra:RevealDisplayForAutoHide(), "page changes should retain a reveal while combat fade is active")
assert(display:GetAlpha() == 0.1, "page changes must not punch through the combat opacity cap")
AngryEra:SetDisplayCombatFade(false)
assert(
    display:GetAlpha() == 1,
    "a page reveal queued during combat should be fully visible afterward (alpha "
        .. tostring(display:GetAlpha())
        .. ")"
)

AngryEra:SetDisplayCombatFade(true)
AngryEra:HideDisplay()
assert(not display:IsShown() and AngryAssign_State.display.hidden, "manual hide should still work during combat")
AngryEra:SetDisplayCombatFade(false)
assert(not display:IsShown() and AngryAssign_State.display.hidden, "combat exit must preserve a manual hide")
AngryEra:SetDisplayCombatFade(true)
AngryEra:ShowDisplay()
assert(display:IsShown() and display:GetAlpha() == 0.1, "manual show in combat should retain the opacity cap")
AngryEra:SetDisplayCombatFade(false)
assert(display:IsShown() and not AngryAssign_State.display.hidden, "combat exit must preserve a manual show")

app.libs.lwin.RegisterConfig = function() end
app.libs.lwin.RestorePosition = function() end
AngryEra.frame = {
    SetWidth = function() end,
}
local updateDirection = AngryEra.UpdateDirection
AngryEra.UpdateDirection = function() end
AngryAssign_State.locked = true
mover:Hide()
display:SetAlpha(0)
AngryEra._displayAutoHideState.HoldRemaining = 0
AngryEra:ResetPosition()
driver:RunUpdate(0.2)
assert(not AngryAssign_State.locked and mover:IsShown(), "ResetPosition should unlock and show the mover")
assert(display:GetAlpha() == 1, "ResetPosition should reveal a faded mover and assignment")
AngryEra.UpdateDirection = updateDirection

AngryEra.UpdateBackdrop = updateBackdrop

local updateMedia = AngryEra.UpdateMedia
local updateDisplayed = AngryEra.UpdateDisplayed
AngryEra.UpdateMedia = function() end
AngryEra.UpdateDisplayed = function() end
_G.LibStub = function()
    return {
        NotifyChange = function() end,
    }
end
display:SetAlpha(0)
AngryAssign_Config.hideoncombat = true
AngryEra:SetDisplayCombatFade(true)
assert(display:GetAlpha() == 0.1, "the restore-defaults regression should begin combat-faded")
AngryEra:RestoreDefaults()
assert(AngryEra:GetConfig("autoHide") == false, "RestoreDefaults should disable auto-hide")
assert(
    AngryEra:GetConfig("hideoncombat") == false and display:GetAlpha() == 1 and mover:GetAlpha() == 1,
    "restoring defaults in combat should clear combat fade and restore full opacity"
)
assert(driver.scripts.OnUpdate == nil, "disabling auto-hide should stop its update driver")
AngryEra.UpdateMedia = updateMedia
AngryEra.UpdateDisplayed = updateDisplayed

local firstLine = {}
local lastLine = {}
display.visibleLines = { firstLine, lastLine }
display.historyBuffer = {
    GetEntryAtIndex = function(_, index)
        return index <= 2 and {} or nil
    end,
}
AngryEra.backdrop = {
    hidden = false,
    Hide = function(self)
        self.hidden = true
    end,
}

AngryAssign_Config.autoHide = true
AngryAssign_State.directionUp = false
AngryEra:UpdateBackdrop()
AngryEra:RefreshDisplayAutoHide(false)
assert(hover:IsShown(), "the hover sensor should follow a rendered note")
assert(
    hover.points[1][1] == "TOPLEFT"
        and hover.points[1][2] == firstLine
        and hover.points[2][1] == "BOTTOMRIGHT"
        and hover.points[2][2] == lastLine,
    "downward notes should use their first and last rendered lines as hover bounds"
)

AngryAssign_State.directionUp = true
AngryEra:UpdateBackdrop()
assert(
    hover.points[1][2] == lastLine and hover.points[2][2] == firstLine,
    "upward notes should reverse the rendered-line hover bounds"
)

local cursorX, cursorY
_G.GetCursorPosition = function()
    return cursorX, cursorY
end
hover.effectiveScale = 2
hover.hovered = false
AngryEra._displayAutoHideState.HoldRemaining = 0
display:SetAlpha(0)
cursorX, cursorY = 300, 200
driver:RunUpdate(0.2)
assert(display:GetAlpha() == 1, "a scaled cursor inside the rendered note should fade it in")

display:SetAlpha(0)
cursorX, cursorY = 400, 300
driver:RunUpdate(0.2)
assert(display:GetAlpha() == 1, "the rendered note's scaled boundary should count as hovered")

cursorX, cursorY = 402, 200
driver:RunUpdate(0.2)
assert(display:GetAlpha() == 0, "a scaled cursor outside the rendered note should fade it out")
_G.GetCursorPosition = nil

display.visibleLines = {}
AngryEra:UpdateBackdrop()
assert(not hover:IsShown(), "an empty display should not retain a hover sensor")

display.visibleLines = { firstLine, lastLine }
display:Hide()
AngryEra:UpdateBackdrop()
assert(not hover:IsShown(), "a manually hidden display should not retain a hover sensor")
display:Show()

AngryAssign_Config.autoHide = false
AngryEra:UpdateBackdrop()
assert(not hover:IsShown(), "disabling auto-hide should remove the transparent hover sensor")

local retainedFrame = AngryEra.frame
retainedFrame.shown = true
function retainedFrame:Show()
    self.shown = true
end
function retainedFrame:Hide()
    self.shown = false
end
local retainedDisplay = AngryEra.display_text
local retainedMover = AngryEra.mover
local retainedDriver = AngryEra.display_auto_hide_driver
local retainedHover = AngryEra.display_auto_hide_hover
local animationGroupCount = 0
local stoppedAnimationGroups = 0
local function NewGlow()
    return {
        CreateAnimationGroup = function()
            animationGroupCount = animationGroupCount + 1
            local group = {}
            function group:CreateAnimation()
                return setmetatable({}, {
                    __index = function()
                        return function() end
                    end,
                })
            end
            function group:Play() end
            function group:Stop()
                stoppedAnimationGroups = stoppedAnimationGroups + 1
            end
            return group
        end,
    }
end
AngryEra.display_glow = NewGlow()
AngryEra.display_glow2 = NewGlow()
AngryEra:DisplayUpdateNotification()
assert(animationGroupCount == 2, "the first display notification should create one animation group per glow")
AngryAssign_Config.autoHide = true
local retainedUpdateDirection = AngryEra.UpdateDirection
AngryEra.UpdateDirection = function() end
retainedDriver:SetScript("OnUpdate", function() end)
AngryEra:DestroyDisplay()
assert(
    AngryEra.frame == retainedFrame
        and AngryEra.display_text == retainedDisplay
        and AngryEra.mover == retainedMover
        and AngryEra.display_auto_hide_driver == retainedDriver
        and not retainedFrame.shown
        and retainedDriver.scripts.OnUpdate == nil,
    "disable teardown should stop scripts and retain the non-destroyable WoW frames"
)
assert(stoppedAnimationGroups == 2, "disable teardown should stop both retained notification animations")
AngryEra:CreateDisplay()
AngryEra:DisplayUpdateNotification()
assert(
    AngryEra.frame == retainedFrame
        and AngryEra.display_text == retainedDisplay
        and AngryEra.display_auto_hide_hover == retainedHover
        and retainedFrame.shown
        and retainedHover:IsShown()
        and animationGroupCount == 2,
    "re-enable should reuse its frames/animations and restore the auto-hide hover bounds"
)
AngryEra:DestroyDisplay()
AngryEra:CreateDisplay()
AngryEra:DisplayUpdateNotification()
assert(
    AngryEra.frame == retainedFrame and retainedFrame.shown and animationGroupCount == 2,
    "a second disable/enable cycle should remain idempotent and animation-leak-free"
)
AngryEra.UpdateDirection = retainedUpdateDirection

print("Display auto-hide tests passed.")
