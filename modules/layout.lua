-- -------------------------------------------------------------------------------
-- Angry Era: modules/layout.lua
--
-- Raid group layouts. A page's `$LAYOUT` metadata describes named groups of
-- player slots (resist groups, spore rotations, chains, trash groups). Slots
-- resolve against the live roster and render as a `{layout}` grid in the note.
--
-- Compact syntax (stored as the `$LAYOUT` variable value):
--   Group 1/1: Vhez, Mage1 > Mage2, *MAGE; Spores: Lock1, Lock2, Lock3
-- Groups are separated by ";" or newlines; "Label/N" binds raid subgroup N;
-- slots are comma-separated and may be a name, a priority list "A > B", or a
-- class fill "*CLASS".
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.layout = {}
local layout = AngryEra.utils.layout

local MAX_GROUPS = 32
local MAX_SLOTS_PER_GROUP = 40
local MAX_SUBGROUPS = 8
local MAX_SUBGROUP_SLOTS = 5

layout.MAX_GROUPS = MAX_GROUPS
layout.MAX_SLOTS_PER_GROUP = MAX_SLOTS_PER_GROUP
layout.MAX_SUBGROUPS = MAX_SUBGROUPS
layout.MAX_SUBGROUP_SLOTS = MAX_SUBGROUP_SLOTS

local function Trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$")
end

--- Classifies one slot expression for display and capacity math.
-- @tparam string slot Slot expression.
-- @treturn table info `{ kind = "name"|"priority"|"class"|"subgroup", label, name?, class?, count?, subgroup? }`.
function layout.DescribeSlot(slot)
    local text = Trim(slot)
    if text == "" then
        return { kind = "name", label = "", name = "" }
    end

    local subgroup = text:match("^[Gg][Rr][Oo][Uu][Pp]%s*:%s*([1-8])$")
    if subgroup then
        return { kind = "subgroup", label = text, subgroup = tonumber(subgroup) }
    end

    local class, countText = text:match("^%*(%a+)%s+[xX]%s*(%d+)$")
    if not class then
        class = text:match("^%*(%a+)$")
    end
    if class then
        return { kind = "class", label = text, class = class:upper(), count = tonumber(countText) or 1 }
    end

    if text:find(">", 1, true) then
        return { kind = "priority", label = text, name = Trim(text:match("^([^>]+)") or text) }
    end

    return { kind = "name", label = text, name = text }
end

--- Returns how many raid slots a slot expression can consume.
-- @tparam string slot Slot expression.
-- @treturn number weight
function layout.SlotWeight(slot)
    local info = layout.DescribeSlot(slot)
    if info.kind == "class" then
        return info.count or 1
    end
    if info.kind == "subgroup" then
        return MAX_SUBGROUP_SLOTS
    end
    return 1
end

-- Sums slot weights for a group, optionally ignoring one slot index.
local function GroupWeight(group, skipIndex)
    local total = 0
    for index, slot in ipairs((type(group) == "table" and group.slots) or {}) do
        if index ~= skipIndex then
            total = total + layout.SlotWeight(slot)
        end
    end
    return total
end

--- Returns the total slot weight a group currently holds.
-- @tparam table group Group entry.
-- @treturn number weight
function layout.GroupWeight(group)
    return GroupWeight(group)
end

-- Subgroup-bound groups are capped by the five-per-subgroup raid limit.
local function GroupCapacity(group)
    if type(group) == "table" and group.subgroup then
        return MAX_SUBGROUP_SLOTS
    end
    return MAX_SLOTS_PER_GROUP
end

local function CanHold(group, addedWeight, skipIndex)
    return GroupWeight(group, skipIndex) + addedWeight <= GroupCapacity(group)
end

--- Parses the compact `$LAYOUT` syntax into a model table.
-- @tparam string text Compact layout syntax.
-- @treturn table model `{ groups = { { name, subgroup?, slots = {string,...} }, ... } }`.
function layout.Parse(text)
    local model = { groups = {} }
    if type(text) ~= "string" or text == "" then
        return model
    end
    local normalized = text:gsub("[\r\n]+", ";")
    for segment in (normalized .. ";"):gmatch("([^;]*);") do
        local piece = Trim(segment)
        if piece ~= "" and #model.groups < MAX_GROUPS then
            local labelPart, slotsPart = piece:match("^(.-):(.*)$")
            if labelPart then
                local label = Trim(labelPart)
                local subgroup
                local bareLabel, boundGroup = label:match("^(.-)%s*/%s*([1-8])$")
                if bareLabel then
                    label = Trim(bareLabel)
                    subgroup = tonumber(boundGroup)
                end
                local slots = {}
                for slot in (slotsPart .. ","):gmatch("([^,]*),") do
                    local trimmed = Trim(slot)
                    if trimmed ~= "" and #slots < MAX_SLOTS_PER_GROUP then
                        slots[#slots + 1] = trimmed
                    end
                end
                model.groups[#model.groups + 1] = {
                    name = label ~= "" and label or ("Group " .. (#model.groups + 1)),
                    subgroup = subgroup,
                    slots = slots,
                }
            end
        end
    end
    return model
end

-- Takes up to `count` present-and-alive, not-yet-placed names from a list.
local function TakeAvailable(source, count, placed)
    local taken = {}
    if type(source) ~= "table" then
        return taken
    end
    for _, name in ipairs(source) do
        if type(name) == "string" and name ~= "" and not placed[name:lower()] then
            taken[#taken + 1] = name
            if #taken >= count then
                break
            end
        end
    end
    return taken
end

-- Resolves one slot string to zero or more player names.
-- A name or priority list yields one; `*CLASS`/`*CLASS xN`/`group:N` may yield
-- several. `placed` (names already assigned this resolve) is honored for fills.
local function ResolveSlotNames(slot, providers, placed)
    local info = layout.DescribeSlot(slot)

    if info.kind == "subgroup" then
        local members = type(providers.SubgroupMembers) == "function" and providers.SubgroupMembers(info.subgroup)
            or nil
        return TakeAvailable(members, math.huge, placed)
    end

    if info.kind == "class" then
        local members = type(providers.ClassMembers) == "function" and providers.ClassMembers(info.class) or nil
        return TakeAvailable(members, info.count, placed)
    end

    if info.kind == "priority" then
        local resolved = type(providers.ResolvePriorityValue) == "function" and (providers.ResolvePriorityValue(slot))
            or slot
        if type(resolved) == "string" and resolved ~= "" then
            return { resolved }
        end
        return {}
    end

    return { slot }
end

--- Resolves a layout model against the roster into groups of member names.
-- @tparam table model Parsed layout model.
-- @tparam table providers `{ ResolvePriorityValue, ClassMembers }` roster accessors.
-- @treturn table resolved `{ groups = { { name, subgroup?, members = {name,...} }, ... } }`.
function layout.Resolve(model, providers)
    local resolved = { groups = {} }
    if type(model) ~= "table" or type(model.groups) ~= "table" then
        return resolved
    end
    providers = providers or {}
    local placed = {}
    for _, group in ipairs(model.groups) do
        local members = {}
        for _, slot in ipairs(group.slots or {}) do
            -- Fills (class/subgroup) skip already-placed members via TakeAvailable;
            -- explicit names and priority lists are always honored, and everything
            -- marks `placed` so later fills never re-pick the same member.
            for _, name in ipairs(ResolveSlotNames(slot, providers, placed)) do
                members[#members + 1] = name
                placed[name:lower()] = true
            end
        end
        resolved.groups[#resolved.groups + 1] = {
            name = group.name,
            subgroup = group.subgroup,
            members = members,
        }
    end
    return resolved
end

--- Returns a resolved layout containing only groups matching a name query.
-- @tparam table resolved Resolved layout.
-- @tparam string query Group name (case-insensitive).
-- @treturn table subset
function layout.SelectGroups(resolved, query)
    local subset = { groups = {} }
    local target = Trim(query):lower()
    for _, group in ipairs(resolved.groups or {}) do
        if type(group.name) == "string" and group.name:lower() == target then
            subset.groups[#subset.groups + 1] = group
        end
    end
    return subset
end

--- Renders a resolved layout as display text, one line per group.
-- @tparam table resolved Resolved layout.
-- @tparam[opt] table providers May supply `Colorize(name)`.
-- @treturn string text
function layout.RenderText(resolved, providers)
    providers = providers or {}
    local colorize = type(providers.Colorize) == "function" and providers.Colorize
        or function(name)
            return name
        end
    local lines = {}
    for _, group in ipairs(resolved.groups or {}) do
        local names = {}
        for _, member in ipairs(group.members or {}) do
            names[#names + 1] = colorize(member)
        end
        local label = type(group.name) == "string" and group.name or "Group"
        lines[#lines + 1] = label .. ": " .. table.concat(names, ", ")
    end
    return table.concat(lines, "\n")
end

--- Finds the `$LAYOUT` source string in a resolved variable map (case-insensitive).
-- @tparam table vars Merged variable map.
-- @treturn string|nil
function layout.SourceFromVars(vars)
    if type(vars) ~= "table" then
        return nil
    end
    if type(vars["$LAYOUT"]) == "string" then
        return vars["$LAYOUT"]
    end
    for key, value in pairs(vars) do
        if type(key) == "string" and type(value) == "string" and key:upper() == "$LAYOUT" then
            return value
        end
    end
    return nil
end

--- Reads the `$LAYOUT` value from a raw Key=Value variable string.
-- @tparam string vars Raw page/category Vars string.
-- @treturn string|nil source
function layout.ExtractSource(vars)
    if type(vars) ~= "string" then
        return nil
    end
    for line in (vars .. "\n"):gmatch("([^\n]*)\n") do
        local key, value = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
        if key and key:upper() == "$LAYOUT" then
            return value
        end
    end
    return nil
end

--- Returns a Vars string with the `$LAYOUT` line set (or removed when empty).
-- Every other variable line is preserved in order. The layout source is stored
-- on a single line, so callers must join multi-line editing with ";" first.
-- @tparam string vars Existing Vars string.
-- @tparam string source Compact layout syntax (empty removes the key).
-- @treturn string vars
function layout.UpsertSource(vars, source)
    vars = type(vars) == "string" and vars or ""
    source = type(source) == "string" and source or ""
    local out = {}
    local replaced = false
    for line in (vars .. "\n"):gmatch("([^\n]*)\n") do
        local key = line:match("^%s*([^=]-)%s*=")
        if key and key:upper() == "$LAYOUT" then
            if source ~= "" and not replaced then
                out[#out + 1] = "$LAYOUT=" .. source
                replaced = true
            end
        else
            out[#out + 1] = line
        end
    end
    while #out > 0 and out[#out]:match("^%s*$") do
        out[#out] = nil
    end
    if source ~= "" and not replaced then
        out[#out + 1] = "$LAYOUT=" .. source
    end
    return table.concat(out, "\n")
end

--- Expands `{layout}` and `{layout GroupName}` placeholders in text.
-- Resolves the layout once and substitutes every placeholder from that result.
-- @tparam string text Note text containing placeholders.
-- @tparam string source Compact `$LAYOUT` syntax.
-- @tparam[opt] table providers Roster accessors + Colorize.
-- @treturn string text
-- @treturn boolean expanded Whether any placeholder was replaced.
function layout.Expand(text, source, providers)
    if type(text) ~= "string" or not text:find("{layout", 1, true) then
        return text, false
    end
    local resolved = layout.Resolve(layout.Parse(source), providers)
    local expanded = false
    text = text:gsub("{layout%s+([^}]+)}", function(name)
        expanded = true
        return layout.RenderText(layout.SelectGroups(resolved, name), providers)
    end)
    text = text:gsub("{layout}", function()
        expanded = true
        return layout.RenderText(resolved, providers)
    end)
    return text, expanded
end

-- -------------------------------------------------------------------------------
-- Editing model
--
-- The visual editor drags slot *expressions* (not resolved players), so class
-- fills and priority lists survive a rearrangement. Every mutator is pure: it
-- returns `ok, model` on success and `ok, reason` on failure, leaving the input
-- untouched so the caller can keep the previous model on a rejected drop.
-- -------------------------------------------------------------------------------

--- Returns an independent copy of a layout model.
-- @tparam table model Layout model.
-- @treturn table copy
function layout.CopyModel(model)
    local copy = { groups = {} }
    if type(model) ~= "table" or type(model.groups) ~= "table" then
        return copy
    end
    for _, group in ipairs(model.groups) do
        local slots = {}
        for _, slot in ipairs(group.slots or {}) do
            slots[#slots + 1] = slot
        end
        copy.groups[#copy.groups + 1] = { name = group.name, subgroup = group.subgroup, slots = slots }
    end
    return copy
end

-- Group labels and slots are stored in a one-line delimited syntax, so the
-- delimiters themselves can never appear inside a value.
local function SanitizeName(name)
    return Trim((tostring(name or ""):gsub("[;:,\r\n]", " ")))
end

local function SanitizeSlot(slot)
    return Trim((tostring(slot or ""):gsub("[;,\r\n]", " ")))
end

local function NormalizeSubgroup(value)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) or number < 1 or number > MAX_SUBGROUPS then
        return nil
    end
    return number
end

--- Serializes a layout model back to the compact `$LAYOUT` syntax.
-- Round-trips `layout.Parse`.
-- @tparam table model Layout model.
-- @treturn string source
function layout.Serialize(model)
    local parts = {}
    for _, group in ipairs((type(model) == "table" and model.groups) or {}) do
        local label = SanitizeName(group.name)
        if label == "" then
            label = "Group " .. (#parts + 1)
        end
        if group.subgroup then
            label = label .. "/" .. tostring(group.subgroup)
        end
        parts[#parts + 1] = label .. ": " .. table.concat(group.slots or {}, ", ")
    end
    return table.concat(parts, "; ")
end

--- Returns a copy of the model with empty groups dropped.
-- Dragging a member out of a subgroup box can leave the box behind; saving a
-- layout should not persist boxes nobody filled.
-- @tparam table model Layout model.
-- @treturn table model
function layout.Compact(model)
    local compact = { groups = {} }
    for _, group in ipairs(layout.CopyModel(model).groups) do
        if #group.slots > 0 then
            compact.groups[#compact.groups + 1] = group
        end
    end
    return compact
end

--- Splits a model into the eight raid subgroup boxes plus free-form groups.
-- A second group claiming an already-bound subgroup is listed as free so it
-- stays visible and editable rather than silently hidden.
-- @tparam table model Layout model.
-- @treturn table view `{ subgroups = { [1..8] = groupIndex }, free = { groupIndex, ... } }`.
function layout.GridView(model)
    local view = { subgroups = {}, free = {} }
    for index, group in ipairs((type(model) == "table" and model.groups) or {}) do
        local bound = group.subgroup
        if bound and view.subgroups[bound] == nil then
            view.subgroups[bound] = index
        else
            view.free[#view.free + 1] = index
        end
    end
    return view
end

--- Appends a group.
-- @tparam table model Layout model.
-- @tparam[opt] string name Group label; defaults to `Group N`.
-- @tparam[opt] number subgroup Raid subgroup to bind (1-8).
-- @treturn boolean ok
-- @treturn table|string model on success, reason on failure
function layout.AddGroup(model, name, subgroup)
    local updated = layout.CopyModel(model)
    if #updated.groups >= MAX_GROUPS then
        return false, "group-limit"
    end
    local bound = NormalizeSubgroup(subgroup)
    if subgroup ~= nil and not bound then
        return false, "unknown-subgroup"
    end
    local label = SanitizeName(name)
    if label == "" then
        label = "Group " .. (bound or (#updated.groups + 1))
    end
    updated.groups[#updated.groups + 1] = { name = label, subgroup = bound, slots = {} }
    return true, updated
end

--- Removes a group by index.
-- @tparam table model Layout model.
-- @tparam number index Group index.
-- @treturn boolean ok
-- @treturn table|string model on success, reason on failure
function layout.RemoveGroup(model, index)
    local updated = layout.CopyModel(model)
    if not updated.groups[index] then
        return false, "unknown-group"
    end
    table.remove(updated.groups, index)
    return true, updated
end

--- Renames a group.
-- @tparam table model Layout model.
-- @tparam number index Group index.
-- @tparam string name New label.
-- @treturn boolean ok
-- @treturn table|string model on success, reason on failure
function layout.SetGroupName(model, index, name)
    local updated = layout.CopyModel(model)
    local group = updated.groups[index]
    if not group then
        return false, "unknown-group"
    end
    local label = SanitizeName(name)
    if label == "" then
        return false, "empty-name"
    end
    group.name = label
    return true, updated
end

--- Binds a group to a raid subgroup, or unbinds it when `subgroup` is nil.
-- @tparam table model Layout model.
-- @tparam number index Group index.
-- @tparam[opt] number subgroup Raid subgroup (1-8).
-- @treturn boolean ok
-- @treturn table|string model on success, reason on failure
function layout.SetGroupSubgroup(model, index, subgroup)
    local updated = layout.CopyModel(model)
    local group = updated.groups[index]
    if not group then
        return false, "unknown-group"
    end
    local bound = NormalizeSubgroup(subgroup)
    if subgroup ~= nil and not bound then
        return false, "unknown-subgroup"
    end
    if bound then
        for other, candidate in ipairs(updated.groups) do
            if other ~= index and candidate.subgroup == bound then
                return false, "subgroup-taken"
            end
        end
        if GroupWeight(group) > MAX_SUBGROUP_SLOTS then
            return false, "group-full"
        end
    end
    group.subgroup = bound
    return true, updated
end

-- Reads the slot expression a drag carries: either an existing slot or the raw
-- text of a roster palette entry.
local function ResolveDragText(model, drag)
    if drag.kind == "text" then
        local text = SanitizeSlot(drag.text)
        if text == "" then
            return nil, "empty-slot"
        end
        return text
    end

    if drag.kind == "slot" then
        local group = model.groups[drag.group]
        if not group then
            return nil, "unknown-group"
        end
        local slot = group.slots[drag.slot]
        if not slot then
            return nil, "unknown-slot"
        end
        return slot
    end

    return nil, "unknown-drag"
end

-- Resolves the destination group index, creating a bound group when a drop
-- lands in an empty subgroup box.
local function ResolveDropGroup(model, drop)
    if drop.kind == "group" or drop.kind == "slot" then
        if type(drop.group) ~= "number" or not model.groups[drop.group] then
            return nil, "unknown-group"
        end
        return drop.group
    end

    if drop.kind == "subgroup" then
        local bound = NormalizeSubgroup(drop.subgroup)
        if not bound then
            return nil, "unknown-subgroup"
        end
        for index, group in ipairs(model.groups) do
            if group.subgroup == bound then
                return index
            end
        end
        if #model.groups >= MAX_GROUPS then
            return nil, "group-limit"
        end
        model.groups[#model.groups + 1] = { name = "Group " .. bound, subgroup = bound, slots = {} }
        return #model.groups
    end

    return nil, "unknown-drop"
end

-- Trades two slots when a member is dropped onto an occupant of a full group.
local function SwapSlots(model, dragIndex, dragSlot, targetIndex, targetSlot, text, occupant)
    local source = model.groups[dragIndex]
    local target = model.groups[targetIndex]
    if not CanHold(target, layout.SlotWeight(text), targetSlot) then
        return false, "group-full"
    end
    if not CanHold(source, layout.SlotWeight(occupant), dragSlot) then
        return false, "group-full"
    end
    source.slots[dragSlot] = occupant
    target.slots[targetSlot] = text
    return true, model
end

--- Applies a drag-and-drop gesture to a layout model.
-- Drags are `{ kind = "slot", group, slot }` or `{ kind = "text", text }`.
-- Drops are `{ kind = "slot", group, slot }` (insert before, or swap when the
-- destination is full), `{ kind = "group", group }` and
-- `{ kind = "subgroup", subgroup }` (append), or `{ kind = "remove" }`.
-- @tparam table model Layout model.
-- @tparam table drag Drag descriptor.
-- @tparam table drop Drop descriptor.
-- @treturn boolean ok
-- @treturn table|string model on success, reason on failure
function layout.ApplyDrop(model, drag, drop)
    if type(drag) ~= "table" or type(drop) ~= "table" then
        return false, "unknown-drag"
    end

    local updated = layout.CopyModel(model)
    local text, dragError = ResolveDragText(updated, drag)
    if not text then
        return false, dragError
    end
    local isMove = drag.kind == "slot"

    if drop.kind == "remove" then
        if not isMove then
            return false, "unknown-drop"
        end
        table.remove(updated.groups[drag.group].slots, drag.slot)
        return true, updated
    end

    local targetIndex, targetError = ResolveDropGroup(updated, drop)
    if not targetIndex then
        return false, targetError
    end
    local target = updated.groups[targetIndex]

    if isMove and drop.kind == "slot" and targetIndex ~= drag.group then
        local occupant = target.slots[drop.slot]
        if occupant and not CanHold(target, layout.SlotWeight(text)) then
            return SwapSlots(updated, drag.group, drag.slot, targetIndex, drop.slot, text, occupant)
        end
    end

    if isMove then
        table.remove(updated.groups[drag.group].slots, drag.slot)
    end
    if not CanHold(target, layout.SlotWeight(text)) or #target.slots >= MAX_SLOTS_PER_GROUP then
        return false, "group-full"
    end

    local position = #target.slots + 1
    if drop.kind == "slot" then
        position = drop.slot
        if isMove and targetIndex == drag.group and drop.slot > drag.slot then
            position = position - 1
        end
        if position < 1 then
            position = 1
        end
        if position > #target.slots + 1 then
            position = #target.slots + 1
        end
    end
    table.insert(target.slots, position, text)
    return true, updated
end
