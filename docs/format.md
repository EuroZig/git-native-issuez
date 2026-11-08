# Format

The format git-native-issuez reads and writes. It is
[git-native-issue](https://github.com/remenoscodes/git-native-issue)'s
format 1 (its `ISSUE-FORMAT.md`) with additive extensions. Every issue this
tool writes stays a valid format-1 issue, and upstream's `fsck` passes on it.
For attachments' library and CLI side see [attachments.md](attachments.md).

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Refs

| Ref | Content |
| --- | --- |
| `refs/issues/<uuid>` | an issue |
| `refs/milestones/<uuid>` | a milestone (§6) |
| `refs/attachments/<uuid>` | LFS pointers for the attachments of issue `<uuid>`, derived (§7) |
| `refs/issuez-purged/<uuid>` | the tombstone of issue `<uuid>`: what was purged from it (§10) |
| `refs/remotes/<remote>/{issues,milestones,attachments}/<uuid>` | refs a plain `git fetch` brought, read by `merge --no-fetch` |
| `refs/issuez-sync/<remote>/<kind>/{issues,milestones,attachments}/<uuid>` | sync bookkeeping, local only (§8) |
| `refs/issuez-guard/<uuid>`, `refs/issuez-guard/number-<n>` | write serialization, local only (§3, Guards) |
| `refs/issuez-cache/parents` | every issue's parent, a local cache (§3, Guards) |

UUIDs are lowercase, hyphenated, version 4. Readers MUST NOT read data from
any ref other than `refs/issues/*` and `refs/milestones/*`, except that
writers and sync apply `refs/issuez-purged/*` (§10).
`refs/attachments/*` holds no data of its own and can always be rebuilt.

`git issue merge`, `push` and `sync` fetch into
`refs/issuez-sync/<remote>/seen/` (§8), and `git fetch` after
`git issue init` into `refs/remotes/<remote>/issues/`, `.../milestones/`
and `.../attachments/`. Neither writes `refs/issues/`, `refs/milestones/`
or `refs/attachments/` directly.

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
- `X-Original-Author` and `X-Original-Id` say where imported text came
  from: its author and ID in the tracker it was imported from. They
  describe their commit (the root for the issue, a comment for the
  comment), like the provider bridges' trailers, and are not fields.
- `X-Author-Id: <uuid>` is the host's identity of the commit's author:
  the user behind the name and email, which may change. A host writes it
  on every commit its users make; readers report it as the author's user
  ID. Only canonical UUIDs count. It describes its commit and is not a
  field, and a commit that adds nothing but it changes nothing (§3). A
  host's push check accepts it only from the user it names (§11).
- Hosts may keep fields of their own under `X-` keys the format doesn't
  use (`X-Forgejo-Project`). They are scalar fields like any other:
  merged by §4, kept by every tool, interpreted by none.
- `X-Message: comment` says that the commit's message (subject and body,
  without the trailer block) is a comment someone wrote, even when the
  commit also sets fields. Without it, a commit whose only text is its
  subject and that sets fields reads as the writer's own description of
  the change ("Close issue"), as format 1 does. Writers add it whenever a
  comment and field trailers share a commit. It describes its commit and
  is not an issue field. A description edit (§5) can't carry a comment:
  its text is the description.
- `X-Purged: true` and `X-Rewritten-From: <full oid>` are written by a
  purge (§10). They describe their commit and are not fields.

A comment that closes the issue in the same commit:

```
Fixed in 1a2b3c4.

State: closed
Fixed-By: 1a2b3c4
X-Message: comment
```

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
| `X-Number` | scalar | the issue's number in its host (`#12`): decimal from 1, no leading zeros, at most 2^53 |
| `X-Locked` | scalar | `true` or `false` |
| `X-Lock-Reason` | scalar | text, why it is locked; cleared when unlocking |
| `X-Ref` | scalar | the branch or tag the issue is about (`main`, `refs/tags/v1`): a valid git ref name |
| `X-Assignees` | set | several assignees, each as `Assignee`, comma-separated |
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
- The assignees are the members of `X-Assignees`, in order. A commit that
  isn't a merge and writes `Assignee` without `X-Assignees`, as upstream
  (which knows one) does, sets them to that one, or to none when it is
  empty. Merges restate `Assignee` and don't count. Writers write
  `Assignee` with the first assignee (empty for none), and `X-Assignees`
  with all of them only when there are two or more: one alone is format 1
  as it is. Removing one by email removes the `<uuid> <email>` member too.
- An `Assignee` whose first word isn't a UUID is an email as a whole, as
  format 1 reads it.
- A lock is information for hosts, which decide who may still comment;
  this tool doesn't refuse writes to a locked issue.
- `X-Number` is written once: writers refuse to change it, and to give a
  number another issue in the clone has. Two clones can still give the
  same number (or two numbers to one issue, which §4 resolves); readers
  report duplicates (`ls --problems`). `#12` names an issue by number
  wherever an ID is taken. The UUID form names a person independently of their
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
child. Giving a number moves `refs/issuez-guard/number-<n>`, so two writers giving the same number in one clone conflict. Milestones work the same way: changing what is in a milestone and
completing it both move the milestone's guard ref. The guard refs carry no
data, are never pushed, and can be deleted at any time.

To find an issue's sub-issues without reading every issue, guards use
`refs/issuez-cache/parents`: a blob with a header line
`issuez-parents 2`, then one line per issue,
`<uuid> <tip> -|=<parent> #-|#<number>` (no parent or its parent, no
number or its `X-Number`). Guards and `#12` lookups read it. A line counts
only while `<tip>` is still the issue's tip; other issues are read. A write
that read it rewrites it after succeeding, once enough lines are stale, and
`show` rewrites it when it is missing or stale. It is local, never pushed,
and can be deleted at any time.

Other tools and concurrent clones can still produce violations; readers
report them and never fail on them.

## 4. Merging: the causal ordering rule

An issue can have merge commits, written by this tool's `merge`, by
upstream's or by hand.
A field's value is computed from the whole DAG, never from the tip alone.
Every value remembers its *setters*: the latest commits that set it, none
an ancestor of another. Walking commits parents first:
- a commit's explicit trailers set fields;
- at a merge, the setters of both sides are pooled, and those that another
  setter descends from drop out: a descendant wins, whatever the clocks
  say. When concurrent setters remain, the one with the later author time
  wins, then the larger OID. When they disagree, that is a **conflict**,
  derived when reading and never stored (`git issue ls --conflicts`);
- a merge commit's own trailers apply after the merge. Restating the value
  the merge resolved to keeps a conflict visible; a different value resolves
  it.

Keeping every latest setter matters after a merge: a later change on one
branch replaces only that branch's setter, so a concurrent setter on the
other branch still counts, even when the later change's clock is behind.

Sets (`Labels`, `X-Blocked-By`): each member's presence has its own
setters, the latest commits that changed it.
A set trailer lists the whole set, adding and removing relative to the
parent state. A concurrent add and remove resolves to add, also when the
add was made on two branches and only one of them saw the removal. Keyed sets
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
  attachments and events follow from the parents;
- when the remote's tip has a number and the parents resolve to another
  (or to none readable), `X-Number` follows with the remote's: a host keeps
  the number it gave out, and refuses a push that changes it (§11).

Restating the values lets upstream, which reads the newest trailer it
finds, show the merged state, extension fields included. For this tool
restating changes nothing: the merge reads as its parents do. The kept
number is the exception, and the one thing a merge reads from which side
is the remote: clones that merge the same pair write the identical commit
as long as they merge it from the same remote.

## 5. Events

Lifecycle changes are commits carrying `X-Event`, at most one per commit:

| Event | Trailers | Message text |
| --- | --- | --- |
| edit a comment | `X-Event: comment-edit`, `X-Comment: <full oid>` | the full new comment |
| delete a comment | `X-Event: comment-delete`, `X-Comment: <full oid>` | none |
| restore a comment | `X-Event: comment-restore`, `X-Comment: <full oid>` | none |
| edit the description | `X-Event: description-edit` | the full new description |
| delete or restore the issue | `X-Deleted: true` or `false` (an ordinary field) | none |
| react | `X-Event: reaction`, `X-Reaction: +<emoji>` or `-<emoji>`, and `X-Comment: <full oid>` for a comment's | none |

- A comment's ID is the full OID of its commit (40 or 64 hex digits;
  abbreviations are invalid). The target MUST be a non-root, non-merge,
  non-event commit of the same issue.
- Events are resolved by §4 per target. Delete hides a comment; restore, or
  any later edit, shows it again.
- An event whose target isn't in the DAG yet is kept and applies once sync
  brings the target in. An event whose target belongs to another issue is
  invalid.
- A reaction is its author's: `+` adds the author's (by email) reaction
  with that emoji to the issue, or with `X-Comment` to that comment, `-`
  takes it back. The emoji is a name like `:+1:` or the character itself,
  1 to 64 bytes without whitespace or commas. Per (target, emoji, email)
  §4 applies as to a set member: a concurrent add and take-back resolve
  to add. Writers don't write a reaction that changes nothing.
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
derive, or when the tip its `X-Issue-Tip` names is no longer in the
issue's history (the history was replaced). A newer issue tip alone is
not stale. Writes that change the
attachments move it in the same transaction as the issue ref.

## 8. Sync

`git issue merge <remote>` fetches the remote's issues into
`refs/issuez-sync/<remote>/seen/issues/` and compares each one with the
local issue (`--no-fetch` takes them from `refs/remotes/<remote>/issues/`
instead). Only refs named by a UUID there are issues: a remote branch
`issues/...`, which git's default refspec also tracks there, is left alone.
An issue whose remote tip is the local tip and the one merged last is
already up to date and isn't checked again. Milestones sync the same way,
through `.../seen/milestones/`, with the
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
what it has (`sync` reuses the merge's fetch), then pushes the local issues and milestones that differ, in
atomic batches and never with force. When the remote moved, it merges and
tries again, a bounded number of times. A ref the remote refuses (a hook,
permissions) fails the push with the remote's message. `git issue sync` is
merge, then push.

Derived attachment refs (§7) are fetched into `.../seen/attachments/` but
never merged. After the merge,
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
- `.../seen/issues/<uuid>`: the remote's ref as of the last fetch by
  `merge`, `push` or `sync`. It stays between syncs, so a fetch only writes
  the refs that changed, and refs the remote no longer has are pruned.

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
- Concurrent edits can resolve differently. Upstream's `merge` compares
  each side with one merge base and, when both changed a field, takes the
  side whose tip has the later author time; this tool keeps every latest
  setter (§4). They agree when clocks are right. They can differ when a
  later edit on one branch carries an older clock than a concurrent edit
  on the other, and in criss-cross histories. Either tool's merge commit
  restates its result, so the other tool then shows the same value.
- Provider bridges (import and export) are upstream's for now. Their
  trailers (`Provider-ID`, `Provider-Comment-ID`, `Exported-Commit`,
  `Parent-ID`) are kept and never written here.

## 10. Purge

Deleting (§5) hides an issue or a comment and keeps it in history. A purge
removes it, for abuse or a legal request, and is the only write that
rewrites history.

- **An issue**: its ref is deleted, with its derived attachment ref, its
  guard refs and every local ref under `refs/remotes/` and
  `refs/issuez-sync/` that names it, but sync's `seen/`: those are the
  remote's refs as last fetched, which the next push replaces and the next
  fetch updates.
- **A comment**: its commit loses its text, attachments and origin, and
  the issue's history is rewritten from there by the rule below. Its
  fields stay. The derived attachment ref is rebuilt with no history, and
  the local refs under `refs/remotes/` and `refs/issuez-sync/` that name
  the issue are deleted, `seen/` again excepted. The root (title and
  description) can't be purged this way: purge the issue.

The rewrite is a function of the issue's commits and the set of purged
comments, so every clone that applies the same purges gets the same
commits, and applying it again changes nothing. Commits are rewritten in
causal order, an event after the comment it targets:
- a purged comment becomes `Purged comment`, no body, its trailers minus
  `X-Attachment`, `X-Attachment-Removed`, `X-Original-Author`,
  `X-Original-Id` and `Provider-Comment-ID`, then `X-Purged: true` and
  `X-Rewritten-From`;
- an edit event targeting it becomes `Edit comment`, body `Purged comment`,
  trailers treated the same way;
- every other commit whose parent or `X-Comment` target was rewritten keeps
  its message, with the `X-Comment` lines pointing at the new target and
  `X-Rewritten-From` added to its trailer block (a new paragraph when it
  has none);
- a merge commit with a rewritten parent, when one of its new parents now
  has the others in its history, is dropped and the commits after it take
  that parent: it merges nothing any more;
- this tool's own merge commit (§4) with a rewritten parent that isn't
  dropped restates what its new parents resolve to, with `Labels` and
  `X-Blocked-By` sorted by bytes, keeps an `X-Number` that differs from
  it, and adds `X-Rewritten-From`: what it restated before could override
  newer values, now that the history changed;
- other commits keep their IDs. Author, committer and dates never change.

`X-Rewritten-From` is the commit's ID before any purge, and a rewrite keeps
it. Tombstones name comments by that first ID, so a purge recorded after
another one moved the comment finds it in every clone.

The tombstone `refs/issuez-purged/<uuid>` is a chain of empty-tree commits,
one per purge, by the purger:

```
Purge comment

X-Purge: comment
X-Purged-Commit: 5186cff79af42ee5c6a80d822eec95a842832b34
Reason: abuse
```

`X-Purge: issue` purges the whole issue and has no `X-Purged-Commit`.
`Reason` is optional. A tombstone says what its whole history says: the
issue is purged if any commit says so, and the purged comments are the
union. Commits that don't read as purges are ignored.

Sync fetches `refs/issuez-purged/*` with the issues and merges tombstone
chains like issues: a fast-forward, or a merge commit `Merge purges` by
`git-issue <git-issue@invalid>`, parents sorted by ID, dated like the
later parent. Then it applies every tombstone: it purges the local issue
the same way, rewrites a remote tip before comparing it with the local
one, and never brings back a purged issue or commit. Merge and push apply
every local tombstone again first, so purged text that came back another
way (upstream's merge, a plain fetch) goes again. A push sends the
tombstone in the same atomic batch as the issue. When the remote's issue
or derived ref still has purged history, the push replaces it, leased on
the tip just fetched (`--force-with-lease`); this is the only push that
isn't a fast-forward, and only a tombstone allows it. It first merges
whatever the remote's tip, purged, has that the local one doesn't, so the
replace loses nothing. A purged issue's remote ref is deleted the same
way. Anyone who can push tombstones can purge every clone: hosts should
limit who may (§11).

Other issues' references to a purged issue (`X-Parent`, `X-Blocked-By`)
dangle afterwards; readers report them like any missing issue, and a
dangling parent counts as none.

A purge can't reach copies outside this tool's sync: clones that never
sync, plain `git fetch` copies, and the LFS bytes of a purged attachment,
which stay on the LFS server and in local LFS stores until pruned. The old
objects stay in the local object store until `git gc` prunes them.
Upstream doesn't know tombstones: its merge can bring purged commits back,
and the next sync here purges them again.

## 11. Push check

A host that takes pushes can check them before it accepts them, in its
pre-receive hook: `git issue push-check` reads the hook's input, and
`issuez_push_check` takes the same updates. The check judges the format
only. Who may push what (permissions, locked issues) stays the host's to
decide, from facts the verdicts report. Objects are read from the push's
quarantine (`GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`),
and nothing is written. A push is accepted when every update is.

Each update `<old> <new> <ref>` gets a verdict:
- refs outside `refs/issues/`, `refs/milestones/`, `refs/attachments/` and
  `refs/issuez-*` are ignored: they are the host's business;
- the local-only refs (`refs/issuez-*` other than `refs/issuez-purged/`)
  and names under these prefixes that aren't a canonical UUID are
  rejected;
- a delete, and an update whose old tip isn't an ancestor of the new one,
  are rejected, except for purges (below).

An issue or milestone update is rejected when the new tip fails `fsck`
(every commit the empty tree, one root, with `State` or `Name`, and
`Format-Version`), when the history can't be read within the limits, or
when the root's `Format-Version` isn't `1`. Then, for the *new* commits,
those the old tip doesn't have:
- **Numbers.** `X-Number` is the host's to give: a new commit that carries
  it (other than restating the issue's number) is rejected, unless the
  host lets clients number. Then a number may not differ from one the
  issue had, nor be another issue's in the repo, nor be given to two
  issues in the same push. The verdict says when an issue has no number,
  so the host can give it one once the push is in.
- **Authors.** Under the host's author policy `warn` a new commit whose
  author email isn't one of the pusher's (compared ignoring case) is
  flagged, under `enforce` rejected; `any` checks nothing. So is a new
  commit whose `X-Author-Id` isn't one of the pusher's UUIDs, whatever its
  email: with no UUIDs given, every `X-Author-Id` is someone else's.
  Merge commits by `git-issue <git-issue@invalid>` are exempt: sync
  writes them.
- **Locks.** The verdict says when new commits go to an issue locked at
  its old tip.
- **Purges.** An issue that a tombstone purges can't be created or
  updated, and a new tip whose history the tombstone's comments would
  still rewrite (§10) is rejected. The tombstones are the repo's together
  with the ones in the same push.

A tombstone update is rejected unless the host lets the pusher purge. It
must be a fast-forward, and every new commit has the empty tree and reads
as a purge (`X-Purge: issue`, or `X-Purge: comment` with an
`X-Purged-Commit` that is a full ID), or is a `Merge purges` merge by
`git-issue <git-issue@invalid>`. With such a tombstone after the push, and
the host's leave to purge:
- an issue it purges may have its ref and derived ref deleted;
- an issue ref may move to a tip that isn't a descendant of the old one if
  the new tip's history has the old tip rewritten by the tombstone's
  comments;
- the issue's derived ref may move the same way.

An update of `refs/attachments/<uuid>` is rejected unless its new tip is
exactly what §7 derives: message `Regenerate attachments` with
`X-Issue: <uuid>` and `X-Issue-Tip`, which names a commit in the issue's
history after the push; identity `git-issue <git-issue@invalid>` dated
like that commit, offset `+0000`; parents sorted; and a tree that is the
pointers of the attachments present at that commit. The other new commits
need only hold pointers: every entry `<uuid>.<png|jpg|webp>`, an LFS
pointer blob (they may name tips a replaced history dropped). The LFS
bytes are not checked: they are the host's LFS server's.
