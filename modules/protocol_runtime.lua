-- -------------------------------------------------------------------------------
-- Angry Era: modules/protocol_runtime.lua
--
-- Runtime session, authenticated transport, discovery, and active-page routing
-- for protocol v3.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local protocol = AngryEra.utils.protocol
local helpers = AngryEra.utils.helpers
local EnsureUnitFullName = helpers.EnsureUnitFullName
local PlayerFullName = helpers.PlayerFullName

local libS = app.libs.libS
local libC = app.libs.libC
local libD = app.libs.libD
local core = AngryEra.core

local QUERY_TTL_SECONDS = 20
local INTERACTION_TTL_SECONDS = 20
local ACTIVE_PAGE_CORRELATION_TTL_SECONDS = 15 * 60
local QUERY_THROTTLE_SECONDS = core.updateFrequency or 2
local REPLY_THROTTLE_SECONDS = core.updateFrequency or 2
local MAX_PENDING_QUERIES = 32
local MAX_PENDING_INTERACTIONS = 64
local MAX_PENDING_PER_PLAYER = 8
local MAX_REPLAY_PLAYERS = 64
local MAX_REPLAY_SESSIONS_PER_PLAYER = 4
local MAX_SEEN_PER_SESSION = 64
local MAX_DISPLAY_SESSIONS_PER_PLAYER = 64
local TIMESTAMP_MILLISECONDS_PER_SECOND = 1000
local DISPLAY_TIMESTAMP_MAX_AGE_SECONDS = 5 * 60
local DISPLAY_TIMESTAMP_MAX_FUTURE_SECONDS = 10
local MINIMUM_PLAUSIBLE_SERVER_EPOCH = 1000000000
local MAX_SAFE_INTEGER = 9007199254740991

local protocolSession
local peers = {}
local peerQueryOrdinals = {}
local pendingQueries = {}
local pendingDisplayRequests = {}
local pendingPageRequests = {}
local outboundDisplays = {}
local displayRequestReplies = {}
local replayPlayers = {}
local replayPlayerCount = 0
local lastVersionReplyAt = {}
local lastVersionReplyCount = 0
local lastQueryAt
local warnedOutOfDate = false
local transportOrdinal = 0
local lastDisplaySentAt

local HANDLERS

local function Now()
    return time()
end

local function IsPlainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function IsSafeInteger(value)
    return type(value) == "number" and value == math.floor(value) and value >= 0 and value <= MAX_SAFE_INTEGER
end

local function CurrentEpochSeconds()
    if type(GetServerTime) == "function" then
        local ok, value = pcall(GetServerTime)
        if ok and IsSafeInteger(value) and value >= MINIMUM_PLAUSIBLE_SERVER_EPOCH then
            return value
        end
    end

    local value = Now()
    if not IsSafeInteger(value) then
        return nil
    end
    return value
end

local function CurrentPreciseMillisecond()
    local clock
    if type(GetTimePreciseSec) == "function" then
        clock = GetTimePreciseSec
    elseif type(GetTime) == "function" then
        clock = GetTime
    end
    if not clock then
        return 0
    end

    local ok, value = pcall(clock)
    if not ok or type(value) ~= "number" or value < 0 then
        return 0
    end
    return math.floor(value * TIMESTAMP_MILLISECONDS_PER_SECOND) % TIMESTAMP_MILLISECONDS_PER_SECOND
end

local function CurrentEpochMilliseconds()
    local seconds = CurrentEpochSeconds()
    if not seconds or seconds > math.floor(MAX_SAFE_INTEGER / TIMESTAMP_MILLISECONDS_PER_SECOND) then
        return nil
    end
    return seconds * TIMESTAMP_MILLISECONDS_PER_SECOND + CurrentPreciseMillisecond()
end

local function NextDisplaySentAt()
    local candidate = CurrentEpochMilliseconds()
    if not candidate then
        return nil, "invalid-clock"
    end

    local previous = lastDisplaySentAt
    local meta = IsPlainTable(AngryAssign_Meta) and AngryAssign_Meta or nil
    local persisted = meta and rawget(meta, "LastDisplaySentAt") or nil
    if
        previous == nil
        and IsSafeInteger(persisted)
        and persisted <= candidate + DISPLAY_TIMESTAMP_MAX_FUTURE_SECONDS * TIMESTAMP_MILLISECONDS_PER_SECOND
    then
        previous = persisted
    end

    local sentAt = candidate
    if previous and previous >= sentAt then
        if previous >= MAX_SAFE_INTEGER then
            return nil, "timestamp-exhausted"
        end
        sentAt = previous + 1
    end

    lastDisplaySentAt = sentAt
    if meta then
        meta.LastDisplaySentAt = sentAt
    end
    return sentAt
end

local function ValidateDisplayTimestamp(sentAt)
    local seconds = CurrentEpochSeconds()
    if not seconds then
        return false
    end

    local sentSeconds = math.floor(sentAt / TIMESTAMP_MILLISECONDS_PER_SECOND)
    return sentSeconds >= seconds - DISPLAY_TIMESTAMP_MAX_AGE_SECONDS
        and sentSeconds <= seconds + DISPLAY_TIMESTAMP_MAX_FUTURE_SECONDS
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

local function CopyPeer(source)
    if not IsPlainTable(source) then
        return nil
    end
    return {
        Sender = source.Sender,
        SenderInstallationId = source.SenderInstallationId,
        SenderSessionId = source.SenderSessionId,
        AddonVersion = source.AddonVersion,
        BuildTimestamp = source.BuildTimestamp,
        Flavor = source.Flavor,
        Capabilities = CopyMap(source.Capabilities),
        NegotiatedCapabilities = CopyMap(source.NegotiatedCapabilities),
        AcceptsCurrentGroup = source.AcceptsCurrentGroup,
        LastSeenAt = source.LastSeenAt,
        ReplyTo = source.ReplyTo,
    }
end

local function NextTransportOrdinal()
    transportOrdinal = transportOrdinal + 1
    return transportOrdinal
end

local function CopyReference(source)
    if not IsPlainTable(source) then
        return nil
    end
    return {
        SyncId = source.SyncId,
        RevisionId = source.RevisionId,
        ContextRevisionId = source.ContextRevisionId,
    }
end

local function SameReference(left, right)
    return IsPlainTable(left)
        and IsPlainTable(right)
        and left.SyncId == right.SyncId
        and left.RevisionId == right.RevisionId
        and left.ContextRevisionId == right.ContextRevisionId
end

local function ReferenceFromPayload(messageType, payload)
    if messageType == "PAGE_UPSERT" then
        return {
            SyncId = payload.Page.SyncId,
            RevisionId = payload.Page.RevisionId,
            ContextRevisionId = payload.ContextRevisionId,
        }
    elseif messageType == "DISPLAY" and payload.Displayed then
        return CopyReference(payload)
    elseif messageType == "PAGE_REQUEST" then
        return CopyReference(payload)
    end
end

local function ActivePageHandlersLive()
    local required = {
        "PrepareActivePageUpsert",
        "BuildActiveDisplayPayload",
        "BuildActiveDisplayRequestResponse",
        "BuildActivePageRequestResponse",
        "AcceptActivePageUpsert",
        "AcceptActiveDisplay",
        "ActivatePreparedActiveDisplay",
        "ClearActiveDisplayReference",
        "GetActivePageRenderContext",
        "GetActiveDisplayReference",
        "ResetActivePageTransientState",
        "HandleProtocolDisplayRequest",
        "HandleProtocolDisplay",
        "HandleProtocolPageRequest",
        "HandleProtocolPageUpsert",
        "SendProtocolDisplayRequest",
        "SendProtocolDisplay",
        "SendProtocolPageRequest",
        "SendProtocolPageUpsert",
    }
    for _, name in ipairs(required) do
        if type(AngryEra[name]) ~= "function" then
            return false
        end
    end
    return HANDLERS ~= nil
        and HANDLERS.DISPLAY_REQUEST ~= nil
        and HANDLERS.DISPLAY ~= nil
        and HANDLERS.PAGE_REQUEST ~= nil
        and HANDLERS.PAGE_UPSERT ~= nil
end

local function LocalCapabilities()
    if ActivePageHandlersLive() then
        return {
            activePage = 1,
        }
    end
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

local HUFFMAN_STORED = 1
local HUFFMAN_COMPRESSED = 3

local function DeclaredHuffmanOutputBytes(value)
    local method = value:byte(1)
    if method == HUFFMAN_STORED then
        return #value - 1
    end
    if method ~= HUFFMAN_COMPRESSED or #value < 5 then
        return nil
    end

    local low, middle, high = value:byte(3, 5)
    return low + middle * 256 + high * 65536
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
    compress = function(value)
        return libC:CompressHuffman(value)
    end,
    decompress = function(value, maximumOutputBytes)
        -- LibCompress Huffman framing exposes the exact output length before
        -- decode: stored packets derive it from packet size and compressed
        -- packets carry it in a fixed header. Reject that length before calling
        -- the decoder so untrusted packets cannot cause unbounded expansion.
        local declaredBytes = DeclaredHuffmanOutputBytes(value)
        if declaredBytes == nil then
            return nil, "invalid-compression-header"
        end
        if declaredBytes > maximumOutputBytes then
            return nil, "output-too-large"
        end
        local output = libC:Decompress(value)
        if type(output) ~= "string" or #output ~= declaredBytes then
            return nil, "invalid-compressed-payload"
        end
        return output
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

local function IsCurrentGroupChannel(channel)
    local current = GroupChannel()
    return current ~= nil and channel == current
end

local function CleanupRecords(records, now)
    for messageId, record in pairs(records) do
        if not IsPlainTable(record) or record.ExpiresAt <= now then
            records[messageId] = nil
        end
    end
end

local function CountRecords(records, ownerKey)
    local total = 0
    local owned = 0
    local oldestOwnedId
    local oldestOwnedOrdinal
    local oldestGlobalId
    local oldestGlobalOrdinal
    for messageId, record in pairs(records) do
        total = total + 1
        if record.OwnerKey == ownerKey then
            owned = owned + 1
            if oldestOwnedOrdinal == nil or record.CreatedOrdinal < oldestOwnedOrdinal then
                oldestOwnedId = messageId
                oldestOwnedOrdinal = record.CreatedOrdinal
            end
        end
        if oldestGlobalOrdinal == nil or record.CreatedOrdinal < oldestGlobalOrdinal then
            oldestGlobalId = messageId
            oldestGlobalOrdinal = record.CreatedOrdinal
        end
    end
    return total, owned, oldestOwnedId, oldestGlobalId
end

local function RememberInteraction(records, messageId, record, now)
    CleanupRecords(records, now)
    local total, owned, oldestOwned, oldestGlobal = CountRecords(records, record.OwnerKey)
    if owned >= MAX_PENDING_PER_PLAYER and oldestOwned then
        records[oldestOwned] = nil
        total = total - 1
    end
    if total >= MAX_PENDING_INTERACTIONS and oldestGlobal then
        records[oldestGlobal] = nil
    end
    record.CreatedAt = now
    record.CreatedOrdinal = NextTransportOrdinal()
    record.ExpiresAt = now + INTERACTION_TTL_SECONDS
    records[messageId] = record
    return true
end

local function CleanupPendingQueries(now)
    CleanupRecords(pendingQueries, now)
end

local function RememberPendingQuery(messageId, now)
    CleanupPendingQueries(now)

    local count = 0
    local oldestId
    local oldestOrdinal
    for pendingId, record in pairs(pendingQueries) do
        count = count + 1
        if oldestOrdinal == nil or record.CreatedOrdinal < oldestOrdinal then
            oldestId = pendingId
            oldestOrdinal = record.CreatedOrdinal
        end
    end
    if count >= MAX_PENDING_QUERIES and oldestId then
        pendingQueries[oldestId] = nil
    end
    pendingQueries[messageId] = {
        CreatedAt = now,
        CreatedOrdinal = NextTransportOrdinal(),
        ExpiresAt = now + QUERY_TTL_SECONDS,
        Responders = {},
    }
end

local function ResetTransportTables()
    peers = {}
    peerQueryOrdinals = {}
    pendingQueries = {}
    pendingDisplayRequests = {}
    pendingPageRequests = {}
    outboundDisplays = {}
    displayRequestReplies = {}
    replayPlayers = {}
    replayPlayerCount = 0
    lastVersionReplyAt = {}
    lastVersionReplyCount = 0
    lastQueryAt = nil
    transportOrdinal = 0
end

local function BuildAuth(sender, envelope, receivedAt)
    return {
        Sender = sender,
        SenderInstallationId = envelope.SenderInstallationId,
        SenderSessionId = envelope.SenderSessionId,
        ReceivedAt = receivedAt,
    }
end

local function ReplaySessionKey(auth)
    return auth.SenderInstallationId .. "\0" .. auth.SenderSessionId
end

local function FindOldestReplaySession(playerState)
    local oldestKey
    local oldestOrdinal
    for sessionKey, sessionState in pairs(playerState.Sessions) do
        if oldestOrdinal == nil or sessionState.LastSeenOrdinal < oldestOrdinal then
            oldestKey = sessionKey
            oldestOrdinal = sessionState.LastSeenOrdinal
        end
    end
    return oldestKey
end

local function GetReplayState(auth, create)
    local playerKey = NormalizePlayerKey(auth.Sender)
    local playerState = playerKey and replayPlayers[playerKey] or nil
    if not playerState and create then
        if replayPlayerCount >= MAX_REPLAY_PLAYERS then
            return nil, "replay-capacity"
        end
        playerState = {
            Sessions = {},
            SessionCount = 0,
            DisplaySessions = {},
            DisplaySessionCount = 0,
            ActiveDisplaySessionKey = nil,
            DisplayEpoch = 0,
            HighestDisplaySentAt = nil,
        }
        replayPlayers[playerKey] = playerState
        replayPlayerCount = replayPlayerCount + 1
    end
    if not playerState then
        return nil
    end

    local sessionKey = ReplaySessionKey(auth)
    local sessionState = playerState.Sessions[sessionKey]
    if not sessionState and create then
        if playerState.SessionCount >= MAX_REPLAY_SESSIONS_PER_PLAYER then
            local oldestKey = FindOldestReplaySession(playerState)
            if oldestKey then
                playerState.Sessions[oldestKey] = nil
                playerState.SessionCount = playerState.SessionCount - 1
            end
        end
        local cache, cacheError = protocol.NewSeenCache(MAX_SEEN_PER_SESSION)
        if not cache then
            return nil, cacheError
        end
        sessionState = {
            Seen = cache,
            LastSeenAt = Now(),
            LastSeenOrdinal = 0,
        }
        playerState.Sessions[sessionKey] = sessionState
        playerState.SessionCount = playerState.SessionCount + 1
    end
    if sessionState then
        sessionState.LastSeenAt = Now()
        sessionState.LastSeenOrdinal = NextTransportOrdinal()
    end
    return sessionState, nil, playerState, sessionKey
end

local function RememberVersionReply(senderKey, now)
    if lastVersionReplyAt[senderKey] == nil then
        if lastVersionReplyCount >= MAX_REPLAY_PLAYERS then
            local oldestKey
            local oldestOrdinal
            for key, replyState in pairs(lastVersionReplyAt) do
                if oldestOrdinal == nil or replyState.Ordinal < oldestOrdinal then
                    oldestKey = key
                    oldestOrdinal = replyState.Ordinal
                end
            end
            if oldestKey then
                lastVersionReplyAt[oldestKey] = nil
                lastVersionReplyCount = lastVersionReplyCount - 1
            end
        end
        lastVersionReplyCount = lastVersionReplyCount + 1
    end
    lastVersionReplyAt[senderKey] = {
        RepliedAt = now,
        Ordinal = NextTransportOrdinal(),
    }
end

local function IsSeen(sessionState, sender, messageId)
    return sessionState.Seen.Entries[sender .. "\0" .. messageId] == true
end

local function ValidateDisplayOrder(playerState, sessionKey, sequence, sentAt)
    local displaySession = playerState.DisplaySessions[sessionKey]
    if displaySession and displaySession.Retired then
        return false, "stale-display-session"
    end
    if playerState.HighestDisplaySentAt ~= nil and sentAt <= playerState.HighestDisplaySentAt then
        return false, "stale-display-timestamp"
    end
    if
        displaySession
        and playerState.ActiveDisplaySessionKey == sessionKey
        and displaySession.HighestSequence ~= nil
        and sequence <= displaySession.HighestSequence
    then
        return false, "stale-display"
    end
    if not displaySession and playerState.DisplaySessionCount >= MAX_DISPLAY_SESSIONS_PER_PLAYER then
        return false, "display-session-capacity"
    end
    return true
end

local function CommitDisplayOrder(playerState, sessionKey, sequence, sentAt)
    local displaySession = playerState.DisplaySessions[sessionKey]
    if playerState.ActiveDisplaySessionKey ~= sessionKey then
        local activeSession = playerState.DisplaySessions[playerState.ActiveDisplaySessionKey]
        if activeSession then
            activeSession.Retired = true
        end

        playerState.DisplayEpoch = playerState.DisplayEpoch + 1
        if not displaySession then
            displaySession = {}
            playerState.DisplaySessions[sessionKey] = displaySession
            playerState.DisplaySessionCount = playerState.DisplaySessionCount + 1
        end
        displaySession.Epoch = playerState.DisplayEpoch
        displaySession.FirstAcceptedOrdinal = NextTransportOrdinal()
        displaySession.Retired = false
        playerState.ActiveDisplaySessionKey = sessionKey
    end

    displaySession.HighestSequence = sequence
    displaySession.LastAcceptedOrdinal = NextTransportOrdinal()
    playerState.HighestDisplaySentAt = sentAt
end

local function SafeCanReceive(self, sender, action)
    if type(self.CanReceiveFrom) ~= "function" then
        return false
    end
    local ok, allowed = pcall(self.CanReceiveFrom, self, sender, action)
    return ok and allowed == true
end

local function SafeCanPublish(self, action)
    if type(self.CanLocalPlayerPublish) ~= "function" then
        return false
    end
    local ok, allowed = pcall(self.CanLocalPlayerPublish, self, action)
    return ok and allowed == true
end

local function IsLocalDisplayAuthority(self)
    if not SafeCanPublish(self, "display") or type(self.IsPlayerRaidLeader) ~= "function" then
        return false
    end
    local ok, isLeader = pcall(self.IsPlayerRaidLeader, self)
    return ok and isLeader == true
end

local function RequiredAction(messageType)
    if messageType == "VERSION_QUERY" or messageType == "VERSION" then
        return "version"
    elseif messageType == "DISPLAY_REQUEST" or messageType == "PAGE_REQUEST" then
        return "request"
    elseif messageType == "DISPLAY" then
        return "display"
    elseif messageType == "PAGE_UPSERT" then
        return "pageUpsert"
    end
end

local function PendingDisplayRequestMatches(record, auth, reference)
    if record.TargetKey ~= NormalizePlayerKey(auth.Sender) then
        return false
    end
    if
        record.SenderInstallationId ~= nil
        and (record.SenderInstallationId ~= auth.SenderInstallationId or record.SenderSessionId ~= auth.SenderSessionId)
    then
        return false
    end
    if record.SyncId ~= nil then
        return reference ~= nil and SameReference(record, reference)
    end
    return true
end

local function PendingPageRequestMatches(record, auth, reference)
    return record.TargetKey == NormalizePlayerKey(auth.Sender)
        and record.SenderInstallationId == auth.SenderInstallationId
        and record.SenderSessionId == auth.SenderSessionId
        and SameReference(record, reference)
end

local function OutboundDisplayMatches(record, auth, reference)
    if not record.Displayed or not SameReference(record, reference) then
        return false
    end
    local senderKey = NormalizePlayerKey(auth.Sender)
    if record.TargetKey ~= nil and record.TargetKey ~= senderKey then
        return false
    end
    if
        record.RecipientInstallationId ~= nil
        and (
            record.RecipientInstallationId ~= auth.SenderInstallationId
            or record.RecipientSessionId ~= auth.SenderSessionId
        )
    then
        return false
    end
    return record.Responders[senderKey] ~= true
end

local function CurrentDisplayThrottleKey(self, auth)
    local reference
    if type(self.GetActiveDisplayReference) == "function" then
        local ok, activeReference = pcall(self.GetActiveDisplayReference, self)
        if ok and IsPlainTable(activeReference) then
            reference = activeReference
        end
    end

    local stateToken
    if reference then
        stateToken = table.concat({
            reference.SyncId or "",
            reference.RevisionId or "",
            reference.ContextRevisionId or "",
        }, "\0")
    else
        local state = IsPlainTable(AngryAssign_State) and AngryAssign_State or nil
        local displayedId = state and rawget(state, "displayed") or nil
        local page = IsPlainTable(AngryAssign_Pages) and AngryAssign_Pages[displayedId] or nil
        if IsPlainTable(page) then
            stateToken = table.concat({
                tostring(displayedId),
                tostring(page.SyncId or ""),
                tostring(page.RevisionId or page.UpdateId or page.Updated or ""),
                tostring(page.CategoryId or ""),
            }, "\0")
        else
            stateToken = "clear"
        end
    end
    return table.concat({
        NormalizePlayerKey(auth.Sender) or "",
        auth.SenderInstallationId,
        auth.SenderSessionId,
        stateToken,
    }, "\0")
end

local function ValidateChannelAndCorrelation(auth, channel, envelope, now)
    CleanupPendingQueries(now)
    CleanupRecords(pendingDisplayRequests, now)
    CleanupRecords(pendingPageRequests, now)
    CleanupRecords(outboundDisplays, now)

    local messageType = envelope.Type
    local replyTo = envelope.ReplyTo
    if messageType == "VERSION_QUERY" then
        if not IsCurrentGroupChannel(channel) then
            return false, "invalid-channel"
        end
        if replyTo ~= nil then
            return false, "unexpected-reply-to"
        end
    elseif messageType == "VERSION" then
        if channel ~= "WHISPER" then
            return false, "invalid-channel"
        end
        local pending = replyTo and pendingQueries[replyTo]
        local senderKey = NormalizePlayerKey(auth.Sender)
        if not pending or pending.Responders[senderKey] then
            return false, "uncorrelated-reply"
        end
    elseif messageType == "DISPLAY_REQUEST" then
        if channel ~= "WHISPER" then
            return false, "invalid-channel"
        end
        if replyTo ~= nil then
            return false, "unexpected-reply-to"
        end
    elseif messageType == "DISPLAY" then
        if IsCurrentGroupChannel(channel) then
            if replyTo ~= nil then
                return false, "unexpected-reply-to"
            end
        elseif channel == "WHISPER" then
            local pending = replyTo and pendingDisplayRequests[replyTo]
            local reference = ReferenceFromPayload(messageType, envelope.Payload)
            if not pending or not PendingDisplayRequestMatches(pending, auth, reference) then
                return false, "uncorrelated-reply"
            end
        else
            return false, "invalid-channel"
        end
    elseif messageType == "PAGE_REQUEST" then
        if channel ~= "WHISPER" then
            return false, "invalid-channel"
        end
        local outbound = replyTo and outboundDisplays[replyTo]
        local reference = ReferenceFromPayload(messageType, envelope.Payload)
        if not outbound or not OutboundDisplayMatches(outbound, auth, reference) then
            return false, "uncorrelated-request"
        end
    elseif messageType == "PAGE_UPSERT" then
        if IsCurrentGroupChannel(channel) then
            if replyTo ~= nil then
                return false, "unexpected-reply-to"
            end
        elseif channel == "WHISPER" then
            local reference = ReferenceFromPayload(messageType, envelope.Payload)
            local displayPending = replyTo and pendingDisplayRequests[replyTo]
            local pagePending = replyTo and pendingPageRequests[replyTo]
            if
                displayPending
                and PendingDisplayRequestMatches(displayPending, auth, reference)
                and not displayPending.PageUpsertReceived
            then
                return true, nil, "display-request", displayPending
            elseif pagePending and PendingPageRequestMatches(pagePending, auth, reference) then
                return true, nil, "page-request", pagePending
            end
            return false, "uncorrelated-reply"
        else
            return false, "invalid-channel"
        end
    end
    return true
end

local function BindDisplayRequest(record, auth, reference)
    record.SenderInstallationId = record.SenderInstallationId or auth.SenderInstallationId
    record.SenderSessionId = record.SenderSessionId or auth.SenderSessionId
    if reference then
        record.SyncId = record.SyncId or reference.SyncId
        record.RevisionId = record.RevisionId or reference.RevisionId
        record.ContextRevisionId = record.ContextRevisionId or reference.ContextRevisionId
    end
end

local function NormalizeTimestamp(timestamp)
    if type(timestamp) ~= "string" or timestamp == "" or timestamp == "dev" then
        return nil
    end
    local number = tonumber(timestamp)
    if not number then
        return nil
    end
    if #timestamp ~= 14 then
        number = tonumber(timestamp:sub(1, 8))
    end
    return number
end

local function MaybeWarnOutOfDate(self, payload)
    if warnedOutOfDate or payload.Flavor ~= ClientFlavor() then
        return
    end
    local localTimestamp = BuildTimestamp()
    local remoteTimestamp = payload.BuildTimestamp
    local localNumber = NormalizeTimestamp(localTimestamp)
    local remoteNumber = NormalizeTimestamp(remoteTimestamp)
    if not localNumber or not remoteNumber then
        return
    end
    if #localTimestamp ~= 14 or #remoteTimestamp ~= 14 then
        localNumber = tonumber(localTimestamp:sub(1, 8))
        remoteNumber = tonumber(remoteTimestamp:sub(1, 8))
    end
    if localNumber and remoteNumber and remoteNumber > localNumber then
        warnedOutOfDate = true
        self:Print(
            "Your version of "
                .. (self.Title or "Angry Era")
                .. " is out of date! Download the latest version from curseforge.com."
        )
    end
end

local function ValidateActiveSendOptions(options)
    if options ~= nil and not IsPlainTable(options) then
        return nil, "invalid-options"
    end
    options = options or {}
    local channel = options.Channel or GroupChannel()
    if channel == "WHISPER" then
        if type(options.Target) ~= "string" or options.Target == "" then
            return nil, "missing-target"
        end
        if type(options.ReplyTo) ~= "string" or options.ReplyTo == "" then
            return nil, "missing-reply-to"
        end
    elseif not IsCurrentGroupChannel(channel) then
        return nil, "invalid-channel"
    elseif options.ReplyTo ~= nil or options.Target ~= nil then
        return nil, "unexpected-correlation"
    end
    return {
        Channel = channel,
        Target = options.Target,
        ReplyTo = options.ReplyTo,
        Priority = options.Priority,
        RecipientInstallationId = options.RecipientInstallationId,
        RecipientSessionId = options.RecipientSessionId,
    }
end

--- Returns the trusted runtime codec used for protocol-v3 packets.
function AngryEra:GetProtocolCodec()
    return protocolCodec
end

--- Starts a fresh ephemeral protocol session and clears transport-bound state.
-- @tparam[opt] string sessionId Injectable session identifier for tests.
-- @treturn boolean ok
-- @treturn string|nil errorCode
function AngryEra:StartProtocolSession(sessionId)
    sessionId = sessionId or GenerateSessionId()
    local session, sessionError = protocol.NewSession(self:GetInstallationId(), sessionId)
    if not session then
        return false, sessionError
    end

    protocolSession = nil
    ResetTransportTables()
    if type(self.ResetActivePageTransientState) == "function" then
        local resetOk = pcall(self.ResetActivePageTransientState, self)
        if not resetOk then
            return false, "active-page-reset-failed"
        end
    end
    if type(self.ResetDisplayPublicationState) == "function" then
        local resetOk = pcall(self.ResetDisplayPublicationState, self)
        if not resetOk then
            return false, "display-publication-reset-failed"
        end
    end

    protocolSession = session
    return true
end

--- Clears discovery, replay, correlation, and active-page state while retaining
-- the current protocol session.
function AngryEra:ResetProtocolPeers()
    ResetTransportTables()
    if type(self.ResetActivePageTransientState) == "function" then
        pcall(self.ResetActivePageTransientState, self)
    end
    if type(self.ResetDisplayPublicationState) == "function" then
        pcall(self.ResetDisplayPublicationState, self)
    end
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
    if options ~= nil and not IsPlainTable(options) then
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

    local sentAt
    local sentAtError
    if messageType == "DISPLAY" then
        sentAt, sentAtError = NextDisplaySentAt()
    else
        sentAt = CurrentEpochMilliseconds()
        sentAtError = sentAt and nil or "invalid-clock"
    end
    if not sentAt then
        return false, sentAtError
    end

    local envelope, envelopeError = protocol.BuildEnvelope(protocolSession, messageType, payload, {
        ReplyTo = options.ReplyTo,
        SentAt = sentAt,
    })
    if not envelope then
        return false, envelopeError
    end

    local encoded, encodeError = protocol.EncodeEnvelope(envelope, protocolCodec)
    if not encoded then
        return false, encodeError
    end

    local prefix = messageType == "DISPLAY" and protocol.DISPLAY_PREFIX or protocol.PREFIX
    local priority = messageType == "DISPLAY" and "ALERT" or options.Priority or "NORMAL"
    local sent = pcall(self.SendCommMessage, self, prefix, encoded, channel, options.Target, priority)
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

    local sent, messageId = self:SendProtocolMessage("VERSION_QUERY", {})
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

--- Whispers an uncorrelated request for the current shared display.
function AngryEra:SendProtocolDisplayRequest(target)
    local targetKey = NormalizePlayerKey(target)
    if not targetKey or not SafeCanReceive(self, target, "request") then
        return false, "invalid-target"
    end
    local sent, messageId = self:SendProtocolMessage("DISPLAY_REQUEST", {}, {
        Channel = "WHISPER",
        Target = EnsureUnitFullName(target),
    })
    if not sent then
        return false, messageId
    end
    local now = Now()
    local remembered, rememberError = RememberInteraction(pendingDisplayRequests, messageId, {
        OwnerKey = targetKey,
        TargetKey = targetKey,
    }, now)
    if not remembered then
        return false, rememberError
    end
    pendingDisplayRequests[messageId].ExpiresAt = now + ACTIVE_PAGE_CORRELATION_TTL_SECONDS
    return true, messageId
end

--- Whispers an exact page request correlated to a received DISPLAY.
function AngryEra:SendProtocolPageRequest(target, displayEnvelope, reference)
    if
        not IsPlainTable(displayEnvelope)
        or displayEnvelope.Type ~= "DISPLAY"
        or displayEnvelope.ReplyTo ~= nil and type(displayEnvelope.ReplyTo) ~= "string"
    then
        return false, "invalid-display-envelope"
    end
    local validEnvelope = protocol.ValidateEnvelope(displayEnvelope)
    local validReference, referenceError = protocol.ValidatePayload("PAGE_REQUEST", reference)
    if not validEnvelope then
        return false, "invalid-display-envelope"
    end
    if not validReference then
        return false, referenceError
    end
    if not displayEnvelope.Payload.Displayed or not SameReference(displayEnvelope.Payload, reference) then
        return false, "display-reference-mismatch"
    end

    local targetKey = NormalizePlayerKey(target)
    if not targetKey or not SafeCanReceive(self, target, "request") then
        return false, "invalid-target"
    end
    local sent, messageId = self:SendProtocolMessage("PAGE_REQUEST", CopyReference(reference), {
        Channel = "WHISPER",
        Target = EnsureUnitFullName(target),
        ReplyTo = displayEnvelope.MessageId,
    })
    if not sent then
        return false, messageId
    end
    local now = Now()
    local remembered, rememberError = RememberInteraction(pendingPageRequests, messageId, {
        OwnerKey = targetKey,
        TargetKey = targetKey,
        SenderInstallationId = displayEnvelope.SenderInstallationId,
        SenderSessionId = displayEnvelope.SenderSessionId,
        SyncId = reference.SyncId,
        RevisionId = reference.RevisionId,
        ContextRevisionId = reference.ContextRevisionId,
        DisplayPayload = {
            Displayed = true,
            SyncId = reference.SyncId,
            RevisionId = reference.RevisionId,
            ContextRevisionId = reference.ContextRevisionId,
        },
    }, now)
    if not remembered then
        return false, rememberError
    end
    pendingPageRequests[messageId].ExpiresAt = now + ACTIVE_PAGE_CORRELATION_TTL_SECONDS
    return true, messageId
end

--- Sends a canonical PAGE_UPSERT as a group publication or correlated whisper.
function AngryEra:SendProtocolPageUpsert(payload, options)
    if not SafeCanPublish(self, "pageUpsert") then
        return false, "unauthorized"
    end
    local safeOptions, optionsError = ValidateActiveSendOptions(options)
    if not safeOptions then
        return false, optionsError
    end
    return self:SendProtocolMessage("PAGE_UPSERT", payload, safeOptions)
end

--- Sends DISPLAY as a group publication or correlated whisper.
-- Sent display references are retained briefly to authenticate PAGE_REQUEST.
function AngryEra:SendProtocolDisplay(payload, options)
    if not SafeCanPublish(self, "display") then
        return false, "unauthorized"
    end
    local safeOptions, optionsError = ValidateActiveSendOptions(options)
    if not safeOptions then
        return false, optionsError
    end
    local sent, messageId = self:SendProtocolMessage("DISPLAY", payload, safeOptions)
    if not sent then
        return false, messageId
    end

    local targetKey = safeOptions.Target and NormalizePlayerKey(safeOptions.Target) or nil
    local ownerKey = targetKey or "*"
    local reference = ReferenceFromPayload("DISPLAY", payload)
    local now = Now()
    local remembered, rememberError = RememberInteraction(outboundDisplays, messageId, {
        OwnerKey = ownerKey,
        TargetKey = targetKey,
        RecipientInstallationId = safeOptions.RecipientInstallationId,
        RecipientSessionId = safeOptions.RecipientSessionId,
        Displayed = payload.Displayed,
        SyncId = reference and reference.SyncId,
        RevisionId = reference and reference.RevisionId,
        ContextRevisionId = reference and reference.ContextRevisionId,
        Responders = {},
        RequestAttempts = {},
    }, now)
    if not remembered then
        return false, rememberError
    end
    outboundDisplays[messageId].ExpiresAt = now + ACTIVE_PAGE_CORRELATION_TTL_SECONDS
    return true, messageId
end

function AngryEra:HandleProtocolVersionQuery(auth, _, envelope)
    local now = Now()
    local senderKey = NormalizePlayerKey(auth.Sender)
    local replyState = senderKey and lastVersionReplyAt[senderKey] or nil
    local repliedAt = replyState and replyState.RepliedAt or nil
    if repliedAt and now - repliedAt < REPLY_THROTTLE_SECONDS then
        return false, "throttled"
    end

    local sent, result = self:SendProtocolVersion(auth.Sender, envelope.MessageId)
    if sent and senderKey then
        RememberVersionReply(senderKey, now)
    end
    return sent, result
end

function AngryEra:HandleProtocolVersion(auth, _, envelope)
    local now = Now()
    CleanupPendingQueries(now)
    local pending = envelope.ReplyTo and pendingQueries[envelope.ReplyTo]
    local senderKey = NormalizePlayerKey(auth.Sender)
    if not pending or pending.Responders[senderKey] then
        return false, "uncorrelated-reply"
    end

    local payload = envelope.Payload
    local localCapabilities = LocalCapabilities()
    local negotiated = protocol.NegotiateCapabilities(localCapabilities, payload.Capabilities)
    local peer = {
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        AddonVersion = payload.AddonVersion,
        BuildTimestamp = payload.BuildTimestamp,
        Flavor = payload.Flavor,
        Capabilities = CopyMap(payload.Capabilities),
        NegotiatedCapabilities = negotiated,
        AcceptsCurrentGroup = payload.AcceptsCurrentGroup,
        LastSeenAt = now,
        ReplyTo = envelope.ReplyTo,
    }
    pending.Responders[senderKey] = CopyPeer(peer)
    local latestQueryOrdinal = peerQueryOrdinals[senderKey]
    if latestQueryOrdinal == nil or pending.CreatedOrdinal > latestQueryOrdinal then
        peers[senderKey] = CopyPeer(peer)
        peerQueryOrdinals[senderKey] = pending.CreatedOrdinal
    end
    MaybeWarnOutOfDate(self, payload)
    return true
end

function AngryEra:HandleProtocolDisplayRequest(auth, _, envelope)
    local now = Now()
    CleanupRecords(displayRequestReplies, now)
    -- Do not let a request received during the roster handoff consume the
    -- leader's post-promotion response throttle.
    if not IsLocalDisplayAuthority(self) then
        return false, "not-display-authority"
    end
    local throttleKey = CurrentDisplayThrottleKey(self, auth)
    if displayRequestReplies[throttleKey] then
        return false, "throttled"
    end
    local remembered, rememberError = RememberInteraction(displayRequestReplies, throttleKey, {
        OwnerKey = NormalizePlayerKey(auth.Sender),
    }, now)
    if not remembered then
        return false, rememberError
    end
    -- A failed response gets only the short retry throttle. Successful
    -- publication below extends this record to suppress duplicate full-page
    -- responses for the same requester session and active tuple.
    displayRequestReplies[throttleKey].ExpiresAt = now + REPLY_THROTTLE_SECONDS

    local plan, planError = self:BuildActiveDisplayRequestResponse(auth, envelope.Payload)
    if not plan then
        return false, planError
    end

    if plan.PageUpsertPayload then
        local pageSent, pageError = self:SendProtocolPageUpsert(plan.PageUpsertPayload, {
            Channel = "WHISPER",
            Target = auth.Sender,
            ReplyTo = envelope.MessageId,
        })
        if not pageSent then
            return false, pageError
        end
    end

    local sent, result = self:SendProtocolDisplay(plan.Payload, {
        Channel = "WHISPER",
        Target = auth.Sender,
        ReplyTo = envelope.MessageId,
        RecipientInstallationId = auth.SenderInstallationId,
        RecipientSessionId = auth.SenderSessionId,
    })
    if sent then
        displayRequestReplies[throttleKey].ExpiresAt = now + INTERACTION_TTL_SECONDS
    end
    return sent, result
end

function AngryEra:HandleProtocolDisplay(auth, _, envelope)
    local accepted, result, warning = self:AcceptActiveDisplay(auth, envelope.Payload)
    if not accepted then
        return false, result
    end

    local requestError
    if result.RequestNeeded then
        local deferred
        if type(self.DeferPendingDisplayRecovery) == "function" then
            local called, scheduled, status =
                pcall(self.DeferPendingDisplayRecovery, self, auth, envelope, result.RequestPayload)
            if called and scheduled then
                deferred = true
                result.RequestDeferred = true
                result.RequestError = status
            end
        end
        if not deferred then
            local requested
            requested, requestError = self:SendProtocolPageRequest(auth.Sender, envelope, result.RequestPayload)
            result.RequestSent = requested == true
            result.RequestError = requestError
        end
    elseif type(self.CancelPendingDisplayRecovery) == "function" then
        pcall(self.CancelPendingDisplayRecovery, self)
    end
    if envelope.ReplyTo ~= nil then
        local pending = pendingDisplayRequests[envelope.ReplyTo]
        if pending then
            BindDisplayRequest(pending, auth, ReferenceFromPayload("DISPLAY", envelope.Payload))
            pending.DisplayReceived = true
            if not envelope.Payload.Displayed or pending.PageUpsertReceived then
                pendingDisplayRequests[envelope.ReplyTo] = nil
            end
        end
    end
    result.UIWarning = warning
    return true, result, requestError or warning
end

function AngryEra:HandleProtocolPageRequest(auth, _, envelope)
    local now = Now()
    local outbound = outboundDisplays[envelope.ReplyTo]
    local senderKey = NormalizePlayerKey(auth.Sender)
    local attempts = outbound and outbound.RequestAttempts
    if not IsPlainTable(attempts) or not senderKey then
        return false, "missing-page-request-state"
    end
    local attemptedAt = attempts[senderKey]
    if attemptedAt and now - attemptedAt < REPLY_THROTTLE_SECONDS then
        return false, "throttled"
    end
    attempts[senderKey] = now

    local plan, planError = self:BuildActivePageRequestResponse(auth, envelope.Payload)
    if not plan then
        return false, planError
    end
    local sent, result = self:SendProtocolPageUpsert(plan.Payload, {
        Channel = "WHISPER",
        Target = auth.Sender,
        ReplyTo = envelope.MessageId,
    })
    if sent then
        if outbound then
            outbound.Responders[senderKey] = true
        end
    end
    return sent, result
end

function AngryEra:HandleProtocolPageUpsert(auth, channel, envelope)
    local accepted
    local result
    local warning
    if channel == "WHISPER" then
        accepted, result, warning = self:AcceptActivePageUpsert(auth, envelope.Payload, {
            CorrelatedReply = true,
        })
    else
        accepted, result, warning = self:AcceptActivePageUpsert(auth, envelope.Payload)
    end
    if not accepted then
        return false, result
    end

    local reference = ReferenceFromPayload("PAGE_UPSERT", envelope.Payload)
    if envelope.ReplyTo ~= nil then
        local displayPending = pendingDisplayRequests[envelope.ReplyTo]
        if displayPending then
            BindDisplayRequest(displayPending, auth, reference)
            displayPending.PageUpsertReceived = true
            if displayPending.DisplayReceived then
                pendingDisplayRequests[envelope.ReplyTo] = nil
            end
        elseif pendingPageRequests[envelope.ReplyTo] then
            pendingPageRequests[envelope.ReplyTo] = nil
        end
    end

    local displayWarning
    if result.PendingDisplayReady and result.PendingDisplayPayload then
        local displayAccepted, displayResult, completionWarning =
            self:AcceptActiveDisplay(auth, result.PendingDisplayPayload)
        if displayAccepted then
            result.CompletedDisplay = displayResult
            displayWarning = completionWarning
            if type(self.CancelPendingDisplayRecovery) == "function" then
                pcall(self.CancelPendingDisplayRecovery, self)
            end
        else
            result.DisplayCompletionError = displayResult
            displayWarning = displayResult
        end
    end
    result.UIWarning = warning
    return true, result, displayWarning or warning
end

HANDLERS = {
    VERSION_QUERY = "HandleProtocolVersionQuery",
    VERSION = "HandleProtocolVersion",
    DISPLAY_REQUEST = "HandleProtocolDisplayRequest",
    DISPLAY = "HandleProtocolDisplay",
    PAGE_REQUEST = "HandleProtocolPageRequest",
    PAGE_UPSERT = "HandleProtocolPageUpsert",
}

--- Dispatches a validated, authorized, non-duplicate envelope.
function AngryEra:DispatchProtocolMessage(auth, channel, envelope)
    local handlerName = HANDLERS[envelope.Type]
    local handler = handlerName and self[handlerName]
    if not handler then
        return false, "unknown-message-type"
    end
    return handler(self, auth, channel, envelope)
end

--- Receives, authenticates, correlates, deduplicates, and dispatches protocol v3.
function AngryEra:ReceiveProtocolMessage(prefix, data, channel, sender)
    if (prefix ~= protocol.PREFIX and prefix ~= protocol.DISPLAY_PREFIX) or type(sender) ~= "string" then
        return false, "invalid-transport"
    end

    sender = EnsureUnitFullName(sender)
    if not sender or NormalizePlayerKey(sender) == NormalizePlayerKey(PlayerFullName()) then
        return false, "invalid-sender"
    end
    if type(self.GetGroupRole) ~= "function" then
        return false, "unauthorized"
    end
    local roleOk, role = pcall(self.GetGroupRole, self, sender)
    if not roleOk or role == "absent" then
        return false, "unauthorized"
    end

    local envelope, decodeError = protocol.DecodeEnvelope(data, protocolCodec)
    if not envelope then
        return false, decodeError
    end
    if
        (envelope.Type == "DISPLAY" and prefix ~= protocol.DISPLAY_PREFIX)
        or (envelope.Type ~= "DISPLAY" and prefix ~= protocol.PREFIX)
    then
        return false, "invalid-transport-message-type"
    end

    local now = Now()
    local auth = BuildAuth(sender, envelope, now)
    local channelValid, channelError = ValidateChannelAndCorrelation(auth, channel, envelope, now)
    if not channelValid then
        return false, channelError
    end

    local action = RequiredAction(envelope.Type)
    if not action or not SafeCanReceive(self, sender, action) then
        return false, "unauthorized"
    end
    if envelope.Type == "DISPLAY" and not ValidateDisplayTimestamp(envelope.SentAt) then
        return false, "invalid-display-timestamp"
    end

    local replayState, replayError, replayPlayer, replaySessionKey = GetReplayState(auth, true)
    if not replayState then
        return false, replayError
    end
    if envelope.Type == "DISPLAY" then
        local displayOrderValid, displayOrderError =
            ValidateDisplayOrder(replayPlayer, replaySessionKey, envelope.Sequence, envelope.SentAt)
        if not displayOrderValid and displayOrderError == "stale-display-session" then
            return false, displayOrderError
        end
    end
    if IsSeen(replayState, sender, envelope.MessageId) then
        return false, "duplicate"
    end
    if envelope.Type == "DISPLAY" then
        local displayOrderValid, displayOrderError =
            ValidateDisplayOrder(replayPlayer, replaySessionKey, envelope.Sequence, envelope.SentAt)
        if not displayOrderValid then
            return false, displayOrderError
        end
    end

    local duplicate, seenError = protocol.SeenOrRemember(replayState.Seen, sender, envelope.MessageId)
    if duplicate == nil then
        return false, seenError
    end
    if duplicate then
        return false, "duplicate"
    end

    local accepted, result, warning = self:DispatchProtocolMessage(auth, channel, envelope)
    if accepted and envelope.Type == "DISPLAY" then
        CommitDisplayOrder(replayPlayer, replaySessionKey, envelope.Sequence, envelope.SentAt)
    end
    return accepted, result, warning
end

--- Returns discovery metadata for an authenticated player.
-- With queryMessageId, returns only the response captured for that exact query.
function AngryEra:GetProtocolPeer(player, queryMessageId)
    local key = NormalizePlayerKey(player)
    if queryMessageId ~= nil then
        if type(queryMessageId) ~= "string" then
            return nil
        end
        CleanupPendingQueries(Now())
        local pending = pendingQueries[queryMessageId]
        local peer = key and pending and pending.Responders[key] or nil
        return CopyPeer(peer)
    end
    return CopyPeer(key and peers[key])
end

function AngryEra:GetPeerCapabilities(player)
    local peer = self:GetProtocolPeer(player)
    return peer and CopyMap(peer.Capabilities)
end

function AngryEra:PeerSupports(player, capability, minimumVersion)
    local peer = self:GetProtocolPeer(player)
    return peer and protocol.Supports(peer.NegotiatedCapabilities, capability, minimumVersion) or false
end

--- Removes peer and transport records for players no longer in the group.
function AngryEra:PruneProtocolPeers()
    for key, peer in pairs(peers) do
        if self:GetGroupRole(peer.Sender) == "absent" then
            peers[key] = nil
            peerQueryOrdinals[key] = nil
        end
    end
    for key in pairs(replayPlayers) do
        if self:GetGroupRole(key) == "absent" then
            replayPlayers[key] = nil
        end
    end
    for key in pairs(lastVersionReplyAt) do
        if self:GetGroupRole(key) == "absent" then
            lastVersionReplyAt[key] = nil
            lastVersionReplyCount = lastVersionReplyCount - 1
        end
    end
    replayPlayerCount = 0
    for _ in pairs(replayPlayers) do
        replayPlayerCount = replayPlayerCount + 1
    end
end
