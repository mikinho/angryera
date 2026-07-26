-- -------------------------------------------------------------------------------
-- Angry Era: modules/raid_layout.lua
--
-- Applies a group layout to the actual raid by moving members between raid
-- subgroups. The move planner is pure and deterministic; the driver is gated to
-- the raid leader/assistants, out of combat, and is only ever run on an explicit
-- action (never automatically).
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

    local ops = {}
    local guard = 0
    while true do
        guard = guard + 1
        if guard > MAX_OPS then
            return {}, false, "plan-too-large"
        end
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
            for _, index in ipairs(allIndices) do
                if index ~= i and groupOf[index] == targetSub and want[index] ~= targetSub then
                    swapWith = index
                    break
                end
            end
            if not swapWith then
                return {}, false, "subgroup-blocked"
            end
            ops[#ops + 1] = { Kind = "swap", Index1 = i, Index2 = swapWith }
            groupOf[i], groupOf[swapWith] = targetSub, fromSub
        end
    end
    return ops, true
end

local function IsInRaidGroup()
    return type(IsInRaid) == "function" and IsInRaid()
end

local function CanRearrangeRaid()
    if not IsInRaidGroup() then
        return false
    end
    if type(UnitIsGroupLeader) == "function" and UnitIsGroupLeader("player") then
        return true
    end
    return type(UnitIsGroupAssistant) == "function" and UnitIsGroupAssistant("player") == true
end

-- Reads the raid roster into index/subgroup maps and layout resolution providers.
local function BuildRaidState()
    local subgroupByIndex = {}
    local indexByName = {}
    local classMembers = {}
    local subgroupMembers = {}
    local count = type(GetNumGroupMembers) == "function" and GetNumGroupMembers() or 0
    for index = 1, count do
        local rawName, _, subgroup, _, _, class, _, online, isDead = GetRaidRosterInfo(index)
        if rawName then
            local fullName = helpers.EnsureUnitFullName(rawName)
            subgroupByIndex[index] = subgroup or 1
            local fullLower = type(fullName) == "string" and fullName:lower() or rawName:lower()
            indexByName[fullLower] = index
            local shortLower = fullLower:match("^([^-]+)")
            if shortLower and indexByName[shortLower] == nil then
                indexByName[shortLower] = index
            end
            if online and not isDead and type(class) == "string" then
                local up = class:upper()
                classMembers[up] = classMembers[up] or {}
                classMembers[up][#classMembers[up] + 1] = fullName
                if type(subgroup) == "number" then
                    subgroupMembers[subgroup] = subgroupMembers[subgroup] or {}
                    subgroupMembers[subgroup][#subgroupMembers[subgroup] + 1] = fullName
                end
            end
        end
    end
    local providers = {
        ResolvePriorityValue = roster and roster.ResolvePriorityValue,
        ClassMembers = function(class)
            return classMembers[class] or {}
        end,
        SubgroupMembers = function(subgroup)
            return subgroupMembers[subgroup] or {}
        end,
    }
    return subgroupByIndex, indexByName, providers
end

local function DisplayedLayoutSource(self)
    if type(self.GetDisplayedMeta) ~= "function" then
        return nil
    end
    local ok, meta = pcall(self.GetDisplayedMeta, self)
    if not ok or type(meta) ~= "table" then
        return nil
    end
    for key, value in pairs(meta) do
        if type(key) == "string" and type(value) == "string" and key:upper() == "LAYOUT" then
            return value
        end
    end
    return nil
end

--- Rearranges the raid subgroups to match the displayed page's `$LAYOUT`.
-- Leader/assist and out-of-combat only, and never automatic. Groups bound with
-- `/N` map to raid subgroup N; unbound groups are display-only and ignored here.
-- @treturn boolean applied
-- @treturn number|string movedCountOrReason
function AngryEra:ApplyGroupLayoutToRaid()
    if not IsInRaidGroup() then
        return false, "not-in-raid"
    end
    if not CanRearrangeRaid() then
        return false, "not-raid-leader"
    end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        return false, "in-combat"
    end

    local source = DisplayedLayoutSource(self)
    if not source then
        return false, "no-layout"
    end

    local subgroupByIndex, indexByName, providers = BuildRaidState()
    local resolved = layout.Resolve(layout.Parse(source), providers)

    local want = {}
    local unresolved = 0
    for _, group in ipairs(resolved.groups) do
        if type(group.subgroup) == "number" then
            for _, name in ipairs(group.members) do
                local index = indexByName[name:lower()] or indexByName[(name:lower():match("^([^-]+)") or "")]
                if index then
                    want[index] = group.subgroup
                else
                    unresolved = unresolved + 1
                end
            end
        end
    end

    if next(want) == nil then
        return false, "no-bound-groups"
    end

    local ops, ok, err = raid_layout.PlanSubgroupMoves(subgroupByIndex, want)
    if not ok then
        return false, err
    end

    for _, op in ipairs(ops) do
        if type(InCombatLockdown) == "function" and InCombatLockdown() then
            return false, "in-combat"
        end
        if op.Kind == "set" then
            SetRaidSubgroup(op.Index, op.Subgroup)
        else
            SwapRaidSubgroup(op.Index1, op.Index2)
        end
    end

    return true, #ops
end
