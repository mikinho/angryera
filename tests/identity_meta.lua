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
assert(not AngryEra.identity.ValidateInstallationId("ae3i:03e8:10:20:30"), "Leading-zero segments should be rejected")
assert(not AngryEra.identity.ValidateInstallationId("ae3i:3E8:10:20:30"), "Uppercase hex segments should be rejected")
assert(
    not AngryEra.identity.ValidateInstallationId("ae3i:100000000:1:2:3"),
    "Installation identity components must fit compact unsigned fields"
)
assert(AngryEra.identity.ValidateInstallationId("ae3i:0:1:2:3"), "Canonical zero segments should remain valid")
assert(meta.SchemaVersion == 1, "Expected identity schema version 1")
assert(meta.NextEntitySequence == 0, "Expected a fresh entity sequence")
assert(type(meta.EntityLocal) == "table", "Expected local entity metadata storage")
assert(type(meta.SyncScopes) == "table", "Expected sync scope storage")
assert(meta.Migrations.InstallationIdentity == 1, "Expected completed installation identity migration")

randomIndex = 0
local wrapped = AngryEra.identity.GenerateInstallationId({
    now = function()
        return 4294967297
    end,
    random = dependencies.random,
})
assert(wrapped == "ae3i:1:10:20:30", "Generated installation components should remain unsigned 32-bit values")

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

retained.NextEntitySequence = 1
retained.EntityLocal[retained.InstallationId .. ":page:91"] = {
    OwnedLocally = true,
    DeletedLocally = true,
}
retained.EntityLocal["ae3i:a:b:c:d:page:999"] = {
    OwnedLocally = false,
}
AngryEra.identity.EnsureMeta(retained, {
    now = function()
        error("Counter repair must retain a valid installation identity")
    end,
    random = function()
        error("Counter repair must not consume randomness")
    end,
})
assert(retained.NextEntitySequence == 91, "Retained local identities should repair a regressed entity counter")
assert(retained.EntitySequenceHighWater == 91, "Counter repair should persist a durable high-water mark")
retained.EntityLocal[retained.InstallationId .. ":page:91"] = nil
retained.NextEntitySequence = 0
AngryEra.identity.EnsureMeta(retained, {
    now = function()
        error("Durable counter repair must retain a valid installation identity")
    end,
    random = function()
        error("Durable counter repair must not consume randomness")
    end,
})
assert(retained.NextEntitySequence == 91, "The durable high-water mark should survive retained-state pruning")

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
assert(repaired.EntitySequenceHighWater == 0, "Malformed high-water marks should reset safely")
assert(type(repaired.EntityLocal) == "table", "Malformed local metadata should be repaired")
assert(type(repaired.SyncScopes) == "table", "Malformed scope metadata should be repaired")

for _, tocPath in ipairs({ "AngryEra.toc", "AngryEra_TBC.toc" }) do
    local file = assert(io.open(tocPath, "r"))
    local contents = file:read("*a")
    file:close()
    assert(contents:find("AngryAssign_Meta", 1, true), tocPath .. " should declare AngryAssign_Meta")
end

print("Identity metadata tests passed.")
