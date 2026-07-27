-- -------------------------------------------------------------------------------
-- Angry Era: modules/permissions.lua
--
-- Sender authorization, receiver policy, and local editing boundaries.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local helpers = AngryEra.utils.helpers
local EnsureUnitFullName = helpers.EnsureUnitFullName
local PlayerFullName = helpers.PlayerFullName
local IterateGroupMembers = helpers.IterateGroupMembers

local PERMISSION_POLICY_VERSION = 1
local guildOfficerNames
local guildMemberNames

local NORMAL_ACTIONS = {
    categoryUpsert = true,
    reorder = true,
    changeProposal = true,
}

local LEADER_ONLY_ACTIONS = {
    display = true,
    pageUpsert = true,
    changeResult = true,
    manifest = true,
    delete = true,
    tombstone = true,
    cleanup = true,
    scopeMove = true,
}

local NON_MUTATING_ACTIONS = {
    version = true,
    request = true,
    acknowledgement = true,
}

AngryEra.permissionActions = {
    normal = NORMAL_ACTIONS,
    leaderOnly = LEADER_ONLY_ACTIONS,
    nonMutating = NON_MUTATING_ACTIONS,
}

local function IsGrouped()
    return IsInRaid() or IsInGroup()
end

local function NormalizePlayerName(player)
    if type(player) ~= "string" or player == "" then
        return nil
    end
    local fullName = EnsureUnitFullName(player)
    return fullName and fullName:lower()
end

local function IsKnownAction(action)
    return NORMAL_ACTIONS[action] or LEADER_ONLY_ACTIONS[action] or NON_MUTATING_ACTIONS[action]
end

--- Rebuilds the receiver-local set of guild officers and higher roles.
-- Missing or unavailable guild APIs intentionally produce an empty set.
-- @treturn table officerNames
function AngryEra:UpdateOfficerRank()
    guildOfficerNames = {}
    guildMemberNames = {}

    if
        not (
            C_Club
            and C_Club.GetGuildClubId
            and CommunitiesUtil
            and CommunitiesUtil.GetMemberIdsSortedByName
            and CommunitiesUtil.GetMemberInfo
            and Enum
            and Enum.ClubRoleIdentifier
        )
    then
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
        if type(memberInfo) == "table" and memberInfo.name then
            local normalizedName = NormalizePlayerName(memberInfo.name)
            if normalizedName then
                guildMemberNames[normalizedName] = true
                if
                    memberInfo.role == clubRoles.Owner
                    or memberInfo.role == clubRoles.Leader
                    or memberInfo.role == clubRoles.Moderator
                then
                    guildOfficerNames[normalizedName] = true
                end
            end
        end
    end

    return guildOfficerNames
end

--- Clears the cached guild officer roster.
function AngryEra:ResetOfficerRank()
    guildOfficerNames = nil
    guildMemberNames = nil
end

--- Returns whether a player is a guild officer or higher on this receiver.
function AngryEra:IsGuildOfficer(player)
    local normalizedName = NormalizePlayerName(player)
    if not normalizedName then
        return false
    end
    if guildOfficerNames == nil then
        self:UpdateOfficerRank()
    end
    return guildOfficerNames[normalizedName] == true
end

--- Returns whether a player belongs to this installation's guild roster.
function AngryEra:IsGuildMember(player)
    local normalizedName = NormalizePlayerName(player)
    if not normalizedName then
        return false
    end
    if guildMemberNames == nil then
        self:UpdateOfficerRank()
    end
    return guildMemberNames[normalizedName] == true
end

--- Returns the current group role for a player.
-- @treturn string role `"leader"`, `"assistant"`, `"member"`, or `"absent"`.
function AngryEra:GetGroupRole(player)
    local normalizedName = NormalizePlayerName(player)
    if not normalizedName then
        return "absent"
    end

    if not IsGrouped() then
        return normalizedName == NormalizePlayerName(PlayerFullName()) and "leader" or "absent"
    end

    local role = "absent"
    IterateGroupMembers(function(_, fullName, rank)
        if NormalizePlayerName(fullName) == normalizedName then
            if rank == 2 then
                role = "leader"
            elseif rank == 1 then
                role = "assistant"
            else
                role = "member"
            end
            return true
        end
        return false
    end)
    return role
end

--- Returns whether a player is directly trusted by receiver-local configuration.
function AngryEra:IsDirectlyAllowlisted(player)
    local normalizedName = NormalizePlayerName(player)
    if not normalizedName then
        return false
    end

    local configured = self:GetConfig("trustedPublishers")
    if type(configured) ~= "string" then
        return false
    end
    for token in configured:gmatch("[^,%s;]+") do
        if NormalizePlayerName(token) == normalizedName then
            return true
        end
    end
    return false
end

--- Returns whether a current raid assistant satisfies the local qualified-
-- assistant policy. The role requirement is intentionally part of this helper
-- so local actions cannot accidentally treat an officer without assist as
-- authorized.
-- @tparam string player Player name.
-- @treturn boolean qualified
function AngryEra:IsQualifiedAssistant(player)
    return self:GetGroupRole(player) == "assistant"
        and (
            self:GetConfig("allowAllAssistants") == true
            or self:IsDirectlyAllowlisted(player)
            or self:IsGuildOfficer(player)
        )
end

--- Returns whether this receiver accepts an action from the authenticated sender.
-- @tparam string sender AceComm sender name.
-- @tparam string action Permission action.
-- @treturn boolean allowed
function AngryEra:CanReceiveFrom(sender, action)
    if not IsKnownAction(action) then
        return false
    end

    local role = self:GetGroupRole(sender)
    if role == "absent" then
        return false
    end
    if NON_MUTATING_ACTIONS[action] then
        return true
    end

    local receiveMode = self:GetConfig("receiveMode")
    if receiveMode == "ignoreShared" then
        return false
    end
    if receiveMode ~= "standard" and receiveMode ~= "leaderOnly" then
        return role == "leader"
    end
    if receiveMode == "leaderOnly" or LEADER_ONLY_ACTIONS[action] then
        return role == "leader"
    end
    if role == "leader" then
        return true
    end
    return role == "assistant" and self:IsQualifiedAssistant(sender)
end

--- Returns whether the local player may publish an action to the current group.
-- Receiver-local trust cannot prove whether another installation has allowlisted
-- this player. Assistants may attempt normal changes; every receiver still
-- enforces CanReceiveFrom independently.
function AngryEra:CanLocalPlayerPublish(action)
    if not IsKnownAction(action) or NON_MUTATING_ACTIONS[action] then
        return false
    end
    if not IsGrouped() then
        return true
    end

    local player = PlayerFullName()
    local role = self:GetGroupRole(player)
    if LEADER_ONLY_ACTIONS[action] then
        return role == "leader"
    end
    if role == "leader" then
        return true
    end
    return role == "assistant"
end

--- Returns whether the local player may broadcast a version-check query.
-- Version discovery is diagnostic. Raid/party leaders and raid assistants may
-- run it; it never selects or mutates the shared display. Solo players resolve
-- to the leader role, so the send later fails on channel selection instead.
-- @treturn boolean allowed
function AngryEra:CanLocalPlayerQueryVersions()
    local role = self:GetGroupRole(PlayerFullName())
    return role == "leader" or role == "assistant"
end

--- Returns whether the local player may output assignments to group chat.
-- Chat output does not select the shared display. Raid/party leaders and raid
-- assistants may output; ordinary members may not.
function AngryEra:CanLocalPlayerOutput()
    if not IsGrouped() then
        return true
    end
    local role = self:GetGroupRole(PlayerFullName())
    return role == "leader" or role == "assistant"
end

--- Returns whether the local player may rearrange raid subgroups from a
-- resolved layout. Leaders are always allowed. Assistants must satisfy the
-- same officer/trusted/allow-all policy used for shared page proposals, which
-- prevents a broadly granted raid assist from enabling this action by default.
-- @treturn boolean allowed
function AngryEra:CanLocalPlayerApplyRaidLayout()
    if not IsInRaid() then
        return false
    end

    local player = PlayerFullName()
    local role = self:GetGroupRole(player)
    if role == "leader" then
        return true
    end
    if role ~= "assistant" then
        return false
    end
    if self:GetConfig("allowAllAssistants") == true or self:IsDirectlyAllowlisted(player) then
        return true
    end

    -- Officer status qualifies by default only when the current raid leader is
    -- in the same local guild roster. Without this check, an officer from an
    -- unrelated guild in a pug could gain the action merely by receiving assist.
    local leader = type(self.GetRaidLeader) == "function" and self:GetRaidLeader() or nil
    return leader ~= nil and self:IsGuildMember(leader) and self:IsGuildOfficer(player)
end

--- Returns whether an entity may be edited locally or proposed to the leader.
-- Unsynchronized and locally owned entities remain locally editable. A
-- remote-owned page is editable only while its exact canonical tuple is the
-- active shared display; cached background pages fail closed. Remote category
-- name/variable editing waits for the future hierarchy-proposal protocol, while
-- receiver-private CategoryId/Index placement remains a separate local action.
-- Only the leader publishes the resulting canonical page revision.
function AngryEra:CanEditEntityLocally(entity)
    if not entity then
        return false
    end
    if not entity.SyncId or self:IsLocallyOwned(entity) then
        return true
    end

    -- CHANGE_PROPOSE currently carries page fields only. Treat synchronized
    -- remote categories as read-only until hierarchy proposals have their own
    -- schema rather than mutating canonical-looking fields receiver-locally.
    if rawget(entity, "Contents") == nil then
        return false
    end
    if type(self.HasAuthoritativePageContext) ~= "function" then
        return false
    end

    local contextChecked, contextAvailable = pcall(self.HasAuthoritativePageContext, self, entity)
    if not contextChecked or contextAvailable ~= true then
        return false
    end

    -- The current leader may canonically edit a cached background page using
    -- its retained authoritative wire hierarchy. Non-canonical publishers are
    -- limited to proposals for the exact active tuple.
    local commitChecked, canCommitPage = pcall(self.CanLocalPlayerPublish, self, "pageUpsert")
    if commitChecked and canCommitPage == true and IsGrouped() then
        return true
    end
    if
        type(rawget(entity, "Id")) ~= "number"
        or type(AngryAssign_State) ~= "table"
        or rawget(AngryAssign_State, "displayed") ~= entity.Id
        or type(self.GetActiveDisplayReference) ~= "function"
    then
        return false
    end

    local referenceChecked, reference = pcall(self.GetActiveDisplayReference, self)
    if
        not referenceChecked
        or type(reference) ~= "table"
        or reference.SyncId ~= entity.SyncId
        or reference.Revision ~= rawget(entity, "Revision")
        or reference.RevisionId ~= rawget(entity, "RevisionId")
        or type(reference.ContextRevisionId) ~= "string"
    then
        return false
    end
    return IsGrouped() and self:CanLocalPlayerPublish("changeProposal")
end

function AngryEra:IsPlayerRaidLeader()
    return self:GetGroupRole(PlayerFullName()) == "leader"
end

--- Returns whether this receiver accepts shared display/page state from its leader.
function AngryEra:IsValidRaid()
    if not IsGrouped() then
        return true
    end
    local leader = self:GetRaidLeader()
    return leader and self:CanReceiveFrom(leader, "display") or false
end

--- Migrates legacy permission settings to sender-specific policy.
function AngryEra:MigratePermissionConfig()
    if AngryAssign_Meta.Migrations.PermissionPolicy == PERMISSION_POLICY_VERSION then
        return
    end

    if AngryAssign_Config.allowAllAssistants == nil and AngryAssign_Config.allowall == true then
        AngryAssign_Config.allowAllAssistants = true
    end
    if
        AngryAssign_Config.trustedPublishers == nil
        and type(AngryAssign_Config.allowplayers) == "string"
        and AngryAssign_Config.allowplayers ~= ""
    then
        AngryAssign_Config.trustedPublishers = AngryAssign_Config.allowplayers
    end

    AngryAssign_Config.allowall = nil
    AngryAssign_Config.allowplayers = nil
    AngryAssign_Meta.Migrations.PermissionPolicy = PERMISSION_POLICY_VERSION
end

--- Refreshes controls after local permission inputs change.
-- Protocol discovery and display recovery belong to explicit group lifecycle
-- boundaries; routine roster and guild events must not generate sync traffic.
function AngryEra:PermissionsUpdated()
    self:UpdateSelected()
end

--- Applies a receive-mode change and recovers state only when sharing is
-- re-enabled after being ignored.
-- @tparam string previousMode Receive mode before the configuration write.
-- @treturn boolean requestedOrNotNeeded
-- @treturn string|nil messageIdOrStatus
function AngryEra:ReceiveModeUpdated(previousMode)
    self:PermissionsUpdated()
    if
        AngryEra._protocolStarted
        and previousMode == "ignoreShared"
        and self:GetConfig("receiveMode") ~= "ignoreShared"
    then
        return self:SendRequestDisplay()
    end
    return false, "not-needed"
end
