local AngryEra = {}
local app = { AngryEra = AngryEra }

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/entities.lua"))("AngryEra", app)

local installationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:a:b:c:d"

function _G.time()
    return 1000
end

local nextHash = 5000
function AngryEra:Hash()
    nextHash = nextHash + 1
    return nextHash
end

AngryAssign_Meta = {
    SchemaVersion = 1,
    InstallationId = installationId,
    NextEntitySequence = 0,
    EntityLocal = {},
    SyncScopes = {},
    Migrations = { InstallationIdentity = 1 },
}
AngryAssign_Categories = {}
AngryAssign_Pages = {}
AngryAssign_State = { displayed = nil }

AngryEra:MigrateEntityIdentities()

local ownedA = AngryEra:NewLocalPageRecord({ Name = "Owned A", Contents = "a" })
AngryAssign_Pages[ownedA.Id] = ownedA
local ownedB = AngryEra:NewLocalPageRecord({ Name = "Owned B", Contents = "b" })
AngryAssign_Pages[ownedB.Id] = ownedB
assert(AngryEra:IsLocallyOwned(ownedA) and AngryEra:IsLocallyOwned(ownedB), "factory pages are locally owned")

local function AddReceived(id, sequence, name)
    local page = { Id = id, Name = name, Contents = "received" }
    assert(AngryEra:RegisterRemoteEntityIdentity(page, "page", {
        SyncId = remoteInstallationId .. ":page:" .. sequence,
        OwnerId = remoteInstallationId,
    }))
    AngryAssign_Pages[id] = page
    return page
end

local recv1 = AddReceived(901, 1, "Received 1")
local recv2 = AddReceived(902, 2, "Received 2")
local recvPinned = AddReceived(903, 3, "Received Pinned")
local recvDisplayed = AddReceived(904, 4, "Received Displayed")
assert(not AngryEra:IsLocallyOwned(recv1), "received pages are not locally owned")

assert(AngryEra:SetPinned(recvPinned, true), "a received page can be pinned locally")
AngryAssign_State.displayed = recvDisplayed.Id

assert(AngryEra:CountReceivedPages() == 2, "only unpinned, non-displayed received pages are eligible")

local removed = AngryEra:CleanReceivedPages()
assert(removed == 2, "the two eligible received pages should be removed")
assert(AngryAssign_Pages[recv1.Id] == nil and AngryAssign_Pages[recv2.Id] == nil, "eligible received pages are gone")
assert(AngryAssign_Pages[ownedA.Id] and AngryAssign_Pages[ownedB.Id], "locally owned pages are kept")
assert(AngryAssign_Pages[recvPinned.Id], "a pinned received page is kept")
assert(AngryAssign_Pages[recvDisplayed.Id], "the displayed received page is kept")

assert(AngryAssign_Meta.EntityLocal[recv1.SyncId] == nil, "a removed received page leaves no tombstone")
assert(AngryAssign_Meta.EntityLocal[recv2.SyncId] == nil, "a removed received page leaves no tombstone")

assert(AngryEra:CleanReceivedPages() == 0, "cleanup is idempotent")
assert(AngryEra:CountReceivedPages() == 0, "no eligible received pages remain")

local unknownRemote = {
    Id = 906,
    Name = "Unknown provenance",
    Contents = "keep",
    SyncId = remoteInstallationId .. ":page:99",
    OwnerId = remoteInstallationId,
}
AngryAssign_Pages[unknownRemote.Id] = unknownRemote
AngryAssign_Meta.EntityLocal[ownedA.SyncId].OwnedLocally = false
assert(AngryEra:CountReceivedPages() == 0, "Cleanup should require explicit remote state and a foreign owner namespace")
assert(AngryEra:CleanReceivedPages() == 0, "Unknown or contradictory ownership must fail closed")
assert(AngryAssign_Pages[unknownRemote.Id] and AngryAssign_Pages[ownedA.Id], "Fail-closed pages should be retained")
AngryAssign_Meta.EntityLocal[ownedA.SyncId].OwnedLocally = true

-- Auto-clean-on-load honors the opt-in config and reports its count.
local config = { autoCleanReceivedPages = false }
local prints = {}
function AngryEra:GetConfig(key)
    return config[key]
end
function AngryEra:Print(message)
    prints[#prints + 1] = message
end

local recvC = AddReceived(905, 5, "Received C")
assert(AngryEra:AutoCleanReceivedPagesOnLoad() == 0, "auto-clean is a no-op when disabled")
assert(AngryAssign_Pages[recvC.Id], "disabled auto-clean keeps received pages")
assert(#prints == 0, "disabled auto-clean prints nothing")

config.autoCleanReceivedPages = "false"
assert(AngryEra:AutoCleanReceivedPagesOnLoad() == 0, "a truthy non-boolean config must not enable cleanup")
assert(AngryAssign_Pages[recvC.Id], "malformed auto-clean config keeps received pages")

config.autoCleanReceivedPages = true
assert(AngryEra:AutoCleanReceivedPagesOnLoad() == 1, "enabled auto-clean removes eligible received pages")
assert(AngryAssign_Pages[recvC.Id] == nil, "enabled auto-clean removed the received page")
assert(
    AngryAssign_Pages[recvPinned.Id] and AngryAssign_Pages[recvDisplayed.Id],
    "auto-clean still keeps pinned/displayed"
)
assert(#prints == 1 and prints[1]:find("1 received page"), "auto-clean reports the removed count")
assert(AngryAssign_Pages[unknownRemote.Id], "auto-clean retains pages whose remote ownership is not positively known")

print("Received page cleanup tests passed.")
