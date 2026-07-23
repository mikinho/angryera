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
    Contents = "{STAR} {RT1} {Circle} {X} {SKULL}",
})

assert(output == "{rt1} {rt1} {rt2} {rt7} {rt8}")

print("Chat output tests passed.")
