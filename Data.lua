-------------------------------------------------------------------------------
-- Angry Era: Data.lua
--
-- Static data definitions, including:
-- 1. Class and Role Color tables.
-- 2. Icon Texture mapping ({icon} -> |T...|t).
-- 3. Raid Utility Shortcuts (e.g. {Sunder}, {LIP}).
-------------------------------------------------------------------------------

local appName, app = ...

-----------------------
-- Color Table
-----------------------
app.ColorTable = {
    ["|cblue"]        = "|cff00cbf4",
    ["|cdeathknight"] = "|cffc41f3b",
    ["|cdemonhunter"] = "|cffa330c9",
    ["|cdh"]          = "|cffa330c9",
    ["|cdk"]          = "|cffc41f3b",
    ["|cdruid"]       = "|cffff7d0a",
    ["|cevoker"]      = "|cff33937f",
    ["|cgreen"]       = "|cff0adc00",
    ["|chunter"]      = "|cffabd473",
    ["|cmage"]        = "|cff40C7eb",
    ["|cmonk"]        = "|cff00ff96",
    ["|corange"]      = "|cffff9d00",
    ["|cpaladin"]     = "|cfff58cba",
    ["|cpink"]        = "|cfff64c97",
    ["|cpriest"]      = "|cffffffff",
    ["|cpurple"]      = "|cffdc44eb",
    ["|cred"]         = "|cffeb310c",
    ["|crogue"]       = "|cfffff569",
    ["|cshaman"]      = "|cff0070de",
    ["|cwarlock"]     = "|cff8787ed",
    ["|cwarrior"]     = "|cffc79c6e",
    ["|cyellow"]      = "|cfffaf318"
}

-----------------------
-- Icon Table
-----------------------
app.IconTable = {
    -- Raid Targets
    ["{star}"]         = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t",
    ["{rt1}"]          = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t",
    ["{circle}"]       = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:0|t",
    ["{rt2}"]          = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:0|t",
    ["{diamond}"]      = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:0|t",
    ["{rt3}"]          = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:0|t",
    ["{triangle}"]     = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:0|t",
    ["{rt4}"]          = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:0|t",
    ["{moon}"]         = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:0|t",
    ["{rt5}"]          = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:0|t",
    ["{square}"]       = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:0|t",
    ["{rt6}"]          = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:0|t",
    ["{cross}"]        = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:0|t",
    ["{x}"]            = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:0|t",
    ["{rt7}"]          = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:0|t",
    ["{skull}"]        = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:0|t",
    ["{rt8}"]          = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:0|t",

    -- Other Icons
    ["{damage}"]       = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:22:41|t",
    ["{dps}"]          = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:22:41|t",
    ["{tank}"]         = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:0:19:22:41|t",
    ["{healer}"]       = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:1:20|t",

    -- Class Icons
    ["{deathknight}"]  = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:32:48|t",
    ["{demonhunter}"]  = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:64:48:32:48|t",
    ["{dh}"]           = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:64:48:32:48|t",
    ["{dk}"]           = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:32:48|t",
    ["{druid}"]        = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:48:64:0:16|t",
    ["{evoker}"]       = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:48:64|t",
    ["{hunter}"]       = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:16:32|t",
    ["{mage}"]         = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:0:16|t",
    ["{monk}"]         = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:32:48|t",
    ["{paladin}"]      = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:32:48|t",
    ["{priest}"]       = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:16:32|t",
    ["{rogue}"]        = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:0:16|t",
    ["{shaman}"]       = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:16:32|t",
    ["{warlock}"]      = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:48:64:16:32|t",
    ["{warrior}"]      = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:0:16|t",

    -- Faction Icons
    ["{alliance}"]     = "|TInterface\\Icons\\INV_BannerPVP_02:0|t",
    ["{horde}"]        = "|TInterface\\Icons\\INV_BannerPVP_01:0|t",

    -- Boss Icons
    ["{4hm}"]          = "|TInterface\\Icons\\INV_Helmet_09:0|t",
    ["{archi}"]        = "|TInterface\\Icons\\Spell_Shadow_DeathCoil:0|t",
    ["{cthun}"]        = "|TInterface\\Icons\\INV_Misc_Eye_01:0|t",
    ["{gruul}"]        = "|TInterface\\Icons\\INV_Misc_MonsterHead_04:0|t", -- Scaled
    ["{hakkar}"]       = "|TInterface\\Icons\\INV_Misc_Head_Dragon_02:0|t",
    ["{illidan}"]      = "|TInterface\\Icons\\INV_Weapon_Glaive_01:0|t",
    ["{kael}"]         = "|TInterface\\Icons\\Spell_Fire_Burnout:0|t",
    ["{kj}"]           = "|TInterface\\Icons\\INV_Misc_Head_Demon_02:0|t",
    ["{kt}"]           = "|TInterface\\Icons\\INV_Lich_Phylactery:0|t",
    ["{mag}"]          = "|TInterface\\Icons\\INV_Misc_MonsterHead_03:0|t",
    ["{nef}"]          = "|TInterface\\Icons\\INV_Misc_Head_Dragon_Black:0|t",
    ["{ony}"]          = "|TInterface\\Icons\\INV_Misc_Head_Dragon_01:0|t",
    ["{patch}"]        = "|TInterface\\Icons\\INV_Misc_MonsterHead_04:0|t", -- Abom
    ["{rag}"]          = "|TInterface\\Icons\\INV_Hammer_Unique_Sulfuras:0|t",
    ["{sapph}"]        = "|TInterface\\Icons\\INV_Misc_Head_Dragon_Blue:0|t",
    ["{twins}"]        = "|TInterface\\Icons\\INV_Misc_QirajiCrystal_01:0|t",
    ["{vashj}"]        = "|TInterface\\Icons\\INV_Misc_Head_Naga_01:0|t",
    
    -- Directional Icons
    ["{left}"]         = "|TInterface\\Buttons\\UI-SpellbookIcon-PrevPage-Up:16:16:0:0:32:32:5:27:5:27|t",
    ["{right}"]        = "|TInterface\\Buttons\\UI-SpellbookIcon-NextPage-Up:16:16:0:0:32:32:5:27:5:27|t",
    ["{up}"]           = "|TInterface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up:16:16:0:0:32:32:5:27:5:27|t",
    ["{down}"]         = "|TInterface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up:16:16:0:0:32:32:5:27:5:27|t",
    ["{+}"]            = "|TInterface\\Icons\\Spell_ChargePositive:0|t",
    ["{-}"]            = "|TInterface\\Icons\\Spell_ChargeNegative:0|t",
    ["{positive}"]     = "|TInterface\\Icons\\Spell_ChargePositive:0|t",
    ["{negative}"]     = "|TInterface\\Icons\\Spell_ChargeNegative:0|t"
}

-----------------------
-- Raid Utility
-----------------------
local AngryEra_RaidUtility = {
    ["Consumables"] = {
        ["FAP"] = {
            ["name"] = "Free Action Potion",
            ["icon"] = "inv_potion_04"
        },
        ["Holy Water"] = {
            ["name"] = "Stratholme Holy Water",
            ["icon"] = "inv_potion_75"
        },
        ["LIP"] = {
            ["name"] = "Limited Invulnerability Potion",
            ["icon"] = "inv_potion_62"
        },
        ["Petri"] = {
            ["name"] = "Flask of Petrification",
            ["icon"] = "inv_potion_26"
        },
        ["Stone"] = {
            ["name"] = "Greater Stoneshield Potion",
            ["icon"] = "inv_potion_69"
        }
    },
    ["Druid"] = {
        ["Abolish"] = {
            ["name"] = "Abolish Poison",
            ["icon"] = "spell_nature_nullifypoison_02"
        },
        ["Bark"] = {
            ["name"] = "Barkskin",
            ["icon"] = "spell_nature_stoneclawtotem"
        },
        ["BR"] = {
            ["name"] = "Rebirth",
            ["icon"] = "spell_nature_reincarnation"
        },
        ["FF"] = {
            ["name"] = "Faerie Fire",
            ["icon"] = "spell_nature_faeriefire"
        },
        ["GOTW"] = {
            ["name"] = "Gift of the Wild",
            ["icon"] = "spell_nature_regeneration"
        },
        ["Innerv"] = {
            ["name"] = "Innervate",
            ["icon"] = "spell_nature_lightning"
        },
        ["Rejuv"] = {
            ["name"] = "Rejuvenation",
            ["icon"] = "spell_nature_rejuvenation"
        },
        ["Remove"] = {
            ["name"] = "Remove Curse",
            ["icon"] = "spell_nature_removecurse"
        },
        ["Thorns"] = {
            ["name"] = "Thorns",
            ["icon"] = "spell_nature_thorns"
        }
    },
    ["Hunter"] = {
        ["Mark"] = {
            ["name"] = "Hunter's Mark",
            ["icon"] = "ability_hunter_snipershot"
        },
        ["Tranq"] = {
            ["name"] = "Tranquilizing Shot",
            ["icon"] = "spell_nature_drowsy"
        },
        ["Trap"] = {
            ["name"] = "Freezing Trap",
            ["icon"] = "spell_frost_freezingtrap"
        }
    },
    ["Mage"] = {
        ["AI"] = {
            ["name"] = "Arcane Intellect",
            ["icon"] = "spell_holy_magicalsentry"
        },
        ["Amplify"] = {
            ["name"] = "Amplify Magic",
            ["icon"] = "spell_holy_flashheal"
        },
        ["Block"] = {
            ["name"] = "Ice Block",
            ["icon"] = "spell_frost_frost"
        },
        ["CS"] = {
            ["name"] = "Counterspell",
            ["icon"] = "spell_frost_iceshock"
        },
        ["Dampen"] = {
            ["name"] = "Dampen Magic",
            ["icon"] = "spell_nature_abolishmagic"
        },
        ["Decurse"] = {
            ["name"] = "Remove Lesser Curse",
            ["icon"] = "spell_nature_removecurse"
        },
        ["Sheep"] = {
            ["name"] = "Polymorph",
            ["icon"] = "spell_nature_polymorph"
        }
    },
    ["Paladin"] = {
        ["BoF"] = {
            ["name"] = "Blessing of Freedom",
            ["icon"] = "spell_holy_sealofvalor"
        },
        ["BoK"] = {
            ["name"] = "Greater Blessing of Kings",
            ["icon"] = "spell_magic_greaterblessingofkings"
        },
        ["BoL"] = {
            ["name"] = "Greater Blessing of Light",
            ["icon"] = "spell_holy_greaterblessingoflight"
        },
        ["BoP"] = {
            ["name"] = "Blessing of Protection",
            ["icon"] = "spell_holy_sealofprotection"
        },
        ["BoW"] = {
            ["name"] = "Greater Blessing of Wisdom",
            ["icon"] = "spell_holy_greaterblessingofwisdom"
        },
        ["Cleanse"] = {
            ["name"] = "Cleanse",
            ["icon"] = "spell_holy_purify"
        },
        ["DI"] = {
            ["name"] = "Divine Intervention",
            ["icon"] = "spell_nature_timestop"
        },
        ["DS"] = {
            ["name"] = "Divine Shield",
            ["icon"] = "spell_holy_divineshield"
        },
        ["JoJ"] = {
            ["name"] = "Judgement of Justice",
            ["icon"] = "spell_holy_sealofwrath"
        },
        ["JoL"] = {
            ["name"] = "Judgement of Light",
            ["icon"] = "spell_holy_healingaura"
        },
        ["JoW"] = {
            ["name"] = "Judgement of Wisdom",
            ["icon"] = "spell_holy_righteousnessaura"
        },
        ["LoH"] = {
            ["name"] = "Lay on Hands",
            ["icon"] = "spell_holy_layonhands"
        },
        ["Sac"] = {
            ["name"] = "Blessing of Sacrifice",
            ["icon"] = "spell_holy_sealofsacrifice"
        },
        ["Salv"] = {
            ["name"] = "Greater Blessing of Salvation",
            ["icon"] = "spell_holy_greaterblessingofsalvation"
        },
        ["Sanc"] = {
            ["name"] = "Greater Blessing of Sanctuary",
            ["icon"] = "spell_holy_greaterblessingofsanctuary"
        }
    },
    ["Priest"] = {
        ["Dispel"] = {
            ["name"] = "Dispel Magic",
            ["icon"] = "spell_holy_dispelmagic"
        },
        ["Fade"] = {
            ["name"] = "Fade",
            ["icon"] = "spell_magic_lesserinvisibility"
        },
        ["Fort"] = {
            ["name"] = "Power Word: Fortitude",
            ["icon"] = "spell_holy_wordfortitude"
        },
        ["FW"] = {
            ["name"] = "Fear Ward",
            ["icon"] = "spell_holy_fearward"
        },
        ["MC"] = {
            ["name"] = "Mind Control",
            ["icon"] = "spell_shadow_shadowworddominate"
        },
        ["PI"] = {
            ["name"] = "Power Infusion",
            ["icon"] = "spell_holy_powerinfusion"
        },
        ["PW:S"] = {
            ["name"] = "Power Word: Shield",
            ["icon"] = "spell_holy_powerwordshield"
        },
        ["Renew"] = {
            ["name"] = "Renew",
            ["icon"] = "spell_holy_renew"
        },
        ["Shackle"] = {
            ["name"] = "Shackle Undead",
            ["icon"] = "spell_nature_slow"
        },
        ["Shadow"] = {
            ["name"] = "Shadow Protection",
            ["icon"] = "spell_shadow_antishadow"
        },
        ["Spirit"] = {
            ["name"] = "Divine Spirit",
            ["icon"] = "spell_holy_divinespirit"
        }
    },
    ["Rogue"] = {
        ["Blind"] = {
            ["name"] = "Blind",
            ["icon"] = "spell_shadow_mindsteal"
        },
        ["Feint"] = {
            ["name"] = "Feint",
            ["icon"] = "ability_rogue_feint"
        },
        ["Kick"] = {
            ["name"] = "Kick",
            ["icon"] = "ability_kick"
        }
    },
    ["Shaman"] = {
        ["BL"] = {
            ["name"] = "Bloodlust",
            ["icon"] = "spell_nature_bloodlust"
        },
        ["ES"] = {
            ["name"] = "Earth Shock",
            ["icon"] = "spell_nature_earthshock"
        },
        ["Hero"] = {
            ["name"] = "Heroism",
            ["icon"] = "ability_shaman_heroism"
        },
        ["Tremor"] = {
            ["name"] = "Tremor Totem",
            ["icon"] = "spell_nature_tremortotem"
        },
        ["WF"] = {
            ["name"] = "Windfury Totem",
            ["icon"] = "spell_nature_windfury"
        }
    },
    ["Warlock"] = {
        ["Banish"] = {
            ["name"] = "Banish",
            ["icon"] = "spell_shadow_banish"
        },
        ["CoE"] = {
            ["name"] = "Curse of Elements",
            ["icon"] = "spell_shadow_chilltouch"
        },
        ["CoR"] = {
            ["name"] = "Curse of Recklessness",
            ["icon"] = "spell_shadow_unholystrength"
        },
        ["CoS"] = {
            ["name"] = "Curse of Shadow",
            ["icon"] = "spell_shadow_curseofachimonde"
        },
        ["HS"] = {
            ["name"] = "Healthstone",
            ["icon"] = "inv_stone_04"
        },
        ["SS"] = {
            ["name"] = "Soulstone",
            ["icon"] = "spell_shadow_soulgem"
        }
    },
    ["Warrior"] = {
        ["AoE"] = {
            ["name"] = "Challenging Shout",
            ["icon"] = "ability_bullrush" -- This is the AoE Taunt
        },
        ["Demo"] = {
            ["name"] = "Demoralizing Shout",
            ["icon"] = "ability_warrior_waracry"
        },
        ["LS"] = {
            ["name"] = "Last Stand",
            ["icon"] = "spell_holy_ashestoashes"
        },
        ["Mock"] = {
            ["name"] = "Mocking Blow",
            ["icon"] = "ability_kick"
        },
        ["Pummel"] = {
            ["name"] = "Pummel",
            ["icon"] = "inv_gauntlets_04"
        },
        ["Shout"] = {
            ["name"] = "Challenging Shout",
            ["icon"] = "ability_bullrush" -- This is the AoE Taunt
        },
        ["Sunder"] = {
            ["name"] = "Sunder Armor",
            ["icon"] = "ability_warrior_sunder"
        },
        ["SW"] = {
            ["name"] = "Shield Wall",
            ["icon"] = "ability_warrior_shieldwall"
        },
        ["Taunt"] = {
            ["name"] = "Taunt",
            ["icon"] = "spell_nature_reincarnation"
        },
        ["Thunder"] = {
            ["name"] = "Thunder Clap",
            ["icon"] = "spell_nature_thunderclap"
        }
    }
}

local isTBC = select(4, GetBuildInfo()) >= 20000

if isTBC then
    -- Warrior
    AngryEra_RaidUtility.Warrior.Reflect = { ["name"] = "Spell Reflection", ["icon"] = "ability_warrior_shieldreflection" }
    
    -- Priest
    AngryEra_RaidUtility.Priest.MDS = { ["name"] = "Mass Dispel", ["icon"] = "spell_arcane_massdispel" }

    -- Warlock
    AngryEra_RaidUtility.Warlock.Seed = { ["name"] = "Seed of Corruption", ["icon"] = "spell_shadow_seedofdestruction" }

    -- Hunter
    AngryEra_RaidUtility.Hunter.MD = { ["name"] = "Misdirection", ["icon"] = "ability_hunter_misdirection" }

    -- Rogue
    AngryEra_RaidUtility.Rogue.Cloak = { ["name"] = "Cloak of Shadows", ["icon"] = "spell_shadow_nethercloak" }
    
    -- Shaman (Bloodlust/Heroism are TBC+, usually)
    -- Leaving BL/Hero in main table for now as they are often used in generic macros, but could move here.
end

app.UtilityChatMap = {}
app.UtilityChatData = {}
for category, items in pairs(AngryEra_RaidUtility) do
    for key, info in pairs(items) do
        local iconTexture = "|TInterface\\Icons\\" .. info.icon .. ":0|t"

        -- Register abbreviation (e.g. {sw})
        local tag = "{" .. key:lower() .. "}"
        app.IconTable[tag] = iconTexture
        app.UtilityChatMap[tag] = info.name
        app.UtilityChatData[tag] = { name = info.name, key = key }

        -- Register full name (e.g. {shield wall})
        local nameTag = "{" .. info.name:lower() .. "}"
        app.IconTable[nameTag] = iconTexture
        app.UtilityChatMap[nameTag] = info.name
        app.UtilityChatData[nameTag] = { name = info.name, key = key }
    end
end
-------------------------------------------------------------------------------
-- JSON Utility
-------------------------------------------------------------------------------

local function scan(str, pos)
	local char = str:sub(pos, pos)
	if char == "{" then return "object", pos, "}" end
	if char == "[" then return "array", pos, "]" end
	if (char >= "0" and char <= "9") or char == "-" then return "number", pos end
	if char == '"' then return "string", pos end
	if str:sub(pos, pos+3) == "true" then return "boolean", pos, true end
	if str:sub(pos, pos+4) == "false" then return "boolean", pos, false end
	if str:sub(pos, pos+3) == "null" then return "null", pos, nil end
	return nil, pos, "Syntax Error"
end

local function skip_ws(str, pos)
	while true do
        local c = str:sub(pos, pos)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            pos = pos + 1
        else
            break
        end
    end
	return pos
end

local function parse_string(str, pos)
	local s = pos
	while true do
		local next_quote = str:find('"', s + 1)
		if not next_quote then return nil, pos, "Unterminated String" end
		-- Check escapes
		local escaped = 0
		local p = next_quote - 1
		while str:sub(p, p) == "\\" do
			escaped = escaped + 1
			p = p - 1
		end
		if escaped % 2 == 0 then
			return str:sub(pos+1, next_quote-1), next_quote + 1
		end
		s = next_quote
	end
end

local function parse_number(str, pos)
	local _, end_pos = str:find("^[%-%d%.eE]+", pos)
	if not end_pos then return nil, pos, "Invalid Number" end
	return tonumber(str:sub(pos, end_pos)), end_pos + 1
end

local function parse_object(str, pos)
	local obj = {}
	pos = skip_ws(str, pos + 1)
	if str:sub(pos, pos) == "}" then return obj, pos + 1 end
    
    local key, val
	while true do
		if str:sub(pos, pos) ~= '"' then return nil, pos, "Expected String Key" end
		key, pos = parse_string(str, pos)
        
		pos = skip_ws(str, pos)
		if str:sub(pos, pos) ~= ":" then return nil, pos, "Expected ':'" end
		pos = skip_ws(str, pos + 1)
        
        -- Parse Value (Recursive call needs helper or forward declare)
        -- We'll inline logic or use forward declare
        -- Since parse_value isn't defined yet, we define it inside or forward declare.
        -- Let's put parsing logic in app namespace.
        return nil, pos, "Not Implemented Recusion" 
	end
end

-- Proper recursive implementation
local parse_value

local function parse_array(str, pos)
	local arr = {}
	pos = skip_ws(str, pos + 1)
	if str:sub(pos, pos) == "]" then return arr, pos + 1 end
	
    local val
	while true do
		val, pos = parse_value(str, pos)
		if not val and pos then return nil, pos, "Error in Array" end
		table.insert(arr, val)
		pos = skip_ws(str, pos)
		if str:sub(pos, pos) == "]" then return arr, pos + 1 end
		if str:sub(pos, pos) ~= "," then return nil, pos, "Expected ',' or ']'" end
		pos = skip_ws(str, pos + 1)
	end
end

local function parse_obj_impl(str, pos)
	local obj = {}
	pos = skip_ws(str, pos + 1)
	if str:sub(pos, pos) == "}" then return obj, pos + 1 end
	
    local key, val
	while true do
		if str:sub(pos, pos) ~= '"' then return nil, pos, "Expected String Key" end
		key, pos = parse_string(str, pos)
		pos = skip_ws(str, pos)
		if str:sub(pos, pos) ~= ":" then return nil, pos, "Expected ':'" end
		pos = skip_ws(str, pos + 1)
		
		val, pos = parse_value(str, pos)
		if not val and pos then return nil, pos, "Error in Object Value" end
		obj[key] = val
		
		pos = skip_ws(str, pos)
		if str:sub(pos, pos) == "}" then return obj, pos + 1 end
		if str:sub(pos, pos) ~= "," then return nil, pos, "Expected ',' or '}'" end
		pos = skip_ws(str, pos + 1)
	end
end

parse_value = function(str, pos)
	pos = skip_ws(str, pos)
	local char = str:sub(pos, pos)
	if char == "{" then return parse_obj_impl(str, pos) end
	if char == "[" then return parse_array(str, pos) end
	if char == '"' then return parse_string(str, pos) end
	if (char >= "0" and char <= "9") or char == "-" then return parse_number(str, pos) end
	if str:sub(pos, pos+3) == "true" then return true, pos + 4 end
	if str:sub(pos, pos+4) == "false" then return false, pos + 5 end
	if str:sub(pos, pos+3) == "null" then return nil, pos + 4 end
	return nil, pos, "Syntax Error"
end

function app.JSON_Decode(str)
    if not str or str == "" then return {} end
    local success, res, pos, err = pcall(function() 
        local v, p, e = parse_value(str, 1)
        return v, p, e
    end)
    if success and res then return res end
    return {}
end

function app.ParseVariables(str)
    if not str or str == "" then return {} end
    
    -- Check for JSON
    if str:find("^%s*[{[]") then
        return app.JSON_Decode(str)
    end
    
    -- Key=Value pairs
    local obj = {}
    for line in str:gmatch("[^\r\n]+") do
        local key, val = line:match("^([^=]+)=(.*)")
        if key then
            -- Trim
            key = key:match("^%s*(.-)%s*$")
            val = val:match("^%s*(.-)%s*$")
            if key ~= "" then
                obj[key] = val
                -- Construct number if possible? 
                -- User request "key=value". JSON values are usually typed.
                -- If val is "123", treats as string "123" or number?
                -- Mustache is loose typing usually. But number vs string matters for math.
                -- Let's try to convert to number if possible.
                local n = tonumber(val)
                if n then obj[key] = n end
                -- Convert "true"/"false"?
                if val == "true" then obj[key] = true
                elseif val == "false" then obj[key] = false end
            end
        end
    end
    return obj
end
