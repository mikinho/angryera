local currentTime = 1750000000
local preciseTime = 42.5
local grouped = true
local raid = true
local instanceGroup = false
local currentPlayer = "Viewer-Realm"
local members = {
    ["viewer-realm"] = "leader",
    ["alpha-realm"] = "assistant",
    ["beta-realm"] = "member",
}
local displayRequiresLeader = false
local pageUpsertRequiresLeader = false
local localDisplayAuthority = true
local sentMessages = {}
local printedMessages = {}
local throttleFrames = {}
local throttleAutoDrain = false
local encodedPadding = 0
local encodedLeadingControl = false

_G.AngryAssign_Meta = {
    InstallationId = "ae3i:1:2:3:4",
    NextEntitySequence = 0,
    EntityLocal = {},
    SyncScopes = {},
    Migrations = {},
}
_G.LE_PARTY_CATEGORY_INSTANCE = 1
_G.LE_PARTY_CATEGORY_HOME = 2
_G.time = function()
    return currentTime
end
_G.GetServerTime = function()
    return currentTime
end
_G.GetTimePreciseSec = function()
    return preciseTime
end
_G.IsInRaid = function(category)
    if category == LE_PARTY_CATEGORY_INSTANCE then
        return grouped and raid and instanceGroup
    end
    return grouped and raid
end
_G.IsInGroup = function(category)
    if category == LE_PARTY_CATEGORY_INSTANCE then
        return grouped and instanceGroup
    end
    return grouped
end

local serializedValues = {}
local nextSerializedId = 0
local libS = {}
function libS:Serialize(value)
    nextSerializedId = nextSerializedId + 1
    local token = "serialized-" .. nextSerializedId
    serializedValues[token] = value
    return token
end
function libS:Deserialize(value)
    if serializedValues[value] then
        return true, serializedValues[value]
    end
    return false, "unknown serialization"
end

local compressedValues = {}
local decompressCalls = 0
local libC = {}
function libC:CompressHuffman(value)
    local size = #value
    local compressed = string.char(3, 0, size % 256, math.floor(size / 256) % 256, math.floor(size / 65536) % 256)
        .. "compressed:"
        .. value
    compressedValues[compressed] = value
    return compressed
end
function libC:Decompress(value)
    decompressCalls = decompressCalls + 1
    if value:byte(1) == 1 then
        return value:sub(2)
    end
    return compressedValues[value], "unknown compressed value"
end

local function TestHash(value)
    local first = 1
    local second = 0
    for index = 1, #value do
        first = (first + value:byte(index)) % 65521
        second = (second + first) % 65521
    end
    local code = second * 65536 + first
    local digits = "0123456789abcdef"
    local result = {}
    for index = 8, 1, -1 do
        local digit = code % 16
        result[index] = digits:sub(digit + 1, digit + 1)
        code = math.floor(code / 16)
    end
    return table.concat(result)
end

local libD = {}
function libD:CompressZlib(value)
    local parts = {
        string.char(0x78, 0x01),
    }
    local cursor = 1
    repeat
        local length = math.min(#value - cursor + 1, 65535)
        if length < 0 then
            length = 0
        end
        local final = cursor + length > #value
        local inverseLength = 65535 - length
        parts[#parts + 1] = string.char(
            final and 1 or 0,
            length % 256,
            math.floor(length / 256),
            inverseLength % 256,
            math.floor(inverseLength / 256)
        )
        if length > 0 then
            parts[#parts + 1] = value:sub(cursor, cursor + length - 1)
        end
        cursor = cursor + length
        if final then
            break
        end
    until false

    local first = 1
    local second = 0
    local processed = 0
    for index = 1, #value do
        first = first + value:byte(index)
        second = second + first
        processed = processed + 1
        if processed == 5552 then
            first = first % 65521
            second = second % 65521
            processed = 0
        end
    end
    first = first % 65521
    second = second % 65521
    local checksum = second * 65536 + first
    parts[#parts + 1] = string.char(
        math.floor(checksum / 16777216) % 256,
        math.floor(checksum / 65536) % 256,
        math.floor(checksum / 256) % 256,
        checksum % 256
    )
    return table.concat(parts)
end

function libD:EncodeForWoWAddonChannel(value)
    local prefix = encodedLeadingControl and "\001" or "encoded:"
    return prefix .. value .. string.rep("x", encodedPadding)
end
function libD:DecodeForWoWAddonChannel(value)
    if value:sub(1, 8) == "encoded:" then
        return value:sub(9, #value - encodedPadding)
    elseif value:byte(1) == 1 then
        return value:sub(2, #value - encodedPadding)
    end
end

local helpers = {
    EnsureUnitFullName = function(player)
        if player and not player:find("-", 1, true) then
            return player .. "-Realm"
        end
        return player
    end,
    PlayerFullName = function()
        return currentPlayer
    end,
}

local AngryEra = {
    Title = "Angry Era",
    Version = "3.0.0",
    Timestamp = "20260722120000",
    core = {
        updateFrequency = 2,
        isClassicVanilla = true,
        isClassicTBC = false,
        isClassicWrath = false,
    },
    sync = {
        revisions = {
            CreateFCS32Callback = function(source)
                assert(source == libC, "runtime hashing should bind the loaded LibCompress instance")
                return TestHash
            end,
        },
    },
    utils = {
        helpers = helpers,
    },
}

function AngryEra:GetInstallationId()
    return "ae3i:1:2:3:4"
end

function AngryEra:IsValidRaid()
    return true
end

function AngryEra:GetGroupRole(player)
    local fullName = helpers.EnsureUnitFullName(player)
    return fullName and members[fullName:lower()] or "absent"
end

function AngryEra:CanReceiveFrom(player, action)
    local role = self:GetGroupRole(player)
    if role == "absent" then
        return false
    end
    if action == "version" or action == "request" then
        return true
    end
    if action == "display" and displayRequiresLeader then
        return role == "leader"
    end
    if action == "pageUpsert" and pageUpsertRequiresLeader then
        return role == "leader"
    end
    if action == "changeResult" then
        return role == "leader"
    end
    if action == "changeProposal" then
        return role == "leader" or role == "assistant"
    end
    return (action == "display" or action == "pageUpsert") and (role == "leader" or role == "assistant")
end

function AngryEra:CanLocalPlayerPublish(action)
    if action == "display" then
        return localDisplayAuthority
    elseif action == "changeResult" then
        return localDisplayAuthority
    elseif action == "changeProposal" then
        return true
    end
    return action == "pageUpsert"
end

function AngryEra:IsPlayerRaidLeader()
    return localDisplayAuthority
end

function AngryEra:SendCommMessage(prefix, data, channel, target, priority, callback, callbackArg)
    sentMessages[#sentMessages + 1] = {
        Callback = callback,
        CallbackArg = callbackArg,
        Prefix = prefix,
        Data = data,
        Channel = channel,
        Target = target,
        Priority = priority,
    }
end

function AngryEra:Print(message)
    printedMessages[#printedMessages + 1] = message
end

_G.ChatThrottleLib = {
    SendAddonMessage = function(_, priority, prefix, data, channel, target, queueName, callback, callbackArg)
        local frame = {
            Callback = callback,
            CallbackArg = callbackArg,
            Channel = channel,
            Data = data,
            Prefix = prefix,
            Priority = priority,
            QueueName = queueName,
            Target = target,
        }
        throttleFrames[#throttleFrames + 1] = frame
        if throttleAutoDrain then
            callback(callbackArg, true, 0)
        end
    end,
}

local app = {
    AngryEra = AngryEra,
    libs = {
        libS = libS,
        libC = libC,
        libD = libD,
    },
}

assert(loadfile("modules/debug.lua"))("AngryEra", app)
assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/protocol.lua"))("AngryEra", app)
assert(loadfile("modules/utils/bounded_deflate.lua"))("AngryEra", app)

local protocol = AngryEra.utils.protocol
local compactPageCodec = {
    compress = function(value)
        return libD:CompressZlib(value)
    end,
    decompress = function(value, maximumOutputBytes)
        local output, trailingBytesOrError = AngryEra.utils.boundedDeflate.DecompressZlib(value, maximumOutputBytes)
        if output == nil then
            return nil, trailingBytesOrError
        end
        if trailingBytesOrError ~= 0 then
            return nil, "trailing-compressed-data"
        end
        return output
    end,
    encode = function(value)
        return libD:EncodeForWoWAddonChannel(value)
    end,
    decode = function(value)
        return libD:DecodeForWoWAddonChannel(value)
    end,
    hash = TestHash,
}
function compactPageCodec.EncodeUInt32(value)
    return string.char(
        value % 256,
        math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 16777216) % 256
    )
end

function compactPageCodec.DecodeUInt32(value, index)
    local first, second, third, fourth = value:byte(index, index + 3)
    return first + second * 256 + third * 65536 + fourth * 16777216
end

local localInstallationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:5:6:7:8"
local localReference = {
    SyncId = localInstallationId .. ":page:1",
    Revision = 1,
    RevisionId = "fcs32:11111111",
    ContextRevisionId = "fcs32:22222222",
}
local remoteReference = {
    SyncId = remoteInstallationId .. ":page:1",
    Revision = 1,
    RevisionId = "fcs32:33333333",
    ContextRevisionId = "fcs32:44444444",
}

local function PageUpsert(reference, ownerId, author)
    return {
        Page = {
            Kind = "page",
            SyncId = reference.SyncId,
            OwnerId = ownerId,
            Revision = reference.Revision,
            RevisionId = reference.RevisionId,
            UpdatedAt = currentTime,
            UpdatedBy = author,
            Order = 1,
            Name = "Assignments",
            Vars = "",
            Contents = "Tank: Alpha",
        },
        AncestorVariableLayers = {},
        ContextRevisionId = reference.ContextRevisionId,
    }
end

local localUpsert = PageUpsert(localReference, localInstallationId, currentPlayer)
local remoteUpsert = PageUpsert(remoteReference, remoteInstallationId, "Alpha-Realm")
local activeCalls = {}
local knownActivePages = {}
local pendingActiveDisplay
local activeResetCount = 0
local publicationResetCount = 0
resolvedDisplayDiscoveries = 0
appliedChangeProposals = {}
handledChangeResults = {}
observedCanonicalChanges = {}
changeProposalApplyResult = nil

function AngryEra:ResetActivePageTransientState()
    activeResetCount = activeResetCount + 1
    knownActivePages = {}
    pendingActiveDisplay = nil
end

function AngryEra:ResetDisplayPublicationState()
    publicationResetCount = publicationResetCount + 1
end

function AngryEra:ResolveDisplayDiscovery()
    resolvedDisplayDiscoveries = resolvedDisplayDiscoveries + 1
    return true
end

function AngryEra:GetActivePageRenderContext()
    return nil
end

function AngryEra:GetActiveDisplayReference()
    return nil
end

function AngryEra:ActivatePreparedActiveDisplay() end

function AngryEra:ClearActiveDisplayReference() end

function AngryEra:PrepareActivePageUpsert()
    return localUpsert
end

function AngryEra:BuildActivePageChangeProposal(_, desired)
    return {
        SyncId = remoteReference.SyncId,
        BaseRevision = 1,
        BaseRevisionId = remoteReference.RevisionId,
        BaseContextRevisionId = remoteReference.ContextRevisionId,
        Name = desired.Name,
        Vars = desired.Vars,
        Contents = desired.Contents,
    }
end

function AngryEra:ApplyActivePageChangeProposal(auth, payload)
    appliedChangeProposals[#appliedChangeProposals + 1] = {
        Auth = auth,
        Payload = payload,
    }
    return true, changeProposalApplyResult
end

function AngryEra:HandleSharedPageChangeResult(auth, payload, proposal, messageId)
    handledChangeResults[#handledChangeResults + 1] = {
        Auth = auth,
        Payload = payload,
        Proposal = proposal,
        MessageId = messageId,
    }
    return true, payload.Status
end

function AngryEra:ObserveSharedPageCanonicalUpdate(auth, payload, result)
    observedCanonicalChanges[#observedCanonicalChanges + 1] = {
        Auth = auth,
        Payload = payload,
        Result = result,
    }
    return true
end

function AngryEra:BuildActiveDisplayPayload(pageId)
    if pageId == nil then
        return {
            Displayed = false,
        }
    end
    return {
        Displayed = true,
        SyncId = localReference.SyncId,
        Revision = localReference.Revision,
        RevisionId = localReference.RevisionId,
        ContextRevisionId = localReference.ContextRevisionId,
    },
        localUpsert
end

function AngryEra:BuildActiveDisplayRequestResponse(auth, payload)
    activeCalls[#activeCalls + 1] = {
        Name = "display-request",
        Auth = auth,
        Payload = payload,
    }
    return {
        Type = "DISPLAY",
        Payload = {
            Displayed = true,
            SyncId = localReference.SyncId,
            Revision = localReference.Revision,
            RevisionId = localReference.RevisionId,
            ContextRevisionId = localReference.ContextRevisionId,
        },
        PageUpsertPayload = localUpsert,
    }
end

function AngryEra:BuildActivePageRequestResponse(auth, payload)
    activeCalls[#activeCalls + 1] = {
        Name = "page-request",
        Auth = auth,
        Payload = payload,
    }
    if
        payload.SyncId ~= localReference.SyncId
        or payload.Revision ~= localReference.Revision
        or payload.RevisionId ~= localReference.RevisionId
        or payload.ContextRevisionId ~= localReference.ContextRevisionId
    then
        return nil, "requested-page-unavailable"
    end
    return {
        Type = "PAGE_UPSERT",
        Payload = localUpsert,
    }
end

function AngryEra:AcceptActivePageUpsert(auth, payload, options)
    activeCalls[#activeCalls + 1] = {
        Name = "page-upsert",
        Auth = auth,
        Payload = payload,
        Options = options,
    }
    local reference = {
        SyncId = payload.Page.SyncId,
        Revision = payload.Page.Revision,
        RevisionId = payload.Page.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
    knownActivePages[reference.SyncId] = {
        Revision = reference.Revision,
        RevisionId = reference.RevisionId,
        ContextRevisionId = reference.ContextRevisionId,
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
    }
    local pendingReady = pendingActiveDisplay
        and pendingActiveDisplay.SyncId == reference.SyncId
        and pendingActiveDisplay.Revision == reference.Revision
        and pendingActiveDisplay.RevisionId == reference.RevisionId
        and pendingActiveDisplay.ContextRevisionId == reference.ContextRevisionId
        and pendingActiveDisplay.Sender == auth.Sender
        and pendingActiveDisplay.SenderInstallationId == auth.SenderInstallationId
        and pendingActiveDisplay.SenderSessionId == auth.SenderSessionId
    return true,
        {
            Applied = true,
            PendingDisplayReady = pendingReady == true,
            PendingDisplayPayload = pendingReady and {
                Displayed = true,
                SyncId = reference.SyncId,
                Revision = reference.Revision,
                RevisionId = reference.RevisionId,
                ContextRevisionId = reference.ContextRevisionId,
            } or nil,
        }
end

function AngryEra:AcceptActiveDisplay(auth, payload)
    activeCalls[#activeCalls + 1] = {
        Name = "display",
        Auth = auth,
        Payload = payload,
    }
    if not payload.Displayed then
        pendingActiveDisplay = nil
        return true,
            {
                Applied = true,
                Displayed = false,
                RequestNeeded = false,
            }
    end

    local known = knownActivePages[payload.SyncId]
    if
        known
        and known.Revision == payload.Revision
        and known.RevisionId == payload.RevisionId
        and known.ContextRevisionId == payload.ContextRevisionId
        and known.Sender == auth.Sender
        and known.SenderInstallationId == auth.SenderInstallationId
        and known.SenderSessionId == auth.SenderSessionId
    then
        pendingActiveDisplay = nil
        return true,
            {
                Applied = true,
                Displayed = true,
                RequestNeeded = false,
            }
    end

    pendingActiveDisplay = {
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        SyncId = payload.SyncId,
        Revision = payload.Revision,
        RevisionId = payload.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
    return true,
        {
            Applied = false,
            Displayed = true,
            RequestNeeded = true,
            RequestPayload = {
                SyncId = payload.SyncId,
                Revision = payload.Revision,
                RevisionId = payload.RevisionId,
                ContextRevisionId = payload.ContextRevisionId,
            },
        },
        "ui-refresh-failed"
end

assert(loadfile("modules/protocol_runtime.lua"))("AngryEra", app)

local function AssertError(value, errorCode, expectedError, message)
    assert(value == false or value == nil, message .. " should fail")
    assert(errorCode == expectedError, string.format("%s: expected %s, got %s", message, expectedError, errorCode))
end

local runtimeCodec = AngryEra:GetProtocolCodec()
local storedOutput, storedError = runtimeCodec.decompress("\001stored", 6)
assert(storedOutput == "stored" and storedError == nil, "stored Huffman packets should decode within the output bound")
local callsBeforeOversizedDecode = decompressCalls
local oversizedOutput, oversizedError = runtimeCodec.decompress("\001oversized", 8)
assert(
    oversizedOutput == nil and oversizedError == "output-too-large",
    "stored Huffman packets should be rejected from their declared size"
)
assert(decompressCalls == callsBeforeOversizedDecode, "oversized stored packets must be rejected before decompression")
oversizedOutput, oversizedError = runtimeCodec.decompress(string.char(3, 0, 0, 4, 0) .. "body", 1023)
assert(
    oversizedOutput == nil and oversizedError == "output-too-large",
    "compressed Huffman packets should be rejected from their declared size"
)
assert(
    decompressCalls == callsBeforeOversizedDecode,
    "oversized compressed packets must be rejected before decompression"
)
local malformedOutput, malformedError = runtimeCodec.decompress(string.char(3, 0, 1), 1024)
assert(
    malformedOutput == nil and malformedError == "invalid-compression-header",
    "truncated Huffman headers should be rejected"
)

local function DecodeSent(index)
    local sent = sentMessages[index or #sentMessages]
    assert(sent, "Expected a sent protocol message")
    local envelope
    local decodeError
    local metadata
    if sent.Prefix == protocol.DISPLAY_PREFIX then
        envelope, decodeError = protocol.DecodeCompactDisplayEnvelope(sent.Data, AngryEra:GetProtocolCodec())
    elseif sent.Prefix == protocol.PAGE_PREFIX then
        envelope, decodeError, metadata = protocol.DecodeCompactPageEnvelope(sent.Data, compactPageCodec)
    else
        envelope, decodeError = protocol.DecodeEnvelope(sent.Data, AngryEra:GetProtocolCodec())
    end
    assert(envelope, decodeError)
    return sent, envelope, metadata
end

local function LastActiveCallNamed(name)
    for index = #activeCalls, 1, -1 do
        if activeCalls[index].Name == name then
            return activeCalls[index]
        end
    end
end

local timestampTest = {}
timestampTest.FindPrintedTrace = function(stage, firstIndex)
    for index = firstIndex or 1, #printedMessages do
        if printedMessages[index]:find(stage, 1, true) then
            return printedMessages[index]
        end
    end
end
timestampTest.NextRemoteSentAt = function()
    local candidate = currentTime * 1000 + math.floor(preciseTime * 1000) % 1000
    if timestampTest.RemoteProtocolSentAt and candidate <= timestampTest.RemoteProtocolSentAt then
        candidate = timestampTest.RemoteProtocolSentAt + 1
    end
    timestampTest.RemoteProtocolSentAt = candidate
    return candidate
end

local function BuildRemoteEnvelope(sessionId, messageType, payload, options)
    options = options or {}
    local installationId = options.InstallationId or remoteInstallationId
    local session = assert(protocol.NewSession(installationId, sessionId))
    if options.Sequence then
        session.Sequence = options.Sequence - 1
    end
    local envelope = assert(protocol.BuildEnvelope(session, messageType, payload, {
        ReplyTo = options.ReplyTo,
        SentAt = options.SentAt or timestampTest.NextRemoteSentAt(),
    }))
    local encoded
    local metadata
    if messageType == "DISPLAY" then
        encoded = assert(protocol.EncodeCompactDisplayEnvelope(envelope, AngryEra:GetProtocolCodec()))
    elseif messageType == "PAGE_UPSERT" then
        local encodeError
        encoded, encodeError, metadata = protocol.EncodeCompactPageEnvelope(envelope, compactPageCodec, {
            IncludeAncestorContext = options.IncludeAncestorContext ~= false,
        })
        assert(encoded, encodeError)
    else
        encoded = assert(protocol.EncodeEnvelope(envelope, AngryEra:GetProtocolCodec()))
    end
    return encoded, envelope, metadata
end

local function VersionPayload(capabilities, overrides)
    overrides = overrides or {}
    return {
        AddonVersion = overrides.AddonVersion or "3.2.0",
        BuildTimestamp = overrides.BuildTimestamp or "20260723120000",
        Flavor = overrides.Flavor or "ERA",
        Capabilities = capabilities or {},
        AcceptsCurrentGroup = overrides.AcceptsCurrentGroup ~= false,
    }
end

local sent, sendError = AngryEra:SendProtocolMessage("VERSION_QUERY", {})
AssertError(sent, sendError, "session-not-started", "send before session")

local started, startError = AngryEra:StartProtocolSession("local-session-1")
assert(started and not startError, "A valid protocol session should start")
assert(activeResetCount == 1, "Starting transport should clear session-bound active-page state")
assert(publicationResetCount == 1, "Starting transport should clear session-bound publication state")
local firstSession = AngryEra:GetProtocolSession()
assert(firstSession.InstallationId == localInstallationId, "Session should use the durable installation identity")
assert(firstSession.SessionId == "local-session-1", "Injected session identity should be retained")

do
    sentMessages = {}
    local pageSent, pageResult = AngryEra:SendProtocolPageUpsert(localUpsert)
    assert(pageSent, pageResult)
    local ordinaryPageTransport, ordinaryPageEnvelope = DecodeSent()
    assert(ordinaryPageTransport.Prefix == protocol.PAGE_PREFIX, "ordinary PAGE_UPSERT should use compact-page prefix")
    assert(ordinaryPageTransport.Channel == "RAID", "ordinary PAGE_UPSERT should use the current group channel")
    assert(ordinaryPageTransport.Priority == "NORMAL", "ordinary PAGE_UPSERT should retain normal priority")
    assert(
        ordinaryPageEnvelope.Type == "PAGE_UPSERT"
            and ordinaryPageEnvelope.Payload.Page.SyncId == localReference.SyncId
            and ordinaryPageEnvelope.ReplyTo == nil,
        "ordinary PAGE_UPSERT should round-trip through the compact runtime codec"
    )
    sentMessages = {}
end

members["alpha-realm"] = "leader"
local queryEncoded, remoteQuery = BuildRemoteEnvelope("remote-session-1", "VERSION_QUERY", {})
local accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, queryEncoded, "RAID", "Alpha-Realm")
assert(accepted, result)
assert(#sentMessages == 1, "A valid group query should receive one reply")

local replyTransport, replyEnvelope = DecodeSent()
assert(replyTransport.Prefix == protocol.PREFIX, "V3 messages should use the v3 prefix")
assert(replyTransport.Priority == "NORMAL", "data messages should use normal transport priority")
assert(replyTransport.Channel == "WHISPER", "Version replies should be whispered")
assert(replyTransport.Target == "Alpha-Realm", "Version replies should target the authenticated sender")
assert(replyEnvelope.Type == "VERSION", "A query should produce a VERSION envelope")
assert(replyEnvelope.ReplyTo == remoteQuery.MessageId, "Version reply should correlate to the exact query")
assert(replyEnvelope.Payload.Capabilities.activePage == 1, "Complete active-page handlers should be advertised")
assert(
    replyEnvelope.Payload.Capabilities.activePageChanges == 1,
    "Complete canonical-change handlers should advertise active page changes"
)

accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, queryEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "duplicate", "duplicate query")
assert(#sentMessages == 1, "A duplicate query should not produce another reply")

local rapidQueryEncoded = BuildRemoteEnvelope("remote-session-1", "VERSION_QUERY", {}, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, rapidQueryEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "throttled", "rapid unique query")

local reloadQueryEncoded = BuildRemoteEnvelope("remote-session-reload", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, reloadQueryEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "throttled", "session rotation must not bypass the authenticated-sender throttle")
assert(#sentMessages == 1, "A rotated session must not amplify version replies")

currentTime = currentTime + 2
local laterReloadQueryEncoded = BuildRemoteEnvelope("remote-session-reload-2", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, laterReloadQueryEncoded, "RAID", "Alpha-Realm")
assert(accepted, result)
assert(#sentMessages == 2, "The sender-level throttle should reopen after its interval")
members["alpha-realm"] = "assistant"

local wrongChannelQuery = BuildRemoteEnvelope("remote-session-2", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "PARTY", "Beta-Realm")
AssertError(accepted, result, "invalid-channel", "query over a non-current group channel")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "RAID", "Beta-Realm")
AssertError(accepted, result, "unauthorized", "nonleader version query")
assert(#sentMessages == 2, "a nonleader query must not amplify whispered version traffic")
members["beta-realm"] = "leader"
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "RAID", "Beta-Realm")
assert(accepted, result)
assert(#sentMessages == 3, "A wrong-channel packet must not poison deduplication")
members["beta-realm"] = "member"

accepted, result = AngryEra:ReceiveProtocolMessage("WrongPrefix", wrongChannelQuery, "RAID", "Beta-Realm")
AssertError(accepted, result, "invalid-transport", "wrong prefix")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, wrongChannelQuery, "RAID", "Alpha-Realm")
AssertError(accepted, result, "invalid-compact-display-packing", "non-display envelope over display prefix")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, wrongChannelQuery, "RAID", "Alpha-Realm")
AssertError(accepted, result, "unsupported-compact-page-format", "non-page envelope over compact-page prefix")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, wrongChannelQuery, "RAID", "Alpha-Realm")
AssertError(accepted, result, "unsupported-compact-page-format", "non-page envelope over active-page prefix")
do
    local activePrefixPage, activePrefixEnvelope =
        BuildRemoteEnvelope("remote-active-prefix", "PAGE_UPSERT", remoteUpsert)
    local genericEncodedPage = assert(protocol.EncodeEnvelope(activePrefixEnvelope, runtimeCodec))
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, genericEncodedPage, "RAID", "Alpha-Realm")
    AssertError(
        accepted,
        result,
        "invalid-transport-message-type",
        "generic protocol prefix must reject a decoded PAGE_UPSERT"
    )

    local activePrefixFrame = assert(libD:DecodeForWoWAddonChannel(activePrefixPage))
    local activePrefixRawBytes = compactPageCodec.DecodeUInt32(activePrefixFrame, 2)
    local undersizedActivePrefixFrame = activePrefixFrame:sub(1, 1)
        .. compactPageCodec.EncodeUInt32(activePrefixRawBytes - 1)
        .. activePrefixFrame:sub(6)
    local undersizedActivePrefixPage = libD:EncodeForWoWAddonChannel(undersizedActivePrefixFrame)
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, undersizedActivePrefixPage, "RAID", "Alpha-Realm")
    AssertError(
        accepted,
        result,
        "compact-page-raw-length-mismatch",
        "compact page decompression must enforce the declared output budget"
    )

    local trailingActivePrefixPage = libD:EncodeForWoWAddonChannel(activePrefixFrame .. "\0")
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, trailingActivePrefixPage, "RAID", "Alpha-Realm")
    AssertError(
        accepted,
        result,
        "compact-page-decompress-failed",
        "compact page runtime must reject bytes trailing the zlib stream"
    )

    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, activePrefixPage, "WHISPER", "Alpha-Realm")
    AssertError(
        accepted,
        result,
        "invalid-transport-message-type",
        "active-page prefix outside the current group channel"
    )
    displayRequiresLeader = true
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, activePrefixPage, "RAID", "Alpha-Realm")
    AssertError(accepted, result, "unauthorized", "assistant page over leader-only active-page prefix")
    members["alpha-realm"] = "leader"
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, activePrefixPage, "RAID", "Alpha-Realm")
    assert(accepted, result)
    assert(knownActivePages[remoteReference.SyncId], "active-page prefix should deliver a complete PAGE_UPSERT")
    members["alpha-realm"] = "assistant"
    displayRequiresLeader = false
    knownActivePages = {}
end
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, "malformed", "RAID", "Beta-Realm")
AssertError(accepted, result, "decode-failed", "malformed encoded payload")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, "malformed", "RAID", "Outside-Realm")
AssertError(accepted, result, "unauthorized", "absent sender should be rejected before decode")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "RAID", "Outside-Realm")
AssertError(accepted, result, "unauthorized", "sender outside current group")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "RAID", currentPlayer)
AssertError(accepted, result, "invalid-sender", "self message")

currentTime = currentTime + 2
sent, result = AngryEra:SendProtocolVersionQuery(true)
assert(sent, result)
local queryMessageId = result
local queryTransport, localQueryEnvelope = DecodeSent()
assert(queryTransport.Channel == "RAID", "A raid query should broadcast to RAID")
assert(queryTransport.Priority == "ALERT", "leader discovery control should bypass queued page data")
assert(localQueryEnvelope.Type == "VERSION_QUERY", "Discovery should send VERSION_QUERY")

local versionEncoded = BuildRemoteEnvelope(
    "remote-session-3",
    "VERSION",
    VersionPayload({
        activePage = 1,
        activePageChanges = 1,
    }),
    {
        ReplyTo = queryMessageId,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, versionEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "invalid-channel", "version over group channel")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, versionEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)

local peer = AngryEra:GetProtocolPeer("alpha")
assert(peer and peer.Sender == "Alpha-Realm", "Peers should be keyed by normalized authenticated sender")
assert(peer.SenderInstallationId == remoteInstallationId, "Peer should retain envelope installation metadata")
assert(peer.SenderSessionId == "remote-session-3", "Peer should retain envelope session metadata")
assert(peer.Capabilities.activePage == 1, "Peer capability metadata should be copied")
assert(AngryEra:PeerSupports("Alpha-Realm", "activePage"), "Live mutual capability should negotiate")
assert(
    AngryEra:PeerSupports("Alpha-Realm", "activePageChanges"),
    "Mutual canonical-change capability should negotiate"
)

do
localDisplayAuthority = false
members["viewer-realm"] = "assistant"
members["alpha-realm"] = "leader"
sentMessages = {}
local bootstrapSent, bootstrapRequestId = AngryEra:SendProtocolDisplayRequest("Alpha-Realm")
assert(bootstrapSent, bootstrapRequestId)
local bootstrapDisplay = BuildRemoteEnvelope("remote-session-3", "DISPLAY", {
    Displayed = false,
    ActivePageChanges = true,
}, {
    ReplyTo = bootstrapRequestId,
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, bootstrapDisplay, "WHISPER", "Alpha-Realm")
assert(accepted, result or "a correlated leader display should bind the follower authority session")
local boundAuthority = AngryEra:GetProtocolDisplayAuthority()
assert(
    boundAuthority
        and boundAuthority.SenderInstallationId == remoteInstallationId
        and boundAuthority.SenderSessionId == "remote-session-3",
    "the follower should bind the exact correlated leader installation/session"
)

local assistantProposalPayload = {
    SyncId = remoteReference.SyncId,
    BaseRevision = 1,
    BaseRevisionId = remoteReference.RevisionId,
    BaseContextRevisionId = remoteReference.ContextRevisionId,
    Name = "Assignments",
    Vars = "",
    Contents = "Tank: Alpha",
    AuthorityInstallationId = remoteInstallationId,
    AuthoritySessionId = "remote-session-3",
}

sentMessages = {}
local proposalSent, proposalMessageId =
    AngryEra:SendProtocolChangeProposal("Alpha-Realm", assistantProposalPayload)
assert(proposalSent, proposalMessageId)
local proposalTransport, proposalEnvelope = DecodeSent()
assert(proposalTransport.Prefix == protocol.PREFIX, "CHANGE_PROPOSE should use the compressed data prefix")
assert(proposalTransport.Channel == "WHISPER", "CHANGE_PROPOSE should whisper to the leader")
assert(proposalTransport.Target == "Alpha-Realm", "CHANGE_PROPOSE should target the current leader")
assert(proposalEnvelope.Type == "CHANGE_PROPOSE" and proposalEnvelope.ReplyTo == nil, "proposal is uncorrelated")

local wrongSessionChangeResult = BuildRemoteEnvelope("wrong-change-result-session", "CHANGE_RESULT", {
    Status = "unchanged",
    SyncId = remoteReference.SyncId,
    Revision = 1,
    RevisionId = remoteReference.RevisionId,
    ContextRevisionId = remoteReference.ContextRevisionId,
}, {
    ReplyTo = proposalMessageId,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongSessionChangeResult, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "wrong-session change result")

local correlatedChangeResult = BuildRemoteEnvelope("remote-session-3", "CHANGE_RESULT", {
    Status = "unchanged",
    SyncId = remoteReference.SyncId,
    Revision = 1,
    RevisionId = remoteReference.RevisionId,
    ContextRevisionId = remoteReference.ContextRevisionId,
}, {
    ReplyTo = proposalMessageId,
    Sequence = 3,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, correlatedChangeResult, "WHISPER", "Alpha-Realm")
assert(accepted and result == "unchanged", result)
assert(#handledChangeResults == 1, "a correlated current-leader result should complete exactly one proposal")
assert(
    handledChangeResults[1].MessageId == proposalMessageId
        and handledChangeResults[1].Proposal.BaseRevisionId == remoteReference.RevisionId,
    "the result bridge should receive its exact detached proposal"
)
members["alpha-realm"] = "assistant"
members["viewer-realm"] = "leader"
localDisplayAuthority = true

local canonicalProposalPage = {
    Kind = "page",
    SyncId = remoteReference.SyncId,
    OwnerId = remoteInstallationId,
    Revision = 2,
    RevisionId = "fcs32:55555555",
    UpdatedAt = currentTime,
    UpdatedBy = "Alpha-Realm",
    Order = 1,
    Name = "Assignments",
    Vars = "",
    Contents = "Tank: Canonical",
}
local canonicalProposalUpsert = {
    Page = canonicalProposalPage,
    AncestorVariableLayers = {},
    ContextRevisionId = remoteReference.ContextRevisionId,
}
changeProposalApplyResult = {
    Status = "applied",
    Applied = true,
    LocalId = 1,
    SyncId = canonicalProposalPage.SyncId,
    Revision = canonicalProposalPage.Revision,
    RevisionId = canonicalProposalPage.RevisionId,
    ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
    PageUpsertPayload = canonicalProposalUpsert,
}
local inboundChangeProposal, inboundChangeProposalEnvelope = BuildRemoteEnvelope(
    "assistant-change-proposal",
    "CHANGE_PROPOSE",
    {
        SyncId = assistantProposalPayload.SyncId,
        BaseRevision = assistantProposalPayload.BaseRevision,
        BaseRevisionId = assistantProposalPayload.BaseRevisionId,
        BaseContextRevisionId = assistantProposalPayload.BaseContextRevisionId,
        Name = assistantProposalPayload.Name,
        Vars = assistantProposalPayload.Vars,
        Contents = assistantProposalPayload.Contents,
        AuthorityInstallationId = localInstallationId,
        AuthoritySessionId = "local-session-1",
    }
)
sentMessages = {}
throttleFrames = {}
throttleAutoDrain = false
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, inboundChangeProposal, "RAID", "Alpha-Realm")
AssertError(accepted, result, "invalid-channel", "group change proposal")
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, inboundChangeProposal, "WHISPER", "Alpha-Realm")
assert(accepted and result.Status == "applied", result)
assert(#appliedChangeProposals == 1, "the leader should serialize one authorized proposal")
assert(#sentMessages == 1, "an applied proposal should publish DISPLAY before its page finishes")
local _, proposalDisplayEnvelope = DecodeSent(1)
assert(
    proposalDisplayEnvelope.Type == "DISPLAY"
        and proposalDisplayEnvelope.Payload.RevisionId == canonicalProposalPage.RevisionId
        and proposalDisplayEnvelope.Payload.PageFollows == true,
    "the leader should immediately select the exact canonical proposal tuple"
)
assert(#throttleFrames > 0, "the canonical proposal PAGE_UPSERT should use the replaceable active-page lane")

local secondInboundChangeProposal, secondInboundChangeProposalEnvelope = BuildRemoteEnvelope(
    "assistant-change-proposal",
    "CHANGE_PROPOSE",
    {
        SyncId = assistantProposalPayload.SyncId,
        BaseRevision = assistantProposalPayload.BaseRevision,
        BaseRevisionId = assistantProposalPayload.BaseRevisionId,
        BaseContextRevisionId = assistantProposalPayload.BaseContextRevisionId,
        Name = assistantProposalPayload.Name,
        Vars = assistantProposalPayload.Vars,
        Contents = assistantProposalPayload.Contents,
        AuthorityInstallationId = localInstallationId,
        AuthoritySessionId = "local-session-1",
    },
    {
        Sequence = 2,
    }
)
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, secondInboundChangeProposal, "WHISPER", "Alpha-Realm")
assert(accepted and result.Status == "applied", result)
assert(
    #appliedChangeProposals == 2
        and #sentMessages == 1
        and #throttleFrames == 1
        and #throttleFrames[1].CallbackArg.Transfer.Waiters == 2,
    "identical proposals should reuse one control and one unfinished canonical page stream"
)
local proposalTransfer = throttleFrames[1].CallbackArg.Transfer
local proposalFrameIndex = 1
while not proposalTransfer.Finished do
    local frame = assert(throttleFrames[proposalFrameIndex], "the shared proposal page should drain in order")
    frame.Callback(frame.CallbackArg, true, 0)
    proposalFrameIndex = proposalFrameIndex + 1
end
assert(#sentMessages == 3, "both applied results should wait for the shared page transfer to succeed")
local proposalResultTransport, proposalResultEnvelope = DecodeSent(2)
local secondProposalResultTransport, secondProposalResultEnvelope = DecodeSent(3)
assert(
    proposalResultTransport.Channel == "WHISPER"
        and proposalResultTransport.Priority == "ALERT"
        and secondProposalResultTransport.Priority == "ALERT",
    "CHANGE_RESULT should return by alert-priority whisper"
)
assert(
    proposalResultEnvelope.Type == "CHANGE_RESULT"
        and proposalResultEnvelope.ReplyTo == inboundChangeProposalEnvelope.MessageId
        and proposalResultEnvelope.Payload.Status == "applied",
    "CHANGE_RESULT should correlate to the accepted proposal"
)
assert(
    secondProposalResultEnvelope.ReplyTo == secondInboundChangeProposalEnvelope.MessageId
        and secondProposalResultEnvelope.Payload.Status == "applied",
    "each coalesced proposer should receive its own correlated result"
)

sentMessages = {}
throttleFrames = {}
changeProposalApplyResult = {
    Status = "applied",
    Applied = true,
    LocalId = 1,
    SyncId = canonicalProposalPage.SyncId,
    Revision = canonicalProposalPage.Revision,
    RevisionId = canonicalProposalPage.RevisionId,
    ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
    PageUpsertPayload = canonicalProposalUpsert,
}
local capacityProposalEnvelopes = {}
for index = 1, 33 do
    local capacityProposal, capacityEnvelope = BuildRemoteEnvelope(
        "assistant-change-proposal",
        "CHANGE_PROPOSE",
        {
            SyncId = assistantProposalPayload.SyncId,
            BaseRevision = assistantProposalPayload.BaseRevision,
            BaseRevisionId = assistantProposalPayload.BaseRevisionId,
            BaseContextRevisionId = assistantProposalPayload.BaseContextRevisionId,
            Name = assistantProposalPayload.Name,
            Vars = assistantProposalPayload.Vars,
            Contents = assistantProposalPayload.Contents,
            AuthorityInstallationId = localInstallationId,
            AuthoritySessionId = "local-session-1",
        },
        {
            Sequence = 100 + index,
        }
    )
    capacityProposalEnvelopes[index] = capacityEnvelope
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PREFIX, capacityProposal, "WHISPER", "Alpha-Realm")
    assert(accepted, result)
end
local capacityTransfer = assert(throttleFrames[1], "capacity proposals should share one healthy stream")
    .CallbackArg.Transfer
local _, capacityUnavailable = DecodeSent(2)
assert(
    #sentMessages == 2
        and #capacityTransfer.Waiters == 32
        and not capacityTransfer.Finished
        and capacityUnavailable.Type == "CHANGE_RESULT"
        and capacityUnavailable.ReplyTo == capacityProposalEnvelopes[33].MessageId
        and capacityUnavailable.Payload.Status == "unavailable",
    "a bounded 33rd waiter should fail alone without canceling the healthy stream"
)
localDisplayAuthority = false
AngryEra:CancelProtocolActivePageTransfer("capacity-test-cleanup")
throttleFrames[1].Callback(throttleFrames[1].CallbackArg, true, 0)
localDisplayAuthority = true

for sequence, status in ipairs({ "conflict", "busy", "unavailable" }) do
    if status == "unavailable" then
        changeProposalApplyResult = {
            Status = status,
            SyncId = canonicalProposalPage.SyncId,
        }
    else
        changeProposalApplyResult = {
            Status = status,
            SyncId = canonicalProposalPage.SyncId,
            Revision = canonicalProposalPage.Revision,
            RevisionId = canonicalProposalPage.RevisionId,
            ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
            PageUpsertPayload = canonicalProposalUpsert,
        }
    end
    sentMessages = {}
    throttleFrames = {}
    local immediateProposal = BuildRemoteEnvelope(
        "assistant-change-proposal",
        "CHANGE_PROPOSE",
        {
            SyncId = assistantProposalPayload.SyncId,
            BaseRevision = assistantProposalPayload.BaseRevision,
            BaseRevisionId = assistantProposalPayload.BaseRevisionId,
            BaseContextRevisionId = assistantProposalPayload.BaseContextRevisionId,
            Name = assistantProposalPayload.Name,
            Vars = assistantProposalPayload.Vars,
            Contents = assistantProposalPayload.Contents,
            AuthorityInstallationId = localInstallationId,
            AuthoritySessionId = "local-session-1",
        },
        {
            Sequence = sequence + 2,
        }
    )
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PREFIX, immediateProposal, "WHISPER", "Alpha-Realm")
    assert(accepted and result.Status == status, result)
    local immediateTransport, immediateResult = DecodeSent()
    assert(
        #sentMessages == 1
            and #throttleFrames == 0
            and immediateTransport.Priority == "ALERT"
            and immediateResult.Type == "CHANGE_RESULT"
            and immediateResult.Payload.Status == status,
        status .. " proposals should return immediately without republishing a canonical page"
    )
end

do
    local savedApplyProposal = AngryEra.ApplyActivePageChangeProposal
    AngryEra.ApplyActivePageChangeProposal = function()
        return false, "stale-base"
    end
    sentMessages = {}
    throttleFrames = {}
    local rejectedProposal, rejectedProposalEnvelope = BuildRemoteEnvelope(
        "assistant-change-proposal",
        "CHANGE_PROPOSE",
        {
            SyncId = assistantProposalPayload.SyncId,
            BaseRevision = assistantProposalPayload.BaseRevision,
            BaseRevisionId = assistantProposalPayload.BaseRevisionId,
            BaseContextRevisionId = assistantProposalPayload.BaseContextRevisionId,
            Name = assistantProposalPayload.Name,
            Vars = assistantProposalPayload.Vars,
            Contents = assistantProposalPayload.Contents,
            AuthorityInstallationId = localInstallationId,
            AuthoritySessionId = "local-session-1",
        },
        {
            Sequence = 20,
        }
    )
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PREFIX, rejectedProposal, "WHISPER", "Alpha-Realm")
    assert(
        accepted and result.Status == "unavailable" and result.Rejection == "stale-base",
        "a semantically rejected correlated proposal should terminate immediately"
    )
    local rejectedTransport, rejectedResult = DecodeSent()
    assert(
        #sentMessages == 1
            and rejectedTransport.Priority == "ALERT"
            and rejectedResult.Type == "CHANGE_RESULT"
            and rejectedResult.ReplyTo == rejectedProposalEnvelope.MessageId
            and rejectedResult.Payload.Status == "unavailable",
        "apply rejection should emit one correlated unavailable result"
    )
    AngryEra.ApplyActivePageChangeProposal = savedApplyProposal

    changeProposalApplyResult = {
        Status = "applied",
        Applied = true,
        LocalId = 1,
        SyncId = canonicalProposalPage.SyncId,
        Revision = canonicalProposalPage.Revision,
        RevisionId = canonicalProposalPage.RevisionId,
        ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
    }
    sentMessages = {}
    throttleFrames = {}
    local missingPageProposal, missingPageProposalEnvelope = BuildRemoteEnvelope(
        "assistant-change-proposal",
        "CHANGE_PROPOSE",
        {
            SyncId = assistantProposalPayload.SyncId,
            BaseRevision = assistantProposalPayload.BaseRevision,
            BaseRevisionId = assistantProposalPayload.BaseRevisionId,
            BaseContextRevisionId = assistantProposalPayload.BaseContextRevisionId,
            Name = assistantProposalPayload.Name,
            Vars = assistantProposalPayload.Vars,
            Contents = assistantProposalPayload.Contents,
            AuthorityInstallationId = localInstallationId,
            AuthoritySessionId = "local-session-1",
        },
        {
            Sequence = 21,
        }
    )
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PREFIX, missingPageProposal, "WHISPER", "Alpha-Realm")
    assert(
        accepted
            and result.Status == "applied"
            and result.PublicationSucceeded == false
            and result.PublicationError == "missing-canonical-page",
        "a missing canonical page should be handled as publication failure"
    )
    local missingTransport, missingResult = DecodeSent()
    assert(
        #sentMessages == 1
            and #throttleFrames == 0
            and missingTransport.Priority == "ALERT"
            and missingResult.ReplyTo == missingPageProposalEnvelope.MessageId
            and missingResult.Payload.Status == "unavailable",
        "pre-stream publication failure should still terminate the proposer"
    )
end

changeProposalApplyResult = {
    Status = "applied",
    Applied = true,
    LocalId = 1,
    SyncId = canonicalProposalPage.SyncId,
    Revision = canonicalProposalPage.Revision,
    RevisionId = canonicalProposalPage.RevisionId,
    ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
    PageUpsertPayload = canonicalProposalUpsert,
}
local savedProposalActiveReference = AngryEra.GetActiveDisplayReference
local proposalActiveReference = {
    SyncId = canonicalProposalPage.SyncId,
    Revision = canonicalProposalPage.Revision,
    RevisionId = canonicalProposalPage.RevisionId,
    ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
}
function AngryEra:GetActiveDisplayReference()
    return proposalActiveReference
end
sentMessages = {}
throttleFrames = {}
for sequence = 6, 7 do
    local failingProposal = BuildRemoteEnvelope(
        "assistant-change-proposal",
        "CHANGE_PROPOSE",
        {
            SyncId = assistantProposalPayload.SyncId,
            BaseRevision = assistantProposalPayload.BaseRevision,
            BaseRevisionId = assistantProposalPayload.BaseRevisionId,
            BaseContextRevisionId = assistantProposalPayload.BaseContextRevisionId,
            Name = assistantProposalPayload.Name,
            Vars = assistantProposalPayload.Vars,
            Contents = assistantProposalPayload.Contents,
            AuthorityInstallationId = localInstallationId,
            AuthoritySessionId = "local-session-1",
        },
        {
            Sequence = sequence,
        }
    )
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PREFIX, failingProposal, "WHISPER", "Alpha-Realm")
    assert(accepted, result)
end
assert(#sentMessages == 1 and #throttleFrames == 1, "failing identical proposals should still share one stream")
throttleFrames[1].Callback(throttleFrames[1].CallbackArg, false, "forced")
local unavailableResults = 0
local recoveryDisplays = 0
for index = 2, #sentMessages do
    local _, sentEnvelope = DecodeSent(index)
    if sentEnvelope.Type == "CHANGE_RESULT" and sentEnvelope.Payload.Status == "unavailable" then
        unavailableResults = unavailableResults + 1
    elseif sentEnvelope.Type == "DISPLAY" and sentEnvelope.Payload.PageFollows ~= true then
        recoveryDisplays = recoveryDisplays + 1
    end
end
assert(
    unavailableResults == 2 and recoveryDisplays == 1,
    "one failed shared stream should notify every proposer and emit only one recovery DISPLAY"
)

local supersedingProposalPage = {
    Kind = "page",
    SyncId = canonicalProposalPage.SyncId,
    OwnerId = canonicalProposalPage.OwnerId,
    Revision = canonicalProposalPage.Revision + 1,
    RevisionId = "fcs32:66666666",
    UpdatedAt = currentTime,
    UpdatedBy = canonicalProposalPage.UpdatedBy,
    Order = canonicalProposalPage.Order,
    Name = canonicalProposalPage.Name,
    Vars = canonicalProposalPage.Vars,
    Contents = "Tank: Newest",
}
local supersedingProposalUpsert = {
    Page = supersedingProposalPage,
    AncestorVariableLayers = {},
    ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
}
sentMessages = {}
throttleFrames = {}
proposalActiveReference = {
    SyncId = canonicalProposalPage.SyncId,
    Revision = canonicalProposalPage.Revision,
    RevisionId = canonicalProposalPage.RevisionId,
    ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
}
changeProposalApplyResult = {
    Status = "applied",
    Applied = true,
    LocalId = 1,
    SyncId = canonicalProposalPage.SyncId,
    Revision = canonicalProposalPage.Revision,
    RevisionId = canonicalProposalPage.RevisionId,
    ContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
    PageUpsertPayload = canonicalProposalUpsert,
}
local supersededProposal, supersededProposalEnvelope = BuildRemoteEnvelope(
    "assistant-change-proposal",
    "CHANGE_PROPOSE",
    {
        SyncId = assistantProposalPayload.SyncId,
        BaseRevision = assistantProposalPayload.BaseRevision,
        BaseRevisionId = assistantProposalPayload.BaseRevisionId,
        BaseContextRevisionId = assistantProposalPayload.BaseContextRevisionId,
        Name = assistantProposalPayload.Name,
        Vars = assistantProposalPayload.Vars,
        Contents = "Tank: Older",
        AuthorityInstallationId = localInstallationId,
        AuthoritySessionId = "local-session-1",
    },
    {
        Sequence = 30,
    }
)
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, supersededProposal, "WHISPER", "Alpha-Realm")
assert(accepted and result.PublicationPending, result)
local supersededFrame = assert(throttleFrames[1], "the older proposal should begin one page stream")

proposalActiveReference = {
    SyncId = supersedingProposalPage.SyncId,
    Revision = supersedingProposalPage.Revision,
    RevisionId = supersedingProposalPage.RevisionId,
    ContextRevisionId = supersedingProposalUpsert.ContextRevisionId,
}
changeProposalApplyResult = {
    Status = "applied",
    Applied = true,
    LocalId = 1,
    SyncId = supersedingProposalPage.SyncId,
    Revision = supersedingProposalPage.Revision,
    RevisionId = supersedingProposalPage.RevisionId,
    ContextRevisionId = supersedingProposalUpsert.ContextRevisionId,
    PageUpsertPayload = supersedingProposalUpsert,
}
local supersedingProposal, supersedingProposalEnvelope = BuildRemoteEnvelope(
    "assistant-change-proposal",
    "CHANGE_PROPOSE",
    {
        SyncId = assistantProposalPayload.SyncId,
        BaseRevision = canonicalProposalPage.Revision,
        BaseRevisionId = canonicalProposalPage.RevisionId,
        BaseContextRevisionId = canonicalProposalUpsert.ContextRevisionId,
        Name = assistantProposalPayload.Name,
        Vars = assistantProposalPayload.Vars,
        Contents = supersedingProposalPage.Contents,
        AuthorityInstallationId = localInstallationId,
        AuthoritySessionId = "local-session-1",
    },
    {
        Sequence = 31,
    }
)
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, supersedingProposal, "WHISPER", "Alpha-Realm")
assert(accepted and result.PublicationPending, result)
assert(
    supersededFrame.CallbackArg.Transfer.Finished
        and supersededFrame.CallbackArg.Transfer.Status == "superseded",
    "a newer canonical tuple should supersede the unfinished older stream"
)
supersededFrame.Callback(supersededFrame.CallbackArg, true, 0)
local supersedingTransfer = assert(throttleFrames[2], "the newest stream should start after the old frame drains")
    .CallbackArg.Transfer
local supersedingFrameIndex = 2
while not supersedingTransfer.Finished do
    local frame = assert(throttleFrames[supersedingFrameIndex], "the newest proposal page should drain in order")
    frame.Callback(frame.CallbackArg, true, 0)
    supersedingFrameIndex = supersedingFrameIndex + 1
end
local supersededUnavailable = 0
local supersedingApplied = 0
local supersededRecovery = 0
for index = 1, #sentMessages do
    local _, sentEnvelope = DecodeSent(index)
    if
        sentEnvelope.Type == "CHANGE_RESULT"
        and sentEnvelope.ReplyTo == supersededProposalEnvelope.MessageId
        and sentEnvelope.Payload.Status == "unavailable"
    then
        supersededUnavailable = supersededUnavailable + 1
    elseif
        sentEnvelope.Type == "CHANGE_RESULT"
        and sentEnvelope.ReplyTo == supersedingProposalEnvelope.MessageId
        and sentEnvelope.Payload.Status == "applied"
    then
        supersedingApplied = supersedingApplied + 1
    elseif sentEnvelope.Type == "DISPLAY" and sentEnvelope.Payload.PageFollows ~= true then
        supersededRecovery = supersededRecovery + 1
    end
end
assert(
    supersededUnavailable == 1 and supersedingApplied == 1 and supersededRecovery == 0,
    "supersession should terminate only the old proposer and publish only the newest success"
)
AngryEra.GetActiveDisplayReference = savedProposalActiveReference

changeProposalApplyResult = nil
sentMessages = {}
members["viewer-realm"] = "leader"
end

local copiedCapabilities = AngryEra:GetPeerCapabilities("Alpha-Realm")
copiedCapabilities.activePage = 99
assert(peer.Capabilities.activePage == 1, "Capability access should not expose mutable peer state")
assert(#printedMessages == 1, "A newer same-flavor build should warn once")

local secondVersionEncoded = BuildRemoteEnvelope("remote-session-4", "VERSION", VersionPayload(), {
    ReplyTo = queryMessageId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, secondVersionEncoded, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "one sender may answer a query only once")

local uncorrelatedEncoded = BuildRemoteEnvelope("remote-session-4", "VERSION", VersionPayload(), {
    ReplyTo = remoteQuery.MessageId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, uncorrelatedEncoded, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "uncorrelated-reply", "unknown reply correlation")

local firstQueryPeer = AngryEra:GetProtocolPeer("Alpha-Realm", queryMessageId)
assert(firstQueryPeer and firstQueryPeer.AddonVersion == "3.2.0", "Exact query lookup should retain its response")
firstQueryPeer.AddonVersion = "mutated"
firstQueryPeer.Capabilities.activePage = 99
firstQueryPeer.NegotiatedCapabilities.activePage = 99
local detachedExactPeer = AngryEra:GetProtocolPeer("Alpha-Realm", queryMessageId)
local detachedLatestPeer = AngryEra:GetProtocolPeer("Alpha-Realm")
assert(detachedExactPeer.AddonVersion == "3.2.0", "Exact query lookups should return detached snapshots")
assert(detachedExactPeer.Capabilities.activePage == 1, "Exact snapshot capability maps should be detached")
assert(detachedExactPeer.NegotiatedCapabilities.activePage == 1, "Negotiated capability maps should be detached")
assert(detachedLatestPeer.AddonVersion == "3.2.0", "Mutating an exact snapshot must not alter latest peer state")
detachedLatestPeer.AddonVersion = "also-mutated"
detachedLatestPeer.Capabilities.activePage = 77
assert(AngryEra:GetProtocolPeer("Alpha-Realm").AddonVersion == "3.2.0", "Latest peer lookups should be detached")
assert(
    AngryEra:GetProtocolPeer("Alpha-Realm", queryMessageId).Capabilities.activePage == 1,
    "Mutating latest peer data must not alter an exact query snapshot"
)

local secondQueryId
sent, secondQueryId = AngryEra:SendProtocolVersionQuery(true)
assert(sent, secondQueryId)
local laterVersionEncoded = BuildRemoteEnvelope(
    "remote-session-later-version",
    "VERSION",
    VersionPayload({}, {
        AddonVersion = "3.3.0",
    }),
    {
        ReplyTo = secondQueryId,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, laterVersionEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)
assert(AngryEra:GetProtocolPeer("Alpha-Realm").AddonVersion == "3.3.0", "One-argument lookup should return latest")
assert(
    AngryEra:GetProtocolPeer("Alpha-Realm", queryMessageId).AddonVersion == "3.2.0",
    "A later query must not overwrite an earlier query response"
)
assert(
    AngryEra:GetProtocolPeer("Alpha-Realm", secondQueryId).AddonVersion == "3.3.0",
    "Exact lookup should return the later query's own response"
)

local olderConcurrentQueryId
local newerConcurrentQueryId
sent, olderConcurrentQueryId = AngryEra:SendProtocolVersionQuery(true)
assert(sent, olderConcurrentQueryId)
sent, newerConcurrentQueryId = AngryEra:SendProtocolVersionQuery(true)
assert(sent, newerConcurrentQueryId)
local newerConcurrentVersion = BuildRemoteEnvelope(
    "remote-session-concurrent-newer",
    "VERSION",
    VersionPayload({}, {
        AddonVersion = "3.5.0",
    }),
    {
        ReplyTo = newerConcurrentQueryId,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, newerConcurrentVersion, "WHISPER", "Alpha-Realm")
assert(accepted, result)
local olderConcurrentVersion = BuildRemoteEnvelope(
    "remote-session-concurrent-older",
    "VERSION",
    VersionPayload({}, {
        AddonVersion = "3.4.0",
    }),
    {
        ReplyTo = olderConcurrentQueryId,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, olderConcurrentVersion, "WHISPER", "Alpha-Realm")
assert(accepted, result)
assert(
    AngryEra:GetProtocolPeer("Alpha-Realm").AddonVersion == "3.5.0",
    "A delayed response to an older query must not replace newer peer state"
)
assert(
    AngryEra:GetProtocolPeer("Alpha-Realm", olderConcurrentQueryId).AddonVersion == "3.4.0",
    "The delayed response should remain available through its exact query"
)
assert(
    AngryEra:GetProtocolPeer("Alpha-Realm", newerConcurrentQueryId).AddonVersion == "3.5.0",
    "The newer exact query snapshot should remain unchanged"
)

local expiringQueryId
sent, expiringQueryId = AngryEra:SendProtocolVersionQuery(true)
assert(sent, expiringQueryId)
currentTime = currentTime + 21
local expiredVersionEncoded = BuildRemoteEnvelope("remote-session-expired", "VERSION", VersionPayload(), {
    ReplyTo = expiringQueryId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, expiredVersionEncoded, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "uncorrelated-reply", "expired version response")
assert(AngryEra:GetProtocolPeer("Beta-Realm", expiringQueryId) == nil, "Expired query lookup should be empty")

local savedActivateDisplay = AngryEra.ActivatePreparedActiveDisplay
AngryEra.ActivatePreparedActiveDisplay = nil
currentTime = currentTime + 2
members["beta-realm"] = "leader"
local incompleteQuery = BuildRemoteEnvelope("remote-session-capability", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, incompleteQuery, "RAID", "Beta-Realm")
assert(accepted, result)
local _, incompleteReply = DecodeSent()
assert(next(incompleteReply.Payload.Capabilities) == nil, "Partial active-page runtimes must not advertise capability")
AngryEra.ActivatePreparedActiveDisplay = savedActivateDisplay

local savedClearDisplayReference = AngryEra.ClearActiveDisplayReference
AngryEra.ClearActiveDisplayReference = nil
currentTime = currentTime + 2
local incompleteClearQuery = BuildRemoteEnvelope("remote-session-clear-capability", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, incompleteClearQuery, "RAID", "Beta-Realm")
assert(accepted, result)
local _, incompleteClearReply = DecodeSent()
assert(next(incompleteClearReply.Payload.Capabilities) == nil, "Display-clear support is required for capability")
AngryEra.ClearActiveDisplayReference = savedClearDisplayReference
members["beta-realm"] = "member"

sentMessages = {}
sent, result = AngryEra:SendProtocolDisplay({
    Displayed = true,
    SyncId = localReference.SyncId,
    Revision = localReference.Revision,
    RevisionId = localReference.RevisionId,
    ContextRevisionId = localReference.ContextRevisionId,
})
assert(sent, result)
local displayMessageId = result
local displayTransport, displayEnvelope = DecodeSent()
assert(displayTransport.Prefix == protocol.DISPLAY_PREFIX, "DISPLAY should use the isolated control prefix")
assert(displayTransport.Priority == "ALERT", "DISPLAY should use alert priority on its isolated prefix")
assert(displayTransport.Channel == "RAID", "Uncorrelated DISPLAY should use the current group channel")
assert(#displayTransport.Data <= 254, "DISPLAY control must fit one escaped-safe AceComm frame")
assert(displayEnvelope.ReplyTo == nil, "Group DISPLAY must not carry correlation")
assert(
    type(displayEnvelope.SentAt) == "number"
        and displayEnvelope.SentAt == math.floor(displayEnvelope.SentAt)
        and displayEnvelope.SentAt >= currentTime * 1000
        and displayEnvelope.SentAt <= 9007199254740991,
    "Protocol sends should carry a safe server-epoch millisecond order stamp"
)
assert(
    AngryAssign_Meta.LastDisplaySentAt == displayEnvelope.SentAt,
    "The latest display timestamp should persist across reloads"
)

local debugOutputBeforeTransport = #printedMessages
AngryEra._syncDebugEnabled = true
timestampTest.SavedPreciseTime = preciseTime
preciseTime = 3000000.125
timestampTest.LargeDebugTimestamp = currentTime * 1000 + 123
AngryEra:SyncDebug("large-clock", "sentAt=%s", tostring(timestampTest.LargeDebugTimestamp))
timestampTest.LargeClockTrace = printedMessages[#printedMessages]
assert(
    timestampTest.LargeClockTrace:find("[sync 3000000125ms]", 1, true)
        and timestampTest.LargeClockTrace:find("sentAt=" .. tostring(timestampTest.LargeDebugTimestamp), 1, true)
        and not timestampTest.LargeClockTrace:find("format-error", 1, true),
    "debug tracing should render large uptime and epoch-millisecond values as strings"
)
preciseTime = timestampTest.SavedPreciseTime

timestampTest.DebugRemoteSentAt = currentTime * 1000 + 123
timestampTest.DebugRemotePage = BuildRemoteEnvelope("debug-large-timestamp", "PAGE_UPSERT", remoteUpsert, {
    SentAt = timestampTest.DebugRemoteSentAt,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, timestampTest.DebugRemotePage, "PARTY", "Alpha-Realm")
AssertError(accepted, result, "invalid-channel", "debug large-timestamp receive")
timestampTest.DebugReceiveTrace = printedMessages[#printedMessages]
assert(
    timestampTest.DebugReceiveTrace:find("rx-decoded", 1, true)
        and timestampTest.DebugReceiveTrace:find("sentAt=" .. tostring(timestampTest.DebugRemoteSentAt), 1, true)
        and timestampTest.DebugReceiveTrace:find("age~=377ms", 1, true)
        and not timestampTest.DebugReceiveTrace:find("format-error", 1, true),
    "receive tracing should render 13-digit timestamps and ages without a format failure"
)

accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, "malformed", "RAID", "Alpha-Realm")
AssertError(accepted, result, "compact-display-decode-failed", "malformed compact display while debugging")
assert(
    printedMessages[#printedMessages]:find("rx%-drop")
        and printedMessages[#printedMessages]:find("reason=compact%-display%-decode%-failed"),
    "debug mode should report sanitized decode failures without logging successful discovery traffic"
)
sent, result = AngryEra:SendProtocolDisplay({
    Displayed = false,
})
assert(sent, result)
local debugTransport = sentMessages[#sentMessages]
local _, debugDisplayEnvelope = DecodeSent()
timestampTest.DebugSubmitTrace = timestampTest.FindPrintedTrace("tx-submit", debugOutputBeforeTransport + 1)
assert(
    timestampTest.DebugSubmitTrace
        and timestampTest.DebugSubmitTrace:find("sentAt=" .. tostring(debugDisplayEnvelope.SentAt), 1, true)
        and not timestampTest.DebugSubmitTrace:find("format-error", 1, true),
    "send tracing should render a 13-digit timestamp without a format failure"
)
assert(
    type(debugTransport.Callback) == "function" and type(debugTransport.CallbackArg) == "table",
    "debug mode should attach an AceComm drain callback"
)
assert(
    debugTransport.CallbackArg.Chunks == 1 and #debugTransport.Data <= 254,
    "debug transport should confirm compact DISPLAY uses one physical frame"
)
debugTransport.Callback(debugTransport.CallbackArg, #debugTransport.Data, #debugTransport.Data, 0)
AngryEra._syncDebugEnabled = false
assert(
    #printedMessages >= debugOutputBeforeTransport + 3
        and printedMessages[#printedMessages]:find("tx%-done")
        and printedMessages[#printedMessages]:find("drain="),
    "debug transport callbacks should report queue start and final drain timing"
)
sentMessages[#sentMessages] = nil

do
    local completions = {}
    local function RecordActiveTransfer(label, succeeded, status, messageId)
        completions[#completions + 1] = {
            Label = label,
            MessageId = messageId,
            Status = status,
            Succeeded = succeeded,
        }
    end

    throttleFrames = {}
    encodedLeadingControl = true
    local debugBeforeActiveTransfer = #printedMessages
    _G.GetFramerate = function()
        return 18
    end
    _G.ChatThrottleLib.avail = -123
    _G.ChatThrottleLib.bChoking = true
    _G.ChatThrottleLib.nBypass = 20
    _G.ChatThrottleLib.nTotalSent = 1000
    _G.ChatThrottleLib.Prio = {
        ALERT = {
            avail = -45,
            ByName = {
                AngryEra3P = {},
                OtherAddon = {},
            },
            nTotalSent = 400,
            Ring = {
                pos = {},
            },
        },
        NORMAL = {
            Blocked = {
                pos = {},
            },
        },
        BULK = {},
    }
    local debugUpsert = PageUpsert(localReference, localInstallationId, currentPlayer)
    debugUpsert.Page.ParentSyncId = localInstallationId .. ":category:1"
    debugUpsert.Page.Vars = "$MT=Alpha"
    debugUpsert.AncestorVariableLayers = {
        {
            SyncId = debugUpsert.Page.ParentSyncId,
            Vars = "$HEAL=Beta",
        },
    }
    AngryEra._syncDebugEnabled = true
    sent, result = AngryEra:SendProtocolActivePageUpsert(debugUpsert, RecordActiveTransfer, "escaped")
    assert(sent, result)
    local activeSubmitTrace = timestampTest.FindPrintedTrace("page-stream-submit", debugBeforeActiveTransfer + 1)
    local expectedActiveSentAt = currentTime * 1000 + math.floor(preciseTime * 1000) % 1000
    assert(
        activeSubmitTrace
            and activeSubmitTrace:find("sentAt=" .. tostring(expectedActiveSentAt), 1, true)
            and activeSubmitTrace:find("contentsBytes=" .. tostring(#debugUpsert.Page.Contents), 1, true)
            and activeSubmitTrace:find("pageVarsBytes=" .. tostring(#debugUpsert.Page.Vars), 1, true)
            and activeSubmitTrace:find(
                "ancestorVarsBytes=" .. tostring(#debugUpsert.AncestorVariableLayers[1].Vars),
                1,
                true
            )
            and activeSubmitTrace:find("layers=1", 1, true)
            and activeSubmitTrace:find("fps=18", 1, true)
            and activeSubmitTrace:find("ctlAvail=-123", 1, true)
            and activeSubmitTrace:find("ctlAlertAvail=-45", 1, true)
            and activeSubmitTrace:find("ctlAlertPipes=2", 1, true)
            and activeSubmitTrace:find("ctlChoking=true", 1, true)
            and activeSubmitTrace:find("ctlQueues=ALERT:ring,NORMAL:blocked", 1, true)
            and not activeSubmitTrace:find("format-error", 1, true),
        "active-page debug should expose safe payload anatomy and detailed throttle congestion"
    )
    assert(
        #throttleFrames == 1 and throttleFrames[1].Data:byte(1) == 4 and throttleFrames[1].Data:byte(2) == 1,
        "a short control-prefixed packet should use AceComm's escape frame"
    )
    local escapedActiveEnvelope =
        assert(protocol.DecodeCompactPageEnvelope(throttleFrames[1].Data:sub(2), compactPageCodec))
    assert(
        escapedActiveEnvelope.Type == "PAGE_UPSERT"
            and escapedActiveEnvelope.Payload.Page.SyncId == debugUpsert.Page.SyncId
            and escapedActiveEnvelope.ReplyTo == nil,
        "escaped proactive frames should carry the compact page wire format"
    )
    local callbackTransfer = throttleFrames[1].CallbackArg.Transfer
    preciseTime = preciseTime + 0.25
    _G.ChatThrottleLib.nTotalSent = 1108
    _G.ChatThrottleLib.Prio.ALERT.nTotalSent = 508
    _G.ChatThrottleLib.nBypass = 27
    throttleFrames[1].Callback(throttleFrames[1].CallbackArg, true, 0)
    local activeDoneTrace = timestampTest.FindPrintedTrace("page-stream-done", debugBeforeActiveTransfer + 1)
    local expectedThroughput = math.floor((callbackTransfer.Bytes * 1000 / 250) + 0.5)
    assert(
        activeDoneTrace
            and activeDoneTrace:find("gapMax=250ms", 1, true)
            and activeDoneTrace:find("bps=" .. tostring(expectedThroughput), 1, true)
            and activeDoneTrace:find("ctlSentDelta=108", 1, true)
            and activeDoneTrace:find("ctlAlertSentDelta=108", 1, true)
            and activeDoneTrace:find("ctlBypassDelta=7", 1, true),
        "active-page completion tracing should summarize throttle deltas, callback stalls, and throughput"
    )
    preciseTime = preciseTime - 0.25
    AngryEra._syncDebugEnabled = false
    _G.GetFramerate = nil
    _G.ChatThrottleLib.avail = nil
    _G.ChatThrottleLib.bChoking = nil
    _G.ChatThrottleLib.nBypass = nil
    _G.ChatThrottleLib.nTotalSent = nil
    _G.ChatThrottleLib.Prio = nil
    for index = debugOutputBeforeTransport + 1, #printedMessages do
        assert(
            not printedMessages[index]:find("format-error", 1, true),
            "large-number debug coverage should not emit a format error"
        )
    end
    assert(
        #completions == 1 and completions[1].Label == "escaped" and completions[1].Succeeded == true,
        "the escaped single-frame transfer should complete"
    )

    throttleFrames = {}
    completions = {}
    encodedLeadingControl = false
    encodedPadding = 700
    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, RecordActiveTransfer, "authority")
    assert(sent, result)
    localDisplayAuthority = false
    throttleFrames[1].Callback(throttleFrames[1].CallbackArg, true, 0)
    localDisplayAuthority = true
    assert(
        #throttleFrames == 1
            and #completions == 1
            and completions[1].Label == "authority"
            and completions[1].Succeeded == false
            and completions[1].Status == "unauthorized",
        "losing display authority should stop the active page after its outstanding frame"
    )

    throttleFrames = {}
    completions = {}
    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, RecordActiveTransfer, "coalesced-first")
    assert(sent, result)
    local coalescedMessageId = result
    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, RecordActiveTransfer, "coalesced-second")
    assert(sent and result == coalescedMessageId, result)
    assert(#throttleFrames == 1 and #completions == 0, "an exact in-flight tuple should reuse its existing stream")
    local coalescedState = throttleFrames[1].CallbackArg.Transfer
    local coalescedFrameIndex = 1
    while not coalescedState.Finished do
        local frame = assert(throttleFrames[coalescedFrameIndex], "the coalesced transfer should continue draining")
        frame.Callback(frame.CallbackArg, true, 0)
        coalescedFrameIndex = coalescedFrameIndex + 1
    end
    assert(
        #completions == 2
            and completions[1].Succeeded
            and completions[2].Succeeded
            and completions[1].MessageId == coalescedMessageId
            and completions[2].MessageId == coalescedMessageId,
        "every coalesced completion waiter should receive the shared transfer result"
    )

    throttleFrames = {}
    local capacityCompletions = 0
    local function CapacityCompleted()
        capacityCompletions = capacityCompletions + 1
    end
    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, CapacityCompleted)
    assert(sent, result)
    for _ = 2, 32 do
        sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, CapacityCompleted)
        assert(sent, result)
    end
    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, CapacityCompleted)
    AssertError(sent, result, "active-page-waiter-capacity", "bounded coalesced completion waiters")
    local capacityFrame = throttleFrames[1]
    AngryEra:CancelProtocolActivePageTransfer("test-capacity")
    assert(capacityCompletions == 32, "canceling a coalesced stream should complete every retained waiter")
    capacityFrame.Callback(capacityFrame.CallbackArg, true, 0)

    local secondUpsert = PageUpsert(localReference, localInstallationId, currentPlayer)
    secondUpsert.Page.Revision = 2
    secondUpsert.Page.RevisionId = "fcs32:22222221"
    local thirdUpsert = PageUpsert(localReference, localInstallationId, currentPlayer)
    thirdUpsert.Page.Revision = 3
    thirdUpsert.Page.RevisionId = "fcs32:33333331"
    local nestedUpsert = PageUpsert(localReference, localInstallationId, currentPlayer)
    nestedUpsert.Page.Revision = 4
    nestedUpsert.Page.RevisionId = "fcs32:44444441"
    local middleUpsert = PageUpsert(localReference, localInstallationId, currentPlayer)
    middleUpsert.Page.Revision = 5
    middleUpsert.Page.RevisionId = "fcs32:55555551"

    throttleFrames = {}
    completions = {}
    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, RecordActiveTransfer, "first")
    assert(sent, result)
    assert(#throttleFrames == 1, "the replaceable active-page sender should enqueue only its first frame")
    assert(
        throttleFrames[1].Prefix == protocol.ACTIVE_PAGE_PREFIX
            and throttleFrames[1].Priority == "ALERT"
            and throttleFrames[1].QueueName == protocol.ACTIVE_PAGE_PREFIX,
        "active-page frames should use their isolated alert lane"
    )
    assert(
        throttleFrames[1].Data:byte(1) == 1 and #throttleFrames[1].Data == 255,
        "a multipart active page should begin with one standard AceComm first frame"
    )

    throttleFrames[1].Callback(throttleFrames[1].CallbackArg, true, 0)
    assert(#throttleFrames == 2, "a successful first frame should enqueue exactly one continuation")
    assert(throttleFrames[2].Data:byte(1) == 2, "the second active-page frame should be a continuation")

    sent, result = AngryEra:SendProtocolActivePageUpsert(secondUpsert, RecordActiveTransfer, "second")
    assert(sent, result)
    assert(
        #completions == 1
            and completions[1].Label == "first"
            and completions[1].Succeeded == false
            and completions[1].Status == "superseded",
        "a newer active page should stop the older transfer"
    )
    assert(
        #throttleFrames == 2,
        "the replacement should wait instead of queuing behind the one outstanding stale frame"
    )

    sent, result = AngryEra:SendProtocolActivePageUpsert(thirdUpsert, RecordActiveTransfer, "third")
    assert(sent, result)
    assert(
        #completions == 2
            and completions[2].Label == "second"
            and completions[2].Succeeded == false
            and completions[2].Status == "superseded",
        "another replacement should discard the waiting middle transfer"
    )
    assert(#throttleFrames == 2, "repeated replacements must not accumulate stale first frames")

    throttleFrames[2].Callback(throttleFrames[2].CallbackArg, true, 0)
    assert(
        #throttleFrames == 3 and throttleFrames[3].Data:byte(1) == 1,
        "the stale callback should release only the newest transfer's first frame"
    )

    local frameIndex = 3
    while #completions < 3 do
        local frame = throttleFrames[frameIndex]
        assert(frame, "replacement active-page transfer should keep producing one frame at a time")
        frame.Callback(frame.CallbackArg, true, 0)
        frameIndex = frameIndex + 1
    end
    assert(
        completions[3].Label == "third" and completions[3].Succeeded == true and completions[3].Status == "sent",
        "the latest active-page transfer should complete normally"
    )
    local latestEncodedParts = {}
    for index = 3, frameIndex - 1 do
        latestEncodedParts[#latestEncodedParts + 1] = throttleFrames[index].Data:sub(2)
    end
    local latestActiveEnvelope =
        assert(protocol.DecodeCompactPageEnvelope(table.concat(latestEncodedParts), compactPageCodec))
    assert(
        latestActiveEnvelope.Type == "PAGE_UPSERT"
            and latestActiveEnvelope.Payload.Page.SyncId == localUpsert.Page.SyncId
            and latestActiveEnvelope.Payload.Page.Revision == thirdUpsert.Page.Revision
            and latestActiveEnvelope.ReplyTo == nil,
        "multipart proactive frames should reassemble to the same compact page codec"
    )

    throttleFrames = {}
    local reentrantCompletions = {}
    local nestedStarted
    local function RecordReentrant(label, succeeded, status)
        reentrantCompletions[#reentrantCompletions + 1] = {
            Label = label,
            Status = status,
            Succeeded = succeeded,
        }
    end
    local function StartNestedOnCancel(_, succeeded, status)
        RecordReentrant("first", succeeded, status)
        if not succeeded and status == "superseded" then
            local nestedResult
            nestedStarted, nestedResult =
                AngryEra:SendProtocolActivePageUpsert(nestedUpsert, RecordReentrant, "nested")
            assert(nestedStarted, nestedResult)
        end
    end

    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, StartNestedOnCancel)
    assert(sent, result)
    local staleFrame = throttleFrames[1]
    sent, result = AngryEra:SendProtocolActivePageUpsert(middleUpsert, RecordReentrant, "middle")
    AssertError(sent, result, "superseded", "a transfer superseded reentrantly by its canceled predecessor")
    assert(
        nestedStarted
            and #reentrantCompletions == 1
            and reentrantCompletions[1].Label == "first"
            and reentrantCompletions[1].Succeeded == false,
        "the cancellation callback should install the nested latest transfer without orphaning it"
    )
    staleFrame.Callback(staleFrame.CallbackArg, true, 0)
    local reentrantFrameIndex = 2
    while #reentrantCompletions < 2 do
        local frame = assert(throttleFrames[reentrantFrameIndex], "the reentrant latest transfer should keep draining")
        frame.Callback(frame.CallbackArg, true, 0)
        reentrantFrameIndex = reentrantFrameIndex + 1
    end
    assert(
        #reentrantCompletions == 2
            and reentrantCompletions[2].Label == "nested"
            and reentrantCompletions[2].Succeeded == true
            and reentrantCompletions[2].Status == "sent",
        "the transfer started by a synchronous cancellation callback must remain the latest and complete"
    )
    encodedPadding = 0
end

do
    local reusePayload = PageUpsert(localReference, localInstallationId, currentPlayer)
    reusePayload.Page.ParentSyncId = localInstallationId .. ":category:7"
    reusePayload.AncestorVariableLayers = {
        {
            SyncId = reusePayload.Page.ParentSyncId,
            Vars = string.rep("$RAID=Alpha Beta Gamma;", 16),
        },
    }
    local replacementPayload = PageUpsert(localReference, localInstallationId, currentPlayer)
    replacementPayload.Page.Revision = 2
    replacementPayload.Page.RevisionId = "fcs32:22222223"
    replacementPayload.Page.ParentSyncId = reusePayload.Page.ParentSyncId
    replacementPayload.AncestorVariableLayers = reusePayload.AncestorVariableLayers
    local completions = {}
    local sentMessageCountBeforeReuse = #sentMessages
    local function Completed(label, succeeded, status)
        completions[#completions + 1] = {
            Label = label,
            Status = status,
            Succeeded = succeeded,
        }
    end
    local function DrainTransfer(firstFrame)
        local transfer = assert(throttleFrames[firstFrame].CallbackArg.Transfer)
        local frameIndex = firstFrame
        while not transfer.Finished do
            local frame = assert(throttleFrames[frameIndex], "active transfer should produce its next frame")
            frame.Callback(frame.CallbackArg, true, 0)
            frameIndex = frameIndex + 1
        end
        return transfer
    end

    AngryEra:ResetProtocolAncestorAnnouncements()
    throttleFrames = {}
    sent, result = AngryEra:SendProtocolActivePageUpsert(reusePayload, Completed, "unconfirmed")
    assert(sent, result)
    local unconfirmedState = throttleFrames[1].CallbackArg.Transfer
    assert(
        unconfirmedState.AncestorContextIncluded == true,
        "the first proactive transfer must carry its complete ancestor context"
    )

    sent, result = AngryEra:SendProtocolActivePageUpsert(replacementPayload, Completed, "full")
    assert(sent, result)
    assert(
        #completions == 1
            and completions[1].Label == "unconfirmed"
            and completions[1].Succeeded == false
            and completions[1].Status == "superseded",
        "a superseded inline transfer must not announce its ancestor context"
    )
    assert(#throttleFrames == 1, "the replacement should wait for the outstanding superseded frame")
    throttleFrames[1].Callback(throttleFrames[1].CallbackArg, true, 0)
    local fullState = DrainTransfer(2)
    assert(
        fullState.AncestorContextIncluded == true,
        "a replacement prepared before final send confirmation must still carry the full context"
    )
    local _, fullDecodeError, fullMetadata = protocol.DecodeCompactPageEnvelope(fullState.Encoded, compactPageCodec)
    assert(
        not fullDecodeError and fullMetadata.AncestorContextIncluded == true,
        "the confirmed baseline should decode inline"
    )

    local omittedStart = #throttleFrames + 1
    sent, result = AngryEra:SendProtocolActivePageUpsert(reusePayload, Completed, "omitted")
    assert(sent, result)
    local omittedState = throttleFrames[omittedStart].CallbackArg.Transfer
    assert(
        omittedState.AncestorContextIncluded == false and omittedState.Bytes < fullState.Bytes,
        string.format(
            "a later proactive transfer should omit an announced ancestor context and be smaller (included=%s full=%d omitted=%d)",
            tostring(omittedState.AncestorContextIncluded),
            fullState.Bytes,
            omittedState.Bytes
        )
    )
    local missingEnvelope, missingError, missingMetadata =
        protocol.DecodeCompactPageEnvelope(omittedState.Encoded, compactPageCodec)
    assert(
        missingEnvelope == nil
            and missingError == "compact-page-ancestor-context-missing"
            and missingMetadata.AncestorContextId == fullMetadata.AncestorContextId,
        "an omitted context should fail closed without the exact announced context"
    )
    local reusedEnvelope, reusedError, reusedMetadata =
        protocol.DecodeCompactPageEnvelope(omittedState.Encoded, compactPageCodec, {
            ResolveAncestorContext = function(installationId, sessionId, contextId)
                assert(installationId == localInstallationId, "reuse should preserve the embedded installation")
                assert(sessionId == "local-session-1", "reuse should preserve the embedded session")
                assert(contextId == fullMetadata.AncestorContextId, "reuse should request the exact context id")
                return reusePayload.AncestorVariableLayers
            end,
        })
    assert(
        reusedEnvelope
            and not reusedError
            and reusedMetadata.AncestorContextIncluded == false
            and reusedEnvelope.Payload.AncestorVariableLayers[1].Vars == reusePayload.AncestorVariableLayers[1].Vars,
        "an exact cache resolver should restore omitted ancestor layers"
    )
    DrainTransfer(omittedStart)

    AngryEra:ResetProtocolAncestorAnnouncements()
    local resetStart = #throttleFrames + 1
    sent, result = AngryEra:SendProtocolActivePageUpsert(reusePayload, Completed, "reset")
    assert(sent, result)
    local resetState = DrainTransfer(resetStart)
    assert(resetState.AncestorContextIncluded == true, "an announcement reset should force the next transfer full")

    sent, result = AngryEra:SendProtocolPageUpsert(reusePayload)
    assert(sent, result)
    local _, _, ordinaryMetadata = DecodeSent()
    assert(ordinaryMetadata.AncestorContextIncluded == true, "ordinary group PAGE_UPSERT must always stay inline")
    sent, result = AngryEra:SendProtocolPageUpsert(reusePayload, {
        Channel = "WHISPER",
        Target = "Alpha-Realm",
        ReplyTo = displayMessageId,
    })
    assert(sent, result)
    local _, correlatedEnvelope, correlatedMetadata = DecodeSent()
    assert(
        correlatedEnvelope.ReplyTo == displayMessageId and correlatedMetadata.AncestorContextIncluded == true,
        "correlated PAGE_UPSERT whispers must always stay inline"
    )
    while #sentMessages > sentMessageCountBeforeReuse do
        sentMessages[#sentMessages] = nil
    end
    throttleFrames = {}
end

timestampTest.TimeBeforeRollback = currentTime
currentTime = currentTime - 1
sent, result = AngryEra:SendProtocolMessage("DISPLAY", {
    Displayed = false,
})
assert(sent, result)
timestampTest.RollbackDisplayEnvelope = select(2, DecodeSent())
assert(
    timestampTest.RollbackDisplayEnvelope.SentAt == debugDisplayEnvelope.SentAt + 1,
    "A backwards clock should advance the display timestamp by one logical tick"
)
sentMessages[#sentMessages] = nil
currentTime = timestampTest.TimeBeforeRollback

currentTime = currentTime + 21
local pageRequestEncoded, pageRequestEnvelope =
    BuildRemoteEnvelope("remote-page-request", "PAGE_REQUEST", localReference, {
        ReplyTo = displayMessageId,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, pageRequestEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)
assert(#sentMessages == 2, "A correlated page request should receive one response")
local pageResponseTransport, pageResponseEnvelope = DecodeSent()
assert(pageResponseTransport.Prefix == protocol.PAGE_PREFIX, "PAGE_UPSERT should use the compact-page prefix")
assert(pageResponseTransport.Priority == "NORMAL", "PAGE_UPSERT should retain normal transport priority")
assert(pageResponseTransport.Channel == "WHISPER", "PAGE_UPSERT response should be whispered")
assert(pageResponseEnvelope.Type == "PAGE_UPSERT", "PAGE_REQUEST should produce PAGE_UPSERT")
assert(pageResponseEnvelope.ReplyTo == pageRequestEnvelope.MessageId, "Page response should correlate to request")

local secondPageRequestEncoded = BuildRemoteEnvelope("remote-page-request-rotated", "PAGE_REQUEST", localReference, {
    ReplyTo = displayMessageId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, secondPageRequestEncoded, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-request", "session rotation must not amplify one sender's page request")

sentMessages = {}
sent, result = AngryEra:SendProtocolDisplay({
    Displayed = true,
    SyncId = localReference.SyncId,
    Revision = localReference.Revision,
    RevisionId = localReference.RevisionId,
    ContextRevisionId = localReference.ContextRevisionId,
})
assert(sent, result)
local failedResponseDisplayId = result
local savedBuildPageResponse = AngryEra.BuildActivePageRequestResponse
local failedBuildCalls = 0
function AngryEra:BuildActivePageRequestResponse()
    failedBuildCalls = failedBuildCalls + 1
    return nil, "requested-page-unavailable"
end

local unavailablePageRequest = BuildRemoteEnvelope("remote-page-request-failure", "PAGE_REQUEST", localReference, {
    ReplyTo = failedResponseDisplayId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, unavailablePageRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "requested-page-unavailable", "first unavailable page request")
local repeatedUnavailablePageRequest =
    BuildRemoteEnvelope("remote-page-request-failure", "PAGE_REQUEST", localReference, {
        ReplyTo = failedResponseDisplayId,
        Sequence = 2,
    })
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, repeatedUnavailablePageRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "throttled", "failed page-response build should still throttle")
assert(failedBuildCalls == 1, "The repeat should be throttled before the expensive response builder")

currentTime = currentTime + 2
local laterUnavailablePageRequest = BuildRemoteEnvelope("remote-page-request-failure", "PAGE_REQUEST", localReference, {
    ReplyTo = failedResponseDisplayId,
    Sequence = 3,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, laterUnavailablePageRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "requested-page-unavailable", "page-response retry after cooldown")
assert(failedBuildCalls == 2, "The response builder should run again after the cooldown")
AngryEra.BuildActivePageRequestResponse = savedBuildPageResponse

sentMessages = {}
local savedBuildDisplayResponse = AngryEra.BuildActiveDisplayRequestResponse
local displayResponseBuildCalls = 0
local displayResponseError
function AngryEra:BuildActiveDisplayRequestResponse(auth, payload)
    displayResponseBuildCalls = displayResponseBuildCalls + 1
    if displayResponseError then
        return nil, displayResponseError
    end
    return savedBuildDisplayResponse(self, auth, payload)
end

localDisplayAuthority = false
local prePromotionDisplayRequest = BuildRemoteEnvelope("transient-display-request", "DISPLAY_REQUEST", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, prePromotionDisplayRequest, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "not-display-authority", "display request before local authority is ready")
assert(#sentMessages == 0, "A pre-promotion display request must not send traffic")
assert(displayResponseBuildCalls == 0, "A non-authority request must stop before response planning")

localDisplayAuthority = true
local postPromotionDisplayRequest = BuildRemoteEnvelope("transient-display-request", "DISPLAY_REQUEST", {}, {
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, postPromotionDisplayRequest, "WHISPER", "Beta-Realm")
assert(accepted, result or "A failed pre-promotion plan must not throttle the post-promotion response")
assert(displayResponseBuildCalls == 1, "Authority recovery should build the display response once")
assert(#sentMessages == 2, "The recovered display response should send its page and display")

local repeatedPostPromotionDisplayRequest = BuildRemoteEnvelope("transient-display-request", "DISPLAY_REQUEST", {}, {
    Sequence = 3,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, repeatedPostPromotionDisplayRequest, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "throttled", "successful recovered display response")
assert(displayResponseBuildCalls == 1, "A successful plan should retain the existing response throttle")
assert(#sentMessages == 2, "The successful-plan throttle must prevent response amplification")

displayResponseError = "display-plan-unavailable"
local failedDisplayRequest = BuildRemoteEnvelope("failed-display-request", "DISPLAY_REQUEST", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, failedDisplayRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "display-plan-unavailable", "failed display response plan")
local repeatedFailedDisplayRequest = BuildRemoteEnvelope("failed-display-request", "DISPLAY_REQUEST", {}, {
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, repeatedFailedDisplayRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "throttled", "immediate failed display response retry")
currentTime = currentTime + 2
local laterFailedDisplayRequest = BuildRemoteEnvelope("failed-display-request", "DISPLAY_REQUEST", {}, {
    Sequence = 3,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, laterFailedDisplayRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "display-plan-unavailable", "failed display response after short retry throttle")
displayResponseError = nil
AngryEra.BuildActiveDisplayRequestResponse = savedBuildDisplayResponse

sentMessages = {}
local displayRequestEncoded, displayRequestEnvelope =
    BuildRemoteEnvelope("remote-display-request", "DISPLAY_REQUEST", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, displayRequestEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "invalid-channel", "DISPLAY_REQUEST over group")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, displayRequestEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)
assert(#sentMessages == 2, "A display response with a page should send upsert then display")
local _, requestedPageEnvelope = DecodeSent(1)
local requestedDisplayTransport, requestedDisplayEnvelope = DecodeSent(2)
assert(requestedPageEnvelope.Type == "PAGE_UPSERT", "Display response should send its page first")
assert(requestedPageEnvelope.ReplyTo == displayRequestEnvelope.MessageId, "Page response should correlate")
assert(
    sentMessages[1].Prefix == protocol.PAGE_PREFIX and sentMessages[1].Priority == "NORMAL",
    "requested page data should use the compact-page data lane"
)
assert(
    requestedDisplayTransport.Prefix == protocol.DISPLAY_PREFIX and requestedDisplayTransport.Priority == "ALERT",
    "requested display control should use the isolated alert lane"
)
assert(requestedDisplayTransport.Channel == "WHISPER", "Requested display should be whispered")
assert(requestedDisplayEnvelope.Type == "DISPLAY", "Display response should end with DISPLAY")
assert(requestedDisplayEnvelope.ReplyTo == displayRequestEnvelope.MessageId, "Display response should correlate")
assert(requestedDisplayEnvelope.Payload.PageFollows == true, "Display response should announce its queued page reply")
local repeatedDisplayRequest = BuildRemoteEnvelope("remote-display-request", "DISPLAY_REQUEST", {}, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, repeatedDisplayRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "throttled", "unique display requests for the same sender and display tuple")
assert(#sentMessages == 2, "A throttled display request must not amplify into another page response")
local reloadedDisplayRequest = BuildRemoteEnvelope("remote-display-request-reloaded", "DISPLAY_REQUEST", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, reloadedDisplayRequest, "WHISPER", "Alpha-Realm")
assert(accepted, result or "a new requester session should not inherit the prior session's throttle")
assert(#sentMessages == 4, "a reloaded requester should receive a fresh page and display response")

local unauthorizedUpsertEncoded = BuildRemoteEnvelope("remote-unauthorized", "PAGE_UPSERT", remoteUpsert)
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, unauthorizedUpsertEncoded, "RAID", "Beta-Realm")
AssertError(accepted, result, "unauthorized", "member page publication")
members["beta-realm"] = "assistant"
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, unauthorizedUpsertEncoded, "RAID", "Beta-Realm")
assert(accepted, result)
members["beta-realm"] = "member"
local lastActiveCall = activeCalls[#activeCalls]
assert(lastActiveCall.Auth.Sender == "Beta-Realm", "Typed auth should preserve the authenticated sender")
assert(lastActiveCall.Auth.SenderInstallationId == remoteInstallationId, "Typed auth should bind installation")
assert(lastActiveCall.Auth.SenderSessionId == "remote-unauthorized", "Typed auth should bind session")
assert(lastActiveCall.Auth.ReceivedAt == currentTime, "Typed auth should use receive time")
assert(lastActiveCall.Options == nil, "Uncorrelated group PAGE_UPSERT should omit correlated-reply options")

knownActivePages = {}
pendingActiveDisplay = nil
local remoteDisplayPayload = {
    Displayed = true,
    SyncId = remoteReference.SyncId,
    Revision = remoteReference.Revision,
    RevisionId = remoteReference.RevisionId,
    ContextRevisionId = remoteReference.ContextRevisionId,
}
local remoteDisplayEncoded, remoteDisplayEnvelope =
    BuildRemoteEnvelope("remote-active-flow", "DISPLAY", remoteDisplayPayload, {
        Sequence = 10,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, remoteDisplayEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "decompress-failed", "compact display envelope over data prefix")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, remoteDisplayEncoded, "RAID", "Alpha-Realm")
assert(accepted, result)
assert(result.RequestNeeded and result.RequestSent, "A missing exact tuple should send PAGE_REQUEST")
assert(result.UIWarning == "ui-refresh-failed", "A committed active result should preserve UI warnings")
local requestTransport, requestEnvelope = DecodeSent()
assert(requestTransport.Channel == "WHISPER", "PAGE_REQUEST should be whispered to the display sender")
assert(requestTransport.Target == "Alpha-Realm", "PAGE_REQUEST should target the authenticated publisher")
assert(requestEnvelope.Type == "PAGE_REQUEST", "Missing page should produce PAGE_REQUEST")
assert(requestEnvelope.ReplyTo == remoteDisplayEnvelope.MessageId, "PAGE_REQUEST should identify triggering DISPLAY")

currentTime = currentTime + 21
local wrongSessionUpsert = BuildRemoteEnvelope("remote-other-session", "PAGE_UPSERT", remoteUpsert, {
    ReplyTo = requestEnvelope.MessageId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, wrongSessionUpsert, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "page response from a different session")

local correlatedUpsertEncoded = BuildRemoteEnvelope("remote-active-flow", "PAGE_UPSERT", remoteUpsert, {
    ReplyTo = requestEnvelope.MessageId,
    Sequence = 11,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, correlatedUpsertEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)
local correlatedPageCall = LastActiveCallNamed("page-upsert")
assert(
    correlatedPageCall.Options and correlatedPageCall.Options.CorrelatedReply == true,
    "Correlated whisper PAGE_UPSERT should identify the reply path"
)
assert(
    result.CompletedDisplay and result.CompletedDisplay.Displayed,
    "Exact page response should complete pending display"
)

accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, remoteDisplayEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "duplicate", "duplicate display")
local staleDisplayEncoded = BuildRemoteEnvelope("remote-active-flow", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 9,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, staleDisplayEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "stale-display", "delayed display replay")

local clearDisplayEncoded = BuildRemoteEnvelope("remote-active-flow", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 12,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, clearDisplayEncoded, "RAID", "Alpha-Realm")
assert(accepted and result.Displayed == false, "A newer display clear should apply")

local deferredRecoveryCalls = 0
local canceledRecoveryCalls = 0
local deferredRecoveryContexts = {}
function AngryEra:DeferPendingDisplayRecovery(auth, envelope, reference, completedAttempts, expedited)
    deferredRecoveryCalls = deferredRecoveryCalls + 1
    deferredRecoveryContexts[#deferredRecoveryContexts + 1] = {
        Auth = auth,
        CompletedAttempts = completedAttempts,
        Envelope = envelope,
        Expedited = expedited,
        Reference = reference,
    }
    return true, "scheduled"
end
function AngryEra:CancelPendingDisplayRecovery()
    canceledRecoveryCalls = canceledRecoveryCalls + 1
    return true
end

sentMessages = {}
knownActivePages = {}
pendingActiveDisplay = nil
local onDemandDisplay = BuildRemoteEnvelope("on-demand-display-flow", "DISPLAY", remoteDisplayPayload)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, onDemandDisplay, "RAID", "Alpha-Realm")
assert(
    accepted and result.RequestNeeded and result.RequestSent and not result.RequestDeferred and result.RecoveryScheduled,
    "a cache miss without a page promise should request immediately and retain a retry watchdog"
)
assert(deferredRecoveryCalls == 1, "an unpromised page should install one bounded retry watchdog")
assert(
    deferredRecoveryContexts[1].CompletedAttempts == 1 and deferredRecoveryContexts[1].Expedited == true,
    "an immediate exact request should seed one attempt and use the single-client watchdog"
)
assert(#sentMessages == 1, "an unpromised cache miss should send one targeted page request")

sentMessages = {}
knownActivePages = {}
pendingActiveDisplay = nil
deferredRecoveryCalls = 0
deferredRecoveryContexts = {}
local newerRemoteReference = {
    SyncId = remoteInstallationId .. ":page:2",
    Revision = 1,
    RevisionId = "fcs32:55555555",
    ContextRevisionId = "fcs32:66666666",
}
local newerRemoteUpsert = PageUpsert(newerRemoteReference, remoteInstallationId, "Alpha-Realm")
local firstRapidDisplay = BuildRemoteEnvelope("rapid-display-flow", "DISPLAY", {
    Displayed = true,
    SyncId = remoteReference.SyncId,
    Revision = remoteReference.Revision,
    RevisionId = remoteReference.RevisionId,
    ContextRevisionId = remoteReference.ContextRevisionId,
    PageFollows = true,
}, {
    Sequence = 20,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, firstRapidDisplay, "RAID", "Alpha-Realm")
assert(
    accepted and result.RequestNeeded and result.RequestDeferred and not result.RequestSent,
    "a promised group page should defer missing-context recovery"
)
local latestRapidDisplay, latestRapidDisplayEnvelope = BuildRemoteEnvelope("rapid-display-flow", "DISPLAY", {
    Displayed = true,
    SyncId = newerRemoteReference.SyncId,
    Revision = newerRemoteReference.Revision,
    RevisionId = newerRemoteReference.RevisionId,
    ContextRevisionId = newerRemoteReference.ContextRevisionId,
    PageFollows = true,
}, {
    Sequence = 21,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, latestRapidDisplay, "RAID", "Alpha-Realm")
assert(accepted and result.RequestDeferred, "a newer rapid display should replace the deferred target")
assert(deferredRecoveryCalls == 2, "each missing rapid display should move the trailing recovery wait")
assert(
    deferredRecoveryContexts[1].Expedited == false and deferredRecoveryContexts[2].Expedited == false,
    "uncorrelated promised group pages should retain the raid-safe recovery grace"
)
assert(
    deferredRecoveryContexts[2].Auth.Sender == "Alpha-Realm"
        and deferredRecoveryContexts[2].Envelope.MessageId == latestRapidDisplayEnvelope.MessageId,
    "deferred recovery should retain the authenticated sender and triggering DISPLAY"
)
assert(
    deferredRecoveryContexts[2].Reference.SyncId == newerRemoteReference.SyncId
        and deferredRecoveryContexts[2].Reference.RevisionId == newerRemoteReference.RevisionId
        and deferredRecoveryContexts[2].Reference.ContextRevisionId == newerRemoteReference.ContextRevisionId,
    "deferred recovery should retain the latest exact page tuple"
)
assert(#sentMessages == 0, "deferred rapid displays should not amplify into immediate page requests")

local delayedFirstPage = BuildRemoteEnvelope("rapid-display-flow", "PAGE_UPSERT", remoteUpsert, {
    Sequence = 22,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, delayedFirstPage, "RAID", "Alpha-Realm")
assert(accepted and not result.CompletedDisplay, "an older page must not complete the newer pending display")
assert(canceledRecoveryCalls == 0, "an irrelevant older page should retain latest-display recovery")
local latestRapidPage = BuildRemoteEnvelope("rapid-display-flow", "PAGE_UPSERT", newerRemoteUpsert, {
    Sequence = 23,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, latestRapidPage, "RAID", "Alpha-Realm")
assert(
    accepted and result.CompletedDisplay and result.CompletedDisplay.Displayed,
    "the latest matching page should complete the rapid display"
)
assert(canceledRecoveryCalls == 1, "resolving the latest pending display should cancel recovery")
AngryEra.DeferPendingDisplayRecovery = nil
AngryEra.CancelPendingDisplayRecovery = nil

sent, result = AngryEra:SendProtocolDisplayRequest("Alpha-Realm")
assert(sent, result)
local localDisplayRequestId = result
local localDisplayRequestTransport, localDisplayRequestEnvelope = DecodeSent()
assert(localDisplayRequestTransport.Channel == "WHISPER", "Display request should be whispered")
assert(localDisplayRequestEnvelope.ReplyTo == nil, "DISPLAY_REQUEST must be uncorrelated")

local requestedRemoteUpsert = BuildRemoteEnvelope("remote-request-response", "PAGE_UPSERT", remoteUpsert, {
    ReplyTo = localDisplayRequestId,
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, requestedRemoteUpsert, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "unauthorized", "wrong response sender")
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, requestedRemoteUpsert, "WHISPER", "Alpha-Realm")
assert(accepted, result)

local requestedRemoteDisplay = BuildRemoteEnvelope("remote-request-response", "DISPLAY", remoteDisplayPayload, {
    ReplyTo = localDisplayRequestId,
    Sequence = 2,
})
discoveriesBeforeRequestedDisplay = resolvedDisplayDiscoveries
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, requestedRemoteDisplay, "WHISPER", "Alpha-Realm")
assert(accepted and not result.RequestNeeded, "Correlated upsert then display should use exact cached tuple")
assert(
    resolvedDisplayDiscoveries == discoveriesBeforeRequestedDisplay + 1,
    "an accepted correlated DISPLAY should resolve its unanswered-request watchdog"
)

do
    sent, result = AngryEra:SendProtocolDisplayRequest("Alpha-Realm")
    assert(sent, result)
    local cacheHitDisplayRequestId = result
    local cacheHitDisplay = BuildRemoteEnvelope("remote-request-response", "DISPLAY", remoteDisplayPayload, {
        ReplyTo = cacheHitDisplayRequestId,
        Sequence = 3,
    })
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, cacheHitDisplay, "WHISPER", "Alpha-Realm")
    assert(accepted and not result.RequestNeeded, "a correlated exact cache hit should apply without awaiting a page")
    local lateCacheHitPage = BuildRemoteEnvelope("remote-request-response", "PAGE_UPSERT", remoteUpsert, {
        ReplyTo = cacheHitDisplayRequestId,
        Sequence = 4,
    })
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, lateCacheHitPage, "WHISPER", "Alpha-Realm")
    AssertError(
        accepted,
        result,
        "uncorrelated-reply",
        "cache-hit display request must not retain page-bootstrap privilege"
    )
end

sentMessages = {}
sent, result = AngryEra:SendProtocolDisplayRequest("Alpha-Realm")
assert(sent, result)
local reorderedDisplayRequestId = result
local reorderedDeferredCalls = 0
local reorderedCancelCalls = 0
function AngryEra:DeferPendingDisplayRecovery(auth, envelope, reference, completedAttempts, expedited)
    reorderedDeferredCalls = reorderedDeferredCalls + 1
    assert(auth.Sender == "Alpha-Realm", "reordered recovery should retain the response sender")
    assert(envelope.ReplyTo == reorderedDisplayRequestId, "reordered recovery should retain request correlation")
    assert(reference.SyncId == remoteReference.SyncId, "reordered recovery should retain the exact tuple")
    assert(completedAttempts == 0 and expedited == true, "a correlated response should use its short watchdog")
    return true, "scheduled"
end
function AngryEra:CancelPendingDisplayRecovery()
    reorderedCancelCalls = reorderedCancelCalls + 1
    return true
end
local reorderedRemoteDisplay = BuildRemoteEnvelope("remote-reordered-response", "DISPLAY", {
    Displayed = true,
    SyncId = remoteReference.SyncId,
    Revision = remoteReference.Revision,
    RevisionId = remoteReference.RevisionId,
    ContextRevisionId = remoteReference.ContextRevisionId,
    PageFollows = true,
}, {
    ReplyTo = reorderedDisplayRequestId,
    Sequence = 1,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, reorderedRemoteDisplay, "WHISPER", "Alpha-Realm")
assert(
    accepted and result.RequestNeeded and result.RequestDeferred,
    "a fast correlated DISPLAY may arrive before its page response"
)
assert(reorderedDeferredCalls == 1, "display-first response should defer recovery for its promised page")
currentTime = currentTime + 21
local reorderedRemotePage = BuildRemoteEnvelope("remote-reordered-response", "PAGE_UPSERT", remoteUpsert, {
    ReplyTo = reorderedDisplayRequestId,
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, reorderedRemotePage, "WHISPER", "Alpha-Realm")
assert(
    accepted and result.CompletedDisplay and result.CompletedDisplay.Displayed,
    "the later correlated page should complete a display-first response"
)
assert(reorderedCancelCalls == 1, "the later matching page should cancel deferred recovery")
local duplicateReorderedPage = BuildRemoteEnvelope("remote-reordered-response", "PAGE_UPSERT", remoteUpsert, {
    ReplyTo = reorderedDisplayRequestId,
    Sequence = 3,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, duplicateReorderedPage, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "completed display-first response")
AngryEra.DeferPendingDisplayRecovery = nil
AngryEra.CancelPendingDisplayRecovery = nil

-- Authorization is re-evaluated for every DISPLAY, so a former leader cannot
-- keep driving either compact page lane after becoming an assistant.
displayRequiresLeader = true
pageUpsertRequiresLeader = true
members["alpha-realm"] = "leader"
members["beta-realm"] = "assistant"
local preHandoffDisplay
preHandoffDisplay, timestampTest.PreHandoffEnvelope = BuildRemoteEnvelope("leader-handoff-alpha", "DISPLAY", {
    Displayed = false,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, preHandoffDisplay, "RAID", "Alpha-Realm")
assert(accepted, result)

members["alpha-realm"] = "assistant"
members["beta-realm"] = "leader"
assert(
    not AngryEra:CanReceiveFrom("Alpha-Realm", "pageUpsert"),
    "canonical PAGE_UPSERT traffic should become unauthorized immediately after demotion"
)
timestampTest.FormerLeaderPage = BuildRemoteEnvelope("leader-handoff-alpha", "PAGE_UPSERT", remoteUpsert, {
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, timestampTest.FormerLeaderPage, "RAID", "Alpha-Realm")
AssertError(accepted, result, "unauthorized", "former leader page over the legacy compact-page prefix")
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, timestampTest.FormerLeaderPage, "RAID", "Alpha-Realm")
AssertError(accepted, result, "unauthorized", "former leader page over the active-page prefix")
local formerLeaderDisplay = BuildRemoteEnvelope("leader-handoff-alpha", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 3,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, formerLeaderDisplay, "RAID", "Alpha-Realm")
AssertError(accepted, result, "unauthorized", "display from a leader demoted to qualified assistant")

local newLeaderDisplay = BuildRemoteEnvelope("leader-handoff-beta", "DISPLAY", {
    Displayed = false,
}, {
    SentAt = timestampTest.PreHandoffEnvelope.SentAt - 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, newLeaderDisplay, "RAID", "Beta-Realm")
assert(accepted, result or "The newly promoted leader should control the display immediately")

displayRequiresLeader = false
pageUpsertRequiresLeader = false
members["alpha-realm"] = "assistant"
members["beta-realm"] = "member"
AngryEra:ResetProtocolPeers()

members["beta-realm"] = "assistant"
currentTime = currentTime + 301
timestampTest.ExpiredDisplayTimestamp = BuildRemoteEnvelope("beta-expired-display-clock", "DISPLAY", {
    Displayed = false,
}, {
    SentAt = (currentTime - 301) * 1000,
})
accepted, result = AngryEra:ReceiveProtocolMessage(
    protocol.DISPLAY_PREFIX,
    timestampTest.ExpiredDisplayTimestamp,
    "RAID",
    "Beta-Realm"
)
AssertError(accepted, result, "invalid-display-timestamp", "expired display timestamp")
timestampTest.FutureDisplayTimestamp = BuildRemoteEnvelope("beta-future-display-clock", "DISPLAY", {
    Displayed = false,
}, {
    SentAt = (currentTime + 11) * 1000,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, timestampTest.FutureDisplayTimestamp, "RAID", "Beta-Realm")
AssertError(accepted, result, "invalid-display-timestamp", "future display timestamp")

local firstDisplaySessionPacket
firstDisplaySessionPacket, timestampTest.FirstDisplaySessionEnvelope =
    BuildRemoteEnvelope("beta-display-session-1", "DISPLAY", {
        Displayed = false,
    })
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, firstDisplaySessionPacket, "RAID", "Beta-Realm")
assert(accepted, result)
local secondDisplaySessionPacket
secondDisplaySessionPacket, timestampTest.SecondDisplaySessionEnvelope =
    BuildRemoteEnvelope("beta-display-session-2", "DISPLAY", {
        Displayed = false,
    })
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, secondDisplaySessionPacket, "RAID", "Beta-Realm")
assert(accepted, result)

timestampTest.QueuedOldDisplaySession = BuildRemoteEnvelope("beta-display-session-queued-old", "DISPLAY", {
    Displayed = false,
}, {
    SentAt = timestampTest.FirstDisplaySessionEnvelope.SentAt,
})
accepted, result = AngryEra:ReceiveProtocolMessage(
    protocol.DISPLAY_PREFIX,
    timestampTest.QueuedOldDisplaySession,
    "RAID",
    "Beta-Realm"
)
AssertError(
    accepted,
    result,
    "stale-display-timestamp",
    "previously unseen queued session older than the active display"
)
assert(
    timestampTest.SecondDisplaySessionEnvelope.SentAt > timestampTest.FirstDisplaySessionEnvelope.SentAt,
    "Remote display fixtures should model strictly ordered millisecond sends"
)

local nondisplayRotatedSession = BuildRemoteEnvelope("beta-nondisplay-session", "PAGE_UPSERT", remoteUpsert)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, nondisplayRotatedSession, "RAID", "Beta-Realm")
assert(accepted, result)
local activeDisplaySessionContinues = BuildRemoteEnvelope("beta-display-session-2", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, activeDisplaySessionContinues, "RAID", "Beta-Realm")
assert(accepted, result or "Non-display traffic from another session must not retire the active display session")

local retiredDisplaySessionPacket = BuildRemoteEnvelope("beta-display-session-1", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, retiredDisplaySessionPacket, "RAID", "Beta-Realm")
AssertError(accepted, result, "stale-display-session", "retired display session")

for index = 3, 64 do
    local rotatedDisplay = BuildRemoteEnvelope("beta-display-session-" .. index, "DISPLAY", {
        Displayed = false,
    })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, rotatedDisplay, "RAID", "Beta-Realm")
    assert(accepted, result)
end
local overflowDisplaySession = BuildRemoteEnvelope("beta-display-session-65", "DISPLAY", {
    Displayed = false,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, overflowDisplaySession, "RAID", "Beta-Realm")
AssertError(accepted, result, "display-session-capacity", "display session rotation capacity")

local lastDisplaySessionContinues = BuildRemoteEnvelope("beta-display-session-64", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, lastDisplaySessionContinues, "RAID", "Beta-Realm")
assert(accepted, result or "Capacity rejection must not poison the active display session")
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, retiredDisplaySessionPacket, "RAID", "Beta-Realm")
AssertError(accepted, result, "stale-display-session", "retired session after replay-cache eviction")
members["beta-realm"] = "member"

local localSessionForCapacity = AngryEra:GetProtocolSession()
assert(localSessionForCapacity.Sequence < 98, "Capacity test requires a controlled sequence boundary")
localSessionForCapacity.Sequence = 98
local chronologicalDisplayIds = {}
timestampTest.PreviousChronologicalSentAt = nil
for index = 1, 10 do
    sent, chronologicalDisplayIds[index] = AngryEra:SendProtocolDisplay({
        Displayed = true,
        SyncId = localReference.SyncId,
        Revision = localReference.Revision,
        RevisionId = localReference.RevisionId,
        ContextRevisionId = localReference.ContextRevisionId,
    })
    assert(sent, chronologicalDisplayIds[index])
    timestampTest.ChronologicalDisplayEnvelope = select(2, DecodeSent())
    if timestampTest.PreviousChronologicalSentAt then
        assert(
            timestampTest.ChronologicalDisplayEnvelope.SentAt == timestampTest.PreviousChronologicalSentAt + 1,
            "Same-millisecond display sends should advance by one logical tick"
        )
    end
    timestampTest.PreviousChronologicalSentAt = timestampTest.ChronologicalDisplayEnvelope.SentAt
end
local evictedChronologicalRequest =
    BuildRemoteEnvelope("remote-chronological-evicted", "PAGE_REQUEST", localReference, {
        ReplyTo = chronologicalDisplayIds[1],
    })
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, evictedChronologicalRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-request", "chronologically oldest outbound display")
local retainedChronologicalRequest =
    BuildRemoteEnvelope("remote-chronological-retained", "PAGE_REQUEST", localReference, {
        ReplyTo = chronologicalDisplayIds[3],
    })
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, retainedChronologicalRequest, "WHISPER", "Alpha-Realm")
assert(accepted, result or "Same-second capacity eviction should retain newer interaction records")

sentMessages = {}
local capacityDisplayId
local capacityTarget
for index = 1, 70 do
    capacityTarget = "Capacity" .. index .. "-Realm"
    sent, capacityDisplayId = AngryEra:SendProtocolDisplay({
        Displayed = true,
        SyncId = localReference.SyncId,
        Revision = localReference.Revision,
        RevisionId = localReference.RevisionId,
        ContextRevisionId = localReference.ContextRevisionId,
    }, {
        Channel = "WHISPER",
        Target = capacityTarget,
        ReplyTo = localDisplayRequestId,
    })
    assert(sent, capacityDisplayId)
end
members[capacityTarget:lower()] = "member"
local capacityPageRequest = BuildRemoteEnvelope("remote-capacity-response", "PAGE_REQUEST", localReference, {
    ReplyTo = capacityDisplayId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, capacityPageRequest, "WHISPER", capacityTarget)
assert(accepted, result)
members[capacityTarget:lower()] = nil

members["alpha-realm"] = "leader"
local beforeResetQuery = BuildRemoteEnvelope("remote-query-before-reset", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, beforeResetQuery, "RAID", "Alpha-Realm")
assert(accepted, result)
local activeResetsBeforePeerReset = activeResetCount
local publicationResetsBeforePeerReset = publicationResetCount
AngryEra:ResetProtocolPeers()
assert(activeResetCount == activeResetsBeforePeerReset + 1, "Group reset should clear prior-group active render state")
assert(
    publicationResetCount == publicationResetsBeforePeerReset + 1,
    "Group reset should clear prior-group publication state"
)
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, requestedRemoteDisplay, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "peer reset should clear transport correlation")
local afterResetQuery = BuildRemoteEnvelope("remote-query-after-reset", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, afterResetQuery, "RAID", "Alpha-Realm")
assert(accepted, result)
members["alpha-realm"] = "assistant"

timestampTest.SentAtBeforeSessionRestart = AngryAssign_Meta.LastDisplaySentAt
started, startError = AngryEra:StartProtocolSession("local-session-2")
assert(started and not startError, "A second enable should create a fresh session")
assert(activeResetCount == activeResetsBeforePeerReset + 2, "A new session should clear active transients")
assert(AngryEra:GetProtocolSession().SessionId == "local-session-2", "A new enable should rotate session identity")
assert(
    AngryEra:GetProtocolSession().InstallationId == firstSession.InstallationId,
    "Installation identity should remain stable across sessions"
)
assert(AngryEra:GetProtocolPeer("Alpha-Realm") == nil, "Starting a new session should clear stale peers")
assert(
    AngryAssign_Meta.LastDisplaySentAt == timestampTest.SentAtBeforeSessionRestart,
    "Starting a new protocol session should retain the monotonic timestamp watermark"
)

sentMessages = {}
sent, result = AngryEra:SendProtocolMessage("DISPLAY", {
    Displayed = false,
})
assert(sent, result)
timestampTest.RestartedSessionEnvelope = select(2, DecodeSent())
assert(
    timestampTest.RestartedSessionEnvelope.SentAt > timestampTest.SentAtBeforeSessionRestart,
    "The first display in a new session should remain newer than the prior session"
)

sentMessages = {}
local chronologicalQueryIds = {}
for index = 1, 34 do
    sent, chronologicalQueryIds[index] = AngryEra:SendProtocolVersionQuery(true)
    assert(sent, chronologicalQueryIds[index])
end
local evictedQueryResponse = BuildRemoteEnvelope("remote-query-capacity-evicted", "VERSION", VersionPayload(), {
    ReplyTo = chronologicalQueryIds[1],
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, evictedQueryResponse, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "chronologically oldest pending query")
local retainedQueryResponse = BuildRemoteEnvelope("remote-query-capacity-retained", "VERSION", VersionPayload(), {
    ReplyTo = chronologicalQueryIds[3],
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, retainedQueryResponse, "WHISPER", "Alpha-Realm")
assert(accepted, result or "Same-second query capacity eviction should retain newer queries")

sentMessages = {}
local pruneQueryId
sent, pruneQueryId = AngryEra:SendProtocolVersionQuery(true)
assert(sent, pruneQueryId)
local pruneVersionEncoded = BuildRemoteEnvelope("remote-session-prune", "VERSION", VersionPayload(), {
    ReplyTo = pruneQueryId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, pruneVersionEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)
assert(AngryEra:GetProtocolPeer("Alpha-Realm"), "Prune setup should discover the peer")

members["alpha-realm"] = "leader"
local beforePruneQuery = BuildRemoteEnvelope("remote-query-before-prune", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, beforePruneQuery, "RAID", "Alpha-Realm")
assert(accepted, result)
members["alpha-realm"] = nil
AngryEra:PruneProtocolPeers()
assert(AngryEra:GetProtocolPeer("Alpha-Realm") == nil, "Roster pruning should remove departed peers")
members["alpha-realm"] = "leader"
local afterPruneQuery = BuildRemoteEnvelope("remote-query-after-prune", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, afterPruneQuery, "RAID", "Alpha-Realm")
assert(accepted, result)
members["alpha-realm"] = "assistant"

sentMessages = {}
instanceGroup = true
sent, result = AngryEra:SendProtocolVersionQuery(true)
assert(sent, result)
queryTransport = DecodeSent()
assert(queryTransport.Channel == "INSTANCE_CHAT", "Instance groups should use INSTANCE_CHAT")
instanceGroup = false

grouped = false
sent, result = AngryEra:SendProtocolVersionQuery(true)
AssertError(sent, result, "no-channel", "query while solo")
grouped = true

timestampTest.PersistedSentAtBeforeReload = AngryAssign_Meta.LastDisplaySentAt
assert(loadfile("modules/protocol_runtime.lua"))("AngryEra", app)
started, startError = AngryEra:StartProtocolSession("local-session-after-reload")
assert(started and not startError, "A reloaded runtime should start a fresh protocol session")
sentMessages = {}
sent, result = AngryEra:SendProtocolMessage("DISPLAY", {
    Displayed = false,
})
assert(sent, result)
timestampTest.AfterReloadEnvelope = select(2, DecodeSent())
assert(
    timestampTest.AfterReloadEnvelope.SentAt == timestampTest.PersistedSentAtBeforeReload + 1,
    "A reloaded runtime should continue above its persisted timestamp"
)

AngryAssign_Meta.LastDisplaySentAt = (currentTime + 11) * 1000
assert(loadfile("modules/protocol_runtime.lua"))("AngryEra", app)
started, startError = AngryEra:StartProtocolSession("local-session-after-poisoned-clock")
assert(started and not startError, "A runtime with a poisoned saved clock should still start")
sentMessages = {}
sent, result = AngryEra:SendProtocolMessage("DISPLAY", {
    Displayed = false,
})
assert(sent, result)
timestampTest.RepairedClockEnvelope = select(2, DecodeSent())
assert(
    timestampTest.RepairedClockEnvelope.SentAt == currentTime * 1000 + math.floor(preciseTime * 1000) % 1000,
    "An implausibly future saved timestamp should be ignored and repaired"
)

local codec = AngryEra:GetProtocolCodec()
local inflated, inflationError = codec.decompress("\001" .. string.rep("x", 9), 8)
assert(inflated == nil and inflationError == "output-too-large", "Runtime decompression must enforce its budget")
local badDecoded, badDecodeError = protocol.DecodeEnvelope("encoded:\001unknown", codec)
AssertError(badDecoded, badDecodeError, "deserialize-failed", "AceSerializer failure unwrapping")

local function RunAncestorContextTests()
    do
        AngryEra:ResetProtocolPeers()
        members["alpha-realm"] = "assistant"
        members["beta-realm"] = "assistant"
        local cacheReference = {
            SyncId = remoteInstallationId .. ":page:77",
            Revision = 1,
            RevisionId = "fcs32:77777777",
            ContextRevisionId = "fcs32:88888888",
        }
        local cachePayload = PageUpsert(cacheReference, remoteInstallationId, "Alpha-Realm")
        cachePayload.Page.ParentSyncId = remoteInstallationId .. ":category:9"
        cachePayload.AncestorVariableLayers = {
            {
                SyncId = cachePayload.Page.ParentSyncId,
                Vars = "$MT=Alpha-Realm\n$HEAL=Beta-Realm",
            },
        }

        local inlinePacket = BuildRemoteEnvelope("ancestor-inbound-session", "PAGE_UPSERT", cachePayload, {
            Sequence = 1,
        })
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, inlinePacket, "RAID", "Alpha-Realm")
        assert(accepted, result or "an accepted inline active page should seed its sender-session context")

        local omittedPacket = BuildRemoteEnvelope("ancestor-inbound-session", "PAGE_UPSERT", cachePayload, {
            IncludeAncestorContext = false,
            Sequence = 2,
        })
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, omittedPacket, "RAID", "Alpha-Realm")
        assert(accepted, result or "the same actual sender and embedded session should reuse its accepted context")

        accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PAGE_PREFIX, omittedPacket, "RAID", "Alpha-Realm")
        AssertError(
            accepted,
            result,
            "invalid-transport-message-type",
            "an ordinary PAGE prefix carrying an omitted context"
        )
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, omittedPacket, "RAID", "Beta-Realm")
        AssertError(
            accepted,
            result,
            "compact-page-ancestor-context-missing",
            "the same embedded identity from a different actual sender"
        )
        local otherSessionPacket = BuildRemoteEnvelope("ancestor-inbound-other-session", "PAGE_UPSERT", cachePayload, {
            IncludeAncestorContext = false,
            Sequence = 1,
        })
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, otherSessionPacket, "RAID", "Alpha-Realm")
        AssertError(
            accepted,
            result,
            "compact-page-ancestor-context-missing",
            "an omitted context from a different embedded session"
        )
        AngryEra:ResetProtocolAncestorAnnouncements()

        local rejectedReference = {
            SyncId = remoteInstallationId .. ":page:78",
            Revision = 1,
            RevisionId = "fcs32:99999999",
            ContextRevisionId = "fcs32:aaaaaaaa",
        }
        local rejectedPayload = PageUpsert(rejectedReference, remoteInstallationId, "Beta-Realm")
        rejectedPayload.Page.ParentSyncId = remoteInstallationId .. ":category:10"
        rejectedPayload.AncestorVariableLayers = {
            {
                SyncId = rejectedPayload.Page.ParentSyncId,
                Vars = "$RANGED=Beta-Realm",
            },
        }
        members["beta-realm"] = "member"
        local rejectedInline = BuildRemoteEnvelope("ancestor-rejected-session", "PAGE_UPSERT", rejectedPayload, {
            Sequence = 1,
        })
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, rejectedInline, "RAID", "Beta-Realm")
        AssertError(accepted, result, "unauthorized", "an inline context from an unauthorized sender")
        members["beta-realm"] = "assistant"
        local rejectedOmitted = BuildRemoteEnvelope("ancestor-rejected-session", "PAGE_UPSERT", rejectedPayload, {
            IncludeAncestorContext = false,
            Sequence = 2,
        })
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, rejectedOmitted, "RAID", "Beta-Realm")
        AssertError(
            accepted,
            result,
            "compact-page-ancestor-context-missing",
            "a rejected inline page must not populate the context cache"
        )

        AngryEra:ResetProtocolPeers()
        local afterResetOmitted = BuildRemoteEnvelope("ancestor-inbound-session", "PAGE_UPSERT", cachePayload, {
            IncludeAncestorContext = false,
            Sequence = 3,
        })
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, afterResetOmitted, "RAID", "Alpha-Realm")
        AssertError(
            accepted,
            result,
            "compact-page-ancestor-context-missing",
            "a transport reset should clear accepted ancestor contexts"
        )
        members["beta-realm"] = "member"
    end

    do
        AngryEra:ResetProtocolPeers()
        local sentCountBeforeRecovery = #sentMessages
        local deferred = {}
        function AngryEra:DeferPendingDisplayRecovery(auth, envelope, reference, completedAttempts, expedited)
            deferred[#deferred + 1] = {
                Attempts = completedAttempts,
                Expedited = expedited,
                MessageId = envelope.MessageId,
                Sender = auth.Sender,
                SyncId = reference.SyncId,
            }
            return true, "scheduled"
        end

        local displayFirstReference = {
            SyncId = remoteInstallationId .. ":page:81",
            Revision = 1,
            RevisionId = "fcs32:bbbbbbbb",
            ContextRevisionId = "fcs32:cccccccc",
        }
        local displayFirstPayload = PageUpsert(displayFirstReference, remoteInstallationId, "Alpha-Realm")
        displayFirstPayload.Page.ParentSyncId = remoteInstallationId .. ":category:11"
        displayFirstPayload.AncestorVariableLayers = {
            {
                SyncId = displayFirstPayload.Page.ParentSyncId,
                Vars = "$MELEE=Alpha-Realm",
            },
        }
        local displayFirst = BuildRemoteEnvelope("ancestor-display-first", "DISPLAY", {
            Displayed = true,
            SyncId = displayFirstReference.SyncId,
            Revision = displayFirstReference.Revision,
            RevisionId = displayFirstReference.RevisionId,
            ContextRevisionId = displayFirstReference.ContextRevisionId,
            PageFollows = true,
        }, {
            Sequence = 1,
        })
        accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, displayFirst, "RAID", "Alpha-Realm")
        assert(accepted and result.RequestDeferred, "a promised display should initially defer exact recovery")
        currentTime = currentTime + 21

        local displayFirstOmitted = BuildRemoteEnvelope("ancestor-display-first", "PAGE_UPSERT", displayFirstPayload, {
            IncludeAncestorContext = false,
            Sequence = 2,
        })
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, displayFirstOmitted, "RAID", "Alpha-Realm")
        AssertError(
            accepted,
            result,
            "compact-page-ancestor-context-missing",
            "a promised page whose ancestor context was missed"
        )
        assert(
            #sentMessages == sentCountBeforeRecovery + 1
                and #deferred == 2
                and deferred[2].Attempts == 1
                and deferred[2].Expedited == true,
            string.format(
                "a display-first context miss should immediately request the exact page and expedite its watchdog (sent=%d baseline=%d deferred=%d attempts=%s expedited=%s)",
                #sentMessages,
                sentCountBeforeRecovery,
                #deferred,
                tostring(deferred[2] and deferred[2].Attempts),
                tostring(deferred[2] and deferred[2].Expedited)
            )
        )
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, displayFirstOmitted, "RAID", "Alpha-Realm")
        AssertError(accepted, result, "compact-page-ancestor-context-missing", "a duplicate display-first context miss")
        assert(
            #sentMessages == sentCountBeforeRecovery + 1 and #deferred == 2,
            "duplicate omitted packets must not amplify exact recovery"
        )

        AngryEra:ResetProtocolPeers()
        deferred = {}
        while #sentMessages > sentCountBeforeRecovery do
            sentMessages[#sentMessages] = nil
        end
        local pageFirstReference = {
            SyncId = remoteInstallationId .. ":page:82",
            Revision = 1,
            RevisionId = "fcs32:dddddddd",
            ContextRevisionId = "fcs32:eeeeeeee",
        }
        local pageFirstPayload = PageUpsert(pageFirstReference, remoteInstallationId, "Alpha-Realm")
        pageFirstPayload.Page.ParentSyncId = remoteInstallationId .. ":category:12"
        pageFirstPayload.AncestorVariableLayers = {
            {
                SyncId = pageFirstPayload.Page.ParentSyncId,
                Vars = "$TANK=Alpha-Realm",
            },
        }
        local pageFirstOmitted = BuildRemoteEnvelope("ancestor-page-first", "PAGE_UPSERT", pageFirstPayload, {
            IncludeAncestorContext = false,
            Sequence = 2,
        })
        for _ = 1, 2 do
            accepted, result =
                AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, pageFirstOmitted, "RAID", "Alpha-Realm")
            AssertError(accepted, result, "compact-page-ancestor-context-missing", "a page-before-display context miss")
        end
        assert(#sentMessages == sentCountBeforeRecovery, "a page-before-display miss should wait for an exact display")

        local pageFirstDisplay = BuildRemoteEnvelope("ancestor-page-first", "DISPLAY", {
            Displayed = true,
            SyncId = pageFirstReference.SyncId,
            Revision = pageFirstReference.Revision,
            RevisionId = pageFirstReference.RevisionId,
            ContextRevisionId = pageFirstReference.ContextRevisionId,
            PageFollows = true,
        }, {
            Sequence = 1,
        })
        accepted, result =
            AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, pageFirstDisplay, "RAID", "Alpha-Realm")
        assert(
            accepted
                and result.RequestNeeded
                and result.RequestSent
                and not result.RequestDeferred
                and result.RecoveryScheduled,
            "an exact page-before-display hint should bypass the normal promise delay"
        )
        assert(
            #sentMessages == sentCountBeforeRecovery + 1
                and #deferred == 1
                and deferred[1].Attempts == 1
                and deferred[1].Expedited == true,
            "deduplicated page-before-display hints should produce one exact request and one watchdog"
        )
        AngryEra.DeferPendingDisplayRecovery = nil
        AngryEra:ResetProtocolPeers()
        while #sentMessages > sentCountBeforeRecovery do
            sentMessages[#sentMessages] = nil
        end
    end

    do
        local rosterPayload = PageUpsert(localReference, localInstallationId, currentPlayer)
        rosterPayload.Page.ParentSyncId = localInstallationId .. ":category:13"
        rosterPayload.AncestorVariableLayers = {
            {
                SyncId = rosterPayload.Page.ParentSyncId,
                Vars = "$ROSTER=Alpha-Realm",
            },
        }
        AngryEra:ResetProtocolAncestorAnnouncements()
        throttleFrames = {}
        throttleAutoDrain = true
        sent, result = AngryEra:SendProtocolActivePageUpsert(rosterPayload)
        assert(sent, result)
        local baselineState = throttleFrames[1].CallbackArg.Transfer
        assert(baselineState.AncestorContextIncluded == true, "roster coverage should begin with an inline context")
        throttleAutoDrain = false
        local omittedStart = #throttleFrames + 1
        sent, result = AngryEra:SendProtocolActivePageUpsert(rosterPayload)
        assert(sent, result)
        local omittedState = throttleFrames[omittedStart].CallbackArg.Transfer
        assert(
            omittedState.AncestorContextIncluded == false and not omittedState.Finished,
            "a confirmed roster baseline should permit omission"
        )
        AngryEra:PruneProtocolPeers()
        assert(not omittedState.Finished, "roster pruning must not cancel the page already in flight")
        local omittedFrameIndex = omittedStart
        while not omittedState.Finished do
            local frame =
                assert(throttleFrames[omittedFrameIndex], "the in-flight page should finish after roster pruning")
            frame.Callback(frame.CallbackArg, true, 0)
            omittedFrameIndex = omittedFrameIndex + 1
        end
        local fullAfterRosterStart = #throttleFrames + 1
        sent, result = AngryEra:SendProtocolActivePageUpsert(rosterPayload)
        assert(sent, result)
        assert(
            throttleFrames[fullAfterRosterStart].CallbackArg.Transfer.AncestorContextIncluded == true,
            "roster pruning should force a full context for newly joined members"
        )
        local fullAfterRosterState = throttleFrames[fullAfterRosterStart].CallbackArg.Transfer
        local fullAfterRosterFrame = fullAfterRosterStart
        while not fullAfterRosterState.Finished do
            local frame = assert(
                throttleFrames[fullAfterRosterFrame],
                "the full post-roster page should finish without stale transfer state"
            )
            frame.Callback(frame.CallbackArg, true, 0)
            fullAfterRosterFrame = fullAfterRosterFrame + 1
        end
        throttleFrames = {}
    end
end

RunAncestorContextTests()

function AngryEra:RunAuthorityTenureTests()
    local installationB = "ae3i:9:10:11:12"

    local function FindSentEnvelope(messageType)
        for index = 1, #sentMessages do
            local _, envelope = DecodeSent(index)
            if envelope.Type == messageType then
                return envelope
            end
        end
    end

    local function RequestAndBind(player, installationId, sessionId, sequence)
        sentMessages = {}
        local requestSent, requestId = self:SendProtocolDisplayRequest(player)
        assert(requestSent, requestId)
        local response = BuildRemoteEnvelope(sessionId, "DISPLAY", {
            Displayed = false,
            ActivePageChanges = true,
        }, {
            InstallationId = installationId,
            ReplyTo = requestId,
            Sequence = sequence or 1,
        })
        local responseAccepted, responseResult =
            self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, response, "WHISPER", player)
        assert(responseAccepted, responseResult)
        return requestId
    end

    localDisplayAuthority = false
    displayRequiresLeader = true
    pageUpsertRequiresLeader = true
    members["viewer-realm"] = "assistant"
    members["alpha-realm"] = "assistant"
    members["beta-realm"] = "leader"
    local sessionStarted, sessionError = self:StartProtocolSession("authority-follower-local")
    assert(sessionStarted, sessionError)

    do
        local recoveryReference = {
            SyncId = installationB .. ":page:91",
            Revision = 1,
            RevisionId = "fcs32:91919191",
            ContextRevisionId = "fcs32:92929292",
        }
        local recoveryPage = PageUpsert(recoveryReference, installationB, "Beta-Realm")
        recoveryPage.Page.ParentSyncId = installationB .. ":category:90"
        recoveryPage.AncestorVariableLayers = {
            {
                SyncId = recoveryPage.Page.ParentSyncId,
                Vars = "$TANK=Beta-Realm",
            },
        }

        local savedSendRequestDisplay = self.SendRequestDisplay
        local recoveryCalls = 0
        function self:SendRequestDisplay()
            recoveryCalls = recoveryCalls + 1
            return self:SendProtocolDisplayRequest("Beta-Realm")
        end

        sentMessages = {}
        local unboundDisplay = BuildRemoteEnvelope("leader-b-unbound", "DISPLAY", {
            Displayed = true,
            SyncId = recoveryReference.SyncId,
            Revision = recoveryReference.Revision,
            RevisionId = recoveryReference.RevisionId,
            ContextRevisionId = recoveryReference.ContextRevisionId,
            PageFollows = true,
            ActivePageChanges = true,
        }, {
            InstallationId = installationB,
            Sequence = 1,
        })
        local unboundAccepted, unboundError =
            self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, unboundDisplay, "RAID", "Beta-Realm")
        AssertError(
            unboundAccepted,
            unboundError,
            "unbound-display-authority",
            "an unbound follower group display"
        )
        local recoveryRequest = assert(
            FindSentEnvelope("DISPLAY_REQUEST"),
            "an unbound leader display should initiate a correlated authority bootstrap"
        )
        assert(recoveryCalls == 1 and #sentMessages == 1, "the rejected display should start one targeted request")

        local omittedRecoveryPage = BuildRemoteEnvelope("leader-b-unbound", "PAGE_UPSERT", recoveryPage, {
            IncludeAncestorContext = false,
            InstallationId = installationB,
            Sequence = 2,
        })
        unboundAccepted, unboundError =
            self:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, omittedRecoveryPage, "RAID", "Beta-Realm")
        AssertError(
            unboundAccepted,
            unboundError,
            "compact-page-ancestor-context-missing",
            "an unbound follower omitted ancestor context"
        )
        assert(
            recoveryCalls == 1 and #sentMessages == 1,
            "the following omitted page should reuse the display-initiated bootstrap"
        )

        local inlineRecoveryPage = BuildRemoteEnvelope("leader-b-unbound", "PAGE_UPSERT", recoveryPage, {
            InstallationId = installationB,
            ReplyTo = recoveryRequest.MessageId,
            Sequence = 3,
        })
        unboundAccepted, unboundError =
            self:ReceiveProtocolMessage(protocol.PAGE_PREFIX, inlineRecoveryPage, "WHISPER", "Beta-Realm")
        assert(unboundAccepted, unboundError)

        local correlatedRecoveryDisplay = BuildRemoteEnvelope("leader-b-unbound", "DISPLAY", {
            Displayed = true,
            SyncId = recoveryReference.SyncId,
            Revision = recoveryReference.Revision,
            RevisionId = recoveryReference.RevisionId,
            ContextRevisionId = recoveryReference.ContextRevisionId,
            PageFollows = true,
            ActivePageChanges = true,
        }, {
            InstallationId = installationB,
            ReplyTo = recoveryRequest.MessageId,
            Sequence = 4,
        })
        unboundAccepted, unboundError =
            self:ReceiveProtocolMessage(
                protocol.DISPLAY_PREFIX,
                correlatedRecoveryDisplay,
                "WHISPER",
                "Beta-Realm"
            )
        assert(unboundAccepted and not unboundError.RequestNeeded, unboundError)
        local recoveredAuthority = self:GetProtocolDisplayAuthority()
        assert(
            recoveredAuthority and recoveredAuthority.SenderSessionId == "leader-b-unbound",
            "the self-contained correlated response should bind the exact leader session"
        )

        self.SendRequestDisplay = savedSendRequestDisplay
        self:ResetProtocolPeers()
    end

    RequestAndBind("Beta-Realm", installationB, "leader-b-1")
    local authority = self:GetProtocolDisplayAuthority()
    assert(
        authority
            and authority.PlayerKey == "beta-realm"
            and authority.SenderInstallationId == installationB
            and authority.SenderSessionId == "leader-b-1",
        "a fresh follower should bind the exact correlated leader session"
    )
    assert(
        self:PeerSupports("Beta-Realm", protocol.ACTIVE_PAGE_CHANGES_CAPABILITY),
        "a correlated DISPLAY should advertise proposal capability without follower version broadcast"
    )

    sentMessages = {}
    local proposalSent, proposalId = self:SendProtocolChangeProposal("Beta-Realm", {
        SyncId = remoteReference.SyncId,
        BaseRevision = remoteReference.Revision,
        BaseRevisionId = remoteReference.RevisionId,
        BaseContextRevisionId = remoteReference.ContextRevisionId,
        Name = "Assignments",
        Vars = "",
        Contents = "Tank: Beta",
        AuthorityInstallationId = installationB,
        AuthoritySessionId = "leader-b-1",
    })
    assert(proposalSent, proposalId)

    sentMessages = {}
    local resetsBeforeReload = publicationResetCount
    local reloadQuery = BuildRemoteEnvelope("leader-b-2", "VERSION_QUERY", {}, {
        InstallationId = installationB,
    })
    local acceptedReload, reloadResult =
        self:ReceiveProtocolMessage(protocol.PREFIX, reloadQuery, "RAID", "Beta-Realm")
    assert(acceptedReload, reloadResult)
    assert(
        publicationResetCount == resetsBeforeReload + 1,
        "a same-leader session change should release transport-side shared draft state immediately"
    )
    local reloadRequest = assert(
        FindSentEnvelope("DISPLAY_REQUEST"),
        "a fresh leader session announcement should trigger a targeted display bootstrap"
    )
    assert(FindSentEnvelope("VERSION"), "the follower should still answer the leader's discovery query")
    assert(self:GetProtocolDisplayAuthority() == nil, "the retired leader session should be unbound during bootstrap")
    local sentBeforePendingBoundary = #sentMessages
    local pendingBoundaryRefreshed, pendingBoundary =
        self:RefreshProtocolLeadershipTenure(nil, true)
    assert(
        pendingBoundaryRefreshed
            and pendingBoundary.PendingDisplayBootstrap
            and self:GetProtocolDisplayAuthority() == nil
            and #sentMessages == sentBeforePendingBoundary,
        "query then leader event should preserve R1 correlation without emitting a replacement request"
    )

    local delayedResult = BuildRemoteEnvelope("leader-b-1", "CHANGE_RESULT", {
        Status = "unchanged",
        SyncId = remoteReference.SyncId,
        Revision = remoteReference.Revision,
        RevisionId = remoteReference.RevisionId,
        ContextRevisionId = remoteReference.ContextRevisionId,
    }, {
        InstallationId = installationB,
        ReplyTo = proposalId,
        Sequence = 2,
    })
    local delayedAccepted, delayedError =
        self:ReceiveProtocolMessage(protocol.PREFIX, delayedResult, "WHISPER", "Beta-Realm")
    AssertError(delayedAccepted, delayedError, "uncorrelated-reply", "retired-session proposal result")

    local delayedBootstrap = BuildRemoteEnvelope("leader-b-1", "DISPLAY", {
        Displayed = false,
        ActivePageChanges = true,
    }, {
        InstallationId = installationB,
        ReplyTo = reloadRequest.MessageId,
        Sequence = 3,
    })
    delayedAccepted, delayedError =
        self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, delayedBootstrap, "WHISPER", "Beta-Realm")
    AssertError(delayedAccepted, delayedError, "uncorrelated-reply", "retired-session bootstrap reply")

    local savedAcceptDisplay = self.AcceptActiveDisplay
    self.AcceptActiveDisplay = function()
        return false, "semantic-display-reject"
    end
    local rejectedBootstrap = BuildRemoteEnvelope("leader-b-2", "DISPLAY", {
        Displayed = false,
        ActivePageChanges = true,
    }, {
        InstallationId = installationB,
        ReplyTo = reloadRequest.MessageId,
        Sequence = 2,
    })
    local rejectedAccepted, rejectedError =
        self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, rejectedBootstrap, "WHISPER", "Beta-Realm")
    AssertError(rejectedAccepted, rejectedError, "semantic-display-reject", "semantically rejected bootstrap")
    assert(
        self:GetProtocolDisplayAuthority() == nil,
        "a correlated packet must not bind authority before semantic dispatch succeeds"
    )
    self.AcceptActiveDisplay = savedAcceptDisplay

    local acceptedBootstrap = BuildRemoteEnvelope("leader-b-2", "DISPLAY", {
        Displayed = false,
        ActivePageChanges = true,
    }, {
        InstallationId = installationB,
        ReplyTo = reloadRequest.MessageId,
        Sequence = 3,
    })
    acceptedReload, reloadResult =
        self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, acceptedBootstrap, "WHISPER", "Beta-Realm")
    assert(acceptedReload, reloadResult)
    authority = self:GetProtocolDisplayAuthority()
    assert(
        authority and authority.SenderSessionId == "leader-b-2",
        "an accepted correlated response should transition the same leader to its fresh session"
    )

    currentTime = currentTime + 2
    sentMessages = {}
    local preEventQuery = BuildRemoteEnvelope("leader-b-3", "VERSION_QUERY", {}, {
        InstallationId = installationB,
    })
    local preEventAccepted, preEventResult =
        self:ReceiveProtocolMessage(protocol.PREFIX, preEventQuery, "RAID", "Beta-Realm")
    assert(preEventAccepted, preEventResult)
    local preEventRequest = assert(
        FindSentEnvelope("DISPLAY_REQUEST"),
        "a query arriving before the roster callback should start one exact bootstrap"
    )
    local preEventReply = BuildRemoteEnvelope("leader-b-3", "DISPLAY", {
        Displayed = false,
        ActivePageChanges = true,
    }, {
        InstallationId = installationB,
        ReplyTo = preEventRequest.MessageId,
        Sequence = 2,
    })
    preEventAccepted, preEventResult =
        self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, preEventReply, "WHISPER", "Beta-Realm")
    assert(preEventAccepted, preEventResult)
    sentMessages = {}
    local refreshedBoundary, boundaryResult = self:RefreshProtocolLeadershipTenure(nil, true)
    assert(
        refreshedBoundary
            and boundaryResult.AlreadyBound
            and boundaryResult.PendingDisplayBootstrap
            and self:GetProtocolDisplayAuthority().SenderSessionId == "leader-b-3"
            and #sentMessages == 0,
        "query then reply then leader event should preserve the already-proven fresh authority without R2"
    )

    members["alpha-realm"] = "leader"
    members["beta-realm"] = "assistant"
    assert(self:RefreshProtocolLeadershipTenure())
    RequestAndBind("Alpha-Realm", remoteInstallationId, "leader-a-1")
    sentMessages = {}
    local oldARequestSent, oldARequestId = self:SendProtocolDisplayRequest("Alpha-Realm")
    assert(oldARequestSent, oldARequestId)

    members["alpha-realm"] = "assistant"
    members["beta-realm"] = "leader"
    assert(self:RefreshProtocolLeadershipTenure())
    RequestAndBind("Beta-Realm", installationB, "leader-b-4")

    members["alpha-realm"] = "leader"
    members["beta-realm"] = "assistant"
    assert(self:RefreshProtocolLeadershipTenure())
    sentMessages = {}
    local newARequestSent, newARequestId = self:SendProtocolDisplayRequest("Alpha-Realm")
    assert(newARequestSent, newARequestId)

    local delayedAReply = BuildRemoteEnvelope("leader-a-1", "DISPLAY", {
        Displayed = false,
        ActivePageChanges = true,
    }, {
        ReplyTo = oldARequestId,
        Sequence = 2,
    })
    delayedAccepted, delayedError =
        self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, delayedAReply, "WHISPER", "Alpha-Realm")
    AssertError(delayedAccepted, delayedError, "uncorrelated-reply", "A1 reply after A to B to A handoff")

    local acceptedA2 = BuildRemoteEnvelope("leader-a-2", "DISPLAY", {
        Displayed = false,
        ActivePageChanges = true,
    }, {
        ReplyTo = newARequestId,
        Sequence = 1,
    })
    local a2Accepted, a2Result =
        self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, acceptedA2, "WHISPER", "Alpha-Realm")
    assert(a2Accepted, a2Result)

    local delayedAGroup = BuildRemoteEnvelope("leader-a-1", "DISPLAY", {
        Displayed = false,
    }, {
        Sequence = 3,
    })
    delayedAccepted, delayedError =
        self:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, delayedAGroup, "RAID", "Alpha-Realm")
    AssertError(delayedAccepted, delayedError, "stale-display-authority", "A1 group packet after A2 binding")
    authority = self:GetProtocolDisplayAuthority()
    assert(
        authority and authority.SenderSessionId == "leader-a-2",
        "the delayed A1 packet must not replace the current A2 authority"
    )

    localDisplayAuthority = true
    members["viewer-realm"] = "leader"
    members["alpha-realm"] = "assistant"
    local promoted, promotion = self:RefreshProtocolLeadershipTenure("local-leader-tenure")
    assert(promoted and promotion.Rotated and promotion.SessionId == "local-leader-tenure", "promotion should rotate tenure")
    local leaderPayload = {
        SyncId = remoteReference.SyncId,
        BaseRevision = remoteReference.Revision,
        BaseRevisionId = remoteReference.RevisionId,
        BaseContextRevisionId = remoteReference.ContextRevisionId,
        Name = "Assignments",
        Vars = "",
        Contents = "Tank: Alpha",
        AuthorityInstallationId = localInstallationId,
        AuthoritySessionId = "local-leader-tenure",
    }
    changeProposalApplyResult = {
        Status = "unavailable",
        SyncId = remoteReference.SyncId,
    }
    local appliedBeforeFreshness = #appliedChangeProposals
    local staleProposal = BuildRemoteEnvelope("assistant-tenure", "CHANGE_PROPOSE", leaderPayload, {
        SentAt = (currentTime - 21) * 1000,
        Sequence = 1,
    })
    local staleAccepted, staleError =
        self:ReceiveProtocolMessage(protocol.PREFIX, staleProposal, "WHISPER", "Alpha-Realm")
    AssertError(staleAccepted, staleError, "stale-change-proposal", "expired change proposal")

    local wrongAuthorityPayload = {}
    for key, value in pairs(leaderPayload) do
        wrongAuthorityPayload[key] = value
    end
    wrongAuthorityPayload.AuthoritySessionId = "retired-local-tenure"
    local wrongAuthorityProposal = BuildRemoteEnvelope("assistant-tenure", "CHANGE_PROPOSE", wrongAuthorityPayload, {
        Sequence = 2,
    })
    local wrongAccepted, wrongError =
        self:ReceiveProtocolMessage(protocol.PREFIX, wrongAuthorityProposal, "WHISPER", "Alpha-Realm")
    assert(
        wrongAccepted and wrongError.Status == "unavailable" and wrongError.Rejection == "stale-change-authority",
        "a proposal for a retired leader tenure should receive a correlated terminal result"
    )
    assert(
        #appliedChangeProposals == appliedBeforeFreshness,
        "stale or wrong-tenure proposals must not reach canonical application"
    )

    sentMessages = {}
    local freshProposal = BuildRemoteEnvelope("assistant-tenure", "CHANGE_PROPOSE", leaderPayload, {
        Sequence = 3,
    })
    local freshAccepted, freshResult =
        self:ReceiveProtocolMessage(protocol.PREFIX, freshProposal, "WHISPER", "Alpha-Realm")
    assert(freshAccepted and freshResult.Status == "unavailable", freshResult)
    assert(
        #appliedChangeProposals == appliedBeforeFreshness + 1,
        "a fresh proposal for the exact active leader tenure should be applied once"
    )

    changeProposalApplyResult = nil
    displayRequiresLeader = false
    pageUpsertRequiresLeader = false
end

AngryEra:RunAuthorityTenureTests()

print("Protocol runtime tests passed.")
