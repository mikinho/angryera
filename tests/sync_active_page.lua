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

print(string.format("Active-page synchronization tests passed (%d assertions).", assertions))
