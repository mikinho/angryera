local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

assert(loadfile("modules/raid_layout.lua"))("AngryEra", app)
local rl = AngryEra.utils.raid_layout

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

print("Raid layout planner tests passed.")
