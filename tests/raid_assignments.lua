local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

local members = {}
AngryEra.utils.helpers = {
    IterateGroupMembers = function(callback)
        for index, member in ipairs(members) do
            if
                callback(
                    member.Name:match("^([^-]+)"),
                    member.Name,
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

assert(loadfile("modules/raid_assignments.lua"))("AngryEra", app)
local raidAssignments = AngryEra.utils.raid_assignments

local inRaid = true
local inCombat = false
local isLeader = true
local everyoneAssistant = false
local currentSnapshot
local now = 0
local timers = {}
local nextTimerId = 0
local calls = {}
local finished = {}
local failNextRoleCall = false
local ignoreRoleCalls = false
local ignoreAssistantCalls = false
local roleReadFailures = 0
local invalidRoleRead = false
local synchronousRoleEvents = false
local softRoleSuggestions = true
local ineligibleTankUnits = {}
local roleAvailabilityFailures = 0
local roleAvailabilityReads = 0
local delegatedControl
local rawDelegatedControl
local forceUnitLeaderFalse = false

local function MemberByUnit(unit)
    local index = type(unit) == "string" and tonumber(unit:match("^raid(%d+)$")) or nil
    return index and members[index] or nil
end

function _G.IsInRaid()
    return inRaid
end

function _G.InCombatLockdown()
    return inCombat
end

function _G.UnitAffectingCombat(unit)
    return unit == "player" and inCombat
end

function _G.GetTimePreciseSec()
    return now
end

function _G.GetNumGroupMembers()
    return #members
end

function _G.UnitGroupRolesAssigned(unit)
    if roleReadFailures > 0 then
        roleReadFailures = roleReadFailures - 1
        error("settling role read")
    end
    if invalidRoleRead then
        return "UNRECOGNIZED"
    end
    local member = MemberByUnit(unit)
    return member and member.Role or "NONE"
end

function _G.UnitIsGroupLeader(unit)
    if forceUnitLeaderFalse then
        return false
    end
    local member = MemberByUnit(unit)
    return member and member.Rank == 2 or false
end

function _G.UnitIsGroupAssistant(unit)
    local member = MemberByUnit(unit)
    return member and (everyoneAssistant or member.Rank == 1) or false
end

function _G.UnitSetRole(unit, role)
    calls[#calls + 1] = {
        Kind = "role",
        Name = assert(MemberByUnit(unit)).Name,
        Role = role,
        At = now,
    }
    if failNextRoleCall then
        failNextRoleCall = false
        return false
    end
    if ignoreRoleCalls then
        return true
    end
    MemberByUnit(unit).Role = (role == nil or role == "NONE") and "NONE" or role
    if synchronousRoleEvents then
        AngryEra:RetryDisplayedRaidAssignments()
    end
    return true
end

function _G.AreClassRolesSoftSuggestions()
    return softRoleSuggestions
end

function _G.UnitGetAvailableRoles(unit)
    roleAvailabilityReads = roleAvailabilityReads + 1
    if roleAvailabilityFailures > 0 then
        roleAvailabilityFailures = roleAvailabilityFailures - 1
        return
    end
    return ineligibleTankUnits[unit] ~= true, true, true
end

local partyInfo = {
    PromoteToAssistant = function(name, exact)
        assert(exact == true)
        calls[#calls + 1] = { Kind = "promote", Name = name, At = now }
        if ignoreAssistantCalls then
            return
        end
        for _, member in ipairs(members) do
            if member.Name == name then
                member.Rank = 1
                return
            end
        end
    end,
}
_G.C_PartyInfo = partyInfo

function AngryEra:IsPlayerRaidLeader()
    return isLeader
end

function AngryEra:GetDisplayedNote()
    return currentSnapshot
end

function AngryEra:GetValidatedDelegatedRaidControl()
    return delegatedControl
end

function AngryEra:GetDelegatedRaidControl()
    return rawDelegatedControl or delegatedControl
end

function AngryEra:ScheduleTimer(method, delay, generation)
    nextTimerId = nextTimerId + 1
    timers[nextTimerId] = {
        Method = method,
        At = now + delay,
        Generation = generation,
    }
    return nextTimerId
end

function AngryEra:CancelTimer(timer)
    timers[timer] = nil
end

function AngryEra:OnDisplayedRaidAssignmentsFinished(success, result)
    finished[#finished + 1] = {
        Success = success,
        Result = result,
    }
end

local function Reference(syncId, revision, meta)
    return {
        SyncId = syncId,
        Revision = revision,
        RevisionId = "revision-" .. tostring(revision),
        ContextRevisionId = "context-" .. tostring(revision),
        Meta = meta,
    }
end

local function RunNextTimer()
    local selectedId
    local selected
    for id, timer in pairs(timers) do
        if not selected or timer.At < selected.At or timer.At == selected.At and id < selectedId then
            selectedId = id
            selected = timer
        end
    end
    if not selected then
        return false
    end
    timers[selectedId] = nil
    now = selected.At
    AngryEra[selected.Method](AngryEra, selected.Generation)
    return true
end

local function DrainTimers()
    local count = 0
    while RunNextTimer() do
        count = count + 1
        assert(count < 100, "raid assignment worker should settle")
    end
end

local function Reset()
    AngryEra:ResetDisplayedRaidAssignmentState()
    members = {
        { Name = "Leader-Home", Rank = 2, Role = "DAMAGER" },
        { Name = "Tank-Home", Rank = 0, Role = "TANK" },
        { Name = "Healer-Home", Rank = 1, Role = "HEALER" },
        { Name = "Newtank-Home", Rank = 0, Role = "DAMAGER" },
        { Name = "Assist-Home", Rank = 0, Role = "DAMAGER" },
    }
    inRaid = true
    inCombat = false
    isLeader = true
    everyoneAssistant = false
    currentSnapshot = nil
    now = 0
    timers = {}
    calls = {}
    finished = {}
    failNextRoleCall = false
    ignoreRoleCalls = false
    ignoreAssistantCalls = false
    roleReadFailures = 0
    invalidRoleRead = false
    synchronousRoleEvents = false
    softRoleSuggestions = true
    ineligibleTankUnits = {}
    roleAvailabilityFailures = 0
    roleAvailabilityReads = 0
    delegatedControl = nil
    rawDelegatedControl = nil
    forceUnitLeaderFalse = false
end

local names = assert(raidAssignments.ParseNameList(" Tank , Assist-Home "))
assert(#names == 2 and names[1] == "Tank" and names[2] == "Assist-Home", "lists should trim names")
assert(#assert(raidAssignments.ParseNameList("")) == 0, "an explicit empty value should be an empty set")
local invalid, invalidError = raidAssignments.ParseNameList("Tank,,Assist")
assert(not invalid and invalidError == "invalid-assignment-name", "empty list members should fail")
local duplicate, duplicateError = raidAssignments.ParseNameList("Tank,tank")
assert(not duplicate and duplicateError == "duplicate-assignment-name", "case-insensitive duplicates should fail")

-- $TANKS owns an exact set while $ASSISTS only adds missing authority.
-- Existing assistants and unmanaged healer/damage roles remain unchanged.
Reset()
currentSnapshot = Reference("page-a", 1, {
    TANKS = "Tank, Newtank",
    ASSISTS = "Assist",
})
local requested, status = AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(requested and status == "scheduled", "managed metadata should schedule")
DrainTimers()
assert(#calls == 2, "the combined directives should promote one assistant and add one tank")
assert(calls[1].Kind == "promote" and calls[1].Name == "Assist-Home", "missing assist is promoted first")
assert(calls[2].Kind == "role" and calls[2].Name == "Newtank-Home", "missing tank role is assigned")
assert(members[3].Rank == 1 and members[5].Rank == 1, "existing and requested assistants both retain authority")
assert(members[2].Role == "TANK" and members[3].Role == "HEALER", "unmanaged healer/damage roles remain")
assert(#finished == 1 and finished[1].Success and finished[1].Result == 2, "actual changes report once")

-- Empty values override inheritance. $TANKS still clears its exact set, while
-- an explicit empty $ASSISTS adds nobody and never revokes existing authority.
currentSnapshot = Reference("page-b", 2, {
    TANKS = "",
    ASSISTS = "",
})
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[2].Role == "NONE" and members[4].Role == "NONE", "empty $TANKS clears live tanks to NONE")
assert(members[3].Rank == 1 and members[5].Rank == 1, "empty $ASSISTS preserves current assistants")
assert(members[3].Role == "HEALER", "clearing tanks must preserve healer roles")
assert(
    #calls == 4 and #finished == 2 and finished[2].Success and finished[2].Result == 2,
    "only the two exact Tank removals should be added by the empty directives"
)

-- A page without either key leaves current Blizzard state unmanaged.
local callCount = #calls
currentSnapshot = Reference("page-c", 3, {})
requested, status = AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(not requested and status == "unmanaged" and #calls == callCount, "absent directives do nothing")

-- Assistant requests accumulate across page changes because later pages never
-- demote authority granted by earlier pages or by the Blizzard raid leader.
Reset()
currentSnapshot = Reference("assist-page-a", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
currentSnapshot = Reference("assist-page-b", 2, { ASSISTS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(
    members[3].Rank == 1 and members[4].Rank == 1 and members[5].Rank == 1,
    "page transitions should accumulate requested and pre-existing assistants"
)
assert(
    #calls == 2
        and calls[1].Kind == "promote"
        and calls[1].Name == "Assist-Home"
        and calls[2].Kind == "promote"
        and calls[2].Name == "Newtank-Home",
    "each page should issue only its missing promotion"
)

-- A fallback render with an invalid ancestor hierarchy must never apply its
-- incomplete page-only metadata, and repeated renders report only once.
Reset()
currentSnapshot = Reference("invalid-context", 1, { TANKS = "Newtank" })
requested, status = AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot, "missing-category")
assert(not requested and status == "invalid-assignment-context", "invalid inheritance should fail closed")
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot, "missing-category")
DrainTimers()
assert(#calls == 0, "incomplete inherited metadata must never mutate roles")
assert(
    #finished == 1 and finished[1].Result == "invalid-assignment-context",
    "repeated invalid hierarchy renders should report once"
)
Reset()
isLeader = false
currentSnapshot = Reference("invalid-follower-context", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot, "missing-category")
assert(#finished == 0, "followers should cancel invalid privileged metadata silently")

-- Ambiguous short names fail closed before any mutation; a full name resolves.
Reset()
members[#members + 1] = { Name = "Tank-Away", Rank = 0, Role = "DAMAGER" }
currentSnapshot = Reference("ambiguous", 1, { TANKS = "Tank", ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "ambiguous metadata must not partially mutate")
assert(
    #finished == 1 and not finished[1].Success and finished[1].Result == "ambiguous-assignment-member",
    "ambiguity should be actionable"
)
currentSnapshot = Reference("qualified", 2, { TANKS = "Tank-Away", ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[6].Role == "TANK", "Name-Realm should select the exact duplicate")

-- Everyone Is Assistant is Blizzard-owned state. Additive $ASSISTS preserves
-- it, while an accompanying $TANKS directive still reconciles exactly.
Reset()
everyoneAssistant = true
currentSnapshot = Reference("everyone-assist", 1, {
    TANKS = "Newtank",
    ASSISTS = "Assist",
})
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(everyoneAssistant == true, "$ASSISTS must never change Everyone Is Assistant")
assert(
    #calls == 2 and calls[1].Kind == "role" and calls[2].Kind == "role",
    "effective global assists should need no rank calls while Tanks still reconcile"
)
assert(members[4].Role == "TANK" and members[2].Role == "NONE", "$TANKS remains exact in global assist mode")

-- Managing only tanks never changes current assistant rank.
Reset()
currentSnapshot = Reference("tank-only", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[3].Rank == 1, "managing only $TANKS must preserve raid assistants")
assert(members[4].Role == "TANK" and members[2].Role == "NONE", "tank-only metadata remains an exact tank set")

-- ROLE_CHANGED_INFORM is synchronous on current clients. Its retry callback
-- must reuse the already-secured poll instead of bypassing the 250 ms pace.
Reset()
synchronousRoleEvents = true
currentSnapshot = Reference("synchronous-role-event", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 2 and calls[2].At - calls[1].At >= 0.25, "synchronous role events must preserve API pacing")

-- One player may intentionally be both a tank and an actual raid assistant.
Reset()
currentSnapshot = Reference("tank-assistant", 1, { TANKS = "Assist", ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[5].Role == "TANK" and members[5].Rank == 1, "the same member may occupy both managed sets")

-- During delegated control, the actual Blizzard leader remains the protected
-- executor. An additive assistant request may omit the controller and promote
-- another member without risking the controller's explicit assistant rank.
Reset()
members[5].Rank = 1
delegatedControl = {
    Controller = "Assist-Home",
}
currentSnapshot = Reference("delegated-controller-omitted", 1, {
    TANKS = "Newtank",
    ASSISTS = "Newtank",
})
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[5].Rank == 1, "an omitted delegated controller must retain raid assistant")
assert(members[3].Rank == 1 and members[4].Rank == 1, "existing authority remains while the new assist is promoted")
for _, call in ipairs(calls) do
    assert(
        call.Name ~= "Leader-Home" and call.Name ~= "Assist-Home",
        "the proxy must never mutate the actual leader or delegated controller"
    )
end
assert(members[4].Role == "TANK" and members[2].Role == "NONE", "the leader should execute delegated tanks")
assert(
    #calls == 3 and #finished == 1 and finished[1].Success and finished[1].Result == 3,
    "the leader proxy should add the requested assist and complete both exact Tank changes"
)

-- Everyone Is Assistant also remains Blizzard-owned during delegated control
-- and does not block exact Tank reconciliation.
Reset()
members[5].Rank = 1
delegatedControl = {
    Controller = "Assist-Home",
}
everyoneAssistant = true
currentSnapshot = Reference("delegated-controller-everyone", 1, {
    TANKS = "Newtank",
    ASSISTS = "Assist",
})
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(everyoneAssistant == true, "delegated reconciliation must preserve global assistant mode")
assert(members[5].Rank == 1, "the delegated controller must retain explicit raid-assistant rank")
assert(
    #calls == 2
        and calls[1].Kind == "role"
        and calls[2].Kind == "role"
        and members[4].Role == "TANK"
        and members[2].Role == "NONE",
    "global assist mode should not block the proxy from reconciling exact Tanks"
)

-- A recovery barrier is still a raw lease. It must pause even a Tanks-only
-- plan instead of silently falling back to the Blizzard leader.
Reset()
rawDelegatedControl = {
    GrantId = "controller-grant-recovering",
    PendingRecovery = true,
}
currentSnapshot = Reference("delegated-controller-recovering", 1, {
    TANKS = "Newtank",
})
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "an unvalidated raw lease must block a Tanks-only plan")
assert(members[2].Role == "TANK" and members[4].Role == "DAMAGER", "paused recovery must preserve Tank roles")
assert(
    #finished == 1 and finished[1].Result == "delegated-controller-state-unvalidated",
    "a recovering raw lease should report the stable authority-barrier error"
)

-- The same barrier covers an active-looking raw record that no longer
-- validates, such as the controller losing explicit raid-assistant rank.
Reset()
rawDelegatedControl = {
    Controller = "Assist-Home",
    GrantId = "controller-grant-rank-lost",
}
currentSnapshot = Reference("delegated-controller-rank-lost", 1, {
    TANKS = "Newtank",
    ASSISTS = "Healer",
})
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "an invalid unreconciled lease must block both protected dimensions")
assert(members[2].Role == "TANK" and members[4].Role == "DAMAGER", "invalid control must preserve Tank roles")
assert(members[3].Rank == 1 and members[5].Rank == 0, "invalid control must preserve assistant ranks")
assert(
    #finished == 1 and finished[1].Result == "delegated-controller-state-unvalidated",
    "rank-loss state should report the stable authority-barrier error"
)

-- The planner itself must never manufacture destructive assistant operations.
local additiveOperations = raidAssignments.PlanOperations({
    Members = {
        {
            Identity = "healer-home",
            FullName = "Healer-Home",
            IsLeader = false,
            IsAssistant = true,
            Role = "HEALER",
        },
        {
            Identity = "assist-home",
            FullName = "Assist-Home",
            IsLeader = false,
            IsAssistant = false,
            Role = "DAMAGER",
        },
    },
}, {
    AssistsPresent = true,
    Assists = { ["assist-home"] = true },
    TanksPresent = false,
    Tanks = {},
})
assert(
    #additiveOperations == 1 and additiveOperations[1].Kind == "promote-assistant",
    "an additive assistant plan should contain only the missing promotion"
)
for _, operation in ipairs(additiveOperations) do
    assert(
        operation.Kind ~= "demote-assistant" and operation.Kind ~= "disable-everyone-assistant",
        "assistant plans must never demote or toggle global assistant mode"
    )
end

-- An explicit empty assistant list adds nobody, preserves individual ranks,
-- and leaves Everyone Is Assistant untouched.
Reset()
everyoneAssistant = true
currentSnapshot = Reference("empty-additive-assist", 1, { ASSISTS = "" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0 and #finished == 0, "empty $ASSISTS should settle without any Blizzard mutation")
assert(everyoneAssistant == true and members[3].Rank == 1, "empty $ASSISTS must preserve all assistant state")

-- Additive promotion needs neither the global-assistant query nor destructive
-- assistant APIs.
Reset()
assert(
    type(_G.IsEveryoneAssistant) ~= "function"
        and type(partyInfo.DemoteAssistant) ~= "function"
        and type(partyInfo.SetEveryoneIsAssistant) ~= "function",
    "the fixture should expose only the additive assistant API"
)
currentSnapshot = Reference("additive-api-surface", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(
    #calls == 1 and calls[1].Kind == "promote" and members[5].Rank == 1,
    "missing destructive and global-assistant APIs must not block promotion"
)

-- PromoteToAssistant is required only when a missing promotion is actually
-- planned. Empty or already-satisfied requests remain harmless no-ops.
Reset()
local savedPromoteToAssistant = partyInfo.PromoteToAssistant
partyInfo.PromoteToAssistant = nil
currentSnapshot = Reference("missing-promote-api", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0 and members[3].Rank == 1, "missing promotion API must fail before changing authority")
assert(
    #finished == 1 and finished[1].Result == "assignment-api-unavailable",
    "a planned promotion should report the missing capability"
)

Reset()
currentSnapshot = Reference("missing-promote-empty", 1, { ASSISTS = "" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0 and #finished == 0 and members[3].Rank == 1, "empty $ASSISTS needs no promotion API")

Reset()
currentSnapshot = Reference("missing-promote-satisfied", 1, { ASSISTS = "Healer" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
partyInfo.PromoteToAssistant = savedPromoteToAssistant
assert(#calls == 0 and #finished == 0 and members[3].Rank == 1, "a satisfied $ASSISTS request needs no API")

-- Distinct spellings that resolve to the same player fail before any mutation.
Reset()
currentSnapshot = Reference("duplicate-member", 1, { TANKS = "Tank,Tank-Home", ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "duplicate resolved identities must fail before mutating either dimension")
assert(
    #finished == 1 and finished[1].Result == "duplicate-assignment-member",
    "duplicate resolved identities should report a stable error"
)

-- The current raid leader already has higher authority and is ignored by
-- additive assistant planning. A leader-only request is therefore a no-op.
Reset()
currentSnapshot = Reference("leader-only-assists", 1, { ASSISTS = "Leader" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0 and #finished == 0, "a leader-only assistant request should make no Blizzard change")
assert(members[1].Rank == 2 and members[3].Rank == 1, "leader filtering must preserve all existing authority")

-- Literal short and full leader names are filtered after exact roster
-- resolution while a requested non-leader is still promoted additively.
Reset()
currentSnapshot = Reference("leader-and-assist", 1, { ASSISTS = "Leader-Home, Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(
    #calls == 1 and calls[1].Kind == "promote" and calls[1].Name == "Assist-Home",
    "a mixed leader list should promote only the requested non-leader assistant"
)
assert(
    members[1].Rank == 2 and members[3].Rank == 1 and members[5].Rank == 1,
    "mixed assistant reconciliation must preserve both the leader and existing assistants"
)
assert(
    #finished == 1 and finished[1].Success and finished[1].Result == 1,
    "leader filtering must not count the ignored entry as a Blizzard change"
)

-- GetRaidRosterInfo's rank remains authoritative when UnitIsGroupLeader
-- transiently returns false during roster settlement.
Reset()
forceUnitLeaderFalse = true
currentSnapshot = Reference("leader-rank-fallback", 1, { ASSISTS = "Leader" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "a false UnitIsGroupLeader signal must not expose the rank-two leader to assistant promotion")
assert(members[1].Rank == 2 and members[3].Rank == 1, "rank fallback must preserve all existing authority")

-- Filtering happens after ordinary identity validation; duplicate aliases for
-- the leader remain malformed input rather than becoming silently acceptable.
Reset()
currentSnapshot = Reference("duplicate-leader-assists", 1, { ASSISTS = "Leader,Leader-Home" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "duplicate leader aliases must fail before any assistant mutation")
assert(
    #finished == 1 and not finished[1].Success and finished[1].Result == "duplicate-assignment-member",
    "duplicate leader aliases should preserve the stable duplicate-member failure"
)

-- Roster and role reads can briefly settle after the event that triggered the
-- scan. Bounded retries recover without requiring an unrelated later event.
Reset()
roleReadFailures = 2
currentSnapshot = Reference("settling-role-read", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[4].Role == "TANK" and #finished == 1 and finished[1].Success, "transient role reads should recover")

-- A desired joiner may appear after the roster count is already internally
-- consistent; desired-name resolution receives the same bounded settlement.
Reset()
currentSnapshot = Reference("settling-joiner", 1, { TANKS = "Late" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(RunNextTimer() and RunNextTimer(), "a missing desired member should schedule bounded retries")
members[#members + 1] = { Name = "Late-Home", Rank = 0, Role = "DAMAGER" }
DrainTimers()
assert(members[#members].Role == "TANK", "a desired member appearing during settlement should be assigned")

-- Unrecognized string-role reads are not treated as None, which could
-- otherwise make a destructive empty set appear already satisfied.
Reset()
invalidRoleRead = true
currentSnapshot = Reference("invalid-role-read", 1, { TANKS = "" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "invalid assigned-role reads must fail before mutation")
assert(#finished == 1 and finished[1].Result == "role-api-failed", "invalid role reads should fail closed")

-- Prefer the modern enum APIs in the mixed environment exposed by current
-- Classic, including the real Tank=0 and no-role=-1 values.
local savedEnum = _G.Enum
local savedConstants = _G.Constants
local savedRoleGetter = _G.UnitGroupRolesAssigned
local savedRoleSetter = _G.UnitSetRole
local savedEnumRoleGetter = _G.UnitGroupRolesAssignedEnum
local savedEnumRoleSetter = _G.UnitSetRoleEnum
_G.Enum = {
    LFGRole = {
        Tank = 0,
        Healer = 1,
        Damage = 2,
    },
}
_G.Constants = {
    LFG_ROLEConstants = {
        LFG_ROLE_NO_ROLE = -1,
    },
}
local enumRoleReads = 0
_G.UnitGroupRolesAssigned = function()
    error("the valid enum getter should be preferred")
end
local function ReadMockEnumRole(unit)
    enumRoleReads = enumRoleReads + 1
    local role = assert(MemberByUnit(unit)).Role
    if role == "TANK" then
        return Enum.LFGRole.Tank
    end
    if role == "HEALER" then
        return Enum.LFGRole.Healer
    end
    if role == "DAMAGER" then
        return Enum.LFGRole.Damage
    end
    return Constants.LFG_ROLEConstants.LFG_ROLE_NO_ROLE
end
_G.UnitGroupRolesAssignedEnum = ReadMockEnumRole
_G.UnitSetRoleEnum = function(unit, role)
    local member = assert(MemberByUnit(unit))
    calls[#calls + 1] = {
        Kind = "role-enum",
        Name = member.Name,
        Role = role,
    }
    member.Role = role == Enum.LFGRole.Tank and "TANK" or "NONE"
    return true
end
Reset()
currentSnapshot = Reference("enum-roles", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(
    calls[1].Kind == "role-enum" and calls[1].Name == "Newtank-Home" and calls[1].Role == Enum.LFGRole.Tank,
    "the enum API should assign the Tank role"
)
assert(
    calls[2].Kind == "role-enum" and calls[2].Name == "Tank-Home" and calls[2].Role == nil,
    "the enum API should clear Tank by assigning nil"
)
assert(enumRoleReads > 0, "current Classic should read assigned roles through the enum API")
assert(members[2].Role == "NONE" and members[4].Role == "TANK", "enum readback should confirm the exact Tank set")
assert(#finished == 1 and finished[1].Success and finished[1].Result == 2, "enum changes should acknowledge")

-- An undocumented nil enum read is transient/invalid, not None. Fall back to a
-- valid string read instead of planning a destructive role change.
local stringRoleReads = 0
_G.UnitGroupRolesAssigned = function(unit)
    stringRoleReads = stringRoleReads + 1
    return savedRoleGetter(unit)
end
_G.UnitGroupRolesAssignedEnum = function(unit)
    if unit == "raid2" then
        return nil
    end
    return ReadMockEnumRole(unit)
end
Reset()
currentSnapshot = Reference("enum-nil-read", 1, { TANKS = "Tank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0 and members[2].Role == "TANK", "a nil enum read must use the valid string fallback")
assert(stringRoleReads > 0 and #finished == 0, "valid string fallback should settle silently")

-- If the enum wrapper itself errors on a compatibility client, fall back to
-- the string API. A normal false rejection remains authoritative.
_G.UnitGroupRolesAssigned = function()
    error("the restored enum getter should be preferred")
end
_G.UnitGroupRolesAssignedEnum = ReadMockEnumRole
_G.UnitSetRoleEnum = function()
    error("enum wrapper unavailable")
end
Reset()
currentSnapshot = Reference("enum-error-fallback", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(
    #calls == 2 and calls[1].Kind == "role" and calls[1].Name == "Newtank-Home",
    "an enum error should use the string API for the complete exact set"
)
assert(members[2].Role == "NONE" and members[4].Role == "TANK", "the string fallback should settle")
assert(#finished == 1 and finished[1].Success and finished[1].Result == 2, "fallback changes should acknowledge")

_G.UnitSetRoleEnum = function(unit, role)
    local member = assert(MemberByUnit(unit))
    calls[#calls + 1] = {
        Kind = "role-enum",
        Name = member.Name,
        Role = role,
    }
    return false
end
Reset()
currentSnapshot = Reference("enum-rejected", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 1 and calls[1].Kind == "role-enum", "an enum rejection must not be reissued through another API")
assert(#finished == 1 and finished[1].Result == "assignment-api-failed", "a false enum result should fail immediately")

_G.UnitSetRoleEnum = function(unit, role)
    local member = assert(MemberByUnit(unit))
    calls[#calls + 1] = {
        Kind = "role-enum",
        Name = member.Name,
        Role = role,
    }
end
Reset()
currentSnapshot = Reference("enum-invalid-return", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 1 and calls[1].Kind == "role-enum", "an invalid enum result must not be retried")
assert(
    #finished == 1 and finished[1].Result == "assignment-api-failed",
    "a missing documented boolean result should fail immediately"
)
_G.Enum = savedEnum
_G.Constants = savedConstants
_G.UnitGroupRolesAssigned = savedRoleGetter
_G.UnitSetRole = savedRoleSetter
_G.UnitGroupRolesAssignedEnum = savedEnumRoleGetter
_G.UnitSetRoleEnum = savedEnumRoleSetter

-- When Blizzard treats class roles as hard limits, reject an unavailable Tank
-- before changing raid-assistant authority.
Reset()
softRoleSuggestions = false
ineligibleTankUnits.raid4 = true
currentSnapshot = Reference("hard-role-limit", 1, {
    TANKS = "Newtank",
    ASSISTS = "Assist",
})
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "Tank eligibility must be validated before any assistant mutation")
assert(members[3].Rank == 1 and members[5].Rank == 0, "a rejected Tank must preserve existing authority")
assert(
    #finished == 1 and finished[1].Result == "tank-role-unavailable",
    "hard class-role rejection should identify the unavailable Tank"
)

-- A temporarily unavailable role-eligibility read retries and then applies
-- instead of reporting a permanent class rejection.
Reset()
softRoleSuggestions = false
roleAvailabilityFailures = 1
currentSnapshot = Reference("transient-role-eligibility", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[4].Role == "TANK", "transient role eligibility should retry")
assert(roleAvailabilityReads >= 2, "transient role eligibility should be read again")
assert(#finished == 1 and finished[1].Success and finished[1].Result == 2, "retried role changes should settle")

-- Soft role suggestions must not block manual Classic assignments even when
-- the class availability hint says Tank is unavailable.
Reset()
softRoleSuggestions = true
ineligibleTankUnits.raid4 = true
currentSnapshot = Reference("soft-role-suggestion", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[4].Role == "TANK", "soft role suggestions should allow the explicit Tank assignment")
assert(#finished == 1 and finished[1].Success and finished[1].Result == 2, "soft-role changes should settle")

-- Combat retains only the newest exact page and applies it after combat.
Reset()
inCombat = true
currentSnapshot = Reference("combat-old", 1, { TANKS = "Tank" })
requested, status = AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(requested and status == "queued" and #calls == 0, "combat should queue without mutation")
currentSnapshot = Reference("combat-new", 2, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(#calls == 0, "newer combat metadata should still be deferred")
inCombat = false
AngryEra:FlushDisplayedRaidAssignments()
DrainTimers()
assert(members[2].Role == "NONE" and members[4].Role == "TANK", "only the latest combat page should win")

-- A newer inherited-context tuple supersedes queued work even when the page and
-- content revision are unchanged.
Reset()
inCombat = true
currentSnapshot = Reference("context-page", 1, { TANKS = "Tank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
currentSnapshot = Reference("context-page", 1, { TANKS = "Newtank" })
currentSnapshot.ContextRevisionId = "context-new"
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
inCombat = false
AngryEra:FlushDisplayedRaidAssignments()
DrainTimers()
assert(members[2].Role == "NONE" and members[4].Role == "TANK", "the latest inherited context should win")

-- Removing both directives before combat ends cancels all unissued work.
Reset()
inCombat = true
currentSnapshot = Reference("managed-in-combat", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
currentSnapshot = Reference("unmanaged-in-combat", 2, {})
requested, status = AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(not requested and status == "unmanaged", "an unmanaged page should cancel queued assignment work")
inCombat = false
requested, status = AngryEra:FlushDisplayedRaidAssignments()
assert(not requested and status == "no-assignment-intent", "canceled combat work must not flush later")
assert(members[2].Role == "TANK" and members[4].Role == "DAMAGER", "canceled unissued work must not mutate roles")

-- An already-issued old-page operation may land, but the newest page
-- compensates it without waiting on the superseded acknowledgement.
Reset()
currentSnapshot = Reference("old-page", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(RunNextTimer(), "the first operation should issue")
currentSnapshot = Reference("new-page", 2, { TANKS = "Tank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[2].Role == "TANK" and members[4].Role == "NONE", "new display should compensate in-flight work")

-- A pending remote display invalidates old-page work before its page/context
-- payload arrives, preventing the still-rendered old note from sending more.
Reset()
currentSnapshot = Reference("old-rendered-page", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(RunNextTimer(), "the old page should issue its first operation")
local callsBeforePendingDisplay = #calls
local pendingReference = Reference("pending-display", 2, { TANKS = "Tank" })
assert(
    AngryEra:InvalidatePendingDisplayedRaidAssignments(pendingReference),
    "a different pending display should invalidate old assignment work"
)
DrainTimers()
assert(#calls == callsBeforePendingDisplay, "no old-page operation may continue during pending transfer")
currentSnapshot = pendingReference
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[2].Role == "TANK" and members[4].Role == "NONE", "the resolved pending display should win")

-- A superseded call that never acknowledges cannot hold the new page for the
-- full acknowledgement timeout.
Reset()
ignoreRoleCalls = true
currentSnapshot = Reference("old-no-ack", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(RunNextTimer(), "the old page should issue its unacknowledged operation")
currentSnapshot = Reference("new-after-no-ack", 2, { TANKS = "Tank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 1 and #finished == 0, "a superseded no-ack call should not timeout the new page")

-- Becoming unmanaged cancels the worker even if a protected call was already
-- issued. The call may have landed, but absent metadata must not keep managing
-- or carry its acknowledgement into a future page.
Reset()
ignoreRoleCalls = true
currentSnapshot = Reference("issued-then-unmanaged", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(RunNextTimer(), "the managed page should issue its first operation")
local issuedCallCount = #calls
currentSnapshot = Reference("unmanaged-after-issue", 2, {})
requested, status = AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(not requested and status == "unmanaged", "unmanaged metadata should cancel the active worker")
DrainTimers()
assert(#calls == issuedCallCount, "an unmanaged page must not continue the old exact-set plan")
ignoreRoleCalls = false
currentSnapshot = Reference("managed-after-unmanaged", 3, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[4].Role == "TANK", "a later managed page must not inherit a stranded old operation")

-- If an outstanding target leaves, abandon that acknowledgement and revalidate
-- the desired list instead of waiting eight seconds on an impossible readback.
Reset()
ignoreRoleCalls = true
currentSnapshot = Reference("target-leaves", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(RunNextTimer(), "the target-leave scenario should issue one operation")
table.remove(members, 4)
DrainTimers()
assert(
    #finished == 1 and finished[1].Result == "unknown-assignment-member" and now < 8,
    "a departed target should reach bounded desired-name failure before the acknowledgement timeout"
)

-- Only the current raid leader mutates; settled leadership retries the retained
-- exact current intent.
Reset()
isLeader = false
currentSnapshot = Reference("leadership", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "non-leaders must never mutate ranks or roles")
isLeader = true
AngryEra:RetryDisplayedRaidAssignments()
DrainTimers()
assert(members[5].Rank == 1, "a newly settled leader should reconcile the current page")

-- A rejected Blizzard role call fails once and never clears a valid old tank as
-- part of a partial plan.
Reset()
failNextRoleCall = true
currentSnapshot = Reference("api-failure", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[2].Role == "TANK" and members[4].Role == "DAMAGER", "failed additions preserve old tanks")
assert(
    #finished == 1 and not finished[1].Success and finished[1].Result == "assignment-api-failed",
    "API failures should report once"
)

-- If an additive promotion never acknowledges, it times out without changing
-- any existing assistant authority.
Reset()
ignoreAssistantCalls = true
currentSnapshot = Reference("assistant-timeout", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[3].Rank == 1 and members[5].Rank == 0, "a failed promotion must preserve existing authority")
assert(
    #calls == 1 and calls[1].Kind == "promote" and finished[1].Result == "assignment-api-timeout",
    "an unacknowledged assistant promotion should report one timeout"
)

-- A call that is accepted but never reflected by Blizzard times out once and
-- does not continue to destructive removals from the remaining plan.
Reset()
ignoreRoleCalls = true
currentSnapshot = Reference("api-timeout", 1, { TANKS = "Newtank" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 1 and calls[1].Name == "Newtank-Home", "an unacknowledged call must not be reissued")
assert(members[2].Role == "TANK", "a timed-out addition must not clear the previous valid tank")
assert(
    #finished == 1 and not finished[1].Success and finished[1].Result == "assignment-api-timeout",
    "unacknowledged Blizzard changes should report one timeout"
)

print("Raid assignment tests passed.")
