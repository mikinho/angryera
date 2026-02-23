**AngryEra** is a modern fork of the legendary AngryAssignments. While initially restored to optimize the experience for **Classic Era, Hardcore, and Season of Discovery**, it is fully compatible with **all versions of World of Warcraft** (Retail, Cataclysm, Classic).

Designed for raid leaders who demand flexibility and speed, AngryEra revitalizes assignment management:

*   **Dynamic Variables**: Define key roles (e.g., `MT=PlayerName`) once, and watch every boss assignment update instantly.
*   **Mustache Logic**: Automate assignments with logic like `{{#classes.WARRIOR}}` based on your live raid roster.
*   **Drag & Drop**: Effortlessly organize pages and categories with intuitive drag-and-drop controls.
*   **Markdown Support**: Create clear, formatted strategies with headers, bold text, and lists.
*   **Safer Imports**: JSON/encoded imports are validated with payload and nesting guardrails to prevent malformed data from causing instability.
*   **Raid Templates**: Includes pre-loaded, optimized strategies for MC, BWL, AQ40, and Naxxramas.
*   **Modern UI**: A polished interface with pixel-perfect alignment and smarter context menus.

Ensure your team knows exactly what to do, whether you're organizing a PUG or leading a hardcore progression guild.

Using AngryEra as a raider
------------------------------
First, you'll likely want to configure a keybinding for the "Toggle Display" function (it should appear under "Angry Assignments" in your game keybindings menu), this will let you easily show/hide the on-screen assignments display during raids.  

The rest of the important configuration is primarily in the game's Interface menu, Addons tab, where you should now have a menu for "Angry Assignments" (you can also bring this screen up with the "/aa" command):

* "Toggle Display" will toggle the on-screen display on and off (can also use "/aa toggle", but most of the time you'll want to use the keybinding discussed above).
* "Toggle Lock" will lock/unlock the anchor for the on-screen display (can also use "/aa lock" or a keybinding), so that you can configure its location, direction, and width.
* In the "Highlight" field, you can set some words that will always be highlighted in on-screen assignments.  Separate multiple words with commas or spaces.  Typically, you will want to set this to your name and any short versions of it that are commonly used.  If you add the special word "Group" into the list of highlights, then raid group numbers (ie "G1", "G2", etc) that appear in assignments will always be highlighted whenever you are a part of that group.
* You may wish to turn on the "Hide on Combat" option which will automatically hide the on-screen assignments whenever you get into combat.  You can always bring them back up during combat by using the keybinding (or other methods mentioned above).
* You can configure the font face, size, color, and outline style that will be used for the on-screen assignments.  You can also configure the color used for highlighted words.
* The "Toggle Window" and "Scale" features here are used for the edit window that officers/raid assistants use to edit assignments.  If you are not going to be doing that, then you can safely ignore them.

For initial setup, unlock the on-screen display if necessary (use the button mentioned above, or "/aa lock", or the keybinding if you set one for it), and you should see a red horizontal strip.  You can adjust the width of the strip (long lines will be word-wrapped as needed) and place it in whatever location you want.  The up/down arrow at the far left of the strip will determine whether the assignments text goes up or down from the location at which you place the strip.  When you're done, click the lock on the strip and it will disappear from view.

During raids, whenever any change in assignments occurs, the new assignments will re-appear on your screen if you had hidden them (along with a noticeable visual indicator).  They will auto-hide during combat, if you selected that option above, but you can bring them back up at any time during combat by using the Toggle Display keybinding or other methods.  If you re-log or reload your UI during the raid, your addon will pull information from the raid leader to get back in sync (if you are the raid leader yourself, it will use saved data).  Upon leaving the raid, the on-screen assignments will go away.  

Using AA as an officer/raid assistant
---------------------------------------------------

Editing of assignment pages and changing of on-screen display is restricted to officers in your guild , and people who are raid assistants in a raid you're in (if the raid is led by a guild officer).  Officer ranks in your guild are autodetected based on which ranks have officer chat access.  Each player's addon will reject any page changes or display requests from unauthorized players.

You will likely want to configure a keybinding for "Toggle Window" in the game keybindings.  This brings up the edit window, which is what officers and raid assistants will use to modify the assignment pages.  The edit window can be scaled up or down via the "Scale" parameter in the configuration menu (or via "/aa scale").

The edit window contains a list of assignment pages you have on the left.  When you select one, you'll see the current contents of that page on the right.  You can **drag and drop** pages and categories to reorder them or nest them inside folders. You can also "Add", "Rename", and "Delete" pages via the buttons at the far bottom left.

When editing pages, you'll have several buttons of interest:

* "Accept" will become available after you've begun changing a page.  It will save changes to the page, update its timestamp, and send the updated version to everyone online in the guild (replacing whatever version they may have had).  "Accept" does not change which page is currently displayed on-screen, but if the page you edited is the one being displayed, everyone will immediately see the new version (and if they had hidden their display, it will re-appear).
* "Revert" will become available after you've begun changing a page.  It will abandon your current edits, going back to the previous version of the page.
* "Restore" will recall the last version of the current page that you personally edited and accepted.  This can be used to get back to your "last good version" if someone else has made undesirable edits to the page in the meantime.  Note that if you want to save the restored version on top of the current version of the page, you still need to "Accept" after you "Restore", otherwise nothing really happens.  You can "Revert" to abort and go back to the current version of the page.
* "Send and Display" is only available while not actively editing a page.  It will update the timestamp on the page, send the current version to everyone online in the guild (replacing whatever version they may have had), and, if in a raid, make it the current on-screen display for everyone in the raid.  If you're not in a raid, it will display on-screen for you personally, so you can preview it.
* "Clear Displayed" will remove whatever on-screen display was currently in place, ie: everyone in the raid will now see nothing.  It doesn't affect the contents of any pages.

Within assignment pages, you can use raid symbols such as {rt1}, {rt2}, {circle}, {star}, etc.  {hs} or {healthstone} will insert the icon for a healthstone, and {bl} or {bloodlust} will insert the icon for bloodlust.  You can insert any other icon in the game using this syntax: {icon spell_holy_sealofprotection}.  Icon names can be looked up by going to a spell's page on [Wowhead](http://www.wowhead.com) and then clicking on the icon.  You can also use any UI escape sequences, see [WoWWiki's page](http://www.wowwiki.com/UI_escape_sequences) for a full list.

If someone else saves edits to a particular page while you are editing that page, you'll receive a pop-up box notifying you of the fact.  At that point, you can continue your edits and eventually overwrite their updated version by hitting "Accept", or alternatively you can hit "Revert" which will abandon your own edits, and instead bring up their updated version of the page.  (Tip: before you hit Revert, you might want to highlight the particular section you were working on, copy it with Ctrl+C, then hit Revert, highlight the same section in their version, and paste your changes on top of it with Ctrl+V).

Individual pages are identified internally with unique IDs.  The names seen in the edit window are only used for display purposes, so there can be multiple pages with the same name.  Much like an edit, if someone renames a page, that rename is sent out to everyone in the guild who's online at the time (others will get the rename later, whenever that page is next edited or sent).  Deletes, however, are only done locally - so if you delete a page, others will still have it.  If you've deleted a page, and later on someone else edits it or sends it, you'll get it back again.

Template System & Variables
---------------------------

AngryEra now supports **Mustache-style templating** to create dynamic assignments that adapt to your raid composition.

**Basic Usage:**
* `{{me}}`: Displays your own name.
* `{{#classes.WARRIOR}} {{name}} {{/classes.WARRIOR}}`: Iterates through all Warriors in the raid.
* `{{#groups.1}} {{name}} {{/groups.1}}`: Iterates through Group 1.

**Custom Variables:**
You can define custom variables for each page or category to simplify your templates.
1. Right-click a Page or Category and select **Edit Variables**.
2. Enter your variables in `Key=Value` format or JSON.
   * Example:
     ```
     MT=Zessy
     OT1=Kwayteow
     Healer1=Eblis
     ```
3. Use them in your assignment text:
   * `Main Tank: {{MT}}` -> Displays "Main Tank: Zessy"
   * `Off Tank: {{OT1}}` -> Displays "Off Tank: Kwayteow"

**Class Coloring:**
Names of players in your Raid or Guild will automatically be **class-colored** when displayed in the assignment window.

Importing
---------

You can import pages and categories by string. This is useful for sharing assignments or backing them up.

1. Click standard **Menu** button at the bottom left of the window.
2. Select **Import Page**.
3. Paste your content.
   * If the content contains headers (lines starting with `# `), a **Category** will be created with individual pages for each header.
   * If no headers are found, a single **Page** will be created.
4. Enter a name. If importing a category, this will be the Category Name. If importing a single page, this will be the Page Name.

Import safety and behavior notes:
* JSON escaped newlines (`\n`) are restored to real line breaks on import.
* JSON `null` values are preserved internally and safely re-encoded on export.
* Encoded imports are bounded and validated (size/schema/depth) before they are applied.

Exporting
---------

Right-click any page or category to **Export** it in one of three formats:
* **JSON**: Used for backups or sharing full data structures.
* **Markdown**: Raw text format. Great for sharing with other Raid Leaders.
* **Output**: Processed text (with variables resolved and icons converted). Ideal for copying into Discord.

Markdown Support
----------------

You can use basic Markdown syntax to style your assignments:
* **Headers**: `## Title` (Gold Color)
* **Lists**: `- Item` (Bullet point)
* **Bold**: `**Text**` (White Color)
* **Italic**: `_Text_` (Grey Color)

Chat Output
-----------
Clicking the **Output** button will render the assignment (including all templates and variables) and send it to the selected chat channel (Raid, Party, or Instance).

Raid Shortcuts
--------------------
You can use the following shortcuts in your assignments to display icons for spells and abilities:

**Warrior**
* `{Sunder}` Sunder Armor, `{AoE}` Challenging Shout, `{Mock}` Mocking Blow, `{Pummel}` Pummel
* `{Taunt}` Taunt, `{Demo}` Demoralizing Shout, `{Thunder}` Thunder Clap, `{SW}` Shield Wall, `{LS}` Last Stand, `{Reflect}` Spell Reflection

**Priest**
* `{MC}` Mind Control, `{PI}` Power Infusion, `{FW}` Fear Ward, `{Shackle}` Shackle Undead
* `{Dispel}` Dispel Magic, `{PW:S}` Power Word: Shield, `{Renew}` Renew
* `{Fort}` Power Word: Fortitude, `{Spirit}` Divine Spirit, `{Shadow}` Shadow Protection, `{Fade}` Fade, `{MDS}` Mass Dispel

**Druid**
* `{FF}` Faerie Fire, `{Innerv}` Innervate, `{BR}` Rebirth, `{Remove}` Remove Curse
* `{Rejuv}` Rejuvenation, `{Abolish}` Abolish Poison, `{GOTW}` Gift of the Wild, `{Thorns}` Thorns, `{Bark}` Barkskin

**Paladin**
* `{JoL}` Judgement of Light, `{JoW}` Judgement of Wisdom, `{BoP}` Blessing of Protection, `{DI}` Divine Intervention, `{BoF}` Blessing of Freedom, `{JoJ}` Judgement of Justice, `{Sac}` Blessing of Sacrifice, `{DS}` Divine Shield
* `{Cleanse}` Cleanse, `{LoH}` Lay on Hands
* `{BoK}` Kings, `{BoW}` Wisdom, `{Salv}` Salvation, `{Sanc}` Sanctuary, `{BoL}` Light

**Mage**
* `{CS}` Counterspell, `{Sheep}` Polymorph, `{Decurse}` Remove Lesser Curse
* `{AI}` Arcane Intellect, `{Dampen}` Dampen Magic, `{Amplify}` Amplify Magic, `{Block}` Ice Block

**Warlock**
* `{CoE}` Curse of Elements, `{CoS}` Curse of Shadow, `{CoR}` Curse of Recklessness
* `{SS}` Soulstone, `{Banish}` Banish, `{HS}` Healthstone, `{Seed}` Seed of Corruption

**Hunter**
* `{Tranq}` Tranquilizing Shot, `{Mark}` Hunter's Mark, `{MD}` Misdirection, `{Trap}` Freezing Trap

**Shaman**
* `{ES}` Earth Shock, `{WF}` Windfury Totem, `{Tremor}` Tremor Totem, `{BL}` Bloodlust, `{Hero}` Heroism

**Rogue**
* `{Kick}` Kick, `{Feint}` Feint, `{Cloak}` Cloak of Shadows, `{Blind}` Blind

**Directional & Mechanics**
* `{left}`, `{right}`, `{up}`, `{down}` (Large Arrows)
* `{+}`, `{-}`, `{positive}`, `{negative}` (Polarity/Charge)
* `{page}` (Displays Title of Current Page)

**Consumables**
* `{LIP}`, `{Stone}` (Stoneshield), `{FAP}`, `{Petri}`

**Miscellaneous**
* Faction: `{alliance}`, `{horde}`
* Bosses: `{rag}`, `{nef}`, `{ony}`, `{hakkar}`, `{cthun}`, `{kt}`, `{sapph}`, `{patch}`, `{4hm}`, `{twins}`, `{gruul}`, `{mag}`, `{vashj}`, `{kael}`, `{illidan}`

Miscellaneous
--------------------

The "/aa help" command will list all console commands.

The "/aa version" command (also available from the config menu) will perform a version check.  You'll be shown the current AA version of everyone in the guild, plus a list of players in your raid that aren't running AA.

The "/aa backup" command (also available from the config menu) will store the current version of every page for later "Restore" (similar to if you had just edited every page and made no actual changes).

The "/aa deleteall" command will delete all pages you have stored.  This could be used occasionally to clean out old assignment pages that are no longer used, for example, when beginning a new tier.  Of course, if others in the guild still have those pages, and choose to edit them and/or send them out for display, you'll get them back if you're online at the time.

Developer Documentation (LDoc)
--------------------

This repository includes an LDoc configuration file at `.ldoc`.

Generate API documentation:

1. Install [LDoc](https://github.com/lunarmodules/LDoc) (for example via LuaRocks).
2. Run from the repo root:
   ```
   make docs
   ```
   Or directly:
   ```
   ldoc .
   ```
3. Open generated docs in `docs/ldoc/` (HTML and Markdown output, depending on LDoc setup).
4. To remove generated docs:
   ```
   make docs-clean
   ```

Developer Checks
--------------------

Run local quality checks from the repo root:

1. Run lint checks:
   ```
   make lint
   ```
   This runs:
   - Lua syntax validation (`luac -p`) on all `*.lua` files.
   - Style checks for trailing whitespace and CRLF line endings.
   - `stylua --check` with repo settings from `.stylua.toml` (when installed).
     In `make lint`, stylua is advisory (differences do not fail the target).
   - `luacheck` with repo settings from `.luacheckrc` when installed.
     In `make lint`, luacheck is advisory (warnings do not fail the target).
     Note: luacheck is not fully WoW-API-aware in this repo yet, but it still
     helps surface glaring issues and cleanup opportunities.
2. Run strict luacheck:
   ```
   make lint-luacheck-strict
   ```
   This fails on luacheck warnings and is useful for incremental cleanup.
3. Run strict formatting check:
   ```
   make lint-stylua-strict
   ```
   This fails when code formatting differs from `.stylua.toml`.
4. Run full local verification:
   ```
   make check
   ```
   This runs `make lint`, `make test`, and `make docs`.
5. Run JSON regression tests directly:
   ```
   make test
   ```
   This validates JSON import/export edge cases, including escaped newlines and
   preserved `null` values.
6. Run strict CI-style verification:
   ```
   make check-strict
   ```
   This uses strict formatter/linter checks (`stylua` + `luacheck`) and is
   intended for PR/CI gating.

Credits
-------
Maintained by **Eblis/Zessy/Kwayteow** on Pagle (Classic Era).
