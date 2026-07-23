**AngryEra** is a modern fork of the legendary AngryAssignments for **WoW Classic Era, Hardcore, Season of Discovery, and Burning Crusade Anniversary**. The current release supports Classic Era 1.15.9 and Burning Crusade Anniversary 2.5.6.

Designed for raid leaders who demand flexibility and speed, AngryEra revitalizes assignment management:

*   **Dynamic Variables**: Define key roles (e.g., `MT=PlayerName`) once, and watch every boss assignment update instantly.
*   **Mustache Logic**: Automate assignments with logic like `{{#classes.WARRIOR}}` based on your live raid roster.
*   **Drag & Drop**: Effortlessly organize pages and categories with intuitive drag-and-drop controls.
*   **Markdown Support**: Create clear, formatted strategies with headers, bold text, and lists.
*   **Safer Imports**: JSON/encoded imports are validated with payload and nesting guardrails to prevent malformed data from causing instability.
*   **Raid Templates**: Includes pre-loaded, optimized strategies for MC, BWL, AQ40, and Naxxramas.
*   **Smart Markers**: Assign raid target icons to your target or mouseover unit with dedicated keybindings.
*   **Modern UI**: A polished interface with pixel-perfect alignment and smarter context menus.

Ensure your team knows exactly what to do, whether you're organizing a PUG or leading a hardcore progression guild.

Smart Markers
-------------

The **AngryEra | Smart Markers** section in the game's keybinding menu provides actions for assigning Star, Circle, Diamond, Triangle, Moon, Square, X, or Skull to either your current target or mouseover unit.

Assigning a marker that is already on the selected unit leaves it in place instead of toggling it off. The **Clear All Raid Targets** keybinding removes every active raid target icon.

**Metadata auto-markers:** page metadata can assign markers to raiders
automatically whenever a page is displayed:

```
MT=Zessy
$MT={{MT}}
$SQUARE=$MT
$SKULL=Kway-OtherRealm
```

See the **Page Metadata ($ Variables)** section for the full rules, including
realm-aware name resolution and marking permissions.

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

Using AngryEra as an officer/raid assistant
-------------------------------------------

Shared page changes are always accepted from the current group leader. A raid assistant may also publish non-destructive page changes when that assistant is a guild officer (or higher) in the receiver's guild, or is named in the receiver's **Trusted Assistants** setting. Officer rank without raid assist does not grant shared write access, and raid assist alone is not enough. The current group leader alone controls which page is shown on-screen or clears the shared display.

Each installation applies its own receiver policy and rejects unauthorized messages. **Leader Only** rejects assistant page changes, while **Ignore Shared Changes** keeps the local library private. **Allow All Raid Assistants** is an explicit override for groups where every assistant should be trusted to publish non-destructive page changes; it never grants shared display control and is disabled by default. Creating, organizing, deleting, importing, and exporting private local content does not require raid authority.

Shared page snapshots are compressed in transit. Display selections use a separate time-critical control lane, so a large page transfer cannot hold the leader's newest selection signal behind it. Rapid unsent snapshots are coalesced before transport, and selections are ordered by both the leader's protocol sequence and a monotonic millisecond send-order stamp: a delayed older selection, including one queued by an earlier sender session, can never replace the newest one. Pages and inherited-variable contexts already seen by the group are reused, including across a raid-leader handoff, while a missing snapshot is recovered automatically.

You will likely want to configure a keybinding for "Toggle Window" in the game keybindings.  This brings up the edit window, which is what officers and raid assistants will use to modify the assignment pages.  The edit window can be scaled up or down via the "Scale" parameter in the configuration menu (or via "/aa scale").

The edit window contains a list of assignment pages you have on the left.  When you select one, you'll see the current contents of that page on the right.  You can **drag and drop** pages and categories to reorder them or nest them inside folders. You can also "Add", "Rename", and "Delete" pages via the buttons at the far bottom left.

When editing pages, you'll have several buttons of interest:

* "Save" will become available after you've begun changing a page. It commits the draft, updates the page timestamp, and publishes the updated page to the group. "Save" does not select a different page. When the raid leader saves the displayed page, its exact updated revision is also made the shared on-screen version. A qualified assistant may publish the page edit, but the leader retains control of the shared display revision.
* "Revert" will become available after you've begun changing a page.  It will abandon your current edits, going back to the previous version of the page.
* "Restore" lets you choose a historical version and loads it into the editor as a draft. Nothing is sent until you click "Save"; click "Revert" to discard the restored draft and return to the current stored version.
* "Send and Display" is only available to the current group leader while grouped and only while not actively editing a page. It publishes the current version and makes it the shared on-screen display. If you're not in a group, it displays on-screen for you personally so you can preview it.
* "Output" is available to the current group leader and raid assistants. It sends the page shown in the editor to group chat without changing the shared display.
* "Clear Displayed" removes the shared on-screen display when used by the current group leader. For anyone else it clears only the local display. It doesn't affect page contents.

Within assignment pages, you can use raid symbols such as {rt1}, {rt2}, {circle}, {star}, etc.  {hs} or {healthstone} will insert the icon for a healthstone, and {bl} or {bloodlust} will insert the icon for bloodlust.  You can insert any other icon in the game using this syntax: {icon spell_holy_sealofprotection}.  Icon names can be looked up by going to a spell's page on [Wowhead](http://www.wowhead.com) and then clicking on the icon.  You can also use any UI escape sequences, see [WoWWiki's page](http://www.wowwiki.com/UI_escape_sequences) for a full list.

If someone else saves edits to a particular page while you are editing that page, you'll receive a pop-up box notifying you of the fact. Your draft remains visible. You can continue editing and eventually overwrite their updated version by clicking "Save", or click "Revert" to abandon your draft and load their updated version. (Tip: before you click Revert, you may want to copy the section you were working on so you can paste it into the new version.)

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

Page Metadata ($ Variables)
---------------------------

Any variable whose name starts with `$` is **page metadata**: a machine-facing
channel that travels with your assignments. Metadata behaves exactly like a
normal template variable — it inherits from category to page, resolves
`{{references}}`, and can be rendered in note text — but it is never
auto-highlighted, and it is published to WeakAuras and other addons with the
`$` prefix stripped. Set metadata on a category to apply it to every page
inside; set it on a page to override.

The intent: your assignment pages describe *what the raid does*, and metadata
describes *what the addon should do about it*. Everything below rides the
existing variable sync, so the whole raid stays consistent with zero extra
setup.

**Reserved keys AngryEra acts on:**

* `$STAR`, `$CIRCLE`, `$DIAMOND`, `$TRIANGLE`, `$MOON`, `$SQUARE`, `$X` (or
  `$CROSS`), `$SKULL` — **auto-markers**. Set one to a player name or a
  variable reference (`$SQUARE=$MT`) and the marker is applied to that raider
  whenever the page is displayed. Names resolve realm-aware: exact
  `Name-Realm` first, a unique cross-realm match for unqualified names, and
  ambiguous names are skipped instead of guessed. Only clients allowed to
  mark will act (raid leader or assistant in a raid; anyone in a party).
* `$AUTOADVANCE` — **kill-driven page advancement**. Set `$AUTOADVANCE=true`
  on a category and, after each boss kill, the raid leader's client advances
  the display to the next page — so the upcoming assignments are on screen
  ahead of the pull. Wipes never advance. The rendered page's exact metadata
  snapshot decides whether advancement is enabled, so a later private category
  edit cannot change the behavior of the note already on screen. Set
  `$AUTOADVANCE=false` on a specific page to stop the chain at that boss (for
  example, the final boss of the night). A shared-display transport failure is
  warned about and retried twice; local activation alone is not reported as a
  shared success.
* `$ENCOUNTER` / `$ENCOUNTERID` — **encounter binding** for auto-advance.
  The displayed page is matched first by encounter id, then by `$ENCOUNTER` or
  its own name (so template pages named "Lucifron" bind automatically). If it
  does not match, Angry Era searches only its bounded, locally authoritative
  sibling sequence and finally falls back to the displayed page. Duplicate id
  or name bindings in that sequence are treated as ambiguous and do not
  advance. Receiver-private placement of a remote-owned displayed page is
  never used to infer what comes next. Use explicit bindings when a page's
  name differs from the boss (`$ENCOUNTER=Patchwerk` on a page called
  "Patch").

**Custom keys** are yours: anything else (`$phase=2`, `$note=swap fast`) is
carried along, inherited, and exposed through `AngryEra:GetDisplayedMeta()`
and the `ANGRYERA_NOTE_UPDATE` event for WeakAuras — see the WeakAuras &
Addon API section.

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

WeakAuras & Addon API
--------------------

AngryEra exposes the actively displayed note to WeakAuras and other addons.

**Page metadata:** any variable whose name starts with `$` is page metadata.
Metadata behaves like a normal template variable (it inherits from category to
page, resolves `{{references}}`, and can be rendered in note text), but it is
never auto-highlighted and is additionally published to the API with the `$`
prefix stripped. Scalars work in `Key=Value` form; tables, arrays, and JSON null
are also preserved when the variables are entered as a JSON object. Example
page variables:

```
MT=Zessy
$encounter=Patchwerk
$phase=2
```

**Event:** `ANGRYERA_NOTE_UPDATE` fires whenever any published field in the
displayed-note snapshot changes, including metadata or ancestor names, and once
when the display clears. It is delivered both as a WeakAuras custom event
(`ScanEvents`) and as an AceEvent message, with `syncId, pageName,
categoryName` arguments.

**API:** the stable public entry point is the global `AngryEra` object
(`_G.AngryEra`). It references the same addon object used internally. AngryEra
will not overwrite an existing global with that name during startup. Every
successful getter returns a detached copy. JSON null values are represented by
fresh marker tables; use `AngryEra:IsDisplayedNull(value)` to recognize them.
If a snapshot exceeds the defensive graph-copy limits, a getter returns nil
plus the `snapshot-too-complex` error code.

* `AngryEra:GetDisplayedNote()` returns the full snapshot: `Name`, `Category`,
  `CategorySyncId`, `Ancestors` (root-to-parent `{ SyncId, Name }`), `Raw`,
  `Rendered`, `Vars`, `Meta`, revision identifiers, and audit fields. Returns
  nil when nothing is displayed.
* `AngryEra:GetDisplayedVars()` returns resolved template variables with
  metadata excluded.
* `AngryEra:GetDisplayedMeta()` returns `$` metadata with the prefix stripped.
* `AngryEra:IsDisplayedNull(value)` identifies JSON null markers returned
  anywhere inside a detached snapshot.
* `AngryEra.NOTE_API_VERSION` and `AngryEra.NOTE_UPDATE_EVENT` support feature
  detection.

Other addons should declare AngryEra as an optional dependency before reading
the API. WeakAuras can feature-detect it directly:

```
local available = type(AngryEra) == "table"
    and type(AngryEra.NOTE_API_VERSION) == "number"
    and AngryEra.NOTE_API_VERSION >= 1
    and type(AngryEra.GetDisplayedNote) == "function"
```

Example WeakAuras trigger (Custom, Event: `ANGRYERA_NOTE_UPDATE`):

```
function(event, syncId, pageName, categoryName)
    local meta = AngryEra:GetDisplayedMeta()
    return meta and meta.encounter == "Patchwerk"
end
```

Category names resolve when the category exists locally (your own library or
an adopted synchronized scope); ancestor sync ids are always included even
when their names are unknown.

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
