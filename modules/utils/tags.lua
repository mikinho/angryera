-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/tags.lua
--
-- Raid utility tag reference data and tag processing.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.tags = {}
local tags = AngryEra.utils.tags

-- -----------------------
-- Raid Utility
-- -----------------------
local AngryEra_RaidUtility = {
	["Targeting"] = {
		["Star"] = {
			["name"] = "{rt1}",
			["icon"] = "UI-RaidTargetingIcon_1",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["rt1"] = {
			["name"] = "{rt1}",
			["icon"] = "UI-RaidTargetingIcon_1",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["Circle"] = {
			["name"] = "{rt2}",
			["icon"] = "UI-RaidTargetingIcon_2",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["rt2"] = {
			["name"] = "{rt2}",
			["icon"] = "UI-RaidTargetingIcon_2",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["Diamond"] = {
			["name"] = "{rt3}",
			["icon"] = "UI-RaidTargetingIcon_3",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["rt3"] = {
			["name"] = "{rt3}",
			["icon"] = "UI-RaidTargetingIcon_3",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["Triangle"] = {
			["name"] = "{rt4}",
			["icon"] = "UI-RaidTargetingIcon_4",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["rt4"] = {
			["name"] = "{rt4}",
			["icon"] = "UI-RaidTargetingIcon_4",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["Moon"] = {
			["name"] = "{rt5}",
			["icon"] = "UI-RaidTargetingIcon_5",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["rt5"] = {
			["name"] = "{rt5}",
			["icon"] = "UI-RaidTargetingIcon_5",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["Square"] = {
			["name"] = "{rt6}",
			["icon"] = "UI-RaidTargetingIcon_6",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["rt6"] = {
			["name"] = "{rt6}",
			["icon"] = "UI-RaidTargetingIcon_6",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["Cross"] = {
			["name"] = "{rt7}",
			["icon"] = "UI-RaidTargetingIcon_7",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["x"] = {
			["name"] = "{rt7}",
			["icon"] = "UI-RaidTargetingIcon_7",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["rt7"] = {
			["name"] = "{rt7}",
			["icon"] = "UI-RaidTargetingIcon_7",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["Skull"] = {
			["name"] = "{rt8}",
			["icon"] = "UI-RaidTargetingIcon_8",
			["path"] = "Interface\\TargetingFrame\\"
		},
		["rt8"] = {
			["name"] = "{rt8}",
			["icon"] = "UI-RaidTargetingIcon_8",
			["path"] = "Interface\\TargetingFrame\\"
		}
	},
	["Factions"] = {
		["alliance"] = {
			["name"] = "Alliance",
			["icon"] = "INV_BannerPVP_02"
		},
		["horde"] = {
			["name"] = "Horde",
			["icon"] = "INV_BannerPVP_01"
		}
	},
	["General"] = {
		["healthstone"] = {
			["name"] = "Healthstone",
			["icon"] = "inv_stone_04"
		},
		["hs"] = {
			["name"] = "Healthstone",
			["icon"] = "inv_stone_04"
		},
		["damage"] = {
			["name"] = "Damage",
			["icon"] = "UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:22:41",
			["path"] = "Interface\\LFGFrame\\"
		},
		["dps"] = {
			["name"] = "Damage",
			["icon"] = "UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:22:41",
			["path"] = "Interface\\LFGFrame\\"
		},
		["tank"] = {
			["name"] = "Tanks",
			["icon"] = "UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:0:19:22:41",
			["path"] = "Interface\\LFGFrame\\"
		},
		["healer"] = {
			["name"] = "Healers",
			["icon"] = "UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:1:20",
			["path"] = "Interface\\LFGFrame\\"
		},
		["bloodlust"] = {
			["name"] = "Bloodlust",
			["icon"] = "spell_nature_bloodlust"
		},
		["bl"] = {
			["name"] = "Bloodlust",
			["icon"] = "spell_nature_bloodlust"
		},
		["hero"] = {
			["name"] = "Heroism",
			["icon"] = "ability_shaman_heroism"
		},
		["heroism"] = {
			["name"] = "Heroism",
			["icon"] = "ability_shaman_heroism"
		},
		["stun"] = {
			["name"] = "Stun",
			["icon"] = "spell_frost_stun"
		},
		["frost"] = {
			["name"] = "Frost",
			["icon"] = "spell_frost_frostbolt02"
		},
		["engineer"] = {
			["name"] = "Engineer",
			["icon"] = "trade_engineering"
		}
	},
	["Classes"] = {
		["deathknight"] = {
			["name"] = "Death Knight",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:32:48|t"
		},
		["dk"] = {
			["name"] = "Death Knight",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:32:48|t"
		},
		["demonhunter"] = {
			["name"] = "Demon Hunter",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:64:48:32:48|t"
		},
		["dh"] = {
			["name"] = "Demon Hunter",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:64:48:32:48|t"
		},
		["druid"] = {
			["name"] = "Druid",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:48:64:0:16|t"
		},
		["evoker"] = {
			["name"] = "Evoker",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:48:64|t"
		},
		["hunter"] = {
			["name"] = "Hunter",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:16:32|t"
		},
		["mage"] = {
			["name"] = "Mage",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:0:16|t"
		},
		["monk"] = {
			["name"] = "Monk",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:32:48|t"
		},
		["paladin"] = {
			["name"] = "Paladin",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:32:48|t"
		},
		["priest"] = {
			["name"] = "Priest",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:16:32|t"
		},
		["rogue"] = {
			["name"] = "Rogue",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:0:16|t"
		},
		["shaman"] = {
			["name"] = "Shaman",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:16:32|t"
		},
		["warlock"] = {
			["name"] = "Warlock",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:48:64:16:32|t"
		},
		["warrior"] = {
			["name"] = "Warrior",
			["texture"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:0:16|t"
		}
	},
	["Bosses"] = {
		["4hm"] = { ["name"] = "4 Horsemen", ["texture"] = "|TInterface\\Icons\\INV_Helmet_09:0|t" },
		["archi"] = { ["name"] = "Archimonde", ["texture"] = "|TInterface\\Icons\\Spell_Shadow_DeathCoil:0|t" },
		["cthun"] = { ["name"] = "C'Thun", ["texture"] = "|TInterface\\Icons\\INV_Misc_Eye_01:0|t" },
		["gruul"] = { ["name"] = "Gruul", ["texture"] = "|TInterface\\Icons\\INV_Misc_MonsterHead_04:0|t" },
		["hakkar"] = { ["name"] = "Hakkar", ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Dragon_02:0|t" },
		["illidan"] = { ["name"] = "Illidan", ["texture"] = "|TInterface\\Icons\\INV_Weapon_Glaive_01:0|t" },
		["kael"] = { ["name"] = "Kael'thas", ["texture"] = "|TInterface\\Icons\\Spell_Fire_Burnout:0|t" },
		["kj"] = { ["name"] = "Kil'jaeden", ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Demon_02:0|t" },
		["kt"] = { ["name"] = "Kel'thuzad", ["texture"] = "|TInterface\\Icons\\INV_Lich_Phylactery:0|t" },
		["mag"] = { ["name"] = "Magtheridon", ["texture"] = "|TInterface\\Icons\\INV_Misc_MonsterHead_03:0|t" },
		["nef"] = { ["name"] = "Nefarian", ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Dragon_Black:0|t" },
		["ony"] = { ["name"] = "Onyxia", ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Dragon_01:0|t" },
		["patch"] = { ["name"] = "Patchwerk", ["texture"] = "|TInterface\\Icons\\INV_Misc_MonsterHead_04:0|t" },
		["rag"] = { ["name"] = "Ragnaros", ["texture"] = "|TInterface\\Icons\\INV_Hammer_Unique_Sulfuras:0|t" },
		["sapph"] = { ["name"] = "Sapphiron", ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Dragon_Blue:0|t" },
		["twins"] = { ["name"] = "Twin Emperors", ["texture"] = "|TInterface\\Icons\\INV_Misc_QirajiCrystal_01:0|t" },
		["vashj"] = { ["name"] = "Lady Vashj", ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Naga_01:0|t" }
	},
	["Directional"] = {
		["left"] = { ["name"] = "Left", ["texture"] = "|TInterface\\Buttons\\UI-SpellbookIcon-PrevPage-Up:16:16:0:0:32:32:5:27:5:27|t" },
		["right"] = { ["name"] = "Right", ["texture"] = "|TInterface\\Buttons\\UI-SpellbookIcon-NextPage-Up:16:16:0:0:32:32:5:27:5:27|t" },
		["up"] = { ["name"] = "Up", ["texture"] = "|TInterface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up:16:16:0:0:32:32:5:27:5:27|t" },
		["down"] = { ["name"] = "Down", ["texture"] = "|TInterface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up:16:16:0:0:32:32:5:27:5:27|t" },
		["+"] = { ["name"] = "Positive", ["texture"] = "|TInterface\\Icons\\Spell_ChargePositive:0|t" },
		["-"] = { ["name"] = "Negative", ["texture"] = "|TInterface\\Icons\\Spell_ChargeNegative:0|t" },
		["positive"] = { ["name"] = "Positive", ["texture"] = "|TInterface\\Icons\\Spell_ChargePositive:0|t" },
		["negative"] = { ["name"] = "Negative", ["texture"] = "|TInterface\\Icons\\Spell_ChargeNegative:0|t" }
	},
	["Consumables"] = {
		["FAP"] = { ["name"] = "Free Action Potion", ["icon"] = "inv_potion_04" },
		["Holy Water"] = { ["name"] = "Stratholme Holy Water", ["icon"] = "inv_potion_75" },
		["LIP"] = { ["name"] = "Limited Invulnerability Potion", ["icon"] = "inv_potion_62" },
		["Petri"] = { ["name"] = "Flask of Petrification", ["icon"] = "inv_potion_26" },
		["Stone"] = { ["name"] = "Greater Stoneshield Potion", ["icon"] = "inv_potion_69" }
	},
	["Druid"] = {
		["Abolish"] = { ["name"] = "Abolish Poison", ["icon"] = "spell_nature_nullifypoison_02" },
		["Bark"] = { ["name"] = "Barkskin", ["icon"] = "spell_nature_stoneclawtotem" },
		["BR"] = { ["name"] = "Rebirth", ["icon"] = "spell_nature_reincarnation" },
		["FF"] = { ["name"] = "Faerie Fire", ["icon"] = "spell_nature_faeriefire" },
		["GOTW"] = { ["name"] = "Gift of the Wild", ["icon"] = "spell_nature_regeneration" },
		["Innerv"] = { ["name"] = "Innervate", ["icon"] = "spell_nature_lightning" },
		["Rejuv"] = { ["name"] = "Rejuvenation", ["icon"] = "spell_nature_rejuvenation" },
		["Remove"] = { ["name"] = "Remove Curse", ["icon"] = "spell_nature_removecurse" },
		["Thorns"] = { ["name"] = "Thorns", ["icon"] = "spell_nature_thorns" }
	},
	["Hunter"] = {
		["Mark"] = { ["name"] = "Hunter's Mark", ["icon"] = "ability_hunter_snipershot" },
		["Tranq"] = { ["name"] = "Tranquilizing Shot", ["icon"] = "spell_nature_drowsy" },
		["Trap"] = { ["name"] = "Freezing Trap", ["icon"] = "spell_frost_freezingtrap" }
	},
	["Mage"] = {
		["AI"] = { ["name"] = "Arcane Intellect", ["icon"] = "spell_holy_magicalsentry" },
		["Amplify"] = { ["name"] = "Amplify Magic", ["icon"] = "spell_holy_flashheal" },
		["Block"] = { ["name"] = "Ice Block", ["icon"] = "spell_frost_frost" },
		["CS"] = { ["name"] = "Counterspell", ["icon"] = "spell_frost_iceshock" },
		["Dampen"] = { ["name"] = "Dampen Magic", ["icon"] = "spell_nature_abolishmagic" },
		["Decurse"] = { ["name"] = "Remove Lesser Curse", ["icon"] = "spell_nature_removecurse" },
		["Pig"] = { ["name"] = "Polymorph: Pig", ["icon"] = "spell_magic_polymorphpig" },
		["Sheep"] = { ["name"] = "Polymorph", ["icon"] = "spell_nature_polymorph" },
		["Turtle"] = { ["name"] = "Polymorph: Turtle", ["icon"] = "ability_hunter_pet_turtle" }
	},
	["Paladin"] = {
		["BoF"] = { ["name"] = "Blessing of Freedom", ["icon"] = "spell_holy_sealofvalor" },
		["BoK"] = { ["name"] = "Greater Blessing of Kings", ["icon"] = "spell_magic_greaterblessingofkings" },
		["BoL"] = { ["name"] = "Greater Blessing of Light", ["icon"] = "spell_holy_greaterblessingoflight" },
		["BoP"] = { ["name"] = "Blessing of Protection", ["icon"] = "spell_holy_sealofprotection" },
		["BoW"] = { ["name"] = "Greater Blessing of Wisdom", ["icon"] = "spell_holy_greaterblessingofwisdom" },
		["Cleanse"] = { ["name"] = "Cleanse", ["icon"] = "spell_holy_purify" },
		["DI"] = { ["name"] = "Divine Intervention", ["icon"] = "spell_nature_timestop" },
		["DS"] = { ["name"] = "Divine Shield", ["icon"] = "spell_holy_divineshield" },
		["JoJ"] = { ["name"] = "Judgement of Justice", ["icon"] = "spell_holy_sealofwrath" },
		["JoL"] = { ["name"] = "Judgement of Light", ["icon"] = "spell_holy_healingaura" },
		["JoW"] = { ["name"] = "Judgement of Wisdom", ["icon"] = "spell_holy_righteousnessaura" },
		["LoH"] = { ["name"] = "Lay on Hands", ["icon"] = "spell_holy_layonhands" },
		["Sac"] = { ["name"] = "Blessing of Sacrifice", ["icon"] = "spell_holy_sealofsacrifice" },
		["Salv"] = { ["name"] = "Greater Blessing of Salvation", ["icon"] = "spell_holy_greaterblessingofsalvation" },
		["Sanc"] = { ["name"] = "Greater Blessing of Sanctuary", ["icon"] = "spell_holy_greaterblessingofsanctuary" }
	},
	["Priest"] = {
		["Dispel"] = { ["name"] = "Dispel Magic", ["icon"] = "spell_holy_dispelmagic" },
		["Fade"] = { ["name"] = "Fade", ["icon"] = "spell_magic_lesserinvisibility" },
		["Fort"] = { ["name"] = "Power Word: Fortitude", ["icon"] = "spell_holy_wordfortitude" },
		["FW"] = { ["name"] = "Fear Ward", ["icon"] = "spell_holy_fearward" },
		["MC"] = { ["name"] = "Mind Control", ["icon"] = "spell_shadow_shadowworddominate" },
		["PI"] = { ["name"] = "Power Infusion", ["icon"] = "spell_holy_powerinfusion" },
		["PW:S"] = { ["name"] = "Power Word: Shield", ["icon"] = "spell_holy_powerwordshield" },
		["Renew"] = { ["name"] = "Renew", ["icon"] = "spell_holy_renew" },
		["Shackle"] = { ["name"] = "Shackle Undead", ["icon"] = "spell_nature_slow" },
		["Shadow"] = { ["name"] = "Shadow Protection", ["icon"] = "spell_shadow_antishadow" },
		["Spirit"] = { ["name"] = "Divine Spirit", ["icon"] = "spell_holy_divinespirit" }
	},
	["Rogue"] = {
		["Blind"] = { ["name"] = "Blind", ["icon"] = "spell_shadow_mindsteal" },
		["Cheap"] = { ["name"] = "Cheap Shot", ["icon"] = "ability_cheapshot" },
		["Feint"] = { ["name"] = "Feint", ["icon"] = "ability_rogue_feint" },
		["Kick"] = { ["name"] = "Kick", ["icon"] = "ability_kick" },
		["Kidney"] = { ["name"] = "Kidney Shot", ["icon"] = "ability_rogue_kidneyshot" }
	},
	["Shaman"] = {
		["BL"] = { ["name"] = "Bloodlust", ["icon"] = "spell_nature_bloodlust" },
		["ES"] = { ["name"] = "Earth Shock", ["icon"] = "spell_nature_earthshock" },
		["Hero"] = { ["name"] = "Heroism", ["icon"] = "ability_shaman_heroism" },
		["Tremor"] = { ["name"] = "Tremor Totem", ["icon"] = "spell_nature_tremortotem" },
		["WF"] = { ["name"] = "Windfury Totem", ["icon"] = "spell_nature_windfury" }
	},
	["Warlock"] = {
		["Banish"] = { ["name"] = "Banish", ["icon"] = "spell_shadow_banish" },
		["CoE"] = { ["name"] = "Curse of Elements", ["icon"] = "spell_shadow_chilltouch" },
		["CoR"] = { ["name"] = "Curse of Recklessness", ["icon"] = "spell_shadow_unholystrength" },
		["CoS"] = { ["name"] = "Curse of Shadow", ["icon"] = "spell_shadow_curseofachimonde" },
		["HS"] = { ["name"] = "Healthstone", ["icon"] = "inv_stone_04" },
		["SS"] = { ["name"] = "Soulstone", ["icon"] = "spell_shadow_soulgem" }
	},
	["Warrior"] = {
		["AoE"] = { ["name"] = "Challenging Shout", ["icon"] = "ability_bullrush" },
		["Demo"] = { ["name"] = "Demoralizing Shout", ["icon"] = "ability_warrior_waracry" },
		["LS"] = { ["name"] = "Last Stand", ["icon"] = "spell_holy_ashestoashes" },
		["Mock"] = { ["name"] = "Mocking Blow", ["icon"] = "ability_kick" },
		["Pummel"] = { ["name"] = "Pummel", ["icon"] = "inv_gauntlets_04" },
		["Shout"] = { ["name"] = "Challenging Shout", ["icon"] = "ability_bullrush" },
		["Sunder"] = { ["name"] = "Sunder Armor", ["icon"] = "ability_warrior_sunder" },
		["SW"] = { ["name"] = "Shield Wall", ["icon"] = "ability_warrior_shieldwall" },
		["Taunt"] = { ["name"] = "Taunt", ["icon"] = "spell_nature_reincarnation" },
		["Thunder"] = { ["name"] = "Thunder Clap", ["icon"] = "spell_nature_thunderclap" }
	}
}

local isTBC = select(4, GetBuildInfo()) >= 20000

if isTBC then
	AngryEra_RaidUtility.Warrior.Reflect = { ["name"] = "Spell Reflection", ["icon"] = "ability_warrior_shieldreflection" }
	AngryEra_RaidUtility.Priest.MDS = { ["name"] = "Mass Dispel", ["icon"] = "spell_arcane_massdispel" }
	AngryEra_RaidUtility.Warlock.Seed = { ["name"] = "Seed of Corruption", ["icon"] = "spell_shadow_seedofdestruction" }
	AngryEra_RaidUtility.Hunter.MD = { ["name"] = "Misdirection", ["icon"] = "ability_hunter_misdirection" }
	AngryEra_RaidUtility.Rogue.Cloak = { ["name"] = "Cloak of Shadows", ["icon"] = "spell_shadow_nethercloak" }
end

-- Build flattened lookup tables
tags.UtilityChatMap = {}
tags.UtilityChatData = {}
for category, items in pairs(AngryEra_RaidUtility) do
	for key, info in pairs(items) do
		local iconTexture = info.texture or ("|T" .. (info.path or "Interface\\Icons\\") .. info.icon .. ":0|t")

		local tag = "{" .. key:lower() .. "}"
		tags.UtilityChatMap[tag] = info.name
		tags.UtilityChatData[tag] = { name = info.name, key = key, texture = iconTexture }

		local nameTag = "{" .. info.name:lower() .. "}"
		tags.UtilityChatMap[nameTag] = info.name
		tags.UtilityChatData[nameTag] = { name = info.name, key = key, texture = iconTexture }
	end
end

-- ChatOutputClassMap
tags.ChatOutputClassMap = {
	["{hunter}"] = LOCALIZED_CLASS_NAMES_MALE["HUNTER"],
	["{warrior}"] = LOCALIZED_CLASS_NAMES_MALE["WARRIOR"],
	["{rogue}"] = LOCALIZED_CLASS_NAMES_MALE["ROGUE"],
	["{mage}"] = LOCALIZED_CLASS_NAMES_MALE["MAGE"],
	["{priest}"] = LOCALIZED_CLASS_NAMES_MALE["PRIEST"],
	["{warlock}"] = LOCALIZED_CLASS_NAMES_MALE["WARLOCK"],
	["{paladin}"] = LOCALIZED_CLASS_NAMES_MALE["PALADIN"],
	["{druid}"] = LOCALIZED_CLASS_NAMES_MALE["DRUID"],
	["{shaman}"] = LOCALIZED_CLASS_NAMES_MALE["SHAMAN"],
	["{dk}"] = LOCALIZED_CLASS_NAMES_MALE["DEATHKNIGHT"],
	["{deathknight}"] = LOCALIZED_CLASS_NAMES_MALE["DEATHKNIGHT"],
	["{monk}"] = LOCALIZED_CLASS_NAMES_MALE["MONK"],
	["{dh}"] = LOCALIZED_CLASS_NAMES_MALE["DEMONHUNTER"],
	["{demonhunter}"] = LOCALIZED_CLASS_NAMES_MALE["DEMONHUNTER"],
	["{evoker}"] = LOCALIZED_CLASS_NAMES_MALE["EVOKER"],
}

-- ProcessTag
function tags.ProcessTag(tag)
	local lowerTag = tag:lower()

	if tags.UtilityChatData[lowerTag] and tags.UtilityChatData[lowerTag].texture then
		return tags.UtilityChatData[lowerTag].texture
	end

	if lowerTag == "{page}" then
		local id = AngryAssign_State.displayed
		if id and AngryAssign_Pages[id] then
			return AngryAssign_Pages[id].Name
		end
	end

	local type, id = lowerTag:match("{(%a+)%s+(%d+)}")
	if type then
		if type == "spell" then
			return GetSpellLink(tonumber(id)) or tag
		elseif type == "icon" then
			return format("|T%s:0|t", select(3, GetSpellInfo(tonumber(id))) or "")
		elseif type == "boss" and EJ_GetEncounterInfo then
			return select(5, EJ_GetEncounterInfo(tonumber(id))) or tag
		elseif type == "journal" and C_EncounterJournal and C_EncounterJournal.GetSectionInfo then
			return (C_EncounterJournal.GetSectionInfo(tonumber(id)) and C_EncounterJournal.GetSectionInfo(tonumber(id)).link) or tag
		end
	end

	local iconName = lowerTag:match("^{icon%s+([%w_%-]+)%s*}$")
	if iconName then
		return "|TInterface\\Icons\\" .. iconName .. ":0|t"
	end

	return tag
end
