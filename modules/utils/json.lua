-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/json.lua
--
-- JSON codec and variable parser.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.json = {}
local json = AngryEra.utils.json

local function skip_ws(str, pos)
	while true do
		local c = str:sub(pos, pos)
		if c == " " or c == "\t" or c == "\n" or c == "\r" then
			pos = pos + 1
		else
			break
		end
	end
	return pos
end

local function codepoint_to_utf8(codepoint)
	if codepoint <= 0x7F then
		return string.char(codepoint)
	elseif codepoint <= 0x7FF then
		local b1 = 0xC0 + math.floor(codepoint / 0x40)
		local b2 = 0x80 + (codepoint % 0x40)
		return string.char(b1, b2)
	elseif codepoint <= 0xFFFF then
		local b1 = 0xE0 + math.floor(codepoint / 0x1000)
		local b2 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
		local b3 = 0x80 + (codepoint % 0x40)
		return string.char(b1, b2, b3)
	end

	local b1 = 0xF0 + math.floor(codepoint / 0x40000)
	local b2 = 0x80 + (math.floor(codepoint / 0x1000) % 0x40)
	local b3 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
	local b4 = 0x80 + (codepoint % 0x40)
	return string.char(b1, b2, b3, b4)
end

local function parse_string(str, pos)
	local i = pos + 1
	local chunkStart = i
	local out = {}
	local outCount = 0
	local len = #str

	while i <= len do
		local c = str:sub(i, i)
		if c == "\"" then
			if i > chunkStart then
				outCount = outCount + 1
				out[outCount] = str:sub(chunkStart, i - 1)
			end
			return table.concat(out), i + 1
		end

		if c == "\\" then
			if i > chunkStart then
				outCount = outCount + 1
				out[outCount] = str:sub(chunkStart, i - 1)
			end

			local esc = str:sub(i + 1, i + 1)
			if esc == "" then
				return nil, i, "Unterminated escape sequence"
			end

			if esc == "\"" or esc == "\\" or esc == "/" then
				outCount = outCount + 1
				out[outCount] = esc
				i = i + 2
			elseif esc == "b" then
				outCount = outCount + 1
				out[outCount] = "\b"
				i = i + 2
			elseif esc == "f" then
				outCount = outCount + 1
				out[outCount] = "\f"
				i = i + 2
			elseif esc == "n" then
				outCount = outCount + 1
				out[outCount] = "\n"
				i = i + 2
			elseif esc == "r" then
				outCount = outCount + 1
				out[outCount] = "\r"
				i = i + 2
			elseif esc == "t" then
				outCount = outCount + 1
				out[outCount] = "\t"
				i = i + 2
			elseif esc == "u" then
				local hex = str:sub(i + 2, i + 5)
				if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
					return nil, i, "Invalid unicode escape"
				end

				local cp = tonumber(hex, 16)
				outCount = outCount + 1
				out[outCount] = codepoint_to_utf8(cp)
				i = i + 6
			else
				return nil, i, "Invalid escape sequence"
			end

			chunkStart = i
		else
			i = i + 1
		end
	end

	return nil, pos, "Unterminated String"
end

local function parse_number(str, pos)
	local i = pos

	if str:sub(i, i) == "-" then
		i = i + 1
	end

	local function is_digit(ch)
		return ch ~= "" and ch:match("%d") ~= nil
	end

	local ch = str:sub(i, i)
	if ch == "0" then
		i = i + 1
		if is_digit(str:sub(i, i)) then
			return nil, pos, "Invalid Number"
		end
	elseif is_digit(ch) then
		repeat
			i = i + 1
			ch = str:sub(i, i)
		until not is_digit(ch)
	else
		return nil, pos, "Invalid Number"
	end

	if str:sub(i, i) == "." then
		i = i + 1
		if not is_digit(str:sub(i, i)) then
			return nil, pos, "Invalid Number"
		end
		repeat
			i = i + 1
			ch = str:sub(i, i)
		until not is_digit(ch)
	end

	ch = str:sub(i, i)
	if ch == "e" or ch == "E" then
		i = i + 1
		ch = str:sub(i, i)
		if ch == "+" or ch == "-" then
			i = i + 1
		end
		if not is_digit(str:sub(i, i)) then
			return nil, pos, "Invalid Number"
		end
		repeat
			i = i + 1
			ch = str:sub(i, i)
		until not is_digit(ch)
	end

	local token = str:sub(pos, i - 1)
	local number = tonumber(token)
	if number == nil then
		return nil, pos, "Invalid Number"
	end

	return number, i
end

local parse_value
local JSON_NULL = {}
json.JSON_NULL = JSON_NULL
local MAX_JSON_NESTING = 256

local function parse_array(str, pos, depth)
	if depth > MAX_JSON_NESTING then
		return nil, pos, "Maximum JSON nesting exceeded"
	end

	local arr = {}
	pos = skip_ws(str, pos + 1)
	if str:sub(pos, pos) == "]" then
		return arr, pos + 1
	end

	local val, parseError
	while true do
		val, pos, parseError = parse_value(str, pos, depth + 1)
		if parseError then
			return nil, pos, parseError
		end
		table.insert(arr, val)
		pos = skip_ws(str, pos)
		if str:sub(pos, pos) == "]" then
			return arr, pos + 1
		end
		if str:sub(pos, pos) ~= "," then
			return nil, pos, "Expected ',' or ']'"
		end
		pos = skip_ws(str, pos + 1)
	end
end

local function parse_obj_impl(str, pos, depth)
	if depth > MAX_JSON_NESTING then
		return nil, pos, "Maximum JSON nesting exceeded"
	end

	local obj = {}
	pos = skip_ws(str, pos + 1)
	if str:sub(pos, pos) == "}" then
		return obj, pos + 1
	end

	local key, val, parseError
	while true do
		if str:sub(pos, pos) ~= "\"" then
			return nil, pos, "Expected String Key"
		end
		key, pos, parseError = parse_string(str, pos)
		if parseError then
			return nil, pos, parseError
		end
		pos = skip_ws(str, pos)
		if str:sub(pos, pos) ~= ":" then
			return nil, pos, "Expected ':'"
		end
		pos = skip_ws(str, pos + 1)

		val, pos, parseError = parse_value(str, pos, depth + 1)
		if parseError then
			return nil, pos, parseError
		end
		obj[key] = val

		pos = skip_ws(str, pos)
		if str:sub(pos, pos) == "}" then
			return obj, pos + 1
		end
		if str:sub(pos, pos) ~= "," then
			return nil, pos, "Expected ',' or '}'"
		end
		pos = skip_ws(str, pos + 1)
	end
end

parse_value = function(str, pos, depth)
	depth = depth or 0
	pos = skip_ws(str, pos)
	local char = str:sub(pos, pos)
	if char == "{" then
		return parse_obj_impl(str, pos, depth)
	end
	if char == "[" then
		return parse_array(str, pos, depth)
	end
	if char == "\"" then
		return parse_string(str, pos)
	end
	if (char >= "0" and char <= "9") or char == "-" then
		return parse_number(str, pos)
	end
	if str:sub(pos, pos + 3) == "true" then
		return true, pos + 4
	end
	if str:sub(pos, pos + 4) == "false" then
		return false, pos + 5
	end
	if str:sub(pos, pos + 3) == "null" then
		return JSON_NULL, pos + 4
	end
	return nil, pos, "Syntax Error"
end

function json.JSON_TryDecode(str)
	if type(str) ~= "string" or str == "" then
		return nil
	end

	local success, value, pos, parseError = pcall(function()
		local decodedValue, nextPos, err = parse_value(str, 1)
		return decodedValue, nextPos, err
	end)

	if not success or parseError then
		return nil
	end

	if not pos then
		return nil
	end

	local nextPos = skip_ws(str, pos)
	if nextPos <= #str then
		return nil
	end

	return value
end

function json.JSON_Decode(str)
	local decoded = json.JSON_TryDecode(str)
	if decoded ~= nil then
		return decoded
	end
	return {}
end

local function encode_json_string(value)
	value = value:gsub("\\", "\\\\")
	value = value:gsub("\"", "\\\"")
	value = value:gsub("\n", "\\n")
	value = value:gsub("\r", "\\r")
	value = value:gsub("\t", "\\t")
	return "\"" .. value .. "\""
end

local function encode_json_value(value)
	if value == JSON_NULL then
		return "null"
	end

	local valueType = type(value)
	if valueType == "string" then
		return encode_json_string(value)
	end
	if valueType == "number" then
		return tostring(value)
	end
	if valueType == "boolean" then
		return tostring(value)
	end
	if valueType == "table" then
		local parts = {}
		local isArray = (value[1] ~= nil or next(value) == nil)
		for key in pairs(value) do
			if type(key) ~= "number" then
				isArray = false
				break
			end
		end

		if isArray then
			for _, element in ipairs(value) do
				table.insert(parts, encode_json_value(element))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end

		local keys = {}
		for key in pairs(value) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)

		for _, key in ipairs(keys) do
			local encodedKey = encode_json_string(tostring(key))
			table.insert(parts, string.format("%s:%s", encodedKey, encode_json_value(value[key])))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end

	return "null"
end

function json.JSON_Encode(value)
	return encode_json_value(value)
end

function json.ParseVariables(str)
	if not str or str == "" then
		return {}
	end

	if str:find("^%s*[{[]") then
		return json.JSON_Decode(str)
	end

	local obj = {}
	for line in str:gmatch("[^\r\n]+") do
		local key, val = line:match("^([^=]+)=(.*)")
		if key then
			key = key:match("^%s*(.-)%s*$")
			val = val:match("^%s*(.-)%s*$")
			if key ~= "" then
				obj[key] = val
				local n = tonumber(val)
				if n then
					obj[key] = n
				end
				if val == "true" then
					obj[key] = true
				elseif val == "false" then
					obj[key] = false
				end
			end
		end
	end
	return obj
end

