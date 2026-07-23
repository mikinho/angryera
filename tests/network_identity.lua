local helpers = {
    EnsureUnitFullName = function(name)
        if name and not name:find("-", 1, true) then
            return name .. "-Realm"
        end
        return name
    end,
    EnsureUnitShortName = function(name)
        return name
    end,
    PlayerFullName = function()
        return "Follower-Realm"
    end,
    IterateGroupMembers = function() end,
    ValidateString = function(value, maxLength)
        if type(value) ~= "string" then
            return ""
        end
        return value:sub(1, maxLength)
    end,
}

local AngryEra = {
    Title = "Angry Era",
    Version = "dev",
    Timestamp = "dev",
    utils = {
        helpers = helpers,
    },
    core = {
        comPrefix = "AngryEra1",
        updateFrequency = 2,
        MAX_COMM_ENCODED_BYTES = 256 * 1024,
        MAX_COMM_DECODED_BYTES = 256 * 1024,
        MAX_COMM_SERIALIZED_BYTES = 1024 * 1024,
        COMMAND = 1,
        PAGE_Id = 2,
        PAGE_Updated = 3,
        PAGE_Name = 4,
        PAGE_Contents = 5,
        PAGE_UpdateId = 6,
        PAGE_Vars = 7,
        REQUEST_PAGE_Id = 2,
        DISPLAY_Id = 2,
        DISPLAY_Updated = 3,
        DISPLAY_UpdateId = 4,
        VERSION_Version = 2,
        VERSION_Timestamp = 3,
        VERSION_ValidRaid = 4,
    },
}

local app = {
    AngryEra = AngryEra,
    libs = {
        libS = {},
        libC = {},
        libCE = {},
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/entities.lua"))("AngryEra", app)
assert(loadfile("modules/network.lua"))("AngryEra", app)

AngryAssign_Meta = {
    SchemaVersion = 1,
    InstallationId = "ae3i:1:2:3:4",
    NextEntitySequence = 0,
    EntityLocal = {},
    SyncScopes = {},
    Migrations = {
        InstallationIdentity = 1,
    },
}
AngryAssign_Categories = {}
AngryAssign_Pages = {
    [5] = {
        Id = 5,
        Name = "Local Page",
        Contents = "Keep me",
        Updated = 1,
        UpdateId = "local-update",
    },
}
AngryAssign_State = {
    displayed = nil,
    tree = {},
}

function _G.time()
    return 1000
end

local nextLocalId = 100
function AngryEra:Hash(name)
    if name == "legacy" then
        return 4242
    end
    nextLocalId = nextLocalId + 1
    return nextLocalId
end

function AngryEra:CanReceiveFrom()
    return true
end

function AngryEra:CanLocalPlayerPublish()
    return true
end

function AngryEra:GetRaidLeader()
    return "Leader-Realm"
end

function AngryEra:SelectedId()
    return nil
end

function AngryEra:PushHistory() end
function AngryEra:UpdateTree() end
function AngryEra:UpdateDisplayed() end
function AngryEra:ShowDisplay() end
function AngryEra:DisplayUpdateNotification() end
function AngryEra:SendRequestPage()
    error("A matching displayed revision should not request the page")
end

AngryEra:MigrateEntityIdentities()
local localPage = AngryAssign_Pages[5]
local localSyncId = localPage.SyncId

AngryEra:ProcessMessage("Leader-Realm", {
    "PAGE",
    5,
    10,
    "Remote Page",
    "Remote contents",
    "remote-update-1",
    nil,
})

assert(AngryAssign_Pages[5] == localPage, "An inbound numeric id must not replace a locally owned page")
assert(localPage.SyncId == localSyncId, "Local identity should remain unchanged after a numeric collision")
assert(localPage.Contents == "Keep me", "Local content should remain unchanged after a numeric collision")

local wireIdentity = AngryEra:BuildLegacyRemoteIdentity("Leader-Realm", "page", 5)
local remotePage = AngryEra:GetPageBySyncId(wireIdentity.SyncId)
assert(remotePage, "The remote page should be stored under its provenance identity")
assert(remotePage.Id ~= 5, "A colliding remote page should receive a different local numeric id")
assert(not AngryEra:IsLocallyOwned(remotePage), "The remote page must remain remotely owned")

AngryEra:ProcessMessage("Assistant-Realm", {
    "PAGE",
    5,
    11,
    "Remote Page",
    "Assistant update",
    "remote-update-2",
    nil,
})

assert(
    AngryEra:GetPageBySyncId(wireIdentity.SyncId) == remotePage,
    "Assistants should resolve the leader's legacy page"
)
assert(remotePage.Contents == "Assistant update", "Authorized assistant updates should target the remote record")

local pageCount = 0
for _ in pairs(AngryAssign_Pages) do
    pageCount = pageCount + 1
end
assert(pageCount == 2, "Repeated legacy updates should not create duplicate records")

local sentMessage
function AngryEra:SendOutMessage(message)
    sentMessage = message
    return true
end

AngryEra:SendPageMessage(remotePage.Id)
assert(sentMessage[2] == 5, "A remapped remote page should retain its PAGE wire id")

AngryEra:SendDisplayMessage(remotePage.Id)
assert(sentMessage[2] == 5, "A remapped remote page should retain its DISPLAY wire id")

local requestedLocalId
function AngryEra:SendPage(id)
    requestedLocalId = id
end

AngryEra:ProcessMessage("Requester-Realm", {
    "REQUEST_PAGE",
    5,
})
assert(requestedLocalId == remotePage.Id, "A requested wire id should resolve to the remapped local record")

AngryEra:ProcessMessage("Leader-Realm", {
    "DISPLAY",
    5,
    11,
    "remote-update-2",
})
assert(AngryAssign_State.displayed == remotePage.Id, "Legacy display ids should resolve through remote identity")

for _, invalidId in ipairs({ 0, -1, 1.5, math.huge, -math.huge }) do
    local ok = pcall(function()
        AngryEra:ProcessMessage("Leader-Realm", {
            "PAGE",
            invalidId,
            12,
            "Invalid",
            "Invalid",
            "invalid-update",
        })
    end)
    assert(ok, "Malformed numeric page ids must be rejected without raising errors")
end

print("Network identity tests passed.")
