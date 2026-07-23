local AngryEra = {}
local app = { AngryEra = AngryEra }

assert(loadfile("modules/identity.lua"))("AngryEra", app)

local randomValues = { 16, 32, 48 }
local randomIndex = 0
local dependencies = {
    now = function()
        return 1000
    end,
    random = function()
        randomIndex = randomIndex + 1
        return randomValues[randomIndex]
    end,
}

local meta = AngryEra.identity.EnsureMeta(nil, dependencies)
assert(meta.InstallationId == "ae3i:3e8:10:20:30", "Expected deterministic installation identity")
assert(AngryEra.identity.ValidateInstallationId(meta.InstallationId), "Generated installation identity should validate")
assert(meta.SchemaVersion == 1, "Expected identity schema version 1")
assert(meta.NextEntitySequence == 0, "Expected a fresh entity sequence")
assert(type(meta.EntityLocal) == "table", "Expected local entity metadata storage")
assert(type(meta.SyncScopes) == "table", "Expected sync scope storage")
assert(meta.Migrations.InstallationIdentity == 1, "Expected completed installation identity migration")

meta.NextEntitySequence = 27
meta.EntityLocal.example = { OwnedLocally = true }
meta.SyncScopes.example = { Enabled = true }

local retained = AngryEra.identity.EnsureMeta(meta, {
    now = function()
        error("A valid installation identity must not be regenerated")
    end,
    random = function()
        error("A valid installation identity must not consume randomness")
    end,
})

assert(retained == meta, "Metadata normalization should preserve the existing table")
assert(retained.InstallationId == "ae3i:3e8:10:20:30", "Installation identity should persist")
assert(retained.NextEntitySequence == 27, "Entity sequence should persist")
assert(retained.EntityLocal.example.OwnedLocally, "Local ownership metadata should persist")
assert(retained.SyncScopes.example.Enabled, "Sync scope metadata should persist")

local repaired = AngryEra.identity.EnsureMeta({
    InstallationId = "invalid",
    SchemaVersion = 5,
    NextEntitySequence = -2,
    EntityLocal = false,
    SyncScopes = "invalid",
}, {
    now = function()
        return 2000
    end,
    random = function()
        return 1
    end,
})

assert(repaired.InstallationId == "ae3i:7d0:1:1:1", "Malformed installation identity should be repaired")
assert(repaired.SchemaVersion == 5, "A newer schema marker must not be downgraded")
assert(repaired.NextEntitySequence == 0, "Malformed counters should reset safely")
assert(type(repaired.EntityLocal) == "table", "Malformed local metadata should be repaired")
assert(type(repaired.SyncScopes) == "table", "Malformed scope metadata should be repaired")

for _, tocPath in ipairs({ "AngryEra.toc", "AngryEra_TBC.toc" }) do
    local file = assert(io.open(tocPath, "r"))
    local contents = file:read("*a")
    file:close()
    assert(contents:find("AngryAssign_Meta", 1, true), tocPath .. " should declare AngryAssign_Meta")
end

print("Identity metadata tests passed.")
