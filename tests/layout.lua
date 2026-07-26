local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

assert(loadfile("modules/layout.lua"))("AngryEra", app)
local layout = AngryEra.utils.layout

-- Stubbed roster providers.
local present = {}
local classMembers = {}
local providers = {
    ResolvePriorityValue = function(value)
        for token in value:gmatch("[^>]+") do
            local name = token:match("^%s*(.-)%s*$")
            if present[name:lower()] then
                return name, true
            end
        end
        local first = value:match("^%s*(.-)%s*>") or value
        return first:match("^%s*(.-)%s*$"), true
    end,
    ClassMembers = function(class)
        return classMembers[class] or {}
    end,
    Colorize = function(name)
        return "[" .. name .. "]"
    end,
}

-- Parse: compact multi-group, subgroup binding, slot list.
local model = layout.Parse("Group 1/1: Vhez, Main > Backup, *MAGE; Spores: Lock1, Lock2")
assert(#model.groups == 2, "two groups parsed")
assert(model.groups[1].name == "Group 1" and model.groups[1].subgroup == 1, "label and subgroup binding")
assert(#model.groups[1].slots == 3 and model.groups[1].slots[3] == "*MAGE", "slots parsed in order")
assert(model.groups[2].name == "Spores" and model.groups[2].subgroup == nil, "unbound group has no subgroup")

-- Parse: newlines separate groups; missing colon and empty input are ignored.
assert(#layout.Parse("A: x\nB: y").groups == 2, "newlines separate groups")
assert(#layout.Parse("").groups == 0, "empty input yields no groups")
assert(#layout.Parse("no colon here").groups == 0, "a line without a colon is skipped")

-- Resolve: names pass through, priority resolves via provider, class fills and dedupes.
present = { backup = true }
classMembers = { MAGE = { "Mage1-Realm", "Mage2-Realm" } }
local resolved = layout.Resolve(layout.Parse("G1: Vhez, Main > Backup, *MAGE, *MAGE"), providers)
local m = resolved.groups[1].members
assert(#m == 4, "four slots resolve")
assert(m[1] == "Vhez", "a plain name passes through")
assert(m[2] == "Backup", "a priority list resolves to the present member")
assert(m[3] == "Mage1-Realm" and m[4] == "Mage2-Realm", "class fills take successive members without repeating")

-- Resolve: an exhausted class fill is skipped rather than repeated.
local few = layout.Resolve(layout.Parse("G: *MAGE, *MAGE, *MAGE"), providers)
assert(#few.groups[1].members == 2, "class fill stops when the class is exhausted")

-- RenderText colorizes and lays out one line per group.
assert(
    layout.RenderText({ groups = { { name = "G1", members = { "A", "B" } } } }, providers) == "G1: [A], [B]",
    "render colorizes members"
)

-- SelectGroups filters by name, case-insensitive.
local two = { groups = { { name = "Spores", members = { "L1" } }, { name = "Chains", members = { "C1" } } } }
assert(#layout.SelectGroups(two, "spores").groups == 1, "group selection is case-insensitive")

-- SourceFromVars locates $LAYOUT case-insensitively.
assert(layout.SourceFromVars({ ["$LAYOUT"] = "x" }) == "x", "exact key found")
assert(layout.SourceFromVars({ ["$Layout"] = "y" }) == "y", "mixed-case key found")
assert(layout.SourceFromVars({ MT = "z" }) == nil, "unrelated vars ignored")

-- Expand substitutes {layout} and {layout GroupName}.
present = {}
classMembers = {}
local out, expanded = layout.Expand("Groups:\n{layout}", "G1: A, B; G2: C", providers)
assert(expanded == true, "expansion reports it replaced a placeholder")
assert(out:find("G1: %[A%], %[B%]", 1) and out:find("G2: %[C%]", 1), "all groups render for a bare placeholder")

local single = layout.Expand("{layout G2}", "G1: A; G2: C", providers)
assert(single == "G2: [C]", "a named placeholder renders only that group")

local untouched, none = layout.Expand("no tag", "G1: A", providers)
assert(untouched == "no tag" and none == false, "text without a placeholder is unchanged")

print("Layout tests passed.")
