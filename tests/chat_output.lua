local AngryEra = {
    core = {
        isClassic = true,
        isClassicTBC = false,
        isClassicWrath = false,
    },
    utils = {
        colors = { ColorTable = {} },
        helpers = {},
        tags = {
            ChatOutputClassMap = {},
            UtilityChatData = {},
            UtilityChatMap = {},
        },
    },
}

function AngryEra:GetConfig(key)
    assert(key == "chatoutput")
    return "Acronym"
end

function AngryEra:GetTemplateContext()
    return {}
end

function AngryEra:RenderPageContent(page)
    return page.Contents, {}
end

local app = { AngryEra = AngryEra }
assert(loadfile("modules/chat_output.lua"))("AngryEra", app)

local output = AngryEra:RenderPageForChatOutput({
    Name = "Target Page",
    Contents = "{STAR} {RT1} {Circle} {X} {SKULL}",
})

assert(output == "{rt1} {rt1} {rt2} {rt7} {rt8}")

AngryAssign_State = { displayed = 1 }
AngryAssign_Pages = {
    [1] = { Name = "Displayed Page" },
}

local pageOutput = AngryEra:RenderPageForChatOutput({
    Name = "Rendered Page",
    Contents = "{PAGE}",
})
assert(pageOutput == "Rendered Page", "{page} should use the page passed to the renderer")

local outputId = false
function AngryEra:OutputDisplayed(id)
    outputId = id
end

AngryEra_OutputDisplayed()
assert(outputId == nil, "The output keybinding should defer to the actively displayed page")

print("Chat output tests passed.")
