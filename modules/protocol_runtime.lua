-- -------------------------------------------------------------------------------
-- Angry Era: modules/protocol_runtime.lua
--
-- Runtime session, transport, discovery, and peer state for protocol v3.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local protocol = AngryEra.utils.protocol
local helpers = AngryEra.utils.helpers
local EnsureUnitFullName = helpers.EnsureUnitFullName
local PlayerFullName = helpers.PlayerFullName

local libS = app.libs.libS
local libD = app.libs.libD
local core = AngryEra.core

local QUERY_TTL_SECONDS = 20
local QUERY_THROTTLE_SECONDS = core.updateFrequency or 2
local REPLY_THROTTLE_SECONDS = core.updateFrequency or 2
local MAX_PENDING_QUERIES = 32

local protocolSession
local seenMessages
local peers = {}
local pendingQueries = {}
local lastQueryAt
local lastReplyAt = {}

local function Now()
    return time()
end

local function NormalizePlayerKey(player)
    local fullName = EnsureUnitFullName(player)
    return fullName and fullName:lower()
end

local function CopyMap(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function LocalCapabilities()
    -- Capabilities are advertised only when their complete v3 handlers are live.
    return {}
end

local function ClientFlavor()
    if core.isClassicVanilla then
        return "ERA"
    elseif core.isClassicTBC then
        return "TBC"
    elseif core.isClassicWrath then
        return "WRATH"
    end
    return "RETAIL"
end

local function AddonVersion()
    local version = AngryEra.Version
    if type(version) ~= "string" or version == "" or version:sub(1, 1) == "@" then
        return "dev"
    end
    return version
end

local function BuildTimestamp()
    local timestamp = AngryEra.Timestamp
    if type(timestamp) ~= "string" or timestamp == "" or timestamp:sub(1, 1) == "@" then
        return "dev"
    end
    return timestamp
end

local function GenerateSessionId()
    local precise = 0
    if GetTimePreciseSec then
        precise = math.floor(GetTimePreciseSec() * 1000)
    elseif GetTime then
        precise = math.floor(GetTime() * 1000)
    end
    return string.format(
        "s%x-%x-%x-%x",
        math.floor(Now()),
        precise,
        math.random(1, 2147483647),
        math.random(1, 2147483647)
    )
end

local protocolCodec = {
    serialize = function(value)
        return libS:Serialize(value)
    end,
    deserialize = function(value)
        local success, decoded = libS:Deserialize(value)
        if success then
            return decoded
        end
    end,
    -- V3 intentionally avoids unbounded DEFLATE expansion. Manifest messages
    -- are chunked at the protocol layer instead.
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
        return libD:EncodeForWoWAddonChannel(value)
    end,
    decode = function(value)
        return libD:DecodeForWoWAddonChannel(value)
    end,
}

local function GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) or IsInRaid(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid(LE_PARTY_CATEGORY_HOME) then
        return "RAID"
    elseif IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "PARTY"
    end
end

local function IsGroupChannel(channel)
    return channel == "INSTANCE_CHAT" or channel == "RAID" or channel == "PARTY"
end

local function CleanupPendingQueries(now)
    for messageId, expiresAt in pairs(pendingQueries) do
        if expiresAt <= now then
            pendingQueries[messageId] = nil
        end
    end
end

local function RememberPendingQuery(messageId, now)
    CleanupPendingQueries(now)

    local count = 0
    local oldestId
    local oldestExpiry
    for pendingId, expiresAt in pairs(pendingQueries) do
        count = count + 1
        if oldestExpiry == nil or expiresAt < oldestExpiry or (expiresAt == oldestExpiry and pendingId < oldestId) then
            oldestId = pendingId
            oldestExpiry = expiresAt
        end
    end
    if count >= MAX_PENDING_QUERIES and oldestId then
        pendingQueries[oldestId] = nil
    end
    pendingQueries[messageId] = now + QUERY_TTL_SECONDS
end

--- Returns the trusted runtime codec used for protocol-v3 packets.
function AngryEra:GetProtocolCodec()
    return protocolCodec
end

--- Starts a fresh ephemeral protocol session and clears discovery state.
-- @tparam[opt] string sessionId Injectable session identifier for tests.
-- @treturn boolean ok
-- @treturn string|nil errorCode
function AngryEra:StartProtocolSession(sessionId)
    sessionId = sessionId or GenerateSessionId()
    local session, sessionError = protocol.NewSession(self:GetInstallationId(), sessionId)
    if not session then
        return false, sessionError
    end

    local cache, cacheError = protocol.NewSeenCache()
    if not cache then
        return false, cacheError
    end

    protocolSession = session
    seenMessages = cache
    peers = {}
    pendingQueries = {}
    lastQueryAt = nil
    lastReplyAt = {}
    return true
end

--- Clears peer/discovery state while retaining the current addon session.
function AngryEra:ResetProtocolPeers()
    peers = {}
    pendingQueries = {}
    lastQueryAt = nil
    lastReplyAt = {}
    seenMessages = assert(protocol.NewSeenCache())
end

--- Returns current protocol session state for diagnostics.
function AngryEra:GetProtocolSession()
    return protocolSession
end

--- Sends one encoded protocol-v3 envelope.
-- @treturn boolean ok
-- @treturn string messageIdOrError
function AngryEra:SendProtocolMessage(messageType, payload, options)
    if not protocolSession then
        return false, "session-not-started"
    end
    if options ~= nil and type(options) ~= "table" then
        return false, "invalid-options"
    end
    options = options or {}

    local channel = options.Channel or GroupChannel()
    if not channel then
        return false, "no-channel"
    end
    if channel == "WHISPER" and (type(options.Target) ~= "string" or options.Target == "") then
        return false, "missing-target"
    end

    local envelope, envelopeError = protocol.BuildEnvelope(protocolSession, messageType, payload, {
        ReplyTo = options.ReplyTo,
        SentAt = options.SentAt or Now(),
    })
    if not envelope then
        return false, envelopeError
    end

    local encoded, encodeError = protocol.EncodeEnvelope(envelope, protocolCodec)
    if not encoded then
        return false, encodeError
    end

    local sent = pcall(
        self.SendCommMessage,
        self,
        protocol.PREFIX,
        encoded,
        channel,
        options.Target,
        options.Priority or "NORMAL"
    )
    if not sent then
        return false, "send-failed"
    end
    return true, envelope.MessageId
end

--- Broadcasts a correlated protocol-v3 version query.
function AngryEra:SendProtocolVersionQuery(force)
    local now = Now()
    CleanupPendingQueries(now)
    if not force and lastQueryAt and now - lastQueryAt < QUERY_THROTTLE_SECONDS then
        return false, "throttled"
    end

    local sent, messageId = self:SendProtocolMessage("VERSION_QUERY", {}, {
        SentAt = now,
    })
    if not sent then
        return false, messageId
    end

    lastQueryAt = now
    RememberPendingQuery(messageId, now)
    return true, messageId
end

--- Whispers local protocol metadata in reply to one query.
function AngryEra:SendProtocolVersion(target, replyTo)
    return self:SendProtocolMessage("VERSION", {
        AddonVersion = AddonVersion(),
        BuildTimestamp = BuildTimestamp(),
        Flavor = ClientFlavor(),
        Capabilities = LocalCapabilities(),
        AcceptsCurrentGroup = self:IsValidRaid(),
    }, {
        Channel = "WHISPER",
        Target = target,
        ReplyTo = replyTo,
    })
end

function AngryEra:HandleProtocolVersionQuery(sender, channel, envelope)
    if not IsGroupChannel(channel) then
        return false, "invalid-channel"
    end

    local senderKey = NormalizePlayerKey(sender)
    local now = Now()
    if lastReplyAt[senderKey] and now - lastReplyAt[senderKey] < REPLY_THROTTLE_SECONDS then
        return false, "throttled"
    end

    local sent, result = self:SendProtocolVersion(sender, envelope.MessageId)
    if sent then
        lastReplyAt[senderKey] = now
    end
    return sent, result
end

function AngryEra:HandleProtocolVersion(sender, channel, envelope)
    if channel ~= "WHISPER" then
        return false, "invalid-channel"
    end

    local now = Now()
    CleanupPendingQueries(now)
    if not envelope.ReplyTo or not pendingQueries[envelope.ReplyTo] then
        return false, "uncorrelated-reply"
    end

    local payload = envelope.Payload
    local localCapabilities = LocalCapabilities()
    local negotiated = protocol.NegotiateCapabilities(localCapabilities, payload.Capabilities)
    local senderKey = NormalizePlayerKey(sender)
    peers[senderKey] = {
        Sender = EnsureUnitFullName(sender),
        SenderInstallationId = envelope.SenderInstallationId,
        SenderSessionId = envelope.SenderSessionId,
        AddonVersion = payload.AddonVersion,
        BuildTimestamp = payload.BuildTimestamp,
        Flavor = payload.Flavor,
        Capabilities = CopyMap(payload.Capabilities),
        NegotiatedCapabilities = negotiated,
        AcceptsCurrentGroup = payload.AcceptsCurrentGroup,
        LastSeenAt = now,
        ReplyTo = envelope.ReplyTo,
    }
    return true
end

local HANDLERS = {
    VERSION_QUERY = "HandleProtocolVersionQuery",
    VERSION = "HandleProtocolVersion",
}

--- Dispatches a validated, authorized, non-duplicate envelope.
function AngryEra:DispatchProtocolMessage(sender, channel, envelope)
    local handlerName = HANDLERS[envelope.Type]
    local handler = handlerName and self[handlerName]
    if not handler then
        return false, "unknown-message-type"
    end
    return handler(self, sender, channel, envelope)
end

--- Receives, authenticates, decodes, deduplicates, and dispatches protocol v3.
function AngryEra:ReceiveProtocolMessage(prefix, data, channel, sender)
    if prefix ~= protocol.PREFIX or type(sender) ~= "string" then
        return false, "invalid-transport"
    end

    sender = EnsureUnitFullName(sender)
    if not sender or sender == PlayerFullName() then
        return false, "invalid-sender"
    end
    if not self:CanReceiveFrom(sender, "version") then
        return false, "unauthorized"
    end

    local envelope, decodeError = protocol.DecodeEnvelope(data, protocolCodec)
    if not envelope then
        return false, decodeError
    end
    if
        (envelope.Type == "VERSION_QUERY" and not IsGroupChannel(channel))
        or (envelope.Type == "VERSION" and channel ~= "WHISPER")
    then
        return false, "invalid-channel"
    end

    seenMessages = seenMessages or assert(protocol.NewSeenCache())
    local duplicate, seenError = protocol.SeenOrRemember(seenMessages, sender, envelope.MessageId)
    if duplicate == nil then
        return false, seenError
    end
    if duplicate then
        return false, "duplicate"
    end

    return self:DispatchProtocolMessage(sender, channel, envelope)
end

--- Returns discovery metadata for an authenticated player.
function AngryEra:GetProtocolPeer(player)
    local key = NormalizePlayerKey(player)
    return key and peers[key]
end

function AngryEra:GetPeerCapabilities(player)
    local peer = self:GetProtocolPeer(player)
    return peer and CopyMap(peer.Capabilities)
end

function AngryEra:PeerSupports(player, capability, minimumVersion)
    local peer = self:GetProtocolPeer(player)
    return peer and protocol.Supports(peer.NegotiatedCapabilities, capability, minimumVersion) or false
end

--- Removes peer and throttle records for players no longer in the group.
function AngryEra:PruneProtocolPeers()
    for key, peer in pairs(peers) do
        if self:GetGroupRole(peer.Sender) == "absent" then
            peers[key] = nil
            lastReplyAt[key] = nil
        end
    end
end
