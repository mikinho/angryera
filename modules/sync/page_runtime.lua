-- -------------------------------------------------------------------------------
-- Angry Era: modules/sync/page_runtime.lua
--
-- Authorized runtime boundary for protocol-v3 active-page preparation, reception,
-- render-context caching, and display selection. Transport and envelope
-- correlation remain the responsibility of protocol_runtime.lua.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity
local protocol = AngryEra.utils and AngryEra.utils.protocol
local helpers = AngryEra.utils and AngryEra.utils.helpers
local schema = AngryEra.sync and AngryEra.sync.schema
local revisions = AngryEra.sync and AngryEra.sync.revisions
local activePage = AngryEra.sync and AngryEra.sync.activePage

if not identity or type(identity.ValidateInstallationId) ~= "function" then
    error("AngryEra identity must load before active-page runtime")
end
if not protocol or type(protocol.ValidatePayload) ~= "function" then
    error("AngryEra protocol must load before active-page runtime")
end
if not helpers or type(helpers.EnsureUnitFullName) ~= "function" then
    error("AngryEra helpers must load before active-page runtime")
end
if not schema or type(schema.ValidateEntity) ~= "function" then
    error("AngryEra synchronization schema must load before active-page runtime")
end
if not revisions or type(revisions.WireToLocal) ~= "function" then
    error("AngryEra synchronization revisions must load before active-page runtime")
end
if
    not activePage
    or type(activePage.PrepareLocalPageUpsert) ~= "function"
    or type(activePage.PrepareLocalPageUpsertFromContext) ~= "function"
    or type(activePage.ValidatePageUpsertPayload) ~= "function"
then
    error("AngryEra active-page synchronization must load before active-page runtime")
end

AngryEra.sync.pageRuntime = {}
local pageRuntime = AngryEra.sync.pageRuntime

local MAX_LOCAL_ID = schema.LIMITS.LocalId
local MAX_RUNTIME_RECORDS = schema.LIMITS.EntityCount * 128
local MAX_CONTEXT_ENTRIES = 32
local HISTORY_LIMIT = 10
local contextArrivalOrdinal = 0
local AUTH_KEYS = {
    Sender = true,
    SenderInstallationId = true,
    SenderSessionId = true,
    ReceivedAt = true,
}
local ACCEPT_OPTION_KEYS = {
    CorrelatedReply = true,
    AuthorityBootstrap = true,
}
local LOCAL_FIELDS = {
    "CategoryId",
    "Index",
    "Backup",
    "History",
    "UpdateId",
    "Updated",
}
local REVISION_FIELDS = {
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
}
local CHANGE_DESIRED_FIELDS = {
    Name = true,
    Vars = true,
    Contents = true,
}

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

local function DeepEqual(left, right, leftToRight, rightToLeft)
    if left == right then
        return true
    end
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end

    leftToRight = leftToRight or {}
    rightToLeft = rightToLeft or {}
    if leftToRight[left] ~= nil or rightToLeft[right] ~= nil then
        return leftToRight[left] == right and rightToLeft[right] == left
    end
    leftToRight[left] = right
    rightToLeft[right] = left

    for key, value in pairs(left) do
        if not DeepEqual(value, rawget(right, key), leftToRight, rightToLeft) then
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

local function ValidateAuth(auth)
    if not IsPlainTable(auth) then
        return nil, "invalid-active-page-auth"
    end
    for key in pairs(auth) do
        if type(key) ~= "string" or not AUTH_KEYS[key] then
            return nil, "active-page-auth-unknown-field"
        end
    end
    for key in pairs(AUTH_KEYS) do
        if rawget(auth, key) == nil then
            return nil, "active-page-auth-missing-" .. key
        end
    end

    if type(auth.Sender) ~= "string" or auth.Sender == "" then
        return nil, "invalid-active-page-sender"
    end
    local sender = helpers.EnsureUnitFullName(auth.Sender)
    if type(sender) ~= "string" or sender == "" then
        return nil, "invalid-active-page-sender"
    end
    if not identity.ValidateInstallationId(auth.SenderInstallationId) then
        return nil, "invalid-active-page-installation"
    end
    if
        type(auth.SenderSessionId) ~= "string"
        or auth.SenderSessionId == ""
        or #auth.SenderSessionId > schema.LIMITS.SessionIdBytes
        or auth.SenderSessionId:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") == nil
    then
        return nil, "invalid-active-page-session"
    end
    if not IsInteger(auth.ReceivedAt, 0, schema.LIMITS.Timestamp) then
        return nil, "invalid-active-page-received-at"
    end

    return {
        Sender = sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        ReceivedAt = auth.ReceivedAt,
    }
end

local function IsAuthorized(self, sender, action)
    if type(self.CanReceiveFrom) ~= "function" then
        return false
    end
    local ok, authorized = pcall(self.CanReceiveFrom, self, sender, action)
    return ok and authorized == true
end

local function IsCurrentDisplayAuthority(self, sender)
    if not IsAuthorized(self, sender, "display") or type(self.GetGroupRole) ~= "function" then
        return false
    end
    local ok, role = pcall(self.GetGroupRole, self, sender)
    return ok and role == "leader"
end

local function CanPublish(self, action)
    if type(self.CanLocalPlayerPublish) ~= "function" then
        return false
    end
    local ok, authorized = pcall(self.CanLocalPlayerPublish, self, action)
    return ok and authorized == true
end

local function GetHashCallback(self)
    if type(self.GetSyncHashCallback) == "function" then
        local ok, callback, callbackError = pcall(self.GetSyncHashCallback, self)
        if not ok then
            return nil, "active-page-hash-unavailable"
        end
        if callback then
            return callback
        end
        return nil, callbackError or "active-page-hash-unavailable"
    end

    return revisions.CreateFCS32Callback(app.libs and app.libs.libC)
end

local function ValidateAcceptOptions(options)
    if options == nil then
        return {
            CorrelatedReply = false,
            AuthorityBootstrap = false,
        }
    end
    if not IsPlainTable(options) then
        return nil, "invalid-active-page-accept-options"
    end
    for key in pairs(options) do
        if type(key) ~= "string" or not ACCEPT_OPTION_KEYS[key] then
            return nil, "active-page-accept-options-unknown-field"
        end
    end
    if rawget(options, "CorrelatedReply") == nil then
        return nil, "active-page-accept-options-missing-CorrelatedReply"
    end
    if options.CorrelatedReply ~= true then
        return nil, "invalid-active-page-correlated-reply"
    end
    if options.AuthorityBootstrap ~= nil and type(options.AuthorityBootstrap) ~= "boolean" then
        return nil, "invalid-active-page-authority-bootstrap"
    end
    return {
        CorrelatedReply = true,
        AuthorityBootstrap = options.AuthorityBootstrap == true,
    }
end

local function ParseSelectedId(state)
    if not IsPlainTable(state) or not IsPlainTable(state.tree) then
        return nil
    end

    local selected = state.tree.selected
    if type(selected) == "number" then
        return IsInteger(selected, -MAX_LOCAL_ID, MAX_LOCAL_ID) and selected ~= 0 and selected or nil
    end
    if type(selected) ~= "string" or selected == "" then
        return nil
    end

    local selectedId = tonumber(selected:match("([^\001]+)$"))
    return IsInteger(selectedId, -MAX_LOCAL_ID, MAX_LOCAL_ID) and selectedId ~= 0 and selectedId or nil
end

local function EditorIsDirty(self)
    if self.window == nil then
        return false
    end
    if type(self.window) ~= "table" or type(self.window.text) ~= "table" then
        return nil, "editor-state-unavailable"
    end

    local button = self.window.text.button
    if type(button) ~= "table" or type(button.IsEnabled) ~= "function" then
        return nil, "editor-state-unavailable"
    end
    local ok, dirty = pcall(button.IsEnabled, button)
    if not ok or type(dirty) ~= "boolean" then
        return nil, "editor-state-unavailable"
    end
    return dirty
end

local function BuildIdentityIndexes(pages, categories)
    if not IsPlainTable(pages) or not IsPlainTable(categories) then
        return nil, nil, "invalid-active-page-records"
    end

    local indexes = {
        page = {},
        category = {},
    }
    local ids = {
        page = {},
        category = {},
    }
    local bySyncId = {}
    local total = 0

    for _, source in ipairs({
        { Kind = "category", Records = categories },
        { Kind = "page", Records = pages },
    }) do
        for localId, record in pairs(source.Records) do
            total = total + 1
            if total > MAX_RUNTIME_RECORDS then
                return nil, nil, "too-many-active-page-records"
            end
            if
                not IsPositiveLocalId(localId)
                or not IsPlainTable(record)
                or rawget(record, "Id") ~= localId
                or not identity.ValidateSyncId(rawget(record, "SyncId"), source.Kind)
                or not identity.ValidateInstallationId(rawget(record, "OwnerId"))
                or identity.ParseSyncId(record.SyncId) ~= record.OwnerId
            then
                return nil, nil, "invalid-active-page-" .. source.Kind
            end
            if bySyncId[record.SyncId] then
                return nil, nil, "duplicate-active-page-sync-id"
            end
            indexes[source.Kind][record.SyncId] = record
            ids[source.Kind][localId] = true
            bySyncId[record.SyncId] = {
                Kind = source.Kind,
                Id = localId,
                Record = record,
            }
        end
    end
    return indexes, {
        BySyncId = bySyncId,
        UsedIds = ids,
    }
end

local function SnapshotIdentityStructure(records)
    local snapshot = {}
    for id, record in pairs(records) do
        snapshot[id] = {
            Record = record,
            Id = IsPlainTable(record) and rawget(record, "Id") or nil,
            SyncId = IsPlainTable(record) and rawget(record, "SyncId") or nil,
            OwnerId = IsPlainTable(record) and rawget(record, "OwnerId") or nil,
        }
    end
    return snapshot
end

local function IdentityStructureMatches(records, snapshot)
    for id, expected in pairs(snapshot) do
        local record = rawget(records, id)
        if
            record ~= expected.Record
            or not IsPlainTable(record)
            or rawget(record, "Id") ~= expected.Id
            or rawget(record, "SyncId") ~= expected.SyncId
            or rawget(record, "OwnerId") ~= expected.OwnerId
        then
            return false
        end
    end
    for id in pairs(records) do
        if snapshot[id] == nil then
            return false
        end
    end
    return true
end

local function SnapshotFields(record)
    local snapshot = {}
    for key, value in pairs(record) do
        snapshot[key] = value
    end
    return snapshot
end

local function FieldsMatch(record, snapshot)
    if not IsPlainTable(record) then
        return false
    end
    for key, value in pairs(snapshot) do
        if rawget(record, key) ~= value then
            return false
        end
    end
    for key in pairs(record) do
        if snapshot[key] == nil then
            return false
        end
    end
    return true
end

local function SnapshotProvenanceStructure(records)
    local snapshot = {}
    for syncId, state in pairs(records) do
        local managedScopes = IsPlainTable(state) and rawget(state, "ManagedScopes") or nil
        snapshot[syncId] = {
            State = state,
            Fields = IsPlainTable(state) and SnapshotFields(state) or nil,
            ManagedScopes = IsPlainTable(managedScopes) and SnapshotFields(managedScopes) or managedScopes,
        }
    end
    return snapshot
end

local function ProvenanceStructureMatches(records, snapshot)
    for syncId, expected in pairs(snapshot) do
        local state = rawget(records, syncId)
        if state ~= expected.State or not IsPlainTable(state) or not FieldsMatch(state, expected.Fields) then
            return false
        end

        local managedScopes = rawget(state, "ManagedScopes")
        if IsPlainTable(expected.ManagedScopes) then
            if not IsPlainTable(managedScopes) or not FieldsMatch(managedScopes, expected.ManagedScopes) then
                return false
            end
        elseif managedScopes ~= expected.ManagedScopes then
            return false
        end
    end
    for syncId in pairs(records) do
        if snapshot[syncId] == nil then
            return false
        end
    end
    return true
end

local function SnapshotScopeStructure(scopes)
    local snapshot = {}
    for scopeId, scope in pairs(scopes) do
        snapshot[scopeId] = {
            Scope = scope,
            Fields = IsPlainTable(scope) and SnapshotFields(scope) or nil,
        }
    end
    return snapshot
end

local function ScopeStructureMatches(scopes, snapshot)
    for scopeId, expected in pairs(snapshot) do
        local scope = rawget(scopes, scopeId)
        if scope ~= expected.Scope or not IsPlainTable(scope) or not FieldsMatch(scope, expected.Fields) then
            return false
        end
    end
    for scopeId in pairs(scopes) do
        if snapshot[scopeId] == nil then
            return false
        end
    end
    return true
end

local function CaptureStorage(self)
    if
        not IsPlainTable(AngryAssign_Pages)
        or not IsPlainTable(AngryAssign_Categories)
        or not IsPlainTable(AngryAssign_Meta)
        or not IsPlainTable(AngryAssign_Meta.EntityLocal)
        or not IsPlainTable(AngryAssign_Meta.SyncScopes)
        or not identity.ValidateInstallationId(AngryAssign_Meta.InstallationId)
        or not IsPlainTable(AngryAssign_State)
    then
        return nil, "invalid-active-page-storage"
    end

    local indexes, indexed, indexError = BuildIdentityIndexes(AngryAssign_Pages, AngryAssign_Categories)
    if not indexes then
        return nil, indexError
    end
    local dirty, dirtyError = EditorIsDirty(self)
    if dirty == nil then
        return nil, dirtyError
    end

    local selectedId = ParseSelectedId(AngryAssign_State)
    local displayedId = rawget(AngryAssign_State, "displayed")
    if not IsPositiveLocalId(displayedId) then
        displayedId = nil
    end
    if IsPositiveLocalId(selectedId) then
        indexed.UsedIds.page[selectedId] = true
    elseif type(selectedId) == "number" and IsPositiveLocalId(-selectedId) then
        indexed.UsedIds.category[-selectedId] = true
    end
    if displayedId then
        indexed.UsedIds.page[displayedId] = true
    end

    return {
        Pages = AngryAssign_Pages,
        Categories = AngryAssign_Categories,
        Meta = AngryAssign_Meta,
        EntityLocal = AngryAssign_Meta.EntityLocal,
        State = AngryAssign_State,
        Contexts = self._activePageContexts,
        DisplayReference = self._activeDisplayReference,
        PendingDisplay = self._activePendingDisplay,
        Indexes = indexes,
        Indexed = indexed,
        PageStructure = SnapshotIdentityStructure(AngryAssign_Pages),
        CategoryStructure = SnapshotIdentityStructure(AngryAssign_Categories),
        ProvenanceStructure = SnapshotProvenanceStructure(AngryAssign_Meta.EntityLocal),
        ScopeStructure = SnapshotScopeStructure(AngryAssign_Meta.SyncScopes),
        MetaSnapshot = SnapshotFields(AngryAssign_Meta),
        StateSnapshot = SnapshotFields(AngryAssign_State),
        SelectedId = selectedId,
        DisplayedId = displayedId,
        EditorDirty = dirty,
    }
end

local function StorageMatches(self, capture)
    if
        AngryAssign_Pages ~= capture.Pages
        or AngryAssign_Categories ~= capture.Categories
        or AngryAssign_Meta ~= capture.Meta
        or AngryAssign_Meta.EntityLocal ~= capture.EntityLocal
        or AngryAssign_State ~= capture.State
        or self._activePageContexts ~= capture.Contexts
        or self._activeDisplayReference ~= capture.DisplayReference
        or self._activePendingDisplay ~= capture.PendingDisplay
        or ParseSelectedId(AngryAssign_State) ~= capture.SelectedId
    then
        return false
    end

    local displayedId = rawget(AngryAssign_State, "displayed")
    if not IsPositiveLocalId(displayedId) then
        displayedId = nil
    end
    if displayedId ~= capture.DisplayedId then
        return false
    end

    local dirty = EditorIsDirty(self)
    return dirty ~= nil
        and dirty == capture.EditorDirty
        and FieldsMatch(AngryAssign_Meta, capture.MetaSnapshot)
        and FieldsMatch(AngryAssign_State, capture.StateSnapshot)
        and IdentityStructureMatches(AngryAssign_Pages, capture.PageStructure)
        and IdentityStructureMatches(AngryAssign_Categories, capture.CategoryStructure)
        and ProvenanceStructureMatches(AngryAssign_Meta.EntityLocal, capture.ProvenanceStructure)
        and ScopeStructureMatches(AngryAssign_Meta.SyncScopes, capture.ScopeStructure)
end

local function AllocatePageId(used)
    for id = 1, MAX_LOCAL_ID do
        if not used[id] then
            return id
        end
    end
    return nil
end

local function CountRevisionFields(record)
    local count = 0
    for _, field in ipairs(REVISION_FIELDS) do
        if rawget(record, field) ~= nil then
            count = count + 1
        end
    end
    return count
end

local function SnapshotRevisionMetadata(record)
    local snapshot = {}
    for _, field in ipairs(REVISION_FIELDS) do
        snapshot[field] = {
            Present = rawget(record, field) ~= nil,
            Value = rawget(record, field),
        }
    end
    return snapshot
end

local function RestorePreparedRevision(record, preparedPage, snapshot)
    for _, field in ipairs(REVISION_FIELDS) do
        if rawget(record, field) ~= rawget(preparedPage, field) then
            return
        end
    end
    for _, field in ipairs(REVISION_FIELDS) do
        local prior = snapshot[field]
        record[field] = prior.Present and prior.Value or nil
    end
end

local WIRE_DEFAULTED_TEXT_FIELDS = {
    Vars = true,
    Contents = true,
}

local function StoredPageMatchesWire(existing, incoming)
    for _, field in ipairs({
        "SyncId",
        "OwnerId",
        "Revision",
        "RevisionId",
        "UpdatedAt",
        "UpdatedBy",
        "Name",
        "Vars",
        "Contents",
    }) do
        local existingValue = rawget(existing, field)
        if existingValue == nil and WIRE_DEFAULTED_TEXT_FIELDS[field] then
            existingValue = ""
        end
        if existingValue ~= rawget(incoming, field) then
            return false
        end
    end
    return true
end

local function CompareIncomingRevision(existing, incoming)
    local present = CountRevisionFields(existing)
    if present ~= 0 and present ~= #REVISION_FIELDS then
        return false, "partial-local-revision-metadata"
    end
    if present == 0 then
        return true, "replace"
    end
    if not IsInteger(existing.Revision, 1, schema.LIMITS.Revision) or type(existing.RevisionId) ~= "string" then
        return false, "invalid-local-revision"
    end
    if incoming.Revision < existing.Revision then
        return false, "page-revision-rollback"
    end
    if incoming.Revision == existing.Revision then
        if incoming.RevisionId ~= existing.RevisionId then
            return false, "page-revision-divergence"
        end
        if not StoredPageMatchesWire(existing, incoming) then
            return false, "page-revision-materialization-mismatch"
        end
        return true, "unchanged"
    end
    return true, "replace"
end

local function BuildLocalFields(existing, id, auth, incoming)
    local fields = {
        Id = id,
    }
    if existing then
        for _, field in ipairs(LOCAL_FIELDS) do
            local value = field ~= "History" and rawget(existing, field) or nil
            if value ~= nil then
                fields[field] = value
            end
        end

        local currentHistory = rawget(existing, "History")
        if currentHistory ~= nil and not IsPlainTable(currentHistory) then
            return nil, "invalid-local-history"
        end
        local history = {}
        for index = 1, HISTORY_LIMIT do
            local entry = currentHistory and rawget(currentHistory, index) or nil
            if entry == nil then
                break
            end
            history[index] = Clone(entry)
        end

        local oldContents = rawget(existing, "Contents")
        if type(oldContents) == "string" and oldContents ~= "" and oldContents ~= incoming.Contents then
            local first = rawget(history, 1)
            if not IsPlainTable(first) or first.content ~= oldContents then
                local retained = math.min(#history, HISTORY_LIMIT - 1)
                for index = retained, 1, -1 do
                    history[index + 1] = history[index]
                end
                history[1] = {
                    timestamp = auth.ReceivedAt,
                    content = oldContents,
                    author = auth.Sender,
                }
            end
        end
        if currentHistory ~= nil or #history > 0 then
            fields.History = history
        end
    end
    return fields
end

local function BuildNextMeta(capture, syncId)
    local nextMeta = ShallowCopy(capture.Meta)
    local nextLocal = ShallowCopy(capture.EntityLocal)
    if not nextMeta or not nextLocal then
        return nil, "invalid-active-page-metadata"
    end

    local current = rawget(capture.EntityLocal, syncId)
    if current ~= nil and not IsPlainTable(current) then
        return nil, "invalid-active-page-provenance"
    end
    if current and current.OwnedLocally == true then
        return nil, "locally-owned-collision"
    end
    if current and current.OwnedLocally ~= nil and type(current.OwnedLocally) ~= "boolean" then
        return nil, "invalid-active-page-provenance"
    end
    if current and current.Pinned ~= nil and type(current.Pinned) ~= "boolean" then
        return nil, "invalid-active-page-provenance"
    end
    if current and current.ManagedScopes ~= nil and not IsPlainTable(current.ManagedScopes) then
        return nil, "invalid-active-page-provenance"
    end

    local localState = current and ShallowCopy(current) or {}
    localState.OwnedLocally = false
    if localState.Pinned == nil then
        localState.Pinned = false
    end
    if localState.ManagedScopes == nil then
        localState.ManagedScopes = {}
    end
    nextLocal[syncId] = localState
    nextMeta.EntityLocal = nextLocal
    return nextMeta
end

local function BuildContextEntry(auth, payload)
    contextArrivalOrdinal = contextArrivalOrdinal + 1
    return {
        SyncId = payload.Page.SyncId,
        Revision = payload.Page.Revision,
        RevisionId = payload.Page.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
        Page = Clone(payload.Page),
        AncestorVariableLayers = Clone(payload.AncestorVariableLayers),
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        ReceivedAt = auth.ReceivedAt,
        ArrivalOrdinal = contextArrivalOrdinal,
    }
end

local function ContextArrivalOrder(entry)
    local ordinal = IsPlainTable(entry) and rawget(entry, "ArrivalOrdinal") or nil
    return IsInteger(ordinal, 1, schema.LIMITS.Timestamp) and ordinal or 0
end

local function ContextIsNewer(candidate, candidateKey, selected, selectedKey)
    if selected == nil or candidate.ReceivedAt > selected.ReceivedAt then
        return true
    end
    if candidate.ReceivedAt < selected.ReceivedAt then
        return false
    end

    local candidateOrdinal = ContextArrivalOrder(candidate)
    local selectedOrdinal = ContextArrivalOrder(selected)
    if candidateOrdinal ~= selectedOrdinal then
        return candidateOrdinal > selectedOrdinal
    end
    return candidateKey < selectedKey
end

local function ContextIsOlder(candidate, candidateKey, selected, selectedKey)
    if selected == nil or candidate.ReceivedAt < selected.ReceivedAt then
        return true
    end
    if candidate.ReceivedAt > selected.ReceivedAt then
        return false
    end

    local candidateOrdinal = ContextArrivalOrder(candidate)
    local selectedOrdinal = ContextArrivalOrder(selected)
    if candidateOrdinal ~= selectedOrdinal then
        return candidateOrdinal < selectedOrdinal
    end
    return candidateKey < selectedKey
end

local function ContextKey(sender, installationId, sessionId, reference)
    local parts = {
        sender,
        installationId,
        sessionId,
        reference.SyncId,
        tostring(reference.Revision),
        reference.RevisionId,
        reference.ContextRevisionId,
    }
    for index, value in ipairs(parts) do
        value = tostring(value)
        parts[index] = tostring(#value) .. ":" .. value
    end
    return table.concat(parts)
end

local function ContextKeyForReference(reference)
    if
        not IsPlainTable(reference)
        or type(reference.Sender) ~= "string"
        or type(reference.SenderInstallationId) ~= "string"
        or type(reference.SenderSessionId) ~= "string"
        or type(reference.SyncId) ~= "string"
        or not IsInteger(reference.Revision, 1, schema.LIMITS.Revision)
        or type(reference.RevisionId) ~= "string"
        or type(reference.ContextRevisionId) ~= "string"
    then
        return nil
    end
    return ContextKey(reference.Sender, reference.SenderInstallationId, reference.SenderSessionId, reference)
end

local function FindContext(contexts, auth, reference)
    if not IsPlainTable(contexts) then
        return nil
    end
    local key = ContextKey(auth.Sender, auth.SenderInstallationId, auth.SenderSessionId, reference)
    local entry = rawget(contexts, key)
    return IsPlainTable(entry) and entry or nil
end

local function FindAnyContext(contexts, reference)
    if not IsPlainTable(contexts) then
        return nil
    end

    local selected
    local selectedKey
    for key, entry in pairs(contexts) do
        if
            IsPlainTable(entry)
            and entry.SyncId == reference.SyncId
            and entry.Revision == reference.Revision
            and entry.RevisionId == reference.RevisionId
            and entry.ContextRevisionId == reference.ContextRevisionId
            and (
                selected == nil
                or entry.ReceivedAt > selected.ReceivedAt
                or (entry.ReceivedAt == selected.ReceivedAt and key < selectedKey)
            )
        then
            selected = entry
            selectedKey = key
        end
    end
    return selected
end

local function PayloadFromContext(entry)
    if not IsPlainTable(entry) then
        return nil
    end
    return {
        Page = Clone(entry.Page),
        AncestorVariableLayers = Clone(entry.AncestorVariableLayers),
        ContextRevisionId = entry.ContextRevisionId,
    }
end

local function ContextBaseMatchesPage(entry, page)
    if not IsPlainTable(entry) or not IsPlainTable(entry.Page) or not IsPlainTable(page) then
        return false
    end
    for _, field in ipairs({
        "SyncId",
        "OwnerId",
        "Revision",
        "RevisionId",
        "UpdatedAt",
        "UpdatedBy",
    }) do
        if rawget(entry.Page, field) ~= rawget(page, field) then
            return false
        end
    end
    return true
end

local function FindAuthoritativeContext(self, page, hashCallback)
    if not IsPlainTable(self._activePageContexts) then
        return nil
    end

    local selected
    local selectedKey
    local selectedPayload
    for key, entry in pairs(self._activePageContexts) do
        if
            type(key) == "string"
            and ContextBaseMatchesPage(entry, page)
            and IsInteger(entry.ReceivedAt, 0, schema.LIMITS.Timestamp)
        then
            local payload = PayloadFromContext(entry)
            local valid, _, safePayload = activePage.ValidatePageUpsertPayload(payload, hashCallback)
            if valid and ContextIsNewer(entry, key, selected, selectedKey) then
                selected = entry
                selectedKey = key
                selectedPayload = safePayload
            end
        end
    end
    if not selected then
        return nil
    end
    return selected, selectedPayload
end

local function BuildNextContexts(current, auth, payload, activeReference, pendingDisplay)
    if current ~= nil and not IsPlainTable(current) then
        return nil, "invalid-active-page-context-cache"
    end
    local nextContexts = ShallowCopy(current or {})
    local entry = BuildContextEntry(auth, payload)
    local incomingKey = ContextKey(auth.Sender, auth.SenderInstallationId, auth.SenderSessionId, entry)
    nextContexts[incomingKey] = entry

    local protected = {
        [incomingKey] = true,
    }
    local activeKey = ContextKeyForReference(activeReference)
    if activeKey then
        protected[activeKey] = true
    end
    if IsPlainTable(pendingDisplay) and IsPlainTable(pendingDisplay.Payload) then
        local pendingKey = ContextKeyForReference({
            Sender = pendingDisplay.Sender,
            SenderInstallationId = pendingDisplay.SenderInstallationId,
            SenderSessionId = pendingDisplay.SenderSessionId,
            SyncId = pendingDisplay.Payload.SyncId,
            Revision = pendingDisplay.Payload.Revision,
            RevisionId = pendingDisplay.Payload.RevisionId,
            ContextRevisionId = pendingDisplay.Payload.ContextRevisionId,
        })
        if pendingKey then
            protected[pendingKey] = true
        end
    end

    local count = 0
    for _ in pairs(nextContexts) do
        count = count + 1
    end
    while count > MAX_CONTEXT_ENTRIES do
        local evictionKey
        local evictionEntry
        for key, candidate in pairs(nextContexts) do
            if
                not protected[key]
                and IsPlainTable(candidate)
                and ContextIsOlder(candidate, key, evictionEntry, evictionKey)
            then
                evictionKey = key
                evictionEntry = candidate
            end
        end
        if not evictionKey then
            return nil, "active-page-context-cache-full"
        end
        nextContexts[evictionKey] = nil
        count = count - 1
    end
    return nextContexts
end

local function ContextMatches(entry, auth, reference)
    return IsPlainTable(entry)
        and entry.SyncId == reference.SyncId
        and entry.Revision == reference.Revision
        and entry.RevisionId == reference.RevisionId
        and entry.ContextRevisionId == reference.ContextRevisionId
        and entry.Sender == auth.Sender
        and entry.SenderInstallationId == auth.SenderInstallationId
        and entry.SenderSessionId == auth.SenderSessionId
end

local function ReferenceFromPayload(payload)
    return {
        SyncId = payload.SyncId,
        Revision = payload.Revision,
        RevisionId = payload.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
end

local function ReferenceFromUpsert(payload)
    return {
        SyncId = payload.Page.SyncId,
        Revision = payload.Page.Revision,
        RevisionId = payload.Page.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
    }
end

local function SameReference(left, right)
    return IsPlainTable(left)
        and IsPlainTable(right)
        and left.SyncId == right.SyncId
        and left.Revision == right.Revision
        and left.RevisionId == right.RevisionId
        and left.ContextRevisionId == right.ContextRevisionId
        and left.Sender == right.Sender
        and left.SenderInstallationId == right.SenderInstallationId
        and left.SenderSessionId == right.SenderSessionId
end

local function PendingMatchesReference(pending, auth, reference)
    return IsPlainTable(pending)
        and IsPlainTable(pending.Payload)
        and pending.Sender == auth.Sender
        and pending.SenderInstallationId == auth.SenderInstallationId
        and pending.SenderSessionId == auth.SenderSessionId
        and pending.Payload.SyncId == reference.SyncId
        and pending.Payload.Revision == reference.Revision
        and pending.Payload.RevisionId == reference.RevisionId
        and pending.Payload.ContextRevisionId == reference.ContextRevisionId
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

local function RefreshAfterPageUpsert(self, summary, sender)
    local refreshed = RefreshTreeWithoutSelectionReload(self)
    if summary.SelectedDirtyConflict and not CallUiMethod(self, "SelectedUpdated", sender) then
        refreshed = false
    end
    if not CallUiMethod(self, "UpdateSelected", false) then
        refreshed = false
    end
    return refreshed and true or false, refreshed and nil or "ui-refresh-failed"
end

local function RefreshAfterDisplay(self, displayed)
    local debugEnabled = IsDebugEnabled(self)
    local startedAt = debugEnabled and PreciseNowMilliseconds() or 0
    local refreshed = RefreshTreeWithoutSelectionReload(self)
    local treeFinishedAt = debugEnabled and PreciseNowMilliseconds() or 0
    if not CallUiMethod(self, "UpdateDisplayed") then
        refreshed = false
    end
    local displayFinishedAt = debugEnabled and PreciseNowMilliseconds() or 0
    if displayed and not CallUiMethod(self, "ShowDisplay") then
        refreshed = false
    end
    if displayed and not CallUiMethod(self, "DisplayUpdateNotification") then
        refreshed = false
    end
    if debugEnabled then
        Trace(
            self,
            "display-render",
            "displayed=%s tree=%dms note=%dms total=%dms success=%s",
            tostring(displayed == true),
            math.max(treeFinishedAt - startedAt, 0),
            math.max(displayFinishedAt - treeFinishedAt, 0),
            math.max(PreciseNowMilliseconds() - startedAt, 0),
            tostring(refreshed == true)
        )
    end
    return refreshed and true or false, refreshed and nil or "ui-refresh-failed"
end

local function InstallIndexes(self, indexes)
    if type(self.InstallSyncIdentityIndexes) == "function" then
        return self:InstallSyncIdentityIndexes(indexes)
    end
    self.entitySyncIndexes = indexes
end

local function CommitPageState(self, capture, nextPages, nextMeta, nextIndexes, nextContexts)
    if not StorageMatches(self, capture) then
        return false, "stale-active-page-state"
    end

    local oldPages = AngryAssign_Pages
    local oldMeta = AngryAssign_Meta
    local oldIndexes = self.entitySyncIndexes
    local oldContexts = self._activePageContexts
    local ok = pcall(function()
        AngryAssign_Pages = nextPages
        AngryAssign_Meta = nextMeta
        InstallIndexes(self, nextIndexes)
        self._activePageContexts = nextContexts
    end)
    if not ok then
        AngryAssign_Pages = oldPages
        AngryAssign_Meta = oldMeta
        self.entitySyncIndexes = oldIndexes
        self._activePageContexts = oldContexts
        return false, "active-page-commit-failed"
    end
    return true
end

local function CommitProposedPageState(self, capture, nextPages, nextIndexes, nextContexts, nextReference)
    if not StorageMatches(self, capture) then
        return false, "stale-active-page-state"
    end

    local oldPages = AngryAssign_Pages
    local oldIndexes = self.entitySyncIndexes
    local oldContexts = self._activePageContexts
    local oldReference = self._activeDisplayReference
    local oldPending = self._activePendingDisplay
    local ok = pcall(function()
        AngryAssign_Pages = nextPages
        InstallIndexes(self, nextIndexes)
        self._activePageContexts = nextContexts
        self._activeDisplayReference = nextReference
        self._activePendingDisplay = nil
    end)
    if not ok then
        AngryAssign_Pages = oldPages
        self.entitySyncIndexes = oldIndexes
        self._activePageContexts = oldContexts
        self._activeDisplayReference = oldReference
        self._activePendingDisplay = oldPending
        return false, "active-page-proposal-commit-failed"
    end
    return true
end

local function CommitDisplayState(self, capture, nextState, nextReference, nextPending)
    if not StorageMatches(self, capture) then
        return false, "stale-active-page-state"
    end

    local oldState = AngryAssign_State
    local oldReference = self._activeDisplayReference
    local oldPending = self._activePendingDisplay
    local ok = pcall(function()
        AngryAssign_State = nextState
        self._activeDisplayReference = nextReference
        self._activePendingDisplay = nextPending
    end)
    if not ok then
        AngryAssign_State = oldState
        self._activeDisplayReference = oldReference
        self._activePendingDisplay = oldPending
        return false, "active-display-commit-failed"
    end
    return true
end

local function CommitReboundDisplayState(self, capture, nextState, nextContexts, nextReference)
    if not StorageMatches(self, capture) then
        return false, "stale-active-page-state"
    end

    local oldState = AngryAssign_State
    local oldContexts = self._activePageContexts
    local oldReference = self._activeDisplayReference
    local oldPending = self._activePendingDisplay
    local ok = pcall(function()
        AngryAssign_State = nextState
        self._activePageContexts = nextContexts
        self._activeDisplayReference = nextReference
        self._activePendingDisplay = nil
    end)
    if not ok then
        AngryAssign_State = oldState
        self._activePageContexts = oldContexts
        self._activeDisplayReference = oldReference
        self._activePendingDisplay = oldPending
        return false, "active-display-commit-failed"
    end
    return true
end

local function CommitContextState(self, capture, nextContexts)
    if not StorageMatches(self, capture) then
        return false, "stale-active-page-state"
    end

    local oldContexts = self._activePageContexts
    local ok = pcall(function()
        self._activePageContexts = nextContexts
    end)
    if not ok then
        self._activePageContexts = oldContexts
        return false, "active-page-context-commit-failed"
    end
    return true
end

local function CommitVolatileDisplayState(self, capture, nextContexts, nextReference, nextPending)
    if not StorageMatches(self, capture) then
        return false, "stale-active-page-state"
    end

    local oldContexts = self._activePageContexts
    local oldReference = self._activeDisplayReference
    local oldPending = self._activePendingDisplay
    local ok = pcall(function()
        self._activePageContexts = nextContexts
        self._activeDisplayReference = nextReference
        self._activePendingDisplay = nextPending
    end)
    if not ok then
        self._activePageContexts = oldContexts
        self._activeDisplayReference = oldReference
        self._activePendingDisplay = oldPending
        return false, "active-display-activation-failed"
    end
    return true
end

local function PreparationOptions(options)
    if options ~= nil then
        if not IsPlainTable(options) then
            return nil, "invalid-page-preparation-options"
        end
        return ShallowCopy(options)
    end

    local updatedBy
    if type(helpers.PlayerFullName) == "function" then
        local ok, name = pcall(helpers.PlayerFullName)
        if ok then
            updatedBy = name
        end
    end
    if type(updatedBy) ~= "string" or updatedBy == "" then
        return nil, "active-page-author-unavailable"
    end
    return {
        UpdatedAt = time(),
        UpdatedBy = updatedBy,
    }
end

local function BuildAncestorDistances(page)
    if not IsPlainTable(AngryAssign_Categories) then
        return nil, "invalid-active-page-records"
    end

    local parentId = rawget(page, "CategoryId")
    if parentId ~= nil and not IsPositiveLocalId(parentId) then
        return nil, "invalid-local-parent-id"
    end

    local distances = {}
    local visited = {}
    local distance = 0
    while parentId ~= nil do
        if visited[parentId] then
            return nil, "cycle"
        end
        visited[parentId] = true
        distance = distance + 1
        if distance > schema.LIMITS.HierarchyDepth then
            return nil, "hierarchy-depth-exceeded"
        end

        local category = rawget(AngryAssign_Categories, parentId)
        if
            not IsPlainTable(category)
            or rawget(category, "Id") ~= parentId
            or not identity.ValidateSyncId(rawget(category, "SyncId"), "category")
        then
            return nil, category and "invalid-active-page-category" or "missing-category"
        end
        if distances[category.SyncId] ~= nil then
            return nil, "duplicate-active-page-sync-id"
        end
        distances[category.SyncId] = distance

        parentId = rawget(category, "CategoryId")
        if parentId ~= nil and not IsPositiveLocalId(parentId) then
            return nil, "invalid-local-parent-id"
        end
    end
    return distances
end

local function ResolveManagedScopeId(page, explicitScopeId)
    if not IsPlainTable(AngryAssign_Meta) or not IsPlainTable(AngryAssign_Meta.SyncScopes) then
        return nil, "invalid-active-page-metadata"
    end
    local ancestorDistances, ancestorError = BuildAncestorDistances(page)
    if not ancestorDistances then
        return nil, ancestorError
    end

    local trustedScopeId
    local trustedDistance
    for scopeId, distance in pairs(ancestorDistances) do
        local scope = rawget(AngryAssign_Meta.SyncScopes, scopeId)
        if scope ~= nil then
            if not IsPlainTable(scope) or type(rawget(scope, "Enabled")) ~= "boolean" then
                return nil, "invalid-active-page-managed-scopes"
            end
            if scope.Enabled and (trustedDistance == nil or distance < trustedDistance) then
                trustedScopeId = scopeId
                trustedDistance = distance
            end
        end
    end

    if explicitScopeId == nil then
        return trustedScopeId
    end
    if not identity.ValidateSyncId(explicitScopeId, "category") or ancestorDistances[explicitScopeId] == nil then
        return nil, "managed-scope-not-ancestor"
    end
    if trustedDistance ~= nil and ancestorDistances[explicitScopeId] > trustedDistance then
        return nil, "managed-scope-boundary-broadened"
    end
    return explicitScopeId
end

local function PageIsLocallyOwned(capture, page)
    local localState = rawget(capture.EntityLocal, page.SyncId)
    if localState ~= nil and not IsPlainTable(localState) then
        return nil, "invalid-active-page-provenance"
    end
    if localState and localState.OwnedLocally ~= nil and type(localState.OwnedLocally) ~= "boolean" then
        return nil, "invalid-active-page-provenance"
    end
    return page.OwnerId == capture.Meta.InstallationId or (localState and localState.OwnedLocally == true) or false
end

local function LocalContextAuth(self, installationId)
    if type(self.GetProtocolSession) ~= "function" then
        return nil, "protocol-session-unavailable"
    end
    local sessionOk, session = pcall(self.GetProtocolSession, self)
    if
        not sessionOk
        or not IsPlainTable(session)
        or session.InstallationId ~= installationId
        or not identity.ValidateInstallationId(session.InstallationId)
        or type(session.SessionId) ~= "string"
    then
        return nil, "protocol-session-unavailable"
    end

    local sender
    if type(helpers.PlayerFullName) == "function" then
        local ok, name = pcall(helpers.PlayerFullName)
        if ok then
            sender = name
        end
    end
    if type(sender) ~= "string" or sender == "" then
        return nil, "active-page-author-unavailable"
    end
    return ValidateAuth({
        Sender = sender,
        SenderInstallationId = session.InstallationId,
        SenderSessionId = session.SessionId,
        ReceivedAt = time(),
    })
end

local function ValidateChangeDesired(desired)
    if not IsPlainTable(desired) then
        return nil, "invalid-page-change-desired"
    end
    for key in pairs(desired) do
        if type(key) ~= "string" or not CHANGE_DESIRED_FIELDS[key] then
            return nil, "page-change-desired-unknown-field"
        end
    end
    for key in pairs(CHANGE_DESIRED_FIELDS) do
        if rawget(desired, key) == nil then
            return nil, "page-change-desired-missing-" .. key
        end
    end
    return {
        Name = desired.Name,
        Vars = desired.Vars,
        Contents = desired.Contents,
    }
end

local function DesiredMatchesPage(desired, page)
    return desired.Name == rawget(page, "Name")
        and desired.Vars == (rawget(page, "Vars") or "")
        and desired.Contents == (rawget(page, "Contents") or "")
end

local function ActiveProposalContext(capture, syncId, hashCallback)
    local indexed = capture.Indexed.BySyncId[syncId]
    if
        not indexed
        or indexed.Kind ~= "page"
        or capture.DisplayedId ~= indexed.Id
        or not IsPlainTable(capture.DisplayReference)
        or capture.DisplayReference.SyncId ~= syncId
        or capture.PendingDisplay ~= nil
    then
        return nil, nil, "page-change-unavailable"
    end

    local context = FindContext(capture.Contexts, capture.DisplayReference, capture.DisplayReference)
    local payload = PayloadFromContext(context)
    if not payload then
        return nil, nil, "page-change-context-unavailable"
    end
    local valid, validationError, safePayload = activePage.ValidatePageUpsertPayload(payload, hashCallback)
    if not valid then
        return nil, nil, validationError
    end
    if
        safePayload.Page.SyncId ~= syncId
        or not StoredPageMatchesWire(indexed.Record, safePayload.Page)
        or safePayload.Page.Revision ~= capture.DisplayReference.Revision
        or safePayload.Page.RevisionId ~= capture.DisplayReference.RevisionId
        or safePayload.ContextRevisionId ~= capture.DisplayReference.ContextRevisionId
    then
        return nil, nil, "stale-page-change-context"
    end
    return indexed, safePayload
end

local function BuildChangeProposalResult(status, syncId, indexed, pageUpsert)
    local result = {
        Status = status,
        LocalId = indexed and indexed.Id or nil,
        SyncId = syncId,
        Applied = status == "applied",
    }
    if pageUpsert then
        result.Revision = pageUpsert.Page.Revision
        result.RevisionId = pageUpsert.Page.RevisionId
        result.ContextRevisionId = pageUpsert.ContextRevisionId
        result.PageUpsertPayload = Clone(pageUpsert)
    end
    return result
end

local function IsLocalProposalAuthority(self)
    if type(self.IsPlayerRaidLeader) ~= "function" then
        return false
    end
    local ok, isLeader = pcall(self.IsPlayerRaidLeader, self)
    return ok and isLeader == true and CanPublish(self, "pageUpsert")
end

--- Builds a detached CHANGE_PROPOSE payload for the exact active display tuple.
-- `desired` is a strict full desired page state containing only `Name`, `Vars`,
-- and `Contents`. Canonical page storage and revision metadata are never
-- modified by this operation.
-- @tparam number pageId Local page identifier currently displayed.
-- @tparam table desired Full desired synchronized page fields.
-- @treturn table|nil proposal Detached CHANGE_PROPOSE payload.
-- @treturn string|nil errorCode
function AngryEra:BuildActivePageChangeProposal(pageId, desired)
    if not CanPublish(self, "changeProposal") then
        return nil, "local-change-proposal-not-authorized"
    end
    if not IsPositiveLocalId(pageId) then
        return nil, "invalid-local-page-id"
    end
    local safeDesired, desiredError = ValidateChangeDesired(desired)
    if not safeDesired then
        return nil, desiredError
    end

    local hashCallback, hashError = GetHashCallback(self)
    if not hashCallback then
        return nil, hashError
    end
    local capture, captureError = CaptureStorage(self)
    if not capture then
        return nil, captureError
    end
    local page = rawget(capture.Pages, pageId)
    if not IsPlainTable(page) or rawget(page, "Id") ~= pageId or type(rawget(page, "SyncId")) ~= "string" then
        return nil, "page-change-unavailable"
    end
    local indexed, basePayload, contextError = ActiveProposalContext(capture, page.SyncId, hashCallback)
    if not indexed or indexed.Id ~= pageId then
        return nil, contextError or "page-change-unavailable"
    end

    local proposal = {
        AuthorityInstallationId = capture.DisplayReference.SenderInstallationId,
        AuthoritySessionId = capture.DisplayReference.SenderSessionId,
        SyncId = basePayload.Page.SyncId,
        BaseRevision = basePayload.Page.Revision,
        BaseRevisionId = basePayload.Page.RevisionId,
        BaseContextRevisionId = basePayload.ContextRevisionId,
        Name = safeDesired.Name,
        Vars = safeDesired.Vars,
        Contents = safeDesired.Contents,
    }
    local valid, validationError = protocol.ValidatePayload("CHANGE_PROPOSE", proposal)
    if not valid then
        return nil, validationError
    end
    if not StorageMatches(self, capture) then
        return nil, "stale-active-page-state"
    end
    return proposal
end

local function ApplyPageChangeProposal(self, auth, proposal)
    local safeAuth, authError = ValidateAuth(auth)
    if not safeAuth then
        return false, authError
    end
    if not IsAuthorized(self, safeAuth.Sender, "changeProposal") then
        return false, "unauthorized-change-proposal"
    end
    if not IsLocalProposalAuthority(self) then
        return false, "not-change-proposal-authority"
    end

    local valid, validationError = protocol.ValidatePayload("CHANGE_PROPOSE", proposal)
    if not valid then
        return false, validationError
    end
    local safeProposal = {
        AuthorityInstallationId = proposal.AuthorityInstallationId,
        AuthoritySessionId = proposal.AuthoritySessionId,
        SyncId = proposal.SyncId,
        BaseRevision = proposal.BaseRevision,
        BaseRevisionId = proposal.BaseRevisionId,
        BaseContextRevisionId = proposal.BaseContextRevisionId,
        Name = proposal.Name,
        Vars = proposal.Vars,
        Contents = proposal.Contents,
    }

    local hashCallback, hashError = GetHashCallback(self)
    if not hashCallback then
        return false, hashError
    end
    local capture, captureError = CaptureStorage(self)
    if not capture then
        return false, captureError
    end
    local indexed, currentPayload, contextError = ActiveProposalContext(capture, safeProposal.SyncId, hashCallback)
    if not indexed then
        if contextError == "page-change-unavailable" or contextError == "page-change-context-unavailable" then
            return true, BuildChangeProposalResult("unavailable", safeProposal.SyncId)
        end
        return false, contextError
    end
    if not StorageMatches(self, capture) then
        return false, "stale-active-page-state"
    end
    if not IsAuthorized(self, safeAuth.Sender, "changeProposal") then
        return false, "change-proposal-authorization-changed"
    end
    if not IsLocalProposalAuthority(self) then
        return false, "change-proposal-authority-changed"
    end

    local currentPage = currentPayload.Page
    local desiredMatches = DesiredMatchesPage(safeProposal, currentPage)
    local exactBase = safeProposal.BaseRevision == currentPage.Revision
        and safeProposal.BaseRevisionId == currentPage.RevisionId
        and safeProposal.BaseContextRevisionId == currentPayload.ContextRevisionId
    if not exactBase then
        if desiredMatches then
            return true, BuildChangeProposalResult("unchanged", safeProposal.SyncId, indexed, currentPayload)
        end
        return true, BuildChangeProposalResult("conflict", safeProposal.SyncId, indexed, currentPayload)
    end
    if desiredMatches then
        return true, BuildChangeProposalResult("unchanged", safeProposal.SyncId, indexed, currentPayload)
    end
    if capture.SelectedId == indexed.Id and capture.EditorDirty then
        return true, BuildChangeProposalResult("busy", safeProposal.SyncId, indexed, currentPayload)
    end
    if currentPage.Revision >= schema.LIMITS.Revision then
        return false, "revision-exhausted"
    end

    local nextWire = Clone(currentPage)
    nextWire.Revision = currentPage.Revision + 1
    nextWire.RevisionId = nil
    nextWire.UpdatedAt = safeAuth.ReceivedAt
    nextWire.UpdatedBy = safeAuth.Sender
    nextWire.Name = safeProposal.Name
    nextWire.Vars = safeProposal.Vars
    nextWire.Contents = safeProposal.Contents
    local revisionId, revisionError = schema.BuildEntityRevisionId(nextWire, hashCallback)
    if not revisionId then
        return false, revisionError
    end
    nextWire.RevisionId = revisionId
    local nextPayload, payloadError =
        activePage.BuildPageUpsertPayload(nextWire, currentPayload.AncestorVariableLayers, hashCallback)
    if not nextPayload then
        return false, payloadError
    end

    local existing = indexed.Record
    local localFields, localFieldsError = BuildLocalFields(existing, indexed.Id, safeAuth, nextWire)
    if not localFields then
        return false, localFieldsError
    end
    local materialized, materializeError = revisions.WireToLocal(nextWire, localFields, hashCallback)
    if not materialized then
        return false, materializeError
    end
    local nextPages = ShallowCopy(capture.Pages)
    nextPages[indexed.Id] = materialized
    local nextIndexes
    nextIndexes, _, materializeError = BuildIdentityIndexes(nextPages, capture.Categories)
    if not nextIndexes then
        return false, materializeError
    end

    local localAuth, localAuthError = LocalContextAuth(self, capture.Meta.InstallationId)
    if not localAuth then
        return false, localAuthError
    end
    local nextContexts, nextContextError =
        BuildNextContexts(capture.Contexts, localAuth, nextPayload, capture.DisplayReference, capture.PendingDisplay)
    if not nextContexts then
        return false, nextContextError
    end
    local nextReference = {
        SyncId = nextPayload.Page.SyncId,
        Revision = nextPayload.Page.Revision,
        RevisionId = nextPayload.Page.RevisionId,
        ContextRevisionId = nextPayload.ContextRevisionId,
        Sender = localAuth.Sender,
        SenderInstallationId = localAuth.SenderInstallationId,
        SenderSessionId = localAuth.SenderSessionId,
        ReceivedAt = localAuth.ReceivedAt,
    }

    if not IsAuthorized(self, safeAuth.Sender, "changeProposal") then
        return false, "change-proposal-authorization-changed"
    end
    if not IsLocalProposalAuthority(self) then
        return false, "change-proposal-authority-changed"
    end
    local committed, commitError =
        CommitProposedPageState(self, capture, nextPages, nextIndexes, nextContexts, nextReference)
    if not committed then
        return false, commitError
    end

    local result = BuildChangeProposalResult("applied", safeProposal.SyncId, indexed, nextPayload)
    local called, refreshed, refreshWarning = pcall(RefreshAfterDisplay, self, true)
    result.UIRefreshed = called and refreshed == true
    if not called then
        refreshWarning = "ui-refresh-failed"
    end
    return true, result, result.UIRefreshed and nil or refreshWarning
end

--- Validates and canonically commits one assistant CHANGE_PROPOSE.
-- The exact active base tuple must still be current. The authenticated sender
-- supplies `UpdatedBy`; the proposal cannot alter ownership, placement, or
-- inherited ancestor layers. Valid conflicts and busy/unavailable outcomes are
-- returned as semantic result tables so transport can always send CHANGE_RESULT.
-- @tparam table auth Authenticated proposal sender.
-- @tparam table proposal Strict CHANGE_PROPOSE payload.
-- @treturn boolean accepted
-- @treturn table|string resultOrError
-- @treturn string|nil warning
function AngryEra:ApplyActivePageChangeProposal(auth, proposal)
    if self._activePageCommitInProgress then
        return false, "active-page-apply-in-progress"
    end
    self._activePageCommitInProgress = true
    local called, accepted, result, warning = pcall(ApplyPageChangeProposal, self, auth, proposal)
    self._activePageCommitInProgress = false
    if not called then
        return false, "active-page-runtime-error"
    end
    return accepted, result, warning
end

--- Clears all session-local active-page render, display, and pending references.
-- Persisted pages, metadata, and editor conflict state are intentionally retained.
function AngryEra:ResetActivePageTransientState()
    contextArrivalOrdinal = 0
    self._activePageContexts = {}
    self._activeDisplayReference = nil
    self._activePendingDisplay = nil
end

--- Returns a detached exact-match render context.
-- All four identifiers are required; stale or partial references return nil.
function AngryEra:GetActivePageRenderContext(syncId, revision, revisionId, contextRevisionId)
    local contexts = self._activePageContexts
    local reference = {
        SyncId = syncId,
        Revision = revision,
        RevisionId = revisionId,
        ContextRevisionId = contextRevisionId,
    }
    local activeReference = self._activeDisplayReference
    local entry
    if
        IsPlainTable(activeReference)
        and activeReference.SyncId == syncId
        and activeReference.Revision == revision
        and activeReference.RevisionId == revisionId
        and activeReference.ContextRevisionId == contextRevisionId
    then
        entry = FindContext(contexts, activeReference, reference)
        return entry and Clone(entry) or nil
    end
    entry = FindAnyContext(contexts, reference)
    if not entry then
        return nil
    end
    return Clone(entry)
end

--- Returns a detached active display reference, when one was selected through v3.
function AngryEra:GetActiveDisplayReference()
    return IsPlainTable(self._activeDisplayReference) and Clone(self._activeDisplayReference) or nil
end

--- Returns a detached pending display request generated by a missing tuple.
function AngryEra:GetPendingActiveDisplayRequest()
    return IsPlainTable(self._activePendingDisplay) and Clone(self._activePendingDisplay) or nil
end

local function ResolveAuthoritativeContextPage(pageOrId)
    if
        not IsPlainTable(AngryAssign_Pages)
        or not IsPlainTable(AngryAssign_Meta)
        or not IsPlainTable(AngryAssign_Meta.EntityLocal)
    then
        return nil
    end

    local page
    if type(pageOrId) == "number" then
        page = IsPositiveLocalId(pageOrId) and rawget(AngryAssign_Pages, pageOrId) or nil
    elseif IsPlainTable(pageOrId) then
        page = pageOrId
    end
    if
        not IsPlainTable(page)
        or not identity.ValidateSyncId(rawget(page, "SyncId"), "page")
        or not identity.ValidateInstallationId(rawget(page, "OwnerId"))
    then
        return nil
    end
    return page
end

--- Returns a detached validated retained context for a remote page's current
-- canonical revision. This does not select the page as the active display.
function AngryEra:GetAuthoritativePageRenderContext(pageOrId)
    local page = ResolveAuthoritativeContextPage(pageOrId)
    if not page then
        return nil
    end
    local locallyOwned = PageIsLocallyOwned({
        EntityLocal = AngryAssign_Meta.EntityLocal,
        Meta = AngryAssign_Meta,
    }, page)
    if locallyOwned ~= false then
        return nil
    end

    local hashCallback = GetHashCallback(self)
    if not hashCallback then
        return nil
    end
    local _, payload = FindAuthoritativeContext(self, page, hashCallback)
    return payload and Clone(payload) or nil
end

--- Reports whether a page can be published without reconstructing remote wire
-- hierarchy from receiver-private placement. This function does not mutate
-- SavedVariables or volatile active-page state.
function AngryEra:HasAuthoritativePageContext(pageOrId)
    local page = ResolveAuthoritativeContextPage(pageOrId)
    if not page then
        return false
    end

    local locallyOwned = PageIsLocallyOwned({
        EntityLocal = AngryAssign_Meta.EntityLocal,
        Meta = AngryAssign_Meta,
    }, page)
    if locallyOwned == true then
        return true
    end
    if locallyOwned == nil then
        return false
    end
    return self:GetAuthoritativePageRenderContext(page) ~= nil
end

--- Prepares a canonical local PAGE_UPSERT payload without sending it.
-- Local-owned pages derive hierarchy from local categories. Remote-owned pages
-- retain the exact authoritative hierarchy from their cached base revision.
-- Every successful preparation caches its new exact tuple, but does not select
-- it as the active display.
function AngryEra:PrepareActivePageUpsert(pageId, options)
    if not CanPublish(self, "pageUpsert") then
        return nil, "local-page-publish-not-authorized"
    end
    if not IsPositiveLocalId(pageId) then
        return nil, "invalid-local-page-id"
    end
    local safeOptions, optionsError = PreparationOptions(options)
    if not safeOptions then
        return nil, optionsError
    end
    local hashCallback, hashError = GetHashCallback(self)
    if not hashCallback then
        return nil, hashError
    end

    local capture, captureError = CaptureStorage(self)
    if not capture then
        return nil, captureError
    end
    if capture.Contexts ~= nil and not IsPlainTable(capture.Contexts) then
        return nil, "invalid-active-page-context-cache"
    end
    local page = rawget(capture.Pages, pageId)
    if not IsPlainTable(page) or rawget(page, "Id") ~= pageId then
        return nil, "missing-local-page"
    end
    local locallyOwned, ownershipError = PageIsLocallyOwned(capture, page)
    if locallyOwned == nil then
        return nil, ownershipError
    end
    local localAuth, localAuthError = LocalContextAuth(self, capture.Meta.InstallationId)
    if not localAuth then
        return nil, localAuthError
    end

    local revisionSnapshot = SnapshotRevisionMetadata(page)
    local upsert
    local preparationError
    local preparation
    if locallyOwned then
        local managedScopeId, managedScopeError = ResolveManagedScopeId(page, safeOptions.ManagedScopeId)
        if managedScopeError then
            return nil, managedScopeError
        end
        safeOptions.ManagedScopeId = managedScopeId
        upsert, preparationError, preparation =
            activePage.PrepareLocalPageUpsert(capture.Categories, capture.Pages, pageId, safeOptions, hashCallback)
    else
        local _, basePayload = FindAuthoritativeContext(self, page, hashCallback)
        if not basePayload then
            return nil, "remote-page-context-unavailable"
        end
        upsert, preparationError, preparation =
            activePage.PrepareLocalPageUpsertFromContext(page, basePayload, safeOptions, hashCallback)
    end
    if not upsert then
        return nil, preparationError
    end

    local nextContexts, contextError =
        BuildNextContexts(capture.Contexts, localAuth, upsert, capture.DisplayReference, capture.PendingDisplay)
    if not nextContexts then
        RestorePreparedRevision(page, upsert.Page, revisionSnapshot)
        return nil, contextError
    end
    local committed, commitError = CommitContextState(self, capture, nextContexts)
    if not committed then
        RestorePreparedRevision(page, upsert.Page, revisionSnapshot)
        return nil, commitError
    end
    return upsert, nil, preparation
end

local function CachedActiveUpsertForPage(self, page)
    local reference = self._activeDisplayReference
    if not IsPlainTable(reference) or reference.SyncId ~= page.SyncId then
        return nil
    end
    local context = FindContext(self._activePageContexts, reference, reference)
    if
        not IsPlainTable(context)
        or context.Revision ~= reference.Revision
        or context.RevisionId ~= reference.RevisionId
        or context.ContextRevisionId ~= reference.ContextRevisionId
    then
        return nil
    end
    return {
        Page = Clone(context.Page),
        AncestorVariableLayers = Clone(context.AncestorVariableLayers),
        ContextRevisionId = context.ContextRevisionId,
    }
end

--- Builds a DISPLAY payload and, for a displayed page, its matching PAGE_UPSERT.
-- The caller decides whether to send the upsert proactively. No envelope is
-- created here and request correlation must be supplied by protocol_runtime.
function AngryEra:BuildActiveDisplayPayload(pageId, options)
    if not CanPublish(self, "display") then
        return nil, "local-display-publish-not-authorized"
    end
    if pageId == nil then
        return {
            Displayed = false,
        }
    end
    if not IsPositiveLocalId(pageId) then
        return nil, "invalid-local-page-id"
    end
    if not CanPublish(self, "pageUpsert") then
        return nil, "local-page-publish-not-authorized"
    end

    local page = IsPlainTable(AngryAssign_Pages) and AngryAssign_Pages[pageId] or nil
    if not IsPlainTable(page) then
        return nil, "missing-local-page"
    end
    local upsert, preparationError, preparation = self:PrepareActivePageUpsert(pageId, options)
    if not upsert then
        return nil, preparationError
    end

    return {
        Displayed = true,
        SyncId = upsert.Page.SyncId,
        Revision = upsert.Page.Revision,
        RevisionId = upsert.Page.RevisionId,
        ContextRevisionId = upsert.ContextRevisionId,
    },
        upsert,
        preparation
end

--- Builds a correlated DISPLAY response plan for protocol_runtime.
-- Result shape: `{ Type = "DISPLAY", Payload = <DISPLAY>,
-- PageUpsertPayload = <PAGE_UPSERT>|nil }`. The handler must put the incoming
-- envelope MessageId in the outbound envelope's ReplyTo field.
function AngryEra:BuildActiveDisplayRequestResponse(auth, payload, options)
    local safeAuth, authError = ValidateAuth(auth)
    if not safeAuth then
        return nil, authError
    end
    local valid, validationError = protocol.ValidatePayload("DISPLAY_REQUEST", payload)
    if not valid then
        return nil, validationError
    end
    if not IsAuthorized(self, safeAuth.Sender, "request") then
        return nil, "unauthorized-display-request"
    end
    if type(self.IsPlayerRaidLeader) ~= "function" or self:IsPlayerRaidLeader() ~= true then
        return nil, "not-display-authority"
    end
    if not CanPublish(self, "display") then
        return nil, "local-display-publish-not-authorized"
    end
    if not CanPublish(self, "pageUpsert") then
        return nil, "local-page-publish-not-authorized"
    end

    local displayedId = IsPlainTable(AngryAssign_State) and rawget(AngryAssign_State, "displayed") or nil
    if not IsPositiveLocalId(displayedId) then
        displayedId = nil
    end
    local page = displayedId and IsPlainTable(AngryAssign_Pages) and AngryAssign_Pages[displayedId] or nil
    local pageUpsertPayload = page and CachedActiveUpsertForPage(self, page) or nil
    local displayPayload
    local preparationOrError
    if pageUpsertPayload then
        displayPayload = {
            Displayed = true,
            SyncId = pageUpsertPayload.Page.SyncId,
            Revision = pageUpsertPayload.Page.Revision,
            RevisionId = pageUpsertPayload.Page.RevisionId,
            ContextRevisionId = pageUpsertPayload.ContextRevisionId,
        }
    else
        displayPayload, pageUpsertPayload, preparationOrError = self:BuildActiveDisplayPayload(displayedId, options)
    end
    if not displayPayload then
        return nil, pageUpsertPayload
    end
    return {
        Type = "DISPLAY",
        Payload = displayPayload,
        PageUpsertPayload = pageUpsertPayload,
        Preparation = preparationOrError,
    }
end

--- Builds a correlated PAGE_UPSERT response plan for an exact PAGE_REQUEST.
-- Result shape: `{ Type = "PAGE_UPSERT", Payload = <PAGE_UPSERT> }`.
-- The handler owns envelope ReplyTo correlation and all network transmission.
function AngryEra:BuildActivePageRequestResponse(auth, payload)
    local safeAuth, authError = ValidateAuth(auth)
    if not safeAuth then
        return nil, authError
    end
    local valid, validationError = protocol.ValidatePayload("PAGE_REQUEST", payload)
    if not valid then
        return nil, validationError
    end
    if not IsAuthorized(self, safeAuth.Sender, "request") then
        return nil, "unauthorized-page-request"
    end
    if not CanPublish(self, "pageUpsert") then
        return nil, "local-page-publish-not-authorized"
    end

    local capture, captureError = CaptureStorage(self)
    if not capture then
        return nil, captureError
    end
    local indexed = capture.Indexed.BySyncId[payload.SyncId]
    if not indexed or indexed.Kind ~= "page" then
        return nil, "requested-page-unavailable"
    end

    local cached = FindAnyContext(capture.Contexts, payload)
    if not cached then
        return nil, "requested-page-version-unavailable"
    end
    local upsert = PayloadFromContext(cached)
    local hashCallback, hashError = GetHashCallback(self)
    if not hashCallback then
        return nil, hashError
    end
    local validUpsert, upsertError, safeUpsert = activePage.ValidatePageUpsertPayload(upsert, hashCallback)
    if not validUpsert then
        return nil, upsertError
    end

    local reference = ReferenceFromUpsert(safeUpsert)
    if
        reference.SyncId ~= payload.SyncId
        or reference.Revision ~= payload.Revision
        or reference.RevisionId ~= payload.RevisionId
        or reference.ContextRevisionId ~= payload.ContextRevisionId
    then
        return nil, "requested-page-version-unavailable"
    end
    return {
        Type = "PAGE_UPSERT",
        Payload = safeUpsert,
    }
end

-- A new leader can legitimately select an unchanged page that originated on
-- this installation. Cache only that leader/session's render context so its
-- following DISPLAY can resolve. Any forward canonical revision from that
-- leader may update the local source while preserving local-only fields and
-- retained history, including when this client missed intermediate revisions.
local function AcceptChangedLocalOwnerCommit(self, capture, auth, payload, existingEntry, existing, options)
    local incoming = payload.Page
    local comparable, revisionAction = CompareIncomingRevision(existing, incoming)
    if not comparable then
        if
            options.AuthorityBootstrap
            and (
                revisionAction == "page-revision-rollback"
                or (
                    revisionAction == "page-revision-divergence"
                    and incoming.Revision == existing.Revision
                    and incoming.RevisionId ~= existing.RevisionId
                )
            )
        then
            revisionAction = "replace"
        else
            return false, revisionAction
        end
    end
    if revisionAction ~= "replace" then
        return false, "local-namespace-collision"
    end
    local reference = ReferenceFromUpsert(payload)
    local pendingReady = PendingMatchesReference(capture.PendingDisplay, auth, reference)
    local nextContexts, contextError =
        BuildNextContexts(capture.Contexts, auth, payload, capture.DisplayReference, capture.PendingDisplay)
    if not nextContexts then
        return false, contextError
    end

    local historyAuth = {
        Sender = incoming.UpdatedBy,
        ReceivedAt = auth.ReceivedAt,
    }
    local localFields, localFieldsError = BuildLocalFields(existing, existingEntry.Id, historyAuth, incoming)
    if not localFields then
        return false, localFieldsError
    end
    local hashCallback, hashError = GetHashCallback(self)
    if not hashCallback then
        return false, hashError
    end
    local materialized, materializeError = revisions.WireToLocal(incoming, localFields, hashCallback)
    if not materialized then
        return false, materializeError
    end
    local nextPages = ShallowCopy(capture.Pages)
    nextPages[existingEntry.Id] = materialized
    local nextIndexes
    nextIndexes, _, materializeError = BuildIdentityIndexes(nextPages, capture.Categories)
    if not nextIndexes then
        return false, materializeError
    end

    local existingSnapshot = SnapshotFields(existing)
    local existingHistorySnapshot = Clone(rawget(existing, "History"))
    if not IsAuthorized(self, auth.Sender, "pageUpsert") then
        return false, "page-upsert-authorization-changed"
    end
    if not IsCurrentDisplayAuthority(self, auth.Sender) then
        return false, "display-authority-changed"
    end
    if
        not FieldsMatch(existing, existingSnapshot)
        or not DeepEqual(rawget(existing, "History"), existingHistorySnapshot)
    then
        return false, "stale-active-page-state"
    end
    local committed, commitError = CommitPageState(self, capture, nextPages, capture.Meta, nextIndexes, nextContexts)
    if not committed then
        return false, commitError
    end

    local selectedDirtyConflict
    if capture.SelectedId == existingEntry.Id and capture.EditorDirty then
        selectedDirtyConflict = {
            SyncId = incoming.SyncId,
            LocalRevisionId = existing.RevisionId,
            IncomingRevisionId = incoming.RevisionId,
            Sender = auth.Sender,
            ReceivedAt = auth.ReceivedAt,
        }
        self.syncDraftConflict = Clone(selectedDirtyConflict)
    end
    local summary = {
        Applied = true,
        NoOp = false,
        Created = false,
        LocalOwnerCanonical = true,
        LocalId = existingEntry.Id,
        SyncId = incoming.SyncId,
        RevisionId = incoming.RevisionId,
        ContextRevisionId = payload.ContextRevisionId,
        ContextUpdated = true,
        SelectedDirtyConflict = selectedDirtyConflict,
        PendingDisplayReady = pendingReady,
        PendingDisplayPayload = pendingReady and Clone(capture.PendingDisplay.Payload) or nil,
        UIRefreshed = false,
    }
    local called, refreshed, warning = pcall(RefreshAfterPageUpsert, self, summary, auth.Sender)
    summary.UIRefreshed = called and refreshed == true
    if not called then
        warning = "ui-refresh-failed"
    end
    return true, summary, summary.UIRefreshed and nil or warning
end

local function AcceptLocalOwnerRelayContext(self, capture, auth, payload, options)
    local incoming = payload.Page
    if not IsCurrentDisplayAuthority(self, auth.Sender) then
        return false, "local-namespace-collision"
    end

    local existingEntry = capture.Indexed.BySyncId[incoming.SyncId]
    local existing = existingEntry and existingEntry.Kind == "page" and existingEntry.Record or nil
    local localState = rawget(capture.EntityLocal, incoming.SyncId)
    if
        not IsPlainTable(existing)
        or rawget(existing, "OwnerId") ~= capture.Meta.InstallationId
        or not IsPlainTable(localState)
        or rawget(localState, "OwnedLocally") ~= true
    then
        return false, "local-namespace-collision"
    end
    if not StoredPageMatchesWire(existing, incoming) then
        return AcceptChangedLocalOwnerCommit(self, capture, auth, payload, existingEntry, existing, options)
    end

    local reference = ReferenceFromUpsert(payload)
    local pendingReady = PendingMatchesReference(capture.PendingDisplay, auth, reference)
    local nextContexts, contextError =
        BuildNextContexts(capture.Contexts, auth, payload, capture.DisplayReference, capture.PendingDisplay)
    if not nextContexts then
        return false, contextError
    end

    local existingSnapshot = SnapshotFields(existing)
    if not IsAuthorized(self, auth.Sender, "pageUpsert") then
        return false, "page-upsert-authorization-changed"
    end
    if
        not IsCurrentDisplayAuthority(self, auth.Sender)
        or not FieldsMatch(existing, existingSnapshot)
        or not StoredPageMatchesWire(existing, incoming)
    then
        return false, "local-namespace-collision"
    end
    local committed, commitError = CommitContextState(self, capture, nextContexts)
    if not committed then
        return false, commitError
    end

    return true,
        {
            Applied = false,
            NoOp = false,
            ContextOnly = true,
            Created = false,
            LocalOwnerRelay = true,
            LocalId = existingEntry.Id,
            SyncId = incoming.SyncId,
            RevisionId = incoming.RevisionId,
            ContextRevisionId = payload.ContextRevisionId,
            ContextUpdated = true,
            PendingDisplayReady = pendingReady,
            PendingDisplayPayload = pendingReady and Clone(capture.PendingDisplay.Payload) or nil,
            UIRefreshed = false,
        }
end

local function AcceptPageUpsert(self, auth, payload, options)
    local safeOptions, optionsError = ValidateAcceptOptions(options)
    if not safeOptions then
        return false, optionsError
    end
    local safeAuth, authError = ValidateAuth(auth)
    if not safeAuth then
        return false, authError
    end
    if not IsAuthorized(self, safeAuth.Sender, "pageUpsert") then
        return false, "unauthorized-page-upsert"
    end

    local hashCallback, hashError = GetHashCallback(self)
    if not hashCallback then
        return false, hashError
    end
    local valid, validationError, safePayload = activePage.ValidatePageUpsertPayload(payload, hashCallback)
    if not valid then
        return false, validationError
    end

    local capture, captureError = CaptureStorage(self)
    if not capture then
        return false, captureError
    end
    local incoming = safePayload.Page
    if incoming.OwnerId == capture.Meta.InstallationId then
        return AcceptLocalOwnerRelayContext(self, capture, safeAuth, safePayload, safeOptions)
    end

    local existingEntry = capture.Indexed.BySyncId[incoming.SyncId]
    if existingEntry and existingEntry.Kind ~= "page" then
        return false, "active-page-kind-collision"
    end
    local existing = existingEntry and existingEntry.Record or nil
    if existing and existing.OwnerId ~= incoming.OwnerId then
        return false, "active-page-owner-collision"
    end
    local localState = rawget(capture.EntityLocal, incoming.SyncId)
    if localState ~= nil and not IsPlainTable(localState) then
        return false, "invalid-active-page-provenance"
    end
    if IsPlainTable(localState) and localState.OwnedLocally == true then
        return false, "locally-owned-collision"
    end

    local reference = ReferenceFromUpsert(safePayload)
    local pendingReady = PendingMatchesReference(capture.PendingDisplay, safeAuth, reference)
    local revisionAction = "replace"
    local contextOnly = false
    if existing then
        local comparable, actionOrError = CompareIncomingRevision(existing, incoming)
        if not comparable then
            if
                safeOptions.AuthorityBootstrap
                and (
                    actionOrError == "page-revision-rollback"
                    or (
                        actionOrError == "page-revision-divergence"
                        and incoming.Revision == existing.Revision
                        and incoming.RevisionId ~= existing.RevisionId
                    )
                )
            then
                revisionAction = "replace"
            elseif
                actionOrError == "page-revision-rollback"
                and safeOptions.CorrelatedReply
                and existing.Revision == incoming.Revision + 1
                and pendingReady
            then
                contextOnly = true
                revisionAction = "context-only"
            else
                return false, actionOrError
            end
        else
            revisionAction = actionOrError
        end
    end

    local localId = existingEntry and existingEntry.Id or AllocatePageId(capture.Indexed.UsedIds.page)
    if not localId then
        return false, "local-page-id-space-exhausted"
    end
    local nextContexts, contextError =
        BuildNextContexts(capture.Contexts, safeAuth, safePayload, capture.DisplayReference, capture.PendingDisplay)
    if not nextContexts then
        return false, contextError
    end

    local existingSnapshot = existing and SnapshotFields(existing) or nil
    local existingHistorySnapshot = existing and revisionAction == "replace" and Clone(rawget(existing, "History"))
        or nil
    if contextOnly then
        if not IsAuthorized(self, safeAuth.Sender, "pageUpsert") then
            return false, "page-upsert-authorization-changed"
        end
        if existing and not FieldsMatch(existing, existingSnapshot) then
            return false, "stale-active-page-state"
        end
        local committed, commitError = CommitContextState(self, capture, nextContexts)
        if not committed then
            return false, commitError
        end
        return true,
            {
                Applied = false,
                NoOp = false,
                ContextOnly = true,
                Created = false,
                LocalId = localId,
                SyncId = incoming.SyncId,
                RevisionId = incoming.RevisionId,
                ContextRevisionId = safePayload.ContextRevisionId,
                ContextUpdated = true,
                PendingDisplayReady = true,
                PendingDisplayPayload = Clone(capture.PendingDisplay.Payload),
                UIRefreshed = false,
            }
    end

    local nextPages = capture.Pages
    local nextMeta = capture.Meta
    local nextIndexes = capture.Indexes
    local applied = revisionAction ~= "unchanged"
    local created = existing == nil
    if applied then
        local historyAuth = {
            Sender = incoming.UpdatedBy,
            ReceivedAt = safeAuth.ReceivedAt,
        }
        local localFields, localFieldsError = BuildLocalFields(existing, localId, historyAuth, incoming)
        if not localFields then
            return false, localFieldsError
        end
        local materialized, materializeError = revisions.WireToLocal(incoming, localFields, hashCallback)
        if not materialized then
            return false, materializeError
        end

        nextPages = ShallowCopy(capture.Pages)
        nextPages[localId] = materialized
        nextMeta, materializeError = BuildNextMeta(capture, incoming.SyncId)
        if not nextMeta then
            return false, materializeError
        end
        nextIndexes, _, materializeError = BuildIdentityIndexes(nextPages, capture.Categories)
        if not nextIndexes then
            return false, materializeError
        end
    end

    if not IsAuthorized(self, safeAuth.Sender, "pageUpsert") then
        return false, "page-upsert-authorization-changed"
    end
    if
        existing
        and (
            not FieldsMatch(existing, existingSnapshot)
            or (applied and not DeepEqual(rawget(existing, "History"), existingHistorySnapshot))
        )
    then
        return false, "stale-active-page-state"
    end
    local committed, commitError = CommitPageState(self, capture, nextPages, nextMeta, nextIndexes, nextContexts)
    if not committed then
        return false, commitError
    end

    local selectedDirtyConflict
    if
        applied
        and capture.SelectedId == localId
        and capture.EditorDirty
        and (not existing or existing.RevisionId ~= incoming.RevisionId)
    then
        selectedDirtyConflict = {
            SyncId = incoming.SyncId,
            LocalRevisionId = existing and existing.RevisionId or nil,
            IncomingRevisionId = incoming.RevisionId,
            Sender = safeAuth.Sender,
            ReceivedAt = safeAuth.ReceivedAt,
        }
        self.syncDraftConflict = Clone(selectedDirtyConflict)
    end

    local pending = capture.PendingDisplay

    local summary = {
        Applied = applied,
        NoOp = not applied,
        Created = created,
        LocalId = localId,
        SyncId = incoming.SyncId,
        RevisionId = incoming.RevisionId,
        ContextRevisionId = safePayload.ContextRevisionId,
        ContextUpdated = true,
        SelectedDirtyConflict = selectedDirtyConflict,
        PendingDisplayReady = pendingReady,
        PendingDisplayPayload = pendingReady and Clone(pending.Payload) or nil,
        UIRefreshed = false,
    }

    if not applied then
        return true, summary
    end
    local refreshOk, refreshWarning
    local called, refreshed, warning = pcall(RefreshAfterPageUpsert, self, summary, safeAuth.Sender)
    if called then
        refreshOk = refreshed
        refreshWarning = warning
    else
        refreshOk = false
        refreshWarning = "ui-refresh-failed"
    end
    summary.UIRefreshed = refreshOk == true
    return true, summary, refreshOk and nil or refreshWarning
end

--- Validates, reauthorizes, and atomically installs one PAGE_UPSERT.
-- Page ownership metadata is validated against SyncId but is not treated as a
-- credential. The authenticated envelope installation/session instead binds the
-- volatile render context and any later DISPLAY that consumes it.
function AngryEra:AcceptActivePageUpsert(auth, payload, options)
    if self._activePageCommitInProgress then
        return false, "active-page-apply-in-progress"
    end
    self._activePageCommitInProgress = true
    local called, accepted, result, warning = pcall(AcceptPageUpsert, self, auth, payload, options)
    self._activePageCommitInProgress = false
    if not called then
        return false, "active-page-runtime-error"
    end
    return accepted, result, warning
end

local function PendingDisplay(auth, payload)
    return {
        Sender = auth.Sender,
        SenderInstallationId = auth.SenderInstallationId,
        SenderSessionId = auth.SenderSessionId,
        ReceivedAt = auth.ReceivedAt,
        Payload = Clone(payload),
    }
end

-- A leadership handoff may leave the exact immutable page/context tuple cached
-- under the former publisher's sender/session. The current leader may rebind
-- that already validated tuple for display only; changed or unknown tuples
-- still require PAGE_UPSERT and take the pending request path.
local function BuildReboundDisplayContexts(self, capture, auth, reference)
    if not IsCurrentDisplayAuthority(self, auth.Sender) then
        return nil
    end

    local cached = FindAnyContext(capture.Contexts, reference)
    local cachedPayload = PayloadFromContext(cached)
    if not cachedPayload then
        return nil
    end

    local hashCallback = GetHashCallback(self)
    if not hashCallback then
        return nil
    end
    local valid, _, safePayload = activePage.ValidatePageUpsertPayload(cachedPayload, hashCallback)
    if not valid then
        return nil
    end

    local safeReference = ReferenceFromUpsert(safePayload)
    if
        safeReference.SyncId ~= reference.SyncId
        or safeReference.Revision ~= reference.Revision
        or safeReference.RevisionId ~= reference.RevisionId
        or safeReference.ContextRevisionId ~= reference.ContextRevisionId
    then
        return nil
    end

    return BuildNextContexts(capture.Contexts, auth, safePayload, capture.DisplayReference, capture.PendingDisplay)
end

local function ActivatePreparedDisplay(self, displayPayload, pageUpsert)
    local capture, captureError = CaptureStorage(self)
    if not capture then
        return false, captureError
    end
    local localAuth, authError = LocalContextAuth(self, capture.Meta.InstallationId)
    if not localAuth then
        return false, authError
    end

    local validDisplay, displayError = protocol.ValidatePayload("DISPLAY", displayPayload)
    if not validDisplay then
        return false, displayError
    end
    if displayPayload.Displayed ~= true then
        return false, "active-display-not-displayed"
    end

    local hashCallback, hashError = GetHashCallback(self)
    if not hashCallback then
        return false, hashError
    end
    local validUpsert, upsertError, safeUpsert = activePage.ValidatePageUpsertPayload(pageUpsert, hashCallback)
    if not validUpsert then
        return false, upsertError
    end

    local displayReference = ReferenceFromPayload(displayPayload)
    local upsertReference = ReferenceFromUpsert(safeUpsert)
    if
        displayReference.SyncId ~= upsertReference.SyncId
        or displayReference.Revision ~= upsertReference.Revision
        or displayReference.RevisionId ~= upsertReference.RevisionId
        or displayReference.ContextRevisionId ~= upsertReference.ContextRevisionId
    then
        return false, "active-display-page-tuple-mismatch"
    end

    local indexed = capture.Indexed.BySyncId[displayReference.SyncId]
    if not indexed or indexed.Kind ~= "page" or not StoredPageMatchesWire(indexed.Record, safeUpsert.Page) then
        return false, "prepared-active-page-unavailable"
    end

    local nextContexts, contextError =
        BuildNextContexts(capture.Contexts, localAuth, safeUpsert, capture.DisplayReference, capture.PendingDisplay)
    if not nextContexts then
        return false, contextError
    end
    local nextReference = {
        SyncId = displayReference.SyncId,
        Revision = displayReference.Revision,
        RevisionId = displayReference.RevisionId,
        ContextRevisionId = displayReference.ContextRevisionId,
        Sender = localAuth.Sender,
        SenderInstallationId = localAuth.SenderInstallationId,
        SenderSessionId = localAuth.SenderSessionId,
        ReceivedAt = localAuth.ReceivedAt,
    }
    local currentContext = FindContext(capture.Contexts, localAuth, displayReference)
    local noOp = SameReference(capture.DisplayReference, nextReference)
        and capture.PendingDisplay == nil
        and ContextMatches(currentContext, localAuth, displayReference)
    if noOp then
        return true,
            {
                Applied = false,
                NoOp = true,
                Displayed = true,
                LocalId = indexed.Id,
                SyncId = displayReference.SyncId,
                RevisionId = displayReference.RevisionId,
                ContextRevisionId = displayReference.ContextRevisionId,
            }
    end

    local committed, commitError = CommitVolatileDisplayState(self, capture, nextContexts, nextReference, nil)
    if not committed then
        return false, commitError
    end
    return true,
        {
            Applied = true,
            NoOp = false,
            Displayed = true,
            LocalId = indexed.Id,
            SyncId = displayReference.SyncId,
            RevisionId = displayReference.RevisionId,
            ContextRevisionId = displayReference.ContextRevisionId,
        }
end

--- Activates an already prepared local display tuple without changing the
-- persisted display/editor selection. Transport success is intentionally not
-- part of this operation.
function AngryEra:ActivatePreparedActiveDisplay(displayPayload, pageUpsert)
    if self._activeDisplayActivationInProgress then
        return false, "active-display-activation-in-progress"
    end
    self._activeDisplayActivationInProgress = true
    local called, activated, result = pcall(ActivatePreparedDisplay, self, displayPayload, pageUpsert)
    self._activeDisplayActivationInProgress = false
    if not called then
        return false, "active-page-runtime-error"
    end
    return activated, result
end

--- Clears only volatile active/pending references. Exact cached contexts remain
-- available for request responses and future remote-owned edits.
function AngryEra:ClearActiveDisplayReference()
    if self._activeDisplayReference == nil and self._activePendingDisplay == nil then
        return true, {
            Applied = false,
            NoOp = true,
            Displayed = false,
        }
    end

    local oldReference = self._activeDisplayReference
    local oldPending = self._activePendingDisplay
    local ok = pcall(function()
        self._activeDisplayReference = nil
        self._activePendingDisplay = nil
    end)
    if not ok then
        self._activeDisplayReference = oldReference
        self._activePendingDisplay = oldPending
        return false, "active-display-clear-failed"
    end
    return true, {
        Applied = true,
        NoOp = false,
        Displayed = false,
    }
end

local function AcceptDisplay(self, auth, payload)
    local safeAuth, authError = ValidateAuth(auth)
    if not safeAuth then
        return false, authError
    end
    if not IsAuthorized(self, safeAuth.Sender, "display") then
        return false, "unauthorized-display"
    end
    local valid, validationError = protocol.ValidatePayload("DISPLAY", payload)
    if not valid then
        return false, validationError
    end

    local capture, captureError = CaptureStorage(self)
    if not capture then
        return false, captureError
    end

    if payload.Displayed then
        local reference = ReferenceFromPayload(payload)
        local entry = FindContext(capture.Contexts, safeAuth, reference)
        local indexed = capture.Indexed.BySyncId[reference.SyncId]
        local available = indexed and indexed.Kind == "page" and ContextMatches(entry, safeAuth, reference)
        local reboundContexts

        if not available and indexed and indexed.Kind == "page" then
            local reboundError
            reboundContexts, reboundError = BuildReboundDisplayContexts(self, capture, safeAuth, reference)
            if reboundError then
                return false, reboundError
            end
            if reboundContexts then
                entry = FindContext(reboundContexts, safeAuth, reference)
                available = ContextMatches(entry, safeAuth, reference)
            end
        end

        if not available then
            if not IsAuthorized(self, safeAuth.Sender, "display") then
                return false, "display-authorization-changed"
            end
            local pending = PendingDisplay(safeAuth, payload)
            if not StorageMatches(self, capture) then
                return false, "stale-active-page-state"
            end
            self._activePendingDisplay = pending
            return true,
                {
                    Applied = false,
                    NoOp = false,
                    Displayed = true,
                    RequestNeeded = true,
                    RequestPayload = Clone(reference),
                    SyncId = reference.SyncId,
                    RevisionId = reference.RevisionId,
                    ContextRevisionId = reference.ContextRevisionId,
                    UIRefreshed = false,
                }
        end

        local nextReference = {
            SyncId = reference.SyncId,
            Revision = reference.Revision,
            RevisionId = reference.RevisionId,
            ContextRevisionId = reference.ContextRevisionId,
            Sender = safeAuth.Sender,
            SenderInstallationId = safeAuth.SenderInstallationId,
            SenderSessionId = safeAuth.SenderSessionId,
            ReceivedAt = safeAuth.ReceivedAt,
        }
        if
            capture.DisplayedId == indexed.Id
            and SameReference(capture.DisplayReference, nextReference)
            and capture.PendingDisplay == nil
        then
            return true,
                {
                    Applied = false,
                    NoOp = true,
                    Displayed = true,
                    RequestNeeded = false,
                    LocalId = indexed.Id,
                    SyncId = reference.SyncId,
                    RevisionId = reference.RevisionId,
                    ContextRevisionId = reference.ContextRevisionId,
                    UIRefreshed = false,
                }
        end

        local nextState = ShallowCopy(capture.State)
        nextState.displayed = indexed.Id
        if reboundContexts and not IsCurrentDisplayAuthority(self, safeAuth.Sender) then
            return false, "display-authorization-changed"
        elseif not reboundContexts and not IsAuthorized(self, safeAuth.Sender, "display") then
            return false, "display-authorization-changed"
        end
        local committed
        local commitError
        if reboundContexts then
            committed, commitError = CommitReboundDisplayState(self, capture, nextState, reboundContexts, nextReference)
        else
            committed, commitError = CommitDisplayState(self, capture, nextState, nextReference, nil)
        end
        if not committed then
            return false, commitError
        end

        local summary = {
            Applied = true,
            NoOp = false,
            Displayed = true,
            RequestNeeded = false,
            LocalId = indexed.Id,
            SyncId = reference.SyncId,
            RevisionId = reference.RevisionId,
            ContextRevisionId = reference.ContextRevisionId,
            ContextRebound = reboundContexts ~= nil,
            UIRefreshed = false,
        }
        local refreshOk, refreshWarning
        local called, refreshed, warning = pcall(RefreshAfterDisplay, self, true)
        if called then
            refreshOk = refreshed
            refreshWarning = warning
        else
            refreshOk = false
            refreshWarning = "ui-refresh-failed"
        end
        summary.UIRefreshed = refreshOk == true
        return true, summary, refreshOk and nil or refreshWarning
    end

    if capture.DisplayedId == nil and capture.DisplayReference == nil and capture.PendingDisplay == nil then
        return true,
            {
                Applied = false,
                NoOp = true,
                Displayed = false,
                RequestNeeded = false,
                UIRefreshed = false,
            }
    end

    local nextState = ShallowCopy(capture.State)
    nextState.displayed = nil
    if not IsAuthorized(self, safeAuth.Sender, "display") then
        return false, "display-authorization-changed"
    end
    local committed, commitError = CommitDisplayState(self, capture, nextState, nil, nil)
    if not committed then
        return false, commitError
    end

    local summary = {
        Applied = true,
        NoOp = false,
        Displayed = false,
        RequestNeeded = false,
        UIRefreshed = false,
    }
    local refreshOk, refreshWarning
    local called, refreshed, warning = pcall(RefreshAfterDisplay, self, false)
    if called then
        refreshOk = refreshed
        refreshWarning = warning
    else
        refreshOk = false
        refreshWarning = "ui-refresh-failed"
    end
    summary.UIRefreshed = refreshOk == true
    return true, summary, refreshOk and nil or refreshWarning
end

--- Applies one authenticated DISPLAY without sending follow-up traffic.
-- If the exact page/context tuple is unavailable, the accepted result contains
-- `RequestNeeded=true` and an exact `RequestPayload` for PAGE_REQUEST. The
-- protocol handler decides whether and where to send that request.
function AngryEra:AcceptActiveDisplay(auth, payload)
    if self._activeDisplayCommitInProgress then
        return false, "active-display-apply-in-progress"
    end
    self._activeDisplayCommitInProgress = true
    local called, accepted, result, warning = pcall(AcceptDisplay, self, auth, payload)
    self._activeDisplayCommitInProgress = false
    if not called then
        return false, "active-page-runtime-error"
    end
    return accepted, result, warning
end

pageRuntime.ValidateAuth = ValidateAuth
pageRuntime.BuildIdentityIndexes = BuildIdentityIndexes
