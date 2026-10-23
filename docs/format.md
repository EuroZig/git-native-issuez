# Format

The format git-native-issuez reads and writes. It is
[git-native-issue](https://github.com/remenoscodes/git-native-issue)'s
format 1 (its `ISSUE-FORMAT.md`). Every issue this tool writes is a valid
format-1 issue, and upstream's `fsck` passes on it.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Refs

| Ref | Content |
| --- | --- |
| `refs/issues/<uuid>` | an issue |
| `refs/remotes/<remote>/issues/<uuid>` | fetched issues, waiting to be merged |
| `refs/issuez-sync/<remote>/<kind>/issues/<uuid>` | sync bookkeeping, local only (§5) |

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
  one. Upstream's readers skip empty values, so a cleared field may still
  show the old value there.
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
| `Assignee` | scalar | an email address |
| `Priority` | scalar | `low`, `medium`, `high`, `critical` |
| `Milestone` | scalar | free text |
| `Fixed-By`, `Release`, `Reason` | scalar | text (upstream's `state` options) |

Keys match case-insensitively, as in git.

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

`Labels` is a set: each label's presence has its own setter. A `Labels`
trailer lists the whole set, adding and removing relative to the parent
state. A concurrent add and remove resolves to add.

No merge base is needed, and criss-cross histories are well defined.

### Merge commits

This tool's merge commits are deterministic, so clones that merge the same
pair write the identical commit:
- subject `Merge issue`, two parents sorted by OID, the empty tree;
- author and committer `git-issue <git-issue@invalid>`, both dated with the
  later parent's committer time, offset `+0000`;
- trailers restate only the resolved, non-empty fields: `State`, `Title`
  (only when it overrides the root subject), `Labels`, `Assignee`,
  `Priority`, `Milestone`. Other fields follow from the parents.

Restating the values lets upstream, which reads the newest trailer it
finds, show the merged state.

## 5. Sync

`git issue merge <remote>` fetches the remote's issues into
`refs/remotes/<remote>/issues/` and compares each one with the local issue:

- no local issue: created;
- local is an ancestor of remote: fast-forwarded;
- remote is an ancestor of local: nothing to do, the next push sends it;
- both moved: a merge commit (§4) with both tips as parents;
- no shared root, a remote that no longer contains the tip merged last time
  (rewritten history), or an issue that fails `fsck`: **quarantined**. The
  local issue is left as it is and the remote version is reported, until
  `git issue quarantine` resolves it.

`git issue push <remote>` first fetches the remote's issue refs to see
what it has, then pushes the local issues that differ, in atomic batches
and never with force. When the remote moved, it merges and tries again, a
bounded number of times. `git issue sync` is merge, then push.

### Bookkeeping refs

These refs are local and never pushed. Losing them only costs extra work on
the next sync:
- `refs/issuez-sync/<remote>/merged/issues/<uuid>`: the remote tip last
  merged, used to detect rewritten history;
- `.../pushed/issues/<uuid>`: the tip the remote has;
- `.../quarantined/issues/<uuid>`: a refused remote tip;
- `.../kept/issues/<uuid>`: a refused remote tip the user chose to ignore
  (`quarantine --keep-local`);
- `.../replaced/issues/<uuid>`: the local tip replaced by
  `quarantine --accept-remote`, so no version is ever dropped;
- `.../seen/issues/<uuid>`: where `push` fetches the remote's refs, deleted
  right after.

## 6. Compatibility

- Upstream reads every issue written here: `ls`, `show` and `fsck` work.
- Upstream's writes (comments, edits, state changes, merges) never lose
  data, because fields come from the whole history and a missing trailer
  never clears a field.
- Clones can sync through either tool. Upstream's `merge` and this tool's
  read each other's merge commits, and the `refs/issuez-sync/` refs are
  invisible to upstream.
- Provider bridges (import and export) are upstream's for now. Their
  trailers (`Provider-ID`, `Provider-Comment-ID`, `Exported-Commit`,
  `Parent-ID`) are kept and never written here.
