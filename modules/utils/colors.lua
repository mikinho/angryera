-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/colors.lua
--
-- Color constants and conversion helpers.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.colors = {}
local colors = AngryEra.utils.colors

colors.ColorTable = {
    ["|cblue"] = "|cff00cbf4",
    ["|cdeathknight"] = "|cffc41f3b",
    ["|cdemonhunter"] = "|cffa330c9",
    ["|cdh"] = "|cffa330c9",
    ["|cdk"] = "|cffc41f3b",
    ["|cdruid"] = "|cffff7d0a",
    ["|cevoker"] = "|cff33937f",
    ["|cgreen"] = "|cff0adc00",
    ["|chunter"] = "|cffabd473",
    ["|cmage"] = "|cff40C7eb",
    ["|cmonk"] = "|cff00ff96",
    ["|corange"] = "|cffff9d00",
    ["|cpaladin"] = "|cfff58cba",
    ["|cpink"] = "|cfff64c97",
    ["|cpriest"] = "|cffffffff",
    ["|cpurple"] = "|cffdc44eb",
    ["|cred"] = "|cffeb310c",
    ["|crogue"] = "|cfffff569",
    ["|cshaman"] = "|cff0070de",
    ["|cwarlock"] = "|cff8787ed",
    ["|cwarrior"] = "|cffc79c6e",
    ["|cyellow"] = "|cfffaf318",
}

function colors.RGBToHex(r, g, b, a)
    r = math.ceil(255 * r)
    g = math.ceil(255 * g)
    b = math.ceil(255 * b)
    if a == nil then
        return string.format("%02x%02x%02x", r, g, b)
    else
        a = math.ceil(255 * a)
        return string.format("%02x%02x%02x%02x", r, g, b, a)
    end
end

function colors.HexToRGB(hex)
    if string.len(hex) == 8 then
        return tonumber("0x" .. hex:sub(1, 2)) / 255,
            tonumber("0x" .. hex:sub(3, 4)) / 255,
            tonumber("0x" .. hex:sub(5, 6)) / 255,
            tonumber("0x" .. hex:sub(7, 8)) / 255
    else
        return tonumber("0x" .. hex:sub(1, 2)) / 255,
            tonumber("0x" .. hex:sub(3, 4)) / 255,
            tonumber("0x" .. hex:sub(5, 6)) / 255
    end
end
