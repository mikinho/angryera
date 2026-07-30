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
local canPublishPageUpsert = false
local displaySendOk = true
local displaySendResult
local displayActivatedLocally = true
local showDisplayCalls = 0
local displayNotificationCalls = 0
local printedMessages = {}
local autoAdvanceRetryCancellations = 0
local operationLog = {}
local updateSelectedCalls = 0
local lastUpdateSelectedDestructive
local activeDisplayReference
local submittedSharedPageProposals = {}
local sharedProposalSubmitOk = true
local sharedProposalSubmitResult = "change-proposal-message"
local grouped = true

_G.RED_FONT_COLOR_CODE = "<red>"
_G.IsInRaid = function()
    return grouped
end
_G.IsInGroup = function()
    return grouped
end

function AngryEra:UpdateTree()
    updateTreeCalls = updateTreeCalls + 1
end

function AngryEra:UpdateSelected(destructive)
    updateSelectedCalls = updateSelectedCalls + 1
    lastUpdateSelectedDestructive = destructive
end

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
    if action == "display" then
        return canPublishDisplay
    end
    return action == "pageUpsert" and canPublishPageUpsert
end

function AngryEra:CanEditEntityLocally()
    return true
end

function AngryEra:IsLocallyOwned(entity)
    return entity.LocallyOwned ~= false
end

function AngryEra:GetActiveDisplayReference()
    return activeDisplayReference
end

function AngryEra:SubmitSharedPageChangeProposal(proposal)
    submittedSharedPageProposals[#submittedSharedPageProposals + 1] = proposal
    return sharedProposalSubmitOk, sharedProposalSubmitResult
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

-- A synchronized page owned by this installation remains directly editable
-- while solo, even when it is still the visible page with an exact display
-- reference. This is a local testing/debug state, not a shared proposal.
local soloPage = {
    Id = 59,
    SyncId = "ae3i:5:6:7:8:page:59",
    OwnerId = "ae3i:5:6:7:8",
    LocallyOwned = true,
    Revision = 3,
    RevisionId = "fcs32:59595959",
    Name = "Solo assignments",
    Vars = "$MT=Player",
    Contents = "Tank: Player",
    Backup = "Tank: Player",
    Updated = 100,
    UpdateId = "solo-update-id",
}
AngryAssign_Pages[59] = soloPage
AngryAssign_State.displayed = 59
activeDisplayReference = {
    SyncId = soloPage.SyncId,
    Revision = soloPage.Revision,
    RevisionId = soloPage.RevisionId,
    ContextRevisionId = "fcs32:59595950",
}
grouped = false
canPublishDisplay = true
canPublishPageUpsert = true
local proposalsBeforeSoloSave = #submittedSharedPageProposals
local displaysBeforeSoloSave = #sentDisplays
local showsBeforeSoloSave = showDisplayCalls
local notificationsBeforeSoloSave = displayNotificationCalls
sentPageId = nil
local soloSaved, soloSaveResult, soloProposed = AngryEra:UpdateContents(59, "  Tank: Updated  ")
assert(soloSaved and soloSaveResult == nil and not soloProposed, "solo displayed-page Save should remain a local edit")
assert(soloPage.Contents == "Tank: Updated", "solo displayed-page Save should update local storage")
assert(
    soloPage.Backup == "Tank: Updated"
        and soloPage.History
        and soloPage.History[1]
        and soloPage.History[1].content == "Tank: Player",
    "solo displayed-page Save should retain normal backup and history behavior"
)
assert(
    #submittedSharedPageProposals == proposalsBeforeSoloSave,
    "solo displayed-page Save must not enter shared proposal routing"
)
assert(
    #sentDisplays == displaysBeforeSoloSave + 1 and sentDisplays[#sentDisplays].Id == 59 and sentPageId == nil,
    "solo displayed-page Save should refresh the exact local display without a page-only publication"
)

local soloRenamed, soloRenameError, soloRenameProposed = AngryEra:RenamePage(59, "Solo assignments revised")
assert(
    soloRenamed and soloRenameError == nil and not soloRenameProposed and soloPage.Name == "Solo assignments revised",
    "solo displayed-page rename should remain a direct local edit"
)
local soloVarsSaved, soloVarsError, soloVarsProposed = AngryEra:UpdatePageVars(59, "$MT=Updated")
assert(
    soloVarsSaved and soloVarsError == nil and not soloVarsProposed and soloPage.Vars == "$MT=Updated",
    "solo displayed-page variable Save should remain a direct local edit"
)
assert(
    #submittedSharedPageProposals == proposalsBeforeSoloSave and #sentDisplays == displaysBeforeSoloSave + 3,
    "every solo displayed-page field edit should bypass proposal routing and refresh locally"
)

soloPage.LocallyOwned = false
local remoteContentsBeforeSoloEdit = soloPage.Contents
local proposalsBeforeSoloRemoteEdit = #submittedSharedPageProposals
sharedProposalSubmitOk = false
sharedProposalSubmitResult = "unauthorized"
soloSaved, soloSaveResult, soloProposed = AngryEra:UpdateContents(59, "Remote cached edit")
assert(
    not soloSaved and soloSaveResult == "unauthorized" and soloProposed,
    "solo authority fallback must not grant direct editing of a displayed remote-owned page"
)
assert(
    soloPage.Contents == remoteContentsBeforeSoloEdit
        and #submittedSharedPageProposals == proposalsBeforeSoloRemoteEdit + 1
        and #sentDisplays == displaysBeforeSoloSave + 3,
    "a rejected solo remote-page edit must preserve storage and publication state"
)
sharedProposalSubmitOk = true
sharedProposalSubmitResult = "change-proposal-message"
table.remove(submittedSharedPageProposals)
AngryAssign_Pages[59] = nil
AngryAssign_State.displayed = 42
activeDisplayReference = nil
grouped = true
canPublishDisplay = false
canPublishPageUpsert = false
showDisplayCalls = showsBeforeSoloSave
displayNotificationCalls = notificationsBeforeSoloSave

sentPageId = nil
local showsBeforeAssistantRename = showDisplayCalls
local renamed, renameError = AngryEra:RenamePage(42, "Assistant rename")
assert(renamed and not renameError, "assistant rename should remain a valid page edit")
assert(sentPageId == 42, "assistant rename should publish the active page without selecting it")
assert(showDisplayCalls == showsBeforeAssistantRename, "assistant rename must not reopen an unchanged leader display")

local sharedPage = {
    Id = 60,
    SyncId = "ae3i:5:6:7:8:page:60",
    OwnerId = "ae3i:5:6:7:8",
    LocallyOwned = false,
    Revision = 7,
    RevisionId = "fcs32:60606060",
    Name = "Shared assignments",
    Vars = "$MT=Leader",
    Contents = "Tank: Leader",
    Backup = "Tank: Leader",
    Updated = 100,
    UpdateId = "shared-update-id",
}
AngryAssign_Pages[60] = sharedPage
AngryAssign_State.displayed = 60
activeDisplayReference = {
    SyncId = sharedPage.SyncId,
    Revision = sharedPage.Revision,
    RevisionId = sharedPage.RevisionId,
    ContextRevisionId = "fcs32:70707070",
}
sentPageId = nil
local selectedUpdatesBeforeSharedProposal = updateSelectedCalls
local treeUpdatesBeforeSharedProposal = updateTreeCalls
local displayUpdatesBeforeSharedProposal = updateDisplayCalls
local historyBeforeSharedProposal = sharedPage.History
local updatedBeforeSharedProposal = sharedPage.Updated
local updateIdBeforeSharedProposal = sharedPage.UpdateId
local saved, saveResult, proposed = AngryEra:UpdateContents(60, "  Tank: Assistant  ")
assert(saved and saveResult == "change-proposal-message" and proposed, "shared content should submit a proposal")
assert(#submittedSharedPageProposals == 1, "shared content should submit exactly one desired-state proposal")
local contentProposal = submittedSharedPageProposals[1]
assert(
    contentProposal.LocalId == 60
        and contentProposal.SyncId == sharedPage.SyncId
        and contentProposal.BaseRevision == 7
        and contentProposal.BaseRevisionId == sharedPage.RevisionId
        and contentProposal.BaseContextRevisionId == activeDisplayReference.ContextRevisionId
        and contentProposal.ChangedField == "Contents",
    "the shared proposal should bind the exact active page tuple and numeric base"
)
assert(
    contentProposal.Desired.Name == "Shared assignments"
        and contentProposal.Desired.Vars == "$MT=Leader"
        and contentProposal.Desired.Contents == "Tank: Assistant",
    "content proposals should carry the complete normalized desired page state"
)
assert(
    sharedPage.Name == "Shared assignments"
        and sharedPage.Vars == "$MT=Leader"
        and sharedPage.Contents == "Tank: Leader"
        and sharedPage.Backup == "Tank: Leader"
        and sharedPage.History == historyBeforeSharedProposal
        and sharedPage.Updated == updatedBeforeSharedProposal
        and sharedPage.UpdateId == updateIdBeforeSharedProposal,
    "proposal submission must leave the canonical shared page and its history metadata unchanged"
)
assert(sentPageId == nil, "the model proposal path must not publish a direct PAGE_UPSERT")
assert(
    updateSelectedCalls == selectedUpdatesBeforeSharedProposal
        and updateTreeCalls == treeUpdatesBeforeSharedProposal
        and updateDisplayCalls == displayUpdatesBeforeSharedProposal,
    "proposal submission must preserve the editor draft without destructive refresh or redraw"
)

renamed, renameError, proposed = AngryEra:RenamePage(60, "Shared assignments revised")
assert(renamed and renameError == "change-proposal-message" and proposed, "shared rename should submit a proposal")
local renameProposal = submittedSharedPageProposals[2]
assert(
    renameProposal.ChangedField == "Name"
        and renameProposal.Desired.Name == "Shared assignments revised"
        and renameProposal.Desired.Vars == "$MT=Leader"
        and renameProposal.Desired.Contents == "Tank: Assistant",
    "a later shared rename should merge with the retained content draft"
)
assert(sharedPage.Name == "Shared assignments", "shared rename must wait for the leader's canonical commit")

saved, saveResult, proposed = AngryEra:UpdatePageVars(60, "$MT=Assistant")
assert(saved and saveResult == "change-proposal-message" and proposed, "shared vars should submit a proposal")
local varsProposal = submittedSharedPageProposals[3]
assert(
    varsProposal.ChangedField == "Vars"
        and varsProposal.Desired.Name == "Shared assignments revised"
        and varsProposal.Desired.Vars == "$MT=Assistant"
        and varsProposal.Desired.Contents == "Tank: Assistant",
    "shared variable saves should merge every retained editor draft field"
)
assert(sharedPage.Vars == "$MT=Leader", "shared vars must remain canonical until the leader commits")
local retainedSharedDraft = AngryEra:GetSharedPageChangeDraft(60)
assert(
    retainedSharedDraft
        and retainedSharedDraft.Desired.Name == "Shared assignments revised"
        and retainedSharedDraft.Desired.Vars == "$MT=Assistant"
        and retainedSharedDraft.Desired.Contents == "Tank: Assistant",
    "the editor should be able to reopen the complete tuple-bound shared draft"
)
retainedSharedDraft.Desired.Contents = "caller mutation"
assert(
    AngryEra:GetSharedPageChangeDraft(60).Desired.Contents == "Tank: Assistant",
    "shared editor drafts should be returned as detached values"
)
canPublishPageUpsert = true
assert(
    AngryEra:GetSharedPageChangeDraft(60).Desired.Contents == "Tank: Assistant",
    "an exact tuple-bound draft should remain visible after promotion to leader"
)
canPublishPageUpsert = false
renamed, renameError, proposed = AngryEra:RenamePage(60, "Shared assignments")
assert(
    renamed and renameError == "change-proposal-message" and proposed,
    "renaming a shared draft back to its canonical name should still submit the desired revert"
)
assert(
    submittedSharedPageProposals[4].Desired.Name == "Shared assignments"
        and submittedSharedPageProposals[4].Desired.Vars == "$MT=Assistant"
        and submittedSharedPageProposals[4].Desired.Contents == "Tank: Assistant",
    "a shared rename revert should retain the other unsaved desired fields"
)

sharedProposalSubmitOk = false
sharedProposalSubmitResult = "change-proposal-send-failed"
saved, saveResult, proposed = AngryEra:UpdateContents(60, "Unsent assistant draft")
assert(
    not saved and saveResult == "change-proposal-send-failed" and proposed,
    "a failed shared proposal should report failure without falling through to direct mutation"
)
assert(
    sharedPage.Contents == "Tank: Leader" and updateSelectedCalls == selectedUpdatesBeforeSharedProposal,
    "a failed proposal should retain both canonical state and the editor draft"
)
sharedProposalSubmitOk = true
sharedProposalSubmitResult = "change-proposal-message"

activeDisplayReference.RevisionId = "fcs32:71717171"
local proposalsBeforeMismatchedDisplay = #submittedSharedPageProposals
assert(
    AngryEra:GetSharedPageChangeDraft(60) == nil,
    "a changed active tuple should immediately hide the stale shared editor draft"
)
saved, saveResult, proposed = AngryEra:UpdateContents(60, "Unsafe stale edit")
assert(
    not saved and saveResult == "shared-page-display-reference-mismatch" and proposed,
    "a stale displayed remote page should fail closed instead of bypassing the proposal path"
)
assert(
    #submittedSharedPageProposals == proposalsBeforeMismatchedDisplay and sharedPage.Contents == "Tank: Leader",
    "a mismatched displayed tuple must neither submit nor mutate"
)

sharedPage.Revision = 8
sharedPage.RevisionId = "fcs32:71717171"
sharedPage.Name = "Leader winning assignments"
sharedPage.Vars = "$MT=WinningLeader"
sharedPage.Contents = "Tank: Winning Leader"
activeDisplayReference = {
    SyncId = sharedPage.SyncId,
    Revision = sharedPage.Revision,
    RevisionId = sharedPage.RevisionId,
    ContextRevisionId = "fcs32:72727272",
}
AngryEra.syncDraftConflict = {
    SyncId = "ae3i:other:page",
    Desired = {
        Name = "Other page",
        Vars = "$MT=Other",
        Contents = "Other contents",
    },
}
assert(
    AngryEra:GetSharedPageChangeDraft(60) == nil,
    "a conflict from another SyncId must never leak into the selected page"
)
AngryEra.syncDraftConflict = {
    SyncId = sharedPage.SyncId,
    LocalId = sharedPage.Id,
    Status = "conflict",
    Reason = "stale-change-base",
    Desired = {
        Name = "Shared assignments",
        Vars = "$MT=Assistant",
        Contents = "Unsent assistant draft",
    },
}
local recoveredConflictDraft = AngryEra:GetSharedPageChangeDraft(60)
assert(
    recoveredConflictDraft
        and recoveredConflictDraft.BaseRevision == 8
        and recoveredConflictDraft.BaseRevisionId == sharedPage.RevisionId
        and recoveredConflictDraft.BaseContextRevisionId == activeDisplayReference.ContextRevisionId,
    "a losing assistant draft should rebind its proposal metadata to the advanced exact active tuple"
)
assert(
    recoveredConflictDraft.Desired.Name == "Shared assignments"
        and recoveredConflictDraft.Desired.Vars == "$MT=Assistant"
        and recoveredConflictDraft.Desired.Contents == "Unsent assistant draft",
    "a same-page conflict should keep the complete unsaved desired state visible"
)
recoveredConflictDraft.Desired.Vars = "caller mutation"
assert(
    AngryEra:GetSharedPageChangeDraft(60).Desired.Vars == "$MT=Assistant",
    "a recovered conflict draft should remain detached from shared conflict state"
)

local selectedUpdatesBeforeConflictRetry = updateSelectedCalls
renamed, renameError, proposed = AngryEra:RenamePage(60, "Recovered assistant assignments")
assert(
    renamed and renameError == "change-proposal-message" and proposed,
    "editing a recovered conflict should submit against the current exact tuple"
)
local recoveredProposal = submittedSharedPageProposals[#submittedSharedPageProposals]
assert(
    recoveredProposal.BaseRevision == 8
        and recoveredProposal.BaseRevisionId == sharedPage.RevisionId
        and recoveredProposal.BaseContextRevisionId == activeDisplayReference.ContextRevisionId
        and recoveredProposal.Desired.Name == "Recovered assistant assignments"
        and recoveredProposal.Desired.Vars == "$MT=Assistant"
        and recoveredProposal.Desired.Contents == "Unsent assistant draft",
    "a recovered field edit should merge with every retained desired field on the new base"
)
assert(
    AngryEra.syncDraftConflict
        and AngryEra.syncDraftConflict.SyncId == sharedPage.SyncId
        and updateSelectedCalls == selectedUpdatesBeforeConflictRetry,
    "retrying a recovered draft must preserve post-send dirty editor semantics"
)
assert(
    AngryEra:GetSharedPageChangeDraft(60).Desired.Name == "Recovered assistant assignments",
    "the newly submitted tuple-bound draft should take precedence over its older conflict fallback"
)
AngryEra.syncDraftConflict = nil
assert(AngryEra:ClearSharedPageChangeDraft(), "an explicit editor revert should clear a retained shared draft")
assert(not AngryEra:ClearSharedPageChangeDraft(), "shared draft clearing should be idempotent")
sharedPage.Revision = 7
sharedPage.RevisionId = "fcs32:60606060"
sharedPage.Name = "Shared assignments"
sharedPage.Vars = "$MT=Leader"
sharedPage.Contents = "Tank: Leader"

AngryAssign_State.displayed = nil
sentPageId = nil
saved, saveResult, proposed = AngryEra:UpdateContents(60, "Background remote edit")
assert(
    not saved and saveResult == "shared-page-not-active" and proposed,
    "a cached background remote page should fail closed"
)
assert(sharedPage.Contents == "Tank: Leader", "a background remote edit must not mutate canonical storage")
assert(sentPageId == nil, "a background remote edit must not publish a direct PAGE_UPSERT")

sentPageId = nil
saved, saveResult, proposed = AngryEra:UpdatePageVars(60, "$MT=Background")
assert(
    not saved and saveResult == "shared-page-not-active" and proposed,
    "background remote variables should fail closed"
)
assert(sharedPage.Vars == "$MT=Leader", "background remote variables must not mutate canonical storage")
assert(sentPageId == nil, "background remote variables must not call PageUpdated")

renamed, renameError, proposed = AngryEra:RenamePage(60, "Background remote rename")
assert(
    not renamed and renameError == "shared-page-not-active" and proposed,
    "background remote renames should fail closed"
)
assert(sharedPage.Name == "Shared assignments", "background remote rename must preserve canonical storage")

canPublishPageUpsert = true
sentPageId = nil
saved, saveResult, proposed = AngryEra:UpdateContents(60, "Leader background canonical edit")
assert(
    saved and saveResult == nil and not proposed,
    "the canonical leader should retain background remote-page editing"
)
assert(sharedPage.Contents == "Leader background canonical edit", "leader background edit should mutate canonically")
assert(sentPageId == 60, "leader background edits should publish through PAGE_UPSERT")

grouped = false
sentPageId = nil
saved, saveResult, proposed = AngryEra:UpdateContents(60, "Solo background remote edit")
assert(
    not saved and saveResult == "shared-page-not-active" and proposed,
    "solo publish fallback must not grant canonical authority over a cached remote page"
)
assert(
    sharedPage.Contents == "Leader background canonical edit",
    "a solo background remote edit must preserve canonical storage"
)
assert(sentPageId == nil, "a solo background remote edit must not publish PAGE_UPSERT")
grouped = true
canPublishPageUpsert = false

AngryAssign_State.displayed = 60
activeDisplayReference = {
    SyncId = sharedPage.SyncId,
    Revision = sharedPage.Revision,
    RevisionId = sharedPage.RevisionId,
    ContextRevisionId = "fcs32:70707070",
}
saved, saveResult, proposed = AngryEra:UpdateContents(60, "Promoted draft contents")
assert(saved and saveResult == "change-proposal-message" and proposed, "the pre-promotion content draft should submit")
renamed, renameError, proposed = AngryEra:RenamePage(60, "Promoted draft name")
assert(renamed and renameError == "change-proposal-message" and proposed, "the pre-promotion name draft should merge")
saved, saveResult, proposed = AngryEra:UpdatePageVars(60, "$MT=PromotedDraft")
assert(saved and saveResult == "change-proposal-message" and proposed, "the pre-promotion variable draft should merge")
AngryEra.syncDraftConflict = {
    SyncId = sharedPage.SyncId,
    Status = "conflict",
    Desired = {
        Name = "Promoted draft name",
        Vars = "$MT=PromotedDraft",
        Contents = "Promoted draft contents",
    },
}
canPublishDisplay = true
canPublishPageUpsert = true
local activationBeforeLeaderRemoteEdit = displayActivatedLocally
displayActivatedLocally = false
local selectedUpdatesBeforePromotedSave = updateSelectedCalls
saved, saveResult, proposed = AngryEra:UpdateContents(60, "Promoted draft contents")
assert(saved and saveResult == nil and not proposed, "a promoted leader should save content directly")
assert(
    sharedPage.Contents == "Promoted draft contents"
        and sharedPage.Name == "Shared assignments"
        and sharedPage.Vars == "$MT=Leader",
    "a partial promoted-leader save should mutate only the selected canonical field"
)
local promotedDraftAfterContent = AngryEra:GetSharedPageChangeDraft(60)
assert(
    promotedDraftAfterContent
        and promotedDraftAfterContent.Desired.Name == "Promoted draft name"
        and promotedDraftAfterContent.Desired.Vars == "$MT=PromotedDraft"
        and promotedDraftAfterContent.Desired.Contents == "Promoted draft contents",
    "a promoted content save must retain the assistant's unsaved name and variable fields"
)
assert(
    updateSelectedCalls == selectedUpdatesBeforePromotedSave + 1 and lastUpdateSelectedDestructive == false,
    "content refresh must remain non-destructive while promoted desired fields are still pending"
)
assert(
    AngryEra.syncDraftConflict and AngryEra.syncDraftConflict.SyncId == sharedPage.SyncId,
    "a partial promoted-leader save must preserve the same-page dirty conflict"
)

renamed, renameError, proposed = AngryEra:RenamePage(60, "Promoted draft name")
assert(renamed and renameError == nil and not proposed, "the promoted leader should save the retained name directly")
local promotedDraftAfterName = AngryEra:GetSharedPageChangeDraft(60)
assert(
    promotedDraftAfterName
        and promotedDraftAfterName.Desired.Vars == "$MT=PromotedDraft"
        and sharedPage.Name == "Promoted draft name"
        and sharedPage.Vars == "$MT=Leader",
    "saving the retained name must keep the remaining variable draft"
)

saved, saveResult, proposed = AngryEra:UpdatePageVars(60, "$MT=PromotedDraft")
assert(saved and saveResult == nil and not proposed, "the promoted leader should save retained variables directly")
assert(
    AngryEra:GetSharedPageChangeDraft(60) == nil and AngryEra.syncDraftConflict == nil,
    "the retained draft should clear only after all canonical fields equal its desired state"
)

local proposalsBeforeLeaderRemoteEdit = #submittedSharedPageProposals
local displaysBeforeLeaderRemoteEdit = #sentDisplays
saved, saveResult, proposed = AngryEra:UpdateContents(60, "Leader canonical edit")
assert(
    saved and saveResult == nil and not proposed,
    "a leader editing a displayed remote-owned page should retain the direct canonical path"
)
assert(sharedPage.Contents == "Leader canonical edit", "leader edits should mutate canonical page storage directly")
assert(
    #submittedSharedPageProposals == proposalsBeforeLeaderRemoteEdit,
    "a canonical page publisher must not submit a proposal to itself"
)
assert(
    #sentDisplays == displaysBeforeLeaderRemoteEdit + 1 and sentDisplays[#sentDisplays].Id == 60,
    "a leader remote-page edit should publish its exact canonical display tuple"
)
canPublishPageUpsert = false
canPublishDisplay = false
displayActivatedLocally = activationBeforeLeaderRemoteEdit

activeDisplayReference = nil
AngryAssign_Pages[60] = nil

page.Id = 42
page.SyncId = "ae3i:1:2:3:4:page:42"
page.LocallyOwned = true
page.Revision = 3
page.RevisionId = "fcs32:42424242"
AngryAssign_State.displayed = 42
activeDisplayReference = {
    SyncId = page.SyncId,
    Revision = page.Revision,
    RevisionId = page.RevisionId,
    ContextRevisionId = "fcs32:43434343",
}
local proposalsBeforeLocalOwnedEdit = #submittedSharedPageProposals
local localOwnerContentsBeforeEdit = page.Contents
sentPageId = nil
saved, saveResult, proposed = AngryEra:UpdateContents(42, "Local owner edit")
assert(
    saved and saveResult == "change-proposal-message" and proposed,
    "a displayed locally owned page should still use leader-canonical editing"
)
assert(page.Contents == localOwnerContentsBeforeEdit, "local-owner proposals must not mutate canonical storage")
assert(sentPageId == nil, "a local-owner assistant must not broadcast a direct PAGE_UPSERT")
assert(
    #submittedSharedPageProposals == proposalsBeforeLocalOwnedEdit + 1
        and submittedSharedPageProposals[#submittedSharedPageProposals].SyncId == page.SyncId,
    "local-owner proposals should bind the same exact displayed tuple"
)
page.SyncId = nil
page.LocallyOwned = nil
page.Revision = nil
page.RevisionId = nil
activeDisplayReference = nil

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
function AngryEra:IsPinned(candidate)
    return candidate.Id == 51
end
AngryAssign_State.displayed = 50
local sendsBeforeNextPage = #sentDisplays
AngryEra:NextPage()
assert(
    AngryAssign_State.displayed == 51,
    "NextPage should follow manual order even when the destination is pinned locally"
)
assert(
    #sentDisplays == sendsBeforeNextPage + 1
        and sentDisplays[#sentDisplays].Id == 51
        and sentDisplays[#sentDisplays].Force == false,
    "NextPage should use non-forced publication"
)

local sendsBeforePrevPage = #sentDisplays
AngryEra:PrevPage()
assert(AngryAssign_State.displayed == 50, "PrevPage should follow manual order even when the source is pinned locally")
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

local initialVars = "MT=Roselea\n$LAYOUT=Tanks/1: {{MT}}"
created, createError, createdId = AngryEra:CreatePage("Templated Sibling", "Assignments", nil, nil, true, initialVars)
assert(created and not createError and createdId == 46, "page creation should accept initial variables")
assert(AngryAssign_Pages[46].Vars == initialVars, "initial variables are stored before the page is published")
assert(
    hashArguments[1] == "Templated Sibling" and hashArguments[2] == "Assignments" and hashArguments[3] == initialVars,
    "the initial content identity includes template variables"
)
assert(sentPageId == 46, "the first published page revision includes the fully initialized record")

local pagesBeforeRejectedCreate = nextPageId
local sendsBeforeRejectedCreate = #sentDisplays
sentPageId = nil
created, createError = AngryEra:CreatePage(string.rep("n", 101), "", nil, nil)
assert(not created and createError, "page creation should reject an oversized name")
assert(nextPageId == pagesBeforeRejectedCreate, "invalid page creation must not allocate a record id")
assert(sentPageId == nil and #sentDisplays == sendsBeforeRejectedCreate, "invalid page creation must not publish")

created, createError = AngryEra:CreatePage("Oversized content", string.rep("x", 20001), nil, nil)
assert(not created and createError, "page creation should reject oversized contents")
assert(nextPageId == pagesBeforeRejectedCreate, "oversized contents must not allocate a record id")

created, createError = AngryEra:CreatePage("Invalid content type", {}, nil, nil)
assert(not created and createError == "Page contents must be text.", "page creation should reject non-text contents")
created, createError = AngryEra:CreatePage("Invalid variables type", "", nil, nil, nil, {})
assert(
    not created and createError == "Variables and metadata must be text.",
    "page creation should reject non-text variables"
)

local pageBeforeRejectedEdit = AngryAssign_Pages[42]
local oldName = pageBeforeRejectedEdit.Name
local oldContents = pageBeforeRejectedEdit.Contents
local oldVars = pageBeforeRejectedEdit.Vars
local oldHistoryCount = #(pageBeforeRejectedEdit.History or {})
local proposalsBeforeRejectedEdit = #submittedSharedPageProposals
local sendsBeforeRejectedEdit = #sentDisplays
sentPageId = nil

renamed, renameError = AngryEra:RenamePage(42, string.rep("n", 101))
assert(not renamed and renameError, "page rename should reject an oversized name")
assert(pageBeforeRejectedEdit.Name == oldName, "a rejected rename must preserve the page name")

saved, saveResult = AngryEra:UpdateContents(42, string.rep("x", 20001))
assert(not saved and saveResult, "page update should reject oversized contents")
assert(pageBeforeRejectedEdit.Contents == oldContents, "rejected contents must preserve the page")
assert(#(pageBeforeRejectedEdit.History or {}) == oldHistoryCount, "rejected contents must not create history")

saved, saveResult = AngryEra:UpdatePageVars(42, string.rep("v", 5001))
assert(not saved and saveResult, "page update should reject oversized variables")
assert(pageBeforeRejectedEdit.Vars == oldVars, "rejected variables must preserve the page")
saved, saveResult = AngryEra:UpdatePageVars(42, {})
assert(
    not saved and saveResult == "Variables and metadata must be text.",
    "page variable updates should reject non-text input instead of silently erasing it"
)
assert(pageBeforeRejectedEdit.Vars == oldVars, "rejected non-text variables must preserve the page")
assert(
    #submittedSharedPageProposals == proposalsBeforeRejectedEdit,
    "invalid local edits must fail before proposal submission"
)
assert(
    sentPageId == nil and #sentDisplays == sendsBeforeRejectedEdit,
    "invalid local edits must fail before publication"
)

local categoriesBeforeRejectedCreate = 0
for _ in pairs(AngryAssign_Categories) do
    categoriesBeforeRejectedCreate = categoriesBeforeRejectedCreate + 1
end
local categoryCreated, categoryCreateError = AngryEra:CreateCategory(string.rep("n", 101))
assert(not categoryCreated and categoryCreateError, "category creation should reject an oversized name")
local categoriesAfterRejectedCreate = 0
for _ in pairs(AngryAssign_Categories) do
    categoriesAfterRejectedCreate = categoriesAfterRejectedCreate + 1
end
assert(
    categoriesAfterRejectedCreate == categoriesBeforeRejectedCreate,
    "invalid category creation must not allocate a record"
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

for depth = 1, 32 do
    local id = 1000 + depth
    AngryAssign_Categories[id] = {
        Id = id,
        Name = "Depth " .. depth,
        CategoryId = depth > 1 and id - 1 or nil,
    }
end
local nextIdBeforeDeepCreate = nextPageId
local sendsBeforeDeepCreate = #sentDisplays
created, createError = AngryEra:CreatePage("Too deep", "", 1032)
assert(not created and createError, "page creation should reject a parent at the maximum category depth")
assert(nextPageId == nextIdBeforeDeepCreate, "a too-deep page must not allocate a record")
assert(#sentDisplays == sendsBeforeDeepCreate, "a too-deep page must not publish")

created, createError = AngryEra:CreatePage("Missing parent", "", 9999)
assert(not created and createError, "page creation should reject an unknown parent category")
assert(nextPageId == nextIdBeforeDeepCreate, "an orphaned page must not allocate a record")

pageBeforeRejectedEdit.History = "corrupt"
AngryEra:PushHistory(pageBeforeRejectedEdit, "Recovered history", "Leader-Realm")
assert(
    type(pageBeforeRejectedEdit.History) == "table" and pageBeforeRejectedEdit.History[1].content == "Recovered history",
    "history insertion should recover safely if runtime state is unexpectedly malformed"
)

print("Model update tests passed.")
