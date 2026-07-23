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

AssertEqual(protocol.VERSION, 3, "protocol version")
AssertEqual(protocol.PREFIX, "AngryEra3", "protocol prefix")
AssertEqual(protocol.DISPLAY_PREFIX, "AngryEra3D", "display protocol prefix")
AssertEqual(protocol.ACTIVE_PAGE_PREFIX, "AngryEra3P", "active-page protocol prefix")
AssertEqual(protocol.WIRE_LIMITS.EncodedBytes, 256 * 1024, "encoded byte limit")
AssertEqual(protocol.WIRE_LIMITS.CompressedBytes, 256 * 1024, "compressed byte limit")
AssertEqual(protocol.WIRE_LIMITS.SerializedBytes, 1024 * 1024, "serialized byte limit")
AssertEqual(protocol.LIMITS.InstallationIdBytes, 40, "compact installation identity bound")
AssertEqual(protocol.COMPACT_DISPLAY_FORMAT, 1, "compact display format")
AssertEqual(protocol.COMPACT_DISPLAY_LIMITS.EncodedBytes, 254, "compact display single-frame bound")
AssertEqual(protocol.COMPACT_DISPLAY_LIMITS.PackedBytes, 237, "compact display safe-alphabet bound")
AssertEqual(protocol.COMPACT_DISPLAY_LIMITS.RawBytes, 207, "compact display raw bound")

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
    RevisionId = "fcs32:12345678",
    ContextRevisionId = "fcs32:87654321",
})
Assert(payloadValid and payloadError == nil, "set display payload")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = true,
    PageFollows = false,
    SyncId = activePageSyncId,
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
    RevisionId = "fcs32:12345678",
    ContextRevisionId = "fcs32:87654321",
})
AssertError(payloadValid, payloadError, "invalid-page-follows", "page-follows hint must be boolean")
payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = true,
    SyncId = activePageSyncId,
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

payloadValid, payloadError = protocol.ValidatePayload("DISPLAY", {
    Displayed = true,
    SyncId = activeInstallationId .. ":page:2147483648",
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

local compactCodec = MakeCompactCodec()
local compactSession = assert(protocol.NewSession(installationId, "compact-display"))
local compactDisplayEnvelope = assert(protocol.BuildEnvelope(compactSession, "DISPLAY", {
    Displayed = true,
    PageFollows = true,
    SyncId = activePageSyncId,
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
AssertEqual(compactDecoded.Payload.RevisionId, "fcs32:ffffffff", "maximum compact revision")
AssertEqual(compactDecoded.Payload.ContextRevisionId, "fcs32:00000000", "zero compact context revision")

local faithfulSawUnsafeByte = false
local faithfulAddonCodec = MakeFaithfulAddonCodec(function(packed)
    faithfulSawUnsafeByte = packed:find("\000", 1, true) ~= nil or packed:find("\001", 1, true) ~= nil
end)
local faithfulCompact = assert(protocol.EncodeCompactDisplayEnvelope(maximumCompactEnvelope, faithfulAddonCodec))
Assert(not faithfulSawUnsafeByte, "maximum compact display avoids bytes escaped by the addon-channel codec")
AssertEqual(#faithfulCompact, 237, "maximum compact display remains bounded through addon-channel encoding")
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
    protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(ReplaceByte(compactRaw, 1, 2)), compactCodec)
AssertError(compactValue, compactError, "unsupported-compact-display-format", "compact display format mismatch")
compactValue, compactError =
    protocol.DecodeCompactDisplayEnvelope(PackCompactForTest(ReplaceByte(compactRaw, 2, 8)), compactCodec)
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
