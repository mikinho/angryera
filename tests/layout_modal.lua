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
        self.shown = false
        if self.dialogInfo and self.dialogInfo.OnHide then
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

popupAvailable = false
assert(layoutEditor.ShowTextPopup({
    Prompt = "Unavailable:",
    Owner = ownerTwo,
    OnAccept = function() end,
}) == nil, "an unavailable StaticPopup slot returns without opening a modal")
assert(not blocker:IsShown() and blocker.allPoints == nil, "a failed popup leaves no input blocker behind")

print("Layout modal tests passed.")
