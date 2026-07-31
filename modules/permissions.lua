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
    controlRequest = true,
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
    controlGrant = true,
    controlRevoke = true,
    controlResult = true,
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

local function SamePlayer(left, right)
    local leftName = NormalizePlayerName(left)
    return leftName ~= nil and leftName == NormalizePlayerName(right)
end

local function IsPlayerOnline(player)
    local normalizedName = NormalizePlayerName(player)
    if not normalizedName then
        return false
    end
    local online = false
    IterateGroupMembers(function(_, fullName, _, _, _, memberOnline)
        if NormalizePlayerName(fullName) == normalizedName then
            online = memberOnline ~= false
            return true
        end
        return false
    end)
    return online
end

local function RawDelegatedRaidControl(self)
    if type(self.GetDelegatedRaidControl) ~= "function" then
        return nil
    end
    local called, control = pcall(self.GetDelegatedRaidControl, self)
    return called and type(control) == "table" and control or nil
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

--- Returns the current session-only delegated Raid Controller lease, if any.
-- Protocol runtime owns the record; this helper deliberately validates only
-- live roster identities so permission checks cannot revive a stale lease.
-- @treturn table|nil control
function AngryEra:GetValidatedDelegatedRaidControl()
    local control = RawDelegatedRaidControl(self)
    if
        type(control) ~= "table"
        or type(control.Controller) ~= "string"
        or type(control.Leader) ~= "string"
        or type(control.ControllerInstallationId) ~= "string"
        or type(control.ControllerSessionId) ~= "string"
        or self:GetGroupRole(control.Controller) ~= "assistant"
    then
        return nil
    end
    local leader = type(self.GetRaidLeader) == "function" and self:GetRaidLeader() or nil
    if not SamePlayer(leader, control.Leader) then
        return nil
    end
    return control
end

--- Returns whether a player is the leader-granted AngryEra Raid Controller.
-- Installation/session binding is additionally enforced by protocol runtime.
function AngryEra:IsDelegatedRaidController(player)
    local control = self:GetValidatedDelegatedRaidControl()
    return control ~= nil and SamePlayer(control.Controller, player)
end

--- Returns the single player allowed to publish canonical AngryEra state.
-- While a lease exists, an invalid/offline controller fails closed instead of
-- silently falling back to the Blizzard leader and creating two authorities.
-- @tparam[opt=false] boolean onlineOnly Require the authority to be online.
-- @treturn string|nil player
function AngryEra:GetAngryEraAuthority(onlineOnly)
    local rawControl = RawDelegatedRaidControl(self)
    if rawControl then
        local control = self:GetValidatedDelegatedRaidControl()
        if not control or onlineOnly and not IsPlayerOnline(control.Controller) then
            return nil
        end
        return EnsureUnitFullName(control.Controller)
    end
    if type(self.GetRaidLeader) ~= "function" then
        return nil
    end
    return self:GetRaidLeader(onlineOnly)
end

--- Returns whether this client is the one canonical AngryEra publisher.
function AngryEra:IsLocalAngryEraAuthority()
    if not IsGrouped() then
        return true
    end
    local authority = self:GetAngryEraAuthority()
    if not SamePlayer(authority, PlayerFullName()) then
        return false
    end
    local control = self:GetValidatedDelegatedRaidControl()
    if not control then
        return true
    end
    if type(self.GetProtocolSession) ~= "function" then
        return false
    end
    local session = self:GetProtocolSession()
    return type(session) == "table"
        and session.InstallationId == control.ControllerInstallationId
        and session.SessionId == control.ControllerSessionId
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
    if action == "controlRequest" then
        return role == "assistant" and self:IsQualifiedAssistant(sender)
    end
    if action == "controlGrant" or action == "controlRevoke" or action == "controlResult" then
        return role == "leader"
    end
    if NON_MUTATING_ACTIONS[action] then
        return true
    end

    local receiveMode = self:GetConfig("receiveMode")
    if receiveMode == "ignoreShared" then
        return false
    end
    local delegatedController = self:IsDelegatedRaidController(sender)
    local hasDelegatedControl = RawDelegatedRaidControl(self) ~= nil
    if receiveMode ~= "standard" and receiveMode ~= "leaderOnly" then
        return delegatedController or (not hasDelegatedControl and role == "leader")
    end
    if receiveMode == "leaderOnly" or LEADER_ONLY_ACTIONS[action] then
        return delegatedController or (not hasDelegatedControl and role == "leader")
    end
    if delegatedController then
        return true
    end
    if hasDelegatedControl and role == "leader" then
        return false
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
    if action == "controlRequest" then
        -- A requester cannot know the leader installation's trust policy.
        -- Any raid assistant may attempt; the leader's CanReceiveFrom check is
        -- the authoritative qualification gate.
        return role == "assistant"
    end
    if action == "controlGrant" or action == "controlRevoke" or action == "controlResult" then
        return role == "leader"
    end
    if LEADER_ONLY_ACTIONS[action] then
        return self:IsLocalAngryEraAuthority()
    end
    if RawDelegatedRaidControl(self) ~= nil and role == "leader" then
        return false
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
-- resolved layout. The Blizzard leader is allowed under normal control; while
-- Raid Control is delegated, only its active controller is allowed. Otherwise,
-- assistants must satisfy the same officer/trusted/allow-all policy used for
-- shared page proposals, which prevents broadly granted raid assist from
-- enabling this action by default.
-- @treturn boolean allowed
-- @treturn string|nil reason Stable denial reason when not allowed.
function AngryEra:CanLocalPlayerApplyRaidLayout()
    if not IsInRaid() then
        return false, "not-in-raid"
    end

    local player = PlayerFullName()
    local role = self:GetGroupRole(player)
    local rawDelegatedControl = RawDelegatedRaidControl(self)
    if rawDelegatedControl then
        local delegatedControl = self:GetValidatedDelegatedRaidControl()
        -- A pending or invalid lease is an authority barrier, not permission to
        -- fall back to the Blizzard leader. This matches canonical publication:
        -- layout mutations remain paused until the lease validates or is
        -- explicitly cleared/reclaimed.
        if delegatedControl ~= nil then
            if self:IsDelegatedRaidController(player) then
                return true
            end
            return false, "not-raid-controller"
        end
        return false, "not-authorized"
    end
    if role == "leader" then
        return true
    end
    if role ~= "assistant" then
        return false, "not-authorized"
    end
    if self:GetConfig("allowAllAssistants") == true or self:IsDirectlyAllowlisted(player) then
        return true
    end

    -- Officer status qualifies by default only when the current raid leader is
    -- in the same local guild roster. Without this check, an officer from an
    -- unrelated guild in a pug could gain the action merely by receiving assist.
    local leader = type(self.GetRaidLeader) == "function" and self:GetRaidLeader() or nil
    if leader ~= nil and self:IsGuildMember(leader) and self:IsGuildOfficer(player) then
        return true
    end
    return false, "not-authorized"
end

--- Returns whether an entity may be edited locally or proposed to the authority.
-- Unsynchronized and locally owned entities remain locally editable. A
-- remote-owned page is editable only while its exact canonical tuple is the
-- active shared display; cached background pages fail closed. Remote category
-- name/variable editing waits for the future hierarchy-proposal protocol, while
-- receiver-private CategoryId/Index placement remains a separate local action.
-- Only the current AngryEra authority publishes the canonical page revision.
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

    -- The current authority may canonically edit a cached background page using
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

--- Returns whether this receiver accepts shared display/page state from its authority.
function AngryEra:IsValidRaid()
    if not IsGrouped() then
        return true
    end
    local authority = self:GetAngryEraAuthority()
    return authority and self:CanReceiveFrom(authority, "display") or false
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
    if AngryEra._protocolStarted and type(self.ReconcileDelegatedRaidControl) == "function" then
        pcall(self.ReconcileDelegatedRaidControl, self, "permission-policy-updated")
    end
    self:UpdateSelected()
end

--- Applies a receive-mode change and recovers state only when sharing is
-- re-enabled after being ignored.
-- @tparam string previousMode Receive mode before the configuration write.
-- @treturn boolean requestedOrNotNeeded
-- @treturn string|nil messageIdOrStatus
function AngryEra:ReceiveModeUpdated(previousMode)
    local receiveMode = self:GetConfig("receiveMode")
    local control = RawDelegatedRaidControl(self)
    local localPlayer = PlayerFullName()
    local localController = receiveMode == "ignoreShared"
        and control ~= nil
        and SamePlayer(control.Controller, localPlayer)
        and type(self.IsLocalAngryEraAuthority) == "function"
        and self:IsLocalAngryEraAuthority()
    if localController then
        -- The active controller cannot opt out of the state it canonically
        -- publishes. Revert the already-written setting instead of stranding
        -- every follower behind an authority that ignores its own stream.
        self:SetConfig("receiveMode", previousMode)
        self:PermissionsUpdated()
        if type(self.Print) == "function" then
            self:Print(
                "The active Raid Controller must accept shared changes. Ask the raid leader to reclaim Raid Control first."
            )
        end
        return false, "raid-controller-sharing-required"
    end

    local localLeader = receiveMode == "ignoreShared"
        and control ~= nil
        and SamePlayer(control.Leader, localPlayer)
        and self:GetGroupRole(localPlayer) == "leader"
    if localLeader and AngryEra._protocolStarted and type(self.ReconcileDelegatedRaidControl) == "function" then
        local called, reconciled = pcall(self.ReconcileDelegatedRaidControl, self, "raid-leader-ignore-shared")
        self:UpdateSelected()
        if called and reconciled == true and RawDelegatedRaidControl(self) == nil then
            return true, "raid-controller-revoked"
        end
        return false, "raid-controller-revoke-pending"
    end

    self:PermissionsUpdated()
    if AngryEra._protocolStarted and previousMode == "ignoreShared" and receiveMode ~= "ignoreShared" then
        return self:SendRequestDisplay()
    end
    return false, "not-needed"
end
