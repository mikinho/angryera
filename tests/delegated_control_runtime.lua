local currentTime = 1785000000
local preciseTime = 81.25
local currentPlayer = "Viewer-Realm"
local raidLeader = "Roselea-Realm"
local members = {}
local sentMessages = {}
local scheduledTimers = {}
local shownRequests = {}
local completedRequests = {}
local controlUpdates = {}
local recoveryRequests = 0
local disqualifiedRequesters = {}
local controllerOnline = true
local layoutApplyResets = 0
local layoutApplyPreservedReference
local markerOwnershipReleases = 0
local receiveMode = "standard"
local printedMessages = {}

local LOCAL_INSTALLATION = "ae3i:1:2:3:4"
local LEADER_INSTALLATION_A = "ae3i:a:1:1:1"
local LEADER_INSTALLATION_B = "ae3i:b:1:1:1"
local CONTROLLER_INSTALLATION = "ae3i:c:1:1:1"
local OTHER_INSTALLATION = "ae3i:d:1:1:1"

_G.AngryAssign_Meta = {
    InstallationId = LOCAL_INSTALLATION,
    NextEntitySequence = 0,
    EntityLocal = {},
    SyncScopes = {},
    Migrations = {},
}
_G.AngryAssign_State = {}
_G.AngryAssign_Pages = {}
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
    return category ~= LE_PARTY_CATEGORY_INSTANCE
end
_G.IsInGroup = function(category)
    return category ~= LE_PARTY_CATEGORY_INSTANCE
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
    return "encoded:" .. value
end

function libD:DecodeForWoWAddonChannel(value)
    if value:sub(1, 8) == "encoded:" then
        return value:sub(9)
    end
end

local function EnsureUnitFullName(player)
    if type(player) ~= "string" or player == "" then
        return nil
    end
    if not player:find("-", 1, true) then
        return player .. "-Realm"
    end
    return player
end

local helpers = {
    EnsureUnitFullName = EnsureUnitFullName,
    PlayerFullName = function()
        return currentPlayer
    end,
}

local AngryEra = {
    Title = "Angry Era",
    Version = "3.3.0",
    Timestamp = "20260729000000",
    core = {
        updateFrequency = 2,
        isClassicVanilla = true,
        isClassicTBC = false,
        isClassicWrath = false,
    },
    sync = {
        revisions = {
            CreateFCS32Callback = function(source)
                assert(source == libC, "runtime hashing should use LibCompress")
                return TestHash
            end,
        },
    },
    utils = {
        helpers = helpers,
    },
}

local function PlayerKey(player)
    local fullName = EnsureUnitFullName(player)
    return fullName and fullName:lower() or nil
end

local function SetRole(player, role)
    members[assert(PlayerKey(player))] = role
end

function AngryEra:IsValidRaid()
    return true
end

function AngryEra:GetGroupRole(player)
    return members[PlayerKey(player)] or "absent"
end

function AngryEra:GetRaidLeader()
    return raidLeader
end

function AngryEra:GetAngryEraAuthority(onlineOnly)
    local control = type(self.GetDelegatedRaidControl) == "function" and self:GetDelegatedRaidControl() or nil
    if control and not control.PendingRole and not control.PendingRecovery then
        if onlineOnly and not controllerOnline then
            return nil
        end
        return control.Controller
    end
    return raidLeader
end

function AngryEra:IsQualifiedAssistant(player)
    return self:GetGroupRole(player) == "assistant"
end

function AngryEra:CanReceiveFrom(player, action)
    local role = self:GetGroupRole(player)
    if role == "absent" then
        return false
    end
    if action == "version" or action == "request" then
        return true
    end
    if action == "controlRequest" then
        return role == "assistant" and disqualifiedRequesters[PlayerKey(player)] ~= true
    end
    if action == "controlGrant" or action == "controlRevoke" or action == "controlResult" then
        return role == "leader"
    end
    if action == "display" or action == "pageUpsert" or action == "changeResult" then
        return role == "leader" or role == "assistant"
    end
    return action == "changeProposal" and (role == "leader" or role == "assistant")
end

function AngryEra:CanLocalPlayerPublish(action)
    local role = self:GetGroupRole(currentPlayer)
    if action == "controlRequest" then
        return role == "assistant"
    end
    if action == "controlGrant" or action == "controlRevoke" or action == "controlResult" then
        return role == "leader"
    end
    if action == "display" or action == "pageUpsert" or action == "changeResult" then
        local control = type(self.GetDelegatedRaidControl) == "function" and self:GetDelegatedRaidControl() or nil
        if control and not control.PendingRole and not control.PendingRecovery then
            return PlayerKey(control.Controller) == PlayerKey(currentPlayer)
                and control.ControllerInstallationId == AngryAssign_Meta.InstallationId
                and self:GetProtocolSession() ~= nil
                and control.ControllerSessionId == self:GetProtocolSession().SessionId
        end
        return role == "leader"
    end
    return action == "changeProposal" and (role == "leader" or role == "assistant")
end

function AngryEra:IsPlayerRaidLeader()
    return self:GetGroupRole(currentPlayer) == "leader"
end

function AngryEra:CanLocalPlayerQueryVersions()
    local role = self:GetGroupRole(currentPlayer)
    return role == "leader" or role == "assistant"
end

function AngryEra:GetConfig(key)
    if key == "receiveMode" then
        return receiveMode
    end
end

function AngryEra:SetConfig(key, value)
    if key == "receiveMode" then
        receiveMode = value
    end
end

function AngryEra:Print(message)
    printedMessages[#printedMessages + 1] = message
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
    if self._testPreciseTimeAfterSend ~= nil then
        preciseTime = self._testPreciseTimeAfterSend
        self._testPreciseTimeAfterSend = nil
    end
end

function AngryEra:ScheduleTimer(method, delay, argument)
    local timer = {
        Method = method,
        Delay = delay,
        Argument = argument,
        Canceled = false,
        Ran = false,
    }
    scheduledTimers[#scheduledTimers + 1] = timer
    return timer
end

function AngryEra:CancelTimer(timer)
    timer.Canceled = true
end

function AngryEra:ShowDelegatedControlRequest(messageId)
    shownRequests[#shownRequests + 1] = messageId
end

function AngryEra:DelegatedControlRequestCompleted(result)
    completedRequests[#completedRequests + 1] = result
end

function AngryEra:DelegatedControlStateUpdated(status, result)
    controlUpdates[#controlUpdates + 1] = {
        Status = status,
        Result = result,
    }
end

function AngryEra:SendRequestDisplay()
    recoveryRequests = recoveryRequests + 1
    return true, "requested"
end

function AngryEra:ResetActivePageTransientState() end

function AngryEra:ResetDisplayPublicationState() end

function AngryEra:ResetSharedPageChangeState() end

function AngryEra:ResetDisplayNavigationState() end

function AngryEra:ResetGroupLayoutApplyState(preserveDisplayedReference)
    layoutApplyResets = layoutApplyResets + 1
    layoutApplyPreservedReference = preserveDisplayedReference
end

function AngryEra:ReleaseOwnedDisplayedNoteMarkers()
    markerOwnershipReleases = markerOwnershipReleases + 1
end

function AngryEra:PermissionsUpdated() end

function AngryEra:UpdateRaidControllerControls() end

function AngryEra:CancelDisplayRequestWatchdog() end

function AngryEra:CancelPendingDisplayRecovery() end

function AngryEra:GetActiveDisplayReference()
    return nil
end

function AngryEra:AcceptActiveDisplay(_, payload)
    return true,
        {
            Applied = true,
            Displayed = payload.Displayed == true,
            RequestNeeded = false,
        }
end

function AngryEra:ResolveDisplayDiscovery()
    return true
end

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
assert(loadfile("modules/protocol_runtime.lua"))("AngryEra", app)

local protocol = AngryEra.utils.protocol
local boundedControlTypes = {
    CONTROL_REQUEST = true,
    DISPLAY_REQUEST = true,
    VERSION_QUERY = true,
}

local function AssertFailure(ok, errorCode, expected, context)
    assert(ok == false or ok == nil, context .. " should fail")
    assert(errorCode == expected, string.format("%s: expected %s, got %s", context, expected, tostring(errorCode)))
end

local function BuildRemoteEnvelope(senderInstallation, senderSession, messageType, payload, options)
    options = options or {}
    local session = assert(protocol.NewSession(senderInstallation, senderSession))
    if options.Sequence then
        session.Sequence = options.Sequence - 1
    end
    local envelope = assert(protocol.BuildEnvelope(session, messageType, payload, {
        ReplyTo = options.ReplyTo,
        SentAt = options.SentAt or currentTime * 1000,
    }))
    local encoded
    local encodeError
    if messageType == "DISPLAY" then
        encoded, encodeError = protocol.EncodeCompactDisplayEnvelope(envelope, AngryEra:GetProtocolCodec())
    else
        local useControlCodec = options.ForceControl == true
            or (boundedControlTypes[messageType] and options.ForceGeneric ~= true)
        local codec = useControlCodec and AngryEra:GetProtocolControlCodec() or AngryEra:GetProtocolCodec()
        local limits = useControlCodec and AngryEra:GetProtocolControlWireLimits()
            or AngryEra:GetProtocolGenericWireLimits()
        encoded, encodeError = protocol.EncodeEnvelope(envelope, codec, limits)
    end
    assert(encoded, encodeError)
    return encoded, envelope
end

local function DecodeSent(index)
    local sent = sentMessages[index or #sentMessages]
    assert(sent, "expected a sent protocol message")
    local envelope, decodeError =
        protocol.DecodeEnvelope(sent.Data, AngryEra:GetProtocolCodec(), AngryEra:GetProtocolGenericWireLimits())
    if not envelope then
        envelope, decodeError = protocol.DecodeEnvelope(
            sent.Data,
            AngryEra:GetProtocolControlCodec(),
            AngryEra:GetProtocolControlWireLimits()
        )
    end
    assert(envelope, decodeError)
    return sent, envelope
end

local function FindSentType(messageType)
    for index = #sentMessages, 1, -1 do
        local _, envelope = DecodeSent(index)
        if envelope.Type == messageType then
            return sentMessages[index], envelope
        end
    end
end

local scenarioSequence = 0
local function ResetScenario(player, sessionId, roles, leader)
    scenarioSequence = scenarioSequence + 1
    currentTime = currentTime + 100
    preciseTime = preciseTime + 0.5
    currentPlayer = EnsureUnitFullName(player)
    raidLeader = EnsureUnitFullName(leader)
    members = {}
    for name, role in pairs(roles) do
        SetRole(name, role)
    end
    sentMessages = {}
    scheduledTimers = {}
    shownRequests = {}
    completedRequests = {}
    controlUpdates = {}
    recoveryRequests = 0
    disqualifiedRequesters = {}
    controllerOnline = true
    layoutApplyResets = 0
    layoutApplyPreservedReference = nil
    markerOwnershipReleases = 0
    receiveMode = "standard"
    printedMessages = {}
    AngryEra._testPreciseTimeAfterSend = nil
    local started, startError = AngryEra:StartProtocolSession(sessionId or ("local-" .. scenarioSequence))
    assert(started, startError)
    sentMessages = {}
end

local function RunTimer(timer)
    assert(timer and not timer.Canceled and not timer.Ran, "timer must be live")
    timer.Ran = true
    return AngryEra[timer.Method](AngryEra, timer.Argument)
end

local function LatestLiveTimer(method)
    for index = #scheduledTimers, 1, -1 do
        local timer = scheduledTimers[index]
        if timer.Method == method and not timer.Canceled and not timer.Ran then
            return timer
        end
    end
end

local function RequestId(installationId, sessionId, sequence)
    return table.concat({
        installationId,
        sessionId,
        tostring(sequence),
    }, ":")
end

local function GrantPayload(controller, installationId, sessionId, requestSequence)
    return {
        Controller = EnsureUnitFullName(controller),
        ControllerInstallationId = installationId,
        ControllerSessionId = sessionId,
        RequestId = RequestId(installationId, sessionId, requestSequence),
    }
end

local function VersionPayload()
    return {
        AddonVersion = "3.3.0",
        BuildTimestamp = "20260729000000",
        Flavor = "ERA",
        Capabilities = {
            [protocol.DELEGATED_CONTROL_CAPABILITY] = protocol.DELEGATED_CONTROL_CAPABILITY_VERSION,
        },
        AcceptsCurrentGroup = true,
    }
end

-- CONTROL_REQUEST uses the single-frame bounded DEFLATE lane in both directions.
ResetScenario("Zessy", "controller-bounded", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local requested, requestId = AngryEra:RequestDelegatedRaidControl()
assert(requested, requestId)
local outgoingRequest = AngryEra:GetPendingOutgoingDelegatedControlRequest(requestId)
assert(
    outgoingRequest
        and outgoingRequest.MessageId == requestId
        and outgoingRequest.Target == "Roselea-Realm"
        and outgoingRequest.TargetKey == "roselea-realm",
    "the UI-facing outgoing request snapshot should follow the exact runtime record"
)
local requestTransport, requestEnvelope = DecodeSent()
assert(requestEnvelope.Type == "CONTROL_REQUEST", "controller request should use the authority-control codec")
assert(
    requestTransport.Channel == "WHISPER" and requestTransport.Target == "Roselea-Realm",
    "request should whisper leader"
)
assert(requestTransport.Priority == "ALERT", "request should use ALERT priority")
assert(#requestTransport.Data <= 254, "bounded controller request should remain a single AceComm frame")
local genericRequest =
    protocol.DecodeEnvelope(requestTransport.Data, AngryEra:GetProtocolCodec(), AngryEra:GetProtocolGenericWireLimits())
assert(genericRequest == nil, "bounded controller request should not masquerade as a generic Huffman packet")

ResetScenario("Viewer", "bounded-receiver", {
    Viewer = "member",
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local boundedRequest = BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "controller-request", "CONTROL_REQUEST", {}, {
    Sequence = 3,
})
local accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, boundedRequest, "WHISPER", "Zessy-Realm")
AssertFailure(accepted, result, "not-raid-leader", "follower receiving a bounded controller request")

ResetScenario("Roselea", "leader-unqualified-request", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
disqualifiedRequesters[PlayerKey("Zessy")] = true
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, boundedRequest, "WHISPER", "Zessy-Realm")
AssertFailure(accepted, result, "unauthorized", "leader receiving an unqualified assistant request")

ResetScenario("Roselea", "leader-bounded", {
    Viewer = "member",
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local boundedRequestEnvelope
boundedRequest, boundedRequestEnvelope = BuildRemoteEnvelope(
    CONTROLLER_INSTALLATION,
    "controller-request",
    "CONTROL_REQUEST",
    {},
    {
        Sequence = 3,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, boundedRequest, "WHISPER", "Zessy-Realm")
assert(accepted, result)
assert(shownRequests[1] == boundedRequestEnvelope.MessageId, "bounded request should reach leader confirmation")

local smuggledPayload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "controller-request", 3)
local smuggledGrant, smuggledEnvelope =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-smuggle", "CONTROL_GRANT", smuggledPayload, {
        ForceControl = true,
        Sequence = 8,
    })
ResetScenario("Viewer", "smuggle-follower", {
    Viewer = "member",
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, smuggledGrant, "RAID", "Roselea-Realm")
AssertFailure(accepted, result, "invalid-transport-message-type", "grant smuggled through bounded control lane")
local genericGrant = assert(
    protocol.EncodeEnvelope(smuggledEnvelope, AngryEra:GetProtocolCodec(), AngryEra:GetProtocolGenericWireLimits())
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, genericGrant, "RAID", "Roselea-Realm")
assert(accepted, result)
assert(
    AngryEra:GetDelegatedRaidControl().GrantId == smuggledPayload.RequestId,
    "transport rejection must not poison retry"
)

-- A result and grant are both recoverable when the other half is delayed or lost.
ResetScenario("Zessy", "controller-recovery", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local querySent, queryId = AngryEra:SendProtocolVersionQuery(true)
assert(querySent, queryId)
local _, localQuery = DecodeSent()
local leaderVersion = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-recovery", "VERSION", VersionPayload(), {
    ReplyTo = localQuery.MessageId,
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderVersion, "WHISPER", "Roselea-Realm")
assert(accepted, result)
sentMessages = {}
requested, requestId = AngryEra:RequestDelegatedRaidControl()
assert(requested, requestId)

local wrongResult = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "wrong-leader-session", "CONTROL_RESULT", {
    Status = "declined",
}, {
    ReplyTo = requestId,
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, wrongResult, "WHISPER", "Roselea-Realm")
AssertFailure(accepted, result, "leader-session-changed", "first result from a replacement leader session")
assert(
    AngryEra:GetPendingOutgoingDelegatedControlRequest(requestId) == nil,
    "replacement leader result should retire the old exact request immediately"
)
assert(
    #completedRequests == 1
        and completedRequests[1].RequestId == requestId
        and completedRequests[1].Status == "stale"
        and completedRequests[1].Reason == "leader-session-changed",
    "replacement result should emit exactly one stale completion"
)
requested = AngryEra:RequestDelegatedRaidControl()
assert(requested, "replacement result should immediately re-enable Request")

ResetScenario("Zessy", "controller-result-recovery", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
querySent, queryId = AngryEra:SendProtocolVersionQuery(true)
assert(querySent, queryId)
_, localQuery = DecodeSent()
leaderVersion = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-recovery", "VERSION", VersionPayload(), {
    ReplyTo = localQuery.MessageId,
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderVersion, "WHISPER", "Roselea-Realm")
assert(accepted, result)
sentMessages = {}
requested, requestId = AngryEra:RequestDelegatedRaidControl()
assert(requested, requestId)

local grantedResult = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-recovery", "CONTROL_RESULT", {
    Status = "granted",
    GrantId = requestId,
}, {
    ReplyTo = requestId,
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, grantedResult, "WHISPER", "Roselea-Realm")
assert(accepted, result)
assert(recoveryRequests == 1, "granted result without grant should request authority recovery")
assert(#completedRequests == 1 and completedRequests[1].RequestId == requestId, "result should complete exact request")
assert(
    AngryEra:GetPendingOutgoingDelegatedControlRequest(requestId) == nil,
    "a terminal result should remove the UI-facing outgoing request"
)

local recoveryGrantPayload = {
    Controller = "Zessy-Realm",
    ControllerInstallationId = LOCAL_INSTALLATION,
    ControllerSessionId = "controller-result-recovery",
    RequestId = requestId,
}
local recoveredGrant =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-recovery", "CONTROL_GRANT", recoveryGrantPayload, {
        Sequence = 3,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, recoveredGrant, "RAID", "Roselea-Realm")
assert(accepted, result)
local recoveredControl = AngryEra:GetDelegatedRaidControl()
assert(recoveredControl and recoveredControl.GrantId == requestId, "late grant should recover a result-only lease")

-- A pending request initially binds an unknown leader process on first accepted
-- traffic, then terminates immediately when the same actual leader proves a
-- replacement process. The UI can request again without waiting for the TTL.
ResetScenario("Zessy", "outgoing-leader-reload", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
requested, requestId = AngryEra:RequestDelegatedRaidControl()
assert(requested, requestId)
local unboundOutgoing = AngryEra:GetPendingOutgoingDelegatedControlRequest(requestId)
assert(
    unboundOutgoing and unboundOutgoing.SenderInstallationId == nil and unboundOutgoing.SenderSessionId == nil,
    "request should safely start without cached leader process identity"
)
local leaderL1Query = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "outgoing-leader-l1", "VERSION_QUERY", {}, {
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderL1Query, "RAID", "Roselea-Realm")
assert(accepted, result)
local boundOutgoing = AngryEra:GetPendingOutgoingDelegatedControlRequest(requestId)
assert(
    boundOutgoing
        and boundOutgoing.SenderInstallationId == LEADER_INSTALLATION_A
        and boundOutgoing.SenderSessionId == "outgoing-leader-l1",
    "first accepted leader traffic should bind a previously unknown request target"
)
currentTime = currentTime + 1
local leaderL2Query = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "outgoing-leader-l2", "VERSION_QUERY", {}, {
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderL2Query, "RAID", "Roselea-Realm")
AssertFailure(accepted, result, "throttled", "replacement leader query inside reply throttle")
assert(
    AngryEra:GetPendingOutgoingDelegatedControlRequest(requestId) == nil,
    "replacement leader process should immediately retire the old pending request"
)
assert(
    #completedRequests == 1
        and completedRequests[1].RequestId == requestId
        and completedRequests[1].Status == "stale"
        and completedRequests[1].Reason == "leader-session-changed",
    "leader-session replacement should notify UI completion exactly once"
)
requested, requestId = AngryEra:RequestDelegatedRaidControl()
assert(requested, requestId)

ResetScenario("Zessy", "controller-result-lost", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
requested, requestId = AngryEra:RequestDelegatedRaidControl()
assert(requested, requestId)
local resultLostGrant = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-result-lost", "CONTROL_GRANT", {
    Controller = "Zessy-Realm",
    ControllerInstallationId = LOCAL_INSTALLATION,
    ControllerSessionId = "controller-result-lost",
    RequestId = requestId,
}, {
    Sequence = 7,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, resultLostGrant, "RAID", "Roselea-Realm")
assert(accepted, result)
assert(
    AngryEra:GetDelegatedRaidControl().GrantId == requestId,
    "broadcast grant should activate control even when whispered result is lost"
)

-- The exact controller may opt out after answering capability discovery but
-- before the leader's grant arrives. Accepting the lease must atomically restore
-- a shared receive mode so the canonical controller cannot ignore proposals.
do
    ResetScenario("Zessy", "controller-sharing-race", {
        Zessy = "assistant",
        Roselea = "leader",
    }, "Roselea")
    receiveMode = "ignoreShared"
    local sharingRacePayload = GrantPayload("Zessy", LOCAL_INSTALLATION, "controller-sharing-race", 4)
    local sharingRaceGrant =
        BuildRemoteEnvelope(LEADER_INSTALLATION_A, "sharing-race-leader", "CONTROL_GRANT", sharingRacePayload, {
            Sequence = 2,
        })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, sharingRaceGrant, "RAID", "Roselea-Realm")
    assert(accepted, result)
    assert(receiveMode == "standard", "local controller grant should normalize Ignore Shared back to standard")
    assert(
        #printedMessages == 1 and printedMessages[1]:find("must accept shared changes", 1, true),
        "receive-mode normalization should explain the controller requirement"
    )
end

-- A grant can arrive before Blizzard exposes the controller's assistant bit.
do
    ResetScenario("Viewer", "role-lag-follower", {
        Viewer = "member",
        Zessy = "member",
        Roselea = "leader",
    }, "Roselea")
    local roleLagPayload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "role-lag-controller", 4)
    local roleLagGrant =
        BuildRemoteEnvelope(LEADER_INSTALLATION_A, "role-lag-leader", "CONTROL_GRANT", roleLagPayload, {
            Sequence = 2,
        })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, roleLagGrant, "RAID", "Roselea-Realm")
    assert(accepted, result)
    local pendingRole = AngryEra:GetDelegatedRaidControl()
    assert(
        pendingRole and pendingRole.PendingRole and pendingRole.GrantId == roleLagPayload.RequestId,
        "role lag should pend"
    )
    local roleTimer = LatestLiveTimer("RetryPendingDelegatedRaidControl")
    assert(roleTimer and roleTimer.Delay == 0.25, "role lag should schedule the first bounded retry")
    SetRole("Zessy", "assistant")
    local reconciled, reconcileResult = RunTimer(roleTimer)
    assert(reconciled, reconcileResult)
    local roleReadyControl = AngryEra:GetDelegatedRaidControl()
    assert(
        roleReadyControl and roleReadyControl.Controller == "Zessy-Realm" and not roleReadyControl.PendingRole,
        "role retry should activate the exact pending grant"
    )
    assert(recoveryRequests == 0, "an ordinary nonlocal grant must not create a full-raid display request burst")

    -- Hard group reset clears state and keeps the retired leader session fenced.
    AngryEra:ResetProtocolPeers()
    assert(AngryEra:GetDelegatedRaidControl() == nil, "group reset should clear active delegated control")
    assert(AngryEra:GetProtocolDisplayAuthority() == nil, "group reset should clear the display binding")
    local delayedAfterReset =
        BuildRemoteEnvelope(LEADER_INSTALLATION_A, "role-lag-leader", "CONTROL_GRANT", roleLagPayload, {
            Sequence = 3,
        })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, delayedAfterReset, "RAID", "Roselea-Realm")
    AssertFailure(accepted, result, "stale-control-leader", "retired leader packet after group reset")

    -- A newly issued exact DISPLAY_REQUEST is a fresh challenge, so a follower
    -- rejoining the same ongoing raid can reactivate the unchanged leader process
    -- without making any uncorrelated pre-reset packet valid.
    local rejoinRequested, rejoinRequestId = AngryEra:SendProtocolDisplayRequest("Roselea-Realm")
    assert(rejoinRequested, rejoinRequestId)
    currentTime = currentTime + 1
    local rejoinDisplay = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "role-lag-leader", "DISPLAY", {
        Displayed = false,
    }, {
        ReplyTo = rejoinRequestId,
        Sequence = 4,
    })
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, rejoinDisplay, "WHISPER", "Roselea-Realm")
    assert(accepted, result)
    local rejoinedAuthority = AngryEra:GetProtocolDisplayAuthority()
    assert(
        rejoinedAuthority
            and rejoinedAuthority.SenderInstallationId == LEADER_INSTALLATION_A
            and rejoinedAuthority.SenderSessionId == "role-lag-leader",
        "fresh correlated recovery should reactivate the unchanged leader after rejoin"
    )
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, delayedAfterReset, "RAID", "Roselea-Realm")
    AssertFailure(accepted, result, "stale-control-order", "pre-reset leader packet after correlated rejoin recovery")
    local postRejoinGrant =
        BuildRemoteEnvelope(LEADER_INSTALLATION_A, "role-lag-leader", "CONTROL_GRANT", roleLagPayload, {
            Sequence = 5,
        })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, postRejoinGrant, "RAID", "Roselea-Realm")
    assert(accepted, result)
    assert(
        AngryEra:GetDelegatedRaidControl() and AngryEra:GetDelegatedRaidControl().GrantId == roleLagPayload.RequestId,
        "unchanged leader should publish fresh ordered control state after correlated rejoin recovery"
    )

    -- A follower that resets while the leader still has an active lease recovers
    -- that exact stable lease through its fresh DISPLAY_REQUEST challenge. The
    -- correlated response is recovery, not a new or implicit controller grant.
    AngryEra:ResetProtocolPeers()
    local leaseRecoveryRequested, leaseRecoveryRequestId = AngryEra:SendProtocolDisplayRequest("Roselea-Realm")
    assert(leaseRecoveryRequested, leaseRecoveryRequestId)
    local correlatedLeaseRecovery =
        BuildRemoteEnvelope(LEADER_INSTALLATION_A, "role-lag-leader", "CONTROL_GRANT", roleLagPayload, {
            ReplyTo = leaseRecoveryRequestId,
            Sequence = 6,
        })
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.PREFIX, correlatedLeaseRecovery, "WHISPER", "Roselea-Realm")
    assert(accepted, result)
    local restoredLease = AngryEra:GetDelegatedRaidControl()
    local restoredControllerAuthority = AngryEra:GetProtocolDisplayAuthority()
    assert(
        restoredLease
            and restoredLease.GrantId == roleLagPayload.RequestId
            and restoredControllerAuthority
            and restoredControllerAuthority.SenderInstallationId == CONTROLLER_INSTALLATION
            and restoredControllerAuthority.SenderSessionId == "role-lag-controller",
        "fresh correlated control recovery should restore only the exact active lease and controller session"
    )
    assert(recoveryRequests == 1, "only the follower recovering an active lease should challenge the controller")
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, postRejoinGrant, "RAID", "Roselea-Realm")
    AssertFailure(accepted, result, "stale-control-order", "old uncorrelated grant after exact lease recovery")
end

-- The exact controller install/session/request tuple is the lease identity.
ResetScenario("Zessy", "exact-controller-session", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local wrongIdentityPayload = GrantPayload("Zessy", OTHER_INSTALLATION, "other-controller-session", 5)
local invalidHighGrant =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "semantic-order-leader", "CONTROL_GRANT", wrongIdentityPayload, {
        Sequence = 100,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, invalidHighGrant, "RAID", "Roselea-Realm")
AssertFailure(accepted, result, "stale-controller-session", "grant bound to another local controller session")
assert(AngryEra:GetDelegatedRaidControl() == nil, "invalid exact identity must not activate control")

local exactPayload = GrantPayload("Zessy", LOCAL_INSTALLATION, "exact-controller-session", 6)
local validLowerGrant =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "semantic-order-leader", "CONTROL_GRANT", exactPayload, {
        Sequence = 10,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, validLowerGrant, "RAID", "Roselea-Realm")
assert(accepted, result)
local exactControl = AngryEra:GetDelegatedRaidControl()
local exactAuthority = AngryEra:GetProtocolDisplayAuthority()
assert(
    exactControl.ControllerInstallationId == LOCAL_INSTALLATION
        and exactControl.ControllerSessionId == "exact-controller-session"
        and exactControl.RequestId == exactPayload.RequestId
        and exactControl.ControllerSequenceFloor == 6,
    "accepted lease should retain the exact request-bound controller identity"
)
assert(
    exactAuthority.SenderInstallationId == LOCAL_INSTALLATION
        and exactAuthority.SenderSessionId == "exact-controller-session"
        and exactAuthority.MinimumSequenceExclusive == 6,
    "display authority should inherit the exact request sequence floor"
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, invalidHighGrant, "RAID", "Roselea-Realm")
AssertFailure(accepted, result, "duplicate", "replayed invalid semantic high sequence")

-- Grants and revokes are ordered, idempotent, and cannot roll back a newer tombstone.
do
    ResetScenario("Viewer", "ordered-follower", {
        Viewer = "member",
        Zessy = "assistant",
        Roselea = "leader",
    }, "Roselea")
    local orderedPayload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "ordered-controller", 11)
    local displayBeforeGrant = BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "ordered-controller", "DISPLAY", {
        Displayed = false,
    }, {
        Sequence = 12,
    })
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, displayBeforeGrant, "RAID", "Zessy-Realm")
    AssertFailure(accepted, result, "unbound-display-authority", "controller display racing before its grant")
    local recoveryRequestsBeforeGrant = recoveryRequests
    local orderedGrant = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "ordered-leader", "CONTROL_GRANT", orderedPayload, {
        Sequence = 2,
    })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, orderedGrant, "RAID", "Roselea-Realm")
    assert(accepted, result)
    assert(
        recoveryRequests == recoveryRequestsBeforeGrant + 1,
        "newly installed nonlocal grant should request the controller display missed before the grant"
    )
    assert(
        layoutApplyResets == 1 and layoutApplyPreservedReference == true and markerOwnershipReleases == 1,
        "an accepted authority handoff should cancel layout work and release marker ownership once"
    )
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, orderedGrant, "RAID", "Roselea-Realm")
    AssertFailure(accepted, result, "stale-control-order", "replayed canonical grant")
    assert(
        layoutApplyResets == 1 and markerOwnershipReleases == 1,
        "a rejected replay must not rerun authority-handoff cleanup"
    )
    local leaderDisplayBeforeRevoke = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "ordered-leader", "DISPLAY", {
        Displayed = false,
    }, {
        Sequence = 3,
    })
    accepted, result =
        AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, leaderDisplayBeforeRevoke, "RAID", "Roselea-Realm")
    AssertFailure(accepted, result, "stale-display-authority", "leader display racing before its revoke")
    local recoveryRequestsBeforeRevoke = recoveryRequests
    local orderedRevoke = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "ordered-leader", "CONTROL_REVOKE", {
        GrantId = orderedPayload.RequestId,
    }, {
        Sequence = 4,
    })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, orderedRevoke, "RAID", "Roselea-Realm")
    assert(accepted, result)
    assert(AngryEra:GetDelegatedRaidControl() == nil, "newer revoke should clear the lease")
    assert(
        recoveryRequests == recoveryRequestsBeforeRevoke + 1,
        "revoke should request the leader display observed before the authority transition"
    )
    assert(
        layoutApplyResets == 2 and layoutApplyPreservedReference == true and markerOwnershipReleases == 2,
        "reclaiming authority should run the same exact cleanup boundary once"
    )
    local staleOrderedGrant =
        BuildRemoteEnvelope(LEADER_INSTALLATION_A, "ordered-leader", "CONTROL_GRANT", orderedPayload, {
            Sequence = 3,
        })
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, staleOrderedGrant, "RAID", "Roselea-Realm")
    AssertFailure(accepted, result, "stale-control-order", "grant older than revoke")
    accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, orderedRevoke, "RAID", "Roselea-Realm")
    AssertFailure(accepted, result, "stale-control-order", "replayed canonical revoke")
end

-- Regranting the same controller process is safe only above the new request
-- sequence floor; queued display traffic from its previous lease stays fenced.
ResetScenario("Viewer", "same-controller-regrant", {
    Viewer = "member",
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local firstRegrantPayload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "regranted-controller", 5)
local firstRegrant =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "regrant-leader", "CONTROL_GRANT", firstRegrantPayload, {
        Sequence = 2,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, firstRegrant, "RAID", "Roselea-Realm")
assert(accepted, result)
local firstLeaseDisplay = BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "regranted-controller", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 6,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, firstLeaseDisplay, "RAID", "Zessy-Realm")
assert(accepted, result)
local betweenGrantRevoke = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "regrant-leader", "CONTROL_REVOKE", {
    GrantId = firstRegrantPayload.RequestId,
}, {
    Sequence = 3,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, betweenGrantRevoke, "RAID", "Roselea-Realm")
assert(accepted, result)

local secondRegrantPayload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "regranted-controller", 20)
local secondRegrant =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "regrant-leader", "CONTROL_GRANT", secondRegrantPayload, {
        Sequence = 4,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, secondRegrant, "RAID", "Roselea-Realm")
assert(accepted, result)
assert(
    AngryEra:GetDelegatedRaidControl().ControllerSequenceFloor == 20,
    "new grant should replace the same controller's request sequence floor"
)
local queuedOldDisplay = BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "regranted-controller", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 20,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, queuedOldDisplay, "RAID", "Zessy-Realm")
AssertFailure(accepted, result, "stale-delegated-authority", "queued display at the regrant floor")
local staleTimestampRegrantedDisplay = BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "regranted-controller", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 21,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, staleTimestampRegrantedDisplay, "RAID", "Zessy-Realm")
AssertFailure(accepted, result, "stale-display-timestamp", "regranted display reusing the previous lease timestamp")
currentTime = currentTime + 1
local freshRegrantedDisplay = BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "regranted-controller", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 21,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, freshRegrantedDisplay, "RAID", "Zessy-Realm")
assert(accepted, result)

-- A -> B -> A uses exact leader sessions; delayed packets from A1 stay retired.
ResetScenario("Viewer", "leader-cycle-follower", {
    Viewer = "member",
    Zessy = "assistant",
    Roselea = "leader",
    Eblis = "member",
}, "Roselea")
local cyclePayload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "cycle-controller", 9)
local leaderA1Query = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-a1", "VERSION_QUERY", {}, {
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderA1Query, "RAID", "Roselea-Realm")
assert(accepted, result)
local leaderA1Grant = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-a1", "CONTROL_GRANT", cyclePayload, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderA1Grant, "RAID", "Roselea-Realm")
assert(accepted, result)

SetRole("Roselea", "member")
SetRole("Eblis", "leader")
raidLeader = "Eblis-Realm"
currentTime = currentTime + 3
local leaderB1Query = BuildRemoteEnvelope(LEADER_INSTALLATION_B, "leader-b1", "VERSION_QUERY", {}, {
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderB1Query, "RAID", "Eblis-Realm")
assert(accepted, result)
assert(AngryEra:GetDelegatedRaidControl() == nil, "B1 should clear A1's delegated tenure")
local leaderB1Grant = BuildRemoteEnvelope(LEADER_INSTALLATION_B, "leader-b1", "CONTROL_GRANT", cyclePayload, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderB1Grant, "RAID", "Eblis-Realm")
assert(accepted, result)

SetRole("Eblis", "member")
SetRole("Roselea", "leader")
raidLeader = "Roselea-Realm"
currentTime = currentTime + 3
local leaderA2Query = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-a2", "VERSION_QUERY", {}, {
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderA2Query, "RAID", "Roselea-Realm")
assert(accepted, result)
assert(AngryEra:GetDelegatedRaidControl() == nil, "A2 should clear B1's delegated tenure")
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderA1Grant, "RAID", "Roselea-Realm")
AssertFailure(accepted, result, "stale-control-leader", "delayed A1 grant after A2")
local leaderA2Grant = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-a2", "CONTROL_GRANT", cyclePayload, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderA2Grant, "RAID", "Roselea-Realm")
assert(accepted, result)
assert(
    AngryEra:GetDelegatedRaidControl().LeaderSessionId == "leader-a2",
    "A2 should establish the only live Roselea tenure"
)

-- A newly observed leader session fences even an older session that was never
-- seen locally, and its VERSION_QUERY sequence advances canonical high-water.
ResetScenario("Viewer", "leader-watermark-follower", {
    Viewer = "member",
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local watermarkSentAt = currentTime * 1000 + 500
local leaderWatermarkQuery = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-l2-watermark", "VERSION_QUERY", {}, {
    SentAt = watermarkSentAt,
    Sequence = 20,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderWatermarkQuery, "RAID", "Roselea-Realm")
assert(accepted, result)
local neverSeenL1Payload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "watermark-controller", 4)
local neverSeenL1Grant =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-l1-never-seen", "CONTROL_GRANT", neverSeenL1Payload, {
        SentAt = watermarkSentAt - 1,
        Sequence = 99,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, neverSeenL1Grant, "RAID", "Roselea-Realm")
AssertFailure(accepted, result, "stale-control-leader", "never-seen L1 grant older than observed L2")
local liveL2Grant =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-l2-watermark", "CONTROL_GRANT", neverSeenL1Payload, {
        SentAt = watermarkSentAt + 1,
        Sequence = 21,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, liveL2Grant, "RAID", "Roselea-Realm")
assert(accepted, result)
assert(
    AngryEra:GetDelegatedRaidControl().LeaderSessionId == "leader-l2-watermark",
    "new leader-session watermark should remain usable"
)

ResetScenario("Viewer", "leader-sequence-highwater", {
    Viewer = "member",
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local highwaterQuery = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-highwater", "VERSION_QUERY", {}, {
    Sequence = 30,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, highwaterQuery, "RAID", "Roselea-Realm")
assert(accepted, result)
local highwaterPayload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "highwater-controller", 7)
local grantBelowQuery =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-highwater", "CONTROL_GRANT", highwaterPayload, {
        Sequence = 29,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, grantBelowQuery, "RAID", "Roselea-Realm")
AssertFailure(accepted, result, "stale-control-order", "grant below same-session query high-water")
local revokeAtQuery = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-highwater", "CONTROL_REVOKE", {
    GrantId = highwaterPayload.RequestId,
}, {
    Sequence = 30,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, revokeAtQuery, "RAID", "Roselea-Realm")
AssertFailure(accepted, result, "stale-control-order", "revoke at same-session query high-water")
local grantAboveQuery =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "leader-highwater", "CONTROL_GRANT", highwaterPayload, {
        Sequence = 31,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, grantAboveQuery, "RAID", "Roselea-Realm")
assert(accepted, result)

-- An uncorrelated packet from the actual leader's replacement session cannot
-- steal authority. A reply to an exact pending DISPLAY_REQUEST can terminate
-- the now-stale L1 lease and bind that proven L2 session without deadlocking.
ResetScenario("Viewer", "correlated-leader-recovery", {
    Viewer = "assistant",
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local staleControlPayload = GrantPayload("Zessy", CONTROLLER_INSTALLATION, "stale-controller", 6)
local staleControlGrant =
    BuildRemoteEnvelope(LEADER_INSTALLATION_A, "stale-leader-l1", "CONTROL_GRANT", staleControlPayload, {
        Sequence = 2,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, staleControlGrant, "RAID", "Roselea-Realm")
assert(accepted, result)
assert(
    AngryEra:GetDelegatedRaidControl().LeaderSessionId == "stale-leader-l1",
    "L1 lease should be active before recovery"
)

sentMessages = {}
querySent, queryId = AngryEra:SendProtocolVersionQuery(true)
assert(querySent, queryId)
local _, recoveryQuery = DecodeSent()
local leaderL2Version = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "recovery-leader-l2", "VERSION", VersionPayload(), {
    ReplyTo = recoveryQuery.MessageId,
    Sequence = 1,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, leaderL2Version, "WHISPER", "Roselea-Realm")
assert(accepted, result)

local uncorrelatedL2Display = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "recovery-leader-l2", "DISPLAY", {
    Displayed = false,
}, {
    Sequence = 2,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, uncorrelatedL2Display, "RAID", "Roselea-Realm")
assert(not accepted and type(result) == "string", "uncorrelated L2 display should remain unauthorized")
assert(
    AngryEra:GetDelegatedRaidControl().LeaderSessionId == "stale-leader-l1",
    "uncorrelated L2 display must leave L1 control intact"
)

sentMessages = {}
local displayRequested, displayRequestId = AngryEra:SendProtocolDisplayRequest("Roselea-Realm")
assert(displayRequested, displayRequestId)
local _, displayRequestEnvelope = DecodeSent()
assert(displayRequestEnvelope.MessageId == displayRequestId, "display recovery should retain exact correlation id")
local wrongSessionDisplay = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "wrong-recovery-session", "DISPLAY", {
    Displayed = false,
}, {
    ReplyTo = displayRequestId,
    Sequence = 1,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, wrongSessionDisplay, "WHISPER", "Roselea-Realm")
AssertFailure(accepted, result, "uncorrelated-reply", "correlated display from wrong exact leader session")
assert(AngryEra:GetDelegatedRaidControl() ~= nil, "wrong-session reply must not clear L1 control")

local correlatedL2Display = BuildRemoteEnvelope(LEADER_INSTALLATION_A, "recovery-leader-l2", "DISPLAY", {
    Displayed = false,
}, {
    ReplyTo = displayRequestId,
    Sequence = 3,
})
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.DISPLAY_PREFIX, correlatedL2Display, "WHISPER", "Roselea-Realm")
assert(accepted, result)
assert(AngryEra:GetDelegatedRaidControl() == nil, "exact correlated L2 display should terminate stale L1 control")
local recoveredLeaderAuthority = AngryEra:GetProtocolDisplayAuthority()
assert(
    recoveredLeaderAuthority
        and recoveredLeaderAuthority.Sender == "Roselea-Realm"
        and recoveredLeaderAuthority.SenderSessionId == "recovery-leader-l2",
    "exact correlated L2 display should bind the proven replacement leader session"
)

-- Concurrent requests share one discovery broadcast, but each exact requester
-- still has to answer that shared query for itself.
ResetScenario("Roselea", "concurrent-controller-discovery", {
    Zessy = "assistant",
    Zessling = "assistant",
    Roselea = "leader",
}, "Roselea")
local concurrentRequestA, concurrentEnvelopeA = BuildRemoteEnvelope(
    CONTROLLER_INSTALLATION,
    "concurrent-controller-a",
    "CONTROL_REQUEST",
    {},
    {
        Sequence = 1,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, concurrentRequestA, "WHISPER", "Zessy-Realm")
assert(accepted, result)
local concurrentRequestB, concurrentEnvelopeB = BuildRemoteEnvelope(
    OTHER_INSTALLATION,
    "concurrent-controller-b",
    "CONTROL_REQUEST",
    {},
    {
        Sequence = 1,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, concurrentRequestB, "WHISPER", "Zessling-Realm")
assert(accepted, result)
local discoveryCount = 0
local sharedDiscoveryQuery
for index = 1, #sentMessages do
    local _, envelope = DecodeSent(index)
    if envelope.Type == "VERSION_QUERY" then
        discoveryCount = discoveryCount + 1
        sharedDiscoveryQuery = envelope
    end
end
assert(discoveryCount == 1 and sharedDiscoveryQuery, "concurrent requests should share one discovery query")
local concurrentVersionA =
    BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "concurrent-controller-a", "VERSION", VersionPayload(), {
        ReplyTo = sharedDiscoveryQuery.MessageId,
        Sequence = 2,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, concurrentVersionA, "WHISPER", "Zessy-Realm")
assert(accepted, result)
currentTime = currentTime + 2
local controllerBGranted, controllerBError, _, controllerBCompatibility =
    AngryEra:GrantDelegatedRaidControl(concurrentEnvelopeB.MessageId)
AssertFailure(
    controllerBGranted,
    controllerBError,
    "capability-check-pending",
    "unanswered concurrent controller request"
)
assert(
    controllerBCompatibility and controllerBCompatibility.ControllerStatus == "pending",
    "controller A's reply must not make controller B ready"
)
assert(
    AngryEra:GetPendingDelegatedControlRequest(concurrentEnvelopeA.MessageId) ~= nil,
    "controller A's request should remain independently correlated"
)

-- The leader grants only after the exact requesting controller session answers
-- discovery and explicitly accepts this group. Unknown state remains pending;
-- an explicit opt-out fails closed and removes the stale request.
ResetScenario("Roselea", "unknown-controller-capability", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local unknownControllerRequest, unknownControllerEnvelope = BuildRemoteEnvelope(
    CONTROLLER_INSTALLATION,
    "unknown-controller",
    "CONTROL_REQUEST",
    {},
    {
        Sequence = 1,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, unknownControllerRequest, "WHISPER", "Zessy-Realm")
assert(accepted, result)
currentTime = currentTime + 2
local unknownGranted, unknownGrantError, _, unknownCompatibility =
    AngryEra:GrantDelegatedRaidControl(unknownControllerEnvelope.MessageId)
AssertFailure(unknownGranted, unknownGrantError, "capability-check-pending", "unknown exact controller capability")
assert(
    unknownCompatibility and unknownCompatibility.ControllerStatus == "pending",
    "unknown exact controller should remain pending discovery"
)
assert(
    AngryEra:GetPendingDelegatedControlRequest(unknownControllerEnvelope.MessageId) ~= nil,
    "unknown exact controller request should remain available after another discovery round"
)

ResetScenario("Roselea", "disabled-controller-sharing", {
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local disabledControllerRequest, disabledControllerEnvelope = BuildRemoteEnvelope(
    CONTROLLER_INSTALLATION,
    "disabled-controller",
    "CONTROL_REQUEST",
    {},
    {
        Sequence = 1,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, disabledControllerRequest, "WHISPER", "Zessy-Realm")
assert(accepted, result)
local _, disabledDiscoveryQuery = FindSentType("VERSION_QUERY")
assert(disabledDiscoveryQuery, "controller request should trigger exact capability discovery")
local disabledVersionPayload = VersionPayload()
disabledVersionPayload.AcceptsCurrentGroup = false
local disabledControllerVersion =
    BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "disabled-controller", "VERSION", disabledVersionPayload, {
        ReplyTo = disabledDiscoveryQuery.MessageId,
        Sequence = 2,
    })
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, disabledControllerVersion, "WHISPER", "Zessy-Realm")
assert(accepted, result)
currentTime = currentTime + 2
local disabledGranted, disabledGrantError, disabledCompatibility =
    AngryEra:GrantDelegatedRaidControl(disabledControllerEnvelope.MessageId)
AssertFailure(disabledGranted, disabledGrantError, "incompatible", "controller with sharing disabled")
assert(
    disabledCompatibility and disabledCompatibility.ControllerStatus == "sharing-disabled",
    "explicit controller opt-out should be reported precisely"
)
assert(
    AngryEra:GetPendingDelegatedControlRequest(disabledControllerEnvelope.MessageId) == nil,
    "explicit controller opt-out should consume the incompatible request"
)

-- The actual leader re-broadcasts stable authority to late followers, then reclaims it.
ResetScenario("Roselea", "local-leader-controller", {
    Viewer = "member",
    Zessy = "assistant",
    Roselea = "leader",
}, "Roselea")
local remoteControlRequest, remoteControlEnvelope = BuildRemoteEnvelope(
    CONTROLLER_INSTALLATION,
    "late-controller",
    "CONTROL_REQUEST",
    {},
    {
        Sequence = 5,
    }
)
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, remoteControlRequest, "WHISPER", "Zessy-Realm")
assert(accepted, result)
assert(AngryEra:GetPendingDelegatedControlRequest(remoteControlEnvelope.MessageId), "leader should retain request")
local _, controllerDiscoveryQuery = FindSentType("VERSION_QUERY")
assert(controllerDiscoveryQuery, "leader should query the exact requested controller session")
local controllerVersion = BuildRemoteEnvelope(CONTROLLER_INSTALLATION, "late-controller", "VERSION", VersionPayload(), {
    ReplyTo = controllerDiscoveryQuery.MessageId,
    Sequence = 6,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, controllerVersion, "WHISPER", "Zessy-Realm")
assert(accepted, result)
currentTime = currentTime + 2
preciseTime = math.floor(preciseTime) + 0.999
AngryEra._testPreciseTimeAfterSend = math.floor(preciseTime) + 1.001
local granted, grantResult = AngryEra:GrantDelegatedRaidControl(remoteControlEnvelope.MessageId)
assert(granted, grantResult)
local localControl = AngryEra:GetDelegatedRaidControl()
assert(localControl and localControl.ControllerSessionId == "late-controller", "leader should grant exact request")
AngryEra._testLocalGrantEnvelope = select(2, FindSentType("CONTROL_GRANT"))
assert(AngryEra._testLocalGrantEnvelope, "local leader grant should be observable on the wire")
currentPlayer = "Viewer-Realm"
AngryEra._testEqualGrantTimestampQuery = BuildRemoteEnvelope(
    LOCAL_INSTALLATION,
    "leader-after-grant",
    "VERSION_QUERY",
    {},
    {
        SentAt = AngryEra._testLocalGrantEnvelope.SentAt,
        Sequence = 1,
    }
)
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, AngryEra._testEqualGrantTimestampQuery, "RAID", "Roselea-Realm")
AssertFailure(
    accepted,
    result,
    "stale-control-leader",
    "local grant watermark should equal the transmitted envelope timestamp"
)
currentPlayer = "Roselea-Realm"
AngryEra._testEqualGrantTimestampQuery = nil
AngryEra._testLocalGrantEnvelope = nil
sentMessages = {}

-- Qualification is a grant-time gate. Temporary guild/trust cache changes or
-- controller offline state fail closed without silently returning authority;
-- assistant-rank/session/leader boundaries and explicit Reclaim remain decisive.
local savedQualificationCheck = AngryEra.IsQualifiedAssistant
AngryEra.IsQualifiedAssistant = function()
    return false
end
controllerOnline = false
local stable, stableResult = AngryEra:ReconcileDelegatedRaidControl("policy-cache-changed")
assert(stable and stableResult.Changed == false, "temporary qualification/offline changes should keep the lease")
assert(
    AngryEra:GetDelegatedRaidControl() and AngryEra:GetDelegatedRaidControl().ControllerSessionId == "late-controller",
    "offline controller should pause authority without implicit reclaim"
)
assert(FindSentType("CONTROL_REVOKE") == nil, "offline/qualification changes must not broadcast an implicit revoke")
AngryEra.IsQualifiedAssistant = savedQualificationCheck
controllerOnline = true

AngryEra._testLateFollowerRequestEncoded, AngryEra._testLateFollowerRequestEnvelope = BuildRemoteEnvelope(
    OTHER_INSTALLATION,
    "late-follower",
    "DISPLAY_REQUEST",
    {},
    {
        Sequence = 1,
    }
)
controllerOnline = false
accepted, result = AngryEra:ReceiveProtocolMessage(
    protocol.PREFIX,
    AngryEra._testLateFollowerRequestEncoded,
    "WHISPER",
    "Viewer-Realm"
)
controllerOnline = true
assert(accepted, result)
local rebroadcastTransport, rebroadcastEnvelope = FindSentType("CONTROL_GRANT")
assert(rebroadcastTransport and rebroadcastEnvelope, "late follower should trigger a stable grant rebroadcast")
assert(
    rebroadcastTransport.Channel == "WHISPER"
        and rebroadcastTransport.Target == "Viewer-Realm"
        and rebroadcastEnvelope.ReplyTo == AngryEra._testLateFollowerRequestEnvelope.MessageId
        and rebroadcastEnvelope.Payload.RequestId == remoteControlEnvelope.MessageId,
    "recovery response must correlate the original stable grant to the exact follower challenge"
)
AngryEra._testLateFollowerRequestEnvelope = nil
AngryEra._testLateFollowerRequestEncoded = nil
local rebroadcastSequence = rebroadcastEnvelope.Sequence
sentMessages = {}
local secondFollowerRequest = BuildRemoteEnvelope(OTHER_INSTALLATION, "late-follower", "DISPLAY_REQUEST", {}, {
    Sequence = 2,
})
accepted, result = AngryEra:ReceiveProtocolMessage(protocol.PREFIX, secondFollowerRequest, "WHISPER", "Viewer-Realm")
AssertFailure(accepted, result, "throttled", "duplicate late-follower recovery during throttle")
assert(#sentMessages == 0, "throttled late-follower request should not chatter")

currentTime = currentTime + 1
preciseTime = math.floor(preciseTime) + 0.999
AngryEra._testPreciseTimeAfterSend = math.floor(preciseTime) + 1.001
local reclaimed, reclaimedGrantId = AngryEra:ReclaimDelegatedRaidControl()
assert(reclaimed and reclaimedGrantId == remoteControlEnvelope.MessageId, "leader should reclaim exact active grant")
assert(AngryEra:GetDelegatedRaidControl() == nil, "reclaim should clear delegated authority")
AngryEra._testReclaimEnvelope = select(2, FindSentType("CONTROL_REVOKE"))
assert(
    AngryEra._testReclaimEnvelope.Sequence > rebroadcastSequence,
    "reclaim revoke should order after grant rebroadcast"
)
currentPlayer = "Viewer-Realm"
AngryEra._testEqualRevokeTimestampQuery = BuildRemoteEnvelope(
    LOCAL_INSTALLATION,
    "leader-after-revoke",
    "VERSION_QUERY",
    {},
    {
        SentAt = AngryEra._testReclaimEnvelope.SentAt,
        Sequence = 1,
    }
)
accepted, result =
    AngryEra:ReceiveProtocolMessage(protocol.PREFIX, AngryEra._testEqualRevokeTimestampQuery, "RAID", "Roselea-Realm")
AssertFailure(
    accepted,
    result,
    "stale-control-leader",
    "local revoke watermark should equal the transmitted envelope timestamp"
)
currentPlayer = "Roselea-Realm"
AngryEra._testEqualRevokeTimestampQuery = nil
sentMessages = {}
local revokeRebroadcast, revokeGrantId = AngryEra:BroadcastDelegatedControlRevocation()
assert(revokeRebroadcast and revokeGrantId == reclaimedGrantId, "leader should retain a late-follower revoke tombstone")
local _, revokeRebroadcastEnvelope = DecodeSent()
assert(
    revokeRebroadcastEnvelope.Type == "CONTROL_REVOKE"
        and revokeRebroadcastEnvelope.Payload.GrantId == reclaimedGrantId
        and revokeRebroadcastEnvelope.Sequence > AngryEra._testReclaimEnvelope.Sequence,
    "revoke rebroadcast should preserve id and advance canonical ordering"
)
AngryEra._testReclaimEnvelope = nil

print("Delegated control runtime tests passed.")
