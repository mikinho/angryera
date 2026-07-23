-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/protocol.lua
--
-- Pure protocol-v3 envelope, validation, codec, capability, and deduplication
-- helpers. This module intentionally has no WoW API dependencies.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity

if not identity or type(identity.ValidateInstallationId) ~= "function" or type(identity.ParseSyncId) ~= "function" then
    error("AngryEra identity must load before protocol")
end

AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.protocol = {}
local protocol = AngryEra.utils.protocol

protocol.VERSION = 3
protocol.PREFIX = "AngryEra3"
protocol.DISPLAY_PREFIX = "AngryEra3D"

protocol.WIRE_LIMITS = {
    EncodedBytes = 256 * 1024,
    CompressedBytes = 256 * 1024,
    SerializedBytes = 1024 * 1024,
}

protocol.LIMITS = {
    MessageTypeBytes = 32,
    InstallationIdBytes = 96,
    SessionIdBytes = 64,
    MessageIdBytes = 192,
    SenderBytes = 128,
    AddonVersionBytes = 32,
    BuildTimestampBytes = 20,
    CapabilityCount = 32,
    CapabilityNameBytes = 32,
    CapabilityVersion = 2147483647,
    ActivePageAncestorCount = 32,
    ActivePageNameBytes = 100,
    ActivePageContentsBytes = 20000,
    ActivePageVarsBytes = 5000,
    ActivePageAuthorBytes = 128,
    ActivePageSyncIdBytes = 160,
    ActivePageRevisionIdBytes = 14,
    ActivePageRevision = 2147483647,
    ActivePageOrder = 512,
    ActivePageTimestamp = 9007199254740991,
    Sequence = 2147483647,
    SeenEntries = 512,
    SeenEntriesMaximum = 4096,
}

local MESSAGE_TYPES = {
    VERSION_QUERY = true,
    VERSION = true,
    DISPLAY_REQUEST = true,
    DISPLAY = true,
    PAGE_REQUEST = true,
    PAGE_UPSERT = true,
}
protocol.MESSAGE_TYPES = MESSAGE_TYPES

local CLIENT_FLAVORS = {
    ERA = true,
    TBC = true,
    WRATH = true,
    RETAIL = true,
}
protocol.CLIENT_FLAVORS = CLIENT_FLAVORS

local function IsInteger(value, minimum, maximum)
    return type(value) == "number"
        and value == value
        and value >= minimum
        and value <= maximum
        and value == math.floor(value)
end

local function IsBoundedString(value, maximum, allowEmpty)
    return type(value) == "string" and (allowEmpty or value ~= "") and #value <= maximum
end

local function IsIdentifier(value, maximum)
    return IsBoundedString(value, maximum, false) and value:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
end

local function IsPlainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function IsInstallationId(value)
    return IsBoundedString(value, protocol.LIMITS.InstallationIdBytes, false) and identity.ValidateInstallationId(value)
end

local function IsSyncId(value, kind)
    if not IsBoundedString(value, protocol.LIMITS.ActivePageSyncIdBytes, false) then
        return false
    end

    local installationId, parsedKind, sequence = identity.ParseSyncId(value)
    return parsedKind == kind
        and IsInteger(sequence, 1, protocol.LIMITS.ActivePageRevision)
        and value == string.format("%s:%s:%d", installationId, parsedKind, sequence)
end

local function IsRevisionId(value)
    return type(value) == "string"
        and #value == protocol.LIMITS.ActivePageRevisionIdBytes
        and value:match("^fcs32:[0-9a-f]+$") ~= nil
end

local function ValidateKnownFields(value, knownFields, requiredFields, prefix)
    for key in pairs(value) do
        if type(key) ~= "string" or not knownFields[key] then
            return false, prefix .. "-unknown-field"
        end
    end
    for _, field in ipairs(requiredFields) do
        if rawget(value, field) == nil then
            return false, prefix .. "-missing-" .. field
        end
    end
    return true
end

local function DenseArrayLength(value, maximum)
    if not IsPlainTable(value) then
        return nil
    end

    local count = 0
    local highest = 0
    for key in pairs(value) do
        if not IsInteger(key, 1, maximum) then
            return nil
        end
        count = count + 1
        if key > highest then
            highest = key
        end
    end
    if count ~= highest then
        return nil
    end
    return count
end

local function ValidateMessageId(value)
    if not IsBoundedString(value, protocol.LIMITS.MessageIdBytes, false) then
        return false
    end

    local installationId, sessionId, sequenceText = value:match("^(.*):([^:]+):([0-9]+)$")
    local sequence = tonumber(sequenceText)
    return IsInstallationId(installationId)
        and IsIdentifier(sessionId, protocol.LIMITS.SessionIdBytes)
        and IsInteger(sequence, 1, protocol.LIMITS.Sequence)
        and sequenceText == tostring(sequence)
end

local function ValidateWireLimits(limits)
    limits = limits or protocol.WIRE_LIMITS
    if type(limits) ~= "table" then
        return nil, "invalid-limits"
    end

    local encoded = limits.EncodedBytes
    local compressed = limits.CompressedBytes
    local serialized = limits.SerializedBytes
    if
        not IsInteger(encoded, 1, protocol.WIRE_LIMITS.EncodedBytes)
        or not IsInteger(compressed, 1, protocol.WIRE_LIMITS.CompressedBytes)
        or not IsInteger(serialized, 1, protocol.WIRE_LIMITS.SerializedBytes)
    then
        return nil, "invalid-limits"
    end

    return {
        EncodedBytes = encoded,
        CompressedBytes = compressed,
        SerializedBytes = serialized,
    }
end

local function ValidateCodec(codec)
    if type(codec) ~= "table" then
        return false
    end

    return type(codec.serialize) == "function"
        and type(codec.deserialize) == "function"
        and type(codec.compress) == "function"
        and type(codec.decompress) == "function"
        and type(codec.encode) == "function"
        and type(codec.decode) == "function"
end

local function CallStringTransform(callback, input, errorCode)
    local ok, output = pcall(callback, input)
    if not ok or type(output) ~= "string" or output == "" then
        return nil, errorCode
    end
    return output
end

local function CallBoundedDecompress(callback, input, maximumOutputBytes)
    local ok, output, status = pcall(callback, input, maximumOutputBytes)
    if status == "output-too-large" then
        return nil, "serialized-too-large"
    end
    if not ok or type(output) ~= "string" or output == "" then
        return nil, "decompress-failed"
    end
    if #output > maximumOutputBytes then
        return nil, "serialized-too-large"
    end
    return output
end

local ACTIVE_REFERENCE_FIELDS = {
    SyncId = true,
    RevisionId = true,
    ContextRevisionId = true,
}

local ACTIVE_REFERENCE_REQUIRED_FIELDS = {
    "SyncId",
    "RevisionId",
    "ContextRevisionId",
}

local DISPLAY_FIELDS = {
    Displayed = true,
    SyncId = true,
    RevisionId = true,
    ContextRevisionId = true,
}

local PAGE_UPSERT_FIELDS = {
    Page = true,
    AncestorVariableLayers = true,
    ContextRevisionId = true,
}

local PAGE_UPSERT_REQUIRED_FIELDS = {
    "Page",
    "AncestorVariableLayers",
    "ContextRevisionId",
}

local PAGE_FIELDS = {
    Kind = true,
    SyncId = true,
    OwnerId = true,
    Revision = true,
    RevisionId = true,
    UpdatedAt = true,
    UpdatedBy = true,
    ParentSyncId = true,
    Order = true,
    Name = true,
    Vars = true,
    Contents = true,
}

local PAGE_REQUIRED_FIELDS = {
    "Kind",
    "SyncId",
    "OwnerId",
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
    "Order",
    "Name",
    "Vars",
    "Contents",
}

local ANCESTOR_LAYER_FIELDS = {
    SyncId = true,
    Vars = true,
}

local ANCESTOR_LAYER_REQUIRED_FIELDS = {
    "SyncId",
    "Vars",
}

local function ValidateEmptyPayload(payload, prefix)
    if next(payload) ~= nil then
        return false, prefix .. "-payload-not-empty"
    end
    return true
end

local function ValidateActiveReference(payload, prefix)
    local known, knownError =
        ValidateKnownFields(payload, ACTIVE_REFERENCE_FIELDS, ACTIVE_REFERENCE_REQUIRED_FIELDS, prefix)
    if not known then
        return false, knownError
    end
    if not IsSyncId(payload.SyncId, "page") then
        return false, "invalid-sync-id"
    end
    if not IsRevisionId(payload.RevisionId) then
        return false, "invalid-revision-id"
    end
    if not IsRevisionId(payload.ContextRevisionId) then
        return false, "invalid-context-revision-id"
    end
    return true
end

local function ValidateDisplayPayload(payload)
    local known, knownError = ValidateKnownFields(payload, DISPLAY_FIELDS, { "Displayed" }, "display")
    if not known then
        return false, knownError
    end
    if type(payload.Displayed) ~= "boolean" then
        return false, "invalid-displayed"
    end

    if not payload.Displayed then
        if payload.SyncId ~= nil or payload.RevisionId ~= nil or payload.ContextRevisionId ~= nil then
            return false, "display-clear-has-page"
        end
        return true
    end

    local reference = {
        SyncId = payload.SyncId,
        RevisionId = payload.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
    return ValidateActiveReference(reference, "display")
end

local function ValidateShallowPage(page)
    if not IsPlainTable(page) then
        return false, "invalid-page"
    end
    local known, knownError = ValidateKnownFields(page, PAGE_FIELDS, PAGE_REQUIRED_FIELDS, "page")
    if not known then
        return false, knownError
    end
    if page.Kind ~= "page" then
        return false, "invalid-page-kind"
    end
    if not IsSyncId(page.SyncId, "page") then
        return false, "invalid-page-sync-id"
    end
    if not IsInstallationId(page.OwnerId) then
        return false, "invalid-page-owner-id"
    end
    local syncInstallationId = identity.ParseSyncId(page.SyncId)
    if page.OwnerId ~= syncInstallationId then
        return false, "owner-mismatch"
    end
    if not IsInteger(page.Revision, 1, protocol.LIMITS.ActivePageRevision) then
        return false, "invalid-page-revision"
    end
    if not IsRevisionId(page.RevisionId) then
        return false, "invalid-page-revision-id"
    end
    if not IsInteger(page.UpdatedAt, 0, protocol.LIMITS.ActivePageTimestamp) then
        return false, "invalid-page-updated-at"
    end
    if not IsBoundedString(page.UpdatedBy, protocol.LIMITS.ActivePageAuthorBytes, false) then
        return false, "invalid-page-updated-by"
    end
    if page.ParentSyncId ~= nil and not IsSyncId(page.ParentSyncId, "category") then
        return false, "invalid-page-parent-sync-id"
    end
    if not IsInteger(page.Order, 1, protocol.LIMITS.ActivePageOrder) then
        return false, "invalid-page-order"
    end
    if not IsBoundedString(page.Name, protocol.LIMITS.ActivePageNameBytes, false) then
        return false, "invalid-page-name"
    end
    if not IsBoundedString(page.Vars, protocol.LIMITS.ActivePageVarsBytes, true) then
        return false, "invalid-page-vars"
    end
    if not IsBoundedString(page.Contents, protocol.LIMITS.ActivePageContentsBytes, true) then
        return false, "invalid-page-contents"
    end
    return true
end

local function ValidateShallowAncestorLayers(layers)
    local count = DenseArrayLength(layers, protocol.LIMITS.ActivePageAncestorCount)
    if not count then
        return false, "invalid-ancestor-layers"
    end

    for index = 1, count do
        local layer = layers[index]
        if not IsPlainTable(layer) then
            return false, "invalid-ancestor-layer"
        end
        local known, knownError =
            ValidateKnownFields(layer, ANCESTOR_LAYER_FIELDS, ANCESTOR_LAYER_REQUIRED_FIELDS, "ancestor-layer")
        if not known then
            return false, knownError
        end
        if not IsSyncId(layer.SyncId, "category") then
            return false, "invalid-ancestor-sync-id"
        end
        if not IsBoundedString(layer.Vars, protocol.LIMITS.ActivePageVarsBytes, true) then
            return false, "invalid-ancestor-vars"
        end
    end
    return true
end

local function ValidatePageUpsertPayload(payload)
    local known, knownError =
        ValidateKnownFields(payload, PAGE_UPSERT_FIELDS, PAGE_UPSERT_REQUIRED_FIELDS, "page-upsert")
    if not known then
        return false, knownError
    end

    local validPage, pageError = ValidateShallowPage(payload.Page)
    if not validPage then
        return false, pageError
    end
    local validLayers, layerError = ValidateShallowAncestorLayers(payload.AncestorVariableLayers)
    if not validLayers then
        return false, layerError
    end
    if not IsRevisionId(payload.ContextRevisionId) then
        return false, "invalid-context-revision-id"
    end
    return true
end

--- Validates a capability-version map.
-- @tparam table capabilities Capability names mapped to positive integer schema versions.
-- @treturn boolean valid
-- @treturn string|nil errorCode
function protocol.ValidateCapabilities(capabilities)
    if type(capabilities) ~= "table" then
        return false, "invalid-capabilities"
    end

    local count = 0
    for name, version in pairs(capabilities) do
        count = count + 1
        if count > protocol.LIMITS.CapabilityCount then
            return false, "too-many-capabilities"
        end
        if
            not IsBoundedString(name, protocol.LIMITS.CapabilityNameBytes, false)
            or name:match("^[a-z][A-Za-z0-9]*$") == nil
        then
            return false, "invalid-capability-name"
        end
        if not IsInteger(version, 1, protocol.LIMITS.CapabilityVersion) then
            return false, "invalid-capability-version"
        end
    end

    return true
end

--- Validates a message payload for its declared protocol message type.
-- Active-page payload validation here is deliberately structural. Canonical
-- entity and render-context hashes are verified by the synchronization layer.
-- @tparam string messageType Protocol message type.
-- @tparam table payload Message payload.
-- @treturn boolean valid
-- @treturn string|nil errorCode
function protocol.ValidatePayload(messageType, payload)
    if not MESSAGE_TYPES[messageType] then
        return false, "unknown-message-type"
    end
    if not IsPlainTable(payload) then
        return false, "invalid-payload"
    end

    if messageType == "VERSION_QUERY" then
        return ValidateEmptyPayload(payload, "version-query")
    elseif messageType == "DISPLAY_REQUEST" then
        return ValidateEmptyPayload(payload, "display-request")
    elseif messageType == "DISPLAY" then
        return ValidateDisplayPayload(payload)
    elseif messageType == "PAGE_REQUEST" then
        return ValidateActiveReference(payload, "page-request")
    elseif messageType == "PAGE_UPSERT" then
        return ValidatePageUpsertPayload(payload)
    end

    if not IsBoundedString(payload.AddonVersion, protocol.LIMITS.AddonVersionBytes, false) then
        return false, "invalid-addon-version"
    end
    if not IsBoundedString(payload.BuildTimestamp, protocol.LIMITS.BuildTimestampBytes, false) then
        return false, "invalid-build-timestamp"
    end
    if not CLIENT_FLAVORS[payload.Flavor] then
        return false, "invalid-client-flavor"
    end

    local validCapabilities, capabilityError = protocol.ValidateCapabilities(payload.Capabilities)
    if not validCapabilities then
        return false, capabilityError
    end

    if payload.AcceptsCurrentGroup ~= nil and type(payload.AcceptsCurrentGroup) ~= "boolean" then
        return false, "invalid-accepts-current-group"
    end

    return true
end

--- Creates protocol session state from dependency-supplied stable and ephemeral IDs.
-- Session IDs are generated by runtime code because this pure module has no clock,
-- random-number source, or WoW character APIs.
-- @tparam string installationId Stable account-installation identifier.
-- @tparam string sessionId Ephemeral identifier unique to one addon enable.
-- @treturn table|nil session
-- @treturn string|nil errorCode
function protocol.NewSession(installationId, sessionId)
    if not IsInstallationId(installationId) then
        return nil, "invalid-installation-id"
    end
    if not IsIdentifier(sessionId, protocol.LIMITS.SessionIdBytes) then
        return nil, "invalid-session-id"
    end

    return {
        InstallationId = installationId,
        SessionId = sessionId,
        Sequence = 0,
    }
end

--- Validates a named protocol-v3 envelope and its type-specific payload.
-- @tparam table envelope Decoded envelope.
-- @treturn boolean valid
-- @treturn string|nil errorCode
function protocol.ValidateEnvelope(envelope)
    if type(envelope) ~= "table" then
        return false, "invalid-envelope"
    end
    if envelope.Protocol ~= protocol.VERSION then
        return false, "invalid-protocol"
    end
    if
        not IsBoundedString(envelope.Type, protocol.LIMITS.MessageTypeBytes, false)
        or envelope.Type:match("^[A-Z][A-Z0-9_]*$") == nil
    then
        return false, "invalid-message-type"
    end
    if not MESSAGE_TYPES[envelope.Type] then
        return false, "unknown-message-type"
    end
    if not IsInstallationId(envelope.SenderInstallationId) then
        return false, "invalid-installation-id"
    end
    if not IsIdentifier(envelope.SenderSessionId, protocol.LIMITS.SessionIdBytes) then
        return false, "invalid-session-id"
    end
    if not IsInteger(envelope.Sequence, 1, protocol.LIMITS.Sequence) then
        return false, "invalid-sequence"
    end
    if not ValidateMessageId(envelope.MessageId) then
        return false, "invalid-message-id"
    end

    local expectedMessageId = table.concat({
        envelope.SenderInstallationId,
        envelope.SenderSessionId,
        tostring(envelope.Sequence),
    }, ":")
    if envelope.MessageId ~= expectedMessageId then
        return false, "message-id-mismatch"
    end

    if envelope.ReplyTo ~= nil and not ValidateMessageId(envelope.ReplyTo) then
        return false, "invalid-reply-to"
    end
    if not IsInteger(envelope.SentAt, 0, 9007199254740991) then
        return false, "invalid-sent-at"
    end

    return protocol.ValidatePayload(envelope.Type, envelope.Payload)
end

--- Builds the next envelope for a session without mutating the session on error.
-- @tparam table session Session returned by `NewSession`.
-- @tparam string messageType Protocol message type.
-- @tparam table payload Type-specific payload.
-- @tparam table options Requires `SentAt`; may include `ReplyTo`.
-- @treturn table|nil envelope
-- @treturn string|nil errorCode
function protocol.BuildEnvelope(session, messageType, payload, options)
    if type(session) ~= "table" then
        return nil, "invalid-session"
    end
    if not IsInstallationId(session.InstallationId) then
        return nil, "invalid-installation-id"
    end
    if not IsIdentifier(session.SessionId, protocol.LIMITS.SessionIdBytes) then
        return nil, "invalid-session-id"
    end
    if not IsInteger(session.Sequence, 0, protocol.LIMITS.Sequence) then
        return nil, "invalid-sequence"
    end
    if session.Sequence >= protocol.LIMITS.Sequence then
        return nil, "sequence-exhausted"
    end

    if options ~= nil and type(options) ~= "table" then
        return nil, "invalid-options"
    end
    options = options or {}
    local nextSequence = session.Sequence + 1
    local envelope = {
        Protocol = protocol.VERSION,
        Type = messageType,
        MessageId = table.concat({ session.InstallationId, session.SessionId, tostring(nextSequence) }, ":"),
        ReplyTo = options.ReplyTo,
        SenderInstallationId = session.InstallationId,
        SenderSessionId = session.SessionId,
        Sequence = nextSequence,
        SentAt = options.SentAt,
        Payload = payload,
    }

    local valid, validationError = protocol.ValidateEnvelope(envelope)
    if not valid then
        return nil, validationError
    end

    session.Sequence = nextSequence
    return envelope
end

--- Serializes, compresses, and encodes a validated protocol envelope.
-- Codec callbacks are regular functions, not methods. They must return one value:
-- strings for transforms and a decoded table for `deserialize`.
-- @tparam table envelope Protocol envelope.
-- @tparam table codec Dependency-injected codec callbacks.
-- @tparam[opt] table limits Wire limits, primarily overridden by tests.
-- @treturn string|nil encoded
-- @treturn string|nil errorCode
function protocol.EncodeEnvelope(envelope, codec, limits)
    local valid, validationError = protocol.ValidateEnvelope(envelope)
    if not valid then
        return nil, validationError
    end
    if not ValidateCodec(codec) then
        return nil, "invalid-codec"
    end

    local wireLimits, limitError = ValidateWireLimits(limits)
    if not wireLimits then
        return nil, limitError
    end

    local serialized, serializeError = CallStringTransform(codec.serialize, envelope, "serialize-failed")
    if not serialized then
        return nil, serializeError
    end
    if #serialized > wireLimits.SerializedBytes then
        return nil, "serialized-too-large"
    end

    local compressed, compressError = CallStringTransform(codec.compress, serialized, "compress-failed")
    if not compressed then
        return nil, compressError
    end
    if #compressed > wireLimits.CompressedBytes then
        return nil, "compressed-too-large"
    end

    local encoded, encodeError = CallStringTransform(codec.encode, compressed, "encode-failed")
    if not encoded then
        return nil, encodeError
    end
    if #encoded > wireLimits.EncodedBytes then
        return nil, "encoded-too-large"
    end

    return encoded
end

--- Decodes, decompresses, deserializes, and validates a protocol envelope.
-- The trusted codec must abort decompression before exceeding the supplied
-- output budget and return `nil, "output-too-large"`.
-- @tparam string encoded Encoded wire data.
-- @tparam table codec Dependency-injected codec callbacks.
-- @tparam[opt] table limits Wire limits, primarily overridden by tests.
-- @treturn table|nil envelope
-- @treturn string|nil errorCode
function protocol.DecodeEnvelope(encoded, codec, limits)
    if type(encoded) ~= "string" or encoded == "" then
        return nil, "invalid-encoded"
    end
    if not ValidateCodec(codec) then
        return nil, "invalid-codec"
    end

    local wireLimits, limitError = ValidateWireLimits(limits)
    if not wireLimits then
        return nil, limitError
    end
    if #encoded > wireLimits.EncodedBytes then
        return nil, "encoded-too-large"
    end

    local compressed, decodeError = CallStringTransform(codec.decode, encoded, "decode-failed")
    if not compressed then
        return nil, decodeError
    end
    if #compressed > wireLimits.CompressedBytes then
        return nil, "compressed-too-large"
    end

    local serialized, decompressError = CallBoundedDecompress(codec.decompress, compressed, wireLimits.SerializedBytes)
    if not serialized then
        return nil, decompressError
    end

    local okDeserialize, envelope = pcall(codec.deserialize, serialized)
    if not okDeserialize or type(envelope) ~= "table" then
        return nil, "deserialize-failed"
    end

    local valid, validationError = protocol.ValidateEnvelope(envelope)
    if not valid then
        return nil, validationError
    end

    return envelope
end

--- Returns the mutually supported version for each shared capability.
-- @tparam table localCapabilities Local capability map.
-- @tparam table remoteCapabilities Remote capability map.
-- @treturn table|nil negotiated
-- @treturn string|nil errorCode
function protocol.NegotiateCapabilities(localCapabilities, remoteCapabilities)
    local validLocal, localError = protocol.ValidateCapabilities(localCapabilities)
    if not validLocal then
        return nil, localError
    end
    local validRemote, remoteError = protocol.ValidateCapabilities(remoteCapabilities)
    if not validRemote then
        return nil, remoteError
    end

    local negotiated = {}
    for name, localVersion in pairs(localCapabilities) do
        local remoteVersion = remoteCapabilities[name]
        if remoteVersion then
            if localVersion < remoteVersion then
                negotiated[name] = localVersion
            else
                negotiated[name] = remoteVersion
            end
        end
    end
    return negotiated
end

--- Returns whether a validated capability map meets a minimum schema version.
-- Invalid maps or requests return `false`.
-- @tparam table capabilities Capability map.
-- @tparam string name Capability name.
-- @tparam[opt=1] number minimumVersion Required version.
-- @treturn boolean supported
function protocol.Supports(capabilities, name, minimumVersion)
    local valid = protocol.ValidateCapabilities(capabilities)
    minimumVersion = minimumVersion or 1
    if
        not valid
        or not IsBoundedString(name, protocol.LIMITS.CapabilityNameBytes, false)
        or name:match("^[a-z][A-Za-z0-9]*$") == nil
        or not IsInteger(minimumVersion, 1, protocol.LIMITS.CapabilityVersion)
    then
        return false
    end

    return capabilities[name] ~= nil and capabilities[name] >= minimumVersion
end

--- Creates a bounded FIFO message-ID cache.
-- @tparam[opt=512] number maxEntries Maximum remembered sender/message pairs.
-- @treturn table|nil cache
-- @treturn string|nil errorCode
function protocol.NewSeenCache(maxEntries)
    maxEntries = maxEntries or protocol.LIMITS.SeenEntries
    if not IsInteger(maxEntries, 1, protocol.LIMITS.SeenEntriesMaximum) then
        return nil, "invalid-seen-cache-size"
    end

    return {
        MaxEntries = maxEntries,
        Entries = {},
        Order = {},
        NextIndex = 1,
        Size = 0,
    }
end

--- Checks and records a message ID scoped to its authenticated addon sender.
-- @tparam table cache Cache returned by `NewSeenCache`.
-- @tparam string sender Authenticated `Name-Realm` sender.
-- @tparam string messageId Valid protocol message ID.
-- @treturn boolean|nil duplicate `true` if already seen, otherwise `false`.
-- @treturn string|nil errorCode
function protocol.SeenOrRemember(cache, sender, messageId)
    if
        type(cache) ~= "table"
        or type(cache.Entries) ~= "table"
        or type(cache.Order) ~= "table"
        or not IsInteger(cache.MaxEntries, 1, protocol.LIMITS.SeenEntriesMaximum)
        or not IsInteger(cache.NextIndex, 1, cache.MaxEntries)
        or not IsInteger(cache.Size, 0, cache.MaxEntries)
    then
        return nil, "invalid-seen-cache"
    end
    if not IsBoundedString(sender, protocol.LIMITS.SenderBytes, false) then
        return nil, "invalid-sender"
    end
    if not ValidateMessageId(messageId) then
        return nil, "invalid-message-id"
    end

    local key = sender .. "\0" .. messageId
    if cache.Entries[key] then
        return true
    end

    local expired = cache.Order[cache.NextIndex]
    if expired then
        cache.Entries[expired] = nil
    else
        cache.Size = cache.Size + 1
    end

    cache.Order[cache.NextIndex] = key
    cache.Entries[key] = true
    cache.NextIndex = cache.NextIndex + 1
    if cache.NextIndex > cache.MaxEntries then
        cache.NextIndex = 1
    end

    return false
end
