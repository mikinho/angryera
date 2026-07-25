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
local displayControlDebounce = 0.125
local displayPageDebounce = 0.125
-- Promised group pages need a long grace period so a large/low-FPS transfer
-- does not make every receiver request a duplicate at once. A targeted request
-- gets a shorter watchdog because only that receiver retries it.
local pendingDisplayRecoveryDelay = math.max(updateFrequency * 15, 30)
local requestedDisplayRecoveryDelay = math.max(updateFrequency * 2, 5)
local maximumDisplayRecoveryAttempts = 3
-- Keep early discovery retries responsive while retaining bounded backoff for
-- a leader whose addon is still starting or whose queued response is lost.
local displayRequestRetryDelays = {
    math.max(updateFrequency, 3),
    math.max(updateFrequency * 2.5, 5),
    math.max(updateFrequency * 6.5, 13),
}

local pageLastUpdate = {}
local pageTimerId = {}
local displayTimerId
local pendingDisplayControl
local displayControlGeneration = 0
local pendingDisplayRecoveryTimer
local pendingDisplayRecovery
local pendingDisplayRecoveryGeneration = 0
local pendingDisplayPage
local pendingDisplayPageTimer
local displayPageGeneration = 0
local activeDisplayPageTransfer
local publishedDisplayTuples = {}
local displayRequestWatchdog
local displayRequestWatchdogTimer
local displayRequestWatchdogGeneration = 0
local displayAuthorityRecoveryPageId
local sharedPageChangeDraft
local sharedPageChangeTimer
local sharedPageChangeTimeoutTimer
local sharedPageChangeCommitTimer
local sharedPageChangeGeneration = 0
local sharedPageChangeDebounce = 0.125
local sharedPageChangeTimeout = math.max(updateFrequency * 10, 20)
local sharedPageChangeCommitWait = math.max(updateFrequency * 2.5, 5)
local sharedPageChangeObservedLimit = 16
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
        or type(page.Revision) ~= "number"
        or type(page.RevisionId) ~= "string"
        or type(payload.ContextRevisionId) ~= "string"
    then
        return nil
    end
    return {
        SyncId = page.SyncId,
        Revision = page.Revision,
        RevisionId = page.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
end

local function IsPublishedDisplayTuple(payload)
    local tuple = PageTuple(payload)
    local published = tuple and publishedDisplayTuples[tuple.SyncId] or nil
    return type(published) == "table"
        and published.Revision == tuple.Revision
        and published.RevisionId == tuple.RevisionId
        and published.ContextRevisionId == tuple.ContextRevisionId
end

local function RememberPublishedDisplayTuple(payload)
    local tuple = PageTuple(payload)
    if not tuple then
        return false
    end
    publishedDisplayTuples[tuple.SyncId] = {
        Revision = tuple.Revision,
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
        or active.Revision ~= tuple.Revision
        or active.RevisionId ~= tuple.RevisionId
        or active.ContextRevisionId ~= tuple.ContextRevisionId
    then
        return false
    end

    state.FailureReannounced = true
    local sent, result = state.Self:SendProtocolDisplay({
        Displayed = true,
        SyncId = tuple.SyncId,
        Revision = tuple.Revision,
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
        and leftTuple.Revision == rightTuple.Revision
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
            Revision = reference.Revision,
            RevisionId = reference.RevisionId,
        },
        ContextRevisionId = reference.ContextRevisionId,
    })
end

local function CancelPendingDisplayPage(self, reason, transferReason)
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
        self:CancelProtocolActivePageTransfer(transferReason or reason or "superseded")
    end
end

local function CancelObsoleteDisplayPage(self, payload)
    if
        payload
        and (
            (pendingDisplayPage and SamePageTuple(pendingDisplayPage.Payload, payload))
            or (activeDisplayPageTransfer and SamePageTuple(activeDisplayPageTransfer.Payload, payload))
        )
    then
        return false
    end
    if not pendingDisplayPage and not activeDisplayPageTransfer then
        return false
    end
    CancelPendingDisplayPage(self, "superseded")
    return true
end

local function CancelMatchingDisplayPage(self, payload)
    if
        not payload
        or not (
            (pendingDisplayPage and SamePageTuple(pendingDisplayPage.Payload, payload))
            or (activeDisplayPageTransfer and SamePageTuple(activeDisplayPageTransfer.Payload, payload))
        )
    then
        return false
    end
    CancelPendingDisplayPage(self, "superseded")
    return true
end

local function CancelPendingDisplayControl(self, reason)
    local pending = pendingDisplayControl
    local timer = displayTimerId
    displayControlGeneration = displayControlGeneration + 1
    pendingDisplayControl = nil
    displayTimerId = nil
    CancelTimer(self, timer)
    if pending and pending.Debug then
        Trace(
            self,
            "display-debounce-drop",
            "id=%s generation=%d reason=%s",
            tostring(pending.Id),
            pending.Generation,
            tostring(reason or "superseded")
        )
    end
    return pending ~= nil or timer ~= nil
end

local function QueueDisplayPage(self, id, payload, delay)
    delay = type(delay) == "number" and delay >= 0 and delay or displayPageDebounce
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
    pendingDisplayPageTimer = self:ScheduleTimer("SendDisplayPageMessage", delay, displayPageGeneration)
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
            math.floor(delay * 1000)
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
        and payload.Revision == reference.Revision
        and payload.RevisionId == reference.RevisionId
        and payload.ContextRevisionId == reference.ContextRevisionId
end

local function SamePlayer(left, right)
    return type(left) == "string" and type(right) == "string" and left:lower() == right:lower()
end

local function CanReceiveSharedDisplayFrom(self, target)
    if type(self.CanReceiveFrom) == "function" then
        local called, accepted = pcall(self.CanReceiveFrom, self, target, "display")
        if called then
            return accepted == true
        end
    end
    if type(self.IsValidRaid) == "function" then
        local called, accepted = pcall(self.IsValidRaid, self)
        return called and accepted == true
    end
    return false
end

local function CopyDesiredPageState(desired)
    if type(desired) ~= "table" then
        return nil
    end
    if type(desired.Name) ~= "string" or type(desired.Vars) ~= "string" or type(desired.Contents) ~= "string" then
        return nil
    end
    return {
        Name = desired.Name,
        Vars = desired.Vars,
        Contents = desired.Contents,
    }
end

local function WireDefaultedText(value)
    return type(value) == "string" and value or ""
end

local function PageMatchesDesiredState(page, desired)
    return type(page) == "table"
        and type(desired) == "table"
        and WireDefaultedText(page.Name) == desired.Name
        and WireDefaultedText(page.Vars) == desired.Vars
        and WireDefaultedText(page.Contents) == desired.Contents
end

local function CopyChangeReference(reference)
    if type(reference) ~= "table" then
        return nil
    end
    return {
        SyncId = reference.SyncId,
        Revision = reference.Revision,
        RevisionId = reference.RevisionId,
        ContextRevisionId = reference.ContextRevisionId,
    }
end

local function SameChangeReference(left, right)
    return type(left) == "table"
        and type(right) == "table"
        and left.SyncId == right.SyncId
        and left.Revision == right.Revision
        and left.RevisionId == right.RevisionId
        and left.ContextRevisionId == right.ContextRevisionId
end

local function ChangeReferenceKey(reference)
    if
        type(reference) ~= "table"
        or type(reference.SyncId) ~= "string"
        or type(reference.Revision) ~= "number"
        or type(reference.RevisionId) ~= "string"
        or type(reference.ContextRevisionId) ~= "string"
    then
        return nil
    end
    return table.concat({
        reference.SyncId,
        tostring(reference.Revision or ""),
        reference.RevisionId,
        reference.ContextRevisionId,
    }, "\0")
end

local function ClearObservedCanonicalReferences(draft)
    if type(draft) ~= "table" then
        return
    end
    draft.ObservedCanonicalReferences = nil
    draft.ObservedCanonicalOrder = nil
end

local function RememberObservedCanonicalReference(draft, reference)
    local key = ChangeReferenceKey(reference)
    if type(draft) ~= "table" or not key then
        return false
    end
    draft.ObservedCanonicalReferences = draft.ObservedCanonicalReferences or {}
    draft.ObservedCanonicalOrder = draft.ObservedCanonicalOrder or {}
    if draft.ObservedCanonicalReferences[key] then
        return true
    end

    draft.ObservedCanonicalReferences[key] = CopyChangeReference(reference)
    table.insert(draft.ObservedCanonicalOrder, key)
    while #draft.ObservedCanonicalOrder > sharedPageChangeObservedLimit do
        local expired = table.remove(draft.ObservedCanonicalOrder, 1)
        draft.ObservedCanonicalReferences[expired] = nil
    end
    return true
end

local function HasObservedCanonicalReference(draft, reference)
    local key = ChangeReferenceKey(reference)
    return type(draft) == "table"
        and key ~= nil
        and type(draft.ObservedCanonicalReferences) == "table"
        and draft.ObservedCanonicalReferences[key] ~= nil
end

local function CancelSharedPageChangeTimers(self)
    CancelTimer(self, sharedPageChangeTimer)
    CancelTimer(self, sharedPageChangeTimeoutTimer)
    CancelTimer(self, sharedPageChangeCommitTimer)
    sharedPageChangeTimer = nil
    sharedPageChangeTimeoutTimer = nil
    sharedPageChangeCommitTimer = nil
end

local function SetSharedPageChangeConflict(self, draft, status, reason, reference)
    if type(draft) ~= "table" then
        return
    end
    self.syncDraftConflict = {
        SyncId = draft.SyncId,
        LocalId = draft.LocalId,
        Status = status,
        Reason = reason,
        Desired = CopyDesiredPageState(draft.Desired),
        CanonicalReference = CopyChangeReference(reference),
        ReceivedAt = time(),
    }
end

local function CurrentSharedPageReference(self, draft)
    if type(draft) ~= "table" or type(AngryAssign_Pages) ~= "table" then
        return nil
    end
    local page = rawget(AngryAssign_Pages, draft.LocalId)
    if
        type(page) ~= "table"
        or page.SyncId ~= draft.SyncId
        or type(page.Revision) ~= "number"
        or type(page.RevisionId) ~= "string"
    then
        return nil
    end
    if type(self.GetActiveDisplayReference) ~= "function" then
        return nil
    end
    local queried, active = pcall(self.GetActiveDisplayReference, self)
    if
        not queried
        or type(active) ~= "table"
        or active.SyncId ~= page.SyncId
        or active.Revision ~= page.Revision
        or active.RevisionId ~= page.RevisionId
        or type(active.ContextRevisionId) ~= "string"
    then
        return nil
    end
    return {
        SyncId = page.SyncId,
        Revision = page.Revision,
        RevisionId = page.RevisionId,
        ContextRevisionId = active.ContextRevisionId,
    }
end

local function CurrentSharedPageMatchesDesired(self, draft, reference, desired)
    local current = CurrentSharedPageReference(self, draft)
    if not SameChangeReference(current, reference) then
        return false
    end
    local page = type(AngryAssign_Pages) == "table" and rawget(AngryAssign_Pages, draft.LocalId) or nil
    return type(page) == "table"
        and page.SyncId == draft.SyncId
        and page.Revision == reference.Revision
        and page.RevisionId == reference.RevisionId
        and PageMatchesDesiredState(page, desired)
end

local function ScheduleSharedPageChangeFlush(self, draft)
    CancelTimer(self, sharedPageChangeTimer)
    sharedPageChangeGeneration = sharedPageChangeGeneration + 1
    draft.FlushGeneration = sharedPageChangeGeneration
    sharedPageChangeTimer =
        self:ScheduleTimer("FlushSharedPageChangeProposal", sharedPageChangeDebounce, draft.FlushGeneration)
    if not sharedPageChangeTimer then
        return false, "change-proposal-schedule-failed"
    end
    return true, "scheduled"
end

local function FinishAcceptedSharedPageChange(self, draft)
    local queued = draft.Generation > (draft.SentGeneration or 0)
    local messageId = draft.InFlightMessageId
    CancelTimer(self, sharedPageChangeTimeoutTimer)
    CancelTimer(self, sharedPageChangeCommitTimer)
    sharedPageChangeTimeoutTimer = nil
    sharedPageChangeCommitTimer = nil
    if messageId and type(self.CancelProtocolChangeProposal) == "function" then
        pcall(self.CancelProtocolChangeProposal, self, messageId)
    end
    draft.InFlightMessageId = nil
    draft.AcceptedReference = nil
    ClearObservedCanonicalReferences(draft)
    draft.Halted = nil

    if queued then
        local current = CurrentSharedPageReference(self, draft)
        if not current then
            SetSharedPageChangeConflict(self, draft, "conflict", "canonical-page-unavailable")
            draft.Halted = true
            return false, "canonical-page-unavailable"
        end
        draft.BaseRevision = current.Revision
        draft.BaseRevisionId = current.RevisionId
        draft.BaseContextRevisionId = current.ContextRevisionId
        if type(self.RebaseSharedPageChangeDraft) ~= "function" then
            SetSharedPageChangeConflict(self, draft, "unavailable", "editor-draft-rebase-unavailable", current)
            draft.Halted = true
            return false, "editor-draft-rebase-unavailable"
        end
        local called, rebased, rebaseError =
            pcall(self.RebaseSharedPageChangeDraft, self, draft.LocalId, current, draft.Desired)
        if not called or rebased ~= true then
            SetSharedPageChangeConflict(
                self,
                draft,
                "unavailable",
                called and rebaseError or "editor-draft-rebase-failed",
                current
            )
            draft.Halted = true
            return false, rebaseError or "editor-draft-rebase-failed"
        end
        if type(self.UpdateSelected) == "function" then
            pcall(self.UpdateSelected, self, false)
        end
        local scheduled, scheduleResult = ScheduleSharedPageChangeFlush(self, draft)
        if not scheduled then
            SetSharedPageChangeConflict(self, draft, "unavailable", scheduleResult, current)
            draft.Halted = true
            return false, scheduleResult
        end
        return true, scheduleResult
    end

    sharedPageChangeDraft = nil
    if type(self.ClearSharedPageChangeDraft) == "function" then
        pcall(self.ClearSharedPageChangeDraft, self, true)
    end
    if type(self.ClearSyncDraftConflict) == "function" then
        pcall(self.ClearSyncDraftConflict, self)
    elseif type(self.syncDraftConflict) == "table" and self.syncDraftConflict.SyncId == draft.SyncId then
        self.syncDraftConflict = nil
    end
    if type(self.UpdateSelected) == "function" then
        pcall(self.UpdateSelected, self, false)
    end
    return true, "completed"
end

--- Clears transport-side proposal state. The editor-owned desired draft is
-- retained as a visible conflict so a handoff or timeout never loses user text.
function AngryEra:ResetSharedPageChangeState(reason)
    local draft = sharedPageChangeDraft
    CancelSharedPageChangeTimers(self)
    sharedPageChangeGeneration = sharedPageChangeGeneration + 1
    sharedPageChangeDraft = nil
    if draft then
        SetSharedPageChangeConflict(self, draft, "unavailable", reason or "reset")
        return true
    end
    return false
end

--- Cancels the current local proposal after an explicit editor revert.
-- An already delivered proposal may still be committed by the leader, but its
-- delayed result can no longer revive the discarded local draft.
function AngryEra:CancelSharedPageChangeProposal(reason)
    local draft = sharedPageChangeDraft
    if not draft then
        return false, "idle"
    end
    CancelSharedPageChangeTimers(self)
    sharedPageChangeGeneration = sharedPageChangeGeneration + 1
    sharedPageChangeDraft = nil
    if draft.InFlightMessageId and type(self.CancelProtocolChangeProposal) == "function" then
        pcall(self.CancelProtocolChangeProposal, self, draft.InFlightMessageId)
    end
    return true, reason or "canceled"
end

--- Queues a full desired-state edit for the exact displayed shared page.
-- Canonical storage remains untouched until a leader PAGE_UPSERT is accepted.
function AngryEra:SubmitSharedPageChangeProposal(proposal)
    if type(proposal) ~= "table" or type(proposal.LocalId) ~= "number" or proposal.LocalId < 1 then
        return false, "invalid-change-proposal"
    end
    local desired = CopyDesiredPageState(proposal.Desired)
    if
        not desired
        or type(proposal.SyncId) ~= "string"
        or type(proposal.BaseRevision) ~= "number"
        or type(proposal.BaseRevisionId) ~= "string"
        or type(proposal.BaseContextRevisionId) ~= "string"
    then
        return false, "invalid-change-proposal"
    end
    if
        type(self.CanLocalPlayerPublish) ~= "function"
        or not self:CanLocalPlayerPublish("changeProposal")
        or self:CanLocalPlayerPublish("pageUpsert")
    then
        return false, "unauthorized"
    end

    local draft = sharedPageChangeDraft
    if draft and draft.SyncId ~= proposal.SyncId then
        SetSharedPageChangeConflict(self, draft, "conflict", "display-changed")
        CancelSharedPageChangeTimers(self)
        draft = nil
    end
    if not draft then
        draft = {
            Generation = 0,
        }
        sharedPageChangeDraft = draft
    end

    draft.LocalId = proposal.LocalId
    draft.SyncId = proposal.SyncId
    draft.BaseRevision = proposal.BaseRevision
    draft.BaseRevisionId = proposal.BaseRevisionId
    draft.BaseContextRevisionId = proposal.BaseContextRevisionId
    draft.Desired = desired
    draft.Generation = draft.Generation + 1
    draft.Halted = nil

    if draft.InFlightMessageId then
        return true, "queued"
    end
    local scheduled, result = ScheduleSharedPageChangeFlush(self, draft)
    if not scheduled then
        SetSharedPageChangeConflict(self, draft, "unavailable", result)
        return false, result
    end
    return true, result
end

--- Sends the newest debounced desired state to the current leader.
function AngryEra:FlushSharedPageChangeProposal(generation)
    local draft = sharedPageChangeDraft
    if not draft or draft.FlushGeneration ~= generation then
        return true, "superseded"
    end
    sharedPageChangeTimer = nil
    if draft.InFlightMessageId then
        return true, "queued"
    end

    local current = CurrentSharedPageReference(self, draft)
    local expected = {
        SyncId = draft.SyncId,
        Revision = draft.BaseRevision,
        RevisionId = draft.BaseRevisionId,
        ContextRevisionId = draft.BaseContextRevisionId,
    }
    if not SameChangeReference(current, expected) then
        draft.Halted = true
        SetSharedPageChangeConflict(self, draft, "conflict", "stale-change-base", current)
        return false, "stale-change-base"
    end
    if type(self.BuildActivePageChangeProposal) ~= "function" then
        return false, "active-page-change-runtime-unavailable"
    end
    local payload, buildError = self:BuildActivePageChangeProposal(draft.LocalId, draft.Desired)
    if not payload then
        draft.Halted = true
        SetSharedPageChangeConflict(self, draft, "unavailable", buildError, current)
        return false, buildError
    end

    local target = self:GetRaidLeader(true)
    if not target or SamePlayer(target, PlayerFullName()) then
        draft.Halted = true
        SetSharedPageChangeConflict(self, draft, "unavailable", "leader-unavailable", current)
        return false, "leader-unavailable"
    end
    local sent, messageId = self:SendProtocolChangeProposal(target, payload)
    if not sent then
        draft.Halted = true
        SetSharedPageChangeConflict(self, draft, "unavailable", messageId, current)
        return false, messageId
    end

    draft.InFlightMessageId = messageId
    draft.SentGeneration = draft.Generation
    draft.SentDesired = CopyDesiredPageState(draft.Desired)
    draft.AcceptedReference = nil
    ClearObservedCanonicalReferences(draft)
    CancelTimer(self, sharedPageChangeTimeoutTimer)
    sharedPageChangeTimeoutTimer = self:ScheduleTimer("SharedPageChangeTimedOut", sharedPageChangeTimeout, messageId)
    if not sharedPageChangeTimeoutTimer then
        if type(self.CancelProtocolChangeProposal) == "function" then
            pcall(self.CancelProtocolChangeProposal, self, messageId)
        end
        draft.InFlightMessageId = nil
        draft.Halted = true
        SetSharedPageChangeConflict(self, draft, "unavailable", "change-result-watchdog-unavailable", current)
        self:SendRequestDisplay()
        return false, "change-result-watchdog-unavailable"
    end
    return true, messageId
end

--- Handles the correlated semantic result after protocol-runtime validation.
function AngryEra:HandleSharedPageChangeResult(_, result, _, messageId)
    local draft = sharedPageChangeDraft
    if
        not draft
        or draft.InFlightMessageId ~= messageId
        or type(result) ~= "table"
        or result.SyncId ~= draft.SyncId
    then
        return false, "stale-change-result"
    end
    CancelTimer(self, sharedPageChangeTimeoutTimer)
    sharedPageChangeTimeoutTimer = nil

    if result.Status == "conflict" or result.Status == "busy" or result.Status == "unavailable" then
        draft.InFlightMessageId = nil
        draft.AcceptedReference = nil
        ClearObservedCanonicalReferences(draft)
        draft.Halted = true
        local reference = result.Status ~= "unavailable" and result or nil
        SetSharedPageChangeConflict(self, draft, result.Status, "leader-" .. result.Status, reference)
        if type(self.UpdateSelected) == "function" then
            pcall(self.UpdateSelected, self, false)
        end
        if
            (
                result.Status == "unavailable"
                or (
                    (result.Status == "conflict" or result.Status == "busy")
                    and not SameChangeReference(reference, CurrentSharedPageReference(self, draft))
                )
            ) and type(self.SendRequestDisplay) == "function"
        then
            pcall(self.SendRequestDisplay, self)
        end
        return true, result.Status
    end

    draft.AcceptedReference = CopyChangeReference(result)
    if
        (
            HasObservedCanonicalReference(draft, draft.AcceptedReference)
            or SameChangeReference(draft.AcceptedReference, CurrentSharedPageReference(self, draft))
        ) and CurrentSharedPageMatchesDesired(self, draft, draft.AcceptedReference, draft.SentDesired)
    then
        return FinishAcceptedSharedPageChange(self, draft)
    end

    CancelTimer(self, sharedPageChangeCommitTimer)
    sharedPageChangeCommitTimer =
        self:ScheduleTimer("SharedPageChangeCommitTimedOut", sharedPageChangeCommitWait, messageId)
    if not sharedPageChangeCommitTimer then
        local acceptedReference = CopyChangeReference(draft.AcceptedReference)
        draft.InFlightMessageId = nil
        draft.AcceptedReference = nil
        ClearObservedCanonicalReferences(draft)
        draft.Halted = true
        SetSharedPageChangeConflict(
            self,
            draft,
            "unavailable",
            "canonical-page-watchdog-unavailable",
            acceptedReference
        )
        self:SendRequestDisplay()
        return true, "canonical-page-watchdog-unavailable"
    end
    return true, "awaiting-canonical-page"
end

--- Observes leader PAGE_UPSERT acceptance so page-before-result and
-- result-before-page delivery both complete the same proposal safely.
function AngryEra:ObserveSharedPageCanonicalUpdate(_, payload, applyResult)
    local draft = sharedPageChangeDraft
    local page = type(payload) == "table" and payload.Page or nil
    if not draft or type(page) ~= "table" or page.SyncId ~= draft.SyncId then
        return false, "unrelated"
    end
    local canonicalReference = {
        SyncId = page.SyncId,
        Revision = page.Revision,
        RevisionId = page.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
    local installed = type(applyResult) == "table"
        and applyResult.ContextOnly ~= true
        and (applyResult.Applied == true or applyResult.NoOp == true)
        and applyResult.LocalId == draft.LocalId
        and applyResult.SyncId == draft.SyncId
        and SameChangeReference(canonicalReference, CurrentSharedPageReference(self, draft))
    if not installed then
        return true, "observed"
    end
    local canonicalMatchesDesired = CurrentSharedPageMatchesDesired(self, draft, canonicalReference, draft.SentDesired)
    if draft.InFlightMessageId and canonicalMatchesDesired and PageMatchesDesiredState(page, draft.SentDesired) then
        return FinishAcceptedSharedPageChange(self, draft)
    end
    if draft.InFlightMessageId then
        RememberObservedCanonicalReference(draft, canonicalReference)
    end
    if canonicalMatchesDesired and SameChangeReference(draft.AcceptedReference, canonicalReference) then
        return FinishAcceptedSharedPageChange(self, draft)
    end
    return true, "observed"
end

--- Retains an unacknowledged desired draft after the bounded interaction TTL.
function AngryEra:SharedPageChangeTimedOut(messageId)
    local draft = sharedPageChangeDraft
    if not draft or draft.InFlightMessageId ~= messageId then
        return true, "superseded"
    end
    sharedPageChangeTimeoutTimer = nil
    if type(self.CancelProtocolChangeProposal) == "function" then
        pcall(self.CancelProtocolChangeProposal, self, messageId)
    end
    draft.InFlightMessageId = nil
    draft.AcceptedReference = nil
    ClearObservedCanonicalReferences(draft)
    draft.Halted = true
    SetSharedPageChangeConflict(self, draft, "unavailable", "change-result-timeout")
    self:SendRequestDisplay()
    return false, "change-result-timeout"
end

--- Requests canonical recovery when an accepted result outruns its page.
function AngryEra:SharedPageChangeCommitTimedOut(messageId)
    local draft = sharedPageChangeDraft
    if not draft or draft.InFlightMessageId ~= messageId or not draft.AcceptedReference then
        return true, "superseded"
    end
    sharedPageChangeCommitTimer = nil
    local acceptedReference = CopyChangeReference(draft.AcceptedReference)
    draft.InFlightMessageId = nil
    draft.AcceptedReference = nil
    ClearObservedCanonicalReferences(draft)
    draft.Halted = true
    SetSharedPageChangeConflict(self, draft, "unavailable", "canonical-page-timeout", acceptedReference)
    self:SendRequestDisplay()
    return false, "canonical-page-timeout"
end

local function ValidLocalPageId(id)
    return type(id) == "number"
        and id >= 1
        and id == math.floor(id)
        and type(AngryAssign_Pages) == "table"
        and type(rawget(AngryAssign_Pages, id)) == "table"
end

--- Captures the SavedVariables display selection before startup clears volatile
-- follower state. It is only used if this client becomes display authority
-- before receiving a newer authoritative DISPLAY.
-- @treturn boolean captured
-- @treturn number|string pageIdOrError
function AngryEra:CaptureDisplayAuthorityRecovery()
    local state = type(AngryAssign_State) == "table" and AngryAssign_State or nil
    local displayedId = state and rawget(state, "displayed") or nil
    if not ValidLocalPageId(displayedId) then
        displayAuthorityRecoveryPageId = nil
        return false, "no-display-continuity"
    end
    displayAuthorityRecoveryPageId = displayedId
    return true, displayedId
end

--- Discards a startup display candidate after a group boundary or an
-- authenticated current-leader DISPLAY resolves discovery.
-- @treturn boolean discarded
function AngryEra:DiscardDisplayAuthorityRecovery()
    local discarded = displayAuthorityRecoveryPageId ~= nil
    displayAuthorityRecoveryPageId = nil
    return discarded
end

--- Rebuilds and republishes the best local display anchor after this client
-- becomes raid/party leader. The current accepted display wins over the
-- startup candidate.
-- @treturn boolean restored
-- @treturn string|nil messageIdOrError
-- @treturn boolean isLocalAuthority
function AngryEra:RestoreDisplayAuthority()
    if not IsGrouped() then
        return false, "not-grouped", false
    end

    local leader = self:GetRaidLeader(true)
    if not SamePlayer(leader, PlayerFullName()) then
        return false, "not-display-authority", false
    end

    local state = type(AngryAssign_State) == "table" and AngryAssign_State or nil
    if not state then
        return false, "display-state-unavailable", true
    end
    local displayedId = rawget(state, "displayed")
    if not ValidLocalPageId(displayedId) then
        displayedId = displayAuthorityRecoveryPageId
    end
    if not ValidLocalPageId(displayedId) then
        displayAuthorityRecoveryPageId = nil
        return false, "no-display-continuity", true
    end

    local sent, result, activatedLocally = self:SendDisplayMessage(displayedId)
    if activatedLocally ~= true then
        return false, result or "display-continuity-activation-failed", true
    end

    state.displayed = displayedId
    displayAuthorityRecoveryPageId = nil
    if type(self.UpdateDisplayed) == "function" then
        self:UpdateDisplayed()
    end
    if type(self.UpdateTree) == "function" then
        self:UpdateTree()
    end
    return true, result, true
end

local function ScheduleDisplayRequestWatchdog(self, record)
    local delay = displayRequestRetryDelays[record.Attempts]
    if type(delay) ~= "number" then
        displayRequestWatchdog = nil
        displayRequestWatchdogTimer = nil
        return true, "exhausted"
    end
    displayRequestWatchdogTimer = self:ScheduleTimer("RetryDisplayRequest", delay, record.Generation)
    if not displayRequestWatchdogTimer then
        displayRequestWatchdog = nil
        return false, "display-request-watchdog-schedule-failed"
    end
    return true, "scheduled"
end

--- Cancels unanswered DISPLAY_REQUEST retry state.
-- @treturn boolean canceled
function AngryEra:CancelDisplayRequestWatchdog()
    local timer = displayRequestWatchdogTimer
    local pending = displayRequestWatchdog
    displayRequestWatchdogGeneration = displayRequestWatchdogGeneration + 1
    displayRequestWatchdog = nil
    displayRequestWatchdogTimer = nil
    CancelTimer(self, timer)
    return timer ~= nil or pending ~= nil
end

--- Resolves startup/display discovery after any authenticated current-leader
-- DISPLAY, including one whose promised page still needs exact-page recovery.
-- @treturn boolean changed
function AngryEra:ResolveDisplayDiscovery()
    local canceled = self:CancelDisplayRequestWatchdog()
    local discarded = self:DiscardDisplayAuthorityRecovery()
    return canceled or discarded
end

--- Retries one unanswered current-display request. Attempts are bounded and
-- re-resolve the online leader so a handoff does not retain a stale target.
-- @tparam number generation AceTimer generation captured at scheduling time.
-- @treturn boolean sentOrResolved
-- @treturn string|nil messageIdOrStatus
function AngryEra:RetryDisplayRequest(generation)
    local record = displayRequestWatchdog
    if not record or record.Generation ~= generation then
        return true, "superseded"
    end
    displayRequestWatchdogTimer = nil

    if not IsGrouped() then
        self:CancelDisplayRequestWatchdog()
        return false, "not-grouped"
    end

    local target = self:GetRaidLeader(true)
    if SamePlayer(target, PlayerFullName()) then
        self:CancelDisplayRequestWatchdog()
        local restored, result = self:RestoreDisplayAuthority()
        return restored, result
    end
    if target and not CanReceiveSharedDisplayFrom(self, target) then
        self:CancelDisplayRequestWatchdog()
        return false, "shared-display-disabled"
    end

    record.Attempts = record.Attempts + 1
    local sent
    local result
    if target then
        sent, result = self:SendProtocolDisplayRequest(target)
        if sent then
            record.MessageId = result
            record.Target = target
        end
    else
        sent, result = false, "leader-unavailable"
    end

    local scheduled, scheduleStatus = ScheduleDisplayRequestWatchdog(self, record)
    if not scheduled and sent then
        return true, result
    end
    if scheduleStatus == "exhausted" then
        return sent, result or scheduleStatus
    end
    return sent, result
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
        and current.Revision == reference.Revision
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
function AngryEra:ResetDisplayAuthorityPublicationState(reason)
    self:CancelPendingDisplayRecovery()
    CancelPendingDisplayPage(self, reason or "authority-reset", "superseded")
    CancelPendingDisplayControl(self, reason or "authority-reset")
    for _, timerId in pairs(pageTimerId) do
        CancelTimer(self, timerId)
    end
    pageTimerId = {}
    pageLastUpdate = {}
    publishedDisplayTuples = {}
end

--- Clears every group/session-bound publication, discovery, and proposal state.
-- Use the narrower authority reset during leadership lifecycle transitions that
-- must preserve an unanswered DISPLAY_REQUEST or assistant proposal.
function AngryEra:ResetDisplayPublicationState()
    self:ResetDisplayAuthorityPublicationState("publication-reset")
    self:CancelDisplayRequestWatchdog()
    self:ResetSharedPageChangeState("publication-reset")
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
            Revision = reference.Revision,
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
            sent, result = self:SendRequestDisplay(true)
        end
    else
        sent, result = self:SendRequestDisplay(true)
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

local function DisplaySelectionMatchesActive(self, prepared)
    local displayPayload = type(prepared) == "table" and prepared.DisplayPayload or nil
    if type(displayPayload) ~= "table" then
        return false
    end
    if displayPayload.Displayed then
        return prepared.PagePayload ~= nil and ActiveDisplayMatches(self, prepared.PagePayload)
    end
    if type(self.GetActiveDisplayReference) ~= "function" then
        return false
    end
    local queried, reference = pcall(self.GetActiveDisplayReference, self)
    return queried and reference == nil
end

local function PrepareDisplaySelection(self, id)
    local debugEnabled = IsDebugEnabled(self)
    if debugEnabled then
        Trace(self, "display-select", "id=%s", tostring(id))
    end
    if not self:CanLocalPlayerPublish("display") then
        return nil, "unauthorized"
    end

    if
        type(self.BuildActiveDisplayPayload) ~= "function"
        or type(self.ActivatePreparedActiveDisplay) ~= "function"
        or type(self.ClearActiveDisplayReference) ~= "function"
    then
        return nil, "active-page-runtime-unavailable"
    end
    if id ~= nil and not self:CanLocalPlayerPublish("pageUpsert") then
        return nil, "unauthorized"
    end

    local author = PlayerFullName()
    if type(author) ~= "string" or author == "" then
        return nil, "invalid-local-author"
    end
    local displayPayload, pagePayloadOrError = self:BuildActiveDisplayPayload(id, {
        UpdatedAt = time(),
        UpdatedBy = author,
    })
    if not displayPayload then
        return nil, pagePayloadOrError
    end

    local pagePayload = pagePayloadOrError
    local activated, activationError
    if id == nil then
        activated, activationError = self:ClearActiveDisplayReference()
    else
        activated, activationError = self:ActivatePreparedActiveDisplay(displayPayload, pagePayload)
    end
    if activated ~= true then
        return nil, activationError or "active-display-activation-failed"
    end
    return {
        Debug = debugEnabled,
        DisplayPayload = displayPayload,
        Id = id,
        PagePayload = pagePayload,
    }
end

local function PublishPreparedDisplay(self, prepared, pageDelay)
    if
        type(prepared) ~= "table"
        or type(prepared.DisplayPayload) ~= "table"
        or not self:CanLocalPlayerPublish("display")
        or (prepared.PagePayload ~= nil and not self:CanLocalPlayerPublish("pageUpsert"))
    then
        CancelPendingDisplayPage(self, "unauthorized")
        return false, "unauthorized"
    end
    if not DisplaySelectionMatchesActive(self, prepared) then
        CancelMatchingDisplayPage(self, prepared.PagePayload)
        if prepared.Debug then
            Trace(
                self,
                "display-debounce-skip",
                "id=%s generation=%s reason=inactive-tuple",
                tostring(prepared.Id),
                tostring(prepared.Generation)
            )
        end
        return true, "superseded"
    end

    local displayPayload = prepared.DisplayPayload
    displayPayload.PageFollows = nil
    if prepared.PagePayload then
        CancelTimer(self, pageTimerId[prepared.Id])
        pageTimerId[prepared.Id] = nil
        local queued, queueResult = QueueDisplayPage(self, prepared.Id, prepared.PagePayload, pageDelay)
        if not queued then
            return false, queueResult
        end
        if queueResult ~= "already-published" then
            displayPayload.PageFollows = true
        end
    else
        CancelPendingDisplayPage(self, "display-cleared")
    end

    local sent, result = self:SendProtocolDisplay(displayPayload)
    if sent then
        if prepared.Debug then
            Trace(
                self,
                "display-submit",
                "id=%s message=%s pageFollows=%s",
                tostring(prepared.Id),
                tostring(result),
                tostring(displayPayload.PageFollows == true)
            )
        end
    else
        CancelPendingDisplayPage(self, "display-send-failed")
    end
    return sent, result
end

local function QueuePendingDisplayControl(self, prepared)
    local replaced = pendingDisplayControl ~= nil
    CancelPendingDisplayControl(self, "superseded")
    prepared.Generation = displayControlGeneration
    prepared.QueuedAt = prepared.Debug and PreciseNowMilliseconds() or 0
    pendingDisplayControl = prepared
    displayTimerId = self:ScheduleTimer("SendPendingDisplayControl", displayControlDebounce, displayControlGeneration)
    if not displayTimerId then
        pendingDisplayControl = nil
        return false, "display-publication-schedule-failed"
    end
    if prepared.Debug then
        Trace(
            self,
            "display-debounce-start",
            "id=%s generation=%d delay=%dms replaced=%s",
            tostring(prepared.Id),
            prepared.Generation,
            math.floor(displayControlDebounce * 1000),
            tostring(replaced)
        )
    end
    return true, "scheduled"
end

--- Sends the newest locally activated interactive display selection.
-- Replaced generations never allocate a protocol sequence or timestamp.
-- @tparam number generation Publication generation captured by AceTimer.
-- @treturn boolean sentOrSuperseded
-- @treturn string|nil messageIdOrStatus
function AngryEra:SendPendingDisplayControl(generation)
    local pending = pendingDisplayControl
    if not pending or pending.Generation ~= generation then
        if IsDebugEnabled(self) then
            Trace(self, "display-debounce-skip", "generation=%s reason=superseded", tostring(generation))
        end
        return true, "superseded"
    end
    pendingDisplayControl = nil
    displayTimerId = nil
    if pending.Debug then
        Trace(
            self,
            "display-debounce-fire",
            "id=%s generation=%d waited=%dms",
            tostring(pending.Id),
            pending.Generation,
            math.max(PreciseNowMilliseconds() - pending.QueuedAt, 0)
        )
    end
    -- The control debounce already absorbed rapid navigation. Start a missing
    -- final page on the next timer turn instead of adding another 125 ms.
    return PublishPreparedDisplay(self, pending, 0)
end

--- Publishes an active display selection.
-- Interactive calls activate locally immediately and replace one 125 ms
-- trailing-edge control timer. Forced calls publish immediately.
-- @tparam[opt] number id Local page id, or nil to clear the shared display.
-- @tparam[opt=false] boolean force Bypass interactive control coalescing.
-- @treturn boolean sentOrScheduled
-- @treturn string|nil messageIdOrStatus
-- @treturn boolean activatedLocally Whether the exact local display state committed.
function AngryEra:SendDisplay(id, force)
    if force then
        return self:SendDisplayMessage(id)
    end

    local prepared, preparationError = PrepareDisplaySelection(self, id)
    if not prepared then
        return false, preparationError, false
    end
    CancelObsoleteDisplayPage(self, prepared.PagePayload)
    local scheduled, scheduleResult = QueuePendingDisplayControl(self, prepared)
    if not scheduled then
        local sent, result = PublishPreparedDisplay(self, prepared, 0)
        return sent, result or scheduleResult, true
    end
    return true, scheduleResult, true
end

--- Immediately prepares, activates, and publishes DISPLAY control.
-- A new tuple retains the page-only debounce for forced revision publication.
-- @tparam[opt] number id Local page id, or nil to clear the shared display.
-- @treturn boolean sent
-- @treturn string|nil messageIdOrError
-- @treturn boolean activatedLocally Whether the exact local display state committed.
function AngryEra:SendDisplayMessage(id)
    CancelPendingDisplayControl(self, "forced")
    local prepared, preparationError = PrepareDisplaySelection(self, id)
    if not prepared then
        return false, preparationError, false
    end
    local sent, result = PublishPreparedDisplay(self, prepared, displayPageDebounce)
    return sent, result, true
end

--- Requests the current display from the online raid/party leader.
-- Normal discovery installs a bounded response watchdog. Callers that already
-- own a recovery timer may suppress it to avoid duplicate retry loops.
-- @tparam[opt=false] boolean suppressWatchdog
-- @treturn boolean sent
-- @treturn string|nil messageIdOrError
function AngryEra:SendRequestDisplay(suppressWatchdog)
    if not IsGrouped() then
        if suppressWatchdog ~= true then
            self:CancelDisplayRequestWatchdog()
        end
        return false, "not-grouped"
    end

    local target = self:GetRaidLeader(true)
    if not target then
        if suppressWatchdog ~= true then
            self:CancelDisplayRequestWatchdog()
        end
        return false, "leader-unavailable"
    end
    if SamePlayer(target, PlayerFullName()) then
        if suppressWatchdog ~= true then
            self:CancelDisplayRequestWatchdog()
        end
        return false, "local-player-is-leader"
    end
    if not CanReceiveSharedDisplayFrom(self, target) then
        self:CancelDisplayRequestWatchdog()
        return false, "shared-display-disabled"
    end
    if
        suppressWatchdog ~= true
        and displayRequestWatchdog
        and displayRequestWatchdogTimer
        and SamePlayer(displayRequestWatchdog.Target, target)
    then
        return true, displayRequestWatchdog.MessageId
    end
    if suppressWatchdog ~= true then
        self:CancelDisplayRequestWatchdog()
    end

    local sent, result = self:SendProtocolDisplayRequest(target)
    if not sent or suppressWatchdog == true then
        return sent, result
    end

    displayRequestWatchdog = {
        Attempts = 1,
        Generation = displayRequestWatchdogGeneration,
        MessageId = result,
        Target = target,
    }
    ScheduleDisplayRequestWatchdog(self, displayRequestWatchdog)
    return true, result
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
