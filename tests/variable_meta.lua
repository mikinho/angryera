local app = {
    AngryEra = {
        utils = {},
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)

local json = app.AngryEra.utils.json
local variables = app.AngryEra.utils.variables

assert(variables.META_VARIABLE_PREFIX == "$", "The metadata prefix should be $")

assert(variables.IsMetaVariableKey("$encounter") == true, "$-prefixed keys should be metadata")
assert(variables.IsMetaVariableKey("$") == true, "A bare $ key should count as metadata")
assert(variables.IsMetaVariableKey("MT") == false, "Plain keys should not be metadata")
assert(variables.IsMetaVariableKey("M$T") == false, "Only a leading $ marks metadata")
assert(variables.IsMetaVariableKey(nil) == false, "Nil keys should not be metadata")
assert(variables.IsMetaVariableKey(7) == false, "Numeric keys should not be metadata")

local nestedValue = {
    inner = "table",
    child = { role = "healer" },
}
local sharedValue = { marker = "shared" }
local structuredMeta = {
    difficulty = "normal",
    phases = {
        { name = "one" },
        { name = "two" },
    },
}
local resolved = {
    MT = "Zessy",
    OT1 = "Kwayteow",
    Healers = nestedValue,
    Shared = sharedValue,
    NullValue = json.JSON_NULL,
    ["$encounter"] = "Patchwerk",
    ["$phase"] = 2,
    ["$optional"] = false,
    ["$table"] = structuredMeta,
    ["$shared"] = sharedValue,
    ["$null"] = json.JSON_NULL,
    ["$"] = "dropped",
    ["$$raw"] = "kept",
}

local publicVariables, meta, partitionError = variables.PartitionResolvedVariables(resolved)
assert(publicVariables and meta and not partitionError, "A valid resolved map should partition")

assert(publicVariables.MT == "Zessy", "Public values should be preserved")
assert(publicVariables.OT1 == "Kwayteow", "All public keys should be preserved")
assert(publicVariables.Healers ~= nestedValue, "Public table values should be detached")
assert(publicVariables.Healers.child ~= nestedValue.child, "Nested public tables should be detached")
assert(publicVariables.Healers.child.role == "healer", "Nested public data should be preserved")
assert(publicVariables.NullValue == json.JSON_NULL, "JSON null identity should survive partitioning")
assert(publicVariables["$encounter"] == nil, "Metadata keys should not leak into public values")

assert(meta.encounter == "Patchwerk", "String metadata should strip the prefix")
assert(meta.phase == 2, "Numeric metadata should be preserved")
assert(meta.optional == false, "Boolean false metadata should be preserved")
assert(meta.table ~= structuredMeta, "Structured metadata should be detached")
assert(meta.table.phases ~= structuredMeta.phases, "Nested metadata tables should be detached")
assert(meta.table.phases[2].name == "two", "Structured metadata should be preserved")
assert(meta.null == json.JSON_NULL, "JSON null metadata should be preserved")
assert(meta[""] == nil, "A bare $ key should be dropped")
assert(meta["$raw"] == "kept", "Only the first $ should be stripped")
assert(publicVariables.Shared == meta.shared, "Shared references should survive across partition outputs")
assert(publicVariables.Shared ~= sharedValue, "Shared output values should still detach from input")

assert(resolved["$encounter"] == "Patchwerk", "The input map should not be mutated")
publicVariables.MT = "Changed"
publicVariables.Healers.child.role = "changed"
meta.encounter = "Changed"
meta.table.phases[2].name = "changed"
assert(resolved.MT == "Zessy", "Public output should be detached from the input")
assert(nestedValue.child.role == "healer", "Nested public mutations should not reach the input")
assert(resolved["$encounter"] == "Patchwerk", "Metadata output should be detached from the input")
assert(structuredMeta.phases[2].name == "two", "Nested metadata mutations should not reach the input")

-- Cyclic and aliased values remain bounded and detached rather than recursing forever.
local cyclicValue = {}
cyclicValue.self = cyclicValue
local cyclicPublic, cyclicMeta, cyclicError = variables.PartitionResolvedVariables({
    Cycle = cyclicValue,
    ["$cycle"] = cyclicValue,
})
assert(cyclicPublic and cyclicMeta and not cyclicError, "Cyclic variable graphs should partition safely")
assert(cyclicPublic.Cycle ~= cyclicValue, "Cyclic output should detach from its source")
assert(cyclicPublic.Cycle.self == cyclicPublic.Cycle, "A detached cycle should retain its topology")
assert(cyclicMeta.cycle == cyclicPublic.Cycle, "Aliases spanning public and metadata values should survive")

-- A cycle back to the resolved root must target the filtered public root rather
-- than retaining an unsplit clone that still exposes raw metadata keys.
local rootCyclicResolved = {
    Public = "visible",
    ["$secret"] = "metadata",
    ["$"] = "dropped",
}
rootCyclicResolved.Self = rootCyclicResolved
rootCyclicResolved["$root"] = rootCyclicResolved
local rootCyclicPublic, rootCyclicMeta, rootCyclicError = variables.PartitionResolvedVariables(rootCyclicResolved)
assert(rootCyclicPublic and rootCyclicMeta and not rootCyclicError, "Root cycles should partition safely")
assert(rootCyclicPublic ~= rootCyclicResolved, "The root cycle should detach from its source")
assert(rootCyclicPublic.Self == rootCyclicPublic, "The public root cycle should retain its topology")
assert(rootCyclicMeta.root == rootCyclicPublic, "Metadata aliases to the resolved root should target the public root")
assert(rootCyclicPublic["$secret"] == nil, "Raw metadata should be removed from the public root")
assert(rootCyclicPublic.Self["$secret"] == nil, "Root cycles must not provide a path to raw metadata")
assert(rootCyclicMeta.secret == "metadata", "Root-cycle metadata should remain available through the metadata output")
assert(rootCyclicMeta[""] == nil, "Bare metadata keys should still be dropped from root cycles")
assert(rootCyclicResolved["$secret"] == "metadata", "Filtering the detached root must not mutate the input")

local invalidPublic, invalidMeta, invalidError = variables.PartitionResolvedVariables("nope")
assert(invalidPublic == nil and invalidMeta == nil, "Non-table input should fail")
assert(invalidError == "invalid-variables", "Non-table input should report invalid-variables")

local badKeyPublic, badKeyMeta, badKeyError = variables.PartitionResolvedVariables({ [1] = "x" })
assert(badKeyPublic == nil and badKeyMeta == nil, "Non-string keys should fail")
assert(badKeyError == "invalid-variables", "Non-string keys should report invalid-variables")

local nestedTableKey = {}
local tableKeyPublic, tableKeyMeta, tableKeyError = variables.PartitionResolvedVariables({
    Nested = {
        [nestedTableKey] = "unsupported",
    },
})
assert(tableKeyPublic == nil and tableKeyMeta == nil, "Nested table keys should fail")
assert(tableKeyError == "invalid-variables", "Nested table keys should report invalid-variables")

-- Metadata participates in layer merging, inheritance, and reference resolution.
local layers = {
    { SyncId = "ae3i:1:2:3:4:category:1", Vars = "$raid=Naxxramas\n$phase=1\nMT=Zessy" },
    { SyncId = "ae3i:1:2:3:4:category:2", Vars = "$phase=2" },
}
local merged, mergeError =
    variables.MergeVariableLayers(layers, "$encounter=Patchwerk\nLabel=Boss: {{$encounter}}\n$note={{MT}} taunts")
assert(merged and not mergeError, "Layers with metadata should merge")

local mergedPublic, mergedMeta = variables.PartitionResolvedVariables(merged)
assert(mergedMeta.raid == "Naxxramas", "Root metadata should inherit to the page")
assert(mergedMeta.phase == 2, "Nearer layers should override metadata")
assert(mergedMeta.encounter == "Patchwerk", "Page metadata should win")
assert(mergedPublic.Label == "Boss: Patchwerk", "Public values should resolve references to metadata")
assert(mergedMeta.note == "Zessy taunts", "Metadata values should resolve references to public values")

-- The partition limits must cover all valid ancestor sources plus the page
-- source, even when compact JSON produces more than the former 4,096 tables.
local largeVariableIndex = 0
local function BuildLargeVariableObject()
    local parts = { "{" }
    local encodedLength = 1
    local first = true

    while true do
        local nextIndex = largeVariableIndex + 1
        local entry = (first and "" or ",") .. "\"Large" .. tostring(nextIndex) .. "\":[]"
        if encodedLength + #entry + 1 > variables.MAX_VARIABLE_BYTES then
            break
        end

        largeVariableIndex = nextIndex
        parts[#parts + 1] = entry
        encodedLength = encodedLength + #entry
        first = false
    end

    parts[#parts + 1] = "}"
    local encoded = table.concat(parts)
    assert(#encoded <= variables.MAX_VARIABLE_BYTES, "Large variable sources should remain individually valid")
    return encoded
end

local largeLayers = {}
for index = 1, variables.MAX_ANCESTOR_DEPTH do
    largeLayers[index] = {
        Vars = BuildLargeVariableObject(),
    }
end
local largePageVariables = BuildLargeVariableObject()
local largeMerged, largeMergeError = variables.MergeVariableLayers(largeLayers, largePageVariables)
assert(largeMerged and not largeMergeError, "The maximum valid layer aggregate should merge")

local largeMergedCount = 0
for _ in pairs(largeMerged) do
    largeMergedCount = largeMergedCount + 1
end
assert(largeMergedCount > 4096, "The aggregate regression should exceed the former table ceiling")

local largePublic, largeMeta, largePartitionError = variables.PartitionResolvedVariables(largeMerged)
assert(largePublic and largeMeta and not largePartitionError, "The maximum valid aggregate should partition")
assert(largePublic.Large1 ~= largeMerged.Large1, "Large aggregate values should still detach")
assert(next(largeMeta) == nil, "A public-only large aggregate should produce empty metadata")

print("Variable metadata tests passed.")
