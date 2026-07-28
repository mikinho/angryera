-- Regression coverage for the destructive "Wipe Unpinned" transaction and
-- its main-menu confirmation. The wipe must fail closed, preserve every pin
-- boundary, and refresh the display/tree only once after a validated batch.

local function SelectedLastValue(value)
    if type(value) == "string" then
        value = value:match("([^\001]+)$")
    end
    return tonumber(value)
end

local AngryEra = {
    utils = {
        helpers = {
            selectedLastValue = SelectedLastValue,
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

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/models.lua"))("AngryEra", app)

local pinned = {}
local calls
local canPublishDisplay
local clearDisplayedError
local refreshDisplayedError

local function ResetCalls()
    calls = {
        RemovedCategories = {},
        RemovedPages = {},
        ClearedConflicts = {},
        ClearDisplayed = 0,
        ClearSharedDraft = 0,
        RefreshDisplayed = 0,
        UpdateDisplayed = 0,
        UpdateSelected = 0,
        UpdateTree = 0,
    }
end

function AngryEra:IsPinned(entity)
    return pinned[entity] == true
end

function AngryEra:RemovePageRecord(id)
    calls.RemovedPages[#calls.RemovedPages + 1] = id
    AngryAssign_Pages[id] = nil
end

function AngryEra:RemoveCategoryRecord(id)
    calls.RemovedCategories[#calls.RemovedCategories + 1] = id
    AngryAssign_Categories[id] = nil
end

function AngryEra:ClearSyncDraftConflict(syncId)
    calls.ClearedConflicts[#calls.ClearedConflicts + 1] = syncId
end

function AngryEra:ClearSharedPageChangeDraft()
    calls.ClearSharedDraft = calls.ClearSharedDraft + 1
end

function AngryEra:ClearDisplayed(publish)
    assert(publish == true, "the destructive wipe should publish one display clear")
    calls.ClearDisplayed = calls.ClearDisplayed + 1
    AngryAssign_State.displayed = nil
    calls.UpdateDisplayed = calls.UpdateDisplayed + 1
    calls.UpdateTree = calls.UpdateTree + 1
    return clearDisplayedError == nil, clearDisplayedError
end

function AngryEra:RefreshDisplayedPageAfterHierarchyMutation()
    calls.RefreshDisplayed = calls.RefreshDisplayed + 1
    return refreshDisplayedError == nil, refreshDisplayedError
end

function AngryEra:CanLocalPlayerPublish(action)
    return action == "display" and canPublishDisplay == true
end

function AngryEra:UpdateSelected(destructive, preserveSharedDraft)
    calls.UpdateSelected = calls.UpdateSelected + 1
    calls.LastUpdateSelectedDestructive = destructive
    calls.LastUpdateSelectedPreservedDraft = preserveSharedDraft
end

function AngryEra:UpdateTree()
    calls.UpdateTree = calls.UpdateTree + 1
end

local function Category(id, parentId)
    return {
        Id = id,
        CategoryId = parentId,
        Name = "Category " .. id,
        SyncId = "category:" .. id,
    }
end

local function Page(id, parentId)
    return {
        Id = id,
        CategoryId = parentId,
        Name = "Page " .. id,
        Contents = "",
        SyncId = "page:" .. id,
    }
end

local function SetLibrary(categories, pages, state)
    AngryAssign_Categories = categories
    AngryAssign_Pages = pages
    AngryAssign_State = state
        or {
            displayed = nil,
            tree = {
                groups = {},
                selected = nil,
            },
        }
    pinned = {}
    canPublishDisplay = true
    clearDisplayedError = nil
    refreshDisplayedError = nil
    ResetCalls()
end

local function Contains(values, wanted)
    for _, value in ipairs(values) do
        if value == wanted then
            return true
        end
    end
    return false
end

-- One fixture covers all retention boundaries:
-- * category 1 is pinned, so its complete subtree survives;
-- * category 7 is pinned beneath disposable category 6 and must move to root;
-- * page 106 is directly pinned beneath category 6 and must also move to root.
local categories = {
    [1] = Category(1),
    [2] = Category(2, 1),
    [3] = Category(3, 2),
    [4] = Category(4),
    [5] = Category(5, 4),
    [6] = Category(6),
    [7] = Category(7, 6),
    [8] = Category(8, 7),
}
local pages = {
    [101] = Page(101, 1),
    [102] = Page(102, 3),
    [103] = Page(103, 5),
    [104] = Page(104),
    [105] = Page(105),
    [106] = Page(106, 6),
    [107] = Page(107, 8),
    [108] = Page(108, 6),
    [109] = Page(109, 4),
}
SetLibrary(categories, pages, {
    displayed = 109,
    tree = {
        selected = 109,
        groups = {
            [-1] = true,
            [-4] = true,
            [-5] = true,
            [-6] = true,
            ["-1\001-2"] = true,
            ["-4\001-5"] = true,
            ["-6\001-7"] = true,
            untouched = true,
        },
    },
})
pinned[categories[1]] = true
pinned[categories[7]] = true
pinned[pages[105]] = true
pinned[pages[106]] = true

local plan, planError = AngryEra:PrepareUnpinnedWipe()
assert(plan and not planError, "a valid mixed library should produce a wipe plan")
assert(plan.PageCount == 4 and plan.CategoryCount == 3, "the plan should count only disposable entities")
assert(
    plan.CategoryIds[1] == 5 and plan.CategoryIds[2] == 4 and plan.CategoryIds[3] == 6,
    "categories should be planned leaf-first with deterministic sibling order"
)
assert(
    plan.PageIds[1] == 103 and plan.PageIds[2] == 104 and plan.PageIds[3] == 108 and plan.PageIds[4] == 109,
    "only pages outside pin boundaries should be planned"
)
assert(plan.CategoryParents[7] == false, "a pinned nested category should be planned for root reparenting")
assert(plan.PageParents[106] == false, "a directly pinned page should be planned for root reparenting")

local removedPages, removedCategories, wipeError = AngryEra:WipeUnpinned(plan)
assert(
    removedPages == 4 and removedCategories == 3 and not wipeError,
    "the prepared plan should execute with its exact confirmed counts"
)
assert(
    AngryAssign_Categories[1] and AngryAssign_Categories[2] and AngryAssign_Categories[3],
    "a pinned category should protect its complete unpinned descendant category subtree"
)
assert(
    AngryAssign_Pages[101] and AngryAssign_Pages[102],
    "a pinned category should protect every unpinned page in its descendant subtree"
)
assert(AngryAssign_Categories[7] and AngryAssign_Categories[8], "a pinned nested category should keep its subtree")
assert(AngryAssign_Categories[7].CategoryId == nil, "a retained pinned category should move above a deleted parent")
assert(AngryAssign_Categories[8].CategoryId == 7, "descendants should remain attached to their pinned root")
assert(AngryAssign_Pages[107].CategoryId == 8, "pages below a retained pinned category should remain attached")
assert(AngryAssign_Pages[105], "a directly pinned root page should survive")
assert(AngryAssign_Pages[106] and AngryAssign_Pages[106].CategoryId == nil, "a pinned page should survive and rehome")
assert(not AngryAssign_Categories[4] and not AngryAssign_Categories[5] and not AngryAssign_Categories[6])
assert(not AngryAssign_Pages[103] and not AngryAssign_Pages[104])
assert(not AngryAssign_Pages[108] and not AngryAssign_Pages[109])
assert(
    calls.RemovedCategories[1] == 5 and calls.RemovedCategories[2] == 4 and calls.RemovedCategories[3] == 6,
    "category removal should preserve the validated leaf-first order"
)
assert(#calls.RemovedPages == 4, "every planned page should be removed exactly once")
assert(#calls.ClearedConflicts == 4, "every deleted page should drop its pending sync conflict")
assert(
    calls.ClearDisplayed == 1 and calls.UpdateDisplayed == 1 and calls.UpdateTree == 1 and calls.RefreshDisplayed == 0,
    "deleting the displayed page should clear and refresh the UI exactly once"
)
assert(
    calls.ClearSharedDraft == 1 and calls.UpdateSelected == 1 and calls.LastUpdateSelectedDestructive == true,
    "deleting the displayed and selected page should discard its editor draft once"
)
assert(calls.LastUpdateSelectedPreservedDraft == true, "the selection reset should not clear another page's draft")
assert(AngryAssign_State.displayed == nil and AngryAssign_State.tree.selected == nil)
assert(AngryAssign_State.tree.groups[-1] == true, "retained category expansion state should survive")
assert(AngryAssign_State.tree.groups["-1\001-2"] == true, "retained expansion paths should survive")
assert(AngryAssign_State.tree.groups.untouched == true, "unrelated tree state should survive")
assert(AngryAssign_State.tree.groups[-4] == nil and AngryAssign_State.tree.groups[-5] == nil)
assert(AngryAssign_State.tree.groups[-6] == nil, "deleted root expansion state should be removed")
assert(
    AngryAssign_State.tree.groups["-4\001-5"] == nil and AngryAssign_State.tree.groups["-6\001-7"] == nil,
    "every expansion path containing a deleted category should be removed"
)

local callsBeforeNoop = {
    clear = calls.ClearDisplayed,
    refresh = calls.RefreshDisplayed,
    selected = calls.UpdateSelected,
    tree = calls.UpdateTree,
}
removedPages, removedCategories, wipeError = AngryEra:WipeUnpinned()
assert(removedPages == 0 and removedCategories == 0 and not wipeError, "a completed wipe should be idempotent")
assert(
    calls.ClearDisplayed == callsBeforeNoop.clear
        and calls.RefreshDisplayed == callsBeforeNoop.refresh
        and calls.UpdateSelected == callsBeforeNoop.selected
        and calls.UpdateTree == callsBeforeNoop.tree,
    "an empty wipe should not refresh or mutate UI state"
)

-- If the active page survives, hierarchy mutation gets exactly one tree refresh
-- and one active-page republish rather than a display clear.
local retainedDisplay = Page(201)
local disposableSibling = Page(202)
SetLibrary({}, {
    [201] = retainedDisplay,
    [202] = disposableSibling,
}, {
    displayed = 201,
    tree = {
        selected = 201,
        groups = {},
    },
})
pinned[retainedDisplay] = true
removedPages, removedCategories, wipeError = AngryEra:WipeUnpinned()
assert(removedPages == 1 and removedCategories == 0 and not wipeError)
assert(AngryAssign_Pages[201] == retainedDisplay and AngryAssign_Pages[202] == nil)
assert(
    calls.ClearDisplayed == 0 and calls.UpdateTree == 1 and calls.RefreshDisplayed == 1,
    "a retained displayed page should be republished once after the batched wipe"
)
assert(calls.UpdateSelected == 0 and AngryAssign_State.tree.selected == 201, "a retained selection should survive")

-- Rehoming a retained selection rewrites its saved tree path without firing
-- the destructive selection callback that discards editor drafts.
local disposableParent = Category(251)
local retainedSelection = Page(252, 251)
SetLibrary({ [251] = disposableParent }, { [252] = retainedSelection }, {
    displayed = nil,
    tree = {
        selected = "-251\001252",
        groups = {},
    },
})
pinned[retainedSelection] = true
removedPages, removedCategories, wipeError = AngryEra:WipeUnpinned()
assert(removedPages == 0 and removedCategories == 1 and not wipeError)
assert(AngryAssign_Pages[252] == retainedSelection and retainedSelection.CategoryId == nil)
assert(AngryAssign_State.tree.selected == 252, "a rehomed root page should keep a valid saved selection")
assert(calls.UpdateSelected == 0, "retaining a selected page should not discard its draft")

-- A post-commit display failure must not misreport the completed local delete
-- as a rollback or as an unqualified success.
local failedClearPage = Page(261)
SetLibrary({}, { [261] = failedClearPage }, {
    displayed = 261,
    tree = {
        selected = 261,
        groups = {},
    },
})
clearDisplayedError = "transport-failed"
local postCommitWarning
removedPages, removedCategories, wipeError, postCommitWarning = AngryEra:WipeUnpinned()
assert(removedPages == 1 and removedCategories == 0 and not wipeError)
assert(not AngryAssign_Pages[261], "a display warning occurs after the confirmed local wipe commits")
assert(postCommitWarning == "shared-display-update-failed", "the caller should receive the sync warning")

local failedRefreshPage = Page(271)
local failedRefreshSibling = Page(272)
SetLibrary({}, {
    [271] = failedRefreshPage,
    [272] = failedRefreshSibling,
}, {
    displayed = 271,
    tree = {
        selected = 271,
        groups = {},
    },
})
pinned[failedRefreshPage] = true
refreshDisplayedError = "transport-failed"
removedPages, removedCategories, wipeError, postCommitWarning = AngryEra:WipeUnpinned()
assert(removedPages == 1 and removedCategories == 0 and not wipeError)
assert(AngryAssign_Pages[271] == failedRefreshPage and not AngryAssign_Pages[272])
assert(postCommitWarning == "shared-display-update-failed", "a leader should be warned when refresh fails")

-- A confirmation snapshot is an exact destructive boundary. New candidates
-- arriving before acceptance must abort rather than being swept in silently.
local stalePage = Page(301)
SetLibrary({}, { [301] = stalePage })
local stalePlan = assert(AngryEra:PrepareUnpinnedWipe())
local latePage = Page(302)
AngryAssign_Pages[302] = latePage
removedPages, removedCategories, wipeError = AngryEra:WipeUnpinned(stalePlan)
assert(
    removedPages == nil and removedCategories == nil and wipeError == "library-changed",
    "a stale confirmation should abort"
)
assert(AngryAssign_Pages[301] == stalePage and AngryAssign_Pages[302] == latePage, "stale plans must not mutate")
assert(#calls.RemovedPages == 0 and calls.UpdateTree == 0, "a stale plan should fail before any side effect")

-- Missing links and cycles are both unsafe. The planner must reject the whole
-- operation, leaving even otherwise disposable records untouched.
local missingParent = Category(401, 999)
local malformedPage = Page(402)
SetLibrary({ [401] = missingParent }, { [402] = malformedPage })
plan, planError = AngryEra:PrepareUnpinnedWipe()
assert(not plan and planError == "unsafe-hierarchy-missing-category", "a missing category parent should fail closed")
removedPages, removedCategories, wipeError = AngryEra:WipeUnpinned()
assert(not removedPages and not removedCategories and wipeError == planError)
assert(AngryAssign_Categories[401] == missingParent and AngryAssign_Pages[402] == malformedPage)
assert(#calls.RemovedPages == 0 and #calls.RemovedCategories == 0 and calls.UpdateTree == 0)

local cycleA = Category(501, 502)
local cycleB = Category(502, 501)
local cyclePage = Page(503, 501)
SetLibrary({
    [501] = cycleA,
    [502] = cycleB,
}, {
    [503] = cyclePage,
})
plan, planError = AngryEra:PrepareUnpinnedWipe()
assert(not plan and planError == "unsafe-hierarchy-cycle", "a category cycle should fail closed")
removedPages, removedCategories, wipeError = AngryEra:WipeUnpinned()
assert(not removedPages and not removedCategories and wipeError == planError)
assert(AngryAssign_Categories[501] == cycleA and AngryAssign_Categories[502] == cycleB)
assert(AngryAssign_Pages[503] == cyclePage and calls.UpdateTree == 0)

SetLibrary({}, { [601] = Page(601, 999) })
plan, planError = AngryEra:PrepareUnpinnedWipe()
assert(not plan and planError == "unsafe-hierarchy-missing-category", "a page with a missing parent should fail closed")
assert(AngryAssign_Pages[601], "invalid page hierarchy should remain untouched")

-- Load the editor last so the same menu wiring players use can be exercised
-- without constructing any AceGUI windows.
AngryEra.utils.helpers.CompareIndexedEntries = function(left, right)
    return (left.Name or "") < (right.Name or "")
end
AngryEra.utils.helpers.EnsureUnitShortName = function(name)
    return name
end
AngryEra.utils.helpers.IterateGroupMembers = function() end
AngryEra.utils.colors = {}
AngryEra.utils.layout = {}
AngryEra.utils.roster = {}

app.libs.AceGUI = setmetatable({}, {
    __index = function()
        return function() end
    end,
})
app.libs.DDM = app.libs.AceGUI

StaticPopupDialogs = {}
rawset(_G, "CANCEL", "Cancel")
local shownPopup
local function CaptureStaticPopup(name, textArg1, textArg2, data)
    shownPopup = {
        Name = name,
        TextArg1 = textArg1,
        TextArg2 = textArg2,
        Data = data,
    }
end
rawset(_G, "StaticPopup_Show", CaptureStaticPopup)

local printed = {}
function AngryEra:Print(message)
    printed[#printed + 1] = message
end

assert(loadfile("modules/ui/editor.lua"))("AngryEra", app)

-- The editor defines its production UI refresh methods while loading. Restore
-- the instrumented, window-free versions used by this focused harness.
function AngryEra:UpdateTree()
    calls.UpdateTree = calls.UpdateTree + 1
end
function AngryEra:RefreshDisplayedPageAfterHierarchyMutation()
    calls.RefreshDisplayed = calls.RefreshDisplayed + 1
    return true
end
function AngryEra:UpdateSelected(destructive, preserveSharedDraft)
    calls.UpdateSelected = calls.UpdateSelected + 1
    calls.LastUpdateSelectedDestructive = destructive
    calls.LastUpdateSelectedPreservedDraft = preserveSharedDraft
end

local menu = AngryEra.utils.layout_editor.MainMenuEntries()
local menuIndexes = {}
local wipeEntry
for index, entry in ipairs(menu) do
    menuIndexes[entry.text] = index
    if entry.text == "Wipe Unpinned" then
        wipeEntry = entry
    end
end
assert(wipeEntry and wipeEntry.notCheckable == true, "the main menu should expose Wipe Unpinned")
assert(
    menuIndexes["Manage Pages"] + 1 == menuIndexes["Wipe Unpinned"]
        and menuIndexes["Wipe Unpinned"] + 1 == menuIndexes["Clear Page"],
    "Wipe Unpinned should sit between Manage Pages and Clear Page"
)

local menuCategory = Category(701)
local menuPage = Page(702, 701)
SetLibrary({ [701] = menuCategory }, { [702] = menuPage })
shownPopup = nil
wipeEntry.func()
assert(shownPopup and shownPopup.Name == "AngryEra_WipeUnpinned", "the menu action should require confirmation")
local popup = StaticPopupDialogs.AngryEra_WipeUnpinned
assert(
    popup
        and popup.button1 == "Wipe Unpinned"
        and popup.button2 == "Cancel"
        and popup.hideOnEscape == true
        and popup.preferredIndex == 3,
    "the wipe should use a focused destructive confirmation"
)
assert(shownPopup.Data.PageCount == 1 and shownPopup.Data.CategoryCount == 1, "the popup should retain exact counts")
assert(popup.text:find("Permanently wipe", 1, true), "the popup should identify the permanent action")
assert(popup.text:find("1 category", 1, true) and popup.text:find("1 page", 1, true))
assert(
    popup.text:find("Pinned pages and everything inside pinned categories will be kept.", 1, true),
    "the popup should explain the pin boundary"
)
assert(popup.text:find("This cannot be undone.", 1, true), "the popup should state that deletion is irreversible")

popup.OnAccept({ data = shownPopup.Data })
assert(not AngryAssign_Categories[701] and not AngryAssign_Pages[702], "accepting should execute the confirmed wipe")
assert(printed[#printed] == "Wiped 1 category and 1 page.", "completion should report both removed counts")

shownPopup = nil
wipeEntry.func()
assert(not shownPopup, "an empty wipe should not open a confirmation")
assert(printed[#printed] == "No unpinned pages or categories to wipe.", "an empty wipe should explain the no-op")

local menuWarningPage = Page(751)
SetLibrary({}, { [751] = menuWarningPage }, {
    displayed = 751,
    tree = {
        selected = 751,
        groups = {},
    },
})
clearDisplayedError = "transport-failed"
shownPopup = nil
wipeEntry.func()
assert(shownPopup, "a displayed candidate should produce a confirmation")
popup.OnAccept({ data = shownPopup.Data })
assert(not AngryAssign_Pages[751], "a failed display publish should not roll back the local wipe")
assert(
    printed[#printed]:find("local wipe completed", 1, true) and printed[#printed]:find("Display a page again", 1, true),
    "a post-commit sync failure should explain how to retry"
)

local menuStalePage = Page(801)
SetLibrary({}, { [801] = menuStalePage })
shownPopup = nil
wipeEntry.func()
assert(shownPopup, "a candidate should produce a prepared confirmation")
local menuLatePage = Page(802)
AngryAssign_Pages[802] = menuLatePage
popup.OnAccept({ data = shownPopup.Data })
assert(
    AngryAssign_Pages[801] == menuStalePage and AngryAssign_Pages[802] == menuLatePage,
    "menu confirmation must not expand to newly arrived candidates"
)
assert(
    printed[#printed]:find("changed while confirmation was open", 1, true),
    "a stale popup should tell the player to review the wipe again"
)

assert(not Contains(calls.RemovedPages, 801) and not Contains(calls.RemovedPages, 802))

print("Unpinned wipe tests passed.")
