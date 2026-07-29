local app = {
    AngryEra = {
        utils = {},
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/protocol.lua"))("AngryEra", app)
local protocol = app.AngryEra.utils.protocol

local assertions = 0

local function Assert(value, message)
    assertions = assertions + 1
    assert(value, message)
end

local function AssertEqual(actual, expected, message)
    assertions = assertions + 1
    assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function AssertError(value, errorCode, expectedError, message)
    Assert(value == nil or value == false, message .. " should fail")
    AssertEqual(errorCode, expectedError, message)
end

local function ShallowCopy(value)
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = item
    end
    return copy
end

local function DeepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[DeepCopy(key, seen)] = DeepCopy(item, seen)
    end
    return copy
end

local function DeepEqual(left, right, seen)
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return left == right
    end
    seen = seen or {}
    if seen[left] == right then
        return true
    end
    seen[left] = right
    for key, value in pairs(left) do
        if not DeepEqual(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function Repeat(character, count)
    return string.rep(character, count)
end

local function MakeVersionPayload()
    return {
        AddonVersion = "3.1.0-beta1",
        BuildTimestamp = "20260723010203",
        Flavor = "ERA",
        Capabilities = {
            activePage = 1,
            activePageChanges = 1,
            ownership = 2,
        },
        AcceptsCurrentGroup = true,
    }
end

local activeInstallationId = "ae3i:1234abcd:11111111:22222222:33333333"
local activeRootSyncId = activeInstallationId .. ":category:1"
local activeParentSyncId = activeInstallationId .. ":category:2"
local activePageSyncId = activeInstallationId .. ":page:3"

local function MakePageUpsertPayload()
    return {
        Page = {
            Kind = "page",
            SyncId = activePageSyncId,
            OwnerId = activeInstallationId,
            Revision = 4,
            RevisionId = "fcs32:12345678",
            UpdatedAt = 100,
            UpdatedBy = "Leader-Realm",
            ParentSyncId = activeParentSyncId,
            Order = 2,
            Name = "Active Page",
            Vars = "role=page",
            Contents = "Assignments",
        },
        AncestorVariableLayers = {
            {
                SyncId = activeRootSyncId,
                Vars = "role=root",
            },
            {
                SyncId = activeParentSyncId,
                Vars = "role=parent",
            },
        },
        ContextRevisionId = "fcs32:87654321",
    }
end

local function MakeChangeProposePayload()
    return {
        AuthorityInstallationId = activeInstallationId,
        AuthoritySessionId = "leader_session",
        SyncId = activePageSyncId,
        BaseRevision = 4,
        BaseRevisionId = "fcs32:12345678",
        BaseContextRevisionId = "fcs32:87654321",
        Name = "Active Page",
        Vars = "role=page",
        Contents = "Updated assignments",
    }
end

local function MakeChangeResultPayload(status)
    local payload = {
        Status = status or "applied",
        SyncId = activePageSyncId,
    }
    if payload.Status ~= "unavailable" then
        payload.Revision = 5
        payload.RevisionId = "fcs32:23456789"
        payload.ContextRevisionId = "fcs32:98765432"
    end
    return payload
end

local function MakeCodec(overrides)
    local storedEnvelope
    local codec = {
        serialize = function(envelope)
            storedEnvelope = envelope
            return "serialized"
        end,
        compress = function(serialized)
            AssertEqual(serialized, "serialized", "compress receives serialized data")
            return "compressed"
        end,
        encode = function(compressed)
            AssertEqual(compressed, "compressed", "encode receives compressed data")
            return "encoded"
        end,
        decode = function(encoded)
            AssertEqual(encoded, "encoded", "decode receives encoded data")
            return "compressed"
        end,
        decompress = function(compressed)
            AssertEqual(compressed, "compressed", "decompress receives compressed data")
            return "serialized"
        end,
        deserialize = function(serialized)
            AssertEqual(serialized, "serialized", "deserialize receives serialized data")
            return storedEnvelope
        end,
    }

    for name, callback in pairs(overrides or {}) do
        codec[name] = callback
    end
    return codec
end

local function MakeCompactCodec(overrides)
    local codec = {
        encode = function(value)
            return value
        end,
        decode = function(value)
            return value
        end,
    }
    for name, callback in pairs(overrides or {}) do
        codec[name] = callback
    end
    return codec
end

local function TestHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function MakeCompactPageCodec(overrides)
    local codec = {
        compress = function(value)
            return value
        end,
        decompress = function(value, maximumOutputBytes)
            if #value > maximumOutputBytes then
                return nil, "output-too-large"
            end
            return value
        end,
        encode = function(value)
            return value
        end,
        decode = function(value)
            return value
        end,
        hash = TestHash,
    }
    for name, callback in pairs(overrides or {}) do
        codec[name] = callback
    end
    return codec
end

local function MakeFaithfulAddonCodec(onEncode)
    return {
        encode = function(value)
            if onEncode then
                onEncode(value)
            end
            local encoded = {}
            for index = 1, #value do
                local byte = value:byte(index)
                if byte == 0 then
                    encoded[#encoded + 1] = "\001\002"
                elseif byte == 1 then
                    encoded[#encoded + 1] = "\001\003"
                else
                    encoded[#encoded + 1] = string.char(byte)
                end
            end
            return table.concat(encoded)
        end,
        decode = function(value)
            local decoded = {}
            local cursor = 1
            while cursor <= #value do
                local byte = value:byte(cursor)
                if byte == 0 then
                    return nil
                elseif byte == 1 then
                    local suffix = value:byte(cursor + 1)
                    if suffix == 2 then
                        decoded[#decoded + 1] = "\000"
                    elseif suffix == 3 then
                        decoded[#decoded + 1] = "\001"
                    else
                        return nil
                    end
                    cursor = cursor + 2
                else
                    decoded[#decoded + 1] = string.char(byte)
                    cursor = cursor + 1
                end
            end
            return table.concat(decoded)
        end,
    }
end

local function PackCompactForTest(raw)
    local packed = {}
    local buffer = 0
    local bufferedBits = 0
    for index = 1, #raw do
        buffer = buffer + raw:byte(index) * 2 ^ bufferedBits
        bufferedBits = bufferedBits + 8
        while bufferedBits >= 7 do
            packed[#packed + 1] = string.char(buffer % 128 + 2)
            buffer = math.floor(buffer / 128)
            bufferedBits = bufferedBits - 7
        end
    end
    if bufferedBits > 0 then
        packed[#packed + 1] = string.char(buffer + 2)
    end
    return table.concat(packed)
end

local function UnpackCompactForTest(packed)
    local raw = {}
    local buffer = 0
    local bufferedBits = 0
    for index = 1, #packed do
        local byte = packed:byte(index)
        assert(byte >= 2 and byte <= 129, "packed test fixture must use the compact safe alphabet")
        buffer = buffer + (byte - 2) * 2 ^ bufferedBits
        bufferedBits = bufferedBits + 7
        while bufferedBits >= 8 do
            raw[#raw + 1] = string.char(buffer % 256)
            buffer = math.floor(buffer / 256)
            bufferedBits = bufferedBits - 8
        end
    end
    assert(buffer == 0, "packed test fixture must have canonical zero padding")
    return table.concat(raw)
end

local function ReplaceByte(value, index, byte)
    return value:sub(1, index - 1) .. string.char(byte) .. value:sub(index + 1)
end

local function ReplaceBytes(value, index, replacement)
    return value:sub(1, index - 1) .. replacement .. value:sub(index + #replacement)
end

local function EncodeUnsignedForTest(value, byteCount)
    local bytes = {}
    for index = 1, byteCount do
        bytes[index] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    assert(value == 0, "test integer must fit requested width")
    return table.concat(bytes)
end

local function DecodeUnsignedForTest(value, index, byteCount)
    local decoded = 0
    local multiplier = 1
    for offset = 0, byteCount - 1 do
        decoded = decoded + assert(value:byte(index + offset)) * multiplier
        multiplier = multiplier * 256
    end
    return decoded
end

local function BuildCompactPageFrameForTest(raw, declaredRawBytes, format)
    return string.char(format or protocol.COMPACT_PAGE_FORMAT)
        .. EncodeUnsignedForTest(declaredRawBytes or #raw, 4)
        .. raw
end

local function ReadCompactPageFrameForTest(encoded)
    AssertEqual(encoded:byte(1), protocol.COMPACT_PAGE_FORMAT, "compact page frame format")
    local declaredRawBytes = DecodeUnsignedForTest(encoded, 2, 4)
    local raw = encoded:sub(6)
    AssertEqual(#raw, declaredRawBytes, "identity-compressed page frame length")
    return raw
end

AssertEqual(protocol.VERSION, 3, "protocol version")
AssertEqual(protocol.PREFIX, "AngryEra3", "protocol prefix")
AssertEqual(protocol.DISPLAY_PREFIX, "AngryEra3D", "display protocol prefix")
AssertEqual(protocol.PAGE_PREFIX, "AngryEra3C", "compact-page protocol prefix")
AssertEqual(protocol.ACTIVE_PAGE_PREFIX, "AngryEra3P", "active-page protocol prefix")
AssertEqual(protocol.ACTIVE_PAGE_CHANGES_CAPABILITY, "activePageChanges", "active-page change capability name")
AssertEqual(protocol.ACTIVE_PAGE_CHANGES_CAPABILITY_VERSION, 1, "active-page change capability version")
AssertEqual(protocol.DELEGATED_CONTROL_CAPABILITY, "delegatedControl", "delegated-control capability name")
AssertEqual(protocol.DELEGATED_CONTROL_CAPABILITY_VERSION, 1, "delegated-control capability version")
AssertEqual(protocol.WIRE_LIMITS.EncodedBytes, 256 * 1024, "encoded byte limit")
AssertEqual(protocol.WIRE_LIMITS.CompressedBytes, 256 * 1024, "compressed byte limit")
AssertEqual(protocol.WIRE_LIMITS.SerializedBytes, 1024 * 1024, "serialized byte limit")
AssertEqual(protocol.LIMITS.InstallationIdBytes, 40, "compact installation identity bound")
AssertEqual(protocol.COMPACT_DISPLAY_FORMAT, 2, "compact display format")
AssertEqual(protocol.COMPACT_DISPLAY_LIMITS.EncodedBytes, 254, "compact display single-frame bound")
AssertEqual(protocol.COMPACT_DISPLAY_LIMITS.PackedBytes, 242, "compact display safe-alphabet bound")
AssertEqual(protocol.COMPACT_DISPLAY_LIMITS.RawBytes, 211, "compact display raw bound")
AssertEqual(protocol.COMPACT_PAGE_FORMAT, 2, "compact page format")
AssertEqual(protocol.COMPACT_PAGE_LIMITS.EncodedBytes, 256 * 1024, "compact page encoded bound")
AssertEqual(protocol.COMPACT_PAGE_LIMITS.CompressedBytes, 256 * 1024 - 5, "compact page compressed bound")
AssertEqual(protocol.COMPACT_PAGE_LIMITS.RawBytes, 186162, "compact page exact semantic bound")

local installationId = "ae3i:1234abcd:11111111:22222222:33333333"
local session, sessionError = protocol.NewSession(installationId, "session_B-2")
Assert(session ~= nil and sessionError == nil, "valid session should be created")
AssertEqual(session.Sequence, 0, "new session sequence")

local invalidSession, invalidSessionError = protocol.NewSession("", "session")
AssertError(invalidSession, invalidSessionError, "invalid-installation-id", "empty installation ID")
invalidSession, invalidSessionError = protocol.NewSession("install/bad", "session")
AssertError(invalidSession, invalidSessionError, "invalid-installation-id", "installation ID character")
invalidSession, invalidSessionError = protocol.NewSession("install::bad", "session")
AssertError(invalidSession, invalidSessionError, "invalid-installation-id", "empty installation ID segment")
invalidSession, invalidSessionError = protocol.NewSession("install", "session")
AssertError(invalidSession, invalidSessionError, "invalid-installation-id", "noncanonical installation ID")
invalidSession, invalidSessionError = protocol.NewSession("ae3i:1:2:3:4:", "session")
AssertError(invalidSession, invalidSessionError, "invalid-installation-id", "trailing installation ID segment")
invalidSession, invalidSessionError = protocol.NewSession("ae3i:100000000:1:2:3", "session")
AssertError(invalidSession, invalidSessionError, "invalid-installation-id", "oversized installation ID component")
invalidSession, invalidSessionError = protocol.NewSession(installationId, Repeat("s", 65))
AssertError(invalidSession, invalidSessionError, "invalid-session-id", "long session ID")

local queryEnvelope, queryError = protocol.BuildEnvelope(session, "VERSION_QUERY", {}, { SentAt = 100 })
Assert(queryEnvelope ~= nil and queryError == nil, "query envelope should build")
AssertEqual(queryEnvelope.Protocol, 3, "query protocol")
AssertEqual(queryEnvelope.Type, "VERSION_QUERY", "query type")
AssertEqual(queryEnvelope.MessageId, installationId .. ":session_B-2:1", "first message ID")
AssertEqual(queryEnvelope.SenderInstallationId, installationId, "sender installation ID")
AssertEqual(queryEnvelope.SenderSessionId, "session_B-2", "sender session ID")
AssertEqual(queryEnvelope.Sequence, 1, "first message sequence")
AssertEqual(queryEnvelope.SentAt, 100, "sent timestamp")
AssertEqual(session.Sequence, 1, "successful build advances session")

local versionEnvelope, versionError = protocol.BuildEnvelope(session, "VERSION", MakeVersionPayload(), {
    SentAt = 101,
    ReplyTo = queryEnvelope.MessageId,
})
Assert(versionEnvelope ~= nil and versionError == nil, "version envelope should build")
AssertEqual(versionEnvelope.MessageId, installationId .. ":session_B-2:2", "second message ID")
AssertEqual(versionEnvelope.ReplyTo, queryEnvelope.MessageId, "version reply correlation")
AssertEqual(session.Sequence, 2, "second successful build advances session")

local sequenceBeforeFailure = session.Sequence
local failedEnvelope, failedEnvelopeError = protocol.BuildEnvelope(
    session,
    "VERSION_QUERY",
    { unexpected = true },
    { SentAt = 102 }
)
AssertError(failedEnvelope, failedEnvelopeError, "version-query-payload-not-empty", "non-empty version query payload")
AssertEqual(session.Sequence, sequenceBeforeFailure, "failed build does not advance sequence")

failedEnvelope, failedEnvelopeError = protocol.BuildEnvelope(session, "DELTA", {}, { SentAt = 102 })
AssertError(failedEnvelope, failedEnvelopeError, "unknown-message-type", "unknown message family")
AssertEqual(session.Sequence, sequenceBeforeFailure, "unknown message does not advance sequence")

failedEnvelope, failedEnvelopeError = protocol.BuildEnvelope(session, "VERSION_QUERY", {}, {})
AssertError(failedEnvelope, failedEnvelopeError, "invalid-sent-at", "missing timestamp")
AssertEqual(session.Sequence, sequenceBeforeFailure, "missing timestamp does not advance sequence")

failedEnvelope, failedEnvelopeError = protocol.BuildEnvelope(session, "VERSION_QUERY", {}, "invalid")
AssertError(failedEnvelope, failedEnvelopeError, "invalid-options", "non-table envelope options")
AssertEqual(session.Sequence, sequenceBeforeFailure, "invalid options do not advance sequence")

local exhaustedSession = assert(protocol.NewSession(installationId, "session"))
exhaustedSession.Sequence = protocol.LIMITS.Sequence
failedEnvelope, failedEnvelopeError = protocol.BuildEnvelope(exhaustedSession, "VERSION_QUERY", {}, { SentAt = 1 })
AssertError(failedEnvelope, failedEnvelopeError, "sequence-exhausted", "exhausted sequence")

local valid, validationError = protocol.ValidateEnvelope(queryEnvelope)
Assert(valid and validationError == nil, "built query validates")

local invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.Protocol = 1
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-protocol", "wrong protocol")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.Type = "version_query"
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-message-type", "lowercase message type")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.Type = "DELTA"
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "unknown-message-type", "unknown validly formatted type")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.MessageId = installationId .. ":session_B-2:2"
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "message-id-mismatch", "message ID sequence mismatch")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.MessageId = "bad"
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-message-id", "malformed message ID")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.SenderInstallationId = "bad/value"
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-installation-id", "malformed sender installation ID")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.SenderSessionId = ""
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-session-id", "empty sender session ID")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.Sequence = 1.5
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-sequence", "fractional sequence")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.ReplyTo = "not-a-message-id"
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-reply-to", "malformed reply ID")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.ReplyTo = installationId .. ":session_B-2:0001"
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-reply-to", "noncanonical reply sequence")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.SentAt = -1
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-sent-at", "negative sent timestamp")

invalidEnvelope = ShallowCopy(queryEnvelope)
invalidEnvelope.Payload = "not-a-table"
valid, validationError = protocol.ValidateEnvelope(invalidEnvelope)
AssertError(valid, validationError, "invalid-payload", "non-table payload")

local payloadValid, payloadError = protocol.ValidatePayload("VERSION", MakeVersionPayload())
Assert(payloadValid and payloadError == nil, "valid version payload")

local versionPayload = MakeVersionPayload()
versionPayload.AddonVersion = ""
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-addon-version", "empty addon version")

versionPayload = MakeVersionPayload()
versionPayload.AddonVersion = Repeat("v", 33)
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-addon-version", "long addon version")

versionPayload = MakeVersionPayload()
versionPayload.BuildTimestamp = Repeat("1", 21)
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-build-timestamp", "long build timestamp")

versionPayload = MakeVersionPayload()
versionPayload.Flavor = "CLASSIC"
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-client-flavor", "unknown client flavor")

versionPayload = MakeVersionPayload()
versionPayload.Capabilities = "activePage"
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-capabilities", "non-table capabilities")

versionPayload = MakeVersionPayload()
versionPayload.Capabilities = { ActivePage = 1 }
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-capability-name", "uppercase capability name")

versionPayload = MakeVersionPayload()
versionPayload.Capabilities = { active_page = 1 }
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-capability-name", "punctuated capability name")

versionPayload = MakeVersionPayload()
versionPayload.Capabilities = { activePage = 0 }
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-capability-version", "zero capability version")

versionPayload = MakeVersionPayload()
versionPayload.Capabilities = { activePage = 1.5 }
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-capability-version", "fractional capability version")

versionPayload = MakeVersionPayload()
versionPayload.AcceptsCurrentGroup = "yes"
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
AssertError(payloadValid, payloadError, "invalid-accepts-current-group", "non-boolean acceptance flag")

versionPayload = MakeVersionPayload()
versionPayload.FutureField = { ignored = true }
payloadValid, payloadError = protocol.ValidatePayload("VERSION", versionPayload)
Assert(payloadValid and payloadError == nil, "unknown version fields remain forward-compatible")

Assert(protocol.MESSAGE_TYPES.DISPLAY_REQUEST, "display request message type is registered")
Assert(protocol.MESSAGE_TYPES.DISPLAY, "display message type is registered")
Assert(protocol.MESSAGE_TYPES.PAGE_REQUEST, "page request message type is registered")
Assert(protocol.MESSAGE_TYPES.PAGE_UPSERT, "page upsert message type is registered")
Assert(protocol.MESSAGE_TYPES.CHANGE_PROPOSE, "change proposal message type is registered")
Assert(protocol.MESSAGE_TYPES.CHANGE_RESULT, "change result message type is registered")
Assert(protocol.MESSAGE_TYPES.CONTROL_REQUEST, "control request message type is registered")
Assert(protocol.MESSAGE_TYPES.CONTROL_GRANT, "control grant message type is registered")
Assert(protocol.MESSAGE_TYPES.CONTROL_REVOKE, "control revoke message type is registered")
Assert(protocol.MESSAGE_TYPES.CONTROL_RESULT, "control result message type is registered")

local controllerSessionId = "controller-session"
local controllerRequestId = activeInstallationId .. ":" .. controllerSessionId .. ":7"
local controlGrantId = installationId .. ":session_B-2:9"
local controlGrantPayload = {
    Controller = "Zessy-Realm",
    ControllerInstallationId = activeInstallationId,
    ControllerSessionId = controllerSessionId,
    RequestId = controllerRequestId,
}

payloadValid, payloadError = protocol.ValidatePayload("CONTROL_REQUEST", {})
Assert(payloadValid and payloadError == nil, "empty control request payload")
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_REQUEST", { Controller = "Zessy-Realm" })
AssertError(payloadValid, payloadError, "control-request-payload-not-empty", "non-empty control request payload")

payloadValid, payloadError = protocol.ValidatePayload("CONTROL_GRANT", controlGrantPayload)
Assert(payloadValid and payloadError == nil, "valid control grant payload")
local malformedControlGrant = ShallowCopy(controlGrantPayload)
malformedControlGrant.RequestId = activeInstallationId .. ":other-session:7"
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_GRANT", malformedControlGrant)
AssertError(payloadValid, payloadError, "control-request-identity-mismatch", "control grant request session mismatch")
malformedControlGrant = ShallowCopy(controlGrantPayload)
malformedControlGrant.ControllerInstallationId = "ae3i:9:8:7:6"
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_GRANT", malformedControlGrant)
AssertError(
    payloadValid,
    payloadError,
    "control-request-identity-mismatch",
    "control grant request installation mismatch"
)
malformedControlGrant = ShallowCopy(controlGrantPayload)
malformedControlGrant.Controller = "Zessy\nRealm"
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_GRANT", malformedControlGrant)
AssertError(payloadValid, payloadError, "invalid-control-controller", "control grant controller control byte")
malformedControlGrant = ShallowCopy(controlGrantPayload)
malformedControlGrant.Contents = "must never be carried"
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_GRANT", malformedControlGrant)
AssertError(payloadValid, payloadError, "control-grant-unknown-field", "control grant page data")

payloadValid, payloadError = protocol.ValidatePayload("CONTROL_REVOKE", {
    GrantId = controlGrantId,
})
Assert(payloadValid and payloadError == nil, "valid control revoke payload")
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_REVOKE", {
    GrantId = "invalid",
})
AssertError(payloadValid, payloadError, "invalid-control-grant-id", "invalid control revoke grant identity")

for _, status in ipairs({ "declined", "busy", "incompatible", "unauthorized", "stale" }) do
    payloadValid, payloadError = protocol.ValidatePayload("CONTROL_RESULT", {
        Status = status,
    })
    Assert(payloadValid and payloadError == nil, "valid " .. status .. " control result")
    Assert(protocol.CONTROL_RESULT_STATUSES[status], "control result status should be exported")
end
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_RESULT", {
    Status = "granted",
    GrantId = controlGrantId,
})
Assert(payloadValid and payloadError == nil, "valid granted control result")
Assert(protocol.CONTROL_RESULT_STATUSES.granted, "granted control result status should be exported")
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_RESULT", {
    Status = "granted",
})
AssertError(payloadValid, payloadError, "control-result-missing-grant-id", "granted result without grant identity")
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_RESULT", {
    Status = "declined",
    GrantId = controlGrantId,
})
AssertError(payloadValid, payloadError, "control-result-unexpected-grant-id", "declined result with grant identity")
payloadValid, payloadError = protocol.ValidatePayload("CONTROL_RESULT", {
    Status = "unknown",
})
AssertError(payloadValid, payloadError, "invalid-control-result-status", "unknown control result status")

payloadValid, payloadError = protocol.ValidatePayload("DISPLAY_REQUEST", {})
Assert(payloadValid and payloadError == nil, "empty display request payload")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY_REQUEST", { unexpected = true })
AssertError(payloadValid, payloadError, "display-request-payload-not-empty", "non-empty display request payload")

payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", { Displayed = false })
Assert(payloadValid and payloadError == nil, "explicit clear display payload")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = false,
    SyncId = activePageSyncId,
})
AssertError(payloadValid, payloadError, "display-clear-has-page", "clear display with page identity")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = true,
    PageFollows = true,
    SyncId = activePageSyncId,
    Revision = 4,
    RevisionId = "fcs32:12345678",
    ContextRevisionId = "fcs32:87654321",
})
Assert(payloadValid and payloadError == nil, "set display payload")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = true,
    PageFollows = false,
    SyncId = activePageSyncId,
    Revision = 4,
    RevisionId = "fcs32:12345678",
    ContextRevisionId = "fcs32:87654321",
})
Assert(payloadValid and payloadError == nil, "display may explicitly omit a following page")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = false,
    PageFollows = false,
})
Assert(payloadValid and payloadError == nil, "clear display permits a false page-follows hint")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = false,
    PageFollows = true,
})
AssertError(payloadValid, payloadError, "display-clear-page-follows", "clear display cannot promise a page")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = true,
    PageFollows = "yes",
    SyncId = activePageSyncId,
    Revision = 4,
    RevisionId = "fcs32:12345678",
    ContextRevisionId = "fcs32:87654321",
})
AssertError(payloadValid, payloadError, "invalid-page-follows", "page-follows hint must be boolean")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = true,
    SyncId = activePageSyncId,
    Revision = 4,
    RevisionId = "fcs32:12345678",
})
AssertError(payloadValid, payloadError, "display-missing-ContextRevisionId", "display missing context identity")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = "yes",
})
AssertError(payloadValid, payloadError, "invalid-displayed", "non-boolean display state")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = false,
    Unknown = true,
})
AssertError(payloadValid, payloadError, "display-unknown-field", "unknown display field")

local pageReference = {
    SyncId = activePageSyncId,
    Revision = 4,
    RevisionId = "fcs32:12345678",
    ContextRevisionId = "fcs32:87654321",
}
payloadValid, payloadError = protocol.ValidatePayload("PAGE_REQUEST", pageReference)
Assert(payloadValid and payloadError == nil, "page request payload")
local invalidReference = ShallowCopy(pageReference)
invalidReference.SyncId = activeRootSyncId
payloadValid, payloadError = protocol.ValidatePayload("PAGE_REQUEST", invalidReference)
AssertError(payloadValid, payloadError, "invalid-sync-id", "page request category identity")
invalidReference = ShallowCopy(pageReference)
invalidReference.SyncId = activeInstallationId .. ":page:03"
payloadValid, payloadError = protocol.ValidatePayload("PAGE_REQUEST", invalidReference)
AssertError(payloadValid, payloadError, "invalid-sync-id", "page request noncanonical identity sequence")
invalidReference = ShallowCopy(pageReference)
invalidReference.RevisionId = "fcs32:ABCDEF12"
payloadValid, payloadError = protocol.ValidatePayload("PAGE_REQUEST", invalidReference)
AssertError(payloadValid, payloadError, "invalid-revision-id", "page request uppercase revision identity")
invalidReference = ShallowCopy(pageReference)
invalidReference.ContextRevisionId = "fcs32:1234567"
payloadValid, payloadError = protocol.ValidatePayload("PAGE_REQUEST", invalidReference)
AssertError(payloadValid, payloadError, "invalid-context-revision-id", "page request short context identity")
invalidReference = ShallowCopy(pageReference)
invalidReference.Unknown = true
payloadValid, payloadError = protocol.ValidatePayload("PAGE_REQUEST", invalidReference)
AssertError(payloadValid, payloadError, "page-request-unknown-field", "unknown page request field")

local changeProposePayload = MakeChangeProposePayload()
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", changeProposePayload)
Assert(payloadValid and payloadError == nil, "valid change proposal payload")

local malformedChangePropose = DeepCopy(changeProposePayload)
malformedChangePropose.OwnerId = activeInstallationId
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
AssertError(payloadValid, payloadError, "change-propose-unknown-field", "change proposal cannot supply ownership")

malformedChangePropose = DeepCopy(changeProposePayload)
malformedChangePropose.BaseRevisionId = nil
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
AssertError(
    payloadValid,
    payloadError,
    "change-propose-missing-BaseRevisionId",
    "change proposal missing base revision identity"
)

malformedChangePropose = DeepCopy(changeProposePayload)
malformedChangePropose.SyncId = activeRootSyncId
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
AssertError(payloadValid, payloadError, "invalid-change-sync-id", "change proposal category identity")

for _, invalidRevision in ipairs({ 0, protocol.LIMITS.ActivePageRevision }) do
    malformedChangePropose = DeepCopy(changeProposePayload)
    malformedChangePropose.BaseRevision = invalidRevision
    payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
    AssertError(payloadValid, payloadError, "invalid-change-base-revision", "change proposal base revision bound")
end

malformedChangePropose = DeepCopy(changeProposePayload)
malformedChangePropose.BaseRevisionId = "fcs32:ABCDEF12"
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
AssertError(payloadValid, payloadError, "invalid-change-base-revision-id", "change proposal base revision identity")

malformedChangePropose = DeepCopy(changeProposePayload)
malformedChangePropose.BaseContextRevisionId = "fcs32:1234567"
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
AssertError(
    payloadValid,
    payloadError,
    "invalid-change-base-context-revision-id",
    "change proposal base context identity"
)

for _, invalidName in ipairs({
    "",
    " ",
    " Leading",
    "Trailing ",
    "Control\nName",
    Repeat("n", protocol.LIMITS.ActivePageNameBytes + 1),
}) do
    malformedChangePropose = DeepCopy(changeProposePayload)
    malformedChangePropose.Name = invalidName
    payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
    AssertError(payloadValid, payloadError, "invalid-change-name", "change proposal page name")
end

malformedChangePropose = DeepCopy(changeProposePayload)
malformedChangePropose.Vars = Repeat("v", protocol.LIMITS.ActivePageVarsBytes + 1)
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
AssertError(payloadValid, payloadError, "invalid-change-vars", "change proposal page variables")

malformedChangePropose = DeepCopy(changeProposePayload)
malformedChangePropose.Contents = Repeat("c", protocol.LIMITS.ActivePageContentsBytes + 1)
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", malformedChangePropose)
AssertError(payloadValid, payloadError, "invalid-change-contents", "change proposal page contents")

payloadValid, payloadError = protocol.ValidatePayload("CHANGE_PROPOSE", setmetatable({}, {}))
AssertError(payloadValid, payloadError, "invalid-payload", "metatable-backed change proposal")

for _, status in ipairs({ "applied", "unchanged", "conflict", "busy", "unavailable" }) do
    local changeResultPayload = MakeChangeResultPayload(status)
    payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", changeResultPayload)
    Assert(payloadValid and payloadError == nil, "valid " .. status .. " change result payload")
    Assert(protocol.CHANGE_RESULT_STATUSES[status], "change result status should be exported")
end

local malformedChangeResult = MakeChangeResultPayload("applied")
malformedChangeResult.Status = "rejected"
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", malformedChangeResult)
AssertError(payloadValid, payloadError, "invalid-change-result-status", "unknown change result status")

malformedChangeResult = MakeChangeResultPayload("applied")
malformedChangeResult.SyncId = activeRootSyncId
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", malformedChangeResult)
AssertError(payloadValid, payloadError, "invalid-change-result-sync-id", "change result category identity")

for _, missingField in ipairs({ "Revision", "RevisionId", "ContextRevisionId" }) do
    malformedChangeResult = MakeChangeResultPayload("applied")
    malformedChangeResult[missingField] = nil
    payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", malformedChangeResult)
    AssertError(
        payloadValid,
        payloadError,
        "change-result-missing-" .. missingField,
        "change result missing canonical reference"
    )
end

malformedChangeResult = MakeChangeResultPayload("applied")
malformedChangeResult.Revision = 0
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", malformedChangeResult)
AssertError(payloadValid, payloadError, "invalid-change-result-revision", "change result revision bound")

malformedChangeResult = MakeChangeResultPayload("applied")
malformedChangeResult.RevisionId = "fcs32:1234567"
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", malformedChangeResult)
AssertError(payloadValid, payloadError, "invalid-change-result-revision-id", "change result revision identity")

malformedChangeResult = MakeChangeResultPayload("applied")
malformedChangeResult.ContextRevisionId = "fcs32:ABCDEF12"
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", malformedChangeResult)
AssertError(payloadValid, payloadError, "invalid-change-result-context-revision-id", "change result context identity")

malformedChangeResult = MakeChangeResultPayload("unavailable")
malformedChangeResult.Revision = 4
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", malformedChangeResult)
AssertError(
    payloadValid,
    payloadError,
    "change-result-unavailable-has-reference",
    "unavailable change result cannot carry a partial reference"
)

malformedChangeResult = MakeChangeResultPayload("applied")
malformedChangeResult.Error = "internal"
payloadValid, payloadError = protocol.ValidatePayload("CHANGE_RESULT", malformedChangeResult)
AssertError(payloadValid, payloadError, "change-result-unknown-field", "change result unknown field")

payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = true,
    SyncId = activeInstallationId .. ":page:2147483648",
    Revision = 4,
    RevisionId = pageReference.RevisionId,
    ContextRevisionId = pageReference.ContextRevisionId,
})
AssertError(payloadValid, payloadError, "invalid-sync-id", "display identity sequence overflow")

local pageUpsertPayload = MakePageUpsertPayload()
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", pageUpsertPayload)
Assert(payloadValid and payloadError == nil, "shallow page upsert payload")

local activeSession = assert(protocol.NewSession(installationId, "active-session"))
local activeEnvelope, activeEnvelopeError =
    protocol.BuildEnvelope(activeSession, "PAGE_UPSERT", pageUpsertPayload, { SentAt = 200 })
Assert(activeEnvelope ~= nil and activeEnvelopeError == nil, "valid page upsert envelope builds")
AssertEqual(activeEnvelope.Type, "PAGE_UPSERT", "active envelope type")

local malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Unknown = true
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "page-upsert-unknown-field", "unknown page upsert field")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.Unknown = true
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "page-unknown-field", "unknown page field")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.Kind = "category"
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-page-kind", "page upsert category record")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.OwnerId = "invalid"
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-page-owner-id", "invalid page owner")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.OwnerId = "ae3i:a:b:c:d"
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "owner-mismatch", "mismatched page owner")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.Revision = 0
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-page-revision", "zero page revision")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.UpdatedAt = -1
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-page-updated-at", "negative page update time")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.ParentSyncId = activePageSyncId
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-page-parent-sync-id", "page parent identity")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.Name = Repeat("n", protocol.LIMITS.ActivePageNameBytes + 1)
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-page-name", "oversized page name")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.Page.Contents = Repeat("c", protocol.LIMITS.ActivePageContentsBytes + 1)
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-page-contents", "oversized page contents")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.AncestorVariableLayers[1].Unknown = true
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "ancestor-layer-unknown-field", "unknown ancestor layer field")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.AncestorVariableLayers[2] = nil
malformedPageUpsert.AncestorVariableLayers[3] = {
    SyncId = activeInstallationId .. ":category:3",
    Vars = "",
}
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-ancestor-layers", "sparse ancestor layers")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.AncestorVariableLayers = {}
for index = 1, protocol.LIMITS.ActivePageAncestorCount + 1 do
    malformedPageUpsert.AncestorVariableLayers[index] = {
        SyncId = activeInstallationId .. ":category:" .. index,
        Vars = "",
    }
end
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-ancestor-layers", "too many ancestor layers")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
malformedPageUpsert.AncestorVariableLayers[1].Vars = Repeat("v", protocol.LIMITS.ActivePageVarsBytes + 1)
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-ancestor-vars", "oversized ancestor variables")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
setmetatable(malformedPageUpsert.Page, {})
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-page", "metatable-backed page")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
setmetatable(malformedPageUpsert.AncestorVariableLayers, {})
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-ancestor-layers", "metatable-backed ancestor layer array")

malformedPageUpsert = DeepCopy(pageUpsertPayload)
setmetatable(malformedPageUpsert.AncestorVariableLayers[1], {})
payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
AssertError(payloadValid, payloadError, "invalid-ancestor-layer", "metatable-backed ancestor layer")

for _, invalidKey in ipairs({ 0, 1.5, "first" }) do
    malformedPageUpsert = DeepCopy(pageUpsertPayload)
    malformedPageUpsert.AncestorVariableLayers[invalidKey] = {
        SyncId = activeInstallationId .. ":category:4",
        Vars = "",
    }
    payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", malformedPageUpsert)
    AssertError(payloadValid, payloadError, "invalid-ancestor-layers", "invalid ancestor layer key")
end

payloadValid, payloadError = protocol.ValidatePayload("PAGE_UPSERT", setmetatable({}, {}))
AssertError(payloadValid, payloadError, "invalid-payload", "metatable-backed active payload")

local tooManyCapabilities = {}
for index = 1, 33 do
    tooManyCapabilities["capability" .. index] = 1
end
local capabilitiesValid, capabilitiesError = protocol.ValidateCapabilities(tooManyCapabilities)
AssertError(capabilitiesValid, capabilitiesError, "too-many-capabilities", "capability count bound")

capabilitiesValid, capabilitiesError = protocol.ValidateCapabilities({})
Assert(capabilitiesValid and capabilitiesError == nil, "empty capability map is valid")

local localCapabilities = {
    activePage = 2,
    hierarchyManifest = 1,
    ownership = 3,
}
local remoteCapabilities = {
    activePage = 1,
    hierarchyManifest = 3,
    tombstones = 1,
}
local negotiated, negotiationError = protocol.NegotiateCapabilities(localCapabilities, remoteCapabilities)
Assert(negotiated ~= nil and negotiationError == nil, "valid capabilities negotiate")
AssertEqual(negotiated.activePage, 1, "negotiation uses lower remote version")
AssertEqual(negotiated.hierarchyManifest, 1, "negotiation uses lower local version")
Assert(negotiated.ownership == nil, "local-only capability omitted")
Assert(negotiated.tombstones == nil, "remote-only capability omitted")
AssertEqual(localCapabilities.activePage, 2, "negotiation does not mutate local map")
AssertEqual(remoteCapabilities.activePage, 1, "negotiation does not mutate remote map")

negotiated, negotiationError = protocol.NegotiateCapabilities({ activePage = 0 }, remoteCapabilities)
AssertError(negotiated, negotiationError, "invalid-capability-version", "invalid local capability negotiation")

Assert(protocol.Supports(remoteCapabilities, "activePage"), "default capability minimum")
Assert(protocol.Supports(remoteCapabilities, "activePage", 1), "explicit supported capability minimum")
Assert(not protocol.Supports(remoteCapabilities, "activePage", 2), "unsupported capability version")
Assert(not protocol.Supports(remoteCapabilities, "ownership", 1), "missing capability")
Assert(not protocol.Supports({ activePage = 0 }, "activePage", 1), "invalid capability map")
Assert(not protocol.Supports(remoteCapabilities, "ActivePage", 1), "invalid capability request name")
Assert(not protocol.Supports(remoteCapabilities, "activePage", 0), "invalid capability minimum")

local codec = MakeCodec()
local encoded, encodeError = protocol.EncodeEnvelope(queryEnvelope, codec)
Assert(encoded ~= nil and encodeError == nil, "valid envelope encodes")
AssertEqual(encoded, "encoded", "encoded wire value")

local decoded, decodeError = protocol.DecodeEnvelope(encoded, codec)
Assert(decoded ~= nil and decodeError == nil, "valid envelope decodes")
AssertEqual(decoded.MessageId, queryEnvelope.MessageId, "decoded envelope identity")

encoded, encodeError = protocol.EncodeEnvelope(queryEnvelope, {}, protocol.WIRE_LIMITS)
AssertError(encoded, encodeError, "invalid-codec", "missing codec functions")

decoded, decodeError = protocol.DecodeEnvelope("", codec)
AssertError(decoded, decodeError, "invalid-encoded", "empty encoded input")

local smallLimits = {
    EncodedBytes = 8,
    CompressedBytes = 8,
    SerializedBytes = 8,
}

encoded, encodeError = protocol.EncodeEnvelope(
    queryEnvelope,
    MakeCodec({
        serialize = function()
            return Repeat("s", 9)
        end,
    }),
    smallLimits
)
AssertError(encoded, encodeError, "serialized-too-large", "encode serialized limit")

encoded, encodeError = protocol.EncodeEnvelope(
    queryEnvelope,
    MakeCodec({
        serialize = function()
            return "s"
        end,
        compress = function()
            return Repeat("c", 9)
        end,
    }),
    smallLimits
)
AssertError(encoded, encodeError, "compressed-too-large", "encode compressed limit")

encoded, encodeError = protocol.EncodeEnvelope(
    queryEnvelope,
    MakeCodec({
        serialize = function()
            return "s"
        end,
        compress = function()
            return "c"
        end,
        encode = function()
            return Repeat("e", 9)
        end,
    }),
    smallLimits
)
AssertError(encoded, encodeError, "encoded-too-large", "encode encoded limit")

encoded, encodeError = protocol.EncodeEnvelope(
    queryEnvelope,
    MakeCodec({
        serialize = function()
            error("serialize")
        end,
    })
)
AssertError(encoded, encodeError, "serialize-failed", "serialize exception")

encoded, encodeError = protocol.EncodeEnvelope(
    queryEnvelope,
    MakeCodec({
        compress = function()
            return nil
        end,
    })
)
AssertError(encoded, encodeError, "compress-failed", "compress nil")

encoded, encodeError = protocol.EncodeEnvelope(
    queryEnvelope,
    MakeCodec({
        compress = function()
            return ""
        end,
    })
)
AssertError(encoded, encodeError, "compress-failed", "compress empty string")

encoded, encodeError = protocol.EncodeEnvelope(
    queryEnvelope,
    MakeCodec({
        encode = function()
            error("encode")
        end,
    })
)
AssertError(encoded, encodeError, "encode-failed", "encode exception")

decoded, decodeError = protocol.DecodeEnvelope(Repeat("e", 9), codec, smallLimits)
AssertError(decoded, decodeError, "encoded-too-large", "decode encoded limit")

decoded, decodeError = protocol.DecodeEnvelope(
    "e",
    MakeCodec({
        decode = function()
            return Repeat("c", 9)
        end,
    }),
    smallLimits
)
AssertError(decoded, decodeError, "compressed-too-large", "decode compressed limit")

decoded, decodeError = protocol.DecodeEnvelope(
    "e",
    MakeCodec({
        decode = function()
            return "c"
        end,
        decompress = function(_, maximumOutputBytes)
            AssertEqual(maximumOutputBytes, 8, "decompress receives the serialized output budget")
            return nil, "output-too-large"
        end,
    }),
    smallLimits
)
AssertError(decoded, decodeError, "serialized-too-large", "decode serialized limit")

decoded, decodeError = protocol.DecodeEnvelope(
    "e",
    MakeCodec({
        decode = function()
            return "c"
        end,
        decompress = function()
            return Repeat("s", 9)
        end,
    }),
    smallLimits
)
AssertError(decoded, decodeError, "serialized-too-large", "post-decompress serialized limit")

decoded, decodeError = protocol.DecodeEnvelope(
    "e",
    MakeCodec({
        decode = function()
            error("decode")
        end,
    })
)
AssertError(decoded, decodeError, "decode-failed", "decode exception")

decoded, decodeError = protocol.DecodeEnvelope(
    "encoded",
    MakeCodec({
        decompress = function()
            return nil
        end,
    })
)
AssertError(decoded, decodeError, "decompress-failed", "decompress nil")

decoded, decodeError = protocol.DecodeEnvelope(
    "encoded",
    MakeCodec({
        decompress = function()
            return ""
        end,
    })
)
AssertError(decoded, decodeError, "decompress-failed", "decompress empty string")

decoded, decodeError = protocol.DecodeEnvelope(
    "encoded",
    MakeCodec({
        deserialize = function()
            error("deserialize")
        end,
    })
)
AssertError(decoded, decodeError, "deserialize-failed", "deserialize exception")

decoded, decodeError = protocol.DecodeEnvelope(
    "encoded",
    MakeCodec({
        deserialize = function()
            return "not-an-envelope"
        end,
    })
)
AssertError(decoded, decodeError, "deserialize-failed", "deserialize non-table")

local badDecodedEnvelope = ShallowCopy(queryEnvelope)
badDecodedEnvelope.Protocol = 2
decoded, decodeError = protocol.DecodeEnvelope(
    "encoded",
    MakeCodec({
        deserialize = function()
            return badDecodedEnvelope
        end,
    })
)
AssertError(decoded, decodeError, "invalid-protocol", "decoded envelope validation")

encoded, encodeError = protocol.EncodeEnvelope(queryEnvelope, codec, {
    EncodedBytes = 0,
    CompressedBytes = 8,
    SerializedBytes = 8,
})
AssertError(encoded, encodeError, "invalid-limits", "invalid custom limits")

local compactPageCodec = MakeCompactPageCodec()
local compactPageSession = assert(protocol.NewSession(installationId, "compact-page"))
local compactPageEnvelope = assert(protocol.BuildEnvelope(compactPageSession, "PAGE_UPSERT", MakePageUpsertPayload(), {
    ReplyTo = queryEnvelope.MessageId,
    SentAt = 1750000000100,
}))
local compactPageEncoded, compactPageEncodeError, compactPageEncodeMetadata =
    protocol.EncodeCompactPageEnvelope(compactPageEnvelope, compactPageCodec)
Assert(compactPageEncoded ~= nil and compactPageEncodeError == nil, "valid compact page encodes")
local compactPageRaw = ReadCompactPageFrameForTest(compactPageEncoded)
AssertEqual(compactPageRaw:byte(1), 3, "compact page reply and inline ancestor flags")
AssertEqual(compactPageEncodeMetadata.AncestorContextIncluded, true, "compact page metadata records inline context")
AssertEqual(compactPageEncodeMetadata.AncestorContextBytes, 65, "compact page metadata records ancestor wire bytes")
Assert(
    compactPageEncodeMetadata.AncestorContextId:match("^fcs32:[0-9a-f]+$") ~= nil,
    "compact page metadata records canonical ancestor identity"
)
AssertEqual(
    compactPageEncodeMetadata.Reference.SyncId,
    compactPageEnvelope.Payload.Page.SyncId,
    "compact page metadata records page reference"
)
Assert(
    #compactPageRaw < #compactPageEnvelope.Payload.Page.Contents + 512,
    "compact page metadata stays small for the representative payload"
)

local compactPageDecoded, compactPageDecodeError, compactPageDecodeMetadata =
    protocol.DecodeCompactPageEnvelope(compactPageEncoded, compactPageCodec)
Assert(compactPageDecoded ~= nil and compactPageDecodeError == nil, "valid compact page decodes")
Assert(DeepEqual(compactPageDecoded, compactPageEnvelope), "compact page canonical envelope round trip")
Assert(DeepEqual(compactPageDecodeMetadata, compactPageEncodeMetadata), "compact page metadata round trip")
AssertEqual(
    compactPageDecoded.Payload.Page.OwnerId,
    compactPageDecoded.Payload.Page.SyncId:match("^(.*):page:"),
    "compact page derives owner identity"
)
AssertEqual(
    compactPageDecoded.Payload.Page.ParentSyncId,
    compactPageDecoded.Payload.AncestorVariableLayers[2].SyncId,
    "compact page derives direct parent"
)
AssertEqual(#compactPageDecoded.Payload.AncestorVariableLayers, 2, "compact page retains every ancestor layer")
AssertEqual(
    compactPageDecoded.Payload.AncestorVariableLayers[1].Vars,
    "role=root",
    "compact page retains root variables"
)
AssertEqual(
    compactPageDecoded.Payload.AncestorVariableLayers[2].Vars,
    "role=parent",
    "compact page retains parent variables"
)

do
    local hashedBytes
    local ancestorContextId, ancestorContextError, ancestorContextBytes =
        protocol.BuildCompactPageAncestorContextId(compactPageEnvelope.Payload.AncestorVariableLayers, {
            hash = function(value)
                hashedBytes = value
                return TestHash(value)
            end,
        })
    Assert(ancestorContextId ~= nil and ancestorContextError == nil, "compact page ancestor context identity builds")
    AssertEqual(ancestorContextBytes, 65, "ancestor context identity reports canonical byte count")
    AssertEqual(#hashedBytes, ancestorContextBytes, "ancestor context hashes the exact inline bytes")
    AssertEqual(ancestorContextId, "fcs32:" .. TestHash(hashedBytes), "ancestor context identity uses the codec digest")
    AssertEqual(
        ancestorContextId,
        compactPageEncodeMetadata.AncestorContextId,
        "standalone and encoded ancestor identities agree"
    )

    local changedLayers = DeepCopy(compactPageEnvelope.Payload.AncestorVariableLayers)
    changedLayers[2].Vars = "role=changed"
    local changedContextId = assert(protocol.BuildCompactPageAncestorContextId(changedLayers, compactPageCodec))
    Assert(changedContextId ~= ancestorContextId, "ancestor variables contribute to context identity")

    changedLayers = {
        DeepCopy(compactPageEnvelope.Payload.AncestorVariableLayers[2]),
        DeepCopy(compactPageEnvelope.Payload.AncestorVariableLayers[1]),
    }
    changedContextId = assert(protocol.BuildCompactPageAncestorContextId(changedLayers, compactPageCodec))
    Assert(changedContextId ~= ancestorContextId, "ancestor order contributes to context identity")

    local emptyContextId, emptyContextError, emptyContextBytes =
        protocol.BuildCompactPageAncestorContextId({}, compactPageCodec)
    Assert(emptyContextId ~= nil and emptyContextError == nil, "empty ancestor context identity builds")
    AssertEqual(emptyContextBytes, 1, "empty ancestor identity hashes its count byte")

    local invalidContextId
    invalidContextId, ancestorContextError = protocol.BuildCompactPageAncestorContextId("layers", compactPageCodec)
    AssertError(
        invalidContextId,
        ancestorContextError,
        "invalid-ancestor-layers",
        "ancestor context identity validates layers"
    )
    invalidContextId, ancestorContextError = protocol.BuildCompactPageAncestorContextId({}, {})
    AssertError(
        invalidContextId,
        ancestorContextError,
        "invalid-compact-page-hash-codec",
        "ancestor context identity requires a hash callback"
    )
    invalidContextId, ancestorContextError = protocol.BuildCompactPageAncestorContextId({}, {
        hash = function()
            error("hash")
        end,
    })
    AssertError(
        invalidContextId,
        ancestorContextError,
        "compact-page-ancestor-hash-failed",
        "ancestor context identity contains hash exceptions"
    )
    for _, invalidDigest in ipairs({ false, "", "1234567", "123456789", "ABCDEF12", "abcdefg1" }) do
        invalidContextId, ancestorContextError = protocol.BuildCompactPageAncestorContextId({}, {
            hash = function()
                return invalidDigest
            end,
        })
        AssertError(
            invalidContextId,
            ancestorContextError,
            "invalid-compact-page-ancestor-digest",
            "ancestor context identity rejects a noncanonical digest"
        )
    end
end

do
    local correlatedOmission, correlatedOmissionError =
        protocol.EncodeCompactPageEnvelope(compactPageEnvelope, compactPageCodec, { IncludeAncestorContext = false })
    AssertError(
        correlatedOmission,
        correlatedOmissionError,
        "compact-page-ancestor-context-reference-correlated",
        "correlated compact pages must remain self-contained"
    )

    local omittedPageEnvelope =
        assert(protocol.BuildEnvelope(compactPageSession, "PAGE_UPSERT", MakePageUpsertPayload(), {
            SentAt = 1750000000101,
        }))
    local omittedBaselineEncoded, omittedBaselineError, omittedBaselineMetadata =
        protocol.EncodeCompactPageEnvelope(omittedPageEnvelope, compactPageCodec)
    Assert(
        omittedBaselineEncoded ~= nil and omittedBaselineError == nil,
        "uncorrelated compact page baseline encodes inline"
    )
    local omittedBaselineRaw = ReadCompactPageFrameForTest(omittedBaselineEncoded)
    local omittedPageEncoded, omittedPageError, omittedPageEncodeMetadata =
        protocol.EncodeCompactPageEnvelope(omittedPageEnvelope, compactPageCodec, { IncludeAncestorContext = false })
    Assert(
        omittedPageEncoded ~= nil and omittedPageError == nil,
        "nonempty compact page ancestor context may be omitted"
    )
    local omittedPageRaw = ReadCompactPageFrameForTest(omittedPageEncoded)
    AssertEqual(omittedPageRaw:byte(1), 0, "omitted compact page has no correlation or inline-context flags")
    AssertEqual(
        #omittedBaselineRaw - #omittedPageRaw,
        omittedBaselineMetadata.AncestorContextBytes,
        "omitted compact page removes the entire canonical ancestor block"
    )
    AssertEqual(
        omittedPageEncodeMetadata.AncestorContextId,
        omittedBaselineMetadata.AncestorContextId,
        "inline and omitted packets share an ancestor identity"
    )
    AssertEqual(
        omittedPageEncodeMetadata.AncestorContextIncluded,
        false,
        "omitted compact page metadata records exclusion"
    )
    AssertEqual(
        omittedPageEncodeMetadata.AncestorContextBytes,
        omittedBaselineMetadata.AncestorContextBytes,
        "omitted encode metadata retains the reusable context size"
    )

    local missingPage, missingPageError, missingPageMetadata =
        protocol.DecodeCompactPageEnvelope(omittedPageEncoded, compactPageCodec)
    AssertError(
        missingPage,
        missingPageError,
        "compact-page-ancestor-context-missing",
        "omitted compact page requires a cached ancestor context"
    )
    AssertEqual(
        missingPageMetadata.AncestorContextId,
        omittedPageEncodeMetadata.AncestorContextId,
        "resolver miss exposes the validated ancestor identity"
    )
    AssertEqual(missingPageMetadata.AncestorContextIncluded, false, "resolver miss metadata records omitted context")
    Assert(
        missingPageMetadata.AncestorContextBytes == nil,
        "resolver miss does not guess the absent context byte count"
    )
    AssertEqual(
        missingPageMetadata.SenderInstallationId,
        omittedPageEnvelope.SenderInstallationId,
        "resolver miss exposes validated sender installation"
    )
    AssertEqual(
        missingPageMetadata.SenderSessionId,
        omittedPageEnvelope.SenderSessionId,
        "resolver miss exposes validated sender session"
    )
    AssertEqual(
        missingPageMetadata.MessageId,
        omittedPageEnvelope.MessageId,
        "resolver miss exposes validated message identity"
    )
    AssertEqual(missingPageMetadata.Sequence, omittedPageEnvelope.Sequence, "resolver miss exposes validated sequence")
    AssertEqual(missingPageMetadata.SentAt, omittedPageEnvelope.SentAt, "resolver miss exposes validated timestamp")
    Assert(missingPageMetadata.ReplyTo == nil, "resolver miss preserves the uncorrelated active-page lane")
    Assert(
        DeepEqual(missingPageMetadata.Reference, omittedBaselineMetadata.Reference),
        "resolver miss exposes only the validated page reference tuple"
    )

    local resolvedLayers = DeepCopy(omittedPageEnvelope.Payload.AncestorVariableLayers)
    local observedInstallationId
    local observedSessionId
    local observedContextId
    local resolvedPage, resolvedPageError, resolvedPageMetadata =
        protocol.DecodeCompactPageEnvelope(omittedPageEncoded, compactPageCodec, {
            ResolveAncestorContext = function(senderInstallationId, senderSessionId, contextId)
                observedInstallationId = senderInstallationId
                observedSessionId = senderSessionId
                observedContextId = contextId
                return resolvedLayers
            end,
        })
    Assert(resolvedPage ~= nil and resolvedPageError == nil, "cached ancestor context resolves omitted page")
    Assert(DeepEqual(resolvedPage, omittedPageEnvelope), "resolved omitted page is canonical")
    AssertEqual(
        observedInstallationId,
        omittedPageEnvelope.SenderInstallationId,
        "resolver receives sender installation"
    )
    AssertEqual(observedSessionId, omittedPageEnvelope.SenderSessionId, "resolver receives sender session")
    AssertEqual(
        observedContextId,
        omittedBaselineMetadata.AncestorContextId,
        "resolver receives ancestor context identity"
    )
    Assert(DeepEqual(resolvedPageMetadata, omittedPageEncodeMetadata), "resolved omitted page metadata round trips")
    resolvedLayers[1].Vars = "mutated-after-resolve"
    AssertEqual(
        resolvedPage.Payload.AncestorVariableLayers[1].Vars,
        omittedPageEnvelope.Payload.AncestorVariableLayers[1].Vars,
        "resolved ancestor context is detached from the cache"
    )

    local badResolvedPage
    badResolvedPage, resolvedPageError = protocol.DecodeCompactPageEnvelope(omittedPageEncoded, compactPageCodec, {
        ResolveAncestorContext = function()
            return {
                {
                    SyncId = activeRootSyncId,
                    Vars = "wrong",
                },
            }
        end,
    })
    AssertError(
        badResolvedPage,
        resolvedPageError,
        "compact-page-ancestor-context-id-mismatch",
        "resolved ancestor context must match its wire identity"
    )
    badResolvedPage, resolvedPageError = protocol.DecodeCompactPageEnvelope(omittedPageEncoded, compactPageCodec, {
        ResolveAncestorContext = function()
            error("resolver")
        end,
    })
    AssertError(
        badResolvedPage,
        resolvedPageError,
        "compact-page-ancestor-context-resolver-failed",
        "compact page contains resolver exceptions"
    )
    badResolvedPage, resolvedPageError = protocol.DecodeCompactPageEnvelope(omittedPageEncoded, compactPageCodec, {
        ResolveAncestorContext = function()
            return "invalid"
        end,
    })
    AssertError(
        badResolvedPage,
        resolvedPageError,
        "invalid-resolved-ancestor-context",
        "compact page validates resolved ancestor contexts"
    )

    local correlatedReferenceFrame = BuildCompactPageFrameForTest(ReplaceByte(compactPageRaw, 1, 1))
    badResolvedPage, resolvedPageError = protocol.DecodeCompactPageEnvelope(correlatedReferenceFrame, compactPageCodec)
    AssertError(
        badResolvedPage,
        resolvedPageError,
        "invalid-compact-page-flags",
        "compact page decoder rejects a correlated ancestor-context reference"
    )
end

local orphanPagePayload = MakePageUpsertPayload()
orphanPagePayload.Page.ParentSyncId = nil
orphanPagePayload.AncestorVariableLayers = {}
local orphanPageEnvelope = assert(protocol.BuildEnvelope(compactPageSession, "PAGE_UPSERT", orphanPagePayload, {
    SentAt = 1750000000102,
}))
local orphanPageEncoded, _, orphanPageEncodeMetadata =
    protocol.EncodeCompactPageEnvelope(orphanPageEnvelope, compactPageCodec, { IncludeAncestorContext = false })
assert(orphanPageEncoded)
local orphanPageRaw = ReadCompactPageFrameForTest(orphanPageEncoded)
AssertEqual(orphanPageRaw:byte(1), 2, "empty ancestor context remains inline")
AssertEqual(orphanPageEncodeMetadata.AncestorContextIncluded, true, "empty ancestor context is never omitted")
AssertEqual(orphanPageEncodeMetadata.AncestorContextBytes, 1, "empty ancestor context has one canonical byte")
local orphanPageDecoded, _, orphanPageDecodeMetadata =
    protocol.DecodeCompactPageEnvelope(orphanPageEncoded, compactPageCodec)
assert(orphanPageDecoded)
Assert(DeepEqual(orphanPageDecoded, orphanPageEnvelope), "orphan compact page round trip")
Assert(DeepEqual(orphanPageDecodeMetadata, orphanPageEncodeMetadata), "orphan compact page metadata round trip")
Assert(orphanPageDecoded.Payload.Page.ParentSyncId == nil, "orphan compact page derives no parent")
AssertEqual(#orphanPageDecoded.Payload.AncestorVariableLayers, 0, "orphan compact page retains empty layers")

local crossOwnerPayload = MakePageUpsertPayload()
crossOwnerPayload.AncestorVariableLayers[1].SyncId = "ae3i:a:b:c:d:category:9"
local crossOwnerEnvelope = assert(protocol.BuildEnvelope(compactPageSession, "PAGE_UPSERT", crossOwnerPayload, {
    SentAt = 1750000000102,
}))
local crossOwnerDecoded = assert(
    protocol.DecodeCompactPageEnvelope(
        assert(protocol.EncodeCompactPageEnvelope(crossOwnerEnvelope, compactPageCodec)),
        compactPageCodec
    )
)
Assert(
    DeepEqual(crossOwnerDecoded.Payload.AncestorVariableLayers, crossOwnerPayload.AncestorVariableLayers),
    "compact page preserves independently owned ancestor identities"
)

local maximumPageInstallationId = "ae3i:ffffffff:ffffffff:ffffffff:ffffffff"
local maximumPageSessionId = Repeat("p", protocol.LIMITS.SessionIdBytes)
local maximumPageReplySessionId = Repeat("q", protocol.LIMITS.SessionIdBytes)
local maximumPageLayers = {}
for index = 1, protocol.LIMITS.ActivePageAncestorCount do
    maximumPageLayers[index] = {
        SyncId = maximumPageInstallationId .. ":category:" .. tostring(index),
        Vars = Repeat("v", protocol.LIMITS.ActivePageVarsBytes),
    }
end
local maximumPagePayload = {
    Page = {
        Kind = "page",
        SyncId = maximumPageInstallationId .. ":page:" .. tostring(protocol.LIMITS.ActivePageRevision),
        OwnerId = maximumPageInstallationId,
        Revision = protocol.LIMITS.ActivePageRevision,
        RevisionId = "fcs32:ffffffff",
        UpdatedAt = protocol.LIMITS.ActivePageTimestamp,
        UpdatedBy = Repeat("u", protocol.LIMITS.ActivePageAuthorBytes),
        ParentSyncId = maximumPageLayers[#maximumPageLayers].SyncId,
        Order = protocol.LIMITS.ActivePageOrder,
        Name = Repeat("n", protocol.LIMITS.ActivePageNameBytes),
        Vars = Repeat("p", protocol.LIMITS.ActivePageVarsBytes),
        Contents = Repeat("c", protocol.LIMITS.ActivePageContentsBytes),
    },
    AncestorVariableLayers = maximumPageLayers,
    ContextRevisionId = "fcs32:00000000",
}
local maximumPageSession = assert(protocol.NewSession(maximumPageInstallationId, maximumPageSessionId))
maximumPageSession.Sequence = protocol.LIMITS.Sequence - 1
local maximumPageEnvelope = assert(protocol.BuildEnvelope(maximumPageSession, "PAGE_UPSERT", maximumPagePayload, {
    ReplyTo = table.concat({
        maximumPageInstallationId,
        maximumPageReplySessionId,
        tostring(protocol.LIMITS.Sequence),
    }, ":"),
    SentAt = protocol.LIMITS.ActivePageTimestamp,
}))
local maximumPageEncoded = assert(protocol.EncodeCompactPageEnvelope(maximumPageEnvelope, compactPageCodec))
local maximumPageRaw = ReadCompactPageFrameForTest(maximumPageEncoded)
AssertEqual(#maximumPageRaw, protocol.COMPACT_PAGE_LIMITS.RawBytes, "maximum compact page exactly fills raw budget")
AssertEqual(
    #maximumPageEncoded,
    protocol.COMPACT_PAGE_LIMITS.RawBytes + 5,
    "identity-compressed maximum compact page includes only its frame header"
)
local maximumPageDecoded = assert(protocol.DecodeCompactPageEnvelope(maximumPageEncoded, compactPageCodec))
Assert(DeepEqual(maximumPageDecoded, maximumPageEnvelope), "maximum compact page round trip")

local compactPageValue
local compactPageError
compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(queryEnvelope, compactPageCodec)
AssertError(
    compactPageValue,
    compactPageError,
    "compact-page-type-mismatch",
    "compact page encoder rejects non-page envelope"
)
for _, missingCallback in ipairs({ "compress", "decompress", "encode", "decode", "hash" }) do
    local invalidCompactPageCodec = MakeCompactPageCodec()
    invalidCompactPageCodec[missingCallback] = nil
    compactPageValue, compactPageError =
        protocol.EncodeCompactPageEnvelope(compactPageEnvelope, invalidCompactPageCodec)
    AssertError(
        compactPageValue,
        compactPageError,
        "invalid-compact-page-codec",
        "compact page encode requires " .. missingCallback
    )
end

local invalidCompactPageEnvelope = DeepCopy(compactPageEnvelope)
invalidCompactPageEnvelope.Payload.Page.SyncId = activeInstallationId .. ":page:03"
compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(invalidCompactPageEnvelope, compactPageCodec)
AssertError(
    compactPageValue,
    compactPageError,
    "invalid-page-sync-id",
    "compact page rejects noncanonical page identity"
)
invalidCompactPageEnvelope = DeepCopy(compactPageEnvelope)
invalidCompactPageEnvelope.Payload.AncestorVariableLayers[1].SyncId = activePageSyncId
compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(invalidCompactPageEnvelope, compactPageCodec)
AssertError(
    compactPageValue,
    compactPageError,
    "invalid-ancestor-sync-id",
    "compact page rejects wrong ancestor identity kind"
)
invalidCompactPageEnvelope = DeepCopy(compactPageEnvelope)
invalidCompactPageEnvelope.Payload.Page.RevisionId = "fcs32:ABCDEF12"
compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(invalidCompactPageEnvelope, compactPageCodec)
AssertError(
    compactPageValue,
    compactPageError,
    "invalid-page-revision-id",
    "compact page rejects noncanonical page hash"
)
invalidCompactPageEnvelope = DeepCopy(compactPageEnvelope)
invalidCompactPageEnvelope.Payload.ContextRevisionId = "fcs32:1234567"
compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(invalidCompactPageEnvelope, compactPageCodec)
AssertError(
    compactPageValue,
    compactPageError,
    "invalid-context-revision-id",
    "compact page rejects malformed context hash"
)
invalidCompactPageEnvelope = DeepCopy(compactPageEnvelope)
invalidCompactPageEnvelope.Payload.Page.ParentSyncId = activeRootSyncId
compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(invalidCompactPageEnvelope, compactPageCodec)
AssertError(
    compactPageValue,
    compactPageError,
    "unsupported-compact-page-parent",
    "compact page rejects a parent that cannot be derived exactly"
)

compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(
    compactPageEnvelope,
    MakeCompactPageCodec({
        compress = function()
            error("compress")
        end,
    })
)
AssertError(compactPageValue, compactPageError, "compact-page-compress-failed", "compact page compress exception")
for _, invalidCompressed in ipairs({ false, "" }) do
    compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(
        compactPageEnvelope,
        MakeCompactPageCodec({
            compress = function()
                return invalidCompressed
            end,
        })
    )
    AssertError(
        compactPageValue,
        compactPageError,
        "compact-page-compress-failed",
        "compact page rejects invalid compressed result"
    )
end
compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(
    compactPageEnvelope,
    MakeCompactPageCodec({
        compress = function()
            return Repeat("c", protocol.COMPACT_PAGE_LIMITS.CompressedBytes + 1)
        end,
    })
)
AssertError(compactPageValue, compactPageError, "compact-page-compressed-too-large", "compact page compressed bound")
local exactCompressedPage = assert(protocol.EncodeCompactPageEnvelope(
    compactPageEnvelope,
    MakeCompactPageCodec({
        compress = function()
            return Repeat("c", protocol.COMPACT_PAGE_LIMITS.CompressedBytes)
        end,
    })
))
AssertEqual(
    #exactCompressedPage,
    protocol.COMPACT_PAGE_LIMITS.EncodedBytes,
    "compact page accepts exact compressed and encoded bound"
)

compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(
    compactPageEnvelope,
    MakeCompactPageCodec({
        encode = function()
            error("encode")
        end,
    })
)
AssertError(compactPageValue, compactPageError, "compact-page-encode-failed", "compact page channel encode exception")
for _, invalidEncoded in ipairs({ false, "" }) do
    compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(
        compactPageEnvelope,
        MakeCompactPageCodec({
            encode = function()
                return invalidEncoded
            end,
        })
    )
    AssertError(
        compactPageValue,
        compactPageError,
        "compact-page-encode-failed",
        "compact page rejects invalid channel encoding"
    )
end
compactPageValue, compactPageError = protocol.EncodeCompactPageEnvelope(
    compactPageEnvelope,
    MakeCompactPageCodec({
        encode = function()
            return Repeat("e", protocol.COMPACT_PAGE_LIMITS.EncodedBytes + 1)
        end,
    })
)
AssertError(compactPageValue, compactPageError, "compact-page-encoded-too-large", "compact page encoded bound")

compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope("", compactPageCodec)
AssertError(compactPageValue, compactPageError, "invalid-compact-page-encoded", "compact page empty input")
for _, missingCallback in ipairs({ "compress", "decompress", "encode", "decode", "hash" }) do
    local invalidCompactPageCodec = MakeCompactPageCodec()
    invalidCompactPageCodec[missingCallback] = nil
    compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(compactPageEncoded, invalidCompactPageCodec)
    AssertError(
        compactPageValue,
        compactPageError,
        "invalid-compact-page-codec",
        "compact page decode requires " .. missingCallback
    )
end
compactPageValue, compactPageError =
    protocol.DecodeCompactPageEnvelope(Repeat("e", protocol.COMPACT_PAGE_LIMITS.EncodedBytes + 1), compactPageCodec)
AssertError(compactPageValue, compactPageError, "compact-page-encoded-too-large", "compact page input bound")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    "encoded",
    MakeCompactPageCodec({
        decode = function()
            error("decode")
        end,
    })
)
AssertError(compactPageValue, compactPageError, "compact-page-decode-failed", "compact page channel decode exception")
for _, invalidFrame in ipairs({ false, "" }) do
    compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
        "encoded",
        MakeCompactPageCodec({
            decode = function()
                return invalidFrame
            end,
        })
    )
    AssertError(
        compactPageValue,
        compactPageError,
        "compact-page-decode-failed",
        "compact page rejects invalid channel decode"
    )
end
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    "encoded",
    MakeCompactPageCodec({
        decode = function()
            return Repeat("f", protocol.COMPACT_PAGE_LIMITS.CompressedBytes + 6)
        end,
    })
)
AssertError(compactPageValue, compactPageError, "compact-page-frame-too-large", "compact page decoded frame bound")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope("short", compactPageCodec)
AssertError(compactPageValue, compactPageError, "invalid-compact-page-frame", "compact page short frame")

local unsupportedCompactPageFrame = ReplaceByte(compactPageEncoded, 1, protocol.COMPACT_PAGE_FORMAT + 1)
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(unsupportedCompactPageFrame, compactPageCodec)
AssertError(
    compactPageValue,
    compactPageError,
    "unsupported-compact-page-format",
    "compact page rejects unknown format"
)
compactPageValue, compactPageError =
    protocol.DecodeCompactPageEnvelope(BuildCompactPageFrameForTest(compactPageRaw, 0), compactPageCodec)
AssertError(
    compactPageValue,
    compactPageError,
    "invalid-compact-page-raw-length",
    "compact page rejects zero declared length"
)
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(compactPageRaw, protocol.COMPACT_PAGE_LIMITS.RawBytes + 1),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "compact-page-raw-too-large", "compact page declared raw bound")

local observedCompactPageBudget
compactPageDecoded = assert(protocol.DecodeCompactPageEnvelope(
    compactPageEncoded,
    MakeCompactPageCodec({
        decompress = function(value, maximumOutputBytes)
            observedCompactPageBudget = maximumOutputBytes
            return value
        end,
    })
))
AssertEqual(
    observedCompactPageBudget,
    #compactPageRaw,
    "compact page decompressor receives exact declared output budget"
)
Assert(DeepEqual(compactPageDecoded, compactPageEnvelope), "custom bounded decompressor round trip")
compactPageDecoded = assert(protocol.DecodeCompactPageEnvelope(
    compactPageEncoded,
    MakeCompactPageCodec({
        decompress = function(value)
            return value, 0
        end,
    })
))
Assert(DeepEqual(compactPageDecoded, compactPageEnvelope), "zero compressed trailing count is accepted")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    compactPageEncoded,
    MakeCompactPageCodec({
        decompress = function(value)
            return value, 1
        end,
    })
)
AssertError(
    compactPageValue,
    compactPageError,
    "compact-page-compressed-trailing-data",
    "compact page rejects bytes trailing the compressed stream"
)
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    compactPageEncoded,
    MakeCompactPageCodec({
        decompress = function()
            error("decompress")
        end,
    })
)
AssertError(compactPageValue, compactPageError, "compact-page-decompress-failed", "compact page decompress exception")
for _, invalidRaw in ipairs({ false, 3 }) do
    compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
        compactPageEncoded,
        MakeCompactPageCodec({
            decompress = function()
                return invalidRaw
            end,
        })
    )
    AssertError(
        compactPageValue,
        compactPageError,
        "compact-page-decompress-failed",
        "compact page rejects invalid decompressed result"
    )
end
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    compactPageEncoded,
    MakeCompactPageCodec({
        decompress = function()
            return nil, "output-too-large"
        end,
    })
)
AssertError(
    compactPageValue,
    compactPageError,
    "compact-page-raw-length-mismatch",
    "compact page maps bounded decompressor overflow"
)
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(compactPageRaw, #compactPageRaw - 1),
    compactPageCodec
)
AssertError(
    compactPageValue,
    compactPageError,
    "compact-page-raw-length-mismatch",
    "compact page rejects decompressed output longer than declared"
)
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(compactPageRaw, #compactPageRaw + 1),
    compactPageCodec
)
AssertError(
    compactPageValue,
    compactPageError,
    "compact-page-raw-length-mismatch",
    "compact page rejects decompressed output shorter than declared"
)

compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(ReplaceByte(compactPageRaw, 1, 4)),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page-flags", "compact page unknown flag")
compactPageValue, compactPageError =
    protocol.DecodeCompactPageEnvelope(BuildCompactPageFrameForTest(compactPageRaw .. "\0"), compactPageCodec)
AssertError(compactPageValue, compactPageError, "compact-page-trailing-data", "compact page trailing raw byte")

for length = 1, #compactPageEncoded - 1 do
    compactPageValue, compactPageError =
        protocol.DecodeCompactPageEnvelope(compactPageEncoded:sub(1, length), compactPageCodec)
    Assert(
        compactPageValue == nil and compactPageError ~= nil,
        "every truncated compact page must fail at byte " .. tostring(length)
    )
end

local compactPageSessionLengthOffset = 18
local compactPageSessionStart = compactPageSessionLengthOffset + 1
local compactPageSequenceStart = compactPageSessionStart + #compactPageEnvelope.SenderSessionId
local compactPageAfterIdentity = compactPageSequenceStart + 4 + 7
local compactPageReplyBytes = 16 + 1 + #queryEnvelope.SenderSessionId + 4
local compactPageSyncStart = compactPageAfterIdentity + compactPageReplyBytes
local compactPageUpdatedByLength = compactPageSyncStart + 20 + 4 + 4 + 7
local compactPageOrderStart = compactPageUpdatedByLength + 1 + #compactPageEnvelope.Payload.Page.UpdatedBy
local compactPageNameLength = compactPageOrderStart + 2
local compactPageVarsLength = compactPageNameLength + 1 + #compactPageEnvelope.Payload.Page.Name
local compactPageContentsLength = compactPageVarsLength + 2 + #compactPageEnvelope.Payload.Page.Vars
local compactPageAncestorContextId = compactPageContentsLength + 2 + #compactPageEnvelope.Payload.Page.Contents
local compactPageLayerCount = compactPageAncestorContextId + 4
local compactPageFirstLayerStart = compactPageLayerCount + 1
local compactPageFirstLayerVarsLength = compactPageFirstLayerStart + 20

compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(ReplaceByte(compactPageRaw, compactPageSessionLengthOffset, 0)),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page zero session length")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(
        ReplaceByte(compactPageRaw, compactPageSessionLengthOffset, protocol.LIMITS.SessionIdBytes + 1)
    ),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page overlong session length")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(ReplaceByte(compactPageRaw, compactPageSessionStart, string.byte(":"))),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-session-id", "compact page invalid session identity")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(ReplaceBytes(compactPageRaw, compactPageSequenceStart, "\0\0\0\0")),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-sequence", "compact page zero sender sequence")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(ReplaceBytes(compactPageRaw, compactPageSyncStart + 16, "\0\0\0\0")),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page zero entity sequence")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(ReplaceBytes(compactPageRaw, compactPageSyncStart + 20, "\0\0\0\0")),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-page-revision", "compact page zero page revision")

compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(
        ReplaceByte(compactPageRaw, compactPageUpdatedByLength, protocol.LIMITS.ActivePageAuthorBytes + 1)
    ),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page overlong author length")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(
        ReplaceByte(compactPageRaw, compactPageNameLength, protocol.LIMITS.ActivePageNameBytes + 1)
    ),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page overlong name length")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(
        ReplaceBytes(
            compactPageRaw,
            compactPageVarsLength,
            EncodeUnsignedForTest(protocol.LIMITS.ActivePageVarsBytes + 1, 2)
        )
    ),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page overlong page vars length")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(
        ReplaceBytes(
            compactPageRaw,
            compactPageContentsLength,
            EncodeUnsignedForTest(protocol.LIMITS.ActivePageContentsBytes + 1, 2)
        )
    ),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page overlong contents length")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(
        ReplaceByte(compactPageRaw, compactPageLayerCount, protocol.LIMITS.ActivePageAncestorCount + 1)
    ),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page overlong layer count")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(ReplaceBytes(compactPageRaw, compactPageFirstLayerStart + 16, "\0\0\0\0")),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page zero ancestor sequence")
compactPageValue, compactPageError = protocol.DecodeCompactPageEnvelope(
    BuildCompactPageFrameForTest(
        ReplaceBytes(
            compactPageRaw,
            compactPageFirstLayerVarsLength,
            EncodeUnsignedForTest(protocol.LIMITS.ActivePageVarsBytes + 1, 2)
        )
    ),
    compactPageCodec
)
AssertError(compactPageValue, compactPageError, "invalid-compact-page", "compact page overlong ancestor vars length")

local compactCodec = MakeCompactCodec()
local compactSession = assert(protocol.NewSession(installationId, "compact-display"))
local compactDisplayEnvelope = assert(protocol.BuildEnvelope(compactSession, "DISPLAY", {
    Displayed = true,
    PageFollows = true,
    SyncId = activePageSyncId,
    Revision = 4,
    RevisionId = "fcs32:12345678",
    ContextRevisionId = "fcs32:87654321",
}, {
    ReplyTo = queryEnvelope.MessageId,
    SentAt = 1750000000123,
}))
local compactEncoded, compactEncodeError = protocol.EncodeCompactDisplayEnvelope(compactDisplayEnvelope, compactCodec)
Assert(compactEncoded ~= nil and compactEncodeError == nil, "valid compact display encodes")
local compactRaw = UnpackCompactForTest(compactEncoded)
AssertEqual(compactRaw:byte(1), protocol.COMPACT_DISPLAY_FORMAT, "compact display format byte")
AssertEqual(compactRaw:byte(2), 7, "compact display combines displayed, reply, and page-follows flags")
for index = 1, #compactEncoded do
    local byte = compactEncoded:byte(index)
    Assert(byte >= 2 and byte <= 129, "compact display uses safe packed byte " .. tostring(index))
end

local compactDecoded, compactDecodeError = protocol.DecodeCompactDisplayEnvelope(compactEncoded, compactCodec)
Assert(compactDecoded ~= nil and compactDecodeError == nil, "valid compact display decodes")
AssertEqual(compactDecoded.Protocol, compactDisplayEnvelope.Protocol, "compact display protocol")
AssertEqual(compactDecoded.Type, compactDisplayEnvelope.Type, "compact display type")
AssertEqual(compactDecoded.MessageId, compactDisplayEnvelope.MessageId, "compact display message identity")
AssertEqual(compactDecoded.ReplyTo, compactDisplayEnvelope.ReplyTo, "compact display reply correlation")
AssertEqual(
    compactDecoded.SenderInstallationId,
    compactDisplayEnvelope.SenderInstallationId,
    "compact display sender installation"
)
AssertEqual(compactDecoded.SenderSessionId, compactDisplayEnvelope.SenderSessionId, "compact display sender session")
AssertEqual(compactDecoded.Sequence, compactDisplayEnvelope.Sequence, "compact display sequence")
AssertEqual(compactDecoded.SentAt, compactDisplayEnvelope.SentAt, "compact display timestamp")
AssertEqual(compactDecoded.Payload.Displayed, true, "compact display selected state")
AssertEqual(compactDecoded.Payload.PageFollows, true, "compact display page-follows hint")
AssertEqual(compactDecoded.Payload.SyncId, compactDisplayEnvelope.Payload.SyncId, "compact display sync identity")
AssertEqual(compactDecoded.Payload.RevisionId, compactDisplayEnvelope.Payload.RevisionId, "compact display revision")
AssertEqual(
    compactDecoded.Payload.ContextRevisionId,
    compactDisplayEnvelope.Payload.ContextRevisionId,
    "compact display context revision"
)

local groupDisplayEnvelope = assert(protocol.BuildEnvelope(compactSession, "DISPLAY", {
    Displayed = true,
    PageFollows = true,
    SyncId = activePageSyncId,
    Revision = 4,
    RevisionId = "fcs32:12345678",
    ContextRevisionId = "fcs32:87654321",
}, {
    SentAt = 1750000000124,
}))
local groupDisplayPacked = assert(protocol.EncodeCompactDisplayEnvelope(groupDisplayEnvelope, compactCodec))
AssertEqual(UnpackCompactForTest(groupDisplayPacked):byte(2), 5, "page-follows flag does not imply reply correlation")
compactDecoded = assert(protocol.DecodeCompactDisplayEnvelope(groupDisplayPacked, compactCodec))
Assert(compactDecoded.ReplyTo == nil, "uncorrelated compact display stays uncorrelated")
AssertEqual(compactDecoded.Payload.PageFollows, true, "uncorrelated compact display retains page-follows hint")

local clearDisplayEnvelope = assert(protocol.BuildEnvelope(compactSession, "DISPLAY", {
    Displayed = false,
    PageFollows = false,
}, {
    ReplyTo = queryEnvelope.MessageId,
    SentAt = 1750000000125,
}))
local clearDisplayPacked = assert(protocol.EncodeCompactDisplayEnvelope(clearDisplayEnvelope, compactCodec))
local clearDisplayRaw = UnpackCompactForTest(clearDisplayPacked)
AssertEqual(clearDisplayRaw:byte(2), 2, "clear display retains only reply flag")
compactDecoded = assert(protocol.DecodeCompactDisplayEnvelope(clearDisplayPacked, compactCodec))
AssertEqual(compactDecoded.Payload.Displayed, false, "compact clear display state")
Assert(compactDecoded.Payload.PageFollows == nil, "false page-follows hint decodes canonically as omitted")
AssertEqual(compactDecoded.ReplyTo, queryEnvelope.MessageId, "compact clear display correlation")

local maximumInstallationId = "ae3i:ffffffff:ffffffff:ffffffff:ffffffff"
local maximumSessionId = Repeat("s", protocol.LIMITS.SessionIdBytes)
local maximumReplySessionId = Repeat("r", protocol.LIMITS.SessionIdBytes)
local maximumCompactSession = assert(protocol.NewSession(maximumInstallationId, maximumSessionId))
maximumCompactSession.Sequence = protocol.LIMITS.Sequence - 1
local maximumCompactEnvelope = assert(protocol.BuildEnvelope(maximumCompactSession, "DISPLAY", {
    Displayed = true,
    PageFollows = true,
    SyncId = maximumInstallationId .. ":page:" .. protocol.LIMITS.ActivePageRevision,
    Revision = protocol.LIMITS.ActivePageRevision,
    RevisionId = "fcs32:ffffffff",
    ContextRevisionId = "fcs32:00000000",
}, {
    ReplyTo = table.concat({
        maximumInstallationId,
        maximumReplySessionId,
        tostring(protocol.LIMITS.Sequence),
    }, ":"),
    SentAt = 9007199254740991,
}))
local maximumCompactPacked = assert(protocol.EncodeCompactDisplayEnvelope(maximumCompactEnvelope, compactCodec))
AssertEqual(
    #maximumCompactPacked,
    protocol.COMPACT_DISPLAY_LIMITS.PackedBytes,
    "maximum compact display exactly fills packed budget"
)
local maximumCompactRaw = UnpackCompactForTest(maximumCompactPacked)
AssertEqual(
    #maximumCompactRaw,
    protocol.COMPACT_DISPLAY_LIMITS.RawBytes,
    "maximum compact display exactly fills raw budget"
)
for index = 1, #maximumCompactPacked do
    local byte = maximumCompactPacked:byte(index)
    Assert(byte >= 2 and byte <= 129, "maximum compact display uses safe packed byte " .. tostring(index))
end
compactDecoded = assert(protocol.DecodeCompactDisplayEnvelope(maximumCompactPacked, compactCodec))
AssertEqual(compactDecoded.MessageId, maximumCompactEnvelope.MessageId, "maximum compact message identity")
AssertEqual(compactDecoded.ReplyTo, maximumCompactEnvelope.ReplyTo, "maximum compact reply identity")
AssertEqual(compactDecoded.SentAt, maximumCompactEnvelope.SentAt, "maximum compact safe timestamp")
AssertEqual(compactDecoded.Payload.SyncId, maximumCompactEnvelope.Payload.SyncId, "maximum compact page identity")
AssertEqual(compactDecoded.Payload.Revision, protocol.LIMITS.ActivePageRevision, "maximum compact numeric revision")
AssertEqual(compactDecoded.Payload.RevisionId, "fcs32:ffffffff", "maximum compact revision identity")
AssertEqual(compactDecoded.Payload.ContextRevisionId, "fcs32:00000000", "zero compact context revision")

local faithfulSawUnsafeByte = false
local faithfulAddonCodec = MakeFaithfulAddonCodec(function(packed)
    faithfulSawUnsafeByte = packed:find("\000", 1, true) ~= nil or packed:find("\001", 1, true) ~= nil
end)
local faithfulCompact = assert(protocol.EncodeCompactDisplayEnvelope(maximumCompactEnvelope, faithfulAddonCodec))
Assert(not faithfulSawUnsafeByte, "maximum compact display avoids bytes escaped by the addon-channel codec")
AssertEqual(#faithfulCompact, 242, "maximum compact display remains bounded through addon-channel encoding")
Assert(
    #faithfulCompact < protocol.COMPACT_DISPLAY_LIMITS.EncodedBytes,
    "maximum encoded compact display leaves AceComm escape room"
)
compactDecoded = assert(protocol.DecodeCompactDisplayEnvelope(faithfulCompact, faithfulAddonCodec))
AssertEqual(compactDecoded.MessageId, maximumCompactEnvelope.MessageId, "faithful codec compact round trip")

local exactLimitCompact = assert(protocol.EncodeCompactDisplayEnvelope(
    maximumCompactEnvelope,
    MakeCompactCodec({
        encode = function()
            return Repeat("e", protocol.COMPACT_DISPLAY_LIMITS.EncodedBytes)
        end,
    })
))
AssertEqual(#exactLimitCompact, 254, "compact display accepts exact single-frame bound")

local compactValue
local compactError
compactValue, compactError = protocol.EncodeCompactDisplayEnvelope(queryEnvelope, compactCodec)
AssertError(compactValue, compactError, "compact-display-type-mismatch", "compact codec rejects non-display envelope")
compactValue, compactError = protocol.EncodeCompactDisplayEnvelope(compactDisplayEnvelope, {})
AssertError(compactValue, compactError, "invalid-compact-display-codec", "compact encode requires channel codec")

compactValue, compactError = protocol.EncodeCompactDisplayEnvelope(
    compactDisplayEnvelope,
    MakeCompactCodec({
        encode = function()
            error("encode")
        end,
    })
)
AssertError(compactValue, compactError, "compact-display-encode-failed", "compact encode exception")
compactValue, compactError = protocol.EncodeCompactDisplayEnvelope(
    compactDisplayEnvelope,
    MakeCompactCodec({
        encode = function()
            return nil
        end,
    })
)
AssertError(compactValue, compactError, "compact-display-encode-failed", "compact encode nil")
compactValue, compactError = protocol.EncodeCompactDisplayEnvelope(
    maximumCompactEnvelope,
    MakeCompactCodec({
        encode = function()
            return Repeat("e", protocol.COMPACT_DISPLAY_LIMITS.EncodedBytes + 1)
        end,
    })
)
AssertError(compactValue, compactError, "compact-display-encoded-too-large", "compact encode single-frame bound")

compactValue, compactError = protocol.DecodeCompactDisplayEnvelope("", compactCodec)
AssertError(compactValue, compactError, "invalid-compact-display-encoded", "compact decode empty input")
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope("encoded", {})
AssertError(compactValue, compactError, "invalid-compact-display-codec", "compact decode requires channel codec")
compactValue, compactError =
    protocol.DecodeCompactDisplayEnvelope(Repeat("e", protocol.COMPACT_DISPLAY_LIMITS.EncodedBytes + 1), compactCodec)
AssertError(compactValue, compactError, "compact-display-encoded-too-large", "compact decode single-frame bound")
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(
    "encoded",
    MakeCompactCodec({
        decode = function()
            error("decode")
        end,
    })
)
AssertError(compactValue, compactError, "compact-display-decode-failed", "compact decode exception")
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(
    "encoded",
    MakeCompactCodec({
        decode = function()
            return Repeat(string.char(2), protocol.COMPACT_DISPLAY_LIMITS.PackedBytes + 1)
        end,
    })
)
AssertError(compactValue, compactError, "compact-display-packed-too-large", "compact decode packed bound")

compactValue, compactError = protocol.DecodeCompactDisplayEnvelope("\001", compactCodec)
AssertError(
    compactValue,
    compactError,
    "invalid-compact-display-packing",
    "compact display rejects bytes outside the safe alphabet"
)
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(Repeat(string.char(2), 9), compactCodec)
AssertError(
    compactValue,
    compactError,
    "noncanonical-compact-display-length",
    "compact display rejects redundant zero symbols"
)
local maximumLastPackedByte = maximumCompactPacked:byte(#maximumCompactPacked)
local noncanonicalPaddingCompact = ReplaceByte(maximumCompactPacked, #maximumCompactPacked, maximumLastPackedByte + 16)
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(noncanonicalPaddingCompact, compactCodec)
AssertError(
    compactValue,
    compactError,
    "noncanonical-compact-display-padding",
    "compact display rejects nonzero padding bits"
)

compactValue, compactError =
    protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(ReplaceByte(compactRaw, 1, 1)), compactCodec)
AssertError(compactValue, compactError, "unsupported-compact-display-format", "compact display format mismatch")
compactValue, compactError =
    protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(ReplaceByte(compactRaw, 2, 16)), compactCodec)
AssertError(compactValue, compactError, "invalid-compact-display-flags", "compact display unknown flag")
compactValue, compactError =
    protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(ReplaceByte(clearDisplayRaw, 2, 4)), compactCodec)
AssertError(compactValue, compactError, "invalid-compact-display-flags", "compact clear display cannot promise a page")
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(compactRaw .. "\0"), compactCodec)
AssertError(compactValue, compactError, "compact-display-trailing-data", "compact display trailing byte")

for length = 1, #compactEncoded - 1 do
    compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(compactEncoded:sub(1, length), compactCodec)
    Assert(
        compactValue == nil and compactError ~= nil,
        "every truncated compact display must fail at byte " .. tostring(length)
    )
end

local compactSequenceStart = 2 + 16 + 1 + #compactDisplayEnvelope.SenderSessionId + 1
local zeroSequenceRaw = compactRaw:sub(1, compactSequenceStart - 1)
    .. "\0\0\0\0"
    .. compactRaw:sub(compactSequenceStart + 4)
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(zeroSequenceRaw), compactCodec)
AssertError(compactValue, compactError, "invalid-sequence", "compact display zero sequence")

local invalidSessionRaw = ReplaceByte(compactRaw, 20, string.byte(":"))
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(invalidSessionRaw), compactCodec)
AssertError(compactValue, compactError, "invalid-session-id", "compact display invalid session character")

local compactSentAtHighByte = 2 + 16 + 1 + #compactDisplayEnvelope.SenderSessionId + 4 + 7
local oversizedSentAtRaw = ReplaceByte(compactRaw, compactSentAtHighByte, 32)
compactValue, compactError = protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(oversizedSentAtRaw), compactCodec)
AssertError(compactValue, compactError, "invalid-compact-display", "compact display timestamp exceeds uint53")

local everyByteSession = assert(protocol.NewSession(installationId, "compact-every-byte"))
for byte = 0, 255 do
    local revisionId = "fcs32:000000" .. string.format("%02x", byte)
    local everyByteEnvelope = assert(protocol.BuildEnvelope(everyByteSession, "DISPLAY", {
        Displayed = true,
        SyncId = activePageSyncId,
        Revision = byte + 1,
        RevisionId = revisionId,
        ContextRevisionId = "fcs32:00000000",
    }, {
        SentAt = 1750000001000 + byte,
    }))
    local everyBytePacked = assert(protocol.EncodeCompactDisplayEnvelope(everyByteEnvelope, compactCodec))
    for index = 1, #everyBytePacked do
        local packedByte = everyBytePacked:byte(index)
        Assert(
            packedByte >= 2 and packedByte <= 129,
            "source byte " .. tostring(byte) .. " produces safe packed byte " .. tostring(index)
        )
    end
    local everyByteDecoded = assert(protocol.DecodeCompactDisplayEnvelope(everyBytePacked, compactCodec))
    AssertEqual(
        everyByteDecoded.Payload.RevisionId,
        revisionId,
        "compact round trip for source byte " .. tostring(byte)
    )
end

for sessionLength = 1, protocol.LIMITS.SessionIdBytes do
    local paddingSessionId = Repeat("p", sessionLength)
    local paddingSession = assert(protocol.NewSession(installationId, paddingSessionId))
    local paddingEnvelope = assert(protocol.BuildEnvelope(paddingSession, "DISPLAY", {
        Displayed = false,
    }, {
        SentAt = 1750000002000 + sessionLength,
    }))
    local paddingPacked = assert(protocol.EncodeCompactDisplayEnvelope(paddingEnvelope, compactCodec))
    local paddingRaw = UnpackCompactForTest(paddingPacked)
    AssertEqual(
        #paddingPacked,
        math.ceil(#paddingRaw * 8 / 7),
        "compact canonical length for sender session length " .. tostring(sessionLength)
    )
    local paddingDecoded = assert(protocol.DecodeCompactDisplayEnvelope(paddingPacked, compactCodec))
    AssertEqual(
        paddingDecoded.SenderSessionId,
        paddingSessionId,
        "compact padding round trip for sender session length " .. tostring(sessionLength)
    )
end

local seenCache, seenCacheError = protocol.NewSeenCache(2)
Assert(seenCache ~= nil and seenCacheError == nil, "bounded seen cache should build")

local messagePrefix = installationId .. ":session:"
local duplicate, seenError = protocol.SeenOrRemember(seenCache, "Alpha-Realm", messagePrefix .. "1")
Assert(duplicate == false and seenError == nil, "first sender/message pair is new")
duplicate, seenError = protocol.SeenOrRemember(seenCache, "Alpha-Realm", messagePrefix .. "1")
Assert(duplicate == true and seenError == nil, "same sender/message pair is duplicate")
duplicate, seenError = protocol.SeenOrRemember(seenCache, "Beta-Realm", messagePrefix .. "1")
Assert(duplicate == false and seenError == nil, "same message ID from another sender is new")
AssertEqual(seenCache.Size, 2, "cache fills to bound")

duplicate, seenError = protocol.SeenOrRemember(seenCache, "Alpha-Realm", messagePrefix .. "2")
Assert(duplicate == false and seenError == nil, "third pair is new")
AssertEqual(seenCache.Size, 2, "cache remains bounded after eviction")
Assert(seenCache.Order[1] ~= nil and seenCache.Order[2] ~= nil, "seen cache ring uses only bounded slots")
Assert(seenCache.Order[3] == nil, "seen cache ring does not grow past its bound")
duplicate, seenError = protocol.SeenOrRemember(seenCache, "Alpha-Realm", messagePrefix .. "1")
Assert(duplicate == false and seenError == nil, "oldest pair was evicted")

local sizeBeforeInvalidMessage = seenCache.Size
duplicate, seenError = protocol.SeenOrRemember(seenCache, "Alpha-Realm", "bad")
AssertError(duplicate, seenError, "invalid-message-id", "seen cache malformed message ID")
AssertEqual(seenCache.Size, sizeBeforeInvalidMessage, "invalid message does not change cache")

local invalidCache, invalidCacheError = protocol.NewSeenCache(0)
AssertError(invalidCache, invalidCacheError, "invalid-seen-cache-size", "zero seen cache size")
duplicate, seenError = protocol.SeenOrRemember({}, "Alpha-Realm", messagePrefix .. "1")
AssertError(duplicate, seenError, "invalid-seen-cache", "malformed seen cache")

print(string.format("Protocol tests passed (%d assertions).", assertions))
