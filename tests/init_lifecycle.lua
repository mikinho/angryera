local calls = {}
local restoreAsAuthority = false
local isRaidLeader = false
local tenureLocalAuthority = false
local tenureRotationCount = 0
local protocolDisplayAuthority
local refreshPendingDisplayBootstrap = false
local requestDisplaySucceeds = true
local requestDisplayError = "request-failed"
local versionQuerySucceeds = true
local authorityReceiveAllowed = true

local function Record(name, value)
    calls[#calls + 1] = {
        Name = name,
        Value = value,
    }
end

local AngryEra = {
    Title = "Angry Era",
    Version = "3.0.1",
    core = {
        isClassic = false,
    },
    utils = {
        protocol = {
            PREFIX = "AngryEra3",
            DISPLAY_PREFIX = "AngryEra3D",
            PAGE_PREFIX = "AngryEra3C",
            ACTIVE_PAGE_PREFIX = "AngryEra3P",
        },
        colors = {
            RGBToHex = function()
                return "ffffff"
            end,
            HexToRGB = function()
                return 1, 1, 1, 1
            end,
        },
        helpers = {
            RequestGuildRoster = function()
                Record("request-guild-roster")
            end,
        },
    },
}

local app = {
    AngryEra = AngryEra,
    Templates = {},
    libs = {
        LSM = {
            RegisterCallback = function(_, _, method)
                Record("media-callback", method)
            end,
        },
    },
}

assert(loadfile("modules/debug.lua"))("AngryEra", app)
assert(loadfile("modules/init.lua"))("AngryEra", app)

function AngryEra:ResetOfficerRank()
    Record("reset-officer-rank")
end

function AngryEra:CreateDisplay()
    Record("create-display")
end

function AngryEra:CaptureDisplayAuthorityRecovery()
    Record("capture-display-authority-recovery")
    return true, 7
end

function AngryEra:DiscardDisplayAuthorityRecovery()
    Record("discard-display-authority-recovery")
    return true
end

function AngryEra:RestoreDisplayAuthority()
    Record("restore-display-authority")
    if restoreAsAuthority then
        return true, "display-message", true
    end
    return false, "not-display-authority", false
end

function AngryEra:IsPlayerRaidLeader()
    return isRaidLeader
end

function AngryEra:ClearDisplayed(publish)
    assert(publish ~= true, "startup and group-boundary clears must remain local-only")
    Record("clear-displayed", publish)
    return true
end

function AngryEra:StartProtocolSession()
    Record("start-protocol-session")
    return true
end

function AngryEra:ScheduleTimer(method, delay)
    Record("schedule", {
        Method = method,
        Delay = delay,
    })
    return {}
end

function AngryEra:RegisterEvent(event)
    assert(event ~= "PARTY_CONVERTED_TO_RAID", "Classic rejects the PARTY_CONVERTED_TO_RAID event")
    Record("register-event", event)
end

function AngryEra:RegisterComm(prefix, method)
    Record("register-comm", {
        Prefix = prefix,
        Method = method,
    })
end

function AngryEra:ResetProtocolPeers()
    Record("reset-protocol-peers")
end

function AngryEra:SendProtocolVersionQuery(force)
    Record("version-query", force)
    return versionQuerySucceeds, versionQuerySucceeds and "query-id" or "query-failed"
end

function AngryEra:SendRequestDisplay()
    Record("request-display")
    return requestDisplaySucceeds, requestDisplaySucceeds and "display-request-id" or requestDisplayError
end

function AngryEra:CancelDisplayRequestWatchdog()
    Record("cancel-display-request-watchdog")
    return true
end

function AngryEra:GetProtocolDisplayAuthority()
    return protocolDisplayAuthority
end

function AngryEra:CanReceiveFrom(_, action)
    return action == "display" and authorityReceiveAllowed
end

function AngryEra:RefreshProtocolLeadershipTenure(_, force)
    Record("refresh-tenure", force)
    local changed = isRaidLeader ~= tenureLocalAuthority
    local rotated = isRaidLeader and (changed or force == true)
    if rotated then
        tenureRotationCount = tenureRotationCount + 1
    end
    tenureLocalAuthority = isRaidLeader
    return true, {
        Changed = changed or force == true,
        LocalAuthority = isRaidLeader,
        PendingDisplayBootstrap = not isRaidLeader and refreshPendingDisplayBootstrap,
        Rotated = rotated,
    }
end

function AngryEra:UpdateDisplayedIfNewGroup()
    Record("update-group-display")
end

function AngryEra:PermissionsUpdated()
    Record("permissions-updated")
end

function AngryEra:ResetDisplayPublicationState()
    Record("reset-display-publication")
end

function AngryEra:ResetDisplayAuthorityPublicationState(reason)
    Record("reset-authority-publication", reason)
end

function AngryEra:ResetProtocolAncestorAnnouncements()
    Record("reset-protocol-ancestor-announcements")
end

function AngryEra:PruneProtocolPeers()
    Record("prune-protocol-peers")
end

function AngryEra:RetryDisplayedNoteMarkers()
    Record("retry-displayed-markers")
end

function AngryEra:Print(message)
    Record("print", message)
end

local function CommandInput(value)
    return {
        trim = function()
            return value
        end,
    }
end

function _G.IsInRaid()
    return true
end

function _G.IsInGroup()
    return true
end

assert(not AngryEra:IsSyncDebugEnabled(), "sync debug should be disabled by default")
AngryEra:ChatCommand(CommandInput("debug"))
assert(AngryEra:IsSyncDebugEnabled(), "bare debug command should enable tracing")
AngryEra:ChatCommand(CommandInput("debug status"))
assert(calls[#calls].Name == "print", "debug status should print its current state")
AngryEra:ChatCommand(CommandInput("debug off"))
assert(not AngryEra:IsSyncDebugEnabled(), "debug off should disable tracing")
calls = {}

AngryEra:OnEnable()

local createIndex
local captureIndex
local startupClearIndex
local sessionIndex
local restoreIndex
local startupRequestIndex
local startupQueryIndex
local registeredPrefixes = {}
local registrationOrder = {}
local registeredEvents = {}
for index, call in ipairs(calls) do
    if call.Name == "create-display" then
        createIndex = index
    elseif call.Name == "capture-display-authority-recovery" then
        captureIndex = index
    elseif call.Name == "clear-displayed" then
        startupClearIndex = index
    elseif call.Name == "start-protocol-session" then
        sessionIndex = index
    elseif call.Name == "restore-display-authority" then
        restoreIndex = index
    elseif call.Name == "request-display" then
        startupRequestIndex = index
    elseif call.Name == "version-query" then
        startupQueryIndex = index
    elseif call.Name == "register-comm" then
        registeredPrefixes[call.Value.Prefix] = call.Value.Method
        registrationOrder[#registrationOrder + 1] = {
            Index = index,
            Prefix = call.Value.Prefix,
        }
    elseif call.Name == "register-event" then
        registeredEvents[call.Value] = true
    end
end
assert(
    createIndex and captureIndex and startupClearIndex and sessionIndex and restoreIndex,
    "startup should capture display continuity, clear follower state, start protocol, and attempt authority restore"
)
assert(
    startupRequestIndex
        and not startupQueryIndex
        and restoreIndex < startupRequestIndex,
    "a follower should request the current display immediately after registered startup restore"
)
assert(
    createIndex < captureIndex
        and captureIndex < startupClearIndex
        and startupClearIndex < sessionIndex
        and registrationOrder[#registrationOrder].Index < restoreIndex,
    "startup must capture the saved display before clearing and restore only after transport registration"
)
assert(registeredPrefixes.AngryEra3 == "ReceiveProtocolMessage", "startup should register the data prefix")
assert(registeredPrefixes.AngryEra3D == "ReceiveProtocolMessage", "startup should register the display prefix")
assert(registeredPrefixes.AngryEra3C == "ReceiveProtocolMessage", "startup should register the compact-page prefix")
assert(registeredPrefixes.AngryEra3P == "ReceiveProtocolMessage", "startup should register the active-page prefix")
assert(#registrationOrder == 4, "startup should register exactly four protocol prefixes")
assert(
    registeredEvents.PARTY_LEADER_CHANGED
        and registeredEvents.GROUP_JOINED
        and registeredEvents.GROUP_ROSTER_UPDATE
        and not registeredEvents.PARTY_CONVERTED_TO_RAID,
    "supported leader and group-boundary handlers must be active without registering the invalid conversion event"
)
assert(
    sessionIndex < registrationOrder[1].Index
        and registrationOrder[1].Prefix == "AngryEra3"
        and registrationOrder[2].Prefix == "AngryEra3D"
        and registrationOrder[3].Prefix == "AngryEra3C"
        and registrationOrder[4].Prefix == "AngryEra3P",
    "the protocol session must start before ordered data, display, compact-page, and active-page registration"
)

local clearCountBeforeJoin = 0
for _, call in ipairs(calls) do
    if call.Name == "clear-displayed" then
        clearCountBeforeJoin = clearCountBeforeJoin + 1
    end
end

calls = {}
AngryEra._protocolStarted = true
AngryEra:GROUP_JOINED()
assert(
    calls[1].Name == "discard-display-authority-recovery",
    "group join must invalidate a startup display candidate from the prior group"
)
assert(calls[2].Name == "clear-displayed", "group join must clear the prior display before all new-group work")
assert(calls[3].Name == "reset-protocol-peers", "group join should reset prior-group transport state after clearing")
assert(
    calls[4].Name == "refresh-tenure"
        and calls[5].Name == "schedule"
        and calls[5].Value.Method == "SendRequestDisplayIfUnbound",
    "a follower group join should request the new leader only after clearing prior-group state"
)
assert(calls[6].Name == "update-group-display", "group display reconciliation should follow follower bootstrap")
for _, call in ipairs(calls) do
    assert(call.Name ~= "version-query", "followers must not broadcast discovery on group join")
end

calls = {}
AngryEra:AfterEnable()
local afterEnableVersionQueryCount = 0
local afterEnableDisplayRequestCount = 0
for _, call in ipairs(calls) do
    assert(call.Name ~= "clear-displayed", "delayed setup must not duplicate the startup clear")
    assert(call.Name ~= "register-comm", "delayed setup must not leave a startup receive blind spot")
    assert(call.Name ~= "register-event", "delayed setup must not leave a startup leader-event blind spot")
    if call.Name == "version-query" then
        afterEnableVersionQueryCount = afterEnableVersionQueryCount + 1
    elseif call.Name == "schedule" and call.Value.Method == "SendRequestDisplayIfUnbound" then
        afterEnableDisplayRequestCount = afterEnableDisplayRequestCount + 1
    end
end
assert(afterEnableVersionQueryCount == 0, "a follower delayed startup must not broadcast discovery")
assert(
    afterEnableDisplayRequestCount == 0,
    "a successful immediate request should rely on its watchdog instead of scheduling duplicate discovery"
)

calls = {}
AngryEra._startupDiscoveryRetryNeeded = true
protocolDisplayAuthority = nil
AngryEra:AfterEnable()
assert(
    calls[2].Name == "schedule" and calls[2].Value.Method == "SendRequestDisplayIfUnbound",
    "failed immediate follower discovery should retain one delayed fallback"
)

calls = {}
AngryEra._startupDiscoveryRetryNeeded = true
protocolDisplayAuthority = {
    Sender = "Leader-Realm",
}
AngryEra:AfterEnable()
for _, call in ipairs(calls) do
    assert(
        call.Name ~= "schedule" or call.Value.Method ~= "SendRequestDisplayIfUnbound",
        "a follower already bound before fallback must not request the full display again"
    )
end
protocolDisplayAuthority = nil

calls = {}
protocolDisplayAuthority = {
    Sender = "Leader-Realm",
}
local lifecycleResolved, lifecycleStatus = AngryEra:SendRequestDisplayIfUnbound()
assert(
    lifecycleResolved and lifecycleStatus == "already-bound" and #calls == 0,
    "a delayed lifecycle callback should become a no-op after its earlier request binds authority"
)

calls = {}
protocolDisplayAuthority = nil
local lifecycleSent, lifecycleMessageId = AngryEra:SendRequestDisplayIfUnbound()
assert(
    lifecycleSent
        and lifecycleMessageId == "display-request-id"
        and #calls == 1
        and calls[1].Name == "request-display",
    "an unbound delayed lifecycle callback should issue exactly one request"
)

calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
local markerRetryCount = 0
for _, call in ipairs(calls) do
    if call.Name == "retry-displayed-markers" then
        markerRetryCount = markerRetryCount + 1
    end
    assert(call.Name ~= "version-query", "routine roster refreshes must not rediscover protocol peers")
    assert(call.Name ~= "request-display", "routine roster refreshes must not request the active page")
    assert(
        call.Name ~= "reset-authority-publication"
            and call.Name ~= "reset-protocol-ancestor-announcements"
            and call.Name ~= "restore-display-authority",
        "same-channel roster refreshes must not disturb publication state"
    )
end
assert(markerRetryCount == 1, "a roster update should retry unresolved displayed-note marker targets once")

calls = {}
local rotationsBeforeSettledPromotion = tenureRotationCount
AngryEra:PARTY_LEADER_CHANGED()
for _, call in ipairs(calls) do
    assert(
        call.Name ~= "version-query" and call.Name ~= "restore-display-authority",
        "a stale follower-role leader event must not publish a leader tenure"
    )
end
assert(
    tenureRotationCount == rotationsBeforeSettledPromotion
        and AngryEra._leadershipRosterReconcilePending == true,
    "the stale leader event should defer one settled-roster reconciliation without rotating"
)

calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
assert(
    tenureRotationCount == rotationsBeforeSettledPromotion
        and AngryEra._leadershipRosterReconcilePending == true,
    "a still-stale first roster callback should retain the bounded reconciliation"
)

calls = {}
isRaidLeader = true
restoreAsAuthority = true
AngryEra:GROUP_ROSTER_UPDATE()
restoreAsAuthority = false
local settledQueryCount = 0
local settledRestoreCount = 0
local settledQueryForced = false
for _, call in ipairs(calls) do
    if call.Name == "version-query" then
        settledQueryCount = settledQueryCount + 1
        settledQueryForced = call.Value == true
    elseif call.Name == "restore-display-authority" then
        settledRestoreCount = settledRestoreCount + 1
    end
end
assert(
    tenureRotationCount == rotationsBeforeSettledPromotion + 1
        and settledQueryCount == 1
        and settledQueryForced
        and settledRestoreCount == 1,
    "the settled roster should rotate, advertise, and restore the missed leader tenure exactly once"
)

calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
for _, call in ipairs(calls) do
    assert(
        call.Name ~= "version-query"
            and call.Name ~= "restore-display-authority"
            and call.Name ~= "reset-authority-publication",
        "duplicate settled roster events must not rotate or republish a stable leader tenure"
    )
end
assert(
    tenureRotationCount == rotationsBeforeSettledPromotion + 1,
    "duplicate settled roster events must preserve the promoted protocol session"
)

calls = {}
local rotationsBeforeSettledDemotion = tenureRotationCount
AngryEra:PARTY_LEADER_CHANGED()
assert(
    tenureRotationCount == rotationsBeforeSettledDemotion + 1
        and AngryEra._leadershipRosterReconcilePending == true,
    "a stale local-leader demotion event should retain a settled-roster correction"
)
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
assert(
    AngryEra._leadershipRosterReconcilePending == true,
    "a still-stale leader roster callback should retain the bounded demotion correction"
)
calls = {}
isRaidLeader = false
AngryEra:GROUP_ROSTER_UPDATE()
local settledDemotionRequests = 0
for _, call in ipairs(calls) do
    if call.Name == "request-display" then
        settledDemotionRequests = settledDemotionRequests + 1
    end
end
assert(
    settledDemotionRequests == 1 and AngryEra._leadershipRosterReconcilePending == false,
    "a settled demotion should retire leader tenure and request the new authority once"
)

calls = {}
protocolDisplayAuthority = nil
AngryEra:PARTY_LEADER_CHANGED()
assert(
    AngryEra._leadershipRosterReconcilePending == true,
    "a remote leader event should await one settled-roster bootstrap check"
)
AngryEra:GROUP_JOINED()
assert(
    AngryEra._leadershipRosterReconcilePending == true,
    "a group-boundary callback must preserve the pending settled-leader check"
)
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
local settledFollowerRequests = 0
for _, call in ipairs(calls) do
    if call.Name == "request-display" then
        settledFollowerRequests = settledFollowerRequests + 1
    end
end
assert(
    settledFollowerRequests == 1,
    "an unbound follower should re-resolve the leader once after roster roles settle"
)
assert(
    AngryEra._leadershipRosterReconcilePending == true,
    "an unresolved first follower bootstrap should retain one bounded settled-roster check"
)
protocolDisplayAuthority = {
    Sender = "Leader-Realm",
}
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
for _, call in ipairs(calls) do
    assert(call.Name ~= "request-display", "a newly bound follower must not restart its display bootstrap")
end
assert(
    AngryEra._leadershipRosterReconcilePending == true,
    "a first bound callback should retain the remaining bounded event-order check"
)
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
for _, call in ipairs(calls) do
    assert(call.Name ~= "request-display", "a bound follower must remain quiet through the final bounded check")
end
assert(
    AngryEra._leadershipRosterReconcilePending == false,
    "the bounded follower reconciliation should expire after stable roster evidence"
)
protocolDisplayAuthority = nil
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
for _, call in ipairs(calls) do
    assert(call.Name ~= "request-display", "routine roster updates must remain free of display requests")
end

calls = {}
AngryEra:PARTY_LEADER_CHANGED()
assert(
    calls[1].Name == "refresh-tenure"
        and calls[1].Value == true
        and calls[2].Name == "reset-authority-publication"
        and calls[3].Name == "reset-protocol-ancestor-announcements"
        and calls[4].Name == "permissions-updated",
    "leader changes must force an epoch boundary and narrowly reset queued authority publication"
)
assert(
    calls[5].Name == "cancel-display-request-watchdog"
        and calls[6].Name == "request-display",
    "a hard follower boundary should discard stale watchdog state before requesting the new leader"
)
for _, call in ipairs(calls) do
    assert(call.Name ~= "version-query", "a follower leader-change handler must not broadcast discovery")
    assert(call.Name ~= "restore-display-authority", "followers must not attempt leader publication restore")
end

calls = {}
refreshPendingDisplayBootstrap = true
AngryEra:PARTY_LEADER_CHANGED()
for _, call in ipairs(calls) do
    assert(
        call.Name ~= "request-display" and call.Name ~= "cancel-display-request-watchdog",
        "a query-first exact bootstrap and watchdog must survive the matching leader event without R2"
    )
end
refreshPendingDisplayBootstrap = false

calls = {}
isRaidLeader = true
restoreAsAuthority = true
AngryEra:PARTY_LEADER_CHANGED()
restoreAsAuthority = false
assert(calls[5].Name == "version-query", "a promoted leader should advertise protocol capabilities")
assert(calls[6].Name == "restore-display-authority", "a promoted leader should restore its current display anchor")
for _, call in ipairs(calls) do
    assert(call.Name ~= "request-display", "a promoted leader must not whisper a display request to itself")
end
isRaidLeader = false

local totalClearCount = clearCountBeforeJoin + 1
assert(totalClearCount == 2, "startup and group join should each perform one local-only clear")

local successfulStartProtocolSession = AngryEra.StartProtocolSession
calls = {}
requestDisplaySucceeds = false
requestDisplayError = "shared-display-disabled"
AngryEra:OnEnable()
local disabledStartupRequests = 0
for _, call in ipairs(calls) do
    if call.Name == "request-display" then
        disabledStartupRequests = disabledStartupRequests + 1
    end
end
assert(
    AngryEra._protocolStarted
        and AngryEra._startupDiscoveryRetryNeeded == false
        and disabledStartupRequests == 1,
    "ignoreShared startup should make one gated check without arming delayed discovery"
)
calls = {}
AngryEra:AfterEnable()
for _, call in ipairs(calls) do
    assert(
        call.Name ~= "request-display"
            and (call.Name ~= "schedule" or call.Value.Method ~= "SendRequestDisplayIfUnbound"),
        "stable disabled sharing must not retry display discovery after startup"
    )
end
requestDisplaySucceeds = true
requestDisplayError = "request-failed"

function AngryEra:StartProtocolSession()
    Record("start-protocol-session")
    return false, "test-session-failure"
end

calls = {}
AngryEra._protocolStarted = true
AngryEra:OnEnable()
assert(not AngryEra._protocolStarted, "a failed protocol session must leave transport disabled")
for _, call in ipairs(calls) do
    assert(call.Name ~= "register-comm", "a failed protocol session must not register comm prefixes")
end

calls = {}
AngryEra:AfterEnable()
for _, call in ipairs(calls) do
    assert(call.Name ~= "version-query", "delayed setup must not discover peers after session failure")
    assert(
        call.Name ~= "schedule" or call.Value.Method ~= "SendRequestDisplayIfUnbound",
        "delayed setup must not request display state after session failure"
    )
end
AngryEra.StartProtocolSession = successfulStartProtocolSession

print("Initialization lifecycle tests passed.")
