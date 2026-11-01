# Format

The format git-native-issuez reads and writes. It is
[git-native-issue](https://github.com/remenoscodes/git-native-issue)'s
format 1 (its `ISSUE-FORMAT.md`) with additive extensions. Every issue this
tool writes stays a valid format-1 issue, and upstream's `fsck` passes on it.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Refs

| Ref | Content |
| --- | --- |
| `refs/issues/<uuid>` | an issue |
| `refs/milestones/<uuid>` | a milestone (§6) |
| `refs/attachments/<uuid>` | LFS pointers for the attachments of issue `<uuid>`, derived (§7) |
| `refs/remotes/<remote>/{issues,milestones,attachments}/<uuid>` | fetched refs, waiting to be merged |
| `refs/issuez-sync/<remote>/<kind>/{issues,milestones,attachments}/<uuid>` | sync bookkeeping, local only (§8) |
| `refs/issuez-guard/<uuid>` | write serialization, local only (§3, Guards) |

UUIDs are lowercase, hyphenated, version 4. Readers MUST NOT read data from
any ref other than `refs/issues/*` and `refs/milestones/*`.
`refs/attachments/*` holds no data of its own and can always be rebuilt.

`git issue merge`, `sync` and `git fetch` after `git issue init` fetch into
`refs/remotes/<remote>/issues/`, `.../milestones/` and `.../attachments/`,
never straight into `refs/issues/`, `refs/milestones/` or
`refs/attachments/`.

## 2. Issue commits

- An issue is a commit DAG with one root. Every commit uses the **empty
  tree**.
- The root carries `State:` and `Format-Version: 1`. This tool never writes
  another format version.
- The root's subject is the title and its body is the description. Every
  other non-merge commit is an update ("comment"): its subject and body are
  the comment text.
- Fields live in the **trailer block**, the last paragraph of the message,
  parsed exactly as `git interpret-trailers --parse` does. The subject
  paragraph is never a trailer block.
- Trailer values MUST NOT contain LF or CR.
- Writers MUST NOT write a body whose last paragraph would itself parse as
  trailers (any key): it would be read as metadata.
- An empty value explicitly clears a field. A missing trailer never clears
  one. Upstream's readers skip empty values for its core fields, so a
  cleared core field may still show the old value there.
- Unknown trailers are kept through merges and ignored by readers that don't
  know them. They appear as plain fields (`show`, `--json` `fields`).
- Per-commit provenance trailers (`Provider-Comment-ID`, `Exported-Commit`,
  written by upstream's provider bridges) describe their commit, not the
  issue, and are not issue fields.

A new issue:

```
Login page crashes

Happens on Safari only.

State: open
Labels: bug, ui
Priority: high
Format-Version: 1
```

## 3. Fields

| Trailer | Kind | Value |
| --- | --- | --- |
| `State` | scalar | `open`, `closed`, or another state |
| `Title` | scalar | overrides the root subject |
| `Labels` | set | `a, b, c` (comma-separated) |
| `Assignee` | scalar | `<email>` or `<uuid> <email>` |
| `Priority` | scalar | `low`, `medium`, `high`, `critical` |
| `Milestone` | scalar | free text |
| `Fixed-By`, `Release`, `Reason` | scalar | text (upstream's `state` options) |
| `X-Milestone-Id` | scalar | milestone UUID (§6) |
| `X-Milestone-Mode` | scalar | `inherit`, `none` or `explicit` (§6) |
| `X-Parent` | scalar | issue UUID |
| `X-Blocked-By` | set | issue UUIDs, comma-separated |
| `X-Start-Date`, `X-Due-Date` | scalar | `YYYY-MM-DD`, a real calendar day |
| `X-Estimate-Minutes` | scalar | decimal minutes, `0` allowed, no leading zeros, at most 10 × 366 days |
| `X-Workflow-State` | scalar | slug: lowercase letter, then lowercase letters, digits, `-` (at most 64 bytes) |
| `X-Deleted` | scalar | `true` or `false` |
| `X-Attachment` | keyed set | an attachment (§7) |
| `X-Attachment-Removed` | keyed set | an attachment's UUID (§7) |
| `X-Event`, `X-Comment` | event | §5 |

- Keys match case-insensitively, as in git.
- A value that doesn't follow its grammar is ignored on read and reported
  (`fsck`, `ls --problems`).
- An `Assignee` whose first word isn't a UUID is an email as a whole, as
  format 1 reads it. The UUID form names a person independently of their
  address; upstream shows the whole value.
- References (`X-Parent`, `X-Blocked-By`, `X-Milestone-Id`) are full UUIDs.
  Whether the target exists, cycles and depth are questions across issues,
  answered when reading (the projection, `ls --problems`, `tree`), never by
  refusing to read.
- `closed` and the states in `git config issue.doneStates` (default
  `wontfix, duplicate`) count as done. `ls` hides them by default, and
  parents, blockers, progress and the guards treat them as closed. Every
  other state (`open`, `in-review`, ...) is open work.
- Workflow states come from `git config issue.workflowStates` (default
  `backlog, ready, in-progress, review`). An open issue without a value
  reads as the first one.

### Guards

Writers keep the hierarchy sound. This tool refuses a write that would:
- make an issue its own parent, close a parent loop, or nest deeper than
  `Limits.max_depth` (8 levels by default);
- give an issue a parent that is missing or deleted;
- block an issue by itself, by a missing issue, or close a blocker loop;
- close an issue with open sub-issues, or open one (create, reopen,
  restore, move) under a closed ancestor;
- delete an issue with sub-issues that aren't deleted;
- link a completed or retired milestone, or put open work (create, reopen,
  restore, move) into a completed milestone, directly or through a parent.
  Moving, relinking or restoring a closed issue counts as putting its open
  sub-issues there;
- complete a milestone that still has open issues (§6).

Each issue or milestone a guard reads is pinned in the same ref
transaction (git's `update-ref` `verify`), so a concurrent change to any of
them aborts the write, which is then retried. A `verify` can't pin that
something is absent, like a new child of the issue being closed. So
creating or moving an issue also moves `refs/issuez-guard/<uuid>` of each
ancestor, and closing or deleting an issue moves its own before reading
the children: two such writes in one clone conflict, and the retry sees the
child. Milestones work the same way: changing what is in a milestone and
completing it both move the milestone's guard ref. The guard refs carry no
data, are never pushed, and can be deleted at any time.

Other tools and concurrent clones can still produce violations; readers
report them and never fail on them.

## 4. Merging: the causal ordering rule

An issue can have merge commits, written by this tool's `merge`, by
upstream's or by hand.
A field's value is computed from the whole DAG, never from the tip alone.
Every value remembers the commit that set it, its *setter*. Walking commits
parents first:
- a commit's explicit trailers set fields;
- at a merge, two values are compared by their setters. If one setter is an
  ancestor of the other, the descendant wins, whatever the clocks say.
  Otherwise the setters are concurrent, and the one with the later author
  time wins, then the larger OID. That case is a **conflict**, derived when
  reading and never stored (`git issue ls --conflicts`);
- a merge commit's own trailers apply after the merge. Restating the value
  the merge resolved to keeps a conflict visible; a different value resolves
  it.

Sets (`Labels`, `X-Blocked-By`): each member's presence has its own setter.
A set trailer lists the whole set, adding and removing relative to the
parent state. A concurrent add and remove resolves to add. Keyed sets
(attachments, §7) follow the same rule per key, and events per target
comment (§5).

No merge base is needed, and criss-cross histories are well defined.

### Merge commits

This tool's merge commits are deterministic, so clones that merge the same
pair write the identical commit:
- subject `Merge issue`, two parents sorted by OID, the empty tree;
- author and committer `git-issue <git-issue@invalid>`, both dated with the
  later parent's committer time, offset `+0000`;
- trailers restate the resolved fields, as written (invalid values too). A
  field that was written and is now empty is restated empty (`Key: `), so a
  reader that takes the newest value finds no older one. The order:
  `State`, `Title` (only when it overrides the root subject), `Labels`,
  `Assignee`, `Priority`, `Milestone`, then `X-Parent`, `X-Start-Date`,
  `X-Due-Date`, `X-Estimate-Minutes`, `X-Workflow-State`, `X-Milestone-Id`,
  `X-Milestone-Mode`, `X-Deleted`, `X-Blocked-By`. Other fields,
  attachments and events follow from the parents.

Restating the values lets upstream, which reads the newest trailer it
finds, show the merged state, extension fields included. For this tool
restating changes nothing: the merge reads as its parents do.

## 5. Events

Lifecycle changes are commits carrying `X-Event`, at most one per commit:

| Event | Trailers | Message text |
| --- | --- | --- |
| edit a comment | `X-Event: comment-edit`, `X-Comment: <full oid>` | the full new comment |
| delete a comment | `X-Event: comment-delete`, `X-Comment: <full oid>` | none |
| restore a comment | `X-Event: comment-restore`, `X-Comment: <full oid>` | none |
| edit the description | `X-Event: description-edit` | the full new description |
| delete or restore the issue | `X-Deleted: true` or `false` (an ordinary field) | none |

- A comment's ID is the full OID of its commit (40 or 64 hex digits;
  abbreviations are invalid). The target MUST be a non-root, non-merge,
  non-event commit of the same issue.
- Events are resolved by §4 per target. Delete hides a comment; restore, or
  any later edit, shows it again.
- An event whose target isn't in the DAG yet is kept and applies once sync
  brings the target in. An event whose target belongs to another issue is
  invalid.
- A deleted issue is hidden from `ls`, `tree` and `search` and kept in
  history. Its sub-issues take its place in `tree`.
- Upstream shows event commits as ordinary updates. Their subjects ("Edit
  comment 3f9a1c2", "Delete issue", ...) are written to read well there.

## 6. Milestones

A milestone is a commit DAG under `refs/milestones/<uuid>`, built like an
issue: empty tree, one root, the trailer rules of §2 and the merge rule of
§4.

```
Create milestone v1.0

Everything for the first release.

Name: v1.0
X-Due-Date: 2026-12-01
X-Milestone-Status: open
Format-Version: 1
```

- The root carries `Name:` and `Format-Version: 1`. The root's body is the
  description, changed later with `X-Event: description-edit` (§5), in the
  same commit as other changes.
- `Name` is the display name and may change; the UUID never does. Names are
  not blank and at most 256 bytes.
- `X-Due-Date` is a date as for issues. An empty value clears it.
- `X-Milestone-Status` is `open`, `completed` or `retired`. A missing or
  unknown value reads as `open`, and `fsck` notes an unknown one.
- Merge commits are `Merge milestone` with no trailers, with the same
  parents, identity and date as issue merges (§4). Only this tool reads
  milestones, so nothing is restated.

An issue links a milestone with `X-Milestone-Id` and `X-Milestone-Mode`:
- `explicit`: the milestone in `X-Milestone-Id`;
- `inherit`: the parent's milestone, through any number of levels;
- `none`: no milestone, and sub-issues that inherit get none either.

Without `X-Milestone-Mode`, the mode is `explicit` when `X-Milestone-Id` is
set, else `inherit` under a parent, else `none`. The *effective* milestone
is found by walking up the parent chain to the nearest `explicit` or `none`.
A deleted issue passes its parent's value through. A milestone ID that
doesn't exist, or a retired milestone, gives no effective milestone and is
reported (`ls --problems`).

Writers that link a milestone also write `Milestone: <name>`, so upstream,
which only knows `Milestone`, shows the name. It is the name when the link
was written: renaming the milestone doesn't rewrite its issues. Clearing it
(`none`, or `inherit` without an ID) writes `Milestone: ` empty. A plain
`Milestone` written by upstream or by hand stays text and links nothing.

Completing a milestone needs every non-deleted issue whose effective
milestone it is to be done (§3), counted as if it were open when it is
retired. Retiring one is for milestones that won't be finished: their
issues keep their trailers, but no longer count as in the milestone, and
new issues can't be added.

## 7. Attachments

Images (PNG, JPEG or WebP, not animated) attached to an issue:

```
X-Attachment: <uuid> <media-type> <size> sha256:<hex> <name>
X-Attachment-Removed: <uuid>
```

- `<uuid>`: the attachment's v4 UUID. `<media-type>`: `image/png`,
  `image/jpeg` or `image/webp`. `<size>`: decimal bytes, 1 to 64 MiB
  (writers default to at most 5 MiB). `<hex>`: 64 lowercase hex digits of
  the content's sha256. `<name>`: the rest of the line, 1 to 255 bytes of
  UTF-8, no control characters, no leading or trailing space.
- Both trailers are repeatable. A commit may add several attachments, and
  may carry a comment too: the images belong to that comment.
- Per UUID, §4 applies over its adds and removals; a concurrent add and
  remove resolves to add. A later `X-Attachment` with the same object
  (hash, size, media type) is a rename. One with a different object is
  invalid and ignored, because attachments are immutable. A removed UUID
  may be added again with the same object.
- Links in text use `attachment:<uuid>`.

A comment with an image:

```
Here's what it looks like on a small screen.

X-Attachment: 5b0c4e0e-2b8a-4f5e-9d39-6c1c1f0f2a77 image/png 45 sha256:<hex> login.png
```

**Bytes.** The trailer is the source of truth. The bytes are LFS objects,
named by their sha256:
- in this tool's store, `$GIT_DIR/issuez/lfs/objects/ab/cd/<sha256>` (the
  git common dir). `git lfs prune` doesn't touch it;
- copied to git-lfs's store (`$GIT_DIR/lfs/objects`, or `lfs.storage`)
  for transfers. Any copy whose hash matches is valid.

**Derived ref.** `refs/attachments/<issue-uuid>` makes the objects visible
to git-lfs and LFS servers. It holds no data of its own and can always be
rebuilt:
- each commit's tree has one entry per present attachment,
  `<attachment-uuid>.<png|jpg|webp>` (mode 100644), whose blob is the LFS
  pointer

  ```
  version https://git-lfs.github.com/spec/v1
  oid sha256:<hex>
  size <size>
  ```
- message `Regenerate attachments`, then `X-Issue: <issue-uuid>` and
  `X-Issue-Tip: <issue tip it was derived from>`;
- author and committer `git-issue <git-issue@invalid>`, dated with that
  issue tip's committer time, offset `+0000`; parents sorted by OID;
- it only moves forward: a new commit has the previous tip (and, after a
  sync, the remote's) as parents.

It is *stale* when its tree differs from what the present attachments
derive. A newer issue tip alone is not stale. Writes that change the
attachments move it in the same transaction as the issue ref.

## 8. Sync

`git issue merge <remote>` fetches the remote's issues into
`refs/remotes/<remote>/issues/` and compares each one with the local issue.
Only refs named by a UUID there are issues: a remote branch `issues/...`,
which git's default refspec also tracks there, is left alone. Milestones
sync the same way, through `refs/remotes/<remote>/milestones/`, with the
same outcomes: `status` lists a quarantined milestone and `quarantine`
resolves it like an issue.

- no local issue: created;
- local is an ancestor of remote: fast-forwarded;
- remote is an ancestor of local: nothing to do, the next push sends it.
  This includes a remote reset to an older tip: nothing is lost;
- both moved: a merge commit (§4) with both tips as parents;
- no shared root, a remote that no longer contains the tip merged last time
  and isn't contained in the local issue either (rewritten history), or an
  issue that fails `fsck`: **quarantined**. The local issue is left as it
  is and the remote version is reported, until `git issue quarantine`
  resolves it.

`git issue push <remote>` first fetches the remote's issue refs to see
what it has, then pushes the local issues and milestones that differ, in
atomic batches and never with force. When the remote moved, it merges and
tries again, a bounded number of times. A ref the remote refuses (a hook,
permissions) fails the push with the remote's message. `git issue sync` is
merge, then push.

Derived attachment refs (§7) are fetched into
`refs/remotes/<remote>/attachments/` but never merged. After the merge,
each issue's derived ref is rebuilt from the merged issue: it
fast-forwards to the remote's when that one is right, and otherwise gets a
new commit on top of both. A remote derived ref that isn't a commit is
ignored. A push first uploads the LFS objects the remote's derived refs
don't list yet (with `git lfs push`), then sends each derived ref in the
same atomic batch as its issue. If the upload fails, nothing is pushed.
The derived refs of quarantined issues are not pushed. Bytes are never
downloaded during a sync.

### Bookkeeping refs

These refs are local and never pushed. Losing them only costs extra work on
the next sync. Milestones have the same refs, with `milestones` in place of
`issues`. Derived attachment refs only have `pushed` and `seen`:
- `refs/issuez-sync/<remote>/merged/issues/<uuid>`: the remote tip last
  merged, used to detect rewritten history;
- `.../pushed/issues/<uuid>`: the tip the remote has;
- `.../quarantined/issues/<uuid>`: a refused remote tip;
- `.../kept/issues/<uuid>`: a refused remote tip the user chose to ignore
  (`quarantine --keep-local`);
- `.../replaced/issues/<uuid>/<tip>`: each local tip replaced by
  `quarantine --accept-remote`, so no version is ever dropped;
- `.../seen/issues/<uuid>`: where `push` fetches the remote's refs, deleted
  right after.

## 9. Compatibility

- Upstream reads every issue written here as format 1: `ls`, `show` and
  `fsck` work, and the extension trailers show as plain trailer lines.
- Upstream's writes (comments, edits, state changes, merges) never lose
  data, extension fields included, because fields come from the whole
  history and a missing trailer never clears a field.
- Upstream doesn't know events or `X-Deleted`: it lists deleted issues and
  shows edited and deleted comments as they were first written, followed by
  the event commits.
- Upstream doesn't know milestones. It neither syncs `refs/milestones/*`
  nor checks the milestone guards. Issues that travel through upstream keep
  their `X-Milestone-Id`, which stays unresolved (and is reported) until
  the milestone itself arrives through this tool's sync. Upstream shows the
  `Milestone` name written next to it.
- Upstream doesn't know attachments. It shows the `X-Attachment` trailers
  as plain lines and keeps them through its writes and merges, but it
  doesn't sync `refs/attachments/*` or the bytes. Issues that travel
  through upstream keep their attachments: this tool rebuilds the derived
  ref, and the bytes come from any clone that pushed them with git-lfs.
- Clones can sync through either tool. Upstream's `merge` and this tool's
  read each other's merge commits, and the `refs/issuez-sync/` refs are
  invisible to upstream.
- Provider bridges (import and export) are upstream's for now. Their
  trailers (`Provider-ID`, `Provider-Comment-ID`, `Exported-Commit`,
  `Parent-ID`) are kept and never written here.
