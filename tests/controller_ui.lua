-- Focused regression coverage for the session-only Raid Controller controls.
-- The editor menu must remain usable without a selected page, and every
-- authority change must travel through the protocol-runtime API rather than
-- mutating UI state directly.

local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra, libs = {} }

assert(loadfile("modules/layout.lua"))("AngryEra", app)

AngryEra.utils.helpers = {
    EnsureUnitShortName = function(name)
        return type(name) == "string" and (name:match("^([^-]+)") or name) or name
    end,
    IsCategoryDescendant = function()
        return false
    end,
    IterateGroupMembers = function() end,
    selectedLastValue = function(value)
        return tonumber(value)
    end,
}
AngryEra.utils.colors = {}

app.libs.AceGUI = setmetatable({}, {
    __index = function()
        return function() end
    end,
})
app.libs.DDM = app.libs.AceGUI

AngryAssign_Categories = {}
AngryAssign_Pages = {}
AngryAssign_State = {
    displayed = nil,
    tree = {
        groups = {},
        selected = nil,
    },
}

local state = {
    CanRequest = true,
    Control = nil,
    InRaid = true,
    Leader = "Roselea-Mankrik",
    Now = 100,
    Outgoing = {},
    Pending = {},
    Role = "assistant",
}
local calls = {
    CloseMenus = 0,
    Decline = {},
    Grant = {},
    HidePopup = 0,
    Reclaim = 0,
    Request = 0,
    UpdateSelected = 0,
}
local printed = {}
local deferred = {}
local shownPopup

rawset(_G, "IsInRaid", function()
    return state.InRaid
end)

rawset(_G, "GetTime", function()
    return state.Now
end)

rawset(_G, "C_Timer", {
    After = function(delay, callback)
        deferred[#deferred + 1] = {
            Callback = callback,
            Delay = delay,
        }
    end,
})

rawset(_G, "CloseDropDownMenus", function()
    calls.CloseMenus = calls.CloseMenus + 1
end)

StaticPopupDialogs = {}
rawset(_G, "StaticPopup_Show", function(name, textArg1, textArg2, data)
    shownPopup = {
        Data = data,
        Frame = {
            data = data,
        },
        Name = name,
        TextArg1 = textArg1,
        TextArg2 = textArg2,
    }
    return shownPopup.Frame
end)

rawset(_G, "StaticPopup_Hide", function()
    calls.HidePopup = calls.HidePopup + 1
    shownPopup = nil
end)

function AngryEra:Print(message)
    printed[#printed + 1] = message
end

function AngryEra:GetDelegatedRaidControl()
    return state.Control
end

function AngryEra:GetRaidLeader()
    return state.Leader
end

function AngryEra:IsPlayerRaidLeader()
    return state.Role == "leader"
end

function AngryEra:CanLocalPlayerPublish(action)
    return action == "controlRequest" and state.Role == "assistant" and state.CanRequest
end

function AngryEra:GetPendingDelegatedControlRequest(requestId)
    return state.Pending[requestId]
end

function AngryEra:GetPendingOutgoingDelegatedControlRequest(requestId)
    return state.Outgoing[requestId]
end

function AngryEra:RequestDelegatedRaidControl()
    calls.Request = calls.Request + 1
    local requestId = "controller-session:request:1"
    state.Outgoing[requestId] = {
        MessageId = requestId,
        Target = state.Leader,
        TargetKey = state.Leader:lower(),
    }
    return true, requestId
end

function AngryEra:GrantDelegatedRaidControl(requestId)
    calls.Grant[#calls.Grant + 1] = requestId
    local request = state.Pending[requestId]
    assert(request, "the UI must revalidate a request before routing Grant")
    state.Pending[requestId] = nil
    state.Control = {
        Controller = request.Controller,
        GrantId = requestId,
        Leader = state.Leader,
    }
    return true, requestId
end

function AngryEra:DeclineDelegatedRaidControl(requestId)
    calls.Decline[#calls.Decline + 1] = requestId
    assert(state.Pending[requestId], "the UI must revalidate a request before routing Decline")
    state.Pending[requestId] = nil
    return true, requestId
end

function AngryEra:ReclaimDelegatedRaidControl()
    calls.Reclaim = calls.Reclaim + 1
    assert(state.Control, "Reclaim should only route while control is delegated")
    local grantId = state.Control.GrantId
    state.Control = nil
    return true, grantId
end

assert(loadfile("modules/ui/editor.lua"))("AngryEra", app)

-- Keep refreshes observable without constructing the editor's AceGUI window.
function AngryEra:UpdateSelected()
    calls.UpdateSelected = calls.UpdateSelected + 1
end

local controllerUi = assert(AngryEra.utils.layout_editor.RaidController, "the Raid Controller UI is testable")

local function MenuEntry(menu, text)
    for _, entry in ipairs(menu) do
        if entry.text == text then
            return entry
        end
    end
end

local function MenuEntryPrefix(menu, prefix)
    for _, entry in ipairs(menu) do
        if type(entry.text) == "string" and entry.text:sub(1, #prefix) == prefix then
            return entry
        end
    end
end

local function MainMenu()
    return AngryEra.utils.layout_editor.MainMenuEntries()
end

-- A qualified assistant can request control with an empty page library and no
-- selected page. The request becomes visibly pending until runtime completes it.
local menu = MainMenu()
local status = assert(MenuEntry(menu, "Raid Controller: Roselea (raid leader)"))
assert(status.isTitle == true, "the current canonical authority should be visible")
local request = assert(MenuEntry(menu, "Request Raid Control"))
request.func()
assert(calls.Request == 1, "Request must route through RequestDelegatedRaidControl")
menu = MainMenu()
assert(MenuEntry(menu, "Raid Control Request Pending").disabled == true)
assert(not MenuEntry(menu, "Request Raid Control"), "a pending request must not be duplicated")

state.Outgoing["controller-session:request:1"] = nil
menu = MainMenu()
assert(MenuEntry(menu, "Request Raid Control"), "runtime expiry/reset should clear the local pending label")
assert(not MenuEntry(menu, "Raid Control Request Pending"))
request = assert(MenuEntry(menu, "Request Raid Control"))
request.func()

AngryEra:DelegatedControlRequestCompleted({
    Leader = state.Leader,
    RequestId = "controller-session:request:1",
    Status = "declined",
})
state.Outgoing["controller-session:request:1"] = nil
assert(MenuEntry(MainMenu(), "Request Raid Control"), "a completed request should restore the action")

-- A pending UI request belongs to one actual leader in one observed raid.
-- Changing leaders, or observing a leave/rejoin boundary, must immediately
-- re-enable Request instead of leaving a dead two-minute pending label.
request = assert(MenuEntry(MainMenu(), "Request Raid Control"))
request.func()
assert(MenuEntry(MainMenu(), "Raid Control Request Pending"))
state.Outgoing["controller-session:request:1"].TargetKey = "eblis-mankrik"
menu = MainMenu()
assert(MenuEntry(menu, "Request Raid Control"), "a runtime target mismatch should clear the local pending request")
assert(not MenuEntry(menu, "Raid Control Request Pending"))
request = assert(MenuEntry(menu, "Request Raid Control"))
request.func()
state.Leader = "Eblis-Mankrik"
menu = MainMenu()
assert(MenuEntry(menu, "Request Raid Control"), "an actual-leader change should clear the old pending request")
assert(not MenuEntry(menu, "Raid Control Request Pending"))
request = assert(MenuEntry(menu, "Request Raid Control"))
request.func()
assert(MenuEntry(MainMenu(), "Raid Control Request Pending"))
state.InRaid = false
menu = MainMenu()
assert(
    not MenuEntryPrefix(menu, "Raid Controller:")
        and not MenuEntry(menu, "Request Raid Control")
        and not MenuEntry(menu, "Raid Control Request Pending"),
    "Raid Controller actions should disappear outside a raid"
)
state.InRaid = true
menu = MainMenu()
assert(MenuEntry(menu, "Request Raid Control"), "a leave/rejoin boundary should clear the previous raid's request")
assert(not MenuEntry(menu, "Raid Control Request Pending"))
state.Leader = "Roselea-Mankrik"

-- A leader receives a focused prompt and can reopen the same validated request
-- from Menu after dismissing it.
state.Role = "leader"
local declineId = "assistant-session:request:2"
state.Pending[declineId] = {
    Controller = "Zessling-Mankrik",
    MessageId = declineId,
}
assert(AngryEra:ShowDelegatedControlRequest(declineId) == true)
assert(shownPopup and shownPopup.Name == controllerUi.PopupName)
assert(shownPopup.TextArg1 == "Zessling", "same-realm controller names should stay readable")
assert(calls.CloseMenus == 1, "the incoming request should take focus from an open menu")

local dialog = assert(StaticPopupDialogs[controllerUi.PopupName])
assert(dialog.button1 == "Grant Control" and dialog.button2 == "Decline")
assert(dialog.hideOnEscape == true and dialog.preferredIndex == 3)
assert(dialog.text:find("complete AngryEra control", 1, true), "the prompt should explain the authority transfer")
assert(
    dialog.text:find("own categories, pages, and page order", 1, true),
    "the prompt should identify the controller's canonical library"
)

dialog.OnCancel(shownPopup.Frame, shownPopup.Data, "escape")
assert(#calls.Decline == 0, "Escape must dismiss without declining")
assert(state.Pending[declineId], "Escape must leave the runtime request pending")
menu = MainMenu()
assert(MenuEntry(menu, "Review Request: Zessling"), "a dismissed request must remain reviewable")

dialog.OnCancel(shownPopup.Frame, shownPopup.Data, "clicked")
assert(calls.Decline[1] == declineId, "Decline must route the exact request id")
assert(not state.Pending[declineId])
assert(not MenuEntry(MainMenu(), "Review Request: Zessling"))

-- Runtime expiry and loss of actual leadership close an already-visible prompt
-- instead of leaving stale Grant/Decline controls over the editor.
local expiredId = "assistant-session:request:expired"
state.Pending[expiredId] = {
    Controller = "Kwayteow-Mankrik",
    ExpiresAt = state.Now + 1,
    MessageId = expiredId,
}
assert(AngryEra:ShowDelegatedControlRequest(expiredId) == true)
local hidesBeforeExpiry = calls.HidePopup
local expiryTimer = assert(deferred[#deferred], "an open request should schedule its exact expiry")
state.Now = state.Pending[expiredId].ExpiresAt + 0.1
expiryTimer.Callback()
assert(
    calls.HidePopup == hidesBeforeExpiry + 1 and shownPopup == nil,
    "an expired request should close its popup without another UI event"
)
state.Pending[expiredId] = nil

local supersededPopupId = "assistant-session:request:superseded-popup"
state.Pending[supersededPopupId] = {
    Controller = "Kwayteow-Mankrik",
    ExpiresAt = state.Now + 1,
    MessageId = supersededPopupId,
}
assert(AngryEra:ShowDelegatedControlRequest(supersededPopupId) == true)
local supersededExpiryTimer = assert(deferred[#deferred])
local currentPopupId = "assistant-session:request:current-popup"
state.Pending[currentPopupId] = {
    Controller = "Eblis-Mankrik",
    ExpiresAt = state.Now + 10,
    MessageId = currentPopupId,
}
assert(AngryEra:ShowDelegatedControlRequest(currentPopupId) == true)
local hidesBeforeSupersededTimer = calls.HidePopup
state.Now = state.Pending[supersededPopupId].ExpiresAt + 0.1
supersededExpiryTimer.Callback()
assert(
    calls.HidePopup == hidesBeforeSupersededTimer
        and shownPopup
        and shownPopup.Data.RequestId == currentPopupId
        and controllerUi.OpenRequestId == currentPopupId,
    "an older request timer must not close the currently reviewed request"
)
controllerUi:CloseRequestPopup()
state.Pending[supersededPopupId] = nil
state.Pending[currentPopupId] = nil

local formerLeaderId = "assistant-session:request:former-leader"
state.Pending[formerLeaderId] = {
    Controller = "Eblis-Mankrik",
    MessageId = formerLeaderId,
}
assert(AngryEra:ShowDelegatedControlRequest(formerLeaderId) == true)
local hidesBeforeRoleLoss = calls.HidePopup
state.Role = "assistant"
AngryEra:UpdateRaidControllerControls()
assert(
    calls.HidePopup == hidesBeforeRoleLoss + 1 and shownPopup == nil,
    "losing actual raid leadership should close the review popup"
)
state.Role = "leader"
state.Pending[formerLeaderId] = nil

-- Grant uses the same exact request boundary, exposes both controller and
-- Blizzard leader in status, and enables explicit leader reclaim.
local grantId = "assistant-session:request:3"
state.Pending[grantId] = {
    Controller = "Zessy-Mankrik",
    MessageId = grantId,
}
assert(AngryEra:ShowDelegatedControlRequest(grantId) == true)
dialog.OnAccept(shownPopup.Frame)
assert(calls.Grant[1] == grantId, "Grant must route the exact reviewed request id")
assert(state.Control and state.Control.GrantId == grantId)

menu = MainMenu()
assert(
    MenuEntry(menu, "Raid Controller: Zessy (raid leader: Roselea)"),
    "delegated status should identify both operational controller and Blizzard leader"
)
local reclaim = assert(MenuEntry(menu, "Reclaim Raid Control"))
assert(not MenuEntry(menu, "Request Raid Control"), "an active lease must suppress new requests")
reclaim.func()
assert(calls.Reclaim == 1, "Reclaim must route through ReclaimDelegatedRaidControl")
assert(not state.Control)
assert(MenuEntry(MainMenu(), "Raid Controller: Roselea (raid leader)"))

-- A non-leader controller sees the active status but cannot reclaim or request
-- a second lease.
state.Role = "assistant"
state.Control = {
    Controller = "Zessy-Mankrik",
    GrantId = "assistant-session:request:4",
    Leader = state.Leader,
}
menu = MainMenu()
status = assert(MenuEntryPrefix(menu, "Raid Controller: Zessy"))
assert(status.isTitle == true)
assert(not MenuEntry(menu, "Reclaim Raid Control"))
assert(not MenuEntry(menu, "Request Raid Control"))

print("Raid Controller UI tests passed.")
