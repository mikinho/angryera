-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/runtime.lua
--
-- Authorized runtime boundary for staging and atomically installing complete
-- selected-category hierarchy manifests.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity
local schema = AngryEra.sync and AngryEra.sync.schema
local revisions = AngryEra.sync and AngryEra.sync.revisions
local snapshot = AngryEra.sync and AngryEra.sync.snapshot
local apply = AngryEra.sync and AngryEra.sync.apply
local helpers = AngryEra.utils and AngryEra.utils.helpers

if not identity or type(identity.ValidateInstallationId) ~= "function" then
    error("AngryEra identity must load before synchronization runtime")
end
if not schema or type(schema.ValidateManifest) ~= "function" then
    error("AngryEra synchronization schema must load before runtime")
end
if not revisions or type(revisions.CreateFCS32Callback) ~= "function" then
    error("AngryEra synchronization revisions must load before runtime")
end
if not snapshot or type(snapshot.Stage) ~= "function" then
    error("AngryEra synchronization snapshots must load before runtime")
end
if not apply or type(apply.BuildNextState) ~= "function" then
    error("AngryEra synchronization apply must load before runtime")
end
if not helpers or type(helpers.EnsureUnitFullName) ~= "function" then
    error("AngryEra helpers must load before synchronization runtime")
end

AngryEra.sync.runtime = {}
local runtime = AngryEra.sync.runtime

local MAX_LOCAL_ID = schema.LIMITS.LocalId
local AUTH_KEYS = {
    Sender = true,
    SenderInstallationId = true,
    SenderSessionId = true,
    ReceivedAt = true,
}

local syncHashCallback

local function IsPlainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function IsInteger(value, minimum, maximum)
    return type(value) == "number"
        and value == value
        and value >= minimum
        and value <= maximum
        and value == math.floor(value)
end

local function IsPositiveLocalId(value)
    return IsInteger(value, 1, MAX_LOCAL_ID)
end

local function Clone(value, seen)
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
        copy[Clone(key, seen)] = Clone(item, seen)
    end
    return copy
end

local function ShallowCopy(source)
    if not IsPlainTable(source) then
        return nil
    end
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

local function ParseSelectedId(state)
    if not IsPlainTable(state) or not IsPlainTable(state.tree) then
        return nil
    end

    local selected = state.tree.selected
    if type(selected) == "number" then
        if IsInteger(selected, -MAX_LOCAL_ID, MAX_LOCAL_ID) and selected ~= 0 then
            return selected
        end
        return nil
    end
    if type(selected) ~= "string" or selected == "" then
        return nil
    end

    local last = selected:match("([^\001]+)$")
    local selectedId = tonumber(last)
    if IsInteger(selectedId, -MAX_LOCAL_ID, MAX_LOCAL_ID) and selectedId ~= 0 then
        return selectedId
    end
    return nil
end

local function EditorIsDirty(self)
    local window = self.window
    if window == nil then
        return false
    end
    if type(window) ~= "table" or type(window.text) ~= "table" then
        return nil, "editor-state-unavailable"
    end

    local button = window.text.button
    if type(button) ~= "table" or type(button.IsEnabled) ~= "function" then
        return nil, "editor-state-unavailable"
    end

    local ok, enabled = pcall(button.IsEnabled, button)
    if not ok or type(enabled) ~= "boolean" then
        return nil, "editor-state-unavailable"
    end
    return enabled
end

local function CaptureEditor(self, pages, selectedId)
    if not IsPositiveLocalId(selectedId) then
        return nil
    end

    local page = pages[selectedId]
    if not IsPlainTable(page) or not identity.ValidateSyncId(page.SyncId, "page") then
        return nil
    end
    local dirty, dirtyError = EditorIsDirty(self)
    if dirty == nil then
        return nil, dirtyError
    end
    return {
        SelectedPageId = selectedId,
        SelectedPageSyncId = page.SyncId,
        Dirty = dirty,
    }
end

local function ValidateAuth(auth)
    if not IsPlainTable(auth) then
        return nil, "invalid-manifest-auth"
    end
    for key in pairs(auth) do
        if type(key) ~= "string" or not AUTH_KEYS[key] then
            return nil, "manifest-auth-unknown-field"
        end
    end
    for key in pairs(AUTH_KEYS) do
        if rawget(auth, key) == nil then
            return nil, "manifest-auth-missing-" .. key
        end
    end

    if type(auth.Sender) ~= "string" or auth.Sender == "" then
        return nil, "invalid-manifest-sender"
    end
    local sender = helpers.EnsureUnitFullName(auth.Sender)
    if type(sender) ~= "string" or sender == "" then
        return nil, "invalid-manifest-sender"
    end
    if not identity.ValidateInstallationId(auth.SenderInstallationId) then
        return nil, "invalid-manifest-installation"
    end
    if
        type(auth.SenderSessionId) ~= "string"
        or auth.SenderSessionId == ""
        or #auth.SenderSessionId > schema.LIMITS.SessionIdBytes
        or auth.SenderSessionId:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") == nil
    then
        return nil, "invalid-manifest-session"
    end
    if not IsInteger(auth.ReceivedAt, 0, schema.LIMITS.Timestamp) then
        return nil, "invalid-manifest-received-at"
    end

    return {
        Sender = sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        ReceivedAt = auth.ReceivedAt,
    }
end

local function IsManifestAuthorized(self, sender)
    if type(self.CanReceiveFrom) ~= "function" then
        return false
    end
    local ok, authorized = pcall(self.CanReceiveFrom, self, sender, "manifest")
    return ok and authorized == true
end

local function IndexRecords(pages, categories)
    if not IsPlainTable(pages) or not IsPlainTable(categories) then
        return nil, nil, "invalid-runtime-records"
    end

    local indexes = {
        page = {},
        category = {},
    }
    local bySyncId = {}
    local usedIds = {
        page = {},
        category = {},
    }

    for _, source in ipairs({
        { Kind = "category", Records = categories },
        { Kind = "page", Records = pages },
    }) do
        for localId, record in pairs(source.Records) do
            if
                not IsPositiveLocalId(localId)
                or not IsPlainTable(record)
                or record.Id ~= localId
                or not identity.ValidateSyncId(record.SyncId, source.Kind)
                or not identity.ValidateInstallationId(record.OwnerId)
                or identity.ParseSyncId(record.SyncId) ~= record.OwnerId
            then
                return nil, nil, "invalid-runtime-" .. source.Kind
            end
            if bySyncId[record.SyncId] then
                return nil, nil, "duplicate-runtime-sync-id"
            end

            indexes[source.Kind][record.SyncId] = record
            bySyncId[record.SyncId] = {
                Kind = source.Kind,
                Id = localId,
                Record = record,
            }
            usedIds[source.Kind][localId] = true
        end
    end
    return indexes, {
        BySyncId = bySyncId,
        UsedIds = usedIds,
    }
end

local function ReserveRuntimeIds(capture, usedIds)
    if IsPositiveLocalId(capture.DisplayedId) then
        usedIds.page[capture.DisplayedId] = true
    end

    local selectedId = capture.SelectedId
    if IsPositiveLocalId(selectedId) then
        usedIds.page[selectedId] = true
    elseif type(selectedId) == "number" and IsPositiveLocalId(-selectedId) then
        usedIds.category[-selectedId] = true
    end
end

local function ReserveDanglingCategoryReferences(currentState, usedIds)
    for _, records in ipairs({ currentState.Categories, currentState.Pages }) do
        for _, record in pairs(records) do
            local categoryId = IsPlainTable(record) and rawget(record, "CategoryId")
            if IsPositiveLocalId(categoryId) then
                usedIds.category[categoryId] = true
            end
        end
    end
end

local function NextFreeId(used, cursor)
    cursor = cursor or 1
    while cursor <= MAX_LOCAL_ID and used[cursor] do
        cursor = cursor + 1
    end
    if cursor > MAX_LOCAL_ID then
        return nil
    end
    return cursor, cursor + 1
end

local function BuildLocalIdAllocations(currentState, capture, manifest)
    local _, current, indexError = IndexRecords(currentState.Pages, currentState.Categories)
    if not current then
        return nil, indexError
    end

    ReserveRuntimeIds(capture, current.UsedIds)
    ReserveDanglingCategoryReferences(currentState, current.UsedIds)
    local cursors = {
        page = 1,
        category = 1,
    }
    local allocations = {}
    for _, entity in ipairs(manifest.Entities) do
        if not current.BySyncId[entity.SyncId] then
            local localId
            localId, cursors[entity.Kind] = NextFreeId(current.UsedIds[entity.Kind], cursors[entity.Kind])
            if not localId then
                return nil, "local-id-space-exhausted"
            end
            current.UsedIds[entity.Kind][localId] = true
            allocations[entity.SyncId] = localId
        end
    end
    return allocations
end

local function AuthorityTransitionAllowed(currentState, manifest)
    local currentScope = IsPlainTable(currentState.SyncScopes) and currentState.SyncScopes[manifest.ScopeId]
    return IsPlainTable(currentScope)
        and type(currentScope.ScopeRevision) == "number"
        and currentScope.ScopeRevision > 0
        and currentScope.AuthorityEpoch ~= manifest.AuthorityEpoch
end

local function BuildNextMeta(capture, nextState)
    if
        not IsPlainTable(capture.Meta)
        or not IsPlainTable(nextState)
        or nextState.InstallationId ~= capture.Meta.InstallationId
        or not IsPlainTable(nextState.EntityLocal)
        or not IsPlainTable(nextState.SyncScopes)
    then
        return nil, "invalid-next-runtime-state"
    end

    local nextMeta = ShallowCopy(capture.Meta)
    if not nextMeta then
        return nil, "invalid-current-meta"
    end
    nextMeta.EntityLocal = nextState.EntityLocal
    nextMeta.SyncScopes = nextState.SyncScopes
    return nextMeta
end

local function PointersMatch(self, capture)
    if
        not (
            IsPlainTable(capture)
            and AngryAssign_Pages == capture.Pages
            and AngryAssign_Categories == capture.Categories
            and AngryAssign_Meta == capture.Meta
            and AngryAssign_State == capture.State
            and capture.Meta.EntityLocal == capture.EntityLocal
            and capture.Meta.SyncScopes == capture.SyncScopes
            and ParseSelectedId(AngryAssign_State) == capture.SelectedId
        )
    then
        return false
    end

    local displayedId = IsPlainTable(AngryAssign_State) and AngryAssign_State.displayed or nil
    if not IsPositiveLocalId(displayedId) then
        displayedId = nil
    end
    if displayedId ~= capture.DisplayedId then
        return false
    end

    if capture.Editor then
        local dirty = EditorIsDirty(self)
        if dirty == nil or dirty ~= capture.Editor.Dirty then
            return false
        end
    end
    return true
end

local function IdentityIndexesMatch(nextState, nextIndexes)
    local expected = IndexRecords(nextState.Pages, nextState.Categories)
    if not expected then
        return false
    end

    for _, kind in ipairs({ "category", "page" }) do
        for syncId, record in pairs(expected[kind]) do
            if nextIndexes[kind][syncId] ~= record then
                return false
            end
        end
        for syncId, record in pairs(nextIndexes[kind]) do
            if expected[kind][syncId] ~= record then
                return false
            end
        end
    end
    return true
end

local function ValidatePreparedRuntimeState(nextState, nextMeta, nextIndexes)
    return IsPlainTable(nextState)
        and IsPlainTable(nextState.Pages)
        and IsPlainTable(nextState.Categories)
        and IsPlainTable(nextMeta)
        and IsPlainTable(nextIndexes)
        and IsPlainTable(nextIndexes.page)
        and IsPlainTable(nextIndexes.category)
        and nextMeta.InstallationId == nextState.InstallationId
        and nextMeta.EntityLocal == nextState.EntityLocal
        and nextMeta.SyncScopes == nextState.SyncScopes
        and IdentityIndexesMatch(nextState, nextIndexes)
end

local function ChangedDisplayedHierarchy(currentState, nextState, capture, changedSyncIds)
    local displayedSyncId = capture.DisplayedPageSyncId
    if displayedSyncId == nil then
        return false
    end
    if changedSyncIds[displayedSyncId] then
        return true
    end

    local function Walk(pages, categories)
        local page
        for _, candidate in pairs(pages) do
            if IsPlainTable(candidate) and candidate.SyncId == displayedSyncId then
                page = candidate
                break
            end
        end
        if not page then
            return false
        end

        local categoryId = rawget(page, "CategoryId")
        local seen = {}
        local depth = 0
        while IsPositiveLocalId(categoryId) and not seen[categoryId] do
            depth = depth + 1
            if depth > schema.LIMITS.HierarchyDepth then
                return false
            end
            seen[categoryId] = true

            local category = categories[categoryId]
            if not IsPlainTable(category) then
                return false
            end
            if identity.ValidateSyncId(category.SyncId, "category") and changedSyncIds[category.SyncId] then
                return true
            end
            categoryId = rawget(category, "CategoryId")
        end
        return false
    end

    return Walk(currentState.Pages, currentState.Categories) or Walk(nextState.Pages, nextState.Categories)
end

local function CallUiMethod(self, name, ...)
    local callback = self[name]
    if type(callback) ~= "function" then
        return true
    end
    return pcall(callback, self, ...)
end

local function RefreshTreeWithoutSelectionReload(self)
    if type(self.UpdateSelected) ~= "function" then
        return CallUiMethod(self, "UpdateTree")
    end

    local inheritedUpdateSelected = self.UpdateSelected
    local ownUpdateSelected = rawget(self, "UpdateSelected")
    self.UpdateSelected = function(target, destructive)
        if destructive == true then
            return
        end
        return inheritedUpdateSelected(target, destructive)
    end
    local ok = CallUiMethod(self, "UpdateTree")
    self.UpdateSelected = ownUpdateSelected
    return ok
end

local function CommitPreparedState(self, capture, nextState, nextMeta, nextIndexes)
    if not PointersMatch(self, capture) then
        return false, "stale-current-state"
    end

    local previousPages = AngryAssign_Pages
    local previousCategories = AngryAssign_Categories
    local previousMeta = AngryAssign_Meta
    local previousIndexes = self.entitySyncIndexes
    local ok = pcall(function()
        AngryAssign_Pages = nextState.Pages
        AngryAssign_Categories = nextState.Categories
        AngryAssign_Meta = nextMeta
        self:InstallSyncIdentityIndexes(nextIndexes)
    end)
    if not ok then
        AngryAssign_Pages = previousPages
        AngryAssign_Categories = previousCategories
        AngryAssign_Meta = previousMeta
        self.entitySyncIndexes = previousIndexes
        return false, "commit-failed"
    end
    return true
end

--- Returns the cached production FCS32 callback used by all v3 sync records.
-- @treturn function|nil hashCallback
-- @treturn string|nil errorCode
function AngryEra:GetSyncHashCallback()
    if syncHashCallback then
        return syncHashCallback
    end

    local callback, callbackError = revisions.CreateFCS32Callback(app.libs and app.libs.libC)
    if not callback then
        return nil, callbackError
    end
    syncHashCallback = callback
    return callback
end

--- Normalizes persisted scope/provenance state before manifest reception starts.
-- This is intentionally a separate API so initialization can call it after
-- entity identity migration and before registering protocol handlers.
-- @treturn boolean ready
-- @treturn table|string errorsOrErrorCode
function AngryEra:InitializeSyncRuntimeStorage()
    local hashCallback, hashError = self:GetSyncHashCallback()
    if not hashCallback then
        self._syncRuntimeReady = false
        return false, hashError
    end
    if type(self.InitializeIdentityStorage) ~= "function" or type(self.NormalizeSyncScopeStorage) ~= "function" then
        self._syncRuntimeReady = false
        return false, "sync-storage-api-unavailable"
    end

    local ok, normalizedScopes, errors = pcall(function()
        self:InitializeIdentityStorage()
        return self:NormalizeSyncScopeStorage(hashCallback)
    end)
    if not ok or not IsPlainTable(normalizedScopes) or type(errors) ~= "table" then
        self._syncRuntimeReady = false
        return false, "sync-storage-normalization-failed"
    end

    self.syncDraftConflict = nil
    self.syncRuntimeStorageErrors = errors
    self._syncRuntimeReady = true
    return true, errors
end

--- Captures the current state references and runtime-only ID/editor reservations.
-- The state references remain read-only until a completely detached replacement
-- has been built.
-- @treturn table|nil currentState
-- @treturn table|string captureOrError
function AngryEra:CaptureSyncCurrentState()
    if
        not IsPlainTable(AngryAssign_Pages)
        or not IsPlainTable(AngryAssign_Categories)
        or not IsPlainTable(AngryAssign_Meta)
        or not IsPlainTable(AngryAssign_Meta.EntityLocal)
        or not IsPlainTable(AngryAssign_Meta.SyncScopes)
        or not identity.ValidateInstallationId(AngryAssign_Meta.InstallationId)
    then
        return nil, "invalid-runtime-storage"
    end

    local selectedId = ParseSelectedId(AngryAssign_State)
    local displayedId = IsPlainTable(AngryAssign_State) and AngryAssign_State.displayed or nil
    if not IsPositiveLocalId(displayedId) then
        displayedId = nil
    end

    local displayedPage = displayedId and AngryAssign_Pages[displayedId]
    local displayedPageSyncId = IsPlainTable(displayedPage)
            and identity.ValidateSyncId(displayedPage.SyncId, "page")
            and displayedPage.SyncId
        or nil

    local editor, editorError = CaptureEditor(self, AngryAssign_Pages, selectedId)
    if editorError then
        return nil, editorError
    end

    return {
        InstallationId = AngryAssign_Meta.InstallationId,
        Pages = AngryAssign_Pages,
        Categories = AngryAssign_Categories,
        EntityLocal = AngryAssign_Meta.EntityLocal,
        SyncScopes = AngryAssign_Meta.SyncScopes,
    }, {
        Pages = AngryAssign_Pages,
        Categories = AngryAssign_Categories,
        Meta = AngryAssign_Meta,
        EntityLocal = AngryAssign_Meta.EntityLocal,
        SyncScopes = AngryAssign_Meta.SyncScopes,
        State = AngryAssign_State,
        SelectedId = selectedId,
        DisplayedId = displayedId,
        DisplayedPageSyncId = displayedPageSyncId,
        Editor = editor,
    }
end

--- Installs prevalidated detached storage and identity indexes.
-- The overridable index installer keeps the rollback path directly testable.
-- @tparam table capture Pointer guard returned by `CaptureSyncCurrentState`.
-- @tparam table nextState Detached state returned by sync.apply.
-- @tparam table nextMeta Detached full metadata table.
-- @tparam table nextIndexes Prebuilt page/category SyncId indexes.
-- @treturn boolean committed
-- @treturn string|nil errorCode
function AngryEra:CommitHierarchySyncState(capture, nextState, nextMeta, nextIndexes)
    if not ValidatePreparedRuntimeState(nextState, nextMeta, nextIndexes) then
        return false, "invalid-prepared-runtime-state"
    end
    return CommitPreparedState(self, capture, nextState, nextMeta, nextIndexes)
end

--- Installs detached identity indexes as the final atomic commit step.
-- Tests may temporarily replace this method to exercise commit rollback.
function AngryEra:InstallSyncIdentityIndexes(indexes)
    self.entitySyncIndexes = indexes
end

--- Returns whether the volatile editor draft currently conflicts with a stored revision.
-- @tparam[opt] string syncId Optional page SyncId to match.
function AngryEra:HasSyncDraftConflict(syncId)
    local conflict = self.syncDraftConflict
    if not IsPlainTable(conflict) then
        return false
    end
    return syncId == nil or conflict.SyncId == syncId
end

--- Clears the volatile editor conflict after Save, Revert, fork, or selection change.
-- @tparam[opt] string syncId Optional page SyncId guard.
-- @treturn boolean cleared
function AngryEra:ClearSyncDraftConflict(syncId)
    if not self:HasSyncDraftConflict(syncId) then
        return false
    end
    self.syncDraftConflict = nil
    return true
end

--- Performs one bounded post-commit UI refresh.
-- Failures are reported to the caller but never roll back committed SavedVariables.
-- @treturn boolean refreshed
-- @treturn string|nil warningCode
function AngryEra:RefreshAfterHierarchyApply(summary, sender)
    local refreshed = true
    if not RefreshTreeWithoutSelectionReload(self) then
        refreshed = false
    end
    if summary.SelectedDirtyConflict and not CallUiMethod(self, "SelectedUpdated", sender) then
        refreshed = false
    end
    if not CallUiMethod(self, "UpdateSelected", false) then
        refreshed = false
    end
    if not CallUiMethod(self, "UpdateDisplayed") then
        refreshed = false
    end
    if summary.DisplayedChanged and not CallUiMethod(self, "DisplayUpdateNotification") then
        refreshed = false
    end

    if not refreshed then
        return false, "ui-refresh-failed"
    end
    return true
end

local function AcceptHierarchyManifest(self, auth, manifest, expectedHash)
    local safeAuth, authError = ValidateAuth(auth)
    if not safeAuth then
        return false, authError
    end
    if not IsManifestAuthorized(self, safeAuth.Sender) then
        return false, "unauthorized-manifest"
    end

    local currentState, capture = self:CaptureSyncCurrentState()
    if not currentState then
        return false, capture
    end
    local hashCallback, hashError = self:GetSyncHashCallback()
    if not hashCallback then
        return false, hashError
    end

    local staged, stageError = snapshot.Stage(manifest, expectedHash, currentState, {
        Sender = safeAuth.Sender,
        SenderInstallationId = safeAuth.SenderInstallationId,
        SenderSessionId = safeAuth.SenderSessionId,
        ReceivedAt = safeAuth.ReceivedAt,
        AllowAuthorityTransition = AuthorityTransitionAllowed(currentState, manifest),
    }, hashCallback)
    if not staged then
        return false, stageError
    end

    if staged.NoOp then
        if not IsManifestAuthorized(self, safeAuth.Sender) then
            return false, "manifest-authorization-changed"
        end
        if not PointersMatch(self, capture) then
            return false, "stale-current-state"
        end
        return true,
            {
                Schema = schema.VERSION,
                ScopeId = staged.ScopeId,
                ScopeRevision = staged.Manifest.ScopeRevision,
                ManifestId = staged.Manifest.ManifestId,
                AuthorityTransition = staged.AuthorityTransition,
                NoOp = true,
                Applied = false,
                UIRefreshed = false,
                CleanupCandidates = Clone(staged.CleanupCandidates),
            }
    end

    local localIds, allocationError = BuildLocalIdAllocations(currentState, capture, staged.Manifest)
    if not localIds then
        return false, allocationError
    end
    local nextState, summary, applyError = apply.BuildNextState(currentState, staged, {
        LocalIds = localIds,
        Editor = capture.Editor,
    }, hashCallback)
    if not nextState then
        return false, applyError
    end

    local nextMeta, metaError = BuildNextMeta(capture, nextState)
    if not nextMeta then
        return false, metaError
    end
    local nextIndexes, _, indexError = IndexRecords(nextState.Pages, nextState.Categories)
    if not nextIndexes then
        return false, indexError
    end
    if not ValidatePreparedRuntimeState(nextState, nextMeta, nextIndexes) then
        return false, "invalid-prepared-runtime-state"
    end

    summary.DisplayedChanged = ChangedDisplayedHierarchy(currentState, nextState, capture, summary.ChangedSyncIds)

    if not PointersMatch(self, capture) then
        return false, "stale-current-state"
    end
    if not IsManifestAuthorized(self, safeAuth.Sender) then
        return false, "manifest-authorization-changed"
    end

    local committed, commitError = CommitPreparedState(self, capture, nextState, nextMeta, nextIndexes)
    if not committed then
        return false, commitError
    end

    if summary.SelectedDirtyConflict then
        self.syncDraftConflict = Clone(summary.SelectedDirtyConflict)
        self.syncDraftConflict.ScopeId = summary.ScopeId
        self.syncDraftConflict.ManifestId = summary.ManifestId
        self.syncDraftConflict.ReceivedAt = safeAuth.ReceivedAt
    end

    local refreshOk, refreshWarning
    local called, result, warning = pcall(self.RefreshAfterHierarchyApply, self, summary, safeAuth.Sender)
    if called then
        refreshOk = result
        refreshWarning = warning
    else
        refreshOk = false
        refreshWarning = "ui-refresh-failed"
    end
    summary.UIRefreshed = refreshOk == true
    return true, summary, refreshOk and nil or (refreshWarning or "ui-refresh-failed")
end

--- Validates, stages, prepares, reauthorizes, and atomically applies a manifest.
-- Authorization occurs once before staging and again immediately before commit.
-- @tparam table auth Authenticated AceComm sender/envelope context.
-- @tparam table manifest Complete selected-category manifest.
-- @tparam string expectedHash Sender-declared canonical manifest hash.
-- @treturn boolean accepted
-- @treturn table|string summaryOrError
-- @treturn string|nil warningCode A post-commit UI warning on successful storage.
function AngryEra:AcceptHierarchyManifest(auth, manifest, expectedHash)
    if self._syncRuntimeReady ~= true then
        return false, "sync-runtime-not-initialized"
    end
    if self._syncHierarchyCommitInProgress then
        return false, "sync-apply-in-progress"
    end

    self._syncHierarchyCommitInProgress = true
    local called, accepted, result, warning = pcall(AcceptHierarchyManifest, self, auth, manifest, expectedHash)
    self._syncHierarchyCommitInProgress = false
    if not called then
        return false, "sync-runtime-error"
    end
    return accepted, result, warning
end

runtime.BuildLocalIdAllocations = BuildLocalIdAllocations
runtime.BuildIdentityIndexes = function(pages, categories)
    return IndexRecords(pages, categories)
end
