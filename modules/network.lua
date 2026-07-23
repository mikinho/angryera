-- -------------------------------------------------------------------------------
-- Angry Era: modules/network.lua
--
-- Protocol-v3 active-page publication throttles and group diagnostics.
-- Envelope validation, correlation, and inbound dispatch live in
-- protocol_runtime.lua; canonical page preparation lives in sync/page_runtime.lua.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local helpers = AngryEra.utils.helpers
local EnsureUnitShortName = helpers.EnsureUnitShortName
local PlayerFullName = helpers.PlayerFullName
local IterateGroupMembers = helpers.IterateGroupMembers

local updateFrequency = AngryEra.core.updateFrequency
local displayPageDebounce = 0.125
-- Promised group pages need a long grace period so a large/low-FPS transfer
-- does not make every receiver request a duplicate at once. A targeted request
-- gets a shorter watchdog because only that receiver retries it.
local pendingDisplayRecoveryDelay = math.max(updateFrequency * 15, 30)
local requestedDisplayRecoveryDelay = math.max(updateFrequency * 2, 5)
local maximumDisplayRecoveryAttempts = 3

local pageLastUpdate = {}
local pageTimerId = {}
local displayLastUpdate
local displayTimerId
local pendingDisplayRecoveryTimer
local pendingDisplayRecovery
local pendingDisplayRecoveryGeneration = 0
local pendingDisplayPage
local pendingDisplayPageTimer
local displayPageGeneration = 0
local activeDisplayPageTransfer
local publishedDisplayTuples = {}
local SamePageTuple

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
    return math.floor(value * 1000)
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

local function IsGrouped()
    return IsInRaid() or IsInGroup()
end

local function CancelTimer(self, timerId)
    if timerId then
        self:CancelTimer(timerId)
    end
end

local function PageTuple(payload)
    local page = type(payload) == "table" and payload.Page or nil
    if
        type(page) ~= "table"
        or type(page.SyncId) ~= "string"
        or type(page.RevisionId) ~= "string"
        or type(payload.ContextRevisionId) ~= "string"
    then
        return nil
    end
    return {
        SyncId = page.SyncId,
        RevisionId = page.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
end

local function IsPublishedDisplayTuple(payload)
    local tuple = PageTuple(payload)
    local published = tuple and publishedDisplayTuples[tuple.SyncId] or nil
    return type(published) == "table"
        and published.RevisionId == tuple.RevisionId
        and published.ContextRevisionId == tuple.ContextRevisionId
end

local function RememberPublishedDisplayTuple(payload)
    local tuple = PageTuple(payload)
    if not tuple then
        return false
    end
    publishedDisplayTuples[tuple.SyncId] = {
        RevisionId = tuple.RevisionId,
        ContextRevisionId = tuple.ContextRevisionId,
    }
    return true
end

local function ReannounceFailedDisplayPage(state, status)
    if
        type(state) ~= "table"
        or state.FailureReannounced
        or status == "superseded"
        or type(state.Self) ~= "table"
        or type(state.Self.GetActiveDisplayReference) ~= "function"
        or type(state.Self.SendProtocolDisplay) ~= "function"
        or type(state.Self.CanLocalPlayerPublish) ~= "function"
        or not state.Self:CanLocalPlayerPublish("display")
    then
        return false
    end

    local queried, active = pcall(state.Self.GetActiveDisplayReference, state.Self)
    local tuple = PageTuple(state.Payload)
    if
        not queried
        or type(active) ~= "table"
        or not tuple
        or active.SyncId ~= tuple.SyncId
        or active.RevisionId ~= tuple.RevisionId
        or active.ContextRevisionId ~= tuple.ContextRevisionId
    then
        return false
    end

    state.FailureReannounced = true
    local sent, result = state.Self:SendProtocolDisplay({
        Displayed = true,
        SyncId = tuple.SyncId,
        RevisionId = tuple.RevisionId,
        ContextRevisionId = tuple.ContextRevisionId,
    })
    if state.Debug then
        Trace(
            state.Self,
            "page-failure-reannounce",
            "id=%s generation=%d sent=%s status=%s message=%s",
            tostring(state.Id),
            state.Generation,
            tostring(sent == true),
            tostring(status),
            tostring(result)
        )
    end
    return sent == true
end

local function DisplayPageTransferCompleted(state, succeeded, status, messageId)
    if type(state) ~= "table" or not state.Self then
        return
    end
    if succeeded then
        RememberPublishedDisplayTuple(state.Payload)
        pageLastUpdate[state.Id] = time()
    else
        ReannounceFailedDisplayPage(state, status)
    end
    if activeDisplayPageTransfer == state then
        activeDisplayPageTransfer = nil
    end
    if state.Debug then
        Trace(
            state.Self,
            succeeded and "page-published" or "page-not-published",
            "id=%s generation=%d message=%s status=%s",
            tostring(state.Id),
            state.Generation,
            tostring(messageId),
            tostring(status)
        )
    end
end

SamePageTuple = function(left, right)
    local leftTuple = PageTuple(left)
    local rightTuple = PageTuple(right)
    return leftTuple ~= nil
        and rightTuple ~= nil
        and leftTuple.SyncId == rightTuple.SyncId
        and leftTuple.RevisionId == rightTuple.RevisionId
        and leftTuple.ContextRevisionId == rightTuple.ContextRevisionId
end

local function ActiveDisplayMatches(self, payload)
    if type(self.GetActiveDisplayReference) ~= "function" then
        return false
    end
    local queried, reference = pcall(self.GetActiveDisplayReference, self)
    if not queried or type(reference) ~= "table" then
        return false
    end
    return SamePageTuple(payload, {
        Page = {
            SyncId = reference.SyncId,
            RevisionId = reference.RevisionId,
        },
        ContextRevisionId = reference.ContextRevisionId,
    })
end

local function CancelPendingDisplayPage(self, reason)
    local pending = pendingDisplayPage
    displayPageGeneration = displayPageGeneration + 1
    CancelTimer(self, pendingDisplayPageTimer)
    pendingDisplayPageTimer = nil
    pendingDisplayPage = nil
    if pending and pending.Debug then
        Trace(
            self,
            "page-debounce-drop",
            "id=%s generation=%d reason=%s",
            tostring(pending.Id),
            pending.Generation,
            tostring(reason or "superseded")
        )
    end
    if type(self.CancelProtocolActivePageTransfer) == "function" then
        self:CancelProtocolActivePageTransfer(reason or "superseded")
    end
end

local function QueueDisplayPage(self, id, payload)
    if IsPublishedDisplayTuple(payload) then
        CancelPendingDisplayPage(self, "superseded")
        if IsDebugEnabled(self) then
            Trace(self, "page-cache-hit", "id=%s status=already-published", tostring(id))
        end
        return true, "already-published"
    end
    if pendingDisplayPage and SamePageTuple(pendingDisplayPage.Payload, payload) then
        if pendingDisplayPage.Debug then
            Trace(
                self,
                "page-debounce-reuse",
                "id=%s generation=%d status=scheduled",
                tostring(id),
                pendingDisplayPage.Generation
            )
        end
        return true, "already-scheduled"
    end
    if activeDisplayPageTransfer and SamePageTuple(activeDisplayPageTransfer.Payload, payload) then
        if activeDisplayPageTransfer.Debug then
            Trace(
                self,
                "page-stream-reuse",
                "id=%s generation=%d status=in-flight",
                tostring(id),
                activeDisplayPageTransfer.Generation
            )
        end
        return true, "already-streaming"
    end
    CancelPendingDisplayPage(self, "superseded")
    local debugEnabled = IsDebugEnabled(self)
    pendingDisplayPage = {
        Debug = debugEnabled,
        Generation = displayPageGeneration,
        Id = id,
        Payload = payload,
        QueuedAt = debugEnabled and PreciseNowMilliseconds() or 0,
    }
    pendingDisplayPageTimer = self:ScheduleTimer("SendDisplayPageMessage", displayPageDebounce, displayPageGeneration)
    if not pendingDisplayPageTimer then
        pendingDisplayPage = nil
        return false, "page-publication-schedule-failed"
    end
    if debugEnabled then
        Trace(
            self,
            "page-debounce-start",
            "id=%s generation=%d delay=%dms",
            tostring(id),
            displayPageGeneration,
            math.floor(displayPageDebounce * 1000)
        )
    end
    return true, "scheduled"
end

local function PreparePage(self, id)
    if type(self.PrepareActivePageUpsert) ~= "function" then
        return nil, "active-page-runtime-unavailable"
    end

    local author = PlayerFullName()
    if type(author) ~= "string" or author == "" then
        return nil, "invalid-local-author"
    end
    return self:PrepareActivePageUpsert(id, {
        UpdatedAt = time(),
        UpdatedBy = author,
    })
end

local function SendPreparedPage(self, id)
    local payload, preparationError = PreparePage(self, id)
    if not payload then
        return false, preparationError
    end

    local sent, result = self:SendProtocolPageUpsert(payload)
    if not sent then
        return false, result
    end
    pageLastUpdate[id] = time()
    return true, payload
end

local function CopyDisplayEnvelope(envelope)
    if type(envelope) ~= "table" or type(envelope.Payload) ~= "table" then
        return nil
    end
    local copy = {}
    for key, value in pairs(envelope) do
        copy[key] = value
    end
    copy.Payload = {}
    for key, value in pairs(envelope.Payload) do
        copy.Payload[key] = value
    end
    return copy
end

local function PendingRecoveryMatches(record, pending)
    local payload = type(pending) == "table" and pending.Payload or nil
    local reference = record and record.Reference or nil
    return type(payload) == "table"
        and type(reference) == "table"
        and pending.Sender == record.Sender
        and pending.SenderInstallationId == record.SenderInstallationId
        and pending.SenderSessionId == record.SenderSessionId
        and payload.SyncId == reference.SyncId
        and payload.RevisionId == reference.RevisionId
        and payload.ContextRevisionId == reference.ContextRevisionId
end

local function SamePlayer(left, right)
    return type(left) == "string" and type(right) == "string" and left:lower() == right:lower()
end

local function SameRecoveryContext(record, auth, reference)
    local current = record and record.Reference or nil
    return type(record) == "table"
        and type(auth) == "table"
        and SamePlayer(record.Sender, auth.Sender)
        and record.SenderInstallationId == auth.SenderInstallationId
        and record.SenderSessionId == auth.SenderSessionId
        and type(current) == "table"
        and type(reference) == "table"
        and current.SyncId == reference.SyncId
        and current.RevisionId == reference.RevisionId
        and current.ContextRevisionId == reference.ContextRevisionId
end

local function SchedulePendingDisplayRecovery(self, record)
    pendingDisplayRecoveryTimer = self:ScheduleTimer("RecoverPendingDisplay", record.Delay, record.Generation)
    if not pendingDisplayRecoveryTimer then
        pendingDisplayRecovery = nil
        return false, "recovery-schedule-failed"
    end
    return true, "scheduled"
end

--- Cancels a deferred missing-display recovery request.
-- @treturn boolean canceled Whether a recovery timer was pending.
function AngryEra:CancelPendingDisplayRecovery()
    local timer = pendingDisplayRecoveryTimer
    local recovery = pendingDisplayRecovery
    pendingDisplayRecoveryGeneration = pendingDisplayRecoveryGeneration + 1
    pendingDisplayRecoveryTimer = nil
    pendingDisplayRecovery = nil
    CancelTimer(self, timer)
    return timer ~= nil or recovery ~= nil
end

--- Clears group/session-bound page publication and recovery state.
-- Callers must reset this state whenever the protocol session or group changes.
function AngryEra:ResetDisplayPublicationState()
    self:CancelPendingDisplayRecovery()
    CancelPendingDisplayPage(self, "reset")
    CancelTimer(self, displayTimerId)
    displayTimerId = nil
    displayLastUpdate = nil
    for _, timerId in pairs(pageTimerId) do
        CancelTimer(self, timerId)
    end
    pageTimerId = {}
    pageLastUpdate = {}
    publishedDisplayTuples = {}
end

--- Defers recovery for an accepted DISPLAY whose exact page tuple is missing.
-- The timer is trailing-edge: a newer pending display replaces the older wait.
-- @tparam table auth Authenticated sender identity.
-- @tparam table displayEnvelope Validated DISPLAY envelope.
-- @tparam table reference Exact missing page/context tuple.
-- @tparam[opt=0] number completedAttempts Recovery sends already queued.
-- @tparam[opt=false] boolean expedited Use the targeted-request watchdog.
-- @treturn boolean scheduled
-- @treturn string|nil statusOrError
function AngryEra:DeferPendingDisplayRecovery(auth, displayEnvelope, reference, completedAttempts, expedited)
    local previousRecovery = pendingDisplayRecovery
    self:CancelPendingDisplayRecovery()
    local envelopeCopy = CopyDisplayEnvelope(displayEnvelope)
    completedAttempts = completedAttempts or 0
    expedited = expedited == true
    if
        type(auth) ~= "table"
        or type(auth.Sender) ~= "string"
        or type(auth.SenderInstallationId) ~= "string"
        or type(auth.SenderSessionId) ~= "string"
        or not envelopeCopy
        or type(reference) ~= "table"
        or type(completedAttempts) ~= "number"
        or completedAttempts ~= math.floor(completedAttempts)
        or completedAttempts < 0
        or completedAttempts > maximumDisplayRecoveryAttempts
    then
        return false, "invalid-recovery-context"
    end
    local inheritedAttempts = SameRecoveryContext(previousRecovery, auth, reference) and previousRecovery.Attempts or 0
    local attempts = math.max(inheritedAttempts, completedAttempts)
    if type(self.GetPendingActiveDisplayRequest) ~= "function" then
        return false, "active-page-runtime-unavailable"
    end
    local queried, pending = pcall(self.GetPendingActiveDisplayRequest, self)
    if not queried then
        return false, "pending-display-query-failed"
    end
    if pending == nil then
        return true, "not-needed"
    end
    pendingDisplayRecovery = {
        Generation = pendingDisplayRecoveryGeneration,
        Attempts = attempts,
        Delay = expedited and requestedDisplayRecoveryDelay or pendingDisplayRecoveryDelay,
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        DisplayEnvelope = envelopeCopy,
        Reference = {
            SyncId = reference.SyncId,
            RevisionId = reference.RevisionId,
            ContextRevisionId = reference.ContextRevisionId,
        },
    }
    if not PendingRecoveryMatches(pendingDisplayRecovery, pending) then
        pendingDisplayRecovery = nil
        return false, "stale-recovery-context"
    end
    if pendingDisplayRecovery.Attempts >= maximumDisplayRecoveryAttempts then
        pendingDisplayRecovery.Exhausted = true
        return true, "exhausted"
    end
    return SchedulePendingDisplayRecovery(self, pendingDisplayRecovery)
end

--- Recovers a still-missing exact tuple without amplifying normal page transit.
-- The first attempt asks the authenticated publisher for only the referenced
-- tuple. Later bounded attempts ask the current leader, which also handles a
-- leadership change while recovery was pending.
-- @tparam number generation Recovery generation captured by AceTimer.
-- @treturn boolean sentOrNotNeeded
-- @treturn string|nil messageIdOrStatus
function AngryEra:RecoverPendingDisplay(generation)
    local recovery = pendingDisplayRecovery
    if not recovery or recovery.Generation ~= generation then
        return true, "superseded"
    end
    if recovery.Exhausted then
        return true, "exhausted"
    end
    pendingDisplayRecoveryTimer = nil
    if type(self.GetPendingActiveDisplayRequest) ~= "function" then
        pendingDisplayRecovery = nil
        return false, "active-page-runtime-unavailable"
    end
    local queried, pending = pcall(self.GetPendingActiveDisplayRequest, self)
    if not queried then
        pendingDisplayRecovery = nil
        return false, "pending-display-query-failed"
    end
    if pending == nil then
        pendingDisplayRecovery = nil
        return true, "not-needed"
    end
    if not PendingRecoveryMatches(recovery, pending) then
        pendingDisplayRecovery = nil
        return true, "superseded"
    end

    recovery.Attempts = recovery.Attempts + 1
    local sent
    local result
    if recovery.Attempts == 1 then
        local leader
        if type(self.GetRaidLeader) == "function" then
            local leaderOk, currentLeader = pcall(self.GetRaidLeader, self, true)
            if leaderOk then
                leader = currentLeader
            end
        end
        if SamePlayer(leader, recovery.Sender) then
            sent, result = self:SendProtocolPageRequest(recovery.Sender, recovery.DisplayEnvelope, recovery.Reference)
        end
        if not sent then
            recovery.Attempts = recovery.Attempts + 1
            sent, result = self:SendRequestDisplay()
        end
    else
        sent, result = self:SendRequestDisplay()
    end

    if recovery.Attempts < maximumDisplayRecoveryAttempts then
        local scheduled, scheduleError = SchedulePendingDisplayRecovery(self, recovery)
        if not scheduled then
            return false, scheduleError
        end
    else
        recovery.Exhausted = true
    end
    return sent, result
end

--- Sends the newest debounced page snapshot associated with DISPLAY control.
-- The active-page stream produces one AceComm frame at a time so a newer
-- display can stop obsolete chunks before they enter ChatThrottleLib.
-- @tparam number generation Publication generation captured by AceTimer.
-- @treturn boolean sentOrSuperseded
-- @treturn string|nil messageIdOrStatus
function AngryEra:SendDisplayPageMessage(generation)
    local pending = pendingDisplayPage
    if not pending or pending.Generation ~= generation then
        if IsDebugEnabled(self) then
            Trace(self, "page-debounce-skip", "generation=%s reason=superseded", tostring(generation))
        end
        return true, "superseded"
    end
    pendingDisplayPage = nil
    pendingDisplayPageTimer = nil
    if pending.Debug then
        Trace(
            self,
            "page-debounce-fire",
            "id=%s generation=%d waited=%dms",
            tostring(pending.Id),
            pending.Generation,
            math.max(PreciseNowMilliseconds() - pending.QueuedAt, 0)
        )
    end
    if not self:CanLocalPlayerPublish("display") or not self:CanLocalPlayerPublish("pageUpsert") then
        if pending.Debug then
            Trace(self, "page-debounce-skip", "id=%s reason=unauthorized", tostring(pending.Id))
        end
        return false, "unauthorized"
    end
    if not ActiveDisplayMatches(self, pending.Payload) then
        if pending.Debug then
            Trace(self, "page-debounce-skip", "id=%s reason=inactive-tuple", tostring(pending.Id))
        end
        return true, "superseded"
    end
    if type(self.SendProtocolActivePageUpsert) ~= "function" then
        return false, "active-page-transport-unavailable"
    end

    local completionState = {
        Debug = pending.Debug,
        Generation = pending.Generation,
        Id = pending.Id,
        Payload = pending.Payload,
        Self = self,
    }
    activeDisplayPageTransfer = completionState
    local sent, result =
        self:SendProtocolActivePageUpsert(pending.Payload, DisplayPageTransferCompleted, completionState)
    if not sent then
        ReannounceFailedDisplayPage(completionState, result)
        if activeDisplayPageTransfer == completionState then
            activeDisplayPageTransfer = nil
        end
        return false, result
    end
    return true, result
end

--- Sends a canonical PAGE_UPSERT with per-page throttling.
-- @tparam number id Local page id.
-- @tparam[opt=false] boolean force Bypass the publication delay.
-- @treturn boolean sentOrScheduled
-- @treturn table|string|nil payloadOrStatus
function AngryEra:SendPage(id, force)
    if not self:CanLocalPlayerPublish("pageUpsert") then
        return false, "unauthorized"
    end

    local now = time()
    local lastUpdate = pageLastUpdate[id]
    if not force and lastUpdate and now - lastUpdate < updateFrequency then
        if not pageTimerId[id] then
            pageTimerId[id] = self:ScheduleTimer("SendPageMessage", updateFrequency - (now - lastUpdate), id)
        end
        return true, "scheduled"
    end

    CancelTimer(self, pageTimerId[id])
    pageTimerId[id] = nil
    return self:SendPageMessage(id)
end

--- Immediately prepares and sends one canonical PAGE_UPSERT.
-- @tparam number id Local page id.
-- @treturn boolean sent
-- @treturn table|string payloadOrError
function AngryEra:SendPageMessage(id)
    pageTimerId[id] = nil
    if not self:CanLocalPlayerPublish("pageUpsert") then
        return false, "unauthorized"
    end
    if not AngryAssign_Pages[id] then
        pageLastUpdate[id] = nil
        return false, "missing-local-page"
    end
    return SendPreparedPage(self, id)
end

--- Publishes an active display selection with throttling.
-- A page tuple is proactively published once per group/session. Later
-- selections send only DISPLAY; a receiver without that tuple requests it.
-- @tparam[opt] number id Local page id, or nil to clear the shared display.
-- @tparam[opt=false] boolean force Bypass the publication delay.
-- @treturn boolean sentOrScheduled
-- @treturn string|nil messageIdOrStatus
-- @treturn boolean activatedLocally Whether the exact local display state committed.
function AngryEra:SendDisplay(id, force)
    if not self:CanLocalPlayerPublish("display") then
        return false, "unauthorized", false
    end

    local now = time()
    if not force and displayLastUpdate and now - displayLastUpdate < updateFrequency then
        CancelTimer(self, displayTimerId)
        displayTimerId = self:ScheduleTimer("SendDisplayMessage", updateFrequency - (now - displayLastUpdate), id)
        return true, "scheduled", false
    end

    CancelTimer(self, displayTimerId)
    displayTimerId = nil
    return self:SendDisplayMessage(id)
end

--- Immediately sends DISPLAY control and, for a new tuple, queues PAGE_UPSERT.
-- A short trailing debounce coalesces rapid page A -> B navigation before the
-- replaceable active-page stream starts.
-- @tparam[opt] number id Local page id, or nil to clear the shared display.
-- @treturn boolean sent
-- @treturn string|nil messageIdOrError
-- @treturn boolean activatedLocally Whether the exact local display state committed.
function AngryEra:SendDisplayMessage(id)
    displayTimerId = nil
    local debugEnabled = IsDebugEnabled(self)
    if debugEnabled then
        Trace(self, "display-select", "id=%s", tostring(id))
    end
    if not self:CanLocalPlayerPublish("display") then
        return false, "unauthorized", false
    end

    if
        type(self.BuildActiveDisplayPayload) ~= "function"
        or type(self.ActivatePreparedActiveDisplay) ~= "function"
        or type(self.ClearActiveDisplayReference) ~= "function"
    then
        return false, "active-page-runtime-unavailable", false
    end
    if id ~= nil and not self:CanLocalPlayerPublish("pageUpsert") then
        return false, "unauthorized", false
    end

    local author = PlayerFullName()
    if type(author) ~= "string" or author == "" then
        return false, "invalid-local-author", false
    end
    local displayPayload, pagePayloadOrError = self:BuildActiveDisplayPayload(id, {
        UpdatedAt = time(),
        UpdatedBy = author,
    })
    if not displayPayload then
        return false, pagePayloadOrError, false
    end

    local pagePayload = pagePayloadOrError
    local activated, activationError
    if id == nil then
        activated, activationError = self:ClearActiveDisplayReference()
    else
        activated, activationError = self:ActivatePreparedActiveDisplay(displayPayload, pagePayload)
    end
    if activated ~= true then
        return false, activationError or "active-display-activation-failed", false
    end

    if pagePayload then
        CancelTimer(self, pageTimerId[id])
        pageTimerId[id] = nil
        local queued, queueResult = QueueDisplayPage(self, id, pagePayload)
        if not queued then
            return false, queueResult, true
        end
        if queueResult ~= "already-published" then
            displayPayload.PageFollows = true
        end
    else
        CancelPendingDisplayPage(self, "display-cleared")
    end

    local sent, result = self:SendProtocolDisplay(displayPayload)
    if sent then
        displayLastUpdate = time()
        if debugEnabled then
            Trace(
                self,
                "display-submit",
                "id=%s message=%s pageFollows=%s",
                tostring(id),
                tostring(result),
                tostring(displayPayload.PageFollows == true)
            )
        end
    else
        CancelPendingDisplayPage(self, "display-send-failed")
    end
    return sent, result, true
end

--- Requests the current display from the online raid/party leader.
-- @treturn boolean sent
-- @treturn string|nil messageIdOrError
function AngryEra:SendRequestDisplay()
    if not IsGrouped() then
        return false, "not-grouped"
    end

    local target = self:GetRaidLeader(true)
    if not target then
        return false, "leader-unavailable"
    end
    if target == PlayerFullName() then
        return false, "local-player-is-leader"
    end
    return self:SendProtocolDisplayRequest(target)
end

--- Returns the current raid or party leader full name.
-- @tparam[opt=false] boolean onlineOnly Require the leader to be online.
-- @treturn string|nil leaderName
function AngryEra:GetRaidLeader(onlineOnly)
    local leaderName
    IterateGroupMembers(function(_, fullName, rank, _, _, online)
        if rank == 2 and (not onlineOnly or online) then
            leaderName = fullName
            return true
        end
        return false
    end)
    return leaderName
end

--- Finds the local player's current raid subgroup.
-- @treturn number|nil subgroup
function AngryEra:GetCurrentGroup()
    local player = PlayerFullName()
    local subgroup
    IterateGroupMembers(function(_, fullName, _, memberSubgroup)
        if fullName == player then
            subgroup = memberSubgroup
            return true
        end
        return false
    end)
    return subgroup
end

--- Prints responses correlated to one protocol-v3 version query.
-- @tparam string queryId VERSION_QUERY message id.
function AngryEra:VersionCheckOutput(queryId)
    if type(queryId) ~= "string" or queryId == "" then
        self:Print("Unable to display version check results: missing query identifier.")
        return false
    end

    local missingAddon = {}
    local invalidRaid = {}
    local differentVersion = {}
    local upToDate = {}
    local localVersion = AngryEra.Version
    if localVersion:sub(1, 1) == "@" then
        localVersion = "dev"
    end
    local localPlayer = PlayerFullName()

    IterateGroupMembers(function(rawName, fullName, _, _, _, online)
        if not online then
            return false
        end

        local displayName = rawName or EnsureUnitShortName(fullName)
        local peer = fullName ~= localPlayer and self:GetProtocolPeer(fullName, queryId)
            or {
                AddonVersion = localVersion,
                AcceptsCurrentGroup = self:IsValidRaid(),
            }
        if not peer then
            table.insert(missingAddon, displayName)
        elseif peer.AcceptsCurrentGroup ~= true then
            table.insert(invalidRaid, displayName)
        elseif peer.AddonVersion ~= localVersion then
            table.insert(differentVersion, string.format("%s - %s", displayName, peer.AddonVersion))
        else
            table.insert(upToDate, displayName)
        end
        return false
    end)

    self:Print("Version check results:")
    if #upToDate > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Same version:|r " .. table.concat(upToDate, ", "))
    end
    if #differentVersion > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Different version:|r " .. table.concat(differentVersion, ", "))
    end
    if #invalidRaid > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Not allowing changes:|r " .. table.concat(invalidRaid, ", "))
    end
    if #missingAddon > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Missing addon:|r " .. table.concat(missingAddon, ", "))
    end
    return true
end

--- Cancels pending publication for a page being removed.
-- @tparam number id Local page id.
function AngryEra:CancelPageTimer(id)
    CancelTimer(self, pageTimerId[id])
    pageTimerId[id] = nil
    pageLastUpdate[id] = nil
end
