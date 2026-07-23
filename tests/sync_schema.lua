local app = {
    AngryEra = {},
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)

local schema = app.AngryEra.sync.schema
local assertions = 0

local function Assert(value, message)
    assertions = assertions + 1
    assert(value, message)
end

local function AssertEqual(actual, expected, message)
    assertions = assertions + 1
    assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function AssertError(value, errorCode, expectedError, message)
    Assert(value == nil or value == false, message .. " should fail")
    AssertEqual(errorCode, expectedError, message)
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

local installationId = "ae3i:1:2:3:4"
local otherInstallationId = "ae3i:a:b:c:d"

local function SyncId(kind, sequence, owner)
    return string.format("%s:%s:%d", owner or installationId, kind, sequence)
end

local function MessageId(sequence)
    return string.format("%s:session_A-1:%d", installationId, sequence)
end

local function MakeEntity(kind, sequence, parentSyncId, order, overrides)
    local entity = {
        Kind = kind,
        SyncId = SyncId(kind, sequence),
        OwnerId = installationId,
        Revision = 1,
        UpdatedAt = 1000,
        UpdatedBy = "Leader-Realm",
        ParentSyncId = parentSyncId,
        Order = order,
        Name = kind == "page" and ("Page " .. sequence) or ("Category " .. sequence),
        Vars = "",
    }
    if kind == "page" then
        entity.Contents = "Assignments " .. sequence
    end
    for key, value in pairs(overrides or {}) do
        entity[key] = value
    end
    entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, TestHash))
    return entity
end

local function MakeTombstone(kind, sequence, deletedScopeRevision, overrides)
    local tombstone = {
        Kind = kind,
        SyncId = SyncId(kind, sequence, otherInstallationId),
        OwnerId = otherInstallationId,
        Revision = 2,
        BaseRevisionId = "fcs32:12345678",
        DeletedAt = 1100,
        DeletedBy = "Leader-Realm",
        DeletedScopeRevision = deletedScopeRevision or 2,
    }
    for key, value in pairs(overrides or {}) do
        tombstone[key] = value
    end
    tombstone.RevisionId = assert(schema.BuildTombstoneRevisionId(tombstone, TestHash))
    return tombstone
end

local function SortBySyncId(values)
    table.sort(values, function(a, b)
        return a.SyncId < b.SyncId
    end)
    return values
end

local function MakeManifest()
    local root = MakeEntity("category", 1, nil, 1)
    local child = MakeEntity("category", 2, root.SyncId, 1)
    local rootPage = MakeEntity("page", 3, root.SyncId, 2)
    local childPage = MakeEntity("page", 4, child.SyncId, 1)
    return {
        Schema = 1,
        ScopeId = root.SyncId,
        RootSyncId = root.SyncId,
        ManifestId = MessageId(10),
        AuthorityEpoch = MessageId(9),
        ScopeRevision = 2,
        Entities = SortBySyncId({ childPage, rootPage, child, root }),
        Tombstones = { MakeTombstone("page", 90, 2) },
    }
end

AssertEqual(schema.VERSION, 1, "schema version")
AssertEqual(schema.LIMITS.EntityCount, 512, "entity bound")
AssertEqual(schema.LIMITS.HierarchyDepth, 32, "hierarchy depth bound")

local page = MakeEntity("page", 10, SyncId("category", 1), 1)
local valid, validationError = schema.ValidateEntity(page, TestHash)
Assert(valid and validationError == nil, "valid page record")

local category = MakeEntity("category", 11, nil, 1)
valid, validationError = schema.ValidateEntity(category, TestHash)
Assert(valid and validationError == nil, "valid category record")

local canonicalPage = assert(schema.CanonicalEntityInput(page))
local canonicalPageAgain = assert(schema.CanonicalEntityInput(DeepCopy(page)))
AssertEqual(canonicalPageAgain, canonicalPage, "entity canonical input is deterministic")
AssertEqual(
    canonicalPage,
    "S14:AngryEraEntity"
        .. "I1;"
        .. "S4:page"
        .. "S20:ae3i:1:2:3:4:page:10"
        .. "S12:ae3i:1:2:3:4"
        .. "S23:ae3i:1:2:3:4:category:1"
        .. "I1;"
        .. "S7:Page 10"
        .. "S0:"
        .. "S14:Assignments 10",
    "entity canonical format"
)

local ambiguousA = MakeEntity("page", 12, SyncId("category", 1), 1, {
    Name = "ab",
    Vars = "c",
    Contents = "",
})
local ambiguousB = MakeEntity("page", 12, SyncId("category", 1), 1, {
    Name = "a",
    Vars = "bc",
    Contents = "",
})
Assert(
    schema.CanonicalEntityInput(ambiguousA) ~= schema.CanonicalEntityInput(ambiguousB),
    "length prefixes prevent concatenation ambiguity"
)

for _, fieldCase in ipairs({
    { field = "Name", value = "Different" },
    { field = "Vars", value = "MT=Different" },
    { field = "Contents", value = "Different assignments" },
    { field = "Order", value = 2 },
    { field = "ParentSyncId", value = SyncId("category", 2) },
}) do
    local changed = DeepCopy(page)
    changed[fieldCase.field] = fieldCase.value
    local changedRevisionId = assert(schema.BuildEntityRevisionId(changed, TestHash))
    Assert(changedRevisionId ~= page.RevisionId, fieldCase.field .. " changes RevisionId")
end

local metadataOnly = DeepCopy(page)
metadataOnly.Revision = 99
metadataOnly.UpdatedAt = 9999
metadataOnly.UpdatedBy = "Assistant-Realm"
AssertEqual(
    schema.BuildEntityRevisionId(metadataOnly, TestHash),
    page.RevisionId,
    "revision metadata is excluded from RevisionId"
)

local hashFailure, hashFailureError = schema.BuildEntityRevisionId(page, nil)
AssertError(hashFailure, hashFailureError, "invalid-hash-callback", "missing hash callback")
hashFailure, hashFailureError = schema.BuildEntityRevisionId(page, function()
    error("hash")
end)
AssertError(hashFailure, hashFailureError, "hash-failed", "hash exception")
hashFailure, hashFailureError = schema.BuildEntityRevisionId(page, function()
    return "ABCDEF12"
end)
AssertError(hashFailure, hashFailureError, "hash-failed", "uppercase hash output")
hashFailure, hashFailureError = schema.BuildEntityRevisionId(page, function()
    return "1234"
end)
AssertError(hashFailure, hashFailureError, "hash-failed", "short hash output")

local invalidEntityCases = {
    { "unknown field", "entity-unknown-field", { Future = true } },
    { "numeric field", "entity-unknown-field", { [1] = true } },
    { "wrong kind", "invalid-entity-kind", { Kind = "PAGE" } },
    { "invalid owner", "invalid-owner-id", { OwnerId = "bad" } },
    { "owner mismatch", "owner-mismatch", { OwnerId = otherInstallationId } },
    { "leading-zero installation", "invalid-sync-id", { SyncId = "ae3i:01:2:3:4:page:10" } },
    { "uppercase installation", "invalid-sync-id", { SyncId = "ae3i:A:2:3:4:page:10" } },
    { "zero-padded SyncId", "invalid-sync-id", { SyncId = installationId .. ":page:010" } },
    { "large SyncId sequence", "invalid-sync-id", { SyncId = installationId .. ":page:2147483648" } },
    { "wrong SyncId kind", "invalid-sync-id", { SyncId = SyncId("category", 10) } },
    { "page parent", "invalid-parent-sync-id", { ParentSyncId = SyncId("page", 2) } },
    { "zero revision", "invalid-revision", { Revision = 0 } },
    { "fractional revision", "invalid-revision", { Revision = 1.5 } },
    { "infinite revision", "invalid-revision", { Revision = math.huge } },
    { "NaN revision", "invalid-revision", { Revision = 0 / 0 } },
    { "large revision", "invalid-revision", { Revision = schema.LIMITS.Revision + 1 } },
    { "zero order", "invalid-order", { Order = 0 } },
    { "fractional order", "invalid-order", { Order = 1.5 } },
    { "large order", "invalid-order", { Order = 513 } },
    { "negative time", "invalid-updated-at", { UpdatedAt = -1 } },
    { "fractional time", "invalid-updated-at", { UpdatedAt = 1.5 } },
    { "large time", "invalid-updated-at", { UpdatedAt = schema.LIMITS.Timestamp + 1 } },
    { "short author", "invalid-updated-by", { UpdatedBy = "Leader" } },
    { "control author", "invalid-updated-by", { UpdatedBy = "Leader-\nRealm" } },
    { "long author", "invalid-updated-by", { UpdatedBy = string.rep("a", 123) .. "-Realm" } },
    { "empty name", "invalid-name", { Name = "" } },
    { "whitespace name", "invalid-name", { Name = "   " } },
    { "untrimmed name", "invalid-name", { Name = " Page" } },
    { "control name", "invalid-name", { Name = "Page\nName" } },
    { "long name", "invalid-name", { Name = string.rep("n", 101) } },
    { "non-string vars", "invalid-vars", { Vars = {} } },
    { "long vars", "invalid-vars", { Vars = string.rep("v", 5001) } },
    { "non-string contents", "invalid-contents", { Contents = {} } },
    { "long contents", "invalid-contents", { Contents = string.rep("c", 20001) } },
    { "bad RevisionId", "invalid-revision-id", { RevisionId = "fcs32:ABCDEF12" } },
}

for _, invalidCase in ipairs(invalidEntityCases) do
    local invalid = DeepCopy(page)
    for key, value in pairs(invalidCase[3]) do
        invalid[key] = value
    end
    valid, validationError = schema.ValidateEntity(invalid, TestHash)
    AssertError(valid, validationError, invalidCase[2], invalidCase[1])
end

for _, missingCase in ipairs({
    { "Kind", "invalid-entity-kind" },
    { "SyncId", "entity-missing-SyncId" },
    { "OwnerId", "entity-missing-OwnerId" },
    { "Revision", "entity-missing-Revision" },
    { "RevisionId", "entity-missing-RevisionId" },
    { "UpdatedAt", "entity-missing-UpdatedAt" },
    { "UpdatedBy", "entity-missing-UpdatedBy" },
    { "Order", "entity-missing-Order" },
    { "Name", "entity-missing-Name" },
    { "Vars", "entity-missing-Vars" },
}) do
    local missing = DeepCopy(page)
    missing[missingCase[1]] = nil
    valid, validationError = schema.ValidateEntity(missing, TestHash)
    AssertError(valid, validationError, missingCase[2], "missing entity " .. missingCase[1])
end

local missingContents = DeepCopy(page)
missingContents.Contents = nil
valid, validationError = schema.ValidateEntity(missingContents, TestHash)
AssertError(valid, validationError, "entity-missing-Contents", "missing page contents")

local categoryWithContents = DeepCopy(category)
categoryWithContents.Contents = "not allowed"
valid, validationError = schema.ValidateEntity(categoryWithContents, TestHash)
AssertError(valid, validationError, "entity-unknown-field", "category contents")

local revisionMismatch = DeepCopy(page)
revisionMismatch.Name = "Changed without revision"
valid, validationError = schema.ValidateEntity(revisionMismatch, TestHash)
AssertError(valid, validationError, "revision-id-mismatch", "entity revision mismatch")

local metatableEntity = DeepCopy(page)
setmetatable(metatableEntity, {})
valid, validationError = schema.ValidateEntity(metatableEntity, TestHash)
AssertError(valid, validationError, "invalid-entity", "entity metatable")

local maximumEntity = MakeEntity("page", 13, SyncId("category", 1), schema.LIMITS.Order, {
    Revision = schema.LIMITS.Revision,
    UpdatedAt = schema.LIMITS.Timestamp,
    UpdatedBy = string.rep("a", 122) .. "-Realm",
    Name = string.rep("n", schema.LIMITS.NameBytes),
    Vars = string.rep("v", schema.LIMITS.VarsBytes),
    Contents = string.rep("c", schema.LIMITS.ContentsBytes),
})
valid, validationError = schema.ValidateEntity(maximumEntity, TestHash)
Assert(valid and validationError == nil, "exact entity scalar limits")

local utf8Pair = string.char(195, 169)
local utf8Name = MakeEntity("page", 14, SyncId("category", 1), 1, {
    Name = string.rep(utf8Pair, 50),
})
valid, validationError = schema.ValidateEntity(utf8Name, TestHash)
Assert(valid and validationError == nil, "name limit counts UTF-8 bytes")
utf8Name.Name = utf8Name.Name .. utf8Pair
valid, validationError = schema.ValidateEntity(utf8Name, TestHash)
AssertError(valid, validationError, "invalid-name", "UTF-8 name over byte limit")

local selfParent = MakeEntity("category", 15, nil, 1)
selfParent.ParentSyncId = selfParent.SyncId
valid, validationError = schema.ValidateEntity(selfParent, TestHash)
AssertError(valid, validationError, "self-parent", "category self parent")

local foreignOwned = MakeEntity("page", 16, SyncId("category", 1), 1, {
    SyncId = SyncId("page", 16, otherInstallationId),
    OwnerId = otherInstallationId,
})
valid, validationError = schema.ValidateEntity(foreignOwned, TestHash)
Assert(valid and validationError == nil, "matching foreign ownership is valid schema, not authorization")

local tombstone = MakeTombstone("page", 91, 2)
valid, validationError = schema.ValidateTombstone(tombstone, TestHash)
Assert(valid and validationError == nil, "valid tombstone")
AssertEqual(
    schema.CanonicalTombstoneInput(DeepCopy(tombstone)),
    schema.CanonicalTombstoneInput(tombstone),
    "tombstone canonical input is deterministic"
)
AssertEqual(
    schema.CanonicalTombstoneInput(tombstone),
    "S17:AngryEraTombstone"
        .. "I1;"
        .. "S4:page"
        .. "S20:ae3i:a:b:c:d:page:91"
        .. "S12:ae3i:a:b:c:d"
        .. "I2;"
        .. "S14:fcs32:12345678"
        .. "I1100;"
        .. "S12:Leader-Realm"
        .. "I2;",
    "tombstone canonical format"
)

local maximumTimestampTombstone = MakeTombstone("page", 92, schema.LIMITS.ScopeRevision, {
    Revision = schema.LIMITS.Revision,
    DeletedAt = schema.LIMITS.Timestamp,
})
Assert(
    schema.CanonicalTombstoneInput(maximumTimestampTombstone):find("I9007199254740991;", 1, true) ~= nil,
    "maximum timestamp has a cross-runtime canonical decimal encoding"
)

local invalidTombstoneCases = {
    { "unknown tombstone field", "tombstone-unknown-field", { Future = true } },
    { "wrong tombstone kind", "invalid-tombstone-kind", { Kind = "PAGE" } },
    { "tombstone owner mismatch", "tombstone-owner-mismatch", { OwnerId = installationId } },
    { "tombstone revision one", "invalid-tombstone-revision", { Revision = 1 } },
    { "bad tombstone base", "invalid-base-revision-id", { BaseRevisionId = "bad" } },
    { "bad tombstone time", "invalid-deleted-at", { DeletedAt = -1 } },
    { "bad tombstone author", "invalid-deleted-by", { DeletedBy = "Leader" } },
    { "bad tombstone scope revision", "invalid-deleted-scope-revision", { DeletedScopeRevision = 0 } },
    { "bad tombstone RevisionId", "invalid-tombstone-revision-id", { RevisionId = "bad" } },
}

for _, invalidCase in ipairs(invalidTombstoneCases) do
    local invalid = DeepCopy(tombstone)
    for key, value in pairs(invalidCase[3]) do
        invalid[key] = value
    end
    valid, validationError = schema.ValidateTombstone(invalid, TestHash)
    AssertError(valid, validationError, invalidCase[2], invalidCase[1])
end

for _, missingCase in ipairs({
    { "Kind", "invalid-tombstone-kind" },
    { "SyncId", "tombstone-missing-SyncId" },
    { "OwnerId", "tombstone-missing-OwnerId" },
    { "Revision", "tombstone-missing-Revision" },
    { "RevisionId", "tombstone-missing-RevisionId" },
    { "BaseRevisionId", "tombstone-missing-BaseRevisionId" },
    { "DeletedAt", "tombstone-missing-DeletedAt" },
    { "DeletedBy", "tombstone-missing-DeletedBy" },
    { "DeletedScopeRevision", "tombstone-missing-DeletedScopeRevision" },
}) do
    local missing = DeepCopy(tombstone)
    missing[missingCase[1]] = nil
    valid, validationError = schema.ValidateTombstone(missing, TestHash)
    AssertError(valid, validationError, missingCase[2], "missing tombstone " .. missingCase[1])
end

local changedTombstone = DeepCopy(tombstone)
changedTombstone.DeletedAt = tombstone.DeletedAt + 1
Assert(
    schema.BuildTombstoneRevisionId(changedTombstone, TestHash) ~= tombstone.RevisionId,
    "deletion metadata changes tombstone RevisionId"
)

local tombstoneMismatch = DeepCopy(tombstone)
tombstoneMismatch.DeletedBy = "Other-Realm"
valid, validationError = schema.ValidateTombstone(tombstoneMismatch, TestHash)
AssertError(valid, validationError, "tombstone-revision-id-mismatch", "tombstone revision mismatch")

local count, arrayError = schema.ValidateDenseArray({ "a", "b" }, 2, 1)
AssertEqual(count, 2, "dense array count")
Assert(arrayError == nil, "dense array has no error")
count, arrayError = schema.ValidateDenseArray({ [1] = "a", [3] = "c" }, 3, 1)
AssertError(count, arrayError, "sparse-array", "sparse array")
count, arrayError = schema.ValidateDenseArray({ [1] = "a", named = "b" }, 3, 1)
AssertError(count, arrayError, "invalid-array-key", "hash array key")
count, arrayError = schema.ValidateDenseArray({ [1.5] = "a" }, 3, 1)
AssertError(count, arrayError, "invalid-array-key", "fractional array key")
count, arrayError = schema.ValidateDenseArray({ "a", "b", "c" }, 2, 1)
AssertError(count, arrayError, "too-many-array-items", "array maximum")
count, arrayError = schema.ValidateDenseArray({}, 2, 1)
AssertError(count, arrayError, "too-few-array-items", "array minimum")
local metatableArray = {}
setmetatable(metatableArray, {})
count, arrayError = schema.ValidateDenseArray(metatableArray, 2)
AssertError(count, arrayError, "invalid-array", "array metatable")

local manifest = MakeManifest()
valid, validationError = schema.ValidateManifest(manifest, TestHash)
Assert(valid and validationError == nil, "valid manifest")

local manifestInput = assert(schema.CanonicalManifestInput(manifest, TestHash))
local manifestHash = assert(schema.BuildManifestHash(manifest, TestHash))
AssertEqual(
    schema.CanonicalManifestInput(DeepCopy(manifest), TestHash),
    manifestInput,
    "manifest canonical input is deterministic"
)
AssertEqual(schema.BuildManifestHash(DeepCopy(manifest), TestHash), manifestHash, "manifest hash is deterministic")

local manifestCases = {
    {
        "manifest unknown field",
        "manifest-unknown-field",
        function(value)
            value.Future = true
        end,
    },
    {
        "manifest schema",
        "invalid-manifest-schema",
        function(value)
            value.Schema = 2
        end,
    },
    {
        "scope/root mismatch",
        "root-scope-mismatch",
        function(value)
            value.RootSyncId = SyncId("category", 99)
        end,
    },
    {
        "bad manifest ID",
        "invalid-manifest-id",
        function(value)
            value.ManifestId = installationId .. ":session_A-1:010"
        end,
    },
    {
        "bad authority epoch",
        "invalid-authority-epoch",
        function(value)
            value.AuthorityEpoch = "bad"
        end,
    },
    {
        "zero scope revision",
        "invalid-scope-revision",
        function(value)
            value.ScopeRevision = 0
        end,
    },
    {
        "noncanonical entity order",
        "manifest-entities-not-canonical",
        function(value)
            value.Entities[1], value.Entities[2] = value.Entities[2], value.Entities[1]
        end,
    },
    {
        "duplicate entity",
        "manifest-entities-not-canonical",
        function(value)
            value.Entities[2] = DeepCopy(value.Entities[1])
        end,
    },
    {
        "unexpected second root",
        "unexpected-manifest-root",
        function(value)
            for _, entity in ipairs(value.Entities) do
                if entity.Kind == "category" and entity.SyncId ~= value.RootSyncId then
                    entity.ParentSyncId = nil
                    entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, TestHash))
                    break
                end
            end
        end,
    },
    {
        "root order",
        "invalid-manifest-root",
        function(value)
            for _, entity in ipairs(value.Entities) do
                if entity.SyncId == value.RootSyncId then
                    entity.Order = 2
                    entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, TestHash))
                    break
                end
            end
        end,
    },
    {
        "missing parent",
        "missing-parent",
        function(value)
            for _, entity in ipairs(value.Entities) do
                if entity.Kind == "page" then
                    entity.ParentSyncId = SyncId("category", 99)
                    entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, TestHash))
                    break
                end
            end
        end,
    },
    {
        "duplicate sibling order",
        "duplicate-sibling-order",
        function(value)
            local rootChildren = {}
            for _, entity in ipairs(value.Entities) do
                if entity.ParentSyncId == value.RootSyncId then
                    rootChildren[#rootChildren + 1] = entity
                end
            end
            rootChildren[2].Order = rootChildren[1].Order
            rootChildren[2].RevisionId = assert(schema.BuildEntityRevisionId(rootChildren[2], TestHash))
        end,
    },
    {
        "noncanonical sibling order",
        "noncanonical-sibling-order",
        function(value)
            for _, entity in ipairs(value.Entities) do
                if entity.ParentSyncId == value.RootSyncId and entity.Order == 2 then
                    entity.Order = 3
                    entity.RevisionId = assert(schema.BuildEntityRevisionId(entity, TestHash))
                    break
                end
            end
        end,
    },
    {
        "noncanonical tombstone order",
        "manifest-tombstones-not-canonical",
        function(value)
            value.Tombstones = {
                MakeTombstone("page", 92, 2),
                MakeTombstone("page", 91, 2),
            }
        end,
    },
    {
        "future tombstone",
        "future-tombstone",
        function(value)
            value.Tombstones[1].DeletedScopeRevision = 3
            value.Tombstones[1].RevisionId = assert(schema.BuildTombstoneRevisionId(value.Tombstones[1], TestHash))
        end,
    },
}

for _, manifestCase in ipairs(manifestCases) do
    local invalid = DeepCopy(manifest)
    manifestCase[3](invalid)
    valid, validationError = schema.ValidateManifest(invalid, TestHash)
    AssertError(valid, validationError, manifestCase[2], manifestCase[1])
end

for _, field in ipairs({
    "Schema",
    "ScopeId",
    "RootSyncId",
    "ManifestId",
    "AuthorityEpoch",
    "ScopeRevision",
    "Entities",
    "Tombstones",
}) do
    local missing = DeepCopy(manifest)
    missing[field] = nil
    valid, validationError = schema.ValidateManifest(missing, TestHash)
    AssertError(valid, validationError, "manifest-missing-" .. field, "missing manifest " .. field)
end

local sparseEntities = DeepCopy(manifest)
sparseEntities.Entities = {
    [1] = manifest.Entities[1],
    [3] = manifest.Entities[2],
}
valid, validationError = schema.ValidateManifest(sparseEntities, TestHash)
AssertError(valid, validationError, "manifest-entities-sparse-array", "sparse manifest entities")

local hashKeyTombstones = DeepCopy(manifest)
hashKeyTombstones.Tombstones.extra = MakeTombstone("page", 99, 2)
valid, validationError = schema.ValidateManifest(hashKeyTombstones, TestHash)
AssertError(valid, validationError, "manifest-tombstones-invalid-array-key", "manifest tombstone hash key")

local entityTombstoneCollision = DeepCopy(manifest)
local collisionEntity = entityTombstoneCollision.Entities[#entityTombstoneCollision.Entities]
entityTombstoneCollision.Tombstones = {
    MakeTombstone(collisionEntity.Kind, 4, 2, {
        SyncId = collisionEntity.SyncId,
        OwnerId = collisionEntity.OwnerId,
    }),
}
entityTombstoneCollision.Tombstones[1].RevisionId =
    assert(schema.BuildTombstoneRevisionId(entityTombstoneCollision.Tombstones[1], TestHash))
valid, validationError = schema.ValidateManifest(entityTombstoneCollision, TestHash)
AssertError(valid, validationError, "entity-tombstone-collision", "entity and tombstone collision")

local cycleManifest = MakeManifest()
local cycleA = MakeEntity("category", 20, SyncId("category", 21), 1)
local cycleB = MakeEntity("category", 21, cycleA.SyncId, 1)
cycleManifest.Entities[#cycleManifest.Entities + 1] = cycleA
cycleManifest.Entities[#cycleManifest.Entities + 1] = cycleB
SortBySyncId(cycleManifest.Entities)
valid, validationError = schema.ValidateManifest(cycleManifest, TestHash)
AssertError(valid, validationError, "hierarchy-cycle", "hierarchy cycle")

local maximumDepthManifest = MakeManifest()
maximumDepthManifest.Entities = {}
local maximumDepthRoot = MakeEntity("category", 50, nil, 1)
maximumDepthManifest.ScopeId = maximumDepthRoot.SyncId
maximumDepthManifest.RootSyncId = maximumDepthRoot.SyncId
maximumDepthManifest.Entities[1] = maximumDepthRoot
local maximumDepthParentId = maximumDepthRoot.SyncId
for depth = 2, schema.LIMITS.HierarchyDepth do
    local child = MakeEntity("category", 49 + depth, maximumDepthParentId, 1)
    maximumDepthManifest.Entities[#maximumDepthManifest.Entities + 1] = child
    maximumDepthParentId = child.SyncId
end
SortBySyncId(maximumDepthManifest.Entities)
valid, validationError = schema.ValidateManifest(maximumDepthManifest, TestHash)
Assert(valid and validationError == nil, "exact hierarchy depth limit")

local deepManifest = MakeManifest()
deepManifest.Entities = {}
local deepRoot = MakeEntity("category", 100, nil, 1)
deepManifest.ScopeId = deepRoot.SyncId
deepManifest.RootSyncId = deepRoot.SyncId
deepManifest.Entities[1] = deepRoot
local parentId = deepRoot.SyncId
for depth = 2, schema.LIMITS.HierarchyDepth + 1 do
    local child = MakeEntity("category", 99 + depth, parentId, 1)
    deepManifest.Entities[#deepManifest.Entities + 1] = child
    parentId = child.SyncId
end
SortBySyncId(deepManifest.Entities)
valid, validationError = schema.ValidateManifest(deepManifest, TestHash)
AssertError(valid, validationError, "hierarchy-too-deep", "hierarchy depth")

local largeTextManifest = MakeManifest()
largeTextManifest.Entities = {}
local largeRoot = MakeEntity("category", 200, nil, 1)
largeTextManifest.ScopeId = largeRoot.SyncId
largeTextManifest.RootSyncId = largeRoot.SyncId
largeTextManifest.Entities[1] = largeRoot
for index = 1, 27 do
    largeTextManifest.Entities[#largeTextManifest.Entities + 1] = MakeEntity(
        "page",
        200 + index,
        largeRoot.SyncId,
        index,
        { Contents = string.rep("x", schema.LIMITS.ContentsBytes) }
    )
end
SortBySyncId(largeTextManifest.Entities)
valid, validationError = schema.ValidateManifest(largeTextManifest, TestHash)
AssertError(valid, validationError, "manifest-text-too-large", "manifest aggregate text")

local tooManyEntities = MakeManifest()
tooManyEntities.Entities = {}
local countRoot = MakeEntity("category", 1000, nil, 1)
tooManyEntities.ScopeId = countRoot.SyncId
tooManyEntities.RootSyncId = countRoot.SyncId
tooManyEntities.Entities[1] = countRoot
for index = 1, schema.LIMITS.EntityCount do
    tooManyEntities.Entities[#tooManyEntities.Entities + 1] =
        MakeEntity("page", 1000 + index, countRoot.SyncId, math.min(index, schema.LIMITS.Order))
end
SortBySyncId(tooManyEntities.Entities)
valid, validationError = schema.ValidateManifest(tooManyEntities, TestHash)
AssertError(valid, validationError, "manifest-entities-too-many-array-items", "manifest entity count")

local invalidEmbeddedRevision = MakeManifest()
invalidEmbeddedRevision.Entities[1].Name = "Changed"
valid, validationError = schema.ValidateManifest(invalidEmbeddedRevision, TestHash)
AssertError(valid, validationError, "manifest-entity-revision-id-mismatch", "manifest embedded entity revision")

local inputSnapshot = schema.CanonicalManifestInput(manifest, TestHash)
schema.ValidateManifest(manifest, TestHash)
AssertEqual(schema.CanonicalManifestInput(manifest, TestHash), inputSnapshot, "validation does not mutate input")

print(string.format("Synchronization schema tests passed (%d assertions).", assertions))
