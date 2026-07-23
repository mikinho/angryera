-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/apply.lua
--
-- Pure copy-on-write materialization of a validated hierarchy snapshot plan.
-- Runtime authorization, SavedVariables swaps, and UI refreshes live elsewhere.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity
local schema = AngryEra.sync and AngryEra.sync.schema
local revisions = AngryEra.sync and AngryEra.sync.revisions
local scopes = AngryEra.sync and AngryEra.sync.scopes
local snapshot = AngryEra.sync and AngryEra.sync.snapshot

if not identity or type(identity.ValidateSyncId) ~= "function" then
    error("AngryEra identity must load before synchronization apply")
end
if not schema or type(schema.ValidateManifest) ~= "function" then
    error("AngryEra synchronization schema must load before apply")
end
if not revisions or type(revisions.WireToLocal) ~= "function" then
    error("AngryEra synchronization revisions must load before apply")
end
if not scopes or type(scopes.ValidateScopeRecord) ~= "function" then
    error("AngryEra synchronization scopes must load before apply")
end
if not snapshot or type(snapshot.Stage) ~= "function" then
    error("AngryEra synchronization snapshots must load before apply")
end

AngryEra.sync.apply = {}
local apply = AngryEra.sync.apply

local MAX_LOCAL_ID = 2147483647
local HISTORY_LIMIT = 10

local STATE_KEYS = {
    InstallationId = true,
    Pages = true,
    Categories = true,
    EntityLocal = true,
    SyncScopes = true,
}

local STAGED_KEYS = {
    Schema = true,
    ScopeId = true,
    Sender = true,
    SenderInstallationId = true,
    SenderSessionId = true,
    ReceivedAt = true,
    AuthorityTransition = true,
    NoOp = true,
    ManifestHash = true,
    Manifest = true,
    EntityIds = true,
    CleanupCandidates = true,
}

local OPTION_KEYS = {
    LocalIds = true,
    Editor = true,
}

local EDITOR_KEYS = {
    SelectedPageId = true,
    SelectedPageSyncId = true,
    Dirty = true,
}

local SYNC_FIELDS = {
    "SyncId",
    "OwnerId",
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
    "Name",
    "Vars",
}

local PAGE_LOCAL_FIELDS = {
    "Backup",
    "History",
}

local function IsPlainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function IsPositiveLocalId(value)
    return IsFiniteNumber(value) and value >= 1 and value <= MAX_LOCAL_ID and value == math.floor(value)
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

local function DeepEqual(left, right, leftSeen, rightSeen)
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return left == right
    end

    leftSeen = leftSeen or {}
    rightSeen = rightSeen or {}
    if leftSeen[left] or rightSeen[right] then
        return leftSeen[left] == right and rightSeen[right] == left
    end
    leftSeen[left] = right
    rightSeen[right] = left

    for key, value in pairs(left) do
        if rawget(right, key) == nil and value ~= nil then
            return false
        end
        if not DeepEqual(value, rawget(right, key), leftSeen, rightSeen) then
            return false
        end
    end
    for key in pairs(right) do
        if rawget(left, key) == nil then
            return false
        end
    end
    return true
end

local function ValidateKnownKeys(value, knownKeys, requiredKeys, errorPrefix)
    if not IsPlainTable(value) then
        return false, "invalid-" .. errorPrefix
    end
    for key in pairs(value) do
        if type(key) ~= "string" or not knownKeys[key] then
            return false, errorPrefix .. "-unknown-field"
        end
    end
    for _, key in ipairs(requiredKeys) do
        if rawget(value, key) == nil then
            return false, errorPrefix .. "-missing-" .. key
        end
    end
    return true
end

local function ValidateCurrentState(currentState)
    local valid, validationError = ValidateKnownKeys(currentState, STATE_KEYS, {
        "InstallationId",
        "Pages",
        "Categories",
        "EntityLocal",
        "SyncScopes",
    }, "current-state")
    if not valid then
        return false, validationError
    end
    if not identity.ValidateInstallationId(currentState.InstallationId) then
        return false, "invalid-current-installation"
    end
    for _, key in ipairs({ "Pages", "Categories", "EntityLocal", "SyncScopes" }) do
        if not IsPlainTable(currentState[key]) then
            return false, "invalid-current-" .. string.lower(key)
        end
    end
    return true
end

local function ValidateStagedShape(staged)
    local valid, validationError = ValidateKnownKeys(staged, STAGED_KEYS, {
        "Schema",
        "ScopeId",
        "Sender",
        "SenderInstallationId",
        "SenderSessionId",
        "ReceivedAt",
        "AuthorityTransition",
        "NoOp",
        "ManifestHash",
        "Manifest",
        "EntityIds",
        "CleanupCandidates",
    }, "staged-plan")
    if not valid then
        return false, validationError
    end
    if staged.Schema ~= schema.VERSION then
        return false, "invalid-staged-schema"
    end
    if type(staged.AuthorityTransition) ~= "boolean" or type(staged.NoOp) ~= "boolean" then
        return false, "invalid-staged-flags"
    end
    return true
end

local function ValidateOptions(options)
    if options == nil then
        return {
            LocalIds = {},
            EditorDirty = false,
        }
    end

    local valid, validationError = ValidateKnownKeys(options, OPTION_KEYS, {}, "apply-options")
    if not valid then
        return nil, validationError
    end

    local localIds = rawget(options, "LocalIds")
    if localIds == nil then
        localIds = {}
    elseif not IsPlainTable(localIds) then
        return nil, "invalid-local-id-allocations"
    end

    local copiedIds = {}
    for syncId, localId in pairs(localIds) do
        if not identity.ValidateSyncId(syncId) then
            return nil, "invalid-local-id-allocation-sync-id"
        end
        if not IsPositiveLocalId(localId) then
            return nil, "invalid-local-id-allocation"
        end
        copiedIds[syncId] = localId
    end

    local editor = rawget(options, "Editor")
    if editor == nil then
        return {
            LocalIds = copiedIds,
            EditorDirty = false,
        }
    end

    valid, validationError = ValidateKnownKeys(editor, EDITOR_KEYS, {}, "editor-context")
    if not valid then
        return nil, validationError
    end

    local selectedPageId = rawget(editor, "SelectedPageId")
    if selectedPageId ~= nil and not IsPositiveLocalId(selectedPageId) then
        return nil, "invalid-selected-page-id"
    end
    local selectedPageSyncId = rawget(editor, "SelectedPageSyncId")
    if selectedPageSyncId ~= nil and not identity.ValidateSyncId(selectedPageSyncId, "page") then
        return nil, "invalid-selected-page-sync-id"
    end
    local dirty = rawget(editor, "Dirty")
    if dirty ~= nil and type(dirty) ~= "boolean" then
        return nil, "invalid-editor-dirty"
    end
    dirty = dirty == true
    if dirty and selectedPageId == nil and selectedPageSyncId == nil then
        return nil, "dirty-editor-without-selection"
    end

    return {
        LocalIds = copiedIds,
        SelectedPageId = selectedPageId,
        SelectedPageSyncId = selectedPageSyncId,
        EditorDirty = dirty,
    }
end

local function RevalidateStage(currentState, staged, hashCallback)
    if type(hashCallback) ~= "function" then
        return nil, "invalid-hash-callback"
    end

    local fresh, stageError = snapshot.Stage(staged.Manifest, staged.ManifestHash, currentState, {
        Sender = staged.Sender,
        SenderInstallationId = staged.SenderInstallationId,
        SenderSessionId = staged.SenderSessionId,
        ReceivedAt = staged.ReceivedAt,
        AllowAuthorityTransition = staged.AuthorityTransition,
    }, hashCallback)
    if not fresh then
        return nil, "stale-stage-" .. tostring(stageError)
    end
    if not DeepEqual(fresh, staged) then
        return nil, "staged-plan-mismatch"
    end
    return fresh
end

local function IndexCurrentRecords(currentState)
    local bySyncId = {}
    local usedIds = {
        page = {},
        category = {},
    }

    for _, source in ipairs({
        { Kind = "category", Records = currentState.Categories },
        { Kind = "page", Records = currentState.Pages },
    }) do
        for localId, record in pairs(source.Records) do
            if
                not IsPositiveLocalId(localId)
                or not IsPlainTable(record)
                or rawget(record, "Id") ~= localId
                or not identity.ValidateSyncId(rawget(record, "SyncId"), source.Kind)
                or not identity.ValidateInstallationId(rawget(record, "OwnerId"))
            then
                return nil, nil, "invalid-current-" .. source.Kind
            end
            if identity.ParseSyncId(record.SyncId) ~= record.OwnerId then
                return nil, nil, "invalid-current-owner"
            end
            if bySyncId[record.SyncId] then
                return nil, nil, "duplicate-current-sync-id"
            end

            usedIds[source.Kind][localId] = true
            local categoryId = rawget(record, "CategoryId")
            if IsPositiveLocalId(categoryId) then
                -- Preserve dangling local placement overlays. Allocating a new
                -- category into a referenced-but-empty numeric slot would
                -- silently reparent unrelated local records.
                usedIds.category[categoryId] = true
            end
            bySyncId[record.SyncId] = {
                Kind = source.Kind,
                Id = localId,
                Record = record,
            }
        end
    end
    return bySyncId, usedIds
end

local function ResolveSelectedSyncId(currentState, currentIndex, options)
    local selectedById
    if options.SelectedPageId ~= nil then
        local page = currentState.Pages[options.SelectedPageId]
        if not page then
            return nil, "selected-page-not-found"
        end
        selectedById = page.SyncId
    end

    local selectedSyncId = options.SelectedPageSyncId or selectedById
    if options.SelectedPageSyncId and selectedById and options.SelectedPageSyncId ~= selectedById then
        return nil, "selected-page-identity-mismatch"
    end
    if selectedSyncId then
        local current = currentIndex[selectedSyncId]
        if not current or current.Kind ~= "page" then
            return nil, "selected-page-not-found"
        end
    end
    return selectedSyncId
end

local function NextFreeId(used)
    for localId = 1, MAX_LOCAL_ID do
        if not used[localId] then
            return localId
        end
    end
    return nil
end

local function SplitManifestEntities(manifest)
    local categories = {}
    local pages = {}
    local incoming = {}
    for _, entity in ipairs(manifest.Entities) do
        incoming[entity.SyncId] = entity
        if entity.Kind == "category" then
            categories[#categories + 1] = entity
        else
            pages[#pages + 1] = entity
        end
    end

    local depths = {}
    local function CategoryDepth(entity)
        local cached = depths[entity.SyncId]
        if cached then
            return cached
        end
        if entity.ParentSyncId == nil then
            depths[entity.SyncId] = 1
        else
            depths[entity.SyncId] = CategoryDepth(incoming[entity.ParentSyncId]) + 1
        end
        return depths[entity.SyncId]
    end

    table.sort(categories, function(left, right)
        local leftDepth = CategoryDepth(left)
        local rightDepth = CategoryDepth(right)
        if leftDepth ~= rightDepth then
            return leftDepth < rightDepth
        end
        if left.ParentSyncId == right.ParentSyncId and left.Order ~= right.Order then
            return left.Order < right.Order
        end
        return left.SyncId < right.SyncId
    end)
    table.sort(pages, function(left, right)
        if left.ParentSyncId ~= right.ParentSyncId then
            return left.ParentSyncId < right.ParentSyncId
        end
        if left.Order ~= right.Order then
            return left.Order < right.Order
        end
        return left.SyncId < right.SyncId
    end)
    return categories, pages, incoming
end

local function ResolveLocalIds(categories, pages, incoming, currentIndex, usedIds, requestedIds)
    for syncId in pairs(requestedIds) do
        if not incoming[syncId] then
            return nil, "unused-local-id-allocation"
        end
    end

    local resolved = {}
    local function ResolveCollection(kind, entities)
        for _, entity in ipairs(entities) do
            local existing = currentIndex[entity.SyncId]
            local requested = requestedIds[entity.SyncId]
            if existing then
                if requested ~= nil and requested ~= existing.Id then
                    return false, "existing-local-id-mismatch"
                end
                resolved[entity.SyncId] = existing.Id
            else
                local localId = requested or NextFreeId(usedIds[kind])
                if not localId then
                    return false, "local-id-space-exhausted"
                end
                if usedIds[kind][localId] then
                    return false, "local-id-allocation-collision"
                end
                usedIds[kind][localId] = true
                resolved[entity.SyncId] = localId
            end
        end
        return true
    end

    local ok, allocationError = ResolveCollection("category", categories)
    if not ok then
        return nil, allocationError
    end
    ok, allocationError = ResolveCollection("page", pages)
    if not ok then
        return nil, allocationError
    end
    return resolved
end

local function NewRootIndex(currentState)
    local maximum = 0
    for _, records in ipairs({ currentState.Categories, currentState.Pages }) do
        for _, record in pairs(records) do
            local index = rawget(record, "Index")
            if rawget(record, "CategoryId") == nil and IsFiniteNumber(index) and index > maximum then
                maximum = index
            end
        end
    end
    if maximum >= schema.LIMITS.Timestamp then
        return nil, "root-index-exhausted"
    end
    return maximum + 1
end

local function CopyPageLocalFields(existing, incoming, localFields, staged)
    for _, field in ipairs(PAGE_LOCAL_FIELDS) do
        local value = rawget(existing, field)
        if value ~= nil then
            localFields[field] = value
        end
    end

    local history = localFields.History
    if history ~= nil then
        if not IsPlainTable(history) then
            return false, "invalid-local-history"
        end
        local boundedHistory = {}
        for index = 1, HISTORY_LIMIT do
            local entry = rawget(history, index)
            if entry == nil then
                break
            end
            boundedHistory[index] = Clone(entry)
        end
        localFields.History = boundedHistory
    end

    if existing.Contents == incoming.Contents or type(existing.Contents) ~= "string" or existing.Contents == "" then
        return true
    end

    history = localFields.History
    if history == nil then
        history = {}
    end

    local first = rawget(history, 1)
    if not IsPlainTable(first) or first.content ~= existing.Contents then
        local retained = math.min(#history, HISTORY_LIMIT - 1)
        for index = retained, 1, -1 do
            history[index + 1] = history[index]
        end
        history[1] = {
            timestamp = staged.ReceivedAt,
            content = existing.Contents,
            author = staged.Sender,
        }
        for index = HISTORY_LIMIT + 1, #history do
            history[index] = nil
        end
    end
    localFields.History = history
    return true
end

local function RecordsMatch(kind, current, materialized)
    if not current then
        return false
    end
    for _, field in ipairs(SYNC_FIELDS) do
        if rawget(current, field) ~= rawget(materialized, field) then
            return false
        end
    end
    if
        rawget(current, "Id") ~= rawget(materialized, "Id")
        or rawget(current, "CategoryId") ~= rawget(materialized, "CategoryId")
        or rawget(current, "Index") ~= rawget(materialized, "Index")
    then
        return false
    end
    return kind ~= "page" or rawget(current, "Contents") == rawget(materialized, "Contents")
end

local function PrepareRootPlacement(currentState, currentIndex, resolvedIds, rootSyncId)
    local existing = currentIndex[rootSyncId]
    if not existing then
        local index, indexError = NewRootIndex(currentState)
        if not index then
            return nil, indexError
        end
        return {
            Index = index,
        }
    end

    local root = existing.Record
    local parentId = rawget(root, "CategoryId")
    if parentId ~= nil then
        local incomingCategoryIds = {}
        for syncId, localId in pairs(resolvedIds) do
            if identity.ValidateSyncId(syncId, "category") then
                incomingCategoryIds[localId] = true
            end
        end

        local seen = {}
        local ancestorId = parentId
        local depth = 0
        while ancestorId ~= nil do
            depth = depth + 1
            if depth > schema.LIMITS.HierarchyDepth then
                return nil, "root-placement-depth-exceeded"
            end
            if not IsPositiveLocalId(ancestorId) then
                return nil, "invalid-root-parent"
            end
            if incomingCategoryIds[ancestorId] then
                return nil, "root-placement-inside-scope"
            end
            if seen[ancestorId] then
                return nil, "root-placement-cycle"
            end
            seen[ancestorId] = true

            local ancestor = currentState.Categories[ancestorId]
            if not IsPlainTable(ancestor) then
                return nil, "invalid-root-parent"
            end
            ancestorId = rawget(ancestor, "CategoryId")
        end
    end
    local index = rawget(root, "Index")
    if index ~= nil and not IsFiniteNumber(index) then
        return nil, "invalid-root-index"
    end

    return {
        CategoryId = parentId,
        Index = index,
    }
end

local function MaterializeEntity(entity, current, resolvedIds, rootSyncId, rootPlacement, staged, hashCallback)
    local localFields = {
        Id = resolvedIds[entity.SyncId],
    }
    if entity.SyncId == rootSyncId then
        localFields.CategoryId = rootPlacement.CategoryId
        localFields.Index = rootPlacement.Index
    else
        local parentId = resolvedIds[entity.ParentSyncId]
        if not parentId then
            return nil, "unresolved-local-parent"
        end
        localFields.CategoryId = parentId
        localFields.Index = entity.Order
    end

    if entity.Kind == "page" and current then
        local copied, copyError = CopyPageLocalFields(current.Record, entity, localFields, staged)
        if not copied then
            return nil, copyError
        end
    end
    if entity.Kind == "page" then
        -- Keep local editor compatibility fields coherent with canonical v3
        -- revisions instead of retaining stale hashes and timestamps.
        localFields.UpdateId = entity.RevisionId
        localFields.Updated = entity.UpdatedAt
    end

    local materialized, materializeError = revisions.WireToLocal(entity, localFields, hashCallback)
    if not materialized then
        return nil, "wire-to-local-" .. tostring(materializeError)
    end
    return materialized
end

local function ReconcileProvenance(currentEntityLocal, scopeId, entityIds, candidates)
    local nextEntityLocal = Clone(currentEntityLocal)

    for _, state in pairs(nextEntityLocal) do
        if IsPlainTable(state) and IsPlainTable(state.ManagedScopes) then
            state.ManagedScopes[scopeId] = nil
        end
    end

    local managedIds = {}
    for _, syncId in ipairs(entityIds) do
        managedIds[syncId] = true
    end
    for _, candidate in ipairs(candidates) do
        managedIds[candidate.SyncId] = true
    end

    for syncId in pairs(managedIds) do
        local state = nextEntityLocal[syncId]
        if not IsPlainTable(state) then
            state = {}
            nextEntityLocal[syncId] = state
        end
        state.OwnedLocally = false
        state.Pinned = state.Pinned == true
        state.ManagedScopes = scopes.NormalizeManagedScopes(state.ManagedScopes)
        state.ManagedScopes[scopeId] = true
    end
    return nextEntityLocal
end

local function BuildNextScope(currentScope, staged, hashCallback)
    local manifest = staged.Manifest
    local nextScope = {
        Schema = scopes.VERSION,
        ScopeId = staged.ScopeId,
        Enabled = currentScope.Enabled,
        AutoCleanup = currentScope.AutoCleanup,
        AuthoritySender = staged.Sender,
        AuthorityInstallationId = staged.SenderInstallationId,
        AuthorityEpoch = manifest.AuthorityEpoch,
        ScopeRevision = manifest.ScopeRevision,
        ManifestId = manifest.ManifestId,
        ManifestHash = staged.ManifestHash,
        AppliedAt = staged.ReceivedAt,
        EntityIds = Clone(staged.EntityIds),
        Tombstones = Clone(manifest.Tombstones),
        CleanupCandidates = Clone(staged.CleanupCandidates),
    }

    local valid, validationError = scopes.ValidateScopeRecord(nextScope, hashCallback)
    if not valid then
        return nil, "invalid-next-scope-" .. tostring(validationError)
    end
    return nextScope
end

local function NewSummary(staged, resolvedIds)
    return {
        Schema = schema.VERSION,
        ScopeId = staged.ScopeId,
        ScopeRevision = staged.Manifest.ScopeRevision,
        ManifestId = staged.Manifest.ManifestId,
        AuthorityTransition = staged.AuthorityTransition,
        NoOp = staged.NoOp,
        Applied = not staged.NoOp,
        RootLocalId = resolvedIds[staged.Manifest.RootSyncId],
        ResolvedLocalIds = Clone(resolvedIds),
        Created = {
            Categories = {},
            Pages = {},
        },
        Updated = {
            Categories = {},
            Pages = {},
        },
        ChangedSyncIds = {},
        CleanupCandidates = Clone(staged.CleanupCandidates),
    }
end

--- Builds a completely detached next synchronization state.
-- The caller owns any editor draft buffer; this function receives only selection
-- and dirty-state metadata and reports a conflict without copying the draft into
-- persisted state. New local IDs may be supplied through `options.LocalIds`;
-- otherwise the lowest unused ID for each entity kind is chosen deterministically.
-- @tparam table currentState Plain InstallationId/Pages/Categories/EntityLocal/SyncScopes state.
-- @tparam table staged Detached result returned by `snapshot.Stage`.
-- @tparam[opt] table options Local ID allocations and runtime-only editor metadata.
-- @tparam function hashCallback Fixed production FCS32 callback.
-- @treturn table|nil nextState
-- @treturn table|nil summary
-- @treturn string|nil errorCode
function apply.BuildNextState(currentState, staged, options, hashCallback)
    local validState, stateError = ValidateCurrentState(currentState)
    if not validState then
        return nil, nil, stateError
    end
    local validStaged, stagedError = ValidateStagedShape(staged)
    if not validStaged then
        return nil, nil, stagedError
    end

    local safeOptions, optionsError = ValidateOptions(options)
    if not safeOptions then
        return nil, nil, optionsError
    end
    local safeStaged, revalidationError = RevalidateStage(currentState, staged, hashCallback)
    if not safeStaged then
        return nil, nil, revalidationError
    end

    local currentIndex, usedIds, indexError = IndexCurrentRecords(currentState)
    if not currentIndex then
        return nil, nil, indexError
    end
    local selectedSyncId, selectedError = ResolveSelectedSyncId(currentState, currentIndex, safeOptions)
    if selectedError then
        return nil, nil, selectedError
    end

    local categories, pages, incoming = SplitManifestEntities(safeStaged.Manifest)
    local resolvedIds, allocationError =
        ResolveLocalIds(categories, pages, incoming, currentIndex, usedIds, safeOptions.LocalIds)
    if not resolvedIds then
        return nil, nil, allocationError
    end

    local summary = NewSummary(safeStaged, resolvedIds)
    if safeStaged.NoOp then
        return {
            InstallationId = currentState.InstallationId,
            Pages = Clone(currentState.Pages),
            Categories = Clone(currentState.Categories),
            EntityLocal = Clone(currentState.EntityLocal),
            SyncScopes = Clone(currentState.SyncScopes),
        },
            summary
    end

    local rootPlacement, placementError =
        PrepareRootPlacement(currentState, currentIndex, resolvedIds, safeStaged.Manifest.RootSyncId)
    if not rootPlacement then
        return nil, nil, placementError
    end

    local nextPages = Clone(currentState.Pages)
    local nextCategories = Clone(currentState.Categories)
    local function MaterializeCollection(kind, entities, destination, summaryKey)
        for _, entity in ipairs(entities) do
            local current = currentIndex[entity.SyncId]
            local materialized, materializeError = MaterializeEntity(
                entity,
                current,
                resolvedIds,
                safeStaged.Manifest.RootSyncId,
                rootPlacement,
                safeStaged,
                hashCallback
            )
            if not materialized then
                return false, materializeError
            end

            destination[materialized.Id] = materialized
            local summaryCollection
            if current then
                if not RecordsMatch(kind, current.Record, materialized) then
                    summaryCollection = summary.Updated[summaryKey]
                end
            else
                summaryCollection = summary.Created[summaryKey]
            end
            if summaryCollection then
                summaryCollection[#summaryCollection + 1] = {
                    SyncId = entity.SyncId,
                    LocalId = materialized.Id,
                }
                summary.ChangedSyncIds[entity.SyncId] = true
            end

            if
                kind == "page"
                and current
                and safeOptions.EditorDirty
                and selectedSyncId == entity.SyncId
                and not RecordsMatch(kind, current.Record, materialized)
            then
                summary.SelectedDirtyConflict = {
                    Reason = "dirty-editor",
                    SyncId = entity.SyncId,
                    LocalId = materialized.Id,
                    PreviousRevision = current.Record.Revision,
                    PreviousRevisionId = current.Record.RevisionId,
                    IncomingRevision = entity.Revision,
                    IncomingRevisionId = entity.RevisionId,
                    Sender = safeStaged.Sender,
                    PreserveDraft = true,
                }
            end
        end
        return true
    end

    -- Categories are intentionally materialized before pages even though the
    -- canonical manifest itself is ordered by SyncId.
    local materialized, materializeError = MaterializeCollection("category", categories, nextCategories, "Categories")
    if not materialized then
        return nil, nil, materializeError
    end
    materialized, materializeError = MaterializeCollection("page", pages, nextPages, "Pages")
    if not materialized then
        return nil, nil, materializeError
    end

    local nextEntityLocal = ReconcileProvenance(
        currentState.EntityLocal,
        safeStaged.ScopeId,
        safeStaged.EntityIds,
        safeStaged.CleanupCandidates
    )
    local nextScopes = Clone(currentState.SyncScopes)

    -- Scope metadata is constructed and attached only after every entity and
    -- provenance update has succeeded.
    local nextScope, scopeError = BuildNextScope(currentState.SyncScopes[safeStaged.ScopeId], safeStaged, hashCallback)
    if not nextScope then
        return nil, nil, scopeError
    end
    nextScopes[safeStaged.ScopeId] = nextScope

    return {
        InstallationId = currentState.InstallationId,
        Pages = nextPages,
        Categories = nextCategories,
        EntityLocal = nextEntityLocal,
        SyncScopes = nextScopes,
    },
        summary
end
