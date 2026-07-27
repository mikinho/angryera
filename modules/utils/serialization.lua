-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/serialization.lua
--
-- Encode/decode logic for AA import/export strings. No UI.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.serialization = {}
local serialization = AngryEra.utils.serialization

local libS = app.libs.libS
local libD = app.libs.libD
local core = AngryEra.core
local boundedDeflate = AngryEra.utils.boundedDeflate
local DEFAULT_MAX_VARIABLE_BYTES = 5000

local function ValidateVariablesIncluded(data, path)
    if data.VariablesIncluded ~= nil and type(data.VariablesIncluded) ~= "boolean" then
        return false, path .. ".VariablesIncluded must be a boolean when provided."
    end
    return true
end

local function ValidateVariableSource(data, path)
    if data.Vars == nil then
        return true
    end
    if type(data.Vars) ~= "string" then
        return false, path .. ".Vars must be a string when provided."
    end

    local variableUtils = AngryEra.utils and AngryEra.utils.variables
    local maximumBytes = variableUtils and variableUtils.MAX_VARIABLE_BYTES or DEFAULT_MAX_VARIABLE_BYTES
    if #data.Vars > maximumBytes then
        return false, path .. ".Vars exceeds the maximum variable size."
    end
    if variableUtils and type(variableUtils.MergeVariableLayers) == "function" then
        local resolved, variableError = variableUtils.MergeVariableLayers({}, data.Vars)
        if not resolved then
            return false, path .. ".Vars is invalid (" .. tostring(variableError or "invalid-variables") .. ")."
        end
    end
    return true
end

local function ValidateEncodedPagePayload(data, path)
    if type(data) ~= "table" then
        return false, path .. " must be a table."
    end
    local valid, validationError = ValidateVariablesIncluded(data, path)
    if not valid then
        return false, validationError
    end
    if type(data.Name) ~= "string" or data.Name:match("^%s*$") then
        return false, path .. ".Name must be a non-empty string."
    end
    if type(data.Contents) ~= "string" then
        return false, path .. ".Contents must be a string."
    end
    valid, validationError = ValidateVariableSource(data, path)
    if not valid then
        return false, validationError
    end
    return true
end

serialization.ValidateEncodedPagePayload = ValidateEncodedPagePayload

local MAX_CATEGORY_DEPTH = 32

local ValidateEncodedCategoryPayload
ValidateEncodedCategoryPayload = function(data, path, state)
    if type(data) ~= "table" then
        return false, path .. " must be a table."
    end
    state = state or {
        depth = 0,
        seen = {},
    }
    if state.seen[data] then
        return false, path .. " contains a repeated or cyclic category."
    end
    if state.depth >= MAX_CATEGORY_DEPTH then
        return false, path .. " exceeds the maximum category depth."
    end
    state.seen[data] = true

    local valid, validationError = ValidateVariablesIncluded(data, path)
    if not valid then
        return false, validationError
    end
    if type(data.Name) ~= "string" or data.Name:match("^%s*$") then
        return false, path .. ".Name must be a non-empty string."
    end
    if type(data.Children) ~= "table" then
        return false, path .. ".Children must be a table."
    end
    valid, validationError = ValidateVariableSource(data, path)
    if not valid then
        return false, validationError
    end

    local childCount = 0
    local highestChildIndex = 0
    for key in pairs(data.Children) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false, path .. ".Children must be an array."
        end
        childCount = childCount + 1
        if key > highestChildIndex then
            highestChildIndex = key
        end
    end
    if childCount ~= highestChildIndex then
        return false, path .. ".Children must be a dense array."
    end

    for index, child in ipairs(data.Children) do
        local childPath = string.format("%s.Children[%d]", path, index)
        local childType = child and child.Type
        if
            childType == "Category" or (childType == nil and type(child) == "table" and type(child.Children) == "table")
        then
            local ok, err = ValidateEncodedCategoryPayload(child, childPath, {
                depth = state.depth + 1,
                seen = state.seen,
            })
            if not ok then
                return false, err
            end
        elseif
            childType == "Page" or (childType == nil and type(child) == "table" and type(child.Contents) == "string")
        then
            local ok, err = ValidateEncodedPagePayload(child, childPath)
            if not ok then
                return false, err
            end
        else
            return false, childPath .. " has an invalid Type value."
        end
    end

    return true
end

serialization.ValidateEncodedCategoryPayload = ValidateEncodedCategoryPayload

function serialization.ParseImportString(str)
    if type(str) ~= "string" then
        return false, "Import text must be a string"
    end
    str = str:match("^%s*(.-)%s*$")
    local prefix, version, encoded
    if str:match("^AA:Page:(%d+):") then
        prefix, version, encoded = "Page", str:match("^AA:Page:(%d+):(.*)$")
    elseif str:match("^AA:Category:(%d+):") then
        prefix, version, encoded = "Category", str:match("^AA:Category:(%d+):(.*)$")
    else
        return false, "Not a valid AA export string"
    end

    if version ~= "1" and version ~= "2" then
        return false, "Unsupported export version: " .. tostring(version)
    end
    if not encoded or encoded == "" then
        return false, "Missing encoded payload"
    end
    if #encoded > core.MAX_IMPORT_ENCODED_BYTES then
        return false, "Import payload is too large"
    end

    local compressed = libD:DecodeForPrint(encoded)
    if not compressed then
        return false, "Decode failed"
    end
    if #compressed > core.MAX_IMPORT_DECODED_BYTES then
        return false, "Decoded import payload is too large"
    end
    local serialized, trailingOrError = boundedDeflate.DecompressDeflate(compressed, core.MAX_IMPORT_SERIALIZED_BYTES)
    if not serialized then
        if trailingOrError == "output-too-large" then
            return false, "Decompressed import payload is too large"
        end
        return false, "Decompress failed: " .. (trailingOrError or "?")
    end
    if trailingOrError ~= 0 then
        return false, "Decompress failed: trailing data"
    end
    local ok, data = libS:Deserialize(serialized)
    if not ok then
        return false, "Deserialize failed"
    end

    if prefix == "Page" then
        local valid, validationError = ValidateEncodedPagePayload(data, "Page")
        if not valid then
            return false, validationError
        end
    elseif prefix == "Category" then
        local valid, validationError = ValidateEncodedCategoryPayload(data, "Category")
        if not valid then
            return false, validationError
        end
    end
    if version == "1" and data.VariablesIncluded == false then
        return false, "Export version 1 cannot omit variables and metadata"
    end
    if version == "2" and data.VariablesIncluded ~= false then
        return false, "Export version 2 must omit variables and metadata"
    end

    return true, data, prefix
end

function serialization.EncodeExportString(data, dataType)
    local serialized = libS:Serialize(data)
    local compressed = libD:CompressDeflate(serialized)
    local encoded = libD:EncodeForPrint(compressed)
    local version = data.VariablesIncluded == false and "2" or "1"
    return "AA:" .. dataType .. ":" .. version .. ":" .. encoded
end

local function IncludeVariables(options)
    return type(options) ~= "table" or options.includeVariables ~= false
end

function serialization.GetPageExportData(page, options)
    if type(page) ~= "table" then
        return nil
    end
    local includeVariables = IncludeVariables(options)
    local data = {
        Name = page.Name,
        Contents = page.Contents,
    }
    -- Legacy v1 payloads are complete exports, so only an explicit omission
    -- needs a marker. Keeping full payloads unchanged preserves compatibility.
    if not includeVariables then
        data.VariablesIncluded = false
    end
    if includeVariables and page.Vars and page.Vars ~= "" and page.Vars ~= "{}" then
        data.Vars = page.Vars
    end
    local valid, validationError = ValidateEncodedPagePayload(data, "Page")
    if not valid then
        return nil, validationError
    end
    return data
end

local function BuildCategoryExportData(self, catId, includeVariables, state)
    state = state or {
        depth = 0,
        seen = {},
    }
    if state.seen[catId] then
        return nil, "category-cycle"
    end
    if state.depth >= MAX_CATEGORY_DEPTH then
        return nil, "category-depth-exceeded"
    end
    state.seen[catId] = true

    local cat = self:GetCat(catId)
    if not cat then
        return nil
    end

    local data = { Type = "Category", Name = cat.Name, Children = {} }
    if includeVariables and cat.Vars and cat.Vars ~= "" and cat.Vars ~= "{}" then
        data.Vars = cat.Vars
    end

    local entries = {}
    for _, p in pairs(AngryAssign_Pages) do
        if p.CategoryId == catId then
            local pageData = { Type = "Page", Name = p.Name, Contents = p.Contents, Index = p.Index or 0 }
            if includeVariables and p.Vars and p.Vars ~= "" and p.Vars ~= "{}" then
                pageData.Vars = p.Vars
            end
            table.insert(entries, pageData)
        end
    end
    for _, c in pairs(AngryAssign_Categories) do
        if c.CategoryId == catId then
            local childCatData, childError = BuildCategoryExportData(self, c.Id, includeVariables, {
                depth = state.depth + 1,
                seen = state.seen,
            })
            if not childCatData then
                return nil, childError
            end
            childCatData.Index = c.Index or 0
            table.insert(entries, childCatData)
        end
    end

    table.sort(entries, function(a, b)
        local ia = a.Index or 0
        local ib = b.Index or 0
        if ia == ib then
            return a.Name < b.Name
        end
        return ia < ib
    end)

    data.Children = entries
    return data
end

function serialization.GetCategoryExportData(self, catId, options)
    local includeVariables = IncludeVariables(options)
    local data, exportError = BuildCategoryExportData(self, catId, includeVariables)
    -- One root marker applies to the complete recursive export.
    if data and not includeVariables then
        data.VariablesIncluded = false
    end
    if data then
        local valid, validationError = ValidateEncodedCategoryPayload(data, "Category")
        if not valid then
            return nil, validationError
        end
    end
    return data, exportError
end
