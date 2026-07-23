local AngryEra = {
    utils = {
        helpers = {},
    },
}

local app = {
    AngryEra = AngryEra,
    libs = {
        libC = {},
    },
}

assert(loadfile("modules/models.lua"))("AngryEra", app)

local updateTreeCalls = 0
local updateDisplayCalls = 0
local sentPageId
local hashArguments

function AngryEra:UpdateTree()
    updateTreeCalls = updateTreeCalls + 1
end

function AngryEra:UpdateDisplayed()
    updateDisplayCalls = updateDisplayCalls + 1
end

function AngryEra:SendPage(id)
    sentPageId = id
end

function AngryEra:Hash(name, contents, vars)
    hashArguments = { name, contents, vars }
    return "new-update-id"
end

function _G.time()
    return 123456
end

AngryAssign_Pages = {
    [42] = {
        Name = "Variable Test",
        Contents = "Tank: {{MT}}",
        Vars = "MT=Player",
        Updated = 100,
        UpdateId = "old-update-id",
    },
}

AngryEra:PageUpdated(42)

local page = AngryAssign_Pages[42]
assert(page.Updated == 123456, "PageUpdated should refresh the page timestamp")
assert(page.UpdateId == "new-update-id", "PageUpdated should refresh the content identity")
assert(hashArguments[1] == page.Name, "PageUpdated should hash the page name")
assert(hashArguments[2] == page.Contents, "PageUpdated should hash the page contents")
assert(hashArguments[3] == page.Vars, "PageUpdated should hash the page variables")
assert(sentPageId == 42, "PageUpdated should broadcast the updated page")
assert(updateTreeCalls == 1, "PageUpdated should refresh the editor tree")
assert(updateDisplayCalls == 1, "PageUpdated should refresh the active display")

print("Model update tests passed.")
