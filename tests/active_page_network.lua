local currentTime = 100
local currentPlayer = "Publisher-Realm"
local grouped = true
local raid = true
local members = {
    {
        Name = "Leader-Realm",
        Rank = 2,
        Subgroup = 1,
        Online = true,
    },
    {
        Name = "Publisher-Realm",
        Rank = 1,
        Subgroup = 2,
        Online = true,
    },
}

function _G.time()
    return currentTime
end
function _G.IsInRaid()
    return grouped and raid
end
function _G.IsInGroup()
    return grouped
end

local helpers = {
    EnsureUnitShortName = function(name)
        return name:match("^([^-]+)")
    end,
    PlayerFullName = function()
        return currentPlayer
    end,
    IterateGroupMembers = function(callback)
        for _, member in ipairs(members) do
            if callback(member.Name, member.Name, member.Rank, member.Subgroup, nil, member.Online) then
                return
            end
        end
    end,
}

local AngryEra = {
    Version = "3.0.1",
    core = {
        updateFrequency = 2,
    },
    utils = {
        helpers = helpers,
    },
}
local app = {
    AngryEra = AngryEra,
}

local calls = {}
local timers = {}
local canceled = {}
local preparationCount = 0
local nextActivationError
local failPageSend = false

function AngryEra:CanLocalPlayerPublish(action)
    return action == "pageUpsert" or action == "display"
end

local function Upsert()
    return {
        Page = {
            SyncId = "ae3i:1:2:3:4:page:1",
            RevisionId = "fcs32:12345678",
        },
        AncestorVariableLayers = {},
        ContextRevisionId = "fcs32:87654321",
    }
end

function AngryEra:PrepareActivePageUpsert(id, options)
    preparationCount = preparationCount + 1
    assert(id == 5, "page preparation should receive the local page id")
    assert(options.UpdatedAt == currentTime, "page preparation should receive local time")
    assert(options.UpdatedBy == currentPlayer, "page preparation should receive authenticated local author")
    return Upsert()
end

function AngryEra:BuildActiveDisplayPayload(id, options)
    preparationCount = preparationCount + 1
    assert(options.UpdatedAt == currentTime, "display preparation should receive local time")
    assert(options.UpdatedBy == currentPlayer, "display preparation should receive local author")
    if id == nil then
        return {
            Displayed = false,
        }
    end
    assert(id == 5, "display preparation should receive the local page id")
    local upsert = Upsert()
    return {
        Displayed = true,
        SyncId = upsert.Page.SyncId,
        RevisionId = upsert.Page.RevisionId,
        ContextRevisionId = upsert.ContextRevisionId,
    },
        upsert
end

function AngryEra:ActivatePreparedActiveDisplay(displayPayload, pagePayload)
    calls[#calls + 1] = {
        Type = "ACTIVATE",
        DisplayPayload = displayPayload,
        PagePayload = pagePayload,
    }
    if nextActivationError then
        local activationError = nextActivationError
        nextActivationError = nil
        return false, activationError
    end
    return true
end

function AngryEra:ClearActiveDisplayReference()
    calls[#calls + 1] = {
        Type = "CLEAR_ACTIVE",
    }
    return true
end

function AngryEra:SendProtocolPageUpsert(payload)
    calls[#calls + 1] = {
        Type = "PAGE_UPSERT",
        Payload = payload,
    }
    if failPageSend then
        return false, "page-send-failed"
    end
    return true, "page-message"
end

function AngryEra:SendProtocolDisplay(payload)
    calls[#calls + 1] = {
        Type = "DISPLAY",
        Payload = payload,
    }
    return true, "display-message"
end

function AngryEra:SendProtocolDisplayRequest(target)
    calls[#calls + 1] = {
        Type = "DISPLAY_REQUEST",
        Target = target,
    }
    return true, "request-message"
end

function AngryEra:ScheduleTimer(method, delay, argument)
    local timer = {
        Method = method,
        Delay = delay,
        Argument = argument,
    }
    timers[#timers + 1] = timer
    return timer
end

function AngryEra:CancelTimer(timer)
    canceled[timer] = true
end

function AngryEra:GetProtocolPeer()
    return nil
end

function AngryEra:IsValidRaid()
    return true
end

function AngryEra:Print() end

assert(loadfile("modules/network.lua"))("AngryEra", app)

AngryAssign_Pages = {
    [5] = {
        Id = 5,
    },
}

assert(AngryEra.ReceiveMessage == nil, "protocol-1 receive entrypoint must not exist")
assert(AngryEra.ProcessMessage == nil, "protocol-1 positional dispatcher must not exist")
assert(AngryEra.SendOutMessage == nil, "protocol-1 send entrypoint must not exist")

local sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message", "active display should send successfully")
assert(activatedLocally, "successful display publication should report local activation")
assert(preparationCount == 1, "active display should be prepared exactly once")
assert(#calls == 3, "active display should activate locally and send exactly two envelopes")
assert(calls[1].Type == "ACTIVATE", "exact display tuple must activate before transport")
assert(calls[2].Type == "PAGE_UPSERT", "page snapshot must be sent before display selection")
assert(calls[3].Type == "DISPLAY", "display selection should follow its snapshot")
assert(
    calls[1].PagePayload.Page.RevisionId == calls[1].DisplayPayload.RevisionId
        and calls[1].PagePayload.ContextRevisionId == calls[1].DisplayPayload.ContextRevisionId
        and calls[2].Payload.Page.RevisionId == calls[3].Payload.RevisionId
        and calls[2].Payload.ContextRevisionId == calls[3].Payload.ContextRevisionId,
    "page and display envelopes should carry one exact tuple"
)

local preparationBeforeFailure = preparationCount
local callsBeforeFailure = #calls
failPageSend = true
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
failPageSend = false
assert(not sent and result == "page-send-failed", "page transport errors should be returned")
assert(activatedLocally, "transport failure after activation should retain the exact local display")
assert(preparationCount == preparationBeforeFailure + 1, "failed transport must not prepare the page twice")
assert(calls[callsBeforeFailure + 1].Type == "ACTIVATE", "local activation must precede failed transport")
assert(calls[callsBeforeFailure + 2].Type == "PAGE_UPSERT", "failed page transport should still be attempted")

local preparationBeforeActivationFailure = preparationCount
local callsBeforeActivationFailure = #calls
nextActivationError = "activation-failed"
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(not sent and result == "activation-failed", "local activation errors should be surfaced")
assert(not activatedLocally, "activation failure must report that local display state did not commit")
assert(preparationCount == preparationBeforeActivationFailure + 1, "activation failure must retain single preparation")
assert(#calls == callsBeforeActivationFailure + 1, "activation failure must stop before transport")
assert(calls[#calls].Type == "ACTIVATE", "activation failure should occur at the local commit boundary")

currentTime = 101
sent, result, activatedLocally = AngryEra:SendDisplay(5)
assert(sent and result == "scheduled", "rapid display changes should be throttled")
assert(not activatedLocally, "a scheduled display has not activated locally yet")
assert(timers[#timers].Method == "SendDisplayMessage", "display throttle should schedule the v3 sender")
local scheduledDisplay = timers[#timers]
sent, result, activatedLocally = AngryEra:SendDisplay(5, true)
assert(sent and result == "display-message", "forced display should send immediately")
assert(activatedLocally, "forced display should activate its exact tuple immediately")
assert(canceled[scheduledDisplay], "forced display should cancel its delayed predecessor")

local callsBeforeClear = #calls
currentTime = 104
sent, result, activatedLocally = AngryEra:SendDisplayMessage(nil)
assert(sent and result == "display-message", "display clear should send")
assert(activatedLocally, "display clear should report that local volatile state committed")
assert(#calls == callsBeforeClear + 2, "display clear should clear locally and send no page snapshot")
assert(calls[callsBeforeClear + 1].Type == "CLEAR_ACTIVE", "local active reference must clear before transport")
assert(calls[#calls].Type == "DISPLAY" and calls[#calls].Payload.Displayed == false, "clear uses named payload")

local preparationBeforePage = preparationCount
sent, result = AngryEra:SendPageMessage(5)
assert(sent and type(result) == "table", "page publication should return its prepared payload")
assert(preparationCount == preparationBeforePage + 1, "page publication should prepare once")
assert(calls[#calls].Type == "PAGE_UPSERT", "page publication should use protocol v3")

currentTime = 105
sent, result = AngryEra:SendPage(5)
assert(sent and result == "scheduled", "rapid page publication should be throttled")
assert(timers[#timers].Method == "SendPageMessage", "page throttle should schedule the v3 sender")
local scheduledPage = timers[#timers]
AngryEra:CancelPageTimer(5)
assert(canceled[scheduledPage], "page removal should cancel pending publication")

sent, result = AngryEra:SendRequestDisplay()
assert(sent and result == "request-message", "followers should request the current leader display")
assert(calls[#calls].Type == "DISPLAY_REQUEST", "display request should use its named v3 message")
assert(calls[#calls].Target == "Leader-Realm", "display request should target the online leader")

currentPlayer = "Leader-Realm"
sent, result = AngryEra:SendRequestDisplay()
assert(not sent and result == "local-player-is-leader", "leader should not whisper a request to itself")

currentPlayer = "Publisher-Realm"
grouped = false
sent, result = AngryEra:SendRequestDisplay()
assert(not sent and result == "not-grouped", "solo clients should not request group display state")
grouped = true

assert(AngryEra:GetRaidLeader(true) == "Leader-Realm", "leader lookup should retain group utility behavior")
assert(AngryEra:GetCurrentGroup() == 2, "subgroup lookup should retain display rendering behavior")

local originalPrint = print
local versionOutput = {}
local peerQueryId
rawset(_G, "LIGHTYELLOW_FONT_COLOR_CODE", "")
function _G.print(message)
    versionOutput[#versionOutput + 1] = message
end
function AngryEra:GetProtocolPeer(_, queryId)
    peerQueryId = queryId
    return nil
end
assert(AngryEra:VersionCheckOutput() == false, "version output should reject a missing query identifier")
assert(peerQueryId == nil, "invalid version output must not consult stale discovery state")
assert(AngryEra:VersionCheckOutput("query-current"), "current-query version output should succeed")
_G.print = originalPrint
assert(peerQueryId == "query-current", "version output must only consult peers from its exact query")
assert(versionOutput[#versionOutput]:find("Leader%-Realm"), "a non-responder should be reported as missing")

print("Active-page network tests passed.")
