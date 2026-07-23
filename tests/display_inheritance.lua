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
                        return tostring(context[key] or "")
                    end)
                )
            end,
        },
    },
}

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/ui/display.lua"))("AngryEra", app)

local AngryEra = app.AngryEra
local variableHelpers = AngryEra.utils.variables

local rootSyncId = "ae3i:1:2:3:4:category:1"
local middleSyncId = "ae3i:1:2:3:4:category:2"
local parentSyncId = "ae3i:1:2:3:4:category:3"

AngryAssign_Categories = {
    [1] = {
        Id = 1,
        SyncId = rootSyncId,
        Vars = "root=root\ntarget=root\nresolved={{target}}",
    },
    [2] = {
        Id = 2,
        SyncId = middleSyncId,
        CategoryId = 1,
        Vars = "middle=middle\ntarget=middle",
    },
    [3] = {
        Id = 3,
        SyncId = parentSyncId,
        CategoryId = 2,
        Vars = "parent=parent\ntarget=parent",
    },
}

local localPage = {
    Contents = "{{root}}/{{middle}}/{{parent}}/{{target}}/{{resolved}}",
    CategoryId = 3,
    Vars = "target=page",
}
local localText, localVariables, localError = AngryEra:RenderPageContent(localPage, {})
assert(not localError, localError)
assert(localText == "root/middle/parent/page/page", "Local render should inherit every ancestor root-to-page")
assert(localVariables.target == "page", "Page variables should win")

local chain = assert(variableHelpers.CollectCategoryChain(AngryAssign_Categories, 3))
local wireLayers = assert(variableHelpers.BuildAncestorVariableLayers(chain))
local wirePage = {
    Contents = localPage.Contents,
    ParentSyncId = parentSyncId,
    AncestorVariableLayers = wireLayers,
    Vars = localPage.Vars,
}
local wireText, wireVariables, wireError = AngryEra:RenderPageContent(wirePage, {})
assert(not wireError, wireError)
assert(wireText == localText, "Standalone wire layers should render identically to the local hierarchy")
assert(wireVariables.resolved == localVariables.resolved, "Wire and local merged variables should match")

local preferredLocalPage = {
    Contents = "{{target}}",
    CategoryId = 3,
    ParentSyncId = parentSyncId,
    AncestorVariableLayers = {
        { SyncId = parentSyncId, Vars = "target=wire" },
    },
}
local preferredText = AngryEra:RenderPageContent(preferredLocalPage, {})
assert(preferredText == "parent", "A valid local hierarchy should take precedence over packet context")

local staleLocalPage = {
    Contents = "{{target}}",
    CategoryId = 99,
    ParentSyncId = parentSyncId,
    AncestorVariableLayers = wireLayers,
    Vars = "target=page",
}
local staleText, _, staleError = AngryEra:RenderPageContent(staleLocalPage, {})
assert(staleText == "page", "A stale local parent should fall back to validated standalone layers")
assert(staleError == "missing-category", "A stale local hierarchy should remain diagnosable")

local malformedPage = {
    Contents = "{{pageOnly}}/{{root}}",
    CategoryId = 99,
    Vars = "pageOnly=yes",
}
local malformedText, malformedVariables, malformedError = AngryEra:RenderPageContent(malformedPage, {})
assert(malformedText == "yes/", "Malformed hierarchy should fall back to page variables only")
assert(malformedVariables.pageOnly == "yes", "Page variables should survive hierarchy failure")
assert(malformedError == "missing-category", "Hierarchy failures should be returned")

local legacyText = AngryEra:RenderPageContent({
    Contents = "{{legacy}}",
    CatVars = "legacy=yes",
}, {})
assert(legacyText == "yes", "Protocol-1 direct category variables should remain a temporary fallback")

local emptyText, emptyVariables = AngryEra:RenderPageContent({
    Contents = 42,
}, {})
assert(emptyText == "" and next(emptyVariables) == nil, "Malformed page contents should fail safe")

AngryAssign_State = {
    displayed = 99,
}
AngryAssign_Pages = {
    [99] = {
        Name = "Unrelated Page",
    },
}
local renderedPage = {
    Name = "Render Target",
    Contents = "{page}",
}
local renderedText
AngryEra.display_text = {
    Clear = function() end,
    AddMessage = function(_, text)
        renderedText = text
    end,
}
AngryEra.display_glow = {}
AngryEra.display_glow2 = {}
AngryEra.backdrop = {
    Hide = function() end,
}
AngryEra.GetConfig = function(_, key)
    local values = {
        backdropShow = false,
        color = "ffffff",
        glowColor = "ffffff",
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
AngryEra.ProcessMarkdown = function(_, text)
    return text
end
AngryAssign_State.directionUp = false
AngryAssign_State.displayed = 1
AngryAssign_Pages[1] = renderedPage
_G.strsplit = function(_, value)
    return value
end
_G.C_Timer = {
    After = function(_, callback)
        callback()
    end,
}
AngryEra:UpdateDisplayed()
assert(renderedText == "Render Target", "{page} should resolve from the page being rendered")

print("Display inheritance tests passed.")
