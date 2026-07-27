local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

local members = {}
local assignedRoles = {}

AngryEra.utils.helpers = {
    IterateGroupMembers = function(callback)
        for _, member in ipairs(members) do
            if callback(member.raw, member.full, 0, 1, member.class, member.online, member.dead, member.unit) then
                return
            end
        end
    end,
}

_G.UnitGroupRolesAssigned = nil
_G.UnitGroupRolesAssignedEnum = nil
_G.Enum = nil
_G.LFG_ROLE_NO_ROLE = nil
_G.IsInGroup = nil
_G.IsInRaid = nil

assert(loadfile("modules/utils/roster.lua"))("AngryEra", app)
local roster = AngryEra.utils.roster

local function SetRoster(nextMembers, nextRoles)
    members = nextMembers or {}
    assignedRoles = nextRoles or {}
    _G.UnitGroupRolesAssigned = function(unit)
        local value = assignedRoles[unit]
        if value == "ERROR" then
            error("role lookup failed")
        end
        return value
    end
end

local rows, scanError = roster.ScanAssignedRoles()
assert(rows == nil and scanError == "role-api-unavailable", "a missing Blizzard role API should fail safely")

_G.UnitGroupRolesAssigned = function()
    return "NONE"
end
_G.IsInGroup = function()
    return false
end
_G.IsInRaid = function()
    return false
end
rows, scanError = roster.ScanAssignedRoles()
assert(rows == nil and scanError == "not-grouped", "a solo player should not produce an assigned-role roster")
_G.IsInGroup = nil
_G.IsInRaid = nil

SetRoster({
    {
        raw = "NoRole",
        full = "NoRole-Mankrik",
        unit = "raid1",
        online = true,
        dead = false,
    },
}, { raid1 = "NONE" })
rows, scanError = roster.ScanAssignedRoles()
assert(rows == nil and scanError == "no-assigned-roles", "a roster without assigned roles should fail safely")

-- Results include offline/dead members, map DAMAGER to DPS, and sort by role
-- then canonical full name rather than callback order.
SetRoster({
    {
        raw = "Zed-Frostwolf",
        full = "Zed-Frostwolf",
        unit = "raid4",
        online = true,
        dead = false,
    },
    {
        raw = "Healz",
        full = "Healz-Mankrik",
        unit = "raid2",
        online = false,
        dead = true,
    },
    {
        raw = "Tanky",
        full = "Tanky-Mankrik",
        unit = "raid1",
        online = false,
        dead = true,
    },
    {
        raw = "Zed-Darkspear",
        full = "Zed-Darkspear",
        unit = "raid3",
        online = true,
        dead = false,
    },
    {
        raw = "SoloZed",
        full = "SoloZed-Mankrik",
        unit = "raid5",
        online = true,
        dead = false,
    },
}, {
    raid1 = "TANK",
    raid2 = "HEALER",
    raid3 = "DAMAGER",
    raid4 = "NONE",
    raid5 = "DAMAGER",
})
rows, scanError = roster.ScanAssignedRoles()
assert(rows and not scanError and #rows == 4, "assigned roles should scan")
assert(
    rows[1].Role == "TANK" and rows[1].Name == "Tanky" and rows[1].Online == false and rows[1].IsDead == true,
    "offline and dead tanks should remain in the assigned-role roster"
)
assert(
    rows[2].Role == "HEALER" and rows[2].Name == "Healz" and rows[2].Online == false and rows[2].IsDead == true,
    "offline and dead healers should remain in the assigned-role roster"
)
assert(
    rows[3].Role == "DPS" and rows[3].Name == "SoloZed" and rows[4].Role == "DPS" and rows[4].Name == "Zed-Darkspear",
    "damage roles should map to DPS and sort by canonical full name"
)
assert(
    rows[4].Name == "Zed-Darkspear",
    "an assigned name should stay realm-qualified when an unassigned roster member has the same short name"
)

-- Numeric enum values are accepted without binding the module to a particular
-- client build's numbers.
_G.Enum = {
    LFGRole = {
        Tank = 0,
        Healer = 1,
        Damage = 2,
    },
}
_G.LFG_ROLE_NO_ROLE = -1
SetRoster({
    { raw = "EnumTank", full = "EnumTank-Mankrik", unit = "party1", online = true, dead = false },
    { raw = "EnumHealer", full = "EnumHealer-Mankrik", unit = "party2", online = true, dead = false },
    { raw = "EnumDamage", full = "EnumDamage-Mankrik", unit = "player", online = true, dead = false },
}, {
    party1 = 0,
    party2 = 1,
    player = 2,
})
_G.UnitGroupRolesAssignedEnum = _G.UnitGroupRolesAssigned
_G.UnitGroupRolesAssigned = nil
rows, scanError = roster.ScanAssignedRoles()
assert(rows and not scanError and #rows == 3, "numeric Blizzard role enums should scan")
assert(
    rows[1].Role == "TANK" and rows[2].Role == "HEALER" and rows[3].Role == "DPS",
    "numeric Blizzard roles should normalize"
)

assignedRoles.party1 = -1
rows, scanError = roster.ScanAssignedRoles()
assert(
    rows and not scanError and #rows == 2 and rows[1].Role == "HEALER" and rows[2].Role == "DPS",
    "the Classic no-role enum should be skipped"
)

assignedRoles.party1 = 99
rows, scanError = roster.ScanAssignedRoles()
assert(rows == nil and scanError == "unsupported-role-value", "an unknown enum should not return a partial role roster")

assignedRoles.party1 = "ERROR"
rows, scanError = roster.ScanAssignedRoles()
assert(rows == nil and scanError == "role-api-failed", "a failed role query should not return a partial role roster")

members[1].unit = nil
rows, scanError = roster.ScanAssignedRoles()
assert(rows == nil and scanError == "invalid-roster-unit", "a member without a unit token should fail safely")

print("Assigned role roster tests passed.")
