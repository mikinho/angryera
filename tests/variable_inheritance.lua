local app = {
    AngryEra = {
        utils = {},
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)

local variables = app.AngryEra.utils.variables

local function AssertError(value, errorCode, expectedError, message)
    assert(value == nil, message .. " should fail")
    assert(errorCode == expectedError, string.format("%s: expected %s, got %s", message, expectedError, errorCode))
end

local rootSyncId = "ae3i:1:2:3:4:category:1"
local middleSyncId = "ae3i:1:2:3:4:category:2"
local parentSyncId = "ae3i:1:2:3:4:category:3"

local categories = {
    [3] = {
        Id = 3,
        CategoryId = 2,
        SyncId = parentSyncId,
        Vars = "role=parent\nparentOnly=yes",
    },
    [1] = {
        Id = 1,
        SyncId = rootSyncId,
        Vars = "role=root\nrootOnly=yes\nresolved={{target}}",
    },
    [2] = {
        Id = 2,
        CategoryId = 1,
        SyncId = middleSyncId,
        Vars = "role=middle\ntarget=middle",
    },
}

local chain, chainError = variables.CollectCategoryChain(categories, 3)
assert(chain and not chainError, "A valid nested chain should collect")
assert(#chain == 3, "The complete category chain should be returned")
assert(chain[1].Id == 1 and chain[2].Id == 2 and chain[3].Id == 3, "Chain order should be root to parent")

local scopedChain, scopedError = variables.CollectCategoryChain(categories, 3, { rootId = 2 })
assert(scopedChain and not scopedError, "An explicit scope root should collect")
assert(#scopedChain == 2 and scopedChain[1].Id == 2, "Private ancestors outside the scope should be excluded")

local layers, layerError = variables.BuildAncestorVariableLayers(chain)
assert(layers and not layerError, "A valid local chain should produce wire layers")
assert(#layers == 3, "Every ancestor should produce one layer")
assert(layers[1].SyncId == rootSyncId and layers[3].SyncId == parentSyncId, "Layer order should be preserved")

local safeLayers, safeLayerError = variables.ValidateAncestorVariableLayers(layers, parentSyncId)
assert(safeLayers and not safeLayerError, "Valid wire layers should copy")
assert(safeLayers ~= layers and safeLayers[1] ~= layers[1], "Validated wire layers should not alias packet tables")

local merged, mergeError = variables.MergeVariableLayers(safeLayers, "role=page\ntarget=page\npageOnly=yes")
assert(merged and not mergeError, "Valid layers should merge")
assert(merged.role == "page", "Page variables should override every ancestor")
assert(merged.rootOnly == "yes" and merged.parentOnly == "yes", "Broad and narrow variables should remain")
assert(merged.resolved == "page", "References should resolve after all layers and page variables merge")

local emptyLayers, emptyLayerError = variables.ValidateAncestorVariableLayers({}, nil)
assert(emptyLayers and not emptyLayerError and #emptyLayers == 0, "A root-level page should accept no ancestors")
merged, mergeError = variables.MergeVariableLayers(emptyLayers, "pageOnly=yes")
assert(merged and not mergeError and merged.pageOnly == "yes", "A root-level page should merge page variables")

chain, chainError = variables.CollectCategoryChain(categories, 3, { rootId = 9 })
AssertError(chain, chainError, "root-not-ancestor", "unrelated scope root")

local missingCategories = {
    [2] = { Id = 2, CategoryId = 1 },
}
chain, chainError = variables.CollectCategoryChain(missingCategories, 2)
AssertError(chain, chainError, "missing-category", "missing ancestor")

local mismatchedCategories = {
    [1] = { Id = 2 },
}
chain, chainError = variables.CollectCategoryChain(mismatchedCategories, 1)
AssertError(chain, chainError, "category-id-mismatch", "mismatched table key")

local selfCycle = {
    [1] = { Id = 1, CategoryId = 1 },
}
chain, chainError = variables.CollectCategoryChain(selfCycle, 1)
AssertError(chain, chainError, "cycle", "self cycle")

local multiCycle = {
    [1] = { Id = 1, CategoryId = 2 },
    [2] = { Id = 2, CategoryId = 1 },
}
chain, chainError = variables.CollectCategoryChain(multiCycle, 1)
AssertError(chain, chainError, "cycle", "multi-node cycle")

local deepCategories = {}
for id = 1, 33 do
    deepCategories[id] = {
        Id = id,
        CategoryId = id > 1 and id - 1 or nil,
    }
end
chain, chainError = variables.CollectCategoryChain(deepCategories, 32)
assert(chain and #chain == 32 and not chainError, "Depth 32 should be accepted")
chain, chainError = variables.CollectCategoryChain(deepCategories, 33)
AssertError(chain, chainError, "depth-exceeded", "depth 33")

local sparseLayers = {
    [1] = { SyncId = rootSyncId, Vars = "" },
    [3] = { SyncId = parentSyncId, Vars = "" },
}
safeLayers, safeLayerError = variables.ValidateAncestorVariableLayers(sparseLayers, parentSyncId)
AssertError(safeLayers, safeLayerError, "invalid-ancestor-layers", "sparse layers")

local duplicateLayers = {
    { SyncId = rootSyncId, Vars = "" },
    { SyncId = rootSyncId, Vars = "" },
}
safeLayers, safeLayerError = variables.ValidateAncestorVariableLayers(duplicateLayers, rootSyncId)
AssertError(safeLayers, safeLayerError, "duplicate-ancestor", "duplicate layer identity")

local invalidIdentityLayers = {
    { SyncId = "not-a-sync-id", Vars = "" },
}
safeLayers, safeLayerError = variables.ValidateAncestorVariableLayers(invalidIdentityLayers, parentSyncId)
AssertError(safeLayers, safeLayerError, "invalid-ancestor-sync-id", "invalid layer identity")

local invalidVariableLayers = {
    { SyncId = rootSyncId, Vars = 42 },
}
safeLayers, safeLayerError = variables.ValidateAncestorVariableLayers(invalidVariableLayers, rootSyncId)
AssertError(safeLayers, safeLayerError, "invalid-ancestor-variables", "non-string layer variables")

local oversizedVariableLayers = {
    { SyncId = rootSyncId, Vars = string.rep("x", variables.MAX_VARIABLE_BYTES + 1) },
}
safeLayers, safeLayerError = variables.ValidateAncestorVariableLayers(oversizedVariableLayers, rootSyncId)
AssertError(safeLayers, safeLayerError, "invalid-ancestor-variables", "oversized layer variables")

safeLayers, safeLayerError = variables.ValidateAncestorVariableLayers(layers, middleSyncId)
AssertError(safeLayers, safeLayerError, "parent-mismatch", "direct parent mismatch")

merged, mergeError = variables.MergeVariableLayers({
    { Vars = "{invalid" },
}, "")
AssertError(merged, mergeError, "invalid-variables", "malformed JSON variables")

merged, mergeError = variables.MergeVariableLayers({
    { Vars = "[{\"name\":\"not-a-map\"}]" },
}, "")
AssertError(merged, mergeError, "invalid-variables", "top-level JSON array variables")

merged, mergeError = variables.MergeVariableLayers({}, "a={{b}}\nb={{a}}")
assert(merged and not mergeError, "Cyclic references should remain representable")
assert(merged.a == "{{a}}" and merged.b == "{{a}}", "Cyclic reference output should be deterministic")

local canonicalContext, canonicalError = variables.BuildContextRevisionInput(layers, "role=page")
assert(canonicalContext and not canonicalError, "Valid layers should produce canonical context input")

local reorderedContext = assert(variables.BuildContextRevisionInput({
    layers[2],
    layers[1],
    layers[3],
}, "role=page"))
assert(reorderedContext ~= canonicalContext, "Layer order should affect context identity input")

local identityChangedLayers = {
    layers[1],
    {
        SyncId = "ae3i:1:2:3:4:category:20",
        Vars = layers[2].Vars,
    },
    layers[3],
}
assert(
    variables.BuildContextRevisionInput(identityChangedLayers, "role=page") ~= canonicalContext,
    "Layer identity should affect context identity input"
)

local variableChangedLayers = {
    layers[1],
    {
        SyncId = layers[2].SyncId,
        Vars = layers[2].Vars .. "\nextra=yes",
    },
    layers[3],
}
assert(
    variables.BuildContextRevisionInput(variableChangedLayers, "role=page") ~= canonicalContext,
    "Layer variables should affect context identity input"
)
assert(
    variables.BuildContextRevisionInput(layers, "role=other") ~= canonicalContext,
    "Page variables should affect context identity input"
)

local delimiterContextA = assert(variables.BuildContextRevisionInput({
    { SyncId = rootSyncId, Vars = "2:ab" },
}, "c"))
local delimiterContextB = assert(variables.BuildContextRevisionInput({
    { SyncId = rootSyncId, Vars = "2:a" },
}, "bc"))
assert(delimiterContextA ~= delimiterContextB, "Length-prefixing should prevent delimiter-boundary collisions")

print("Variable inheritance tests passed.")
