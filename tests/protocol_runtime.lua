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

local libD = {}
function libD:EncodeForWoWAddonChannel(value)
    local prefix = encodedLeadingControl and "\001" or "encoded:"
    return prefix .. value .. string.rep("x", encodedPadding)
end
function libD:DecodeForWoWAddonChannel(value)
    if value:sub(1, 8) == "encoded:" then
        return value:sub(9, #value - encodedPadding)
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
    return (action == "display" or action == "pageUpsert") and (role == "leader" or role == "assistant")
end

function AngryEra:CanLocalPlayerPublish(action)
    if action == "display" then
        return localDisplayAuthority
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

local protocol = AngryEra.utils.protocol
local localInstallationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:5:6:7:8"
local localReference = {
    SyncId = localInstallationId .. ":page:1",
    RevisionId = "fcs32:11111111",
    ContextRevisionId = "fcs32:22222222",
}
local remoteReference = {
    SyncId = remoteInstallationId .. ":page:1",
    RevisionId = "fcs32:33333333",
    ContextRevisionId = "fcs32:44444444",
}

local function PageUpsert(reference, ownerId, author)
    return {
        Page = {
            Kind = "page",
            SyncId = reference.SyncId,
            OwnerId = ownerId,
            Revision = 1,
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

function AngryEra:ResetActivePageTransientState()
    activeResetCount = activeResetCount + 1
    knownActivePages = {}
    pendingActiveDisplay = nil
end

function AngryEra:ResetDisplayPublicationState()
    publicationResetCount = publicationResetCount + 1
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

function AngryEra:BuildActiveDisplayPayload(pageId)
    if pageId == nil then
        return {
            Displayed = false,
        }
    end
    return {
        Displayed = true,
        SyncId = localReference.SyncId,
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
        RevisionId = payload.Page.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
    knownActivePages[reference.SyncId] = {
        RevisionId = reference.RevisionId,
        ContextRevisionId = reference.ContextRevisionId,
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
    }
    local pendingReady = pendingActiveDisplay
        and pendingActiveDisplay.SyncId == reference.SyncId
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
    local envelope, decodeError = protocol.DecodeEnvelope(sent.Data, AngryEra:GetProtocolCodec())
    assert(envelope, decodeError)
    return sent, envelope
end

local function LastActiveCallNamed(name)
    for index = #activeCalls, 1, -1 do
        if activeCalls[index].Name == name then
            return activeCalls[index]
        end
    end
end

local timestampTest = {}
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
    local encoded = assert(protocol.EncodeEnvelope(envelope, AngryEra:GetProtocolCodec()))
    return encoded, envelope
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

local wrongChannelQuery = BuildRemoteEnvelope("remote-session-2", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "PARTY", "Beta-Realm")
AssertError(accepted, result, "invalid-channel", "query over a non-current group channel")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "RAID", "Beta-Realm")
assert(accepted, result)
assert(#sentMessages == 3, "A wrong-channel packet must not poison deduplication")

accepted, result = AngryEra:ReceiveProtocolMessage("WrongPrefix", wrongChannelQuery, "RAID", "Beta-Realm")
AssertError(accepted, result, "invalid-transport", "wrong prefix")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, wrongChannelQuery, "RAID", "Beta-Realm")
AssertError(accepted, result, "invalid-transport-message-type", "non-display envelope over display prefix")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, wrongChannelQuery, "RAID", "Beta-Realm")
AssertError(accepted, result, "invalid-transport-message-type", "non-page envelope over active-page prefix")
local activePrefixPage = BuildRemoteEnvelope("remote-active-prefix", "PAGE_UPSERT", remoteUpsert)
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, activePrefixPage, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "invalid-transport-message-type", "active-page prefix outside the current group channel")
displayRequiresLeader = true
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, activePrefixPage, "RAID", "Alpha-Realm")
AssertError(accepted, result, "unauthorized", "assistant page over leader-only active-page prefix")
members["alpha-realm"] = "leader"
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.ACTIVE_PAGE_PREFIX, activePrefixPage, "RAID", "Alpha-Realm")
assert(accepted, result)
assert(knownActivePages[remoteReference.SyncId], "active-page prefix should deliver a complete PAGE_UPSERT")
members["alpha-realm"] = "assistant"
displayRequiresLeader = false
knownActivePages = {}
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
assert(localQueryEnvelope.Type == "VERSION_QUERY", "Discovery should send VERSION_QUERY")

local versionEncoded = BuildRemoteEnvelope(
    "remote-session-3",
    "VERSION",
    VersionPayload({
        activePage = 1,
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

sentMessages = {}
sent, result = AngryEra:SendProtocolDisplay({
    Displayed = true,
    SyncId = localReference.SyncId,
    RevisionId = localReference.RevisionId,
    ContextRevisionId = localReference.ContextRevisionId,
})
assert(sent, result)
local displayMessageId = result
local displayTransport, displayEnvelope = DecodeSent()
assert(displayTransport.Prefix == protocol.DISPLAY_PREFIX, "DISPLAY should use the isolated control prefix")
assert(displayTransport.Priority == "ALERT", "DISPLAY should use alert priority on its isolated prefix")
assert(displayTransport.Channel == "RAID", "Uncorrelated DISPLAY should use the current group channel")
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
sent, result = AngryEra:SendProtocolMessage("PAGE_UPSERT", localUpsert)
assert(sent, result)
local debugTransport = sentMessages[#sentMessages]
assert(
    type(debugTransport.Callback) == "function" and type(debugTransport.CallbackArg) == "table",
    "debug mode should attach an AceComm drain callback"
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
    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, RecordActiveTransfer, "escaped")
    assert(sent, result)
    assert(
        #throttleFrames == 1 and throttleFrames[1].Data:byte(1) == 4 and throttleFrames[1].Data:byte(2) == 1,
        "a short control-prefixed packet should use AceComm's escape frame"
    )
    throttleFrames[1].Callback(throttleFrames[1].CallbackArg, true, 0)
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

    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, RecordActiveTransfer, "second")
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

    sent, result = AngryEra:SendProtocolActivePageUpsert(localUpsert, RecordActiveTransfer, "third")
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
    encodedPadding = 0
end

timestampTest.TimeBeforeRollback = currentTime
currentTime = currentTime - 1
sent, result = AngryEra:SendProtocolMessage("DISPLAY", {
    Displayed = false,
})
assert(sent, result)
timestampTest.RollbackDisplayEnvelope = select(2, DecodeSent())
assert(
    timestampTest.RollbackDisplayEnvelope.SentAt == displayEnvelope.SentAt + 1,
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
assert(pageResponseTransport.Prefix == protocol.PREFIX, "PAGE_UPSERT should remain on the data prefix")
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
    sentMessages[1].Prefix == protocol.PREFIX and sentMessages[1].Priority == "NORMAL",
    "requested page data should use the normal data lane"
)
assert(
    requestedDisplayTransport.Prefix == protocol.DISPLAY_PREFIX and requestedDisplayTransport.Priority == "ALERT",
    "requested display control should use the isolated alert lane"
)
assert(requestedDisplayTransport.Channel == "WHISPER", "Requested display should be whispered")
assert(requestedDisplayEnvelope.Type == "DISPLAY", "Display response should end with DISPLAY")
assert(requestedDisplayEnvelope.ReplyTo == displayRequestEnvelope.MessageId, "Display response should correlate")
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
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, unauthorizedUpsertEncoded, "RAID", "Beta-Realm")
AssertError(accepted, result, "unauthorized", "member page publication")
members["beta-realm"] = "assistant"
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, unauthorizedUpsertEncoded, "RAID", "Beta-Realm")
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
    RevisionId = remoteReference.RevisionId,
    ContextRevisionId = remoteReference.ContextRevisionId,
}
local remoteDisplayEncoded, remoteDisplayEnvelope =
    BuildRemoteEnvelope("remote-active-flow", "DISPLAY", remoteDisplayPayload, {
        Sequence = 10,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, remoteDisplayEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "invalid-transport-message-type", "display envelope over data prefix")
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
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongSessionUpsert, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "page response from a different session")

local correlatedUpsertEncoded = BuildRemoteEnvelope("remote-active-flow", "PAGE_UPSERT", remoteUpsert, {
    ReplyTo = requestEnvelope.MessageId,
    Sequence = 11,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, correlatedUpsertEncoded, "WHISPER", "Alpha-Realm")
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
function AngryEra:DeferPendingDisplayRecovery(auth, envelope, reference)
    deferredRecoveryCalls = deferredRecoveryCalls + 1
    deferredRecoveryContexts[#deferredRecoveryContexts + 1] = {
        Auth = auth,
        Envelope = envelope,
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
local newerRemoteReference = {
    SyncId = remoteInstallationId .. ":page:2",
    RevisionId = "fcs32:55555555",
    ContextRevisionId = "fcs32:66666666",
}
local newerRemoteUpsert = PageUpsert(newerRemoteReference, remoteInstallationId, "Alpha-Realm")
local firstRapidDisplay = BuildRemoteEnvelope("rapid-display-flow", "DISPLAY", remoteDisplayPayload, {
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
    RevisionId = newerRemoteReference.RevisionId,
    ContextRevisionId = newerRemoteReference.ContextRevisionId,
}, {
    Sequence = 21,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, latestRapidDisplay, "RAID", "Alpha-Realm")
assert(accepted and result.RequestDeferred, "a newer rapid display should replace the deferred target")
assert(deferredRecoveryCalls == 2, "each missing rapid display should move the trailing recovery wait")
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
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, delayedFirstPage, "RAID", "Alpha-Realm")
assert(accepted and not result.CompletedDisplay, "an older page must not complete the newer pending display")
assert(canceledRecoveryCalls == 0, "an irrelevant older page should retain latest-display recovery")
local latestRapidPage = BuildRemoteEnvelope("rapid-display-flow", "PAGE_UPSERT", newerRemoteUpsert, {
    Sequence = 23,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, latestRapidPage, "RAID", "Alpha-Realm")
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
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, requestedRemoteUpsert, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "uncorrelated-reply", "wrong response sender")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, requestedRemoteUpsert, "WHISPER", "Alpha-Realm")
assert(accepted, result)

local requestedRemoteDisplay = BuildRemoteEnvelope("remote-request-response", "DISPLAY", remoteDisplayPayload, {
    ReplyTo = localDisplayRequestId,
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, requestedRemoteDisplay, "WHISPER", "Alpha-Realm")
assert(accepted and not result.RequestNeeded, "Correlated upsert then display should use exact cached tuple")

sentMessages = {}
sent, result = AngryEra:SendProtocolDisplayRequest("Alpha-Realm")
assert(sent, result)
local reorderedDisplayRequestId = result
local reorderedDeferredCalls = 0
local reorderedCancelCalls = 0
function AngryEra:DeferPendingDisplayRecovery(auth, envelope, reference)
    reorderedDeferredCalls = reorderedDeferredCalls + 1
    assert(auth.Sender == "Alpha-Realm", "reordered recovery should retain the response sender")
    assert(envelope.ReplyTo == reorderedDisplayRequestId, "reordered recovery should retain request correlation")
    assert(reference.SyncId == remoteReference.SyncId, "reordered recovery should retain the exact tuple")
    return true, "scheduled"
end
function AngryEra:CancelPendingDisplayRecovery()
    reorderedCancelCalls = reorderedCancelCalls + 1
    return true
end
local reorderedRemoteDisplay = BuildRemoteEnvelope("remote-reordered-response", "DISPLAY", remoteDisplayPayload, {
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
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, reorderedRemotePage, "WHISPER", "Alpha-Realm")
assert(
    accepted and result.CompletedDisplay and result.CompletedDisplay.Displayed,
    "the later correlated page should complete a display-first response"
)
assert(reorderedCancelCalls == 1, "the later matching page should cancel deferred recovery")
local duplicateReorderedPage = BuildRemoteEnvelope("remote-reordered-response", "PAGE_UPSERT", remoteUpsert, {
    ReplyTo = reorderedDisplayRequestId,
    Sequence = 3,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, duplicateReorderedPage, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "completed display-first response")
AngryEra.DeferPendingDisplayRecovery = nil
AngryEra.CancelPendingDisplayRecovery = nil

-- Authorization is re-evaluated for every DISPLAY, so a former leader cannot
-- keep driving the display after becoming an otherwise-qualified assistant.
displayRequiresLeader = true
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
    AngryEra:CanReceiveFrom("Alpha-Realm", "pageUpsert"),
    "The former leader should remain a qualified assistant for page updates"
)
local formerLeaderDisplay = BuildRemoteEnvelope("leader-handoff-alpha", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 2,
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
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, nondisplayRotatedSession, "RAID", "Beta-Realm")
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

local beforePruneQuery = BuildRemoteEnvelope("remote-query-before-prune", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, beforePruneQuery, "RAID", "Alpha-Realm")
assert(accepted, result)
members["alpha-realm"] = nil
AngryEra:PruneProtocolPeers()
assert(AngryEra:GetProtocolPeer("Alpha-Realm") == nil, "Roster pruning should remove departed peers")
members["alpha-realm"] = "assistant"
local afterPruneQuery = BuildRemoteEnvelope("remote-query-after-prune", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, afterPruneQuery, "RAID", "Alpha-Realm")
assert(accepted, result)

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

print("Protocol runtime tests passed.")
