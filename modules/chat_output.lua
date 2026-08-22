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

local RaidTargetChatMap = {
    star = "{rt1}",
    rt1 = "{rt1}",
    circle = "{rt2}",
    rt2 = "{rt2}",
    diamond = "{rt3}",
    rt3 = "{rt3}",
    triangle = "{rt4}",
    rt4 = "{rt4}",
    moon = "{rt5}",
    rt5 = "{rt5}",
    square = "{rt6}",
    rt6 = "{rt6}",
    cross = "{rt7}",
    x = "{rt7}",
    rt7 = "{rt7}",
    skull = "{rt8}",
    rt8 = "{rt8}",
}

function AngryEra_OutputDisplayed()
    return AngryEra:OutputDisplayed()
end

local function ResolveChatOutputTag(self, page, tagContent, preserveRaidTargetTags)
    local normalizedTag = tagContent:lower()
    local raidTargetTag = RaidTargetChatMap[normalizedTag]
    if raidTargetTag then
        if preserveRaidTargetTags == true then
            return "{" .. tagContent .. "}"
        end
        return raidTargetTag
    end

    if normalizedTag == "page" then
        return page.Name or ""
    end

    local lowerTag = "{" .. normalizedTag .. "}"

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
        if lowerC:match("^|c%x%x%x%x%x%x%x%x") then
            return c:sub(11)
        end
        if lowerC:match("^|c%x+$") then
            return ""
        end
        return c
    end):gsub("|r", "")
end

--- Removes every UI escape sequence from untrusted page text.
-- Runs before tag resolution so trusted links added by tag handlers survive.
-- Pasted links keep their visible name, textures and atlases are dropped, and
-- any leftover pipe is removed entirely, because a malformed escape sequence
-- in outgoing chat can disconnect recipients.
local function StripUiEscapes(text)
    text = text:gsub("|H.-|h(.-)|h", "%1")
    text = text:gsub("|T.-|t", "")
    text = text:gsub("|A.-|a", "")
    return (text:gsub("|", ""))
end

local function RenderPageOutput(self, page, options)
    if not page then
        return ""
    end

    local ctx = self:GetTemplateContext()
    local renderedText, _, _, renderedPage = self:RenderPageContent(page, ctx, {
        UseActiveDisplayContext = options.UseActiveDisplayContext == true,
    })
    local output = renderedText or page.Contents or ""
    renderedPage = renderedPage or page

    if options.SanitizeUiEscapes then
        output = StripUiEscapes(StripChatOutputColors(output))
    end

    output = output:gsub("{(.-)}", function(tagContent)
        return ResolveChatOutputTag(self, renderedPage, tagContent, options.PreserveRaidTargetTags)
    end)

    return StripChatOutputColors(output)
end

--- Renders a page into chat-ready plain output.
-- Applies variable rendering, tag substitution, and custom color stripping.
-- Page-authored UI escape sequences are removed before tag resolution, so
-- links produced by tags such as `{spell}` remain intact while remote-authored
-- escapes can never reach `SendChatMessage`. Named raid targets become
-- Blizzard's native `{rt1}` through `{rt8}` chat tokens so the game renders
-- their icons.
-- @tparam[opt] table page Page object.
-- @tparam[opt=false] boolean useActiveDisplayContext Render the exact active v3 snapshot.
-- @treturn string output Chat-ready text.
function AngryEra:RenderPageForChatOutput(page, useActiveDisplayContext)
    return RenderPageOutput(self, page, {
        UseActiveDisplayContext = useActiveDisplayContext,
        SanitizeUiEscapes = true,
    })
end

local MAX_CHAT_MESSAGE_BYTES = 255

local function IsUtf8ContinuationByte(byte)
    return byte ~= nil and byte >= 128 and byte < 192
end

--- Appends one rendered line to the send queue in chat-sized chunks.
-- `SendChatMessage` cannot deliver more than 255 bytes, so longer lines wrap
-- at the last space inside the limit, falling back to a hard split that never
-- lands inside a UTF-8 sequence.
local function AppendWrappedChatOutputLines(queue, line)
    while #line > MAX_CHAT_MESSAGE_BYTES do
        local head = line:sub(1, MAX_CHAT_MESSAGE_BYTES + 1)
        local afterSpace = head:match("^.* ()")
        if afterSpace and afterSpace > 2 then
            table.insert(queue, line:sub(1, afterSpace - 2))
            line = line:sub(afterSpace)
        else
            local cut = MAX_CHAT_MESSAGE_BYTES
            while cut > 1 and IsUtf8ContinuationByte(line:byte(cut + 1)) do
                cut = cut - 1
            end
            table.insert(queue, line:sub(1, cut))
            line = line:sub(cut + 1)
        end
    end
    if line ~= "" then
        table.insert(queue, line)
    end
end

--- Outputs rendered page content to current group chat channel.
-- Lines longer than the chat limit are wrapped at word boundaries before
-- queueing so no part of an assignment is silently dropped.
-- @tparam[opt] number id Page id, defaults to currently displayed id.
function AngryEra:OutputDisplayed(id)
    if type(self.CanLocalPlayerOutput) ~= "function" or not self:CanLocalPlayerOutput() then
        self:Print(RED_FONT_COLOR_CODE .. "You don't have permission to output a page.|r")
        return
    end

    local useActiveDisplayContext = id == nil
    if useActiveDisplayContext then
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
        local output = self:RenderPageForChatOutput(page, useActiveDisplayContext)

        -- If an output is already running, cancel it so we don't overlap spam
        if self.outputTimer then
            self:CancelTimer(self.outputTimer)
            self.outputTimer = nil
        end

        local queue = {}
        for line in (output .. "\n"):gmatch("([^\n]*)\n") do
            if line ~= "" then
                AppendWrappedChatOutputLines(queue, line)
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
-- Raid-target tokens retain their descriptive source spelling for pasting into
-- Discord or documents; every other template/tag transformation matches chat.
-- @tparam[opt] table page Page object.
-- @treturn string output Posting-ready text.
function AngryEra:ProcessPageForOutput(page)
    return RenderPageOutput(self, page, {
        PreserveRaidTargetTags = true,
    })
end
