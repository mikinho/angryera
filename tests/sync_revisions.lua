local fcsCalls = {}
local fakeLibC = {}

function fakeLibC:fcs32init()
    fcsCalls[#fcsCalls + 1] = { Method = "init", Self = self }
    return -1
end

function fakeLibC:fcs32update(code, value)
    fcsCalls[#fcsCalls + 1] = {
        Method = "update",
        Self = self,
        Code = code,
        Value = value,
    }
    return code
end

function fakeLibC:fcs32final(code)
    fcsCalls[#fcsCalls + 1] = {
        Method = "final",
        Self = self,
        Code = code,
    }
    return code
end

local app = {
    AngryEra = {},
    libs = {
        libC = fakeLibC,
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/revisions.lua"))("AngryEra", app)

local schema = app.AngryEra.sync.schema
local revisions = app.AngryEra.sync.revisions
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
    if expectedError then
        AssertEqual(errorCode, expectedError, message)
    else
        Assert(type(errorCode) == "string", message .. " should return an error code")
    end
end

local function TestHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function SyncId(kind, sequence)
    return string.format("ae3i:1:2:3:4:%s:%d", kind, sequence)
end

local installationId = "ae3i:1:2:3:4"
local audit = {
    UpdatedAt = 1000,
    UpdatedBy = "Leader-Realm",
}

local function NewCollections()
    local categories = {
        [30] = {
            Id = 30,
            SyncId = SyncId("category", 3),
            OwnerId = installationId,
            CategoryId = 10,
            Name = "Unindexed",
            Vars = nil,
        },
        [10] = {
            Id = 10,
            SyncId = SyncId("category", 1),
            OwnerId = installationId,
            CategoryId = 999,
            Index = 99.5,
            Name = "Root",
            Vars = "root=yes",
        },
        [20] = {
            Id = 20,
            SyncId = SyncId("category", 2),
            OwnerId = installationId,
            CategoryId = 10,
            Index = 10,
            Name = "Nested",
            Vars = "nested=yes",
        },
    }
    local pages = {
        [22] = {
            Id = 22,
            SyncId = SyncId("page", 6),
            OwnerId = installationId,
            CategoryId = 20,
            Name = "Nested Page",
            Contents = "nested contents",
            Vars = "",
        },
        [21] = {
            Id = 21,
            SyncId = SyncId("page", 5),
            OwnerId = installationId,
            CategoryId = 10,
            Index = 5,
            Name = "Same",
            Contents = "second",
            Vars = "role=two",
        },
        [20] = {
            Id = 20,
            SyncId = SyncId("page", 4),
            OwnerId = installationId,
            CategoryId = 10,
            Index = 5,
            Name = "Same",
            Contents = nil,
            Vars = nil,
        },
    }
    return categories, pages
end

local function SnapshotRevision(record)
    return {
        Revision = record.Revision,
        RevisionId = record.RevisionId,
        UpdatedAt = record.UpdatedAt,
        UpdatedBy = record.UpdatedBy,
    }
end

local function AssertRevisionSnapshot(record, snapshot, message)
    AssertEqual(record.Revision, snapshot.Revision, message .. " Revision")
    AssertEqual(record.RevisionId, snapshot.RevisionId, message .. " RevisionId")
    AssertEqual(record.UpdatedAt, snapshot.UpdatedAt, message .. " UpdatedAt")
    AssertEqual(record.UpdatedBy, snapshot.UpdatedBy, message .. " UpdatedBy")
end

local fcs32, fcsError = revisions.CreateFCS32Callback(fakeLibC)
Assert(fcs32 and not fcsError, "valid LibCompress should produce a callback")
AssertEqual(fcs32("canonical"), "ffffffff", "signed FCS32 should normalize to unsigned hexadecimal")
AssertEqual(#fcsCalls, 3, "FCS32 callback should use the three LibCompress phases")
Assert(fcsCalls[1].Self == fakeLibC and fcsCalls[2].Self == fakeLibC, "LibCompress methods should receive self")
AssertEqual(fcsCalls[2].Value, "canonical", "FCS32 update should receive the complete canonical value")

local unsignedCallback = assert(revisions.CreateFCS32Callback({
    fcs32init = function()
        return 0
    end,
    fcs32update = function(_, _, value)
        AssertEqual(value, "value", "alternate FCS32 update input")
        return 4294967295
    end,
    fcs32final = function(_, code)
        return code
    end,
}))
AssertEqual(unsignedCallback("value"), "ffffffff", "unsigned FCS32 should format identically")

local highBitCallback = assert(revisions.CreateFCS32Callback({
    fcs32init = function()
        return 0
    end,
    fcs32update = function()
        return -2147483648
    end,
    fcs32final = function(_, code)
        return code
    end,
}))
AssertEqual(highBitCallback("value"), "80000000", "high-bit signed FCS32 should normalize portably")

for _, badLibrary in ipairs({
    false,
    {},
    { fcs32init = function() end },
    {
        fcs32init = function() end,
        fcs32update = function() end,
    },
}) do
    local callback, callbackError = revisions.CreateFCS32Callback(badLibrary)
    AssertError(callback, callbackError, "invalid-fcs32-library", "incomplete FCS32 library")
end

local invalidResultCallback = assert(revisions.CreateFCS32Callback({
    fcs32init = function()
        return 0
    end,
    fcs32update = function()
        return 0
    end,
    fcs32final = function()
        return "not-a-number"
    end,
}))
Assert(not pcall(invalidResultCallback, "value"), "non-numeric LibCompress results should raise inside the callback")

local outOfRangeCallback = assert(revisions.CreateFCS32Callback({
    fcs32init = function()
        return 0
    end,
    fcs32update = function()
        return 4294967296
    end,
    fcs32final = function(_, code)
        return code
    end,
}))
Assert(not pcall(outOfRangeCallback, "value"), "out-of-range LibCompress results should raise inside the callback")

local categories, pages = NewCollections()
local context, contextError = revisions.BuildSiblingOrders(categories, pages, 10)
Assert(context and not contextError, "valid selected category should build an order context")
AssertEqual(context.RootSyncId, categories[10].SyncId, "context root identity")
AssertEqual(context.CategoryOrders[10], 1, "selected root always has order one")
AssertEqual(context.PageOrders[20], 1, "SyncId breaks equal-index/equal-name ties")
AssertEqual(context.PageOrders[21], 2, "second equal-index/equal-name page receives the next order")
AssertEqual(context.CategoryOrders[20], 3, "indexed category follows lower indexed pages")
AssertEqual(context.CategoryOrders[30], 4, "unindexed category sorts after indexed siblings")
AssertEqual(context.PageOrders[22], 1, "nested sibling order starts at one")
AssertEqual(context.PageParents[22], categories[20].SyncId, "nested parent uses category SyncId")
Assert(context.IncludedPages[20] == pages[20], "page and category numeric ids remain separate")
Assert(context.IncludedCategories[20] == categories[20], "same numeric id category remains included")

local initializationOrder = {
    { "category", categories[10] },
    { "category", categories[20] },
    { "category", categories[30] },
    { "page", pages[20] },
    { "page", pages[21] },
    { "page", pages[22] },
}
for _, entry in ipairs(initializationOrder) do
    local callbackCalls = 0
    local wire, initializationError = revisions.InitializeLocalRevision(
        entry[1],
        entry[2],
        context,
        audit,
        function(value)
            callbackCalls = callbackCalls + 1
            return TestHash(value)
        end
    )
    Assert(wire and not initializationError, "revision initialization should succeed")
    AssertEqual(callbackCalls, 1, "revision initialization should hash exactly once")
    AssertEqual(entry[2].Revision, 1, "revision initialization starts at one")
    AssertEqual(entry[2].RevisionId, wire.RevisionId, "local and wire content identities should match")
    Assert(schema.ValidateEntity(wire, TestHash), "initialized wire record should pass strict schema validation")
end

local rootWire = assert(revisions.LocalToWire("category", categories[10], context, TestHash))
AssertEqual(rootWire.ParentSyncId, nil, "selected root omits its private local parent")
AssertEqual(rootWire.Order, 1, "selected root ignores its private local index")
AssertEqual(rootWire.Vars, "root=yes", "category variables should map to wire")
AssertEqual(rootWire.Id, nil, "wire records omit local numeric ids")
AssertEqual(rootWire.CategoryId, nil, "wire records omit local parent ids")
AssertEqual(rootWire.Index, nil, "wire records omit local indices")

local rootRevisionId = rootWire.RevisionId
categories[10].CategoryId = 555
categories[10].Index = -25.5
local movedRootWire = assert(revisions.LocalToWire("category", categories[10], context, TestHash))
AssertEqual(movedRootWire.ParentSyncId, nil, "moving the selected root locally does not stale wire parent")
AssertEqual(movedRootWire.Order, 1, "reordering the selected root locally does not stale wire order")
AssertEqual(movedRootWire.RevisionId, rootRevisionId, "private root placement does not change content identity")

pages[21].Index = 6
local crossSiblingWire, crossSiblingError = revisions.LocalToWire("page", pages[20], context, TestHash)
AssertError(crossSiblingWire, crossSiblingError, "stale-order-context", "another sibling reindexed")
pages[21].Index = 5

pages[21].Name = "Renamed sibling"
crossSiblingWire, crossSiblingError = revisions.LocalToWire("page", pages[20], context, TestHash)
AssertError(crossSiblingWire, crossSiblingError, "stale-order-context", "another sibling renamed")
pages[21].Name = "Same"

local addedPage = {
    Id = 23,
    SyncId = SyncId("page", 7),
    OwnerId = installationId,
    CategoryId = 10,
    Index = 6,
    Name = "Added",
    Contents = "",
    Vars = "",
}
pages[23] = addedPage
crossSiblingWire, crossSiblingError = revisions.LocalToWire("page", pages[20], context, TestHash)
AssertError(crossSiblingWire, crossSiblingError, "stale-order-context", "added sibling")
pages[23] = nil

local removedPage = pages[21]
pages[21] = nil
crossSiblingWire, crossSiblingError = revisions.LocalToWire("page", pages[20], context, TestHash)
AssertError(crossSiblingWire, crossSiblingError, "stale-order-context", "removed sibling")
pages[21] = removedPage

local defaultedPageWire = assert(revisions.LocalToWire("page", pages[20], context, TestHash))
AssertEqual(defaultedPageWire.ParentSyncId, rootWire.SyncId, "page parent should map to root SyncId")
AssertEqual(defaultedPageWire.Order, 1, "page order should use normalized dense order")
AssertEqual(defaultedPageWire.Contents, "", "missing legacy page contents should sanitize before hashing")
AssertEqual(defaultedPageWire.Vars, "", "missing legacy page variables should sanitize before hashing")

local page = pages[21]
local initialPageRevisionId = page.RevisionId
local touched, touchError = revisions.TouchLocalRevision("page", page, context, {
    UpdatedAt = 1001,
    UpdatedBy = "Assistant-Realm",
}, TestHash)
Assert(touched and not touchError, "unchanged content may advance numeric revision")
AssertEqual(touched.Revision, 2, "touch increments numeric revision")
AssertEqual(touched.RevisionId, initialPageRevisionId, "content identity excludes numeric and audit metadata")
AssertEqual(page.UpdatedBy, "Assistant-Realm", "touch commits new audit author")

page.Contents = "changed"
local changedWire = assert(revisions.TouchLocalRevision("page", page, context, {
    UpdatedAt = 1002,
    UpdatedBy = "Leader-Realm",
}, TestHash))
AssertEqual(changedWire.Revision, 3, "second touch increments revision again")
Assert(changedWire.RevisionId ~= initialPageRevisionId, "behavioral content changes content identity")

local pageBeforeReorder = pages[20].RevisionId
pages[20].Index = 20
local staleOrderSnapshot = SnapshotRevision(pages[20])
local staleOrderWire, staleOrderError = revisions.TouchLocalRevision("page", pages[20], context, {
    UpdatedAt = 1003,
    UpdatedBy = "Leader-Realm",
}, TestHash)
AssertError(staleOrderWire, staleOrderError, "stale-order-context", "mutated ordering context")
AssertRevisionSnapshot(pages[20], staleOrderSnapshot, "stale ordering context")

local reorderedContext = assert(revisions.BuildSiblingOrders(categories, pages, 10))
local reorderedWire = assert(revisions.TouchLocalRevision("page", pages[20], reorderedContext, {
    UpdatedAt = 1003,
    UpdatedBy = "Leader-Realm",
}, TestHash))
Assert(reorderedWire.RevisionId ~= pageBeforeReorder, "normalized hierarchy order participates in content identity")
AssertEqual(reorderedWire.Order, 3, "changed fractional ordering is renormalized densely")

local staleSiblingWire, staleSiblingError =
    revisions.LocalToWire("category", categories[20], reorderedContext, TestHash)
AssertError(
    staleSiblingWire,
    staleSiblingError,
    "revision-id-mismatch",
    "siblings shifted by reordering require their own canonical revision"
)

local alreadyInitializedSnapshot = SnapshotRevision(categories[10])
local initializedAgain =
    assert(revisions.InitializeLocalRevision("category", categories[10], reorderedContext, audit, TestHash))
Assert(initializedAgain, "complete revision initialization should be idempotent")
AssertRevisionSnapshot(categories[10], alreadyInitializedSnapshot, "idempotent initialization")

local invalidIdempotent, invalidIdempotentError =
    revisions.InitializeLocalRevision("category", categories[10], reorderedContext, {
        Unexpected = true,
    }, TestHash)
AssertError(
    invalidIdempotent,
    invalidIdempotentError,
    "revision-audit-unknown-field",
    "idempotent initialization still validates audit input"
)
AssertRevisionSnapshot(categories[10], alreadyInitializedSnapshot, "invalid idempotent audit")

local invalidCategories, invalidPages = NewCollections()
invalidPages[20].Name = " "
local invalidContext = assert(revisions.BuildSiblingOrders(invalidCategories, invalidPages, 10))
local invalidSnapshot = SnapshotRevision(invalidPages[20])
local invalidWire, invalidWireError =
    revisions.InitializeLocalRevision("page", invalidPages[20], invalidContext, audit, TestHash)
AssertError(invalidWire, invalidWireError, "invalid-name", "invalid local content")
AssertRevisionSnapshot(invalidPages[20], invalidSnapshot, "failed initialization")

invalidCategories, invalidPages = NewCollections()
invalidContext = assert(revisions.BuildSiblingOrders(invalidCategories, invalidPages, 10))
local hashFailureSnapshot = SnapshotRevision(invalidPages[20])
local hashFailure, hashFailureError = revisions.InitializeLocalRevision(
    "page",
    invalidPages[20],
    invalidContext,
    audit,
    function()
        error("hash failure")
    end
)
AssertError(hashFailure, hashFailureError, "hash-failed", "throwing initialization hash")
AssertRevisionSnapshot(invalidPages[20], hashFailureSnapshot, "throwing hash initialization")

invalidPages[20].Revision = 1
local partialSnapshot = SnapshotRevision(invalidPages[20])
local partial, partialError =
    revisions.InitializeLocalRevision("page", invalidPages[20], invalidContext, audit, TestHash)
AssertError(partial, partialError, "partial-revision-metadata", "partial revision initialization")
AssertRevisionSnapshot(invalidPages[20], partialSnapshot, "partial initialization")

local failurePage = page
local validContents = failurePage.Contents
failurePage.Contents = string.rep("x", schema.LIMITS.ContentsBytes + 1)
local failureSnapshot = SnapshotRevision(failurePage)
local failedTouch, failedTouchError = revisions.TouchLocalRevision("page", failurePage, reorderedContext, {
    UpdatedAt = 1004,
    UpdatedBy = "Leader-Realm",
}, TestHash)
AssertError(failedTouch, failedTouchError, "invalid-contents", "oversized touch")
AssertRevisionSnapshot(failurePage, failureSnapshot, "oversized touch")
failurePage.Contents = validContents

failureSnapshot = SnapshotRevision(failurePage)
failedTouch, failedTouchError = revisions.TouchLocalRevision("page", failurePage, reorderedContext, {
    UpdatedAt = 1004,
    UpdatedBy = "Leader-Realm",
    Extra = true,
}, TestHash)
AssertError(failedTouch, failedTouchError, "revision-audit-unknown-field", "unknown audit field")
AssertRevisionSnapshot(failurePage, failureSnapshot, "invalid audit touch")

failureSnapshot = SnapshotRevision(failurePage)
failedTouch, failedTouchError = revisions.TouchLocalRevision("page", failurePage, reorderedContext, audit, function()
    return "UPPERBAD"
end)
AssertError(failedTouch, failedTouchError, "hash-failed", "invalid hash output touch")
AssertRevisionSnapshot(failurePage, failureSnapshot, "invalid hash output touch")

failurePage.Revision = schema.LIMITS.Revision
failureSnapshot = SnapshotRevision(failurePage)
failedTouch, failedTouchError = revisions.TouchLocalRevision("page", failurePage, reorderedContext, audit, TestHash)
AssertError(failedTouch, failedTouchError, "revision-exhausted", "maximum numeric revision")
AssertRevisionSnapshot(failurePage, failureSnapshot, "exhausted revision touch")

local malformedCollections = {
    {
        categories = setmetatable({}, {}),
        pages = {},
        root = 1,
        expected = "invalid-local-collections",
    },
    {
        categories = {},
        pages = {},
        root = 1,
        expected = "missing-root-category",
    },
    {
        categories = {},
        pages = {},
        root = 0,
        expected = "invalid-root-category-id",
    },
}
for _, malformed in ipairs(malformedCollections) do
    local value, valueError = revisions.BuildSiblingOrders(malformed.categories, malformed.pages, malformed.root)
    AssertError(value, valueError, malformed.expected, "malformed order context")
end

local badCategories, badPages = NewCollections()
badPages[20].Index = 0 / 0
local badContext, badContextError = revisions.BuildSiblingOrders(badCategories, badPages, 10)
AssertError(badContext, badContextError, "invalid-local-index", "NaN local index")

badCategories, badPages = NewCollections()
badPages[20].Id = 99
badContext, badContextError = revisions.BuildSiblingOrders(badCategories, badPages, 10)
AssertError(badContext, badContextError, "invalid-local-id", "mismatched local id")

badCategories, badPages = NewCollections()
badPages[21].SyncId = badPages[20].SyncId
badContext, badContextError = revisions.BuildSiblingOrders(badCategories, badPages, 10)
AssertError(badContext, badContextError, "duplicate-local-sync-id", "duplicate local SyncId")

badCategories, badPages = NewCollections()
badCategories[10].CategoryId = 20
badContext, badContextError = revisions.BuildSiblingOrders(badCategories, badPages, 10)
AssertError(badContext, badContextError, nil, "root-descendant local cycle")

local deepCategories = {}
for id = 1, schema.LIMITS.HierarchyDepth do
    deepCategories[id] = {
        Id = id,
        SyncId = SyncId("category", 100 + id),
        OwnerId = installationId,
        CategoryId = id > 1 and id - 1 or nil,
        Index = id,
        Name = "Depth " .. id,
        Vars = "",
    }
end
Assert(revisions.BuildSiblingOrders(deepCategories, {}, 1), "maximum hierarchy depth should succeed")
deepCategories[schema.LIMITS.HierarchyDepth + 1] = {
    Id = schema.LIMITS.HierarchyDepth + 1,
    SyncId = SyncId("category", 200),
    OwnerId = installationId,
    CategoryId = schema.LIMITS.HierarchyDepth,
    Index = 1,
    Name = "Too Deep",
    Vars = "",
}
badContext, badContextError = revisions.BuildSiblingOrders(deepCategories, {}, 1)
AssertError(badContext, badContextError, "hierarchy-too-deep", "overlong hierarchy")

local largeCategories = {
    [1] = {
        Id = 1,
        SyncId = SyncId("category", 300),
        OwnerId = installationId,
        Name = "Large Root",
        Vars = "",
    },
}
local largePages = {}
for id = 1, schema.LIMITS.EntityCount - 1 do
    largePages[id] = {
        Id = id,
        SyncId = SyncId("page", 300 + id),
        OwnerId = installationId,
        CategoryId = 1,
        Index = id,
        Name = "Page " .. id,
        Contents = "",
        Vars = "",
    }
end
Assert(revisions.BuildSiblingOrders(largeCategories, largePages, 1), "maximum scope entity count should succeed")
local excessiveId = schema.LIMITS.EntityCount
largePages[excessiveId] = {
    Id = excessiveId,
    SyncId = SyncId("page", 300 + excessiveId),
    OwnerId = installationId,
    CategoryId = 1,
    Index = excessiveId,
    Name = "One Too Many",
    Contents = "",
    Vars = "",
}
badContext, badContextError = revisions.BuildSiblingOrders(largeCategories, largePages, 1)
AssertError(badContext, badContextError, "too-many-scope-entities", "scope entity limit")

rootWire = assert(revisions.LocalToWire("category", categories[10], reorderedContext, TestHash))
local history = {
    {
        timestamp = 900,
        content = "old",
        author = "Local",
    },
}
local mapped, mappedError = revisions.WireToLocal(rootWire, {
    Id = 500,
    CategoryId = 777,
    Index = 42.5,
    Backup = "backup",
    History = history,
    UpdateId = -123,
    Updated = 999,
}, TestHash)
Assert(mapped and not mappedError, "validated wire record should map to local fields")
AssertEqual(mapped.Id, 500, "explicit local id should be preserved")
AssertEqual(mapped.CategoryId, 777, "root private parent overlay should be preserved")
AssertEqual(mapped.Index, 42.5, "root private index overlay should be preserved")
AssertEqual(mapped.ParentSyncId, nil, "wire parent relationship is not copied into local fields")
AssertEqual(mapped.Order, nil, "wire order is not copied into local fields")
AssertEqual(mapped.Kind, nil, "wire-only kind is not persisted locally")
AssertEqual(mapped.Name, rootWire.Name, "authoritative name should map from wire")
Assert(mapped.History ~= history and mapped.History[1] ~= history[1], "preserved local tables should be copied")
history[1].content = "mutated"
AssertEqual(mapped.History[1].content, "old", "mapped local history should not alias caller tables")

local mappedWithoutLocal = assert(revisions.WireToLocal(rootWire, nil, TestHash))
for _, key in ipairs({ "Id", "CategoryId", "Index", "Backup", "History", "UpdateId", "Updated" }) do
    AssertEqual(mappedWithoutLocal[key], nil, "local field " .. key .. " requires explicit preservation")
end

for _, injectedLocal in ipairs({
    { Name = "Injected" },
    { Pinned = true },
    { OwnedLocally = true },
    { ParentSyncId = SyncId("category", 99) },
}) do
    local injected, injectedError = revisions.WireToLocal(rootWire, injectedLocal, TestHash)
    AssertError(injected, injectedError, "unsupported-local-field", "unsupported local field")
end

local cyclicHistory = {}
cyclicHistory[1] = cyclicHistory
local cyclicLocal, cyclicLocalError = revisions.WireToLocal(rootWire, {
    History = cyclicHistory,
}, TestHash)
AssertError(cyclicLocal, cyclicLocalError, "cyclic-local-field", "cyclic local history")

local nonfiniteLocal, nonfiniteLocalError = revisions.WireToLocal(rootWire, {
    History = {
        timestamp = 0 / 0,
    },
}, TestHash)
AssertError(nonfiniteLocal, nonfiniteLocalError, "invalid-local-field-value", "non-finite local history value")

local malformedLocal, malformedLocalError = revisions.WireToLocal(rootWire, {
    CategoryId = -1,
}, TestHash)
AssertError(malformedLocal, malformedLocalError, "invalid-local-field", "invalid preserved category id")

malformedLocal, malformedLocalError = revisions.WireToLocal(rootWire, setmetatable({}, {}), TestHash)
AssertError(malformedLocal, malformedLocalError, "invalid-local-fields", "metatable local fields")

local extraWire = {}
for key, value in pairs(rootWire) do
    extraWire[key] = value
end
extraWire.Pinned = true
local extraMapped, extraMappedError = revisions.WireToLocal(extraWire, nil, TestHash)
AssertError(extraMapped, extraMappedError, "entity-unknown-field", "local provenance from wire")

local mismatchedWire = {}
for key, value in pairs(rootWire) do
    mismatchedWire[key] = value
end
mismatchedWire.Name = "Changed after hash"
local mismatchedMapped, mismatchedMappedError = revisions.WireToLocal(mismatchedWire, nil, TestHash)
AssertError(mismatchedMapped, mismatchedMappedError, "revision-id-mismatch", "wire content identity mismatch")

local callbackMutationWire = {}
for key, value in pairs(rootWire) do
    callbackMutationWire[key] = value
end
local callbackMutationMapped = assert(revisions.WireToLocal(callbackMutationWire, nil, function(value)
    callbackMutationWire.Name = "Mutated during hashing"
    return TestHash(value)
end))
AssertEqual(
    callbackMutationMapped.Name,
    rootWire.Name,
    "wire mapping should use a snapshot that cannot change during hash validation"
)

local noDefaultCategories, noDefaultPages = NewCollections()
local noDefaultContext = assert(revisions.BuildSiblingOrders(noDefaultCategories, noDefaultPages, 10))
local defaultWire =
    assert(revisions.InitializeLocalRevision("category", noDefaultCategories[10], noDefaultContext, audit))
AssertEqual(defaultWire.RevisionId, "fcs32:ffffffff", "omitted callback should use production LibCompress wrapper")

print(string.format("Synchronization revision adapter tests passed (%d assertions).", assertions))
