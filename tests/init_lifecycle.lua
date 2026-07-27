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
local grouped = true
local scheduledTimers = {}
local timerOrdinal = 0
local layoutApplyResetCount = 0
local layoutApplyCancelCount = 0
local layoutFlushApplied = false
local layoutFlushResult = "no-pending-layout"
local layoutFlushCount = 0
local layoutPauseCount = 0
local unitCombat = {}

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

function AngryEra:ResetGroupLayoutApplyState()
    layoutApplyResetCount = layoutApplyResetCount + 1
end

function AngryEra:CancelPendingGroupLayoutApply()
    layoutApplyCancelCount = layoutApplyCancelCount + 1
end

function AngryEra:FlushPendingGroupLayoutApply()
    layoutFlushCount = layoutFlushCount + 1
    return layoutFlushApplied, layoutFlushResult
end

function AngryEra:PauseGroupLayoutApplyForCombat()
    layoutPauseCount = layoutPauseCount + 1
end

function AngryEra:GetConfig()
    return false
end

local guildDisplayRefreshes = 0
function AngryEra:UpdateDisplayed()
    guildDisplayRefreshes = guildDisplayRefreshes + 1
end

function AngryEra:UpdateGuildColors() end

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

function AngryEra:ScheduleTimer(method, delay, ...)
    timerOrdinal = timerOrdinal + 1
    local timer = {
        Active = true,
        Arguments = { ... },
        Delay = delay,
        Id = timerOrdinal,
        Method = method,
    }
    scheduledTimers[#scheduledTimers + 1] = timer
    Record("schedule", {
        Arguments = timer.Arguments,
        Method = method,
        Delay = delay,
        Timer = timer,
    })
    return timer
end

function AngryEra:CancelTimer(timer)
    if type(timer) ~= "table" or timer.Active ~= true then
        return false
    end
    timer.Active = false
    return true
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

function AngryEra:ResetCurrentGroup()
    Record("reset-current-group")
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
    return true,
        {
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
    return grouped
end

function _G.IsInGroup()
    return grouped
end

function _G.UnitAffectingCombat(unit)
    return unitCombat[unit] == true
end

local function LatestTimer(method)
    for index = #scheduledTimers, 1, -1 do
        local timer = scheduledTimers[index]
        if timer.Method == method then
            return timer
        end
    end
end

local function FireTimer(timer)
    assert(type(timer) == "table", "a scheduled timer is required")
    timer.Active = false
    local callback = assert(AngryEra[timer.Method], "the scheduled callback must exist")
    return callback(AngryEra, timer.Arguments[1])
end

local function CountCalls(name)
    local count = 0
    for _, call in ipairs(calls) do
        if call.Name == name then
            count = count + 1
        end
    end
    return count
end

local function CountActiveTimers(method)
    local count = 0
    for _, timer in ipairs(scheduledTimers) do
        if timer.Active and timer.Method == method then
            count = count + 1
        end
    end
    return count
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
assert(layoutApplyResetCount == 1, "startup should clear session-local raid-layout apply state")

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
    startupRequestIndex and not startupQueryIndex and restoreIndex < startupRequestIndex,
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
        and registeredEvents.PLAYER_REGEN_DISABLED
        and registeredEvents.PLAYER_REGEN_ENABLED
        and registeredEvents.UNIT_FLAGS
        and not registeredEvents.PARTY_CONVERTED_TO_RAID,
    "supported group and unit handlers must be active without registering the invalid conversion event"
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
layoutFlushApplied = true
layoutFlushResult = 2
AngryEra:PLAYER_REGEN_ENABLED()
assert(layoutFlushCount == 1, "leaving combat should flush one queued layout request")
assert(#calls == 0, "the asynchronous completion hook, not the combat event, should report the result")
AngryEra:OnGroupLayoutApplyFinished(true, 2)
assert(
    #calls == 1 and calls[1].Name == "print" and calls[1].Value == "Rearranged the raid to the layout (2 moves).",
    "leaving combat should report a completed queued layout exactly once"
)
calls = {}
AngryEra:OnGroupLayoutApplyFinished(true, 0)
assert(#calls == 0, "an already-satisfied raid layout should not print a zero-move success")
calls = {}
layoutFlushApplied = false
layoutFlushResult = "no-pending-layout"
AngryEra:PLAYER_REGEN_ENABLED()
assert(layoutFlushCount == 2 and #calls == 0, "leaving combat with no queued layout should stay silent")
AngryEra:OnGroupLayoutApplyFinished(false, "display-changed")
assert(#calls == 0, "an expected page-change cancellation should stay silent")
AngryEra:PLAYER_REGEN_DISABLED()
assert(layoutPauseCount == 1, "entering combat should pause any not-yet-issued raid-layout operation")
unitCombat.raid1 = true
AngryEra:UNIT_FLAGS(nil, "raid1")
assert(layoutPauseCount == 1, "a remote raider's combat flag should not pause locally protected layout work")
unitCombat.raid1 = false
AngryEra:UNIT_FLAGS(nil, "raid1")
assert(layoutFlushCount == 2, "a remote raider's combat flag should not flush locally protected layout work")
unitCombat.player = true
AngryEra:UNIT_FLAGS(nil, "player")
assert(layoutPauseCount == 2, "the local player's combat flag should pause layout work")
unitCombat.player = false
AngryEra:UNIT_FLAGS(nil, "player")
assert(layoutFlushCount == 3, "the local player's combat flag should retry queued layout work")

calls = {}
AngryEra._protocolStarted = true
AngryEra:GROUP_JOINED()
assert(layoutApplyResetCount == 2, "a group boundary should discard layout work from the prior group")
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
    lifecycleSent and lifecycleMessageId == "display-request-id" and #calls == 1 and calls[1].Name == "request-display",
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
assert(layoutApplyCancelCount == 1, "a leader change should cancel layout work authorized under the old leader")
for _, call in ipairs(calls) do
    assert(
        call.Name ~= "version-query" and call.Name ~= "restore-display-authority",
        "a stale follower-role leader event must not publish a leader tenure"
    )
end
assert(
    tenureRotationCount == rotationsBeforeSettledPromotion and AngryEra._leadershipRosterReconcilePending == true,
    "the stale leader event should defer one settled-roster reconciliation without rotating"
)

calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
assert(
    tenureRotationCount == rotationsBeforeSettledPromotion and AngryEra._leadershipRosterReconcilePending == true,
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
    tenureRotationCount == rotationsBeforeSettledDemotion + 1 and AngryEra._leadershipRosterReconcilePending == true,
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
assert(settledFollowerRequests == 1, "an unbound follower should re-resolve the leader once after roster roles settle")
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
    AngryEra._leadershipRosterReconcilePending == true and AngryEra._leadershipRosterReconcileAttempts == 2,
    "roster evidence should reserve the terminal reconciliation for its trailing timer"
)
local settledFollowerTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
calls = {}
FireTimer(settledFollowerTimer)
for _, call in ipairs(calls) do
    assert(call.Name ~= "request-display", "the terminal bound-follower timer must remain quiet")
end
assert(
    AngryEra._leadershipRosterReconcilePending == false,
    "the terminal timer should expire the bounded follower reconciliation"
)
protocolDisplayAuthority = nil
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
for _, call in ipairs(calls) do
    assert(call.Name ~= "request-display", "routine roster updates must remain free of display requests")
end

-- A timer must finish a promotion even when Classic settles the role API
-- without emitting a second GROUP_ROSTER_UPDATE.
AngryEra:CancelProtocolLeadershipRosterReconcile()
grouped = true
isRaidLeader = false
tenureLocalAuthority = false
protocolDisplayAuthority = nil
calls = {}
local rotationsBeforeTimerPromotion = tenureRotationCount
AngryEra:PARTY_LEADER_CHANGED()
local promotionEventTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
assert(
    promotionEventTimer
        and promotionEventTimer.Active
        and promotionEventTimer.Delay == 0.25
        and AngryEra._leadershipRosterReconcilePending == true,
    "a leader event should arm one settled-roster fallback timer"
)
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
local promotionFallbackTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
assert(
    promotionEventTimer.Active == false
        and promotionFallbackTimer ~= promotionEventTimer
        and promotionFallbackTimer.Active
        and promotionFallbackTimer.Arguments[1] ~= promotionEventTimer.Arguments[1]
        and AngryEra._leadershipRosterReconcileAttempts == 1,
    "a stale roster callback should consume one attempt and re-arm a fresh timer generation"
)
calls = {}
FireTimer(promotionEventTimer)
assert(
    CountCalls("refresh-tenure") == 0 and promotionFallbackTimer.Active,
    "a canceled timer must not consume or clear its re-armed replacement"
)
isRaidLeader = true
restoreAsAuthority = true
calls = {}
FireTimer(promotionFallbackTimer)
restoreAsAuthority = false
assert(
    tenureRotationCount == rotationsBeforeTimerPromotion + 1
        and CountCalls("version-query") == 1
        and CountCalls("restore-display-authority") == 1
        and AngryEra._leadershipRosterReconcilePending == false,
    "the fallback timer should rotate, advertise, and restore a silently settled promotion once"
)

-- Demotion has no follower display watchdog, so the same timer must retire the
-- local tenure and request the newly settled leader.
calls = {}
local rotationsBeforeTimerDemotion = tenureRotationCount
restoreAsAuthority = true
AngryEra:PARTY_LEADER_CHANGED()
restoreAsAuthority = false
local demotionEventTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
assert(
    tenureRotationCount == rotationsBeforeTimerDemotion + 1 and demotionEventTimer.Active,
    "a stale demotion event should arm a correction after its provisional rotation"
)
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
local demotionFallbackTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
assert(
    demotionEventTimer.Active == false and demotionFallbackTimer ~= demotionEventTimer and demotionFallbackTimer.Active,
    "a stale leader roster should re-arm the demotion correction"
)
isRaidLeader = false
calls = {}
FireTimer(demotionFallbackTimer)
assert(
    CountCalls("request-display") == 1
        and CountCalls("version-query") == 0
        and AngryEra._leadershipRosterReconcilePending == false,
    "the fallback timer should retire a silently settled demotion and request its new leader once"
)

-- A settled roster callback wins the race with its timer and invalidates the
-- already-dispatched generation before it can duplicate promotion work.
isRaidLeader = false
tenureLocalAuthority = false
calls = {}
AngryEra:PARTY_LEADER_CHANGED()
local rosterWinsTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
isRaidLeader = true
restoreAsAuthority = true
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
restoreAsAuthority = false
assert(
    rosterWinsTimer.Active == false
        and CountCalls("version-query") == 1
        and CountCalls("restore-display-authority") == 1
        and AngryEra._leadershipRosterReconcilePending == false,
    "a settled roster callback should cancel its fallback after reconciling once"
)
calls = {}
FireTimer(rosterWinsTimer)
assert(
    CountCalls("refresh-tenure") == 0
        and CountCalls("version-query") == 0
        and CountCalls("restore-display-authority") == 0,
    "a canceled fallback must not duplicate settled-roster promotion work"
)

-- New leader events and group boundaries must invalidate callbacks captured
-- from an older lifecycle generation.
isRaidLeader = false
tenureLocalAuthority = false
calls = {}
AngryEra:PARTY_LEADER_CHANGED()
local supersededEventTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
local supersededGeneration = supersededEventTimer.Arguments[1]
AngryEra:PARTY_LEADER_CHANGED()
local replacementEventTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
assert(
    supersededEventTimer.Active == false
        and replacementEventTimer.Active
        and replacementEventTimer.Arguments[1] ~= supersededGeneration,
    "a newer leader event should replace and invalidate the prior timer generation"
)
calls = {}
FireTimer(supersededEventTimer)
assert(
    CountCalls("refresh-tenure") == 0 and replacementEventTimer.Active,
    "a superseded event callback must not consume the replacement generation"
)
AngryEra:CancelProtocolLeadershipRosterReconcile()

calls = {}
AngryEra:PARTY_LEADER_CHANGED()
AngryEra:GROUP_ROSTER_UPDATE()
local preJoinTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
local preJoinGeneration = preJoinTimer.Arguments[1]
assert(
    AngryEra._leadershipRosterReconcileAttempts == 1,
    "the pre-join roster should consume one shared bounded attempt"
)
AngryEra:GROUP_JOINED()
local postJoinTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
assert(
    preJoinTimer.Active == false and postJoinTimer.Active and postJoinTimer.Arguments[1] ~= preJoinGeneration,
    "GROUP_JOINED should preserve the boundary under a fresh timer generation"
)
assert(
    AngryEra._leadershipRosterReconcileAttempts == 1,
    "GROUP_JOINED should preserve the shared attempt budget while re-arming"
)
calls = {}
FireTimer(preJoinTimer)
assert(
    CountCalls("refresh-tenure") == 0 and postJoinTimer.Active,
    "a pre-join callback must not act on post-join protocol state"
)
AngryEra:CancelProtocolLeadershipRosterReconcile()

-- Group departure and OnEnable both cancel and invalidate any pending callback.
calls = {}
AngryEra:PARTY_LEADER_CHANGED()
local departureTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
grouped = false
calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
assert(
    departureTimer.Active == false and AngryEra._leadershipRosterReconcilePending == false,
    "group departure should cancel settled-roster reconciliation"
)
grouped = true
calls = {}
FireTimer(departureTimer)
assert(
    CountCalls("refresh-tenure") == 0 and CountCalls("request-display") == 0,
    "a callback captured before group departure must remain inert"
)

calls = {}
AngryEra:PARTY_LEADER_CHANGED()
local preEnableTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
calls = {}
AngryEra:OnEnable()
assert(
    preEnableTimer.Active == false and AngryEra._leadershipRosterReconcilePending == false,
    "OnEnable should invalidate a timer retained from an earlier enable lifecycle"
)
calls = {}
FireTimer(preEnableTimer)
assert(CountCalls("refresh-tenure") == 0, "a callback captured before OnEnable must not enter the new protocol session")

-- Stable evidence is bounded to exactly three total attempts, regardless of
-- whether those attempts are event-driven or timer-driven.
isRaidLeader = false
tenureLocalAuthority = false
protocolDisplayAuthority = {
    Sender = "Leader-Realm",
}
AngryEra:CancelProtocolLeadershipRosterReconcile()
local timersBeforeBoundedRun = #scheduledTimers
calls = {}
AngryEra:PARTY_LEADER_CHANGED()
local boundedTimerOne = LatestTimer("RetryProtocolLeadershipRosterReconcile")
calls = {}
FireTimer(boundedTimerOne)
local boundedTimerTwo = LatestTimer("RetryProtocolLeadershipRosterReconcile")
FireTimer(boundedTimerTwo)
local boundedTimerThree = LatestTimer("RetryProtocolLeadershipRosterReconcile")
FireTimer(boundedTimerThree)
assert(
    #scheduledTimers == timersBeforeBoundedRun + 3
        and CountCalls("refresh-tenure") == 3
        and CountCalls("request-display") == 0
        and AngryEra._leadershipRosterReconcilePending == false
        and AngryEra._leadershipRosterReconcileAttempts == 0,
    "three stable attempts should exhaust without scheduling a fourth timer or adding display traffic"
)

-- A burst of roster events may consume the first two attempts, but it may only
-- trailingly re-arm the reserved terminal attempt until the burst goes quiet.
AngryEra:CancelProtocolLeadershipRosterReconcile()
isRaidLeader = false
tenureLocalAuthority = false
local rotationsBeforeRosterBurst = tenureRotationCount
calls = {}
AngryEra:PARTY_LEADER_CHANGED()
calls = {}
for _ = 1, 4 do
    AngryEra:GROUP_ROSTER_UPDATE()
end
local rosterBurstTimer = LatestTimer("RetryProtocolLeadershipRosterReconcile")
assert(
    CountCalls("refresh-tenure") == 2
        and AngryEra._leadershipRosterReconcileAttempts == 2
        and AngryEra._leadershipRosterReconcilePending == true
        and CountActiveTimers("RetryProtocolLeadershipRosterReconcile") == 1
        and rosterBurstTimer.Active,
    "rapid stale roster events must reserve exactly one active delayed reconciliation"
)
isRaidLeader = true
restoreAsAuthority = true
calls = {}
FireTimer(rosterBurstTimer)
restoreAsAuthority = false
assert(
    tenureRotationCount == rotationsBeforeRosterBurst + 1
        and CountCalls("refresh-tenure") == 1
        and CountCalls("version-query") == 1
        and CountCalls("restore-display-authority") == 1
        and AngryEra._leadershipRosterReconcilePending == false,
    "the reserved timer should reconcile a role API that settles silently after the roster burst"
)
protocolDisplayAuthority = nil
isRaidLeader = false
tenureLocalAuthority = false

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
    calls[5].Name == "cancel-display-request-watchdog" and calls[6].Name == "request-display",
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
    AngryEra._protocolStarted and AngryEra._startupDiscoveryRetryNeeded == false and disabledStartupRequests == 1,
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

do
    AngryEra._displayedHasPriority = true
    AngryEra._priorityRefreshTimer = nil
    guildDisplayRefreshes = 0
    local scheduledBefore = #scheduledTimers
    AngryEra:UNIT_FLAGS("UNIT_FLAGS", "target")
    AngryEra:UNIT_FLAGS("UNIT_FLAGS", "nameplate1")
    assert(#scheduledTimers == scheduledBefore, "non-group unit flags should not schedule priority refreshes")

    AngryEra:UNIT_FLAGS("UNIT_FLAGS", "raid2")
    local refreshTimer = scheduledTimers[#scheduledTimers]
    assert(
        #scheduledTimers == scheduledBefore + 1 and refreshTimer.Method == "RunDisplayedPriorityRefresh",
        "a unit death or revive flag should schedule a priority refresh"
    )
    AngryEra:UNIT_FLAGS("UNIT_FLAGS", "raid2")
    assert(#scheduledTimers == scheduledBefore + 1, "unit flag bursts should coalesce into one priority refresh")
    FireTimer(refreshTimer)
    assert(guildDisplayRefreshes == 1, "the coalesced priority timer should redraw once")
    assert(AngryEra._priorityRefreshTimer == nil, "the completed priority refresh should clear its timer token")

    AngryEra._displayedHasPriority = false
    scheduledBefore = #scheduledTimers
    AngryEra:UNIT_FLAGS("UNIT_FLAGS", "raid2")
    assert(#scheduledTimers == scheduledBefore, "unit flags should do no work without displayed priority assignments")
end

do
    AngryEra._guildDisplayRefreshTimer = nil
    guildDisplayRefreshes = 0
    local scheduledBefore = #scheduledTimers
    AngryEra:GUILD_ROSTER_UPDATE(false)
    local refreshTimer = scheduledTimers[#scheduledTimers]
    assert(
        #scheduledTimers == scheduledBefore + 1 and refreshTimer.Method == "GuildDisplayRefresh",
        "a roster update should schedule one cancelable display refresh"
    )
    AngryEra:GUILD_ROSTER_UPDATE(false)
    assert(#scheduledTimers == scheduledBefore + 1, "a pending refresh must not reschedule")
    assert(AngryEra._guildDisplayRefreshTimer == refreshTimer, "the pending refresh token should be retained")

    AngryEra:GuildDisplayRefresh()
    assert(guildDisplayRefreshes == 1, "firing the refresh should redraw once")
    assert(AngryEra._guildDisplayRefreshTimer == nil, "firing should clear the refresh token")

    AngryEra:GUILD_ROSTER_UPDATE(false)
    assert(
        #scheduledTimers == scheduledBefore + 2,
        "a settled refresh should allow the next roster update to reschedule"
    )
    assert(AngryEra:CancelTimer(AngryEra._guildDisplayRefreshTimer), "the refresh timer must be cancelable on disable")
    AngryEra._guildDisplayRefreshTimer = nil
end

print("Initialization lifecycle tests passed.")
