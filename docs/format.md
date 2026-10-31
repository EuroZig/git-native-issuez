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
| `refs/remotes/<remote>/issues/<uuid>` | fetched issues, waiting to be merged |
| `refs/issuez-sync/<remote>/<kind>/issues/<uuid>` | sync bookkeeping, local only (§6) |

UUIDs are lowercase, hyphenated, version 4. Readers MUST NOT read issue
data from any ref other than `refs/issues/*`.

`git issue merge`, `sync` and `git fetch` after `git issue init` fetch into
`refs/remotes/<remote>/issues/`, never straight into `refs/issues/`.

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
  know them. They appear as plain fields in `show`.
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
| `X-Parent` | scalar | issue UUID |
| `X-Blocked-By` | set | issue UUIDs, comma-separated |
| `X-Start-Date`, `X-Due-Date` | scalar | `YYYY-MM-DD`, a real calendar day |
| `X-Estimate-Minutes` | scalar | decimal minutes, `0` allowed, no leading zeros, at most 10 × 366 days |
| `X-Workflow-State` | scalar | slug: lowercase letter, then lowercase letters, digits, `-` (at most 64 bytes) |
| `X-Deleted` | scalar | `true` or `false` |
| `X-Event`, `X-Comment` | event | §5 |

- Keys match case-insensitively, as in git.
- A value that doesn't follow its grammar is ignored on read and reported
  (`fsck`, `ls --problems`).
- An `Assignee` whose first word isn't a UUID is an email as a whole, as
  format 1 reads it. The UUID form names a person independently of their
  address; upstream shows the whole value.
- References (`X-Parent`, `X-Blocked-By`) are full UUIDs. Whether the target
  exists, cycles and depth are questions across issues, answered when
  reading (the projection, `ls --problems`, `tree`), never by refusing to
  read.
- Any `State` but `open` counts as done (`wontfix`, `duplicate`, ...).
  `ls` hides it by default, as upstream does, and parents, blockers,
  progress and the guards treat it as closed.
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
- delete an issue with sub-issues that aren't deleted.

Each issue a guard reads is pinned in the same ref transaction (git's
`update-ref` `verify`), so a concurrent change to any of them aborts the
write, which is then retried. Other tools and concurrent clones can still
produce violations; readers report them and never fail on them.

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
parent state. A concurrent add and remove resolves to add. Events follow the
same rule per target comment (§5).

No merge base is needed, and criss-cross histories are well defined.

### Merge commits

This tool's merge commits are deterministic, so clones that merge the same
pair write the identical commit:
- subject `Merge issue`, two parents sorted by OID, the empty tree;
- author and committer `git-issue <git-issue@invalid>`, both dated with the
  later parent's committer time, offset `+0000`;
- trailers restate the resolved, non-empty fields, as written (invalid
  values too), in this order: `State`, `Title` (only when it overrides the
  root subject), `Labels`, `Assignee`, `Priority`, `Milestone`, then
  `X-Parent`, `X-Start-Date`, `X-Due-Date`, `X-Estimate-Minutes`,
  `X-Workflow-State`, `X-Deleted`, `X-Blocked-By`. Other fields and events
  follow from the parents.

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

## 6. Sync

`git issue merge <remote>` fetches the remote's issues into
`refs/remotes/<remote>/issues/` and compares each one with the local issue.
Only refs named by a UUID there are issues: a remote branch `issues/...`,
which git's default refspec also tracks there, is left alone.

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
what it has, then pushes the local issues that differ, in atomic batches
and never with force. When the remote moved, it merges and tries again, a
bounded number of times. A ref the remote refuses (a hook, permissions)
fails the push with the remote's message. `git issue sync` is merge, then
push.

### Bookkeeping refs

These refs are local and never pushed. Losing them only costs extra work on
the next sync:
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

## 7. Compatibility

- Upstream reads every issue written here as format 1: `ls`, `show` and
  `fsck` work, and the extension trailers show as plain trailer lines.
- Upstream's writes (comments, edits, state changes, merges) never lose
  data, extension fields included, because fields come from the whole
  history and a missing trailer never clears a field.
- Upstream doesn't know events or `X-Deleted`: it lists deleted issues and
  shows edited and deleted comments as they were first written, followed by
  the event commits.
- Clones can sync through either tool. Upstream's `merge` and this tool's
  read each other's merge commits, and the `refs/issuez-sync/` refs are
  invisible to upstream.
- Provider bridges (import and export) are upstream's for now. Their
  trailers (`Provider-ID`, `Provider-Comment-ID`, `Exported-Commit`,
  `Parent-ID`) are kept and never written here.
