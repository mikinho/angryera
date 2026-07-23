local function TestHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local currentTime = 1000
local unpackValues = unpack or rawget(table, "unpack")

function _G.time()
    return currentTime
end
function _G.strsplit(separator, text)
    local parts = {}
    for piece in (text .. separator):gmatch("([^" .. separator .. "]*)" .. separator) do
        parts[#parts + 1] = piece
    end
    return unpackValues(parts)
end
_G.C_Timer = {
    After = function() end,
}
_G.IsInRaid = function()
    return false
end
_G.IsInGroup = function()
    return false
end
_G.UnitName = function()
    return "Viewer"
end
_G.UnitClass = function()
    return "Warrior", "WARRIOR"
end
_G.RAID_CLASS_COLORS = {
    WARRIOR = { colorStr = "ffc79c6e" },
}

local app = {
    AngryEra = {
        core = {
            isClassic = true,
            isClassicTBC = false,
            isClassicWrath = false,
        },
        utils = {
            helpers = {
                EnsureUnitFullName = function(player)
                    return player
                end,
                EnsureUnitShortName = function(player)
                    return player
                end,
                PlayerFullName = function()
                    return "Viewer-Realm"
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
                ProcessTag = function(value, page)
                    if value:lower() == "{page}" then
                        return page and page.Name or value
                    end
                    return value
                end,
                ChatOutputClassMap = {},
                UtilityChatData = {},
                UtilityChatMap = {},
            },
        },
    },
    libs = {
        lwin = {},
        LSM = {},
        LibMustache = {
            render = function(text, context)
                return (
                    text:gsub("{{%s*([^{}]-)%s*}}", function(key)
                        key = key:match("^%s*(.-)%s*$")
                        local value = context[key]
                        if value == nil then
                            return "{{" .. key .. "}}"
                        end
                        return tostring(value)
                    end)
                )
            end,
        },
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/protocol.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/revisions.lua"))("AngryEra", app)
assert(loadfile("modules/sync/active_page.lua"))("AngryEra", app)
assert(loadfile("modules/sync/page_runtime.lua"))("AngryEra", app)
assert(loadfile("modules/ui/display.lua"))("AngryEra", app)
assert(loadfile("modules/chat_output.lua"))("AngryEra", app)
assert(loadfile("modules/api.lua"))("AngryEra", app)

local AngryEra = app.AngryEra

local localInstallationId = "ae3i:1:2:3:4"
local remoteInstallationId = "ae3i:a:b:c:d"
local categorySyncId = localInstallationId .. ":category:1"
local pageSyncId = localInstallationId .. ":page:2"
local remotePageSyncId = remoteInstallationId .. ":page:9"
local hashedCategorySyncId = localInstallationId .. ":category:5"
local hashedPageSyncId = localInstallationId .. ":page:6"

_G.AngryAssign_Meta = {
    SchemaVersion = 1,
    InstallationId = localInstallationId,
    EntityCounter = 10,
    EntityLocal = {
        [categorySyncId] = { OwnedLocally = true },
        [pageSyncId] = { OwnedLocally = true },
        [hashedCategorySyncId] = { OwnedLocally = true },
        [hashedPageSyncId] = { OwnedLocally = true },
    },
    SyncScopes = {},
}
_G.AngryAssign_Categories = {
    [1] = {
        Id = 1,
        Name = "Naxxramas",
        SyncId = categorySyncId,
        OwnerId = localInstallationId,
        Vars = "",
    },
    [4025479151] = {
        Id = 4025479151,
        Name = "Legacy Folder",
        SyncId = hashedCategorySyncId,
        OwnerId = localInstallationId,
        Vars = "$raid=Legacy",
    },
}
_G.AngryAssign_Pages = {
    [2] = {
        Id = 2,
        Name = "Patchwerk",
        SyncId = pageSyncId,
        OwnerId = localInstallationId,
        CategoryId = 1,
        Contents = "MT = {{MT}}\n$MT = {{$MT}}",
        Vars = "MT=Zessy\n$MT=Meta",
    },
    [9] = {
        Id = 9,
        Name = "Remote",
        SyncId = remotePageSyncId,
        OwnerId = remoteInstallationId,
        Contents = "remote body",
        Vars = "",
    },
    [3221957842] = {
        Id = 3221957842,
        Name = "Legacy Page",
        SyncId = hashedPageSyncId,
        OwnerId = localInstallationId,
        CategoryId = 4025479151,
        Contents = "Raid: {{$raid}}",
        Vars = "",
    },
}
_G.AngryAssign_State = {
    displayed = nil,
    display = {},
    tree = {},
    directionUp = false,
}

function AngryEra:GetSyncHashCallback()
    return TestHash
end
function AngryEra:CanLocalPlayerPublish()
    return true
end
function AngryEra:GetProtocolSession()
    return {
        InstallationId = localInstallationId,
        SessionId = "session-1",
    }
end
function AngryEra:GetConfig(key)
    local defaults = {
        highlight = "",
        highlightColor = "ffd200",
        color = "ffffff",
        lineSpacing = 0,
        chatoutput = "Acronym",
    }
    return defaults[key]
end
function AngryEra:GetCurrentGroup()
    return nil
end
function AngryEra:UpdateBackdrop() end
AngryEra.GuildColors = nil

local rendered = {}
AngryEra.display_text = {
    Clear = function()
        rendered = {}
    end,
    AddMessage = function(_, line)
        rendered[#rendered + 1] = line
    end,
    IsShown = function()
        return true
    end,
}

local function RenderedBody()
    return table.concat(rendered, "\n")
end

AngryEra:ResetActivePageTransientState()

-- The activated exact snapshot renders normally.
local displayPayload, pagePayload = AngryEra:BuildActiveDisplayPayload(2, {
    UpdatedAt = time(),
    UpdatedBy = "Viewer-Realm",
})
assert(displayPayload, "local display preparation should succeed: " .. tostring(pagePayload))
local activated, activationError = AngryEra:ActivatePreparedActiveDisplay(displayPayload, pagePayload)
assert(activated == true, "local activation should succeed: " .. tostring(activationError))
AngryAssign_State.displayed = 2

AngryEra:UpdateDisplayed()
assert(#rendered > 1, "an activated display should render lines")
assert(RenderedBody():find("MT = |cffffd200Zessy|r", 1, true), "public variables should render and highlight")
assert(RenderedBody():find("$MT = Meta", 1, true), "metadata should render without highlighting")

local note = AngryEra:GetDisplayedNote()
assert(note and note.RevisionId ~= nil, "an activated display should expose revision identity")
assert(note.Meta.MT == "Meta", "metadata should reach the note API")

-- A missing active snapshot falls back to local rendering instead of a blank display.
AngryEra:ResetActivePageTransientState()
AngryEra:UpdateDisplayed()
assert(#rendered > 1, "a locally authoritative page should render without an active snapshot")
assert(RenderedBody():find("MT = |cffffd200Zessy|r", 1, true), "fallback rendering should resolve variables")
assert(RenderedBody():find("$MT = Meta", 1, true), "fallback rendering should resolve metadata")

local fallbackNote = AngryEra:GetDisplayedNote()
assert(fallbackNote and fallbackNote.RevisionId == nil, "fallback snapshots should carry no revision identity")
assert(fallbackNote.Rendered:find("Zessy", 1, true), "fallback snapshots should carry the rendered text")

-- Chat output intentionally keeps its exact-tuple requirement (no local fallback).
local chatOutput = AngryEra:RenderPageForChatOutput(AngryAssign_Pages[2], true)
assert(chatOutput == "", "active chat output must stay blank without its exact tuple")

-- A remote-owned page without an authoritative context stays blank.
AngryAssign_State.displayed = 9
AngryEra:UpdateDisplayed()
assert(RenderedBody() == " ", "a remote page without context should not render local guesses")

-- A failing note API must never abort display rendering.
AngryAssign_State.displayed = 2
function AngryEra:NotifyDisplayedNoteChanged()
    error("api boom")
end
AngryEra:UpdateDisplayed()
assert(#rendered > 1, "a failing note API must not blank the display")
assert(RenderedBody():find("Zessy", 1, true), "rendering should complete despite note API errors")

-- Legacy hashed ids above 2^31 must prepare, activate, and render.
AngryEra:ResetActivePageTransientState()
local legacyDisplay, legacyPage = AngryEra:BuildActiveDisplayPayload(3221957842, {
    UpdatedAt = time(),
    UpdatedBy = "Viewer-Realm",
})
assert(legacyDisplay, "hashed local page ids should prepare: " .. tostring(legacyPage))
local legacyActivated, legacyActivationError = AngryEra:ActivatePreparedActiveDisplay(legacyDisplay, legacyPage)
assert(legacyActivated == true, "hashed local page ids should activate: " .. tostring(legacyActivationError))
AngryAssign_State.displayed = 3221957842
AngryEra.NotifyDisplayedNoteChanged = nil
AngryEra:UpdateDisplayed()
assert(RenderedBody():find("Raid: Legacy", 1, true), "hashed ids should render with inherited metadata")

print("Display fallback tests passed.")
