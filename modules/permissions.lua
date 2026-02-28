-- -------------------------------------------------------------------------------
-- Angry Era: modules/permissions.lua
--
-- Permission system: officer rank, valid-raid checks, sender permission checks.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryAssign = app.AngryAssign
local helpers = app.utils.helpers
local EnsureUnitFullName = helpers.EnsureUnitFullName
local PlayerFullName = helpers.PlayerFullName
local IterateGroupMembers = helpers.IterateGroupMembers

local guildOfficerNames = nil
local warnedPermission = false

--- Resets the one-time permission warning flag.
function AngryAssign:ResetPermissionWarning()
	warnedPermission = false
end

--- Prints a one-time warning when an inbound update fails permission checks.
-- @tparam string sender Sender unit name.
function AngryAssign:PermissionCheckFailError(sender)
	if not warnedPermission then
		self:Print( RED_FONT_COLOR_CODE .. "You have received a page update from "..Ambiguate(sender, "none").." that was rejected due to insufficient permissions. If you wish to see this page, please adjust your permission settings.|r" )
		warnedPermission = true
	end
end

function AngryAssign:IsGuildOfficer(player)
	if not player then
		return false
	end
	local fullplayer = EnsureUnitFullName(player)

	if guildOfficerNames == nil then
		self:UpdateOfficerRank()
	end

	return guildOfficerNames[fullplayer]
end

function AngryAssign:ResetOfficerRank()
	guildOfficerNames = nil
end

function AngryAssign:UpdateOfficerRank()
	guildOfficerNames = {}

	if not (C_Club and C_Club.GetGuildClubId and CommunitiesUtil and CommunitiesUtil.GetMemberIdsSortedByName and CommunitiesUtil.GetMemberInfo and Enum and Enum.ClubRoleIdentifier) then
		return guildOfficerNames
	end

	local okClub, clubId = pcall(C_Club.GetGuildClubId)
	if not okClub or not clubId then
		return guildOfficerNames
	end

	local okMemberIds, memberIds = pcall(CommunitiesUtil.GetMemberIdsSortedByName, clubId, nil)
	if not okMemberIds or type(memberIds) ~= "table" then
		return guildOfficerNames
	end

	local okMembers, allMemberList = pcall(CommunitiesUtil.GetMemberInfo, clubId, memberIds)
	if not okMembers or type(allMemberList) ~= "table" then
		return guildOfficerNames
	end

	local clubRoles = Enum.ClubRoleIdentifier
	for _, memberInfo in ipairs(allMemberList) do
		if type(memberInfo) == "table" and memberInfo.name and (memberInfo.role == clubRoles.Owner or memberInfo.role == clubRoles.Leader or memberInfo.role == clubRoles.Moderator) then
			guildOfficerNames[EnsureUnitFullName(memberInfo.name)] = true
		end
	end

	return guildOfficerNames
end

function AngryAssign:IsPlayerRaidLeader()
	local leader = self:GetRaidLeader()
	return leader and PlayerFullName() == EnsureUnitFullName(leader)
end

function AngryAssign:IsGuildRaid()
	local leader = self:GetRaidLeader()

	if self:IsGuildOfficer(leader) then
		return true
	end

	return false
end

--- Returns whether the configured leader/officer rules allow modifications.
-- @treturn boolean valid
function AngryAssign:IsValidRaid()
	if self:GetConfig("allowall") then
		return true
	end

	local leader = self:GetRaidLeader()

	if self:IsGuildOfficer(leader) then
		return true
	end

	for token in string.gmatch( AngryAssign:GetConfig("allowplayers") , "[^%s!#$%%&()*+,./:;<=>?@\\^_{|}~%[%]]+") do
		if leader and EnsureUnitFullName(token):lower() == EnsureUnitFullName(leader):lower() then
			return true
		end
	end

	if self:IsPlayerRaidLeader() then
		return true
	end

	return false
end

--- Checks whether a sender is allowed to modify page/display state.
-- @tparam[opt] string sender Sender full name, defaults to current player.
-- @treturn boolean allowed
function AngryAssign:PermissionCheck(sender)
	if not sender then
		sender = PlayerFullName()
	end

	if (IsInRaid() or IsInGroup()) then
		local senderFullName = EnsureUnitFullName(sender)
		local isLeaderOrAssistant = false
		IterateGroupMembers(function(_, fullName, rank)
			if fullName == senderFullName then
				isLeaderOrAssistant = (rank == 2 or rank == 1)
				return true
			end
			return false
		end)
		return isLeaderOrAssistant and self:IsValidRaid()
	else
		return sender == PlayerFullName()
	end
end


function AngryAssign:PermissionsUpdated()
	self:UpdateSelected()
	if app._comStarted then
		self:SendRequestDisplay()
	end
	if (IsInRaid() or IsInGroup()) and not self:IsValidRaid() then
		self:ClearDisplayed()
	end
end
