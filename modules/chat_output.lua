-- -------------------------------------------------------------------------------
-- Angry Era: modules/chat_output.lua
--
-- Chat output rendering + throttled sending to group chat.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local tags = AngryEra.utils.tags
local colors = AngryEra.utils.colors
local helpers = AngryEra.utils.helpers

local ChatOutputClassMap = tags.ChatOutputClassMap
local UtilityChatData = tags.UtilityChatData
local UtilityChatMap = tags.UtilityChatMap
local ColorTable = colors.ColorTable

local core = AngryEra.core
local isClassic = core.isClassic
local isClassicTBC = core.isClassicTBC
local isClassicWrath = core.isClassicWrath

function AngryEra_OutputDisplayed()
    return AngryEra:OutputDisplayed(AngryEra:SelectedId())
end

local function ResolveChatOutputTag(self, tagContent)
    local lowerTag = "{" .. tagContent:lower() .. "}"

    if ChatOutputClassMap[lowerTag] then
        return ChatOutputClassMap[lowerTag]
    end

    if UtilityChatData and UtilityChatData[lowerTag] then
        local data = UtilityChatData[lowerTag]
        if self:GetConfig("chatoutput") == "Acronym" and data.key then
            return data.key
        end
        return data.name or data.key or UtilityChatMap[lowerTag]
    end

    if UtilityChatMap[lowerTag] then
        return UtilityChatMap[lowerTag]
    end

    local tagType, tagId = tagContent:match("^(%a+)%s+(%d+)$")
    if tagType then
        local numericId = tonumber(tagId)
        tagType = tagType:lower()
        if tagType == "spell" then
            return helpers.GetSpellLink(numericId)
        end
        if tagType == "boss" and not isClassicTBC and not isClassicWrath and EJ_GetEncounterInfo then
            return select(5, EJ_GetEncounterInfo(numericId))
        end
        if
            tagType == "journal"
            and not isClassicTBC
            and not isClassicWrath
            and C_EncounterJournal
            and C_EncounterJournal.GetSectionInfo
        then
            local section = C_EncounterJournal.GetSectionInfo(numericId)
            return section and section.link
        end
    end

    if tagContent:lower():match("^icon%s+") then
        return ""
    end

    return "{" .. tagContent .. "}"
end

local function StripChatOutputColors(text)
    return text:gsub("(|c%w+)", function(c)
        local lowerC = c:lower()
        if ColorTable[lowerC] then
            return ""
        end
        for i = #c - 1, 3, -1 do
            local sub = lowerC:sub(1, i)
            if ColorTable[sub] then
                return c:sub(i + 1)
            end
        end
        if lowerC:match("^|c%x+$") then
            return ""
        end
        return c
    end):gsub("|r", "")
end

--- Renders a page into chat-ready plain output.
-- Applies variable rendering, tag substitution, and custom color stripping.
-- @tparam[opt] table page Page object.
-- @treturn string output Chat-ready text.
function AngryEra:RenderPageForChatOutput(page)
    if not page then
        return ""
    end

    local ctx = self:GetTemplateContext()
    local renderedText, _ = self:RenderPageContent(page, ctx)
    local output = renderedText or page.Contents or ""

    output = output:gsub("{(.-)}", function(tagContent)
        return ResolveChatOutputTag(self, tagContent)
    end)

    return StripChatOutputColors(output)
end

--- Outputs rendered page content to current group chat channel.
-- @tparam[opt] number id Page id, defaults to currently displayed id.
function AngryEra:OutputDisplayed(id)
    if not self:PermissionCheck() then
        self:Print(RED_FONT_COLOR_CODE .. "You don't have permission to output a page.|r")
        return
    end

    if not id then
        id = AngryAssign_State.displayed
    end
    local page = AngryAssign_Pages[id]

    local channel
    if not isClassic and (IsInGroup(LE_PARTY_CATEGORY_INSTANCE) or IsInRaid(LE_PARTY_CATEGORY_INSTANCE)) then
        channel = "INSTANCE_CHAT"
    elseif IsInRaid() then
        channel = "RAID"
    elseif IsInGroup() then
        channel = "PARTY"
    end

    if channel and page then
        local output = self:RenderPageForChatOutput(page)

        -- If an output is already running, cancel it so we don't overlap spam
        if self.outputTimer then
            self:CancelTimer(self.outputTimer)
            self.outputTimer = nil
        end

        local lines = { strsplit("\n", output) }
        local queue = {}
        for _, line in ipairs(lines) do
            if line ~= "" then
                table.insert(queue, line)
            end
        end

        if #queue > 0 then
            local idx = 1
            -- Send the very first line instantly
            SendChatMessage(queue[idx], channel)
            idx = idx + 1

            -- If there are more lines, schedule them at a 0.2s interval
            if idx <= #queue then
                self.outputTimer = self:ScheduleRepeatingTimer(function()
                    SendChatMessage(queue[idx], channel)
                    idx = idx + 1
                    if idx > #queue then
                        self:CancelTimer(self.outputTimer)
                        self.outputTimer = nil
                    end
                end, 0.2)
            end
        end
    end
end

--- Renders a page for export format `"Output"`.
-- @tparam[opt] table page Page object.
-- @treturn string output Chat-ready text.
function AngryEra:ProcessPageForOutput(page)
    return self:RenderPageForChatOutput(page)
end
