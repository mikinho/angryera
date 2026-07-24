-- -------------------------------------------------------------------------------
-- Angry Era: modules/init.lua
--
-- Lifecycle: OnInitialize, OnEnable, AfterEnable, event handlers, slash command.
-- -------------------------------------------------------------------------------

local appName, app = ...
local AngryEra = app.AngryEra
local LSM = app.libs.LSM

AngryEra.Templates = app.Templates

local core = AngryEra.core
local isClassic = core.isClassic
local protocolPrefix = AngryEra.utils.protocol.PREFIX
local displayProtocolPrefix = AngryEra.utils.protocol.DISPLAY_PREFIX
local pageProtocolPrefix = AngryEra.utils.protocol.PAGE_PREFIX
local activePageProtocolPrefix = AngryEra.utils.protocol.ACTIVE_PAGE_PREFIX
local leadershipRosterReconcileDelay = 0.25
local leadershipRosterReconcileMaxAttempts = 3

local colors = AngryEra.utils.colors
local RGBToHex = colors.RGBToHex
local HexToRGB = colors.HexToRGB
local RequestGuildRoster = AngryEra.utils.helpers.RequestGuildRoster

local AngryEra_Title = AngryEra.Title
local AngryEra_Version = AngryEra.Version

-- -----------------
-- Addon Setup --
-- -----------------

local blizOptionsPanel
local blizOptionsCategoryId

-- class AngryEraState
-- field tree table Tree view state (collapsed nodes etc)
-- field window table Window position/size
-- field display table Display frame position/size
-- field displayed? number ID of the currently displayed page
-- field locked boolean Whether the display is locked
-- field directionUp boolean Growth direction

-- class AngryEraConfig
-- field scale number Scale of the edit window
-- field hideoncombat boolean Hide display in combat
-- field highlight string Comma/space separated words to highlight
-- field highlightColor string Hex color for highlights
-- field backdropShow boolean Show backdrop
-- field backdropColor string Hex color for backdrop
-- field glowColor string Hex color for update notification
-- field fontName string Font face
-- field fontHeight number Font size
-- field fontFlags string Font outline
-- field color string Normal text color

-- class AngryEraTemplatePage
-- field name string
-- field content string

-- class AngryEraTemplate
-- field name string
-- field pages AngryEraTemplatePage[]

-- type table<number, Page> Dictionary of pages key=Id
_G.AngryAssign_Pages = _G.AngryAssign_Pages

-- type table<number, Category> Dictionary of categories key=Id
_G.AngryAssign_Categories = _G.AngryAssign_Categories

-- type AngryEraState
_G.AngryAssign_State = _G.AngryAssign_State

-- type AngryEraConfig
_G.AngryAssign_Config = _G.AngryAssign_Config

-- type AngryEraTemplate[]
_G.AngryAssign_Templates = _G.AngryAssign_Templates

-- type table Durable installation, ownership, and synchronization metadata
_G.AngryAssign_Meta = _G.AngryAssign_Meta

--- Addon initialization hook.
-- Creates saved variable tables, migrates legacy category data, and registers options.
function AngryEra:OnInitialize()
    if AngryAssign_State == nil then
        AngryAssign_State =
            { tree = {}, window = {}, display = {}, displayed = nil, locked = false, directionUp = false }
    end
    if AngryAssign_Pages == nil then
        AngryAssign_Pages = {}
    end
    if AngryAssign_Config == nil then
        AngryAssign_Config = {}
    end
    if AngryAssign_Templates == nil then
        AngryAssign_Templates = {}
    end
    if AngryAssign_Categories == nil then
        AngryAssign_Categories = {}
    else
        for _, cat in pairs(AngryAssign_Categories) do
            if cat.Children then
                for _, pageId in ipairs(cat.Children) do
                    local page = AngryAssign_Pages[pageId]
                    if page then
                        page.CategoryId = cat.Id
                    end
                end
                cat.Children = nil
            end
        end
    end

    self:InitializeIdentityStorage()
    self:MigratePermissionConfig()
    self:MigrateEntityIdentities()
    self:MigrateLegacyLocalIds()
    local syncRuntimeReady, syncRuntimeResult = self:InitializeSyncRuntimeStorage()
    if not syncRuntimeReady then
        self.syncRuntimeStartupWarning = "Synchronization v3 is disabled because its saved state could not be initialized: "
            .. tostring(syncRuntimeResult)
    elseif #syncRuntimeResult > 0 then
        local scopeLabel = #syncRuntimeResult == 1 and "scope" or "scopes"
        self.syncRuntimeStartupWarning = string.format(
            "Synchronization v3 repaired %d invalid saved %s; affected scopes were disabled.",
            #syncRuntimeResult,
            scopeLabel
        )
    else
        self.syncRuntimeStartupWarning = nil
    end

    -- Run cleanup once on load
    self:CleanupOrphanedStates()

    local ver = AngryEra_Version
    if ver:sub(1, 1) == "@" then
        ver = "dev"
    end

    local options = {
        name = appName .. " " .. ver,
        handler = AngryEra,
        type = "group",
        args = {
            window = {
                type = "execute",
                order = 3,
                name = "Toggle Window",
                desc = "Shows/hides the edit window (also available in game keybindings)",
                func = function()
                    AngryEra_ToggleWindow()
                end,
            },
            help = {
                type = "execute",
                order = 99,
                name = "Help",
                hidden = true,
                func = function()
                    LibStub("AceConfigCmd-3.0").HandleCommand(self, "aa", "AngryEra", "")
                end,
            },
            debug = {
                type = "execute",
                order = 98,
                name = "Toggle Sync Debug",
                desc = "Toggles session-local synchronization timing output",
                hidden = true,
                cmdHidden = false,
                func = function()
                    self:ToggleSyncDebug()
                end,
            },
            toggle = {
                type = "execute",
                order = 1,
                name = "Toggle Display",
                desc = "Shows/hides the display frame (also available in game keybindings)",
                func = function()
                    AngryEra_ToggleDisplay()
                end,
            },
            deleteall = {
                type = "execute",
                name = "Delete All Pages",
                desc = "Deletes all pages",
                order = 4,
                hidden = true,
                cmdHidden = false,
                confirm = true,
                func = function()
                    self:ClearDisplayed(true)
                    self:RemoveAllEntityRecords()
                    self:UpdateTree()
                    self:UpdateSelected()
                    self:UpdateDisplayed()
                    if self.window then
                        self.window.tree:SetSelected(nil)
                    end
                    self:Print("All pages have been deleted.")
                end,
            },
            defaults = {
                type = "execute",
                name = "Restore Defaults",
                desc = "Restore configuration values to their default settings",
                order = 10,
                hidden = true,
                cmdHidden = false,
                confirm = true,
                func = function()
                    self:RestoreDefaults()
                end,
            },
            output = {
                type = "execute",
                name = "Output",
                desc = "Outputs currently displayed assignments to chat",
                order = 11,
                hidden = true,
                cmdHidden = false,
                confirm = true,
                func = function()
                    self:OutputDisplayed()
                end,
            },
            first = {
                type = "execute",
                name = "First Page",
                desc = "Toggles to and from the first page in the current category",
                order = 11.5,
                hidden = true,
                cmdHidden = false,
                func = function()
                    self:FirstPage()
                end,
            },
            send = {
                type = "input",
                name = "Send and Display",
                desc = "Sends page with specified name",
                order = 12,
                hidden = true,
                cmdHidden = false,
                confirm = true,
                get = function(info)
                    return ""
                end,
                set = function(info, val)
                    local result = self:DisplayPageByName(val:trim())
                    if result == false then
                        self:Print(
                            RED_FONT_COLOR_CODE .. "A page with the name \"" .. val:trim() .. "\" could not be found.|r"
                        )
                    elseif not result then
                        self:Print(RED_FONT_COLOR_CODE .. "You don't have permission to send a page.|r")
                    end
                end,
            },
            clear = {
                type = "execute",
                name = "Clear",
                desc = "Clears currently displayed page",
                order = 13,
                hidden = true,
                cmdHidden = false,
                confirm = true,
                func = function()
                    AngryEra._AngryEra_ClearPage()
                end,
            },
            backup = {
                type = "execute",
                order = 20,
                name = "Backup Pages",
                desc = "Creates a backup of all pages with their current contents",
                func = function()
                    self:CreateBackup()
                    self:Print("Created a backup of all pages.")
                end,
            },
            resetposition = {
                type = "execute",
                order = 22,
                name = "Reset Position",
                desc = "Resets position for the assignment display",
                func = function()
                    self:ResetPosition()
                end,
            },
            version = {
                type = "execute",
                order = 21,
                name = "Version Check",
                desc = "Displays a list of all users (in the raid) running the addon and the version they're running",
                func = function()
                    if IsInRaid() or IsInGroup() then
                        local sent, queryIdOrError = self:SendProtocolVersionQuery(true)
                        if sent then
                            self:ScheduleTimer("VersionCheckOutput", 3, queryIdOrError)
                            self:Print("Version check running...")
                        else
                            self:Print("Unable to start version check: " .. tostring(queryIdOrError))
                        end
                    else
                        self:Print("You must be in a raid group to run the version check.")
                    end
                end,
            },
            lock = {
                type = "execute",
                order = 2,
                name = "Toggle Lock",
                desc = "Shows/hides the display mover (also available in game keybindings)",
                func = function()
                    self:ToggleLock()
                end,
            },
            config = {
                type = "group",
                order = 5,
                name = "General",
                inline = true,
                args = {
                    highlight = {
                        type = "input",
                        order = 1,
                        name = "Highlight",
                        desc = "A list of words to highlight on displayed pages (separated by spaces or punctuation)\n\nUse \"Group\" to highlight the current group you are in, ex. G2",
                        get = function(info)
                            return self:GetConfig("highlight")
                        end,
                        set = function(info, val)
                            self:SetConfig("highlight", val)
                            self:UpdateDisplayed()
                        end,
                    },
                    hideoncombat = {
                        type = "toggle",
                        order = 3,
                        name = "Hide on Combat",
                        desc = "Enable to hide display frame upon entering combat",
                        get = function(info)
                            return self:GetConfig("hideoncombat")
                        end,
                        set = function(info, val)
                            self:SetConfig("hideoncombat", val)
                        end,
                    },
                    chatoutput = {
                        type = "select",
                        order = 3.5,
                        name = "Chat Output Format",
                        desc = "How spells should be displayed when outputting to chat (e.g. {jol})",
                        values = { ["Name"] = "Spell Name", ["Acronym"] = "Acronym" },
                        get = function(info)
                            return self:GetConfig("chatoutput")
                        end,
                        set = function(info, val)
                            self:SetConfig("chatoutput", val)
                        end,
                    },
                    scale = {
                        type = "range",
                        order = 4,
                        name = "Scale",
                        desc = "Sets the scale of the edit window",
                        min = 0.3,
                        max = 3,
                        get = function(info)
                            return self:GetConfig("scale")
                        end,
                        set = function(info, val)
                            self:SetConfig("scale", val)
                            if AngryEra.window then
                                AngryEra.window.frame:SetScale(val)
                            end
                        end,
                    },
                    backdrop = {
                        type = "toggle",
                        order = 5,
                        name = "Display Backdrop",
                        desc = "Enable to display a backdrop behind the assignment display",
                        get = function(info)
                            return self:GetConfig("backdropShow")
                        end,
                        set = function(info, val)
                            self:SetConfig("backdropShow", val)
                            self:UpdateBackdrop()
                        end,
                    },
                    backdropcolor = {
                        type = "color",
                        order = 6,
                        name = "Backdrop Color",
                        desc = "The color used by the backdrop",
                        hasAlpha = true,
                        get = function(info)
                            local hex = self:GetConfig("backdropColor")
                            return HexToRGB(hex)
                        end,
                        set = function(info, r, g, b, a)
                            self:SetConfig("backdropColor", RGBToHex(r, g, b, a))
                            self:UpdateMedia()
                            self:UpdateDisplayed()
                        end,
                    },
                    updatecolor = {
                        type = "color",
                        order = 7,
                        name = "Update Notification Color",
                        desc = "The color used by the update notification glow",
                        get = function(info)
                            local hex = self:GetConfig("glowColor")
                            return HexToRGB(hex)
                        end,
                        set = function(info, r, g, b)
                            self:SetConfig("glowColor", RGBToHex(r, g, b))
                            self.display_glow:SetVertexColor(r, g, b)
                            self.display_glow2:SetVertexColor(r, g, b)
                        end,
                    },
                },
            },
            font = {
                type = "group",
                order = 6,
                name = "Font",
                inline = true,
                args = {
                    fontname = {
                        type = "select",
                        order = 1,
                        dialogControl = "LSM30_Font",
                        name = "Face",
                        desc = "Sets the font face used to display a page",
                        values = LSM:HashTable("font"),
                        get = function(info)
                            return self:GetConfig("fontName")
                        end,
                        set = function(info, val)
                            self:SetConfig("fontName", val)
                            self:UpdateMedia()
                        end,
                    },
                    fontheight = {
                        type = "range",
                        order = 2,
                        name = "Size",
                        desc = function()
                            return "Sets the font height used to display a page"
                        end,
                        min = 6,
                        max = 24,
                        step = 1,
                        get = function(info)
                            return self:GetConfig("fontHeight")
                        end,
                        set = function(info, val)
                            self:SetConfig("fontHeight", val)
                            self:UpdateMedia()
                        end,
                    },
                    fontflags = {
                        type = "select",
                        order = 3,
                        name = "Outline",
                        desc = "Sets the font outline used to display a page",
                        values = {
                            ["NONE"] = "None",
                            ["OUTLINE"] = "Outline",
                            ["THICKOUTLINE"] = "Thick Outline",
                            ["MONOCHROMEOUTLINE"] = "Monochrome",
                        },
                        get = function(info)
                            return self:GetConfig("fontFlags")
                        end,
                        set = function(info, val)
                            self:SetConfig("fontFlags", val)
                            self:UpdateMedia()
                        end,
                    },
                    color = {
                        type = "color",
                        order = 4,
                        name = "Normal Color",
                        desc = "The normal color used to display assignments",
                        get = function(info)
                            local hex = self:GetConfig("color")
                            return HexToRGB(hex)
                        end,
                        set = function(info, r, g, b)
                            self:SetConfig("color", RGBToHex(r, g, b))
                            self:UpdateMedia()
                            self:UpdateDisplayed()
                        end,
                    },
                    highlightcolor = {
                        type = "color",
                        order = 5,
                        name = "Highlight Color",
                        desc = "The color used to emphasize highlighted words",
                        get = function(info)
                            local hex = self:GetConfig("highlightColor")
                            return HexToRGB(hex)
                        end,
                        set = function(info, r, g, b)
                            self:SetConfig("highlightColor", RGBToHex(r, g, b))
                            self:UpdateDisplayed()
                        end,
                    },
                    linespacing = {
                        type = "range",
                        order = 6,
                        name = "Line Spacing",
                        desc = function()
                            return "Sets the line spacing used to display a page"
                        end,
                        min = 0,
                        max = 10,
                        step = 1,
                        get = function(info)
                            return self:GetConfig("lineSpacing")
                        end,
                        set = function(info, val)
                            self:SetConfig("lineSpacing", val)
                            self:UpdateMedia()
                            self:UpdateDisplayed()
                        end,
                    },
                    editBoxFont = {
                        type = "toggle",
                        order = 7,
                        name = "Change Edit Box Font",
                        desc = "Enable to set edit box font to display font",
                        get = function(info)
                            return self:GetConfig("editBoxFont")
                        end,
                        set = function(info, val)
                            self:SetConfig("editBoxFont", val)
                            self:UpdateMedia()
                        end,
                    },
                },
            },
            permissions = {
                type = "group",
                order = 7,
                name = "Permissions",
                inline = true,
                args = {
                    receiveMode = {
                        type = "select",
                        order = 1,
                        name = "Receive Shared Page Changes",
                        desc = "Choose who may change shared pages on this installation; only the group leader controls the display",
                        values = {
                            standard = "Leader + Qualified Assistants",
                            leaderOnly = "Leader Only",
                            ignoreShared = "Ignore Shared Changes",
                        },
                        get = function(info)
                            return self:GetConfig("receiveMode")
                        end,
                        set = function(info, val)
                            local previousMode = self:GetConfig("receiveMode")
                            self:SetConfig("receiveMode", val)
                            self:ReceiveModeUpdated(previousMode)
                        end,
                    },
                    allowAllAssistants = {
                        type = "toggle",
                        order = 2,
                        name = "Allow All Raid Assistants",
                        desc = "Explicitly trust every raid assistant for non-destructive shared page changes",
                        get = function(info)
                            return self:GetConfig("allowAllAssistants")
                        end,
                        set = function(info, val)
                            self:SetConfig("allowAllAssistants", val)
                            self:PermissionsUpdated()
                        end,
                    },
                    trustedPublishers = {
                        type = "input",
                        order = 3,
                        name = "Trusted Assistants",
                        desc = "Names of raid assistants trusted directly for non-destructive page changes (Name-Realm, separated by spaces or commas)",
                        get = function(info)
                            return self:GetConfig("trustedPublishers")
                        end,
                        set = function(info, val)
                            self:SetConfig("trustedPublishers", val)
                            self:PermissionsUpdated()
                        end,
                    },
                },
            },
        },
    }

    self:RegisterChatCommand("aa", "ChatCommand")
    LibStub("AceConfig-3.0"):RegisterOptionsTable("AngryEra", options)

    blizOptionsPanel, blizOptionsCategoryId =
        LibStub("AceConfigDialog-3.0"):AddToBlizOptions("AngryEra", AngryEra_Title)
    blizOptionsPanel.default = function()
        self:RestoreDefaults()
    end
end

--- Slash command entry point (`/aa`).
-- @tparam string input Raw slash command arguments.
function AngryEra:ChatCommand(input)
    if not input or input:trim() == "" then
        if Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(blizOptionsCategoryId)
        else
            InterfaceOptionsFrame_OpenToCategory(blizOptionsPanel)
        end
    else
        local command = input:trim():lower()
        if command == "first" then
            self:FirstPage()
        elseif command == "debug" then
            self:HandleSyncDebugCommand("")
        else
            local debugArgument = command:match("^debug%s+(.+)$")
            if debugArgument then
                self:HandleSyncDebugCommand(debugArgument)
            else
                LibStub("AceConfigCmd-3.0").HandleCommand(self, "aa", "AngryEra", input)
            end
        end
    end
end

local function CancelLeadershipRosterReconcileTimer(self)
    local timer = self._leadershipRosterReconcileTimer
    self._leadershipRosterReconcileTimer = nil
    if timer and type(self.CancelTimer) == "function" then
        pcall(self.CancelTimer, self, timer)
    end
    return timer ~= nil
end

--- Cancels and invalidates the current settled-roster reconciliation.
-- A generation increment makes an already-dispatched AceTimer callback inert.
-- @treturn boolean canceled Whether a timer was pending.
function AngryEra:CancelProtocolLeadershipRosterReconcile()
    local canceled = CancelLeadershipRosterReconcileTimer(self)
    self._leadershipRosterReconcileGeneration =
        (self._leadershipRosterReconcileGeneration or 0) + 1
    self._leadershipRosterReconcilePending = false
    self._leadershipRosterReconcileAttempts = 0
    return canceled
end

local function ScheduleLeadershipRosterReconcile(self)
    if
        self._leadershipRosterReconcilePending ~= true
        or not self._protocolStarted
        or type(self.ScheduleTimer) ~= "function"
    then
        return false, "leadership-reconcile-inactive"
    end

    CancelLeadershipRosterReconcileTimer(self)
    self._leadershipRosterReconcileGeneration =
        (self._leadershipRosterReconcileGeneration or 0) + 1
    local generation = self._leadershipRosterReconcileGeneration
    local timer =
        self:ScheduleTimer(
            "RetryProtocolLeadershipRosterReconcile",
            leadershipRosterReconcileDelay,
            generation
        )
    if not timer then
        return false, "leadership-reconcile-schedule-failed"
    end
    self._leadershipRosterReconcileTimer = timer
    return true, timer
end

--- Starts one bounded settled-roster reconciliation generation.
-- Roster events may run it early; the timer guarantees progress when Classic
-- updates the role APIs without emitting another GROUP_ROSTER_UPDATE.
-- @treturn boolean scheduled
-- @treturn table|string timerOrError
function AngryEra:StartProtocolLeadershipRosterReconcile()
    self:CancelProtocolLeadershipRosterReconcile()
    if not self._protocolStarted then
        return false, "protocol-not-started"
    end
    self._leadershipRosterReconcilePending = true
    return ScheduleLeadershipRosterReconcile(self)
end

--- Runs one generation-scoped settled-roster reconciliation attempt.
-- Roster events may consume the first two attempts. The terminal attempt is
-- reserved for the trailing timer so an event burst cannot exhaust recovery
-- before Classic's role APIs settle.
-- @tparam number generation Expected lifecycle generation.
-- @tparam[opt=false] boolean timerDriven Whether this invocation is the timer callback.
-- @treturn boolean reconciled
-- @treturn table|string resultOrStatus
-- @treturn string|nil schedulingError
function AngryEra:RunProtocolLeadershipRosterReconcile(generation, timerDriven)
    if
        self._leadershipRosterReconcilePending ~= true
        or generation ~= self._leadershipRosterReconcileGeneration
    then
        return true, "superseded"
    end

    CancelLeadershipRosterReconcileTimer(self)
    if not self._protocolStarted or not (IsInRaid() or IsInGroup()) then
        self:CancelProtocolLeadershipRosterReconcile()
        return false, "protocol-or-group-inactive"
    end

    local completedAttempts = self._leadershipRosterReconcileAttempts or 0
    if
        timerDriven ~= true
        and completedAttempts >= leadershipRosterReconcileMaxAttempts - 1
    then
        local scheduled, scheduleResult = ScheduleLeadershipRosterReconcile(self)
        return true, "awaiting-timer", scheduled and nil or scheduleResult
    end

    local attempts = completedAttempts + 1
    self._leadershipRosterReconcileAttempts = attempts
    local reconciled, result = self:ReconcileProtocolLeadershipFromRoster()
    local retryUnsettled = type(result) == "table"
        and result.Changed == false
        and attempts < leadershipRosterReconcileMaxAttempts
    if not retryUnsettled then
        self:CancelProtocolLeadershipRosterReconcile()
        return reconciled, result
    end

    local scheduled, scheduleResult = ScheduleLeadershipRosterReconcile(self)
    return reconciled, result, scheduled and nil or scheduleResult
end

--- Timer callback for one settled-roster reconciliation generation.
-- @tparam number generation Generation captured when the timer was scheduled.
-- @treturn boolean reconciled
-- @treturn table|string resultOrStatus
function AngryEra:RetryProtocolLeadershipRosterReconcile(generation)
    if generation == self._leadershipRosterReconcileGeneration then
        self._leadershipRosterReconcileTimer = nil
    end
    return self:RunProtocolLeadershipRosterReconcile(generation, true)
end

--- Addon enable hook.
-- Initializes display and core event listeners.
function AngryEra:OnEnable()
    self:CancelProtocolLeadershipRosterReconcile()
    self:ResetOfficerRank()
    self:CreateDisplay()
    if type(self.CaptureDisplayAuthorityRecovery) == "function" then
        self:CaptureDisplayAuthorityRecovery()
    end
    self:ClearDisplayed()
    if self.syncRuntimeStartupWarning then
        self:Print(self.syncRuntimeStartupWarning)
        self.syncRuntimeStartupWarning = nil
    end
    AngryEra._protocolStarted = false
    AngryEra._startupDiscoveryRetryNeeded = false
    local protocolStarted, protocolError = self:StartProtocolSession()
    if not protocolStarted then
        self:Print("Unable to start synchronization session: " .. tostring(protocolError))
    else
        self:RegisterComm(protocolPrefix, "ReceiveProtocolMessage")
        self:RegisterComm(displayProtocolPrefix, "ReceiveProtocolMessage")
        self:RegisterComm(pageProtocolPrefix, "ReceiveProtocolMessage")
        self:RegisterComm(activePageProtocolPrefix, "ReceiveProtocolMessage")
        AngryEra._protocolStarted = true
        local localAuthority =
            type(self.IsPlayerRaidLeader) == "function" and self:IsPlayerRaidLeader() == true
        local discoverySent
        local discoveryResult
        if localAuthority then
            discoverySent, discoveryResult = self:SendProtocolVersionQuery(true)
        end
        if type(self.RestoreDisplayAuthority) == "function" then
            self:RestoreDisplayAuthority()
        end
        if not localAuthority and type(self.SendRequestDisplay) == "function" then
            discoverySent, discoveryResult = self:SendRequestDisplay()
        end
        AngryEra._startupDiscoveryRetryNeeded =
            discoverySent ~= true and discoveryResult ~= "shared-display-disabled"
    end

    self:ScheduleTimer("AfterEnable", 4)

    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("PLAYER_GUILD_UPDATE")
    self:RegisterEvent("GUILD_ROSTER_UPDATE")
    self:RegisterEvent("ENCOUNTER_END")
    self:RegisterEvent("PARTY_LEADER_CHANGED")
    self:RegisterEvent("GROUP_JOINED")
    self:RegisterEvent("GROUP_ROSTER_UPDATE")

    if isClassic then
        RequestGuildRoster()
    end

    LSM.RegisterCallback(self, "LibSharedMedia_Registered", "UpdateMedia")
    LSM.RegisterCallback(self, "LibSharedMedia_SetGlobal", "UpdateMedia")

    if type(self.NOTE_UPDATE_EVENT) == "string" and type(self.RegisterMessage) == "function" then
        self:RegisterMessage(self.NOTE_UPDATE_EVENT, "ApplyDisplayedNoteMarkers")
    end
end

function AngryEra:PARTY_LEADER_CHANGED()
    local tenure
    if self._protocolStarted and type(self.RefreshProtocolLeadershipTenure) == "function" then
        local refreshed, result = self:RefreshProtocolLeadershipTenure(nil, true)
        if refreshed and type(result) == "table" then
            tenure = result
        end
    end
    if type(self.ResetDisplayAuthorityPublicationState) == "function" then
        self:ResetDisplayAuthorityPublicationState("leader-changed")
    elseif type(self.CancelPendingDisplayRecovery) == "function" then
        self:CancelPendingDisplayRecovery()
    end
    if type(self.ResetProtocolAncestorAnnouncements) == "function" then
        self:ResetProtocolAncestorAnnouncements()
    end
    self:PermissionsUpdated()
    if self._protocolStarted then
        local localAuthority = false
        if tenure then
            localAuthority = tenure.LocalAuthority == true
        elseif type(self.IsPlayerRaidLeader) == "function" then
            localAuthority = self:IsPlayerRaidLeader() == true
        end
        if localAuthority then
            self:SendProtocolVersionQuery(tenure and tenure.Rotated == true)
        end
        if localAuthority and type(self.RestoreDisplayAuthority) == "function" then
            local _, _, isLocalAuthority = self:RestoreDisplayAuthority()
            localAuthority = isLocalAuthority == true
        end
        if not localAuthority and not (tenure and tenure.PendingDisplayBootstrap == true) then
            if type(self.CancelDisplayRequestWatchdog) == "function" then
                self:CancelDisplayRequestWatchdog()
            end
            self:SendRequestDisplay()
        end
    end
    self:StartProtocolLeadershipRosterReconcile()
end

function AngryEra:GROUP_JOINED()
    local preserveLeadershipReconcile = self._leadershipRosterReconcilePending == true
    local preservedLeadershipReconcileAttempts =
        self._leadershipRosterReconcileAttempts or 0
    self:CancelProtocolLeadershipRosterReconcile()
    if type(self.DiscardDisplayAuthorityRecovery) == "function" then
        self:DiscardDisplayAuthorityRecovery()
    end
    self:ClearDisplayed()
    self:ResetProtocolPeers()
    if self._protocolStarted then
        local localAuthority = type(self.IsPlayerRaidLeader) == "function" and self:IsPlayerRaidLeader() == true
        if type(self.RefreshProtocolLeadershipTenure) == "function" then
            local refreshed, result = self:RefreshProtocolLeadershipTenure()
            if refreshed and type(result) == "table" then
                localAuthority = result.LocalAuthority == true
            end
        end
        if localAuthority then
            self:SendProtocolVersionQuery(true)
        else
            self:ScheduleTimer("SendRequestDisplayIfUnbound", 0.5)
        end
    end
    self:UpdateDisplayedIfNewGroup()
    if preserveLeadershipReconcile and self._protocolStarted then
        self:StartProtocolLeadershipRosterReconcile()
        self._leadershipRosterReconcileAttempts =
            preservedLeadershipReconcileAttempts
    end
end

function AngryEra:PLAYER_REGEN_DISABLED()
    if AngryEra:GetConfig("hideoncombat") then
        self:HideDisplay()
    end
end

--- Rechecks protocol tenure after roster roles have settled.
-- PARTY_LEADER_CHANGED can precede the roster API update on Classic. This
-- bounded pass is a no-op for a stable tenure, but repairs one missed
-- promotion, demotion, or remote-leader transition.
-- @treturn boolean reconciled
-- @treturn table|string resultOrStatus
function AngryEra:ReconcileProtocolLeadershipFromRoster()
    if not self._protocolStarted or type(self.RefreshProtocolLeadershipTenure) ~= "function" then
        return false, "protocol-not-started"
    end

    local refreshed, result = self:RefreshProtocolLeadershipTenure()
    if not refreshed or type(result) ~= "table" then
        return false, result
    end
    if result.Changed ~= true then
        local authority
        if result.LocalAuthority ~= true and type(self.GetProtocolDisplayAuthority) == "function" then
            local called, current = pcall(self.GetProtocolDisplayAuthority, self)
            if called then
                authority = current
            end
        end
        if
            result.LocalAuthority ~= true
            and type(authority) ~= "table"
            and type(self.SendRequestDisplay) == "function"
        then
            local sent, requestResult = self:SendRequestDisplay()
            return sent,
                {
                    Changed = false,
                    LocalAuthority = false,
                    PendingDisplayBootstrap = true,
                    RequestResult = requestResult,
                }
        end
        return true, result
    end

    if type(self.ResetDisplayAuthorityPublicationState) == "function" then
        self:ResetDisplayAuthorityPublicationState("roster-leadership-reconciled")
    elseif type(self.CancelPendingDisplayRecovery) == "function" then
        self:CancelPendingDisplayRecovery()
    end
    if type(self.ResetProtocolAncestorAnnouncements) == "function" then
        self:ResetProtocolAncestorAnnouncements()
    end

    if result.LocalAuthority == true then
        self:SendProtocolVersionQuery(result.Rotated == true)
        if type(self.RestoreDisplayAuthority) == "function" then
            self:RestoreDisplayAuthority()
        end
    elseif result.PendingDisplayBootstrap ~= true then
        if type(self.CancelDisplayRequestWatchdog) == "function" then
            self:CancelDisplayRequestWatchdog()
        end
        self:SendRequestDisplay()
    end
    return true, result
end

function AngryEra:GROUP_ROSTER_UPDATE()
    self:PermissionsUpdated()
    local reconcileLeadership = self._leadershipRosterReconcilePending == true
    if not (IsInRaid() or IsInGroup()) then
        self:CancelProtocolLeadershipRosterReconcile()
        if type(self.DiscardDisplayAuthorityRecovery) == "function" then
            self:DiscardDisplayAuthorityRecovery()
        end
        self:ClearDisplayed()
        self:ResetCurrentGroup()
        self:ResetPermissionWarning()
        self:ResetProtocolPeers()
    else
        self:PruneProtocolPeers()
        if reconcileLeadership then
            self:RunProtocolLeadershipRosterReconcile(
                self._leadershipRosterReconcileGeneration
            )
        end
        self:UpdateDisplayedIfNewGroup()
        if type(self.RetryDisplayedNoteMarkers) == "function" then
            self:RetryDisplayedNoteMarkers()
        end
    end
end

function AngryEra:PLAYER_GUILD_UPDATE()
    self:ResetOfficerRank()
    self:PermissionsUpdated()
end

local guildUpdatePending = false
function AngryEra:GUILD_ROSTER_UPDATE(...)
    local canRequestRosterUpdate = ...
    self:ResetOfficerRank()
    self:PermissionsUpdated()
    self:UpdateGuildColors()

    if not guildUpdatePending then
        guildUpdatePending = true
        C_Timer.After(2, function()
            guildUpdatePending = false
            self:UpdateDisplayed()
        end)
    end

    if canRequestRosterUpdate and isClassic then
        RequestGuildRoster()
    end
end

--- Requests lifecycle discovery only when no current authorized leader tenure
-- became bound while the delayed callback was waiting.
-- Explicit recovery callers continue to use SendRequestDisplay directly.
-- @treturn boolean sentOrResolved
-- @treturn string|nil messageIdOrStatus
function AngryEra:SendRequestDisplayIfUnbound()
    local authority
    if type(self.GetProtocolDisplayAuthority) == "function" then
        local called, current = pcall(self.GetProtocolDisplayAuthority, self)
        if called then
            authority = current
        end
    end
    if type(authority) == "table" and type(authority.Sender) == "string" then
        local authorized = true
        if type(self.CanReceiveFrom) == "function" then
            local called, allowed = pcall(self.CanReceiveFrom, self, authority.Sender, "display")
            authorized = called and allowed == true
        end
        if authorized then
            return true, "already-bound"
        end
    end
    if type(self.SendRequestDisplay) ~= "function" then
        return false, "display-request-unavailable"
    end
    return self:SendRequestDisplay()
end

--- Post-enable delayed setup hook for group discovery and event wiring.
function AngryEra:AfterEnable()
    self:UpdateDisplayedIfNewGroup()
    if self._protocolStarted and self._startupDiscoveryRetryNeeded == true then
        self._startupDiscoveryRetryNeeded = false
        local localAuthority = type(self.IsPlayerRaidLeader) == "function" and self:IsPlayerRaidLeader() == true
        if localAuthority then
            self:SendProtocolVersionQuery(true)
        else
            local authority
            if type(self.GetProtocolDisplayAuthority) == "function" then
                authority = self:GetProtocolDisplayAuthority()
            end
            if authority == nil then
                self:ScheduleTimer("SendRequestDisplayIfUnbound", 0.5)
            end
        end
    end
end
