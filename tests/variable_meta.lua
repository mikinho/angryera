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

local nestedValue = { inner = "table" }
local resolved = {
    MT = "Zessy",
    OT1 = "Kwayteow",
    Healers = nestedValue,
    NullValue = json.JSON_NULL,
    ["$encounter"] = "Patchwerk",
    ["$phase"] = 2,
    ["$optional"] = false,
    ["$table"] = { dropped = true },
    ["$null"] = json.JSON_NULL,
    ["$"] = "dropped",
    ["$$raw"] = "kept",
}

local publicVariables, meta, partitionError = variables.PartitionResolvedVariables(resolved)
assert(publicVariables and meta and not partitionError, "A valid resolved map should partition")

assert(publicVariables.MT == "Zessy", "Public values should be preserved")
assert(publicVariables.OT1 == "Kwayteow", "All public keys should be preserved")
assert(publicVariables.Healers == nestedValue, "Public table values should be copied by reference")
assert(publicVariables.NullValue == json.JSON_NULL, "JSON null identity should survive partitioning")
assert(publicVariables["$encounter"] == nil, "Metadata keys should not leak into public values")

assert(meta.encounter == "Patchwerk", "String metadata should strip the prefix")
assert(meta.phase == 2, "Numeric metadata should be preserved")
assert(meta.optional == false, "Boolean false metadata should be preserved")
assert(meta.table == nil, "Table metadata values should be dropped")
assert(meta.null == nil, "JSON null metadata values should be dropped")
assert(meta[""] == nil, "A bare $ key should be dropped")
assert(meta["$raw"] == "kept", "Only the first $ should be stripped")

assert(resolved["$encounter"] == "Patchwerk", "The input map should not be mutated")
publicVariables.MT = "Changed"
meta.encounter = "Changed"
assert(resolved.MT == "Zessy", "Public output should be detached from the input")
assert(resolved["$encounter"] == "Patchwerk", "Metadata output should be detached from the input")

local invalidPublic, invalidMeta, invalidError = variables.PartitionResolvedVariables("nope")
assert(invalidPublic == nil and invalidMeta == nil, "Non-table input should fail")
assert(invalidError == "invalid-variables", "Non-table input should report invalid-variables")

local badKeyPublic, badKeyMeta, badKeyError = variables.PartitionResolvedVariables({ [1] = "x" })
assert(badKeyPublic == nil and badKeyMeta == nil, "Non-string keys should fail")
assert(badKeyError == "invalid-variables", "Non-string keys should report invalid-variables")

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

print("Variable metadata tests passed.")
