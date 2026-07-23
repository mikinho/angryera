local app = {
    AngryEra = {
        utils = {
            helpers = {
                EnsureUnitShortName = function(value)
                    return value
                end,
                IterateGroupMembers = function() end,
            },
            colors = {
                ColorTable = {},
                HexToRGB = function()
                    return 1, 1, 1, 1
                end,
            },
            tags = {
                ProcessTag = function(value)
                    return value
                end,
            },
        },
    },
    libs = {
        lwin = {},
        LSM = {},
        LibMustache = {
            render = function(text)
                return text
            end,
        },
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/api.lua"))("AngryEra", app)
assert(loadfile("modules/ui/display.lua"))("AngryEra", app)

local AngryEra = app.AngryEra
local firstPage = {
    SyncId = "ae3i:1:2:3:4:page:1",
    Name = "First Page",
    Contents = "First assignment",
}
local secondPage = {
    SyncId = "ae3i:1:2:3:4:page:2",
    Name = "Second Page",
    Contents = "Second assignment",
}
local rendered = {}

AngryAssign_Categories = {}
AngryAssign_Pages = {
    [1] = firstPage,
    [2] = secondPage,
}
AngryAssign_State = {
    directionUp = false,
    displayed = 1,
}

AngryEra.display_text = {
    Clear = function()
        for index = #rendered, 1, -1 do
            rendered[index] = nil
        end
    end,
    AddMessage = function(_, text)
        rendered[#rendered + 1] = text
    end,
}
AngryEra.GetConfig = function(_, key)
    local values = {
        highlight = "",
        highlightColor = "ffffff",
    }
    return values[key]
end
AngryEra.GetCurrentGroup = function()
    return 1
end
AngryEra.GetTemplateContext = function()
    return {
        rosterColors = {},
    }
end
AngryEra.UpdateBackdrop = function() end

function _G.strsplit(_, text)
    return text
end

_G.C_Timer = {
    After = function(_, callback)
        callback()
    end,
}

local function RenderedBody()
    return table.concat(rendered, "\n")
end

local listenerMode
local eventSawCommittedDisplay = false
_G.WeakAuras = {
    ScanEvents = function(event, syncId)
        if event == AngryEra.NOTE_UPDATE_EVENT and syncId == firstPage.SyncId and listenerMode ~= nil then
            eventSawCommittedDisplay = RenderedBody() == firstPage.Contents
            local action = listenerMode
            listenerMode = nil
            if action == "switch" then
                AngryAssign_State.displayed = 2
            else
                AngryAssign_State.displayed = nil
            end
            AngryEra:UpdateDisplayed()
        end
    end,
}

listenerMode = "switch"
AngryEra:UpdateDisplayed()

local switchedNote = AngryEra:GetDisplayedNote()
assert(eventSawCommittedDisplay, "The note update event should observe the committed first-page display")
assert(AngryAssign_State.displayed == 2, "The synchronous listener should switch the active page")
assert(RenderedBody() == secondPage.Contents, "The outer render must not overwrite the listener's page")
assert(switchedNote and switchedNote.SyncId == secondPage.SyncId, "The note snapshot should match the switched page")
assert(switchedNote.Rendered == secondPage.Contents, "The note snapshot and visible text should stay consistent")

AngryEra:NotifyDisplayedNoteChanged(nil)
AngryEra.display_text:Clear()
AngryAssign_State.displayed = 1
eventSawCommittedDisplay = false
listenerMode = "clear"
AngryEra:UpdateDisplayed()

assert(eventSawCommittedDisplay, "The clear listener should observe the committed first-page display")
assert(AngryAssign_State.displayed == nil, "The synchronous listener should clear the active page")
assert(RenderedBody() == "", "The outer render must not restore text after a listener clears the display")
assert(AngryEra:GetDisplayedNote() == nil, "The cleared display should retain a cleared note snapshot")

print("Display note API integration tests passed.")
