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
protocol.PAGE_PREFIX = "AngryEra3C"
protocol.ACTIVE_PAGE_PREFIX = "AngryEra3P"

protocol.WIRE_LIMITS = {
    EncodedBytes = 256 * 1024,
    CompressedBytes = 256 * 1024,
    SerializedBytes = 1024 * 1024,
}

-- AceComm reserves one byte when a single-frame payload starts with one of its
-- control markers. Keeping compact DISPLAY below 255 bytes guarantees that
-- even the escaped representation remains one physical addon-message frame.
protocol.COMPACT_DISPLAY_FORMAT = 1
protocol.COMPACT_DISPLAY_LIMITS = {
    EncodedBytes = 254,
    PackedBytes = 237,
    RawBytes = 207,
}

-- Compact PAGE_UPSERT keeps the binary payload below the generic serializer
-- ceiling while leaving room for a compressor header and channel encoding.
-- Every variable-length field also has its own semantic bound below.
protocol.COMPACT_PAGE_FORMAT = 2
protocol.COMPACT_PAGE_LIMITS = {
    EncodedBytes = 256 * 1024,
    CompressedBytes = 256 * 1024 - 5,
    -- Exact maximum produced by the current bounded fields, including all 32
    -- maximum-size ancestor layers and the longest correlated identity.
    RawBytes = 186162,
}

protocol.LIMITS = {
    MessageTypeBytes = 32,
    InstallationIdBytes = 40,
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

local UINT32_MAXIMUM = 4294967295
local MAX_SAFE_INTEGER = 9007199254740991
local COMPACT_DISPLAY_FLAG_DISPLAYED = 1
local COMPACT_DISPLAY_FLAG_REPLY_TO = 2
local COMPACT_DISPLAY_FLAG_PAGE_FOLLOWS = 4
local COMPACT_DISPLAY_KNOWN_FLAGS = COMPACT_DISPLAY_FLAG_DISPLAYED
    + COMPACT_DISPLAY_FLAG_REPLY_TO
    + COMPACT_DISPLAY_FLAG_PAGE_FOLLOWS
local COMPACT_PAGE_FLAG_REPLY_TO = 1
local COMPACT_PAGE_FLAG_ANCESTOR_CONTEXT_INCLUDED = 2
local COMPACT_PAGE_KNOWN_FLAGS = COMPACT_PAGE_FLAG_REPLY_TO + COMPACT_PAGE_FLAG_ANCESTOR_CONTEXT_INCLUDED
local HEX_DIGITS = "0123456789abcdef"

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

local function ValidateCompactDisplayCodec(codec)
    return type(codec) == "table" and type(codec.encode) == "function" and type(codec.decode) == "function"
end

local function ValidateCompactPageCodec(codec)
    return type(codec) == "table"
        and type(codec.compress) == "function"
        and type(codec.decompress) == "function"
        and type(codec.encode) == "function"
        and type(codec.decode) == "function"
        and type(codec.hash) == "function"
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
    PageFollows = true,
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
    if payload.PageFollows ~= nil and type(payload.PageFollows) ~= "boolean" then
        return false, "invalid-page-follows"
    end

    if not payload.Displayed then
        if payload.SyncId ~= nil or payload.RevisionId ~= nil or payload.ContextRevisionId ~= nil then
            return false, "display-clear-has-page"
        end
        if payload.PageFollows == true then
            return false, "display-clear-page-follows"
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
-- @tparam table options Requires millisecond `SentAt`; may include `ReplyTo`.
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

local function EncodeHexInteger(value, minimumDigits)
    local encoded = {}
    repeat
        local digit = value % 16
        table.insert(encoded, 1, HEX_DIGITS:sub(digit + 1, digit + 1))
        value = math.floor(value / 16)
    until value == 0
    while #encoded < (minimumDigits or 1) do
        table.insert(encoded, 1, "0")
    end
    return table.concat(encoded)
end

local function ParseCompactInstallationId(value)
    if not IsInstallationId(value) then
        return nil
    end
    local first, second, third, fourth = value:match("^ae3i:([0-9a-f]+):([0-9a-f]+):([0-9a-f]+):([0-9a-f]+)$")
    local encoded = {}
    for index, component in ipairs({ first, second, third, fourth }) do
        if #component > 8 then
            return nil
        end
        local number = tonumber(component, 16)
        if not IsInteger(number, 0, UINT32_MAXIMUM) or EncodeHexInteger(number) ~= component then
            return nil
        end
        encoded[index] = number
    end
    return encoded
end

local function AppendUnsigned(parts, value, byteCount, maximum)
    if not IsInteger(value, 0, maximum) then
        return false
    end
    for _ = 1, byteCount do
        local byte = value % 256
        parts[#parts + 1] = string.char(byte)
        value = math.floor(value / 256)
    end
    return value == 0
end

local function ReadUnsigned(raw, cursor, byteCount, maximum)
    if cursor + byteCount - 1 > #raw then
        return nil
    end

    local value = 0
    local multiplier = 1
    for offset = 0, byteCount - 1 do
        local byte = raw:byte(cursor + offset)
        if byte > math.floor((maximum - value) / multiplier) then
            return nil
        end
        value = value + byte * multiplier
        multiplier = multiplier * 256
    end
    return value, cursor + byteCount
end

local function AppendCompactInstallationId(parts, value)
    local components = ParseCompactInstallationId(value)
    if not components then
        return false
    end
    for _, component in ipairs(components) do
        if not AppendUnsigned(parts, component, 4, UINT32_MAXIMUM) then
            return false
        end
    end
    return true
end

local function ReadCompactInstallationId(raw, cursor)
    local components = {}
    for index = 1, 4 do
        local component
        component, cursor = ReadUnsigned(raw, cursor, 4, UINT32_MAXIMUM)
        if component == nil then
            return nil
        end
        components[index] = EncodeHexInteger(component)
    end
    return "ae3i:" .. table.concat(components, ":"), cursor
end

local function AppendCompactSessionId(parts, value)
    if not IsIdentifier(value, protocol.LIMITS.SessionIdBytes) then
        return false
    end
    parts[#parts + 1] = string.char(#value)
    parts[#parts + 1] = value
    return true
end

local function ReadCompactSessionId(raw, cursor)
    local length = raw:byte(cursor)
    if not length or length < 1 or length > protocol.LIMITS.SessionIdBytes then
        return nil
    end
    local first = cursor + 1
    local last = first + length - 1
    if last > #raw then
        return nil
    end
    return raw:sub(first, last), last + 1
end

local function ParseMessageIdComponents(value)
    if not ValidateMessageId(value) then
        return nil
    end
    local installationId, sessionId, sequenceText = value:match("^(.*):([^:]+):([0-9]+)$")
    return installationId, sessionId, tonumber(sequenceText)
end

local function AppendCompactMessageId(parts, value)
    local installationId, sessionId, sequence = ParseMessageIdComponents(value)
    return installationId ~= nil
        and AppendCompactInstallationId(parts, installationId)
        and AppendCompactSessionId(parts, sessionId)
        and AppendUnsigned(parts, sequence, 4, UINT32_MAXIMUM)
end

local function ReadCompactMessageId(raw, cursor)
    local installationId
    installationId, cursor = ReadCompactInstallationId(raw, cursor)
    if not installationId then
        return nil
    end
    local sessionId
    sessionId, cursor = ReadCompactSessionId(raw, cursor)
    if not sessionId then
        return nil
    end
    local sequence
    sequence, cursor = ReadUnsigned(raw, cursor, 4, UINT32_MAXIMUM)
    if sequence == nil then
        return nil
    end
    return table.concat({ installationId, sessionId, tostring(sequence) }, ":"), cursor
end

local function AppendLengthPrefixedString(parts, value, byteCount, maximum, allowEmpty)
    if not IsBoundedString(value, maximum, allowEmpty) then
        return false
    end
    if not AppendUnsigned(parts, #value, byteCount, maximum) then
        return false
    end
    parts[#parts + 1] = value
    return true
end

local function ReadLengthPrefixedString(raw, cursor, byteCount, maximum, allowEmpty)
    local length
    length, cursor = ReadUnsigned(raw, cursor, byteCount, maximum)
    if length == nil or (not allowEmpty and length == 0) then
        return nil
    end
    local last = cursor + length - 1
    if last > #raw then
        return nil
    end
    return raw:sub(cursor, last), last + 1
end

local function AppendCompactSyncId(parts, value, expectedKind)
    if not IsSyncId(value, expectedKind) then
        return false
    end
    local installationId, _, sequence = identity.ParseSyncId(value)
    return AppendCompactInstallationId(parts, installationId)
        and AppendUnsigned(parts, sequence, 4, protocol.LIMITS.ActivePageRevision)
end

local function ReadCompactSyncId(raw, cursor, kind)
    local installationId
    installationId, cursor = ReadCompactInstallationId(raw, cursor)
    if not installationId then
        return nil
    end
    local sequence
    sequence, cursor = ReadUnsigned(raw, cursor, 4, protocol.LIMITS.ActivePageRevision)
    if sequence == nil or sequence < 1 then
        return nil
    end
    return table.concat({ installationId, kind, tostring(sequence) }, ":"), cursor
end

local function ParseRevisionCode(value)
    if not IsRevisionId(value) then
        return nil
    end
    return tonumber(value:sub(7), 16)
end

local function AppendCompactRevisionId(parts, value)
    local revision = ParseRevisionCode(value)
    return revision ~= nil and AppendUnsigned(parts, revision, 4, UINT32_MAXIMUM)
end

local function ReadCompactRevisionId(raw, cursor)
    local revision
    revision, cursor = ReadUnsigned(raw, cursor, 4, UINT32_MAXIMUM)
    if revision == nil then
        return nil
    end
    return "fcs32:" .. EncodeHexInteger(revision, 8), cursor
end

local function BuildCompactPageAncestorContextBytes(layers)
    local valid, validationError = ValidateShallowAncestorLayers(layers)
    if not valid then
        return nil, nil, validationError
    end

    local count = #layers
    local parts = {}
    if not AppendUnsigned(parts, count, 1, protocol.LIMITS.ActivePageAncestorCount) then
        return nil, nil, "unsupported-compact-page-ancestor-count"
    end
    local safeLayers = {}
    for index = 1, count do
        local layer = layers[index]
        if
            not AppendCompactSyncId(parts, layer.SyncId, "category")
            or not AppendLengthPrefixedString(parts, layer.Vars, 2, protocol.LIMITS.ActivePageVarsBytes, true)
        then
            return nil, nil, "unsupported-compact-page-layer"
        end
        safeLayers[index] = {
            SyncId = layer.SyncId,
            Vars = layer.Vars,
        }
    end
    return table.concat(parts), safeLayers
end

local function HashCompactPageAncestorContext(ancestorContextBytes, codec)
    if type(codec) ~= "table" or type(codec.hash) ~= "function" then
        return nil, "invalid-compact-page-hash-codec"
    end
    local ok, digest = pcall(codec.hash, ancestorContextBytes)
    if not ok then
        return nil, "compact-page-ancestor-hash-failed"
    end
    if type(digest) ~= "string" or #digest ~= 8 or digest:match("^[0-9a-f]+$") == nil then
        return nil, "invalid-compact-page-ancestor-digest"
    end
    return "fcs32:" .. digest
end

--- Builds the compact wire identity for one canonical ancestor-variable context.
-- The hashed bytes are exactly the inline wire block: count followed by each
-- compact category SyncId and length-prefixed variable string.
-- @tparam table layers Ordered root-to-parent ancestor layers.
-- @tparam table codec Codec containing a regular `hash` callback.
-- @treturn string|nil ancestorContextId
-- @treturn string|nil errorCode
-- @treturn number|nil ancestorContextBytes
function protocol.BuildCompactPageAncestorContextId(layers, codec)
    local ancestorContextBytes, _, contextError = BuildCompactPageAncestorContextBytes(layers)
    if not ancestorContextBytes then
        return nil, contextError
    end
    local contextId, hashError = HashCompactPageAncestorContext(ancestorContextBytes, codec)
    if not contextId then
        return nil, hashError
    end
    return contextId, nil, #ancestorContextBytes
end

local function AppendCompactDisplayReference(parts, payload)
    local installationId, kind, sequence = identity.ParseSyncId(payload.SyncId)
    local revision = ParseRevisionCode(payload.RevisionId)
    local contextRevision = ParseRevisionCode(payload.ContextRevisionId)
    return kind == "page"
        and AppendCompactInstallationId(parts, installationId)
        and AppendUnsigned(parts, sequence, 4, UINT32_MAXIMUM)
        and AppendUnsigned(parts, revision, 4, UINT32_MAXIMUM)
        and AppendUnsigned(parts, contextRevision, 4, UINT32_MAXIMUM)
end

local function ReadCompactDisplayReference(raw, cursor)
    local installationId
    installationId, cursor = ReadCompactInstallationId(raw, cursor)
    if not installationId then
        return nil
    end
    local sequence
    sequence, cursor = ReadUnsigned(raw, cursor, 4, UINT32_MAXIMUM)
    if sequence == nil then
        return nil
    end
    local revision
    revision, cursor = ReadUnsigned(raw, cursor, 4, UINT32_MAXIMUM)
    if revision == nil then
        return nil
    end
    local contextRevision
    contextRevision, cursor = ReadUnsigned(raw, cursor, 4, UINT32_MAXIMUM)
    if contextRevision == nil then
        return nil
    end
    return {
        Displayed = true,
        SyncId = installationId .. ":page:" .. tostring(sequence),
        RevisionId = "fcs32:" .. EncodeHexInteger(revision, 8),
        ContextRevisionId = "fcs32:" .. EncodeHexInteger(contextRevision, 8),
    },
        cursor
end

local function PackCompactDisplayRaw(raw)
    local packed = {}
    local buffer = 0
    local bufferedBits = 0
    for index = 1, #raw do
        buffer = buffer + raw:byte(index) * 2 ^ bufferedBits
        bufferedBits = bufferedBits + 8
        while bufferedBits >= 7 do
            local symbol = buffer % 128
            packed[#packed + 1] = string.char(symbol + 2)
            buffer = math.floor(buffer / 128)
            bufferedBits = bufferedBits - 7
        end
    end
    if bufferedBits > 0 then
        packed[#packed + 1] = string.char(buffer + 2)
    end
    return table.concat(packed)
end

local function UnpackCompactDisplayRaw(packed)
    if #packed > protocol.COMPACT_DISPLAY_LIMITS.PackedBytes then
        return nil, "compact-display-packed-too-large"
    end

    local raw = {}
    local buffer = 0
    local bufferedBits = 0
    for index = 1, #packed do
        local byte = packed:byte(index)
        if byte < 2 or byte > 129 then
            return nil, "invalid-compact-display-packing"
        end
        buffer = buffer + (byte - 2) * 2 ^ bufferedBits
        bufferedBits = bufferedBits + 7
        while bufferedBits >= 8 do
            raw[#raw + 1] = string.char(buffer % 256)
            buffer = math.floor(buffer / 256)
            bufferedBits = bufferedBits - 8
        end
    end

    local decoded = table.concat(raw)
    if #packed ~= math.ceil(#decoded * 8 / 7) then
        return nil, "noncanonical-compact-display-length"
    end
    if buffer ~= 0 then
        return nil, "noncanonical-compact-display-padding"
    end
    return decoded
end

--- Encodes one DISPLAY envelope into the bounded single-frame wire format.
-- Protocol/type/message identity fields that can be derived canonically are
-- omitted and reconstructed by `DecodeCompactDisplayEnvelope`.
-- @tparam table envelope Valid protocol-v3 DISPLAY envelope.
-- @tparam table codec Channel codec with regular `encode` and `decode` functions.
-- @treturn string|nil encoded
-- @treturn string|nil errorCode
function protocol.EncodeCompactDisplayEnvelope(envelope, codec)
    local valid, validationError = protocol.ValidateEnvelope(envelope)
    if not valid then
        return nil, validationError
    end
    if envelope.Type ~= "DISPLAY" then
        return nil, "compact-display-type-mismatch"
    end
    if not ValidateCompactDisplayCodec(codec) then
        return nil, "invalid-compact-display-codec"
    end

    local flags = envelope.Payload.Displayed and COMPACT_DISPLAY_FLAG_DISPLAYED or 0
    if envelope.ReplyTo ~= nil then
        flags = flags + COMPACT_DISPLAY_FLAG_REPLY_TO
    end
    if envelope.Payload.PageFollows == true then
        flags = flags + COMPACT_DISPLAY_FLAG_PAGE_FOLLOWS
    end
    local parts = {
        string.char(protocol.COMPACT_DISPLAY_FORMAT),
        string.char(flags),
    }
    if
        not AppendCompactInstallationId(parts, envelope.SenderInstallationId)
        or not AppendCompactSessionId(parts, envelope.SenderSessionId)
        or not AppendUnsigned(parts, envelope.Sequence, 4, UINT32_MAXIMUM)
        or not AppendUnsigned(parts, envelope.SentAt, 7, MAX_SAFE_INTEGER)
    then
        return nil, "unsupported-compact-display-identity"
    end
    if envelope.ReplyTo ~= nil and not AppendCompactMessageId(parts, envelope.ReplyTo) then
        return nil, "unsupported-compact-display-reply-to"
    end
    if envelope.Payload.Displayed and not AppendCompactDisplayReference(parts, envelope.Payload) then
        return nil, "unsupported-compact-display-reference"
    end

    local raw = table.concat(parts)
    if #raw > protocol.COMPACT_DISPLAY_LIMITS.RawBytes then
        return nil, "compact-display-raw-too-large"
    end
    local packed = PackCompactDisplayRaw(raw)
    if #packed > protocol.COMPACT_DISPLAY_LIMITS.PackedBytes then
        return nil, "compact-display-packed-too-large"
    end
    local encoded, encodeError = CallStringTransform(codec.encode, packed, "compact-display-encode-failed")
    if not encoded then
        return nil, encodeError
    end
    if #encoded > protocol.COMPACT_DISPLAY_LIMITS.EncodedBytes then
        return nil, "compact-display-encoded-too-large"
    end
    return encoded
end

--- Decodes the bounded single-frame DISPLAY representation into a normal
-- validated protocol envelope.
-- @tparam string encoded Compact channel-encoded DISPLAY.
-- @tparam table codec Channel codec with regular `encode` and `decode` functions.
-- @treturn table|nil envelope
-- @treturn string|nil errorCode
function protocol.DecodeCompactDisplayEnvelope(encoded, codec)
    if type(encoded) ~= "string" or encoded == "" then
        return nil, "invalid-compact-display-encoded"
    end
    if not ValidateCompactDisplayCodec(codec) then
        return nil, "invalid-compact-display-codec"
    end
    if #encoded > protocol.COMPACT_DISPLAY_LIMITS.EncodedBytes then
        return nil, "compact-display-encoded-too-large"
    end

    local packed, decodeError = CallStringTransform(codec.decode, encoded, "compact-display-decode-failed")
    if not packed then
        return nil, decodeError
    end
    local raw, packingError = UnpackCompactDisplayRaw(packed)
    if not raw then
        return nil, packingError
    end
    if #raw > protocol.COMPACT_DISPLAY_LIMITS.RawBytes then
        return nil, "compact-display-raw-too-large"
    end
    if raw:byte(1) ~= protocol.COMPACT_DISPLAY_FORMAT then
        return nil, "unsupported-compact-display-format"
    end
    local flags = raw:byte(2)
    if not flags or flags < 0 or flags > COMPACT_DISPLAY_KNOWN_FLAGS then
        return nil, "invalid-compact-display-flags"
    end
    local displayed = flags % 2 == COMPACT_DISPLAY_FLAG_DISPLAYED
    local hasReplyTo = math.floor(flags / COMPACT_DISPLAY_FLAG_REPLY_TO) % 2 == 1
    local pageFollows = math.floor(flags / COMPACT_DISPLAY_FLAG_PAGE_FOLLOWS) % 2 == 1
    if pageFollows and not displayed then
        return nil, "invalid-compact-display-flags"
    end

    local cursor = 3
    local senderInstallationId
    senderInstallationId, cursor = ReadCompactInstallationId(raw, cursor)
    if not senderInstallationId then
        return nil, "invalid-compact-display"
    end
    local senderSessionId
    senderSessionId, cursor = ReadCompactSessionId(raw, cursor)
    if not senderSessionId then
        return nil, "invalid-compact-display"
    end
    local sequence
    sequence, cursor = ReadUnsigned(raw, cursor, 4, UINT32_MAXIMUM)
    if sequence == nil then
        return nil, "invalid-compact-display"
    end
    local sentAt
    sentAt, cursor = ReadUnsigned(raw, cursor, 7, MAX_SAFE_INTEGER)
    if sentAt == nil then
        return nil, "invalid-compact-display"
    end

    local replyTo
    if hasReplyTo then
        replyTo, cursor = ReadCompactMessageId(raw, cursor)
        if not replyTo then
            return nil, "invalid-compact-display"
        end
    end

    local payload
    if displayed then
        payload, cursor = ReadCompactDisplayReference(raw, cursor)
        if not payload then
            return nil, "invalid-compact-display"
        end
        if pageFollows then
            payload.PageFollows = true
        end
    else
        payload = {
            Displayed = false,
        }
    end
    if cursor ~= #raw + 1 then
        return nil, "compact-display-trailing-data"
    end

    local envelope = {
        Protocol = protocol.VERSION,
        Type = "DISPLAY",
        MessageId = table.concat({ senderInstallationId, senderSessionId, tostring(sequence) }, ":"),
        ReplyTo = replyTo,
        SenderInstallationId = senderInstallationId,
        SenderSessionId = senderSessionId,
        Sequence = sequence,
        SentAt = sentAt,
        Payload = payload,
    }
    local valid, validationError = protocol.ValidateEnvelope(envelope)
    if not valid then
        return nil, validationError
    end
    return envelope
end

local function ValidateCompactPageEncodeOptions(options)
    if options == nil then
        return true
    end
    if not IsPlainTable(options) then
        return nil, "invalid-compact-page-options"
    end
    for key in pairs(options) do
        if key ~= "IncludeAncestorContext" then
            return nil, "compact-page-options-unknown-field"
        end
    end
    if options.IncludeAncestorContext ~= nil and type(options.IncludeAncestorContext) ~= "boolean" then
        return nil, "invalid-ancestor-context-inclusion"
    end
    return options.IncludeAncestorContext ~= false
end

local function ValidateCompactPageDecodeOptions(options)
    if options == nil then
        return nil
    end
    if not IsPlainTable(options) then
        return nil, "invalid-compact-page-options"
    end
    for key in pairs(options) do
        if key ~= "ResolveAncestorContext" then
            return nil, "compact-page-options-unknown-field"
        end
    end
    if options.ResolveAncestorContext ~= nil and type(options.ResolveAncestorContext) ~= "function" then
        return nil, "invalid-ancestor-context-resolver"
    end
    return options.ResolveAncestorContext
end

local function ReadCompactPageAncestorContextBytes(raw, cursor)
    local first = cursor
    local count
    count, cursor = ReadUnsigned(raw, cursor, 1, protocol.LIMITS.ActivePageAncestorCount)
    if count == nil then
        return nil
    end

    local layers = {}
    for index = 1, count do
        local syncId
        syncId, cursor = ReadCompactSyncId(raw, cursor, "category")
        if not syncId then
            return nil
        end
        local vars
        vars, cursor = ReadLengthPrefixedString(raw, cursor, 2, protocol.LIMITS.ActivePageVarsBytes, true)
        if vars == nil then
            return nil
        end
        layers[index] = {
            SyncId = syncId,
            Vars = vars,
        }
    end
    return layers, cursor, raw:sub(first, cursor - 1)
end

local function BuildCompactPageMetadata(envelope, ancestorContextId, ancestorContextIncluded, ancestorContextBytes)
    return {
        AncestorContextId = ancestorContextId,
        AncestorContextIncluded = ancestorContextIncluded,
        AncestorContextBytes = ancestorContextBytes,
        SenderInstallationId = envelope.SenderInstallationId,
        SenderSessionId = envelope.SenderSessionId,
        MessageId = envelope.MessageId,
        Sequence = envelope.Sequence,
        SentAt = envelope.SentAt,
        ReplyTo = envelope.ReplyTo,
        Reference = {
            SyncId = envelope.Payload.Page.SyncId,
            RevisionId = envelope.Payload.Page.RevisionId,
            ContextRevisionId = envelope.Payload.ContextRevisionId,
        },
    }
end

local function EncodeCompactPageRaw(envelope, codec, includeAncestorContext)
    local page = envelope.Payload.Page
    local layers = envelope.Payload.AncestorVariableLayers
    local layerCount = #layers
    local derivedParentSyncId = layerCount > 0 and layers[layerCount].SyncId or nil
    if page.ParentSyncId ~= derivedParentSyncId then
        return nil, "unsupported-compact-page-parent"
    end

    local ancestorContextBytes, _, contextError = BuildCompactPageAncestorContextBytes(layers)
    if not ancestorContextBytes then
        return nil, contextError
    end
    local ancestorContextId, hashError = HashCompactPageAncestorContext(ancestorContextBytes, codec)
    if not ancestorContextId then
        return nil, hashError
    end
    local ancestorContextIncluded = includeAncestorContext or layerCount == 0
    if not ancestorContextIncluded and envelope.ReplyTo ~= nil then
        return nil, "compact-page-ancestor-context-reference-correlated"
    end

    local flags = envelope.ReplyTo ~= nil and COMPACT_PAGE_FLAG_REPLY_TO or 0
    if ancestorContextIncluded then
        flags = flags + COMPACT_PAGE_FLAG_ANCESTOR_CONTEXT_INCLUDED
    end
    local parts = {
        string.char(flags),
    }
    if
        not AppendCompactInstallationId(parts, envelope.SenderInstallationId)
        or not AppendCompactSessionId(parts, envelope.SenderSessionId)
        or not AppendUnsigned(parts, envelope.Sequence, 4, UINT32_MAXIMUM)
        or not AppendUnsigned(parts, envelope.SentAt, 7, MAX_SAFE_INTEGER)
    then
        return nil, "unsupported-compact-page-identity"
    end
    if envelope.ReplyTo ~= nil and not AppendCompactMessageId(parts, envelope.ReplyTo) then
        return nil, "unsupported-compact-page-reply-to"
    end

    if
        not AppendCompactSyncId(parts, page.SyncId, "page")
        or not AppendUnsigned(parts, page.Revision, 4, protocol.LIMITS.ActivePageRevision)
        or not AppendCompactRevisionId(parts, page.RevisionId)
        or not AppendUnsigned(parts, page.UpdatedAt, 7, protocol.LIMITS.ActivePageTimestamp)
        or not AppendLengthPrefixedString(parts, page.UpdatedBy, 1, protocol.LIMITS.ActivePageAuthorBytes, false)
        or not AppendUnsigned(parts, page.Order, 2, protocol.LIMITS.ActivePageOrder)
        or not AppendLengthPrefixedString(parts, page.Name, 1, protocol.LIMITS.ActivePageNameBytes, false)
        or not AppendLengthPrefixedString(parts, page.Vars, 2, protocol.LIMITS.ActivePageVarsBytes, true)
        or not AppendLengthPrefixedString(parts, page.Contents, 2, protocol.LIMITS.ActivePageContentsBytes, true)
        or not AppendCompactRevisionId(parts, ancestorContextId)
    then
        return nil, "unsupported-compact-page-payload"
    end

    if ancestorContextIncluded then
        parts[#parts + 1] = ancestorContextBytes
    end
    if not AppendCompactRevisionId(parts, envelope.Payload.ContextRevisionId) then
        return nil, "unsupported-compact-page-context-revision"
    end
    return table.concat(parts),
        nil,
        BuildCompactPageMetadata(envelope, ancestorContextId, ancestorContextIncluded, #ancestorContextBytes)
end

local function DecodeCompactPageRaw(raw, codec, resolveAncestorContext)
    local flags = raw:byte(1)
    if flags == nil or flags > COMPACT_PAGE_KNOWN_FLAGS then
        return nil, "invalid-compact-page-flags"
    end
    local hasReplyTo = flags % 2 == COMPACT_PAGE_FLAG_REPLY_TO
    local ancestorContextIncluded = math.floor(flags / COMPACT_PAGE_FLAG_ANCESTOR_CONTEXT_INCLUDED) % 2 == 1
    if hasReplyTo and not ancestorContextIncluded then
        return nil, "invalid-compact-page-flags"
    end
    local cursor = 2

    local senderInstallationId
    senderInstallationId, cursor = ReadCompactInstallationId(raw, cursor)
    if not senderInstallationId then
        return nil, "invalid-compact-page"
    end
    local senderSessionId
    senderSessionId, cursor = ReadCompactSessionId(raw, cursor)
    if not senderSessionId then
        return nil, "invalid-compact-page"
    end
    local sequence
    sequence, cursor = ReadUnsigned(raw, cursor, 4, UINT32_MAXIMUM)
    if sequence == nil then
        return nil, "invalid-compact-page"
    end
    local sentAt
    sentAt, cursor = ReadUnsigned(raw, cursor, 7, MAX_SAFE_INTEGER)
    if sentAt == nil then
        return nil, "invalid-compact-page"
    end

    local replyTo
    if hasReplyTo then
        replyTo, cursor = ReadCompactMessageId(raw, cursor)
        if not replyTo then
            return nil, "invalid-compact-page"
        end
    end

    local pageSyncId
    pageSyncId, cursor = ReadCompactSyncId(raw, cursor, "page")
    if not pageSyncId then
        return nil, "invalid-compact-page"
    end
    local pageOwnerId = identity.ParseSyncId(pageSyncId)
    local pageRevision
    pageRevision, cursor = ReadUnsigned(raw, cursor, 4, protocol.LIMITS.ActivePageRevision)
    if pageRevision == nil then
        return nil, "invalid-compact-page"
    end
    local pageRevisionId
    pageRevisionId, cursor = ReadCompactRevisionId(raw, cursor)
    if not pageRevisionId then
        return nil, "invalid-compact-page"
    end
    local pageUpdatedAt
    pageUpdatedAt, cursor = ReadUnsigned(raw, cursor, 7, protocol.LIMITS.ActivePageTimestamp)
    if pageUpdatedAt == nil then
        return nil, "invalid-compact-page"
    end
    local pageUpdatedBy
    pageUpdatedBy, cursor = ReadLengthPrefixedString(raw, cursor, 1, protocol.LIMITS.ActivePageAuthorBytes, false)
    if not pageUpdatedBy then
        return nil, "invalid-compact-page"
    end
    local pageOrder
    pageOrder, cursor = ReadUnsigned(raw, cursor, 2, protocol.LIMITS.ActivePageOrder)
    if pageOrder == nil then
        return nil, "invalid-compact-page"
    end
    local pageName
    pageName, cursor = ReadLengthPrefixedString(raw, cursor, 1, protocol.LIMITS.ActivePageNameBytes, false)
    if not pageName then
        return nil, "invalid-compact-page"
    end
    local pageVars
    pageVars, cursor = ReadLengthPrefixedString(raw, cursor, 2, protocol.LIMITS.ActivePageVarsBytes, true)
    if pageVars == nil then
        return nil, "invalid-compact-page"
    end
    local pageContents
    pageContents, cursor = ReadLengthPrefixedString(raw, cursor, 2, protocol.LIMITS.ActivePageContentsBytes, true)
    if pageContents == nil then
        return nil, "invalid-compact-page"
    end

    local ancestorContextId
    ancestorContextId, cursor = ReadCompactRevisionId(raw, cursor)
    if not ancestorContextId then
        return nil, "invalid-compact-page"
    end

    local embeddedLayers
    local embeddedAncestorContextBytes
    if ancestorContextIncluded then
        embeddedLayers, cursor, embeddedAncestorContextBytes = ReadCompactPageAncestorContextBytes(raw, cursor)
        if not embeddedLayers then
            return nil, "invalid-compact-page"
        end
    end

    local contextRevisionId
    contextRevisionId, cursor = ReadCompactRevisionId(raw, cursor)
    if not contextRevisionId then
        return nil, "invalid-compact-page"
    end
    if cursor ~= #raw + 1 then
        return nil, "compact-page-trailing-data"
    end

    local function BuildEnvelope(layers)
        return {
            Protocol = protocol.VERSION,
            Type = "PAGE_UPSERT",
            MessageId = table.concat({ senderInstallationId, senderSessionId, tostring(sequence) }, ":"),
            ReplyTo = replyTo,
            SenderInstallationId = senderInstallationId,
            SenderSessionId = senderSessionId,
            Sequence = sequence,
            SentAt = sentAt,
            Payload = {
                Page = {
                    Kind = "page",
                    SyncId = pageSyncId,
                    OwnerId = pageOwnerId,
                    Revision = pageRevision,
                    RevisionId = pageRevisionId,
                    UpdatedAt = pageUpdatedAt,
                    UpdatedBy = pageUpdatedBy,
                    ParentSyncId = #layers > 0 and layers[#layers].SyncId or nil,
                    Order = pageOrder,
                    Name = pageName,
                    Vars = pageVars,
                    Contents = pageContents,
                },
                AncestorVariableLayers = layers,
                ContextRevisionId = contextRevisionId,
            },
        }
    end

    -- Validate every embedded envelope field before exposing identity metadata
    -- to a resolver or caller. The temporary empty layer set is never returned.
    local embeddedEnvelope = BuildEnvelope({})
    local embeddedValid, embeddedError = protocol.ValidateEnvelope(embeddedEnvelope)
    if not embeddedValid then
        return nil, embeddedError
    end

    local ancestorContextBytes
    local layers
    if ancestorContextIncluded then
        local rebuiltBytes, safeLayers, contextError = BuildCompactPageAncestorContextBytes(embeddedLayers)
        if not rebuiltBytes then
            return nil, contextError
        end
        if rebuiltBytes ~= embeddedAncestorContextBytes then
            return nil, "noncanonical-compact-page-ancestor-context"
        end
        ancestorContextBytes = rebuiltBytes
        layers = safeLayers
    else
        local missingMetadata = BuildCompactPageMetadata(embeddedEnvelope, ancestorContextId, false, nil)
        if not resolveAncestorContext then
            return nil, "compact-page-ancestor-context-missing", missingMetadata
        end
        local ok, resolvedLayers =
            pcall(resolveAncestorContext, senderInstallationId, senderSessionId, ancestorContextId)
        if not ok then
            return nil, "compact-page-ancestor-context-resolver-failed"
        end
        if resolvedLayers == nil then
            return nil, "compact-page-ancestor-context-missing", missingMetadata
        end
        local resolvedBytes, safeLayers = BuildCompactPageAncestorContextBytes(resolvedLayers)
        if not resolvedBytes then
            return nil, "invalid-resolved-ancestor-context"
        end
        if #safeLayers == 0 then
            return nil, "compact-page-empty-ancestor-context-omitted"
        end
        ancestorContextBytes = resolvedBytes
        layers = safeLayers
    end

    local expectedAncestorContextId, hashError = HashCompactPageAncestorContext(ancestorContextBytes, codec)
    if not expectedAncestorContextId then
        return nil, hashError
    end
    if expectedAncestorContextId ~= ancestorContextId then
        return nil, "compact-page-ancestor-context-id-mismatch"
    end

    local envelope = BuildEnvelope(layers)
    local valid, validationError = protocol.ValidateEnvelope(envelope)
    if not valid then
        return nil, validationError
    end
    return envelope,
        nil,
        BuildCompactPageMetadata(envelope, ancestorContextId, ancestorContextIncluded, #ancestorContextBytes)
end

--- Encodes one PAGE_UPSERT envelope into the compact binary page wire format.
-- Protocol/type/message identity, page kind/owner, and direct parent are
-- reconstructed canonically instead of being repeated on the wire.
-- @tparam table envelope Valid protocol-v3 PAGE_UPSERT envelope.
-- @tparam table codec Bounded compression, channel codec, and hash callbacks.
-- @tparam[opt] table options Compact page encoding options.
-- @treturn string|nil encoded
-- @treturn string|nil errorCode
-- @treturn table|nil metadata
function protocol.EncodeCompactPageEnvelope(envelope, codec, options)
    local valid, validationError = protocol.ValidateEnvelope(envelope)
    if not valid then
        return nil, validationError
    end
    if envelope.Type ~= "PAGE_UPSERT" then
        return nil, "compact-page-type-mismatch"
    end
    if not ValidateCompactPageCodec(codec) then
        return nil, "invalid-compact-page-codec"
    end
    local includeAncestorContext, optionsError = ValidateCompactPageEncodeOptions(options)
    if optionsError then
        return nil, optionsError
    end

    local raw, rawError, metadata = EncodeCompactPageRaw(envelope, codec, includeAncestorContext)
    if not raw then
        return nil, rawError
    end
    if #raw > protocol.COMPACT_PAGE_LIMITS.RawBytes then
        return nil, "compact-page-raw-too-large"
    end

    local compressed, compressError = CallStringTransform(codec.compress, raw, "compact-page-compress-failed")
    if not compressed then
        return nil, compressError
    end
    if #compressed > protocol.COMPACT_PAGE_LIMITS.CompressedBytes then
        return nil, "compact-page-compressed-too-large"
    end

    local frameParts = {
        string.char(protocol.COMPACT_PAGE_FORMAT),
    }
    if not AppendUnsigned(frameParts, #raw, 4, protocol.COMPACT_PAGE_LIMITS.RawBytes) then
        return nil, "compact-page-raw-too-large"
    end
    frameParts[#frameParts + 1] = compressed
    local encoded, encodeError =
        CallStringTransform(codec.encode, table.concat(frameParts), "compact-page-encode-failed")
    if not encoded then
        return nil, encodeError
    end
    if #encoded > protocol.COMPACT_PAGE_LIMITS.EncodedBytes then
        return nil, "compact-page-encoded-too-large"
    end
    return encoded, nil, metadata
end

--- Decodes a compact PAGE_UPSERT into the canonical named protocol envelope.
-- The decompressor must enforce the supplied output budget before allocation
-- and return `nil, "output-too-large"` if that budget would be exceeded.
-- @tparam string encoded Compact channel-encoded PAGE_UPSERT.
-- @tparam table codec Bounded compression, channel codec, and hash callbacks.
-- @tparam[opt] table options Compact page decoding options.
-- @treturn table|nil envelope
-- @treturn string|nil errorCode
-- @treturn table|nil metadata
function protocol.DecodeCompactPageEnvelope(encoded, codec, options)
    if type(encoded) ~= "string" or encoded == "" then
        return nil, "invalid-compact-page-encoded"
    end
    if not ValidateCompactPageCodec(codec) then
        return nil, "invalid-compact-page-codec"
    end
    local resolveAncestorContext, optionsError = ValidateCompactPageDecodeOptions(options)
    if optionsError then
        return nil, optionsError
    end
    if #encoded > protocol.COMPACT_PAGE_LIMITS.EncodedBytes then
        return nil, "compact-page-encoded-too-large"
    end

    local frame, decodeError = CallStringTransform(codec.decode, encoded, "compact-page-decode-failed")
    if not frame then
        return nil, decodeError
    end
    if #frame > protocol.COMPACT_PAGE_LIMITS.CompressedBytes + 5 then
        return nil, "compact-page-frame-too-large"
    end
    if #frame < 6 then
        return nil, "invalid-compact-page-frame"
    end
    if frame:byte(1) ~= protocol.COMPACT_PAGE_FORMAT then
        return nil, "unsupported-compact-page-format"
    end

    local declaredRawBytes = ReadUnsigned(frame, 2, 4, UINT32_MAXIMUM)
    if declaredRawBytes == nil or declaredRawBytes < 1 then
        return nil, "invalid-compact-page-raw-length"
    end
    if declaredRawBytes > protocol.COMPACT_PAGE_LIMITS.RawBytes then
        return nil, "compact-page-raw-too-large"
    end
    local compressed = frame:sub(6)
    if #compressed > protocol.COMPACT_PAGE_LIMITS.CompressedBytes then
        return nil, "compact-page-compressed-too-large"
    end

    local ok, raw, status = pcall(codec.decompress, compressed, declaredRawBytes)
    if not ok or type(raw) ~= "string" then
        if ok and status == "output-too-large" then
            return nil, "compact-page-raw-length-mismatch"
        end
        return nil, "compact-page-decompress-failed"
    end
    if status ~= nil and status ~= 0 then
        if type(status) == "number" and status > 0 then
            return nil, "compact-page-compressed-trailing-data"
        end
        return nil, "compact-page-decompress-failed"
    end
    if #raw ~= declaredRawBytes then
        return nil, "compact-page-raw-length-mismatch"
    end
    if #raw > protocol.COMPACT_PAGE_LIMITS.RawBytes then
        return nil, "compact-page-raw-too-large"
    end
    return DecodeCompactPageRaw(raw, codec, resolveAncestorContext)
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
