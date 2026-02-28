-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/helpers.lua
--
-- Shared pure-utility functions.
-- -------------------------------------------------------------------------------

local _, app = ...

app.utils = app.utils or {}
app.utils.helpers = {}
local helpers = app.utils.helpers

local _player_realm = nil

function helpers.EnsureUnitFullName(unit)
	if not _player_realm then
		_player_realm = select(2, UnitFullName("player"))
	end
	if unit and not unit:find("-") then
		unit = unit .. "-" .. _player_realm
	end
	return unit
end

function helpers.EnsureUnitShortName(unit)
	if not _player_realm then
		_player_realm = select(2, UnitFullName("player"))
	end
	local name, realm = strsplit("-", unit, 2)
	if not realm or realm == _player_realm then
		return name
	else
		return unit
	end
end

function helpers.PlayerFullName()
	if not _player_realm then
		_player_realm = select(2, UnitFullName("player"))
	end
	return UnitName("player") .. "-" .. _player_realm
end

function helpers.IterateGroupMembers(callback)
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local rawName, rank, subgroup, _, _, class, _, online, isDead = GetRaidRosterInfo(i)
			if rawName then
				local fullName = helpers.EnsureUnitFullName(rawName)
				if callback(rawName, fullName, rank or 0, subgroup or 1, class, online ~= false, isDead == true, "raid" .. i) then
					return
				end
			end
		end
		return
	end

	if IsInGroup() then
		local function emit(unitToken)
			if not UnitExists(unitToken) then
				return false
			end

			local rawName = UnitName(unitToken)
			if not rawName then
				return false
			end

			local fullName = helpers.EnsureUnitFullName(rawName)
			local _, class = UnitClass(unitToken)
			local rank = 0
			if UnitIsGroupLeader(unitToken) then
				rank = 2
			elseif UnitIsGroupAssistant and UnitIsGroupAssistant(unitToken) then
				rank = 1
			end

			return callback(rawName, fullName, rank, 1, class, UnitIsConnected(unitToken), UnitIsDeadOrGhost(unitToken), unitToken)
		end

		if emit("player") then
			return
		end

		for i = 1, GetNumSubgroupMembers() do
			if emit("party" .. i) then
				return
			end
		end
	end
end

function helpers.IsCategoryDescendant(categoryId, ancestorId)
	if not categoryId or not ancestorId then
		return false
	end

	local currentId = categoryId
	local seen = {}
	while currentId do
		if currentId == ancestorId then
			return true
		end
		if seen[currentId] then
			return false
		end
		seen[currentId] = true
		local category = AngryAssign_Categories[currentId]
		currentId = category and category.CategoryId or nil
	end

	return false
end

function helpers.selectedLastValue(input)
	local a = select(-1, strsplit("", input or ""))
	return tonumber(a)
end

function helpers.tReverse(tbl)
	for i = 1, math.floor(#tbl / 2) do
		tbl[i], tbl[#tbl - i + 1] = tbl[#tbl - i + 1], tbl[i]
	end
end

function helpers.ValidateString(str, maxLength, fieldName)
	if type(str) ~= "string" then
		return ""
	end
	if #str > maxLength then
		str = string.sub(str, 1, maxLength)
	end
	str = string.gsub(str, "|[Tt]", "!")
	return str
end

function helpers.ExtractAndValidateName(nameOrFrame)
	local text

	if type(nameOrFrame) == "table" then
		local editBox = nameOrFrame.editBox or nameOrFrame.wideEditBox or nameOrFrame.EditBox
		if not editBox and nameOrFrame.GetText then
			editBox = nameOrFrame
		end

		if not editBox then
			return nil, "Could not find input box."
		end
		text = editBox:GetText()
	else
		text = nameOrFrame
	end

	if type(text) ~= "string" then
		return nil, "Invalid name format."
	end

	local cleanName = text:match("^%s*(.-)%s*$")

	if cleanName == "" then
		return nil, "Name cannot be empty."
	end

	return cleanName
end
