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

local function AppendLengthPrefixed(parts, value)
    parts[#parts + 1] = tostring(#value)
    parts[#parts + 1] = ":"
    parts[#parts + 1] = value
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
    for index = 1, count do
        for key, value in pairs(parsedLayers[index]) do
            merged[key] = value
        end
    end
    for key, value in pairs(parsedPage) do
        merged[key] = value
    end
    return json.ResolveVariableReferences(merged)
end
