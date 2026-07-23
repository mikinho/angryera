-- -------------------------------------------------------------------------------
-- Angry Era: modules/identity.lua
--
-- Durable installation identity and synchronization metadata.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

AngryEra.identity = AngryEra.identity or {}
local identity = AngryEra.identity

local CURRENT_SCHEMA_VERSION = 1
local INSTALLATION_ID_PATTERN = "^ae3i:%x+:%x+:%x+:%x+$"

local function NormalizeInteger(value)
    if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
        return 0
    end
    return value
end

--- Returns whether a value is a supported installation identifier.
-- @tparam any value Candidate identifier.
-- @treturn boolean valid
function identity.ValidateInstallationId(value)
    return type(value) == "string" and #value <= 96 and value:match(INSTALLATION_ID_PATTERN) ~= nil
end

--- Generates a non-secret, opaque installation identifier.
-- Dependencies are injectable so migration behavior can be tested outside WoW.
-- @tparam table dependencies Clock and random providers.
-- @treturn string installationId
function identity.GenerateInstallationId(dependencies)
    local now = NormalizeInteger(dependencies.now())
    local random = dependencies.random
    return string.format(
        "ae3i:%x:%x:%x:%x",
        now,
        NormalizeInteger(random(1, 2147483647)),
        NormalizeInteger(random(1, 2147483647)),
        NormalizeInteger(random(1, 2147483647))
    )
end

--- Normalizes the account-wide synchronization metadata table.
-- @tparam any meta Existing SavedVariable value.
-- @tparam table dependencies Clock and random providers.
-- @treturn table normalizedMeta
function identity.EnsureMeta(meta, dependencies)
    if type(meta) ~= "table" then
        meta = {}
    end

    if not identity.ValidateInstallationId(meta.InstallationId) then
        meta.InstallationId = identity.GenerateInstallationId(dependencies)
    end

    meta.NextEntitySequence = NormalizeInteger(meta.NextEntitySequence)
    if type(meta.EntityLocal) ~= "table" then
        meta.EntityLocal = {}
    end
    if type(meta.SyncScopes) ~= "table" then
        meta.SyncScopes = {}
    end
    if type(meta.Migrations) ~= "table" then
        meta.Migrations = {}
    end

    meta.Migrations.InstallationIdentity = CURRENT_SCHEMA_VERSION
    if type(meta.SchemaVersion) ~= "number" or meta.SchemaVersion < CURRENT_SCHEMA_VERSION then
        meta.SchemaVersion = CURRENT_SCHEMA_VERSION
    end

    return meta
end

--- Initializes account-wide identity metadata without replacing a valid identity.
-- @treturn table meta
function AngryEra:InitializeIdentityStorage()
    AngryAssign_Meta = identity.EnsureMeta(AngryAssign_Meta, {
        now = time,
        random = math.random,
    })
    return AngryAssign_Meta
end

--- Returns this installation's persistent identifier.
-- @treturn string installationId
function AngryEra:GetInstallationId()
    if not AngryAssign_Meta or not identity.ValidateInstallationId(AngryAssign_Meta.InstallationId) then
        self:InitializeIdentityStorage()
    end
    return AngryAssign_Meta.InstallationId
end
