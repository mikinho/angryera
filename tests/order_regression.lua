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

print("Ordering regression tests passed.")
