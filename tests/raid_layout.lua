local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

local raidMembers = {}
AngryEra.utils.helpers = {
    EnsureUnitFullName = function(name)
        if type(name) == "string" and not name:find("-", 1, true) then
            return name .. "-Home"
        end
        return name
    end,
    IterateGroupMembers = function(callback)
        for index, member in ipairs(raidMembers) do
            local fullName = AngryEra.utils.helpers.EnsureUnitFullName(member.Name)
            if
                callback(
                    "raid" .. index,
                    fullName,
                    member.Rank or 0,
                    member.Subgroup or 1,
                    member.Class or "WARRIOR",
                    member.Online ~= false,
                    member.Dead == true,
                    "raid" .. index
                )
            then
                return
            end
        end
    end,
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/utils/roster.lua"))("AngryEra", app)
assert(loadfile("modules/layout.lua"))("AngryEra", app)
assert(loadfile("modules/raid_layout.lua"))("AngryEra", app)
local rl = AngryEra.utils.raid_layout
local variableHelpers = AngryEra.utils.variables

-- Applies a plan to a copy of the current state, asserting the cap is never
-- exceeded, and returns the resulting subgroup map.
local function Simulate(current, ops, cap)
    cap = cap or 5
    local groupOf = {}
    local counts = {}
    for index, subgroup in pairs(current) do
        groupOf[index] = subgroup
        counts[subgroup] = (counts[subgroup] or 0) + 1
    end
    for _, op in ipairs(ops) do
        if op.Kind == "set" then
            local from = groupOf[op.Index]
            counts[from] = counts[from] - 1
            counts[op.Subgroup] = (counts[op.Subgroup] or 0) + 1
            groupOf[op.Index] = op.Subgroup
        else
            groupOf[op.Index1], groupOf[op.Index2] = groupOf[op.Index2], groupOf[op.Index1]
        end
        for _, occupancy in pairs(counts) do
            assert(occupancy <= cap, "no subgroup may exceed the cap during the plan")
        end
    end
    return groupOf
end

local function Reaches(current, want)
    local ops, ok, err = rl.PlanSubgroupMoves(current, want)
    assert(ok, tostring(err))
    local final = Simulate(current, ops)
    for index, subgroup in pairs(want) do
        assert(final[index] == subgroup, "member " .. index .. " should land in subgroup " .. subgroup)
    end
    return ops
end

local function FullRaidGroups()
    local groups = {}
    for index = 1, 40 do
        groups[index] = math.floor((index - 1) / 5) + 1
    end
    return groups
end

local function AssertOnlySwaps(operations, message)
    for _, operation in ipairs(operations) do
        assert(operation.Kind == "swap", message)
    end
end

-- A single move into a non-full subgroup uses set.
local single = Reaches({ [1] = 1, [2] = 1, [3] = 2 }, { [3] = 1 })
assert(#single == 1 and single[1].Kind == "set", "a non-full target is filled with set")

-- A full target forces a swap.
local full = Reaches({ [1] = 1, [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 2 }, { [6] = 1 })
assert(full[1].Kind == "swap", "a full target is entered by swapping")

-- Two members trading subgroups is one mutual swap.
local trade = {}
for index = 1, 5 do
    trade[index] = 1
end
for index = 6, 10 do
    trade[index] = 2
end
local traded = Reaches(trade, { [1] = 2, [6] = 1 })
assert(#traded == 1 and traded[1].Kind == "swap", "a mutual swap satisfies both members at once")

-- A reciprocal swap is still cheaper when both target subgroups have room.
local sparseTrade = Reaches({ [1] = 1, [2] = 2 }, { [1] = 2, [2] = 1 })
assert(#sparseTrade == 1 and sparseTrade[1].Kind == "swap", "a sparse reciprocal pair should avoid two sets")

-- Already-correct assignments need no moves.
assert(#Reaches({ [1] = 1, [2] = 2 }, { [1] = 1 }) == 0, "a satisfied layout produces no moves")

-- A larger reshuffle still reaches the target.
Reaches(
    { [1] = 1, [2] = 1, [3] = 2, [4] = 2, [5] = 3, [6] = 3, [7] = 4, [8] = 4, [9] = 5, [10] = 5 },
    { [1] = 5, [10] = 1, [5] = 2 }
)

-- A complete 40-person layout can exchange every pair of full subgroups
-- without ever requiring a capacity-breaking set operation.
local fullRaid = FullRaidGroups()
local pairedGroups = {}
for index, subgroup in pairs(fullRaid) do
    pairedGroups[index] = subgroup % 2 == 1 and subgroup + 1 or subgroup - 1
end
local pairedFullRaid = Reaches(fullRaid, pairedGroups)
assert(#pairedFullRaid == 20, "four pairs of full subgroups should need twenty mutual swaps")
AssertOnlySwaps(pairedFullRaid, "a full 40-person raid must rearrange through swaps")

-- Partial layouts also work in a full raid. The displaced, unbound member may
-- occupy the assigned member's old subgroup, but no sixth member is introduced.
local partialFullRaid = Reaches(fullRaid, { [1] = 2 })
assert(
    #partialFullRaid == 1 and partialFullRaid[1].Kind == "swap",
    "one partial assignment into a full subgroup should need one swap"
)

-- Prefer reciprocal partners even when a lower-index non-reciprocal candidate
-- is available. These four members form two independent mutual swaps.
local reciprocalTargets = {}
for index, subgroup in pairs(fullRaid) do
    reciprocalTargets[index] = subgroup
end
reciprocalTargets[1] = 2
reciprocalTargets[6] = 3
reciprocalTargets[7] = 1
reciprocalTargets[11] = 2
local reciprocalPlan = Reaches(fullRaid, reciprocalTargets)
assert(#reciprocalPlan == 2, "two available reciprocal pairs should take exactly two swaps")
AssertOnlySwaps(reciprocalPlan, "reciprocal exchanges in a full raid must remain swaps")

-- Five parallel cycles rotate all eight full subgroups. Each eight-way cycle
-- takes seven swaps, so the complete transformation takes thirty-five.
local cycleTargets = {}
for index, subgroup in pairs(fullRaid) do
    cycleTargets[index] = subgroup % 8 + 1
end
local cyclePlan = Reaches(fullRaid, cycleTargets)
assert(#cyclePlan == 35, "five eight-subgroup cycles should need thirty-five swaps")
AssertOnlySwaps(cyclePlan, "a full multi-group cycle must preserve subgroup capacity through swaps")

-- Oversubscribing a subgroup is rejected up front.
local _, okOver, errOver = rl.PlanSubgroupMoves(
    { [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6 },
    { [1] = 1, [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 1 }
)
assert(not okOver and errOver == "subgroup-oversubscribed", "more than five in one subgroup is rejected")

-- Wanting a member who is not in the raid is rejected.
local _, okUnknown, errUnknown = rl.PlanSubgroupMoves({ [1] = 1 }, { [99] = 2 })
assert(not okUnknown and errUnknown == "unknown-member", "an unknown member is rejected")

-- Deterministic integration harness for the asynchronous runtime. Blizzard can
-- reindex the roster after every move, so calls record both the transient index
-- and the canonical member name that occupied it at call time.
local inRaid = true
local inCombat = false
local combatUnits = {}
local applyAllowed = true
local permissionRequiresReadableRoster = false
local layoutSource
local layoutVars
local operations = {}
local activeReference
local autoApplyLayoutValue
local autoApplyLayoutKey = "AUTOAPPLYLAYOUT"
local localRaidLeader = false
local failRaidApi = false
local failScheduleTimer = false
local rosterReadUnavailable = false
local autoAcknowledgeRaidApi = true
local afterRaidApiCall
local finishEvents = {}
local now = 0
local timers = {}
local timerOrdinal = 0

function _G.IsInRaid()
    return inRaid
end

function _G.InCombatLockdown()
    return inCombat
end

function _G.UnitAffectingCombat(unit)
    return combatUnits[unit] == true
end

function _G.GetTimePreciseSec()
    return now
end

function _G.GetNumGroupMembers()
    return #raidMembers
end

function _G.GetRaidRosterInfo(index)
    if rosterReadUnavailable then
        return nil
    end
    local member = raidMembers[index]
    if not member then
        return nil
    end
    return member.Name,
        member.Rank or 0,
        member.Subgroup or 1,
        60,
        member.Class or "WARRIOR",
        member.Class or "WARRIOR",
        "",
        member.Online ~= false,
        member.Dead == true
end

function _G.SetRaidSubgroup(index, subgroup)
    if failRaidApi then
        error("set failed")
    end
    local member = assert(raidMembers[index], "set must use a current raid index")
    local call = {
        Kind = "set",
        Index = index,
        Name = member.Name,
        Subgroup = subgroup,
        At = now,
    }
    operations[#operations + 1] = call
    if autoAcknowledgeRaidApi then
        member.Subgroup = subgroup
    end
    if afterRaidApiCall then
        afterRaidApiCall(call)
    end
end

function _G.SwapRaidSubgroup(index1, index2)
    if failRaidApi then
        error("swap failed")
    end
    local member1 = assert(raidMembers[index1], "swap must use a current first index")
    local member2 = assert(raidMembers[index2], "swap must use a current second index")
    local call = {
        Kind = "swap",
        Index1 = index1,
        Index2 = index2,
        Name1 = member1.Name,
        Name2 = member2.Name,
        At = now,
    }
    operations[#operations + 1] = call
    if autoAcknowledgeRaidApi then
        member1.Subgroup, member2.Subgroup = member2.Subgroup, member1.Subgroup
    end
    if afterRaidApiCall then
        afterRaidApiCall(call)
    end
end

function AngryEra:CanLocalPlayerApplyRaidLayout()
    return applyAllowed and not (permissionRequiresReadableRoster and rosterReadUnavailable)
end

function AngryEra:GetDisplayedMeta()
    local meta = { LAYOUT = layoutSource }
    if autoApplyLayoutValue ~= nil then
        meta[autoApplyLayoutKey] = autoApplyLayoutValue
    end
    return meta
end

function AngryEra:GetDisplayedVars()
    return layoutVars
end

function AngryEra:GetActiveDisplayReference()
    return activeReference
end

function AngryEra:IsPlayerRaidLeader()
    return localRaidLeader
end

function AngryEra:IsLocalAngryEraAuthority()
    return localRaidLeader
end

function AngryEra:ScheduleTimer(method, delay, ...)
    if failScheduleTimer then
        return nil
    end
    timerOrdinal = timerOrdinal + 1
    local timer = {
        At = now + delay,
        Method = method,
        Args = { ... },
        Ordinal = timerOrdinal,
    }
    timers[#timers + 1] = timer
    return timer
end

function AngryEra:CancelTimer(timer)
    timer.Canceled = true
end

function AngryEra:OnGroupLayoutApplyFinished(success, result, origin, reference)
    finishEvents[#finishEvents + 1] = {
        Success = success,
        Result = result,
        Origin = origin,
        Reference = reference,
        At = now,
    }
end

local function Reference(syncId, revision, revisionId, contextRevisionId)
    return {
        SyncId = syncId or "page-a",
        Revision = revision or 1,
        RevisionId = revisionId or "revision-a",
        ContextRevisionId = contextRevisionId or "context-a",
    }
end

local function NextTimer()
    local selected
    for _, timer in ipairs(timers) do
        if
            not timer.Canceled
            and not timer.Fired
            and (not selected or timer.At < selected.At or timer.At == selected.At and timer.Ordinal < selected.Ordinal)
        then
            selected = timer
        end
    end
    return selected
end

local function ActiveTimerCount()
    local count = 0
    for _, timer in ipairs(timers) do
        if not timer.Canceled and not timer.Fired then
            count = count + 1
        end
    end
    return count
end

local function FireTimer(timer)
    timer.Fired = true
    now = timer.At
    local callback = type(timer.Method) == "string" and AngryEra[timer.Method] or timer.Method
    assert(type(callback) == "function", "scheduled callback must exist")
    callback(AngryEra, timer.Args[1], timer.Args[2], timer.Args[3], timer.Args[4])
end

local function Advance(seconds)
    local target = now + seconds
    local guard = 0
    while true do
        local timer = NextTimer()
        if not timer or timer.At > target then
            break
        end
        guard = guard + 1
        assert(guard < 1000, "timer loop should remain bounded")
        FireTimer(timer)
    end
    now = target
end

local function RunTimers()
    local guard = 0
    while true do
        local timer = NextTimer()
        if not timer then
            return
        end
        guard = guard + 1
        assert(guard < 1000, "asynchronous apply should settle")
        FireTimer(timer)
    end
end

local function FindMember(name)
    for _, member in ipairs(raidMembers) do
        if member.Name == name then
            return member
        end
    end
end

local function Setup(members, source, variables)
    AngryEra:ResetGroupLayoutApplyState()
    raidMembers = members
    layoutSource = source
    layoutVars = variables
    activeReference = Reference()
    inRaid = true
    inCombat = false
    combatUnits = {}
    applyAllowed = true
    permissionRequiresReadableRoster = false
    autoApplyLayoutValue = nil
    autoApplyLayoutKey = "AUTOAPPLYLAYOUT"
    localRaidLeader = false
    failRaidApi = false
    failScheduleTimer = false
    rosterReadUnavailable = false
    autoAcknowledgeRaidApi = true
    afterRaidApiCall = nil
    operations = {}
    finishEvents = {}
    now = 0
    timers = {}
    timerOrdinal = 0
end

local function RequestAndFinish(origin)
    local eventCount = #finishEvents
    local accepted, status = AngryEra:RequestGroupLayoutApply(origin)
    if not accepted or type(status) == "number" then
        return accepted, status
    end
    assert(status == "started" or status == "in-progress", "fixture request should start immediately")
    RunTimers()
    assert(#finishEvents == eventCount + 1, "an asynchronous request should finish exactly once")
    local event = finishEvents[#finishEvents]
    return event.Success, event.Result
end

local function Apply(members, source, variables, allowed)
    Setup(members, source, variables)
    applyAllowed = allowed ~= false
    return RequestAndFinish("manual")
end

-- Permission checks fail closed before any operation and manual validation
-- failures remain synchronous (the caller owns their user-facing message).
local applied, reason = Apply({ { Name = "A-Home", Subgroup = 1 } }, "G/1: A", nil, false)
assert(not applied and reason == "not-authorized", "an unauthorized caller cannot apply a layout")
assert(#operations == 0 and #finishEvents == 0, "authorization failure performs no async notification or mutation")

applied, reason = Apply({ { Name = "A-Home", Subgroup = 1 } }, "G/1: A")
assert(applied and reason == 0, "an already-satisfied manual layout returns its move count immediately")
assert(#finishEvents == 0, "an immediate numeric manual result does not use the asynchronous hook")

local permissionHelper = AngryEra.CanLocalPlayerApplyRaidLayout
AngryEra.CanLocalPlayerApplyRaidLayout = nil
applied, reason = Apply({ { Name = "A-Home", Subgroup = 1 } }, "G/1: A")
assert(not applied and reason == "not-authorized", "a missing permission helper fails closed")
AngryEra.CanLocalPlayerApplyRaidLayout = function()
    error("permission lookup failed")
end
applied, reason = Apply({ { Name = "A-Home", Subgroup = 1 } }, "G/1: A")
assert(not applied and reason == "not-authorized", "a failing permission helper fails closed")
AngryEra.CanLocalPlayerApplyRaidLayout = permissionHelper

applied, reason = Apply({
    { Name = "Zed-Other", Subgroup = 1 },
    { Name = "Zed-Home", Subgroup = 2 },
}, "Home/2: Zed")
assert(not applied and reason == "unresolved-member", "a same-realm collision still requires Name-Realm")

applied, reason = Apply({
    { Name = "Zed-Other", Subgroup = 1 },
    { Name = "Zed-Third", Subgroup = 2 },
}, "Ambiguous/2: Zed")
assert(not applied and reason == "unresolved-member", "a duplicated short name is ambiguous")

applied, reason = Apply({ { Name = "Zed-Other", Subgroup = 1 } }, "Cross/2: Zed")
assert(applied and reason == 1, "a unique cross-realm short name can be applied")
assert(#operations == 1 and operations[1].Name == "Zed-Other", "the canonical member is moved")

applied, reason = Apply({
    { Name = "Zed-Other", Subgroup = 1 },
    { Name = "Zed-Home", Subgroup = 2 },
    { Name = "Backup-Home", Subgroup = 1 },
}, "Priority/2: Zed > Backup")
assert(applied and reason == 1 and operations[1].Name == "Backup-Home", "priority skips an ambiguous candidate")

applied, reason = Apply({ { Name = "Zed-Home", Subgroup = 1 } }, "One/1: Zed; Two/2: Zed-Home")
assert(not applied and reason == "duplicate-member", "canonical duplicate assignments are rejected")
assert(#operations == 0, "duplicate validation finishes before mutation")

applied, reason = Apply({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "Move/2: Alice, Typo; Stay/1: Bob")
assert(not applied and reason == "unresolved-member", "one unresolved member rejects the whole layout")
assert(#operations == 0, "unresolved validation prevents a partial apply")

applied, reason = Apply({
    { Name = "A-Home", Subgroup = 2 },
    { Name = "B-Home", Subgroup = 2 },
    { Name = "C-Home", Subgroup = 2 },
    { Name = "D-Home", Subgroup = 2 },
    { Name = "M1-Home", Subgroup = 1, Class = "MAGE" },
    { Name = "M2-Home", Subgroup = 1, Class = "MAGE" },
    { Name = "M3-Home", Subgroup = 1, Class = "MAGE" },
    { Name = "M4-Home", Subgroup = 1, Class = "MAGE" },
    { Name = "M5-Home", Subgroup = 1, Class = "MAGE" },
}, "Over/1: A, B, C, D, {{Fill}}", { Fill = "*MAGE x5" })
assert(not applied and reason == "subgroup-oversubscribed", "expanded layouts enforce subgroup capacity")

local roleVariables =
    assert(variableHelpers.MergeVariableLayers({}, "PRIEST1=Alice\nPALADIN1=Bob\nHEALER*=PRIEST*,PALADIN*"))
applied, reason = Apply({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "Healers/2: {{HEALER1}}, {{HEALER2}}", roleVariables)
assert(applied and reason == 2 and #operations == 2, "generated families apply as ordinary variables")

roleVariables =
    assert(variableHelpers.MergeVariableLayers({}, "PRIEST1=Alice\nPALADIN1=Alice\nHEALER*=PRIEST*,PALADIN*"))
applied, reason = Apply({
    { Name = "Alice-Home", Subgroup = 1 },
}, "Healers/2: {{HEALER1}}, {{HEALER2}}", roleVariables)
assert(not applied and reason == "duplicate-member", "duplicate generated values fail before mutation")

-- Local combat lockdown queues the exact page without capturing a stale index
-- or running a 0.10-second poll loop. A remote member's combat flag alone does
-- not block Blizzard's local protected call.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "Move/2: Bob")
combatUnits.raid2 = true
inCombat = true
applied, reason = AngryEra:RequestGroupLayoutApply()
assert(applied and reason == "queued", "local combat lockdown should queue the request")
assert(#operations == 0 and ActiveTimerCount() == 0, "combat queueing should be non-destructive and event-driven")
Advance(5)
assert(#operations == 0, "waiting in combat should not poll or mutate")
raidMembers = {
    { Name = "Bob-Home", Subgroup = 1 },
    { Name = "Alice-Home", Subgroup = 1 },
}
inCombat = false
applied, reason = AngryEra:FlushPendingGroupLayoutApply()
assert(applied and reason == "started", "combat-end flush should start the queued request")
assert(operations[1].Name == "Bob-Home" and operations[1].Index == 1, "post-combat planning uses the live index")
RunTimers()
assert(finishEvents[1].Success and finishEvents[1].Result == 1, "the queued request should finish once")

-- Reindexing after the first acknowledged move cannot stale the second call.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "First/2: Alice; Second/3: Bob")
afterRaidApiCall = function()
    if #operations == 1 then
        raidMembers = { raidMembers[2], raidMembers[1] }
    end
end
applied, reason = AngryEra:RequestGroupLayoutApply()
assert(applied and reason == "started", "a multi-operation request starts asynchronously")
RunTimers()
assert(#operations == 2, "both required members should move")
assert(operations[1].Name == "Alice-Home", "the first operation targets Alice")
assert(operations[2].Name == "Bob-Home" and operations[2].Index == 1, "the second operation refreshes Bob's index")
assert(operations[2].At - operations[1].At >= 0.25, "raid API calls are separated by at least 250ms")

-- A complete full-raid cycle also survives roster reindexing after every API
-- acknowledgement. The driver must continue targeting identities, not the
-- indices captured by an earlier plan.
local fullRaidMembers = {}
for index = 1, 40 do
    fullRaidMembers[index] = {
        Name = ("Player%02d-Home"):format(index),
        Subgroup = math.floor((index - 1) / 5) + 1,
    }
end
local fullRaidLayoutGroups = {}
for targetSubgroup = 1, 8 do
    local sourceSubgroup = targetSubgroup == 1 and 8 or targetSubgroup - 1
    local names = {}
    for offset = 1, 5 do
        local index = (sourceSubgroup - 1) * 5 + offset
        names[#names + 1] = ("Player%02d-Home"):format(index)
    end
    fullRaidLayoutGroups[#fullRaidLayoutGroups + 1] = ("Group %d/%d: %s"):format(
        targetSubgroup,
        targetSubgroup,
        table.concat(names, ", ")
    )
end
Setup(fullRaidMembers, table.concat(fullRaidLayoutGroups, "; "))
afterRaidApiCall = function()
    local first = table.remove(raidMembers, 1)
    raidMembers[#raidMembers + 1] = first
end
applied, reason = AngryEra:RequestGroupLayoutApply()
assert(applied and reason == "started", "a complete full-raid cycle should start asynchronously")
RunTimers()
assert(#operations == 35, "the full-raid cycle should issue the planned thirty-five swaps")
AssertOnlySwaps(operations, "the asynchronous full-raid cycle must not overfill a subgroup")
assert(
    #finishEvents == 1 and finishEvents[1].Success and finishEvents[1].Result == 35,
    "the full-raid cycle should report one successful completion"
)
for index = 1, 40 do
    local member = assert(FindMember(("Player%02d-Home"):format(index)), "every full-raid member should remain present")
    local originalSubgroup = math.floor((index - 1) / 5) + 1
    assert(member.Subgroup == originalSubgroup % 8 + 1, "every full-raid member should reach the target subgroup")
end

-- Only one raid API operation may be outstanding. A second operation cannot be
-- sent until a fresh roster snapshot acknowledges the first.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "First/2: Alice; Second/3: Bob")
autoAcknowledgeRaidApi = false
applied, reason = AngryEra:RequestGroupLayoutApply()
assert(applied and reason == "started" and #operations == 1, "only the first operation is issued")
Advance(1)
assert(#operations == 1 and #finishEvents == 0, "an unacknowledged call blocks every later call")
FindMember("Alice-Home").Subgroup = 2
Advance(0.11)
assert(#operations == 2 and operations[2].Name == "Bob-Home", "fresh acknowledgement releases the next call")
FindMember("Bob-Home").Subgroup = 3
Advance(0.11)
assert(#finishEvents == 1 and finishEvents[1].Success, "the asynchronous completion hook fires exactly once")

-- Classic can briefly advertise the full raid count while roster slots are
-- unreadable. While a call is outstanding that is a retryable snapshot, not a
-- terminal roster error.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
AngryEra:RequestGroupLayoutApply()
permissionRequiresReadableRoster = true
rosterReadUnavailable = true
Advance(0.11)
assert(
    #finishEvents == 0 and ActiveTimerCount() == 1,
    "an incomplete acknowledgement roster is retried before permission is rechecked"
)
rosterReadUnavailable = false
Advance(0.11)
assert(
    #finishEvents == 1 and finishEvents[1].Success and finishEvents[1].Result == 1,
    "the recovered complete roster can acknowledge the call"
)

-- A missing roster acknowledgement times out once and never emits another call.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
autoAcknowledgeRaidApi = false
AngryEra:RequestGroupLayoutApply()
Advance(8.2)
assert(#operations == 1, "a timed-out operation is never retried blindly")
assert(
    #finishEvents == 1 and not finishEvents[1].Success and finishEvents[1].Result == "raid-api-timeout",
    "acknowledgement timeout reports one terminal failure"
)

-- Combat beginning between acknowledged operations cancels the pending timer.
-- The event-driven flush replans from fresh state when local combat ends.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "First/2: Alice; Second/3: Bob")
AngryEra:RequestGroupLayoutApply()
Advance(0.11)
assert(#operations == 1 and ActiveTimerCount() == 1, "the second operation is waiting for the call interval")
inCombat = true
assert(AngryEra:PauseGroupLayoutApplyForCombat(), "combat entry should pause an active apply")
assert(ActiveTimerCount() == 0, "combat entry cancels a not-yet-issued operation timer")
Advance(4)
assert(#operations == 1, "no later operation is sent during combat")
inCombat = false
applied, reason = AngryEra:FlushPendingGroupLayoutApply()
assert(applied and reason == "in-progress" and #operations == 2, "combat-end flush resumes with a fresh plan")
RunTimers()
assert(finishEvents[1].Success and finishEvents[1].Result == 2, "the paused request completes")

-- If combat starts before the first acknowledgement, that operation is still
-- monitored; after acknowledgement the driver sleeps for the rest of combat.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "First/2: Alice; Second/3: Bob")
inCombat = true
AngryEra:RequestGroupLayoutApply()
assert(#operations == 0, "initial local combat queues before any operation")
inCombat = false
AngryEra:FlushPendingGroupLayoutApply()
inCombat = true
Advance(0.11)
assert(#operations == 1 and ActiveTimerCount() == 0, "acknowledged work pauses without encounter-long polling")
inCombat = false
AngryEra:FlushPendingGroupLayoutApply()
RunTimers()
assert(#operations == 2 and finishEvents[1].Success, "unit-combat flush resumes the pending request")

-- A page replacement during an outstanding operation cancels old work but the
-- latest request cannot start until that old operation acknowledges.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "Old/2: Alice")
autoApplyLayoutValue = true
localRaidLeader = true
AngryEra:ObserveDisplayedRaidLayout(activeReference)
autoAcknowledgeRaidApi = false
AngryEra:RequestGroupLayoutApply()
local replacement = Reference("page-b", 1, "revision-b", "context-b")
activeReference = replacement
layoutSource = "New/3: Bob"
applied, reason = AngryEra:ObserveDisplayedRaidLayout(replacement)
assert(applied and reason == "queued", "the newest page should replace old pending work")
Advance(0.5)
assert(#operations == 1 and operations[1].Name == "Alice-Home", "new work waits for the old acknowledgement")
FindMember("Alice-Home").Subgroup = 2
Advance(0.11)
assert(
    #finishEvents == 1 and finishEvents[1].Result == "display-changed",
    "the old request terminates once its call is acknowledged"
)
Advance(0.11)
assert(#operations == 2 and operations[2].Name == "Bob-Home", "only then may the latest page issue a call")
FindMember("Bob-Home").Subgroup = 3
Advance(0.11)
assert(#finishEvents == 2 and finishEvents[2].Success, "the replacement request finishes independently")

-- If a replacement cannot secure its first timer after the old call settles,
-- it fails terminally instead of remaining silently stranded.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "Old/2: Alice")
autoAcknowledgeRaidApi = false
AngryEra:RequestGroupLayoutApply()
activeReference = Reference("page-b", 1, "revision-b", "context-b")
layoutSource = "New/3: Bob"
applied, reason = AngryEra:RequestGroupLayoutApply()
assert(applied and reason == "queued", "the timer-failure replacement should queue behind the old call")
failScheduleTimer = true
FindMember("Alice-Home").Subgroup = 2
Advance(0.11)
assert(#finishEvents == 2, "both the superseded request and stranded replacement should finish")
assert(finishEvents[1].Result == "superseded", "the acknowledged old request reports supersession")
assert(finishEvents[2].Result == "timer-unavailable", "the replacement reports its scheduling failure")
assert(ActiveTimerCount() == 0, "a scheduling failure leaves no hidden work")
applied, reason = AngryEra:FlushPendingGroupLayoutApply()
assert(not applied and reason == "no-pending-layout", "a failed replacement is consumed")

-- Any membership change aborts the frozen apply instead of mixing two rosters.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "First/2: Alice; Second/3: Bob")
AngryEra:RequestGroupLayoutApply()
raidMembers[#raidMembers + 1] = { Name = "Charlie-Home", Subgroup = 1 }
Advance(0.11)
assert(#operations == 1, "membership changes prevent every later operation")
assert(
    #finishEvents == 1 and not finishEvents[1].Success and finishEvents[1].Result == "roster-changed",
    "membership changes produce one safe terminal failure"
)

-- Every field in the display tuple is identity-bearing for queued requests.
for _, changed in ipairs({
    { Field = "SyncId", Value = "page-b" },
    { Field = "Revision", Value = 2 },
    { Field = "RevisionId", Value = "revision-b" },
    { Field = "ContextRevisionId", Value = "context-b" },
}) do
    Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
    inCombat = true
    applied, reason = AngryEra:RequestGroupLayoutApply()
    assert(applied and reason == "queued", "the exact-reference fixture should queue")
    local changedReference = Reference()
    changedReference[changed.Field] = changed.Value
    applied, reason = AngryEra:ObserveDisplayedRaidLayout(changedReference)
    assert(not applied and reason == "canceled", changed.Field .. " must cancel queued work")
    activeReference = changedReference
    inCombat = false
    applied, reason = AngryEra:FlushPendingGroupLayoutApply()
    assert(not applied and reason == "no-pending-layout", changed.Field .. " cancellation must not resurrect")
    assert(#operations == 0, changed.Field .. " cancellation must not mutate the raid")
end

-- A -> B -> A creates a fresh final A request; it cannot revive the original
-- request that B canceled.
Setup({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "A/2: Alice")
autoApplyLayoutValue = true
localRaidLeader = true
AngryEra:ObserveDisplayedRaidLayout(activeReference)
inCombat = true
applied, reason = AngryEra:RequestGroupLayoutApply("manual")
assert(applied and reason == "queued", "the original A request should queue")
activeReference = Reference("page-b", 1, "revision-b", "context-b")
layoutSource = "B/3: Bob"
applied, reason = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(applied and reason == "queued", "B should replace the original A request")
activeReference = Reference("page-a", 1, "revision-a", "context-a")
layoutSource = "A/2: Alice"
applied, reason = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(applied and reason == "queued", "returning to A should create a fresh request")
inCombat = false
AngryEra:FlushPendingGroupLayoutApply()
RunTimers()
assert(#operations == 1 and operations[1].Name == "Alice-Home", "only the fresh final A request may mutate")
assert(FindMember("Bob-Home").Subgroup == 1, "the superseded B layout must not run")
assert(finishEvents[#finishEvents].Success, "the fresh final A request should complete")

-- Permission is rechecked after combat, and a manual assistant remains allowed.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
inCombat = true
AngryEra:RequestGroupLayoutApply()
applyAllowed = false
inCombat = false
applied, reason = AngryEra:FlushPendingGroupLayoutApply()
assert(not applied and reason == "not-authorized", "post-combat permission loss fails closed")
assert(#operations == 0 and #finishEvents == 1, "an async permission loss finishes once without mutation")

Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
localRaidLeader = false
applied, reason = RequestAndFinish("manual")
assert(applied and reason == 1, "a qualified assistant may still apply manually")

-- Automatic observation is controller-only. A page seen during transient
-- authority ordering retains one exact intent that settled control can retry.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
local observed, observationStatus = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(
    not observed and observationStatus == "observed",
    "the first displayed page only primes automatic layout tracking"
)
activeReference = Reference("page-b", 1, "revision-b", "context-b")
observed, observationStatus = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(
    not observed and observationStatus == "auto-disabled" and #operations == 0,
    "page swaps do not apply layouts without effective $AUTOAPPLYLAYOUT metadata"
)

for _, legacyValue in ipairs({ "true", "TRUE", 1 }) do
    Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
    autoApplyLayoutValue = legacyValue
    localRaidLeader = true
    AngryEra:ObserveDisplayedRaidLayout(activeReference)
    activeReference = Reference("page-b", 1, "revision-b", "context-b")
    applied, reason = AngryEra:ObserveDisplayedRaidLayout(activeReference)
    assert(
        not applied and reason == "auto-disabled" and #operations == 0,
        "untyped automatic-layout values should remain disabled"
    )
end

Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
autoApplyLayoutKey = "autoapplylayout"
autoApplyLayoutValue = true
localRaidLeader = true
AngryEra:ObserveDisplayedRaidLayout(activeReference)
activeReference = Reference("page-b", 1, "revision-b", "context-b")
localRaidLeader = false
applied, reason = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(not applied and reason == "not-raid-controller", "non-controllers never auto-apply")
applied, reason = AngryEra:RetryObservedGroupLayoutAutoApply()
assert(not applied and reason == "not-raid-controller" and #operations == 0, "the intent waits for settled control")
localRaidLeader = true
applied, reason = AngryEra:RetryObservedGroupLayoutAutoApply()
assert(applied and reason == "started", "promotion retries the still-active page exactly once")
RunTimers()
assert(#finishEvents == 1 and finishEvents[1].Origin == "auto", "the retried automatic request completes")
applied, reason = AngryEra:RetryObservedGroupLayoutAutoApply()
assert(not applied and reason == "no-auto-intent", "a consumed intent cannot replay")

-- Exact page mismatch and a nearer false metadata override both clear the
-- retained auto intent.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
autoApplyLayoutValue = true
localRaidLeader = true
AngryEra:ObserveDisplayedRaidLayout(activeReference)
activeReference = Reference("page-b", 1, "revision-b", "context-b")
localRaidLeader = false
AngryEra:ObserveDisplayedRaidLayout(activeReference)
local mismatch = Reference("page-c", 1, "revision-c", "context-c")
activeReference = mismatch
assert(AngryEra:InvalidatePendingGroupLayoutApply(mismatch), "a different tuple clears the retained intent")
localRaidLeader = true
applied, reason = AngryEra:RetryObservedGroupLayoutAutoApply()
assert(not applied and reason == "no-auto-intent", "a stale automatic intent never crosses pages")

Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
autoApplyLayoutValue = true
localRaidLeader = true
AngryEra:ObserveDisplayedRaidLayout(activeReference)
activeReference = Reference("page-b", 1, "revision-b", "context-b")
localRaidLeader = false
AngryEra:ObserveDisplayedRaidLayout(activeReference)
autoApplyLayoutValue = false
applied, reason = AngryEra:RetryObservedGroupLayoutAutoApply()
assert(not applied and reason == "auto-disabled", "disabling automatic layouts clears retained intent")
autoApplyLayoutValue = true
localRaidLeader = true
applied, reason = AngryEra:RetryObservedGroupLayoutAutoApply()
assert(not applied and reason == "no-auto-intent", "re-enabling cannot revive an old-page intent")

-- Transition observation uses the accepted snapshot's authoritative metadata,
-- rather than a receiver-private or stale local category result.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
autoApplyLayoutValue = true
localRaidLeader = true
AngryEra:ObserveDisplayedRaidLayout(activeReference)
activeReference = Reference("page-b", 1, "revision-b", "context-b")
activeReference.Meta = { AUTOAPPLYLAYOUT = false, LAYOUT = layoutSource }
applied, reason = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(not applied and reason == "auto-disabled", "the accepted page metadata can disable automatic application")
assert(#operations == 0, "an authoritative false override never rearranges the raid")

-- Combat execution rechecks the current metadata and consumes stale automatic
-- work if the effective value becomes false before any raid mutation.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
autoApplyLayoutValue = true
localRaidLeader = true
AngryEra:ObserveDisplayedRaidLayout(activeReference)
inCombat = true
activeReference = Reference("page-b", 1, "revision-b", "context-b")
applied, reason = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(applied and reason == "queued", "enabled destination metadata queues automatic combat work")
autoApplyLayoutValue = false
inCombat = false
applied, reason = AngryEra:FlushPendingGroupLayoutApply()
assert(not applied and reason == "auto-disabled", "combat flush rechecks current automatic-layout metadata")
assert(#operations == 0 and #finishEvents == 0, "disabled stale automatic work remains a quiet no-op")

-- A controller handoff clears combat-queued automatic work before the new
-- authority can begin publishing the retained page. The protocol runtime calls
-- this same reset boundary for every accepted grant/revoke transition.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
autoApplyLayoutValue = true
localRaidLeader = true
AngryEra:ObserveDisplayedRaidLayout(activeReference)
inCombat = true
activeReference = Reference("page-b", 1, "revision-b", "context-b")
applied, reason = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(applied and reason == "queued", "authority-handoff fixture should have one queued automatic apply")
localRaidLeader = false
assert(AngryEra:ResetGroupLayoutApplyState(true), "authority handoff should cancel the queued automatic apply")
assert(
    #finishEvents == 1 and finishEvents[1].Origin == "auto" and finishEvents[1].Result == "canceled",
    "handoff cancellation should terminate the old authority's exact request once"
)
inCombat = false
applied, reason = AngryEra:FlushPendingGroupLayoutApply()
assert(not applied and reason == "no-pending-layout", "post-handoff combat flush must find no stale layout")
assert(#operations == 0, "the former authority must never mutate the raid after handoff")
localRaidLeader = true
applied, reason = AngryEra:RetryObservedGroupLayoutAutoApply()
assert(not applied and reason == "no-auto-intent", "handoff reset must also discard the retained auto intent")
activeReference = Reference("page-c", 1, "revision-c", "context-c")
applied, reason = AngryEra:ObserveDisplayedRaidLayout(activeReference)
assert(applied and reason == "started", "new authority's first real page transition must still auto-apply")
RunTimers()
assert(
    #operations == 1 and operations[1].Kind == "set" and operations[1].Subgroup == 2,
    "handoff observation baseline should preserve normal destination layout application"
)

-- Disabling automatic behavior cancels only auto-origin work; manual work is
-- retained through combat.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
inCombat = true
AngryEra:RequestGroupLayoutApply("manual")
assert(not AngryEra:CancelAutomaticGroupLayoutApply(), "manual queued work is not automatic")
inCombat = false
AngryEra:FlushPendingGroupLayoutApply()
RunTimers()
assert(finishEvents[1].Success and finishEvents[1].Origin == "manual", "manual work survives auto cancellation")

-- Actionable automatic failures use the completion hook, while expected quiet
-- states do not. Immediate manual failures were already verified above.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "One/1: Alice; Two/2: Alice-Home")
autoApplyLayoutValue = true
localRaidLeader = true
applied, reason = AngryEra:RequestGroupLayoutApply("auto")
assert(not applied and reason == "duplicate-member", "an invalid automatic layout fails immediately")
assert(#finishEvents == 1 and finishEvents[1].Result == "duplicate-member", "actionable auto failure is reported")

Setup({ { Name = "Alice-Home", Subgroup = 1 } }, nil)
autoApplyLayoutValue = true
localRaidLeader = true
applied, reason = AngryEra:RequestGroupLayoutApply("auto")
assert(not applied and reason == "no-layout" and #finishEvents == 0, "no-layout is quiet for automatic work")

Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
autoApplyLayoutValue = true
localRaidLeader = false
applied, reason = AngryEra:RequestGroupLayoutApply("auto")
assert(not applied and reason == "not-raid-controller" and #finishEvents == 0, "non-controller auto rejection is quiet")

-- Blizzard API errors are contained, cancel the pre-secured poll, and leave no
-- operation that could overlap a later request.
Setup({ { Name = "Alice-Home", Subgroup = 1 } }, "Move/2: Alice")
failRaidApi = true
local apiCallProtected, apiApplied, apiReason = pcall(AngryEra.RequestGroupLayoutApply, AngryEra)
assert(apiCallProtected, "a Blizzard raid API error must not escape the addon callback")
assert(not apiApplied and apiReason == "raid-api-failed", "the protected error should be reported")
assert(#operations == 0 and ActiveTimerCount() == 0, "a failed API call leaves no mutation or poll")

print("Raid layout planner and asynchronous apply tests passed.")
