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

local canPublishDisplay = false
local permissionChecks = 0
local displaySends = {}
local activeReferenceClears = 0
local retryCancellations = 0
local displayUpdates = 0
local treeUpdates = 0

function AngryEra:CanLocalPlayerPublish(action)
    assert(action == "display", "delegated model actions should check display publication authority")
    permissionChecks = permissionChecks + 1
    return canPublishDisplay
end

function AngryEra:SendDisplay(id, force)
    displaySends[#displaySends + 1] = {
        Id = id,
        Force = force,
    }
    return true, "display-message", true
end

function AngryEra:CancelAutoAdvancePublishRetry()
    retryCancellations = retryCancellations + 1
    self._autoAdvancePublishRetry = nil
end

function AngryEra:ClearActiveDisplayReference()
    activeReferenceClears = activeReferenceClears + 1
    return true
end

function AngryEra:UpdateDisplayed()
    displayUpdates = displayUpdates + 1
end

function AngryEra:UpdateTree()
    treeUpdates = treeUpdates + 1
end

function AngryEra:Print()
    error("unauthorized navigation must stop before producing hierarchy-dependent output")
end

local function ExpectAuthorityDenial(label, callback)
    local called, result, errorCode, published, publicationResult = pcall(callback)
    assert(called, label .. " should stop before inspecting the local hierarchy")
    assert(result == nil, label .. " should not report local display success")
    assert(errorCode == "not-angryera-authority", label .. " should report the authority boundary")
    if label == "DisplayPage" then
        assert(published == false, "DisplayPage denial should expose an explicit non-publication result")
        assert(
            publicationResult == "not-angryera-authority",
            "DisplayPage denial should expose the publication authority error"
        )
    end
end

AngryAssign_State = {
    displayed = 41,
    tree = {},
}
AngryAssign_Categories = {}
AngryAssign_Pages = setmetatable({}, {
    __index = function()
        error("unauthorized navigation inspected a local page")
    end,
    __pairs = function()
        error("unauthorized navigation enumerated the local hierarchy")
    end,
})

AngryEra.lastNonFirstPageId = 99
ExpectAuthorityDenial("DisplayPage", function()
    return AngryEra:DisplayPage(42)
end)
ExpectAuthorityDenial("NextPage", function()
    return AngryEra:NextPage()
end)
ExpectAuthorityDenial("PrevPage", function()
    return AngryEra:PrevPage()
end)
ExpectAuthorityDenial("FirstPage", function()
    return AngryEra:FirstPage()
end)
assert(AngryAssign_State.displayed == 41, "unauthorized display navigation must preserve the active local page")
assert(AngryEra.lastNonFirstPageId == 99, "unauthorized first-page navigation must preserve toggle memory")
assert(#displaySends == 0, "unauthorized display navigation must never enter the send path")
assert(permissionChecks == 4, "each denied display navigation action should perform exactly one authority check")

AngryEra:ResetDisplayNavigationState()
assert(AngryEra.lastNonFirstPageId == nil, "authority handoff should clear first-page toggle memory")

AngryAssign_Pages = {}
AngryAssign_State.displayed = 41
AngryEra._autoAdvancePublishRetry = {}
local retainedRetry = AngryEra._autoAdvancePublishRetry
local cleared, clearError = AngryEra:ClearSharedDisplay()
assert(not cleared and clearError == "not-angryera-authority", "an unauthorized shared clear should fail closed")
assert(AngryAssign_State.displayed == 41, "an unauthorized shared clear must preserve the local display selection")
assert(AngryEra._autoAdvancePublishRetry == retainedRetry, "an unauthorized shared clear must preserve retry state")
assert(activeReferenceClears == 0, "an unauthorized shared clear must preserve the active exact reference")
assert(retryCancellations == 0, "an unauthorized shared clear must not cancel display work")
assert(displayUpdates == 0 and treeUpdates == 0, "an unauthorized shared clear must not redraw local state")
assert(#displaySends == 0, "an unauthorized shared clear must not publish")
assert(permissionChecks == 5, "the denied shared clear should perform one preflight authority check")

canPublishDisplay = true
cleared, clearError = AngryEra:ClearSharedDisplay()
assert(cleared and clearError == nil, "the delegated AngryEra authority should be able to clear the shared display")
assert(AngryAssign_State.displayed == nil, "an authorized shared clear should clear the local display selection")
assert(AngryEra._autoAdvancePublishRetry == nil, "an authorized shared clear should cancel stale display work")
assert(activeReferenceClears == 1, "an authorized shared clear should discard the active exact reference")
assert(retryCancellations == 1, "an authorized shared clear should cancel display retry state exactly once")
assert(displayUpdates == 1 and treeUpdates == 1, "an authorized shared clear should refresh local display state")
assert(#displaySends == 1, "an authorized shared clear should publish exactly once")
assert(displaySends[1].Id == nil and displaySends[1].Force == true, "the canonical clear should be forced")
assert(permissionChecks == 7, "an authorized shared clear should preflight and recheck immediately before publication")

print("Delegated model authority tests passed.")
