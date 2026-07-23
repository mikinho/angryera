local AngryEra = {
    utils = {
        helpers = {
            selectedLastValue = function(value)
                return value
            end,
            IsCategoryDescendant = function()
                return false
            end,
            ExtractAndValidateName = function(value)
                return value
            end,
        },
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
local sentDisplays = {}
local hashArguments
local activeClearCalls = 0
local canPublishDisplay = true
local displaySendOk = true
local displaySendResult
local displayActivatedLocally = true
local showDisplayCalls = 0
local displayNotificationCalls = 0

function AngryEra:UpdateTree()
    updateTreeCalls = updateTreeCalls + 1
end

function AngryEra:UpdateDisplayed()
    updateDisplayCalls = updateDisplayCalls + 1
end

function AngryEra:SendPage(id)
    sentPageId = id
end

function AngryEra:SendDisplay(id, force)
    sentDisplays[#sentDisplays + 1] = {
        Id = id,
        Force = force,
    }
    return displaySendOk, displaySendResult, displayActivatedLocally
end

function AngryEra:ShowDisplay()
    showDisplayCalls = showDisplayCalls + 1
end

function AngryEra:DisplayUpdateNotification()
    displayNotificationCalls = displayNotificationCalls + 1
end

function AngryEra:ClearActiveDisplayReference()
    activeClearCalls = activeClearCalls + 1
    return true
end

function AngryEra:CanLocalPlayerPublish(action)
    return action == "display" and canPublishDisplay
end

function AngryEra:RemovePageRecord(id)
    AngryAssign_Pages[id] = nil
end

local nextPageId = 44
function AngryEra:NewLocalPageRecord(fields)
    fields.Id = nextPageId
    nextPageId = nextPageId + 1
    return fields
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
AngryAssign_State = {
    displayed = nil,
    tree = {},
}
AngryAssign_Categories = {}

AngryEra:PageUpdated(42)

local page = AngryAssign_Pages[42]
assert(page.Updated == 123456, "PageUpdated should refresh the page timestamp")
assert(page.UpdateId == "new-update-id", "PageUpdated should refresh the content identity")
assert(hashArguments[1] == page.Name, "PageUpdated should hash the page name")
assert(hashArguments[2] == page.Contents, "PageUpdated should hash the page contents")
assert(hashArguments[3] == page.Vars, "PageUpdated should hash the page variables")
assert(sentPageId == 42, "PageUpdated should broadcast the updated page")
assert(#sentDisplays == 0, "A background page update should not change shared display selection")
assert(updateTreeCalls == 1, "PageUpdated should refresh the editor tree")
assert(updateDisplayCalls == 1, "PageUpdated should refresh the active display")

sentPageId = nil
AngryAssign_State.displayed = 42
AngryEra:PageUpdated(42)
assert(sentPageId == nil, "An active page update should not send an unpaired page snapshot")
assert(
    #sentDisplays == 1 and sentDisplays[1].Id == 42,
    "An active page update should publish its exact page and display tuple"
)

AngryAssign_State.displayed = nil
displaySendOk = false
displaySendResult = "preparation-failed"
displayActivatedLocally = false
local displayUpdatesBeforeFailure = updateDisplayCalls
local displayed, displayError = AngryEra:DisplayPage(42)
assert(not displayed and displayError == "preparation-failed", "display preparation errors should be returned")
assert(AngryAssign_State.displayed == nil, "failed activation must not commit the displayed page id")
assert(updateDisplayCalls == displayUpdatesBeforeFailure, "failed activation must not render a local fallback")

displaySendResult = "transport-failed"
displayActivatedLocally = true
displayed, displayError = AngryEra:DisplayPage(42)
assert(displayed and displayError == nil, "transport failure after activation should retain local display success")
assert(AngryAssign_State.displayed == 42, "successful activation should commit despite transport failure")
assert(
    showDisplayCalls == 1 and displayNotificationCalls == 1,
    "successful local activation should refresh the display"
)
displaySendOk = true
displaySendResult = nil

local sendsBeforeLocalClear = #sentDisplays
AngryAssign_State.displayed = 42
local cleared, clearError = AngryEra:ClearDisplayed()
assert(cleared and not clearError, "local display clear should succeed")
assert(AngryAssign_State.displayed == nil, "local display clear should reset selection")
assert(activeClearCalls == 1, "local display clear should discard the exact active tuple")
assert(#sentDisplays == sendsBeforeLocalClear, "local-only clear must not publish")

AngryAssign_State.displayed = 42
cleared, clearError = AngryEra:ClearDisplayed(true)
assert(cleared and not clearError, "authorized shared display clear should succeed")
assert(activeClearCalls == 2, "shared clear should also discard the local exact tuple")
assert(#sentDisplays == sendsBeforeLocalClear + 1, "shared clear should publish exactly once")
assert(sentDisplays[#sentDisplays].Id == nil and sentDisplays[#sentDisplays].Force, "shared clear should be forced")

canPublishDisplay = false
AngryAssign_State.displayed = 42
local sendsBeforeUnauthorizedClear = #sentDisplays
cleared, clearError = AngryEra:ClearDisplayed(true)
assert(cleared and not clearError, "unauthorized shared clear should remain a valid local operation")
assert(activeClearCalls == 3, "unauthorized clear should still discard the local exact tuple")
assert(#sentDisplays == sendsBeforeUnauthorizedClear, "unauthorized clear must not publish")

canPublishDisplay = true
AngryAssign_Pages[42] = page
AngryAssign_State.displayed = 42
local sendsBeforeDelete = #sentDisplays
AngryEra:DeletePage(42)
assert(AngryAssign_State.displayed == nil, "deleting the active page should clear local selection")
assert(activeClearCalls == 4, "deleting the active page should discard its exact tuple")
assert(#sentDisplays == sendsBeforeDelete + 1, "deleting the active page should publish one clear")
assert(sentDisplays[#sentDisplays].Id == nil and sentDisplays[#sentDisplays].Force, "delete clear should be forced")

AngryAssign_Pages[42] = page
AngryAssign_Pages[43] = {
    Name = "Sibling",
    Contents = "",
}
AngryAssign_State.displayed = 42
local sendsBeforeSiblingDelete = #sentDisplays
AngryEra:DeletePage(43)
assert(
    #sentDisplays == sendsBeforeSiblingDelete + 1 and sentDisplays[#sentDisplays].Id == 42,
    "deleting a non-active sibling should republish the active page's canonical order"
)

local sendsBeforeMissingDelete = #sentDisplays
AngryEra:DeletePage(999)
assert(
    #sentDisplays == sendsBeforeMissingDelete,
    "deleting a missing page should not republish an unchanged active hierarchy"
)

local sendsBeforeCreate = #sentDisplays
sentPageId = nil
local created, createError, createdId = AngryEra:CreatePage("Created Sibling", "", nil, nil)
assert(created and not createError and createdId == 44, "ordinary page creation should succeed")
assert(sentPageId == 44, "ordinary page creation should publish its own page revision")
assert(
    #sentDisplays == sendsBeforeCreate + 1 and sentDisplays[#sentDisplays].Id == 42,
    "ordinary page creation should republish the displayed page's canonical order"
)

local sendsBeforeSuppressedCreate = #sentDisplays
created, createError, createdId = AngryEra:CreatePage("Bulk Sibling", "", nil, nil, true)
assert(created and not createError and createdId == 45, "bulk page creation should still create its page")
assert(
    #sentDisplays == sendsBeforeSuppressedCreate,
    "bulk page creation should defer active-page republishing to its caller"
)

AngryAssign_Pages[43] = {
    Name = "Movable Sibling",
    Contents = "",
}
AngryAssign_Categories[7] = {
    Id = 7,
    Name = "Destination",
}
local sendsBeforeAssignment = #sentDisplays
AngryEra:AssignCategory(43, 7)
assert(AngryAssign_Pages[43].CategoryId == 7, "category assignment should still mutate private placement")
assert(
    #sentDisplays == sendsBeforeAssignment + 1 and sentDisplays[#sentDisplays].Id == 42,
    "moving a sibling should republish the displayed page's mixed-sibling order"
)

print("Model update tests passed.")
