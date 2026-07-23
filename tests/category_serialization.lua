local AngryEra = {
    core = {
        MAX_IMPORT_ENCODED_BYTES = 1024,
        MAX_IMPORT_DECODED_BYTES = 1024,
        MAX_IMPORT_SERIALIZED_BYTES = 4096,
    },
    utils = {},
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

AngryAssign_Categories[1].CategoryId = 2
AngryAssign_Categories[2].CategoryId = 1
local cyclicExport, cyclicExportError = serialization.GetCategoryExportData(AngryEra, 1)
assert(cyclicExport == nil, "Cyclic category exports must fail instead of silently dropping content")
assert(cyclicExportError == "category-cycle", "Cyclic category exports should return a stable error")

print("Category serialization tests passed.")
