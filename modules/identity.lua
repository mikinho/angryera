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
local MAX_SYNC_ID_BYTES = 160
local MAX_INSTALLATION_ID_BYTES = 40
local INSTALLATION_COMPONENT_MODULUS = 4294967296

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
    if type(value) ~= "string" or #value > MAX_INSTALLATION_ID_BYTES then
        return false
    end

    local first, second, third, fourth = value:match("^ae3i:([0-9a-f]+):([0-9a-f]+):([0-9a-f]+):([0-9a-f]+)$")
    if not first then
        return false
    end

    for _, segment in ipairs({ first, second, third, fourth }) do
        if #segment > 8 or (#segment > 1 and segment:sub(1, 1) == "0") then
            return false
        end
    end
    return true
end

--- Parses a protocol-3 entity synchronization identifier.
-- @tparam any value Candidate identifier.
-- @treturn string|nil installationId
-- @treturn string|nil kind
-- @treturn number|nil sequence
function identity.ParseSyncId(value)
    if type(value) ~= "string" or #value > MAX_SYNC_ID_BYTES then
        return nil
    end

    local installationId, kind, sequenceText = value:match("^(.*):([%a]+):(%d+)$")
    local sequence = tonumber(sequenceText)
    if
        not identity.ValidateInstallationId(installationId)
        or (kind ~= "page" and kind ~= "category")
        or not sequence
        or sequence < 1
        or sequence % 1 ~= 0
    then
        return nil
    end

    return installationId, kind, sequence
end

--- Returns whether a SyncId is valid and optionally matches an entity kind.
-- @tparam any value Candidate identifier.
-- @tparam[opt] string expectedKind `"page"` or `"category"`.
-- @treturn boolean valid
function identity.ValidateSyncId(value, expectedKind)
    local _, kind = identity.ParseSyncId(value)
    return kind ~= nil and (expectedKind == nil or kind == expectedKind)
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
        now % INSTALLATION_COMPONENT_MODULUS,
        NormalizeInteger(random(1, 2147483647)) % INSTALLATION_COMPONENT_MODULUS,
        NormalizeInteger(random(1, 2147483647)) % INSTALLATION_COMPONENT_MODULUS,
        NormalizeInteger(random(1, 2147483647)) % INSTALLATION_COMPONENT_MODULUS
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
