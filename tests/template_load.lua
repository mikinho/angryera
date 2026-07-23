local function TestHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local currentTime = 1000
function _G.time()
    return currentTime
end
function _G.strsplit(separator, text)
    local parts = {}
    for piece in (text .. separator):gmatch("([^" .. separator .. "]*)" .. separator) do
        parts[#parts + 1] = piece
    end
    return unpack(parts)
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

assert(loadfile("Templates.lua"))("AngryEra", app)
assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/entities.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/protocol.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/sync/schema.lua"))("AngryEra", app)
assert(loadfile("modules/sync/revisions.lua"))("AngryEra", app)
assert(loadfile("modules/sync/active_page.lua"))("AngryEra", app)
assert(loadfile("modules/sync/page_runtime.lua"))("AngryEra", app)
assert(loadfile("modules/ui/display.lua"))("AngryEra", app)

local AngryEra = app.AngryEra
local templates = app.Templates

assert(type(templates) == "table" and #templates == 4, "the built-in Classic Era templates should load")

_G.AngryAssign_Meta = nil
_G.AngryAssign_Categories = {}
_G.AngryAssign_Pages = {}
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
function AngryEra:GetConfig(key)
    local defaults = {
        highlight = "",
        highlightColor = "ffd200",
        color = "ffffff",
        lineSpacing = 0,
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

-- Load every built-in Classic Era raid template the way the editor does.
for templateIndex, template in ipairs(templates) do
    local category = AngryEra:NewLocalCategoryRecord({
        Name = template.name,
        Index = templateIndex,
    })
    AngryAssign_Categories[category.Id] = category

    for pageIndex, templatePage in ipairs(template.pages) do
        local page = AngryEra:NewLocalPageRecord({
            Name = templatePage.name,
            Contents = templatePage.content,
            CategoryId = category.Id,
            Index = pageIndex,
        })
        AngryAssign_Pages[page.Id] = page
    end
end

local session = {
    InstallationId = AngryAssign_Meta.InstallationId,
    SessionId = "session-1",
}
function AngryEra:GetProtocolSession()
    return session
end

AngryEra:ResetActivePageTransientState()

-- Every template page must produce a valid v3 display payload.
local pageCount = 0
for id in pairs(AngryAssign_Pages) do
    pageCount = pageCount + 1
    local displayPayload, buildError = AngryEra:BuildActiveDisplayPayload(id, {
        UpdatedAt = time(),
        UpdatedBy = "Viewer-Realm",
    })
    assert(
        displayPayload,
        string.format("template page %s should prepare: %s", AngryAssign_Pages[id].Name, tostring(buildError))
    )
end
assert(pageCount == 42, "all template pages should be created, got " .. tostring(pageCount))

-- Displaying one template page and switching to another must both activate.
local function DisplayTemplatePage(name)
    local pageId
    for id, page in pairs(AngryAssign_Pages) do
        if page.Name == name then
            pageId = id
            break
        end
    end
    assert(pageId, "template page should exist: " .. name)

    local displayPayload, pagePayload = AngryEra:BuildActiveDisplayPayload(pageId, {
        UpdatedAt = time(),
        UpdatedBy = "Viewer-Realm",
    })
    assert(displayPayload, name .. " should prepare: " .. tostring(pagePayload))
    local activated, activationError = AngryEra:ActivatePreparedActiveDisplay(displayPayload, pagePayload)
    assert(activated == true, name .. " should activate: " .. tostring(activationError))
    AngryAssign_State.displayed = pageId
    AngryEra:UpdateDisplayed()
end

currentTime = currentTime + 1
DisplayTemplatePage("Lucifron")
assert(RenderedBody():find("Lucifron", 1, true), "the first template page should render its header")

currentTime = currentTime + 1
DisplayTemplatePage("Magmadar")
assert(RenderedBody():find("Magmadar", 1, true), "switching template pages should render the new header")

currentTime = currentTime + 1
DisplayTemplatePage("Kel'Thuzad")
assert(RenderedBody():find("Kel'Thuzad", 1, true), "switching across templates should render")

print("Template load tests passed.")
