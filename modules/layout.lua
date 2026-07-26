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

local function Trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$")
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

-- Resolves one slot string to a player name, or nil when nothing is available.
-- Marks the chosen name in `placed` so class fills never double-assign.
local function ResolveSlot(slot, providers, placed)
    local class, count = slot:match("^%*(%a+)%s*[xX]?%s*(%d*)$")
    if class then
        local members = type(providers.ClassMembers) == "function" and providers.ClassMembers(class:upper()) or nil
        if type(members) ~= "table" then
            return nil
        end
        for _, name in ipairs(members) do
            if type(name) == "string" and not placed[name:lower()] then
                return name
            end
        end
        return nil
    end

    if slot:find(">", 1, true) then
        if type(providers.ResolvePriorityValue) == "function" then
            return (providers.ResolvePriorityValue(slot))
        end
        return slot
    end

    return slot
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
            local name = ResolveSlot(slot, providers, placed)
            if type(name) == "string" and name ~= "" then
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
