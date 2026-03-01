local _, app = ...
local AngryEra = app.AngryEra

AngryEra.Templates = {
    {
        name = "Molten Core",
        pages = {
            { name = "Lucifron", content = "## {page}\n\n{tank} Guards: \n{dispel} Curse: " },
            { name = "Magmadar", content = "## {page}\n\n{hunter} Tranq Rotation: \n{tank} MT: " },
            { name = "Gehennas", content = "## {page}\n\n{tank} Adds: \n{dispel} Rain of Fire: " },
            { name = "Garr", content = "## {page}\n\n{warlock} Banishes: \n{tank} OT Assignments: " },
            { name = "Baron Geddon", content = "## {page}\n\n{dispel} Bomb: " },
            { name = "Shazzrah", content = "## {page}\n\n{mage} Decurse: \n{tank} Boss Position: " },
            { name = "Sulfuron Harbinger", content = "## {page}\n\n{tank} Adds: \n{kick} Interrupts: " },
            { name = "Golemagg the Incinerator", content = "## {page}\n\n{tank} Dogs: " },
            { name = "Majordomo Executus", content = "## {page}\n\n{mage} Sheep: \n{tank} Boss: " },
            { name = "Ragnaros", content = "## {page}\n\n{tank} MT: \n{tank} OT (Knockback): \n{healer} Melee Group: " }
        }
    },
    {
        name = "Blackwing Lair",
        pages = {
            { name = "Razorgore the Untamed", content = "## {page}\n\n{tank} Corners: \n{hunter} Kiting: " },
            { name = "Vaelastrasz the Corrupt", content = "## {page}\n\n{tank} Rotation: " },
            { name = "Broodlord Lashlayer", content = "## {page}\n\n{tank} MT: \n{rogue} Suppression Room: " },
            { name = "Firemaw", content = "## {page}\n\n{tank} MT: \n{tank} OT (Wing Buffet): \n{healer} LoS Healers: " },
            { name = "Ebonroc", content = "## {page}\n\n{tank} Taunt Rotation: " },
            { name = "Flamegor", content = "## {page}\n\n{hunter} Tranq Rotation: " },
            { name = "Chromaggus", content = "## {page}\n\n{hunter} Tranq (Enrage): \n{dispel} Debuffs: " },
            { name = "Nefarian", content = "## {page}\n\n{tank} Phase 1 Adds: \n{tank} Nefarian: \n{warlock} Class Calls (Infernals): " }
        }
    },
    {
        name = "Temple of Ahn'Qiraj (AQ40)",
        pages = {
            { name = "The Prophet Skeram", content = "## {page}\n\n{tank} Platforms: \n{kick} Interrupts: " },
            { name = "Battleguard Sartura", content = "## {page}\n\n{tank} Adds: \n{stun} Stun Rotation: " },
            { name = "The Silithid Royalty", content = "## {page}\n\n{tank} Lord Kri: \n{tank} Princess Yauj: \n{tank} Vem: \n{kick} Interrupts: " },
            { name = "Fankriss the Unyielding", content = "## {page}\n\n{tank} Worms: " },
            { name = "Princess Huhuran", content = "## {page}\n\n{hunter} Soothe: \n{healer} Poison Cleansing: " },
            { name = "Twin Emperors", content = "## {page}\n\n{warlock} Tank (Vek'lor): \n{tank} Tank (Vek'nilash): \n{healer} Healing Assignments: " },
            { name = "C'Thun", content = "## {page}\n\n{tank} Stomach Team: \n{kick} Eye Tentacles: " },
            { name = "Viscidus", content = "## {page}\n\n{frost} Frost Damage: \n{engineer} Sappers: " },
            { name = "Ouro", content = "## {page}\n\n{tank} Sweep: \n{mage} Sand Blast: " }
        }
    },
    {
        name = "Naxxramas",
        pages = {
            { name = "Anub'Rekhan", content = "## {page}\n\n{tank} Crypt Guards: " },
            { name = "Grand Widow Faerlina", content = "## {page}\n\n{priest} MC Rotation: " },
            { name = "Maexxna", content = "## {page}\n\n{tank} MT: \n{healer} Web Wrap: " },
            { name = "Noth the Plaguebringer", content = "## {page}\n\n{tank} Adds: \n{dispel} Curse: " },
            { name = "Heigan the Unclean", content = "## {page}\n\n{tank} Dance: " },
            { name = "Loatheb", content = "## {page}\n\n{healer} Spore Rotation: " },
            { name = "Instructor Razuvious", content = "## {page}\n\n{priest} MC Rotation: " },
            { name = "Gothik the Harvester", content = "## {page}\n\n{tank} Live Side: \n{tank} Dead Side: " },
            { name = "The Four Horsemen", content = "## {page}\n\n{tank} Thane: \n{tank} Mograine: \n{tank} Blaumeux: \n{tank} Zeliek: \n{healer} Rotation: " },
            { name = "Patchwerk", content = "## {page}\n\n{tank} MT: \n{tank} OT (Hateful): " },
            { name = "Grobbulus", content = "## {page}\n\n{tank} Kite Path: " },
            { name = "Gluth", content = "## {page}\n\n{tank} Zombie Kiting: " },
            { name = "Thaddius", content = "## {page}\n\n{tank} Stalagg: \n{tank} Feugen: " },
            { name = "Sapphiron", content = "## {page}\n\n{dispel} Curse: \n{healer} Frost Aura: " },
            { name = "Kel'Thuzad", content = "## {page}\n\n{tank} Abominations: \n{kick} Interrupts: \n{mage} Sheep (MC): " }
        }
    }
}
