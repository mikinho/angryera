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

local activeRenderFailure = false
function AngryEra:RenderPageContent(page, _, options)
    if activeRenderFailure and options and options.UseActiveDisplayContext then
        return "", {}, "missing-active-display-context", page
    end
    local renderedPage = options and options.UseActiveDisplayContext and page.ActiveSnapshot or page
    return renderedPage.Contents, {}, nil, renderedPage
end

local app = { AngryEra = AngryEra }
assert(loadfile("modules/chat_output.lua"))("AngryEra", app)

local markerSource = "{STAR} {rt1} {Circle} {DIAMOND} {Triangle} {MOON} {Square} {X} {cross} {SKULL}"
local output = AngryEra:RenderPageForChatOutput({
    Name = "Target Page",
    Contents = markerSource,
})

assert(
    output == "{rt1} {rt1} {rt2} {rt3} {rt4} {rt5} {rt6} {rt7} {rt7} {rt8}",
    "chat output should continue normalizing named and explicit raid-target tokens"
)

local exportedOutput = AngryEra:ProcessPageForOutput({
    Name = "Discord Page",
    Contents = markerSource .. " {PAGE}",
})
assert(
    exportedOutput == markerSource .. " Discord Page",
    "Export -> Output should preserve every raid-target token's exact source spelling while resolving other tags"
)

AngryAssign_State = { displayed = 1 }
AngryAssign_Pages = {
    [1] = { Name = "Displayed Page" },
}

local pageOutput = AngryEra:RenderPageForChatOutput({
    Name = "Rendered Page",
    Contents = "{PAGE}",
})
assert(pageOutput == "Rendered Page", "{page} should use the page passed to the renderer")

local activeOutput = AngryEra:RenderPageForChatOutput({
    Name = "Stored Page",
    Contents = "{PAGE}",
    ActiveSnapshot = {
        Name = "Exact Active Page",
        Contents = "{PAGE}",
    },
}, true)
assert(activeOutput == "Exact Active Page", "Active chat output should use the exact display snapshot")

activeRenderFailure = true
activeOutput = AngryEra:RenderPageForChatOutput({
    Name = "Unsafe Local Fallback",
    Contents = "must not be sent",
}, true)
activeRenderFailure = false
assert(activeOutput == "", "Active chat output must remain blank when its exact tuple is unavailable")

AngryEra.utils.helpers.GetSpellLink = function(id)
    return "|cff71d5ff|Hspell:" .. id .. "|h[Frostbolt]|h|r"
end

local strippedOutput = AngryEra:RenderPageForChatOutput({
    Name = "Colored Page",
    Contents = "|cffff0000Tanks|r and |cFF00FF00Heals|r",
})
assert(strippedOutput == "Tanks and Heals", "glued hex color codes must strip cleanly from chat output")

local sanitizedOutput = AngryEra:RenderPageForChatOutput({
    Name = "Hostile Page",
    Contents = "|Hitem:123|h[Epic Cloak]|h pull |T133784:16|t now ||grouped",
})
assert(
    sanitizedOutput == "[Epic Cloak] pull  now grouped",
    "chat output must keep pasted link names while dropping every other escape and leftover pipe"
)

local spellOutput = AngryEra:RenderPageForChatOutput({
    Name = "Spell Page",
    Contents = "{spell 116} |Tbad|t",
})
assert(spellOutput == "|Hspell:116|h[Frostbolt]|h ", "links produced by tag resolution must survive chat sanitization")

local exportOutput = AngryEra:ProcessPageForOutput({
    Name = "Export Page",
    Contents = "A||B |cffff0000Rend|r",
})
assert(exportOutput == "A||B Rend", "export output should strip colors while preserving literal pipes")

local outputPermissionChecks = 0
local deniedOutputMessage
function AngryEra:CanLocalPlayerOutput()
    outputPermissionChecks = outputPermissionChecks + 1
    return false
end
function AngryEra:Print(message)
    deniedOutputMessage = message
end
_G.RED_FONT_COLOR_CODE = "<red>"
AngryEra:OutputDisplayed(1)
assert(outputPermissionChecks == 1, "chat output should use its independent local authority check")
assert(
    deniedOutputMessage and deniedOutputMessage:find("permission to output", 1, true),
    "denied chat output should explain the permission failure"
)

function AngryEra:CanLocalPlayerOutput()
    return true
end
local sentMessages = {}
_G.SendChatMessage = function(message, channel)
    assert(channel == "RAID")
    table.insert(sentMessages, message)
end
_G.IsInRaid = function()
    return true
end
_G.IsInGroup = function()
    return true
end
local repeatingCallback
function AngryEra:ScheduleRepeatingTimer(callback)
    repeatingCallback = callback
    return "chat-output-timer"
end
function AngryEra:CancelTimer(token)
    assert(token == "chat-output-timer")
    repeatingCallback = nil
    return true
end

local longWords = {}
for i = 1, 60 do
    table.insert(longWords, "word" .. i)
end
local wordsLine = table.concat(longWords, " ")
AngryAssign_Pages[2] = {
    Name = "Long Page",
    Contents = "short\n" .. wordsLine .. "\n" .. string.rep("x", 600),
}
AngryEra:OutputDisplayed(2)
while repeatingCallback do
    repeatingCallback()
end
assert(#sentMessages > 3, "long content should queue multiple wrapped chat lines")
for _, message in ipairs(sentMessages) do
    assert(#message > 0 and #message <= 255, "every queued chat line must fit the send limit")
    assert(not message:find("\n", 1, true), "queued chat lines must never contain newlines")
end
assert(sentMessages[1] == "short", "the first rendered line should send immediately and unchanged")
local expectedStream = (wordsLine .. string.rep("x", 600)):gsub(" ", "")
local actualStream = table.concat(sentMessages, "", 2):gsub(" ", "")
assert(actualStream == expectedStream, "wrapping must preserve every non-space character in order")

sentMessages = {}
AngryAssign_Pages[3] = {
    Name = "Newline Page",
    Contents = string.rep("\n", 9000) .. "x",
}
AngryEra:OutputDisplayed(3)
assert(
    #sentMessages == 1 and sentMessages[1] == "x",
    "newline-heavy pages must send only their real content without exploding the line splitter"
)

local outputId = false
function AngryEra:OutputDisplayed(id)
    outputId = id
end

AngryEra_OutputDisplayed()
assert(outputId == nil, "The output keybinding should defer to the actively displayed page")

print("Chat output tests passed.")
