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
    Assert(ok == false, message .. " should fail")
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
        if not player:find("-", 1, true) then
            return player .. "-Realm"
        end
        return player
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
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/revisions.lua"))("AngryEra", app)
assert(loadfile("modules/sync/scopes.lua"))("AngryEra", app)
assert(loadfile("modules/sync/snapshot.lua"))("AngryEra", app)
assert(loadfile("modules/sync/apply.lua"))("AngryEra", app)
assert(loadfile("modules/entities.lua"))("AngryEra", app)
assert(loadfile("modules/sync/runtime.lua"))("AngryEra", app)

local schema = AngryEra.sync.schema
local localInstallationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:a:b:c:d"
local secondInstallationId = "ae3i:e:f:10:11"
local senderSessionId = "leader_session"
local hashCallback = assert(AngryEra:GetSyncHashCallback())

local function SyncId(kind, sequence, installationId)
    return string.format("%s:%s:%d", installationId or remoteInstallationId, kind, sequence)
end

local function MessageId(sequence, installationId, sessionId)
    return string.format("%s:%s:%d", installationId or remoteInstallationId, sessionId or senderSessionId, sequence)
end

local function MakeEntity(kind, sequence, parentSyncId, order, overrides)
    local ownerId = overrides and overrides.OwnerId or remoteInstallationId
    local entity = {
        Kind = kind,
        SyncId = SyncId(kind, sequence, ownerId),
        OwnerId = ownerId,
        Revision = 1,
        UpdatedAt = 1000,
        UpdatedBy = "Leader-Realm",
        ParentSyncId = parentSyncId,
        Order = order,
        Name = kind == "page" and "Assignments" or "Raid",
        Vars = "",
    }
    if kind == "page" then
        entity.Contents = "Tank: Player"
    end
    for key, value in pairs(overrides or {}) do
        entity[key] = value
    end
    entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, hashCallback))
    return entity
end

local function SortEntities(entities)
    table.sort(entities, function(left, right)
        return left.SyncId < right.SyncId
    end)
    return entities
end

local function MakeInitialManifest()
    local root = MakeEntity("category", 1, nil, 1, {
        Name = "Molten Core",
    })
    local child = MakeEntity("category", 2, root.SyncId, 1, {
        Name = "Bosses",
    })
    local page = MakeEntity("page", 3, child.SyncId, 1, {
        Name = "Lucifron",
    })
    local secondPage = MakeEntity("page", 4, child.SyncId, 2, {
        Name = "Magmadar",
        Contents = "Healer: Player",
    })
    return {
        Schema = schema.VERSION,
        ScopeId = root.SyncId,
        RootSyncId = root.SyncId,
        ManifestId = MessageId(2),
        AuthorityEpoch = MessageId(1),
        ScopeRevision = 1,
        Entities = SortEntities({ root, child, page, secondPage }),
        Tombstones = {},
    }
end

local function UpdatedManifest(previous, revision, contents)
    local manifest = DeepCopy(previous)
    manifest.ScopeRevision = revision
    manifest.ManifestId = MessageId(revision + 1)
    for _, entity in ipairs(manifest.Entities) do
        if entity.Kind == "page" then
            entity.Revision = revision
            entity.UpdatedAt = 1000 + revision
            entity.Contents = contents
            entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, hashCallback))
        end
    end
    return manifest
end

local function AncestorUpdatedManifest(previous, revision)
    local manifest = DeepCopy(previous)
    manifest.ScopeRevision = revision
    manifest.ManifestId = MessageId(revision + 1)
    for _, entity in ipairs(manifest.Entities) do
        if entity.SyncId == manifest.RootSyncId then
            entity.Revision = entity.Revision + 1
            entity.UpdatedAt = 1000 + revision
            entity.Vars = "MARK=Skull"
            entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, hashCallback))
        end
    end
    return manifest
end

local function ManifestHash(manifest)
    return assert(schema.BuildManifestHash(manifest, hashCallback))
end

local function PendingScope(scopeId)
    return {
        Schema = 1,
        ScopeId = scopeId,
        Enabled = true,
        AutoCleanup = false,
        ScopeRevision = 0,
        EntityIds = {},
        Tombstones = {},
        CleanupCandidates = {},
    }
end

local function LocalRecord(kind, id, sequence, fields)
    local record = {
        Id = id,
        SyncId = SyncId(kind, sequence, localInstallationId),
        OwnerId = localInstallationId,
        Name = fields.Name,
        Vars = "",
        CategoryId = fields.CategoryId,
        Index = fields.Index,
    }
    if kind == "page" then
        record.Contents = fields.Contents or ""
    end
    return record
end

local initialManifest = MakeInitialManifest()
local badScopeId = SyncId("category", 99, secondInstallationId)

local function ResetStorage()
    local localCategory = LocalRecord("category", 1, 90, {
        Name = "Personal",
        Index = 7,
    })
    local localPage = LocalRecord("page", 1, 91, {
        Name = "Notes",
        Contents = "Private",
        CategoryId = 4,
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
            selected = "-2",
        },
    }
    AngryAssign_Meta = {
        SchemaVersion = 2,
        InstallationId = localInstallationId,
        NextEntitySequence = 100,
        EntityLocal = {
            [localCategory.SyncId] = {
                OwnedLocally = true,
                Pinned = false,
                ManagedScopes = {},
            },
            [localPage.SyncId] = {
                OwnedLocally = true,
                Pinned = true,
                ManagedScopes = {},
            },
        },
        SyncScopes = {
            [initialManifest.ScopeId] = PendingScope(initialManifest.ScopeId),
            [badScopeId] = {
                Schema = 1,
                ScopeId = badScopeId,
                Enabled = true,
                AutoCleanup = "yes",
                ScopeRevision = 0,
                EntityIds = {},
                Tombstones = {},
                CleanupCandidates = {},
            },
        },
        Migrations = {
            InstallationIdentity = 1,
            EntityIdentity = 2,
        },
        UnrelatedMetadata = {
            Retained = true,
        },
    }
    AngryEra.entitySyncIndexes = nil
    AngryEra.syncDraftConflict = {
        Old = true,
    }
end

local uiCalls
local draftText
local editorDirty
local treeRefreshError
local authorizationResults
local authorizationCalls
local authorizationHook

local function ResetRuntimeStubs()
    uiCalls = {
        Tree = 0,
        Selected = 0,
        DestructiveSelected = 0,
        Display = 0,
        Notification = 0,
        Conflict = 0,
    }
    draftText = "unsaved draft"
    editorDirty = false
    treeRefreshError = false
    authorizationResults = {
        true,
        true,
    }
    authorizationCalls = 0
    authorizationHook = nil

    AngryEra.window = {
        text = {
            GetText = function()
                error("runtime must not read the draft")
            end,
            SetText = function()
                error("runtime must not write the draft")
            end,
            button = {
                IsEnabled = function()
                    return editorDirty
                end,
            },
        },
    }
end

function AngryEra:CanReceiveFrom(sender, action)
    authorizationCalls = authorizationCalls + 1
    AssertEqual(sender, "Leader-Realm", "authorization uses normalized authenticated sender")
    AssertEqual(action, "manifest", "authorization uses leader-only manifest action")
    if authorizationHook then
        authorizationHook(authorizationCalls)
    end
    return authorizationResults[authorizationCalls] == true
end

function AngryEra:UpdateTree()
    uiCalls.Tree = uiCalls.Tree + 1
    self:UpdateSelected(true)
    if treeRefreshError then
        error("simulated tree refresh failure")
    end
end

function AngryEra:UpdateSelected(destructive)
    uiCalls.Selected = uiCalls.Selected + 1
    if destructive then
        uiCalls.DestructiveSelected = uiCalls.DestructiveSelected + 1
        draftText = "draft was overwritten"
    end
end

function AngryEra:UpdateDisplayed()
    uiCalls.Display = uiCalls.Display + 1
end

function AngryEra:DisplayUpdateNotification()
    uiCalls.Notification = uiCalls.Notification + 1
end

function AngryEra:SelectedUpdated(sender)
    uiCalls.Conflict = uiCalls.Conflict + 1
    AssertEqual(sender, "Leader-Realm", "conflict notification sender")
end

local function Auth(overrides)
    local auth = {
        Sender = "Leader",
        SenderInstallationId = remoteInstallationId,
        SenderSessionId = senderSessionId,
        ReceivedAt = currentTime,
    }
    for key, value in pairs(overrides or {}) do
        auth[key] = value
    end
    return auth
end

local function AssertNoUi(message)
    AssertEqual(uiCalls.Tree, 0, message .. " tree")
    AssertEqual(uiCalls.Selected, 0, message .. " selected")
    AssertEqual(uiCalls.Display, 0, message .. " display")
    AssertEqual(uiCalls.Notification, 0, message .. " notification")
    AssertEqual(uiCalls.Conflict, 0, message .. " conflict")
end

ResetStorage()
ResetRuntimeStubs()

local accepted, initializeResult =
    AngryEra:AcceptHierarchyManifest(Auth(), initialManifest, ManifestHash(initialManifest))
AssertError(accepted, initializeResult, "sync-runtime-not-initialized", "receive before startup normalization")

local initialized, normalizationErrors = AngryEra:InitializeSyncRuntimeStorage()
Assert(initialized, "runtime storage should initialize")
AssertEqual(#normalizationErrors, 1, "malformed scope should produce one startup normalization error")
AssertEqual(
    AngryAssign_Meta.SyncScopes[badScopeId].Enabled,
    false,
    "malformed scope should be retained disabled and empty"
)
Assert(AngryEra.syncDraftConflict == nil, "volatile draft conflict should clear during startup")
Assert(AngryEra._syncRuntimeReady, "successful startup should enable runtime")

local capturedState, pointerCapture = AngryEra:CaptureSyncCurrentState()
Assert(capturedState.Pages == AngryAssign_Pages, "current state capture should retain read-only page reference")
Assert(pointerCapture.Meta == AngryAssign_Meta, "pointer capture should retain metadata guard")
AssertEqual(pointerCapture.DisplayedId, 2, "stale displayed page id should be captured")
AssertEqual(pointerCapture.SelectedId, -2, "stale selected category id should be captured")
Assert(pointerCapture.Editor == nil, "stale category selection is not an editor page")
local positiveSelectionCapture = {}
for key, value in pairs(pointerCapture) do
    positiveSelectionCapture[key] = value
end
positiveSelectionCapture.SelectedId = 3
local positiveSelectionAllocations =
    assert(AngryEra.sync.runtime.BuildLocalIdAllocations(capturedState, positiveSelectionCapture, initialManifest))
AssertEqual(positiveSelectionAllocations[SyncId("page", 3)], 4, "stale selected page id is independently reserved")
AssertEqual(positiveSelectionAllocations[SyncId("page", 4)], 5, "multiple runtime allocations remain collision-free")

AngryAssign_State.tree.selected = "1"
local originalIsEnabled = AngryEra.window.text.button.IsEnabled
AngryEra.window.text.button.IsEnabled = function()
    error("unreadable editor state")
end
local unreadableState, unreadableError = AngryEra:CaptureSyncCurrentState()
Assert(unreadableState == nil, "unreadable editor state should fail closed")
AssertEqual(unreadableError, "editor-state-unavailable", "unreadable editor error")
AngryEra.window.text.button.IsEnabled = originalIsEnabled
AngryAssign_State.tree.selected = "-2"

accepted, initializeResult = AngryEra:AcceptHierarchyManifest(
    Auth({
        Sender = {},
    }),
    initialManifest,
    ManifestHash(initialManifest)
)
AssertError(accepted, initializeResult, "invalid-manifest-sender", "non-string sender")
AssertEqual(authorizationCalls, 0, "invalid sender should fail before authorization")

authorizationResults = {
    false,
}
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), initialManifest, ManifestHash(initialManifest))
AssertError(accepted, initializeResult, "unauthorized-manifest", "initial authorization")
AssertEqual(authorizationCalls, 1, "unauthorized manifest should perform one permission check")
AssertNoUi("unauthorized manifest")

ResetRuntimeStubs()
local pagesBeforeBinding = AngryAssign_Pages
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(
    Auth({
        SenderInstallationId = secondInstallationId,
    }),
    initialManifest,
    ManifestHash(initialManifest)
)
AssertError(accepted, initializeResult, "manifest-authority-installation-mismatch", "claimed installation binding")
Assert(AngryAssign_Pages == pagesBeforeBinding, "installation mismatch must not swap pages")
AssertEqual(authorizationCalls, 1, "binding rejection happens after initial authorization only")
AssertNoUi("installation mismatch")

ResetRuntimeStubs()
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(
    Auth({
        SenderSessionId = "other_session",
    }),
    initialManifest,
    ManifestHash(initialManifest)
)
AssertError(accepted, initializeResult, "manifest-authority-session-mismatch", "claimed session binding")
AssertEqual(authorizationCalls, 1, "session rejection happens after initial authorization only")
AssertNoUi("session mismatch")

ResetRuntimeStubs()
local oldPages = AngryAssign_Pages
local oldCategories = AngryAssign_Categories
local oldMeta = AngryAssign_Meta
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), initialManifest, ManifestHash(initialManifest))
Assert(accepted, initializeResult)
local initialSummary = initializeResult
AssertEqual(authorizationCalls, 2, "successful manifest should authorize twice")
Assert(AngryAssign_Pages ~= oldPages, "successful commit swaps page table")
Assert(AngryAssign_Categories ~= oldCategories, "successful commit swaps category table")
Assert(AngryAssign_Meta ~= oldMeta, "successful commit swaps metadata table")
AssertEqual(initialSummary.ResolvedLocalIds[SyncId("category", 1)], 3, "stale selected category id is reserved")
AssertEqual(initialSummary.ResolvedLocalIds[SyncId("category", 2)], 5, "dangling CategoryId reference is reserved")
AssertEqual(initialSummary.ResolvedLocalIds[SyncId("page", 3)], 3, "stale displayed page id is reserved")
AssertEqual(initialSummary.ResolvedLocalIds[SyncId("page", 4)], 4, "multiple new pages receive distinct ids")
Assert(AngryAssign_Categories[4] == nil, "incoming category cannot claim a dangling CategoryId reference")
AssertEqual(AngryAssign_Categories[5].CategoryId, 3, "child category uses allocated root id")
AssertEqual(AngryAssign_Pages[3].CategoryId, 5, "page uses allocated child category id")
Assert(AngryAssign_Meta.UnrelatedMetadata.Retained, "copy-on-write metadata keeps unrelated fields")
Assert(oldMeta.SyncScopes[initialManifest.ScopeId].ScopeRevision == 0, "old metadata remains unchanged")
Assert(
    AngryEra:GetPageBySyncId(SyncId("page", 3)) == AngryAssign_Pages[3],
    "prebuilt page identity index installs with the commit"
)
Assert(
    AngryEra:GetCategoryBySyncId(SyncId("category", 1)) == AngryAssign_Categories[3],
    "prebuilt category identity index installs with the commit"
)
AssertEqual(uiCalls.Tree, 1, "successful apply refreshes tree once")
AssertEqual(uiCalls.Selected, 1, "tree callback is suppressed and selected refresh runs once")
AssertEqual(uiCalls.DestructiveSelected, 0, "hierarchy refresh never destructively reloads selection")
AssertEqual(uiCalls.Display, 1, "successful apply refreshes display once")
AssertEqual(uiCalls.Notification, 0, "stale displayed id does not trigger notification")
AssertEqual(uiCalls.Conflict, 0, "clean apply does not report conflict")
Assert(initialSummary.UIRefreshed, "successful UI refresh is reported")

capturedState, pointerCapture = AngryEra:CaptureSyncCurrentState()
local preparedIndexes =
    assert(AngryEra.sync.runtime.BuildIdentityIndexes(capturedState.Pages, capturedState.Categories))
local mismatchedMeta = DeepCopy(AngryAssign_Meta)
local committed, commitError =
    AngryEra:CommitHierarchySyncState(pointerCapture, capturedState, mismatchedMeta, preparedIndexes)
AssertError(committed, commitError, "invalid-prepared-runtime-state", "mismatched prepared metadata")
local matchingMeta = {}
for key, value in pairs(AngryAssign_Meta) do
    matchingMeta[key] = value
end
local badIndexes = DeepCopy(preparedIndexes)
badIndexes.page[SyncId("page", 3)] = {}
committed, commitError = AngryEra:CommitHierarchySyncState(pointerCapture, capturedState, matchingMeta, badIndexes)
AssertError(committed, commitError, "invalid-prepared-runtime-state", "identity index record mismatch")

ResetRuntimeStubs()
oldPages = AngryAssign_Pages
oldCategories = AngryAssign_Categories
oldMeta = AngryAssign_Meta
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), initialManifest, ManifestHash(initialManifest))
Assert(accepted, initializeResult)
Assert(initializeResult.NoOp and not initializeResult.Applied, "exact manifest should report no-op")
AssertEqual(authorizationCalls, 2, "no-op still reauthorizes before acknowledgement")
Assert(AngryAssign_Pages == oldPages, "no-op does not swap pages")
Assert(AngryAssign_Categories == oldCategories, "no-op does not swap categories")
Assert(AngryAssign_Meta == oldMeta, "no-op does not swap metadata")
AssertNoUi("no-op")

local ancestorManifest = AncestorUpdatedManifest(initialManifest, 2)
ResetRuntimeStubs()
AngryAssign_State.tree.selected = "-2"
AngryAssign_State.displayed = 3
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), ancestorManifest, ManifestHash(ancestorManifest))
Assert(accepted, initializeResult)
Assert(
    initializeResult.ChangedSyncIds[initialManifest.RootSyncId],
    "ancestor-only manifest should identify changed root"
)
Assert(
    not initializeResult.ChangedSyncIds[SyncId("page", 3)],
    "ancestor-only manifest should leave displayed page record unchanged"
)
Assert(initializeResult.DisplayedChanged, "changed ancestor should invalidate displayed page")
AssertEqual(uiCalls.Notification, 1, "changed ancestor should notify displayed page once")
AssertEqual(uiCalls.Display, 1, "changed ancestor should refresh display once")

local secondManifest = UpdatedManifest(ancestorManifest, 3, "Tank: Updated")

ResetRuntimeStubs()
authorizationResults = {
    true,
    false,
}
oldPages = AngryAssign_Pages
oldCategories = AngryAssign_Categories
oldMeta = AngryAssign_Meta
local oldIndexes = AngryEra.entitySyncIndexes
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), secondManifest, ManifestHash(secondManifest))
AssertError(accepted, initializeResult, "manifest-authorization-changed", "authorization changed before commit")
AssertEqual(authorizationCalls, 2, "authorization change is detected by second check")
Assert(AngryAssign_Pages == oldPages, "reauthorization failure preserves pages")
Assert(AngryAssign_Categories == oldCategories, "reauthorization failure preserves categories")
Assert(AngryAssign_Meta == oldMeta, "reauthorization failure preserves metadata")
Assert(AngryEra.entitySyncIndexes == oldIndexes, "reauthorization failure preserves indexes")
AssertNoUi("reauthorization failure")

ResetRuntimeStubs()
oldPages = AngryAssign_Pages
oldCategories = AngryAssign_Categories
oldMeta = AngryAssign_Meta
authorizationHook = function(call)
    if call == 2 then
        AngryAssign_Pages = DeepCopy(AngryAssign_Pages)
    end
end
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), secondManifest, ManifestHash(secondManifest))
AssertError(accepted, initializeResult, "stale-current-state", "pointer changed during reauthorization")
Assert(AngryAssign_Pages ~= oldPages, "test hook should replace the live page pointer")
Assert(AngryAssign_Categories == oldCategories, "runtime does not swap categories after stale pointer")
Assert(AngryAssign_Meta == oldMeta, "runtime does not swap metadata after stale pointer")
AssertNoUi("stale pointer")
AngryAssign_Pages = oldPages

ResetRuntimeStubs()
local tamperedTransition = DeepCopy(secondManifest)
tamperedTransition.AuthorityEpoch = MessageId(20, remoteInstallationId, "tampered_session")
tamperedTransition.ManifestId = MessageId(21, remoteInstallationId, "tampered_session")
accepted, initializeResult =
    AngryEra:AcceptHierarchyManifest(Auth(), tamperedTransition, ManifestHash(tamperedTransition))
AssertError(accepted, initializeResult, "manifest-authority-session-mismatch", "tampered authority transition")
AssertEqual(authorizationCalls, 1, "tampered transition never reaches commit reauthorization")
AssertNoUi("tampered transition")

ResetRuntimeStubs()
AngryAssign_State.tree.selected = "3"
AngryAssign_State.displayed = 3
editorDirty = true
draftText = "my unsaved assignment draft"
oldPages = AngryAssign_Pages
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), secondManifest, ManifestHash(secondManifest))
Assert(accepted, initializeResult)
local dirtySummary = initializeResult
Assert(dirtySummary.SelectedDirtyConflict ~= nil, "dirty selected page should report a conflict")
AssertEqual(AngryAssign_Pages[3].Contents, "Tank: Updated", "incoming revision is stored")
AssertEqual(draftText, "my unsaved assignment draft", "tree refresh preserves the editor draft")
Assert(AngryEra.syncDraftConflict ~= nil, "dirty conflict receives an in-memory runtime marker")
AssertEqual(
    AngryEra.syncDraftConflict.IncomingRevisionId,
    AngryAssign_Pages[3].RevisionId,
    "runtime conflict marker identifies incoming revision"
)
AssertEqual(uiCalls.Tree, 1, "dirty apply refreshes tree once")
AssertEqual(uiCalls.Selected, 1, "dirty apply refreshes selected page non-destructively once")
AssertEqual(uiCalls.DestructiveSelected, 0, "dirty apply suppresses destructive tree callback")
AssertEqual(uiCalls.Display, 1, "dirty apply refreshes display once")
AssertEqual(uiCalls.Notification, 1, "changed displayed page notifies once")
AssertEqual(uiCalls.Conflict, 1, "dirty apply warns once")
Assert(dirtySummary.UIRefreshed, "dirty apply reports successful refresh")
Assert(AngryAssign_Pages ~= oldPages, "dirty conflict does not block stored revision")
Assert(AngryEra:HasSyncDraftConflict(), "runtime should expose unresolved draft conflict")
Assert(AngryEra:HasSyncDraftConflict(SyncId("page", 3)), "runtime conflict query should match selected page identity")
Assert(not AngryEra:ClearSyncDraftConflict(SyncId("page", 999)), "wrong identity must not clear runtime conflict")

ResetRuntimeStubs()
oldPages = AngryAssign_Pages
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), secondManifest, ManifestHash(secondManifest))
Assert(accepted and initializeResult.NoOp, initializeResult)
Assert(AngryAssign_Pages == oldPages, "dirty-conflict no-op does not swap")
Assert(AngryEra.syncDraftConflict ~= nil, "no-op does not discard unresolved runtime conflict")
AssertNoUi("dirty-conflict no-op")
Assert(AngryEra:ClearSyncDraftConflict(SyncId("page", 3)), "resolved page should clear volatile conflict marker")
Assert(not AngryEra:HasSyncDraftConflict(), "cleared runtime conflict should no longer be reported")

local thirdManifest = UpdatedManifest(secondManifest, 4, "Tank: Third")
ResetRuntimeStubs()
AngryAssign_State.tree.selected = "3"
AngryAssign_State.displayed = 3
treeRefreshError = true
oldPages = AngryAssign_Pages
accepted, initializeResult, normalizationErrors =
    AngryEra:AcceptHierarchyManifest(Auth(), thirdManifest, ManifestHash(thirdManifest))
Assert(accepted, initializeResult)
AssertEqual(normalizationErrors, "ui-refresh-failed", "UI failure returns a post-commit warning")
Assert(AngryAssign_Pages ~= oldPages, "UI failure does not roll back committed pages")
AssertEqual(AngryAssign_Pages[3].Contents, "Tank: Third", "UI failure retains incoming revision")
Assert(not initializeResult.UIRefreshed, "summary records failed UI refresh")
AssertEqual(uiCalls.Tree, 1, "failing tree refresh is attempted once")
AssertEqual(uiCalls.Selected, 1, "later selected refresh still runs once")
AssertEqual(uiCalls.DestructiveSelected, 0, "failing tree callback remains non-destructive")
AssertEqual(uiCalls.Display, 1, "later display refresh still runs once")
AssertEqual(uiCalls.Notification, 1, "display notification still runs once")

local fourthManifest = UpdatedManifest(thirdManifest, 5, "Tank: Fourth")
ResetRuntimeStubs()
oldPages = AngryAssign_Pages
oldCategories = AngryAssign_Categories
oldMeta = AngryAssign_Meta
oldIndexes = AngryEra.entitySyncIndexes
local defaultIndexInstaller = AngryEra.InstallSyncIdentityIndexes
function AngryEra:InstallSyncIdentityIndexes()
    error("simulated index install failure")
end
accepted, initializeResult = AngryEra:AcceptHierarchyManifest(Auth(), fourthManifest, ManifestHash(fourthManifest))
AssertError(accepted, initializeResult, "commit-failed", "index installation rollback")
Assert(AngryAssign_Pages == oldPages, "commit failure restores page pointer")
Assert(AngryAssign_Categories == oldCategories, "commit failure restores category pointer")
Assert(AngryAssign_Meta == oldMeta, "commit failure restores metadata pointer")
Assert(AngryEra.entitySyncIndexes == oldIndexes, "commit failure restores identity index pointer")
AssertEqual(AngryAssign_Pages[3].Contents, "Tank: Third", "commit rollback restores stored contents")
AssertNoUi("commit rollback")
AngryEra.InstallSyncIdentityIndexes = defaultIndexInstaller

AssertEqual(TestHash("runtime"), hashCallback("runtime"), "runtime uses the production-compatible FCS32 callback")

print(string.format("Synchronization runtime tests passed (%d assertions).", assertions))
