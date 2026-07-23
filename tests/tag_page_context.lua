_G.LOCALIZED_CLASS_NAMES_MALE = setmetatable({}, {
    __index = function(_, class)
        return class
    end,
})
function _G.GetBuildInfo()
    return "", "", "", 11500
end

local app = {
    AngryEra = {
        utils = {
            helpers = {},
        },
    },
}

assert(loadfile("modules/utils/tags.lua"))("AngryEra", app)

local ProcessTag = app.AngryEra.utils.tags.ProcessTag
AngryAssign_State = {
    displayed = 1,
}
AngryAssign_Pages = {
    [1] = {
        Name = "Unrelated Display",
    },
}

assert(ProcessTag("{page}", {
    Name = "Render Target",
}) == "Render Target", "{page} should resolve from the explicit render target")
assert(ProcessTag("{page}") == "{page}", "{page} should remain unchanged without a render target")

print("Tag page-context tests passed.")
