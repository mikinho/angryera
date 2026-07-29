local currentPlayer = "Viewer-Realm"
local grouped = true
local raid = true
local groupRoster = {}
local guildMembers = {}
local clearDisplayedCalls = 0
local authoritativePageContextAvailable = true
local selectedUpdateCalls = 0
local displayRequestCalls = 0
local versionQueryCalls = 0
local activeDisplayReference
local delegatedControl
local reconcileCalls = {}
local reconcileClearsControl = false

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

function AngryEra:SetConfig(key, value)
    config[key] = value
end

function AngryEra:GetRaidLeader()
    for _, member in ipairs(groupRoster) do
        if member.rank == 2 then
            return EnsureUnitFullName(member.name)
        end
    end
end

function AngryEra:GetDelegatedRaidControl()
    if type(delegatedControl) ~= "table" then
        return nil
    end
    local copy = {}
    for key, value in pairs(delegatedControl) do
        copy[key] = value
    end
    return copy
end

function AngryEra:GetProtocolSession()
    return {
        InstallationId = "ae3i:1:2:3:4",
        SessionId = "controller-session",
    }
end

function AngryEra:IsLocallyOwned(entity)
    return entity and entity.LocallyOwned == true
end

function AngryEra:HasAuthoritativePageContext()
    return authoritativePageContextAvailable
end

function AngryEra:GetActiveDisplayReference()
    return activeDisplayReference
end

function AngryEra:UpdateSelected()
    selectedUpdateCalls = selectedUpdateCalls + 1
end
function AngryEra:SendRequestDisplay()
    displayRequestCalls = displayRequestCalls + 1
    return true, "display-request-id"
end
function AngryEra:SendProtocolVersionQuery()
    versionQueryCalls = versionQueryCalls + 1
end
function AngryEra:ClearDisplayed()
    clearDisplayedCalls = clearDisplayedCalls + 1
end
function AngryEra:ReconcileDelegatedRaidControl(reason)
    reconcileCalls[#reconcileCalls + 1] = reason
    if reconcileClearsControl then
        delegatedControl = nil
    end
    return true
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
assert(
    AngryEra.permissionActions.leaderOnly.display and not AngryEra.permissionActions.normal.display,
    "shared display selection should be classified as leader-only"
)
assert(
    AngryEra.permissionActions.leaderOnly.pageUpsert
        and AngryEra.permissionActions.leaderOnly.changeResult
        and not AngryEra.permissionActions.normal.pageUpsert,
    "canonical page commits and proposal results should be classified as leader-only"
)
assert(
    AngryEra.permissionActions.normal.changeProposal and not AngryEra.permissionActions.leaderOnly.changeProposal,
    "assistant change proposals should remain a normal qualified action"
)

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
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "display"), "The current group leader should control display")
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "changeResult"), "The current group leader should return results")
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
    { name = "PugLeader-Realm", role = 4 },
    { name = "Officer-Realm", role = 3 },
    { name = "OfficerMember-Realm", role = 3 },
})
assert(AngryEra:CanReceiveFrom("Officer-Realm", "changeProposal"), "An officer assistant should be trusted")
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "pageUpsert"), "An officer assistant must not commit pages")
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "changeResult"), "An officer assistant must not return results")
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "display"), "An officer assistant must not control display")
assert(
    not AngryEra:CanReceiveFrom("OrdinaryAssist-Realm", "changeProposal"),
    "An ordinary assistant should be rejected"
)
assert(
    not AngryEra:CanReceiveFrom("OfficerMember-Realm", "changeProposal"),
    "An officer without assist should be rejected"
)
currentPlayer = "Officer-Realm"
assert(AngryEra:IsQualifiedAssistant("Officer-Realm"), "An officer with assist should be a qualified assistant")
assert(
    AngryEra:CanLocalPlayerApplyRaidLayout(),
    "A qualified officer assistant should be allowed to apply raid layouts"
)
currentPlayer = "OfficerMember-Realm"
assert(not AngryEra:IsQualifiedAssistant("OfficerMember-Realm"), "An officer without assist should not qualify")
assert(
    not AngryEra:CanLocalPlayerApplyRaidLayout(),
    "An officer without assist should not be allowed to apply raid layouts"
)
currentPlayer = "OrdinaryAssist-Realm"
assert(not AngryEra:IsQualifiedAssistant("OrdinaryAssist-Realm"), "Raid assist alone should not qualify by default")
assert(
    not AngryEra:CanLocalPlayerApplyRaidLayout(),
    "Raid assist alone should not allow a layout rearrangement by default"
)
SetGuild({
    { name = "Officer-Realm", role = 3 },
})
currentPlayer = "Officer-Realm"
assert(
    not AngryEra:CanLocalPlayerApplyRaidLayout(),
    "An officer from a different guild than the raid leader should not qualify by default"
)
SetGuild({
    { name = "PugLeader-Realm", role = 4 },
    { name = "Officer-Realm", role = 3 },
    { name = "OfficerMember-Realm", role = 3 },
})
currentPlayer = "Viewer-Realm"

config.trustedPublishers = "DirectAssist-Realm"
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "DirectAssist-Realm", rank = 1 },
    { name = "DirectMember-Realm", rank = 0 },
})
assert(AngryEra:CanReceiveFrom("DirectAssist-Realm", "changeProposal"), "A directly trusted assistant should qualify")
config.trustedPublishers = 12345
assert(
    not AngryEra:CanReceiveFrom("DirectAssist-Realm", "changeProposal"),
    "A non-string trusted-publisher config must deny rather than error"
)
config.trustedPublishers = "DirectAssist-Realm"
assert(not AngryEra:CanReceiveFrom("DirectAssist-Realm", "pageUpsert"), "Direct trust must not grant commit authority")
assert(not AngryEra:CanReceiveFrom("DirectAssist-Realm", "display"), "Direct trust must not grant display control")
currentPlayer = "DirectAssist-Realm"
assert(
    AngryEra:CanLocalPlayerApplyRaidLayout(),
    "A directly trusted raid assistant should be allowed to apply raid layouts"
)
currentPlayer = "Viewer-Realm"
config.trustedPublishers = "DirectMember-Realm"
assert(not AngryEra:CanReceiveFrom("DirectMember-Realm", "changeProposal"), "Allowlisting must not grant assist rank")

config.trustedPublishers = ""
config.allowAllAssistants = true
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "AnyAssist-Realm", rank = 1 },
    { name = "AnyMember-Realm", rank = 0 },
})
assert(AngryEra:CanReceiveFrom("AnyAssist-Realm", "changeProposal"), "The explicit override should trust assistants")
assert(not AngryEra:CanReceiveFrom("AnyAssist-Realm", "pageUpsert"), "The override must not grant commit authority")
assert(
    not AngryEra:CanReceiveFrom("AnyAssist-Realm", "display"),
    "The assistant override must not grant display control"
)
assert(not AngryEra:CanReceiveFrom("AnyMember-Realm", "changeProposal"), "The assistant override should reject members")
assert(not AngryEra:CanReceiveFrom("AnyAssist-Realm", "delete"), "Assistants must never pass destructive actions")
currentPlayer = "AnyAssist-Realm"
assert(
    AngryEra:CanLocalPlayerApplyRaidLayout(),
    "The explicit assistant override should allow a raid assistant to apply layouts"
)
currentPlayer = "AnyMember-Realm"
assert(
    not AngryEra:CanLocalPlayerApplyRaidLayout(),
    "The explicit assistant override should not allow an ordinary raid member to apply layouts"
)
currentPlayer = "Viewer-Realm"

config.receiveMode = "leaderOnly"
assert(not AngryEra:CanReceiveFrom("AnyAssist-Realm", "changeProposal"), "Leader-only mode should reject assistants")
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "pageUpsert"), "Leader-only mode should retain the leader")

config.receiveMode = "invalid"
assert(not AngryEra:CanReceiveFrom("AnyAssist-Realm", "changeProposal"), "Unknown receiver modes should fail closed")
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "pageUpsert"), "Unknown receiver modes should retain the leader")

config.receiveMode = "ignoreShared"
assert(not AngryEra:CanReceiveFrom("PugLeader-Realm", "display"), "Ignore mode should reject shared mutations")
assert(AngryEra:CanReceiveFrom("PugLeader-Realm", "version"), "Ignore mode should retain non-mutating discovery")
assert(AngryEra:CanEditEntityLocally({ LocallyOwned = true }), "Ignore mode must not disable local editing")

config.receiveMode = "standard"
config.allowAllAssistants = false
assert(not AngryEra:CanReceiveFrom("Absent-Realm", "changeProposal"), "Players outside the group should be rejected")
currentPlayer = "PugLeader-Realm"
assert(AngryEra:CanLocalPlayerApplyRaidLayout(), "The raid leader should always be allowed to apply layouts")
currentPlayer = "AnyAssist-Realm"
assert(
    not AngryEra:CanLocalPlayerApplyRaidLayout(),
    "Removing the assistant override should immediately revoke layout application"
)
currentPlayer = "Viewer-Realm"

config.trustedPublishers = "TRUSTED"
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "Trusted-Realm", rank = 1 },
    { name = "Cross-Other", rank = 1 },
})
assert(AngryEra:CanReceiveFrom("trusted-realm", "changeProposal"), "Local-realm names should normalize")
config.trustedPublishers = "Cross"
assert(not AngryEra:CanReceiveFrom("Cross-Other", "changeProposal"), "Cross-realm trust should require the realm")
config.trustedPublishers = "cross-other"
assert(AngryEra:CanReceiveFrom("Cross-Other", "changeProposal"), "Explicit cross-realm trust should normalize case")

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
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "changeProposal"), "Unavailable guild APIs should fail closed")
_G.C_Club = savedClub
_G.CommunitiesUtil = savedCommunities

SetGuild({})
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "changeProposal"), "An uncached ordinary assistant should fail")
SetGuild({
    { name = "Officer-Realm", role = 3 },
})
assert(AngryEra:CanReceiveFrom("Officer-Realm", "changeProposal"), "A roster refresh should update officer authority")

SetGuild({
    { name = "GuildLeader-Realm", role = 3 },
})
SetRoster({
    { name = "GuildLeader-Realm", rank = 2 },
    { name = "RandomAssist-Realm", rank = 1 },
})
assert(
    not AngryEra:CanReceiveFrom("RandomAssist-Realm", "changeProposal"),
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
assert(AngryEra:CanReceiveFrom("Officer-Realm", "changeProposal"), "Officer assistant should initially qualify")
groupRoster[2].rank = 0
assert(not AngryEra:CanReceiveFrom("Officer-Realm", "changeProposal"), "Authorization should follow current group rank")

currentPlayer = "PugLeader-Realm"
assert(AngryEra:CanLocalPlayerPublish("pageUpsert"), "The local leader should publish canonical pages")
assert(AngryEra:CanLocalPlayerPublish("changeResult"), "The local leader should return proposal results")

currentPlayer = "Officer-Realm"
groupRoster[2].rank = 1
assert(AngryEra:CanLocalPlayerPublish("changeProposal"), "A local officer assistant should propose normal changes")
assert(not AngryEra:CanLocalPlayerPublish("pageUpsert"), "A local assistant must not publish canonical pages")
assert(not AngryEra:CanLocalPlayerPublish("changeResult"), "A local assistant must not return proposal results")
assert(not AngryEra:CanLocalPlayerPublish("display"), "A local assistant must not publish display changes")
assert(AngryEra:CanLocalPlayerOutput(), "A local raid assistant should retain group-chat output authority")
assert(not AngryEra:CanLocalPlayerPublish("delete"), "A local assistant should not publish destructive changes")

delegatedControl = {
    Controller = "Officer-Realm",
    Leader = "PugLeader-Realm",
    ControllerInstallationId = "ae3i:1:2:3:4",
    ControllerSessionId = "controller-session",
    GrantId = "ae3i:5:6:7:8:leader-session:1",
}
assert(AngryEra:IsDelegatedRaidController("Officer"), "the granted assistant should be the delegated controller")
assert(
    AngryEra:GetAngryEraAuthority() == "Officer-Realm",
    "the delegated controller should replace the Blizzard leader as AngryEra authority"
)
assert(AngryEra:CanReceiveFrom("Officer-Realm", "display"), "followers should accept controller displays")
assert(AngryEra:CanReceiveFrom("Officer-Realm", "pageUpsert"), "followers should accept controller pages")
assert(AngryEra:CanReceiveFrom("Officer-Realm", "changeResult"), "followers should accept controller results")
assert(
    not AngryEra:CanReceiveFrom("PugLeader-Realm", "display"),
    "the Blizzard leader must not compete with an active controller"
)
assert(AngryEra:CanLocalPlayerPublish("display"), "the local controller should publish displays")
assert(AngryEra:CanLocalPlayerPublish("pageUpsert"), "the local controller should publish pages")
assert(AngryEra:CanLocalPlayerPublish("changeResult"), "the local controller should return proposal results")
assert(AngryEra:CanLocalPlayerApplyRaidLayout(), "the local controller should apply raid layouts")
assert(AngryEra:CanLocalPlayerPublish("controlRequest"), "a qualified assistant should request control")
assert(not AngryEra:CanLocalPlayerPublish("controlGrant"), "a controller cannot grant another controller")

config.receiveMode = "leaderOnly"
assert(
    AngryEra:CanReceiveFrom("Officer-Realm", "display"),
    "Leader Only receive mode should treat the leader-granted controller as authority"
)
config.receiveMode = "standard"
currentPlayer = "PugLeader-Realm"
assert(not AngryEra:CanLocalPlayerPublish("display"), "the Blizzard leader should not publish while delegated")
assert(
    not AngryEra:CanLocalPlayerPublish("changeProposal"),
    "the Blizzard leader should not propose AngryEra changes while delegated"
)
assert(
    not AngryEra:CanReceiveFrom("PugLeader-Realm", "changeProposal"),
    "followers should reject Blizzard-leader change proposals while delegated"
)
assert(not AngryEra:CanLocalPlayerApplyRaidLayout(), "the Blizzard leader should not race controller layouts")
assert(AngryEra:CanLocalPlayerPublish("controlGrant"), "only the Blizzard leader should grant control")
assert(AngryEra:CanLocalPlayerPublish("controlRevoke"), "only the Blizzard leader should revoke control")
assert(AngryEra:CanLocalPlayerPublish("controlResult"), "only the Blizzard leader should answer requests")

groupRoster[2].rank = 0
assert(AngryEra:GetAngryEraAuthority() == nil, "a controller that loses assist should fail closed")
assert(
    not AngryEra:CanReceiveFrom("PugLeader-Realm", "display"),
    "an invalid but unreconciled lease must not silently reactivate the leader"
)
assert(not AngryEra:CanLocalPlayerPublish("display"), "an invalid lease should leave no local publisher")
assert(
    not AngryEra:CanLocalPlayerApplyRaidLayout(),
    "an invalid but unreconciled lease must not silently reactivate leader layout mutations"
)
delegatedControl = {
    GrantId = "ae3i:5:6:7:8:leader-session:1",
    Leader = "PugLeader-Realm",
    PendingRecovery = true,
}
assert(
    not AngryEra:CanLocalPlayerApplyRaidLayout(),
    "a recovery barrier must pause layout mutations until explicit authority recovery"
)
groupRoster[2].rank = 1
delegatedControl = nil
assert(AngryEra:GetAngryEraAuthority() == "PugLeader-Realm", "reclaim should restore the Blizzard leader")
assert(AngryEra:CanLocalPlayerPublish("display"), "the reclaimed Blizzard leader should publish again")
currentPlayer = "Officer-Realm"

local activeRemotePage = {
    Id = 70,
    SyncId = "remote-page",
    RevisionId = "fcs32:70707070",
    LocallyOwned = false,
    Contents = "",
}
AngryAssign_State = {
    displayed = activeRemotePage.Id,
}
activeDisplayReference = {
    SyncId = activeRemotePage.SyncId,
    RevisionId = activeRemotePage.RevisionId,
    ContextRevisionId = "fcs32:71717171",
}
assert(
    AngryEra:CanEditEntityLocally(activeRemotePage),
    "A qualified publisher should edit the exact active remote page while grouped"
)
AngryAssign_State.displayed = nil
assert(not AngryEra:CanEditEntityLocally(activeRemotePage), "A cached background remote page must remain read-only")
currentPlayer = "PugLeader-Realm"
assert(
    AngryEra:CanEditEntityLocally(activeRemotePage),
    "the canonical leader may edit a background remote page with authoritative context"
)
currentPlayer = "Officer-Realm"
AngryAssign_State.displayed = activeRemotePage.Id
activeDisplayReference.RevisionId = "fcs32:72727272"
assert(not AngryEra:CanEditEntityLocally(activeRemotePage), "A remote page whose active tuple changed must fail closed")
activeDisplayReference.RevisionId = activeRemotePage.RevisionId
authoritativePageContextAvailable = false
assert(
    not AngryEra:CanEditEntityLocally(activeRemotePage),
    "A remote page without its authoritative base context must fail closed"
)
assert(
    not AngryEra:CanEditEntityLocally({ SyncId = "remote-category", LocallyOwned = false }),
    "Remote category name and variable fields need a hierarchy proposal before editing"
)
authoritativePageContextAvailable = true
local savedContextCheck = AngryEra.HasAuthoritativePageContext
AngryEra.HasAuthoritativePageContext = nil
assert(
    not AngryEra:CanEditEntityLocally(activeRemotePage),
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
assert(not AngryEra:CanEditEntityLocally(activeRemotePage), "Authoritative-context lookup failures must fail closed")
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
    AngryEra:CanLocalPlayerPublish("controlRequest"),
    "Any current raid assistant may request control without trusting itself on this installation"
)
assert(
    not AngryEra:CanReceiveFrom("OrdinaryAssist-Realm", "controlRequest"),
    "The leader-side receiver must still qualify an inbound controller request"
)
assert(
    AngryEra:CanLocalPlayerPublish("changeProposal"),
    "Any current assistant may attempt a normal change for receivers to authorize"
)
assert(not AngryEra:CanLocalPlayerPublish("pageUpsert"), "An ordinary assistant must not commit page changes")
assert(not AngryEra:CanLocalPlayerPublish("display"), "An ordinary assistant must not attempt display changes")
assert(AngryEra:CanLocalPlayerOutput(), "Guild trust must not be required for a raid assistant to output")
config.allowAllAssistants = true
config.trustedPublishers = "OrdinaryAssist-Realm"
assert(
    AngryEra:CanLocalPlayerPublish("changeProposal"),
    "Receiver preferences must not grant or revoke outbound attempt authority"
)
assert(not AngryEra:CanLocalPlayerPublish("changeResult"), "Receiver overrides must not grant result authority")
assert(not AngryEra:CanLocalPlayerPublish("display"), "Receiver overrides must not grant outbound display authority")
AngryEra._protocolStarted = true
AngryEra:PermissionsUpdated()
assert(clearDisplayedCalls == 0, "Ignore-shared preference changes must not clear a locally selected display")
assert(selectedUpdateCalls == 1, "Routine permission refresh should update local controls")
assert(displayRequestCalls == 0, "Routine permission refresh must not request the active page")
assert(versionQueryCalls == 0, "Routine permission refresh must not rediscover protocol peers")
config.receiveMode = "standard"
local requested, requestResult = AngryEra:ReceiveModeUpdated("ignoreShared")
assert(requested and requestResult == "display-request-id", "Re-enabling shared updates should request current state")
assert(displayRequestCalls == 1, "A deny-to-accept receive-mode transition should request exactly once")
assert(versionQueryCalls == 0, "A receive-mode transition should not trigger unrelated discovery traffic")
requested, requestResult = AngryEra:ReceiveModeUpdated("standard")
assert(not requested and requestResult == "not-needed", "An accepting-to-accepting transition needs no request")
assert(displayRequestCalls == 1, "Equivalent accepting modes must not request the active page again")

delegatedControl = {
    Controller = "OrdinaryAssist-Realm",
    Leader = "PugLeader-Realm",
    ControllerInstallationId = "ae3i:1:2:3:4",
    ControllerSessionId = "controller-session",
    GrantId = "ae3i:9:9:9:9:controller-session:1",
}
currentPlayer = "OrdinaryAssist-Realm"
config.receiveMode = "ignoreShared"
reconcileClearsControl = false
requested, requestResult = AngryEra:ReceiveModeUpdated("standard")
assert(
    not requested and requestResult == "raid-controller-sharing-required",
    "The active controller must reject Ignore Shared locally"
)
assert(config.receiveMode == "standard", "Rejecting Ignore Shared must immediately restore the controller's prior mode")
assert(delegatedControl ~= nil, "Rejecting Ignore Shared must preserve the active controller grant")

currentPlayer = "PugLeader-Realm"
config.receiveMode = "ignoreShared"
reconcileClearsControl = true
requested, requestResult = AngryEra:ReceiveModeUpdated("standard")
assert(
    requested and requestResult == "raid-controller-revoked",
    "The actual leader selecting Ignore Shared should revoke delegated control normally"
)
assert(config.receiveMode == "ignoreShared", "The actual leader may retain Ignore Shared after reclaiming control")
assert(delegatedControl == nil, "The actual leader's Ignore Shared transition should clear the delegated grant")
assert(
    reconcileCalls[#reconcileCalls] == "raid-leader-ignore-shared",
    "The leader transition should use the normal delegated-control reconciliation path"
)
reconcileClearsControl = false
currentPlayer = "OrdinaryAssist-Realm"

AngryEra._protocolStarted = false
requested, requestResult = AngryEra:ReceiveModeUpdated("ignoreShared")
assert(not requested and requestResult == "not-needed", "A disabled protocol cannot request shared state")
assert(displayRequestCalls == 1, "Disabled protocol state must suppress receive-mode recovery traffic")
currentPlayer = "OrdinaryMember-Realm"
assert(not AngryEra:CanLocalPlayerPublish("changeProposal"), "An ordinary member may not attempt shared changes")
assert(not AngryEra:CanLocalPlayerPublish("pageUpsert"), "An ordinary member may not commit shared changes")
assert(not AngryEra:CanLocalPlayerOutput(), "An ordinary member must not output assignments to group chat")

grouped = false
assert(AngryEra:CanLocalPlayerOutput(), "Solo chat-output previews should remain available")
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
local displayButtonDisabled
local outputButtonDisabled
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
    button_display = {
        SetDisabled = function(_, disabled)
            displayButtonDisabled = disabled
        end,
    },
    button_output = {
        SetDisabled = function(_, disabled)
            outputButtonDisabled = disabled
        end,
    },
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
    displayed = 777,
    tree = {},
}
AngryAssign_Pages = {
    [777] = {
        Id = 777,
        SyncId = "remote-page",
        RevisionId = "fcs32:77777777",
        Contents = "Remote",
        LocallyOwned = false,
    },
}
activeDisplayReference = {
    SyncId = "remote-page",
    RevisionId = "fcs32:77777777",
    ContextRevisionId = "fcs32:78787878",
}
authoritativePageContextAvailable = false
AngryEra:UpdateSelected()
assert(editorDisabled == true, "Editor Save controls must disable without an authoritative remote-page context")
authoritativePageContextAvailable = true
AngryEra:UpdateSelected()
assert(editorDisabled == false, "Editor Save controls should enable when the authoritative context is available")

currentPlayer = "Officer-Realm"
SetRoster({
    { name = "PugLeader-Realm", rank = 2 },
    { name = "Officer-Realm", rank = 1 },
})
AngryEra:UpdateSelected()
assert(displayButtonDisabled == true, "Assistant editor Send should remain disabled without display authority")
assert(
    outputButtonDisabled == false,
    "Assistant editor Output should remain enabled independently of display authority"
)

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
