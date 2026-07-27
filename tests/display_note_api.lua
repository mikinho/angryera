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
        },
    },
    libs = {
        lwin = {},
        LSM = {},
        LibMustache = {
            render = function(text)
                return text
            end,
        },
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/api.lua"))("AngryEra", app)
assert(loadfile("modules/ui/display.lua"))("AngryEra", app)

local AngryEra = app.AngryEra
local firstPage = {
    SyncId = "ae3i:1:2:3:4:page:1",
    Name = "First Page",
    Contents = "First assignment",
}
local secondPage = {
    SyncId = "ae3i:1:2:3:4:page:2",
    Name = "Second Page",
    Contents = "Second assignment",
}
local rendered = {}

AngryAssign_Categories = {}
AngryAssign_Pages = {
    [1] = firstPage,
    [2] = secondPage,
}
AngryAssign_State = {
    directionUp = false,
    displayed = 1,
}

AngryEra.display_text = {
    Clear = function()
        for index = #rendered, 1, -1 do
            rendered[index] = nil
        end
    end,
    AddMessage = function(_, text)
        rendered[#rendered + 1] = text
    end,
}
AngryEra.GetConfig = function(_, key)
    local values = {
        highlight = "",
        highlightColor = "ffffff",
    }
    return values[key]
end
AngryEra.GetCurrentGroup = function()
    return 1
end
AngryEra.GetTemplateContext = function()
    return {
        rosterColors = {},
    }
end
AngryEra.UpdateBackdrop = function() end

function _G.strsplit(_, text)
    return text
end

_G.C_Timer = {
    After = function(_, callback)
        callback()
    end,
}

local function RenderedBody()
    return table.concat(rendered, "\n")
end

local function EventLabel(syncId)
    return syncId or "<clear>"
end

local function AssertEvents(actual, expected, message)
    assert(#actual == #expected, message .. " count")
    for index, value in ipairs(expected) do
        assert(actual[index] == value, message .. " at index " .. index)
    end
end

local weakAuraEvents = {}
local weakAuraTailEvents = {}
local aceEvents = {}
local aceTailEvents = {}
local listenerChannel
local listenerMode
local eventSawCommittedDisplay = false
local weakAuraDispatchDepth = 0
local aceDispatchDepth = 0
local maximumWeakAuraDispatchDepth = 0
local maximumAceDispatchDepth = 0

local function HandleListener(channel, syncId)
    if channel ~= listenerChannel or syncId ~= firstPage.SyncId or listenerMode == nil then
        return
    end

    eventSawCommittedDisplay = RenderedBody() == firstPage.Contents
    local action = listenerMode
    listenerMode = nil
    if action == "switch" then
        AngryAssign_State.displayed = 2
    else
        AngryAssign_State.displayed = nil
    end
    AngryEra:UpdateDisplayed()
end

_G.WeakAuras = {
    ScanEvents = function(event, syncId)
        if event ~= AngryEra.NOTE_UPDATE_EVENT then
            return
        end

        weakAuraDispatchDepth = weakAuraDispatchDepth + 1
        maximumWeakAuraDispatchDepth = math.max(maximumWeakAuraDispatchDepth, weakAuraDispatchDepth)
        weakAuraEvents[#weakAuraEvents + 1] = EventLabel(syncId)
        HandleListener("WeakAuras", syncId)
        weakAuraTailEvents[#weakAuraTailEvents + 1] = EventLabel(syncId)
        weakAuraDispatchDepth = weakAuraDispatchDepth - 1
    end,
}

function AngryEra:SendMessage(event, syncId)
    if event ~= AngryEra.NOTE_UPDATE_EVENT then
        return
    end

    aceDispatchDepth = aceDispatchDepth + 1
    maximumAceDispatchDepth = math.max(maximumAceDispatchDepth, aceDispatchDepth)
    aceEvents[#aceEvents + 1] = EventLabel(syncId)
    HandleListener("AceEvent", syncId)
    aceTailEvents[#aceTailEvents + 1] = EventLabel(syncId)
    aceDispatchDepth = aceDispatchDepth - 1
end

local function ResetScenario(channel, mode)
    listenerChannel = nil
    listenerMode = nil
    AngryEra:NotifyDisplayedNoteChanged(nil)
    AngryEra.display_text:Clear()

    weakAuraEvents = {}
    weakAuraTailEvents = {}
    aceEvents = {}
    aceTailEvents = {}
    eventSawCommittedDisplay = false
    weakAuraDispatchDepth = 0
    aceDispatchDepth = 0
    maximumWeakAuraDispatchDepth = 0
    maximumAceDispatchDepth = 0

    AngryAssign_State.displayed = 1
    listenerChannel = channel
    listenerMode = mode
end

local function RunScenario(channel, mode)
    ResetScenario(channel, mode)
    AngryEra:UpdateDisplayed()

    local expectedFinalSyncId = mode == "switch" and secondPage.SyncId or "<clear>"
    local expectedEvents = { firstPage.SyncId, expectedFinalSyncId }
    AssertEvents(weakAuraEvents, expectedEvents, channel .. " " .. mode .. " WeakAuras delivery")
    AssertEvents(weakAuraTailEvents, expectedEvents, channel .. " " .. mode .. " WeakAuras tail delivery")
    AssertEvents(aceEvents, expectedEvents, channel .. " " .. mode .. " AceEvent delivery")
    AssertEvents(aceTailEvents, expectedEvents, channel .. " " .. mode .. " AceEvent tail delivery")
    assert(maximumWeakAuraDispatchDepth == 1, channel .. " " .. mode .. " must not recursively dispatch WeakAuras")
    assert(maximumAceDispatchDepth == 1, channel .. " " .. mode .. " must not recursively dispatch AceEvent")
    assert(eventSawCommittedDisplay, channel .. " " .. mode .. " should observe the committed first-page display")

    if mode == "switch" then
        local switchedNote = AngryEra:GetDisplayedNote()
        assert(AngryAssign_State.displayed == 2, channel .. " should switch the active page")
        assert(RenderedBody() == secondPage.Contents, channel .. " must retain the switched page")
        assert(
            switchedNote and switchedNote.SyncId == secondPage.SyncId,
            channel .. " snapshot should match the switch"
        )
        assert(switchedNote.Rendered == secondPage.Contents, channel .. " snapshot and display should stay consistent")
    else
        assert(AngryAssign_State.displayed == nil, channel .. " should clear the active page")
        assert(RenderedBody() == "", channel .. " must retain the cleared display")
        assert(AngryEra:GetDisplayedNote() == nil, channel .. " should retain a cleared note snapshot")
    end
end

for _, channel in ipairs({ "WeakAuras", "AceEvent" }) do
    RunScenario(channel, "switch")
    RunScenario(channel, "clear")
end

local isolatedAceEvents = {}
_G.WeakAuras.ScanEvents = function(event)
    if event == AngryEra.NOTE_UPDATE_EVENT then
        error("WeakAuras listener failure")
    end
end
function AngryEra:SendMessage(event, syncId)
    if event == AngryEra.NOTE_UPDATE_EVENT then
        isolatedAceEvents[#isolatedAceEvents + 1] = EventLabel(syncId)
    end
end

local weakAurasFailureIsolated, weakAurasFailureAnnounced = pcall(AngryEra.NotifyDisplayedNoteChanged, AngryEra, {
    Page = firstPage,
    RenderedText = firstPage.Contents,
    MergedVariables = {},
})
assert(weakAurasFailureIsolated and weakAurasFailureAnnounced, "WeakAuras callback failures should remain isolated")
AssertEvents(isolatedAceEvents, { firstPage.SyncId }, "AceEvent delivery after a WeakAuras callback failure")

AngryEra:NotifyDisplayedNoteChanged(nil)
local isolatedWeakAuraEvents = {}
_G.WeakAuras.ScanEvents = function(event, syncId)
    if event == AngryEra.NOTE_UPDATE_EVENT then
        isolatedWeakAuraEvents[#isolatedWeakAuraEvents + 1] = EventLabel(syncId)
    end
end
function AngryEra:SendMessage(event)
    if event == AngryEra.NOTE_UPDATE_EVENT then
        error("AceEvent listener failure")
    end
end

local aceFailureIsolated, aceFailureAnnounced = pcall(AngryEra.NotifyDisplayedNoteChanged, AngryEra, {
    Page = firstPage,
    RenderedText = firstPage.Contents,
    MergedVariables = {},
})
assert(aceFailureIsolated and aceFailureAnnounced, "AceEvent callback failures should remain isolated")
AssertEvents(isolatedWeakAuraEvents, { firstPage.SyncId }, "WeakAuras delivery before an AceEvent callback failure")

-- A listener that continuously creates meaningful changes must yield instead
-- of trapping the UI thread in one synchronous event drain.
AngryEra:NotifyDisplayedNoteChanged(nil)
local deferredCallbacks = {}
_G.C_Timer.After = function(_, callback)
    deferredCallbacks[#deferredCallbacks + 1] = callback
end
function AngryEra:SendMessage() end

local feedbackEnabled = true
local feedbackEvents = {}
_G.WeakAuras.ScanEvents = function(event, syncId)
    if event ~= AngryEra.NOTE_UPDATE_EVENT then
        return
    end

    feedbackEvents[#feedbackEvents + 1] = EventLabel(syncId)
    if feedbackEnabled then
        AngryAssign_State.displayed = AngryAssign_State.displayed == 1 and 2 or 1
        AngryEra:UpdateDisplayed()
    end
end

AngryAssign_State.displayed = 1
local feedbackReturned, feedbackError = pcall(AngryEra.UpdateDisplayed, AngryEra)
assert(feedbackReturned, "A feedback loop should yield without failing: " .. tostring(feedbackError))
assert(#feedbackEvents > 1 and #feedbackEvents <= 32, "A synchronous event drain should have a fixed budget")
assert(#deferredCallbacks > 0, "The latest coalesced feedback event should be deferred")

feedbackEnabled = false
local eventsBeforeDeferredDrain = #feedbackEvents
local callbacks = deferredCallbacks
deferredCallbacks = {}
for index = 1, #callbacks do
    callbacks[index]()
end
assert(#feedbackEvents == eventsBeforeDeferredDrain + 1, "The deferred drain should deliver one coalesced event")
local feedbackNote = AngryEra:GetDisplayedNote()
assert(
    feedbackEvents[#feedbackEvents] == EventLabel(feedbackNote and feedbackNote.SyncId),
    "The coalesced event should describe the latest snapshot"
)

firstPage.Vars = "PRIEST1=Roselea\nPALADIN1=Zessy\nHEALER*=PRIEST*,PALADIN*"
AngryAssign_State.displayed = 1
AngryEra:UpdateDisplayed()
local familyVars = AngryEra:GetDisplayedVars()
assert(
    familyVars and familyVars.HEALER1 == "Roselea" and familyVars.HEALER2 == "Zessy" and familyVars["HEALER*"] == nil,
    "the displayed-note API should expose generated family members without their declaration"
)

print("Display note API integration tests passed.")
