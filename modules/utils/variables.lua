-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/variables.lua
--
-- Deterministic category traversal and variable-layer helpers.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity
local json = AngryEra.utils.json

if not identity or type(identity.ValidateSyncId) ~= "function" then
    error("AngryEra identity must load before variable helpers")
end

AngryEra.utils.variables = {}
local variables = AngryEra.utils.variables

variables.MAX_ANCESTOR_DEPTH = 32
variables.MAX_VARIABLE_BYTES = 5000
variables.MAX_RESOLVED_VARIABLE_BYTES = (variables.MAX_ANCESTOR_DEPTH + 1) * variables.MAX_VARIABLE_BYTES
variables.MAX_VARIABLE_FAMILIES = 64
variables.MAX_VARIABLE_FAMILY_SELECTORS = 64
variables.MAX_VARIABLE_FAMILY_MEMBERS = 40
variables.MAX_GENERATED_FAMILY_VARIABLES = 1024
variables.MAX_GENERATED_FAMILY_BYTES = variables.MAX_RESOLVED_VARIABLE_BYTES
variables.RAID_ROSTER_DIRECTIVE = "$AE_RAID_ROSTER"
variables.RAID_ROSTER_VERSION = 1
variables.MAX_RAID_ROSTER_MEMBERS = 40

local function RaidRosterDirectiveIdentity(key)
    return type(key) == "string" and key:upper() == variables.RAID_ROSTER_DIRECTIVE or false
end

local function KeyValueRaidRosterDirective(rawVariables)
    local foundValue
    local found = false
    for line in (rawVariables .. "\n"):gmatch("([^\r\n]*)[\r\n]+") do
        local key, value = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
        if key and RaidRosterDirectiveIdentity(key) then
            if found then
                return nil, nil, "conflicting-reserved-metadata"
            end
            found = true
            foundValue = value
        end
    end
    return found, foundValue
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function IsValidEntityId(value, idField)
    if idField == "SyncId" then
        return identity.ValidateSyncId(value, "category")
    end
    return IsPositiveInteger(value)
end

local function DenseArrayLength(value, maximum)
    if type(value) ~= "table" then
        return nil
    end

    local count = 0
    local highest = 0
    for key in pairs(value) do
        if not IsPositiveInteger(key) then
            return nil
        end
        count = count + 1
        if key > highest then
            highest = key
        end
        if highest > maximum or count > maximum then
            return nil
        end
    end
    if count ~= highest then
        return nil
    end
    return count
end

--- Collects a category chain in root-to-direct-parent order.
-- The category table must be keyed by the chosen entity identifier.
-- @tparam table categories Category records.
-- @tparam number|string|nil directParentId Direct parent identifier.
-- @tparam[opt] table options Traversal boundary and field names.
-- @treturn table|nil chain
-- @treturn string|nil errorCode
function variables.CollectCategoryChain(categories, directParentId, options)
    if type(categories) ~= "table" then
        return nil, "invalid-categories"
    end

    options = options or {}
    if type(options) ~= "table" then
        return nil, "invalid-options"
    end

    local idField = options.idField or "Id"
    local parentField = options.parentField or "CategoryId"
    local rootId = options.rootId
    local maxDepth = options.maxDepth or variables.MAX_ANCESTOR_DEPTH
    if type(idField) ~= "string" or idField == "" or type(parentField) ~= "string" or parentField == "" then
        return nil, "invalid-options"
    end
    if not IsPositiveInteger(maxDepth) or maxDepth > variables.MAX_ANCESTOR_DEPTH then
        return nil, "invalid-options"
    end
    if directParentId == nil then
        if rootId ~= nil then
            return nil, "root-not-ancestor"
        end
        return {}
    end
    if not IsValidEntityId(directParentId, idField) then
        return nil, "invalid-parent"
    end
    if rootId ~= nil and not IsValidEntityId(rootId, idField) then
        return nil, "invalid-parent"
    end

    local reversed = {}
    local seen = {}
    local currentId = directParentId
    while currentId ~= nil do
        if seen[currentId] then
            return nil, "cycle"
        end
        seen[currentId] = true

        if #reversed >= maxDepth then
            return nil, "depth-exceeded"
        end

        local category = categories[currentId]
        if type(category) ~= "table" then
            return nil, "missing-category"
        end
        if category[idField] ~= currentId then
            return nil, "category-id-mismatch"
        end

        reversed[#reversed + 1] = category
        if rootId ~= nil and currentId == rootId then
            break
        end

        local parentId = category[parentField]
        if parentId ~= nil and not IsValidEntityId(parentId, idField) then
            return nil, "invalid-parent"
        end
        currentId = parentId
    end

    if rootId ~= nil and reversed[#reversed][idField] ~= rootId then
        return nil, "root-not-ancestor"
    end

    local chain = {}
    for index = #reversed, 1, -1 do
        chain[#chain + 1] = reversed[index]
    end
    return chain
end

--- Converts a local category chain to an ordered wire-safe variable layer list.
-- @tparam table chain Root-to-parent category records.
-- @treturn table|nil layers
-- @treturn string|nil errorCode
function variables.BuildAncestorVariableLayers(chain)
    local count = DenseArrayLength(chain, variables.MAX_ANCESTOR_DEPTH)
    if not count then
        return nil, "invalid-ancestor-layers"
    end

    local layers = {}
    local seen = {}
    for index = 1, count do
        local category = chain[index]
        if type(category) ~= "table" or not identity.ValidateSyncId(category.SyncId, "category") then
            return nil, "invalid-ancestor-sync-id"
        end
        if seen[category.SyncId] then
            return nil, "duplicate-ancestor"
        end
        seen[category.SyncId] = true

        local rawVariables = category.Vars or ""
        if type(rawVariables) ~= "string" or #rawVariables > variables.MAX_VARIABLE_BYTES then
            return nil, "invalid-ancestor-variables"
        end
        layers[index] = {
            SyncId = category.SyncId,
            Vars = rawVariables,
        }
    end
    return layers
end

--- Validates and copies ancestor layers received from a standalone page packet.
-- @tparam table layers Ordered root-to-parent layers.
-- @tparam string|nil parentSyncId Expected direct-parent synchronization ID.
-- @treturn table|nil safeLayers
-- @treturn string|nil errorCode
function variables.ValidateAncestorVariableLayers(layers, parentSyncId)
    local count = DenseArrayLength(layers, variables.MAX_ANCESTOR_DEPTH)
    if not count then
        return nil, "invalid-ancestor-layers"
    end
    if parentSyncId ~= nil and not identity.ValidateSyncId(parentSyncId, "category") then
        return nil, "invalid-parent-sync-id"
    end

    local safeLayers = {}
    local seen = {}
    for index = 1, count do
        local layer = layers[index]
        if type(layer) ~= "table" or not identity.ValidateSyncId(layer.SyncId, "category") then
            return nil, "invalid-ancestor-sync-id"
        end
        if seen[layer.SyncId] then
            return nil, "duplicate-ancestor"
        end
        seen[layer.SyncId] = true
        if type(layer.Vars) ~= "string" or #layer.Vars > variables.MAX_VARIABLE_BYTES then
            return nil, "invalid-ancestor-variables"
        end
        safeLayers[index] = {
            SyncId = layer.SyncId,
            Vars = layer.Vars,
        }
    end

    local actualParentSyncId = count > 0 and safeLayers[count].SyncId or nil
    if actualParentSyncId ~= parentSyncId then
        return nil, "parent-mismatch"
    end
    return safeLayers
end

local function ParseVariableString(rawVariables)
    rawVariables = rawVariables or ""
    if type(rawVariables) ~= "string" or #rawVariables > variables.MAX_VARIABLE_BYTES then
        return nil, "invalid-variables"
    end
    if rawVariables == "" or rawVariables == "{}" then
        return {}
    end

    local firstCharacter = rawVariables:match("^%s*(.)")
    if firstCharacter == "[" then
        return nil, "invalid-variables"
    end
    if firstCharacter ~= "{" then
        local _, _, directiveError = KeyValueRaidRosterDirective(rawVariables)
        if directiveError then
            return nil, directiveError
        end
    end
    local parser = firstCharacter == "{" and json.JSON_TryDecode or json.ParseVariables
    local ok, parsed = pcall(parser, rawVariables)
    if not ok or type(parsed) ~= "table" then
        return nil, "invalid-variables"
    end
    for key in pairs(parsed) do
        if type(key) ~= "string" then
            return nil, "invalid-variables"
        end
    end
    return parsed
end

local RAID_ROSTER_ROLES = {
    "TANK",
    "HEALER",
    "DPS",
}

local RAID_ROSTER_FIELDS = {
    DPS = true,
    HEALER = true,
    ID = true,
    TANK = true,
    v = true,
}

local RAID_ROSTER_ID_FIELDS = {
    DPS = true,
    HEALER = true,
    TANK = true,
}

local function ValidRaidRosterName(member, requireQualified)
    if
        type(member) ~= "string"
        or member == ""
        or #member > 128
        or member:match("^%s*(.-)%s*$") ~= member
        or member:find("[%c%s{},>=]")
    then
        return nil
    end

    local memberIdentity = member:lower()
    local shortStem = memberIdentity:match("^([^-]+)")
    if
        type(shortStem) ~= "string"
        or shortStem == ""
        or memberIdentity:sub(-1) == "-"
        or memberIdentity:find("--", 1, true)
        or (requireQualified and not memberIdentity:find("-", 1, true))
    then
        return nil
    end
    return memberIdentity, shortStem
end

local function CloneValidatedRaidRosterSnapshot(snapshot)
    if type(snapshot) ~= "table" or snapshot == json.JSON_NULL or snapshot.v ~= variables.RAID_ROSTER_VERSION then
        return nil, "invalid-raid-roster"
    end
    for key in pairs(snapshot) do
        if not RAID_ROSTER_FIELDS[key] then
            return nil, "invalid-raid-roster"
        end
    end
    if type(snapshot.ID) ~= "table" or snapshot.ID == json.JSON_NULL then
        return nil, "invalid-raid-roster"
    end
    for key in pairs(snapshot.ID) do
        if not RAID_ROSTER_ID_FIELDS[key] then
            return nil, "invalid-raid-roster"
        end
    end

    local safe = {
        ID = {},
        v = variables.RAID_ROSTER_VERSION,
    }
    local total = 0
    local seenMembers = {}
    local seenCanonicalIds = {}
    local qualifiedStems = {}
    local unqualifiedStems = {}
    for _, role in ipairs(RAID_ROSTER_ROLES) do
        local members = snapshot[role]
        local count = DenseArrayLength(members, variables.MAX_RAID_ROSTER_MEMBERS)
        local canonicalIds = snapshot.ID[role]
        local canonicalCount = DenseArrayLength(canonicalIds, variables.MAX_RAID_ROSTER_MEMBERS)
        if count == nil or canonicalCount == nil or canonicalCount ~= count then
            return nil, "invalid-raid-roster"
        end
        safe[role] = {}
        safe.ID[role] = {}
        for index = 1, count do
            local member = members[index]
            local memberIdentity, shortStem = ValidRaidRosterName(member, false)
            local canonicalId = canonicalIds[index]
            local canonicalIdentity, canonicalStem = ValidRaidRosterName(canonicalId, true)
            if
                not memberIdentity
                or not canonicalIdentity
                or shortStem ~= canonicalStem
                or (member:find("-", 1, true) and memberIdentity ~= canonicalIdentity)
            then
                return nil, "invalid-raid-roster"
            end
            if seenMembers[memberIdentity] then
                return nil, "duplicate-raid-roster-member"
            end
            if seenCanonicalIds[canonicalIdentity] then
                return nil, "duplicate-raid-roster-member"
            end
            if member:find("-", 1, true) then
                if unqualifiedStems[shortStem] then
                    return nil, "ambiguous-raid-roster-member"
                end
                qualifiedStems[shortStem] = true
            else
                if qualifiedStems[shortStem] then
                    return nil, "ambiguous-raid-roster-member"
                end
                unqualifiedStems[shortStem] = true
            end
            seenMembers[memberIdentity] = true
            seenCanonicalIds[canonicalIdentity] = true
            safe[role][index] = member
            safe.ID[role][index] = canonicalId
        end
        total = total + count
        if total > variables.MAX_RAID_ROSTER_MEMBERS then
            return nil, "raid-roster-too-large"
        end
    end
    return safe
end

--- Validates and detaches a version-1 managed raid-roster snapshot.
-- Every display-role array and parallel canonical-ID array is required and dense.
-- @tparam table snapshot `{ v=1, TANK={...}, HEALER={...}, DPS={...}, ID={TANK={...}, HEALER={...}, DPS={...}} }`.
-- @treturn table|nil safeSnapshot
-- @treturn string|nil errorCode
function variables.ValidateRaidRosterSnapshot(snapshot)
    return CloneValidatedRaidRosterSnapshot(snapshot)
end

local function DecodeRaidRosterSnapshot(value)
    if type(value) == "string" then
        value = json.JSON_TryDecode(value)
    end
    return CloneValidatedRaidRosterSnapshot(value)
end

local function DecodeRawVariablesObject(rawVariables)
    local firstCharacter = rawVariables:match("^%s*(.)")
    if firstCharacter ~= "{" and firstCharacter ~= "[" then
        return nil, false
    end
    if firstCharacter ~= "{" then
        return nil, true
    end
    local object = json.JSON_TryDecode(rawVariables)
    if type(object) ~= "table" or object == json.JSON_NULL then
        return nil, true
    end
    for key in pairs(object) do
        if type(key) ~= "string" then
            return nil, true
        end
    end
    return object, true
end

local function FindRaidRosterDirective(object)
    local foundKey
    local foundValue
    for key, value in pairs(object) do
        if RaidRosterDirectiveIdentity(key) then
            if foundKey ~= nil then
                return nil, nil, "conflicting-reserved-metadata"
            end
            foundKey = key
            foundValue = value
        end
    end
    return foundKey, foundValue
end

--- Reads the managed raid-roster snapshot from raw Key=Value or JSON variables.
-- An absent directive returns nil without an error.
-- @tparam string|nil rawVariables Raw page/category variables.
-- @treturn table|nil snapshot
-- @treturn string|nil errorCode
function variables.ExtractRaidRosterSnapshot(rawVariables)
    rawVariables = rawVariables or ""
    if type(rawVariables) ~= "string" or #rawVariables > variables.MAX_VARIABLE_BYTES then
        return nil, "invalid-variables"
    end

    local object, isJson = DecodeRawVariablesObject(rawVariables)
    if isJson and not object then
        return nil, "invalid-variables"
    end

    local present
    local value
    local findError
    if object then
        local key
        key, value, findError = FindRaidRosterDirective(object)
        present = key ~= nil
    else
        present, value, findError = KeyValueRaidRosterDirective(rawVariables)
    end
    if findError then
        return nil, findError
    end
    if not present then
        return nil
    end
    return DecodeRaidRosterSnapshot(value)
end

local function NewlineFor(rawVariables)
    return rawVariables:find("\r\n", 1, true) and "\r\n"
        or (rawVariables:find("\n", 1, true) and "\n")
        or (rawVariables:find("\r", 1, true) and "\r")
        or "\n"
end

local function UpsertKeyValueRaidRoster(rawVariables, encodedSnapshot)
    local newline = NewlineFor(rawVariables)
    local normalized = rawVariables:gsub("\r\n", "\n"):gsub("\r", "\n")
    local hadFinalNewline = normalized:sub(-1) == "\n"
    local lines = {}
    if normalized ~= "" then
        local scan = hadFinalNewline and normalized or (normalized .. "\n")
        for line in scan:gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end
    end

    local out = {}
    local replaced = false
    for _, line in ipairs(lines) do
        local key = line:match("^%s*([^=]-)%s*=")
        if key and RaidRosterDirectiveIdentity(key) then
            if replaced then
                return nil, "conflicting-reserved-metadata"
            end
            replaced = true
            if encodedSnapshot then
                out[#out + 1] = variables.RAID_ROSTER_DIRECTIVE .. "=" .. encodedSnapshot
            end
        else
            out[#out + 1] = line
        end
    end

    if encodedSnapshot and not replaced then
        out[#out + 1] = variables.RAID_ROSTER_DIRECTIVE .. "=" .. encodedSnapshot
    end

    local result = table.concat(out, newline)
    if hadFinalNewline then
        result = result .. newline
    end
    return result
end

--- Sets or removes the one managed raid-roster directive in raw variables.
-- Key=Value source retains unrelated lines and newline style. JSON source
-- remains a JSON object but is canonically re-encoded.
-- @tparam string|nil rawVariables Existing raw page/category variables.
-- @tparam table|nil snapshot Valid version-1 snapshot, or nil to remove it.
-- @treturn string|nil updatedVariables
-- @treturn string|nil errorCode
function variables.UpsertRaidRosterSource(rawVariables, snapshot)
    rawVariables = rawVariables or ""
    if type(rawVariables) ~= "string" or #rawVariables > variables.MAX_VARIABLE_BYTES then
        return nil, "invalid-variables"
    end

    local safeSnapshot
    if snapshot ~= nil then
        local snapshotError
        safeSnapshot, snapshotError = CloneValidatedRaidRosterSnapshot(snapshot)
        if not safeSnapshot then
            return nil, snapshotError
        end
    end

    local object, isJson = DecodeRawVariablesObject(rawVariables)
    if isJson and not object then
        return nil, "invalid-variables"
    end

    local updated
    if object then
        local existingKey, _, findError = FindRaidRosterDirective(object)
        if findError then
            return nil, findError
        end
        if existingKey then
            object[existingKey] = nil
        end
        if safeSnapshot then
            object[variables.RAID_ROSTER_DIRECTIVE] = safeSnapshot
        end
        updated = next(object) == nil and "{}" or json.JSON_Encode(object)
    else
        local encodedSnapshot = safeSnapshot and json.JSON_Encode(safeSnapshot) or nil
        local updateError
        updated, updateError = UpsertKeyValueRaidRoster(rawVariables, encodedSnapshot)
        if not updated then
            return nil, updateError
        end
    end

    if #updated > variables.MAX_VARIABLE_BYTES then
        return nil, "invalid-variables"
    end
    return updated
end

local function AppendLengthPrefixed(parts, value)
    parts[#parts + 1] = tostring(#value)
    parts[#parts + 1] = ":"
    parts[#parts + 1] = value
end

local RESERVED_METADATA_IDENTITIES = {
    AE_RAID_ROSTER = true,
    AUTOADVANCE = true,
    AUTOAPPLYLAYOUT = true,
    CIRCLE = true,
    DIAMOND = true,
    ENCOUNTER = true,
    ENCOUNTERID = true,
    LAYOUT = true,
    MOON = true,
    SKULL = true,
    SQUARE = true,
    STAR = true,
    TRIANGLE = true,
    X = true,
}

local function ReservedMetadataIdentity(key)
    if type(key) ~= "string" or key:sub(1, 1) ~= "$" then
        return nil
    end

    local identityKey = key:sub(2):upper()
    if identityKey == "CROSS" then
        identityKey = "X"
    end
    if not RESERVED_METADATA_IDENTITIES[identityKey] then
        return nil
    end
    return identityKey
end

local function MergeParsedVariableLayer(merged, reservedKeys, sourceRanks, rank, parsed)
    local layerReservedKeys = {}
    for key in pairs(parsed) do
        local identityKey = ReservedMetadataIdentity(key)
        if identityKey then
            if layerReservedKeys[identityKey] ~= nil then
                return nil, "conflicting-reserved-metadata"
            end
            layerReservedKeys[identityKey] = key
        end
    end

    for key, value in pairs(parsed) do
        local identityKey = ReservedMetadataIdentity(key)
        if identityKey then
            local previousKey = reservedKeys[identityKey]
            if previousKey ~= nil and previousKey ~= key then
                merged[previousKey] = nil
                sourceRanks[previousKey] = nil
            end
            reservedKeys[identityKey] = key
        end
        merged[key] = value
        sourceRanks[key] = rank
    end
    return true
end

local function Trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

-- Family names deliberately end in a non-digit so `HEALER12` has exactly one
-- possible declaration owner (`HEALER*`). That keeps nested-family dependency
-- and collision handling deterministic.
local function IsFamilyBase(value)
    return type(value) == "string" and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil and value:match("%d$") == nil
end

local function IsVariableIdentifier(value)
    return type(value) == "string" and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function FamilyDeclarationBase(key)
    if type(key) ~= "string" or key:sub(-1) ~= "*" then
        return nil, false
    end
    local base = key:sub(1, -2)
    if key:sub(1, 1) == "$" or not IsFamilyBase(base) then
        return nil, true
    end
    return base, true
end

local function IndexedFamilyMember(key)
    if type(key) ~= "string" or key:sub(1, 1) == "$" then
        return nil
    end
    local base, suffix = key:match("^(.-)([1-9]%d*)$")
    if not IsFamilyBase(base) then
        return nil
    end
    return base, suffix
end

local function NumericSuffixLess(left, right)
    if #left ~= #right then
        return #left < #right
    end
    return left < right
end

local RAID_ROSTER_OUTPUT_PREFIXES = {
    DPS = "RAID_DPS",
    HEALER = "RAID_HEALER",
    TANK = "RAID_TANK",
}

local RAID_ROSTER_FAMILY_KEYS = {
    ["RAID_DPS*"] = true,
    ["RAID_HEALER*"] = true,
    ["RAID_TANK*"] = true,
}

local function RaidRosterOutputIdentity(key)
    if type(key) ~= "string" then
        return nil
    end
    local role, suffix = key:match("^RAID_([A-Z]+)([1-9]%d*)$")
    if not role or RAID_ROSTER_OUTPUT_PREFIXES[role] == nil then
        return nil
    end
    return role, suffix
end

-- Materializes the nearest managed roster snapshot into ordinary numbered
-- variables. The directive itself is removed before public/meta partitioning.
-- A same-layer or nearer explicit numbered member is an intentional override.
local function ExpandRaidRosterSnapshot(merged, sourceRanks)
    local directiveKey
    for key in pairs(merged) do
        if ReservedMetadataIdentity(key) == "AE_RAID_ROSTER" then
            directiveKey = key
            break
        end
    end
    if not directiveKey then
        return merged
    end

    local snapshot, snapshotError = DecodeRaidRosterSnapshot(merged[directiveKey])
    if not snapshot then
        return nil, snapshotError
    end
    local directiveRank = sourceRanks[directiveKey]
    merged[directiveKey] = nil
    sourceRanks[directiveKey] = nil

    -- The snapshot replaces broader declarations of its generated families.
    -- A same-layer declaration is ambiguous and rejected; a closer declaration
    -- remains an intentional override and is handled by normal family expansion.
    local inheritedDeclarations = {}
    for key in pairs(merged) do
        if RAID_ROSTER_FAMILY_KEYS[key] then
            local declarationRank = sourceRanks[key] or 0
            if declarationRank == directiveRank then
                return nil, "conflicting-raid-roster-family"
            end
            if declarationRank < directiveRank then
                inheritedDeclarations[#inheritedDeclarations + 1] = key
            end
        end
    end
    for _, key in ipairs(inheritedDeclarations) do
        merged[key] = nil
        sourceRanks[key] = nil
    end

    -- A closer snapshot owns the complete managed output namespace, so raw
    -- numbered values inherited from broader layers cannot leak through it.
    local inheritedKeys = {}
    for key in pairs(merged) do
        if RaidRosterOutputIdentity(key) and (sourceRanks[key] or 0) < directiveRank then
            inheritedKeys[#inheritedKeys + 1] = key
        end
    end
    for _, key in ipairs(inheritedKeys) do
        merged[key] = nil
        sourceRanks[key] = nil
    end

    for _, role in ipairs(RAID_ROSTER_ROLES) do
        local prefix = RAID_ROSTER_OUTPUT_PREFIXES[role]
        for index, member in ipairs(snapshot[role]) do
            local targetKey = prefix .. tostring(index)
            local targetRank = sourceRanks[targetKey]
            if targetRank == nil or targetRank < directiveRank then
                merged[targetKey] = member
                sourceRanks[targetKey] = directiveRank
            end
        end
    end
    return merged
end

local function ParseFamilySelectors(raw)
    if type(raw) ~= "string" then
        return nil, "invalid-variable-family"
    end
    if Trim(raw) == "" then
        return {}
    end

    local selectors = {}
    local cursor = 1
    while true do
        local separator = raw:find(",", cursor, true)
        local term = Trim(raw:sub(cursor, separator and separator - 1 or nil))
        if term == "" then
            return nil, "invalid-variable-family"
        end

        if term:sub(1, 2) == "{{" or term:sub(-2) == "}}" then
            local wrapped = term:match("^{{%s*([^{}]-)%s*}}$")
            if not wrapped then
                return nil, "invalid-variable-family"
            end
            term = Trim(wrapped)
        end

        local selector
        if term:sub(-1) == "*" then
            local base = term:sub(1, -2)
            if not IsFamilyBase(base) then
                return nil, "invalid-variable-family"
            end
            selector = {
                Kind = "family",
                Base = base,
            }
        else
            if not IsVariableIdentifier(term) then
                return nil, "invalid-variable-family"
            end
            selector = {
                Kind = "exact",
                Key = term,
            }
        end

        selectors[#selectors + 1] = selector
        if #selectors > variables.MAX_VARIABLE_FAMILY_SELECTORS then
            return nil, "variable-family-too-large"
        end
        if not separator then
            break
        end
        cursor = separator + 1
    end
    return selectors
end

-- Expands declaration pseudo-keys such as `HEALER*` into dense, ordinary
-- `HEALER1..N` references. Inheritance has already selected the nearest
-- declaration. A nearer declaration owns its numbered namespace, while an
-- explicit member from the same or a nearer layer remains an intentional
-- override.
local function ExpandVariableFamilies(merged, sourceRanks)
    local definitions = {}
    local definitionBases = {}
    local declarationKeys = {}
    for key in pairs(merged) do
        local _, attempted = FamilyDeclarationBase(key)
        if attempted then
            declarationKeys[#declarationKeys + 1] = key
        end
    end
    if #declarationKeys == 0 then
        return merged
    end
    if #declarationKeys > variables.MAX_VARIABLE_FAMILIES then
        return nil, "variable-family-too-large"
    end
    table.sort(declarationKeys)

    for _, key in ipairs(declarationKeys) do
        local base = FamilyDeclarationBase(key)
        local value = merged[key]
        if not base or type(value) ~= "string" then
            return nil, "invalid-variable-family"
        end
        local selectors, selectorError = ParseFamilySelectors(value)
        if not selectors then
            return nil, selectorError
        end
        definitionBases[#definitionBases + 1] = base
        definitions[base] = {
            Key = key,
            Rank = sourceRanks[key],
            Selectors = selectors,
        }
    end

    for _, base in ipairs(definitionBases) do
        local key = definitions[base].Key
        merged[key] = nil
        sourceRanks[key] = nil
    end

    local memberIndex = {}
    local function IndexMember(key)
        local base, suffix = IndexedFamilyMember(key)
        if not base then
            return
        end
        memberIndex[base] = memberIndex[base] or {}
        memberIndex[base][suffix] = key
    end
    local function UnindexMember(key)
        local base, suffix = IndexedFamilyMember(key)
        local indexed = base and memberIndex[base]
        if indexed and indexed[suffix] == key then
            indexed[suffix] = nil
        end
    end
    for key in pairs(merged) do
        IndexMember(key)
    end

    local state = {}
    local generatedCount = 0
    local generatedBytes = 0

    local function EvaluateFamily(base)
        if state[base] == 2 then
            return true
        end
        if state[base] == 1 then
            return nil, "variable-family-cycle"
        end

        local definition = definitions[base]
        if not definition then
            return true
        end
        state[base] = 1

        -- A closer declaration replaces concrete members inherited under the
        -- same destination prefix. Same-layer and still-closer exact members
        -- are retained as explicit ordinal overrides.
        local destinationMembers = memberIndex[base]
        if destinationMembers then
            local inheritedKeys = {}
            for _, key in pairs(destinationMembers) do
                if (sourceRanks[key] or 0) < definition.Rank then
                    inheritedKeys[#inheritedKeys + 1] = key
                end
            end
            for _, key in ipairs(inheritedKeys) do
                merged[key] = nil
                sourceRanks[key] = nil
                UnindexMember(key)
            end
        end

        local sourceKeys = {}
        local seenSources = {}
        local function AddSource(key)
            if seenSources[key] or type(merged[key]) ~= "string" then
                return true
            end
            seenSources[key] = true
            sourceKeys[#sourceKeys + 1] = key
            if #sourceKeys > variables.MAX_VARIABLE_FAMILY_MEMBERS then
                return nil, "variable-family-too-large"
            end
            return true
        end

        for _, selector in ipairs(definition.Selectors) do
            if selector.Kind == "family" then
                local evaluated, evaluateError = EvaluateFamily(selector.Base)
                if not evaluated then
                    return nil, evaluateError
                end
                local indexed = memberIndex[selector.Base] or {}
                local suffixes = {}
                for suffix, key in pairs(indexed) do
                    if type(merged[key]) == "string" and not seenSources[key] then
                        suffixes[#suffixes + 1] = suffix
                        if #sourceKeys + #suffixes > variables.MAX_VARIABLE_FAMILY_MEMBERS then
                            return nil, "variable-family-too-large"
                        end
                    end
                end
                table.sort(suffixes, NumericSuffixLess)
                for _, suffix in ipairs(suffixes) do
                    local added, addError = AddSource(indexed[suffix])
                    if not added then
                        return nil, addError
                    end
                end
            else
                local dependencyBase = IndexedFamilyMember(selector.Key)
                local dependency = dependencyBase and definitions[dependencyBase]
                local selectedRank = sourceRanks[selector.Key]
                if dependency and (selectedRank == nil or selectedRank < dependency.Rank) then
                    local evaluated, evaluateError = EvaluateFamily(dependencyBase)
                    if not evaluated then
                        return nil, evaluateError
                    end
                end
                local added, addError = AddSource(selector.Key)
                if not added then
                    return nil, addError
                end
            end
        end

        for ordinal, sourceKey in ipairs(sourceKeys) do
            local targetKey = base .. tostring(ordinal)
            local targetRank = sourceRanks[targetKey]
            if targetRank == nil or targetRank < definition.Rank then
                -- Copy the effective raw expression instead of adding another
                -- reference hop. Deeply composed families therefore retain the
                -- ordinary resolver's full recursion budget for the variables
                -- the original member actually references.
                local generatedValue = merged[sourceKey]
                local addedBytes = #targetKey + #generatedValue
                if
                    generatedCount + 1 > variables.MAX_GENERATED_FAMILY_VARIABLES
                    or generatedBytes + addedBytes > variables.MAX_GENERATED_FAMILY_BYTES
                then
                    return nil, "variable-family-too-large"
                end
                merged[targetKey] = generatedValue
                sourceRanks[targetKey] = definition.Rank
                IndexMember(targetKey)
                generatedCount = generatedCount + 1
                generatedBytes = generatedBytes + addedBytes
            end
        end

        state[base] = 2
        return true
    end

    for _, base in ipairs(definitionBases) do
        local evaluated, evaluateError = EvaluateFamily(base)
        if not evaluated then
            return nil, evaluateError
        end
    end
    return merged
end

--- Builds collision-resistant canonical input for a page render context revision.
-- Layer order and identity are intentionally significant.
-- @tparam table layers Root-to-parent variable layers.
-- @tparam string|nil pageVariables Raw page variable string.
-- @treturn string|nil canonicalInput
-- @treturn string|nil errorCode
function variables.BuildContextRevisionInput(layers, pageVariables)
    local count = DenseArrayLength(layers, variables.MAX_ANCESTOR_DEPTH)
    if not count then
        return nil, "invalid-ancestor-layers"
    end

    pageVariables = pageVariables or ""
    if type(pageVariables) ~= "string" or #pageVariables > variables.MAX_VARIABLE_BYTES then
        return nil, "invalid-variables"
    end

    local parts = { "AE3CTX1:", tostring(count), ":" }
    for index = 1, count do
        local layer = layers[index]
        if type(layer) ~= "table" or not identity.ValidateSyncId(layer.SyncId, "category") then
            return nil, "invalid-ancestor-sync-id"
        end
        if type(layer.Vars) ~= "string" or #layer.Vars > variables.MAX_VARIABLE_BYTES then
            return nil, "invalid-ancestor-variables"
        end
        AppendLengthPrefixed(parts, layer.SyncId)
        AppendLengthPrefixed(parts, layer.Vars)
    end
    AppendLengthPrefixed(parts, pageVariables)
    return table.concat(parts)
end

--- Merges ordered ancestor variables and page variables, then resolves references.
-- @tparam table layers Root-to-parent layers already validated or locally built.
-- @tparam string|nil pageVariables Raw page variable string.
-- @treturn table|nil merged
-- @treturn string|nil errorCode
function variables.MergeVariableLayers(layers, pageVariables)
    local count = DenseArrayLength(layers, variables.MAX_ANCESTOR_DEPTH)
    if not count then
        return nil, "invalid-ancestor-layers"
    end

    local parsedLayers = {}
    for index = 1, count do
        local layer = layers[index]
        if type(layer) ~= "table" then
            return nil, "invalid-ancestor-layers"
        end
        local parsed, parseError = ParseVariableString(layer.Vars)
        if not parsed then
            return nil, parseError
        end
        parsedLayers[index] = parsed
    end

    local parsedPage, pageError = ParseVariableString(pageVariables)
    if not parsedPage then
        return nil, pageError
    end

    local merged = {}
    local reservedKeys = {}
    local sourceRanks = {}
    for index = 1, count do
        local mergedLayer, mergeError =
            MergeParsedVariableLayer(merged, reservedKeys, sourceRanks, index, parsedLayers[index])
        if not mergedLayer then
            return nil, mergeError
        end
    end
    local mergedPage, mergePageError =
        MergeParsedVariableLayer(merged, reservedKeys, sourceRanks, count + 1, parsedPage)
    if not mergedPage then
        return nil, mergePageError
    end
    local rosterExpanded, rosterError = ExpandRaidRosterSnapshot(merged, sourceRanks)
    if not rosterExpanded then
        return nil, rosterError
    end
    local expanded, familyError = ExpandVariableFamilies(rosterExpanded, sourceRanks)
    if not expanded then
        return nil, familyError
    end
    return json.ResolveVariableReferences(
        expanded,
        nil,
        variables.MAX_RESOLVED_VARIABLE_BYTES,
        variables.MAX_VARIABLE_BYTES
    )
end

variables.META_VARIABLE_PREFIX = "$"

-- A render can merge every allowed ancestor layer plus the page layer. Every
-- reachable parsed table or entry requires source text, so the aggregate byte
-- ceiling is also a conservative ceiling for either graph dimension. The extra
-- slot accounts for the resolved root created after the source layers merge.
local MAX_PARTITION_SOURCE_BYTES = variables.MAX_RESOLVED_VARIABLE_BYTES
local MAX_PARTITION_TABLES = MAX_PARTITION_SOURCE_BYTES + 1
local MAX_PARTITION_ENTRIES = MAX_PARTITION_SOURCE_BYTES + 1

local function CloneVariableGraph(value)
    if type(value) ~= "table" or value == json.JSON_NULL then
        return value
    end

    local copies = {}
    local pending = {}
    local tableCount = 0
    local entryCount = 0

    local function QueueTable(source)
        if source == json.JSON_NULL then
            return source
        end

        local existing = copies[source]
        if existing then
            return existing
        end

        tableCount = tableCount + 1
        if tableCount > MAX_PARTITION_TABLES then
            return nil, "variables-too-complex"
        end

        local copy = {}
        copies[source] = copy
        pending[#pending + 1] = {
            Source = source,
            Copy = copy,
        }
        return copy
    end

    local root, rootError = QueueTable(value)
    if not root then
        return nil, rootError
    end

    while #pending > 0 do
        local work = pending[#pending]
        pending[#pending] = nil

        for key, entry in pairs(work.Source) do
            if type(key) == "table" then
                return nil, "invalid-variables"
            end

            entryCount = entryCount + 1
            if entryCount > MAX_PARTITION_ENTRIES then
                return nil, "variables-too-complex"
            end

            local copiedEntry = entry
            if type(entry) == "table" then
                local entryError
                copiedEntry, entryError = QueueTable(entry)
                if not copiedEntry then
                    return nil, entryError
                end
            end
            work.Copy[key] = copiedEntry
        end
    end

    return root
end

--- Reports whether a resolved variable key is reserved page metadata.
-- Metadata keys start with the `$` prefix and never enter display highlights.
-- @tparam any key Candidate variable key.
-- @treturn boolean isMeta
function variables.IsMetaVariableKey(key)
    return type(key) == "string" and key:sub(1, 1) == variables.META_VARIABLE_PREFIX
end

--- Splits resolved variables into public template values and `$` metadata.
-- Metadata keys are exposed with the prefix stripped; only empty stripped names
-- are dropped. The input table is never mutated. Returned values are deeply
-- detached while preserving shared references, cycles, and the JSON-null
-- sentinel used by the internal codec. Nested table keys are rejected because
-- parsed variable graphs only contain scalar keys.
-- @tparam table resolved Resolved variable map from `MergeVariableLayers`.
-- @treturn table|nil publicVariables
-- @treturn table|nil meta
-- @treturn string|nil errorCode
function variables.PartitionResolvedVariables(resolved)
    if type(resolved) ~= "table" then
        return nil, nil, "invalid-variables"
    end

    for key in pairs(resolved) do
        if type(key) ~= "string" then
            return nil, nil, "invalid-variables"
        end
    end

    local detached, cloneError = CloneVariableGraph(resolved)
    if not detached then
        return nil, nil, cloneError
    end

    local publicVariables = detached
    local meta = {}
    local metadataKeys = {}
    for key in pairs(publicVariables) do
        if variables.IsMetaVariableKey(key) then
            metadataKeys[#metadataKeys + 1] = key
        end
    end

    for index = 1, #metadataKeys do
        local key = metadataKeys[index]
        local value = publicVariables[key]
        publicVariables[key] = nil

        local metaKey = key:sub(2)
        if metaKey ~= "" then
            meta[metaKey] = value
        end
    end
    return publicVariables, meta
end
