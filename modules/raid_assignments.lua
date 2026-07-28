-- -------------------------------------------------------------------------------
-- Angry Era: modules/raid_assignments.lua
--
-- Reconciles inherited `$TANKS` metadata with Blizzard's assigned TANK role and
-- `$ASSISTS` with the actual raid-assistant rank. Only the current raid leader
-- acts. Every mutation is planned from a fresh roster, paced one at a time, and
-- bound to the exact displayed page/context so a newer display always wins.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.raid_assignments = {}
local raidAssignments = AngryEra.utils.raid_assignments
local helpers = AngryEra.utils.helpers

local MAX_LIST_BYTES = 4096
local MAX_MEMBERS = 40
local POLL_INTERVAL = 0.25
local MIN_CALL_INTERVAL = 0.25
local MAX_TRANSIENT_READ_RETRIES = 8
local ACK_TIMEOUT = 8

local currentIntent
local outstandingOperation
local reconcileTimer
local reconcileGeneration = 0
local appliedMutationCount = 0
local lastReportedFailure
local lastOperationSentAt

local TRANSIENT_READ_ERRORS = {
    ["assistant-state-failed"] = true,
    ["invalid-roster"] = true,
    ["role-api-failed"] = true,
    ["roster-unavailable"] = true,
    ["unknown-assignment-member"] = true,
    ["leader-cannot-be-assistant"] = true,
}

local function Trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
end

local function IsValidName(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= 128
        and not value:find("[%c%s{},=>]")
        and value:sub(-1) ~= "-"
        and not value:find("--", 1, true)
end

--- Parses a comma-separated metadata list while preserving explicit emptiness.
-- @tparam string value Resolved metadata value.
-- @treturn table|nil names
-- @treturn string|nil errorCode
function raidAssignments.ParseNameList(value)
    if type(value) ~= "string" or #value > MAX_LIST_BYTES then
        return nil, "invalid-assignment-list"
    end
    if Trim(value) == "" then
        return {}
    end

    local names = {}
    local seen = {}
    local cursor = 1
    while true do
        local separator = value:find(",", cursor, true)
        local name = Trim(value:sub(cursor, separator and separator - 1 or nil))
        if not IsValidName(name) then
            return nil, "invalid-assignment-name"
        end
        local identity = name:lower()
        if seen[identity] then
            return nil, "duplicate-assignment-name"
        end
        seen[identity] = true
        names[#names + 1] = name
        if #names > MAX_MEMBERS then
            return nil, "assignment-list-too-large"
        end
        if not separator then
            break
        end
        cursor = separator + 1
    end
    return names
end

local function CopyReference(value)
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

local function SameReference(left, right)
    return type(left) == "table"
        and type(right) == "table"
        and left.SyncId == right.SyncId
        and left.Revision == right.Revision
        and left.RevisionId == right.RevisionId
        and left.ContextRevisionId == right.ContextRevisionId
end

local function MetadataEntry(meta, canonicalKey)
    if type(meta) ~= "table" then
        return false
    end
    if rawget(meta, canonicalKey) ~= nil then
        return true, rawget(meta, canonicalKey)
    end
    for key, value in pairs(meta) do
        if type(key) == "string" and key:upper() == canonicalKey then
            return true, value
        end
    end
    return false
end

local function IntentSignature(reference, tanksPresent, tanks, assistsPresent, assists)
    return table.concat({
        reference.SyncId,
        tostring(reference.Revision),
        reference.RevisionId,
        reference.ContextRevisionId,
        tanksPresent and ("T:" .. type(tanks) .. ":" .. tostring(tanks)) or "T:-",
        assistsPresent and ("A:" .. type(assists) .. ":" .. tostring(assists)) or "A:-",
    }, "\031")
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

local function InCombat()
    if type(InCombatLockdown) == "function" then
        local called, locked = pcall(InCombatLockdown)
        if called and locked == true then
            return true
        end
    end
    if type(UnitAffectingCombat) == "function" then
        local called, active = pcall(UnitAffectingCombat, "player")
        if called and active == true then
            return true
        end
    end
    return false
end

local function Trace(self, stage, formatText, ...)
    local callback = self and self.SyncDebug
    if type(callback) == "function" then
        callback(self, stage, formatText, ...)
    end
end

local function IsRaidLeader(self)
    if type(IsInRaid) ~= "function" or IsInRaid() ~= true or type(self.IsPlayerRaidLeader) ~= "function" then
        return false
    end
    local called, leader = pcall(self.IsPlayerRaidLeader, self)
    return called and leader == true
end

local function NormalizeRole(value, enumApi)
    if type(value) == "string" then
        local role = value:upper()
        if role == "TANK" then
            return "TANK"
        end
        if role == "HEALER" or role == "DAMAGER" or role == "DPS" then
            return role == "DPS" and "DAMAGER" or role
        end
        return role == "NONE" and "NONE" or nil
    end
    local roles = type(Enum) == "table" and Enum.LFGRole or nil
    local noRole = type(_G) == "table" and type(_G.LFG_ROLE_NO_ROLE) == "number" and _G.LFG_ROLE_NO_ROLE
        or type(Constants) == "table" and type(Constants.LFG_ROLEConstants) == "table" and Constants.LFG_ROLEConstants.LFG_ROLE_NO_ROLE
        or -1
    if enumApi and (value == noRole or value == -1) then
        return "NONE"
    end
    if enumApi and type(roles) == "table" then
        local tank = roles.Tank or roles.TANK
        local healer = roles.Healer or roles.HEALER
        local damage = roles.Damage or roles.Damager or roles.Dps or roles.DPS or roles.DAMAGER
        if tank ~= nil and value == tank then
            return "TANK"
        end
        if healer ~= nil and value == healer then
            return "HEALER"
        end
        if damage ~= nil and value == damage then
            return "DAMAGER"
        end
    end
    return nil
end

local function ReadAssignedRole(unitToken)
    if type(UnitGroupRolesAssignedEnum) == "function" then
        local called, value = pcall(UnitGroupRolesAssignedEnum, unitToken)
        local normalized = called and NormalizeRole(value, true) or nil
        if normalized then
            return normalized
        end
    end
    if type(UnitGroupRolesAssigned) == "function" then
        local called, value = pcall(UnitGroupRolesAssigned, unitToken)
        local normalized = called and NormalizeRole(value, false) or nil
        if normalized then
            return normalized
        end
    end
    return nil
end

local function BuildRosterState()
    if type(helpers) ~= "table" or type(helpers.IterateGroupMembers) ~= "function" then
        return nil, "roster-unavailable"
    end
    if type(UnitGroupRolesAssignedEnum) ~= "function" and type(UnitGroupRolesAssigned) ~= "function" then
        return nil, "role-api-unavailable"
    end

    local state = {
        Members = {},
        ByIdentity = {},
        ByShortName = {},
    }
    local scanError
    local iterated = pcall(helpers.IterateGroupMembers, function(_, fullName, rank, _, _, _, _, unitToken)
        if type(fullName) ~= "string" or fullName == "" or type(unitToken) ~= "string" or unitToken == "" then
            scanError = "invalid-roster"
            return true
        end
        local identity = fullName:lower()
        if state.ByIdentity[identity] then
            scanError = "invalid-roster"
            return true
        end

        local leader = rank == 2
        if type(UnitIsGroupLeader) == "function" then
            local called, result = pcall(UnitIsGroupLeader, unitToken)
            if called then
                leader = result == true
            end
        end
        local assistant = rank == 1
        if type(UnitIsGroupAssistant) == "function" then
            local called, result = pcall(UnitIsGroupAssistant, unitToken)
            if called then
                assistant = result == true
            end
        end

        local normalizedRole = ReadAssignedRole(unitToken)
        if not normalizedRole then
            scanError = "role-api-failed"
            return true
        end

        local member = {
            Identity = identity,
            FullName = fullName,
            Unit = unitToken,
            IsLeader = leader,
            IsAssistant = assistant,
            Role = normalizedRole,
        }
        state.Members[#state.Members + 1] = member
        state.ByIdentity[identity] = member
        local shortName = identity:match("^([^-]+)")
        if shortName then
            state.ByShortName[shortName] = state.ByShortName[shortName] or {}
            state.ByShortName[shortName][#state.ByShortName[shortName] + 1] = member
        end
        return false
    end)
    if not iterated or scanError then
        return nil, scanError or "roster-unavailable"
    end
    if #state.Members == 0 or #state.Members > MAX_MEMBERS then
        return nil, "roster-unavailable"
    end
    if type(GetNumGroupMembers) == "function" then
        local called, expected = pcall(GetNumGroupMembers)
        if not called or type(expected) ~= "number" or expected < 1 then
            return nil, "roster-unavailable"
        end
        if expected ~= #state.Members then
            return nil, "roster-unavailable"
        end
    end
    table.sort(state.Members, function(left, right)
        return left.Identity < right.Identity
    end)
    return state
end

local function ResolveNames(names, state)
    local desired = {}
    for _, name in ipairs(names) do
        local identity = name:lower()
        local member
        if name:find("-", 1, true) then
            member = state.ByIdentity[identity]
            if not member then
                return nil, "unknown-assignment-member"
            end
        else
            local matches = state.ByShortName[identity]
            if type(matches) ~= "table" or #matches == 0 then
                return nil, "unknown-assignment-member"
            end
            if #matches ~= 1 then
                return nil, "ambiguous-assignment-member"
            end
            member = matches[1]
        end
        if desired[member.Identity] then
            return nil, "duplicate-assignment-member"
        end
        desired[member.Identity] = true
    end
    return desired
end

local function BuildDesiredState(meta, rosterState)
    local tanksPresent, tanksValue = MetadataEntry(meta, "TANKS")
    local assistsPresent, assistsValue = MetadataEntry(meta, "ASSISTS")
    if not tanksPresent and not assistsPresent then
        return nil, "unmanaged"
    end

    local desired = {
        TanksPresent = tanksPresent,
        AssistsPresent = assistsPresent,
    }
    if tanksPresent then
        local names, parseError = raidAssignments.ParseNameList(tanksValue)
        if not names then
            return nil, parseError
        end
        desired.Tanks, parseError = ResolveNames(names, rosterState)
        if not desired.Tanks then
            return nil, parseError
        end
    end
    if assistsPresent then
        local names, parseError = raidAssignments.ParseNameList(assistsValue)
        if not names then
            return nil, parseError
        end
        desired.Assists, parseError = ResolveNames(names, rosterState)
        if not desired.Assists then
            return nil, parseError
        end
        for identity in pairs(desired.Assists) do
            if rosterState.ByIdentity[identity].IsLeader then
                return nil, "leader-cannot-be-assistant"
            end
        end
    end
    return desired
end

local function ValidateTankEligibility(self, desired, rosterState)
    if not desired.TanksPresent then
        return true
    end
    if type(AreClassRolesSoftSuggestions) ~= "function" or type(UnitGetAvailableRoles) ~= "function" then
        return true
    end

    local called, softSuggestions = pcall(AreClassRolesSoftSuggestions)
    if not called or type(softSuggestions) ~= "boolean" then
        return false, "role-api-failed"
    end
    if softSuggestions == true then
        return true
    end

    for _, member in ipairs(rosterState.Members) do
        if desired.Tanks[member.Identity] and member.Role ~= "TANK" then
            local roleCalled, canTank = pcall(UnitGetAvailableRoles, member.Unit)
            if not roleCalled or type(canTank) ~= "boolean" then
                return false, "role-api-failed"
            end
            if canTank ~= true then
                Trace(
                    self,
                    "raid-assignment-tank-eligibility",
                    "mode=hard unit=%s allowed=false",
                    tostring(member.Unit)
                )
                return false, "tank-role-unavailable"
            end
        end
    end
    return true
end

local function EveryoneIsAssistant()
    if type(IsEveryoneAssistant) ~= "function" then
        return nil, "assistant-state-unavailable"
    end
    local called, enabled = pcall(IsEveryoneAssistant)
    if not called or type(enabled) ~= "boolean" then
        return nil, "assistant-state-failed"
    end
    return enabled
end

--- Plans a deterministic exact-set reconciliation.
-- Non-tank HEALER/DAMAGER roles are never changed.
-- @tparam table rosterState Internal or test roster state.
-- @tparam table desired Desired sets from `BuildDesiredState`.
-- @tparam boolean everyoneAssistant Current global assist mode.
-- @treturn table operations
function raidAssignments.PlanOperations(rosterState, desired, everyoneAssistant)
    local operations = {}
    if desired.AssistsPresent and everyoneAssistant then
        operations[#operations + 1] = { Kind = "disable-everyone-assistant" }
        return operations
    end

    if desired.AssistsPresent then
        for _, member in ipairs(rosterState.Members) do
            if not member.IsLeader and desired.Assists[member.Identity] and not member.IsAssistant then
                operations[#operations + 1] = {
                    Kind = "promote-assistant",
                    Identity = member.Identity,
                    FullName = member.FullName,
                }
            end
        end
        for _, member in ipairs(rosterState.Members) do
            if member.IsAssistant and not desired.Assists[member.Identity] then
                operations[#operations + 1] = {
                    Kind = "demote-assistant",
                    Identity = member.Identity,
                    FullName = member.FullName,
                }
            end
        end
    end

    if desired.TanksPresent then
        for _, member in ipairs(rosterState.Members) do
            if desired.Tanks[member.Identity] and member.Role ~= "TANK" then
                operations[#operations + 1] = {
                    Kind = "set-tank",
                    Identity = member.Identity,
                    FullName = member.FullName,
                }
            end
        end
        for _, member in ipairs(rosterState.Members) do
            if member.Role == "TANK" and not desired.Tanks[member.Identity] then
                operations[#operations + 1] = {
                    Kind = "clear-tank",
                    Identity = member.Identity,
                    FullName = member.FullName,
                }
            end
        end
    end
    return operations
end

local function CancelTimer(self)
    reconcileGeneration = reconcileGeneration + 1
    local timer = reconcileTimer
    reconcileTimer = nil
    if timer and type(self.CancelTimer) == "function" then
        pcall(self.CancelTimer, self, timer)
    end
end

local function ScheduleReconcile(self, delay)
    if reconcileTimer then
        return true
    end
    if type(self.ScheduleTimer) ~= "function" then
        return false, "timer-unavailable"
    end
    reconcileGeneration = reconcileGeneration + 1
    local generation = reconcileGeneration
    local called, timer =
        pcall(self.ScheduleTimer, self, "PollDisplayedRaidAssignments", math.max(delay or 0, 0), generation)
    if not called or not timer then
        return false, "timer-unavailable"
    end
    reconcileTimer = timer
    return true
end

local function Notify(self, success, result)
    if type(self.OnDisplayedRaidAssignmentsFinished) == "function" then
        pcall(self.OnDisplayedRaidAssignmentsFinished, self, success == true, result)
    end
end

local function ReportFailure(self, errorCode, failureScope)
    local intentKey = failureScope or (currentIntent and currentIntent.Signature) or "none"
    local reportKey = intentKey .. "\031" .. tostring(errorCode)
    if lastReportedFailure ~= reportKey then
        lastReportedFailure = reportKey
        Notify(self, false, errorCode)
    end
    appliedMutationCount = 0
end

local function RetryTransientRead(self, errorCode, bucket)
    if not currentIntent or not TRANSIENT_READ_ERRORS[errorCode] then
        return false
    end
    local attemptsKey
    if bucket == "desired" then
        attemptsKey = "TransientDesiredAttempts"
    elseif bucket == "eligibility" then
        attemptsKey = "TransientEligibilityAttempts"
    elseif bucket == "assistant" then
        attemptsKey = "TransientAssistantAttempts"
    else
        attemptsKey = "TransientReadAttempts"
    end
    local attempts = currentIntent[attemptsKey] or 0
    if attempts >= MAX_TRANSIENT_READ_RETRIES then
        return false
    end
    currentIntent[attemptsKey] = attempts + 1
    local scheduled, scheduleError = ScheduleReconcile(self, POLL_INTERVAL)
    if not scheduled then
        ReportFailure(self, scheduleError)
        return false, scheduleError
    end
    return true, "retrying"
end

local function CurrentSnapshot(self)
    if type(self.GetDisplayedNote) ~= "function" then
        return nil
    end
    local called, snapshot = pcall(self.GetDisplayedNote, self)
    return called and type(snapshot) == "table" and snapshot or nil
end

local function OperationAcknowledged(operation, rosterState)
    if operation.Kind == "disable-everyone-assistant" then
        local enabled, errorCode = EveryoneIsAssistant()
        if errorCode then
            return nil, errorCode
        end
        return not enabled
    end
    local member = rosterState.ByIdentity[operation.Identity]
    if not member then
        return nil, "operation-member-missing"
    end
    if operation.Kind == "demote-assistant" then
        return not member.IsAssistant
    end
    if operation.Kind == "promote-assistant" then
        return member.IsAssistant
    end
    if operation.Kind == "set-tank" then
        return member.Role == "TANK"
    end
    if operation.Kind == "clear-tank" then
        return member.Role ~= "TANK"
    end
    return false
end

local function SetTankRole(self, member, enabled)
    local enumRoles = type(Enum) == "table" and Enum.LFGRole or nil
    local tankRole = type(enumRoles) == "table" and (enumRoles.Tank or enumRoles.TANK) or nil
    if type(UnitSetRoleEnum) == "function" and tankRole ~= nil then
        local called, accepted = pcall(UnitSetRoleEnum, member.Unit, enabled and tankRole or nil)
        Trace(
            self,
            "raid-assignment-role-call",
            "api=enum unit=%s role=%s value=%s called=%s accepted=%s",
            tostring(member.Unit),
            enabled and "TANK" or "NONE",
            tostring(enabled and tankRole or nil),
            tostring(called),
            tostring(accepted)
        )
        if called then
            return accepted == true
        end
    end
    if type(UnitSetRole) == "function" then
        local role = enabled and "TANK" or "NONE"
        local called, accepted = pcall(UnitSetRole, member.Unit, role)
        Trace(
            self,
            "raid-assignment-role-call",
            "api=string unit=%s role=%s value=%s called=%s accepted=%s",
            tostring(member.Unit),
            enabled and "TANK" or "NONE",
            role,
            tostring(called),
            tostring(accepted)
        )
        return called and accepted == true
    end
    return false
end

local function IssueOperation(self, operation, rosterState)
    if operation.Kind == "disable-everyone-assistant" then
        if type(C_PartyInfo) ~= "table" or type(C_PartyInfo.SetEveryoneIsAssistant) ~= "function" then
            return false
        end
        local called, updated = pcall(C_PartyInfo.SetEveryoneIsAssistant, false)
        return called and updated ~= false
    end

    local member = rosterState.ByIdentity[operation.Identity]
    if not member then
        return false
    end
    if operation.Kind == "demote-assistant" or operation.Kind == "promote-assistant" then
        if type(C_PartyInfo) ~= "table" then
            return false
        end
        local callback = operation.Kind == "promote-assistant" and C_PartyInfo.PromoteToAssistant
            or C_PartyInfo.DemoteAssistant
        return type(callback) == "function" and pcall(callback, member.FullName, true)
    end
    if operation.Kind == "set-tank" then
        return SetTankRole(self, member, true)
    end
    if operation.Kind == "clear-tank" then
        return SetTankRole(self, member, false)
    end
    return false
end

local function MutationApisAvailable(desired, everyoneAssistant)
    if desired.AssistsPresent then
        if
            type(C_PartyInfo) ~= "table"
            or type(C_PartyInfo.PromoteToAssistant) ~= "function"
            or type(C_PartyInfo.DemoteAssistant) ~= "function"
            or everyoneAssistant and type(C_PartyInfo.SetEveryoneIsAssistant) ~= "function"
        then
            return false
        end
    end
    if desired.TanksPresent then
        local enumRoles = type(Enum) == "table" and Enum.LFGRole or nil
        local tankRole = type(enumRoles) == "table" and (enumRoles.Tank or enumRoles.TANK) or nil
        if not (type(UnitSetRoleEnum) == "function" and tankRole ~= nil) and type(UnitSetRole) ~= "function" then
            return false
        end
    end
    return true
end

--- Advances one latest-page reconciliation operation.
-- @tparam[opt] number generation Scheduled timer generation.
-- @treturn boolean activeOrComplete
-- @treturn number|string status
function AngryEra:PollDisplayedRaidAssignments(generation)
    if generation and generation ~= reconcileGeneration then
        return false, "superseded"
    end
    reconcileTimer = nil
    if not currentIntent then
        return false, "no-assignment-intent"
    end
    if not IsRaidLeader(self) then
        return false, "not-raid-leader"
    end
    if InCombat() then
        return true, "queued"
    end

    local snapshot = CurrentSnapshot(self)
    if not snapshot or not SameReference(currentIntent.Reference, CopyReference(snapshot)) then
        currentIntent = nil
        outstandingOperation = nil
        appliedMutationCount = 0
        lastReportedFailure = nil
        return false, "display-changed"
    end
    local rosterState, rosterError = BuildRosterState()
    if not rosterState then
        local retrying, retryStatus = RetryTransientRead(self, rosterError)
        if retrying then
            return true, retryStatus
        end
        if retryStatus then
            return false, retryStatus
        end
        ReportFailure(self, rosterError)
        return false, rosterError
    end
    currentIntent.TransientReadAttempts = 0

    if outstandingOperation then
        if outstandingOperation.IntentSignature ~= currentIntent.Signature then
            outstandingOperation = nil
        else
            local acknowledged, acknowledgementError = OperationAcknowledged(outstandingOperation, rosterState)
            if acknowledged then
                outstandingOperation = nil
                appliedMutationCount = appliedMutationCount + 1
            elseif acknowledgementError == "operation-member-missing" then
                outstandingOperation = nil
            elseif acknowledgementError then
                local retrying, retryStatus = RetryTransientRead(self, acknowledgementError, "assistant")
                if retrying then
                    return true, retryStatus
                end
                outstandingOperation = nil
                if retryStatus then
                    return false, retryStatus
                end
                ReportFailure(self, acknowledgementError)
                return false, acknowledgementError
            elseif Now() - outstandingOperation.SentAt >= ACK_TIMEOUT then
                outstandingOperation = nil
                ReportFailure(self, "assignment-api-timeout")
                return false, "assignment-api-timeout"
            else
                local scheduled, scheduleError = ScheduleReconcile(self, POLL_INTERVAL)
                if not scheduled then
                    ReportFailure(self, scheduleError)
                    return false, scheduleError
                end
                return true, "in-progress"
            end
        end
    end

    local desired, desiredError = BuildDesiredState(snapshot.Meta, rosterState)
    if not desired then
        if desiredError == "unmanaged" then
            currentIntent = nil
            appliedMutationCount = 0
            return false, desiredError
        end
        local retrying, retryStatus = RetryTransientRead(self, desiredError, "desired")
        if retrying then
            return true, retryStatus
        end
        if retryStatus then
            return false, retryStatus
        end
        ReportFailure(self, desiredError)
        return false, desiredError
    end
    currentIntent.TransientDesiredAttempts = 0

    local eligible, eligibilityError = ValidateTankEligibility(self, desired, rosterState)
    if not eligible then
        local retrying, retryStatus = RetryTransientRead(self, eligibilityError, "eligibility")
        if retrying then
            return true, retryStatus
        end
        if retryStatus then
            return false, retryStatus
        end
        ReportFailure(self, eligibilityError)
        return false, eligibilityError
    end
    currentIntent.TransientEligibilityAttempts = 0

    local everyoneAssistant = false
    if desired.AssistsPresent then
        local assistantStateError
        everyoneAssistant, assistantStateError = EveryoneIsAssistant()
        if assistantStateError then
            local retrying, retryStatus = RetryTransientRead(self, assistantStateError, "assistant")
            if retrying then
                return true, retryStatus
            end
            if retryStatus then
                return false, retryStatus
            end
            ReportFailure(self, assistantStateError)
            return false, assistantStateError
        end
        currentIntent.TransientAssistantAttempts = 0
    end
    if not MutationApisAvailable(desired, everyoneAssistant) then
        ReportFailure(self, "assignment-api-unavailable")
        return false, "assignment-api-unavailable"
    end

    local operations = raidAssignments.PlanOperations(rosterState, desired, everyoneAssistant)
    Trace(
        self,
        "raid-assignment-plan",
        "operations=%d tanks=%s assists=%s",
        #operations,
        tostring(desired.TanksPresent),
        tostring(desired.AssistsPresent)
    )
    local operation = operations[1]
    if not operation then
        local changed = appliedMutationCount
        appliedMutationCount = 0
        lastReportedFailure = nil
        if changed > 0 then
            Notify(self, true, changed)
        end
        return true, changed
    end

    local now = Now()
    if lastOperationSentAt and now - lastOperationSentAt < MIN_CALL_INTERVAL then
        local delay = math.max(MIN_CALL_INTERVAL - (now - lastOperationSentAt), 0)
        local scheduled, scheduleError = ScheduleReconcile(self, delay)
        if not scheduled then
            ReportFailure(self, scheduleError)
            return false, scheduleError
        end
        return true, "in-progress"
    end

    -- Secure the acknowledgement poll before invoking a restricted API. Role
    -- events can fire synchronously, and their retry must observe this paced
    -- timer instead of scheduling an immediate second mutation.
    local scheduled, scheduleError = ScheduleReconcile(self, POLL_INTERVAL)
    if not scheduled then
        ReportFailure(self, scheduleError)
        return false, scheduleError
    end

    operation.Reference = CopyReference(currentIntent.Reference)
    operation.IntentSignature = currentIntent.Signature
    operation.SentAt = now
    outstandingOperation = operation
    lastOperationSentAt = now
    if not IssueOperation(self, operation, rosterState) then
        outstandingOperation = nil
        CancelTimer(self)
        ReportFailure(self, "assignment-api-failed")
        return false, "assignment-api-failed"
    end
    return true, "in-progress"
end

--- Observes resolved `$TANKS`/`$ASSISTS` metadata from the authoritative display.
-- @tparam table|nil snapshot Displayed-note snapshot.
-- @tparam string|nil variableError Inherited-variable merge failure.
-- @treturn boolean requested
-- @treturn string status
function AngryEra:ObserveDisplayedRaidAssignments(snapshot, variableError)
    local reference = CopyReference(snapshot)
    local meta = type(snapshot) == "table" and snapshot.Meta or nil
    local tanksPresent, tanks = MetadataEntry(meta, "TANKS")
    local assistsPresent, assists = MetadataEntry(meta, "ASSISTS")
    if variableError ~= nil then
        local failureScope = reference
                and IntentSignature(reference, tanksPresent, tanks, assistsPresent, assists) .. "\031context:" .. tostring(
                    variableError
                )
            or "invalid-context:" .. tostring(variableError)
        currentIntent = nil
        outstandingOperation = nil
        appliedMutationCount = 0
        CancelTimer(self)
        if (tanksPresent or assistsPresent) and IsRaidLeader(self) then
            ReportFailure(self, "invalid-assignment-context", failureScope)
        else
            lastReportedFailure = nil
        end
        return false, "invalid-assignment-context"
    end
    if not reference or not tanksPresent and not assistsPresent then
        currentIntent = nil
        outstandingOperation = nil
        appliedMutationCount = 0
        lastReportedFailure = nil
        CancelTimer(self)
        return false, reference and "unmanaged" or "no-display"
    end

    local signature = IntentSignature(reference, tanksPresent, tanks, assistsPresent, assists)
    if not currentIntent or currentIntent.Signature ~= signature then
        CancelTimer(self)
        outstandingOperation = nil
        appliedMutationCount = 0
        currentIntent = {
            Reference = reference,
            Signature = signature,
            TransientReadAttempts = 0,
        }
        lastReportedFailure = nil
    end
    if InCombat() then
        CancelTimer(self)
        return true, "queued"
    end
    local scheduled, scheduleError = ScheduleReconcile(self, 0)
    return scheduled, scheduled and "scheduled" or scheduleError
end

--- Invalidates old-page work as soon as a newer display tuple is accepted but
-- still waiting for its page/context payload.
-- @tparam table|nil reference Newly accepted display tuple.
-- @treturn boolean canceled
function AngryEra:InvalidatePendingDisplayedRaidAssignments(reference)
    local nextReference = CopyReference(reference)
    local canceled = false
    if currentIntent and not SameReference(currentIntent.Reference, nextReference) then
        currentIntent = nil
        canceled = true
    end
    if outstandingOperation and not SameReference(outstandingOperation.Reference, nextReference) then
        outstandingOperation = nil
        canceled = true
    end
    if canceled then
        CancelTimer(self)
        appliedMutationCount = 0
        lastReportedFailure = nil
    end
    return canceled
end

--- Schedules a fresh readback/replan after roster or role state changes.
-- @treturn boolean requested
-- @treturn string status
function AngryEra:RetryDisplayedRaidAssignments()
    if not currentIntent then
        return false, "no-assignment-intent"
    end
    if InCombat() then
        CancelTimer(self)
        return true, "queued"
    end
    local scheduled, scheduleError = ScheduleReconcile(self, 0)
    return scheduled, scheduled and "scheduled" or scheduleError
end

--- Pauses unissued work while retaining only the latest exact display intent.
-- @treturn boolean paused
function AngryEra:PauseDisplayedRaidAssignmentsForCombat()
    if currentIntent or outstandingOperation then
        CancelTimer(self)
        return true
    end
    return false
end

--- Flushes the latest queued work after combat.
-- @treturn boolean activeOrComplete
-- @treturn number|string status
function AngryEra:FlushDisplayedRaidAssignments()
    if not currentIntent then
        return false, "no-assignment-intent"
    end
    return self:PollDisplayedRaidAssignments()
end

--- Clears all session-local assignment automation state.
function AngryEra:ResetDisplayedRaidAssignmentState()
    CancelTimer(self)
    currentIntent = nil
    outstandingOperation = nil
    appliedMutationCount = 0
    lastReportedFailure = nil
    lastOperationSentAt = nil
end
