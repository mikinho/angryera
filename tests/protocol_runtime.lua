local currentTime = 100
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
local sentMessages = {}
local printedMessages = {}

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

local libD = {}
function libD:EncodeForWoWAddonChannel(value)
    return "encoded:" .. value
end
function libD:DecodeForWoWAddonChannel(value)
    return value:match("^encoded:(.+)$")
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
    return (action == "display" or action == "pageUpsert") and (role == "leader" or role == "assistant")
end

function AngryEra:CanLocalPlayerPublish(action)
    return action == "display" or action == "pageUpsert"
end

function AngryEra:SendCommMessage(prefix, data, channel, target, priority)
    sentMessages[#sentMessages + 1] = {
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

local app = {
    AngryEra = AngryEra,
    libs = {
        libS = libS,
        libD = libD,
    },
}

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

function AngryEra:ResetActivePageTransientState()
    activeResetCount = activeResetCount + 1
    knownActivePages = {}
    pendingActiveDisplay = nil
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

local function BuildRemoteEnvelope(sessionId, messageType, payload, options)
    options = options or {}
    local installationId = options.InstallationId or remoteInstallationId
    local session = assert(protocol.NewSession(installationId, sessionId))
    if options.Sequence then
        session.Sequence = options.Sequence - 1
    end
    local envelope = assert(protocol.BuildEnvelope(session, messageType, payload, {
        ReplyTo = options.ReplyTo,
        SentAt = options.SentAt or currentTime,
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
local firstSession = AngryEra:GetProtocolSession()
assert(firstSession.InstallationId == localInstallationId, "Session should use the durable installation identity")
assert(firstSession.SessionId == "local-session-1", "Injected session identity should be retained")

local queryEncoded, remoteQuery = BuildRemoteEnvelope("remote-session-1", "VERSION_QUERY", {})
local accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, queryEncoded, "RAID", "Alpha-Realm")
assert(accepted, result)
assert(#sentMessages == 1, "A valid group query should receive one reply")

local replyTransport, replyEnvelope = DecodeSent()
assert(replyTransport.Prefix == protocol.PREFIX, "V3 messages should use the v3 prefix")
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
assert(displayTransport.Channel == "RAID", "Uncorrelated DISPLAY should use the current group channel")
assert(displayEnvelope.ReplyTo == nil, "Group DISPLAY must not carry correlation")

local pageRequestEncoded, pageRequestEnvelope =
    BuildRemoteEnvelope("remote-page-request", "PAGE_REQUEST", localReference, {
        ReplyTo = displayMessageId,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, pageRequestEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)
assert(#sentMessages == 2, "A correlated page request should receive one response")
local pageResponseTransport, pageResponseEnvelope = DecodeSent()
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
assert(requestedDisplayTransport.Channel == "WHISPER", "Requested display should be whispered")
assert(requestedDisplayEnvelope.Type == "DISPLAY", "Display response should end with DISPLAY")
assert(requestedDisplayEnvelope.ReplyTo == displayRequestEnvelope.MessageId, "Display response should correlate")
local repeatedDisplayRequest = BuildRemoteEnvelope("remote-display-request", "DISPLAY_REQUEST", {}, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, repeatedDisplayRequest, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "throttled", "unique display requests for the same sender and display tuple")
assert(#sentMessages == 2, "A throttled display request must not amplify into another page response")

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
        SentAt = 1,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, remoteDisplayEncoded, "RAID", "Alpha-Realm")
assert(accepted, result)
assert(result.RequestNeeded and result.RequestSent, "A missing exact tuple should send PAGE_REQUEST")
assert(result.UIWarning == "ui-refresh-failed", "A committed active result should preserve UI warnings")
local requestTransport, requestEnvelope = DecodeSent()
assert(requestTransport.Channel == "WHISPER", "PAGE_REQUEST should be whispered to the display sender")
assert(requestTransport.Target == "Alpha-Realm", "PAGE_REQUEST should target the authenticated publisher")
assert(requestEnvelope.Type == "PAGE_REQUEST", "Missing page should produce PAGE_REQUEST")
assert(requestEnvelope.ReplyTo == remoteDisplayEnvelope.MessageId, "PAGE_REQUEST should identify triggering DISPLAY")

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

accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, remoteDisplayEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "duplicate", "duplicate display")
local staleDisplayEncoded = BuildRemoteEnvelope("remote-active-flow", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 9,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, staleDisplayEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "stale-display", "delayed display replay")

local clearDisplayEncoded = BuildRemoteEnvelope("remote-active-flow", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 12,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, clearDisplayEncoded, "RAID", "Alpha-Realm")
assert(accepted and result.Displayed == false, "A newer display clear should apply")

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
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, requestedRemoteDisplay, "WHISPER", "Alpha-Realm")
assert(accepted and not result.RequestNeeded, "Correlated upsert then display should use exact cached tuple")

members["beta-realm"] = "assistant"
local firstDisplaySessionPacket = BuildRemoteEnvelope("beta-display-session-1", "DISPLAY", {
    Displayed = false,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, firstDisplaySessionPacket, "RAID", "Beta-Realm")
assert(accepted, result)
local secondDisplaySessionPacket = BuildRemoteEnvelope("beta-display-session-2", "DISPLAY", {
    Displayed = false,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, secondDisplaySessionPacket, "RAID", "Beta-Realm")
assert(accepted, result)

local nondisplayRotatedSession = BuildRemoteEnvelope("beta-nondisplay-session", "PAGE_UPSERT", remoteUpsert)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, nondisplayRotatedSession, "RAID", "Beta-Realm")
assert(accepted, result)
local activeDisplaySessionContinues = BuildRemoteEnvelope("beta-display-session-2", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, activeDisplaySessionContinues, "RAID", "Beta-Realm")
assert(accepted, result or "Non-display traffic from another session must not retire the active display session")

local retiredDisplaySessionPacket = BuildRemoteEnvelope("beta-display-session-1", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, retiredDisplaySessionPacket, "RAID", "Beta-Realm")
AssertError(accepted, result, "stale-display-session", "retired display session")

for index = 3, 64 do
    local rotatedDisplay = BuildRemoteEnvelope("beta-display-session-" .. index, "DISPLAY", {
        Displayed = false,
    })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, rotatedDisplay, "RAID", "Beta-Realm")
    assert(accepted, result)
end
local overflowDisplaySession = BuildRemoteEnvelope("beta-display-session-65", "DISPLAY", {
    Displayed = false,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, overflowDisplaySession, "RAID", "Beta-Realm")
AssertError(accepted, result, "display-session-capacity", "display session rotation capacity")

local lastDisplaySessionContinues = BuildRemoteEnvelope("beta-display-session-64", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, lastDisplaySessionContinues, "RAID", "Beta-Realm")
assert(accepted, result or "Capacity rejection must not poison the active display session")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, retiredDisplaySessionPacket, "RAID", "Beta-Realm")
AssertError(accepted, result, "stale-display-session", "retired session after replay-cache eviction")
members["beta-realm"] = "member"

local localSessionForCapacity = AngryEra:GetProtocolSession()
assert(localSessionForCapacity.Sequence < 98, "Capacity test requires a controlled sequence boundary")
localSessionForCapacity.Sequence = 98
local chronologicalDisplayIds = {}
for index = 1, 10 do
    sent, chronologicalDisplayIds[index] = AngryEra:SendProtocolDisplay({
        Displayed = true,
        SyncId = localReference.SyncId,
        RevisionId = localReference.RevisionId,
        ContextRevisionId = localReference.ContextRevisionId,
    })
    assert(sent, chronologicalDisplayIds[index])
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
AngryEra:ResetProtocolPeers()
assert(activeResetCount == activeResetsBeforePeerReset + 1, "Group reset should clear prior-group active render state")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, requestedRemoteDisplay, "WHISPER", "Alpha-Realm")
AssertError(accepted, result, "uncorrelated-reply", "peer reset should clear transport correlation")
local afterResetQuery = BuildRemoteEnvelope("remote-query-after-reset", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, afterResetQuery, "RAID", "Alpha-Realm")
assert(accepted, result)

started, startError = AngryEra:StartProtocolSession("local-session-2")
assert(started and not startError, "A second enable should create a fresh session")
assert(activeResetCount == activeResetsBeforePeerReset + 2, "A new session should clear active transients")
assert(AngryEra:GetProtocolSession().SessionId == "local-session-2", "A new enable should rotate session identity")
assert(
    AngryEra:GetProtocolSession().InstallationId == firstSession.InstallationId,
    "Installation identity should remain stable across sessions"
)
assert(AngryEra:GetProtocolPeer("Alpha-Realm") == nil, "Starting a new session should clear stale peers")

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

local codec = AngryEra:GetProtocolCodec()
local inflated, inflationError = codec.decompress(string.rep("x", 9), 8)
assert(inflated == nil and inflationError == "output-too-large", "Runtime decompression must enforce its budget")
local badDecoded, badDecodeError = protocol.DecodeEnvelope("encoded:unknown", codec)
AssertError(badDecoded, badDecodeError, "deserialize-failed", "AceSerializer failure unwrapping")

print("Protocol runtime tests passed.")
