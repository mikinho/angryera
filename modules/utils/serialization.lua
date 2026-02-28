-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/serialization.lua
--
-- Encode/decode logic for AA import/export strings. No UI.
-- -------------------------------------------------------------------------------

local _, app = ...

app.utils = app.utils or {}
app.utils.serialization = {}
local serialization = app.utils.serialization

local libS = app.libS
local libD = app.libD
local libC = app.libC
local core = app.core

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

local ValidateEncodedCategoryPayload
ValidateEncodedCategoryPayload = function(data, path)
	if type(data) ~= "table" then
		return false, path .. " must be a table."
	end
	if type(data.Name) ~= "string" or data.Name:match("^%s*$") then
		return false, path .. ".Name must be a non-empty string."
	end
	if type(data.Children) ~= "table" then
		return false, path .. ".Children must be a table."
	end

	for key in pairs(data.Children) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false, path .. ".Children must be an array."
		end
	end

	for index, child in ipairs(data.Children) do
		local childPath = string.format("%s.Children[%d]", path, index)
		local childType = child and child.Type
		if childType == "Category" or (childType == nil and type(child) == "table" and type(child.Children) == "table") then
			local ok, err = ValidateEncodedCategoryPayload(child, childPath)
			if not ok then
				return false, err
			end
		elseif childType == "Page" or (childType == nil and type(child) == "table" and type(child.Contents) == "string") then
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
	local serialized, err = libD:DecompressDeflate(compressed)
	if not serialized then
		return false, "Decompress failed: " .. (err or "?")
	end
	if #serialized > core.MAX_IMPORT_SERIALIZED_BYTES then
		return false, "Decompressed import payload is too large"
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

function serialization.GetCategoryExportData(self, catId)
	local cat = self:GetCat(catId)
	if not cat then
		return nil
	end

	local data = { Type = "Category", Name = cat.Name, Children = {} }

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
			local childCatData = serialization.GetCategoryExportData(self, c.Id)
			if childCatData then
				childCatData.Index = c.Index or 0
				table.insert(entries, childCatData)
			end
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
