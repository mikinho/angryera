-- -------------------------------------------------------------------------------
-- Angry Era: modules/entities.lua
--
-- Entity identity migration, construction, lookup, and removal.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local identity = AngryEra.identity

local ENTITY_SCHEMA_VERSION = 2
local IDENTITY_FIELDS = {
    "SyncId",
    "OwnerId",
    "Revision",
    "RevisionId",
    "UpdatedAt",
    "UpdatedBy",
}

local function GetRecords(kind)
    if kind == "page" then
        return AngryAssign_Pages
    end
    return AngryAssign_Categories
end

local function CopyRecord(fields)
    local record = {}
    for key, value in pairs(fields or {}) do
        record[key] = value
    end
    return record
end

local function SortRecordEntries(records)
    local entries = {}
    for id, record in pairs(records) do
        table.insert(entries, { Id = id, Record = record })
    end
    table.sort(entries, function(a, b)
        if type(a.Id) == "number" and type(b.Id) == "number" then
            return a.Id < b.Id
        end
        return tostring(a.Id) < tostring(b.Id)
    end)
    return entries
end

local function EnsureLocalState(meta, syncId, ownedLocally)
    local state = meta.EntityLocal[syncId]
    if type(state) ~= "table" then
        state = {}
        meta.EntityLocal[syncId] = state
    end
    if ownedLocally ~= nil then
        state.OwnedLocally = ownedLocally
    elseif state.OwnedLocally == nil then
        state.OwnedLocally = false
    end
    if state.Pinned == nil then
        state.Pinned = false
    end
    if type(state.ManagedScopes) ~= "table" then
        state.ManagedScopes = {}
    end
    return state
end

local function AllocateSyncId(meta, kind, used)
    repeat
        meta.NextEntitySequence = meta.NextEntitySequence + 1
        local syncId = string.format("%s:%s:%d", meta.InstallationId, kind, meta.NextEntitySequence)
        if not used[syncId] and meta.EntityLocal[syncId] == nil then
            return syncId
        end
    until false
end

local function EntitySyncId(entityOrSyncId)
    if type(entityOrSyncId) == "table" then
        return entityOrSyncId.SyncId
    end
    return entityOrSyncId
end

--- Rebuilds non-persistent SyncId lookup tables from current records.
function AngryEra:RebuildSyncIdentityIndexes()
    local indexes = {
        page = {},
        category = {},
    }
    for _, kind in ipairs({ "category", "page" }) do
        for _, entity in pairs(GetRecords(kind)) do
            if identity.ValidateSyncId(entity.SyncId, kind) and not indexes[kind][entity.SyncId] then
                indexes[kind][entity.SyncId] = entity
            end
        end
    end
    self.entitySyncIndexes = indexes
end

local function GetIdentityIndex(self, kind)
    if not self.entitySyncIndexes then
        self:RebuildSyncIdentityIndexes()
    end
    return self.entitySyncIndexes[kind]
end

--- Returns a page by immutable SyncId.
-- @tparam string syncId Page synchronization id.
-- @treturn table|nil page
function AngryEra:GetPageBySyncId(syncId)
    return GetIdentityIndex(self, "page")[syncId]
end

--- Returns a category by immutable SyncId.
-- @tparam string syncId Category synchronization id.
-- @treturn table|nil category
function AngryEra:GetCategoryBySyncId(syncId)
    return GetIdentityIndex(self, "category")[syncId]
end

--- Migrates all legacy records to immutable local identities.
-- The migration is idempotent and writes its completion marker last.
function AngryEra:MigrateEntityIdentities()
    local meta = self:InitializeIdentityStorage()
    local legacyMigration = meta.Migrations.EntityIdentity ~= ENTITY_SCHEMA_VERSION
    local used = {}
    local allEntries = {}

    for _, kind in ipairs({ "category", "page" }) do
        for _, entry in ipairs(SortRecordEntries(GetRecords(kind))) do
            entry.Kind = kind
            table.insert(allEntries, entry)

            local installationId, parsedKind, sequence = identity.ParseSyncId(entry.Record.SyncId)
            if installationId == meta.InstallationId and parsedKind == kind and sequence > meta.NextEntitySequence then
                meta.NextEntitySequence = sequence
            end
        end
    end

    for _, entry in ipairs(allEntries) do
        local entity = entry.Record
        local syncId = entity.SyncId
        local assignedNewIdentity = false
        if not identity.ValidateSyncId(syncId, entry.Kind) or used[syncId] then
            syncId = AllocateSyncId(meta, entry.Kind, used)
            entity.SyncId = syncId
            assignedNewIdentity = true
        end
        used[syncId] = entity

        local repairedOwner = false
        local syncInstallationId = identity.ParseSyncId(syncId)
        if entity.OwnerId ~= syncInstallationId then
            entity.OwnerId = syncInstallationId
            repairedOwner = true
        end

        local state = EnsureLocalState(meta, syncId)
        if legacyMigration or assignedNewIdentity or repairedOwner then
            state.OwnedLocally = true
        end
    end

    self:RebuildSyncIdentityIndexes()
    meta.Migrations.EntityIdentity = ENTITY_SCHEMA_VERSION
    if meta.SchemaVersion < ENTITY_SCHEMA_VERSION then
        meta.SchemaVersion = ENTITY_SCHEMA_VERSION
    end
end

local LOCAL_ID_MIGRATION_VERSION = 1

local function IsPositiveInteger(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function RemapSelectionValue(value, maps)
    if type(value) ~= "number" or value % 1 ~= 0 or value == 0 then
        return nil
    end
    if value < 0 then
        local mapped = maps.category[-value]
        return mapped and -mapped or nil
    end
    return maps.page[value]
end

local function RemapCategoryStateValue(value, categoryMap)
    if type(value) ~= "number" or value % 1 ~= 0 or value == 0 then
        return nil
    end
    local categoryId = value < 0 and -value or value
    local mapped = categoryMap[categoryId]
    if not mapped then
        return nil
    end
    return value < 0 and -mapped or mapped
end

local function RemapTreePath(path, maps)
    local parts = {}
    local changed = false
    for segment in path:gmatch("[^\001]+") do
        local mapped = RemapSelectionValue(tonumber(segment), maps)
        if mapped then
            changed = true
            parts[#parts + 1] = tostring(mapped)
        else
            parts[#parts + 1] = segment
        end
    end
    if not changed then
        return nil
    end
    return table.concat(parts, "\001")
end

local function ReserveSelectionPath(path, pages, categories, reserved)
    for segment in path:gmatch("[^\001]+") do
        local value = tonumber(segment)
        if IsPositiveInteger(value) and pages[value] == nil then
            reserved.page[value] = true
        elseif type(value) == "number" and value < 0 and value % 1 == 0 and categories[-value] == nil then
            reserved.category[-value] = true
        end
    end
end

local function ReserveDanglingCategoryReferences(pages, categories, reservedCategories)
    for _, records in ipairs({ categories, pages }) do
        for _, record in pairs(records) do
            local categoryId = type(record) == "table" and record.CategoryId or nil
            if IsPositiveInteger(categoryId) and categories[categoryId] == nil then
                reservedCategories[categoryId] = true
            end
        end
    end
end

local function CollectReservedLocalIds(pages, categories)
    local reserved = {
        page = {},
        category = {},
    }
    ReserveDanglingCategoryReferences(pages, categories, reserved.category)

    local state = AngryAssign_State
    if type(state) ~= "table" then
        return reserved
    end

    if IsPositiveInteger(state.displayed) and pages[state.displayed] == nil then
        reserved.page[state.displayed] = true
    end

    local tree = type(state.tree) == "table" and state.tree or nil
    local selected = tree and tree.selected or nil
    if type(selected) == "string" then
        ReserveSelectionPath(selected, pages, categories, reserved)
    elseif IsPositiveInteger(selected) and pages[selected] == nil then
        reserved.page[selected] = true
    elseif type(selected) == "number" and selected < 0 and selected % 1 == 0 and categories[-selected] == nil then
        reserved.category[-selected] = true
    end

    local groups = tree and type(tree.groups) == "table" and tree.groups or nil
    if groups then
        for key in pairs(groups) do
            if type(key) == "string" then
                ReserveSelectionPath(key, pages, categories, reserved)
            else
                local categoryId = type(key) == "number" and key < 0 and -key or key
                if IsPositiveInteger(categoryId) and categories[categoryId] == nil then
                    reserved.category[categoryId] = true
                end
            end
        end
    end
    return reserved
end

local function BuildSequentialIdMap(records, reserved)
    local oldIds = {}
    for id in pairs(records) do
        if IsPositiveInteger(id) then
            oldIds[#oldIds + 1] = id
        end
    end
    table.sort(oldIds)

    local map = {}
    local newId = 1
    for _, oldId in ipairs(oldIds) do
        while reserved[newId] do
            newId = newId + 1
        end
        map[oldId] = newId
        newId = newId + 1
    end
    return map, oldIds
end

local function ApplySequentialIdMap(records, map, oldIds)
    local originals = {}
    local migrated = 0
    for _, oldId in ipairs(oldIds) do
        originals[oldId] = records[oldId]
        records[oldId] = nil
    end
    for _, oldId in ipairs(oldIds) do
        local newId = map[oldId]
        local record = originals[oldId]
        records[newId] = record
        if type(record) == "table" then
            record.Id = newId
        end
        if newId ~= oldId then
            migrated = migrated + 1
        end
    end
    return migrated
end

--- Renumbers legacy hashed local ids to sequential ids.
-- Legacy AngryAssignments allocated local page and category ids from FCS32
-- hashes spanning the full 32-bit range. This versioned migration normalizes
-- every pre-sequential library once, moves records to the lowest available ids,
-- and rewrites parent references plus persisted display and tree state.
-- @treturn number migrated Count of renumbered entities.
function AngryEra:MigrateLegacyLocalIds()
    if
        type(AngryAssign_Pages) ~= "table"
        or type(AngryAssign_Categories) ~= "table"
        or type(AngryAssign_Meta) ~= "table"
        or type(AngryAssign_Meta.Migrations) ~= "table"
    then
        return 0
    end
    local migrationVersion = AngryAssign_Meta.Migrations.SequentialLocalIds
    if type(migrationVersion) == "number" and migrationVersion >= LOCAL_ID_MIGRATION_VERSION then
        return 0
    end

    local reserved = CollectReservedLocalIds(AngryAssign_Pages, AngryAssign_Categories)
    local pageMap, pageIds = BuildSequentialIdMap(AngryAssign_Pages, reserved.page)
    local categoryMap, categoryIds = BuildSequentialIdMap(AngryAssign_Categories, reserved.category)
    local maps = {
        page = pageMap,
        category = categoryMap,
    }
    local migrated = ApplySequentialIdMap(AngryAssign_Pages, maps.page, pageIds)
        + ApplySequentialIdMap(AngryAssign_Categories, maps.category, categoryIds)

    for _, page in pairs(AngryAssign_Pages) do
        if type(page) == "table" and maps.category[page.CategoryId] then
            page.CategoryId = maps.category[page.CategoryId]
        end
    end
    for _, category in pairs(AngryAssign_Categories) do
        if type(category) == "table" and maps.category[category.CategoryId] then
            category.CategoryId = maps.category[category.CategoryId]
        end
    end

    local state = AngryAssign_State
    if type(state) == "table" then
        if maps.page[state.displayed] then
            state.displayed = maps.page[state.displayed]
        end

        local tree = type(state.tree) == "table" and state.tree or nil
        if tree then
            if type(tree.selected) == "string" then
                tree.selected = RemapTreePath(tree.selected, maps) or tree.selected
            else
                local remappedSelected = RemapSelectionValue(tree.selected, maps)
                if remappedSelected then
                    tree.selected = remappedSelected
                end
            end

            if type(tree.groups) == "table" then
                local rewritten = {}
                for key, value in pairs(tree.groups) do
                    local newKey = key
                    if type(key) == "number" then
                        newKey = RemapCategoryStateValue(key, maps.category) or key
                    elseif type(key) == "string" then
                        newKey = RemapTreePath(key, maps) or key
                    end
                    rewritten[newKey] = value
                end
                tree.groups = rewritten
            end
        end
    end

    AngryAssign_Meta.Migrations.SequentialLocalIds = LOCAL_ID_MIGRATION_VERSION
    return migrated
end

--- Allocates an unused local numeric UI id.
-- @tparam string kind `"page"` or `"category"`.
-- @treturn number id
function AngryEra:AllocateLocalEntityId(kind)
    local records = GetRecords(kind)
    local reserved = CollectReservedLocalIds(AngryAssign_Pages, AngryAssign_Categories)[kind]
    local id = 1
    while records[id] ~= nil or reserved[id] do
        id = id + 1
    end
    return id
end

--- Allocates an unused immutable SyncId.
-- @tparam string kind `"page"` or `"category"`.
-- @treturn string syncId
function AngryEra:NextSyncId(kind)
    if kind ~= "page" and kind ~= "category" then
        error("Invalid entity kind")
    end
    local meta = self:InitializeIdentityStorage()
    local used = {}
    for syncId in pairs(GetIdentityIndex(self, kind)) do
        used[syncId] = true
    end
    return AllocateSyncId(meta, kind, used)
end

--- Ensures an entity is identified as local without changing a valid SyncId.
-- @tparam table entity Entity record.
-- @tparam string kind `"page"` or `"category"`.
-- @treturn table entity
function AngryEra:EnsureLocalEntityIdentity(entity, kind)
    local meta = self:InitializeIdentityStorage()
    local index = GetIdentityIndex(self, kind)
    if
        not identity.ValidateSyncId(entity.SyncId, kind) or (index[entity.SyncId] and index[entity.SyncId] ~= entity)
    then
        entity.SyncId = self:NextSyncId(kind)
    end
    if not identity.ValidateInstallationId(entity.OwnerId) then
        entity.OwnerId = meta.InstallationId
    end
    EnsureLocalState(meta, entity.SyncId, true)
    index[entity.SyncId] = entity
    return entity
end

local function NewLocalRecord(self, kind, fields)
    local record = CopyRecord(fields)
    record.Id = record.Id or self:AllocateLocalEntityId(kind)
    record.SyncId = nil
    record.OwnerId = nil
    return self:EnsureLocalEntityIdentity(record, kind)
end

--- Creates a locally owned page record.
-- @tparam table fields Page fields.
-- @treturn table page
function AngryEra:NewLocalPageRecord(fields)
    return NewLocalRecord(self, "page", fields)
end

--- Creates a locally owned category record.
-- @tparam table fields Category fields.
-- @treturn table category
function AngryEra:NewLocalCategoryRecord(fields)
    return NewLocalRecord(self, "category", fields)
end

local function ReplaceRecord(self, kind, id, fields)
    local existing = GetRecords(kind)[id]
    local record = CopyRecord(fields)
    record.Id = id
    if existing then
        for _, field in ipairs(IDENTITY_FIELDS) do
            record[field] = existing[field]
        end
        if identity.ValidateSyncId(record.SyncId, kind) and identity.ValidateInstallationId(record.OwnerId) then
            GetIdentityIndex(self, kind)[record.SyncId] = record
            return record
        end
    end
    return self:EnsureLocalEntityIdentity(record, kind)
end

--- Replaces page data while preserving immutable identity.
function AngryEra:ReplacePageRecord(id, fields)
    return ReplaceRecord(self, "page", id, fields)
end

--- Replaces category data while preserving immutable identity.
function AngryEra:ReplaceCategoryRecord(id, fields)
    return ReplaceRecord(self, "category", id, fields)
end

--- Registers identity supplied by an authenticated remote message.
-- Local ownership and pin state are never accepted from wire data.
-- @treturn boolean ok
-- @treturn string|nil err
function AngryEra:RegisterRemoteEntityIdentity(entity, kind, wireIdentity)
    if type(wireIdentity) ~= "table" then
        return false, "missingIdentity"
    end
    if not identity.ValidateSyncId(wireIdentity.SyncId, kind) then
        return false, "invalidSyncId"
    end
    if not identity.ValidateInstallationId(wireIdentity.OwnerId) then
        return false, "invalidOwnerId"
    end

    local meta = self:InitializeIdentityStorage()
    local syncInstallationId = identity.ParseSyncId(wireIdentity.SyncId)
    if wireIdentity.OwnerId ~= syncInstallationId then
        return false, "ownerMismatch"
    end
    if syncInstallationId == meta.InstallationId then
        return false, "localIdentityCollision"
    end
    local localState = meta.EntityLocal[wireIdentity.SyncId]
    if localState and localState.OwnedLocally then
        return false, "localIdentityCollision"
    end

    local index = GetIdentityIndex(self, kind)
    if index[wireIdentity.SyncId] and index[wireIdentity.SyncId] ~= entity then
        return false, "identityCollision"
    end

    entity.SyncId = wireIdentity.SyncId
    entity.OwnerId = wireIdentity.OwnerId
    EnsureLocalState(meta, entity.SyncId, false)
    index[entity.SyncId] = entity
    return true
end

--- Returns the local-only identity metadata for an entity.
function AngryEra:GetLocalEntityState(entityOrSyncId)
    local syncId = EntitySyncId(entityOrSyncId)
    return syncId and AngryAssign_Meta and AngryAssign_Meta.EntityLocal[syncId]
end

--- Returns whether an entity originated in this local library.
function AngryEra:IsLocallyOwned(entityOrSyncId)
    local state = self:GetLocalEntityState(entityOrSyncId)
    return state and state.OwnedLocally == true or false
end

--- Returns whether an entity is protected from remote cleanup/deletion.
function AngryEra:IsPinned(entityOrSyncId)
    local state = self:GetLocalEntityState(entityOrSyncId)
    return state and state.Pinned == true or false
end

--- Changes local pin state without mutating wire-visible entity data.
function AngryEra:SetPinned(entityOrSyncId, pinned)
    local syncId = EntitySyncId(entityOrSyncId)
    if not syncId or not identity.ValidateSyncId(syncId) then
        return false
    end
    local state = EnsureLocalState(self:InitializeIdentityStorage(), syncId)
    state.Pinned = pinned == true
    return true
end

--- Removes runtime identity registration while retaining retired local ownership.
function AngryEra:ForgetEntityIdentity(entityOrSyncId, kind)
    local syncId = EntitySyncId(entityOrSyncId)
    if not syncId then
        return
    end
    if kind then
        GetIdentityIndex(self, kind)[syncId] = nil
    else
        GetIdentityIndex(self, "page")[syncId] = nil
        GetIdentityIndex(self, "category")[syncId] = nil
    end

    local state = AngryAssign_Meta.EntityLocal[syncId]
    if state and state.OwnedLocally then
        state.DeletedLocally = true
    else
        AngryAssign_Meta.EntityLocal[syncId] = nil
    end
end

--- Removes a page record and its identity registration.
function AngryEra:RemovePageRecord(id)
    local page = AngryAssign_Pages[id]
    if not page then
        return
    end
    if self.CancelPageTimer then
        self:CancelPageTimer(id)
    end
    self:ForgetEntityIdentity(page, "page")
    AngryAssign_Pages[id] = nil
end

--- Removes a category record and its identity registration.
function AngryEra:RemoveCategoryRecord(id)
    local category = AngryAssign_Categories[id]
    if not category then
        return
    end
    self:ForgetEntityIdentity(category, "category")
    AngryAssign_Categories[id] = nil
end

--- Removes all entity records while retaining installation identity and counters.
function AngryEra:RemoveAllEntityRecords()
    for id in pairs(AngryAssign_Pages) do
        self:RemovePageRecord(id)
    end
    for id in pairs(AngryAssign_Categories) do
        self:RemoveCategoryRecord(id)
    end
    AngryAssign_Meta.SyncScopes = {}
end
