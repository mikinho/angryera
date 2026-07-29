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
local failNextTimer = false
local preparationCount = 0
local nextActivationError
local failPageSend = false
local failPageRequest = false
local canPublishDisplay = true
local canPublishPage = true
local canPublishChangeProposal = true
local canReceiveDisplay = true
local completeActiveTransfersImmediately = true
local activePageTransfer
local canceledActiveTransfers = 0
local activeDisplayReference
local pageRevisionIds = {
    [5] = "fcs32:12345678",
    [6] = "fcs32:22345678",
}
local pageRevisions = {
    [5] = 1,
    [6] = 1,
}
local contextRevisionIds = {
    [5] = "fcs32:87654321",
    [6] = "fcs32:97654321",
}
local pendingDisplayRequest
local sentChangeProposals = {}
local clearedSharedPageDrafts = 0
local clearedSyncDraftConflicts = 0
local rebasedSharedPageDrafts = {}
local canceledProtocolChangeProposals = {}

function AngryEra:CanLocalPlayerPublish(action)
    if action == "display" then
        return canPublishDisplay
    elseif action == "changeProposal" then
        return canPublishChangeProposal
    end
    return action == "pageUpsert" and canPublishPage
end

function AngryEra:CanReceiveFrom(_, action)
    return action ~= "display" or canReceiveDisplay
end

function AngryEra:GetAngryEraAuthority()
    return self:GetRaidLeader(true)
end

function AngryEra:GetDelegatedRaidControl()
    return nil
end

local function Upsert(id)
    return {
        Page = {
            SyncId = "ae3i:1:2:3:4:page:" .. tostring(id),
            Revision = pageRevisions[id],
            RevisionId = pageRevisionIds[id],
        },
        AncestorVariableLayers = {},
        ContextRevisionId = contextRevisionIds[id],
    }
end

function AngryEra:PrepareActivePageUpsert(id, options)
    preparationCount = preparationCount + 1
    assert(pageRevisionIds[id], "page preparation should receive a known local page id")
    assert(options.UpdatedAt == currentTime, "page preparation should receive local time")
    assert(options.UpdatedBy == currentPlayer, "page preparation should receive authenticated local author")
    return Upsert(id)
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
    assert(pageRevisionIds[id], "display preparation should receive a known local page id")
    local upsert = Upsert(id)
    return {
        Displayed = true,
        SyncId = upsert.Page.SyncId,
        Revision = upsert.Page.Revision,
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
    activeDisplayReference = {
        SyncId = displayPayload.SyncId,
        Revision = displayPayload.Revision,
        RevisionId = displayPayload.RevisionId,
        ContextRevisionId = displayPayload.ContextRevisionId,
    }
    return true
end

function AngryEra:ClearActiveDisplayReference()
    calls[#calls + 1] = {
        Type = "CLEAR_ACTIVE",
    }
    activeDisplayReference = nil
    return true
end

function AngryEra:GetActiveDisplayReference()
    return activeDisplayReference
end

function AngryEra:BuildActivePageChangeProposal(id, desired)
    local page = AngryAssign_Pages[id]
    assert(page and activeDisplayReference, "change proposal should bind the active page")
    return {
        SyncId = page.SyncId,
        BaseRevision = page.Revision,
        BaseRevisionId = activeDisplayReference.RevisionId,
        BaseContextRevisionId = activeDisplayReference.ContextRevisionId,
        Name = desired.Name,
        Vars = desired.Vars,
        Contents = desired.Contents,
    }
end

function AngryEra:SendProtocolChangeProposal(target, payload)
    sentChangeProposals[#sentChangeProposals + 1] = {
        Target = target,
        Payload = payload,
    }
    return true, "change-message-" .. tostring(#sentChangeProposals)
end

function AngryEra:ClearSharedPageChangeDraft()
    clearedSharedPageDrafts = clearedSharedPageDrafts + 1
    return true
end

function AngryEra:RebaseSharedPageChangeDraft(id, reference, desired)
    rebasedSharedPageDrafts[#rebasedSharedPageDrafts + 1] = {
        Id = id,
        Reference = reference,
        Desired = desired,
    }
    return true
end

function AngryEra:CancelProtocolChangeProposal(messageId)
    canceledProtocolChangeProposals[#canceledProtocolChangeProposals + 1] = messageId
    return true
end

function AngryEra:ClearSyncDraftConflict()
    clearedSyncDraftConflicts = clearedSyncDraftConflicts + 1
    self.syncDraftConflict = nil
    return true
end

function AngryEra:UpdateSelected(destructive)
    calls[#calls + 1] = {
        Type = "UPDATE_SELECTED",
        Destructive = destructive,
    }
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

function AngryEra:CancelProtocolActivePageTransfer(reason)
    if not activePageTransfer then
        return false, "idle"
    end
    local transfer = activePageTransfer
    activePageTransfer = nil
    canceledActiveTransfers = canceledActiveTransfers + 1
    transfer.Callback(transfer.CallbackArg, false, reason or "canceled", transfer.MessageId)
    return true, reason or "canceled"
end

function AngryEra:SendProtocolActivePageUpsert(payload, callback, callbackArg)
    calls[#calls + 1] = {
        Type = "PAGE_UPSERT",
        Payload = payload,
    }
    if failPageSend then
        return false, "page-send-failed"
    end
    activePageTransfer = {
        Callback = callback,
        CallbackArg = callbackArg,
        MessageId = "page-message",
    }
    if completeActiveTransfersImmediately then
        activePageTransfer = nil
        callback(callbackArg, true, "sent", "page-message")
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

function AngryEra:SendProtocolPageRequest(target, displayEnvelope, reference)
    calls[#calls + 1] = {
        Type = "PAGE_REQUEST",
        Target = target,
        DisplayEnvelope = displayEnvelope,
        Reference = reference,
    }
    if failPageRequest then
        return false, "page-request-failed"
    end
    return true, "page-request-message"
end

function AngryEra:GetPendingActiveDisplayRequest()
    return pendingDisplayRequest
end

function AngryEra:ScheduleTimer(method, delay, argument)
    if failNextTimer then
        failNextTimer = false
        return nil
    end
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

function AngryEra:UpdateDisplayed()
    calls[#calls + 1] = {
        Type = "UPDATE_DISPLAYED",
    }
end

function AngryEra:UpdateTree()
    calls[#calls + 1] = {
        Type = "UPDATE_TREE",
    }
end

assert(loadfile("modules/network.lua"))("AngryEra", app)

AngryAssign_Pages = {
    [5] = {
        Id = 5,
    },
    [6] = {
        Id = 6,
    },
}
AngryAssign_State = {
    displayed = nil,
}

assert(AngryEra.ReceiveMessage == nil, "protocol-1 receive entrypoint must not exist")
assert(AngryEra.ProcessMessage == nil, "protocol-1 positional dispatcher must not exist")
assert(AngryEra.SendOutMessage == nil, "protocol-1 send entrypoint must not exist")

local function CopyReference(payload)
    return {
        SyncId = payload.Page.SyncId,
        Revision = payload.Page.Revision,
        RevisionId = payload.Page.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
end

local sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message", "active display should send successfully")
assert(activatedLocally, "successful display publication should report local activation")
assert(preparationCount == 1, "active display should be prepared exactly once")
assert(#calls == 2, "active display should activate locally and send DISPLAY immediately")
assert(calls[1].Type == "ACTIVATE", "exact display tuple must activate before transport")
assert(calls[2].Type == "DISPLAY", "display selection should use the immediate control lane")
assert(calls[2].Payload.PageFollows == true, "an uncached display should announce its queued page snapshot")
local firstDisplayPageTimer = timers[#timers]
assert(
    firstDisplayPageTimer.Method == "SendDisplayPageMessage" and firstDisplayPageTimer.Delay == 0.125,
    "an uncached display should debounce its page snapshot for 125 milliseconds"
)

local callsBeforePendingReuse = #calls
local timersBeforePendingReuse = #timers
local canceledTransfersBeforePendingReuse = canceledActiveTransfers
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message", "a repeated pending tuple should publish its newer selection")
assert(activatedLocally, "a repeated pending tuple should activate locally")
assert(
    #calls == callsBeforePendingReuse + 2
        and calls[callsBeforePendingReuse + 1].Type == "ACTIVATE"
        and calls[callsBeforePendingReuse + 2].Type == "DISPLAY",
    "a repeated pending tuple should activate and send its newer DISPLAY immediately"
)
assert(calls[#calls].Payload.PageFollows == true, "a repeated pending tuple should retain its page promise")
assert(
    #timers == timersBeforePendingReuse
        and timers[#timers] == firstDisplayPageTimer
        and not canceled[firstDisplayPageTimer]
        and canceledActiveTransfers == canceledTransfersBeforePendingReuse,
    "a repeated pending tuple must retain its original debounce without adding or canceling work"
)

local latestPendingDisplay = calls[callsBeforePendingReuse + 2]
local callsBeforeFirstDisplayPageFlush = #calls
sent, result = AngryEra:SendDisplayPageMessage(firstDisplayPageTimer.Argument)
assert(sent and result == "page-message", "the captured display-page timer should flush its snapshot")
assert(
    #calls == callsBeforeFirstDisplayPageFlush + 1 and calls[#calls].Type == "PAGE_UPSERT",
    "the retained debounced page snapshot should follow the newer immediate DISPLAY"
)
assert(
    calls[1].PagePayload.Page.RevisionId == calls[1].DisplayPayload.RevisionId
        and calls[1].PagePayload.ContextRevisionId == calls[1].DisplayPayload.ContextRevisionId
        and calls[#calls].Payload.Page.SyncId == latestPendingDisplay.Payload.SyncId
        and calls[#calls].Payload.Page.RevisionId == latestPendingDisplay.Payload.RevisionId
        and calls[#calls].Payload.ContextRevisionId == latestPendingDisplay.Payload.ContextRevisionId,
    "the retained delayed page and newer immediate display should carry one exact tuple"
)

local callsBeforeCachedDisplay = #calls
local timersBeforeCachedDisplay = #timers
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message", "a repeated display tuple should publish its selection")
assert(activatedLocally, "a repeated display tuple should activate locally")
assert(#calls == callsBeforeCachedDisplay + 2, "a repeated display should activate and send DISPLAY immediately")
assert(calls[callsBeforeCachedDisplay + 1].Type == "ACTIVATE", "repeated display should still activate first")
assert(calls[#calls].Type == "DISPLAY", "repeated display should send its compact control")
assert(
    #timers == timersBeforeCachedDisplay and calls[#calls].Payload.PageFollows == nil,
    "an exact tuple published in this session should not retransmit its page"
)

pageRevisionIds[5] = "fcs32:12345679"
callsBeforeCachedDisplay = #calls
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "a new page revision should publish")
assert(#calls == callsBeforeCachedDisplay + 2, "a new page revision should send DISPLAY before its page")
assert(calls[#calls].Payload.PageFollows == true, "a new page revision should promise its queued page snapshot")
local revisedPageTimer = timers[#timers]
assert(revisedPageTimer.Method == "SendDisplayPageMessage", "a new page revision should queue its snapshot")
sent, result = AngryEra:SendDisplayPageMessage(revisedPageTimer.Argument)
assert(sent and result == "page-message", "a new page revision should flush asynchronously")
assert(calls[#calls].Type == "PAGE_UPSERT", "the new page revision should resend its snapshot")

contextRevisionIds[5] = "fcs32:87654322"
callsBeforeCachedDisplay = #calls
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "a new render context should publish")
assert(#calls == callsBeforeCachedDisplay + 2, "a new context should send DISPLAY before its page")
local revisedContextTimer = timers[#timers]
sent, result = AngryEra:SendDisplayPageMessage(revisedContextTimer.Argument)
assert(sent and result == "page-message", "a new render context should flush asynchronously")
assert(calls[#calls].Type == "PAGE_UPSERT", "the new context revision should resend its snapshot")

pageRevisionIds[5] = "fcs32:12345680"
local callsBeforeRapidDisplays = #calls
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "rapid page A should send DISPLAY immediately")
local rapidPageATimer = timers[#timers]
sent, result, activatedLocally = AngryEra:SendDisplayMessage(6)
assert(sent and result == "display-message" and activatedLocally, "rapid page B should send DISPLAY immediately")
local rapidPageBTimer = timers[#timers]
assert(canceled[rapidPageATimer], "rapid page B should cancel page A before A enters AceComm")
assert(#calls == callsBeforeRapidDisplays + 4, "rapid A to B should immediately activate and display both selections")
local callsBeforeStaleRapidFlush = #calls
sent, result = AngryEra:SendDisplayPageMessage(rapidPageATimer.Argument)
assert(sent and result == "superseded", "the canceled page A callback should be harmless")
assert(#calls == callsBeforeStaleRapidFlush, "the superseded page A callback must not publish")
sent, result = AngryEra:SendDisplayPageMessage(rapidPageBTimer.Argument)
assert(sent and result == "page-message", "the latest rapid page should flush")
assert(
    calls[#calls].Type == "PAGE_UPSERT" and calls[#calls].Payload.Page.SyncId == Upsert(6).Page.SyncId,
    "only rapid page B should enter page transport"
)

do
    completeActiveTransfersImmediately = false
    pageRevisionIds[5] = "fcs32:12345690"
    sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
    assert(sent and result == "display-message" and activatedLocally, "in-flight cancellation setup should display A")
    local firstTransferTimer = timers[#timers]
    sent, result = AngryEra:SendDisplayPageMessage(firstTransferTimer.Argument)
    assert(sent and result == "page-message" and activePageTransfer, "page A should enter the active stream")

    local timersBeforeSameTuple = #timers
    local canceledBeforeSameTuple = canceledActiveTransfers
    local firstActiveTransfer = activePageTransfer
    sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
    assert(sent and result == "display-message" and activatedLocally, "repeating page A should resend DISPLAY")
    assert(
        #timers == timersBeforeSameTuple
            and canceledActiveTransfers == canceledBeforeSameTuple
            and activePageTransfer == firstActiveTransfer,
        "repeating the same tuple must not restart its in-flight page stream"
    )

    local canceledBeforeReplacement = canceledActiveTransfers
    sent, result, activatedLocally = AngryEra:SendDisplayMessage(6)
    assert(sent and result == "display-message" and activatedLocally, "cached page B should replace in-flight page A")
    assert(
        canceledActiveTransfers == canceledBeforeReplacement + 1 and activePageTransfer == nil,
        "a newer display should stop production of the older active-page stream"
    )

    local timersBeforeRetry = #timers
    sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
    assert(sent and result == "display-message" and activatedLocally, "canceled page A should remain displayable")
    assert(#timers == timersBeforeRetry + 1, "a canceled transfer must not mark page A as published")
    local retryTimer = timers[#timers]
    sent, result = AngryEra:SendDisplayPageMessage(retryTimer.Argument)
    assert(sent and result == "page-message" and activePageTransfer, "page A should retry through the active stream")
    local completedTransfer = activePageTransfer
    activePageTransfer = nil
    completedTransfer.Callback(completedTransfer.CallbackArg, true, "sent", completedTransfer.MessageId)
    completeActiveTransfersImmediately = true
end

pageRevisionIds[5] = "fcs32:12345681"
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "authority recheck setup should publish DISPLAY")
local authorityRecheckTimer = timers[#timers]
local callsBeforeAuthorityRecheck = #calls
canPublishDisplay = false
sent, result = AngryEra:SendDisplayPageMessage(authorityRecheckTimer.Argument)
canPublishDisplay = true
assert(not sent and result == "unauthorized", "a delayed page flush should recheck display authority")
assert(#calls == callsBeforeAuthorityRecheck, "lost display authority must prevent delayed page transport")

pageRevisionIds[5] = "fcs32:12345682"
local timersBeforeTupleRecheck = #timers
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "tuple recheck setup should publish DISPLAY")
assert(#timers == timersBeforeTupleRecheck + 1, "tuple recheck setup should queue a new page snapshot")
local tupleRecheckTimer = timers[#timers]
activeDisplayReference = CopyReference(Upsert(6))
local callsBeforeTupleRecheck = #calls
sent, result = AngryEra:SendDisplayPageMessage(tupleRecheckTimer.Argument)
assert(sent and result == "superseded", "a delayed page flush should discard a tuple that is no longer active")
assert(#calls == callsBeforeTupleRecheck, "an obsolete active tuple must not enter page transport")

local preparationBeforeFailure = preparationCount
local callsBeforeFailure = #calls
pageRevisionIds[5] = "fcs32:12345683"
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "async failure setup should publish DISPLAY")
local failedPageTimer = timers[#timers]
failPageSend = true
sent, result = AngryEra:SendDisplayPageMessage(failedPageTimer.Argument)
failPageSend = false
assert(not sent and result == "page-send-failed", "async page errors should surface from the timer callback")
assert(preparationCount == preparationBeforeFailure + 1, "failed transport must not prepare the page twice")
assert(calls[callsBeforeFailure + 1].Type == "ACTIVATE", "local activation must precede failed transport")
assert(calls[callsBeforeFailure + 2].Type == "DISPLAY", "DISPLAY should succeed before an async page failure")
assert(calls[callsBeforeFailure + 3].Type == "PAGE_UPSERT", "failed async page transport should be attempted")
assert(
    calls[callsBeforeFailure + 4].Type == "DISPLAY" and calls[callsBeforeFailure + 4].Payload.PageFollows == nil,
    "a failed current page stream should reannounce the tuple without a page promise"
)

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
assert(sent and result == "scheduled", "interactive display changes should be coalesced")
assert(activatedLocally, "a coalesced display should still activate locally immediately")
assert(
    timers[#timers].Method == "SendPendingDisplayControl" and timers[#timers].Delay == 0.125,
    "interactive display control should use the 125 millisecond trailing timer"
)
local scheduledDisplay = timers[#timers]
sent, result, activatedLocally = AngryEra:SendDisplay(5, true)
assert(sent and result == "display-message", "forced display should send immediately")
assert(activatedLocally, "forced display should activate its exact tuple immediately")
assert(canceled[scheduledDisplay], "forced display should cancel its coalesced predecessor")
local forcedDisplayPageTimer = timers[#timers]

local callsBeforeClear = #calls
currentTime = 104
sent, result, activatedLocally = AngryEra:SendDisplayMessage(nil)
assert(sent and result == "display-message", "display clear should send")
assert(activatedLocally, "display clear should report that local volatile state committed")
assert(#calls == callsBeforeClear + 2, "display clear should clear locally and send no page snapshot")
assert(calls[callsBeforeClear + 1].Type == "CLEAR_ACTIVE", "local active reference must clear before transport")
assert(calls[#calls].Type == "DISPLAY" and calls[#calls].Payload.Displayed == false, "clear uses named payload")
assert(canceled[forcedDisplayPageTimer], "display clear should cancel an unsent page snapshot")

local preparationBeforePage = preparationCount
sent, result = AngryEra:SendPageMessage(5)
assert(sent and type(result) == "table", "page publication should return its prepared payload")
assert(preparationCount == preparationBeforePage + 1, "page publication should prepare once")
assert(calls[#calls].Type == "PAGE_UPSERT", "page publication should use protocol v3")

callsBeforeCachedDisplay = #calls
local timersBeforeDisplayAfterPageSend = #timers
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "a directly published page should remain displayable")
assert(#calls == callsBeforeCachedDisplay + 2, "display selection should still activate and send DISPLAY immediately")
assert(
    #timers == timersBeforeDisplayAfterPageSend + 1,
    "a generic queued page send must not suppress the replaceable active-page stream"
)
local displayAfterPageSendTimer = timers[#timers]
sent, result = AngryEra:SendDisplayPageMessage(displayAfterPageSendTimer.Argument)
assert(sent and result == "page-message", "the active-page stream should republish after a generic page send")

do
    pageRevisionIds[5] = "fcs32:12345685"
    pageRevisionIds[6] = "fcs32:22345685"
    local burstCallsStart = #calls
    local burstTimers = {}
    for index = 1, 10 do
        local id = index % 2 == 1 and 5 or 6
        sent, result, activatedLocally = AngryEra:SendDisplay(id)
        assert(
            sent and result == "scheduled" and activatedLocally,
            "every rapid interactive selection should activate locally and schedule publication"
        )
        burstTimers[#burstTimers + 1] = timers[#timers]
    end
    assert(
        #calls == burstCallsStart + 10,
        "ten rapid uncached selections should perform only their ten local activations before the quiet window"
    )
    for index = burstCallsStart + 1, #calls do
        assert(calls[index].Type == "ACTIVATE", "rapid uncached intermediates must not enter transport")
    end
    for index = 1, #burstTimers - 1 do
        assert(canceled[burstTimers[index]], "each replaced display generation should cancel its timer")
        local callsBeforeStaleControl = #calls
        sent, result = AngryEra:SendPendingDisplayControl(burstTimers[index].Argument)
        assert(sent and result == "superseded", "a canceled display generation should be harmless")
        assert(#calls == callsBeforeStaleControl, "a canceled display generation must not send")
    end

    local finalBurstTimer = burstTimers[#burstTimers]
    assert(not canceled[finalBurstTimer], "the final display generation should remain scheduled")
    sent, result = AngryEra:SendPendingDisplayControl(finalBurstTimer.Argument)
    assert(sent and result == "display-message", "the final uncached display generation should publish")
    assert(
        #calls == burstCallsStart + 11
            and calls[#calls].Type == "DISPLAY"
            and calls[#calls].Payload.SyncId == Upsert(6).Page.SyncId
            and calls[#calls].Payload.PageFollows == true,
        "ten uncached toggles should emit exactly one final DISPLAY with a page promise"
    )
    local finalBurstPageTimer = timers[#timers]
    assert(
        finalBurstPageTimer.Method == "SendDisplayPageMessage" and finalBurstPageTimer.Delay == 0,
        "the final page should start on the next timer turn without a second debounce"
    )
    sent, result = AngryEra:SendDisplayPageMessage(finalBurstPageTimer.Argument)
    assert(sent and result == "page-message", "the final uncached page should publish")
    assert(
        calls[#calls].Type == "PAGE_UPSERT" and calls[#calls].Payload.Page.SyncId == Upsert(6).Page.SyncId,
        "only the final page from an uncached burst may enter transport"
    )

    sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
    assert(sent and result == "display-message" and activatedLocally, "cached burst setup should publish page A")
    local cachedPageATimer = timers[#timers]
    sent, result = AngryEra:SendDisplayPageMessage(cachedPageATimer.Argument)
    assert(sent and result == "page-message", "cached burst setup should finish page A")

    burstCallsStart = #calls
    burstTimers = {}
    local timersBeforeCachedBurst = #timers
    for index = 1, 10 do
        local id = index % 2 == 1 and 6 or 5
        sent, result, activatedLocally = AngryEra:SendDisplay(id)
        assert(
            sent and result == "scheduled" and activatedLocally,
            "every cached rapid selection should still activate locally"
        )
        burstTimers[#burstTimers + 1] = timers[#timers]
    end
    assert(#calls == burstCallsStart + 10, "ten cached toggles should remain local until the final control timer")
    for index = 1, #burstTimers - 1 do
        local callsBeforeStaleControl = #calls
        sent, result = AngryEra:SendPendingDisplayControl(burstTimers[index].Argument)
        assert(sent and result == "superseded", "cached stale display generations should be harmless")
        assert(#calls == callsBeforeStaleControl, "cached stale generations must not send")
    end
    sent, result = AngryEra:SendPendingDisplayControl(burstTimers[#burstTimers].Argument)
    assert(sent and result == "display-message", "the final cached generation should publish")
    assert(
        #calls == burstCallsStart + 11
            and calls[#calls].Type == "DISPLAY"
            and calls[#calls].Payload.SyncId == Upsert(5).Page.SyncId
            and calls[#calls].Payload.PageFollows == nil,
        "ten cached toggles should emit exactly one final control and no page promise"
    )
    assert(
        #timers == timersBeforeCachedBurst + 10,
        "a cached burst should allocate only replaceable control timers and no page timer"
    )
end

pageRevisionIds[5] = "fcs32:12345686"
local callsBeforeDisplayScheduleFailure = #calls
failNextTimer = true
sent, result, activatedLocally = AngryEra:SendDisplay(5)
assert(
    sent and result == "display-message" and activatedLocally,
    "display timer allocation failure should fall back to immediate publication"
)
assert(
    #calls == callsBeforeDisplayScheduleFailure + 2
        and calls[callsBeforeDisplayScheduleFailure + 1].Type == "ACTIVATE"
        and calls[callsBeforeDisplayScheduleFailure + 2].Type == "DISPLAY",
    "display timer allocation failure must not report a phantom scheduled send"
)
local fallbackDisplayPageTimer = timers[#timers]
sent, result = AngryEra:SendDisplayPageMessage(fallbackDisplayPageTimer.Argument)
assert(sent and result == "page-message", "the timer-allocation fallback should still publish its final page")

pageRevisionIds[5] = "fcs32:12345687"
sent, result, activatedLocally = AngryEra:SendDisplay(5)
assert(sent and result == "scheduled" and activatedLocally, "authority recheck should queue display control")
local authorityDisplayTimer = timers[#timers]
local callsBeforeDisplayAuthorityRecheck = #calls
canPublishDisplay = false
sent, result = AngryEra:SendPendingDisplayControl(authorityDisplayTimer.Argument)
canPublishDisplay = true
assert(not sent and result == "unauthorized", "a delayed display flush should recheck display authority")
assert(#calls == callsBeforeDisplayAuthorityRecheck, "lost display authority must prevent delayed display transport")

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
local firstDisplayRequestWatchdog = timers[#timers]
assert(
    firstDisplayRequestWatchdog.Method == "RetryDisplayRequest" and firstDisplayRequestWatchdog.Delay == 3,
    "an unanswered display request should schedule a short first retry"
)
local callsBeforeCoalescedDisplayRequest = #calls
local timersBeforeCoalescedDisplayRequest = #timers
sent, result = AngryEra:SendRequestDisplay()
assert(sent and result == "request-message", "same-leader discovery should reuse the unanswered request")
assert(
    #calls == callsBeforeCoalescedDisplayRequest
        and #timers == timersBeforeCoalescedDisplayRequest
        and not canceled[firstDisplayRequestWatchdog],
    "same-leader discovery must not replace its useful request or watchdog"
)
local callsBeforeSuppressedDisplayRequest = #calls
sent, result = AngryEra:SendRequestDisplay(true)
assert(sent and result == "request-message", "explicit recovery should bypass discovery coalescing")
assert(
    #calls == callsBeforeSuppressedDisplayRequest + 1
        and #timers == timersBeforeCoalescedDisplayRequest
        and not canceled[firstDisplayRequestWatchdog],
    "suppressed-watchdog recovery should send explicitly without disturbing discovery"
)
local callsBeforeDisplayRequestRetry = #calls
sent, result = AngryEra:RetryDisplayRequest(firstDisplayRequestWatchdog.Argument)
assert(sent and result == "request-message", "the first unanswered display request should retry")
assert(
    #calls == callsBeforeDisplayRequestRetry + 1
        and calls[#calls].Type == "DISPLAY_REQUEST"
        and calls[#calls].Target == "Leader-Realm",
    "a display-request retry should re-resolve and target the current online leader"
)
local secondDisplayRequestWatchdog = timers[#timers]
assert(
    secondDisplayRequestWatchdog.Method == "RetryDisplayRequest" and secondDisplayRequestWatchdog.Delay == 5,
    "the bounded display-request watchdog should retain a second retry"
)
assert(AngryEra:ResolveDisplayDiscovery(), "an accepted display should resolve discovery state")
assert(canceled[secondDisplayRequestWatchdog], "resolved discovery should cancel its pending retry")
local callsBeforeStaleDisplayRetry = #calls
sent, result = AngryEra:RetryDisplayRequest(secondDisplayRequestWatchdog.Argument)
assert(sent and result == "superseded", "a canceled display retry should be harmless")
assert(#calls == callsBeforeStaleDisplayRetry, "a stale display retry must not send traffic")

sent, result = AngryEra:SendRequestDisplay()
assert(sent and result == "request-message", "receive-policy coverage should start display discovery")
local disabledSharingWatchdog = timers[#timers]
canReceiveDisplay = false
local callsBeforeDisabledSharing = #calls
sent, result = AngryEra:SendRequestDisplay()
assert(not sent and result == "shared-display-disabled", "disabled sharing should reject normal discovery")
assert(
    #calls == callsBeforeDisabledSharing and canceled[disabledSharingWatchdog],
    "disabled sharing should cancel its existing watchdog without sending"
)
sent, result = AngryEra:SendRequestDisplay(true)
assert(not sent and result == "shared-display-disabled", "disabled sharing should reject explicit recovery too")
assert(#calls == callsBeforeDisabledSharing, "disabled sharing must suppress all display-request transport")

canReceiveDisplay = true
sent, result = AngryEra:SendRequestDisplay()
assert(sent and result == "request-message", "reenabled sharing should resume standard discovery")
local disabledRetryWatchdog = timers[#timers]
canReceiveDisplay = false
local callsBeforeDisabledRetry = #calls
sent, result = AngryEra:RetryDisplayRequest(disabledRetryWatchdog.Argument)
assert(not sent and result == "shared-display-disabled", "a mode switch should stop an active discovery retry")
assert(#calls == callsBeforeDisabledRetry, "a disabled retry must not send to the former accepted leader")
sent, result = AngryEra:RetryDisplayRequest(disabledRetryWatchdog.Argument)
assert(sent and result == "superseded", "a stopped disabled retry should remain inert")
canReceiveDisplay = true

sent, result = AngryEra:SendRequestDisplay()
assert(sent and result == "request-message", "bounded retry coverage should start a new display request")
local boundedFirstRetry = timers[#timers]
sent, result = AngryEra:RetryDisplayRequest(boundedFirstRetry.Argument)
assert(sent and result == "request-message", "bounded retry attempt two should send")
local boundedSecondRetry = timers[#timers]
sent, result = AngryEra:RetryDisplayRequest(boundedSecondRetry.Argument)
assert(sent and result == "request-message", "bounded retry attempt three should send")
local boundedFinalRetry = timers[#timers]
assert(boundedFinalRetry.Delay == 13, "the final reserved retry should retain bounded backoff")
local timersBeforeBoundedFinalRetry = #timers
sent, result = AngryEra:RetryDisplayRequest(boundedFinalRetry.Argument)
assert(sent and result == "request-message", "the final bounded retry should send")
assert(#timers == timersBeforeBoundedFinalRetry, "the final display retry must not schedule unbounded work")
local callsAfterDisplayRetryBudget = #calls
sent, result = AngryEra:RetryDisplayRequest(boundedFinalRetry.Argument)
assert(sent and result == "superseded", "an exhausted display retry generation should be inert")
assert(#calls == callsAfterDisplayRetryBudget, "an exhausted display retry must not send again")

currentPlayer = "Leader-Realm"
sent, result = AngryEra:SendRequestDisplay()
assert(not sent and result == "local-player-is-authority", "authority should not whisper a request to itself")

AngryAssign_State.displayed = 5
assert(AngryEra:CaptureDisplayAuthorityRecovery(), "startup should capture a valid saved display page")
AngryAssign_State.displayed = nil
local callsBeforeAuthorityRestore = #calls
local restored, restoreResult, isLocalAuthority = AngryEra:RestoreDisplayAuthority()
assert(
    restored and restoreResult == "display-message" and isLocalAuthority,
    "a promoted leader should restore its anchor"
)
assert(AngryAssign_State.displayed == 5, "authority restore should reinstate the captured displayed page")
assert(
    #calls == callsBeforeAuthorityRestore + 4
        and calls[callsBeforeAuthorityRestore + 1].Type == "ACTIVATE"
        and calls[callsBeforeAuthorityRestore + 2].Type == "DISPLAY"
        and calls[callsBeforeAuthorityRestore + 3].Type == "UPDATE_DISPLAYED"
        and calls[callsBeforeAuthorityRestore + 4].Type == "UPDATE_TREE",
    "authority restore should activate, publish, and redraw the saved page"
)
assert(not AngryEra:DiscardDisplayAuthorityRecovery(), "a successful restore should consume its startup candidate")

currentPlayer = "Publisher-Realm"
grouped = false
sent, result = AngryEra:SendRequestDisplay()
assert(not sent and result == "not-grouped", "solo clients should not request group display state")
grouped = true

assert(AngryEra:GetRaidLeader(true) == "Leader-Realm", "leader lookup should retain group utility behavior")
assert(AngryEra:GetCurrentGroup() == 2, "subgroup lookup should retain display rendering behavior")

local recoveryAuth = {
    Sender = "Leader-Realm",
    SenderInstallationId = "leader-installation",
    SenderSessionId = "leader-session",
}
local recoveryReference = {
    SyncId = "ae3i:1:2:3:4:page:7",
    Revision = 7,
    RevisionId = "fcs32:33333333",
    ContextRevisionId = "fcs32:44444444",
}
local recoveryEnvelope = {
    Type = "DISPLAY",
    MessageId = "leader-installation:leader-session:7",
    Payload = {
        Displayed = true,
        SyncId = recoveryReference.SyncId,
        Revision = recoveryReference.Revision,
        RevisionId = recoveryReference.RevisionId,
        ContextRevisionId = recoveryReference.ContextRevisionId,
    },
}
pendingDisplayRequest = {
    Sender = recoveryAuth.Sender,
    SenderInstallationId = recoveryAuth.SenderInstallationId,
    SenderSessionId = recoveryAuth.SenderSessionId,
    Payload = {
        SyncId = recoveryReference.SyncId,
        Revision = recoveryReference.Revision,
        RevisionId = recoveryReference.RevisionId,
        ContextRevisionId = recoveryReference.ContextRevisionId,
    },
}
local recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(recoveryAuth, recoveryEnvelope, recoveryReference)
assert(recoveryScheduled and recoveryStatus == "scheduled", "missing display recovery should be deferred")
local firstRecoveryTimer = timers[#timers]
assert(
    firstRecoveryTimer.Method == "RecoverPendingDisplay"
        and firstRecoveryTimer.Delay == 30
        and type(firstRecoveryTimer.Argument) == "number",
    "display recovery should retain context for a 30-second fallback"
)
recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(recoveryAuth, recoveryEnvelope, recoveryReference)
assert(recoveryScheduled and recoveryStatus == "scheduled", "a newer pending display should replace the recovery wait")
local replacementRecoveryTimer = timers[#timers]
assert(canceled[firstRecoveryTimer], "replacing a pending display should cancel its older recovery timer")
assert(AngryEra:CancelPendingDisplayRecovery(), "explicit recovery cancellation should report pending work")
assert(canceled[replacementRecoveryTimer], "explicit recovery cancellation should cancel the active timer")
assert(not AngryEra:CancelPendingDisplayRecovery(), "recovery cancellation should be idempotent")

recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(recoveryAuth, recoveryEnvelope, recoveryReference, 1, true)
assert(recoveryScheduled and recoveryStatus == "scheduled", "a queued exact request should retain a retry watchdog")
local requestedPageWatchdog = timers[#timers]
assert(
    requestedPageWatchdog.Method == "RecoverPendingDisplay" and requestedPageWatchdog.Delay == 5,
    "a targeted page request should use the short single-client watchdog"
)
local callsBeforeRequestedPageWatchdog = #calls
sent, result = AngryEra:RecoverPendingDisplay(requestedPageWatchdog.Argument)
assert(sent and result == "request-message", "the first targeted-request watchdog should ask for current display state")
assert(
    #calls == callsBeforeRequestedPageWatchdog + 1 and calls[#calls].Type == "DISPLAY_REQUEST",
    "a queued exact request must not retry a response correlation that the publisher already consumed"
)
assert(AngryEra:CancelPendingDisplayRecovery(), "targeted-request watchdog cleanup should cancel its fallback")

local callsBeforeResolvedRecovery = #calls
pendingDisplayRequest = nil
recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(recoveryAuth, recoveryEnvelope, recoveryReference)
assert(recoveryScheduled and recoveryStatus == "not-needed", "resolved display recovery should not schedule")
sent, result = AngryEra:RecoverPendingDisplay(replacementRecoveryTimer.Argument)
assert(sent and result == "superseded", "a canceled recovery callback should be superseded")
assert(#calls == callsBeforeResolvedRecovery, "resolved display recovery should not use the transport")

pendingDisplayRequest = {
    Sender = recoveryAuth.Sender,
    SenderInstallationId = recoveryAuth.SenderInstallationId,
    SenderSessionId = recoveryAuth.SenderSessionId,
    Payload = {
        SyncId = recoveryReference.SyncId,
        Revision = recoveryReference.Revision,
        RevisionId = recoveryReference.RevisionId,
        ContextRevisionId = recoveryReference.ContextRevisionId,
    },
}
recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(recoveryAuth, recoveryEnvelope, recoveryReference)
assert(recoveryScheduled and recoveryStatus == "scheduled", "exact recovery should schedule")
local exactRecoveryTimer = timers[#timers]
recoveryReference.Revision = 70
recoveryReference.RevisionId = "mutated-reference"
recoveryEnvelope.Payload.Revision = 71
recoveryEnvelope.Payload.RevisionId = "mutated-envelope"
sent, result = AngryEra:RecoverPendingDisplay(exactRecoveryTimer.Argument)
assert(sent and result == "page-request-message", "first recovery should request only the exact missing page")
local exactPageRequest = calls[#calls]
assert(exactPageRequest.Type == "PAGE_REQUEST", "first recovery should use PAGE_REQUEST")
assert(exactPageRequest.Target == recoveryAuth.Sender, "exact recovery should target the authenticated publisher")
assert(
    exactPageRequest.Reference.Revision == 7
        and exactPageRequest.Reference.RevisionId == "fcs32:33333333"
        and exactPageRequest.DisplayEnvelope.Payload.Revision == 7
        and exactPageRequest.DisplayEnvelope.Payload.RevisionId == "fcs32:33333333",
    "recovery should retain detached envelope and reference snapshots"
)
local firstFallbackTimer = timers[#timers]
assert(
    firstFallbackTimer.Method == "RecoverPendingDisplay" and firstFallbackTimer.Delay == 30,
    "exact recovery should schedule a bounded current-display fallback"
)
sent, result = AngryEra:RecoverPendingDisplay(firstFallbackTimer.Argument)
assert(sent and result == "request-message", "second recovery should request the current leader display")
assert(calls[#calls].Type == "DISPLAY_REQUEST", "second recovery should use DISPLAY_REQUEST")
local finalFallbackTimer = timers[#timers]
local timersBeforeFinalFallback = #timers
sent, result = AngryEra:RecoverPendingDisplay(finalFallbackTimer.Argument)
assert(sent and result == "request-message", "final bounded recovery should retry the current display")
assert(calls[#calls].Type == "DISPLAY_REQUEST", "final bounded recovery should use DISPLAY_REQUEST")
assert(#timers == timersBeforeFinalFallback, "the bounded recovery should stop after three attempts")
local callsAfterRecoveryBudget = #calls
sent, result = AngryEra:RecoverPendingDisplay(finalFallbackTimer.Argument)
assert(sent and result == "exhausted", "a completed recovery generation should retain its exhausted state")
assert(#calls == callsAfterRecoveryBudget, "an exhausted recovery must not retry transport")

local exhaustedReference = {
    SyncId = "ae3i:1:2:3:4:page:7",
    Revision = 7,
    RevisionId = "fcs32:33333333",
    ContextRevisionId = "fcs32:44444444",
}
local exhaustedEnvelope = {
    Type = "DISPLAY",
    MessageId = "leader-installation:leader-session:9",
    Payload = {
        Displayed = true,
        SyncId = exhaustedReference.SyncId,
        Revision = exhaustedReference.Revision,
        RevisionId = exhaustedReference.RevisionId,
        ContextRevisionId = exhaustedReference.ContextRevisionId,
    },
}
local timersAfterRecoveryBudget = #timers
recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(recoveryAuth, exhaustedEnvelope, exhaustedReference)
assert(recoveryScheduled and recoveryStatus == "exhausted", "same-tuple DISPLAY should inherit recovery exhaustion")
assert(#timers == timersAfterRecoveryBudget, "same-tuple fallback must not reset the recovery timer budget")
assert(#calls == callsAfterRecoveryBudget, "same-tuple fallback must not issue more transport")

local reloadedRecoveryAuth = {
    Sender = recoveryAuth.Sender,
    SenderInstallationId = recoveryAuth.SenderInstallationId,
    SenderSessionId = "leader-session-reloaded",
}
local reloadedRecoveryEnvelope = {
    Type = "DISPLAY",
    MessageId = "leader-installation:leader-session-reloaded:1",
    Payload = {
        Displayed = true,
        SyncId = exhaustedReference.SyncId,
        Revision = exhaustedReference.Revision,
        RevisionId = exhaustedReference.RevisionId,
        ContextRevisionId = exhaustedReference.ContextRevisionId,
    },
}
pendingDisplayRequest = {
    Sender = reloadedRecoveryAuth.Sender,
    SenderInstallationId = reloadedRecoveryAuth.SenderInstallationId,
    SenderSessionId = reloadedRecoveryAuth.SenderSessionId,
    Payload = {
        SyncId = exhaustedReference.SyncId,
        Revision = exhaustedReference.Revision,
        RevisionId = exhaustedReference.RevisionId,
        ContextRevisionId = exhaustedReference.ContextRevisionId,
    },
}
recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(reloadedRecoveryAuth, reloadedRecoveryEnvelope, exhaustedReference)
assert(recoveryScheduled and recoveryStatus == "scheduled", "a reloaded publisher session gets a fresh recovery budget")
assert(#timers == timersAfterRecoveryBudget + 1, "session rotation should not inherit exhausted recovery attempts")
assert(AngryEra:CancelPendingDisplayRecovery(), "reloaded-session recovery cleanup should cancel its timer")

local formerLeaderAuth = {
    Sender = "Former-Realm",
    SenderInstallationId = "former-installation",
    SenderSessionId = "former-session",
}
local formerLeaderReference = {
    SyncId = "ae3i:1:2:3:4:page:9",
    Revision = 9,
    RevisionId = "fcs32:77777777",
    ContextRevisionId = "fcs32:88888888",
}
local formerLeaderEnvelope = {
    Type = "DISPLAY",
    MessageId = "former-installation:former-session:1",
    Payload = {
        Displayed = true,
        SyncId = formerLeaderReference.SyncId,
        Revision = formerLeaderReference.Revision,
        RevisionId = formerLeaderReference.RevisionId,
        ContextRevisionId = formerLeaderReference.ContextRevisionId,
    },
}
pendingDisplayRequest = {
    Sender = formerLeaderAuth.Sender,
    SenderInstallationId = formerLeaderAuth.SenderInstallationId,
    SenderSessionId = formerLeaderAuth.SenderSessionId,
    Payload = {
        SyncId = formerLeaderReference.SyncId,
        Revision = formerLeaderReference.Revision,
        RevisionId = formerLeaderReference.RevisionId,
        ContextRevisionId = formerLeaderReference.ContextRevisionId,
    },
}
recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(formerLeaderAuth, formerLeaderEnvelope, formerLeaderReference)
assert(recoveryScheduled and recoveryStatus == "scheduled", "a changed-leader recovery should schedule")
local changedLeaderRecoveryTimer = timers[#timers]
local callsBeforeChangedLeaderRecovery = #calls
sent, result = AngryEra:RecoverPendingDisplay(changedLeaderRecoveryTimer.Argument)
assert(sent and result == "request-message", "a former publisher should fall back to the current leader")
assert(#calls == callsBeforeChangedLeaderRecovery + 1, "leader handoff recovery should issue only one request")
assert(
    calls[#calls].Type == "DISPLAY_REQUEST" and calls[#calls].Target == "Leader-Realm",
    "leader handoff recovery should skip PAGE_REQUEST and query the current online leader"
)
local changedLeaderFallbackTimer = timers[#timers]
assert(
    changedLeaderFallbackTimer.Method == "RecoverPendingDisplay" and changedLeaderFallbackTimer.Delay == 30,
    "leader handoff recovery should retain its bounded fallback"
)

recoveryReference = {
    SyncId = "ae3i:1:2:3:4:page:8",
    Revision = 8,
    RevisionId = "fcs32:55555555",
    ContextRevisionId = "fcs32:66666666",
}
recoveryEnvelope = {
    Type = "DISPLAY",
    MessageId = "leader-installation:leader-session:8",
    Payload = {
        Displayed = true,
        SyncId = recoveryReference.SyncId,
        Revision = recoveryReference.Revision,
        RevisionId = recoveryReference.RevisionId,
        ContextRevisionId = recoveryReference.ContextRevisionId,
    },
}
pendingDisplayRequest = {
    Sender = recoveryAuth.Sender,
    SenderInstallationId = recoveryAuth.SenderInstallationId,
    SenderSessionId = recoveryAuth.SenderSessionId,
    Payload = {
        SyncId = recoveryReference.SyncId,
        Revision = recoveryReference.Revision,
        RevisionId = recoveryReference.RevisionId,
        ContextRevisionId = recoveryReference.ContextRevisionId,
    },
}
recoveryScheduled, recoveryStatus =
    AngryEra:DeferPendingDisplayRecovery(recoveryAuth, recoveryEnvelope, recoveryReference)
assert(recoveryScheduled and recoveryStatus == "scheduled", "reset should have a pending recovery timer")
local resetRecoveryTimer = timers[#timers]
assert(canceled[changedLeaderFallbackTimer], "a new tuple should replace the former leader fallback")

pageRevisionIds[5] = "fcs32:12345684"
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "reset should have a pending display page")
local resetDisplayPageTimer = timers[#timers]

sent, result = AngryEra:SendPageMessage(6)
assert(sent and type(result) == "table", "reset should seed page throttling state")
sent, result = AngryEra:SendPage(6)
assert(sent and result == "scheduled", "reset should have a pending page timer")
local resetPageTimer = timers[#timers]

sent, result, activatedLocally = AngryEra:SendDisplay(5)
assert(sent and result == "scheduled" and activatedLocally, "reset should have a pending display timer")
local resetDisplayTimer = timers[#timers]

sent, result = AngryEra:SendRequestDisplay()
assert(sent and result == "request-message", "reset should have an unanswered display request")
local resetDisplayRequestWatchdog = timers[#timers]

AngryEra:ResetDisplayPublicationState()
assert(canceled[resetRecoveryTimer], "publication reset should cancel pending recovery")
assert(canceled[resetDisplayPageTimer], "publication reset should cancel the debounced display page")
assert(canceled[resetPageTimer], "publication reset should cancel page throttling")
assert(canceled[resetDisplayTimer], "publication reset should cancel display throttling")
assert(canceled[resetDisplayRequestWatchdog], "publication reset should cancel display discovery retries")
local callsBeforeStaleResetDisplay = #calls
sent, result = AngryEra:SendPendingDisplayControl(resetDisplayTimer.Argument)
assert(sent and result == "superseded", "a reset display callback should be harmless")
assert(#calls == callsBeforeStaleResetDisplay, "a reset display callback must not publish")

local timersBeforeResetDisplay = #timers
callsBeforeCachedDisplay = #calls
sent, result, activatedLocally = AngryEra:SendDisplayMessage(6)
assert(sent and result == "display-message" and activatedLocally, "display should publish after a session reset")
assert(#calls == callsBeforeCachedDisplay + 2, "reset display should send DISPLAY before its snapshot")
assert(#timers == timersBeforeResetDisplay + 1, "session reset should clear the exact page tuple cache")
assert(calls[#calls].Payload.PageFollows == true, "a reset tuple cache should restore the proactive page promise")
local postResetPageTimer = timers[#timers]
sent, result = AngryEra:SendDisplayPageMessage(postResetPageTimer.Argument)
assert(sent and result == "page-message", "the reset display should resend its page snapshot")
assert(calls[#calls].Type == "PAGE_UPSERT", "reset should require a fresh page publication")

sent, result = AngryEra:SendRequestDisplay()
assert(sent and result == "request-message", "authority reset coverage should start display discovery")
local authorityPreservedRequestWatchdog = timers[#timers]
sent, result, activatedLocally = AngryEra:SendDisplay(5)
assert(sent and result == "scheduled" and activatedLocally, "authority reset should have pending publication work")
local authorityResetDisplayTimer = timers[#timers]
AngryEra:ResetDisplayAuthorityPublicationState("test-authority-change")
assert(canceled[authorityResetDisplayTimer], "authority reset should cancel stale display publication")
assert(
    not canceled[authorityPreservedRequestWatchdog],
    "authority reset must preserve unanswered display discovery across leader handoff"
)
local callsBeforeAuthorityPreservedRetry = #calls
sent, result = AngryEra:RetryDisplayRequest(authorityPreservedRequestWatchdog.Argument)
assert(sent and result == "request-message", "preserved discovery should retain its bounded retry")
assert(
    #calls == callsBeforeAuthorityPreservedRetry + 1 and calls[#calls].Type == "DISPLAY_REQUEST",
    "the preserved discovery retry should still query the current online leader"
)
local authorityPreservedRetry = timers[#timers]
assert(AngryEra:CancelDisplayRequestWatchdog(), "authority-reset discovery cleanup should find the live retry")
assert(canceled[authorityPreservedRetry], "authority-reset discovery cleanup should cancel its retry timer")

completeActiveTransfersImmediately = false
sent, result, activatedLocally = AngryEra:SendDisplayMessage(5)
assert(sent and result == "display-message" and activatedLocally, "authority reset should seed an active page stream")
local authorityActivePageTimer = timers[#timers]
sent, result = AngryEra:SendDisplayPageMessage(authorityActivePageTimer.Argument)
assert(sent and result == "page-message" and activePageTransfer, "authority reset should see the active transfer")
local canceledTransfersBeforeAuthorityReset = canceledActiveTransfers
local callsBeforeActiveAuthorityReset = #calls
AngryEra:ResetDisplayAuthorityPublicationState("test-authority-change")
assert(
    canceledActiveTransfers == canceledTransfersBeforeAuthorityReset + 1 and activePageTransfer == nil,
    "authority reset should stop an active page transfer"
)
assert(
    #calls == callsBeforeActiveAuthorityReset,
    "canceling an authority-owned transfer must not reannounce stale DISPLAY control"
)
completeActiveTransfersImmediately = true
pendingDisplayRequest = nil

do
    currentPlayer = "Publisher-Realm"
    canPublishDisplay = false
    canPublishPage = false
    canPublishChangeProposal = true
    AngryAssign_State.displayed = 5
    AngryAssign_Pages[5].SyncId = "ae3i:5:6:7:8:page:5"
    AngryAssign_Pages[5].Revision = 1
    AngryAssign_Pages[5].RevisionId = "fcs32:31000001"
    activeDisplayReference = {
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = AngryAssign_Pages[5].Revision,
        RevisionId = AngryAssign_Pages[5].RevisionId,
        ContextRevisionId = "fcs32:41000001",
    }

    local function Draft(contents, name)
        return {
            LocalId = 5,
            SyncId = AngryAssign_Pages[5].SyncId,
            BaseRevision = AngryAssign_Pages[5].Revision,
            BaseRevisionId = activeDisplayReference.RevisionId,
            BaseContextRevisionId = activeDisplayReference.ContextRevisionId,
            Desired = {
                Name = name or "Assignments",
                Vars = "",
                Contents = contents,
            },
            ChangedField = "Contents",
        }
    end

    local submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("First"))
    assert(submitted and submitStatus == "scheduled", "a shared edit should enter the trailing debounce")
    local firstProposalTimer = timers[#timers]
    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Latest"))
    assert(submitted and submitStatus == "scheduled", "a newer draft should replace the debounce")
    local latestProposalTimer = timers[#timers]
    assert(canceled[firstProposalTimer], "a newer desired state should cancel the prior proposal timer")
    local sentBeforeStaleProposal = #sentChangeProposals
    sent, result = AngryEra:FlushSharedPageChangeProposal(firstProposalTimer.Argument)
    assert(sent and result == "superseded", "a replaced proposal generation should be inert")
    assert(#sentChangeProposals == sentBeforeStaleProposal, "a stale proposal must not send")
    sent, result = AngryEra:FlushSharedPageChangeProposal(latestProposalTimer.Argument)
    assert(sent and result == "change-message-1", "the final desired state should send once")
    assert(
        #sentChangeProposals == 1
            and sentChangeProposals[1].Target == "Leader-Realm"
            and sentChangeProposals[1].Payload.Contents == "Latest",
        "proposal debounce should whisper only the newest full desired state"
    )

    local appliedResult = {
        Status = "applied",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = 2,
        RevisionId = "fcs32:31000002",
        ContextRevisionId = "fcs32:41000002",
    }
    sent, result =
        AngryEra:HandleSharedPageChangeResult(nil, appliedResult, sentChangeProposals[1].Payload, "change-message-1")
    assert(sent and result == "awaiting-canonical-page", "result-before-page should wait for canonical storage")
    local resultFirstCommitTimer = timers[#timers]
    assert(
        resultFirstCommitTimer.Method == "SharedPageChangeCommitTimedOut",
        "an accepted result should install a bounded canonical-page watchdog"
    )

    AngryAssign_Pages[5].Revision = appliedResult.Revision
    AngryAssign_Pages[5].RevisionId = appliedResult.RevisionId
    AngryAssign_Pages[5].Name = "Assignments"
    AngryAssign_Pages[5].Vars = ""
    AngryAssign_Pages[5].Contents = "Latest"
    activeDisplayReference.Revision = appliedResult.Revision
    activeDisplayReference.RevisionId = appliedResult.RevisionId
    activeDisplayReference.ContextRevisionId = appliedResult.ContextRevisionId
    local canceledCorrelationsBeforeResultFirstPage = #canceledProtocolChangeProposals
    sent, result = AngryEra:ObserveSharedPageCanonicalUpdate(nil, {
        Page = {
            SyncId = appliedResult.SyncId,
            Revision = appliedResult.Revision,
            RevisionId = appliedResult.RevisionId,
            Name = "Assignments",
            Vars = "",
            Contents = "Latest",
        },
        ContextRevisionId = appliedResult.ContextRevisionId,
    }, {
        Applied = true,
        LocalId = 5,
        SyncId = appliedResult.SyncId,
    })
    assert(sent and result == "completed", "the later matching page should complete the accepted draft")
    assert(canceled[resultFirstCommitTimer], "canonical arrival should cancel the result-first watchdog")
    assert(
        #canceledProtocolChangeProposals == canceledCorrelationsBeforeResultFirstPage + 1
            and canceledProtocolChangeProposals[#canceledProtocolChangeProposals] == "change-message-1",
        "result-first completion should safely forget its protocol correlation"
    )
    assert(clearedSharedPageDrafts == 1, "completed canonical storage should clear the editor draft")
    assert(clearedSyncDraftConflicts == 1, "completed own proposal should clear its dirty-editor conflict")
    assert(
        calls[#calls].Type == "UPDATE_SELECTED" and calls[#calls].Destructive == false,
        "proposal completion should refresh clean controls without clobbering newer unsaved editor text"
    )

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Page first"))
    assert(submitted and submitStatus == "scheduled", "a second proposal should schedule")
    local pageFirstProposalTimer = timers[#timers]
    sent, result = AngryEra:FlushSharedPageChangeProposal(pageFirstProposalTimer.Argument)
    assert(sent and result == "change-message-2", "the second proposal should enter flight")
    local pageFirstResultWatchdog = timers[#timers]
    assert(
        pageFirstResultWatchdog.Method == "SharedPageChangeTimedOut",
        "an in-flight proposal should retain its result watchdog"
    )
    AngryEra:ResetDisplayAuthorityPublicationState("test-authority-change")
    assert(
        not canceled[pageFirstResultWatchdog],
        "an authority-only publication reset must preserve an assistant proposal watchdog"
    )

    local mismatchedCanonical = {
        Status = "applied",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = 3,
        RevisionId = "fcs32:31000003",
        ContextRevisionId = "fcs32:41000003",
    }
    AngryAssign_Pages[5].Revision = mismatchedCanonical.Revision
    AngryAssign_Pages[5].RevisionId = mismatchedCanonical.RevisionId
    AngryAssign_Pages[5].Name = "Assignments"
    AngryAssign_Pages[5].Vars = ""
    AngryAssign_Pages[5].Contents = "Different canonical contents"
    activeDisplayReference.Revision = mismatchedCanonical.Revision
    activeDisplayReference.RevisionId = mismatchedCanonical.RevisionId
    activeDisplayReference.ContextRevisionId = mismatchedCanonical.ContextRevisionId
    local canceledCorrelationsBeforePageAck = #canceledProtocolChangeProposals
    sent, result = AngryEra:ObserveSharedPageCanonicalUpdate(nil, {
        Page = {
            SyncId = mismatchedCanonical.SyncId,
            Revision = mismatchedCanonical.Revision,
            RevisionId = mismatchedCanonical.RevisionId,
            Name = "Assignments",
            Vars = "",
            Contents = "Different canonical contents",
        },
        ContextRevisionId = mismatchedCanonical.ContextRevisionId,
    }, {
        Applied = true,
        LocalId = 5,
        SyncId = mismatchedCanonical.SyncId,
    })
    assert(sent and result == "observed", "non-matching canonical content must not acknowledge the proposal")
    assert(not canceled[pageFirstResultWatchdog], "field mismatch must retain the proposal result watchdog")
    assert(
        #canceledProtocolChangeProposals == canceledCorrelationsBeforePageAck,
        "field mismatch must retain the protocol result correlation"
    )
    assert(clearedSharedPageDrafts == 1, "field mismatch must retain the editor draft")

    sent, result = AngryEra:ObserveSharedPageCanonicalUpdate(nil, {
        Page = {
            SyncId = mismatchedCanonical.SyncId,
            Revision = appliedResult.Revision,
            RevisionId = appliedResult.RevisionId,
            Name = "Assignments",
            Vars = "",
            Contents = "Page first",
        },
        ContextRevisionId = appliedResult.ContextRevisionId,
    }, {
        Applied = false,
        ContextOnly = true,
        LocalId = 5,
        SyncId = mismatchedCanonical.SyncId,
    })
    assert(sent and result == "observed", "context-only rollback must not acknowledge matching wire content")
    assert(not canceled[pageFirstResultWatchdog], "context-only rollback must retain the result watchdog")
    assert(
        #canceledProtocolChangeProposals == canceledCorrelationsBeforePageAck,
        "context-only rollback must retain protocol correlation"
    )
    assert(
        AngryAssign_Pages[5].Contents == "Different canonical contents" and clearedSharedPageDrafts == 1,
        "context-only rollback must leave the differing current canonical page and editor draft intact"
    )

    local pageFirstResult = {
        Status = "applied",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = 4,
        RevisionId = "fcs32:31000004",
        ContextRevisionId = "fcs32:41000004",
    }
    AngryAssign_Pages[5].Revision = pageFirstResult.Revision
    AngryAssign_Pages[5].RevisionId = pageFirstResult.RevisionId
    AngryAssign_Pages[5].Name = "Assignments"
    AngryAssign_Pages[5].Vars = ""
    AngryAssign_Pages[5].Contents = "Page first"
    activeDisplayReference.Revision = pageFirstResult.Revision
    activeDisplayReference.RevisionId = pageFirstResult.RevisionId
    activeDisplayReference.ContextRevisionId = pageFirstResult.ContextRevisionId
    sent, result = AngryEra:ObserveSharedPageCanonicalUpdate(nil, {
        Page = {
            SyncId = pageFirstResult.SyncId,
            Revision = pageFirstResult.Revision,
            RevisionId = pageFirstResult.RevisionId,
            Name = "Assignments",
            Vars = "",
            Contents = "Page first",
        },
        ContextRevisionId = pageFirstResult.ContextRevisionId,
    }, {
        Applied = true,
        LocalId = 5,
        SyncId = pageFirstResult.SyncId,
    })
    assert(sent and result == "completed", "matching canonical content should acknowledge before CHANGE_RESULT")
    assert(canceled[pageFirstResultWatchdog], "page-first acknowledgement should cancel the result watchdog")
    assert(
        #canceledProtocolChangeProposals == canceledCorrelationsBeforePageAck + 1
            and canceledProtocolChangeProposals[#canceledProtocolChangeProposals] == "change-message-2",
        "page-first acknowledgement should forget its protocol correlation immediately"
    )
    assert(clearedSharedPageDrafts == 2, "page-first acknowledgement should clear its editor draft")
    sent, result =
        AngryEra:HandleSharedPageChangeResult(nil, pageFirstResult, sentChangeProposals[2].Payload, "change-message-2")
    assert(not sent and result == "stale-change-result", "a delayed or lost page-first result must be inert")
    assert(clearedSharedPageDrafts == 2, "a delayed result must not clear the draft twice")

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Conflicting draft"))
    assert(submitted and submitStatus == "scheduled", "a conflict candidate should schedule")
    local conflictProposalTimer = timers[#timers]
    sent, result = AngryEra:FlushSharedPageChangeProposal(conflictProposalTimer.Argument)
    assert(sent and result == "change-message-3", "the conflict candidate should enter flight")
    local callsBeforeCurrentConflict = #calls
    sent, result = AngryEra:HandleSharedPageChangeResult(nil, {
        Status = "conflict",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = AngryAssign_Pages[5].Revision,
        RevisionId = AngryAssign_Pages[5].RevisionId,
        ContextRevisionId = activeDisplayReference.ContextRevisionId,
    }, sentChangeProposals[3].Payload, "change-message-3")
    assert(sent and result == "conflict", "a semantic conflict should be handled without canonical mutation")
    assert(
        AngryEra.syncDraftConflict
            and AngryEra.syncDraftConflict.Status == "conflict"
            and AngryEra.syncDraftConflict.Desired.Contents == "Conflicting draft",
        "a rejected proposal should retain the exact desired draft"
    )
    assert(clearedSharedPageDrafts == 2, "a conflict must not clear user text")
    assert(
        #calls == callsBeforeCurrentConflict + 1
            and calls[#calls].Type == "UPDATE_SELECTED"
            and calls[#calls].Destructive == false,
        "a current conflict should refresh controls non-destructively without requesting redundant state"
    )

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Stale conflict draft"))
    assert(submitted and submitStatus == "scheduled", "a stale conflict candidate should schedule")
    local staleConflictProposalTimer = timers[#timers]
    sent, result = AngryEra:FlushSharedPageChangeProposal(staleConflictProposalTimer.Argument)
    assert(sent, "the stale conflict candidate should enter flight")
    local staleConflictMessageId = result
    local staleConflictPayload = sentChangeProposals[#sentChangeProposals].Payload
    local callsBeforeStaleConflict = #calls
    sent, result = AngryEra:HandleSharedPageChangeResult(nil, {
        Status = "conflict",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = AngryAssign_Pages[5].Revision + 1,
        RevisionId = "fcs32:31000005",
        ContextRevisionId = "fcs32:41000005",
    }, staleConflictPayload, staleConflictMessageId)
    assert(sent and result == "conflict", "a stale semantic conflict should retain the desired draft")
    assert(
        AngryEra.syncDraftConflict and AngryEra.syncDraftConflict.Desired.Contents == "Stale conflict draft",
        "stale-conflict recovery must not discard the local desired state"
    )
    assert(
        #calls == callsBeforeStaleConflict + 2
            and calls[callsBeforeStaleConflict + 1].Type == "UPDATE_SELECTED"
            and calls[callsBeforeStaleConflict + 1].Destructive == false
            and calls[callsBeforeStaleConflict + 2].Type == "DISPLAY_REQUEST",
        "a stale conflict should refresh non-destructively and request the current canonical display"
    )
    local staleConflictRecoveryWatchdog = timers[#timers]

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Busy draft"))
    assert(submitted and submitStatus == "scheduled", "a busy candidate should schedule")
    local busyProposalTimer = timers[#timers]
    sent, result = AngryEra:FlushSharedPageChangeProposal(busyProposalTimer.Argument)
    assert(sent, "the busy candidate should enter flight")
    local busyMessageId = result
    local busyPayload = sentChangeProposals[#sentChangeProposals].Payload
    local callsBeforeBusy = #calls
    sent, result = AngryEra:HandleSharedPageChangeResult(nil, {
        Status = "busy",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = AngryAssign_Pages[5].Revision,
        RevisionId = AngryAssign_Pages[5].RevisionId,
        ContextRevisionId = activeDisplayReference.ContextRevisionId,
    }, busyPayload, busyMessageId)
    assert(sent and result == "busy", "a busy result should retain the proposal")
    assert(
        #calls == callsBeforeBusy + 1 and calls[#calls].Type == "UPDATE_SELECTED" and calls[#calls].Destructive == false,
        "a current busy result should refresh controls without a redundant display request"
    )

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Unavailable draft"))
    assert(submitted and submitStatus == "scheduled", "an unavailable candidate should schedule")
    local unavailableProposalTimer = timers[#timers]
    sent, result = AngryEra:FlushSharedPageChangeProposal(unavailableProposalTimer.Argument)
    assert(sent, "the unavailable candidate should enter flight")
    local unavailableMessageId = result
    local unavailablePayload = sentChangeProposals[#sentChangeProposals].Payload
    local callsBeforeUnavailable = #calls
    sent, result = AngryEra:HandleSharedPageChangeResult(nil, {
        Status = "unavailable",
        SyncId = AngryAssign_Pages[5].SyncId,
    }, unavailablePayload, unavailableMessageId)
    assert(sent and result == "unavailable", "an unavailable result should retain the proposal")
    assert(
        #calls == callsBeforeUnavailable + 1
            and calls[callsBeforeUnavailable + 1].Type == "UPDATE_SELECTED"
            and calls[callsBeforeUnavailable + 1].Destructive == false,
        "an unavailable result should retain the draft and reuse existing same-leader canonical recovery"
    )
    local unavailableRecoveryWatchdog = staleConflictRecoveryWatchdog
    assert(
        unavailableRecoveryWatchdog.Method == "RetryDisplayRequest" and not canceled[unavailableRecoveryWatchdog],
        "unavailable recovery should remain bounded when no follow-up display arrives"
    )
    local callsBeforeUnavailableRetry = #calls
    sent, result = AngryEra:RetryDisplayRequest(unavailableRecoveryWatchdog.Argument)
    assert(sent and result == "request-message", "missing unavailable recovery should use the bounded retry path")
    assert(
        #calls == callsBeforeUnavailableRetry + 1 and calls[#calls].Type == "DISPLAY_REQUEST",
        "the bounded unavailable retry should re-query the current leader once"
    )

    AngryEra:CancelDisplayRequestWatchdog()
    AngryEra:ResetSharedPageChangeState("test-cleanup")
    canPublishDisplay = true
    canPublishPage = true
end

do
    currentPlayer = "Publisher-Realm"
    canPublishDisplay = false
    canPublishPage = false
    canPublishChangeProposal = true
    AngryAssign_State.displayed = 5
    AngryAssign_Pages[5].SyncId = "ae3i:5:6:7:8:page:5"
    AngryAssign_Pages[5].Revision = 3
    AngryAssign_Pages[5].RevisionId = "fcs32:31000003"
    activeDisplayReference = {
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = AngryAssign_Pages[5].Revision,
        RevisionId = AngryAssign_Pages[5].RevisionId,
        ContextRevisionId = "fcs32:41000003",
    }

    local function Draft(contents, name)
        return {
            LocalId = 5,
            SyncId = AngryAssign_Pages[5].SyncId,
            BaseRevision = AngryAssign_Pages[5].Revision,
            BaseRevisionId = activeDisplayReference.RevisionId,
            BaseContextRevisionId = activeDisplayReference.ContextRevisionId,
            Desired = {
                Name = name or "Assignments",
                Vars = "",
                Contents = contents,
            },
            ChangedField = "Contents",
        }
    end

    local function ApplyReference(reference)
        AngryAssign_Pages[5].Revision = reference.Revision
        AngryAssign_Pages[5].RevisionId = reference.RevisionId
        activeDisplayReference.Revision = reference.Revision
        activeDisplayReference.RevisionId = reference.RevisionId
        activeDisplayReference.ContextRevisionId = reference.ContextRevisionId
    end

    local submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("First generation"))
    assert(submitted and submitStatus == "scheduled", "the first queued-rebase generation should schedule")
    local firstGenerationTimer = timers[#timers]
    local proposalSent, messageId = AngryEra:FlushSharedPageChangeProposal(firstGenerationTimer.Argument)
    assert(proposalSent, "the first queued-rebase generation should enter flight")
    local firstGenerationMessageId = messageId
    local firstGenerationPayload = sentChangeProposals[#sentChangeProposals].Payload
    local firstGenerationResultWatchdog = timers[#timers]

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Latest generation", "Latest name"))
    assert(submitted and submitStatus == "queued", "one in-flight proposal should retain only the newest desired state")

    local firstGenerationResult = {
        Status = "applied",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = 4,
        RevisionId = "fcs32:31000004",
        ContextRevisionId = "fcs32:41000004",
    }
    ApplyReference(firstGenerationResult)
    AngryAssign_Pages[5].Name = "Assignments"
    AngryAssign_Pages[5].Vars = ""
    AngryAssign_Pages[5].Contents = "First generation"
    local rebasesBeforePageAck = #rebasedSharedPageDrafts
    local canceledCorrelationsBeforeQueuedAck = #canceledProtocolChangeProposals
    sent, result = AngryEra:ObserveSharedPageCanonicalUpdate(nil, {
        Page = {
            SyncId = firstGenerationResult.SyncId,
            Revision = firstGenerationResult.Revision,
            RevisionId = firstGenerationResult.RevisionId,
            Name = "Assignments",
            Vars = "",
            Contents = "First generation",
        },
        ContextRevisionId = firstGenerationResult.ContextRevisionId,
    }, {
        Applied = true,
        LocalId = 5,
        SyncId = firstGenerationResult.SyncId,
    })
    assert(
        sent and result == "scheduled",
        "matching page-first acknowledgement should immediately schedule the queued desired state"
    )
    assert(
        canceled[firstGenerationResultWatchdog],
        "queued page-first acknowledgement should cancel the older result watchdog"
    )
    assert(
        #canceledProtocolChangeProposals == canceledCorrelationsBeforeQueuedAck + 1
            and canceledProtocolChangeProposals[#canceledProtocolChangeProposals] == firstGenerationMessageId,
        "queued page-first acknowledgement should forget the older result correlation"
    )
    assert(
        #rebasedSharedPageDrafts == rebasesBeforePageAck + 1
            and rebasedSharedPageDrafts[#rebasedSharedPageDrafts].Reference.Revision == 4
            and rebasedSharedPageDrafts[#rebasedSharedPageDrafts].Desired.Name == "Latest name"
            and rebasedSharedPageDrafts[#rebasedSharedPageDrafts].Desired.Contents == "Latest generation",
        "queued content and name edits should rebase together without waiting for CHANGE_RESULT"
    )
    local rebasedGenerationTimer = timers[#timers]
    assert(
        rebasedGenerationTimer.Method == "FlushSharedPageChangeProposal",
        "a successful queued rebase must leave a live debounce instead of stalling"
    )
    sent, result = AngryEra:HandleSharedPageChangeResult(
        nil,
        firstGenerationResult,
        firstGenerationPayload,
        firstGenerationMessageId
    )
    assert(
        not sent and result == "stale-change-result",
        "a delayed result for the acknowledged generation must not disrupt its queued successor"
    )
    sent, messageId = AngryEra:FlushSharedPageChangeProposal(rebasedGenerationTimer.Argument)
    assert(
        sent
            and sentChangeProposals[#sentChangeProposals].Payload.BaseRevision == 4
            and sentChangeProposals[#sentChangeProposals].Payload.Name == "Latest name"
            and sentChangeProposals[#sentChangeProposals].Payload.Contents == "Latest generation",
        "the rebased generation should send its complete newest desired state from the new base"
    )

    local rebasedGenerationResult = {
        Status = "applied",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = 5,
        RevisionId = "fcs32:31000005",
        ContextRevisionId = "fcs32:41000005",
    }
    sent, result = AngryEra:HandleSharedPageChangeResult(
        nil,
        rebasedGenerationResult,
        sentChangeProposals[#sentChangeProposals].Payload,
        messageId
    )
    assert(sent and result == "awaiting-canonical-page", "the rebased generation should wait for canonical storage")
    ApplyReference(rebasedGenerationResult)
    AngryAssign_Pages[5].Name = "Latest name"
    AngryAssign_Pages[5].Vars = ""
    AngryAssign_Pages[5].Contents = "Latest generation"
    sent, result = AngryEra:ObserveSharedPageCanonicalUpdate(nil, {
        Page = {
            SyncId = rebasedGenerationResult.SyncId,
            Revision = rebasedGenerationResult.Revision,
            RevisionId = rebasedGenerationResult.RevisionId,
            Name = "Latest name",
            Vars = "",
            Contents = "Latest generation",
        },
        ContextRevisionId = rebasedGenerationResult.ContextRevisionId,
    }, {
        Applied = true,
        LocalId = 5,
        SyncId = rebasedGenerationResult.SyncId,
    })
    assert(sent and result == "completed", "the rebased generation should complete normally")

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Reordered canonical evidence"))
    assert(submitted and submitStatus == "scheduled", "the reordered-evidence proposal should schedule")
    local reorderedTimer = timers[#timers]
    sent, messageId = AngryEra:FlushSharedPageChangeProposal(reorderedTimer.Argument)
    assert(sent, "the reordered-evidence proposal should enter flight")
    local reorderedResult = {
        Status = "applied",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = 6,
        RevisionId = "fcs32:31000006",
        ContextRevisionId = "fcs32:41000006",
    }
    ApplyReference(reorderedResult)
    AngryAssign_Pages[5].Name = "Assignments"
    AngryAssign_Pages[5].Vars = ""
    AngryAssign_Pages[5].Contents = "Reordered canonical evidence"
    sent, result = AngryEra:ObserveSharedPageCanonicalUpdate(nil, {
        Page = {
            SyncId = reorderedResult.SyncId,
            Revision = reorderedResult.Revision,
            RevisionId = reorderedResult.RevisionId,
            Name = "Assignments",
            Vars = "",
            Contents = "Reordered canonical evidence",
        },
        ContextRevisionId = reorderedResult.ContextRevisionId,
    }, {
        Applied = true,
        LocalId = 5,
        SyncId = reorderedResult.SyncId,
    })
    assert(sent and result == "completed", "matching canonical evidence should complete before its delayed result")
    local newerCanonical = {
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = 7,
        RevisionId = "fcs32:31000007",
        ContextRevisionId = "fcs32:41000007",
    }
    ApplyReference(newerCanonical)
    AngryAssign_Pages[5].Contents = "Newer canonical state"
    sent, result = AngryEra:ObserveSharedPageCanonicalUpdate(nil, {
        Page = {
            SyncId = newerCanonical.SyncId,
            Revision = newerCanonical.Revision,
            RevisionId = newerCanonical.RevisionId,
            Name = "Assignments",
            Vars = "",
            Contents = "Newer canonical state",
        },
        ContextRevisionId = newerCanonical.ContextRevisionId,
    }, {
        Applied = true,
        LocalId = 5,
        SyncId = newerCanonical.SyncId,
    })
    assert(not sent and result == "unrelated", "newer canonical state must not revive a completed draft")
    sent, result = AngryEra:HandleSharedPageChangeResult(
        nil,
        reorderedResult,
        sentChangeProposals[#sentChangeProposals].Payload,
        messageId
    )
    assert(
        not sent and result == "stale-change-result",
        "a delayed result must not revive a proposal already acknowledged by canonical storage"
    )

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Commit timeout draft"))
    assert(submitted and submitStatus == "scheduled", "the commit-timeout proposal should schedule")
    local commitTimeoutProposalTimer = timers[#timers]
    sent, messageId = AngryEra:FlushSharedPageChangeProposal(commitTimeoutProposalTimer.Argument)
    assert(sent, "the commit-timeout proposal should enter flight")
    local missingCanonicalResult = {
        Status = "applied",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = 8,
        RevisionId = "fcs32:31000008",
        ContextRevisionId = "fcs32:41000008",
    }
    sent, result = AngryEra:HandleSharedPageChangeResult(
        nil,
        missingCanonicalResult,
        sentChangeProposals[#sentChangeProposals].Payload,
        messageId
    )
    assert(sent and result == "awaiting-canonical-page", "missing canonical storage should arm the commit timeout")
    sent, result = AngryEra:SharedPageChangeCommitTimedOut(messageId)
    assert(not sent and result == "canonical-page-timeout", "the commit timeout should become an explicit conflict")
    assert(
        AngryEra.syncDraftConflict
            and AngryEra.syncDraftConflict.Reason == "canonical-page-timeout"
            and AngryEra.syncDraftConflict.Desired.Contents == "Commit timeout draft",
        "the commit timeout should retain the exact latest desired state"
    )
    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("After commit timeout"))
    assert(
        submitted and submitStatus == "scheduled",
        "a canonical-page timeout must clear in-flight state so a later edit cannot remain queued forever"
    )
    assert(AngryEra:CancelSharedPageChangeProposal("test-cleanup"), "the post-timeout debounce should be cancelable")

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Result timeout draft"))
    assert(submitted and submitStatus == "scheduled", "the result-timeout proposal should schedule")
    local resultTimeoutProposalTimer = timers[#timers]
    sent, messageId = AngryEra:FlushSharedPageChangeProposal(resultTimeoutProposalTimer.Argument)
    assert(sent, "the result-timeout proposal should enter flight")
    local canceledCorrelationsBeforeTimeout = #canceledProtocolChangeProposals
    sent, result = AngryEra:SharedPageChangeTimedOut(messageId)
    assert(not sent and result == "change-result-timeout", "the result timeout should become an explicit conflict")
    assert(
        #canceledProtocolChangeProposals == canceledCorrelationsBeforeTimeout + 1
            and canceledProtocolChangeProposals[#canceledProtocolChangeProposals] == messageId,
        "a result timeout should forget its now-stale protocol correlation"
    )
    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("After result timeout"))
    assert(
        submitted and submitStatus == "scheduled",
        "a result timeout must clear in-flight state so a later edit schedules normally"
    )
    assert(AngryEra:CancelSharedPageChangeProposal("test-cleanup"), "the post-result-timeout debounce should cancel")

    AngryAssign_Pages[5].Revision = 6
    AngryAssign_Pages[5].RevisionId = "fcs32:31000006"
    AngryAssign_Pages[5].Name = "Assignments"
    AngryAssign_Pages[5].Vars = nil
    AngryAssign_Pages[5].Contents = "Nil vars canonical"
    activeDisplayReference.Revision = 6
    activeDisplayReference.RevisionId = "fcs32:31000006"
    activeDisplayReference.ContextRevisionId = "fcs32:41000006"

    submitted, submitStatus = AngryEra:SubmitSharedPageChangeProposal(Draft("Nil vars canonical"))
    assert(submitted and submitStatus == "scheduled", "a no-op save of a nil-vars page should schedule")
    local nilVarsProposalTimer = timers[#timers]
    sent, result = AngryEra:FlushSharedPageChangeProposal(nilVarsProposalTimer.Argument)
    assert(sent, "the nil-vars proposal should enter flight")
    local nilVarsMessageId = result
    sent, result = AngryEra:HandleSharedPageChangeResult(nil, {
        Status = "unchanged",
        SyncId = AngryAssign_Pages[5].SyncId,
        Revision = AngryAssign_Pages[5].Revision,
        RevisionId = AngryAssign_Pages[5].RevisionId,
        ContextRevisionId = activeDisplayReference.ContextRevisionId,
    }, sentChangeProposals[#sentChangeProposals].Payload, nilVarsMessageId)
    assert(
        sent and result == "completed",
        "an unchanged result must complete against stored nil text fields via wire defaulting"
    )

    AngryEra:ResetSharedPageChangeState("test-cleanup")
    canPublishDisplay = true
    canPublishPage = true
end

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
