local currentPlayer = "Viewer-Realm"
local grouped = true
local raid = true
local groupRoster = {}
local guildMembers = {}
local clearDisplayedCalls = 0

local function EnsureUnitFullName(name)
    if name and not name:find("-", 1, true) then
        return name .. "-Realm"
    end
    return name
end

local helpers = {
    EnsureUnitFullName = EnsureUnitFullName,
    PlayerFullName = function()
        return currentPlayer
    end,
    IterateGroupMembers = function(callback)
        for _, member in ipairs(groupRoster) do
            if callback(member.name, EnsureUnitFullName(member.name), member.rank) then
                return
            end
        end
    end,
}

local configDefaults = {
    receiveMode = "standard",
    allowAllAssistants = false,
    trustedPublishers = "",
}
local config = {}

local AngryEra = {
    utils = {
        helpers = helpers,
    },
}

function AngryEra:GetConfig(key)
    if config[key] ~= nil then
        return config[key]
    end
    return configDefaults[key]
end

function AngryEra:GetRaidLeader()
    for _, member in ipairs(groupRoster) do
        if member.rank == 2 then
            return EnsureUnitFullName(member.name)
        end
    end
end

function AngryEra:IsLocallyOwned(entity)
    return entity and entity.LocallyOwned == true
end

function AngryEra:UpdateSelected() end
function AngryEra:SendRequestDisplay() end
function AngryEra:ClearDisplayed()
    clearDisplayedCalls = clearDisplayedCalls + 1
end

local app = { AngryEra = AngryEra }

_G.IsInRaid = function()
    return grouped and raid
end
_G.IsInGroup = function()
    return grouped
end
_G.C_Club = {
    GetGuildClubId = function()
        return 1
    end,
}
_G.CommunitiesUtil = {
    GetMemberIdsSortedByName = function()
        return { 1 }
    end,
    GetMemberInfo = function()
        return guildMembers
    end,
}
_G.Enum = {
    ClubRoleIdentifier = {
        Owner = 1,
        Leader = 2,
        Moderator = 3,
        Member = 4,
    },
}

assert(loadfile("modules/permissions.lua"))("AngryEra", app)

local function SetRoster(entries, isRaid)
    groupRoster = entries
    grouped = true
    raid = isRaid ~= false
end

local function SetGuild(entries)
    guildMembers = entries
    AngryEra:ResetOfficerRank()
end

SetGuild({})
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "Viewer-Realm", rank = 0 },
})
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "pageUpsert"), "A non-officer group leader should be trusted")
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "delete"), "The group leader should pass leader-only actions")

SetGuild({
    { name = "Owner-Realm", role = 1 },
    { name = "GuildLeader-Realm", role = 2 },
    { name = "Officer-Realm", role = 3 },
})
assert(AngryEra:IsGuildOfficer("Owner"), "Guild owners should qualify")
assert(AngryEra:IsGuildOfficer("guildleader-realm"), "Guild leaders should qualify case-insensitively")
assert(AngryEra:IsGuildOfficer("Officer-Realm"), "Guild moderators should qualify")

SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "Officer-Realm", rank = 1 },
    { name = "OrdinaryAssist-Realm", rank = 1 },
    { name = "OfficerMember-Realm", rank = 0 },
})
SetGuild({
    { name = "Officer-Realm", role = 3 },
    { name = "OfficerMember-Realm", role = 3 },
})
assert(AngryEra:CanReceiveFrom("Officer-Realm", "pageUpsert"), "An officer assistant should be trusted")
assert(not AngryEra:CanReceiveFrom("OrdinaryAssist-Realm", "pageUpsert"), "An ordinary assistant should be rejected")
assert(not AngryEra:CanReceiveFrom("OfficerMember-Realm", "pageUpsert"), "An officer without assist should be rejected")

config.trustedPublishers = "DirectAssist-Realm"
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "DirectAssist-Realm", rank = 1 },
    { name = "DirectMember-Realm", rank = 0 },
})
assert(AngryEra:CanReceiveFrom("DirectAssist-Realm", "pageUpsert"), "A directly trusted assistant should qualify")
config.trustedPublishers = "DirectMember-Realm"
assert(not AngryEra:CanReceiveFrom("DirectMember-Realm", "pageUpsert"), "Allowlisting must not grant assist rank")

config.trustedPublishers = ""
config.allowAllAssistants = true
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "AnyAssist-Realm", rank = 1 },
    { name = "AnyMember-Realm", rank = 0 },
})
assert(AngryEra:CanReceiveFrom("AnyAssist-Realm", "pageUpsert"), "The explicit override should trust assistants")
assert(not AngryEra:CanReceiveFrom("AnyMember-Realm", "pageUpsert"), "The assistant override should reject members")
assert(not AngryEra:CanReceiveFrom("AnyAssist-Realm", "delete"), "Assistants must never pass destructive actions")

config.receiveMode = "leaderOnly"
assert(not AngryEra:CanReceiveFrom("AnyAssist-Realm", "pageUpsert"), "Leader-only mode should reject assistants")
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "pageUpsert"), "Leader-only mode should retain the leader")

config.receiveMode = "invalid"
assert(not AngryEra:CanReceiveFrom("AnyAssist-Realm", "pageUpsert"), "Unknown receiver modes should fail closed")
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "pageUpsert"), "Unknown receiver modes should retain the leader")

config.receiveMode = "ignoreShared"
assert(not AngryEra:CanReceiveFrom("PugLeader-Realm", "display"), "Ignore mode should reject shared mutations")
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "version"), "Ignore mode should retain non-mutating discovery")
assert(AngryEra:CanEditEntityLocally({ LocallyOwned = true }), "Ignore mode must not disable local editing")

config.receiveMode = "standard"
config.allowAllAssistants = false
assert(not AngryEra:CanReceiveFrom("Absent-Realm", "pageUpsert"), "Players outside the group should be rejected")

config.trustedPublishers = "TRUSTED"
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "Trusted-Realm", rank = 1 },
    { name = "Cross-Other", rank = 1 },
})
assert(AngryEra:CanReceiveFrom("trusted-realm", "pageUpsert"), "Local-realm names should normalize")
config.trustedPublishers = "Cross"
assert(not AngryEra:CanReceiveFrom("Cross-Other", "pageUpsert"), "Cross-realm trust should require the realm")
config.trustedPublishers = "cross-other"
assert(AngryEra:CanReceiveFrom("Cross-Other", "pageUpsert"), "Explicit cross-realm trust should normalize case")

config.trustedPublishers = ""
local savedClub = C_Club
local savedCommunities = CommunitiesUtil
_G.C_Club = nil
_G.CommunitiesUtil = nil
AngryEra:ResetOfficerRank()
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "Officer-Realm", rank = 1 },
})
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "pageUpsert"), "Unavailable guild APIs should fail closed")
_G.C_Club = savedClub
_G.CommunitiesUtil = savedCommunities

SetGuild({})
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "pageUpsert"), "An uncached ordinary assistant should fail")
SetGuild({
    { name = "Officer-Realm", role = 3 },
})
assert(AngryEra:CanReceiveFrom("Officer-Realm", "pageUpsert"), "A roster refresh should update officer authority")

SetGuild({
    { name = "GuildLeader-Realm", role = 3 },
})
SetRoster({
    { name = "GuildLeader-Realm", rank = 2 },
    { name = "RandomAssist-Realm", rank = 1 },
})
assert(
    not AngryEra:CanReceiveFrom("RandomAssist-Realm", "pageUpsert"),
    "A trusted leader must not implicitly trust every assistant"
)

SetGuild({})
SetRoster({
    { name = "PartyLeader-Realm", rank = 2 },
    { name = "PartyMember-Realm", rank = 0 },
}, false)
assert(AngryEra:CanReceiveFrom("PartyLeader-Realm", "display"), "A party leader should qualify")
assert(not AngryEra:CanReceiveFrom("PartyMember-Realm", "display"), "A party member should not qualify")

SetGuild({
    { name = "Officer-Realm", role = 3 },
})
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "Officer-Realm", rank = 1 },
})
assert(AngryEra:CanReceiveFrom("Officer-Realm", "pageUpsert"), "Officer assistant should initially qualify")
groupRoster[2].rank = 0
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "pageUpsert"), "Authorization should follow current group rank")

currentPlayer = "Officer-Realm"
groupRoster[2].rank = 1
assert(AngryEra:CanLocalPlayerPublish("pageUpsert"), "A local officer assistant should publish normal changes")
assert(not AngryEra:CanLocalPlayerPublish("delete"), "A local assistant should not publish destructive changes")
assert(
    AngryEra:CanEditEntityLocally({ SyncId = "remote", LocallyOwned = false }),
    "A qualified publisher should edit managed remote entities while grouped"
)

currentPlayer = "OrdinaryAssist-Realm"
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "OrdinaryAssist-Realm", rank = 1 },
    { name = "OrdinaryMember-Realm", rank = 0 },
})
config.receiveMode = "ignoreShared"
config.allowAllAssistants = false
config.trustedPublishers = ""
assert(
    AngryEra:CanLocalPlayerPublish("pageUpsert"),
    "Any current assistant may attempt a normal change for receivers to authorize"
)
config.allowAllAssistants = true
config.trustedPublishers = "OrdinaryAssist-Realm"
assert(
    AngryEra:CanLocalPlayerPublish("pageUpsert"),
    "Receiver preferences must not grant or revoke outbound attempt authority"
)
AngryEra._comStarted = true
AngryEra:PermissionsUpdated()
assert(clearDisplayedCalls == 0, "Ignore-shared preference changes must not clear a locally selected display")
currentPlayer = "OrdinaryMember-Realm"
assert(not AngryEra:CanLocalPlayerPublish("pageUpsert"), "An ordinary member may not attempt shared changes")

grouped = false
assert(AngryEra:CanEditEntityLocally({ LocallyOwned = true }), "Local entities should remain editable while solo")
assert(
    not AngryEra:CanEditEntityLocally({ SyncId = "remote", LocallyOwned = false }),
    "Managed remote entities should require active publish authority"
)

AngryAssign_Meta = {
    Migrations = {},
}
AngryAssign_Config = {
    allowall = true,
    allowplayers = "LegacyAssist-Realm",
}
config = AngryAssign_Config
AngryEra:MigratePermissionConfig()
assert(AngryAssign_Config.allowAllAssistants, "Legacy allow-all should migrate to the explicit assistant override")
assert(
    AngryAssign_Config.trustedPublishers == "LegacyAssist-Realm",
    "Legacy player names should migrate to direct trusted publishers"
)
assert(AngryAssign_Config.allowall == nil, "Legacy allow-all config should be removed")
assert(AngryAssign_Config.allowplayers == nil, "Legacy allow-player config should be removed")
assert(AngryAssign_Meta.Migrations.PermissionPolicy == 1, "Permission migration should be marked complete")

print("Permission tests passed.")
