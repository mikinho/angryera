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

local function ValidateEncodedPagePayload(data, path)
    if type(data) ~= "table" then
        return false, path .. " must be a table."
    end
    if type(data.Name) ~= "string" or data.Name:match("^%s*$") then
        return false, path .. ".Name must be a non-empty string."
    end
    if type(data.Contents) ~= "string" then
        return false, path .. ".Contents must be a string."
    end
    if data.Vars ~= nil and type(data.Vars) ~= "string" then
        return false, path .. ".Vars must be a string when provided."
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

    if type(data.Name) ~= "string" or data.Name:match("^%s*$") then
        return false, path .. ".Name must be a non-empty string."
    end
    if type(data.Children) ~= "table" then
        return false, path .. ".Children must be a table."
    end
    if data.Vars ~= nil and type(data.Vars) ~= "string" then
        return false, path .. ".Vars must be a string when provided."
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

    if version ~= "1" then
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

    return true, data, prefix
end

function serialization.EncodeExportString(data, dataType)
    local serialized = libS:Serialize(data)
    local compressed = libD:CompressDeflate(serialized)
    local encoded = libD:EncodeForPrint(compressed)
    return "AA:" .. dataType .. ":1:" .. encoded
end

function serialization.GetCategoryExportData(self, catId, state)
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
    if cat.Vars and cat.Vars ~= "" and cat.Vars ~= "{}" then
        data.Vars = cat.Vars
    end

    local entries = {}
    for _, p in pairs(AngryAssign_Pages) do
        if p.CategoryId == catId then
            local pageData = { Type = "Page", Name = p.Name, Contents = p.Contents, Index = p.Index or 0 }
            if p.Vars and p.Vars ~= "" and p.Vars ~= "{}" then
                pageData.Vars = p.Vars
            end
            table.insert(entries, pageData)
        end
    end
    for _, c in pairs(AngryAssign_Categories) do
        if c.CategoryId == catId then
            local childCatData, childError = serialization.GetCategoryExportData(self, c.Id, {
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
