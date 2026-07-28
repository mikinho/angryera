local AngryEra = { utils = {} }
local app = { AngryEra = AngryEra }

assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/layout.lua"))("AngryEra", app)
local layout = AngryEra.utils.layout
local json = AngryEra.utils.json

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
local model = layout.Parse("Group 1/1: Vhez, Main > Backup, *MAGE; Spores/2: Lock1, Lock2")
assert(#model.groups == 2, "two groups parsed")
assert(model.groups[1].name == "Group 1" and model.groups[1].subgroup == 1, "label and subgroup binding")
assert(#model.groups[1].slots == 3 and model.groups[1].slots[3] == "*MAGE", "slots parsed in order")
assert(model.groups[2].name == "Spores" and model.groups[2].subgroup == 2, "a named group keeps its own label")

-- Parse: newlines separate groups; missing colon and empty input are ignored.
assert(#layout.Parse("A: x\nB: y").groups == 2, "newlines separate groups")
assert(#layout.Parse("").groups == 0, "empty input yields no groups")
assert(#layout.Parse("no colon here").groups == 0, "a line without a colon is skipped")

-- Parse seats every group in a raid subgroup, so a layout is the raid itself:
-- an explicit /N is honored first, then whatever is left takes the lowest free.
local seated = layout.Parse("Spores: A; Main/1: B; Dup/1: C")
assert(seated.groups[2].subgroup == 1, "an explicit binding is honored")
assert(seated.groups[1].subgroup == 2, "a group written without one takes the lowest free subgroup")
assert(seated.groups[3].subgroup == 3, "a group asking for a taken subgroup falls to the next free one")
assert(layout.Parse("Spores: A").groups[1].name == "Spores", "seating leaves a written name alone")
assert(layout.Parse("/3: A").groups[1].name == "Group 3", "a group left unnamed is named for its subgroup")

-- Parse: the raid is the limit, so groups past the eighth and slots past the
-- fifth of a subgroup are dropped rather than kept as an unusable arrangement.
local nine = {}
for index = 1, 9 do
    nine[index] = "G" .. index .. ": x"
end
assert(#layout.Parse(table.concat(nine, "; ")).groups == 8, "a ninth group has no raid subgroup to hold it")
assert(#layout.Parse("G: A, B, C, D, E, F").groups[1].slots == 5, "a sixth slot does not fit a subgroup")
assert(#layout.Parse("G: A, B, C, D, *MAGE x2").groups[1].slots == 4, "a fill that overruns the subgroup is dropped")

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
assert(#dedup.duplicates == 1, "an explicit duplicate is reported for destructive callers")

-- Short and full spellings of the same roster member share one identity. A fill
-- skips the already-listed member, while an explicit duplicate remains visible
-- and is reported so Apply to Raid can fail before moving anyone.
local canonicalProviders = {
    ClassMembers = function()
        return { "Zed-Realm", "Mage-Realm" }
    end,
    ResolveRosterName = function(name)
        if name == "Zed" or name == "Zed-Realm" then
            return "Zed-Realm"
        end
        return name
    end,
}
local canonicalFill = layout.Resolve(layout.Parse("G: Zed, *MAGE"), canonicalProviders)
assert(
    #canonicalFill.groups[1].members == 2 and canonicalFill.groups[1].members[2] == "Mage-Realm",
    "a class fill dedupes short and full spellings canonically"
)
local canonicalDuplicate = layout.Resolve(layout.Parse("G1: Zed; G2: Zed-Realm"), canonicalProviders)
assert(#canonicalDuplicate.groups[1].members == 1, "the first canonical spelling remains rendered")
assert(#canonicalDuplicate.groups[2].members == 1, "an explicit duplicate remains rendered")
assert(#canonicalDuplicate.duplicates == 1, "a short/full explicit duplicate is reported canonically")

-- A slot may hold a {{Variable}}, which is classified after it expands so the
-- variable can stand in for a name, a priority list, or a class fill.
present = { backup = true }
classMembers = { MAGE = { "Mage1-Realm", "Mage2-Realm" } }
providers.Variables = {
    MT = "Vhez",
    Healers = "*MAGE x2",
    Backup = "Missing > Backup",
    Count = 2,
}

local named = layout.Resolve(layout.Parse("G: {{MT}}"), providers)
assert(named.groups[1].members[1] == "Vhez", "a variable slot resolves to the name it holds")

local viaFill = layout.Resolve(layout.Parse("G: {{Healers}}"), providers)
assert(#viaFill.groups[1].members == 2, "a variable holding a class fill fills like one")

local viaPriority = layout.Resolve(layout.Parse("G: {{ Backup }}"), providers)
assert(viaPriority.groups[1].members[1] == "Backup", "a variable holding a priority list resolves through it")

local mixed = layout.Resolve(layout.Parse("G: *MAGE x{{Count}}"), providers)
assert(#mixed.groups[1].members == 2, "a variable substitutes inside a larger expression")

local unset = layout.Resolve(layout.Parse("G: {{Nobody}}, Vhez"), providers)
assert(
    #unset.groups[1].members == 1 and unset.groups[1].members[1] == "Vhez",
    "an unset variable drops its slot rather than naming a missing player"
)

providers.Variables.Fill = "*MAGE x5"
local expandedOverCapacity = layout.Resolve(layout.Parse("G: A, B, C, D, {{Fill}}"), providers)
assert(
    expandedOverCapacity.error == "subgroup-oversubscribed",
    "capacity is enforced after a variable expands to a multi-member fill"
)
assert(#expandedOverCapacity.groups[1].members == 4, "an expanded slot that exceeds capacity is not admitted")

assert(layout.ExpandSlotVariables("{{MT}}", nil) == "", "no variable map leaves nothing to place")
assert(layout.ExpandSlotVariables("Vhez", providers.Variables) == "Vhez", "a slot without a token is untouched")
providers.Variables = nil

local booleanNameVariables = json.ParseVariables("LOWER=true\nTITLE=True\nENABLED=$true")
assert(
    layout.ExpandSlotVariables("{{LOWER}}", booleanNameVariables) == "true"
        and layout.ExpandSlotVariables("{{TITLE}}", booleanNameVariables) == "True",
    "boolean-looking player names should remain usable layout slots"
)
assert(
    layout.ExpandSlotVariables("{{ENABLED}}", booleanNameVariables) == "",
    "a typed boolean should not become a player slot"
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
local explicitEmpty = layout.UpsertSource("MT=Vn\n$LAYOUT=old\nOT=Zed", "", true)
assert(
    explicitEmpty == "MT=Vn\n$LAYOUT=\nOT=Zed" and layout.ExtractSource(explicitEmpty) == "",
    "an explicit empty override remains distinguishable from inheritance"
)

assert(
    layout.ExtractSource(layout.UpsertSource("", "G1: A, B; G2: C")) == "G1: A, B; G2: C",
    "extract round-trips upsert"
)

-- JSON-object Vars stay JSON; mixed-case layout keys are read, replaced, and
-- removed without losing nested or non-string values.
local jsonVars = "{\"Count\":2,\"Nested\":{\"Enabled\":true},\"$Layout\":\"old\"}"
assert(layout.ExtractSource(jsonVars) == "old", "extract reads a mixed-case layout key from JSON Vars")

local jsonReplaced = layout.UpsertSource(jsonVars, "G1: A")
assert(jsonReplaced:match("^%s*{"), "upsert preserves JSON-object storage")
local decodedReplaced = json.JSON_TryDecode(jsonReplaced)
assert(decodedReplaced.Count == 2 and decodedReplaced.Nested.Enabled == true, "JSON upsert preserves other values")
assert(decodedReplaced["$LAYOUT"] == "G1: A", "JSON upsert writes the canonical layout key")
assert(decodedReplaced["$Layout"] == nil, "JSON upsert removes mixed-case duplicate keys")

local jsonAppended = layout.UpsertSource("{\"MT\":\"Vn\"}", "G1: A")
assert(json.JSON_TryDecode(jsonAppended)["$LAYOUT"] == "G1: A", "JSON upsert adds a missing layout key")

local jsonRemoved = layout.UpsertSource(jsonVars, "")
local decodedRemoved = json.JSON_TryDecode(jsonRemoved)
assert(decodedRemoved["$Layout"] == nil and decodedRemoved["$LAYOUT"] == nil, "JSON removal is case-insensitive")
assert(decodedRemoved.Count == 2 and decodedRemoved.Nested.Enabled == true, "JSON removal preserves other values")
local jsonExplicitEmpty = json.JSON_TryDecode(layout.UpsertSource(jsonVars, "", true))
assert(jsonExplicitEmpty["$LAYOUT"] == "", "JSON can retain an explicit empty local layout override")
assert(layout.UpsertSource("{\"$layout\":\"old\"}", "") == "{}", "removing the only JSON key preserves an object")
local malformedSource, malformedError = layout.ExtractSource("{")
assert(malformedSource == nil and malformedError == "invalid-variables", "malformed JSON Vars fail extraction")
local malformedUpsert, malformedUpsertError = layout.UpsertSource("{", "G1: A")
assert(malformedUpsert == nil and malformedUpsertError == "invalid-variables", "malformed JSON Vars fail upsert")
local arrayUpsert, arrayUpsertError = layout.UpsertSource("[]", "G1: A")
assert(arrayUpsert == nil and arrayUpsertError == "invalid-variables", "JSON-array Vars never become mixed formats")

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
assert(
    layout.ExpandedSlotWeight("{{Fill}}", { Fill = "*MAGE x3" }) == 3,
    "editor capacity follows a variable's expanded fill"
)
assert(layout.ExpandedSlotWeight("{{Unset}}", {}) == 1, "an unresolved expression still occupies one editable row")
assert(
    layout.GroupWeight({ slots = { "{{Fill}}", "Vhez" } }, { Fill = "*MAGE x3" }) == 4,
    "group capacity can count effective variable expressions"
)
local capacityValid, capacityError, capacityGroup =
    layout.ValidateCapacity(layout.Parse("Main/1: A, B, C, D, {{Fill}}"), { Fill = "*MAGE x2" })
assert(
    capacityValid == false and capacityError == "subgroup-oversubscribed" and capacityGroup == 1,
    "model validation rejects a variable-expanded subgroup before save"
)
assert(
    layout.ValidateCapacity(layout.Parse("Main/1: A, B, C, {{Fill}}"), { Fill = "*MAGE x2" }) == true,
    "model validation accepts a variable-expanded subgroup that fits"
)

-- Serialize round-trips Parse and repairs unlabeled or unsafe groups.
local source = "Group 1/1: Vhez, Main > Backup, *MAGE; Spores/2: L1, L2"
assert(layout.Serialize(layout.Parse(source)) == source, "serialize round-trips parse")
assert(layout.Serialize({ groups = {} }) == "", "an empty model serializes to an empty source")
assert(layout.Serialize({ groups = { { slots = { "A" } } } }) == "Group 1/1: A", "an unseated group takes its position")
assert(
    layout.Serialize({ groups = { { name = "A:B", slots = { "x" } } } }) == "A B/1: x",
    "a label cannot break syntax"
)

-- Compact drops the empty boxes a drag-out leaves behind, but a box named
-- before anyone was dragged into it is the whole point of naming one.
local compacted = layout.Compact(layout.Parse("Keep/1: A; Group 2/2: ; Also/3: B"))
assert(#compacted.groups == 2, "an unnamed empty group is dropped")
assert(compacted.groups[2].name == "Also", "remaining groups keep their order")
assert(#layout.Compact(layout.Parse("Keep/1: A; Spores/2: ")).groups == 2, "a named empty group is kept")

-- GridView reports which group holds each of the eight raid subgroups.
local view = layout.GridView(layout.Parse("Main/1: A; Resist/4: D"))
assert(view.subgroups[1] == 1 and view.subgroups[4] == 2, "each group is found by the subgroup it holds")
assert(view.subgroups[2] == nil, "a subgroup no group holds is empty")

-- Group mutators are pure and report why they refuse.
local base = layout.Parse("Main/1: A; Spores/2: B")
local ok, added = layout.AddGroup(base, nil, 3)
assert(ok and #added.groups == 3 and added.groups[3].name == "Group 3", "a group is named for its subgroup")
assert(#base.groups == 2, "the input model is left untouched")
assert(select(2, layout.AddGroup(base, "X", 9)) == "unknown-subgroup", "a subgroup outside 1-8 is refused")
assert(select(2, layout.AddGroup(base, "X", 1)) == "subgroup-taken", "a subgroup another group holds is refused")
assert(select(2, layout.AddGroup(base, "X")).groups[3].subgroup == 3, "an unasked group takes the lowest free subgroup")
local packedRaid = layout.Parse("A/1: x; B/2: x; C/3: x; D/4: x; E/5: x; F/6: x; G/7: x; H/8: x")
assert(select(2, layout.AddGroup(packedRaid, "Ninth")) == "group-limit", "a ninth group has nowhere to sit")

assert(#select(2, layout.RemoveGroup(base, 1)).groups == 1, "a group is removed by index")
assert(select(2, layout.RemoveGroup(base, 7)) == "unknown-group", "removing a missing group is refused")

assert(select(2, layout.SetGroupName(base, 2, "Fire:Resist")).groups[2].name == "Fire Resist", "a rename is cleaned")
assert(select(2, layout.SetGroupName(base, 2, "  ")) == "empty-name", "a blank rename is refused")

assert(select(2, layout.SetGroupSubgroup(base, 2, 1)) == "subgroup-taken", "two groups cannot share a subgroup")
assert(select(2, layout.SetGroupSubgroup(base, 2, 5)).groups[2].subgroup == 5, "a group moves to a free subgroup")
assert(select(2, layout.SetGroupSubgroup(base, 2, nil)) == "unknown-subgroup", "a group cannot leave the raid")
assert(select(2, layout.SetGroupSubgroup(base, 9, 5)) == "unknown-group", "moving a missing group is refused")

-- SetSlot retypes one slot under the same capacity rules a drop obeys.
assert(select(2, layout.SetSlot(base, 1, 1, " C:D ")).groups[1].slots[1] == "C:D", "a typed slot is trimmed")
assert(base.groups[1].slots[1] == "A", "the input model is left untouched")
assert(select(2, layout.SetSlot(base, 9, 1, "C")) == "unknown-group", "typing into a missing group is refused")
assert(select(2, layout.SetSlot(base, 1, 4, "C")) == "unknown-slot", "typing into a missing slot is refused")
assert(select(2, layout.SetSlot(base, 1, 1, "  ")) == "empty-slot", "a blank slot is refused")
local packed = layout.Parse("Main/1: A, B, C, D, E")
assert(select(2, layout.SetSlot(packed, 1, 1, "*MAGE x2")) == "group-full", "a retype cannot exceed the subgroup cap")
assert(select(2, layout.SetSlot(packed, 1, 1, "*MAGE")).groups[1].slots[1] == "*MAGE", "a same-weight retype fits")
assert(
    select(2, layout.SetSlot(packed, 1, 1, "{{Fill}}", { Fill = "*MAGE x2" })) == "group-full",
    "a variable cannot hide an oversized typed fill"
)

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
local twoSeatDrop =
    select(2, layout.ApplyDrop(four, { kind = "text", text = "*MAGE x2" }, { kind = "group", group = 1 }))
assert(twoSeatDrop == "group-full", "a two-seat fill does not fit one free seat")
local spare =
    select(2, layout.ApplyDrop(four, { kind = "text", text = "*MAGE x2" }, { kind = "subgroup", subgroup = 5 }))
assert(spare.groups[2].slots[1] == "*MAGE x2", "the same fill fits an empty subgroup")
local variableFillDrop = select(
    2,
    layout.ApplyDrop(four, { kind = "text", text = "{{Fill}}" }, { kind = "group", group = 1 }, { Fill = "*MAGE x2" })
)
assert(variableFillDrop == "group-full", "a dragged variable cannot hide an oversized fill")

-- Duplicate guards apply to both typed slots and palette drops. They distinguish
-- variable identity from the member it resolves to, and use roster identity so
-- a short and realm-qualified spelling cannot occupy two seats.
local assignmentVariables = {
    MT = "Vhez",
    MAIN_TANK = "Vhez-Realm",
    Open = "{{MISSING}}",
    OtherOpen = "{{OTHER_MISSING}}",
    Mage = "*MAGE",
    Count = 2,
}
local assignmentProviders = {
    Variables = assignmentVariables,
    ResolveRosterName = function(name)
        if name == "Vhez" or name == "Vhez-Realm" then
            return "Vhez-Realm"
        end
        return name
    end,
    ClassMembers = function(class)
        return class == "MAGE" and { "Vhez", "Kaza" } or {}
    end,
}
local assigned = layout.Parse("Main/1: {{MT}}; Bench/2: Backup")
assert(
    select(
        2,
        layout.ApplyDrop(
            assigned,
            { kind = "text", text = "{{MT}}" },
            { kind = "group", group = 2 },
            assignmentVariables,
            assignmentProviders
        )
    ) == "duplicate-slot",
    "the same whole-slot variable cannot be dropped twice"
)
assert(
    select(
        2,
        layout.ApplyDrop(
            assigned,
            { kind = "text", text = "{{MAIN_TANK}}" },
            { kind = "group", group = 2 },
            assignmentVariables,
            assignmentProviders
        )
    ) == "duplicate-slot",
    "a different variable resolving to the same member cannot be dropped"
)
assert(
    select(
        2,
        layout.ApplyDrop(
            assigned,
            { kind = "text", text = "Vhez-Realm" },
            { kind = "group", group = 2 },
            assignmentVariables,
            assignmentProviders
        )
    ) == "duplicate-slot",
    "short and realm-qualified spellings share one assignment identity"
)
assert(
    select(
        2,
        layout.SetSlot(
            layout.Parse("Main/1: {{MT}}, Backup"),
            1,
            2,
            "{{MAIN_TANK}}",
            assignmentVariables,
            assignmentProviders
        )
    ) == "duplicate-slot",
    "typing an alias for an assigned member is also refused"
)

local aliasRetypeOk, aliasRetype =
    layout.SetSlot(layout.Parse("Main/1: {{MT}}"), 1, 1, "{{MAIN_TANK}}", assignmentVariables, assignmentProviders)
assert(
    aliasRetypeOk and aliasRetype.groups[1].slots[1] == "{{MAIN_TANK}}",
    "replacing one assignment with an alias for the same member remains valid"
)

local unresolved = layout.Parse("Main/1: {{Open}}")
assert(
    select(
        2,
        layout.ApplyDrop(
            unresolved,
            { kind = "text", text = "{{Open}}" },
            { kind = "group", group = 1 },
            assignmentVariables,
            assignmentProviders
        )
    ) == "duplicate-slot",
    "the same unresolved whole-slot variable still cannot be repeated"
)
local distinctUnresolvedOk, distinctUnresolved = layout.ApplyDrop(
    unresolved,
    { kind = "text", text = "{{OtherOpen}}" },
    { kind = "group", group = 1 },
    assignmentVariables,
    assignmentProviders
)
assert(
    distinctUnresolvedOk and distinctUnresolved.groups[1].slots[2] == "{{OtherOpen}}",
    "different unresolved variables are not guessed to share a target"
)

local classAssignmentOk, classAssignment = layout.ApplyDrop(
    layout.Parse("Main/1: Vhez"),
    { kind = "text", text = "{{Mage}}" },
    { kind = "group", group = 1 },
    assignmentVariables,
    assignmentProviders
)
assert(
    classAssignmentOk and classAssignment.groups[1].slots[2] == "{{Mage}}",
    "a class variable remains valid when its fill selects a different member"
)
local parameterReuse = layout.Parse("Main/1: *MAGE x{{Count}}; Bench/2: *PRIEST x{{Count}}")
assert(
    layout.ValidateDuplicateProgress({ groups = {} }, parameterReuse, assignmentVariables, assignmentProviders),
    "a variable used as an embedded count is not a duplicated player assignment"
)
local embeddedReuse = layout.Parse("Main/1: Missing > {{MT}}; Bench/2: {{MT}}")
assert(
    select(2, layout.ValidateUniqueAssignments(embeddedReuse, assignmentVariables, assignmentProviders))
        == "duplicate-slot",
    "a string player variable cannot be reused inside another slot expression"
)

-- Legacy duplicates remain movable and removable so the editor can repair them,
-- but no edit may increase one or trade it for a different duplicate identity.
local legacyDuplicates = layout.Parse("Main/1: {{MT}}, {{MT}}; Bench/2: Backup")
assert(
    select(2, layout.ValidateUniqueAssignments(legacyDuplicates, assignmentVariables, assignmentProviders))
        == "duplicate-slot",
    "strict save validation rejects every remaining legacy duplicate"
)
local legacyMovedOk, legacyMoved = layout.ApplyDrop(
    legacyDuplicates,
    { kind = "slot", group = 1, slot = 2 },
    { kind = "group", group = 2 },
    assignmentVariables,
    assignmentProviders
)
assert(
    legacyMovedOk and legacyMoved.groups[2].slots[2] == "{{MT}}",
    "a pre-existing duplicate can be moved without worsening it"
)
assert(
    select(
        2,
        layout.ApplyDrop(
            legacyDuplicates,
            { kind = "text", text = "{{MT}}" },
            { kind = "group", group = 2 },
            assignmentVariables,
            assignmentProviders
        )
    ) == "duplicate-slot",
    "a pre-existing duplicate cannot gain another copy"
)
local legacyCleanedOk, legacyCleaned = layout.ApplyDrop(
    legacyDuplicates,
    { kind = "slot", group = 1, slot = 2 },
    { kind = "remove" },
    assignmentVariables,
    assignmentProviders
)
assert(legacyCleanedOk and #legacyCleaned.groups[1].slots == 1, "a pre-existing duplicate can be removed")
assert(
    select(2, layout.SetSlot(legacyDuplicates, 1, 2, "Backup", assignmentVariables, assignmentProviders))
        == "duplicate-slot",
    "removing one conflict cannot introduce a different duplicate member"
)

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
