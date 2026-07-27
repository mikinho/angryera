# AngryEra

AngryEra is a modern fork of AngryAssignments for WoW Classic Era, Hardcore, Season of Discovery, and Burning Crusade Anniversary. It combines a fast shared assignment display with nested pages, reusable variables, automatic raid markers, encounter-driven page advancement, import/export tools, and WeakAuras integration.

Supported game clients:

- Classic Era 1.15.9
- Burning Crusade Anniversary 2.5.6

> [!IMPORTANT]
> **BREAKING CHANGE FROM PRE-v3.1:** Protocol 3 releases cannot share assignments or displayed pages with older AngryEra or AngryAssignments versions. AngryEra v3.1 and newer can continue sharing ordinary pages with each other, but every viewer needs v3.3 or newer to render group layouts. Existing local pages and settings are migrated automatically; downgrading across the v3.1 data migration requires restoring a SavedVariables backup.

Before upgrading, export important categories as **Encoded AA** or copy your AngryEra SavedVariables file. Do not rely on group layouts in a mixed pre-v3.3 raid.

## What is new

- **Fast, ordered shared displays:** page changes arrive quickly, rapid navigation publishes the final selection, and older delayed changes cannot replace the newest page.
- **Automatic recovery:** late joiners and reloaded clients retrieve the leader's current page, and display control follows a raid-leader change.
- **Safer shared editing:** only the current leader commits shared changes. Qualified raid assistants can submit edits to the exact active page without directly overwriting it.
- **Inherited variables:** variables flow through nested categories to their pages, with the closest category or page value winning.
- **Page metadata:** `$` variables can drive automatic raid markers, encounter advancement, WeakAuras, and other addons.
- **Automatic raid markers:** display a page and AngryEra can mark the assigned players.
- **Boss-kill auto-advance:** after a successful encounter, the leader can automatically display the next page in the category.
- **Displayed-note API:** WeakAuras and other addons can read the active note, resolved variables, metadata, and hierarchy.
- **Safer restore workflow:** choosing an older page version loads it as a draft; nothing changes until you click **Save**.
- **Safer imports and migration:** imported data is bounded and validated, and existing pages and settings are migrated automatically.
- **Priority assignments:** `Primary > Backup` selects the first listed player who is present and alive.
- **Optional received-page cleanup:** remove pages received from other leaders at login or on demand while retaining protected local data.
- **Raid group layouts:** build inherited, roster-aware subgroup plans, render them inside notes, and apply validated layouts out of combat.

## Quick start

### For every raider

1. Install the same AngryEra release as the rest of the group.
2. Type `/aa` to open the addon settings.
3. Set a keybinding for **Toggle Display** under **Angry Era** in the game's keybinding menu.
4. Use `/aa lock` or the **Toggle Lock** keybinding to show the display mover.
5. Drag the display into position, resize it from the red strip, choose whether it grows upward or downward, and lock it again.

When the group leader displays an assignment, it appears automatically. Reloading, reconnecting, or joining late retrieves the current page again.

### For raid and party leaders

1. Open the editor with `/aa window` or the **Toggle Window** keybinding.
2. Create pages and categories from **Menu**, or load one of the included raid templates.
3. Select a page and click **Send**. Double-clicking a page in the tree does the same thing.
4. Use the **Previous Page**, **Next Page**, and **First Page** keybindings to navigate the category containing the actively displayed page.
5. Use **Menu > Clear Page** or `/aa clear` to clear the shared display.

Only the current party or raid leader selects and clears the shared display. Leadership transfers automatically when the group leader changes.

### For raid assistants

Raid assistants can output assignments to chat. Qualified assistants can also edit the exact active shared page when the leader's permission settings accept them and apply a validated raid layout out of combat. Raid assist alone does not enable either action by default. See [Shared pages and permissions](#shared-pages-and-permissions).

## Shared pages and permissions

### What AngryEra shares

AngryEra shares the active assignment page and the category-variable context needed to render it correctly. This context includes inherited metadata such as `$LAYOUT`; it does not broadcast your category records or entire page library.

Your local pages, categories, placement, imports, exports, and private organization remain yours. To give someone a complete page or category for their own library, use **Export > Encoded AA** and have them import it.

If a displayed page is new to your installation, it appears unfiled. You may organize or delete that received page locally; later shared revisions preserve your local placement. If the leader displays a page you deleted, AngryEra can receive it again.

To keep a received page during cleanup, right-click it and choose **Pin**. Pinning is local to your installation and does not change the shared page; right-click it again and choose **Unpin** to remove that protection.

Shared page changes are fast and ordered. If the leader rapidly presses Previous and Next, followers move to the final selection instead of replaying obsolete intermediate pages.

### Who may change a shared page

The current leader is always the final authority. A raid assistant may submit a non-destructive edit only to the exact page currently displayed. Under the default policy, that assistant must also be one of the following:

- a guild officer or higher in the leader's guild;
- listed in the leader's **Trusted Assistants** setting; or
- covered by the leader's **Allow All Raid Assistants** option.

Officer status without raid assist is not enough. Raid assist alone is not enough by default, and a name in **Trusted Assistants** still needs raid assist.

The leader processes simultaneous edits in order and shares each accepted result. If the active page changes, the leader changes, or another edit wins, AngryEra keeps the assistant's text visible as a recoverable draft instead of silently discarding it.

Assistant edits are limited to the active page's name, variables, and contents. They do not grant permission to select or clear the display, edit categories or background received pages, reorder shared data, or perform shared deletions. Party sharing is leader-only because parties do not have a raid-assistant role.

### Permission settings

Open `/aa` and find **Permissions**:

- **Leader + Qualified Assistants** is the default. It accepts the leader plus assistants who meet the rules above.
- **Leader Only** rejects assistant edits. The leader still controls the shared page normally.
- **Ignore Shared Changes** keeps this installation private and ignores group-shared page changes and displays.
- **Allow All Raid Assistants** trusts every raid assistant for non-destructive active-page edits. It is off by default and should be used carefully when assist is handed out broadly.
- **Trusted Assistants** accepts `Name-Realm` entries separated by spaces or commas. Prefer full names when players may be from different realms.

These settings never let an assistant select or clear the shared display.

## Editor guide

Open the editor with `/aa window` or **Toggle Window**. The left side contains a searchable page tree with drag-and-drop ordering and nested categories. Right-click pages and categories for their management menus.

### Main menu

The **Menu** button provides:

- **Add Page**
- **Add Category**
- **Load Raid Template**
- **Import > Encoded AA / JSON / Markdown**
- **Manage Pages**
- **Clear Page**, which clears the current display

Right-click a page or category to rename it, delete it, edit variables, export it, or change its category placement. Categories can also be saved as reusable templates. A saved template retains that category's variables and each page's variables, including a category layout and page-specific layout overrides.

### Editor controls

| Control | What it does |
| --- | --- |
| **Save** | Saves the editor draft. Local pages save locally; on the active shared page, the leader commits the change and a qualified assistant submits it to the leader. |
| **Revert** | Discards the visible draft and reloads the current stored page. |
| **Restore** | Opens up to ten prior content versions. Selecting one loads only its contents as an unsaved draft; click **Save** to keep it. |
| **Output** | Sends the page selected in the editor to group chat without changing the shared display. |
| **Highlight** | Inserts class-color codes around recognized raid and guild names and saves the updated page immediately. |
| **Send** | Displays the page selected in the editor. While grouped, only the current leader can use it. |

If another update arrives while you are editing, AngryEra warns you and leaves your draft visible. Click **Revert** to load the received version, or keep working and **Save** again.

### Local and shared editing

- Your locally owned pages remain editable while solo or grouped.
- A leader can edit and republish shared pages.
- An assistant can edit only the exact active shared page and only when the leader accepts that assistant.
- Received background pages and received categories remain read-only.
- Private category placement and organization remain local.

## Page navigation and chat output

Keybindings under **Angry Era**:

- **Toggle Display**
- **Show Display**
- **Hide Display**
- **Previous Page**
- **Next Page**
- **First Page**
- **Toggle Lock**
- **Toggle Window**
- **Output Assignment to Chat**

Previous, Next, and First Page start from the actively displayed page and stay within its category. **First Page** jumps to the first page in that category; pressing it again returns to the page it left when possible.

While grouped, only the leader's navigation changes the shared display. Rapid navigation is coalesced so the group settles on the leader's latest choice.

The output source depends on how you invoke it:

- The editor's **Output** button outputs the page currently selected in the editor.
- The **Output Assignment to Chat** keybinding and `/aa output` output the actively displayed page.
- Output automatically chooses the appropriate available group chat channel.
- Leaders and raid assistants may output while grouped.

Use **Chat Output Format** in `/aa` to choose spell names or acronyms.

## Variables and inheritance

Right-click a page or category and choose **Edit Variables**. Variables accept either `Key=Value` lines or a JSON object.

```text
MT=Zessy
OT1=Kwayteow
HEALER=Eblis
```

Use them in page text with Mustache syntax:

```text
Main Tank: {{MT}}
Off Tank: {{OT1}}
```

### Category inheritance

Variables are merged in this order:

1. outermost category;
2. each nested category;
3. the page.

The nearest value wins. Put raid-wide defaults on an outer category, encounter defaults on a nested category, and exceptions on individual pages.

References resolve after all layers are merged. This lets a category define a reusable expression that picks up a page override:

```text
Tank={{MT}}
```

If a page later sets `MT=Roselea`, `{{Tank}}` resolves to `Roselea`.

A priority assignment uses `>` to select the first listed player who is both present and alive. It re-resolves when the roster or player state changes:

```text
MAIN_TANK=Roselea > Zessy > Backup
$SKULL={{MAIN_TANK}}
```

Use `Name-Realm` when two group members may share the same short name.

### Roster templates

Common Mustache examples:

```text
You: {{me}}
{{#classes.WARRIOR}}{{name}}{{/classes.WARRIOR}}
{{#groups.1}}{{name}}{{/groups.1}}
```

Player names are class-colored automatically in the on-screen assignment display.

## Page metadata and automation

A variable whose name starts with `$` is metadata. Metadata inherits and resolves references like ordinary variables, but it is intended to describe what AngryEra, WeakAuras, or another addon should do.

Metadata can also appear in page text. It is excluded from automatic word highlighting and is exposed to integrations without the `$` prefix.

### Automatic raid markers

Supported marker keys are case-insensitive:

```text
$STAR
$CIRCLE
$DIAMOND
$TRIANGLE
$MOON
$SQUARE
$X
$CROSS
$SKULL
```

`$X` and `$CROSS` refer to the same marker. A value may be a player name, an ordinary variable, or another metadata variable.

```text
MT=Zessy
$MT={{MT}}
$SQUARE=$MT
$SKULL=Kway-OtherRealm
```

When the page is displayed, AngryEra resolves the assignments and applies the requested markers:

- An exact `Name-Realm` match wins.
- A short name is used only when it uniquely identifies one group member.
- Ambiguous short names are skipped instead of guessed.
- Only the leader or a raid assistant applies automatic markers in a raid.
- Any party member may apply them in a party.
- Missing roster members are retried when roster information changes.

When the display changes or clears, AngryEra removes only stale markers that it assigned. It does not remove a matching marker that already existed, and it does not fight a marker someone changes manually.

### Automatic encounter advancement

To advance assignments after boss kills:

1. Put the encounter pages in the desired order inside one category.
2. Right-click the category, choose **Edit Variables**, and add:

   ```text
   $AUTOADVANCE=true
   ```

3. Name each page after its encounter, or add an explicit page binding:

   ```text
   $ENCOUNTER=Patchwerk
   ```

   You may instead use a numeric encounter ID:

   ```text
   $ENCOUNTERID=1112
   ```

4. To stop after a particular page, override the inherited setting on that page:

   ```text
   $AUTOADVANCE=false
   ```

Only the current group leader advances the shared display. Successful kills advance; wipes do not. Auto-advance uses locally owned sibling pages inside one category; it does not infer a sequence from root-level, unfiled, or received remote-owned pages. Advancement stops when there is no next page. Duplicate encounter names or IDs are treated as ambiguous and do not advance.

### Group layouts

A `$LAYOUT` names the eight raid subgroups and the player slots in them — resist groups, spore rotations, chains, trash groups. It renders wherever you place a `{layout}` tag, updates as the roster changes, and can rearrange the actual raid.

It is metadata like any other, so it inherits. Put the raid's standard arrangement on the category and every page under it has it, then give a page its own only where the fight moves people. The nearest one wins, so a page's layout replaces its category's for that page alone.

`$LAYOUT` is a single line. Groups are separated by `;`; each group is `Label: slot, slot, ...`, and `Label/N` is raid subgroup N. A group written without one takes the lowest subgroup still free, so naming every group is enough to lay out a raid. A slot is a name, a priority list `A > B > C` (first present-and-alive), a class fill `*MAGE` or `*MAGE x2`, or `group:2` (the current members of subgroup 2). Auto-fill never assigns the same player twice. A raid has eight subgroups of five, so the text parser keeps only the first eight groups and first five literal slots in each group. If variable, class, or roster expansion would resolve a subgroup above five members, Apply rejects the whole plan before moving anyone.

```text
$LAYOUT=Tanks/1: MT, OT1; Spores: Lock1 > Lock2, *WARLOCK x2; Kite/8: group:3
```

A slot may also be a `{{Variable}}`, so one name change updates the note and the layout together. The variable is read first and what it holds is classified afterwards, so `MT=Roselea` places Roselea, `MT=Roselea > Vhez` picks whichever of them is present, and `Soakers=*WARLOCK x3` fills three warlocks. A variable that is not set anywhere leaves its slot out rather than placing a player of that name.

```text
MT=Roselea > Vhez
$LAYOUT=Tanks/1: {{MT}}, {{OT1}}
```

Show it in the note with `{layout}` (all groups) or `{layout Spores}` (one group):

```text
Spore soakers:
{layout Spores}
```

Edit it from the page's or the category's right-click menu → **Edit Group Layout**. The editor opens on a fixed visual grid: all eight raid subgroup boxes stay visible in two columns. **Unrostered** is the third column, and **Variables** is the fourth column to its right; each list scrolls independently when needed without moving the subgroup boxes.

The Variables column shows the effective string variables inherited by the page or category being edited. For an actively displayed received page, AngryEra uses the leader's authoritative shared inheritance context rather than that page's placement in your local tree. Dragging one into a subgroup stores its exact token, such as `{{MT}}`, rather than the player name it currently resolves to, so the layout stays dynamic when that variable changes. Variables remain in the column after placement and can be reused in more than one slot. Numeric variables are not offered as whole-slot entries, but remain available inside expressions you type manually, such as `*MAGE x{{Count}}`.

Drag an unrostered name into a box to place it, drag between boxes to move or swap a slot, and drag onto another member to insert ahead of them — or to swap, if the destination subgroup is already full. Drag a member back onto the Unrostered list, drop them outside the window, or right-click them to take them out; releasing on empty space inside the window cancels instead, so a misaimed drag never quietly removes anyone.

You can also type instead of drag. Click a box title to name that group — Spores, Resist, Kite — click a member to edit their slot expression, and click an empty row to add one — a name, a priority list, a class fill, or a `{{Variable}}` — so a layout can be built solo, before there is any roster to drag from. Right-clicking a box title removes the group after a confirmation.

Slots hold the expression, not the resolved player, so `*MAGE x2` and `A > B` keep auto-filling after you rearrange the grid. Tick **Edit as text** to switch the same layout to one group per line, which is also where roster names insert at the cursor. Both views write the same `$LAYOUT`. Groups left empty are dropped when you save, unless you named one — naming Spores before anyone is dragged into it is the point of naming it.

**Save** writes the layout. Saving or applying an inherited layout without changing it does not create a page override, so later category changes continue to flow through. The category record remains local, but when one of its pages is displayed, AngryEra includes the inherited layout in that page's rendering context so the raid sees the same result.

Out of combat, **Apply to Raid** moves resolved members into the bound subgroups. AngryEra validates the whole plan before moving anyone: ambiguous or missing names, duplicate assignments, and resolved expansions that overfill a subgroup are rejected.

The raid leader may always apply it. A raid assistant must also be an officer in the current raid leader's guild, be listed in **Trusted Assistants** on that installation, or have **Allow All Raid Assistants** enabled there. This local check means routinely granting assist to an entire raid does not enable the action for everyone by default.

The editor button saves and applies only the exact page currently displayed. After editing a category layout, display a descendant page that inherits it and use `/aa applylayout`, or open that displayed page's layout editor. `/aa applylayout` always applies the layout resolved by the actively displayed page.

### Custom metadata

Any other `$` key is available to WeakAuras and addons:

```text
$PHASE=2
$CALL=spread
$NOTE=swap fast
```

See [WeakAuras and addon integration](#weakauras-and-addon-integration).

## Smart Marker keybindings

The **AngryEra | Smart Markers** section in the game's keybinding menu contains:

- Star, Circle, Diamond, Triangle, Moon, Square, X, and Skull for your current target;
- the same eight markers for your mouseover unit; and
- **Clear All Raid Targets**.

Assigning a marker that is already on the selected unit leaves it in place rather than toggling it off.

Mouseover keybindings mark a live hostile unit under the cursor and fall back to your current target when the mouseover is not valid. Enable **Allow Friendly Smart Markers** in `/aa` if you intentionally want those bindings to mark friendly players too.

## Importing, exporting, and backups

### Import

Open the editor and choose **Menu > Import**:

- **Encoded AA** imports a full AngryEra page or recursive category export, including variables and nested organization.
- **JSON** imports structured page or category data.
- **Markdown** imports plain assignment text. Lines beginning with `# ` create pages inside a category.

Imports are validated and bounded before they change local data. If a matching page or category name exists, AngryEra asks before replacing it.

Read-only received data is protected: choosing **Replace** for an item you cannot edit creates a uniquely named local copy instead. Importing into the exact active shared page follows the same leader and qualified-assistant rules as editing it.

### Export

Right-click a page or category and choose **Export**:

- **Encoded AA** is the best format for transferring or backing up complete AngryEra data.
- **JSON** is useful for structured interchange.
- **Markdown** is convenient for Discord, documents, or manual editing.
- **Output** resolves templates and produces chat-ready text.

For a release upgrade or downgrade backup, export important categories as **Encoded AA** or copy the addon's SavedVariables file. `/aa backup` only refreshes a legacy per-page backup field; it does not populate the **Restore** history menu and is not a portable backup.

### Page history

When page contents change, AngryEra retains up to ten previous non-empty versions. Use **Restore** to load one as a draft. Restore affects page contents only; the current page name and variables remain unchanged.

## Markdown and assignment tags

The on-screen display supports:

- `## Header` for a gold header;
- `- Item` for a bulleted list;
- `**Bold**` for bold text; and
- `*Italic*` for italic text.

Use `{icon spell_holy_sealofprotection}` to insert a game texture. The following shortcuts are also available.

### Raid targets and navigation

- `{star}`, `{circle}`, `{diamond}`, `{triangle}`, `{moon}`, `{square}`, `{x}`, `{cross}`, `{skull}`
- `{rt1}` through `{rt8}`
- `{left}`, `{right}`, `{up}`, `{down}`
- `{+}`, `{-}`, `{positive}`, `{negative}`
- `{page}` for the rendered page name

### Class and utility shortcuts

- **Warrior:** `{Sunder}`, `{AoE}`, `{Mock}`, `{Pummel}`, `{Taunt}`, `{Demo}`, `{Thunder}`, `{SW}`, `{LS}`, `{Reflect}`
- **Priest:** `{MC}`, `{PI}`, `{FW}`, `{Shackle}`, `{Dispel}`, `{PW:S}`, `{Renew}`, `{Fort}`, `{Spirit}`, `{Shadow}`, `{Fade}`, `{MDS}`
- **Druid:** `{FF}`, `{Innerv}`, `{BR}`, `{Remove}`, `{Rejuv}`, `{Abolish}`, `{GOTW}`, `{Thorns}`, `{Bark}`
- **Paladin:** `{JoL}`, `{JoW}`, `{BoP}`, `{DI}`, `{BoF}`, `{JoJ}`, `{Sac}`, `{DS}`, `{Cleanse}`, `{LoH}`, `{BoK}`, `{BoW}`, `{Salv}`, `{Sanc}`, `{BoL}`
- **Mage:** `{CS}`, `{Sheep}`, `{Decurse}`, `{AI}`, `{Dampen}`, `{Amplify}`, `{Block}`
- **Warlock:** `{CoE}`, `{CoS}`, `{CoR}`, `{SS}`, `{Banish}`, `{HS}`, `{Seed}`
- **Hunter:** `{Tranq}`, `{Mark}`, `{MD}`, `{Trap}`
- **Shaman:** `{ES}`, `{WF}`, `{Tremor}`, `{BL}`, `{Hero}`
- **Rogue:** `{Kick}`, `{Feint}`, `{Cloak}`, `{Blind}`
- **Consumables:** `{LIP}`, `{Stone}`, `{FAP}`, `{Petri}`
- **Bosses:** `{rag}`, `{nef}`, `{ony}`, `{hakkar}`, `{cthun}`, `{kt}`, `{sapph}`, `{patch}`, `{4hm}`, `{twins}`, `{gruul}`, `{mag}`, `{vashj}`, `{kael}`, `{illidan}`
- **Faction:** `{alliance}`, `{horde}`
- **Other:** `{hs}`, `{healthstone}`, `{bl}`, `{bloodlust}`

Named raid targets become native `{rt1}` through `{rt8}` tokens when output to chat.

## Display settings

Open `/aa` to configure:

- highlighted words and the special `Group` keyword;
- hide-on-combat behavior;
- editor scale;
- display backdrop and colors;
- update-notification glow color;
- font face, size, outline, colors, and line spacing;
- whether the edit box uses the display font;
- chat output format;
- whether Smart Marker mouseover bindings may mark friendly units; and
- automatic or on-demand cleanup of received pages.

Adding `Group` to **Highlight** emphasizes your current group token, such as `G2`, when it appears in a displayed assignment.

## Slash commands

| Command | Action |
| --- | --- |
| `/aa` | Open settings. |
| `/aa help` | List available commands. |
| `/aa window` | Toggle the editor window. |
| `/aa toggle` | Toggle the assignment display. |
| `/aa lock` | Show or hide the display mover. |
| `/aa send <exact page name>` | Display a page by its exact name. |
| `/aa clear` | Clear the shared display as leader, or the local display otherwise. |
| `/aa first` | Toggle to or from the first page in the active category. |
| `/aa output` | Output the actively displayed page to group chat. |
| `/aa applylayout` | Apply the displayed page's validated group layout to the raid. Available to the raid leader and qualified raid assistants while out of combat. |
| `/aa version` | Check AngryEra versions in the current party or raid. Available to the leader and raid assistants. |
| `/aa resetposition` | Reset the assignment display position and size. |
| `/aa defaults` | Restore configuration defaults after confirmation. |
| `/aa deleteall` | Permanently delete the local page library after confirmation. |
| `/aa debug [on\|off\|status]` | Control session-local sharing diagnostics. |

Debug is off by default and resets to off after a UI reload. It never prints page contents or variable values, but it does include character names and message, page, and revision identifiers. Review debug output before sharing it publicly.

## Troubleshooting

### A raider does not receive the displayed page

1. Confirm every client is running protocol 3 (AngryEra v3.1 or newer). Group layouts require v3.3 or newer on every viewer.
2. Confirm the sender is the current party or raid leader.
3. On the affected client, confirm **Receive Shared Page Changes** is not set to **Ignore Shared Changes**.
4. Have the leader or a raid assistant run `/aa version` in the group.
5. Reload the affected client. It should request the active page automatically.
6. If needed, enable `/aa debug on`, reproduce one page change, then disable it with `/aa debug off`.

### An assistant's edit is rejected

Confirm that the player:

- currently has raid assist;
- is a guild officer or higher, is listed in the leader's **Trusted Assistants**, or is covered by **Allow All Raid Assistants**; and
- is editing the exact active shared page.

Also confirm the leader is using **Leader + Qualified Assistants**, not **Leader Only**.

### Automatic markers do not appear

- Confirm the local client may place markers: leader or assistant in a raid.
- Prefer `Name-Realm`, or verify that the short name is unique in the group.
- Confirm the metadata key begins with `$`.
- Confirm the displayed page inherited the expected variable value.

### Auto-advance does not run

- Confirm the encounter ended successfully; wipes never advance.
- Confirm the current client is the group leader.
- Confirm the page is inside a category with a next sibling page.
- Confirm the displayed page inherits `$AUTOADVANCE=true`.
- Match the page name to the encounter or add `$ENCOUNTER` or `$ENCOUNTERID`.
- Remove duplicate encounter bindings.

## WeakAuras and addon integration

AngryEra exposes the actively displayed note through the global `AngryEra` object.

### WeakAuras event

`ANGRYERA_NOTE_UPDATE` fires whenever the displayed note changes and once when it clears. WeakAuras receives it as a custom event with:

```text
syncId, pageName, categoryName
```

Example WeakAuras trigger:

1. Choose **Custom** trigger type.
2. Choose **Event**.
3. Enter `ANGRYERA_NOTE_UPDATE` as the event.
4. Use:

   ```lua
   function(event, syncId, pageName, categoryName)
       local meta = AngryEra:GetDisplayedMeta()
       return meta and meta.ENCOUNTER == "Patchwerk"
   end
   ```

Metadata keys are returned without `$` and retain the case used when they were defined.

### Public getters

- `AngryEra:GetDisplayedNote()` returns the displayed page snapshot, including raw and rendered text, resolved variables, metadata, revision information, and ancestor identities.
- `AngryEra:GetDisplayedVars()` returns resolved template variables with metadata excluded.
- `AngryEra:GetDisplayedMeta()` returns metadata with the `$` prefix removed.
- `AngryEra:IsDisplayedNull(value)` recognizes JSON null markers returned inside snapshots.
- `AngryEra.NOTE_API_VERSION` and `AngryEra.NOTE_UPDATE_EVENT` support feature detection.

Successful getters return detached copies so consumers cannot mutate AngryEra's stored display state. A category name may be unavailable when that category does not exist in the local library.

Other addons should declare AngryEra as an optional dependency and feature-detect the API:

```lua
local available = type(AngryEra) == "table"
    and type(AngryEra.NOTE_API_VERSION) == "number"
    and AngryEra.NOTE_API_VERSION >= 1
    and type(AngryEra.GetDisplayedNote) == "function"
```

## Contributor checks

Common local checks:

```sh
make test
make lint-syntax lint-style
make lint
make docs
```

Strict formatter and static-analysis targets are also available:

```sh
make lint-stylua-strict
make lint-luacheck-strict
make check-strict
```

Generated API documentation is written under `docs/ldoc/`; remove it with `make docs-clean`.

## Credits

AngryEra is based on AngryAssignments by Ermad.

Maintained by **Eblis/Zessy/Kwayteow** on Pagle (Classic Era).
