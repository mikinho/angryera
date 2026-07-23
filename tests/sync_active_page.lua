local app = {
    AngryEra = {
        utils = {},
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/protocol.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/active_page.lua"))("AngryEra", app)

local protocol = app.AngryEra.utils.protocol
local variables = app.AngryEra.utils.variables
local schema = app.AngryEra.sync.schema
local activePage = app.AngryEra.sync.activePage
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

local function DeepEqual(left, right, seen)
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return left == right
    end

    seen = seen or {}
    if seen[left] then
        return seen[left] == right
    end
    seen[left] = right
    for key, value in pairs(left) do
        if not DeepEqual(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function TestHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local installationId = "ae3i:1:2:3:4"
local rootSyncId = installationId .. ":category:1"
local parentSyncId = installationId .. ":category:2"
local pageSyncId = installationId .. ":page:3"

local function MakePage(parent)
    local page = {
        Kind = "page",
        SyncId = pageSyncId,
        OwnerId = installationId,
        Revision = 3,
        UpdatedAt = 1000,
        UpdatedBy = "Leader-Realm",
        ParentSyncId = parent,
        Order = 2,
        Name = "Active Page",
        Vars = "role=page\npageOnly=yes",
        Contents = "{{role}} {{rootOnly}}",
    }
    page.RevisionId = assert(schema.BuildEntityRevisionId(page, TestHash))
    return page
end

local function MakeLayers()
    return {
        {
            SyncId = rootSyncId,
            Vars = "role=root\nrootOnly=yes",
        },
        {
            SyncId = parentSyncId,
            Vars = "role=parent",
        },
    }
end

local page = MakePage(parentSyncId)
local layers = MakeLayers()
local contextRevisionId, contextError =
    activePage.BuildContextRevisionId(layers, page.Vars, page.ParentSyncId, TestHash)
Assert(contextRevisionId ~= nil and contextError == nil, "valid context identity builds")
Assert(
    contextRevisionId:match("^fcs32:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"),
    "context identity format"
)

local canonicalContext = assert(variables.BuildContextRevisionInput(layers, page.Vars))
AssertEqual(contextRevisionId, "fcs32:" .. TestHash(canonicalContext), "context identity hashes canonical input")

local payload, payloadError = activePage.BuildPageUpsertPayload(page, layers, TestHash)
Assert(payload ~= nil and payloadError == nil, "valid detached payload builds")
Assert(payload.Page ~= page, "payload page is detached")
Assert(payload.AncestorVariableLayers ~= layers, "payload layer array is detached")
Assert(payload.AncestorVariableLayers[1] ~= layers[1], "payload layer records are detached")
AssertEqual(payload.ContextRevisionId, contextRevisionId, "payload carries canonical context identity")

local payloadSnapshot = DeepCopy(payload)
local valid, validationError, validatedPayload = activePage.ValidatePageUpsertPayload(payload, TestHash)
Assert(valid and validationError == nil, "built payload fully validates")
Assert(DeepEqual(payload, payloadSnapshot), "full validation does not mutate its input")
Assert(
    validatedPayload ~= payload and validatedPayload.Page ~= payload.Page,
    "full validation returns a detached payload"
)
Assert(
    validatedPayload.AncestorVariableLayers ~= payload.AncestorVariableLayers
        and validatedPayload.AncestorVariableLayers[1] ~= payload.AncestorVariableLayers[1],
    "full validation detaches ancestor layers"
)
validatedPayload.Page.Name = "Validated copy"
validatedPayload.AncestorVariableLayers[1].Vars = "validated=copy"
AssertEqual(payload.Page.Name, "Active Page", "validated page copy cannot mutate packet")
AssertEqual(payload.AncestorVariableLayers[1].Vars, "role=root\nrootOnly=yes", "validated layers cannot mutate packet")
local shallowValid, shallowError = protocol.ValidatePayload("PAGE_UPSERT", payload)
Assert(shallowValid and shallowError == nil, "built payload passes protocol bounds")

page.Name = "Changed after build"
layers[1].Vars = "changed=yes"
AssertEqual(payload.Page.Name, "Active Page", "caller page mutation cannot change payload")
AssertEqual(
    payload.AncestorVariableLayers[1].Vars,
    "role=root\nrootOnly=yes",
    "caller layer mutation cannot change payload"
)

payload.Page.Contents = "Changed payload"
AssertEqual(page.Contents, "{{role}} {{rootOnly}}", "payload page mutation cannot change caller page")
payload.AncestorVariableLayers[2].Vars = "changed=payload"
AssertEqual(layers[2].Vars, "role=parent", "payload layer mutation cannot change caller layer")

payload = assert(activePage.BuildPageUpsertPayload(MakePage(parentSyncId), MakeLayers(), TestHash))

local tampered = DeepCopy(payload)
tampered.Page.Contents = "Tampered"
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, TestHash)
AssertError(valid, validationError, "revision-id-mismatch", "tampered page content")

tampered = DeepCopy(payload)
tampered.ContextRevisionId = "fcs32:00000000"
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, TestHash)
AssertError(valid, validationError, "context-revision-id-mismatch", "tampered context identity")

tampered = DeepCopy(payload)
tampered.AncestorVariableLayers[1].Vars = "role=changed"
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, TestHash)
AssertError(valid, validationError, "context-revision-id-mismatch", "tampered context variables")

tampered = DeepCopy(payload)
tampered.AncestorVariableLayers[2].SyncId = rootSyncId
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, TestHash)
AssertError(valid, validationError, "duplicate-ancestor", "duplicate ancestor identity")

tampered = DeepCopy(payload)
tampered.Page.ParentSyncId = rootSyncId
tampered.Page.RevisionId = assert(schema.BuildEntityRevisionId(tampered.Page, TestHash))
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, TestHash)
AssertError(valid, validationError, "parent-mismatch", "ancestor direct-parent mismatch")

tampered = DeepCopy(payload)
tampered.Page.OwnerId = "ae3i:a:b:c:d"
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, TestHash)
AssertError(valid, validationError, "owner-mismatch", "page ownership mismatch")

tampered = DeepCopy(payload)
tampered.Page.Name = " Active Page"
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, TestHash)
AssertError(valid, validationError, "invalid-name", "noncanonical page name")

tampered = DeepCopy(payload)
tampered.Unknown = true
local shallowHashCalls = 0
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, function(value)
    shallowHashCalls = shallowHashCalls + 1
    return TestHash(value)
end)
AssertError(valid, validationError, "page-upsert-unknown-field", "unknown payload field")
AssertEqual(shallowHashCalls, 0, "shallow payload failures do not invoke FCS")

tampered = DeepCopy(payload)
tampered.Page.Contents = "Tampered"
tampered.AncestorVariableLayers[2].SyncId = rootSyncId
local fullHashCalls = 0
valid, validationError = activePage.ValidatePageUpsertPayload(tampered, function(value)
    fullHashCalls = fullHashCalls + 1
    return TestHash(value)
end)
AssertError(valid, validationError, "revision-id-mismatch", "entity identity is checked before layer semantics")
AssertEqual(fullHashCalls, 1, "entity failure stops before context FCS")

local rootPage = MakePage(nil)
rootPage.Order = 1
rootPage.RevisionId = assert(schema.BuildEntityRevisionId(rootPage, TestHash))
local rootPayload, rootPayloadError = activePage.BuildPageUpsertPayload(rootPage, {}, TestHash)
Assert(rootPayload ~= nil and rootPayloadError == nil, "root page accepts empty ancestor context")
valid, validationError = activePage.ValidatePageUpsertPayload(rootPayload, TestHash)
Assert(valid and validationError == nil, "root page payload fully validates")

local invalidPayload, invalidPayloadError =
    activePage.BuildPageUpsertPayload(MakePage(parentSyncId), { MakeLayers()[1] }, TestHash)
AssertError(invalidPayload, invalidPayloadError, "parent-mismatch", "builder rejects missing direct-parent layer")

local metatableLayers = MakeLayers()
setmetatable(metatableLayers, {})
invalidPayload, invalidPayloadError =
    activePage.BuildPageUpsertPayload(MakePage(parentSyncId), metatableLayers, TestHash)
AssertError(invalidPayload, invalidPayloadError, "invalid-ancestor-layers", "builder rejects metatable layers")

metatableLayers = MakeLayers()
setmetatable(metatableLayers[1], {})
invalidPayload, invalidPayloadError =
    activePage.BuildPageUpsertPayload(MakePage(parentSyncId), metatableLayers, TestHash)
AssertError(invalidPayload, invalidPayloadError, "invalid-ancestor-layer", "builder rejects metatable layer")

invalidPayload, invalidPayloadError = activePage.BuildPageUpsertPayload(MakePage(parentSyncId), MakeLayers(), nil)
AssertError(invalidPayload, invalidPayloadError, "invalid-hash-callback", "builder requires hash callback")

local badContext, badContextError = activePage.BuildContextRevisionId(
    MakeLayers(),
    MakePage(parentSyncId).Vars,
    parentSyncId,
    function()
        error("hash")
    end
)
AssertError(badContext, badContextError, "context-hash-failed", "context hash exception")

for _, invalidDigest in ipairs({
    "",
    "1234567",
    "123456789",
    "ABCDEF12",
    12345678,
}) do
    badContext, badContextError = activePage.BuildContextRevisionId(
        MakeLayers(),
        MakePage(parentSyncId).Vars,
        parentSyncId,
        function()
            return invalidDigest
        end
    )
    AssertError(badContext, badContextError, "context-hash-failed", "invalid context digest")
end

local reorderedLayers = MakeLayers()
reorderedLayers[1], reorderedLayers[2] = reorderedLayers[2], reorderedLayers[1]
local reorderedContext =
    assert(activePage.BuildContextRevisionId(reorderedLayers, MakePage(parentSyncId).Vars, rootSyncId, TestHash))
Assert(reorderedContext ~= contextRevisionId, "ancestor order changes context identity")

local changedPageVariables =
    assert(activePage.BuildContextRevisionId(MakeLayers(), "role=other", parentSyncId, TestHash))
Assert(changedPageVariables ~= contextRevisionId, "page variables change context identity")

local sourcePage = MakePage(parentSyncId)
local sourcePageSnapshot = DeepCopy(sourcePage)
invalidPayload, invalidPayloadError = activePage.BuildPageUpsertPayload(sourcePage, MakeLayers(), function()
    return "invalid"
end)
AssertError(invalidPayload, invalidPayloadError, "hash-failed", "invalid entity hash callback result")
for key, value in pairs(sourcePageSnapshot) do
    AssertEqual(sourcePage[key], value, "failed build preserves source page " .. key)
end

local function LocalSyncId(kind, sequence)
    return string.format("%s:%s:%d", installationId, kind, sequence)
end

local function MakeLocalCollections()
    local categories = {
        [1] = {
            Id = 1,
            SyncId = LocalSyncId("category", 10),
            OwnerId = installationId,
            Index = 5,
            Name = "Top",
            Vars = "top=yes",
        },
        [2] = {
            Id = 2,
            SyncId = LocalSyncId("category", 11),
            OwnerId = installationId,
            CategoryId = 1,
            Index = 2,
            Name = "Managed",
            Vars = "managed=yes",
        },
        [3] = {
            Id = 3,
            SyncId = LocalSyncId("category", 12),
            OwnerId = installationId,
            CategoryId = 2,
            Index = 3,
            Name = "Parent",
            Vars = "parent=yes",
        },
        [4] = {
            Id = 4,
            SyncId = LocalSyncId("category", 13),
            OwnerId = installationId,
            CategoryId = 3,
            Index = 1,
            Name = "Before",
            Vars = "",
        },
    }
    local pages = {
        [100] = {
            Id = 100,
            SyncId = LocalSyncId("page", 20),
            OwnerId = installationId,
            CategoryId = 3,
            Index = 10,
            Name = "Target",
            Vars = "page=yes",
            Contents = "initial",
        },
        [101] = {
            Id = 101,
            SyncId = LocalSyncId("page", 22),
            OwnerId = installationId,
            CategoryId = 3,
            Index = 5,
            Name = "Page Before",
            Vars = "",
            Contents = "",
        },
        [102] = {
            Id = 102,
            SyncId = LocalSyncId("page", 21),
            OwnerId = installationId,
            CategoryId = 3,
            Index = 10,
            Name = "Target",
            Vars = "",
            Contents = "",
        },
        [200] = {
            Id = 200,
            SyncId = LocalSyncId("page", 30),
            OwnerId = installationId,
            Index = 10,
            Name = "Orphan",
            Vars = "",
            Contents = "root",
        },
    }
    return categories, pages
end

local function PreparationOptions(updatedAt, managedScopeId)
    return {
        UpdatedAt = updatedAt,
        UpdatedBy = "Leader-Realm",
        ManagedScopeId = managedScopeId,
    }
end

local localCategories, localPages = MakeLocalCollections()
local managedScopeId = localCategories[2].SyncId
local prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2000, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "missing local revision should prepare")
AssertEqual(preparation.RevisionAction, "initialized", "first preparation initializes revision metadata")
AssertEqual(localPages[100].Revision, 1, "initial preparation starts at revision one")
AssertEqual(localPages[100].RevisionId, prepared.Page.RevisionId, "prepared identity commits to the local page")
AssertEqual(prepared.Page.Order, 3, "mixed siblings receive deterministic dense order")
AssertEqual(prepared.Page.ParentSyncId, localCategories[3].SyncId, "direct parent maps to its SyncId")
AssertEqual(#prepared.AncestorVariableLayers, 2, "managed boundary trims private ancestors")
AssertEqual(prepared.AncestorVariableLayers[1].SyncId, managedScopeId, "managed root is the first layer")
AssertEqual(prepared.AncestorVariableLayers[2].SyncId, localCategories[3].SyncId, "direct parent is the final layer")
AssertEqual(preparation.BoundarySyncId, managedScopeId, "preparation reports the selected managed boundary")

local overlayCategories, overlayPages = MakeLocalCollections()
overlayCategories[2].CategoryId = 999
local overlayPayload, overlayError = activePage.PrepareLocalPageUpsert(
    overlayCategories,
    overlayPages,
    100,
    PreparationOptions(2000, overlayCategories[2].SyncId),
    TestHash
)
Assert(overlayPayload and not overlayError, "managed root ignores its private local parent overlay")
AssertEqual(#overlayPayload.AncestorVariableLayers, 2, "private root overlay stays outside the managed context")

local initializedRevisionId = localPages[100].RevisionId
prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2001, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "unchanged local page should prepare")
AssertEqual(preparation.RevisionAction, "unchanged", "unchanged preparation does not touch")
AssertEqual(localPages[100].Revision, 1, "unchanged preparation does not bump the revision")
AssertEqual(localPages[100].UpdatedAt, 2000, "unchanged preparation preserves the prior audit time")

local topmostPayload, topmostError, topmostPreparation =
    activePage.PrepareLocalPageUpsert(localCategories, localPages, 100, PreparationOptions(2002), TestHash)
Assert(topmostPayload and not topmostError, "unmanaged local page should prepare")
AssertEqual(#topmostPayload.AncestorVariableLayers, 3, "unmanaged context starts at the topmost ancestor")
AssertEqual(
    topmostPayload.AncestorVariableLayers[1].SyncId,
    localCategories[1].SyncId,
    "topmost ancestor is the fallback boundary"
)
AssertEqual(
    topmostPreparation.RevisionAction,
    "unchanged",
    "changing only the render-context boundary does not touch the page"
)
AssertEqual(localPages[100].RevisionId, initializedRevisionId, "context boundary is excluded from page identity")

local contextBeforeAncestorChange = prepared.ContextRevisionId
localCategories[2].Vars = "managed=changed"
prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2003, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "changed inherited variables should prepare")
Assert(prepared.ContextRevisionId ~= contextBeforeAncestorChange, "ancestor variables change context identity")
AssertEqual(preparation.RevisionAction, "unchanged", "ancestor variables do not touch the page revision")
AssertEqual(localPages[100].Revision, 1, "ancestor-only changes leave page revision unchanged")

localPages[100].Contents = "changed contents"
prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2004, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "changed page contents should prepare")
AssertEqual(preparation.RevisionAction, "touched", "changed contents touch the page")
AssertEqual(localPages[100].Revision, 2, "changed contents increment exactly once")

localPages[100].Name = "Renamed Target"
prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2005, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "renamed page should prepare")
AssertEqual(preparation.RevisionAction, "touched", "changed name touches the page")
AssertEqual(localPages[100].Revision, 3, "changed name increments exactly once")

localPages[100].Vars = "page=changed"
prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2006, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "changed page variables should prepare")
AssertEqual(preparation.RevisionAction, "touched", "changed page variables touch the page")
AssertEqual(localPages[100].Revision, 4, "changed page variables increment exactly once")

localPages[100].Index = 9
prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2007, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "raw index change with stable dense order should prepare")
AssertEqual(prepared.Page.Order, 3, "stable normalized placement keeps its dense order")
AssertEqual(preparation.RevisionAction, "unchanged", "noncanonical index changes do not touch the page")
AssertEqual(localPages[100].Revision, 4, "stable canonical placement preserves the revision")

localPages[100].Index = 0
prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2008, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "reordered page should prepare")
AssertEqual(prepared.Page.Order, 1, "fractional local placement is normalized after reorder")
AssertEqual(preparation.RevisionAction, "touched", "changed canonical order touches the page")
AssertEqual(localPages[100].Revision, 5, "changed order increments exactly once")

prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2009, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "repeated reordered page should prepare")
AssertEqual(preparation.RevisionAction, "unchanged", "repeated preparation does not touch twice")
AssertEqual(localPages[100].Revision, 5, "repeated preparation preserves the revision")

localPages[100].CategoryId = 2
prepared, preparationError, preparation = activePage.PrepareLocalPageUpsert(
    localCategories,
    localPages,
    100,
    PreparationOptions(2010, managedScopeId),
    TestHash
)
Assert(prepared and not preparationError, "page moved inside its managed scope should prepare")
AssertEqual(prepared.Page.ParentSyncId, managedScopeId, "moved page publishes its new direct parent")
AssertEqual(#prepared.AncestorVariableLayers, 1, "moved page context ends at its new direct parent")
AssertEqual(preparation.RevisionAction, "touched", "changed canonical parent touches the page")
AssertEqual(localPages[100].Revision, 6, "changed parent increments exactly once")

local orphanPayload, orphanError, orphanPreparation =
    activePage.PrepareLocalPageUpsert(localCategories, localPages, 200, PreparationOptions(2011), TestHash)
Assert(orphanPayload and not orphanError, "orphan page should prepare")
AssertEqual(orphanPayload.Page.ParentSyncId, nil, "orphan page has no wire parent")
AssertEqual(orphanPayload.Page.Order, 2, "orphan order includes root categories")
AssertEqual(#orphanPayload.AncestorVariableLayers, 0, "orphan page has no ancestor layers")
AssertEqual(orphanPreparation.BoundarySyncId, nil, "orphan page has no context boundary")
AssertEqual(orphanPreparation.RevisionAction, "initialized", "orphan revision initializes once")

local siblingCategories, siblingPages = MakeLocalCollections()
local siblingScopeId = siblingCategories[2].SyncId
assert(
    activePage.PrepareLocalPageUpsert(
        siblingCategories,
        siblingPages,
        100,
        PreparationOptions(2012, siblingScopeId),
        TestHash
    )
)
siblingPages[101].Index = 20
local siblingPayload, siblingError, siblingPreparation = activePage.PrepareLocalPageUpsert(
    siblingCategories,
    siblingPages,
    100,
    PreparationOptions(2013, siblingScopeId),
    TestHash
)
Assert(siblingPayload and not siblingError, "sibling-driven placement change should prepare")
AssertEqual(siblingPayload.Page.Order, 2, "sibling movement recomputes deterministic target order")
AssertEqual(siblingPreparation.RevisionAction, "touched", "changed sibling-derived placement touches the page")
AssertEqual(siblingPages[100].Revision, 2, "sibling-derived placement increments exactly once")

local invalidCategories
local invalidPages
local invalidOptions
local beforeFailure

invalidCategories, invalidPages = MakeLocalCollections()
invalidPages[100].Revision = 1
beforeFailure = DeepCopy(invalidPages[100])
local failedPreparation, failedPreparationError = activePage.PrepareLocalPageUpsert(
    invalidCategories,
    invalidPages,
    100,
    PreparationOptions(3000, invalidCategories[2].SyncId),
    TestHash
)
AssertError(failedPreparation, failedPreparationError, "partial-revision-metadata", "partial revision metadata")
Assert(DeepEqual(invalidPages[100], beforeFailure), "partial revision failure is atomic")

invalidCategories, invalidPages = MakeLocalCollections()
invalidPages[100].CategoryId = 999
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError =
    activePage.PrepareLocalPageUpsert(invalidCategories, invalidPages, 100, PreparationOptions(3001), TestHash)
AssertError(failedPreparation, failedPreparationError, "missing-category", "missing ancestor")
Assert(DeepEqual(invalidPages[100], beforeFailure), "missing ancestor failure is atomic")

invalidCategories, invalidPages = MakeLocalCollections()
invalidCategories[1].CategoryId = 3
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError =
    activePage.PrepareLocalPageUpsert(invalidCategories, invalidPages, 100, PreparationOptions(3002), TestHash)
AssertError(failedPreparation, failedPreparationError, "cycle", "ancestor cycle")
Assert(DeepEqual(invalidPages[100], beforeFailure), "cycle failure is atomic")

invalidCategories, invalidPages = MakeLocalCollections()
invalidCategories[2].Id = 999
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError =
    activePage.PrepareLocalPageUpsert(invalidCategories, invalidPages, 100, PreparationOptions(3003), TestHash)
AssertError(failedPreparation, failedPreparationError, "category-id-mismatch", "stale ancestor reference")
Assert(DeepEqual(invalidPages[100], beforeFailure), "stale ancestor failure is atomic")

invalidCategories, invalidPages = MakeLocalCollections()
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError = activePage.PrepareLocalPageUpsert(
    invalidCategories,
    invalidPages,
    100,
    PreparationOptions(3004, invalidCategories[4].SyncId),
    TestHash
)
AssertError(failedPreparation, failedPreparationError, "managed-scope-not-ancestor", "stale managed scope reference")
Assert(DeepEqual(invalidPages[100], beforeFailure), "stale managed scope failure is atomic")

invalidCategories, invalidPages = MakeLocalCollections()
invalidPages[100].Id = 999
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError = activePage.PrepareLocalPageUpsert(
    invalidCategories,
    invalidPages,
    100,
    PreparationOptions(3005, invalidCategories[2].SyncId),
    TestHash
)
AssertError(failedPreparation, failedPreparationError, "invalid-local-id", "stale page reference")
Assert(DeepEqual(invalidPages[100], beforeFailure), "stale page failure is atomic")

invalidCategories, invalidPages = MakeLocalCollections()
invalidPages[300] = DeepCopy(invalidPages[100])
invalidPages[300].Id = 300
invalidPages[300].CategoryId = 2
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError = activePage.PrepareLocalPageUpsert(
    invalidCategories,
    invalidPages,
    100,
    PreparationOptions(3006, invalidCategories[2].SyncId),
    TestHash
)
AssertError(failedPreparation, failedPreparationError, "duplicate-local-sync-id", "duplicate target identity")
Assert(DeepEqual(invalidPages[100], beforeFailure), "duplicate target identity failure is atomic")

invalidCategories, invalidPages = MakeLocalCollections()
invalidCategories[5] = DeepCopy(invalidCategories[3])
invalidCategories[5].Id = 5
invalidCategories[5].CategoryId = 1
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError = activePage.PrepareLocalPageUpsert(
    invalidCategories,
    invalidPages,
    100,
    PreparationOptions(3007, invalidCategories[2].SyncId),
    TestHash
)
AssertError(failedPreparation, failedPreparationError, "duplicate-local-sync-id", "duplicate ancestor identity")
Assert(DeepEqual(invalidPages[100], beforeFailure), "duplicate ancestor identity failure is atomic")

invalidCategories, invalidPages = MakeLocalCollections()
beforeFailure = DeepCopy(invalidPages[100])
local preparationHashCalls = 0
failedPreparation, failedPreparationError = activePage.PrepareLocalPageUpsert(
    invalidCategories,
    invalidPages,
    100,
    PreparationOptions(3008, invalidCategories[2].SyncId),
    function(value)
        preparationHashCalls = preparationHashCalls + 1
        if preparationHashCalls == 3 then
            return "INVALID!"
        end
        return TestHash(value)
    end
)
AssertError(failedPreparation, failedPreparationError, "context-hash-failed", "late payload validation failure")
Assert(DeepEqual(invalidPages[100], beforeFailure), "late payload failure does not initialize revision metadata")

invalidCategories, invalidPages = MakeLocalCollections()
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError = activePage.PrepareLocalPageUpsert(
    invalidCategories,
    invalidPages,
    100,
    PreparationOptions(3009, invalidCategories[2].SyncId),
    function(value)
        invalidPages[101].Index = 20
        return TestHash(value)
    end
)
AssertError(failedPreparation, failedPreparationError, "stale-page-context", "context changes during preparation")
Assert(DeepEqual(invalidPages[100], beforeFailure), "stale context does not initialize target revision metadata")

invalidCategories, invalidPages = MakeLocalCollections()
beforeFailure = DeepCopy(invalidPages[100])
local insertedDuplicate = false
failedPreparation, failedPreparationError = activePage.PrepareLocalPageUpsert(
    invalidCategories,
    invalidPages,
    100,
    PreparationOptions(3010, invalidCategories[2].SyncId),
    function(value)
        if not insertedDuplicate then
            insertedDuplicate = true
            invalidPages[300] = DeepCopy(invalidPages[100])
            invalidPages[300].Id = 300
        end
        return TestHash(value)
    end
)
AssertError(
    failedPreparation,
    failedPreparationError,
    "duplicate-local-sync-id",
    "identity ambiguity introduced during preparation"
)
Assert(DeepEqual(invalidPages[100], beforeFailure), "late identity ambiguity does not initialize revision metadata")

invalidCategories, invalidPages = MakeLocalCollections()
invalidOptions = PreparationOptions(3011, LocalSyncId("category", 999))
beforeFailure = DeepCopy(invalidPages[100])
failedPreparation, failedPreparationError =
    activePage.PrepareLocalPageUpsert(invalidCategories, invalidPages, 100, invalidOptions, TestHash)
AssertError(
    failedPreparation,
    failedPreparationError,
    "managed-scope-not-ancestor",
    "unrelated canonical managed scope"
)
Assert(DeepEqual(invalidPages[100], beforeFailure), "unrelated scope failure is atomic")

print(string.format("Active-page synchronization tests passed (%d assertions).", assertions))
