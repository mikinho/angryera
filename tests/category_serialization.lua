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
        Vars = "root=yes",
    },
    [2] = {
        Id = 2,
        Name = "Child",
        CategoryId = 1,
        Index = 2,
        Vars = "child=yes",
    },
}
AngryAssign_Pages = {
    [10] = {
        Id = 10,
        Name = "Page",
        Contents = "Assignment",
        CategoryId = 1,
        Index = 1,
        Vars = "page=yes",
    },
}

function AngryEra:GetCat(id)
    return AngryAssign_Categories[id]
end

assert(loadfile("modules/utils/serialization.lua"))("AngryEra", app)
local serialization = AngryEra.utils.serialization

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
assert(exported and exported.Vars == "root=yes", "Root category variables should be exported")
assert(exported.Children[1].Type == "Page", "Encoded children should retain deterministic ordering")
assert(exported.Children[1].Vars == "page=yes", "Page variables should be exported")
assert(exported.Children[2].Type == "Category", "Nested categories should be exported")
assert(exported.Children[2].Vars == "child=yes", "Nested category variables should be exported")

local valid, validationError = serialization.ValidateEncodedCategoryPayload(exported, "Category")
assert(valid, validationError)

valid, validationError = serialization.ValidateEncodedCategoryPayload({
    Name = "Invalid",
    Vars = 42,
    Children = {},
}, "Category")
assert(not valid and validationError:find("Vars", 1, true), "Non-string category variables should be rejected")

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
