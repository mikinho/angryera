local AngryEra = {
    core = {
        MAX_IMPORT_ENCODED_BYTES = 1024,
        MAX_IMPORT_DECODED_BYTES = 1024,
        MAX_IMPORT_SERIALIZED_BYTES = 4096,
    },
    utils = {
        boundedDeflate = {},
    },
}

local app = {
    AngryEra = AngryEra,
    libs = {
        libS = {},
        libD = {},
    },
}

AngryAssign_Categories = {
    [1] = {
        Id = 1,
        Name = "Root",
        Vars = "root=yes\n$AUTOAPPLYLAYOUT=$true",
    },
    [2] = {
        Id = 2,
        Name = "Child",
        CategoryId = 1,
        Index = 2,
        Vars = "{\"ROLE\":\"healers\",\"$LAYOUT\":\"Healing/1: {{HEALER1}}\"}",
    },
}
AngryAssign_Pages = {
    [10] = {
        Id = 10,
        Name = "Page",
        Contents = "Assignment",
        CategoryId = 1,
        Index = 1,
        Vars = "page=yes\n$SKULL={{MT}}",
    },
}

function AngryEra:GetCat(id)
    return AngryAssign_Categories[id]
end

assert(loadfile("modules/utils/serialization.lua"))("AngryEra", app)
local serialization = AngryEra.utils.serialization

app.libs.libS.Serialize = function()
    return "serialized-export"
end
app.libs.libD.CompressDeflate = function(_, serialized)
    assert(serialized == "serialized-export", "Encoded exports should compress the serialized payload")
    return "compressed-export"
end
app.libs.libD.EncodeForPrint = function(_, compressed)
    assert(compressed == "compressed-export", "Encoded exports should make the compressed payload printable")
    return "encoded-export"
end

assert(
    serialization
        .EncodeExportString({
            Name = "Full",
            Contents = "",
        }, "Page")
        :match("^AA:Page:1:"),
    "Complete exports should retain the legacy v1 prefix"
)
assert(
    serialization
        .EncodeExportString({
            Name = "Content only",
            Contents = "",
            VariablesIncluded = false,
        }, "Page")
        :match("^AA:Page:2:"),
    "Content-only exports should use v2 so older importers reject them safely"
)

local importState = {}

app.libs.libD.DecodeForPrint = function(_, encoded)
    importState.decodedEncoded = encoded
    return importState.compressed
end

AngryEra.utils.boundedDeflate.DecompressDeflate = function(compressed, maximumOutputBytes)
    importState.decompressCalls = importState.decompressCalls + 1
    importState.decompressedCompressed = compressed
    importState.maximumOutputBytes = maximumOutputBytes
    return importState.serialized, importState.trailingOrError
end

app.libs.libS.Deserialize = function(_, serialized)
    importState.deserializeCalls = importState.deserializeCalls + 1
    importState.deserializedSerialized = serialized
    return importState.deserializeOk, importState.deserializeData
end

local function ConfigureImport(serialized, trailingOrError, deserializeData)
    importState.compressed = "compressed"
    importState.serialized = serialized
    importState.trailingOrError = trailingOrError
    importState.deserializeOk = true
    importState.deserializeData = deserializeData
    importState.decompressCalls = 0
    importState.deserializeCalls = 0
    importState.decodedEncoded = nil
    importState.decompressedCompressed = nil
    importState.maximumOutputBytes = nil
    importState.deserializedSerialized = nil
end

local exported = serialization.GetCategoryExportData(AngryEra, 1)
assert(exported and exported.VariablesIncluded == nil, "Full category exports should retain the legacy payload shape")
assert(
    exported.Vars == "root=yes\n$AUTOAPPLYLAYOUT=$true",
    "Root category variables and metadata should be exported exactly"
)
assert(exported.Children[1].Type == "Page", "Encoded children should retain deterministic ordering")
assert(exported.Children[1].Vars == "page=yes\n$SKULL={{MT}}", "Page variables and metadata should be exported exactly")
assert(exported.Children[2].Type == "Category", "Nested categories should be exported")
assert(
    exported.Children[2].Vars == "{\"ROLE\":\"healers\",\"$LAYOUT\":\"Healing/1: {{HEALER1}}\"}",
    "JSON-form nested variables and metadata should be exported exactly"
)

local exportedPage = serialization.GetPageExportData(AngryAssign_Pages[10])
assert(
    exportedPage and exportedPage.VariablesIncluded == nil,
    "Full page exports should retain the legacy payload shape"
)
assert(exportedPage.Vars == AngryAssign_Pages[10].Vars, "Full page exports should retain raw variables exactly")

local exportedWithoutVariables = serialization.GetCategoryExportData(AngryEra, 1, {
    includeVariables = false,
})
assert(
    exportedWithoutVariables and exportedWithoutVariables.VariablesIncluded == false,
    "Variable-free category exports should declare variables omitted"
)
assert(exportedWithoutVariables.Vars == nil, "Variable-free category exports should omit root variables")
assert(exportedWithoutVariables.Children[1].Vars == nil, "Variable-free category exports should omit page variables")
assert(
    exportedWithoutVariables.Children[2].Vars == nil,
    "Variable-free category exports should recursively omit nested category variables"
)

local exportedPageWithoutVariables = serialization.GetPageExportData(AngryAssign_Pages[10], {
    includeVariables = false,
})
assert(
    exportedPageWithoutVariables and exportedPageWithoutVariables.VariablesIncluded == false,
    "Variable-free page exports should declare variables omitted"
)
assert(exportedPageWithoutVariables.Vars == nil, "Variable-free page exports should omit variables")

local valid, validationError = serialization.ValidateEncodedCategoryPayload(exported, "Category")
assert(valid, validationError)

valid, validationError = serialization.ValidateEncodedPagePayload({
    Name = string.rep("n", 100),
    Contents = string.rep("x", 20000),
    Vars = string.rep("v", 5000),
}, "Page")
assert(valid, validationError)

valid, validationError = serialization.ValidateEncodedPagePayload({
    Name = string.rep("n", 101),
    Contents = "",
}, "Page")
assert(not valid and validationError:find("at most 100 bytes", 1, true), "Oversized imported names should be rejected")

valid, validationError = serialization.ValidateEncodedPagePayload({
    Name = "Bad\nName",
    Contents = "",
}, "Page")
assert(
    not valid and validationError:find("without control characters", 1, true),
    "Control characters in imported names should be rejected"
)

valid, validationError = serialization.ValidateEncodedPagePayload({
    Name = "Oversized contents",
    Contents = string.rep("x", 20001),
}, "Page")
assert(
    not valid and validationError:find("maximum page-content size", 1, true),
    "Oversized imported page contents should be rejected"
)

valid, validationError = serialization.ValidateEncodedPagePayload({
    Name = "Invalid flag",
    Contents = "",
    VariablesIncluded = "false",
}, "Page")
assert(
    not valid and validationError:find("VariablesIncluded", 1, true),
    "Non-boolean page variable-inclusion flags should be rejected"
)

valid, validationError = serialization.ValidateEncodedCategoryPayload({
    Name = "Invalid flag",
    VariablesIncluded = "false",
    Children = {},
}, "Category")
assert(
    not valid and validationError:find("VariablesIncluded", 1, true),
    "Non-boolean category variable-inclusion flags should be rejected"
)

valid, validationError = serialization.ValidateEncodedCategoryPayload({
    Name = "Invalid",
    Vars = 42,
    Children = {},
}, "Category")
assert(not valid and validationError:find("Vars", 1, true), "Non-string category variables should be rejected")

valid, validationError = serialization.ValidateEncodedPagePayload({
    Name = "Oversized",
    Contents = "",
    Vars = string.rep("x", 5001),
}, "Page")
assert(
    not valid and validationError:find("maximum variable size", 1, true),
    "Oversized imported variable sources should be rejected"
)

local originalPageVariables = AngryAssign_Pages[10].Vars
AngryAssign_Pages[10].Vars = string.rep("x", 5001)
local invalidPageExport, invalidPageExportError = serialization.GetPageExportData(AngryAssign_Pages[10])
assert(
    invalidPageExport == nil and invalidPageExportError:find("maximum variable size", 1, true),
    "A generated full page export must not contain variables its importer rejects"
)
local invalidCategoryExport, invalidCategoryExportError = serialization.GetCategoryExportData(AngryEra, 1)
assert(
    invalidCategoryExport == nil and invalidCategoryExportError:find("maximum variable size", 1, true),
    "A generated full category export must reject invalid descendant variables"
)
local recoverableContentOnlyExport = serialization.GetCategoryExportData(AngryEra, 1, {
    includeVariables = false,
})
assert(
    recoverableContentOnlyExport and recoverableContentOnlyExport.VariablesIncluded == false,
    "Content-only export should remain available when stored variables are invalid"
)
AngryAssign_Pages[10].Vars = originalPageVariables

valid, validationError = serialization.ValidateEncodedCategoryPayload({
    Name = "Sparse",
    Children = {
        [2] = {
            Type = "Page",
            Name = "Page",
            Contents = "",
        },
    },
}, "Category")
assert(not valid and validationError:find("dense", 1, true), "Sparse child arrays should be rejected")

local cyclic = {
    Name = "Cycle",
    Children = {},
}
cyclic.Children[1] = cyclic
valid, validationError = serialization.ValidateEncodedCategoryPayload(cyclic, "Category")
assert(not valid and validationError:find("cyclic", 1, true), "Cyclic category imports should be rejected")

local exactDepthCategory = {
    Type = "Category",
    Name = "Depth 1",
    Children = {},
}
local exactDepthParent = exactDepthCategory
for depth = 2, 31 do
    local child = {
        Type = "Category",
        Name = "Depth " .. depth,
        Children = {},
    }
    exactDepthParent.Children[1] = child
    exactDepthParent = child
end
exactDepthParent.Children[1] = {
    Type = "Page",
    Name = "Depth 32 page",
    Contents = "",
}
valid, validationError = serialization.ValidateEncodedCategoryPayload(exactDepthCategory, "Category")
assert(valid, validationError)

local tooDeepCategory = exactDepthParent
tooDeepCategory.Children[1] = {
    Type = "Category",
    Name = "Depth 32",
    Children = {
        {
            Type = "Page",
            Name = "Depth 33 page",
            Contents = "",
        },
    },
}
valid, validationError = serialization.ValidateEncodedCategoryPayload(exactDepthCategory, "Category")
assert(
    not valid and validationError:find("maximum hierarchy depth", 1, true),
    "Imported pages should count toward the complete hierarchy depth limit"
)

local maximumEntityCategory = {
    Type = "Category",
    Name = "Maximum entities",
    Children = {},
}
for index = 1, 511 do
    maximumEntityCategory.Children[index] = {
        Type = "Page",
        Name = "Page " .. index,
        Contents = "",
    }
end
valid, validationError = serialization.ValidateEncodedCategoryPayload(maximumEntityCategory, "Category")
assert(valid, validationError)
maximumEntityCategory.Children[512] = {
    Type = "Page",
    Name = "One page too many",
    Contents = "",
}
valid, validationError = serialization.ValidateEncodedCategoryPayload(maximumEntityCategory, "Category")
assert(
    not valid and validationError:find("maximum category entity count", 1, true),
    "Category imports must not exceed the synchronization entity budget"
)

local validPage = {
    Type = "Page",
    Name = "Imported page",
    Contents = "Assignment",
}
ConfigureImport("serialized-page", 0, validPage)
local parsed, parsedData, parsedPrefix = serialization.ParseImportString(" AA:Page:1:fixture ")
assert(parsed, parsedData)
assert(parsedData == validPage and parsedPrefix == "Page", "Valid v1 page imports should remain compatible")
assert(importState.decodedEncoded == "fixture", "The encoded v1 payload should be decoded")
assert(importState.decompressedCompressed == "compressed", "The decoded bytes should be decompressed")
assert(
    importState.maximumOutputBytes == AngryEra.core.MAX_IMPORT_SERIALIZED_BYTES,
    "The bounded decoder should receive the serialized import budget"
)
assert(importState.deserializedSerialized == "serialized-page", "Valid decompressed bytes should be deserialized")
assert(
    importState.decompressCalls == 1 and importState.deserializeCalls == 1,
    "Valid imports should use each decoder once"
)

ConfigureImport("serialized-category", 0, exported)
parsed, parsedData, parsedPrefix = serialization.ParseImportString("AA:Category:1:fixture")
assert(parsed, parsedData)
assert(parsedData == exported and parsedPrefix == "Category", "Valid v1 category imports should remain compatible")

ConfigureImport("serialized-content-only-category", 0, exportedWithoutVariables)
parsed, validationError = serialization.ParseImportString("AA:Category:1:fixture")
assert(
    not parsed and validationError == "Export version 1 cannot omit variables and metadata",
    "A v1 payload must remain an authoritative complete export"
)

ConfigureImport("serialized-content-only-category", 0, exportedWithoutVariables)
parsed, parsedData, parsedPrefix = serialization.ParseImportString("AA:Category:2:fixture")
assert(parsed, parsedData)
assert(
    parsedData == exportedWithoutVariables and parsedData.VariablesIncluded == false and parsedPrefix == "Category",
    "Valid content-only category imports should retain their omission marker"
)

ConfigureImport("serialized-complete-category", 0, exported)
parsed, validationError = serialization.ParseImportString("AA:Category:2:fixture")
assert(
    not parsed and validationError == "Export version 2 must omit variables and metadata",
    "A v2 payload must be explicitly content-only"
)

ConfigureImport(nil, "output-too-large", validPage)
parsed, validationError = serialization.ParseImportString("AA:Page:1:fixture")
assert(not parsed, "Imports exceeding the decompressed budget should be rejected")
assert(
    validationError == "Decompressed import payload is too large",
    "Oversized imports should preserve their user-facing error"
)
assert(importState.deserializeCalls == 0, "Oversized imports must fail before deserialization")

ConfigureImport(nil, "truncated-input", validPage)
parsed, validationError = serialization.ParseImportString("AA:Page:1:fixture")
assert(not parsed and validationError == "Decompress failed: truncated-input", "Malformed streams should be rejected")
assert(importState.deserializeCalls == 0, "Malformed streams must fail before deserialization")

ConfigureImport("serialized-page", 1, validPage)
parsed, validationError = serialization.ParseImportString("AA:Page:1:fixture")
assert(not parsed and validationError == "Decompress failed: trailing data", "Trailing stream data should be rejected")
assert(importState.deserializeCalls == 0, "Streams with trailing data must fail before deserialization")

AngryAssign_Categories[1].CategoryId = 2
AngryAssign_Categories[2].CategoryId = 1
local cyclicExport, cyclicExportError = serialization.GetCategoryExportData(AngryEra, 1)
assert(cyclicExport == nil, "Cyclic category exports must fail instead of silently dropping content")
assert(cyclicExportError == "category-cycle", "Cyclic category exports should return a stable error")

print("Category serialization tests passed.")
