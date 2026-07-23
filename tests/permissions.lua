local currentPlayer = "Viewer-Realm"
local grouped = true
local raid = true
local groupRoster = {}
local guildMembers = {}
local clearDisplayedCalls = 0
local authoritativePageContextAvailable = true

local function EnsureUnitFullName(name)
    if name and not name:find("-", 1, true) then
        return name .. "-Realm"
    end
    return name
end

local helpers = {
    EnsureUnitFullName = EnsureUnitFullName,
    selectedLastValue = function(value)
        return tonumber(value)
    end,
    IsCategoryDescendant = function()
        return false
    end,
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

function AngryEra:HasAuthoritativePageContext()
    return authoritativePageContextAvailable
end

function AngryEra:UpdateSelected() end
function AngryEra:SendRequestDisplay() end
function AngryEra:SendProtocolVersionQuery() end
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
    AngryEra:CanEditEntityLocally({ SyncId = "remote", LocallyOwned = false, Contents = "" }),
    "A qualified publisher should edit managed remote entities while grouped"
)
authoritativePageContextAvailable = false
assert(
    not AngryEra:CanEditEntityLocally({ SyncId = "remote", LocallyOwned = false, Contents = "" }),
    "A remote page without its authoritative base context must fail closed"
)
assert(
    AngryEra:CanEditEntityLocally({ SyncId = "remote-category", LocallyOwned = false }),
    "Remote category editing should remain governed by hierarchy publish authority"
)
authoritativePageContextAvailable = true
local savedContextCheck = AngryEra.HasAuthoritativePageContext
AngryEra.HasAuthoritativePageContext = nil
assert(
    not AngryEra:CanEditEntityLocally({ SyncId = "remote", LocallyOwned = false, Contents = "" }),
    "A missing authoritative-context helper must fail closed for remote pages"
)
assert(
    AngryEra:CanEditEntityLocally({ SyncId = "local", LocallyOwned = true, Contents = "" }),
    "Locally owned pages must not depend on the authoritative remote-context helper"
)
assert(
    AngryEra:CanEditEntityLocally({ Contents = "" }),
    "Unsynchronized pages must remain editable without an authoritative remote context"
)
AngryEra.HasAuthoritativePageContext = function()
    error("malformed transient context")
end
assert(
    not AngryEra:CanEditEntityLocally({ SyncId = "remote", LocallyOwned = false, Contents = "" }),
    "Authoritative-context lookup failures must fail closed"
)
AngryEra.HasAuthoritativePageContext = savedContextCheck

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
AngryEra._protocolStarted = true
AngryEra:PermissionsUpdated()
assert(clearDisplayedCalls == 0, "Ignore-shared preference changes must not clear a locally selected display")
currentPlayer = "OrdinaryMember-Realm"
assert(not AngryEra:CanLocalPlayerPublish("pageUpsert"), "An ordinary member may not attempt shared changes")

grouped = false
assert(AngryEra:CanEditEntityLocally({ LocallyOwned = true }), "Local entities should remain editable while solo")
assert(
    not AngryEra:CanEditEntityLocally({ SyncId = "remote", LocallyOwned = false, Contents = "" }),
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

-- The editor must consume the same authoritative-context guard so a post-reload
-- remote page cannot expose a Save path that will mutate locally and fail later.
AngryEra.Title = "Angry Era"
AngryEra.utils.colors = {}
app.libs = {
    AceGUI = {},
    DDM = {},
}
assert(loadfile("modules/ui/editor.lua"))("AngryEra", app)

local editorDisabled
local function DisabledButton()
    return {
        SetDisabled = function() end,
    }
end

AngryEra.window = {
    text = {
        button = {
            IsEnabled = function()
                return false
            end,
            Disable = function() end,
        },
        SetText = function() end,
        SetDisabled = function(_, disabled)
            editorDisabled = disabled
        end,
    },
    button_revert = DisabledButton(),
    button_display = DisabledButton(),
    button_output = DisabledButton(),
    button_restore = DisabledButton(),
    button_menu = DisabledButton(),
}
function AngryEra:SelectedId()
    return 777
end

SetRoster({
    { name = "OrdinaryMember-Realm", rank = 2 },
})
AngryAssign_State = {
    tree = {},
}
AngryAssign_Pages = {
    [777] = {
        SyncId = "remote-page",
        Contents = "Remote",
        LocallyOwned = false,
    },
}
authoritativePageContextAvailable = false
AngryEra:UpdateSelected()
assert(editorDisabled == true, "Editor Save controls must disable without an authoritative remote-page context")
authoritativePageContextAvailable = true
AngryEra:UpdateSelected()
assert(editorDisabled == false, "Editor Save controls should enable when the authoritative context is available")

local hierarchyRefreshes = 0
AngryEra.window = nil
AngryEra.UpdateTree = function() end
AngryEra.RefreshDisplayedPageAfterHierarchyMutation = function()
    hierarchyRefreshes = hierarchyRefreshes + 1
end
AngryAssign_State = {
    tree = {
        groups = {},
    },
}
AngryAssign_Categories = {}
AngryAssign_Pages = {
    [1] = {
        Id = 1,
        Name = "Moved",
        Index = 2,
    },
    [2] = {
        Id = 2,
        Name = "Target",
        Index = 1,
    },
}
AngryEra:MoveItem("1", "2", "before")
assert(AngryAssign_Pages[1].Index == 0.5, "tree drag should retain its structural mutation")
assert(hierarchyRefreshes == 1, "tree drag should republish the displayed exact tuple once")

print("Permission tests passed.")
