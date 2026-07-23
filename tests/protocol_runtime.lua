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
    Version = "@project-version@",
    Timestamp = "@timestamp@",
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
    return action == "version" and self:GetGroupRole(player) ~= "absent"
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

local app = {
    AngryEra = AngryEra,
    libs = {
        libS = libS,
        libD = libD,
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/protocol.lua"))("AngryEra", app)
assert(loadfile("modules/protocol_runtime.lua"))("AngryEra", app)

local protocol = AngryEra.utils.protocol
local remoteInstallationId = "ae3i:5:6:7:8"

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

local function BuildRemoteEnvelope(sessionId, messageType, payload, options)
    local session = assert(protocol.NewSession(remoteInstallationId, sessionId))
    if options and options.Sequence then
        session.Sequence = options.Sequence - 1
    end
    local envelope = assert(protocol.BuildEnvelope(session, messageType, payload, {
        ReplyTo = options and options.ReplyTo,
        SentAt = options and options.SentAt or currentTime,
    }))
    local encoded = assert(protocol.EncodeEnvelope(envelope, AngryEra:GetProtocolCodec()))
    return encoded, envelope
end

local function VersionPayload(capabilities)
    return {
        AddonVersion = "3.2.0",
        BuildTimestamp = "20260723120000",
        Flavor = "ERA",
        Capabilities = capabilities or {},
        AcceptsCurrentGroup = true,
    }
end

local sent, sendError = AngryEra:SendProtocolMessage("VERSION_QUERY", {})
AssertError(sent, sendError, "session-not-started", "send before session")

local started, startError = AngryEra:StartProtocolSession("local-session-1")
assert(started and not startError, "A valid protocol session should start")
local firstSession = AngryEra:GetProtocolSession()
assert(firstSession.InstallationId == "ae3i:1:2:3:4", "Session should use the durable installation identity")
assert(firstSession.SessionId == "local-session-1", "Injected session identity should be retained")

local queryEncoded, remoteQuery = BuildRemoteEnvelope("remote-session-1", "VERSION_QUERY", {})
local accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, queryEncoded, "RAID", "Alpha-Realm")
assert(accepted, result)
assert(#sentMessages == 1, "A valid group query should receive one reply")

local replyTransport, replyEnvelope = DecodeSent()
assert(replyTransport.Prefix == protocol.PREFIX, "V3 messages should use the v3 prefix")
assert(replyTransport.Channel == "WHISPER", "Version replies should be whispered")
assert(replyTransport.Target == "Alpha-Realm", "Version replies should target the authenticated sender")
assert(replyTransport.Priority == "NORMAL", "Protocol messages should use normal priority")
assert(replyEnvelope.Type == "VERSION", "A query should produce a VERSION envelope")
assert(replyEnvelope.ReplyTo == remoteQuery.MessageId, "Version reply should correlate to the exact query")
assert(replyEnvelope.Payload.AddonVersion == "dev", "Unexpanded addon versions should advertise dev")
assert(replyEnvelope.Payload.BuildTimestamp == "dev", "Unexpanded build timestamps should advertise dev")
assert(next(replyEnvelope.Payload.Capabilities) == nil, "Unimplemented capabilities must not be advertised")

accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, queryEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "duplicate", "duplicate query")
assert(#sentMessages == 1, "A duplicate query should not produce another reply")

local rapidQueryEncoded = BuildRemoteEnvelope("remote-session-1", "VERSION_QUERY", {}, { Sequence = 2 })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, rapidQueryEncoded, "RAID", "Alpha-Realm")
AssertError(accepted, result, "throttled", "rapid unique query")
assert(#sentMessages == 1, "A rapid unique query should be suppressed per sender")

currentTime = currentTime + 2
local laterQueryEncoded = BuildRemoteEnvelope("remote-session-1", "VERSION_QUERY", {}, { Sequence = 3 })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, laterQueryEncoded, "RAID", "Alpha-Realm")
assert(accepted, result)
assert(#sentMessages == 2, "A later query should receive a new reply")

local wrongChannelQuery = BuildRemoteEnvelope("remote-session-2", "VERSION_QUERY", {})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "invalid-channel", "query over whisper")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "PARTY", "Beta-Realm")
assert(accepted, result)
assert(#sentMessages == 3, "A wrong-channel packet must not poison deduplication")

accepted, result = AngryEra:ReceiveProtocolMessage("WrongPrefix", wrongChannelQuery, "PARTY", "Beta-Realm")
AssertError(accepted, result, "invalid-transport", "wrong prefix")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, "malformed", "PARTY", "Beta-Realm")
AssertError(accepted, result, "decode-failed", "malformed encoded payload")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "PARTY", "Outside-Realm")
AssertError(accepted, result, "unauthorized", "sender outside current group")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongChannelQuery, "PARTY", currentPlayer)
AssertError(accepted, result, "invalid-sender", "self message")

currentTime = currentTime + 2
sent, result = AngryEra:SendProtocolVersionQuery(true)
assert(sent, result)
local queryMessageId = result
local queryTransport, localQueryEnvelope = DecodeSent()
assert(queryTransport.Channel == "RAID", "A raid query should broadcast to RAID")
assert(localQueryEnvelope.Type == "VERSION_QUERY", "Discovery should send VERSION_QUERY")
assert(localQueryEnvelope.MessageId == queryMessageId, "Returned query ID should match the sent envelope")

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
assert(peer.SenderInstallationId == remoteInstallationId, "Peer should retain advertised installation metadata")
assert(peer.SenderSessionId == "remote-session-3", "Peer should retain advertised session metadata")
assert(peer.ReplyTo == queryMessageId, "Peer should retain discovery correlation")
assert(peer.Capabilities.activePage == 1, "Peer capability metadata should be copied")
assert(not AngryEra:PeerSupports("Alpha-Realm", "activePage"), "Unimplemented local capabilities must not negotiate")
local copiedCapabilities = AngryEra:GetPeerCapabilities("Alpha-Realm")
copiedCapabilities.activePage = 99
assert(peer.Capabilities.activePage == 1, "Capability access should not expose mutable peer state")

local uncorrelatedEncoded = BuildRemoteEnvelope("remote-session-4", "VERSION", VersionPayload(), {
    ReplyTo = remoteQuery.MessageId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, uncorrelatedEncoded, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "uncorrelated-reply", "unknown reply correlation")

local replacementEncoded = BuildRemoteEnvelope("remote-session-5", "VERSION", VersionPayload(), {
    ReplyTo = queryMessageId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, replacementEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)
peer = AngryEra:GetProtocolPeer("Alpha-Realm")
assert(peer.SenderSessionId == "remote-session-5", "A new authenticated session should replace prior peer metadata")

currentTime = currentTime + 21
local expiredEncoded = BuildRemoteEnvelope("remote-session-6", "VERSION", VersionPayload(), {
    ReplyTo = queryMessageId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, expiredEncoded, "WHISPER", "Beta-Realm")
AssertError(accepted, result, "uncorrelated-reply", "expired reply correlation")

local codec = AngryEra:GetProtocolCodec()
local inflated, inflationError = codec.decompress(string.rep("x", 9), 8)
assert(inflated == nil and inflationError == "output-too-large", "Runtime decompression must enforce its input budget")
local badDecoded, badDecodeError = protocol.DecodeEnvelope("encoded:unknown", codec)
AssertError(badDecoded, badDecodeError, "deserialize-failed", "AceSerializer failure unwrapping")

currentTime = currentTime + 1
started, startError = AngryEra:StartProtocolSession("local-session-2")
assert(started and not startError, "A second enable should create a fresh session")
assert(AngryEra:GetProtocolSession().SessionId == "local-session-2", "Session ID should renew across enables")
assert(
    AngryEra:GetProtocolSession().InstallationId == firstSession.InstallationId,
    "Installation identity should remain stable across sessions"
)
assert(AngryEra:GetProtocolPeer("Alpha-Realm") == nil, "Starting a new session should clear stale peers")

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

currentTime = currentTime + 2
local pruneQueryId
sent, pruneQueryId = AngryEra:SendProtocolVersionQuery(true)
assert(sent, pruneQueryId)
local pruneVersionEncoded = BuildRemoteEnvelope("remote-session-prune", "VERSION", VersionPayload(), {
    ReplyTo = pruneQueryId,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, pruneVersionEncoded, "WHISPER", "Alpha-Realm")
assert(accepted, result)
members["alpha-realm"] = nil
AngryEra:PruneProtocolPeers()
assert(AngryEra:GetProtocolPeer("Alpha-Realm") == nil, "Roster pruning should remove departed peers")

AngryEra:ResetProtocolPeers()
assert(AngryEra:GetProtocolPeer("Beta-Realm") == nil, "Discovery reset should clear peer state")

print("Protocol runtime tests passed.")
