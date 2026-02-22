-- -------------------------------------------------------------------------------
-- Angry Era: Data.lua
--
-- Static data definitions, including:
-- 1. Class and Role Color tables.
-- 2. Icon Texture mapping ({icon} -> |T...|t).
-- 3. Raid Utility Shortcuts (e.g. {Sunder}, {LIP}).
-- -------------------------------------------------------------------------------

-- Shared data tables and parsing helpers for AngryEra.
-- Provides utility tag maps, class/color lookup data, and variable decoding.

local _, app = ...

-- -----------------------
-- Color Table
-- -----------------------
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
        ["4hm"] = {
            ["name"] = "4 Horsemen",
            ["texture"] = "|TInterface\\Icons\\INV_Helmet_09:0|t"
        },
        ["archi"] = {
            ["name"] = "Archimonde",
            ["texture"] = "|TInterface\\Icons\\Spell_Shadow_DeathCoil:0|t"
        },
        ["cthun"] = {
            ["name"] = "C'Thun",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_Eye_01:0|t"
        },
        ["gruul"] = {
            ["name"] = "Gruul",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_MonsterHead_04:0|t"
        },
        ["hakkar"] = {
            ["name"] = "Hakkar",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Dragon_02:0|t"
        },
        ["illidan"] = {
            ["name"] = "Illidan",
            ["texture"] = "|TInterface\\Icons\\INV_Weapon_Glaive_01:0|t"
        },
        ["kael"] = {
            ["name"] = "Kael'thas",
            ["texture"] = "|TInterface\\Icons\\Spell_Fire_Burnout:0|t"
        },
        ["kj"] = {
            ["name"] = "Kil'jaeden",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Demon_02:0|t"
        },
        ["kt"] = {
            ["name"] = "Kel'thuzad",
            ["texture"] = "|TInterface\\Icons\\INV_Lich_Phylactery:0|t"
        },
        ["mag"] = {
            ["name"] = "Magtheridon",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_MonsterHead_03:0|t"
        },
        ["nef"] = {
            ["name"] = "Nefarian",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Dragon_Black:0|t"
        },
        ["ony"] = {
            ["name"] = "Onyxia",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Dragon_01:0|t"
        },
        ["patch"] = {
            ["name"] = "Patchwerk",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_MonsterHead_04:0|t"
        },
        ["rag"] = {
            ["name"] = "Ragnaros",
            ["texture"] = "|TInterface\\Icons\\INV_Hammer_Unique_Sulfuras:0|t"
        },
        ["sapph"] = {
            ["name"] = "Sapphiron",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Dragon_Blue:0|t"
        },
        ["twins"] = {
            ["name"] = "Twin Emperors",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_QirajiCrystal_01:0|t"
        },
        ["vashj"] = {
            ["name"] = "Lady Vashj",
            ["texture"] = "|TInterface\\Icons\\INV_Misc_Head_Naga_01:0|t"
        }
    },
    ["Directional"] = {
        ["left"] = {
            ["name"] = "Left",
            ["texture"] = "|TInterface\\Buttons\\UI-SpellbookIcon-PrevPage-Up:16:16:0:0:32:32:5:27:5:27|t"
        },
        ["right"] = {
            ["name"] = "Right",
            ["texture"] = "|TInterface\\Buttons\\UI-SpellbookIcon-NextPage-Up:16:16:0:0:32:32:5:27:5:27|t"
        },
        ["up"] = {
            ["name"] = "Up",
            ["texture"] = "|TInterface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up:16:16:0:0:32:32:5:27:5:27|t"
        },
        ["down"] = {
            ["name"] = "Down",
            ["texture"] = "|TInterface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up:16:16:0:0:32:32:5:27:5:27|t"
        },
        ["+"] = {
            ["name"] = "Positive",
            ["texture"] = "|TInterface\\Icons\\Spell_ChargePositive:0|t"
        },
        ["-"] = {
            ["name"] = "Negative",
            ["texture"] = "|TInterface\\Icons\\Spell_ChargeNegative:0|t"
        },
        ["positive"] = {
            ["name"] = "Positive",
            ["texture"] = "|TInterface\\Icons\\Spell_ChargePositive:0|t"
        },
        ["negative"] = {
            ["name"] = "Negative",
            ["texture"] = "|TInterface\\Icons\\Spell_ChargeNegative:0|t"
        }
    },
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
        ["Pig"] = {
            ["name"] = "Polymorph: Pig",
            ["icon"] = "spell_magic_polymorphpig"
        },
        ["Sheep"] = {
            ["name"] = "Polymorph",
            ["icon"] = "spell_nature_polymorph"
        },
        ["Turtle"] = {
            ["name"] = "Polymorph: Turtle",
            ["icon"] = "ability_hunter_pet_turtle"
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
        ["Cheap"] = {
            ["name"] = "Cheap Shot",
            ["icon"] = "ability_cheapshot"
        },
        ["Feint"] = {
            ["name"] = "Feint",
            ["icon"] = "ability_rogue_feint"
        },
        ["Kick"] = {
            ["name"] = "Kick",
            ["icon"] = "ability_kick"
        },
        ["Kidney"] = {
            ["name"] = "Kidney Shot",
            ["icon"] = "ability_rogue_kidneyshot"
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
        local iconTexture = info.texture or ("|T" .. (info.path or "Interface\\Icons\\") .. info.icon .. ":0|t")

        -- Register abbreviation (e.g. {sw})
        local tag = "{" .. key:lower() .. "}"
        app.UtilityChatMap[tag] = info.name
        app.UtilityChatData[tag] = { name = info.name, key = key, texture = iconTexture }

        -- Register full name (e.g. {shield wall})
        local nameTag = "{" .. info.name:lower() .. "}"
        app.UtilityChatMap[nameTag] = info.name
        app.UtilityChatData[nameTag] = { name = info.name, key = key, texture = iconTexture }
    end
end

-- -------------------------------------------------------------------------------
-- JSON Utility
-- -------------------------------------------------------------------------------
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

local function codepoint_to_utf8(codepoint)
    if codepoint <= 0x7F then
        return string.char(codepoint)
    elseif codepoint <= 0x7FF then
        local b1 = 0xC0 + math.floor(codepoint / 0x40)
        local b2 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2)
    elseif codepoint <= 0xFFFF then
        local b1 = 0xE0 + math.floor(codepoint / 0x1000)
        local b2 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
        local b3 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2, b3)
    end

    local b1 = 0xF0 + math.floor(codepoint / 0x40000)
    local b2 = 0x80 + (math.floor(codepoint / 0x1000) % 0x40)
    local b3 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
    local b4 = 0x80 + (codepoint % 0x40)
    return string.char(b1, b2, b3, b4)
end

local function parse_string(str, pos)
    local i = pos + 1
    local chunkStart = i
    local out = {}
    local outCount = 0
    local len = #str

    while i <= len do
        local c = str:sub(i, i)
        if c == "\"" then
            if i > chunkStart then
                outCount = outCount + 1
                out[outCount] = str:sub(chunkStart, i - 1)
            end
            return table.concat(out), i + 1
        end

        if c == "\\" then
            if i > chunkStart then
                outCount = outCount + 1
                out[outCount] = str:sub(chunkStart, i - 1)
            end

            local esc = str:sub(i + 1, i + 1)
            if esc == "" then
                return nil, i, "Unterminated escape sequence"
            end

            if esc == "\"" or esc == "\\" or esc == "/" then
                outCount = outCount + 1
                out[outCount] = esc
                i = i + 2
            elseif esc == "b" then
                outCount = outCount + 1
                out[outCount] = "\b"
                i = i + 2
            elseif esc == "f" then
                outCount = outCount + 1
                out[outCount] = "\f"
                i = i + 2
            elseif esc == "n" then
                outCount = outCount + 1
                out[outCount] = "\n"
                i = i + 2
            elseif esc == "r" then
                outCount = outCount + 1
                out[outCount] = "\r"
                i = i + 2
            elseif esc == "t" then
                outCount = outCount + 1
                out[outCount] = "\t"
                i = i + 2
            elseif esc == "u" then
                local hex = str:sub(i + 2, i + 5)
                if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
                    return nil, i, "Invalid unicode escape"
                end

                local codepoint = tonumber(hex, 16)
                outCount = outCount + 1
                out[outCount] = codepoint_to_utf8(codepoint)
                i = i + 6
            else
                return nil, i, "Invalid escape sequence"
            end

            chunkStart = i
        else
            i = i + 1
        end
    end

    return nil, pos, "Unterminated String"
end

local function parse_number(str, pos)
    local i = pos

    if str:sub(i, i) == "-" then
        i = i + 1
    end

    local function is_digit(ch)
        return ch ~= "" and ch:match("%d") ~= nil
    end

    local ch = str:sub(i, i)
    if ch == "0" then
        i = i + 1
        if is_digit(str:sub(i, i)) then
            return nil, pos, "Invalid Number"
        end
    elseif is_digit(ch) then
        repeat
            i = i + 1
            ch = str:sub(i, i)
        until not is_digit(ch)
    else
        return nil, pos, "Invalid Number"
    end

    if str:sub(i, i) == "." then
        i = i + 1
        if not is_digit(str:sub(i, i)) then
            return nil, pos, "Invalid Number"
        end
        repeat
            i = i + 1
            ch = str:sub(i, i)
        until not is_digit(ch)
    end

    ch = str:sub(i, i)
    if ch == "e" or ch == "E" then
        i = i + 1
        ch = str:sub(i, i)
        if ch == "+" or ch == "-" then
            i = i + 1
        end
        if not is_digit(str:sub(i, i)) then
            return nil, pos, "Invalid Number"
        end
        repeat
            i = i + 1
            ch = str:sub(i, i)
        until not is_digit(ch)
    end

    local token = str:sub(pos, i - 1)
    local number = tonumber(token)
    if number == nil then
        return nil, pos, "Invalid Number"
    end

    return number, i
end

-- Proper recursive implementation
local parse_value
-- Sentinel used to preserve JSON `null` values in decoded tables.
local JSON_NULL = {}
app.JSON_NULL = JSON_NULL
local MAX_JSON_NESTING = 256

local function parse_array(str, pos, depth)
    if depth > MAX_JSON_NESTING then
        return nil, pos, "Maximum JSON nesting exceeded"
    end

    local arr = {}
    pos = skip_ws(str, pos + 1)
    if str:sub(pos, pos) == "]" then
        return arr, pos + 1
    end

    local val, parseError
    while true do
        val, pos, parseError = parse_value(str, pos, depth + 1)
        if parseError then
            return nil, pos, parseError
        end
        table.insert(arr, val)
        pos = skip_ws(str, pos)
        if str:sub(pos, pos) == "]" then
            return arr, pos + 1
        end
        if str:sub(pos, pos) ~= "," then
            return nil, pos, "Expected ',' or ']'"
        end
        pos = skip_ws(str, pos + 1)
    end
end

local function parse_obj_impl(str, pos, depth)
    if depth > MAX_JSON_NESTING then
        return nil, pos, "Maximum JSON nesting exceeded"
    end

    local obj = {}
    pos = skip_ws(str, pos + 1)
    if str:sub(pos, pos) == "}" then
        return obj, pos + 1
    end

    local key, val, parseError
    while true do
        if str:sub(pos, pos) ~= "\"" then
            return nil, pos, "Expected String Key"
        end
        key, pos, parseError = parse_string(str, pos)
        if parseError then
            return nil, pos, parseError
        end
        pos = skip_ws(str, pos)
        if str:sub(pos, pos) ~= ":" then
            return nil, pos, "Expected ':'"
        end
        pos = skip_ws(str, pos + 1)

        val, pos, parseError = parse_value(str, pos, depth + 1)
        if parseError then
            return nil, pos, parseError
        end
        obj[key] = val

        pos = skip_ws(str, pos)
        if str:sub(pos, pos) == "}" then
            return obj, pos + 1
        end
        if str:sub(pos, pos) ~= "," then
            return nil, pos, "Expected ',' or '}'"
        end
        pos = skip_ws(str, pos + 1)
    end
end

parse_value = function(str, pos, depth)
    depth = depth or 0
    pos = skip_ws(str, pos)
    local char = str:sub(pos, pos)
    if char == "{" then
        return parse_obj_impl(str, pos, depth)
    end
    if char == "[" then
        return parse_array(str, pos, depth)
    end
    if char == "\"" then
        return parse_string(str, pos)
    end
    if (char >= "0" and char <= "9") or char == "-" then
        return parse_number(str, pos)
    end
    if str:sub(pos, pos+3) == "true" then
        return true, pos + 4
    end
    if str:sub(pos, pos+4) == "false" then
        return false, pos + 5
    end
    if str:sub(pos, pos+3) == "null" then
        return JSON_NULL, pos + 4
    end
    return nil, pos, "Syntax Error"
end

-- Strict JSON decode:
-- Returns decoded Lua value on success.
-- Returns nil on parse failure or trailing garbage.
--- Attempts strict JSON decoding.
-- Returns `nil` if the value is invalid JSON or has trailing non-whitespace.
-- JSON `null` values are returned as `app.JSON_NULL`.
-- @tparam string str JSON input string.
-- @treturn any|nil Decoded Lua value on success.
function app.JSON_TryDecode(str)
    if type(str) ~= "string" or str == "" then
        return nil
    end

    local success, value, pos, parseError = pcall(function()
        local decodedValue, nextPos, err = parse_value(str, 1)
        return decodedValue, nextPos, err
    end)

    if not success or parseError then
        return nil
    end

    if not pos then
        return nil
    end

    local nextPos = skip_ws(str, pos)
    if nextPos <= #str then
        return nil
    end

    return value
end

--- Decodes JSON into Lua with a safe fallback.
-- @tparam string str JSON input string.
-- @treturn table|any Decoded value on success, or `{}` when invalid.
function app.JSON_Decode(str)
    local decoded = app.JSON_TryDecode(str)
    if decoded ~= nil then
        return decoded
    end
    return {}
end

local function encode_json_string(value)
    value = value:gsub("\\", "\\\\")
    value = value:gsub("\"", "\\\"")
    value = value:gsub("\n", "\\n")
    value = value:gsub("\r", "\\r")
    value = value:gsub("\t", "\\t")
    return "\"" .. value .. "\""
end

local function encode_json_value(value)
    if value == JSON_NULL then
        return "null"
    end

    local valueType = type(value)
    if valueType == "string" then
        return encode_json_string(value)
    end
    if valueType == "number" then
        return tostring(value)
    end
    if valueType == "boolean" then
        return tostring(value)
    end
    if valueType == "table" then
        local parts = {}
        local isArray = (value[1] ~= nil or next(value) == nil)
        for key in pairs(value) do
            if type(key) ~= "number" then
                isArray = false
                break
            end
        end

        if isArray then
            for _, element in ipairs(value) do
                table.insert(parts, encode_json_value(element))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end

        local keys = {}
        for key in pairs(value) do
            table.insert(keys, key)
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)

        for _, key in ipairs(keys) do
            local encodedKey = encode_json_string(tostring(key))
            table.insert(parts, string.format("%s:%s", encodedKey, encode_json_value(value[key])))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    return "null"
end

--- Encodes a Lua value to JSON.
-- `app.JSON_NULL` is encoded as `null`.
-- @tparam any value Lua value to encode.
-- @treturn string JSON-encoded value.
function app.JSON_Encode(value)
    return encode_json_value(value)
end

--- Parses variables from either JSON or `key=value` lines.
-- @tparam string str Variable text.
-- @treturn table Parsed key/value table.
function app.ParseVariables(str)
    if not str or str == "" then
        return {}
    end

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
                -- Let's try to convert to number if possible.
                local n = tonumber(val)
                if n then
                    obj[key] = n
                end
                -- Convert "true"/"false"?
                if val == "true" then
                    obj[key] = true
                elseif val == "false" then
                    obj[key] = false
                end
            end
        end
    end
    return obj
end
