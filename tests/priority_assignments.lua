local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

-- Controllable roster. Each member: { full = "Name-Realm", online = bool, dead = bool }.
local members = {}
local function SetRoster(list)
    members = list
end

AngryEra.utils.helpers = {
    EnsureUnitFullName = function(name)
        if name and not name:find("-", 1, true) then
            return name .. "-Bloodfang"
        end
        return name
    end,
    IterateGroupMembers = function(callback)
        for _, member in ipairs(members) do
            if callback(nil, member.full, 0, 1, nil, member.online ~= false, member.dead == true, "raidX") then
                return
            end
        end
    end,
}

assert(loadfile("modules/utils/roster.lua"))("AngryEra", app)
local roster = AngryEra.utils.roster

local function Resolve(value)
    return (roster.ResolvePriorityValue(value))
end

-- First present-and-alive member wins.
SetRoster({
    { full = "Main-Bloodfang", online = true, dead = false },
    { full = "Backup-Bloodfang", online = true, dead = false },
})
assert(Resolve("Main > Backup") == "Main", "the first present-and-alive member wins")

-- A dead primary is skipped.
SetRoster({
    { full = "Main-Bloodfang", online = true, dead = true },
    { full = "Backup-Bloodfang", online = true, dead = false },
})
assert(Resolve("Main > Backup") == "Backup", "a dead primary is skipped")

-- An offline primary is skipped.
SetRoster({
    { full = "Main-Bloodfang", online = false, dead = false },
    { full = "Backup-Bloodfang", online = true, dead = false },
})
assert(Resolve("Main > Backup") == "Backup", "an offline primary is skipped")

-- With none present, the primary name is still shown.
SetRoster({})
local resolved, wasPriority = roster.ResolvePriorityValue("Main > Backup")
assert(resolved == "Main" and wasPriority == true, "no eligible member falls back to the primary")

-- Non-priority values are left untouched.
assert(select(2, roster.ResolvePriorityValue("JustAName")) == false, "a plain value is not a priority list")
assert(
    select(2, roster.ResolvePriorityValue("Kill boss > move on pull")) == false,
    "prose with > is not a priority list"
)
assert(select(2, roster.ResolvePriorityValue("A >> B")) == false, "a malformed list is rejected")
assert(select(2, roster.ResolvePriorityValue("")) == false, "an empty value is not a priority list")

-- Realm-aware membership.
SetRoster({ { full = "Zed-Darkspear", online = true, dead = false } })
assert(roster.IsPresentAndAlive("Zed") == true, "a unique cross-realm short name matches")
assert(
    roster.ResolvePresentAndAliveName("Zed") == "Zed-Darkspear",
    "a unique short name resolves to its canonical full roster name"
)

SetRoster({ { full = "Zed-Frostwolf", online = true, dead = false } })
assert(roster.IsPresentAndAlive("Zed-Frostwolf") == true, "a qualified name matches its realm exactly")
assert(roster.IsPresentAndAlive("Zed-Darkspear") == false, "a qualified name to an absent realm does not match")

SetRoster({
    { full = "Zed-Darkspear", online = true, dead = false },
    { full = "Zed-Frostwolf", online = true, dead = false },
})
assert(roster.IsPresentAndAlive("Zed") == false, "an ambiguous cross-realm short name is rejected")
local ambiguousName, ambiguousReason = roster.ResolvePresentAndAliveName("Zed")
assert(ambiguousName == nil and ambiguousReason == "ambiguous-name", "canonical resolution reports ambiguity")

SetRoster({
    { full = "Zed-Darkspear", online = true, dead = false },
    { full = "Zed-Bloodfang", online = true, dead = false },
})
assert(
    roster.ResolvePresentAndAliveName("Zed") == "Zed-Bloodfang",
    "an unqualified name prefers the exact member on the player's realm"
)

-- WoW names are UTF-8; Lua 5.1 character classes are not. Priority parsing
-- accepts those names and canonical resolution still returns the full name.
SetRoster({
    { full = "Éowyn-Bloodfang", online = true, dead = false },
    { full = "Backup-Bloodfang", online = true, dead = false },
})
local unicodeResolved, unicodePriority = roster.ResolvePriorityValue("Éowyn > Backup")
assert(unicodeResolved == "Éowyn" and unicodePriority == true, "UTF-8 names are accepted in priorities")
assert(
    roster.ResolvePriorityFullName("Éowyn > Backup") == "Éowyn-Bloodfang",
    "priority resolution can return the canonical full roster name"
)

-- The map hook resolves both marker ($) and text keys to the same member.
SetRoster({
    { full = "Main-Bloodfang", online = true, dead = false },
    { full = "Backup-Bloodfang", online = true, dead = false },
})
local vars = { ["$MOON"] = "Main > Backup", MOON = "Main > Backup", MT = "Vn" }
assert(roster.ApplyPriorityAssignments(vars) == true, "a map containing a priority list reports it")
assert(vars["$MOON"] == "Main" and vars.MOON == "Main", "marker metadata and text resolve to the same member")
assert(vars.MT == "Vn", "plain values are untouched")

-- A dead primary reassigns both surfaces together.
SetRoster({
    { full = "Main-Bloodfang", online = true, dead = true },
    { full = "Backup-Bloodfang", online = true, dead = false },
})
local reassigned = { ["$MOON"] = "Main > Backup", MOON = "Main > Backup" }
roster.ApplyPriorityAssignments(reassigned)
assert(reassigned["$MOON"] == "Backup" and reassigned.MOON == "Backup", "a dead primary reassigns marker and text")

assert(roster.ApplyPriorityAssignments({ MT = "Vn" }) == false, "a map without priority lists reports false")

print("Priority assignment tests passed.")
