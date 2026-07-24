-- -------------------------------------------------------------------------------
-- Angry Era: modules/protocol_runtime.lua
--
-- Runtime session, authenticated transport, discovery, and active-page routing
-- for protocol v3.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local protocol = AngryEra.utils.protocol
local boundedDeflate = AngryEra.utils.boundedDeflate
local helpers = AngryEra.utils.helpers
local revisions = AngryEra.sync and AngryEra.sync.revisions
local EnsureUnitFullName = helpers.EnsureUnitFullName
local PlayerFullName = helpers.PlayerFullName

if not boundedDeflate or type(boundedDeflate.DecompressZlib) ~= "function" then
    error("AngryEra bounded DEFLATE utilities must load before protocol runtime")
end
if not revisions or type(revisions.CreateFCS32Callback) ~= "function" then
    error("AngryEra synchronization revisions must load before protocol runtime")
end

local libS = app.libs.libS
local libC = app.libs.libC
local libD = app.libs.libD
local core = AngryEra.core
local compactPageHash = revisions.CreateFCS32Callback(libC)

if type(compactPageHash) ~= "function" then
    error("AngryEra compact-page hashing is unavailable")
end

local QUERY_TTL_SECONDS = 20
local INTERACTION_TTL_SECONDS = 20
local ACTIVE_PAGE_CORRELATION_TTL_SECONDS = 15 * 60
local QUERY_THROTTLE_SECONDS = core.updateFrequency or 2
local REPLY_THROTTLE_SECONDS = core.updateFrequency or 2
-- Keep the exact display tuple available beyond the normal 30-second
-- promised-page watchdog so a late omitted context can recover immediately.
local PENDING_DISPLAY_CONTEXT_TTL_SECONDS = math.max((core.updateFrequency or 2) * 20, 60)
local MAX_PENDING_QUERIES = 32
local MAX_PENDING_INTERACTIONS = 64
local MAX_PENDING_PER_PLAYER = 8
local MAX_REPLAY_PLAYERS = 64
local MAX_REPLAY_SESSIONS_PER_PLAYER = 4
local MAX_SEEN_PER_SESSION = 64
local MAX_DISPLAY_SESSIONS_PER_PLAYER = 64
local MAX_ACTIVE_PAGE_COMPLETION_WAITERS = 32
local MAX_RETIRED_DISPLAY_AUTHORITIES = 64
local TIMESTAMP_MILLISECONDS_PER_SECOND = 1000
local DISPLAY_TIMESTAMP_MAX_AGE_SECONDS = 5 * 60
local DISPLAY_TIMESTAMP_MAX_FUTURE_SECONDS = 10
local CHANGE_PROPOSAL_MAX_AGE_SECONDS = INTERACTION_TTL_SECONDS
local MINIMUM_PLAUSIBLE_SERVER_EPOCH = 1000000000
local MAX_SAFE_INTEGER = 9007199254740991
local ACECOMM_SINGLE_BYTES = 255
local ACECOMM_MULTIPART_BYTES = 254
local ACECOMM_FIRST = "\001"
local ACECOMM_NEXT = "\002"
local ACECOMM_LAST = "\003"
local ACECOMM_ESCAPE = "\004"

local protocolSession
local boundDisplayAuthority
local localLeadershipTenureActive = false
local peers = {}
local peerQueryOrdinals = {}
local pendingQueries = {}
local pendingDisplayRequests = {}
local pendingPageRequests = {}
local pendingChangeProposals = {}
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
local activePageTransfer
local activePageTransferGeneration = 0
local activePageOutstandingFrame
local proposalFailureAnnouncements = {}
local proposalFailureAnnouncementCount = 0
local retiredDisplayAuthorities = {}
local retiredDisplayAuthorityCount = 0
local retiredDisplayAuthorityOrdinal = 0
local displayAuthoritySignals = {}
local displayAuthoritySignalCount = 0
local displayAuthoritySignalOrdinal = 0
local pendingDisplayAuthorityEventBoundary
local ancestorContexts = {
    Inbound = {},
    InboundAmbiguous = {},
    InboundBytes = 0,
    InboundCount = 0,
    InboundOrdinal = 0,
    InboundSessions = {},
    MaxGlobalBytes = 1024 * 1024,
    MaxGlobalEntries = 64,
    MaxSessionBytes = 256 * 1024,
    MaxSessionEntries = 16,
    MaxMissHints = 32,
    MaxOutboundBytes = 512 * 1024,
    MaxOutboundEntries = 32,
    MissHints = {},
    MissHintCount = 0,
    MissHintOrdinal = 0,
    MissHintTtl = INTERACTION_TTL_SECONDS,
    Outbound = {},
    OutboundAmbiguous = {},
    OutboundBytes = 0,
    OutboundCount = 0,
    OutboundEpoch = 0,
    OutboundOrdinal = 0,
    PendingDisplayTtl = PENDING_DISPLAY_CONTEXT_TTL_SECONDS,
}

local HANDLERS
local CancelActivePageTransfer

local function Now()
    return time()
end

local function PreciseNowMilliseconds()
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
    return math.floor(value * TIMESTAMP_MILLISECONDS_PER_SECOND)
end

local function Trace(self, stage, formatText, ...)
    local callback = self and self.SyncDebug
    if type(callback) == "function" then
        callback(self, stage, formatText, ...)
    end
end

local function IsDebugEnabled(self)
    local callback = self and self.IsSyncDebugEnabled
    return type(callback) == "function" and callback(self) == true
end

local function DiagnosticInteger(value)
    if type(value) ~= "number" then
        return "-"
    end
    return tostring(math.floor(value))
end

local function ChatThrottleDebugSnapshot()
    local snapshot = {
        AlertAvailable = "-",
        AlertPipes = "-",
        Available = "-",
        Choking = "-",
        FrameRate = "-",
        QueueStates = "-",
    }
    local getFrameRate = rawget(_G, "GetFramerate")
    if type(getFrameRate) == "function" then
        local ok, value = pcall(getFrameRate)
        if ok and type(value) == "number" and value >= 0 then
            snapshot.FrameRate = tostring(math.floor(value + 0.5))
        end
    end

    local activeQueues = {}
    local throttle = rawget(_G, "ChatThrottleLib")
    if type(throttle) == "table" then
        snapshot.Available = DiagnosticInteger(throttle.avail)
        snapshot.Bypass = type(throttle.nBypass) == "number" and throttle.nBypass or nil
        snapshot.Choking = type(throttle.bChoking) == "boolean" and tostring(throttle.bChoking) or "-"
        local priorities = throttle.Prio
        if type(priorities) == "table" then
            local totalSent = 0
            local hasTotalSent = false
            for _, priority in ipairs({ "ALERT", "NORMAL", "BULK" }) do
                local state = priorities[priority]
                if type(state) == "table" then
                    if type(state.nTotalSent) == "number" then
                        totalSent = totalSent + state.nTotalSent
                        hasTotalSent = true
                    end
                    if priority == "ALERT" then
                        snapshot.AlertAvailable = DiagnosticInteger(state.avail)
                        snapshot.AlertTotalSent = type(state.nTotalSent) == "number" and state.nTotalSent or nil
                        if type(state.ByName) == "table" then
                            local pipes = 0
                            for _ in pairs(state.ByName) do
                                pipes = pipes + 1
                            end
                            snapshot.AlertPipes = tostring(pipes)
                        end
                    end

                    local states = {}
                    if type(state.Ring) == "table" and state.Ring.pos ~= nil then
                        states[#states + 1] = "ring"
                    end
                    if type(state.Blocked) == "table" and state.Blocked.pos ~= nil then
                        states[#states + 1] = "blocked"
                    end
                    if #states > 0 then
                        activeQueues[#activeQueues + 1] = priority .. ":" .. table.concat(states, "+")
                    end
                end
            end
            snapshot.TotalSent = hasTotalSent and totalSent or nil
        end
    end

    snapshot.QueueStates = #activeQueues > 0 and table.concat(activeQueues, ",") or "-"
    return snapshot
end

local function CounterDelta(before, after)
    if type(before) ~= "number" or type(after) ~= "number" then
        return "-"
    end
    return tostring(math.floor(after - before))
end

local function ActivePagePayloadDebugAnatomy(payload)
    local page = type(payload) == "table" and payload.Page or nil
    local layers = type(payload) == "table" and payload.AncestorVariableLayers or nil
    local contentsBytes = type(page) == "table" and type(page.Contents) == "string" and #page.Contents or 0
    local pageVarsBytes = type(page) == "table" and type(page.Vars) == "string" and #page.Vars or 0
    local ancestorVarsBytes = 0
    local layerCount = 0
    if type(layers) == "table" then
        for _, layer in ipairs(layers) do
            layerCount = layerCount + 1
            if type(layer) == "table" and type(layer.Vars) == "string" then
                ancestorVarsBytes = ancestorVarsBytes + #layer.Vars
            end
        end
    end
    return contentsBytes, pageVarsBytes, ancestorVarsBytes, layerCount
end

local function IsActivePageMessage(messageType)
    return messageType == "DISPLAY"
        or messageType == "PAGE_UPSERT"
        or messageType == "PAGE_REQUEST"
        or messageType == "DISPLAY_REQUEST"
        or messageType == "CHANGE_PROPOSE"
        or messageType == "CHANGE_RESULT"
end

local function DebugReference(messageType, payload)
    if type(payload) ~= "table" then
        return "-", "-", "-"
    end
    local reference = messageType == "PAGE_UPSERT" and payload.Page or payload
    if type(reference) ~= "table" then
        return "-", "-", "-"
    end
    return tostring(reference.SyncId or "-"),
        tostring(reference.RevisionId or reference.BaseRevisionId or "-"),
        tostring(payload.ContextRevisionId or payload.BaseContextRevisionId or reference.ContextRevisionId or "-")
end

local function EncodedChunkCount(encodedBytes)
    if encodedBytes <= ACECOMM_SINGLE_BYTES then
        return 1
    end
    return math.ceil(encodedBytes / ACECOMM_MULTIPART_BYTES)
end

local function ActivePageFramePlan(encoded)
    local encodedBytes = #encoded
    local startsWithControl = encoded:match("^[\001-\009]") ~= nil
    if encodedBytes <= ACECOMM_SINGLE_BYTES and not startsWithControl then
        return 1, false, false
    end
    if encodedBytes + 1 <= ACECOMM_SINGLE_BYTES and startsWithControl then
        return 1, false, true
    end
    return math.ceil(encodedBytes / ACECOMM_MULTIPART_BYTES), true, false
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

local function ValidateChangeProposalTimestamp(sentAt)
    local seconds = CurrentEpochSeconds()
    if not seconds then
        return false
    end
    local sentSeconds = math.floor(sentAt / TIMESTAMP_MILLISECONDS_PER_SECOND)
    return sentSeconds >= seconds - CHANGE_PROPOSAL_MAX_AGE_SECONDS
        and sentSeconds <= seconds + DISPLAY_TIMESTAMP_MAX_FUTURE_SECONDS
end

local function NormalizePlayerKey(player)
    local fullName = EnsureUnitFullName(player)
    return fullName and fullName:lower()
end

function ancestorContexts:CopyLayers(layers)
    if not IsPlainTable(layers) then
        return nil
    end
    local copy = {}
    for index = 1, #layers do
        local layer = layers[index]
        if not IsPlainTable(layer) or type(layer.SyncId) ~= "string" or type(layer.Vars) ~= "string" then
            return nil
        end
        copy[index] = {
            SyncId = layer.SyncId,
            Vars = layer.Vars,
        }
    end
    return copy
end

function ancestorContexts:LayersEqual(left, right)
    if not IsPlainTable(left) or not IsPlainTable(right) or #left ~= #right then
        return false
    end
    for index = 1, #left do
        local leftLayer = left[index]
        local rightLayer = right[index]
        if
            not IsPlainTable(leftLayer)
            or not IsPlainTable(rightLayer)
            or leftLayer.SyncId ~= rightLayer.SyncId
            or leftLayer.Vars ~= rightLayer.Vars
        then
            return false
        end
    end
    return true
end

function ancestorContexts:LayerCost(layers)
    local bytes = 64
    for index = 1, #layers do
        local layer = layers[index]
        bytes = bytes + 64 + #layer.SyncId + #layer.Vars
    end
    return bytes
end

function ancestorContexts:CopyReference(reference)
    if not IsPlainTable(reference) then
        return nil
    end
    return {
        SyncId = reference.SyncId,
        Revision = reference.Revision,
        RevisionId = reference.RevisionId,
        ContextRevisionId = reference.ContextRevisionId,
    }
end

function ancestorContexts:Identity(sender, installationId, sessionId, contextId)
    local senderKey = NormalizePlayerKey(sender)
    if
        type(senderKey) ~= "string"
        or type(installationId) ~= "string"
        or type(sessionId) ~= "string"
        or type(contextId) ~= "string"
    then
        return nil
    end
    local sessionKey = table.concat({
        tostring(#senderKey),
        ":",
        senderKey,
        tostring(#installationId),
        ":",
        installationId,
        tostring(#sessionId),
        ":",
        sessionId,
    })
    return senderKey, sessionKey, sessionKey .. tostring(#contextId) .. ":" .. contextId
end

function ancestorContexts:NextInboundOrdinal()
    self.InboundOrdinal = self.InboundOrdinal + 1
    return self.InboundOrdinal
end

function ancestorContexts:RemoveInbound(key)
    local entry = self.Inbound[key]
    if not entry then
        return false
    end
    self.Inbound[key] = nil
    self.InboundCount = self.InboundCount - 1
    self.InboundBytes = self.InboundBytes - entry.Cost
    local session = self.InboundSessions[entry.SessionKey]
    if session then
        session.Count = session.Count - 1
        session.Bytes = session.Bytes - entry.Cost
        if session.Count <= 0 then
            self.InboundSessions[entry.SessionKey] = nil
        end
    end
    return true
end

function ancestorContexts:OldestInbound(sessionKey)
    local oldestKey
    local oldestEntry
    for key, entry in pairs(self.Inbound) do
        if
            (sessionKey == nil or entry.SessionKey == sessionKey)
            and (
                oldestEntry == nil
                or entry.LastUsedOrdinal < oldestEntry.LastUsedOrdinal
                or (entry.LastUsedOrdinal == oldestEntry.LastUsedOrdinal and key < oldestKey)
            )
        then
            oldestKey = key
            oldestEntry = entry
        end
    end
    return oldestKey
end

function ancestorContexts:TrimAmbiguous(records, maximum)
    local count = 0
    for _ in pairs(records) do
        count = count + 1
    end
    while count > (maximum or self.MaxGlobalEntries) do
        local oldestKey
        local oldest
        for key, record in pairs(records) do
            if
                oldest == nil
                or record.Ordinal < oldest.Ordinal
                or (record.Ordinal == oldest.Ordinal and key < oldestKey)
            then
                oldestKey = key
                oldest = record
            end
        end
        if not oldestKey then
            break
        end
        records[oldestKey] = nil
        count = count - 1
    end
end

function ancestorContexts:MarkInboundAmbiguous(key, senderKey)
    self:RemoveInbound(key)
    self.InboundAmbiguous[key] = {
        Ordinal = self:NextInboundOrdinal(),
        SenderKey = senderKey,
    }
    self:TrimAmbiguous(self.InboundAmbiguous)
end

function ancestorContexts:StoreInbound(sender, installationId, sessionId, contextId, layers)
    local senderKey, sessionKey, key = self:Identity(sender, installationId, sessionId, contextId)
    local safeLayers = self:CopyLayers(layers)
    if not key or not safeLayers or self.InboundAmbiguous[key] then
        return false
    end

    local existing = self.Inbound[key]
    if existing then
        if not self:LayersEqual(existing.Layers, safeLayers) then
            self:MarkInboundAmbiguous(key, senderKey)
            return false
        end
        existing.LastUsedOrdinal = self:NextInboundOrdinal()
        return true
    end

    local cost = self:LayerCost(safeLayers)
    if cost > self.MaxSessionBytes or cost > self.MaxGlobalBytes then
        return false
    end
    local session = self.InboundSessions[sessionKey]
    if not session then
        session = {
            Bytes = 0,
            Count = 0,
        }
        self.InboundSessions[sessionKey] = session
    end
    while session.Count >= self.MaxSessionEntries or session.Bytes + cost > self.MaxSessionBytes do
        local oldestKey = self:OldestInbound(sessionKey)
        if not oldestKey then
            return false
        end
        self:RemoveInbound(oldestKey)
        session = self.InboundSessions[sessionKey] or {
            Bytes = 0,
            Count = 0,
        }
        self.InboundSessions[sessionKey] = session
    end
    while self.InboundCount >= self.MaxGlobalEntries or self.InboundBytes + cost > self.MaxGlobalBytes do
        local oldestKey = self:OldestInbound()
        if not oldestKey then
            return false
        end
        self:RemoveInbound(oldestKey)
    end

    local ordinal = self:NextInboundOrdinal()
    self.Inbound[key] = {
        ContextId = contextId,
        Cost = cost,
        InstallationId = installationId,
        LastUsedOrdinal = ordinal,
        Layers = safeLayers,
        Sender = EnsureUnitFullName(sender),
        SenderKey = senderKey,
        SessionId = sessionId,
        SessionKey = sessionKey,
    }
    session = self.InboundSessions[sessionKey] or {
        Bytes = 0,
        Count = 0,
    }
    self.InboundSessions[sessionKey] = session
    session.Count = session.Count + 1
    session.Bytes = session.Bytes + cost
    self.InboundCount = self.InboundCount + 1
    self.InboundBytes = self.InboundBytes + cost
    return true
end

function ancestorContexts:ResolveInbound(sender, installationId, sessionId, contextId)
    local _, _, key = self:Identity(sender, installationId, sessionId, contextId)
    if not key or self.InboundAmbiguous[key] then
        return nil
    end
    local entry = self.Inbound[key]
    return entry and self:CopyLayers(entry.Layers) or nil
end

function ancestorContexts:TouchInbound(sender, installationId, sessionId, contextId)
    local _, _, key = self:Identity(sender, installationId, sessionId, contextId)
    local entry = key and self.Inbound[key] or nil
    if not entry or self.InboundAmbiguous[key] then
        return false
    end
    entry.LastUsedOrdinal = self:NextInboundOrdinal()
    return true
end

function ancestorContexts:ResetInbound()
    self.Inbound = {}
    self.InboundAmbiguous = {}
    self.InboundBytes = 0
    self.InboundCount = 0
    self.InboundOrdinal = 0
    self.InboundSessions = {}
end

function ancestorContexts:NextOutboundOrdinal()
    self.OutboundOrdinal = self.OutboundOrdinal + 1
    return self.OutboundOrdinal
end

function ancestorContexts:RemoveOutbound(contextId)
    local entry = self.Outbound[contextId]
    if not entry then
        return false
    end
    self.Outbound[contextId] = nil
    self.OutboundCount = self.OutboundCount - 1
    self.OutboundBytes = self.OutboundBytes - entry.Cost
    return true
end

function ancestorContexts:OldestOutbound()
    local oldestId
    local oldest
    for contextId, entry in pairs(self.Outbound) do
        if
            oldest == nil
            or entry.LastUsedOrdinal < oldest.LastUsedOrdinal
            or (entry.LastUsedOrdinal == oldest.LastUsedOrdinal and contextId < oldestId)
        then
            oldestId = contextId
            oldest = entry
        end
    end
    return oldestId
end

function ancestorContexts:IsOutboundAnnounced(contextId, layers)
    if self.OutboundAmbiguous[contextId] then
        return false
    end
    local entry = self.Outbound[contextId]
    if not entry then
        return false
    end
    if not self:LayersEqual(entry.Layers, layers) then
        self:RemoveOutbound(contextId)
        self.OutboundAmbiguous[contextId] = {
            Ordinal = self:NextOutboundOrdinal(),
        }
        self:TrimAmbiguous(self.OutboundAmbiguous, self.MaxOutboundEntries)
        return false
    end
    return true
end

function ancestorContexts:RememberOutbound(contextId, layers)
    if self.OutboundAmbiguous[contextId] then
        return false
    end
    local safeLayers = self:CopyLayers(layers)
    if not safeLayers or #safeLayers == 0 then
        return false
    end
    local existing = self.Outbound[contextId]
    if existing then
        if not self:LayersEqual(existing.Layers, safeLayers) then
            self:RemoveOutbound(contextId)
            self.OutboundAmbiguous[contextId] = {
                Ordinal = self:NextOutboundOrdinal(),
            }
            self:TrimAmbiguous(self.OutboundAmbiguous, self.MaxOutboundEntries)
            return false
        end
        existing.LastUsedOrdinal = self:NextOutboundOrdinal()
        return true
    end

    local cost = self:LayerCost(safeLayers)
    if cost > self.MaxOutboundBytes then
        return false
    end
    while self.OutboundCount >= self.MaxOutboundEntries or self.OutboundBytes + cost > self.MaxOutboundBytes do
        local oldestId = self:OldestOutbound()
        if not oldestId then
            return false
        end
        self:RemoveOutbound(oldestId)
    end
    self.Outbound[contextId] = {
        Cost = cost,
        LastUsedOrdinal = self:NextOutboundOrdinal(),
        Layers = safeLayers,
    }
    self.OutboundCount = self.OutboundCount + 1
    self.OutboundBytes = self.OutboundBytes + cost
    return true
end

function ancestorContexts:TouchOutbound(contextId, layers)
    if not self:IsOutboundAnnounced(contextId, layers) then
        return false
    end
    self.Outbound[contextId].LastUsedOrdinal = self:NextOutboundOrdinal()
    return true
end

function ancestorContexts:ResetOutbound()
    self.Outbound = {}
    self.OutboundAmbiguous = {}
    self.OutboundBytes = 0
    self.OutboundCount = 0
    self.OutboundEpoch = self.OutboundEpoch + 1
    self.OutboundOrdinal = 0
end

function ancestorContexts:ResetMissState()
    self.MissHints = {}
    self.MissHintCount = 0
    self.MissHintOrdinal = 0
    self.PendingDisplay = nil
end

function ancestorContexts:ResetAll()
    self:ResetInbound()
    self:ResetOutbound()
    self:ResetMissState()
end

function ancestorContexts:PruneInbound(selfAddon)
    for key, entry in pairs(self.Inbound) do
        if selfAddon:GetGroupRole(entry.Sender) == "absent" then
            self:RemoveInbound(key)
        end
    end
    for key, record in pairs(self.InboundAmbiguous) do
        if selfAddon:GetGroupRole(record.SenderKey) == "absent" then
            self.InboundAmbiguous[key] = nil
        end
    end
end

function ancestorContexts:ReferenceIdentity(sender, installationId, sessionId, reference, contextId)
    if
        not IsPlainTable(reference)
        or type(reference.SyncId) ~= "string"
        or type(reference.Revision) ~= "number"
        or type(reference.RevisionId) ~= "string"
        or type(reference.ContextRevisionId) ~= "string"
    then
        return nil
    end
    local senderKey, sessionKey = self:Identity(sender, installationId, sessionId, contextId or "")
    if not sessionKey then
        return nil
    end
    local tupleKey = table.concat({
        sessionKey,
        tostring(#reference.SyncId),
        ":",
        reference.SyncId,
        tostring(#tostring(reference.Revision)),
        ":",
        tostring(reference.Revision),
        tostring(#reference.RevisionId),
        ":",
        reference.RevisionId,
        tostring(#reference.ContextRevisionId),
        ":",
        reference.ContextRevisionId,
    })
    local hintKey = contextId and (tupleKey .. tostring(#contextId) .. ":" .. contextId) or nil
    return senderKey, tupleKey, hintKey
end

function ancestorContexts:CleanupMissHints(now)
    for key, record in pairs(self.MissHints) do
        if record.ExpiresAt <= now then
            self.MissHints[key] = nil
            self.MissHintCount = self.MissHintCount - 1
        end
    end
    local pending = self.PendingDisplay
    if pending and pending.ExpiresAt <= now then
        self.PendingDisplay = nil
    end
end

function ancestorContexts:OldestMissHint()
    local oldestKey
    local oldest
    for key, record in pairs(self.MissHints) do
        if
            oldest == nil
            or record.Ordinal < oldest.Ordinal
            or (record.Ordinal == oldest.Ordinal and key < oldestKey)
        then
            oldestKey = key
            oldest = record
        end
    end
    return oldestKey
end

function ancestorContexts:ValidateMissMetadata(sender, metadata)
    if
        not IsPlainTable(metadata)
        or metadata.AncestorContextIncluded ~= false
        or type(metadata.AncestorContextId) ~= "string"
        or metadata.AncestorContextId == ""
        or type(metadata.SenderInstallationId) ~= "string"
        or type(metadata.SenderSessionId) ~= "string"
        or type(metadata.MessageId) ~= "string"
        or metadata.ReplyTo ~= nil
        or not IsPlainTable(metadata.Reference)
    then
        return nil
    end
    local validReference = protocol.ValidatePayload("PAGE_REQUEST", metadata.Reference)
    if not validReference then
        return nil
    end
    local senderKey, tupleKey, hintKey = self:ReferenceIdentity(
        sender,
        metadata.SenderInstallationId,
        metadata.SenderSessionId,
        metadata.Reference,
        metadata.AncestorContextId
    )
    if not hintKey then
        return nil
    end
    return {
        AncestorContextId = metadata.AncestorContextId,
        HintKey = hintKey,
        InstallationId = metadata.SenderInstallationId,
        MessageId = metadata.MessageId,
        Reference = self:CopyReference(metadata.Reference),
        Sender = EnsureUnitFullName(sender),
        SenderKey = senderKey,
        SessionId = metadata.SenderSessionId,
        TupleKey = tupleKey,
    }
end

function ancestorContexts:RememberMissHint(sender, metadata, now)
    self:CleanupMissHints(now)
    local record = self:ValidateMissMetadata(sender, metadata)
    if not record then
        return false
    end
    self.MissHintOrdinal = self.MissHintOrdinal + 1
    record.ExpiresAt = now + self.MissHintTtl
    record.Ordinal = self.MissHintOrdinal
    if self.MissHints[record.HintKey] then
        self.MissHints[record.HintKey] = record
        return true
    end
    while self.MissHintCount >= self.MaxMissHints do
        local oldestKey = self:OldestMissHint()
        if not oldestKey then
            return false
        end
        self.MissHints[oldestKey] = nil
        self.MissHintCount = self.MissHintCount - 1
    end
    self.MissHints[record.HintKey] = record
    self.MissHintCount = self.MissHintCount + 1
    return true
end

function ancestorContexts:ConsumeMissHints(sender, installationId, sessionId, reference, now)
    self:CleanupMissHints(now)
    local _, tupleKey = self:ReferenceIdentity(sender, installationId, sessionId, reference)
    if not tupleKey then
        return false
    end
    local found = false
    for key, record in pairs(self.MissHints) do
        if record.TupleKey == tupleKey then
            self.MissHints[key] = nil
            self.MissHintCount = self.MissHintCount - 1
            found = true
        end
    end
    return found
end

function ancestorContexts:SetPendingDisplay(auth, envelope, reference, now)
    local senderKey, tupleKey =
        self:ReferenceIdentity(auth.Sender, auth.SenderInstallationId, auth.SenderSessionId, reference)
    if not tupleKey then
        self.PendingDisplay = nil
        return nil
    end
    local record = {
        Auth = {
            Sender = EnsureUnitFullName(auth.Sender),
            SenderInstallationId = auth.SenderInstallationId,
            SenderSessionId = auth.SenderSessionId,
        },
        Envelope = envelope,
        ExpiresAt = now + self.PendingDisplayTtl,
        Reference = self:CopyReference(reference),
        RequestAttempted = false,
        SenderKey = senderKey,
        TupleKey = tupleKey,
    }
    self.PendingDisplay = record
    return record
end

function ancestorContexts:PendingMatchesMetadata(sender, metadata, now)
    self:CleanupMissHints(now)
    local safeMetadata = self:ValidateMissMetadata(sender, metadata)
    local pending = self.PendingDisplay
    return safeMetadata and pending and safeMetadata.TupleKey == pending.TupleKey and pending or nil
end

function ancestorContexts:ClearPendingForPage(auth, reference)
    local _, tupleKey = self:ReferenceIdentity(auth.Sender, auth.SenderInstallationId, auth.SenderSessionId, reference)
    if self.PendingDisplay and tupleKey == self.PendingDisplay.TupleKey then
        self.PendingDisplay = nil
    end
    self:ConsumeMissHints(auth.Sender, auth.SenderInstallationId, auth.SenderSessionId, reference, Now())
end

function ancestorContexts:PruneMissState(selfAddon)
    for key, record in pairs(self.MissHints) do
        if selfAddon:GetGroupRole(record.Sender) == "absent" then
            self.MissHints[key] = nil
            self.MissHintCount = self.MissHintCount - 1
        end
    end
    local pending = self.PendingDisplay
    if pending and selfAddon:GetGroupRole(pending.Auth.Sender) == "absent" then
        self.PendingDisplay = nil
    end
end

function ancestorContexts:DebugMetadata(metadata, inbound)
    if not IsPlainTable(metadata) then
        return "-", "-", "-", "-"
    end
    local included = metadata.AncestorContextIncluded
    local source = "-"
    if included == true then
        source = "inline"
    elseif included == false then
        source = inbound and "cache" or "announced"
    end
    return metadata.AncestorContextId or "-",
        source,
        included == nil and "-" or tostring(included),
        metadata.AncestorContextBytes == nil and "-" or tostring(metadata.AncestorContextBytes)
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
        Revision = source.Revision,
        RevisionId = source.RevisionId,
        ContextRevisionId = source.ContextRevisionId,
    }
end

local function SameReference(left, right)
    return IsPlainTable(left)
        and IsPlainTable(right)
        and left.SyncId == right.SyncId
        and left.Revision == right.Revision
        and left.RevisionId == right.RevisionId
        and left.ContextRevisionId == right.ContextRevisionId
end

local function ReferenceFromPayload(messageType, payload)
    if messageType == "PAGE_UPSERT" then
        return {
            SyncId = payload.Page.SyncId,
            Revision = payload.Page.Revision,
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

local function ActivePageChangeHandlersLive()
    local required = {
        "BuildActivePageChangeProposal",
        "ApplyActivePageChangeProposal",
        "HandleProtocolChangePropose",
        "HandleProtocolChangeResult",
        "SendProtocolChangeProposal",
        "SendProtocolChangeResult",
    }
    for _, name in ipairs(required) do
        if type(AngryEra[name]) ~= "function" then
            return false
        end
    end
    return HANDLERS ~= nil
        and HANDLERS.CHANGE_PROPOSE ~= nil
        and HANDLERS.CHANGE_RESULT ~= nil
end

local function LocalCapabilities()
    if ActivePageHandlersLive() then
        local capabilities = {
            activePage = 1,
        }
        if ActivePageChangeHandlersLive() then
            capabilities[protocol.ACTIVE_PAGE_CHANGES_CAPABILITY] =
                protocol.ACTIVE_PAGE_CHANGES_CAPABILITY_VERSION
        end
        return capabilities
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

local compactPageCodec = {
    compress = function(value)
        return libD:CompressZlib(value)
    end,
    decompress = function(value, maximumOutputBytes)
        local output, trailingBytesOrError = boundedDeflate.DecompressZlib(value, maximumOutputBytes)
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
    hash = compactPageHash,
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

local function ResetTransportTables(preserveRetiredDisplayAuthorities)
    if CancelActivePageTransfer then
        CancelActivePageTransfer("reset")
    end
    peers = {}
    peerQueryOrdinals = {}
    pendingQueries = {}
    pendingDisplayRequests = {}
    pendingPageRequests = {}
    pendingChangeProposals = {}
    outboundDisplays = {}
    displayRequestReplies = {}
    replayPlayers = {}
    replayPlayerCount = 0
    lastVersionReplyAt = {}
    lastVersionReplyCount = 0
    lastQueryAt = nil
    transportOrdinal = 0
    proposalFailureAnnouncements = {}
    proposalFailureAnnouncementCount = 0
    pendingDisplayAuthorityEventBoundary = nil
    if preserveRetiredDisplayAuthorities ~= true then
        retiredDisplayAuthorities = {}
        retiredDisplayAuthorityCount = 0
        retiredDisplayAuthorityOrdinal = 0
        displayAuthoritySignals = {}
        displayAuthoritySignalCount = 0
        displayAuthoritySignalOrdinal = 0
    end
    ancestorContexts:ResetAll()
    boundDisplayAuthority = nil
end

local function DisplayAuthorityIdentityKey(authority)
    if not IsPlainTable(authority) then
        return nil
    end
    local playerKey = authority.PlayerKey or NormalizePlayerKey(authority.Sender)
    if
        type(playerKey) ~= "string"
        or type(authority.SenderInstallationId) ~= "string"
        or type(authority.SenderSessionId) ~= "string"
    then
        return nil
    end
    return table.concat({
        playerKey,
        authority.SenderInstallationId,
        authority.SenderSessionId,
    }, "\0")
end

local function RetireDisplayAuthority(authority)
    local key = DisplayAuthorityIdentityKey(authority)
    if not key then
        return false
    end
    retiredDisplayAuthorityOrdinal = retiredDisplayAuthorityOrdinal + 1
    if retiredDisplayAuthorities[key] then
        retiredDisplayAuthorities[key].Ordinal = retiredDisplayAuthorityOrdinal
        return true
    end
    if retiredDisplayAuthorityCount >= MAX_RETIRED_DISPLAY_AUTHORITIES then
        local oldestKey
        local oldestOrdinal
        for candidateKey, record in pairs(retiredDisplayAuthorities) do
            if oldestOrdinal == nil or record.Ordinal < oldestOrdinal then
                oldestKey = candidateKey
                oldestOrdinal = record.Ordinal
            end
        end
        if oldestKey then
            retiredDisplayAuthorities[oldestKey] = nil
            retiredDisplayAuthorityCount = retiredDisplayAuthorityCount - 1
        end
    end
    retiredDisplayAuthorities[key] = {
        Ordinal = retiredDisplayAuthorityOrdinal,
    }
    retiredDisplayAuthorityCount = retiredDisplayAuthorityCount + 1
    return true
end

local function IsRetiredDisplayAuthority(authority)
    local key = DisplayAuthorityIdentityKey(authority)
    return key ~= nil and retiredDisplayAuthorities[key] ~= nil
end

local function MarkPendingDisplayAuthorityEventBoundary(authority, now)
    local identityKey = DisplayAuthorityIdentityKey(authority)
    if not identityKey then
        return false
    end
    pendingDisplayAuthorityEventBoundary = {
        ExpiresAt = now + INTERACTION_TTL_SECONDS,
        IdentityKey = identityKey,
    }
    return true
end

local function ConsumePendingDisplayAuthorityEventBoundary(authority, now)
    local pending = pendingDisplayAuthorityEventBoundary
    if not pending then
        return false
    end
    if pending.ExpiresAt < now then
        pendingDisplayAuthorityEventBoundary = nil
        return false
    end
    if pending.IdentityKey ~= DisplayAuthorityIdentityKey(authority) then
        return false
    end
    pendingDisplayAuthorityEventBoundary = nil
    return true
end

local function ObserveDisplayAuthoritySignal(authority)
    local playerKey = NormalizePlayerKey(authority and authority.Sender)
    local sentAt = authority and authority.SentAt
    if not playerKey or type(sentAt) ~= "number" then
        return false
    end
    local existing = displayAuthoritySignals[playerKey]
    if existing and sentAt < existing.SentAt then
        return false
    end
    displayAuthoritySignalOrdinal = displayAuthoritySignalOrdinal + 1
    if not existing and displayAuthoritySignalCount >= MAX_RETIRED_DISPLAY_AUTHORITIES then
        local oldestKey
        local oldestOrdinal
        for candidateKey, record in pairs(displayAuthoritySignals) do
            if oldestOrdinal == nil or record.Ordinal < oldestOrdinal then
                oldestKey = candidateKey
                oldestOrdinal = record.Ordinal
            end
        end
        if oldestKey then
            displayAuthoritySignals[oldestKey] = nil
            displayAuthoritySignalCount = displayAuthoritySignalCount - 1
        end
    end
    if not existing then
        displayAuthoritySignalCount = displayAuthoritySignalCount + 1
    end
    displayAuthoritySignals[playerKey] = {
        IdentityKey = DisplayAuthorityIdentityKey(authority),
        Ordinal = displayAuthoritySignalOrdinal,
        SentAt = sentAt,
    }
    return true
end

local function IsStaleDisplayAuthoritySignal(authority)
    local playerKey = NormalizePlayerKey(authority and authority.Sender)
    local sentAt = authority and authority.SentAt
    local observed = playerKey and displayAuthoritySignals[playerKey] or nil
    return observed ~= nil
        and type(sentAt) == "number"
        and observed.IdentityKey ~= DisplayAuthorityIdentityKey(authority)
        and sentAt < observed.SentAt
end

local function ResetLeaderBoundInteractions(preservedDisplayRequests, retireBoundAuthority)
    if type(preservedDisplayRequests) ~= "table" then
        preservedDisplayRequests = {}
    end
    if retireBoundAuthority then
        RetireDisplayAuthority(boundDisplayAuthority)
    end
    pendingDisplayRequests = {}
    for messageId, pending in pairs(preservedDisplayRequests) do
        pendingDisplayRequests[messageId] = pending
    end
    pendingPageRequests = {}
    pendingChangeProposals = {}
    outboundDisplays = {}
    displayRequestReplies = {}
    ancestorContexts:ResetMissState()
    boundDisplayAuthority = nil
end

local function BuildAuth(sender, envelope, receivedAt)
    return {
        Sender = sender,
        SenderInstallationId = envelope.SenderInstallationId,
        SenderSessionId = envelope.SenderSessionId,
        SentAt = envelope.SentAt,
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

local LEADER_TENURE_MESSAGE_TYPES = {
    DISPLAY = true,
    PAGE_UPSERT = true,
    CHANGE_RESULT = true,
}

local function DisplayAuthorityMatches(auth)
    return IsPlainTable(boundDisplayAuthority)
        and boundDisplayAuthority.PlayerKey == NormalizePlayerKey(auth.Sender)
        and boundDisplayAuthority.SenderInstallationId == auth.SenderInstallationId
        and boundDisplayAuthority.SenderSessionId == auth.SenderSessionId
end

local function BindDisplayAuthority(auth)
    if boundDisplayAuthority and not DisplayAuthorityMatches(auth) then
        RetireDisplayAuthority(boundDisplayAuthority)
    end
    boundDisplayAuthority = {
        PlayerKey = NormalizePlayerKey(auth.Sender),
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        SignalSentAt = auth.SentAt,
    }
    ObserveDisplayAuthoritySignal(auth)
end

local function PendingDisplayAuthorityBootstraps(auth, now)
    local senderKey = NormalizePlayerKey(auth.Sender)
    CleanupRecords(pendingDisplayRequests, now)
    local preserved = {}
    local exactSession = false
    local targetOnly = false
    for messageId, pending in pairs(pendingDisplayRequests) do
        if
            pending.TargetKey == senderKey
            and pending.SenderInstallationId == auth.SenderInstallationId
            and pending.SenderSessionId == auth.SenderSessionId
        then
            preserved[messageId] = pending
            exactSession = true
        elseif
            pending.TargetKey == senderKey
            and pending.SenderInstallationId == nil
        then
            preserved[messageId] = pending
            targetOnly = true
        end
    end
    return preserved, exactSession, targetOnly
end

local function PendingCurrentLeaderBootstraps(self, now, excludedAuthority)
    CleanupRecords(pendingDisplayRequests, now)
    local preserved = {}
    local count = 0
    local excludedAuthorityKey = DisplayAuthorityIdentityKey(excludedAuthority)
    for messageId, pending in pairs(pendingDisplayRequests) do
        local target = pending.Target or pending.TargetKey
        local pendingAuthority = pending.SenderInstallationId ~= nil
            and {
                Sender = target,
                SenderInstallationId = pending.SenderInstallationId,
                SenderSessionId = pending.SenderSessionId,
            }
            or nil
        local retired = pendingAuthority and IsRetiredDisplayAuthority(pendingAuthority)
        local excluded = pendingAuthority
            and excludedAuthorityKey ~= nil
            and DisplayAuthorityIdentityKey(pendingAuthority) == excludedAuthorityKey
        if target and not retired and not excluded and SafeCanReceive(self, target, "display") then
            preserved[messageId] = pending
            count = count + 1
        end
    end
    return preserved, count
end

local function ResetSharedProposalForAuthorityChange(self)
    if type(self.CancelPendingDisplayRecovery) == "function" then
        pcall(self.CancelPendingDisplayRecovery, self)
    end
    if type(self.ResetSharedPageChangeState) == "function" then
        pcall(self.ResetSharedPageChangeState, self, "authority-session-change")
    elseif type(self.ResetDisplayPublicationState) == "function" then
        pcall(self.ResetDisplayPublicationState, self)
    end
end

-- VERSION_QUERY is the first authenticated signal emitted by a leader after an
-- addon reload. A follower bound to that same player's retired session must
-- discard every old leader-bound correlation and issue a request that only the
-- announced installation/session may satisfy.
local function RefreshDisplayAuthorityFromVersionQuery(self, auth)
    if
        IsLocalDisplayAuthority(self)
        or not SafeCanReceive(self, auth.Sender, "display")
        or DisplayAuthorityMatches(auth)
    then
        return false
    end

    local now = Now()
    local preserved, exactSession, targetOnly = PendingDisplayAuthorityBootstraps(auth, now)
    if exactSession and not targetOnly and boundDisplayAuthority == nil then
        return false
    end

    if next(preserved) ~= nil then
        ResetLeaderBoundInteractions(preserved, boundDisplayAuthority ~= nil)
        for _, pending in pairs(preserved) do
            pending.SenderInstallationId = auth.SenderInstallationId
            pending.SenderSessionId = auth.SenderSessionId
        end
        MarkPendingDisplayAuthorityEventBoundary(auth, now)
        ResetSharedProposalForAuthorityChange(self)
        return true
    end

    ResetLeaderBoundInteractions({}, boundDisplayAuthority ~= nil)
    ResetSharedProposalForAuthorityChange(self)
    local requested
    local messageId
    if type(self.SendRequestDisplay) == "function" then
        local called
        called, requested, messageId = pcall(self.SendRequestDisplay, self)
        if not called then
            return false
        end
    elseif type(self.SendProtocolDisplayRequest) == "function" then
        local called
        called, requested, messageId = pcall(self.SendProtocolDisplayRequest, self, auth.Sender)
        if not called then
            return false
        end
    end
    if requested ~= true then
        return false
    end

    local pending = pendingDisplayRequests[messageId]
    if pending then
        pending.SenderInstallationId = auth.SenderInstallationId
        pending.SenderSessionId = auth.SenderSessionId
    end
    MarkPendingDisplayAuthorityEventBoundary(auth, now)
    return true
end

-- Followers accept leader-authored mutable state only from the installation
-- and session proven by a correlated DISPLAY_REQUEST reply. This closes the
-- A -> B -> A handoff window where delayed packets from A's former tenure
-- would otherwise become role-authorized again after A is re-promoted.
local function ValidateDisplayAuthorityTenure(self, auth, envelope, correlationKind)
    if not LEADER_TENURE_MESSAGE_TYPES[envelope.Type] or IsLocalDisplayAuthority(self) then
        return true, nil, false
    end
    if DisplayAuthorityMatches(auth) then
        return true, nil, false
    end
    if IsRetiredDisplayAuthority(auth) then
        return false, "stale-display-authority"
    end
    if
        correlationKind == "display-request"
        and (envelope.Type == "DISPLAY" or envelope.Type == "PAGE_UPSERT")
    then
        return true, nil, true
    end
    if boundDisplayAuthority ~= nil then
        return false, "stale-display-authority"
    end
    return false, "unbound-display-authority"
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
    elseif messageType == "CHANGE_PROPOSE" then
        return "changeProposal"
    elseif messageType == "CHANGE_RESULT" then
        return "changeResult"
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
            tostring(reference.Revision or ""),
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
    CleanupRecords(pendingChangeProposals, now)
    CleanupRecords(outboundDisplays, now)

    local messageType = envelope.Type
    local replyTo = envelope.ReplyTo
    local correlationKind
    local correlationRecord
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
            correlationKind = "display-request"
            correlationRecord = pending
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
                correlationKind = "display-request"
                correlationRecord = displayPending
            elseif pagePending and PendingPageRequestMatches(pagePending, auth, reference) then
                correlationKind = "page-request"
                correlationRecord = pagePending
            else
                return false, "uncorrelated-reply"
            end
        else
            return false, "invalid-channel"
        end
    elseif messageType == "CHANGE_PROPOSE" then
        if channel ~= "WHISPER" then
            return false, "invalid-channel"
        end
        if replyTo ~= nil then
            return false, "unexpected-reply-to"
        end
    elseif messageType == "CHANGE_RESULT" then
        if channel ~= "WHISPER" then
            return false, "invalid-channel"
        end
        local pending = replyTo and pendingChangeProposals[replyTo]
        if not pending or pending.TargetKey ~= NormalizePlayerKey(auth.Sender) then
            return false, "uncorrelated-reply"
        end
        if
            pending.SenderInstallationId ~= nil
            and (
                pending.SenderInstallationId ~= auth.SenderInstallationId
                or pending.SenderSessionId ~= auth.SenderSessionId
            )
        then
            return false, "uncorrelated-reply"
        end
    end
    return true, nil, correlationKind, correlationRecord
end

local function BindDisplayRequest(record, auth, reference)
    record.SenderInstallationId = record.SenderInstallationId or auth.SenderInstallationId
    record.SenderSessionId = record.SenderSessionId or auth.SenderSessionId
    if reference then
        record.SyncId = record.SyncId or reference.SyncId
        record.Revision = record.Revision or reference.Revision
        record.RevisionId = record.RevisionId or reference.RevisionId
        record.ContextRevisionId = record.ContextRevisionId or reference.ContextRevisionId
    end
end

local function InvalidatePendingDisplayRequestsForAuthority(auth, reference)
    local senderKey = NormalizePlayerKey(auth.Sender)
    CleanupRecords(pendingDisplayRequests, Now())
    for messageId, pending in pairs(pendingDisplayRequests) do
        if pending.TargetKey == senderKey then
            if pending.SenderInstallationId == nil then
                pendingDisplayRequests[messageId] = nil
            elseif
                pending.SenderInstallationId == auth.SenderInstallationId
                and pending.SenderSessionId == auth.SenderSessionId
                and (
                    pending.SyncId == nil
                    or reference == nil
                    or not SameReference(pending, reference)
                )
            then
                pendingDisplayRequests[messageId] = nil
            end
        end
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
    boundDisplayAuthority = nil
    localLeadershipTenureActive = IsLocalDisplayAuthority(self)
    return true
end

--- Reconciles the local protocol session with the current leadership tenure.
-- Promotion rotates to a fresh session without discarding the retained active
-- page/context cache; demotion immediately retires queued leader publication.
-- Followers also clear their accepted leader session so only a newly
-- correlated DISPLAY_REQUEST response can bind the next authority epoch.
-- @tparam[opt] string sessionId Injectable promoted-tenure identifier for tests.
-- @tparam[opt=false] boolean forceLocalRotation Treat this callback as a hard
-- local leadership-tenure boundary even if an intervening demotion event was
-- coalesced before the roster API exposed it.
-- @treturn boolean ok
-- @treturn table|string resultOrError
function AngryEra:RefreshProtocolLeadershipTenure(sessionId, forceLocalRotation)
    if not protocolSession then
        return false, "session-not-started"
    end

    local isLocalAuthority = IsLocalDisplayAuthority(self)
    if
        not isLocalAuthority
        and forceLocalRotation == true
        and boundDisplayAuthority ~= nil
        and SafeCanReceive(self, boundDisplayAuthority.Sender, "display")
        and ConsumePendingDisplayAuthorityEventBoundary(boundDisplayAuthority, Now())
    then
        if localLeadershipTenureActive and CancelActivePageTransfer then
            CancelActivePageTransfer("leadership-lost")
        end
        localLeadershipTenureActive = false
        return true, {
            AlreadyBound = true,
            LocalAuthority = false,
            PendingDisplayBootstrap = true,
            Rotated = false,
        }
    end
    local preservedDisplayRequests = {}
    local preservedDisplayRequestCount = 0
    if not isLocalAuthority then
        local excludedAuthority = forceLocalRotation == true and boundDisplayAuthority or nil
        preservedDisplayRequests, preservedDisplayRequestCount =
            PendingCurrentLeaderBootstraps(self, Now(), excludedAuthority)
    end
    local retireBoundAuthority = boundDisplayAuthority ~= nil
        and (
            forceLocalRotation == true
            or not SafeCanReceive(self, boundDisplayAuthority.Sender, "display")
        )
    ResetLeaderBoundInteractions(preservedDisplayRequests, retireBoundAuthority)
    if not isLocalAuthority then
        ResetSharedProposalForAuthorityChange(self)
        if localLeadershipTenureActive and CancelActivePageTransfer then
            CancelActivePageTransfer("leadership-lost")
        end
        localLeadershipTenureActive = false
        return true, {
            LocalAuthority = false,
            Rotated = false,
            PendingDisplayBootstrap = preservedDisplayRequestCount > 0,
        }
    end
    if localLeadershipTenureActive and forceLocalRotation ~= true then
        return true, {
            LocalAuthority = true,
            Rotated = false,
            SessionId = protocolSession.SessionId,
        }
    end

    local nextSession, sessionError =
        protocol.NewSession(protocolSession.InstallationId, sessionId or GenerateSessionId())
    if not nextSession then
        return false, sessionError
    end
    protocolSession = nextSession
    ResetTransportTables(true)
    if type(self.ResetDisplayPublicationState) == "function" then
        local resetOk = pcall(self.ResetDisplayPublicationState, self)
        if not resetOk then
            return false, "display-publication-reset-failed"
        end
    end
    localLeadershipTenureActive = true
    return true, {
        LocalAuthority = true,
        Rotated = true,
        SessionId = protocolSession.SessionId,
    }
end

--- Clears discovery, replay, correlation, and active-page state while retaining
-- the current protocol session.
function AngryEra:ResetProtocolPeers()
    ResetTransportTables()
    localLeadershipTenureActive = false
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

--- Returns a detached follower-side binding for the current leader tenure.
function AngryEra:GetProtocolDisplayAuthority()
    return IsPlainTable(boundDisplayAuthority) and CopyMap(boundDisplayAuthority) or nil
end

local function PrepareProtocolPacket(messageType, payload, options, compactPageOptions)
    if not protocolSession then
        return nil, "session-not-started"
    end
    if options ~= nil and not IsPlainTable(options) then
        return nil, "invalid-options"
    end
    options = options or {}

    local channel = options.Channel or GroupChannel()
    if not channel then
        return nil, "no-channel"
    end
    if channel == "WHISPER" and (type(options.Target) ~= "string" or options.Target == "") then
        return nil, "missing-target"
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
        return nil, sentAtError
    end

    local envelope, envelopeError = protocol.BuildEnvelope(protocolSession, messageType, payload, {
        ReplyTo = options.ReplyTo,
        SentAt = sentAt,
    })
    if not envelope then
        return nil, envelopeError
    end

    local encoded
    local encodeError
    local compactPageMetadata
    if messageType == "DISPLAY" then
        encoded, encodeError = protocol.EncodeCompactDisplayEnvelope(envelope, protocolCodec)
    elseif messageType == "PAGE_UPSERT" then
        encoded, encodeError, compactPageMetadata =
            protocol.EncodeCompactPageEnvelope(envelope, compactPageCodec, compactPageOptions or {
                IncludeAncestorContext = true,
            })
    else
        encoded, encodeError = protocol.EncodeEnvelope(envelope, protocolCodec)
    end
    if not encoded then
        return nil, encodeError
    end

    return {
        Channel = channel,
        Encoded = encoded,
        Envelope = envelope,
        CompactPageMetadata = compactPageMetadata,
        Prefix = messageType == "DISPLAY" and protocol.DISPLAY_PREFIX
            or (messageType == "PAGE_UPSERT" and protocol.PAGE_PREFIX or protocol.PREFIX),
        Priority = messageType == "DISPLAY" and "ALERT" or options.Priority or "NORMAL",
        Target = options.Target,
    }
end

local function ProtocolSendDebugCallback(state, sentBytes, totalBytes, sendResult)
    if not state or type(sentBytes) ~= "number" or type(totalBytes) ~= "number" then
        return
    end

    local now = PreciseNowMilliseconds()
    if not state.Started then
        state.Started = true
        Trace(
            state.Self,
            "tx-start",
            "type=%s id=%s channel=%s target=%s queue=%dms bytes=%d chunks=%d",
            state.Type,
            state.MessageId,
            state.Channel,
            state.Target or "-",
            math.max(now - state.QueuedAt, 0),
            state.Bytes,
            state.Chunks
        )
    end
    if not state.Completed and sentBytes >= totalBytes then
        state.Completed = true
        Trace(
            state.Self,
            "tx-done",
            "type=%s id=%s channel=%s target=%s drain=%dms bytes=%d result=%s",
            state.Type,
            state.MessageId,
            state.Channel,
            state.Target or "-",
            math.max(now - state.QueuedAt, 0),
            state.Bytes,
            tostring(sendResult)
        )
    end
end

--- Sends one encoded protocol-v3 envelope through AceComm.
-- @treturn boolean ok
-- @treturn string messageIdOrError
function AngryEra:SendProtocolMessage(messageType, payload, options)
    local packet, packetError = PrepareProtocolPacket(messageType, payload, options)
    if not packet then
        return false, packetError
    end

    local debugState
    local debugCallback
    if IsActivePageMessage(messageType) and IsDebugEnabled(self) then
        local encodedBytes = #packet.Encoded
        local syncId, revisionId, contextRevisionId = DebugReference(messageType, payload)
        local ancestorId, ancestorSource, ancestorIncluded, ancestorBytes =
            ancestorContexts:DebugMetadata(packet.CompactPageMetadata, false)
        Trace(
            self,
            "tx-submit",
            "type=%s id=%s seq=%d sentAt=%s sync=%s rev=%s ctx=%s prefix=%s channel=%s target=%s replyTo=%s bytes=%d chunks=%d ancestorId=%s ancestorSource=%s ancestorIncluded=%s ancestorBytes=%s",
            messageType,
            packet.Envelope.MessageId,
            packet.Envelope.Sequence,
            tostring(packet.Envelope.SentAt),
            syncId,
            revisionId,
            contextRevisionId,
            packet.Prefix,
            packet.Channel,
            packet.Target or "-",
            packet.Envelope.ReplyTo or "-",
            encodedBytes,
            EncodedChunkCount(encodedBytes),
            ancestorId,
            ancestorSource,
            ancestorIncluded,
            ancestorBytes
        )
        debugState = {
            Bytes = encodedBytes,
            Channel = packet.Channel,
            Chunks = EncodedChunkCount(encodedBytes),
            MessageId = packet.Envelope.MessageId,
            QueuedAt = PreciseNowMilliseconds(),
            Self = self,
            Target = packet.Target,
            Type = messageType,
        }
        debugCallback = ProtocolSendDebugCallback
    end

    local sent = pcall(
        self.SendCommMessage,
        self,
        packet.Prefix,
        packet.Encoded,
        packet.Channel,
        packet.Target,
        packet.Priority,
        debugCallback,
        debugState
    )
    if not sent then
        return false, "send-failed"
    end
    return true, packet.Envelope.MessageId
end

local function FinishActivePageTransfer(state, succeeded, status)
    if not state or state.Finished then
        return
    end
    state.Finished = true
    state.Succeeded = succeeded == true
    state.Status = status
    if activePageTransfer == state then
        activePageTransfer = nil
    end
    if
        succeeded
        and state.AncestorContextId
        and state.AncestorContextLayers
        and state.AncestorContextEpoch == ancestorContexts.OutboundEpoch
    then
        if state.AncestorContextIncluded then
            ancestorContexts:RememberOutbound(state.AncestorContextId, state.AncestorContextLayers)
        else
            ancestorContexts:TouchOutbound(state.AncestorContextId, state.AncestorContextLayers)
        end
    end

    if state.Debug then
        local elapsed = math.max(PreciseNowMilliseconds() - state.QueuedAt, 0)
        local throughput = elapsed > 0 and tostring(math.floor((state.Bytes * 1000 / elapsed) + 0.5)) or "-"
        local throttle = ChatThrottleDebugSnapshot()
        local submittedThrottle = state.ThrottleAtSubmit or {}
        Trace(
            state.Self,
            succeeded and "page-stream-done" or "page-stream-stop",
            "id=%s generation=%d chunks=%d/%d elapsed=%dms gapMax=%dms bps=%s ctlSentDelta=%s ctlAlertSentDelta=%s ctlBypassDelta=%s status=%s",
            state.MessageId,
            state.Generation,
            state.SentChunks,
            state.TotalChunks,
            elapsed,
            state.MaxCallbackGap or 0,
            throughput,
            CounterDelta(submittedThrottle.TotalSent, throttle.TotalSent),
            CounterDelta(submittedThrottle.AlertTotalSent, throttle.AlertTotalSent),
            CounterDelta(submittedThrottle.Bypass, throttle.Bypass),
            tostring(status)
        )
    end

    local waiters = state.Waiters
    state.Waiters = nil
    for _, waiter in ipairs(waiters or {}) do
        pcall(waiter.Callback, waiter.CallbackArg, succeeded == true, status, state.MessageId)
    end
end

local function AddActivePageTransferWaiter(state, callback, callbackArg)
    if callback == nil then
        return true
    end
    local waiters = state.Waiters
    if #waiters >= MAX_ACTIVE_PAGE_COMPLETION_WAITERS then
        return false, "active-page-waiter-capacity"
    end
    waiters[#waiters + 1] = {
        Callback = callback,
        CallbackArg = callbackArg,
    }
    return true
end

local function ActivePageTransferMatches(state, reference, options)
    return state
        and not state.Finished
        and SameReference(state.Reference, reference)
        and state.Channel == options.Channel
        and state.Target == options.Target
end

CancelActivePageTransfer = function(reason)
    activePageTransferGeneration = activePageTransferGeneration + 1
    local state = activePageTransfer
    if not state then
        return false, "idle"
    end
    FinishActivePageTransfer(state, false, reason or "canceled")
    return true, reason or "canceled"
end

local QueueActivePageChunk

local function ActivePageChunkSent(frameState, didSend, sendResult)
    if not frameState or activePageOutstandingFrame ~= frameState then
        return
    end
    activePageOutstandingFrame = nil

    local state = frameState.Transfer
    if
        not state
        or state.Finished
        or state ~= activePageTransfer
        or state.Generation ~= activePageTransferGeneration
    then
        local latest = activePageTransfer
        if latest and not latest.Finished then
            QueueActivePageChunk(latest)
        end
        return
    end

    if state.Debug then
        local callbackAt = PreciseNowMilliseconds()
        local previousCallbackAt = state.LastCallbackAt or state.QueuedAt
        state.MaxCallbackGap = math.max(state.MaxCallbackGap or 0, callbackAt - previousCallbackAt, 0)
        state.LastCallbackAt = callbackAt
    end
    if didSend ~= true then
        FinishActivePageTransfer(state, false, "send-failed:" .. tostring(sendResult))
        return
    end
    if not SafeCanPublish(state.Self, "display") or not SafeCanPublish(state.Self, "pageUpsert") then
        FinishActivePageTransfer(state, false, "unauthorized")
        return
    end
    state.SentChunks = state.Index

    if state.Debug and not state.Started then
        state.Started = true
        Trace(
            state.Self,
            "page-stream-start",
            "id=%s generation=%d queue=%dms bytes=%d chunks=%d",
            state.MessageId,
            state.Generation,
            math.max(PreciseNowMilliseconds() - state.QueuedAt, 0),
            state.Bytes,
            state.TotalChunks
        )
    end

    if state.Index >= state.TotalChunks then
        FinishActivePageTransfer(state, true, "sent")
        return
    end
    state.Index = state.Index + 1
    QueueActivePageChunk(state)
end

QueueActivePageChunk = function(state)
    if not state or state.Finished then
        return false
    end
    if state ~= activePageTransfer or state.Generation ~= activePageTransferGeneration then
        FinishActivePageTransfer(state, false, "superseded")
        return false
    end
    if not SafeCanPublish(state.Self, "display") or not SafeCanPublish(state.Self, "pageUpsert") then
        FinishActivePageTransfer(state, false, "unauthorized")
        return false
    end
    if activePageOutstandingFrame then
        return true
    end

    local encoded = state.Encoded
    local frame
    if not state.Multipart then
        frame = state.EscapeSingle and (ACECOMM_ESCAPE .. encoded) or encoded
    else
        local firstByte = (state.Index - 1) * ACECOMM_MULTIPART_BYTES + 1
        local lastByte = math.min(firstByte + ACECOMM_MULTIPART_BYTES - 1, #encoded)
        local marker = state.Index == 1 and ACECOMM_FIRST
            or (state.Index == state.TotalChunks and ACECOMM_LAST or ACECOMM_NEXT)
        frame = marker .. encoded:sub(firstByte, lastByte)
    end

    local throttle = rawget(_G, "ChatThrottleLib")
    if type(throttle) ~= "table" or type(throttle.SendAddonMessage) ~= "function" then
        FinishActivePageTransfer(state, false, "chat-throttle-unavailable")
        return false
    end
    local frameState = {
        Transfer = state,
    }
    activePageOutstandingFrame = frameState
    local queued = pcall(
        throttle.SendAddonMessage,
        throttle,
        "ALERT",
        state.Prefix,
        frame,
        state.Channel,
        state.Target,
        state.Prefix,
        ActivePageChunkSent,
        frameState
    )
    if not queued and activePageOutstandingFrame == frameState then
        activePageOutstandingFrame = nil
        if not state.Finished then
            FinishActivePageTransfer(state, false, "send-failed")
        end
        local latest = activePageTransfer
        if latest and latest ~= state and not latest.Finished then
            QueueActivePageChunk(latest)
        end
        return false
    end
    return queued
end

--- Stops production of the current proactive active-page transfer.
-- At most one already-enqueued ChatThrottleLib frame may still drain.
-- @tparam[opt="canceled"] string reason
-- @treturn boolean canceled
-- @treturn string status
function AngryEra:CancelProtocolActivePageTransfer(reason)
    return CancelActivePageTransfer(reason)
end

--- Clears proactive ancestor announcements after a group-authority transition.
-- The active transfer is canceled so an inline context from the former
-- publication epoch cannot complete after the reset.
function AngryEra:ResetProtocolAncestorAnnouncements()
    CancelActivePageTransfer("ancestor-context-reset")
    ancestorContexts:ResetOutbound()
    ancestorContexts:ResetMissState()
    return true
end

--- Broadcasts a proactive PAGE_UPSERT through the replaceable active-page lane.
-- Standard AceComm multipart frames are produced one at a time, allowing a
-- newer display to stop obsolete chunks before they enter ChatThrottleLib.
-- @tparam table payload Canonical PAGE_UPSERT payload.
-- @tparam[opt] function callback Completion callback.
-- @param callbackArg Opaque first callback argument.
-- @treturn boolean queued
-- @treturn string messageIdOrError
function AngryEra:SendProtocolActivePageUpsert(payload, callback, callbackArg)
    if not SafeCanPublish(self, "display") or not SafeCanPublish(self, "pageUpsert") then
        return false, "unauthorized"
    end
    if callback ~= nil and type(callback) ~= "function" then
        return false, "invalid-callback"
    end

    local safeOptions, optionsError = ValidateActiveSendOptions(nil)
    if not safeOptions then
        return false, optionsError
    end
    local validPayload, payloadError = protocol.ValidatePayload("PAGE_UPSERT", payload)
    if not validPayload then
        return false, payloadError
    end
    local reference = ReferenceFromPayload("PAGE_UPSERT", payload)
    local currentTransfer = activePageTransfer
    if ActivePageTransferMatches(currentTransfer, reference, safeOptions) then
        local attached, attachError = AddActivePageTransferWaiter(currentTransfer, callback, callbackArg)
        if not attached then
            return false, attachError
        end
        return true, currentTransfer.MessageId
    end

    local layers = IsPlainTable(payload) and payload.AncestorVariableLayers or nil
    local ancestorContextId, contextError = protocol.BuildCompactPageAncestorContextId(layers, compactPageCodec)
    if not ancestorContextId then
        return false, contextError
    end
    local includeAncestorContext = true
    if #layers > 0 and ancestorContexts:IsOutboundAnnounced(ancestorContextId, layers) then
        includeAncestorContext = false
    end
    local packet, packetError = PrepareProtocolPacket("PAGE_UPSERT", payload, safeOptions, {
        IncludeAncestorContext = includeAncestorContext,
    })
    if not packet then
        return false, packetError
    end
    packet.Prefix = protocol.ACTIVE_PAGE_PREFIX

    local expectedGeneration = activePageTransferGeneration + 1
    CancelActivePageTransfer("superseded")
    if activePageTransferGeneration ~= expectedGeneration then
        return false, "superseded"
    end
    local encodedBytes = #packet.Encoded
    local totalChunks, multipart, escapeSingle = ActivePageFramePlan(packet.Encoded)
    local debugEnabled = IsDebugEnabled(self)
    local compactPageMetadata = packet.CompactPageMetadata
    local state = {
        AncestorContextId = #layers > 0 and compactPageMetadata.AncestorContextId or nil,
        AncestorContextIncluded = compactPageMetadata.AncestorContextIncluded,
        AncestorContextLayers = #layers > 0 and ancestorContexts:CopyLayers(layers) or nil,
        AncestorContextEpoch = ancestorContexts.OutboundEpoch,
        Bytes = encodedBytes,
        Channel = packet.Channel,
        Debug = debugEnabled,
        Encoded = packet.Encoded,
        EscapeSingle = escapeSingle,
        Generation = activePageTransferGeneration,
        Index = 1,
        MessageId = packet.Envelope.MessageId,
        Multipart = multipart,
        Prefix = packet.Prefix,
        QueuedAt = debugEnabled and PreciseNowMilliseconds() or 0,
        Reference = reference,
        Self = self,
        SentChunks = 0,
        Target = packet.Target,
        TotalChunks = totalChunks,
        Waiters = {},
    }
    local attached, attachError = AddActivePageTransferWaiter(state, callback, callbackArg)
    if not attached then
        return false, attachError
    end
    activePageTransfer = state
    if debugEnabled then
        local syncId, revisionId, contextRevisionId = DebugReference("PAGE_UPSERT", payload)
        local throttle = ChatThrottleDebugSnapshot()
        local contentsBytes, pageVarsBytes, ancestorVarsBytes, layerCount = ActivePagePayloadDebugAnatomy(payload)
        local ancestorId, ancestorSource, ancestorIncluded, ancestorBytes =
            ancestorContexts:DebugMetadata(compactPageMetadata, false)
        state.ThrottleAtSubmit = throttle
        Trace(
            self,
            "page-stream-submit",
            "id=%s seq=%d sentAt=%s generation=%d sync=%s rev=%s ctx=%s channel=%s bytes=%d chunks=%d contentsBytes=%d pageVarsBytes=%d ancestorVarsBytes=%d layers=%d ancestorId=%s ancestorSource=%s ancestorIncluded=%s ancestorBytes=%s fps=%s ctlAvail=%s ctlAlertAvail=%s ctlAlertPipes=%s ctlChoking=%s ctlQueues=%s",
            state.MessageId,
            packet.Envelope.Sequence,
            tostring(packet.Envelope.SentAt),
            state.Generation,
            syncId,
            revisionId,
            contextRevisionId,
            state.Channel,
            state.Bytes,
            state.TotalChunks,
            contentsBytes,
            pageVarsBytes,
            ancestorVarsBytes,
            layerCount,
            ancestorId,
            ancestorSource,
            ancestorIncluded,
            ancestorBytes,
            throttle.FrameRate,
            throttle.Available,
            throttle.AlertAvailable,
            throttle.AlertPipes,
            throttle.Choking,
            throttle.QueueStates
        )
    end

    local queued = QueueActivePageChunk(state)
    if (not queued or state.Finished) and not state.Succeeded then
        return false, state.Status or "send-failed"
    end
    return true, state.MessageId
end

--- Broadcasts a correlated protocol-v3 version query.
function AngryEra:SendProtocolVersionQuery(force)
    if not IsLocalDisplayAuthority(self) then
        return false, "not-raid-leader"
    end
    local now = Now()
    CleanupPendingQueries(now)
    if not force and lastQueryAt and now - lastQueryAt < QUERY_THROTTLE_SECONDS then
        return false, "throttled"
    end

    local sent, messageId = self:SendProtocolMessage("VERSION_QUERY", {}, {
        Priority = "ALERT",
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

--- Whispers an uncorrelated request for the current shared display.
function AngryEra:SendProtocolDisplayRequest(target)
    local targetKey = NormalizePlayerKey(target)
    if not targetKey or not SafeCanReceive(self, target, "request") then
        return false, "invalid-target"
    end
    local fullTarget = EnsureUnitFullName(target)
    local sent, messageId = self:SendProtocolMessage("DISPLAY_REQUEST", {}, {
        Channel = "WHISPER",
        Target = fullTarget,
    })
    if not sent then
        return false, messageId
    end
    local now = Now()
    local remembered, rememberError = RememberInteraction(pendingDisplayRequests, messageId, {
        OwnerKey = targetKey,
        TargetKey = targetKey,
        Target = fullTarget,
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
        Revision = reference.Revision,
        RevisionId = reference.RevisionId,
        ContextRevisionId = reference.ContextRevisionId,
        DisplayPayload = {
            Displayed = true,
            SyncId = reference.SyncId,
            Revision = reference.Revision,
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

function ancestorContexts:AttemptPendingDisplayRequest(selfAddon, pending)
    local now = Now()
    self:CleanupMissHints(now)
    if not pending or self.PendingDisplay ~= pending or pending.RequestAttempted then
        return false, "already-requested"
    end
    pending.RequestAttempted = true

    local auth = pending.Auth
    local roleOk, role = pcall(selfAddon.GetGroupRole, selfAddon, auth.Sender)
    if
        not roleOk
        or role == "absent"
        or not SafeCanReceive(selfAddon, auth.Sender, "display")
        or not SafeCanReceive(selfAddon, auth.Sender, "pageUpsert")
    then
        return false, "unauthorized"
    end

    local requested, requestError = selfAddon:SendProtocolPageRequest(auth.Sender, pending.Envelope, pending.Reference)
    pending.RequestSent = requested == true
    local recoveryScheduled = false
    local recoveryStatus
    if type(selfAddon.DeferPendingDisplayRecovery) == "function" then
        local called, scheduled, status = pcall(
            selfAddon.DeferPendingDisplayRecovery,
            selfAddon,
            auth,
            pending.Envelope,
            pending.Reference,
            requested and 1 or 0,
            true
        )
        if called and scheduled then
            recoveryScheduled = status == "scheduled"
            recoveryStatus = status
        elseif called then
            recoveryStatus = status
        else
            recoveryStatus = "recovery-failed"
        end
    end
    return requested == true, requestError, recoveryScheduled, recoveryStatus
end

function ancestorContexts:HandleDecodeMiss(selfAddon, prefix, channel, sender, metadata)
    if
        prefix ~= protocol.ACTIVE_PAGE_PREFIX
        or not IsCurrentGroupChannel(channel)
        or not SafeCanReceive(selfAddon, sender, "display")
        or not SafeCanReceive(selfAddon, sender, "pageUpsert")
    then
        return false, "unsafe-context-miss"
    end
    local now = Now()
    local safeMetadata = self:ValidateMissMetadata(sender, metadata)
    if not safeMetadata then
        return false, "invalid-context-miss"
    end
    local pending = self:PendingMatchesMetadata(sender, metadata, now)
    if pending then
        return self:AttemptPendingDisplayRequest(selfAddon, pending)
    end
    return self:RememberMissHint(sender, metadata, now), "hinted"
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

--- Whispers a detached active-page edit proposal to the current leader.
-- The proposal is retained briefly so only a correlated result from the same
-- advertised leader session can complete it.
function AngryEra:SendProtocolChangeProposal(target, payload)
    if not SafeCanPublish(self, "changeProposal") then
        return false, "unauthorized"
    end
    local targetKey = NormalizePlayerKey(target)
    if not targetKey or not SafeCanReceive(self, target, "changeResult") then
        return false, "invalid-target"
    end

    local peer = peers[targetKey]
    if
        not IsPlainTable(boundDisplayAuthority)
        or boundDisplayAuthority.PlayerKey ~= targetKey
        or not peer
        or peer.SenderInstallationId ~= boundDisplayAuthority.SenderInstallationId
        or peer.SenderSessionId ~= boundDisplayAuthority.SenderSessionId
        or not protocol.Supports(
            peer.NegotiatedCapabilities,
            protocol.ACTIVE_PAGE_CHANGES_CAPABILITY,
            protocol.ACTIVE_PAGE_CHANGES_CAPABILITY_VERSION
        )
    then
        return false, "change-proposals-unsupported"
    end
    if
        not IsPlainTable(payload)
        or payload.AuthorityInstallationId ~= boundDisplayAuthority.SenderInstallationId
        or payload.AuthoritySessionId ~= boundDisplayAuthority.SenderSessionId
    then
        return false, "stale-change-authority"
    end

    local sent, messageId = self:SendProtocolMessage("CHANGE_PROPOSE", payload, {
        Channel = "WHISPER",
        Priority = "ALERT",
        Target = EnsureUnitFullName(target),
    })
    if not sent then
        return false, messageId
    end

    local remembered, rememberError = RememberInteraction(pendingChangeProposals, messageId, {
        OwnerKey = targetKey,
        TargetKey = targetKey,
        SenderInstallationId = peer.SenderInstallationId,
        SenderSessionId = peer.SenderSessionId,
        Payload = CopyMap(payload),
    }, Now())
    if not remembered then
        return false, rememberError
    end
    return true, messageId
end

--- Forgets one locally canceled proposal correlation. This cannot retract an
-- already transmitted whisper, but it prevents a later result from reviving a
-- draft the user explicitly discarded.
function AngryEra:CancelProtocolChangeProposal(messageId)
    if type(messageId) ~= "string" then
        return false
    end
    local canceled = pendingChangeProposals[messageId] ~= nil
    pendingChangeProposals[messageId] = nil
    return canceled
end

--- Whispers a leader-authored result correlated to one CHANGE_PROPOSE.
function AngryEra:SendProtocolChangeResult(target, replyTo, payload)
    if not SafeCanPublish(self, "changeResult") then
        return false, "unauthorized"
    end
    if type(replyTo) ~= "string" or replyTo == "" then
        return false, "missing-reply-to"
    end
    local targetKey = NormalizePlayerKey(target)
    if not targetKey or not SafeCanReceive(self, target, "changeProposal") then
        return false, "invalid-target"
    end
    return self:SendProtocolMessage("CHANGE_RESULT", payload, {
        Channel = "WHISPER",
        Priority = "ALERT",
        Target = EnsureUnitFullName(target),
        ReplyTo = replyTo,
    })
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
    local wirePayload = CopyMap(payload)
    wirePayload.ActivePageChanges = ActivePageChangeHandlersLive() and true or nil
    local sent, messageId = self:SendProtocolMessage("DISPLAY", wirePayload, safeOptions)
    if not sent then
        return false, messageId
    end

    local targetKey = safeOptions.Target and NormalizePlayerKey(safeOptions.Target) or nil
    local ownerKey = targetKey or "*"
    local reference = ReferenceFromPayload("DISPLAY", wirePayload)
    local now = Now()
    local remembered, rememberError = RememberInteraction(outboundDisplays, messageId, {
        OwnerKey = ownerKey,
        TargetKey = targetKey,
        RecipientInstallationId = safeOptions.RecipientInstallationId,
        RecipientSessionId = safeOptions.RecipientSessionId,
        Displayed = wirePayload.Displayed,
        SyncId = reference and reference.SyncId,
        Revision = reference and reference.Revision,
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
    RefreshDisplayAuthorityFromVersionQuery(self, auth)
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

local function RememberDisplayCapabilities(auth, payload, now)
    local senderKey = NormalizePlayerKey(auth.Sender)
    if not senderKey then
        return
    end
    local existing = peers[senderKey]
    if
        existing
        and (
            existing.SenderInstallationId ~= auth.SenderInstallationId
            or existing.SenderSessionId ~= auth.SenderSessionId
        )
    then
        existing = nil
    end

    local capabilities = existing and CopyMap(existing.Capabilities) or {}
    if payload.ActivePageChanges == true then
        capabilities[protocol.ACTIVE_PAGE_CHANGES_CAPABILITY] =
            protocol.ACTIVE_PAGE_CHANGES_CAPABILITY_VERSION
    end
    peers[senderKey] = {
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        AddonVersion = existing and existing.AddonVersion or nil,
        BuildTimestamp = existing and existing.BuildTimestamp or nil,
        Flavor = existing and existing.Flavor or nil,
        Capabilities = capabilities,
        NegotiatedCapabilities = protocol.NegotiateCapabilities(LocalCapabilities(), capabilities),
        AcceptsCurrentGroup = existing and existing.AcceptsCurrentGroup or nil,
        LastSeenAt = now,
        ReplyTo = existing and existing.ReplyTo or nil,
    }
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

    local displayPayload = CopyMap(plan.Payload)
    if plan.PageUpsertPayload then
        displayPayload.PageFollows = true
    end
    local sent, result = self:SendProtocolDisplay(displayPayload, {
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
    local debugEnabled = IsDebugEnabled(self)
    local accepted, result, warning = self:AcceptActiveDisplay(auth, envelope.Payload)
    if not accepted then
        if debugEnabled then
            Trace(
                self,
                "display-reject",
                "id=%s sender=%s reason=%s",
                envelope.MessageId,
                auth.Sender,
                tostring(result)
            )
        end
        return false, result
    end
    if envelope.ReplyTo == nil then
        InvalidatePendingDisplayRequestsForAuthority(
            auth,
            ReferenceFromPayload("DISPLAY", envelope.Payload)
        )
    end
    RememberDisplayCapabilities(auth, envelope.Payload, Now())
    -- An authenticated, authorized DISPLAY resolves discovery even when its
    -- promised exact page still needs the separate page-recovery watchdog.
    if type(self.ResolveDisplayDiscovery) == "function" then
        pcall(self.ResolveDisplayDiscovery, self)
    end
    if debugEnabled then
        Trace(
            self,
            "display-accept",
            "id=%s sender=%s cache=%s applied=%s localId=%s",
            envelope.MessageId,
            auth.Sender,
            result.RequestNeeded and "miss" or (result.ContextRebound and "rebound" or "hit"),
            tostring(result.Applied == true),
            tostring(result.LocalId)
        )
    end

    local requestError
    if result.RequestNeeded then
        local pendingContext = ancestorContexts:SetPendingDisplay(auth, envelope, result.RequestPayload, Now())
        local missedBeforeDisplay = ancestorContexts:ConsumeMissHints(
            auth.Sender,
            auth.SenderInstallationId,
            auth.SenderSessionId,
            result.RequestPayload,
            Now()
        )
        local deferred
        local recoveryStatus
        if
            not missedBeforeDisplay
            and type(self.DeferPendingDisplayRecovery) == "function"
            and envelope.Payload.PageFollows == true
        then
            local called, scheduled, status = pcall(
                self.DeferPendingDisplayRecovery,
                self,
                auth,
                envelope,
                result.RequestPayload,
                0,
                envelope.ReplyTo ~= nil
            )
            if called and scheduled then
                deferred = true
                result.RequestDeferred = true
                result.RecoveryScheduled = status == "scheduled"
                recoveryStatus = status
            end
        end
        if not deferred then
            local requested
            local recoveryScheduled
            requested, requestError, recoveryScheduled, recoveryStatus =
                ancestorContexts:AttemptPendingDisplayRequest(self, pendingContext)
            result.RequestSent = requested == true
            result.RecoveryScheduled = recoveryScheduled == true
        end
        result.RequestError = requestError
        result.RecoveryStatus = recoveryStatus
        if debugEnabled then
            Trace(
                self,
                "display-wait-page",
                "id=%s sender=%s pageFollows=%s deferred=%s requestSent=%s watchdog=%s request=%s recovery=%s",
                envelope.MessageId,
                auth.Sender,
                tostring(envelope.Payload.PageFollows == true),
                tostring(result.RequestDeferred == true),
                tostring(result.RequestSent == true),
                tostring(result.RecoveryScheduled == true),
                tostring(result.RequestError),
                tostring(result.RecoveryStatus)
            )
        end
    else
        ancestorContexts:ResetMissState()
        if type(self.CancelPendingDisplayRecovery) == "function" then
            pcall(self.CancelPendingDisplayRecovery, self)
        end
    end
    if envelope.ReplyTo ~= nil then
        local pending = pendingDisplayRequests[envelope.ReplyTo]
        if pending then
            BindDisplayRequest(pending, auth, ReferenceFromPayload("DISPLAY", envelope.Payload))
            pending.DisplayReceived = true
            if
                not envelope.Payload.Displayed
                or pending.PageUpsertReceived
                or result.RequestNeeded ~= true
                or envelope.Payload.PageFollows ~= true
            then
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

function AngryEra:HandleProtocolPageUpsert(auth, channel, envelope, correlationKind, authorityBootstrap)
    local debugEnabled = IsDebugEnabled(self)
    local accepted
    local result
    local warning
    if channel == "WHISPER" then
        accepted, result, warning = self:AcceptActivePageUpsert(auth, envelope.Payload, {
            CorrelatedReply = true,
            AuthorityBootstrap = authorityBootstrap == true,
        })
    else
        accepted, result, warning = self:AcceptActivePageUpsert(auth, envelope.Payload)
    end
    if not accepted then
        if debugEnabled then
            Trace(self, "page-reject", "id=%s sender=%s reason=%s", envelope.MessageId, auth.Sender, tostring(result))
        end
        return false, result
    end
    if channel ~= "WHISPER" then
        InvalidatePendingDisplayRequestsForAuthority(
            auth,
            ReferenceFromPayload("PAGE_UPSERT", envelope.Payload)
        )
    end
    if debugEnabled then
        Trace(
            self,
            "page-accept",
            "id=%s sender=%s localId=%s pendingReady=%s applied=%s",
            envelope.MessageId,
            auth.Sender,
            tostring(result.LocalId),
            tostring(result.PendingDisplayReady == true),
            tostring(result.Applied == true)
        )
    end

    local reference = ReferenceFromPayload("PAGE_UPSERT", envelope.Payload)
    ancestorContexts:ClearPendingForPage(auth, reference)
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
            if debugEnabled then
                Trace(
                    self,
                    "display-resume",
                    "pageMessage=%s sender=%s displayed=%s localId=%s ui=%s",
                    envelope.MessageId,
                    auth.Sender,
                    tostring(displayResult.Displayed == true),
                    tostring(displayResult.LocalId),
                    tostring(displayResult.UIRefreshed == true)
                )
            end
            if type(self.CancelPendingDisplayRecovery) == "function" then
                pcall(self.CancelPendingDisplayRecovery, self)
            end
        else
            result.DisplayCompletionError = displayResult
            displayWarning = displayResult
        end
    end
    result.UIWarning = warning
    if type(self.ObserveSharedPageCanonicalUpdate) == "function" then
        pcall(self.ObserveSharedPageCanonicalUpdate, self, auth, envelope.Payload, result)
    end
    return true, result, displayWarning or warning
end

local function ChangeResultPayload(result)
    local payload = {
        Status = result.Status,
        SyncId = result.SyncId,
    }
    if result.Status ~= "unavailable" then
        payload.Revision = result.Revision
        payload.RevisionId = result.RevisionId
        payload.ContextRevisionId = result.ContextRevisionId
    end
    return payload
end

local function ProposalPublicationAuthorityCurrent(context)
    return IsLocalDisplayAuthority(context.Self)
        and protocolSession
        and protocolSession.InstallationId == context.AuthorityInstallationId
        and protocolSession.SessionId == context.AuthoritySessionId
end

local function ActiveProposalReferenceMatches(context)
    if type(context.Self.GetActiveDisplayReference) ~= "function" then
        return false
    end
    local called, reference = pcall(context.Self.GetActiveDisplayReference, context.Self)
    return called and SameReference(reference, context.Reference)
end

local function FirstProposalFailureAnnouncement(messageId)
    if type(messageId) ~= "string" then
        return true
    end
    if proposalFailureAnnouncements[messageId] then
        return false
    end
    if proposalFailureAnnouncementCount >= MAX_PENDING_INTERACTIONS then
        proposalFailureAnnouncements = {}
        proposalFailureAnnouncementCount = 0
    end
    proposalFailureAnnouncements[messageId] = true
    proposalFailureAnnouncementCount = proposalFailureAnnouncementCount + 1
    return true
end

local function CompleteProposalPagePublication(context, succeeded, status, messageId)
    if not context or context.Completed then
        return
    end
    context.Completed = true
    context.Result.PublicationSucceeded = succeeded == true
    context.Result.PublicationError = succeeded and nil or status
    if not ProposalPublicationAuthorityCurrent(context) then
        return
    end

    if succeeded then
        local sent, sendError = context.Self:SendProtocolChangeResult(
            context.Target,
            context.ReplyTo,
            context.ResultPayload
        )
        if not sent then
            context.Result.PublicationSucceeded = false
            context.Result.PublicationError = sendError
        end
        return
    end

    context.Self:SendProtocolChangeResult(context.Target, context.ReplyTo, {
        Status = "unavailable",
        SyncId = context.Reference.SyncId,
    })
    if FirstProposalFailureAnnouncement(messageId) and ActiveProposalReferenceMatches(context) then
        context.Self:SendProtocolDisplay({
            Displayed = true,
            SyncId = context.Reference.SyncId,
            Revision = context.Reference.Revision,
            RevisionId = context.Reference.RevisionId,
            ContextRevisionId = context.Reference.ContextRevisionId,
        })
    end
end

local function ProposalPageTransferCompleted(context, succeeded, status, messageId)
    CompleteProposalPagePublication(context, succeeded, status, messageId)
end

local function PublishCanonicalProposalResult(self, auth, envelope, result, resultPayload)
    local reference = {
        SyncId = result.SyncId,
        Revision = result.Revision,
        RevisionId = result.RevisionId,
        ContextRevisionId = result.ContextRevisionId,
    }
    local context = {
        AuthorityInstallationId = envelope.Payload.AuthorityInstallationId,
        AuthoritySessionId = envelope.Payload.AuthoritySessionId,
        Reference = reference,
        ReplyTo = envelope.MessageId,
        Result = result,
        ResultPayload = resultPayload,
        Self = self,
        Target = auth.Sender,
    }

    if not IsPlainTable(result) or not IsPlainTable(result.PageUpsertPayload) then
        CompleteProposalPagePublication(context, false, "missing-canonical-page")
        return false, "missing-canonical-page"
    end
    if not IsLocalDisplayAuthority(self) then
        CompleteProposalPagePublication(context, false, "not-display-authority")
        return false, "not-display-authority"
    end

    local activeOptions = ValidateActiveSendOptions(nil)
    local reusingPublication = activeOptions
        and ActivePageTransferMatches(activePageTransfer, reference, activeOptions)
    if not reusingPublication then
        local displaySent, displayResult = self:SendProtocolDisplay({
            Displayed = true,
            SyncId = reference.SyncId,
            Revision = reference.Revision,
            RevisionId = reference.RevisionId,
            ContextRevisionId = reference.ContextRevisionId,
            PageFollows = true,
        })
        if not displaySent then
            CompleteProposalPagePublication(context, false, displayResult)
            return false, displayResult
        end
    else
        result.PublicationDisplayReused = true
    end
    local pageSent, pageResult =
        self:SendProtocolActivePageUpsert(result.PageUpsertPayload, ProposalPageTransferCompleted, context)
    if not pageSent then
        if reusingPublication then
            context.Completed = true
            context.Result.PublicationSucceeded = false
            context.Result.PublicationError = pageResult
            if ProposalPublicationAuthorityCurrent(context) then
                context.Self:SendProtocolChangeResult(context.Target, context.ReplyTo, {
                    Status = "unavailable",
                    SyncId = context.Reference.SyncId,
                })
            end
            return false, pageResult
        end
        CompleteProposalPagePublication(context, false, pageResult)
        return false, pageResult
    end
    result.PublicationPending = not context.Completed
    return true, pageResult
end

local function RejectChangeProposalUnavailable(self, auth, envelope, reason)
    local payload = {
        Status = "unavailable",
        SyncId = envelope.Payload.SyncId,
    }
    local sent, sendResult =
        self:SendProtocolChangeResult(auth.Sender, envelope.MessageId, payload)
    if not sent then
        return false, sendResult
    end
    return true, {
        PublicationSkipped = true,
        Rejection = reason,
        Status = "unavailable",
        SyncId = payload.SyncId,
    }, reason
end

--- Applies one authorized assistant proposal and returns the leader's
-- correlated semantic result. Applied and unchanged outcomes republish the
-- exact canonical tuple; terminal failures return only their correlated result.
function AngryEra:HandleProtocolChangePropose(auth, _, envelope)
    if not IsLocalDisplayAuthority(self) then
        return false, "not-display-authority"
    end
    if
        not protocolSession
        or envelope.Payload.AuthorityInstallationId ~= protocolSession.InstallationId
        or envelope.Payload.AuthoritySessionId ~= protocolSession.SessionId
    then
        return RejectChangeProposalUnavailable(self, auth, envelope, "stale-change-authority")
    end
    local called, accepted, result, warning =
        pcall(self.ApplyActivePageChangeProposal, self, auth, envelope.Payload)
    if not called then
        return RejectChangeProposalUnavailable(self, auth, envelope, "change-proposal-apply-failed")
    end
    if not accepted then
        return RejectChangeProposalUnavailable(self, auth, envelope, result)
    end
    if not IsPlainTable(result) then
        return RejectChangeProposalUnavailable(self, auth, envelope, "invalid-change-proposal-result")
    end

    local resultPayload = ChangeResultPayload(result)
    local validResult, validationError = protocol.ValidatePayload("CHANGE_RESULT", resultPayload)
    if not validResult then
        return RejectChangeProposalUnavailable(self, auth, envelope, validationError)
    end

    if result.Status == "conflict" or result.Status == "busy" or result.Status == "unavailable" then
        local sent, sendResult =
            self:SendProtocolChangeResult(auth.Sender, envelope.MessageId, resultPayload)
        if not sent then
            return false, sendResult
        end
        result.PublicationSkipped = true
        return true, result, warning
    end

    local published, publicationError =
        PublishCanonicalProposalResult(self, auth, envelope, result, resultPayload)
    if not published then
        result.PublicationSucceeded = false
        result.PublicationError = publicationError
    end
    return true, result, publicationError or warning
end

--- Completes one locally pending proposal only when the current leader session
-- returns a correlated result for the same page.
function AngryEra:HandleProtocolChangeResult(auth, _, envelope)
    local pending = pendingChangeProposals[envelope.ReplyTo]
    if not pending or pending.Payload.SyncId ~= envelope.Payload.SyncId then
        return false, "uncorrelated-reply"
    end
    pendingChangeProposals[envelope.ReplyTo] = nil

    local callbackResult
    if type(self.HandleSharedPageChangeResult) == "function" then
        local called, handled, result = pcall(
            self.HandleSharedPageChangeResult,
            self,
            auth,
            envelope.Payload,
            pending.Payload,
            envelope.ReplyTo
        )
        if not called then
            return false, "change-result-handler-failed"
        end
        if handled == false then
            return false, result or "change-result-rejected"
        end
        callbackResult = result
    end
    return true, callbackResult or CopyMap(envelope.Payload)
end

HANDLERS = {
    VERSION_QUERY = "HandleProtocolVersionQuery",
    VERSION = "HandleProtocolVersion",
    DISPLAY_REQUEST = "HandleProtocolDisplayRequest",
    DISPLAY = "HandleProtocolDisplay",
    PAGE_REQUEST = "HandleProtocolPageRequest",
    PAGE_UPSERT = "HandleProtocolPageUpsert",
    CHANGE_PROPOSE = "HandleProtocolChangePropose",
    CHANGE_RESULT = "HandleProtocolChangeResult",
}

--- Dispatches a validated, authorized, non-duplicate envelope.
function AngryEra:DispatchProtocolMessage(auth, channel, envelope, correlationKind, authorityBootstrap)
    local handlerName = HANDLERS[envelope.Type]
    local handler = handlerName and self[handlerName]
    if not handler then
        return false, "unknown-message-type"
    end
    return handler(self, auth, channel, envelope, correlationKind, authorityBootstrap)
end

--- Receives, authenticates, correlates, deduplicates, and dispatches protocol v3.
function AngryEra:ReceiveProtocolMessage(prefix, data, channel, sender)
    if
        (
            prefix ~= protocol.PREFIX
            and prefix ~= protocol.DISPLAY_PREFIX
            and prefix ~= protocol.PAGE_PREFIX
            and prefix ~= protocol.ACTIVE_PAGE_PREFIX
        ) or type(sender) ~= "string"
    then
        return false, "invalid-transport"
    end
    if prefix == protocol.ACTIVE_PAGE_PREFIX and not IsCurrentGroupChannel(channel) then
        return false, "invalid-transport-message-type"
    end
    local debugEnabled = IsDebugEnabled(self)
    local decodeStarted = debugEnabled and PreciseNowMilliseconds() or 0

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
    if
        (prefix == protocol.DISPLAY_PREFIX and not SafeCanReceive(self, sender, "display"))
        or (prefix == protocol.PAGE_PREFIX and not SafeCanReceive(self, sender, "pageUpsert"))
        or (
            prefix == protocol.ACTIVE_PAGE_PREFIX
            and (
                not SafeCanReceive(self, sender, "pageUpsert")
                or not SafeCanReceive(self, sender, "display")
            )
        )
    then
        return false, "unauthorized"
    end

    local envelope
    local decodeError
    local compactPageMetadata
    if prefix == protocol.DISPLAY_PREFIX then
        envelope, decodeError = protocol.DecodeCompactDisplayEnvelope(data, protocolCodec)
    elseif prefix == protocol.PAGE_PREFIX or prefix == protocol.ACTIVE_PAGE_PREFIX then
        local decodeOptions
        if prefix == protocol.ACTIVE_PAGE_PREFIX then
            decodeOptions = {
                ResolveAncestorContext = function(installationId, sessionId, contextId)
                    return ancestorContexts:ResolveInbound(sender, installationId, sessionId, contextId)
                end,
            }
        end
        envelope, decodeError, compactPageMetadata =
            protocol.DecodeCompactPageEnvelope(data, compactPageCodec, decodeOptions)
        if prefix == protocol.PAGE_PREFIX and decodeError == "compact-page-ancestor-context-missing" then
            decodeError = "invalid-transport-message-type"
        end
    else
        envelope, decodeError = protocol.DecodeEnvelope(data, protocolCodec)
    end
    if not envelope then
        if decodeError == "compact-page-ancestor-context-missing" then
            ancestorContexts:HandleDecodeMiss(self, prefix, channel, sender, compactPageMetadata)
        end
        if debugEnabled then
            local ancestorId, ancestorSource, ancestorIncluded, ancestorBytes =
                ancestorContexts:DebugMetadata(compactPageMetadata, true)
            if decodeError == "compact-page-ancestor-context-missing" then
                ancestorSource = "missing"
            end
            Trace(
                self,
                "rx-drop",
                "prefix=%s sender=%s channel=%s bytes=%d decode=%dms reason=%s ancestorId=%s ancestorSource=%s ancestorIncluded=%s ancestorBytes=%s",
                prefix,
                sender,
                tostring(channel),
                type(data) == "string" and #data or 0,
                math.max(PreciseNowMilliseconds() - decodeStarted, 0),
                tostring(decodeError),
                ancestorId,
                ancestorSource,
                ancestorIncluded,
                ancestorBytes
            )
        end
        return false, decodeError
    end
    if
        (envelope.Type == "DISPLAY" and prefix ~= protocol.DISPLAY_PREFIX)
        or (envelope.Type == "PAGE_UPSERT" and prefix ~= protocol.PAGE_PREFIX and prefix ~= protocol.ACTIVE_PAGE_PREFIX)
        or (envelope.Type ~= "DISPLAY" and envelope.Type ~= "PAGE_UPSERT" and prefix ~= protocol.PREFIX)
    then
        return false, "invalid-transport-message-type"
    end
    if
        envelope.Type == "PAGE_UPSERT"
        and compactPageMetadata
        and compactPageMetadata.AncestorContextIncluded == false
        and (prefix ~= protocol.ACTIVE_PAGE_PREFIX or not IsCurrentGroupChannel(channel) or envelope.ReplyTo ~= nil)
    then
        return false, "invalid-transport-message-type"
    end
    if debugEnabled and IsActivePageMessage(envelope.Type) then
        local syncId, revisionId, contextRevisionId = DebugReference(envelope.Type, envelope.Payload)
        local receivedAt = CurrentEpochMilliseconds()
        local approximateAge = receivedAt and (receivedAt - envelope.SentAt) or 0
        local ancestorId, ancestorSource, ancestorIncluded, ancestorBytes =
            ancestorContexts:DebugMetadata(compactPageMetadata, true)
        Trace(
            self,
            "rx-decoded",
            "type=%s id=%s seq=%d sentAt=%s age~=%sms sync=%s rev=%s ctx=%s sender=%s prefix=%s channel=%s replyTo=%s bytes=%d decode=%dms ancestorId=%s ancestorSource=%s ancestorIncluded=%s ancestorBytes=%s",
            envelope.Type,
            envelope.MessageId,
            envelope.Sequence,
            tostring(envelope.SentAt),
            tostring(approximateAge),
            syncId,
            revisionId,
            contextRevisionId,
            sender,
            prefix,
            tostring(channel),
            envelope.ReplyTo or "-",
            type(data) == "string" and #data or 0,
            math.max(PreciseNowMilliseconds() - decodeStarted, 0),
            ancestorId,
            ancestorSource,
            ancestorIncluded,
            ancestorBytes
        )
    end

    local now = Now()
    local auth = BuildAuth(sender, envelope, now)
    local channelValid, channelError, correlationKind, correlationRecord =
        ValidateChannelAndCorrelation(auth, channel, envelope, now)
    if not channelValid then
        return false, channelError
    end

    local action = RequiredAction(envelope.Type)
    if not action or not SafeCanReceive(self, sender, action) then
        return false, "unauthorized"
    end
    if envelope.Type == "VERSION_QUERY" and role ~= "leader" then
        return false, "unauthorized"
    end
    if
        envelope.Type == "VERSION_QUERY"
        and not IsLocalDisplayAuthority(self)
        and IsRetiredDisplayAuthority(auth)
    then
        return false, "stale-display-authority"
    end
    if
        not IsLocalDisplayAuthority(self)
        and (envelope.Type == "VERSION_QUERY" or LEADER_TENURE_MESSAGE_TYPES[envelope.Type])
        and IsStaleDisplayAuthoritySignal(auth)
    then
        return false, "stale-display-authority"
    end
    if prefix == protocol.ACTIVE_PAGE_PREFIX and not SafeCanReceive(self, sender, "display") then
        return false, "unauthorized"
    end
    if
        (envelope.Type == "DISPLAY" or envelope.Type == "VERSION_QUERY")
        and not ValidateDisplayTimestamp(envelope.SentAt)
    then
        return false, "invalid-display-timestamp"
    end
    if envelope.Type == "CHANGE_PROPOSE" and not ValidateChangeProposalTimestamp(envelope.SentAt) then
        return false, "stale-change-proposal"
    end
    local tenureValid, tenureError, bindDisplayAuthority =
        ValidateDisplayAuthorityTenure(self, auth, envelope, correlationKind)
    if not tenureValid then
        return false, tenureError
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
        if debugEnabled then
            Trace(self, "rx-drop", "type=%s id=%s reason=duplicate", envelope.Type, envelope.MessageId)
        end
        return false, "duplicate"
    end
    if envelope.Type == "DISPLAY" then
        local displayOrderValid, displayOrderError =
            ValidateDisplayOrder(replayPlayer, replaySessionKey, envelope.Sequence, envelope.SentAt)
        if not displayOrderValid then
            if debugEnabled then
                Trace(self, "rx-drop", "type=DISPLAY id=%s reason=%s", envelope.MessageId, tostring(displayOrderError))
            end
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

    if envelope.Type == "VERSION_QUERY" then
        ObserveDisplayAuthoritySignal(auth)
    end
    local traceActivePage = debugEnabled and IsActivePageMessage(envelope.Type)
    local dispatchStarted = traceActivePage and PreciseNowMilliseconds() or 0
    local authorityBootstrap = bindDisplayAuthority
        or (correlationRecord and correlationRecord.AuthorityBootstrap == true)
    local accepted, result, warning =
        self:DispatchProtocolMessage(auth, channel, envelope, correlationKind, authorityBootstrap)
    if accepted and bindDisplayAuthority then
        if correlationRecord then
            correlationRecord.AuthorityBootstrap = true
        end
        BindDisplayAuthority(auth)
    end
    if accepted and envelope.Type == "PAGE_UPSERT" and compactPageMetadata then
        if compactPageMetadata.AncestorContextIncluded == true and #envelope.Payload.AncestorVariableLayers > 0 then
            ancestorContexts:StoreInbound(
                sender,
                envelope.SenderInstallationId,
                envelope.SenderSessionId,
                compactPageMetadata.AncestorContextId,
                envelope.Payload.AncestorVariableLayers
            )
        elseif compactPageMetadata.AncestorContextIncluded == false then
            ancestorContexts:TouchInbound(
                sender,
                envelope.SenderInstallationId,
                envelope.SenderSessionId,
                compactPageMetadata.AncestorContextId
            )
        end
    end
    if accepted and envelope.Type == "DISPLAY" then
        CommitDisplayOrder(replayPlayer, replaySessionKey, envelope.Sequence, envelope.SentAt)
    end
    if traceActivePage then
        local requestNeeded = type(result) == "table" and result.RequestNeeded == true
        local completedDisplay = type(result) == "table" and result.CompletedDisplay ~= nil
        Trace(
            self,
            "rx-dispatch",
            "type=%s id=%s accepted=%s elapsed=%dms waitPage=%s completedDisplay=%s status=%s",
            envelope.Type,
            envelope.MessageId,
            tostring(accepted == true),
            math.max(PreciseNowMilliseconds() - dispatchStarted, 0),
            tostring(requestNeeded),
            tostring(completedDisplay),
            type(result) == "string" and result or (accepted and "ok" or "rejected")
        )
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
    ancestorContexts:PruneInbound(self)
    ancestorContexts:PruneMissState(self)
    ancestorContexts:ResetOutbound()
end
