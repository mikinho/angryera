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
local everyoneStateFailures = 0
local synchronousRoleEvents = false
local softRoleSuggestions = true
local ineligibleTankUnits = {}
local roleAvailabilityFailures = 0
local roleAvailabilityReads = 0

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
    local member = MemberByUnit(unit)
    return member and member.Rank == 2 or false
end

function _G.UnitIsGroupAssistant(unit)
    local member = MemberByUnit(unit)
    return member and (everyoneAssistant or member.Rank == 1) or false
end

function _G.IsEveryoneAssistant()
    if everyoneStateFailures > 0 then
        everyoneStateFailures = everyoneStateFailures - 1
        error("settling assistant state")
    end
    return everyoneAssistant
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
    DemoteAssistant = function(name, exact)
        assert(exact == true)
        calls[#calls + 1] = { Kind = "demote", Name = name, At = now }
        if ignoreAssistantCalls then
            return
        end
        for _, member in ipairs(members) do
            if member.Name == name then
                member.Rank = 0
                return
            end
        end
    end,
    SetEveryoneIsAssistant = function(enabled)
        calls[#calls + 1] = { Kind = "everyone", Enabled = enabled, At = now }
        everyoneAssistant = enabled
        return true
    end,
}
_G.C_PartyInfo = partyInfo

function AngryEra:IsPlayerRaidLeader()
    return isLeader
end

function AngryEra:GetDisplayedNote()
    return currentSnapshot
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
    everyoneStateFailures = 0
    synchronousRoleEvents = false
    softRoleSuggestions = true
    ineligibleTankUnits = {}
    roleAvailabilityFailures = 0
    roleAvailabilityReads = 0
end

local names = assert(raidAssignments.ParseNameList(" Tank , Assist-Home "))
assert(#names == 2 and names[1] == "Tank" and names[2] == "Assist-Home", "lists should trim names")
assert(#assert(raidAssignments.ParseNameList("")) == 0, "an explicit empty value should be an empty set")
local invalid, invalidError = raidAssignments.ParseNameList("Tank,,Assist")
assert(not invalid and invalidError == "invalid-assignment-name", "empty list members should fail")
local duplicate, duplicateError = raidAssignments.ParseNameList("Tank,tank")
assert(not duplicate and duplicateError == "duplicate-assignment-name", "case-insensitive duplicates should fail")

-- Present directives own exact sets. Extra assistants are demoted, missing
-- assistants promoted, new tanks set, and existing healer/damage roles remain.
Reset()
currentSnapshot = Reference("page-a", 1, {
    TANKS = "Tank, Newtank",
    ASSISTS = "Assist",
})
local requested, status = AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(requested and status == "scheduled", "managed metadata should schedule")
DrainTimers()
assert(#calls == 3, "the exact desired sets should require three changes")
assert(calls[1].Kind == "promote" and calls[1].Name == "Assist-Home", "missing assist is promoted first")
assert(calls[2].Kind == "demote" and calls[2].Name == "Healer-Home", "extra authority clears after replacement")
assert(calls[3].Kind == "role" and calls[3].Name == "Newtank-Home", "missing tank role is assigned")
assert(members[2].Role == "TANK" and members[3].Role == "HEALER", "unmanaged healer/damage roles remain")
assert(#finished == 1 and finished[1].Success and finished[1].Result == 3, "actual changes report once")

-- Empty values override inheritance and clear every managed assignment.
currentSnapshot = Reference("page-b", 2, {
    TANKS = "",
    ASSISTS = "",
})
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[2].Role == "NONE" and members[4].Role == "NONE", "empty $TANKS clears live tanks to NONE")
assert(members[5].Rank == 0, "empty $ASSISTS demotes current assistants")
assert(members[3].Role == "HEALER", "clearing tanks must preserve healer roles")

-- A page without either key leaves current Blizzard state unmanaged.
local callCount = #calls
currentSnapshot = Reference("page-c", 3, {})
requested, status = AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
assert(not requested and status == "unmanaged" and #calls == callCount, "absent directives do nothing")

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

-- Selective assistant metadata disables Everyone Is Assistant before applying
-- the exact list.
Reset()
everyoneAssistant = true
currentSnapshot = Reference("selective-assist", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(calls[1].Kind == "everyone" and calls[1].Enabled == false, "global assist mode disables first")
assert(members[3].Rank == 0 and members[5].Rank == 1, "individual assists then match the declared set")
assert(members[2].Role == "TANK", "managing only $ASSISTS must preserve assigned tank roles")

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

-- An empty assistant set still owns the dimension and disables the global
-- Everyone Is Assistant mode before confirming the empty exact set.
Reset()
everyoneAssistant = true
currentSnapshot = Reference("empty-selective-assist", 1, { ASSISTS = "" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(calls[1].Kind == "everyone" and everyoneAssistant == false, "empty $ASSISTS disables global assist mode")
assert(members[3].Rank == 0, "empty $ASSISTS demotes remaining individual assistants")

-- Assistant-state reads are fail-closed but retry bounded transient failures.
Reset()
everyoneStateFailures = 2
currentSnapshot = Reference("settling-assistant-state", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[5].Rank == 1, "transient Everyone Is Assistant reads should recover")

Reset()
local savedIsEveryoneAssistant = _G.IsEveryoneAssistant
_G.IsEveryoneAssistant = nil
currentSnapshot = Reference("missing-assistant-state", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
_G.IsEveryoneAssistant = savedIsEveryoneAssistant
assert(#calls == 0, "missing global assistant state must fail before rank mutations")
assert(
    #finished == 1 and finished[1].Result == "assistant-state-unavailable",
    "missing global assistant state should report a stable capability error"
)

-- Validate all required APIs before changing any rank in a multi-step exact
-- set, even when the first planned operation would use an available function.
Reset()
local savedPromoteToAssistant = partyInfo.PromoteToAssistant
partyInfo.PromoteToAssistant = nil
currentSnapshot = Reference("missing-assistant-api", 1, { ASSISTS = "" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
partyInfo.PromoteToAssistant = savedPromoteToAssistant
assert(members[3].Rank == 1 and #calls == 0, "missing later APIs must prevent earlier demotions")
assert(
    #finished == 1 and finished[1].Result == "assignment-api-unavailable",
    "capability preflight should report an unavailable API"
)

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

Reset()
currentSnapshot = Reference("leader-as-assistant", 1, { ASSISTS = "Leader" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(#calls == 0, "the raid leader must never be promoted to assistant")
assert(
    #finished == 1 and finished[1].Result == "leader-cannot-be-assistant",
    "listing the leader as an assistant should report a stable error"
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

-- Assistant replacements are added before old authority is removed. If the
-- promotion never acknowledges, the existing assistant remains in place.
Reset()
ignoreAssistantCalls = true
currentSnapshot = Reference("assistant-timeout", 1, { ASSISTS = "Assist" })
AngryEra:ObserveDisplayedRaidAssignments(currentSnapshot)
DrainTimers()
assert(members[3].Rank == 1 and members[5].Rank == 0, "a failed replacement must preserve existing authority")
assert(
    #calls == 1 and calls[1].Kind == "promote" and finished[1].Result == "assignment-api-timeout",
    "an unacknowledged promotion should stop before demoting the existing assistant"
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
