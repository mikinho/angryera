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
local printedMessages = {}
local autoAdvanceRetryCancellations = 0
local operationLog = {}

_G.RED_FONT_COLOR_CODE = "<red>"

function AngryEra:UpdateTree()
    updateTreeCalls = updateTreeCalls + 1
end

function AngryEra:UpdateSelected() end

function AngryEra:Print(message)
    printedMessages[#printedMessages + 1] = message
end

function AngryEra:UpdateDisplayed()
    updateDisplayCalls = updateDisplayCalls + 1
    operationLog[#operationLog + 1] = "render"
end

function AngryEra:SendPage(id)
    sentPageId = id
    return true, "page-message"
end

function AngryEra:SendDisplay(id, force)
    operationLog[#operationLog + 1] = "send-display"
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

function AngryEra:CancelAutoAdvancePublishRetry()
    autoAdvanceRetryCancellations = autoAdvanceRetryCancellations + 1
    self._autoAdvancePublishRetry = nil
    return true
end

function AngryEra:ClearActiveDisplayReference()
    activeClearCalls = activeClearCalls + 1
    return true
end

function AngryEra:CanLocalPlayerPublish(action)
    return action == "display" and canPublishDisplay
end

function AngryEra:CanEditEntityLocally()
    return true
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
operationLog = {}
local cancellationsBeforeActiveUpdate = autoAdvanceRetryCancellations
AngryEra:PageUpdated(42)
assert(sentPageId == nil, "An active page update should not send an unpaired page snapshot")
assert(
    #sentDisplays == 1 and sentDisplays[1].Id == 42,
    "An active page update should publish its exact page and display tuple"
)
assert(
    operationLog[1] == "send-display" and operationLog[2] == "render",
    "an active page update should activate its new exact tuple before rendering"
)
assert(
    autoAdvanceRetryCancellations == cancellationsBeforeActiveUpdate + 1,
    "an active page update should cancel a superseded auto-advance retry after activation"
)

sentPageId = nil
canPublishDisplay = false
local displaysBeforeAssistantUpdate = #sentDisplays
local cancellationsBeforeAssistantUpdate = autoAdvanceRetryCancellations
AngryEra:PageUpdated(42)
assert(sentPageId == 42, "an assistant should publish an active-page edit as PAGE_UPSERT")
assert(
    #sentDisplays == displaysBeforeAssistantUpdate,
    "an assistant active-page edit must not replace the leader-controlled display"
)
assert(
    autoAdvanceRetryCancellations == cancellationsBeforeAssistantUpdate,
    "a page-only assistant publication must not alter display retry state"
)

sentPageId = nil
local showsBeforeAssistantSave = showDisplayCalls
local notificationsBeforeAssistantSave = displayNotificationCalls
AngryEra:UpdateContents(42, "Assistant revision")
assert(sentPageId == 42, "assistant Save should publish the active page without selecting it")
assert(showDisplayCalls == showsBeforeAssistantSave, "assistant Save must not reopen an unchanged leader display")
assert(
    displayNotificationCalls == notificationsBeforeAssistantSave,
    "assistant Save must not announce an unchanged leader display"
)

sentPageId = nil
local showsBeforeAssistantRename = showDisplayCalls
local renamed, renameError = AngryEra:RenamePage(42, "Assistant rename")
assert(renamed and not renameError, "assistant rename should remain a valid page edit")
assert(sentPageId == 42, "assistant rename should publish the active page without selecting it")
assert(showDisplayCalls == showsBeforeAssistantRename, "assistant rename must not reopen an unchanged leader display")

canPublishDisplay = true

AngryAssign_State.displayed = nil
displaySendOk = false
displaySendResult = "preparation-failed"
displayActivatedLocally = false
local displayUpdatesBeforeFailure = updateDisplayCalls
local retainedRetry = {}
AngryEra._autoAdvancePublishRetry = retainedRetry
local cancellationsBeforeFailedDisplay = autoAdvanceRetryCancellations
local displayed, displayError, published, publicationResult = AngryEra:DisplayPage(42)
assert(not displayed and displayError == "preparation-failed", "display preparation errors should be returned")
assert(
    published == false and publicationResult == "preparation-failed",
    "failed activation should expose publication failure"
)
assert(AngryAssign_State.displayed == nil, "failed activation must not commit the displayed page id")
assert(updateDisplayCalls == displayUpdatesBeforeFailure, "failed activation must not render a local fallback")
assert(
    AngryEra._autoAdvancePublishRetry == retainedRetry
        and autoAdvanceRetryCancellations == cancellationsBeforeFailedDisplay,
    "a failed replacement display must preserve the existing publication retry"
)
assert(#printedMessages == 1, "a failed display activation should be reported to the user")
assert(printedMessages[1]:find("preparation-failed", 1, true), "the report should carry the failure code")

displaySendResult = "transport-failed"
displayActivatedLocally = true
displayed, displayError, published, publicationResult = AngryEra:DisplayPage(42)
assert(displayed and displayError == nil, "transport failure after activation should retain local display success")
assert(
    published == false and publicationResult == "transport-failed",
    "transport failure should be independently exposed"
)
assert(AngryAssign_State.displayed == 42, "successful activation should commit despite transport failure")
assert(
    AngryEra._autoAdvancePublishRetry == nil and autoAdvanceRetryCancellations == cancellationsBeforeFailedDisplay + 1,
    "a successful replacement activation should cancel the superseded retry"
)
assert(
    showDisplayCalls == 1 and displayNotificationCalls == 1,
    "successful local activation should refresh the display"
)
assert(#printedMessages == 1, "a transport-only failure after activation should not be reported as an error")
displaySendOk = true
displaySendResult = "display-message-id"
local updatesBeforeSamePagePublish = updateDisplayCalls
displayed, displayError, published, publicationResult = AngryEra:DisplayPage(42)
assert(displayed and displayError == nil, "a published display should remain a local success")
assert(published == true and publicationResult == "display-message-id", "publication success should be exposed")
assert(
    sentDisplays[#sentDisplays].Id == 42 and sentDisplays[#sentDisplays].Force == false,
    "an ordinary DisplayPage should activate locally through non-forced publication"
)
assert(
    updateDisplayCalls == updatesBeforeSamePagePublish + 1,
    "republishing the same page should render its newly activated exact tuple"
)
assert(
    showDisplayCalls == 1 and displayNotificationCalls == 1,
    "same-page republication should not repeat page-change UI effects"
)
displaySendResult = nil

AngryAssign_Pages[50] = {
    Id = 50,
    CategoryId = 9,
    Index = 1,
    Name = "Navigation A",
    Contents = "",
}
AngryAssign_Pages[51] = {
    Id = 51,
    CategoryId = 9,
    Index = 2,
    Name = "Navigation B",
    Contents = "",
}
AngryAssign_State.displayed = 50
local sendsBeforeNextPage = #sentDisplays
AngryEra:NextPage()
assert(AngryAssign_State.displayed == 51, "NextPage should activate the next page locally")
assert(
    #sentDisplays == sendsBeforeNextPage + 1
        and sentDisplays[#sentDisplays].Id == 51
        and sentDisplays[#sentDisplays].Force == false,
    "NextPage should use non-forced publication"
)

local sendsBeforePrevPage = #sentDisplays
AngryEra:PrevPage()
assert(AngryAssign_State.displayed == 50, "PrevPage should activate the previous page locally")
assert(
    #sentDisplays == sendsBeforePrevPage + 1
        and sentDisplays[#sentDisplays].Id == 50
        and sentDisplays[#sentDisplays].Force == false,
    "PrevPage should use non-forced publication"
)
AngryAssign_Pages[50] = nil
AngryAssign_Pages[51] = nil

local sendsBeforeLocalClear = #sentDisplays
AngryAssign_State.displayed = 42
local cancellationsBeforeClear = autoAdvanceRetryCancellations
local cleared, clearError = AngryEra:ClearDisplayed()
assert(cleared and not clearError, "local display clear should succeed")
assert(AngryAssign_State.displayed == nil, "local display clear should reset selection")
assert(activeClearCalls == 1, "local display clear should discard the exact active tuple")
assert(#sentDisplays == sendsBeforeLocalClear, "local-only clear must not publish")
assert(
    autoAdvanceRetryCancellations == cancellationsBeforeClear + 1,
    "clearing the display should synchronously cancel a stale auto-advance retry"
)

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
