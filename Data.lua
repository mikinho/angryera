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
    ["|cgreen"]       = "|cff0adc00",
    ["|cred"]         = "|cffeb310c",
    ["|cyellow"]      = "|cfffaf318",
    ["|corange"]      = "|cffff9d00",
    ["|cpink"]        = "|cfff64c97",
    ["|cpurple"]      = "|cffdc44eb",
    ["|cdruid"]       = "|cffff7d0a",
    ["|chunter"]      = "|cffabd473",
    ["|cmage"]        = "|cff40C7eb",
    ["|cpaladin"]     = "|cfff58cba",
    ["|cpriest"]      = "|cffffffff",
    ["|crogue"]       = "|cfffff569",
    ["|cshaman"]      = "|cff0070de",
    ["|cwarlock"]     = "|cff8787ed",
    ["|cwarrior"]     = "|cffc79c6e",
    ["|cdk"]          = "|cffc41f3b",
    ["|cdeathknight"] = "|cffc41f3b",
    ["|cmonk"]        = "|cff00ff96",
    ["|cdh"]          = "|cffa330c9",
    ["|cdemonhunter"] = "|cffa330c9",
    ["|cevoker"]      = "|cff33937f"
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
    ["{healthstone}"]  = "|TInterface\\Icons\\INV_Stone_04:0|t",
    ["{hs}"]           = "|TInterface\\Icons\\INV_Stone_04:0|t",
    ["{damage}"]       = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:22:41|t",
    ["{dps}"]          = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:22:41|t",
    ["{tank}"]         = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:0:19:22:41|t",
    ["{healer}"]       = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:1:20|t",
    ["{hero}"]         = "|TInterface\\Icons\\ABILITY_Shaman_Heroism:0|t",
    ["{heroism}"]      = "|TInterface\\Icons\\ABILITY_Shaman_Heroism:0|t",
    ["{bl}"]           = "|TInterface\\Icons\\SPELL_Nature_Bloodlust:0|t",
    ["{bloodlust}"]    = "|TInterface\\Icons\\SPELL_Nature_Bloodlust:0|t",
    
    -- Class Icons
    ["{hunter}"]       = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:16:32|t",
    ["{warrior}"]      = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:0:16|t",
    ["{rogue}"]        = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:0:16|t",
    ["{mage}"]         = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:0:16|t",
    ["{priest}"]       = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:16:32|t",
    ["{warlock}"]      = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:48:64:16:32|t",
    ["{paladin}"]      = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:32:48|t",
    ["{druid}"]        = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:48:64:0:16|t",
    ["{shaman}"]       = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:16:32|t",
    ["{dk}"]           = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:32:48|t",
    ["{deathknight}"]  = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:32:48|t",
    ["{monk}"]         = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:32:48|t",
    ["{dh}"]           = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:64:48:32:48|t",
    ["{demonhunter}"]  = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:64:48:32:48|t",
    ["{evoker}"]       = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:48:64|t"
}

-----------------------
-- Raid Utility
-----------------------
local AngryEra_RaidUtility = {
    ["Warrior"] = {
        ["Sunder"] = {
            ["name"] = "Sunder Armor",
            ["icon"] = "ability_warrior_sunderarmor"
        },
        ["AoE"] = {
            ["name"] = "Challenging Shout",
            ["icon"] = "ability_bullrush" -- This is the AoE Taunt
        },
        ["Mock"] = {
            ["name"] = "Mocking Blow",
            ["icon"] = "ability_kick"
        },
        ["Pummel"] = {
            ["name"] = "Pummel",
            ["icon"] = "inv_gauntlets_04"
        },
        ["Taunt"] = {
            ["name"] = "Taunt",
            ["icon"] = "spell_nature_reincarnation"
        }
    },
    ["Consumables"] = {
        ["LIP"] = {
            ["name"] = "Limited Invulnerability Potion",
            ["icon"] = "inv_potion_62"
        },
        ["Stone"] = {
            ["name"] = "Greater Stoneshield Potion",
            ["icon"] = "inv_potion_69"
        },
        ["FAP"] = {
            ["name"] = "Free Action Potion",
            ["icon"] = "inv_potion_04"
        },
        ["Petri"] = {
            ["name"] = "Flask of Petrification",
            ["icon"] = "inv_potion_26"
        }
    },
    ["Priest"] = {
        ["MC"] = {
            ["name"] = "Mind Control",
            ["icon"] = "spell_shadow_shadowworddominate"
        },
        ["PI"] = {
            ["name"] = "Power Infusion",
            ["icon"] = "spell_holy_powerinfusion"
        },
        ["FW"] = {
            ["name"] = "Fear Ward",
            ["icon"] = "spell_holy_fearward"
        },
        ["Shackle"] = {
            ["name"] = "Shackle Undead",
            ["icon"] = "spell_nature_slow"
        },
        ["Dispel"] = {
            ["name"] = "Dispel Magic",
            ["icon"] = "spell_holy_dispelmagic"
        }
    },
    ["Warlock"] = {
        ["CoE"] = {
            ["name"] = "Curse of Elements",
            ["icon"] = "spell_shadow_curseofelementals"
        },
        ["CoS"] = {
            ["name"] = "Curse of Shadow",
            ["icon"] = "spell_shadow_curseofshadow"
        },
        ["CoR"] = {
            ["name"] = "Curse of Recklessness",
            ["icon"] = "spell_shadow_unholystrength"
        },
        ["SS"] = {
            ["name"] = "Create Soulstone",
            ["icon"] = "spell_shadow_soulgem"
        },
        ["Banish"] = {
            ["name"] = "Banish",
            ["icon"] = "spell_shadow_cripple"
        }
    },
    ["Druid"] = {
        ["FF"] = {
            ["name"] = "Faerie Fire",
            ["icon"] = "spell_nature_faeriefire"
        },
        ["Innerv"] = {
            ["name"] = "Innervate",
            ["icon"] = "spell_nature_lightning"
        },
        ["BR"] = {
            ["name"] = "Rebirth",
            ["icon"] = "spell_nature_reincarnation"
        },
        ["Remove"] = {
            ["name"] = "Remove Curse",
            ["icon"] = "spell_nature_removecurse"
        }
    },
    ["Paladin"] = {
        ["JoL"] = {
            ["name"] = "Judgement of Light",
            ["icon"] = "spell_holy_judgmentoflight"
        },
        ["JoW"] = {
            ["name"] = "Judgement of Wisdom",
            ["icon"] = "spell_holy_judgmentofwisdom"
        },
        ["BoP"] = {
            ["name"] = "Blessing of Protection",
            ["icon"] = "spell_holy_sealofprotection"
        },
        ["DI"] = {
            ["name"] = "Divine Intervention",
            ["icon"] = "spell_nature_timestop"
        },
        ["Cleanse"] = {
            ["name"] = "Cleanse",
            ["icon"] = "spell_holy_renew"
        }
    },
    ["Hunter"] = {
        ["Tranq"] = {
            ["name"] = "Tranquilizing Shot",
            ["icon"] = "spell_nature_drowsy"
        },
        ["Mark"] = {
            ["name"] = "Hunter's Mark",
            ["icon"] = "ability_hunter_snipershot"
        }
    },
    ["Mage"] = {
        ["CS"] = {
            ["name"] = "Counterspell",
            ["icon"] = "spell_frost_iceshock"
        },
        ["Sheep"] = {
            ["name"] = "Polymorph",
            ["icon"] = "spell_nature_polymorph"
        },
        ["Decurse"] = {
            ["name"] = "Remove Lesser Curse",
            ["icon"] = "spell_nature_removecurse"
        }
    },
    ["Shaman"] = {
        ["ES"] = {
            ["name"] = "Earth Shock",
            ["icon"] = "spell_nature_earthshock"
        },
        ["WF"] = {
            ["name"] = "Windfury Totem",
            ["icon"] = "spell_nature_windfury"
        },
        ["Tremor"] = {
            ["name"] = "Tremor Totem",
            ["icon"] = "spell_nature_tremortotem"
        }
    },
    ["Rogue"] = {
        ["Kick"] = {
            ["name"] = "Kick",
            ["icon"] = "ability_kick"
        },
        ["Feint"] = {
            ["name"] = "Feint",
            ["icon"] = "ability_rogue_feint"
        }
    }
}

app.UtilityChatMap = {}
for category, items in pairs(AngryEra_RaidUtility) do
    for key, info in pairs(items) do
        local tag = "{" .. key:lower() .. "}"
        app.IconTable[tag] = "|TInterface\\Icons\\" .. info.icon .. ":0|t"
        app.UtilityChatMap[tag] = info.name
    end
end
