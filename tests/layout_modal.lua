-- Verifies that layout prompts behave as modal children of their editor:
-- foreground popup, input-catching owner veil, and complete cleanup.

local AngryEra = {
    utils = {
        helpers = {
            EnsureUnitShortName = function(name)
                return name
            end,
            IterateGroupMembers = function() end,
            IsCategoryDescendant = function()
                return false
            end,
            selectedLastValue = function(value)
                return value
            end,
        },
        colors = {},
    },
}
local app = {
    AngryEra = AngryEra,
    libs = {
        AceGUI = {},
        DDM = {},
    },
}

AngryAssign_Pages = {}
AngryAssign_Categories = {}
StaticPopupDialogs = {}
_G.OKAY = "Okay"
_G.CANCEL = "Cancel"
_G.YES = "Yes"
_G.NO = "No"
_G.UISpecialFrames = { "AngryEra_Window" }
local deferredCallbacks = {}
_G.C_Timer = {
    After = function(_, callback)
        deferredCallbacks[#deferredCallbacks + 1] = callback
    end,
}

local function RunDeferredCallbacks()
    local callbacks = deferredCallbacks
    deferredCallbacks = {}
    for _, callback in ipairs(callbacks) do
        callback()
    end
end

local function NewFrame(parent)
    local frame = {
        parent = parent,
        frameLevel = 1,
        frameStrata = "DIALOG",
        shown = false,
        scripts = {},
    }

    function frame:SetParent(value)
        self.parent = value
    end

    function frame:GetParent()
        return self.parent
    end

    function frame:ClearAllPoints()
        self.allPoints = nil
    end

    function frame:SetAllPoints(value)
        self.allPoints = value
    end

    function frame:EnableMouse(value)
        self.mouseEnabled = value
    end

    function frame:EnableMouseWheel(value)
        self.mouseWheelEnabled = value
    end

    function frame:SetScript(script, callback)
        self.scripts[script] = callback
    end

    function frame:GetScript(script)
        return self.scripts[script]
    end

    function frame:SetFrameStrata(value)
        self.frameStrata = value
    end

    function frame:GetFrameStrata()
        return self.frameStrata
    end

    function frame:SetFrameLevel(value)
        self.frameLevel = value
    end

    function frame:GetFrameLevel()
        return self.frameLevel
    end

    function frame:SetToplevel(value)
        self.toplevel = value
    end

    function frame:Raise()
        self.raised = true
    end

    function frame:Show()
        self.shown = true
    end

    function frame:Hide()
        local wasShown = self.shown
        self.shown = false
        if wasShown and self.scripts.OnHide then
            self.scripts.OnHide(self)
        end
        if wasShown and self.dialogInfo and self.dialogInfo.OnHide then
            self.dialogInfo.OnHide(self)
        end
    end

    function frame:IsShown()
        return self.shown
    end

    function frame:CreateTexture()
        local texture = {}
        function texture.SetAllPoints(textureSelf, value)
            textureSelf.allPoints = value
        end
        function texture.SetColorTexture(textureSelf, red, green, blue, alpha)
            textureSelf.color = { red, green, blue, alpha }
        end
        return texture
    end

    return frame
end

_G.UIParent = NewFrame(nil)
_G.AngryEra_Window = NewFrame(UIParent)
AngryEra_Window:Show()
local popup = NewFrame(UIParent)
popup.frameLevel = 7
popup.editBox = {
    SetText = function(self, value)
        self.text = value
    end,
    GetText = function(self)
        return self.text
    end,
    HighlightText = function(self)
        self.highlighted = true
    end,
}

function _G.CreateFrame(_, _, parent)
    return NewFrame(parent or UIParent)
end

local popupAvailable = true
function _G.StaticPopup_Show(name, _, _, data)
    if not popupAvailable then
        return nil
    end
    popup.data = data
    popup.dialogInfo = StaticPopupDialogs[name]
    popup:Show()
    if popup.dialogInfo.OnShow then
        popup.dialogInfo.OnShow(popup)
    end
    return popup
end

assert(loadfile("modules/ui/editor.lua"))("AngryEra", app)

local layoutEditor = AngryEra.utils.layout_editor
assert(type(layoutEditor.ShowTextPopup) == "function", "layout text popup is testable")
assert(type(layoutEditor.ShowConfirmPopup) == "function", "layout confirmation popup is testable")
assert(type(layoutEditor.CloseModal) == "function", "an editor can explicitly close its active modal")
assert(type(layoutEditor.AttachEditorCloseGuard) == "function", "auxiliary editors share a close guard")

local ownerOne = NewFrame(UIParent)
ownerOne.frameLevel = 12
local acceptedText
local shown = layoutEditor.ShowTextPopup({
    Prompt = "Group name:",
    Text = "Tanks",
    Owner = ownerOne,
    OnAccept = function(text)
        acceptedText = text
    end,
})
assert(shown == popup, "the text helper returns the shown popup")
assert(popup.editBox.text == "Tanks" and popup.editBox.highlighted, "the text prompt seeds and selects its edit box")

local blocker = popup.angryEraLayoutModalBlocker
assert(blocker and blocker:IsShown(), "the modal blocker is shown")
assert(blocker:GetParent() == ownerOne, "the blocker belongs to the editor that opened the prompt")
assert(blocker.allPoints == ownerOne, "the blocker covers the entire owner")
assert(blocker.mouseEnabled and blocker.mouseWheelEnabled, "the blocker captures mouse and wheel input")
assert(type(blocker:GetScript("OnMouseDown")) == "function", "the blocker consumes mouse presses")
assert(type(blocker:GetScript("OnMouseUp")) == "function", "the blocker consumes mouse releases")
assert(type(blocker:GetScript("OnMouseWheel")) == "function", "the blocker consumes wheel input")
assert(blocker:GetFrameStrata() == "FULLSCREEN_DIALOG", "the blocker shares the owner's dialog strata")
assert(blocker:GetFrameLevel() > ownerOne:GetFrameLevel(), "the blocker draws above the editor")
assert(popup:GetFrameStrata() == "FULLSCREEN_DIALOG", "the prompt uses foreground dialog strata")
assert(popup:GetFrameLevel() > blocker:GetFrameLevel(), "the prompt draws above its blocker")
assert(popup.toplevel == nil and popup.raised, "the prompt is raised without altering its pooled top-level state")

StaticPopupDialogs.AngryEra_LayoutText.OnAccept(popup)
assert(acceptedText == "Tanks", "the modal text prompt preserves its acceptance callback")
popup:Hide()
assert(not blocker:IsShown(), "hiding the text prompt removes its blocker")
assert(blocker.allPoints == nil, "cleanup removes the old editor anchors")
assert(blocker:GetParent() == UIParent, "cleanup detaches the blocker from a recyclable editor")
assert(popup:GetFrameStrata() == "DIALOG" and popup:GetFrameLevel() == 7, "cleanup restores popup layering")

-- StaticPopup reuses its frames. A later invocation must attach the same
-- blocker to the new editor rather than retaining the previous owner.
local ownerTwo = NewFrame(UIParent)
ownerTwo.frameLevel = 20
layoutEditor.ShowTextPopup({
    Prompt = "Add a slot:",
    Owner = ownerTwo,
    OnAccept = function() end,
})
assert(popup.angryEraLayoutModalBlocker == blocker, "the reusable popup also reuses its blocker")
assert(blocker:GetParent() == ownerTwo and blocker.allPoints == ownerTwo, "a reused popup follows its current owner")
popup:Hide()

local confirmed = false
layoutEditor.ShowConfirmPopup({
    Prompt = "Remove the group Tanks?",
    Owner = ownerOne,
    OnAccept = function()
        confirmed = true
    end,
})
assert(blocker:GetParent() == ownerOne and blocker:IsShown(), "confirmation prompts are modal too")
StaticPopupDialogs.AngryEra_LayoutConfirm.OnAccept(popup)
assert(confirmed, "the modal confirmation preserves its acceptance callback")
layoutEditor.CloseModal(ownerOne)
assert(not popup:IsShown(), "closing an editor also dismisses its active prompt")
assert(not blocker:IsShown() and blocker.allPoints == nil, "confirmation cleanup releases the editor")

local function HasSpecialFrame(name)
    for _, registered in ipairs(UISpecialFrames) do
        if registered == name then
            return true
        end
    end
    return false
end

local function PressSpecialFrameEscape()
    local snapshot = {}
    for index, name in ipairs(UISpecialFrames) do
        snapshot[index] = name
    end
    for _, name in ipairs(snapshot) do
        local frame = _G[name]
        if frame and frame.IsShown and frame:IsShown() then
            frame:Hide()
        end
    end
end

local function AttachTestGuard(owner, isDirty, onFinish)
    return layoutEditor.AttachEditorCloseGuard({
        Owner = owner,
        IsDirty = isDirty,
        Prompt = "Discard unsaved test changes and close?",
        OnFinish = function()
            onFinish()
            owner:Hide()
        end,
    })
end

-- A clean editor owns Escape by itself. Closing it must not hide the main
-- window, and the main registration returns only after the current Escape pass.
local cleanOwner = NewFrame(UIParent)
cleanOwner:Show()
local cleanFinished = 0
local cleanPriorHide = 0
local cleanGuard
local cleanOriginalOnHide = function()
    cleanPriorHide = cleanPriorHide + 1
    cleanGuard:Request()
end
cleanOwner:SetScript("OnHide", cleanOriginalOnHide)
cleanGuard = AttachTestGuard(cleanOwner, function()
    return false
end, function()
    cleanFinished = cleanFinished + 1
end)
local cleanEscapeName = UISpecialFrames[1]
assert(
    cleanEscapeName and cleanEscapeName:match("^AngryEra_AuxiliaryEditor_Window_"),
    "an auxiliary editor becomes the only registered Escape frame"
)
assert(not HasSpecialFrame("AngryEra_Window"), "the main window is suspended while an editor owns Escape")
PressSpecialFrameEscape()
assert(cleanFinished == 1 and not cleanOwner:IsShown(), "a clean Escape closes only the editor")
assert(cleanPriorHide == 1, "a clean raw Hide runs the prior AceGUI lifecycle exactly once")
assert(cleanOwner:GetScript("OnHide") == cleanOriginalOnHide, "a clean close restores the pooled frame's prior script")
assert(AngryEra_Window:IsShown(), "closing the editor does not hide the main AngryEra window")
assert(not HasSpecialFrame("AngryEra_Window"), "the main Escape registration is not restored in the same pass")
RunDeferredCallbacks()
assert(
    HasSpecialFrame("AngryEra_Window") and not HasSpecialFrame(cleanEscapeName),
    "the next frame restores only the main Escape registration"
)
assert(_G[cleanEscapeName] == nil, "closing an editor releases its temporary global frame")

-- A dirty raw Hide is reversed before the discard prompt. Cancel keeps both
-- the window and draft alive; accepting closes exactly once.
local dirtyOwner = NewFrame(UIParent)
dirtyOwner:Show()
local dirty = true
local dirtyFinished = 0
local dirtyPriorHide = 0
local dirtyGuard
local dirtyOriginalOnHide = function()
    dirtyPriorHide = dirtyPriorHide + 1
    dirtyGuard:Request()
end
dirtyOwner:SetScript("OnHide", dirtyOriginalOnHide)
dirtyGuard = AttachTestGuard(dirtyOwner, function()
    return dirty
end, function()
    dirtyFinished = dirtyFinished + 1
end)
PressSpecialFrameEscape()
assert(dirtyOwner:IsShown(), "a dirty Escape immediately restores the editor")
assert(popup:IsShown(), "a dirty Escape asks before discarding changes")
assert(dirtyFinished == 0 and AngryEra_Window:IsShown(), "the dirty editor and main window remain open")
popup:Hide()
assert(
    dirtyOwner:IsShown() and dirtyFinished == 0 and dirtyPriorHide == 0,
    "canceling the warning preserves the dirty draft without running the prior lifecycle"
)
dirtyOwner:Hide()
assert(popup:IsShown(), "the discard warning can be opened again after cancel")
StaticPopupDialogs.AngryEra_LayoutConfirm.OnAccept(popup)
assert(dirtyFinished == 1 and not dirtyOwner:IsShown(), "accepting discard closes the dirty editor once")
assert(dirtyPriorHide == 1, "accepted discard runs the prior AceGUI lifecycle exactly once")
assert(dirtyOwner:GetScript("OnHide") == dirtyOriginalOnHide, "discard restores the pooled frame's prior script")
RunDeferredCallbacks()
assert(HasSpecialFrame("AngryEra_Window"), "discarding restores the main Escape registration")

-- Nested layout prompts consume Escape before their owner. A second Escape can
-- then close the clean owner, matching the foreground modal behavior in-game.
local nestedOwner = NewFrame(UIParent)
nestedOwner:Show()
local nestedFinished = 0
AttachTestGuard(nestedOwner, function()
    return false
end, function()
    nestedFinished = nestedFinished + 1
end)
layoutEditor.ShowTextPopup({
    Prompt = "Nested:",
    Owner = nestedOwner,
    OnAccept = function() end,
})
nestedOwner:Hide()
assert(nestedOwner:IsShown() and nestedFinished == 0, "Escape closes a nested prompt before its editor")
assert(not popup:IsShown(), "the nested prompt is gone after the first Escape")
nestedOwner:Hide()
assert(nestedFinished == 1 and not nestedOwner:IsShown(), "the next Escape closes the clean editor")
RunDeferredCallbacks()

-- If two auxiliary editors exist, only the top one is registered. Closing it
-- reveals the previous editor on the next frame without touching the main UI.
local lowerOwner = NewFrame(UIParent)
local upperOwner = NewFrame(UIParent)
lowerOwner:Show()
upperOwner:Show()
local lowerGuard = AttachTestGuard(lowerOwner, function()
    return false
end, function() end)
local lowerEscapeName = UISpecialFrames[1]
AttachTestGuard(upperOwner, function()
    return false
end, function() end)
local upperEscapeName = UISpecialFrames[1]
assert(
    upperEscapeName ~= lowerEscapeName and not HasSpecialFrame(lowerEscapeName),
    "only the top auxiliary editor participates in Escape"
)
upperOwner:Hide()
RunDeferredCallbacks()
assert(HasSpecialFrame(lowerEscapeName), "closing the top editor restores the previous editor")
lowerGuard:Finish()
RunDeferredCallbacks()
assert(HasSpecialFrame("AngryEra_Window"), "closing the last editor restores the main window")

popupAvailable = false
assert(layoutEditor.ShowTextPopup({
    Prompt = "Unavailable:",
    Owner = ownerTwo,
    OnAccept = function() end,
}) == nil, "an unavailable StaticPopup slot returns without opening a modal")
assert(not blocker:IsShown() and blocker.allPoints == nil, "a failed popup leaves no input blocker behind")

local unavailableOwner = NewFrame(UIParent)
unavailableOwner:Show()
local unavailableDirty = true
local unavailableFinished = 0
AttachTestGuard(unavailableOwner, function()
    return unavailableDirty
end, function()
    unavailableFinished = unavailableFinished + 1
end)
unavailableOwner:Hide()
assert(
    unavailableOwner:IsShown() and unavailableFinished == 0,
    "an unavailable discard popup leaves the dirty editor open"
)
unavailableDirty = false
unavailableOwner:Hide()
RunDeferredCallbacks()
assert(unavailableFinished == 1, "the editor can retry closing after an unavailable discard popup")

print("Layout modal tests passed.")
