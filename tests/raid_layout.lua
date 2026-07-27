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

-- Already-correct assignments need no moves.
assert(#Reaches({ [1] = 1, [2] = 2 }, { [1] = 1 }) == 0, "a satisfied layout produces no moves")

-- A larger reshuffle still reaches the target.
Reaches(
    { [1] = 1, [2] = 1, [3] = 2, [4] = 2, [5] = 3, [6] = 3, [7] = 4, [8] = 4, [9] = 5, [10] = 5 },
    { [1] = 5, [10] = 1, [5] = 2 }
)

-- Oversubscribing a subgroup is rejected up front.
local _, okOver, errOver = rl.PlanSubgroupMoves(
    { [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6 },
    { [1] = 1, [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 1 }
)
assert(not okOver and errOver == "subgroup-oversubscribed", "more than five in one subgroup is rejected")

-- Wanting a member who is not in the raid is rejected.
local _, okUnknown, errUnknown = rl.PlanSubgroupMoves({ [1] = 1 }, { [99] = 2 })
assert(not okUnknown and errUnknown == "unknown-member", "an unknown member is rejected")

-- Integration coverage for ApplyGroupLayoutToRaid. These globals mirror the
-- narrow WoW API surface used by the driver and record every destructive call.
local inRaid = true
local inCombat = false
local applyAllowed = true
local layoutSource
local layoutVars
local operations = {}

function _G.IsInRaid()
    return inRaid
end

function _G.InCombatLockdown()
    return inCombat
end

function _G.GetNumGroupMembers()
    return #raidMembers
end

function _G.GetRaidRosterInfo(index)
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
    operations[#operations + 1] = { Kind = "set", Index = index, Subgroup = subgroup }
end

function _G.SwapRaidSubgroup(index1, index2)
    operations[#operations + 1] = { Kind = "swap", Index1 = index1, Index2 = index2 }
end

function AngryEra:CanLocalPlayerApplyRaidLayout()
    return applyAllowed
end

function AngryEra:GetDisplayedMeta()
    return { LAYOUT = layoutSource }
end

function AngryEra:GetDisplayedVars()
    return layoutVars
end

local function Apply(members, source, variables, allowed)
    raidMembers = members
    layoutSource = source
    layoutVars = variables
    applyAllowed = allowed ~= false
    operations = {}
    return AngryEra:ApplyGroupLayoutToRaid()
end

-- The centralized permission helper is authoritative, including for callers
-- that would otherwise be raid assistants.
local applied, reason = Apply({ { Name = "A-Home", Subgroup = 1 } }, "G/1: A", nil, false)
assert(not applied and reason == "not-authorized", "an unauthorized caller cannot apply a layout")
assert(#operations == 0, "authorization failure performs no raid mutation")

local permissionHelper = AngryEra.CanLocalPlayerApplyRaidLayout
AngryEra.CanLocalPlayerApplyRaidLayout = nil
applied, reason = Apply({ { Name = "A-Home", Subgroup = 1 } }, "G/1: A")
assert(not applied and reason == "not-authorized", "a missing permission helper fails closed")
assert(#operations == 0, "a missing permission helper performs no raid mutation")

AngryEra.CanLocalPlayerApplyRaidLayout = function()
    error("permission lookup failed")
end
applied, reason = Apply({ { Name = "A-Home", Subgroup = 1 } }, "G/1: A")
assert(not applied and reason == "not-authorized", "a failing permission helper fails closed")
assert(#operations == 0, "a failing permission helper performs no raid mutation")
AngryEra.CanLocalPlayerApplyRaidLayout = permissionHelper

-- A short name prefers the exact same-realm member and never guesses the first
-- matching short name returned by the raid roster.
applied, reason = Apply({
    { Name = "Zed-Other", Subgroup = 1 },
    { Name = "Zed-Home", Subgroup = 2 },
}, "Home/2: Zed")
assert(applied and reason == 0, "a short name resolves to the same-realm member")
assert(#operations == 0, "the already-seated same-realm member does not move")

-- With no same-realm member, a duplicated short name is ambiguous and Apply
-- fails closed before any subgroup operation.
applied, reason = Apply({
    { Name = "Zed-Other", Subgroup = 1 },
    { Name = "Zed-Third", Subgroup = 2 },
}, "Ambiguous/2: Zed")
assert(not applied and reason == "unresolved-member", "an ambiguous short name is rejected")
assert(#operations == 0, "an ambiguous name performs no raid mutation")

-- A unique cross-realm short name is safe to resolve canonically.
applied, reason = Apply({ { Name = "Zed-Other", Subgroup = 1 } }, "Cross/2: Zed")
assert(applied and reason == 1, "a unique cross-realm short name can be applied")
assert(
    #operations == 1 and operations[1].Kind == "set" and operations[1].Index == 1 and operations[1].Subgroup == 2,
    "the unique canonical member is moved"
)

-- Priority resolution uses canonical roster names too, so a same-realm primary
-- is not confused with a cross-realm member of the same short name.
applied, reason = Apply({
    { Name = "Zed-Other", Subgroup = 1 },
    { Name = "Zed-Home", Subgroup = 2 },
    { Name = "Backup-Home", Subgroup = 1 },
}, "Priority/2: Zed > Backup")
assert(applied and reason == 0, "priority resolution targets the canonical same-realm member")
assert(#operations == 0, "an already-correct priority target does not move")

-- Explicit short/full duplicates are rejected as one canonical raid member.
applied, reason = Apply({ { Name = "Zed-Home", Subgroup = 1 } }, "One/1: Zed; Two/2: Zed-Home")
assert(not applied and reason == "duplicate-member", "canonical duplicate assignments are rejected")
assert(#operations == 0, "duplicate validation finishes before raid mutation")

-- A typo anywhere makes the entire destructive operation fail closed; valid
-- assignments earlier in the layout are not partially applied.
applied, reason = Apply({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "Move/2: Alice, Typo; Stay/1: Bob")
assert(not applied and reason == "unresolved-member", "an unresolved member rejects the whole layout")
assert(#operations == 0, "unresolved validation prevents a partial apply")

-- Variable expansion is included in five-seat capacity validation.
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
assert(#operations == 0, "capacity validation finishes before raid mutation")

local roleVariables =
    assert(variableHelpers.MergeVariableLayers({}, "PRIEST1=Alice\nPALADIN1=Bob\nHEALER*=PRIEST*,PALADIN*"))
applied, reason = Apply({
    { Name = "Alice-Home", Subgroup = 1 },
    { Name = "Bob-Home", Subgroup = 1 },
}, "Healers/2: {{HEALER1}}, {{HEALER2}}", roleVariables)
assert(applied and reason == 2, "generated family members should apply like ordinary layout variables")
assert(#operations == 2, "each generated role member should move into the bound subgroup")

roleVariables =
    assert(variableHelpers.MergeVariableLayers({}, "PRIEST1=Alice\nPALADIN1=Alice\nHEALER*=PRIEST*,PALADIN*"))
applied, reason = Apply({
    { Name = "Alice-Home", Subgroup = 1 },
}, "Healers/2: {{HEALER1}}, {{HEALER2}}", roleVariables)
assert(not applied and reason == "duplicate-member", "duplicate generated role values should fail visibly")
assert(#operations == 0, "duplicate generated roles should never partially rearrange the raid")

print("Raid layout planner and apply tests passed.")
