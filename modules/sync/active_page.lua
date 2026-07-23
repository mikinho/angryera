-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/active_page.lua
--
-- Pure construction and canonical validation for protocol-v3 active-page data.
-- This module has no SavedVariables, networking, authorization, or UI effects.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local protocol = AngryEra.utils and AngryEra.utils.protocol
local variables = AngryEra.utils and AngryEra.utils.variables
local schema = AngryEra.sync and AngryEra.sync.schema

if not protocol or type(protocol.ValidatePayload) ~= "function" then
    error("AngryEra protocol must load before active-page synchronization")
end
if
    not variables
    or type(variables.ValidateAncestorVariableLayers) ~= "function"
    or type(variables.BuildContextRevisionInput) ~= "function"
then
    error("AngryEra variable helpers must load before active-page synchronization")
end
if not schema or type(schema.ValidateEntity) ~= "function" then
    error("AngryEra synchronization schema must load before active-page synchronization")
end
if
    protocol.LIMITS.ActivePageAncestorCount ~= variables.MAX_ANCESTOR_DEPTH
    or protocol.LIMITS.ActivePageAncestorCount ~= schema.LIMITS.HierarchyDepth
    or protocol.LIMITS.ActivePageNameBytes ~= schema.LIMITS.NameBytes
    or protocol.LIMITS.ActivePageContentsBytes ~= schema.LIMITS.ContentsBytes
    or protocol.LIMITS.ActivePageVarsBytes ~= variables.MAX_VARIABLE_BYTES
    or protocol.LIMITS.ActivePageVarsBytes ~= schema.LIMITS.VarsBytes
    or protocol.LIMITS.ActivePageAuthorBytes ~= schema.LIMITS.AuthorBytes
    or protocol.LIMITS.ActivePageSyncIdBytes ~= schema.LIMITS.SyncIdBytes
    or protocol.LIMITS.ActivePageRevisionIdBytes ~= schema.LIMITS.RevisionIdBytes
    or protocol.LIMITS.ActivePageRevision ~= schema.LIMITS.Revision
    or protocol.LIMITS.ActivePageOrder ~= schema.LIMITS.Order
    or protocol.LIMITS.ActivePageTimestamp ~= schema.LIMITS.Timestamp
then
    error("AngryEra protocol and synchronization active-page limits must match")
end

AngryEra.sync.activePage = {}
local activePage = AngryEra.sync.activePage
local EMPTY_CONTEXT_REVISION_ID = "fcs32:00000000"

local PAGE_FIELDS = {
    "Kind",
    "SyncId",
    "OwnerId",
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
    "ParentSyncId",
    "Order",
    "Name",
    "Vars",
    "Contents",
}

local function HashContextInput(canonicalInput, hashCallback)
    if type(hashCallback) ~= "function" then
        return nil, "invalid-hash-callback"
    end

    local ok, digest = pcall(hashCallback, canonicalInput)
    if not ok or type(digest) ~= "string" or #digest ~= 8 or digest:match("^[0-9a-f]+$") == nil then
        return nil, "context-hash-failed"
    end
    return "fcs32:" .. digest
end

local function CopyPage(page)
    local copy = {}
    for _, field in ipairs(PAGE_FIELDS) do
        local value = rawget(page, field)
        if value ~= nil then
            copy[field] = value
        end
    end
    return copy
end

local function BuildValidatedContextRevisionId(safeLayers, pageVariables, hashCallback)
    local canonicalInput, canonicalError = variables.BuildContextRevisionInput(safeLayers, pageVariables)
    if not canonicalInput then
        return nil, canonicalError
    end
    return HashContextInput(canonicalInput, hashCallback)
end

--- Builds the canonical active-page render-context identity.
-- The supplied ancestor layers are validated and copied before hashing.
-- @tparam table ancestorLayers Root-to-direct-parent variable layers.
-- @tparam string pageVariables Raw page variable string.
-- @tparam string|nil parentSyncId Expected direct-parent synchronization ID.
-- @tparam function hashCallback FCS32-compatible callback.
-- @treturn string|nil contextRevisionId
-- @treturn string|nil errorCode
function activePage.BuildContextRevisionId(ancestorLayers, pageVariables, parentSyncId, hashCallback)
    local safeLayers, layerError = variables.ValidateAncestorVariableLayers(ancestorLayers, parentSyncId)
    if not safeLayers then
        return nil, layerError
    end
    return BuildValidatedContextRevisionId(safeLayers, pageVariables, hashCallback)
end

--- Fully validates a protocol-v3 PAGE_UPSERT payload.
-- Structural bounds are checked by the protocol layer; canonical page and
-- render-context hashes are checked here.
-- @tparam table payload PAGE_UPSERT payload.
-- @tparam function hashCallback FCS32-compatible callback.
-- @treturn boolean valid
-- @treturn string|nil errorCode
-- @treturn table|nil detachedPayload
function activePage.ValidatePageUpsertPayload(payload, hashCallback)
    local shallowValid, shallowError = protocol.ValidatePayload("PAGE_UPSERT", payload)
    if not shallowValid then
        return false, shallowError
    end

    local entityValid, entityError = schema.ValidateEntity(payload.Page, hashCallback)
    if not entityValid then
        return false, entityError
    end

    local safeLayers, layerError =
        variables.ValidateAncestorVariableLayers(payload.AncestorVariableLayers, payload.Page.ParentSyncId)
    if not safeLayers then
        return false, layerError
    end

    local expectedContextRevisionId, contextError =
        BuildValidatedContextRevisionId(safeLayers, payload.Page.Vars, hashCallback)
    if not expectedContextRevisionId then
        return false, contextError
    end
    if payload.ContextRevisionId ~= expectedContextRevisionId then
        return false, "context-revision-id-mismatch"
    end
    return true,
        nil,
        {
            Page = CopyPage(payload.Page),
            AncestorVariableLayers = safeLayers,
            ContextRevisionId = expectedContextRevisionId,
        }
end

--- Builds a detached, fully validated protocol-v3 PAGE_UPSERT payload.
-- The returned page and ancestor-layer tables never alias caller-owned tables.
-- @tparam table page Strict canonical page wire record.
-- @tparam table ancestorLayers Root-to-direct-parent variable layers.
-- @tparam function hashCallback FCS32-compatible callback.
-- @treturn table|nil payload
-- @treturn string|nil errorCode
function activePage.BuildPageUpsertPayload(page, ancestorLayers, hashCallback)
    local shallowValid, shallowError = protocol.ValidatePayload("PAGE_UPSERT", {
        Page = page,
        AncestorVariableLayers = ancestorLayers,
        ContextRevisionId = EMPTY_CONTEXT_REVISION_ID,
    })
    if not shallowValid then
        return nil, shallowError
    end

    local entityValid, entityError = schema.ValidateEntity(page, hashCallback)
    if not entityValid then
        return nil, entityError
    end

    local safeLayers, layerError = variables.ValidateAncestorVariableLayers(ancestorLayers, page.ParentSyncId)
    if not safeLayers then
        return nil, layerError
    end

    local contextRevisionId, contextError = BuildValidatedContextRevisionId(safeLayers, page.Vars, hashCallback)
    if not contextRevisionId then
        return nil, contextError
    end

    local payload = {
        Page = CopyPage(page),
        AncestorVariableLayers = safeLayers,
        ContextRevisionId = contextRevisionId,
    }
    return payload
end
