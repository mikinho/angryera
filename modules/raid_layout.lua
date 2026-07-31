-- -------------------------------------------------------------------------------
-- Angry Era: modules/raid_layout.lua
--
-- Applies a group layout to the actual raid by moving members between raid
-- subgroups. The move planner is pure and deterministic; the driver is gated to
-- an authorized raid member. Explicit requests made in combat
-- wait for the exact displayed page/context, and optional display-driven applies
-- are restricted to the current AngryEra authority.
--
-- SetRaidSubgroup/SwapRaidSubgroup are #nocombat and cap subgroups at 5, so the
-- plan uses SetRaidSubgroup into a non-full target and SwapRaidSubgroup
-- otherwise, and never produces an intermediate state above the cap.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.raid_layout = {}
local raid_layout = AngryEra.utils.raid_layout
local layout = AngryEra.utils.layout
local roster = AngryEra.utils.roster
local helpers = AngryEra.utils.helpers

local GROUP_CAP = 5
local MAX_OPS = 200
local POLL_INTERVAL = 0.10
local MIN_CALL_INTERVAL = 0.25
local ACK_TIMEOUT = 8
local pendingGroupLayoutApply
local activeGroupLayoutApply
local observedDisplayedPage
local observedGroupLayoutAutoIntent
local hasObservedDisplayedPage = false
local groupLayoutApplyTimer
local groupLayoutApplyGeneration = 0
local lastRaidApiCallAt

local function SortedKeys(map)
    local keys = {}
    for key in pairs(map) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

--- Plans the subgroup moves that transform the current raid into the target.
-- @tparam table current `{ [raidIndex] = subgroup }` for every raid member.
-- @tparam table want `{ [raidIndex] = subgroup }` for members the layout binds.
-- @tparam[opt] table options `{ GroupCap = 5 }`.
-- @treturn table ops Ordered `{Kind="set",Index,Subgroup}` / `{Kind="swap",Index1,Index2}`.
-- @treturn boolean ok
-- @treturn string|nil err
function raid_layout.PlanSubgroupMoves(current, want, options)
    local cap = (options and options.GroupCap) or GROUP_CAP
    local groupOf = {}
    local counts = {}
    for index, subgroup in pairs(current) do
        groupOf[index] = subgroup
        counts[subgroup] = (counts[subgroup] or 0) + 1
    end

    local wantCount = {}
    for index, subgroup in pairs(want) do
        if groupOf[index] == nil then
            return {}, false, "unknown-member"
        end
        wantCount[subgroup] = (wantCount[subgroup] or 0) + 1
        if wantCount[subgroup] > cap then
            return {}, false, "subgroup-oversubscribed"
        end
    end

    local assigned = SortedKeys(want)
    local allIndices = SortedKeys(groupOf)

    local function FirstMisplaced()
        for _, index in ipairs(assigned) do
            if groupOf[index] ~= want[index] then
                return index
            end
        end
        return nil
    end

    -- Returns the first member on the shortest directed path from one subgroup
    -- to another. Each misplaced constrained member is an edge from their
    -- current subgroup to their desired subgroup.
    local function ShortestPathFirstIndex(startSubgroup, finishSubgroup, excludedIndex)
        local queue = { startSubgroup }
        local queueHead = 1
        local seen = {
            [startSubgroup] = true,
        }
        local firstIndexBySubgroup = {}
        local distanceBySubgroup = {
            [startSubgroup] = 0,
        }
        while queueHead <= #queue do
            local subgroup = queue[queueHead]
            queueHead = queueHead + 1
            for _, index in ipairs(assigned) do
                local desiredSubgroup = want[index]
                if index ~= excludedIndex and groupOf[index] == subgroup and desiredSubgroup ~= subgroup then
                    local firstIndex = firstIndexBySubgroup[subgroup] or index
                    local distance = distanceBySubgroup[subgroup] + 1
                    if desiredSubgroup == finishSubgroup then
                        return firstIndex, distance
                    end
                    if not seen[desiredSubgroup] then
                        seen[desiredSubgroup] = true
                        firstIndexBySubgroup[desiredSubgroup] = firstIndex
                        distanceBySubgroup[desiredSubgroup] = distance
                        queue[#queue + 1] = desiredSubgroup
                    end
                end
            end
        end
        return nil
    end

    -- Resolve the shortest available cycle before consuming empty capacity or
    -- an unconstrained filler. A two-edge cycle is a reciprocal swap that fixes
    -- both members; a longer k-edge cycle completes in k-1 swaps.
    local function BestCycleSwap()
        local bestIndex
        local bestSwapWith
        local bestLength
        for _, index in ipairs(assigned) do
            local fromSubgroup = groupOf[index]
            local targetSubgroup = want[index]
            if fromSubgroup ~= targetSubgroup then
                local swapWith, returnPathLength = ShortestPathFirstIndex(targetSubgroup, fromSubgroup, index)
                if swapWith then
                    local cycleLength = returnPathLength + 1
                    if not bestLength or cycleLength < bestLength then
                        bestIndex = index
                        bestSwapWith = swapWith
                        bestLength = cycleLength
                    end
                end
            end
        end
        return bestIndex, bestSwapWith
    end

    local ops = {}
    local guard = 0
    while true do
        guard = guard + 1
        if guard > MAX_OPS then
            return {}, false, "plan-too-large"
        end
        local cycleIndex, cycleSwapWith = BestCycleSwap()
        if cycleIndex then
            ops[#ops + 1] = { Kind = "swap", Index1 = cycleIndex, Index2 = cycleSwapWith }
            groupOf[cycleIndex], groupOf[cycleSwapWith] = groupOf[cycleSwapWith], groupOf[cycleIndex]
        else
            local i = FirstMisplaced()
            if not i then
                break
            end
            local targetSub = want[i]
            local fromSub = groupOf[i]
            if (counts[targetSub] or 0) < cap then
                ops[#ops + 1] = { Kind = "set", Index = i, Subgroup = targetSub }
                counts[fromSub] = counts[fromSub] - 1
                counts[targetSub] = (counts[targetSub] or 0) + 1
                groupOf[i] = targetSub
            else
                local swapWith
                -- Prefer an unconstrained occupant when no constrained cycle
                -- exists, avoiding an unnecessary extra move for another
                -- assigned member.
                for _, index in ipairs(allIndices) do
                    if index ~= i and groupOf[index] == targetSub and want[index] == nil then
                        swapWith = index
                        break
                    end
                end
                if not swapWith then
                    for _, index in ipairs(allIndices) do
                        if index ~= i and groupOf[index] == targetSub and want[index] ~= targetSub then
                            swapWith = index
                            break
                        end
                    end
                end
                if not swapWith then
                    return {}, false, "subgroup-blocked"
                end
                ops[#ops + 1] = { Kind = "swap", Index1 = i, Index2 = swapWith }
                groupOf[i], groupOf[swapWith] = targetSub, fromSub
            end
        end
    end
    return ops, true
end

local DriveActiveApply
local StartPendingApply

local function IsInRaidGroup()
    return type(IsInRaid) == "function" and IsInRaid()
end

local function CanRearrangeRaid(self)
    if not IsInRaidGroup() or type(self.CanLocalPlayerApplyRaidLayout) ~= "function" then
        return false
    end
    local checked, allowed = pcall(self.CanLocalPlayerApplyRaidLayout, self)
    return checked and allowed == true
end

local function CopyDisplayReference(value)
    if
        type(value) ~= "table"
        or type(value.SyncId) ~= "string"
        or value.SyncId == ""
        or type(value.Revision) ~= "number"
        or value.Revision < 1
        or value.Revision % 1 ~= 0
        or type(value.RevisionId) ~= "string"
        or value.RevisionId == ""
        or type(value.ContextRevisionId) ~= "string"
        or value.ContextRevisionId == ""
    then
        return nil
    end
    return {
        SyncId = value.SyncId,
        Revision = value.Revision,
        RevisionId = value.RevisionId,
        ContextRevisionId = value.ContextRevisionId,
    }
end

local function SameDisplayReference(left, right)
    return type(left) == "table"
        and type(right) == "table"
        and left.SyncId == right.SyncId
        and left.Revision == right.Revision
        and left.RevisionId == right.RevisionId
        and left.ContextRevisionId == right.ContextRevisionId
end

local function CurrentDisplayReference(self)
    if type(self.GetActiveDisplayReference) ~= "function" then
        return nil
    end
    local called, reference = pcall(self.GetActiveDisplayReference, self)
    return called and CopyDisplayReference(reference) or nil
end

local function Now()
    if type(GetTimePreciseSec) == "function" then
        local called, value = pcall(GetTimePreciseSec)
        if called and type(value) == "number" then
            return value
        end
    end
    if type(GetTime) == "function" then
        local called, value = pcall(GetTime)
        if called and type(value) == "number" then
            return value
        end
    end
    return os and type(os.clock) == "function" and os.clock() or 0
end

local function UnitIsInCombat(unit)
    if type(UnitAffectingCombat) ~= "function" then
        return false
    end
    local called, inCombat = pcall(UnitAffectingCombat, unit)
    return called and inCombat == true
end

local function RaidIsInCombat()
    if type(InCombatLockdown) == "function" then
        local called, locked = pcall(InCombatLockdown)
        if called and locked == true then
            return true
        end
    end
    return UnitIsInCombat("player")
end

local function MetadataValue(meta, canonicalKey)
    if type(meta) ~= "table" then
        return nil
    end
    if rawget(meta, canonicalKey) ~= nil then
        return rawget(meta, canonicalKey)
    end
    for key, value in pairs(meta) do
        if type(key) == "string" and key:upper() == canonicalKey then
            return value
        end
    end
    return nil
end

local function MetadataFlagEnabled(value)
    return value == true
end

local function DisplayedMetadata(self)
    if type(self.GetDisplayedMeta) ~= "function" then
        return nil
    end
    local called, meta = pcall(self.GetDisplayedMeta, self)
    return called and type(meta) == "table" and meta or nil
end

-- The accepted snapshot is authoritative during a display transition,
-- including inherited context sent with a remote page. Later authorization
-- checks re-read the current displayed snapshot so combat-queued work cannot
-- outlive a nearer `$AUTOAPPLYLAYOUT=$false` override.
local function AutoApplyEnabled(self, snapshot)
    local meta = type(snapshot) == "table" and type(snapshot.Meta) == "table" and snapshot.Meta
        or DisplayedMetadata(self)
    return MetadataFlagEnabled(MetadataValue(meta, "AUTOAPPLYLAYOUT"))
end

local function IsLocalRaidController(self)
    if type(self.IsLocalAngryEraAuthority) ~= "function" then
        return false
    end
    local called, isAuthority = pcall(self.IsLocalAngryEraAuthority, self)
    return called and isAuthority == true
end

local function RequestStillAuthorized(self, request)
    if not IsInRaidGroup() then
        return false, "not-in-raid"
    end
    if not CanRearrangeRaid(self) then
        return false, "not-authorized"
    end
    if request.Origin == "auto" then
        if not AutoApplyEnabled(self) then
            return false, "auto-disabled"
        end
        if not IsLocalRaidController(self) then
            return false, "not-raid-controller"
        end
    end
    return true
end

local function DisplayedLayoutSource(self)
    local value = MetadataValue(DisplayedMetadata(self), "LAYOUT")
    return type(value) == "string" and value or nil
end

local function DisplayedVariables(self)
    if type(self.GetDisplayedVars) ~= "function" then
        return nil
    end
    local ok, vars = pcall(self.GetDisplayedVars, self)
    return ok and type(vars) == "table" and vars or nil
end

-- Reads names, current indices, and subgroup membership in one snapshot.
-- Desired members are stored by canonical full-name identity; indices from this
-- structure are used for at most one immediately following API call.
local function BuildRaidState()
    local state = {
        SubgroupByIndex = {},
        IndexByIdentity = {},
        IdentityByIndex = {},
        FullNameByIdentity = {},
    }
    local indicesByShortName = {}
    local classMembers = {}
    local subgroupMembers = {}
    local identities = {}
    local collected = 0
    local expectedCount
    local limit = type(MAX_RAID_MEMBERS) == "number" and MAX_RAID_MEMBERS or 40
    if type(GetRaidRosterInfo) ~= "function" then
        return state, nil, nil, "roster-unavailable"
    end
    if type(GetNumGroupMembers) == "function" then
        local called, count = pcall(GetNumGroupMembers)
        if not called or type(count) ~= "number" or count < 0 then
            return state, nil, nil, "roster-unavailable"
        end
        expectedCount = math.floor(count)
    end
    for index = 1, limit do
        local called, rawName, _, subgroup, _, _, class, _, online, isDead = pcall(GetRaidRosterInfo, index)
        if not called then
            return state, nil, nil, "roster-unavailable"
        end
        if rawName then
            collected = collected + 1
            local fullName = helpers.EnsureUnitFullName(rawName)
            if type(fullName) ~= "string" or fullName == "" then
                return state, nil, nil, "invalid-roster"
            end
            local identity = fullName:lower()
            if state.IndexByIdentity[identity] then
                return state, nil, nil, "invalid-roster"
            end
            local currentSubgroup = type(subgroup) == "number" and subgroup or 1
            state.SubgroupByIndex[index] = currentSubgroup
            state.IndexByIdentity[identity] = index
            state.IdentityByIndex[index] = identity
            state.FullNameByIdentity[identity] = fullName
            identities[#identities + 1] = identity
            local shortLower = identity:match("^([^-]+)")
            if shortLower then
                indicesByShortName[shortLower] = indicesByShortName[shortLower] or {}
                indicesByShortName[shortLower][#indicesByShortName[shortLower] + 1] = identity
            end
            if online and not isDead and type(class) == "string" then
                local upperClass = class:upper()
                classMembers[upperClass] = classMembers[upperClass] or {}
                classMembers[upperClass][#classMembers[upperClass] + 1] = fullName
                subgroupMembers[currentSubgroup] = subgroupMembers[currentSubgroup] or {}
                subgroupMembers[currentSubgroup][#subgroupMembers[currentSubgroup] + 1] = fullName
            end
        end
    end
    if expectedCount and collected ~= expectedCount then
        return state, nil, nil, "roster-unavailable"
    end
    table.sort(identities)
    state.MembershipSignature = table.concat(identities, "\031")

    local function ResolveRaidMember(name)
        if type(name) ~= "string" or name == "" then
            return nil, nil, "invalid-name"
        end
        local identity = name:lower()
        if name:find("-", 1, true) then
            local index = state.IndexByIdentity[identity]
            return index and state.FullNameByIdentity[identity] or nil, index, index and nil or "unknown-member"
        end
        local candidates = indicesByShortName[identity]
        if type(candidates) == "table" and #candidates == 1 then
            local uniqueIdentity = candidates[1]
            return state.FullNameByIdentity[uniqueIdentity], state.IndexByIdentity[uniqueIdentity]
        end
        return nil, nil, type(candidates) == "table" and #candidates > 1 and "ambiguous-member" or "unknown-member"
    end

    local providers = {
        ResolvePriorityValue = roster and (roster.ResolvePriorityFullName or roster.ResolvePriorityValue),
        ResolveRosterName = function(name)
            return (ResolveRaidMember(name))
        end,
        ClassMembers = function(class)
            return classMembers[class] or {}
        end,
        SubgroupMembers = function(subgroup)
            return subgroupMembers[subgroup] or {}
        end,
    }
    return state, ResolveRaidMember, providers
end

local function ResolveDesiredLayout(self, request)
    if not SameDisplayReference(request.Reference, CurrentDisplayReference(self)) then
        return nil, "display-changed"
    end
    local source = DisplayedLayoutSource(self)
    if not source then
        return nil, "no-layout"
    end
    local raidState, resolveRaidMember, providers, rosterError = BuildRaidState()
    if rosterError then
        return nil, rosterError
    end
    providers.Variables = DisplayedVariables(self)
    local resolved = layout.Resolve(layout.Parse(source), providers)
    if resolved.error then
        return nil, resolved.error
    end

    local wantByIdentity = {}
    local subgroupCounts = {}
    local ambiguous = false
    local unresolved = false
    local duplicate = false
    -- A syntactically valid name with no current roster match is an optional
    -- empty seat. This lets a complete raid template arrange the members
    -- already present while the raid fills. Ambiguity remains a whole-plan
    -- failure; guessing would make a protected subgroup change target-dependent.
    for _, group in ipairs(resolved.groups) do
        if type(group.subgroup) == "number" then
            for _, name in ipairs(group.members) do
                local fullName, _, resolutionError = resolveRaidMember(name)
                if fullName then
                    local identity = fullName:lower()
                    if wantByIdentity[identity] then
                        duplicate = true
                    else
                        wantByIdentity[identity] = group.subgroup
                        subgroupCounts[group.subgroup] = (subgroupCounts[group.subgroup] or 0) + 1
                    end
                elseif resolutionError == "ambiguous-member" then
                    ambiguous = true
                elseif resolutionError ~= "unknown-member" then
                    unresolved = true
                end
            end
        end
    end
    if duplicate or #resolved.duplicates > 0 then
        return nil, "duplicate-member"
    end
    if ambiguous then
        return nil, "ambiguous-member"
    end
    if unresolved then
        return nil, "unresolved-member"
    end
    if next(wantByIdentity) == nil then
        return nil, "no-bound-groups"
    end
    for _, count in pairs(subgroupCounts) do
        if count > GROUP_CAP then
            return nil, "subgroup-oversubscribed"
        end
    end
    return {
        WantByIdentity = wantByIdentity,
        MembershipSignature = raidState.MembershipSignature,
    }
end

local function NextIdentityOperation(active, raidState)
    if raidState.MembershipSignature ~= active.MembershipSignature then
        return nil, "roster-changed"
    end
    local wantByIndex = {}
    for identity, subgroup in pairs(active.WantByIdentity) do
        local index = raidState.IndexByIdentity[identity]
        if not index then
            return nil, "roster-changed"
        end
        wantByIndex[index] = subgroup
    end
    local operations, planned, planError = raid_layout.PlanSubgroupMoves(raidState.SubgroupByIndex, wantByIndex)
    if not planned then
        return nil, planError
    end
    local operation = operations[1]
    if not operation then
        return nil
    end
    if operation.Kind == "set" then
        local identity = raidState.IdentityByIndex[operation.Index]
        return {
            Kind = "set",
            Identity = identity,
            Index = operation.Index,
            TargetSubgroup = operation.Subgroup,
        }
    end
    local identity1 = raidState.IdentityByIndex[operation.Index1]
    local identity2 = raidState.IdentityByIndex[operation.Index2]
    return {
        Kind = "swap",
        Identity1 = identity1,
        Identity2 = identity2,
        Index1 = operation.Index1,
        Index2 = operation.Index2,
        TargetSubgroup1 = raidState.SubgroupByIndex[operation.Index2],
        TargetSubgroup2 = raidState.SubgroupByIndex[operation.Index1],
    }
end

local function OperationAcknowledged(operation, raidState)
    if operation.Kind == "set" then
        local index = raidState.IndexByIdentity[operation.Identity]
        return index and raidState.SubgroupByIndex[index] == operation.TargetSubgroup
    end
    local index1 = raidState.IndexByIdentity[operation.Identity1]
    local index2 = raidState.IndexByIdentity[operation.Identity2]
    return index1
        and index2
        and raidState.SubgroupByIndex[index1] == operation.TargetSubgroup1
        and raidState.SubgroupByIndex[index2] == operation.TargetSubgroup2
end

local function CancelApplyTimer(self)
    groupLayoutApplyGeneration = groupLayoutApplyGeneration + 1
    local timer = groupLayoutApplyTimer
    groupLayoutApplyTimer = nil
    if timer and type(self.CancelTimer) == "function" then
        pcall(self.CancelTimer, self, timer)
    end
end

local function ScheduleApplyPoll(self, delay)
    if type(self.ScheduleTimer) ~= "function" then
        return false, "timer-unavailable"
    end
    if groupLayoutApplyTimer then
        return true, groupLayoutApplyTimer
    end
    groupLayoutApplyGeneration = groupLayoutApplyGeneration + 1
    local generation = groupLayoutApplyGeneration
    local called, timer =
        pcall(self.ScheduleTimer, self, "PollGroupLayoutApply", math.max(delay or POLL_INTERVAL, 0), generation)
    if not called or not timer then
        return false, "timer-unavailable"
    end
    groupLayoutApplyTimer = timer
    return true, timer
end

local function NotifyFinished(self, success, result, request)
    if not request or request.Finished then
        return
    end
    request.Finished = true
    if
        request.Origin == "auto"
        and success ~= true
        and (result == "no-layout" or result == "auto-disabled" or result == "not-raid-controller")
    then
        return
    end
    if request.Notify ~= true or type(self.OnGroupLayoutApplyFinished) ~= "function" then
        return
    end
    pcall(
        self.OnGroupLayoutApplyFinished,
        self,
        success == true,
        result,
        request.Origin,
        CopyDisplayReference(request.Reference)
    )
end

local function FinishPending(self, success, result, request)
    NotifyFinished(self, success, result, request)
end

local function FinishActive(self, success, result)
    local active = activeGroupLayoutApply
    if not active then
        return
    end
    activeGroupLayoutApply = nil
    CancelApplyTimer(self)
    NotifyFinished(self, success, result, active)
    if pendingGroupLayoutApply and not RaidIsInCombat() then
        local scheduled, scheduleError = ScheduleApplyPoll(self, POLL_INTERVAL)
        if not scheduled then
            local pending = pendingGroupLayoutApply
            pendingGroupLayoutApply = nil
            FinishPending(self, false, scheduleError, pending)
        end
    end
end

local function QueueRequest(self, request)
    request.Async = true
    request.Notify = true
    local previous = pendingGroupLayoutApply
    if previous and SameDisplayReference(previous.Reference, request.Reference) then
        if request.Origin == "manual" then
            previous.Origin = "manual"
        end
        return true, "queued"
    end
    pendingGroupLayoutApply = request
    if previous then
        FinishPending(self, false, "superseded", previous)
    end
    if RaidIsInCombat() then
        if not (activeGroupLayoutApply and activeGroupLayoutApply.Outstanding) then
            CancelApplyTimer(self)
        end
        return true, "queued"
    end
    local scheduled, scheduleError = ScheduleApplyPoll(self, POLL_INTERVAL)
    if not scheduled then
        pendingGroupLayoutApply = nil
        FinishPending(self, false, scheduleError, request)
        return false, scheduleError
    end
    return true, "queued"
end

local function ValidateRequest(self, request)
    local allowed, permissionError = RequestStillAuthorized(self, request)
    if not allowed then
        return false, permissionError
    end
    if not DisplayedLayoutSource(self) then
        return false, "no-layout"
    end
    if not SameDisplayReference(request.Reference, CurrentDisplayReference(self)) then
        return false, "display-changed"
    end
    return true
end

local function StartApply(self, request)
    local valid, validationError = ValidateRequest(self, request)
    if not valid then
        NotifyFinished(self, false, validationError, request)
        return false, validationError
    end
    if RaidIsInCombat() then
        return QueueRequest(self, request)
    end
    local desired, resolveError = ResolveDesiredLayout(self, request)
    if not desired then
        NotifyFinished(self, false, resolveError, request)
        return false, resolveError
    end
    local raidState, _, _, rosterError = BuildRaidState()
    if rosterError then
        NotifyFinished(self, false, rosterError, request)
        return false, rosterError
    end
    local firstOperation, planError = NextIdentityOperation({
        MembershipSignature = desired.MembershipSignature,
        WantByIdentity = desired.WantByIdentity,
    }, raidState)
    if planError then
        NotifyFinished(self, false, planError, request)
        return false, planError
    end
    if not firstOperation then
        NotifyFinished(self, true, 0, request)
        return true, 0
    end
    if type(self.ScheduleTimer) ~= "function" then
        NotifyFinished(self, false, "timer-unavailable", request)
        return false, "timer-unavailable"
    end

    activeGroupLayoutApply = {
        Reference = CopyDisplayReference(request.Reference),
        Origin = request.Origin,
        Async = request.Async,
        Notify = request.Notify,
        WantByIdentity = desired.WantByIdentity,
        MembershipSignature = desired.MembershipSignature,
        MoveCount = 0,
    }
    local progressed, status = DriveActiveApply(self)
    if progressed and activeGroupLayoutApply then
        activeGroupLayoutApply.Notify = true
        return true, "started"
    end
    return progressed, status
end

local function MarkActiveCanceled(self, reason)
    local active = activeGroupLayoutApply
    if not active then
        return false
    end
    active.CancelReason = active.CancelReason or reason or "canceled"
    if not active.Outstanding then
        FinishActive(self, false, active.CancelReason)
    else
        ScheduleApplyPoll(self, POLL_INTERVAL)
    end
    return true
end

DriveActiveApply = function(self)
    local active = activeGroupLayoutApply
    if not active then
        return false, "no-active-layout"
    end

    local currentReference = CurrentDisplayReference(self)
    if not SameDisplayReference(active.Reference, currentReference) then
        active.CancelReason = active.CancelReason or "display-changed"
    end

    local raidState, _, _, rosterError = BuildRaidState()
    -- Permission helpers consult the live roster. Defer that check while the
    -- roster is transiently unreadable so a protected move cannot make the
    -- leader or assistant appear absent and cancel otherwise-valid work.
    if not rosterError then
        local allowed, permissionError = RequestStillAuthorized(self, active)
        if not allowed then
            active.CancelReason = active.CancelReason or permissionError
        end
    end
    if active.Outstanding then
        if not rosterError and raidState.MembershipSignature ~= active.MembershipSignature then
            active.CancelReason = active.CancelReason or "roster-changed"
        end
        if not rosterError and OperationAcknowledged(active.Outstanding, raidState) then
            active.Outstanding = nil
            if active.CancelReason then
                local reason = active.CancelReason
                FinishActive(self, false, reason)
                return false, reason
            end
        elseif Now() - active.Outstanding.SentAt >= ACK_TIMEOUT then
            local reason = active.CancelReason or "raid-api-timeout"
            FinishActive(self, false, reason)
            return false, reason
        else
            local scheduled, scheduleError = ScheduleApplyPoll(self, POLL_INTERVAL)
            if not scheduled then
                FinishActive(self, false, scheduleError)
                return false, scheduleError
            end
            return true, "in-progress"
        end
    end

    if rosterError then
        active.CancelReason = active.CancelReason or rosterError
    elseif raidState.MembershipSignature ~= active.MembershipSignature then
        active.CancelReason = active.CancelReason or "roster-changed"
    end
    if active.CancelReason then
        local reason = active.CancelReason
        FinishActive(self, false, reason)
        return false, reason
    end
    if RaidIsInCombat() then
        CancelApplyTimer(self)
        return true, "queued"
    end

    raidState, _, _, rosterError = BuildRaidState()
    if rosterError or raidState.MembershipSignature ~= active.MembershipSignature then
        local reason = rosterError or "roster-changed"
        FinishActive(self, false, reason)
        return false, reason
    end
    if not SameDisplayReference(active.Reference, CurrentDisplayReference(self)) then
        FinishActive(self, false, "display-changed")
        return false, "display-changed"
    end
    local operation, planError = NextIdentityOperation(active, raidState)
    if planError then
        FinishActive(self, false, planError)
        return false, planError
    end
    if not operation then
        local count = active.MoveCount
        FinishActive(self, true, count)
        return true, count
    end

    local now = Now()
    if lastRaidApiCallAt and now - lastRaidApiCallAt < MIN_CALL_INTERVAL then
        local delay = math.max(POLL_INTERVAL, MIN_CALL_INTERVAL - (now - lastRaidApiCallAt))
        local scheduled, scheduleError = ScheduleApplyPoll(self, delay)
        if not scheduled then
            FinishActive(self, false, scheduleError)
            return false, scheduleError
        end
        return true, "in-progress"
    end

    -- Secure one future acknowledgement poll before issuing the protected API
    -- call. If scheduling fails, no mutation has happened and a newer request
    -- can never overlap an unmonitored operation.
    local scheduled, scheduleError = ScheduleApplyPoll(self, POLL_INTERVAL)
    if not scheduled then
        FinishActive(self, false, scheduleError)
        return false, scheduleError
    end

    local called
    if operation.Kind == "set" then
        called = type(SetRaidSubgroup) == "function"
            and pcall(SetRaidSubgroup, raidState.IndexByIdentity[operation.Identity], operation.TargetSubgroup)
    else
        called = type(SwapRaidSubgroup) == "function"
            and pcall(
                SwapRaidSubgroup,
                raidState.IndexByIdentity[operation.Identity1],
                raidState.IndexByIdentity[operation.Identity2]
            )
    end
    if not called then
        FinishActive(self, false, "raid-api-failed")
        return false, "raid-api-failed"
    end

    now = Now()
    operation.SentAt = now
    active.Outstanding = operation
    active.MoveCount = active.MoveCount + 1
    lastRaidApiCallAt = now
    return true, "in-progress"
end

StartPendingApply = function(self)
    local request = pendingGroupLayoutApply
    if not request then
        return false, "no-pending-layout"
    end
    if activeGroupLayoutApply then
        return true, "in-progress"
    end
    if RaidIsInCombat() then
        CancelApplyTimer(self)
        return true, "queued"
    end
    pendingGroupLayoutApply = nil
    return StartApply(self, request)
end

local function SubmitRequest(self, origin, suppliedReference)
    origin = origin == "auto" and "auto" or "manual"
    local reference
    if suppliedReference ~= nil then
        reference = CopyDisplayReference(suppliedReference)
    else
        reference = CurrentDisplayReference(self)
    end
    if not reference then
        return false, "active-display-unavailable"
    end
    local request = {
        Reference = reference,
        Origin = origin,
        Notify = origin == "auto",
    }
    local valid, validationError = ValidateRequest(self, request)
    if not valid then
        if
            origin == "auto"
            and validationError ~= "no-layout"
            and validationError ~= "auto-disabled"
            and validationError ~= "not-raid-controller"
        then
            request.Notify = true
            NotifyFinished(self, false, validationError, request)
        end
        return false, validationError
    end

    local active = activeGroupLayoutApply
    if active and SameDisplayReference(active.Reference, reference) and not active.CancelReason then
        if origin == "manual" then
            active.Origin = "manual"
        end
        return true, "in-progress"
    end
    if active then
        active.CancelReason = active.CancelReason or "superseded"
        local queued, queueStatus = QueueRequest(self, request)
        if not active.Outstanding then
            FinishActive(self, false, active.CancelReason)
        end
        return queued, queueStatus
    end
    if pendingGroupLayoutApply then
        return QueueRequest(self, request)
    end
    if RaidIsInCombat() then
        return QueueRequest(self, request)
    end
    return StartApply(self, request)
end

--- Starts a safe asynchronous apply for the currently displayed layout.
-- The optional expected reference is retained for legacy/internal callers.
-- @tparam[opt] table expectedReference Exact four-field active display tuple.
-- @treturn boolean accepted
-- @treturn number|string status
function AngryEra:ApplyGroupLayoutToRaid(expectedReference)
    return SubmitRequest(self, "manual", expectedReference)
end

--- Requests a manual or automatic layout apply.
-- @tparam[opt="manual"] string origin `"manual"` or `"auto"`.
-- @treturn boolean accepted
-- @treturn number|string status `queued`, `started`, `in-progress`, or an immediate move count.
function AngryEra:RequestGroupLayoutApply(origin)
    return SubmitRequest(self, origin)
end

--- Timer callback that advances at most one acknowledged layout operation.
-- @tparam[opt] number generation Scheduled timer generation.
-- @treturn boolean activeOrCompleted
-- @treturn number|string status
function AngryEra:PollGroupLayoutApply(generation)
    if generation and generation ~= groupLayoutApplyGeneration then
        return false, "superseded"
    end
    groupLayoutApplyTimer = nil
    if activeGroupLayoutApply then
        return DriveActiveApply(self)
    end
    return StartPendingApply(self)
end

--- Flushes queued combat work or advances an already active apply.
-- @treturn boolean activeOrCompleted
-- @treturn number|string status
function AngryEra:FlushPendingGroupLayoutApply()
    if activeGroupLayoutApply then
        return DriveActiveApply(self)
    end
    return StartPendingApply(self)
end

--- Stops any not-yet-issued operation when combat begins.
-- An already-issued operation keeps its bounded acknowledgement poll, but once
-- acknowledged the driver pauses without polling for the rest of the fight.
-- @treturn boolean paused
function AngryEra:PauseGroupLayoutApplyForCombat()
    if activeGroupLayoutApply and activeGroupLayoutApply.Outstanding then
        return true
    end
    if activeGroupLayoutApply or pendingGroupLayoutApply then
        CancelApplyTimer(self)
        return true
    end
    return false
end

--- Cancels a queued request without touching an already-issued operation.
-- @tparam[opt="canceled"] string reason Terminal reason.
-- @treturn boolean canceled
function AngryEra:CancelPendingGroupLayoutApply(reason)
    local pending = pendingGroupLayoutApply
    pendingGroupLayoutApply = nil
    if pending then
        FinishPending(self, false, reason or "canceled", pending)
        if not activeGroupLayoutApply then
            CancelApplyTimer(self)
        end
        return true
    end
    return false
end

--- Cancels only work created by automatic page-change behavior.
-- @treturn boolean canceled
function AngryEra:CancelAutomaticGroupLayoutApply()
    local canceled = observedGroupLayoutAutoIntent ~= nil
    observedGroupLayoutAutoIntent = nil
    if pendingGroupLayoutApply and pendingGroupLayoutApply.Origin == "auto" then
        canceled = self:CancelPendingGroupLayoutApply("auto-disabled") or canceled
    end
    if activeGroupLayoutApply and activeGroupLayoutApply.Origin == "auto" then
        canceled = MarkActiveCanceled(self, "auto-disabled") or canceled
    end
    return canceled
end

--- Invalidates old-page queued and active work before a pending display arrives.
-- An issued operation remains monitored until it is acknowledged or times out;
-- no further old-page operation can be sent.
-- @tparam table|nil reference Newly accepted display tuple.
-- @treturn boolean canceled
function AngryEra:InvalidatePendingGroupLayoutApply(reference)
    local nextReference = CopyDisplayReference(reference)
    local canceled = false
    if observedGroupLayoutAutoIntent and not SameDisplayReference(observedGroupLayoutAutoIntent, nextReference) then
        observedGroupLayoutAutoIntent = nil
        canceled = true
    end
    if pendingGroupLayoutApply and not SameDisplayReference(pendingGroupLayoutApply.Reference, nextReference) then
        canceled = self:CancelPendingGroupLayoutApply("display-changed") or canceled
    end
    if activeGroupLayoutApply and not SameDisplayReference(activeGroupLayoutApply.Reference, nextReference) then
        canceled = MarkActiveCanceled(self, "display-changed") or canceled
    end
    return canceled
end

--- Resets every session-local request, including lifecycle/leadership changes.
-- Authority handoffs retain the current canonical display, so callers may
-- preserve it as the observation baseline. This cancels all old-authority work
-- without causing the new authority's first real page transition to be mistaken
-- for the addon's initial display observation.
-- @tparam[opt=false] boolean preserveDisplayedReference
-- @treturn boolean canceled
function AngryEra:ResetGroupLayoutApplyState(preserveDisplayedReference)
    local canceled = self:CancelPendingGroupLayoutApply("canceled")
    if activeGroupLayoutApply then
        local active = activeGroupLayoutApply
        activeGroupLayoutApply = nil
        NotifyFinished(self, false, "canceled", active)
        canceled = true
    end
    CancelApplyTimer(self)
    observedGroupLayoutAutoIntent = nil
    if preserveDisplayedReference == true then
        observedDisplayedPage = CurrentDisplayReference(self)
        hasObservedDisplayedPage = observedDisplayedPage ~= nil
    else
        observedDisplayedPage = nil
        hasObservedDisplayedPage = false
    end
    lastRaidApiCallAt = nil
    return canceled
end

function AngryEra:ResetPendingGroupLayoutApply()
    return self:ResetGroupLayoutApplyState()
end

--- Tracks exact page identity, cancels stale work, and optionally auto-applies.
-- Automatic work is controller-only and starts only on a real SyncId transition.
-- @tparam table|nil snapshot Canonical displayed-note snapshot.
-- @treturn boolean requested
-- @treturn number|string status
function AngryEra:ObserveDisplayedRaidLayout(snapshot)
    local reference = CopyDisplayReference(snapshot)
    local canceled = self:InvalidatePendingGroupLayoutApply(reference)
    local autoApplyEnabled = AutoApplyEnabled(self, snapshot)
    if not autoApplyEnabled then
        canceled = self:CancelAutomaticGroupLayoutApply() or canceled
    end

    local previousSyncId = observedDisplayedPage and observedDisplayedPage.SyncId or nil
    local wasObserved = hasObservedDisplayedPage
    hasObservedDisplayedPage = true
    observedDisplayedPage = reference
    if not reference then
        return false, canceled and "canceled" or "no-display"
    end
    if not wasObserved then
        return false, canceled and "canceled" or "observed"
    end
    if previousSyncId == reference.SyncId then
        return false, canceled and "canceled" or "same-page"
    end
    if not autoApplyEnabled then
        return false, canceled and "canceled" or "auto-disabled"
    end
    if not IsLocalRaidController(self) then
        observedGroupLayoutAutoIntent = CopyDisplayReference(reference)
        return false, canceled and "canceled" or "not-raid-controller"
    end
    observedGroupLayoutAutoIntent = nil
    return self:RequestGroupLayoutApply("auto")
end

--- Retries a page-bound automatic intent after raid authority has settled.
-- The intent survives a transient non-controller observation, but only the exact
-- still-active tuple may start and only while automatic applies remain enabled.
-- @treturn boolean requested
-- @treturn number|string status
function AngryEra:RetryObservedGroupLayoutAutoApply()
    local reference = CopyDisplayReference(observedGroupLayoutAutoIntent)
    if not reference then
        return false, "no-auto-intent"
    end
    if not AutoApplyEnabled(self) then
        observedGroupLayoutAutoIntent = nil
        self:CancelAutomaticGroupLayoutApply()
        return false, "auto-disabled"
    end
    if
        not SameDisplayReference(reference, observedDisplayedPage)
        or not SameDisplayReference(reference, CurrentDisplayReference(self))
    then
        observedGroupLayoutAutoIntent = nil
        return false, "display-changed"
    end
    if not IsLocalRaidController(self) then
        return false, "not-raid-controller"
    end

    observedGroupLayoutAutoIntent = nil
    local requested, status = self:RequestGroupLayoutApply("auto")
    if not requested and status == "not-raid-controller" then
        observedGroupLayoutAutoIntent = reference
    end
    return requested, status
end
