local assertions = 0

local function Assert(value, message)
    assertions = assertions + 1
    assert(value, message)
end

local function AssertEqual(actual, expected, message)
    assertions = assertions + 1
    assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function AssertError(ok, errorCode, expected, message)
    Assert(ok == false or ok == nil, message .. " should fail")
    AssertEqual(errorCode, expected, message)
end

local function DeepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[DeepCopy(key, seen)] = DeepCopy(item, seen)
    end
    return copy
end

local function TestHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local libC = {}
function libC:fcs32init()
    return 0
end
function libC:fcs32update(hash, value)
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return hash
end
function libC:fcs32final(hash)
    return hash
end

local currentTime = 1000
function _G.time()
    return currentTime
end

local helpers = {
    EnsureUnitFullName = function(player)
        if player and not player:find("-", 1, true) then
            return player .. "-Realm"
        end
        return player
    end,
    PlayerFullName = function()
        return "Viewer-Realm"
    end,
}

local AngryEra = {
    utils = {
        helpers = helpers,
    },
}
local app = {
    AngryEra = AngryEra,
    libs = {
        libC = libC,
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/protocol.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/revisions.lua"))("AngryEra", app)
assert(loadfile("modules/sync/active_page.lua"))("AngryEra", app)
assert(loadfile("modules/sync/page_runtime.lua"))("AngryEra", app)

local schema = AngryEra.sync.schema
local activePage = AngryEra.sync.activePage
local localInstallationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:a:b:c:d"
local otherInstallationId = "ae3i:e:f:10:11"
local remotePageSyncId = remoteInstallationId .. ":page:1"
local remoteParentSyncId = remoteInstallationId .. ":category:2"
local localPageSyncId = localInstallationId .. ":page:1"
local localCategorySyncId = localInstallationId .. ":category:2"

local hashHook
function AngryEra:GetSyncHashCallback()
    return function(value)
        if hashHook then
            hashHook(value)
        end
        return TestHash(value)
    end
end

local authorization = {
    pageUpsert = true,
    display = true,
    request = true,
}
local authorizationCalls = {}
local authorizationHook
function AngryEra:CanReceiveFrom(sender, action)
    authorizationCalls[#authorizationCalls + 1] = {
        Sender = sender,
        Action = action,
    }
    if authorizationHook then
        authorizationHook(#authorizationCalls, sender, action)
    end
    return authorization[action] == true
end

local localPublish = {
    pageUpsert = true,
    display = true,
}
function AngryEra:CanLocalPlayerPublish(action)
    return localPublish[action] == true
end

function AngryEra:IsPlayerRaidLeader()
    return true
end

function AngryEra:GetProtocolSession()
    return {
        InstallationId = localInstallationId,
        SessionId = "viewer_session",
    }
end

function AngryEra:GetGroupRole(sender)
    if sender == "Leader-Realm" then
        return "leader"
    end
    return "assistant"
end

function AngryEra:InstallSyncIdentityIndexes(indexes)
    self.entitySyncIndexes = indexes
end

local uiCalls
local editorDirty
local draftText
local treeError
local displayError
local function ResetUi()
    uiCalls = {
        Tree = 0,
        Selected = 0,
        DestructiveSelected = 0,
        Conflict = 0,
        Display = 0,
        Show = 0,
        Notification = 0,
    }
    editorDirty = false
    draftText = "unsaved draft"
    treeError = false
    displayError = false
    AngryEra.window = {
        text = {
            button = {
                IsEnabled = function()
                    return editorDirty
                end,
            },
            GetText = function()
                return draftText
            end,
            SetText = function(_, value)
                draftText = value
            end,
        },
    }
end

function AngryEra:UpdateTree()
    uiCalls.Tree = uiCalls.Tree + 1
    self:UpdateSelected(true)
    if treeError then
        error("tree refresh failed")
    end
end

function AngryEra:UpdateSelected(destructive)
    uiCalls.Selected = uiCalls.Selected + 1
    if destructive then
        uiCalls.DestructiveSelected = uiCalls.DestructiveSelected + 1
        draftText = "draft overwritten"
    end
end

function AngryEra:SelectedUpdated(sender)
    uiCalls.Conflict = uiCalls.Conflict + 1
    AssertEqual(sender, "Leader-Realm", "conflict uses authenticated sender")
end

function AngryEra:UpdateDisplayed()
    uiCalls.Display = uiCalls.Display + 1
    if displayError then
        error("display refresh failed")
    end
end

function AngryEra:ShowDisplay()
    uiCalls.Show = uiCalls.Show + 1
end

function AngryEra:DisplayUpdateNotification()
    uiCalls.Notification = uiCalls.Notification + 1
end

local function Auth(overrides)
    local auth = {
        Sender = "Leader",
        SenderInstallationId = remoteInstallationId,
        SenderSessionId = "leader_session",
        ReceivedAt = currentTime,
    }
    for key, value in pairs(overrides or {}) do
        auth[key] = value
    end
    return auth
end

local function LocalRecord(kind, id, syncId, ownerId, fields)
    local record = {
        Id = id,
        SyncId = syncId,
        OwnerId = ownerId,
        Name = fields.Name,
        Vars = fields.Vars or "",
        CategoryId = fields.CategoryId,
        Index = fields.Index,
    }
    if kind == "page" then
        record.Contents = fields.Contents or ""
    end
    return record
end

local function ResetStorage()
    local localCategory = LocalRecord("category", 1, localCategorySyncId, localInstallationId, {
        Name = "Personal",
        Index = 1,
    })
    local localPage = LocalRecord("page", 1, localPageSyncId, localInstallationId, {
        Name = "Notes",
        Contents = "Private",
        CategoryId = 1,
        Index = 1,
    })
    AngryAssign_Pages = {
        [1] = localPage,
    }
    AngryAssign_Categories = {
        [1] = localCategory,
    }
    AngryAssign_State = {
        displayed = 2,
        tree = {
            selected = "3",
        },
    }
    AngryAssign_Meta = {
        InstallationId = localInstallationId,
        NextEntitySequence = 2,
        EntityLocal = {
            [localPage.SyncId] = {
                OwnedLocally = true,
                Pinned = false,
                ManagedScopes = {},
            },
            [localCategory.SyncId] = {
                OwnedLocally = true,
                Pinned = false,
                ManagedScopes = {},
            },
        },
        SyncScopes = {},
        Migrations = {},
    }
    AngryEra.entitySyncIndexes = nil
    AngryEra.syncDraftConflict = nil
    AngryEra:ResetActivePageTransientState()
    authorization = {
        pageUpsert = true,
        display = true,
        request = true,
    }
    authorizationCalls = {}
    authorizationHook = nil
    hashHook = nil
    localPublish = {
        pageUpsert = true,
        display = true,
    }
    ResetUi()
end

local function MakePage(revision, contents, overrides)
    local page = {
        Kind = "page",
        SyncId = remotePageSyncId,
        OwnerId = remoteInstallationId,
        Revision = revision,
        UpdatedAt = currentTime + revision,
        UpdatedBy = "Leader-Realm",
        ParentSyncId = remoteParentSyncId,
        Order = 2,
        Name = "Raid Assignments",
        Vars = "page=yes",
        Contents = contents,
    }
    for key, value in pairs(overrides or {}) do
        page[key] = value
    end
    page.RevisionId = assert(schema.BuildEntityRevisionId(page, TestHash))
    return page
end

local function MakePayload(revision, contents, layerVars, overrides)
    local page = MakePage(revision, contents, overrides)
    return assert(activePage.BuildPageUpsertPayload(page, {
        {
            SyncId = remoteParentSyncId,
            Vars = layerVars or "raid=one",
        },
    }, TestHash))
end

ResetStorage()
local initialPages = AngryAssign_Pages
local initialMeta = AngryAssign_Meta
local payload = MakePayload(1, "Tank: One")
local accepted, result = AngryEra:AcceptActivePageUpsert({
    Sender = {},
    SenderInstallationId = remoteInstallationId,
    SenderSessionId = "leader_session",
    ReceivedAt = currentTime,
}, payload)
AssertError(accepted, result, "invalid-active-page-sender", "non-string authenticated sender")
Assert(AngryAssign_Pages == initialPages and AngryAssign_Meta == initialMeta, "malformed auth does not mutate storage")

authorization.pageUpsert = false
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), payload)
AssertError(accepted, result, "unauthorized-page-upsert", "unauthorized page upsert")
Assert(AngryAssign_Pages == initialPages and AngryAssign_Meta == initialMeta, "unauthorized upsert does not mutate")
authorization.pageUpsert = true

local malformedPayload = DeepCopy(payload)
malformedPayload.Page.Contents = "tampered"
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), malformedPayload)
AssertError(accepted, result, "revision-id-mismatch", "tampered page upsert")
Assert(AngryAssign_Pages == initialPages and AngryAssign_Meta == initialMeta, "malformed upsert does not mutate")

local localNamespacePayload = MakePayload(1, "Collision", nil, {
    SyncId = localInstallationId .. ":page:99",
    OwnerId = localInstallationId,
})
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), localNamespacePayload)
AssertError(accepted, result, "local-namespace-collision", "local installation namespace")

AngryAssign_Meta.EntityLocal[remotePageSyncId] = {
    OwnedLocally = true,
    Pinned = false,
    ManagedScopes = {},
}
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), payload)
AssertError(accepted, result, "locally-owned-collision", "receiver-local ownership collision")
AngryAssign_Meta.EntityLocal[remotePageSyncId] = nil

accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), payload)
Assert(accepted, result)
Assert(result.Applied and result.Created, "new remote page is applied")
AssertEqual(result.LocalId, 4, "allocator reserves occupied, displayed, and selected page IDs")
local remotePage = AngryAssign_Pages[4]
Assert(remotePage ~= nil and remotePage.Id == 4, "new remote page uses allocated local id")
Assert(
    remotePage.CategoryId == nil and remotePage.Index == nil,
    "new active-only page does not import hierarchy placement"
)
Assert(remotePage.ParentSyncId == nil and remotePage.Order == nil, "wire placement is not persisted as local fields")
AssertEqual(remotePage.Contents, "Tank: One", "canonical page content is installed")
Assert(AngryAssign_Meta ~= initialMeta, "metadata is replaced copy-on-write")
Assert(
    AngryAssign_Meta.EntityLocal[remotePageSyncId].OwnedLocally == false,
    "remote ownership is recorded only as receiver-local provenance"
)
Assert(AngryEra.entitySyncIndexes.page[remotePageSyncId] == remotePage, "identity index points at replacement")
local cached = AngryEra:GetActivePageRenderContext(remotePageSyncId, payload.Page.RevisionId, payload.ContextRevisionId)
Assert(cached ~= nil, "validated render context is cached")
AssertEqual(cached.SenderInstallationId, remoteInstallationId, "cache binds envelope installation")
AssertEqual(cached.SenderSessionId, "leader_session", "cache binds envelope session")
AssertEqual(cached.AncestorVariableLayers[1].Vars, "raid=one", "cache retains ancestor variables")
payload.AncestorVariableLayers[1].Vars = "packet mutation"
payload.Page.Contents = "packet mutation"
AssertEqual(remotePage.Contents, "Tank: One", "stored page is detached from packet")
cached = AngryEra:GetActivePageRenderContext(remotePageSyncId, remotePage.RevisionId, result.ContextRevisionId)
AssertEqual(cached.Page.Contents, "Tank: One", "cached page is detached from packet")
cached.AncestorVariableLayers[1].Vars = "caller mutation"
AssertEqual(
    AngryEra:GetActivePageRenderContext(remotePageSyncId, remotePage.RevisionId, result.ContextRevisionId).AncestorVariableLayers[1].Vars,
    "raid=one",
    "cache getter returns a detached copy"
)

local canonicalContents = remotePage.Contents
remotePage.Contents = "locally corrupted"
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), MakePayload(1, "Tank: One"))
AssertError(accepted, result, "page-revision-materialization-mismatch", "same revision local materialization")
remotePage.Contents = canonicalContents

local beforeStalePages = AngryAssign_Pages
local beforeStaleMeta = AngryAssign_Meta
local beforeStaleContext = AngryEra._activePageContexts
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), MakePayload(1, "Different at same revision"))
AssertError(accepted, result, "page-revision-divergence", "same revision divergence")
Assert(
    AngryAssign_Pages == beforeStalePages
        and AngryAssign_Meta == beforeStaleMeta
        and AngryEra._activePageContexts == beforeStaleContext,
    "divergent revision mutates neither persistence nor cache"
)

remotePage.CategoryId = 1
remotePage.Index = 7.5
remotePage.History = {
    {
        content = "older",
        timestamp = 20,
    },
}
AngryAssign_State.tree.selected = "4"
editorDirty = true
local secondPayload = MakePayload(2, "Tank: Two", "raid=two")
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), secondPayload)
Assert(accepted, result)
Assert(result.Applied and not result.Created, "newer known page revision applies")
local replacedPage = AngryAssign_Pages[4]
Assert(replacedPage ~= remotePage, "known page is replaced copy-on-write")
AssertEqual(replacedPage.CategoryId, 1, "known page keeps local category placement")
AssertEqual(replacedPage.Index, 7.5, "known page keeps local order overlay")
AssertEqual(replacedPage.History[1].content, "Tank: One", "replaced stored content enters history")
AssertEqual(replacedPage.History[1].author, "Leader-Realm", "automatic history uses authenticated sender")
AssertEqual(replacedPage.History[1].timestamp, currentTime, "automatic history uses receive time")
AssertEqual(replacedPage.History[2].content, "older", "existing history remains behind automatic entry")
Assert(result.SelectedDirtyConflict ~= nil, "dirty selected draft is reported as conflict")
Assert(AngryEra.syncDraftConflict ~= nil, "dirty conflict is retained in volatile editor state")
AssertEqual(draftText, "unsaved draft", "dirty draft text is preserved")
AssertEqual(uiCalls.DestructiveSelected, 0, "tree refresh cannot destructively reload selection")
AssertEqual(uiCalls.Conflict, 1, "dirty editor receives one conflict notification")

editorDirty = false
treeError = true
local thirdPayload = MakePayload(3, "Tank: Three", "raid=three")
local warning
accepted, result, warning = AngryEra:AcceptActivePageUpsert(Auth(), thirdPayload)
Assert(accepted, result)
AssertEqual(warning, "ui-refresh-failed", "post-commit tree exception becomes warning")
AssertEqual(AngryAssign_Pages[4].Contents, "Tank: Three", "UI failure does not roll back committed page")
treeError = false

local pagesBeforeRollback = AngryAssign_Pages
local metaBeforeRollback = AngryAssign_Meta
local cacheBeforeRollback = AngryEra._activePageContexts
local indexesBeforeRollback = AngryEra.entitySyncIndexes
local defaultInstaller = AngryEra.InstallSyncIdentityIndexes
function AngryEra:InstallSyncIdentityIndexes()
    error("index installation failed")
end
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), MakePayload(4, "Tank: Four"))
AssertError(accepted, result, "active-page-commit-failed", "identity-index install rollback")
Assert(
    AngryAssign_Pages == pagesBeforeRollback
        and AngryAssign_Meta == metaBeforeRollback
        and AngryEra._activePageContexts == cacheBeforeRollback
        and AngryEra.entitySyncIndexes == indexesBeforeRollback,
    "failed atomic commit restores every pointer"
)
AngryEra.InstallSyncIdentityIndexes = defaultInstaller

authorizationCalls = {}
authorizationHook = function(call, _, action)
    if action == "pageUpsert" and call == 2 then
        authorization.pageUpsert = false
    end
end
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), MakePayload(4, "Tank: Four"))
AssertError(accepted, result, "page-upsert-authorization-changed", "page authorization changes before commit")
Assert(AngryAssign_Pages == pagesBeforeRollback, "reauthorization failure does not commit")
authorization.pageUpsert = true
authorizationHook = nil

local function AssertReceiveMutationIsStale(label, mutate, restore)
    authorizationCalls = {}
    authorizationHook = function(call, _, action)
        if action == "pageUpsert" and call == 2 then
            mutate()
        end
    end
    local pagesBeforeMutation = AngryAssign_Pages
    local metaBeforeMutation = AngryAssign_Meta
    local acceptedMutation, mutationError = AngryEra:AcceptActivePageUpsert(Auth(), MakePayload(4, "Tank: Four"))
    AssertError(acceptedMutation, mutationError, "stale-active-page-state", label)
    Assert(
        AngryAssign_Pages == pagesBeforeMutation and AngryAssign_Meta == metaBeforeMutation,
        label .. " does not replace persistence"
    )
    restore()
    authorizationHook = nil
end

local remoteLocalState = AngryAssign_Meta.EntityLocal[remotePageSyncId]
AssertReceiveMutationIsStale("OwnedLocally mutation during reauthorization", function()
    remoteLocalState.OwnedLocally = true
end, function()
    remoteLocalState.OwnedLocally = false
end)
AssertReceiveMutationIsStale("Pinned mutation during reauthorization", function()
    remoteLocalState.Pinned = true
end, function()
    remoteLocalState.Pinned = false
end)
AssertReceiveMutationIsStale("ManagedScopes membership mutation during reauthorization", function()
    remoteLocalState.ManagedScopes[remoteParentSyncId] = true
end, function()
    remoteLocalState.ManagedScopes[remoteParentSyncId] = nil
end)
local priorSequence = AngryAssign_Meta.NextEntitySequence
AssertReceiveMutationIsStale("top-level metadata mutation during reauthorization", function()
    AngryAssign_Meta.NextEntitySequence = priorSequence + 1
end, function()
    AngryAssign_Meta.NextEntitySequence = priorSequence
end)
AssertReceiveMutationIsStale("top-level state mutation during reauthorization", function()
    AngryAssign_State.runtimeProbe = true
end, function()
    AngryAssign_State.runtimeProbe = nil
end)
local historyDuringReauthorization = AngryAssign_Pages[4].History
local historyContentBeforeReauthorization = historyDuringReauthorization[1].content
AssertReceiveMutationIsStale("History entry mutation during reauthorization", function()
    historyDuringReauthorization[1].content = "concurrent local history edit"
end, function()
    AssertEqual(
        historyDuringReauthorization[1].content,
        "concurrent local history edit",
        "stale rejection preserves the concurrent History mutation"
    )
    historyDuringReauthorization[1].content = historyContentBeforeReauthorization
end)

local matchingPayload = MakePayload(4, "Tank: Four")
AngryEra:ResetActivePageTransientState()
local displayPayload = {
    Displayed = true,
    SyncId = remotePageSyncId,
    RevisionId = matchingPayload.Page.RevisionId,
    ContextRevisionId = matchingPayload.ContextRevisionId,
}
local displayedBeforeRequest = AngryAssign_State.displayed
accepted, result = AngryEra:AcceptActiveDisplay(Auth(), displayPayload)
Assert(accepted, result)
Assert(result.RequestNeeded and not result.Applied, "missing exact render tuple returns request-needed")
AssertEqual(result.RequestPayload.SyncId, remotePageSyncId, "request-needed payload keeps exact page identity")
AssertEqual(result.RequestPayload.RevisionId, matchingPayload.Page.RevisionId, "request keeps exact revision")
AssertEqual(
    result.RequestPayload.ContextRevisionId,
    matchingPayload.ContextRevisionId,
    "request keeps exact context revision"
)
AssertEqual(AngryAssign_State.displayed, displayedBeforeRequest, "missing tuple does not change display selection")
Assert(AngryEra:GetPendingActiveDisplayRequest() ~= nil, "missing tuple is retained only as volatile pending state")

accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), matchingPayload)
Assert(accepted, result)
Assert(result.PendingDisplayReady, "matching page upsert reports pending display readiness")
Assert(result.PendingDisplayPayload ~= displayPayload, "pending display result is detached")
accepted, result = AngryEra:AcceptActiveDisplay(Auth(), result.PendingDisplayPayload)
Assert(accepted, result)
Assert(result.Applied and not result.RequestNeeded, "exact cached tuple selects display")
AssertEqual(AngryAssign_State.displayed, 4, "display resolves immutable identity to local numeric id")
Assert(AngryEra:GetPendingActiveDisplayRequest() == nil, "successful display clears pending reference")
local activeReference = AngryEra:GetActiveDisplayReference()
AssertEqual(activeReference.ContextRevisionId, matchingPayload.ContextRevisionId, "active display keeps exact context")

local storedBeforeUnsolicited = AngryAssign_Pages[4]
storedBeforeUnsolicited.History = {}
for index = 1, 10 do
    storedBeforeUnsolicited.History[index] = {
        content = "retained-" .. index,
        timestamp = index,
        author = "Earlier-Realm",
    }
end
local unsolicitedPayload = MakePayload(5, "Tank: Five", "raid=five")
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), unsolicitedPayload)
Assert(accepted and result.Applied, result)
AssertEqual(AngryAssign_Pages[4].Contents, "Tank: Five", "new unsolicited revision updates stored page")
AssertEqual(#AngryAssign_Pages[4].History, 10, "automatic history is capped at ten entries")
AssertEqual(AngryAssign_Pages[4].History[1].content, "Tank: Four", "history records replaced stored content")
local retainedActive = AngryEra:GetActivePageRenderContext(
    remotePageSyncId,
    matchingPayload.Page.RevisionId,
    matchingPayload.ContextRevisionId
)
Assert(retainedActive ~= nil, "new unsolicited tuple does not evict active older tuple")
AssertEqual(retainedActive.Page.Contents, "Tank: Four", "active cache retains the exact older page snapshot")

AngryAssign_Pages[4].History[1] = {
    content = "Tank: Five",
    timestamp = 999,
    author = "Existing-Realm",
}
local dedupePayload = MakePayload(6, "Tank: Six", "raid=six")
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), dedupePayload)
Assert(accepted and result.Applied, result)
AssertEqual(#AngryAssign_Pages[4].History, 10, "consecutive duplicate history remains bounded")
AssertEqual(AngryAssign_Pages[4].History[1].timestamp, 999, "consecutive duplicate history is not reinserted")

accepted, result = AngryEra:AcceptActiveDisplay(Auth(), displayPayload)
Assert(accepted and result.NoOp, "older exact active tuple remains a display no-op after newer upsert")

accepted, result = AngryEra:AcceptActiveDisplay(
    Auth({
        SenderSessionId = "other_session",
    }),
    displayPayload
)
Assert(accepted and result.Applied and result.ContextRebound, "current leader rebinds an exact prior-session context")
AssertEqual(AngryAssign_State.displayed, 4, "exact session rebind retains the current selection")
AssertEqual(
    AngryEra:GetActiveDisplayReference().SenderSessionId,
    "other_session",
    "rebound display context is bound to the current leader session"
)

authorization.display = false
local stateBeforeUnauthorizedDisplay = AngryAssign_State
accepted, result = AngryEra:AcceptActiveDisplay(Auth(), {
    Displayed = false,
})
AssertError(accepted, result, "unauthorized-display", "unauthorized display clear")
Assert(AngryAssign_State == stateBeforeUnauthorizedDisplay, "unauthorized clear does not mutate state")
authorization.display = true

displayError = true
accepted, result, warning = AngryEra:AcceptActiveDisplay(Auth(), {
    Displayed = false,
})
Assert(accepted and result.Applied, result)
AssertEqual(warning, "ui-refresh-failed", "display UI exception is reported after commit")
Assert(AngryAssign_State.displayed == nil, "display UI failure does not roll back clear")
displayError = false

accepted, result = AngryEra:AcceptActiveDisplay(Auth(), {
    Displayed = false,
})
Assert(accepted and result.NoOp, "repeated clear is a no-op")

Assert(AngryEra:AcceptActiveDisplay(Auth(), displayPayload), "cached exact display is available for response tests")
local pageRequestPayload = {
    SyncId = displayPayload.SyncId,
    RevisionId = displayPayload.RevisionId,
    ContextRevisionId = displayPayload.ContextRevisionId,
}
local requestPlan, requestError = AngryEra:BuildActivePageRequestResponse(
    Auth({
        Sender = "Requester",
        SenderInstallationId = otherInstallationId,
        SenderSessionId = "requester_session",
    }),
    pageRequestPayload,
    {
        UpdatedAt = currentTime,
        UpdatedBy = "Viewer-Realm",
    }
)
Assert(requestPlan ~= nil and requestError == nil, "exact PAGE_REQUEST builds a response plan")
AssertEqual(requestPlan.Type, "PAGE_UPSERT", "page request plan names existing message type")
AssertEqual(requestPlan.Payload.Page.RevisionId, displayPayload.RevisionId, "page response matches requested revision")
AssertEqual(
    requestPlan.Payload.ContextRevisionId,
    displayPayload.ContextRevisionId,
    "page response matches requested context"
)

local mismatchedRequest = DeepCopy(pageRequestPayload)
mismatchedRequest.ContextRevisionId = "fcs32:00000000"
local requestRevision = AngryAssign_Pages[4].Revision
local requestRevisionId = AngryAssign_Pages[4].RevisionId
local requestUpdatedAt = AngryAssign_Pages[4].UpdatedAt
local requestUpdatedBy = AngryAssign_Pages[4].UpdatedBy
requestPlan, requestError = AngryEra:BuildActivePageRequestResponse(
    Auth({
        Sender = "Requester",
        SenderInstallationId = otherInstallationId,
        SenderSessionId = "requester_session",
    }),
    mismatchedRequest,
    {
        UpdatedAt = currentTime,
        UpdatedBy = "Viewer-Realm",
    }
)
AssertError(requestPlan, requestError, "requested-page-version-unavailable", "unavailable exact page request")
AssertEqual(AngryAssign_Pages[4].Revision, requestRevision, "unavailable request does not touch revision")
AssertEqual(AngryAssign_Pages[4].RevisionId, requestRevisionId, "unavailable request preserves revision identity")
AssertEqual(AngryAssign_Pages[4].UpdatedAt, requestUpdatedAt, "unavailable request preserves audit time")
AssertEqual(AngryAssign_Pages[4].UpdatedBy, requestUpdatedBy, "unavailable request preserves audit author")

AngryAssign_State.displayed = 4
local displayPlan, displayPlanError = AngryEra:BuildActiveDisplayRequestResponse(
    Auth({
        Sender = "Requester",
        SenderInstallationId = otherInstallationId,
        SenderSessionId = "requester_session",
    }),
    {},
    {
        UpdatedAt = currentTime,
        UpdatedBy = "Viewer-Realm",
    }
)
Assert(displayPlan ~= nil and displayPlanError == nil, "DISPLAY_REQUEST builds response plan")
AssertEqual(displayPlan.Type, "DISPLAY", "display response plan names existing message type")
Assert(displayPlan.Payload.Displayed, "display response identifies the selected page")
Assert(displayPlan.PageUpsertPayload ~= nil, "display response exposes matching optional page upsert")
AssertEqual(
    displayPlan.Payload.ContextRevisionId,
    displayPlan.PageUpsertPayload.ContextRevisionId,
    "display and page response share one prepared tuple"
)
AssertEqual(
    displayPlan.PageUpsertPayload.Page.Contents,
    "Tank: Four",
    "display request answers the selected cached tuple instead of newer stored content"
)

localPublish.display = false
displayPlan, displayPlanError = AngryEra:BuildActiveDisplayRequestResponse(Auth(), {}, {
    UpdatedAt = currentTime,
    UpdatedBy = "Viewer-Realm",
})
AssertError(displayPlan, displayPlanError, "local-display-publish-not-authorized", "local display response publication")
localPublish.display = true

local activelyStoredPage = AngryAssign_Pages[4]
Assert(AngryEra:HasAuthoritativePageContext(activelyStoredPage), "remote page has an exact authoritative base")
local firstSameSecondPayload = MakePayload(6, "Tank: Six", "tie=a")
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), firstSameSecondPayload)
Assert(accepted and result.NoOp, "first same-second context-only change is cached")
local latestSameSecondPayload = MakePayload(6, "Tank: Six", "tie=b")
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), latestSameSecondPayload)
Assert(accepted and result.NoOp, "latest same-second context-only change is cached")
local activeBeforePreparation = AngryEra:GetActiveDisplayReference()
activelyStoredPage.Contents = "Locally edited while displayed"
local proactiveDisplay, proactiveUpsert, proactivePreparation = AngryEra:BuildActiveDisplayPayload(4, {
    UpdatedAt = 3000,
    UpdatedBy = "Viewer-Realm",
})
Assert(proactiveDisplay ~= nil and proactiveUpsert ~= nil, "proactive display prepares current local state")
AssertEqual(proactivePreparation.RevisionAction, "touched", "edited displayed page touches its revision")
AssertEqual(
    proactiveUpsert.Page.Contents,
    "Locally edited while displayed",
    "proactive display never rebroadcasts stale cached content"
)
AssertEqual(
    proactiveDisplay.RevisionId,
    proactiveUpsert.Page.RevisionId,
    "proactive display uses the newly prepared exact revision"
)
AssertEqual(
    proactiveUpsert.Page.ParentSyncId,
    remoteParentSyncId,
    "remote-owned preparation retains authoritative parent instead of private CategoryId"
)
AssertEqual(proactiveUpsert.Page.Order, 2, "remote-owned preparation retains authoritative wire order")
AssertEqual(
    proactiveUpsert.AncestorVariableLayers[1].Vars,
    "tie=b",
    "remote-owned preparation uses the latest same-second authoritative ancestor variables"
)
AssertEqual(activelyStoredPage.CategoryId, 1, "remote-owned preparation preserves private local category")
AssertEqual(activelyStoredPage.Index, 7.5, "remote-owned preparation preserves private local index")
AssertEqual(
    AngryEra:GetActiveDisplayReference().RevisionId,
    activeBeforePreparation.RevisionId,
    "payload construction does not activate its prepared tuple"
)

activelyStoredPage.Contents = "Second local edit while displayed"
local secondProactiveDisplay, secondProactiveUpsert, secondProactivePreparation =
    AngryEra:BuildActiveDisplayPayload(4, {
        UpdatedAt = 3001,
        UpdatedBy = "Viewer-Realm",
    })
Assert(secondProactiveDisplay and secondProactiveUpsert, "cached prepared tuple supports a consecutive remote edit")
AssertEqual(secondProactivePreparation.RevisionAction, "touched", "consecutive remote edit touches once")
AssertEqual(
    secondProactiveUpsert.Page.Revision,
    proactiveUpsert.Page.Revision + 1,
    "consecutive remote edit advances exactly one revision"
)
AssertEqual(
    secondProactiveUpsert.Page.ParentSyncId,
    proactiveUpsert.Page.ParentSyncId,
    "consecutive remote edit retains authoritative parent"
)
AssertEqual(
    secondProactiveUpsert.Page.Order,
    proactiveUpsert.Page.Order,
    "consecutive remote edit retains authoritative order"
)
AssertEqual(
    secondProactiveUpsert.ContextRevisionId,
    proactiveUpsert.ContextRevisionId,
    "unchanged variables and hierarchy retain authoritative context identity"
)

local rollbackAuth = Auth({
    Sender = "Assistant",
})
accepted, result = AngryEra:AcceptActiveDisplay(rollbackAuth, proactiveDisplay)
Assert(accepted and result.RequestNeeded, "assistant cannot consume locally prepared context without its own tuple")
local pendingForRollback = result.RequestPayload
local pagesBeforeContextOnly = AngryAssign_Pages
local pageBeforeContextOnly = AngryAssign_Pages[4]
local metaBeforeContextOnly = AngryAssign_Meta
local indexesBeforeContextOnly = AngryEra.entitySyncIndexes
local historyBeforeContextOnly = pageBeforeContextOnly.History
local stateBeforeContextOnly = AngryAssign_State
local treeCallsBeforeContextOnly = uiCalls.Tree
local selectedCallsBeforeContextOnly = uiCalls.Selected

accepted, result = AngryEra:AcceptActivePageUpsert(rollbackAuth, proactiveUpsert)
AssertError(accepted, result, "page-revision-rollback", "uncorrelated prior revision")
accepted, result = AngryEra:AcceptActivePageUpsert(rollbackAuth, proactiveUpsert, {})
AssertError(
    accepted,
    result,
    "active-page-accept-options-missing-CorrelatedReply",
    "correlated option requires its sole field"
)
accepted, result = AngryEra:AcceptActivePageUpsert(rollbackAuth, proactiveUpsert, {
    CorrelatedReply = false,
})
AssertError(accepted, result, "invalid-active-page-correlated-reply", "correlated option must be true")
accepted, result = AngryEra:AcceptActivePageUpsert(rollbackAuth, proactiveUpsert, {
    CorrelatedReply = true,
    Extra = true,
})
AssertError(accepted, result, "active-page-accept-options-unknown-field", "correlated option rejects extras")
accepted, result = AngryEra:AcceptActivePageUpsert(
    Auth({
        Sender = "Assistant",
        SenderSessionId = "wrong_pending_session",
    }),
    proactiveUpsert,
    {
        CorrelatedReply = true,
    }
)
AssertError(accepted, result, "page-revision-rollback", "correlated rollback must match pending source session")

local contextsBeforeContextOnly = AngryEra._activePageContexts
accepted, result = AngryEra:AcceptActivePageUpsert(rollbackAuth, proactiveUpsert, {
    CorrelatedReply = true,
})
Assert(accepted and result.ContextOnly, "correlated prior revision commits context only")
Assert(result.PendingDisplayReady, "context-only commit makes exact pending display ready")
AssertEqual(result.PendingDisplayPayload.RevisionId, pendingForRollback.RevisionId, "pending tuple is returned exactly")
Assert(
    AngryAssign_Pages == pagesBeforeContextOnly
        and AngryAssign_Pages[4] == pageBeforeContextOnly
        and AngryAssign_Meta == metaBeforeContextOnly
        and AngryEra.entitySyncIndexes == indexesBeforeContextOnly
        and pageBeforeContextOnly.History == historyBeforeContextOnly
        and AngryAssign_State == stateBeforeContextOnly,
    "context-only commit changes no page, metadata, history, index, or state pointer"
)
Assert(AngryEra._activePageContexts ~= contextsBeforeContextOnly, "context-only commit replaces only volatile cache")
AssertEqual(uiCalls.Tree, treeCallsBeforeContextOnly, "context-only commit does not refresh tree")
AssertEqual(uiCalls.Selected, selectedCallsBeforeContextOnly, "context-only commit does not refresh editor")

accepted, result = AngryEra:AcceptActiveDisplay(rollbackAuth, result.PendingDisplayPayload)
Assert(accepted and result.Applied, "newly cached prior tuple completes pending display")

local mismatchedPreparedDisplay = DeepCopy(secondProactiveDisplay)
mismatchedPreparedDisplay.RevisionId = proactiveDisplay.RevisionId
local referenceBeforeFailedActivation = AngryEra:GetActiveDisplayReference()
local activated, activationResult =
    AngryEra:ActivatePreparedActiveDisplay(mismatchedPreparedDisplay, secondProactiveUpsert)
AssertError(
    activated,
    activationResult,
    "active-display-page-tuple-mismatch",
    "prepared activation requires an exact tuple"
)
AssertEqual(
    AngryEra:GetActiveDisplayReference().RevisionId,
    referenceBeforeFailedActivation.RevisionId,
    "failed prepared activation preserves active reference"
)

local statePointerBeforeActivation = AngryAssign_State
local displayedBeforeActivation = AngryAssign_State.displayed
local treeCallsBeforeActivation = uiCalls.Tree
activated, activationResult = AngryEra:ActivatePreparedActiveDisplay(secondProactiveDisplay, secondProactiveUpsert)
Assert(activated and activationResult.Applied, "prepared exact tuple activates locally")
Assert(
    AngryAssign_State == statePointerBeforeActivation and AngryAssign_State.displayed == displayedBeforeActivation,
    "prepared activation does not change persisted display selection"
)
AssertEqual(uiCalls.Tree, treeCallsBeforeActivation, "prepared activation performs no UI work")
AssertEqual(
    AngryEra:GetActiveDisplayReference().RevisionId,
    secondProactiveDisplay.RevisionId,
    "prepared activation installs the exact volatile reference"
)

accepted, result = AngryEra:AcceptActiveDisplay(
    Auth({
        Sender = "Assistant",
        SenderSessionId = "pending_clear_session",
    }),
    secondProactiveDisplay
)
Assert(accepted and result.RequestNeeded, "missing remote-source tuple creates pending state for clear test")
local contextsBeforeClear = AngryEra._activePageContexts
local cleared, clearResult = AngryEra:ClearActiveDisplayReference()
Assert(cleared and clearResult.Applied, "volatile display clear succeeds")
Assert(AngryEra:GetActiveDisplayReference() == nil, "volatile clear removes active reference")
Assert(AngryEra:GetPendingActiveDisplayRequest() == nil, "volatile clear removes pending reference")
Assert(AngryEra._activePageContexts == contextsBeforeClear, "volatile clear retains exact context cache")
Assert(
    AngryAssign_State == statePointerBeforeActivation and AngryAssign_State.displayed == displayedBeforeActivation,
    "volatile clear leaves persisted display selection unchanged"
)
cleared, clearResult = AngryEra:ClearActiveDisplayReference()
Assert(cleared and clearResult.NoOp, "repeated volatile clear is a no-op")
accepted, result = AngryEra:AcceptActiveDisplay(Auth(), displayPayload)
Assert(accepted and not result.RequestNeeded, "older remote active tuple can be restored after volatile clear")

local localPage = AngryAssign_Pages[1]
Assert(localPage.Revision == nil, "local fixture begins without revision metadata")
AngryAssign_Meta.EntityLocal[localPage.SyncId].ManagedScopes = nil
AngryAssign_Meta.SyncScopes[localCategorySyncId] = {
    Enabled = true,
}
local localDisplay, localUpsert, preparation = AngryEra:BuildActiveDisplayPayload(1, {
    UpdatedAt = 2000,
    UpdatedBy = "Viewer-Realm",
})
Assert(localDisplay ~= nil and localUpsert ~= nil, "local display prepares one matching page upsert")
AssertEqual(preparation.RevisionAction, "initialized", "first local preparation initializes revision")
AssertEqual(preparation.BoundarySyncId, localCategorySyncId, "enabled managed scope bounds ancestor disclosure")
AssertEqual(localDisplay.RevisionId, localUpsert.Page.RevisionId, "local display and upsert revision match")
local firstLocalRevision = localPage.Revision
localDisplay, localUpsert, preparation = AngryEra:BuildActiveDisplayPayload(1, {
    UpdatedAt = 2001,
    UpdatedBy = "Viewer-Realm",
})
Assert(localDisplay ~= nil and localUpsert ~= nil, "repeated local display still returns one matching tuple")
AssertEqual(preparation.RevisionAction, "unchanged", "unchanged local display does not touch revision twice")
AssertEqual(localPage.Revision, firstLocalRevision, "unchanged repeated preparation keeps revision")

local middleCategorySyncId = localInstallationId .. ":category:3"
local directCategorySyncId = localInstallationId .. ":category:4"
AngryAssign_Categories[2] = LocalRecord("category", 2, middleCategorySyncId, localInstallationId, {
    Name = "Narrower managed scope",
    CategoryId = 1,
    Index = 1,
})
AngryAssign_Categories[3] = LocalRecord("category", 3, directCategorySyncId, localInstallationId, {
    Name = "Direct parent",
    CategoryId = 2,
    Index = 1,
})
localPage.CategoryId = 3
AngryAssign_Meta.SyncScopes[middleCategorySyncId] = {
    Enabled = true,
}
AngryAssign_Meta.SyncScopes[directCategorySyncId] = {
    Enabled = false,
}
local nestedUpsert, nestedError, nestedPreparation = AngryEra:PrepareActivePageUpsert(1, {
    UpdatedAt = 2002,
    UpdatedBy = "Viewer-Realm",
})
Assert(nestedUpsert and not nestedError, "page without ManagedScopes derives enabled ancestor scope")
AssertEqual(
    nestedPreparation.BoundarySyncId,
    middleCategorySyncId,
    "closest enabled ancestor becomes the trusted disclosure boundary"
)

local revisionBeforeBroadening = localPage.Revision
local invalidManaged, invalidManagedError = AngryEra:PrepareActivePageUpsert(1, {
    UpdatedAt = 2003,
    UpdatedBy = "Viewer-Realm",
    ManagedScopeId = localCategorySyncId,
})
AssertError(
    invalidManaged,
    invalidManagedError,
    "managed-scope-boundary-broadened",
    "explicit managed scope cannot broaden above trusted boundary"
)
AssertEqual(localPage.Revision, revisionBeforeBroadening, "rejected boundary broadening does not touch revision")

local narrowedUpsert, narrowedError, narrowedPreparation = AngryEra:PrepareActivePageUpsert(1, {
    UpdatedAt = 2004,
    UpdatedBy = "Viewer-Realm",
    ManagedScopeId = directCategorySyncId,
})
Assert(narrowedUpsert and not narrowedError, "explicit narrower ancestor boundary is allowed")
AssertEqual(
    narrowedPreparation.BoundarySyncId,
    directCategorySyncId,
    "explicit narrower boundary starts at the direct parent"
)

local scopeHashMutated = false
local revisionBeforeScopeMutation = localPage.Revision
local revisionIdBeforeScopeMutation = localPage.RevisionId
localPage.Contents = "scope mutation preparation"
hashHook = function()
    if not scopeHashMutated then
        scopeHashMutated = true
        AngryAssign_Meta.SyncScopes[middleCategorySyncId].Enabled = false
    end
end
local staleScopeUpsert, staleScopeError = AngryEra:PrepareActivePageUpsert(1, {
    UpdatedAt = 2005,
    UpdatedBy = "Viewer-Realm",
})
AssertError(staleScopeUpsert, staleScopeError, "stale-active-page-state", "in-place SyncScopes mutation")
AssertEqual(localPage.Revision, revisionBeforeScopeMutation, "stale scope mutation rolls back prepared revision")
AssertEqual(
    localPage.RevisionId,
    revisionIdBeforeScopeMutation,
    "stale scope mutation rolls back prepared revision identity"
)
Assert(
    AngryAssign_Meta.SyncScopes[middleCategorySyncId].Enabled == false,
    "stale guard preserves concurrent scope mutation"
)
hashHook = nil
AngryAssign_Meta.SyncScopes[middleCategorySyncId].Enabled = true

AngryAssign_Meta.SyncScopes[remoteParentSyncId] = {
    Enabled = true,
}
invalidManaged, invalidManagedError = AngryEra:PrepareActivePageUpsert(1, {
    UpdatedAt = 2006,
    UpdatedBy = "Viewer-Realm",
    ManagedScopeId = remoteParentSyncId,
})
AssertError(invalidManaged, invalidManagedError, "managed-scope-not-ancestor", "managed scope privacy boundary")

local boundedPayloads = {}
for sequence = 134, 100, -1 do
    local boundedPayload = MakePayload(1, "Bounded " .. sequence, nil, {
        SyncId = remoteInstallationId .. ":page:" .. sequence,
    })
    boundedPayloads[sequence] = boundedPayload
    accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), boundedPayload)
    Assert(accepted and result.Created, "bounded cache fixture page applies")
end
local contextCount = 0
for _ in pairs(AngryEra._activePageContexts) do
    contextCount = contextCount + 1
end
AssertEqual(contextCount, 32, "volatile tuple cache stays bounded")
Assert(
    AngryEra:GetActivePageRenderContext(
        remotePageSyncId,
        matchingPayload.Page.RevisionId,
        matchingPayload.ContextRevisionId
    ) ~= nil,
    "bounded cache eviction preserves the active display tuple"
)
Assert(
    AngryEra:GetActivePageRenderContext(
        boundedPayloads[101].Page.SyncId,
        boundedPayloads[101].Page.RevisionId,
        boundedPayloads[101].ContextRevisionId
    ) ~= nil,
    "same-second cache eviction retains a recent unprotected arrival"
)
Assert(
    AngryEra:GetActivePageRenderContext(
        boundedPayloads[134].Page.SyncId,
        boundedPayloads[134].Page.RevisionId,
        boundedPayloads[134].ContextRevisionId
    ) == nil,
    "same-second cache eviction removes the oldest unprotected arrival"
)

local foreignOwnerPayload = MakePayload(1, "Foreign owner", nil, {
    SyncId = remoteInstallationId .. ":page:99",
})
accepted, result = AngryEra:AcceptActivePageUpsert(
    Auth({
        Sender = "Assistant",
        SenderInstallationId = otherInstallationId,
        SenderSessionId = "assistant_session",
    }),
    foreignOwnerPayload
)
Assert(accepted and result.Created, "authorized assistant may relay a foreign-owned page")
accepted, result = AngryEra:AcceptActivePageUpsert(
    Auth({
        SenderInstallationId = otherInstallationId,
        SenderSessionId = "leader_relay_session",
    }),
    foreignOwnerPayload
)
Assert(accepted and result.NoOp, "owner identity is inert after the authorized assistant create")

local persistedPages = AngryAssign_Pages
local remoteRevisionBeforeReset = AngryAssign_Pages[4].Revision
local remoteRevisionIdBeforeReset = AngryAssign_Pages[4].RevisionId
AngryEra:ResetActivePageTransientState()
Assert(AngryEra:GetActiveDisplayReference() == nil, "transient reset clears active display")
Assert(AngryEra:GetPendingActiveDisplayRequest() == nil, "transient reset clears pending display")
Assert(
    AngryEra:GetActivePageRenderContext(
        remotePageSyncId,
        matchingPayload.Page.RevisionId,
        matchingPayload.ContextRevisionId
    ) == nil,
    "transient reset clears render context"
)
Assert(AngryAssign_Pages == persistedPages, "transient reset never clears persisted pages")
Assert(not AngryEra:HasAuthoritativePageContext(4), "remote page needs an exact cached authoritative base")
Assert(AngryEra:HasAuthoritativePageContext(1), "local-owned page never needs remote hierarchy context")
local missingContextUpsert, missingContextError = AngryEra:PrepareActivePageUpsert(4, {
    UpdatedAt = 4000,
    UpdatedBy = "Viewer-Realm",
})
AssertError(
    missingContextUpsert,
    missingContextError,
    "remote-page-context-unavailable",
    "remote republish refuses to reconstruct missing hierarchy"
)
AssertEqual(AngryAssign_Pages[4].Revision, remoteRevisionBeforeReset, "missing remote context does not touch revision")
AssertEqual(
    AngryAssign_Pages[4].RevisionId,
    remoteRevisionIdBeforeReset,
    "missing remote context preserves revision identity"
)

-- A current leader can select an exact tuple already cached under the former
-- publisher without waiting for a redundant PAGE_UPSERT. Assistants, changed
-- tuples, unknown pages, and invalid cached payloads must retain the pending
-- request behavior.
do
    ResetStorage()
    local exactPayload = MakePayload(1, "Handoff exact", "raid=handoff")
    local formerPublisherAuth = Auth({
        Sender = "FormerLeader",
        SenderInstallationId = remoteInstallationId,
        SenderSessionId = "former_leader_session",
    })
    accepted, result = AngryEra:AcceptActivePageUpsert(formerPublisherAuth, exactPayload)
    Assert(accepted and result.Applied and result.Created, result)

    local exactDisplay = {
        Displayed = true,
        SyncId = exactPayload.Page.SyncId,
        RevisionId = exactPayload.Page.RevisionId,
        ContextRevisionId = exactPayload.ContextRevisionId,
    }
    local newLeaderAuth = Auth({
        Sender = "Leader",
        SenderInstallationId = otherInstallationId,
        SenderSessionId = "new_leader_session",
    })
    local assistantAuth = Auth({
        Sender = "Assistant",
        SenderInstallationId = otherInstallationId,
        SenderSessionId = "assistant_session",
    })
    local pagesBeforeRebind = AngryAssign_Pages
    local categoriesBeforeRebind = AngryAssign_Categories
    local metaBeforeRebind = AngryAssign_Meta
    local stateBeforeRebind = AngryAssign_State
    local contextsBeforeRebind = AngryEra._activePageContexts
    local pageBeforeRebind = AngryAssign_Pages[result.LocalId]
    local indexesBeforeRebind = AngryEra.entitySyncIndexes

    accepted, result = AngryEra:AcceptActiveDisplay(assistantAuth, exactDisplay)
    Assert(accepted and result.RequestNeeded and not result.Applied, result)
    Assert(AngryAssign_State == stateBeforeRebind, "assistant display cannot replace persisted display state")
    Assert(AngryEra._activePageContexts == contextsBeforeRebind, "assistant display cannot rebind an exact context")
    AssertEqual(
        AngryEra:GetPendingActiveDisplayRequest().Sender,
        "Assistant-Realm",
        "assistant exact tuple remains pending"
    )

    local pendingBeforeRoleChange = AngryEra._activePendingDisplay
    local defaultGetGroupRole = AngryEra.GetGroupRole
    local leaderRoleChecks = 0
    function AngryEra:GetGroupRole(sender)
        if sender == "Leader-Realm" then
            leaderRoleChecks = leaderRoleChecks + 1
            return leaderRoleChecks == 1 and "leader" or "assistant"
        end
        return defaultGetGroupRole(self, sender)
    end
    accepted, result = AngryEra:AcceptActiveDisplay(newLeaderAuth, exactDisplay)
    AssertError(accepted, result, "display-authorization-changed", "leader role revoked before context rebind commit")
    AssertEqual(leaderRoleChecks, 2, "context rebind rechecks current leadership before commit")
    Assert(AngryAssign_State == stateBeforeRebind, "revoked rebind preserves persisted display state")
    Assert(AngryEra._activePageContexts == contextsBeforeRebind, "revoked rebind preserves cached contexts")
    Assert(
        AngryEra._activePendingDisplay == pendingBeforeRoleChange,
        "revoked rebind preserves the prior pending display"
    )
    AngryEra.GetGroupRole = defaultGetGroupRole

    accepted, result = AngryEra:AcceptActiveDisplay(newLeaderAuth, exactDisplay)
    Assert(accepted and result.Applied and result.ContextRebound and not result.RequestNeeded, result)
    AssertEqual(AngryAssign_State.displayed, pageBeforeRebind.Id, "current leader exact rebind selects the cached page")
    Assert(AngryAssign_Pages == pagesBeforeRebind, "context rebind does not replace persisted pages")
    Assert(AngryAssign_Categories == categoriesBeforeRebind, "context rebind does not replace persisted categories")
    Assert(AngryAssign_Meta == metaBeforeRebind, "context rebind does not replace persisted metadata")
    Assert(AngryAssign_Pages[pageBeforeRebind.Id] == pageBeforeRebind, "context rebind preserves the source page")
    Assert(AngryEra.entitySyncIndexes == indexesBeforeRebind, "context rebind does not install new identity indexes")
    Assert(AngryEra._activePageContexts ~= contextsBeforeRebind, "context rebind atomically installs a new cache")
    Assert(AngryEra:GetPendingActiveDisplayRequest() == nil, "successful context rebind clears stale pending display")
    local reboundReference = AngryEra:GetActiveDisplayReference()
    AssertEqual(reboundReference.Sender, "Leader-Realm", "rebound display is bound to the current leader")
    AssertEqual(
        reboundReference.SenderInstallationId,
        otherInstallationId,
        "rebound display is bound to the current leader installation"
    )
    AssertEqual(
        reboundReference.SenderSessionId,
        "new_leader_session",
        "rebound display is bound to the current leader session"
    )
    local reboundContext = AngryEra:GetActivePageRenderContext(
        exactPayload.Page.SyncId,
        exactPayload.Page.RevisionId,
        exactPayload.ContextRevisionId
    )
    AssertEqual(reboundContext.Page.Contents, "Handoff exact", "rebound context retains the validated page snapshot")
    AssertEqual(
        reboundContext.AncestorVariableLayers[1].Vars,
        "raid=handoff",
        "rebound context retains inherited variables"
    )

    local changedPayload = MakePayload(2, "Handoff changed", "raid=changed")
    local changedDisplay = {
        Displayed = true,
        SyncId = changedPayload.Page.SyncId,
        RevisionId = changedPayload.Page.RevisionId,
        ContextRevisionId = changedPayload.ContextRevisionId,
    }
    local stateBeforeChangedDisplay = AngryAssign_State
    local contextsBeforeChangedDisplay = AngryEra._activePageContexts
    local activeBeforeChangedDisplay = AngryEra._activeDisplayReference
    accepted, result = AngryEra:AcceptActiveDisplay(newLeaderAuth, changedDisplay)
    Assert(accepted and result.RequestNeeded and not result.Applied, result)
    Assert(AngryAssign_State == stateBeforeChangedDisplay, "changed tuple does not change persisted display state")
    Assert(AngryEra._activePageContexts == contextsBeforeChangedDisplay, "changed tuple is not rebound")
    Assert(
        AngryEra._activeDisplayReference == activeBeforeChangedDisplay,
        "changed tuple preserves the active reference"
    )
    AssertEqual(
        AngryAssign_Pages[pageBeforeRebind.Id].Contents,
        "Handoff exact",
        "changed tuple does not mutate source"
    )

    local unknownDisplay = {
        Displayed = true,
        SyncId = otherInstallationId .. ":page:99",
        RevisionId = "fcs32:12345678",
        ContextRevisionId = "fcs32:87654321",
    }
    local stateBeforeUnknownDisplay = AngryAssign_State
    local contextsBeforeUnknownDisplay = AngryEra._activePageContexts
    accepted, result = AngryEra:AcceptActiveDisplay(newLeaderAuth, unknownDisplay)
    Assert(accepted and result.RequestNeeded and not result.Applied, result)
    Assert(AngryAssign_State == stateBeforeUnknownDisplay, "unknown tuple does not change persisted display state")
    Assert(AngryEra._activePageContexts == contextsBeforeUnknownDisplay, "unknown tuple is not rebound")
end

do
    ResetStorage()
    local exactPayload = MakePayload(1, "Validated cache", "raid=validated")
    accepted, result = AngryEra:AcceptActivePageUpsert(
        Auth({
            Sender = "FormerLeader",
            SenderSessionId = "former_invalid_cache_session",
        }),
        exactPayload
    )
    Assert(accepted and result.Applied, result)
    local sourcePageId = result.LocalId

    local cachedEntry
    for _, entry in pairs(AngryEra._activePageContexts) do
        if entry.SyncId == exactPayload.Page.SyncId then
            cachedEntry = entry
            break
        end
    end
    Assert(cachedEntry ~= nil, "invalid-cache test locates the exact cached tuple")
    cachedEntry.Page.Contents = "tampered volatile cache"

    local pagesBeforeInvalidCache = AngryAssign_Pages
    local metaBeforeInvalidCache = AngryAssign_Meta
    local stateBeforeInvalidCache = AngryAssign_State
    local contextsBeforeInvalidCache = AngryEra._activePageContexts
    accepted, result = AngryEra:AcceptActiveDisplay(
        Auth({
            Sender = "Leader",
            SenderInstallationId = otherInstallationId,
            SenderSessionId = "new_invalid_cache_session",
        }),
        {
            Displayed = true,
            SyncId = exactPayload.Page.SyncId,
            RevisionId = exactPayload.Page.RevisionId,
            ContextRevisionId = exactPayload.ContextRevisionId,
        }
    )
    Assert(accepted and result.RequestNeeded and not result.Applied, result)
    Assert(AngryAssign_Pages == pagesBeforeInvalidCache, "invalid cached payload does not replace source pages")
    Assert(AngryAssign_Meta == metaBeforeInvalidCache, "invalid cached payload does not replace metadata")
    Assert(AngryAssign_State == stateBeforeInvalidCache, "invalid cached payload does not select a page")
    Assert(AngryEra._activePageContexts == contextsBeforeInvalidCache, "invalid cached payload is not rebound")
    AssertEqual(AngryAssign_Pages[sourcePageId].Contents, "Validated cache", "invalid cache leaves source intact")
end

-- A new display authority may relay an unchanged page back to its owning
-- installation. The relay only supplies the sender-bound volatile context
-- required by the following DISPLAY; it must never replace local-owned data.
ResetStorage()
local localOwnerPage = AngryAssign_Pages[1]
local localOwnerWire = {
    Kind = "page",
    SyncId = localPageSyncId,
    OwnerId = localInstallationId,
    Revision = 1,
    UpdatedAt = currentTime,
    UpdatedBy = "Viewer-Realm",
    ParentSyncId = localCategorySyncId,
    Order = 1,
    Name = localOwnerPage.Name,
    Vars = localOwnerPage.Vars,
    Contents = localOwnerPage.Contents,
}
localOwnerWire.RevisionId = assert(schema.BuildEntityRevisionId(localOwnerWire, TestHash))
localOwnerPage.Revision = localOwnerWire.Revision
localOwnerPage.RevisionId = localOwnerWire.RevisionId
localOwnerPage.UpdatedAt = localOwnerWire.UpdatedAt
localOwnerPage.UpdatedBy = localOwnerWire.UpdatedBy
local localOwnerPayload = assert(activePage.BuildPageUpsertPayload(localOwnerWire, {
    {
        SyncId = localCategorySyncId,
        Vars = "",
    },
}, TestHash))
local localOwnerDisplay = {
    Displayed = true,
    SyncId = localOwnerWire.SyncId,
    RevisionId = localOwnerWire.RevisionId,
    ContextRevisionId = localOwnerPayload.ContextRevisionId,
}
local pagesBeforeLocalOwnerRelay = AngryAssign_Pages
local categoriesBeforeLocalOwnerRelay = AngryAssign_Categories
local metaBeforeLocalOwnerRelay = AngryAssign_Meta
local stateBeforeLocalOwnerRelay = AngryAssign_State
local provenanceBeforeLocalOwnerRelay = AngryAssign_Meta.EntityLocal[localPageSyncId]
local managedScopesBeforeLocalOwnerRelay = provenanceBeforeLocalOwnerRelay.ManagedScopes
local indexesBeforeLocalOwnerRelay = AngryEra.entitySyncIndexes

accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), localOwnerPayload)
Assert(accepted and result.ContextOnly and result.LocalOwnerRelay, result)
Assert(not result.Applied and not result.Created, "local-owner relay caches context without applying a page revision")
AssertEqual(result.LocalId, 1, "local-owner relay resolves the existing local page")
Assert(AngryAssign_Pages == pagesBeforeLocalOwnerRelay, "local-owner relay preserves the pages table")
Assert(AngryAssign_Categories == categoriesBeforeLocalOwnerRelay, "local-owner relay preserves the categories table")
Assert(AngryAssign_Meta == metaBeforeLocalOwnerRelay, "local-owner relay preserves metadata")
Assert(AngryAssign_State == stateBeforeLocalOwnerRelay, "local-owner relay preserves display state")
Assert(AngryAssign_Pages[1] == localOwnerPage, "local-owner relay preserves the local page record")
Assert(
    AngryAssign_Meta.EntityLocal[localPageSyncId] == provenanceBeforeLocalOwnerRelay
        and provenanceBeforeLocalOwnerRelay.ManagedScopes == managedScopesBeforeLocalOwnerRelay,
    "local-owner relay preserves local provenance"
)
Assert(AngryEra.entitySyncIndexes == indexesBeforeLocalOwnerRelay, "local-owner relay does not install new indexes")
local localOwnerContext =
    AngryEra:GetActivePageRenderContext(localPageSyncId, localOwnerWire.RevisionId, localOwnerPayload.ContextRevisionId)
Assert(localOwnerContext ~= nil, "local-owner relay caches the exact volatile context")
AssertEqual(localOwnerContext.Sender, "Leader-Realm", "local-owner relay binds context to the display authority")

accepted, result = AngryEra:AcceptActiveDisplay(Auth(), localOwnerDisplay)
Assert(accepted and result.Applied and not result.RequestNeeded, result)
AssertEqual(AngryAssign_State.displayed, 1, "proactive local-owner relay lets the leader display the existing page")
Assert(AngryAssign_Pages == pagesBeforeLocalOwnerRelay, "display activation still preserves local-owned pages")
Assert(AngryAssign_Meta == metaBeforeLocalOwnerRelay, "display activation still preserves local-owned metadata")
local localOwnerActiveReference = AngryEra:GetActiveDisplayReference()
AssertEqual(localOwnerActiveReference.Sender, "Leader-Realm", "active local-owner relay remains bound to the leader")

-- DISPLAY can arrive before its PAGE_UPSERT and take the correlated request
-- path. The exact local-owner relay must complete that pending display too.
AngryEra:ResetActivePageTransientState()
accepted, result = AngryEra:AcceptActiveDisplay(Auth(), localOwnerDisplay)
Assert(accepted and result.RequestNeeded, result)
Assert(AngryEra:GetPendingActiveDisplayRequest() ~= nil, "missing relay context creates a pending display")
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), localOwnerPayload, {
    CorrelatedReply = true,
})
Assert(accepted and result.ContextOnly and result.PendingDisplayReady, result)
Assert(result.PendingDisplayPayload ~= nil, "local-owner reply returns the exact pending display payload")
accepted, result = AngryEra:AcceptActiveDisplay(Auth(), result.PendingDisplayPayload)
Assert(accepted and not result.RequestNeeded, result)
AssertEqual(AngryAssign_State.displayed, 1, "correlated local-owner relay completes the leader display")
Assert(AngryAssign_Pages == pagesBeforeLocalOwnerRelay, "correlated relay still preserves local-owned pages")
Assert(AngryAssign_Meta == metaBeforeLocalOwnerRelay, "correlated relay still preserves local-owned metadata")

local changedLocalOwnerWire = DeepCopy(localOwnerWire)
changedLocalOwnerWire.Contents = "Changed by relay"
changedLocalOwnerWire.RevisionId = assert(schema.BuildEntityRevisionId(changedLocalOwnerWire, TestHash))
local changedLocalOwnerPayload = assert(activePage.BuildPageUpsertPayload(changedLocalOwnerWire, {
    {
        SyncId = localCategorySyncId,
        Vars = "",
    },
}, TestHash))
local contextsBeforeChangedLocalOwnerRelay = AngryEra._activePageContexts
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), changedLocalOwnerPayload)
AssertError(accepted, result, "local-namespace-collision", "changed local-owner relay")
Assert(AngryEra._activePageContexts == contextsBeforeChangedLocalOwnerRelay, "changed relay does not mutate context")
AssertEqual(localOwnerPage.Contents, "Private", "changed relay does not mutate local-owned content")

accepted, result = AngryEra:AcceptActivePageUpsert(
    Auth({
        Sender = "Assistant",
        SenderInstallationId = otherInstallationId,
        SenderSessionId = "assistant_owner_relay",
    }),
    localOwnerPayload
)
AssertError(accepted, result, "local-namespace-collision", "assistant local-owner relay")
Assert(
    AngryEra._activePageContexts == contextsBeforeChangedLocalOwnerRelay,
    "ordinary assistant cannot add a local-owner relay context"
)

local localOwnerPageAuthorizationChecks = 0
authorization.pageUpsert = true
authorizationHook = function(_, _, action)
    if action == "pageUpsert" then
        localOwnerPageAuthorizationChecks = localOwnerPageAuthorizationChecks + 1
        if localOwnerPageAuthorizationChecks == 2 then
            authorization.pageUpsert = false
        end
    end
end
accepted, result = AngryEra:AcceptActivePageUpsert(Auth(), localOwnerPayload)
AssertError(accepted, result, "page-upsert-authorization-changed", "revoked local-owner relay")
AssertEqual(localOwnerPageAuthorizationChecks, 2, "local-owner relay rechecks page authority before context commit")
Assert(
    AngryEra._activePageContexts == contextsBeforeChangedLocalOwnerRelay,
    "revoked local-owner relay cannot commit a volatile context"
)
authorizationHook = nil
authorization.pageUpsert = true

print(string.format("Active-page runtime tests passed (%d assertions).", assertions))
