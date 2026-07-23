# AngryEra v3 Synchronization Contract

This document defines the synchronization behavior targeted after AngryEra
v3.0.1. It is an implementation contract, not a release-version decision.
Release and beta version numbers will be chosen separately.

## Product boundary

- Published client support remains Classic Era, Hardcore, Season of Discovery,
  and Burning Crusade Anniversary.
- Existing Wrath and Retail compatibility branches may remain where they are
  inexpensive, so future expansion is not blocked.
- Wire compatibility with AngryAssignments and AngryEra versions older than
  this synchronization protocol is not required.
- The current active-page exchange remains automatic.
- Full hierarchy synchronization is opt-in and operates on one selected root
  category at a time.
- Automatic cleanup is a separate opt-in and defaults to disabled.

## Local and shared data

Every installation has account-wide metadata stored in a dedicated
`AngryAssign_Meta` SavedVariable. It contains:

- a schema version;
- an installation identifier generated once and reused by every character
  sharing that SavedVariables file;
- a persisted monotonic entity counter;
- idempotent migration markers.

Display, window, and tree resets never clear identity metadata.

Every page and category has:

- a local numeric ID used by the existing tree and SavedVariables tables;
- a globally unique synchronization ID generated from its owning installation
  and persisted monotonic entity counter;
- an owner installation ID;
- a revision identity;
- an author name for display and audit purposes.

Numeric IDs remain local implementation details. Network relationships use
synchronization IDs so independently generated numeric IDs cannot collide.

Existing pages and categories are migrated as locally owned. Migration must
prefer protecting old data over classifying it as remotely synchronized.
Local ownership is recorded as local-only provenance and is never accepted
from the wire. An inbound entity that claims a locally owned synchronization ID
is rejected as an identity collision.

Pinning is local-only state. It is omitted from wire payloads and shared
exports. A pinned entity cannot be removed by cleanup or a remote tombstone,
but pinning does not freeze ordinary remote updates. Forking is the mechanism
for diverging from authoritative content.

The local provenance maps live under metadata, for example:

```lua
AngryAssign_Meta.localOwnership[syncId] = true
AngryAssign_Meta.pins[syncId] = true
```

## Permission model

Permissions apply to publishing shared mutations, not to private library use.

| Action | Raid leader | Raid assistant AND (guild officer OR directly allowlisted) | Other member |
| --- | --- | --- | --- |
| Display an assignment | Allowed | Allowed | Denied |
| Add or update shared content | Allowed | Allowed | Denied |
| Rename shared content | Allowed | Allowed | Denied |
| Reorder inside a synchronized root | Allowed | Allowed | Denied |
| Publish or replace a hierarchy manifest | Allowed | Denied | Denied |
| Delete shared content or move it out of scope | Allowed | Denied | Denied |
| Issue tombstones or trigger shared cleanup | Allowed | Denied | Denied |
| Organize, fork, delete, import, or export locally | Allowed | Allowed | Allowed |

Additional rules:

- A raid leader is trusted even when not a guild officer.
- Raid-assistant status alone never grants AngryEra write authority.
- A guild officer who is not a raid assistant has no shared write authority.
- An explicit allowlist can grant a raid assistant non-destructive shared
  proposal authority. It never elevates a non-assistant.
- `Allow All Assistants` may remain as an explicit override and defaults off.
- `Allow All Assistants` never elevates a non-assistant and never bypasses
  leader-only actions.
- Destructive shared actions remain raid-leader-only even when an assistant is
  allowlisted.
- Permission decisions are receiver-local. Rejected packets never mutate local
  data.
- WoW's authenticated addon-message sender plus current group and guild state
  authorize every packet. Installation IDs, owner IDs, and advertised
  capabilities are untrusted lifecycle metadata, never credentials.
- Authorization is checked when a message arrives and again immediately before
  an atomic manifest or delta commits.
- Receiver trust modes are `standard` (leader plus qualified assistants),
  `leader-only`, and `ignore`. `Allow All Assistants` is a separate override.

Assistants may add, edit, rename, and reorder only inside a leader-established
synchronization scope. Moving an entity out of scope, moving it across scopes,
deleting it, replacing the manifest, or issuing a tombstone is destructive and
leader-only.

Everyone may change private organization. A member without publishing rights
cannot mutate authoritative fields of a managed remote entity in place; the UI
creates a local fork instead. Local placement of a synchronized root is a
private overlay and is not an authoritative mutation.

## Editing and conflicts

Page text and variables use an explicit draft lifecycle:

1. Editing creates a local draft.
2. Save publishes one atomic revision.
3. Revert discards the draft and reloads the current stored revision.
4. Restore loads a historical revision into the draft for review.
5. Restore does not publish until Save is selected.

An incoming revision must not overwrite a dirty editor buffer. The incoming
revision is stored, the draft remains visible, and the editor reports a
conflict. The user may discard the draft, keep it as a local fork, or publish a
new revision if still authorized.

Automatic page history records successful stored revisions. A manual backup is
a separate lossless library snapshot rather than another page-history slot.

## Variable inheritance

Variables resolve from broadest to narrowest scope:

1. selected synchronization root category;
2. each nested category from root to the page's direct parent;
3. page variables.

Later scopes override earlier scopes. Variable-to-variable references resolve
after all scopes have merged.

For synchronized entities, the published hierarchy and variable values are
authoritative. A member who wants different values creates a local fork.
Personal display highlights remain local and are not part of synchronized
variables.

## Output behavior

- The Output keybinding renders the actively displayed page.
- The editor Output button renders the page selected in the editor.
- `{page}` resolves from the page passed to the renderer, never from global
  display state.
- Group chat continues to auto-select instance, raid, or party channels unless
  a later feature adds an explicit override.

## Protocol

The protocol version is independent from the addon release version. This
contract introduces protocol version `3` and the `AngryEra3` communication
prefix.

All messages use a named envelope. Each addon enable creates an in-memory
client-session ID and starts a session-local sequence. This prevents message-ID
reuse after a reload:

```lua
{
    Protocol = 3,
    Type = "PAGE_UPSERT",
    MessageId = "installation-id:session-id:sequence",
    ReplyTo = nil,
    SenderInstallationId = "installation-id",
    SentAt = 1234567890,
    Payload = {},
}
```

Receivers reject envelopes with:

- an unsupported protocol;
- an unknown message type;
- malformed identifiers or payloads;
- fields exceeding the existing communication limits.

`VERSION_QUERY` is broadcast to the group. Each protocol-3 client replies by
whisper with `VERSION`, including:

```lua
{
    activePage = 1,
    hierarchyManifest = 1,
    hierarchyDelta = 1,
    variableInheritance = 1,
    ownership = 1,
    tombstones = 1,
}
```

Capabilities are compatibility claims only. They never grant permission.

The initial message families are:

- discovery: `VERSION_QUERY`, `VERSION`;
- active display: `DISPLAY_REQUEST`, `DISPLAY`, `PAGE_REQUEST`,
  `PAGE_UPSERT`;
- scope discovery: `SCOPE_ANNOUNCE`, `MANIFEST_REQUEST`;
- manifest transfer: `MANIFEST_BEGIN`, `MANIFEST_CHUNK`, `MANIFEST_END`,
  `MANIFEST_NACK`, `MANIFEST_APPLIED`;
- shared changes: `CHANGE_PROPOSE`, `CHANGE_RESULT`, `DELTA`,
  `DELTA_REQUEST`.

The hard cutover registers and sends only `AngryEra3`. There is no positional
protocol-1 fallback.

The raid leader is the canonical authority for each managed category scope.
Publishing a scope or changing raid leadership creates a new
`AuthorityEpoch`. Each canonical transaction increments `ScopeRevision`
exactly once.

A qualified assistant whispers a non-destructive `CHANGE_PROPOSE` containing
the base scope and entity revisions. The leader rechecks authorization,
validates the proposal, assigns canonical revisions, and broadcasts `DELTA`.
Only the leader broadcasts manifests, canonical deltas, deletions, and
tombstone operations. The assistant receives `CHANGE_RESULT`.

Active-page-only clients that have not opted into hierarchy synchronization
still receive `PAGE_UPSERT`. It contains ordered ancestor variable layers so
the page renders identically without importing the hierarchy.

## Entity revisions

Every published entity carries:

```lua
{
    SyncId = "owner-installation:page:entity-counter",
    OwnerId = "owner-installation",
    Revision = 4,
    RevisionId = "content-identity",
    UpdatedAt = 1234567890,
    UpdatedBy = "Name-Realm",
}
```

`RevisionId` includes every synchronized field that affects behavior,
including page variables, category variables, hierarchy position, and entity
name. Hash input uses a deterministic, fixed field order. FCS32 may detect
changes but is not a security primitive. A receiver must never retain the
sender's revision identity after sanitizing the data into different content.

Page wire records contain `SyncId`, ownership and revision metadata,
`ParentSyncId`, normalized integer order, name, raw contents, page variables,
and ordered ancestor variable layers when sent outside a manifest.

Category wire records contain `SyncId`, ownership and revision metadata,
`ParentSyncId`, normalized integer order, name, and category variables.

`SyncId` and `OwnerId` are immutable after creation.

`BaseRevisionId` belongs to a proposal or delta operation rather than stored
entity state. An operation whose base revision does not match the stored
revision is a conflict, not an unconditional last-packet-wins overwrite.

Every canonical `DELTA` contains:

```lua
{
    ScopeId = "root-category-sync-id",
    AuthorityEpoch = "leader-session-identity",
    BaseScopeRevision = 11,
    ScopeRevision = 12,
    TransactionId = "leader-installation:session:sequence",
    TransactionHash = "deterministic-change-identity",
    Operations = {
        -- ordered upsert, move, and tombstone operations
    },
}
```

Operations apply in order and commit atomically. A revision gap triggers
`DELTA_REQUEST`; if the missing transaction cannot be supplied, the receiver
requests a fresh manifest.

## Selected-category manifests

One selected category is published recursively as a flat, bounded manifest:

```lua
{
    ScopeId = "root-category-sync-id",
    ManifestId = "publisher-installation:session:sequence",
    AuthorityEpoch = "leader-session-identity",
    ScopeRevision = 12,
    RootSyncId = "root-category-sync-id",
    Entities = {
        -- category and page records
    },
    Tombstones = {
        -- retained canonical deletion records
    },
}
```

Relationships inside a manifest use `SyncId` and `ParentSyncId`. All ordering
values are normalized integers. The selected root has no synchronized parent,
allowing the receiver to place that root locally without importing unrelated
ancestors.

Manifests are transferred through `MANIFEST_BEGIN`, one or more bounded
`MANIFEST_CHUNK` messages, and `MANIFEST_END`. The receiver stages chunks by
manifest ID. It applies nothing until every chunk is present and the total
manifest hash matches. Missing or invalid chunks produce `MANIFEST_NACK`;
successful application produces `MANIFEST_APPLIED`.

Before application, the receiver validates:

- entity and byte limits;
- unique synchronization IDs;
- exactly one root;
- valid parent references;
- absence of cycles;
- a bounded hierarchy depth;
- supported entity kinds and field types;
- revision identities;
- raid-leader authority for the manifest.

Application is atomic from the user's perspective:

1. Validate the complete manifest.
2. Resolve or allocate local numeric IDs.
3. Detect dirty drafts and revision conflicts.
4. Apply categories before pages.
5. Preserve the existing local placement of an already-known root.
6. Update the scope record only after all entities succeed.
7. Refresh the tree and display once.

The sender is authorized again immediately before step 4.

## Cleanup

Each accepted synchronization root stores the set of remote entity
synchronization IDs from its last successfully applied manifest.

The next manifest computes:

```text
stale = previous remote IDs - incoming remote IDs
```

Manifest absence and tombstones are distinct:

- absence means an entity is no longer present in the latest selected-category
  snapshot and may become an optional cleanup candidate;
- a tombstone is an explicit leader-issued shared deletion represented as a
  canonical `DELTA` operation and retained in later manifests for offline
  clients.

Cleanup candidates and tombstones cannot remove:

- entities owned by the local installation;
- locally pinned entities;
- entities outside the selected synchronization scope;
- dirty drafts and unresolved conflicts.

With automatic cleanup disabled, candidates are retained and exposed as a
preview. With automatic cleanup enabled, candidates may be removed only after
a complete manifest from the raid leader has validated successfully.

Partial, malformed, unauthorized, or interrupted manifests never trigger
cleanup.

When a stale remote category contains protected descendants, cleanup never
cascade-deletes them. Locally owned or pinned descendants are rehomed to the
nearest surviving ancestor (or root). Dirty or conflicted descendants block
automatic removal until the conflict is resolved.

## Imports, exports, and templates

Encoded AA is the lossless format. It preserves:

- nested categories;
- ordering;
- page and category variables;
- synchronization identity and revision metadata where appropriate;
- ownership treatment explicitly chosen during import.

Importing a lossless backup may restore entities as locally owned. Importing
someone else's shared package creates external-origin entities or local forks
according to the selected import mode.

Local ownership and pin state are not trusted from an ordinary shared import.
The explicit backup-restore mode is the only path that may recreate them.

JSON and Markdown remain portable, intentionally simpler formats. Custom
templates may evolve to use the lossless recursive representation, but history
and live synchronization state are not template content.

## Implementation sequence

1. Repair current revision, rendering, Restore, and production-test gaps.
2. Add installation identity, entity synchronization identity, migration, and
   pinning.
3. Replace positional protocol-1 packets with protocol-3 envelopes.
4. Enforce sender-level capabilities and leader-only destructive actions.
5. Implement category-variable inheritance.
6. Implement selected-category manifests without cleanup.
7. Add cleanup previews and opt-in cleanup.
8. Add conflict UI, lossless backup handling, and broader runtime tests.

SavedVariables migration is idempotent:

- legacy entities become locally owned;
- `allowall` migrates to `allowAllAssistants`;
- names in `allowplayers` migrate to direct trusted-publisher entries rather
  than continuing the old "trusted leader enables every assistant" behavior.

No implementation phase changes the addon release number or creates a beta tag.
