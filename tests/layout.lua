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

-- Auto-fill rules: class counts, subgroup references, and fill dedupe.
present = {}
classMembers = { MAGE = { "Mage1-Realm", "Mage2-Realm", "Mage3-Realm" } }
local subgroups = { [2] = { "GroupTwoA-Realm", "GroupTwoB-Realm" } }
providers.SubgroupMembers = function(n)
    return subgroups[n] or {}
end

local counted = layout.Resolve(layout.Parse("G: *MAGE x2"), providers)
assert(#counted.groups[1].members == 2, "a class count fills up to N members")
assert(
    counted.groups[1].members[1] == "Mage1-Realm" and counted.groups[1].members[2] == "Mage2-Realm",
    "the count takes successive class members"
)

local ref = layout.Resolve(layout.Parse("Resist: group:2"), providers)
assert(
    #ref.groups[1].members == 2 and ref.groups[1].members[1] == "GroupTwoA-Realm",
    "group:N references the live subgroup members"
)

-- A class fill skips an already-placed explicit name; explicit listings still honor the user.
classMembers = { MAGE = { "Dup-Realm", "Mage2-Realm" } }
local dedup = layout.Resolve(layout.Parse("G1: Dup-Realm, *MAGE; G2: Dup-Realm"), providers)
assert(#dedup.groups[1].members == 2, "explicit name plus one distinct class fill")
assert(dedup.groups[1].members[1] == "Dup-Realm", "the explicit name is placed")
assert(dedup.groups[1].members[2] == "Mage2-Realm", "the class fill skips the already-placed member")
assert(
    #dedup.groups[2].members == 1 and dedup.groups[2].members[1] == "Dup-Realm",
    "an explicit name may still be listed again by choice"
)

-- Vars source round-trip: extract, upsert (replace, append, preserve, remove).
assert(layout.ExtractSource("MT=Vn\n$LAYOUT=G1: A, B\nOT=Zed") == "G1: A, B", "extracts the layout line")
assert(layout.ExtractSource("MT=Vn") == nil, "no layout line yields nil")

local replaced = layout.UpsertSource("MT=Vn\n$LAYOUT=old\nOT=Zed", "G1: A")
assert(replaced == "MT=Vn\n$LAYOUT=G1: A\nOT=Zed", "upsert replaces in place and preserves other vars")

local appended = layout.UpsertSource("MT=Vn", "G1: A")
assert(appended == "MT=Vn\n$LAYOUT=G1: A", "upsert appends when absent")

local removed = layout.UpsertSource("MT=Vn\n$LAYOUT=old\nOT=Zed", "")
assert(removed == "MT=Vn\nOT=Zed", "an empty source removes the layout line")

assert(
    layout.ExtractSource(layout.UpsertSource("", "G1: A, B; G2: C")) == "G1: A, B; G2: C",
    "extract round-trips upsert"
)

-- DescribeSlot classifies each slot expression the editor can drag.
assert(layout.DescribeSlot("Vhez").kind == "name", "a bare name is a name slot")
local priority = layout.DescribeSlot("Main > Backup")
assert(priority.kind == "priority" and priority.name == "Main", "a priority list reports its primary")
local fill = layout.DescribeSlot("*mage x2")
assert(fill.kind == "class" and fill.class == "MAGE" and fill.count == 2, "a counted class fill is normalized")
assert(layout.DescribeSlot("*MAGE").count == 1, "an uncounted class fill takes one member")
assert(layout.DescribeSlot("group:2").subgroup == 2, "a subgroup reference reports its subgroup")
assert(layout.DescribeSlot("  ").label == "", "an empty slot describes as an empty name")

-- SlotWeight charges a slot for every raid seat it can consume.
assert(layout.SlotWeight("Vhez") == 1 and layout.SlotWeight("A > B") == 1, "names and priorities weigh one")
assert(layout.SlotWeight("*MAGE x3") == 3, "a counted class fill weighs its count")
assert(layout.SlotWeight("group:2") == layout.MAX_SUBGROUP_SLOTS, "a subgroup reference weighs a full subgroup")
assert(layout.GroupWeight({ slots = { "Vhez", "*MAGE x2" } }) == 3, "group weight sums its slots")

-- Serialize round-trips Parse and repairs unlabeled or unsafe groups.
local source = "Group 1/1: Vhez, Main > Backup, *MAGE; Spores: L1, L2"
assert(layout.Serialize(layout.Parse(source)) == source, "serialize round-trips parse")
assert(layout.Serialize({ groups = {} }) == "", "an empty model serializes to an empty source")
assert(layout.Serialize({ groups = { { slots = { "A" } } } }) == "Group 1: A", "an unlabeled group is numbered")
assert(layout.Serialize({ groups = { { name = "A:B", slots = { "x" } } } }) == "A B: x", "a label cannot break syntax")

-- Compact drops the empty boxes a drag-out leaves behind.
local compacted = layout.Compact(layout.Parse("Keep: A; Empty: ; Also: B"))
assert(#compacted.groups == 2, "empty groups are dropped")
assert(compacted.groups[2].name == "Also", "remaining groups keep their order")

-- GridView splits bound subgroup boxes from free-form groups.
local view = layout.GridView(layout.Parse("Main/1: A; Spores: B; Dup/1: C; Resist/4: D"))
assert(view.subgroups[1] == 1 and view.subgroups[4] == 4, "bound groups claim their subgroup box")
assert(view.subgroups[2] == nil, "an unclaimed subgroup box is empty")
assert(#view.free == 2 and view.free[1] == 2 and view.free[2] == 3, "unbound and duplicate bindings stay visible")

-- Group mutators are pure and report why they refuse.
local base = layout.Parse("Main/1: A; Spores: B")
local ok, added = layout.AddGroup(base, nil, 3)
assert(ok and #added.groups == 3 and added.groups[3].name == "Group 3", "a bound group is named for its subgroup")
assert(#base.groups == 2, "the input model is left untouched")
assert(select(2, layout.AddGroup(base, "X", 9)) == "unknown-subgroup", "a subgroup outside 1-8 is refused")

assert(#select(2, layout.RemoveGroup(base, 1)).groups == 1, "a group is removed by index")
assert(select(2, layout.RemoveGroup(base, 7)) == "unknown-group", "removing a missing group is refused")

assert(select(2, layout.SetGroupName(base, 2, "Fire:Resist")).groups[2].name == "Fire Resist", "a rename is cleaned")
assert(select(2, layout.SetGroupName(base, 2, "  ")) == "empty-name", "a blank rename is refused")

assert(select(2, layout.SetGroupSubgroup(base, 2, 1)) == "subgroup-taken", "two groups cannot share a subgroup")
assert(select(2, layout.SetGroupSubgroup(base, 2, 2)).groups[2].subgroup == 2, "a free group binds to a subgroup")
assert(select(2, layout.SetGroupSubgroup(base, 1, nil)).groups[1].subgroup == nil, "a bound group can unbind")
local wide = layout.Parse("Bench: A, B, C, D, E, F")
assert(select(2, layout.SetGroupSubgroup(wide, 1, 2)) == "group-full", "an oversized group cannot bind to a subgroup")

-- ApplyDrop: moving a slot between groups appends to the destination.
local roster = layout.Parse("Main/1: A, B; Spores: C")
local moved
ok, moved = layout.ApplyDrop(roster, { kind = "slot", group = 1, slot = 1 }, { kind = "group", group = 2 })
assert(ok and table.concat(moved.groups[1].slots, ",") == "B", "the slot leaves its source group")
assert(table.concat(moved.groups[2].slots, ",") == "C,A", "the slot appends to the destination group")
assert(table.concat(roster.groups[1].slots, ",") == "A,B", "a successful drop does not mutate the input")

-- ApplyDrop: a palette entry inserts before the slot it lands on.
ok, moved = layout.ApplyDrop(roster, { kind = "text", text = "Vhez" }, { kind = "slot", group = 1, slot = 2 })
assert(ok and table.concat(moved.groups[1].slots, ",") == "A,Vhez,B", "a palette drop inserts at the target slot")
assert(
    select(2, layout.ApplyDrop(roster, { kind = "text", text = "Bad;Name" }, { kind = "group", group = 2 })).groups[2].slots[2]
        == "Bad Name",
    "a dropped slot cannot break syntax"
)

-- ApplyDrop: reordering inside one group accounts for the slot leaving first.
local ordered = layout.Parse("G: A, B, C")
ok, moved = layout.ApplyDrop(ordered, { kind = "slot", group = 1, slot = 1 }, { kind = "slot", group = 1, slot = 3 })
assert(ok and table.concat(moved.groups[1].slots, ",") == "B,A,C", "a forward reorder lands before the target")
ok, moved = layout.ApplyDrop(ordered, { kind = "slot", group = 1, slot = 3 }, { kind = "slot", group = 1, slot = 1 })
assert(ok and table.concat(moved.groups[1].slots, ",") == "C,A,B", "a backward reorder lands before the target")

-- ApplyDrop: dropping onto an occupant of a full subgroup trades the two.
local full = layout.Parse("Main/1: A, B, C, D, E; Bench: Z")
ok, moved = layout.ApplyDrop(full, { kind = "slot", group = 2, slot = 1 }, { kind = "slot", group = 1, slot = 2 })
assert(ok and table.concat(moved.groups[1].slots, ",") == "A,Z,C,D,E", "the dragged slot takes the occupant's place")
assert(table.concat(moved.groups[2].slots, ",") == "B", "the occupant takes the dragged slot's place")

-- ApplyDrop: a subgroup box with no group yet creates one on the first drop.
ok, moved = layout.ApplyDrop({ groups = {} }, { kind = "text", text = "Vhez" }, { kind = "subgroup", subgroup = 3 })
assert(ok and #moved.groups == 1, "dropping into an empty subgroup box creates its group")
assert(moved.groups[1].subgroup == 3 and moved.groups[1].name == "Group 3", "the created group is bound and named")
assert(moved.groups[1].slots[1] == "Vhez", "the dropped slot lands in the created group")

-- ApplyDrop: dropping a slot outside the editor removes it.
ok, moved = layout.ApplyDrop(full, { kind = "slot", group = 1, slot = 5 }, { kind = "remove" })
assert(ok and table.concat(moved.groups[1].slots, ",") == "A,B,C,D", "a slot dropped away is removed")
local removeText = select(2, layout.ApplyDrop(full, { kind = "text", text = "X" }, { kind = "remove" }))
assert(removeText == "unknown-drop", "a palette entry cannot be removed")

-- ApplyDrop: subgroup capacity counts slot weight, not slot count.
local four = layout.Parse("Main/1: A, B, C, D")
local one = select(2, layout.ApplyDrop(four, { kind = "text", text = "*MAGE" }, { kind = "group", group = 1 }))
assert(one.groups[1].slots[5] == "*MAGE", "a single-seat fill takes the last free seat")
local two = select(2, layout.ApplyDrop(four, { kind = "text", text = "*MAGE x2" }, { kind = "group", group = 1 }))
assert(two == "group-full", "a two-seat fill does not fit one free seat")
local spare =
    select(2, layout.ApplyDrop(four, { kind = "text", text = "*MAGE x2" }, { kind = "subgroup", subgroup = 5 }))
assert(spare.groups[2].slots[1] == "*MAGE x2", "the same fill fits an empty subgroup")

-- ApplyDrop: malformed gestures are refused without touching the model.
local refusedDropCases = {
    {
        Name = "a missing drag is refused",
        Drop = { kind = "remove" },
        Error = "unknown-drag",
    },
    {
        Name = "an unknown drag kind is refused",
        Drag = { kind = "wat" },
        Drop = { kind = "remove" },
        Error = "unknown-drag",
    },
    {
        Name = "an empty palette entry is refused",
        Drag = { kind = "text", text = " " },
        Drop = { kind = "group", group = 1 },
        Error = "empty-slot",
    },
    {
        Name = "dragging a missing slot is refused",
        Drag = { kind = "slot", group = 1, slot = 9 },
        Drop = { kind = "group", group = 1 },
        Error = "unknown-slot",
    },
    {
        Name = "dropping on a missing group is refused",
        Drag = { kind = "text", text = "X" },
        Drop = { kind = "group", group = 9 },
        Error = "unknown-group",
    },
    {
        Name = "dropping on a subgroup outside 1-8 is refused",
        Drag = { kind = "text", text = "X" },
        Drop = { kind = "subgroup", subgroup = 0 },
        Error = "unknown-subgroup",
    },
}

for _, case in ipairs(refusedDropCases) do
    local refused, reason = layout.ApplyDrop(four, case.Drag, case.Drop)
    assert(refused == false and reason == case.Error, case.Name)
end
assert(#four.groups == 1 and #four.groups[1].slots == 4, "refused drops leave the model untouched")

print("Layout tests passed.")
