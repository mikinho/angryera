local app = { AngryEra = { utils = {} } }
assert(loadfile("modules/utils/helpers.lua"))("AngryEra", app)

local compare = app.AngryEra.utils.helpers.CompareIndexedEntries

local pages = {
    { Name = "Unindexed A" },
    { Name = "Indexed B", Index = 2 },
    { Name = "Indexed A", Index = 1 },
    { Name = "Unindexed B" },
}
table.sort(pages, compare)
assert(pages[1].Name == "Indexed A")
assert(pages[2].Name == "Indexed B")
assert(pages[3].Name == "Unindexed A")
assert(pages[4].Name == "Unindexed B")

local equalIndexes = {
    { Name = "Zulu", Index = 1 },
    { Name = "Alpha", Index = 1 },
}
table.sort(equalIndexes, compare)
assert(equalIndexes[1].Name == "Alpha")
assert(equalIndexes[2].Name == "Zulu")

-- Classic can temporarily leave holes in raid indices while subgroup changes
-- are acknowledged. Group iteration must still find members beyond the
-- reported member count instead of treating them as absent.
local sparseRoster = {
    [1] = { Name = "Leader-Realm", Rank = 2 },
    [3] = { Name = "Player-Realm", Rank = 1 },
}
_G.IsInRaid = function()
    return true
end
_G.GetNumGroupMembers = function()
    return 2
end
_G.GetRaidRosterInfo = function(index)
    local member = sparseRoster[index]
    if member then
        return member.Name, member.Rank, 1, 60, "Warrior", "WARRIOR", "", true, false
    end
end
_G.UnitFullName = function()
    return "Player", "Realm"
end
local iterated = {}
app.AngryEra.utils.helpers.IterateGroupMembers(function(_, fullName)
    iterated[#iterated + 1] = fullName
end)
assert(#iterated == 2 and iterated[2] == "Player-Realm", "raid iteration should scan past transient index holes")

print("Ordering regression tests passed.")
