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

-- Reserved action metadata is one case-insensitive namespace across layers.
-- Preserve the spelling from the winning layer so consumers can expose exactly
-- what the author entered while preventing inherited variants from competing.
local reservedCaseKeys = {
    "STAR",
    "CIRCLE",
    "DIAMOND",
    "TRIANGLE",
    "MOON",
    "SQUARE",
    "SKULL",
    "AUTOADVANCE",
    "ENCOUNTER",
    "ENCOUNTERID",
    "LAYOUT",
}
for _, key in ipairs(reservedCaseKeys) do
    local lowerKey = key:lower()
    merged, mergeError = variables.MergeVariableLayers({
        { Vars = "$" .. key .. "=ancestor" },
    }, "$" .. lowerKey .. "=page")
    assert(merged and not mergeError, key .. " case override should merge")
    assert(merged["$" .. key] == nil, key .. " inherited spelling should be removed")
    assert(merged["$" .. lowerKey] == "page", key .. " should preserve the winning spelling and value")
end

merged, mergeError = variables.MergeVariableLayers({
    { Vars = "$CROSS=ancestor" },
}, "$X=page")
assert(merged and not mergeError, "CROSS to X alias override should merge")
assert(merged["$CROSS"] == nil, "An inherited CROSS alias should be removed")
assert(merged["$X"] == "page", "The page X alias should win and preserve its spelling")

merged, mergeError = variables.MergeVariableLayers({
    { Vars = "$Custom=title-ancestor\n$custom=lower-ancestor" },
}, "$CUSTOM=upper-page\n$custom=lower-page")
assert(merged and not mergeError, "Custom metadata case variants should merge independently")
assert(merged["$Custom"] == "title-ancestor", "Custom metadata should retain inherited case variants")
assert(merged["$CUSTOM"] == "upper-page", "Custom metadata should retain page case variants")
assert(merged["$custom"] == "lower-page", "Exact custom metadata keys should still override normally")

merged, mergeError = variables.MergeVariableLayers({}, "$CROSS=Alice\n$X=Bob")
AssertError(merged, mergeError, "conflicting-reserved-metadata", "same-layer marker alias conflict")

merged, mergeError = variables.MergeVariableLayers({}, "$AUTOADVANCE=true\n$autoadvance=false")
AssertError(merged, mergeError, "conflicting-reserved-metadata", "same-layer reserved case conflict")

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

local expansiveReferences = {}
for index = 1, 20 do
    local key = string.format("K%02d", index)
    local nextKey = string.format("K%02d", index + 1)
    expansiveReferences[#expansiveReferences + 1] = key .. "={{" .. nextKey .. "}}{{" .. nextKey .. "}}"
end
expansiveReferences[#expansiveReferences + 1] = "K21=end"
merged, mergeError = variables.MergeVariableLayers({}, table.concat(expansiveReferences, "\n"))
assert(merged == nil, "Exponentially expanding references should be rejected")
assert(mergeError == "resolved-variables-too-large", "Expansion rejection should return a stable error")

-- Variable-family declarations flatten numbered source families in authored
-- order and materialize ordinary dense variables for every existing consumer.
merged, mergeError = variables.MergeVariableLayers(
    {},
    [[
PRIESTS1=PriestOne
PRIESTS3=PriestThree
PRIESTS10=PriestTen
PRIESTS01=NotCanonical
PRIESTS0=NotPositive
Priests2=WrongCase
PALADINS1=PaladinOne
DRUID1=DruidOne
FURY1=FuryOne
ROGUE1=RogueOne
HEALER*={{PRIESTS*}},{{PALADINS*}},{{DRUID1}}
MELEE*=FURY*,ROGUE*
RAID*=HEALER*,MELEE*,{{HEALER1}}
FIRST_HEALER={{HEALER1}}
]]
)
assert(merged and not mergeError, "valid variable families should expand")
assert(
    merged.HEALER1 == "PriestOne"
        and merged.HEALER2 == "PriestThree"
        and merged.HEALER3 == "PriestTen"
        and merged.HEALER4 == "PaladinOne"
        and merged.HEALER5 == "DruidOne",
    "families should preserve selector order and sort numbered matches naturally"
)
assert(merged.MELEE1 == "FuryOne" and merged.MELEE2 == "RogueOne", "bare wildcard selectors should compose a family")
assert(
    merged.RAID1 == "PriestOne"
        and merged.RAID5 == "DruidOne"
        and merged.RAID6 == "FuryOne"
        and merged.RAID7 == "RogueOne"
        and merged.RAID8 == nil,
    "nested families should flatten densely and deduplicate repeated source keys"
)
assert(merged.FIRST_HEALER == "PriestOne", "ordinary variables should resolve generated family members")
assert(
    merged["HEALER*"] == nil and merged["MELEE*"] == nil and merged["RAID*"] == nil,
    "family declaration pseudo-keys should not reach consumers"
)

merged, mergeError = variables.MergeVariableLayers(
    {},
    "SOURCE100000000000000000000=Later\nSOURCE99999999999999999999=Earlier\nTARGET*=SOURCE*"
)
assert(
    merged and not mergeError and merged.TARGET1 == "Earlier" and merged.TARGET2 == "Later",
    "large numeric suffixes should sort naturally without runtime-specific number conversion"
)

local deepFamilyComposition = { "BASE1=DeepMember" }
local previousFamily = "BASE"
for index = 1, 25 do
    local nextFamily = "CHAIN_" .. string.char(64 + index)
    deepFamilyComposition[#deepFamilyComposition + 1] = nextFamily .. "*=" .. previousFamily .. "*"
    previousFamily = nextFamily
end
merged, mergeError = variables.MergeVariableLayers({}, table.concat(deepFamilyComposition, "\n"))
assert(
    merged and not mergeError and merged[previousFamily .. "1"] == "DeepMember",
    "deep family composition should not consume ordinary reference recursion depth"
)

merged, mergeError = variables.MergeVariableLayers(
    {},
    [[
EMPTY1=
SAME1=Roselea
SAME2=Roselea
NUMBER1=7
BOOLEAN1=true
DRUID1=DruidOne
STABLE*=EMPTY*,DRUID1
DUPLICATE*=SAME*
STRING_ONLY*=NUMBER*,BOOLEAN*,DRUID1
]]
)
assert(merged and not mergeError, "family member filtering should resolve")
assert(
    merged.STABLE1 == "" and merged.STABLE2 == "DruidOne",
    "an explicitly empty matched member should keep its stable ordinal"
)
assert(
    merged.DUPLICATE1 == "Roselea" and merged.DUPLICATE2 == "Roselea",
    "different source keys with equal values should remain visible for duplicate validation"
)
assert(
    merged.STRING_ONLY1 == "DruidOne" and merged.STRING_ONLY2 == nil,
    "numeric and boolean source values should not become role-family members"
)

merged, mergeError =
    variables.MergeVariableLayers({}, "{\"PRIEST1\":\"PriestOne\",\"HEALER*\":\"PRIEST*\",\"COPY\":\"{{HEALER1}}\"}")
assert(merged and not mergeError, "JSON-form family declarations should expand")
assert(merged.HEALER1 == "PriestOne" and merged.COPY == "PriestOne", "JSON families should resolve normally")

-- A declaration owns lower-layer numbered members under its prefix. Explicit
-- members from the same or a closer layer remain intentional exceptions.
merged, mergeError = variables.MergeVariableLayers({
    {
        Vars = "PALADIN1=PaladinOne\nPALADIN2=PaladinTwo\nHEALER1=OldOne\nHEALER2=OldTwo\nHEALER9=OldNine",
    },
}, "HEALER*=PALADIN*\nHEALER2=Special")
assert(merged and not mergeError, "a closer family declaration should replace inherited members")
assert(merged.HEALER1 == "PaladinOne", "a closer family should replace an inherited first member")
assert(merged.HEALER2 == "Special", "an exact same-layer member should override its generated ordinal")
assert(merged.HEALER3 == nil, "an exact override should not renumber later generated members")
assert(merged.HEALER9 == nil, "a closer family should clear stale inherited members in its namespace")

merged, mergeError = variables.MergeVariableLayers({
    {
        Vars = "PRIEST1=RootOne\nPRIEST2=RootTwo\nHEALER*=PRIEST*",
    },
}, "PRIEST2=PageTwo\nHEALER1=PageException")
assert(merged and not mergeError, "inherited families should use the final effective source values")
assert(merged.HEALER1 == "PageException", "a closer exact member should override an inherited family output")
assert(merged.HEALER2 == "PageTwo", "child source overrides should feed an inherited family")

merged, mergeError = variables.MergeVariableLayers({
    {
        Vars = "HEALER1=OldOne\nHEALER2=OldTwo\nHEALER*=PRIEST*",
    },
}, "HEALER*=")
assert(merged and not mergeError, "an empty closer declaration should disable an inherited family")
assert(merged.HEALER1 == nil and merged.HEALER2 == nil, "disabling a family should clear inherited members")

merged, mergeError = variables.MergeVariableLayers({}, "A*=B*\nB*=A*")
AssertError(merged, mergeError, "variable-family-cycle", "wildcard family cycle")
merged, mergeError = variables.MergeVariableLayers({}, "A*={{B1}}\nB*={{A1}}")
AssertError(merged, mergeError, "variable-family-cycle", "exact generated-member cycle")

merged, mergeError = variables.MergeVariableLayers({}, "A1=Alice\nA*=A1")
assert(
    merged and not mergeError and merged.A1 == "Alice",
    "a same-layer explicit member should satisfy its own family without a false cycle"
)
merged, mergeError = variables.MergeVariableLayers({}, "A*=B1\nB*=A1\nB1=Bob")
assert(
    merged and not mergeError and merged.A1 == "Bob" and merged.B1 == "Bob",
    "an explicit exact member should break an otherwise cyclic family dependency"
)
merged, mergeError = variables.MergeVariableLayers({}, "A1=Alice\nB1=Bob\nA*=B1\nB*=A1")
assert(
    merged and not mergeError and merged.A1 == "Alice" and merged.B1 == "Bob",
    "cross-family exact overrides should remain deterministic"
)

for _, invalidSource in ipairs({
    "HEALER*=PRIEST*.PALADIN*",
    "HEALER*=PRIEST*,",
    "HEALER1*=PRIEST*",
    "$HEALER*=PRIEST*",
    "{\"HEALER*\":7}",
}) do
    merged, mergeError = variables.MergeVariableLayers({}, invalidSource)
    AssertError(merged, mergeError, "invalid-variable-family", "malformed family declaration")
end

local oversizedFamily = {}
for index = 1, variables.MAX_VARIABLE_FAMILY_MEMBERS + 1 do
    oversizedFamily[#oversizedFamily + 1] = ("SOURCE%d=Member%d"):format(index, index)
end
oversizedFamily[#oversizedFamily + 1] = "TARGET*=SOURCE*"
merged, mergeError = variables.MergeVariableLayers({}, table.concat(oversizedFamily, "\n"))
AssertError(merged, mergeError, "variable-family-too-large", "oversized family member list")

local tooManyGenerated = {}
for index = 1, variables.MAX_VARIABLE_FAMILY_MEMBERS do
    tooManyGenerated[#tooManyGenerated + 1] = ("SOURCE%d=Member%d"):format(index, index)
end
for first = 1, 2 do
    for second = 1, 13 do
        tooManyGenerated[#tooManyGenerated + 1] = ("FAMILY_%s%s*=SOURCE*"):format(
            string.char(64 + first),
            string.char(64 + second)
        )
    end
end
merged, mergeError = variables.MergeVariableLayers({}, table.concat(tooManyGenerated, "\n"))
AssertError(merged, mergeError, "variable-family-too-large", "total generated family output")

local familyBoundary = {}
for first = 1, 3 do
    for second = 1, 26 do
        familyBoundary[#familyBoundary + 1] = ("BOUND_%s%s*="):format(string.char(64 + first), string.char(64 + second))
    end
end
local maximumFamilies = {}
for index = 1, variables.MAX_VARIABLE_FAMILIES do
    maximumFamilies[index] = familyBoundary[index]
end
merged, mergeError = variables.MergeVariableLayers({}, table.concat(maximumFamilies, "\n"))
assert(merged and not mergeError, "the exact family declaration limit should be accepted")
maximumFamilies[#maximumFamilies + 1] = familyBoundary[variables.MAX_VARIABLE_FAMILIES + 1]
merged, mergeError = variables.MergeVariableLayers({}, table.concat(maximumFamilies, "\n"))
AssertError(merged, mergeError, "variable-family-too-large", "family declaration count above the limit")
maximumFamilies[#maximumFamilies + 1] = "$MALFORMED*=SOURCE*"
merged, mergeError = variables.MergeVariableLayers({}, table.concat(maximumFamilies, "\n"))
AssertError(
    merged,
    mergeError,
    "variable-family-too-large",
    "family count should have deterministic precedence over malformed declarations"
)

local selectorBoundary = {}
for index = 1, variables.MAX_VARIABLE_FAMILY_SELECTORS do
    selectorBoundary[index] = "SOURCE1"
end
merged, mergeError = variables.MergeVariableLayers({}, "SOURCE1=One\nTARGET*=" .. table.concat(selectorBoundary, ","))
assert(merged and not mergeError and merged.TARGET1 == "One", "the exact selector limit should be accepted")
selectorBoundary[#selectorBoundary + 1] = "SOURCE1"
merged, mergeError = variables.MergeVariableLayers({}, "SOURCE1=One\nTARGET*=" .. table.concat(selectorBoundary, ","))
AssertError(merged, mergeError, "variable-family-too-large", "selector count above the limit")

local generatedByteLimit = variables.MAX_GENERATED_FAMILY_BYTES
variables.MAX_GENERATED_FAMILY_BYTES = 1
merged, mergeError = variables.MergeVariableLayers({}, "SOURCE1=One\nTARGET*=SOURCE*")
variables.MAX_GENERATED_FAMILY_BYTES = generatedByteLimit
AssertError(merged, mergeError, "variable-family-too-large", "generated family byte limit")

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
