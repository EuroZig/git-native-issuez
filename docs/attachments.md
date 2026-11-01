# Attachments

Images on issues: PNG, JPEG and WebP (no animation), at most 5 MiB each and
30 per issue by default (`Limits.max_attachment_bytes`,
`Limits.max_attachments`). This page covers the CLI and the library
interface a GUI or another program uses. The format is in
[format.md](format.md) §7; a complete program is
[examples/attachments.zig](../examples/attachments.zig)
(`zig build example-attachments`).

## CLI

```
git issue attach add <issue> <file>... [-m <comment>] [--name <name>]
git issue attach ls <issue>
git issue attach cat <issue> <attachment> > out.png
git issue attach rename <issue> <attachment> <name>
git issue attach rm <issue> <attachment>...
git issue attach fetch [<issue>] [--remote <remote>]
git issue comment <issue> -m <text> --attach <file>
git issue fsck [--repair]
```

An attachment is named by a unique prefix of its ID (at least 4
characters). `show` lists the attachments, and each comment names the
images it added. `cat` downloads missing bytes by itself.

Attachments need [git-lfs](https://git-lfs.com). Without it, every
`attach` subcommand, `comment --attach` and `fsck --repair` refuse before
doing anything, and `fsck` notes that it didn't check the bytes. `show`
still lists the attachments, and issues still sync.

`git issue sync` and `push` upload the bytes with `git lfs push`, before
any ref goes out, so the remote needs an LFS server (GitHub, GitLab, Gitea
and Forgejo have one). When the upload fails, nothing is pushed. Only
objects the remote's derived ref doesn't list yet are uploaded. Bytes are
never downloaded during a sync: `attach cat` and `attach fetch` get them
when they are needed.

## Where things live

| What | Where | Role |
| --- | --- | --- |
| `X-Attachment` / `X-Attachment-Removed` trailers | the issue's commits (`refs/issues/<uuid>`) | source of truth: ID, media type, size, sha256, name |
| the bytes | `$GIT_DIR/issuez/lfs/objects/ab/cd/<sha256>` | this tool's store; `git lfs prune` never touches it |
| a copy of the bytes | `$GIT_DIR/lfs/objects/...` (git-lfs's store, or `lfs.storage`) | mirror for `git lfs push` and `fetch`; safe to prune |
| `refs/attachments/<issue-uuid>` | one commit, a tree of LFS pointer files | derived, so git-lfs and LFS servers see the objects; rebuilt at will |

The store sits outside git-lfs's directory because `git lfs prune` deletes
objects that only custom refs reference. In a repository without a remote,
that would delete the only copy. `test/cli_git.zig` checks that the bytes
survive `git lfs prune`.

Upstream git-native-issue sees ordinary format 1 issues: its `fsck` passes,
its `show` shows the trailer lines, and its comments, edits and merges keep
the attachments.

## API

```zig
const issuez = @import("issuez");
const Attachments = issuez.Attachments(issuez.backend.GitProcess);

const att = Attachments.fromRepo(repo); // shares repo.limits
```

Everything takes and returns **bytes**, never paths. `att.ready(arena)`
fails with `LfsUnavailable` when git-lfs isn't installed. Every call
below that reads or writes attachments checks it first; call it yourself
to refuse before reading any file.

### Writing

| Call | Does |
| --- | --- |
| `att.validate(input) !Media` | what `add` would accept, without writing (call it on drop or paste) |
| `att.add(arena, issue_ref, .{ .files, .comment, .author, .expect }) !Added` | stores the bytes, then one commit with one `X-Attachment` per file, plus the comment text if given; returns the new tip and the new IDs in input order |
| `att.rename(arena, issue_ref, id, name, .{}) !Oid` | new name, same object |
| `att.remove(arena, issue_ref, ids, .{}) !Oid` | hides them; the bytes stay, since history references them |

`Input` is `{ .name, .data, .media = null }`. The name is sanitised: last
path component, no control characters, at most 255 bytes. `media` is
optional; if given, it must match the bytes.

The issue ref and `refs/attachments/<uuid>` move in one `update-ref`
transaction, and the derived commit is rebuilt on every compare and swap
retry. `expect` works as for every `Repo` write: the write only applies on
top of that version.

Errors a GUI can tell apart: `UnsupportedType`, `AnimatedImage`,
`MediaMismatch`, `EmptyAttachment`, `AttachmentTooLarge`,
`TooManyAttachments` (only when adding: removing works on an issue over
the limit), `AttachmentNotFound`, `NoAttachments`, `LfsUnavailable`, and
`AttachmentsUnsupported` (a backend without LFS operations).

### Reading

The model has everything that needs no bytes:

- `issue.attachments` holds the present attachments, oldest first. Each has
  `id`, `media`, `size`, `sha256`, `name`, `added_in` (commit) and
  `added_by`.
- `issue.removed_attachments` holds the removed ones; their bytes are still
  referenced.
- `comment.attachments` lists the IDs that comment added, so a GUI can show
  the images inline with it.
- `issue.attachment_problems` lists ignored trailers: malformed ones, or
  ones that change a UUID's object.

To get the bytes:

```zig
switch (try att.read(arena, a)) {
    .bytes => |b| render(b),      // verified against the trailer's sha256 and size
    .missing => offerFetch(),     // not in this clone yet
    .corrupt => warnDamaged(),    // stored bytes don't match
}
```

`read` looks in this tool's store first, then in git-lfs's store, and
copies a good copy it finds there into its own, also over a damaged one. `att.list(arena, issue)` gives
every attachment with its `availability` (`local`, `missing`, `corrupt`).
`Attachments.find(arena, issue, prefix)` resolves an ID prefix of at least
4 characters.

### Maintenance

- `att.derivedState(arena, issue)` returns `.ok`, `.absent` or `.stale`. A
  clone with upstream's refspec has no `refs/attachments/*`, and upstream
  merges don't rebuild it.
- `att.repair(arena, issue)` rebuilds the derived ref and returns whether
  it moved. It never touches the issue ref.
- `att.orphans(arena, issues)` lists stored objects that no issue
  references. A write that failed after storing the bytes leaves one.
- `att.uploads(arena, attachments, mode)` returns the bytes this clone has,
  and with `.git_lfs` also copies them into git-lfs's store (so
  `git lfs push` finds them); sync uses it before a push.
- `att.fetch(arena, remote, issues)` brings the derived refs in line, then
  downloads missing bytes (`git lfs fetch <remote> refs/attachments/<id>`)
  and stores them. `FetchReport.missing` lists what is still missing, and
  `transfer_failed` says git-lfs failed for some of it.
- `att.reconcile(arena, issue, remote_derived_tip)` is what sync runs after
  a merge.

### Sync

`Sync.sync`, `push` and `merge` handle attachments:

- merges fetch the remote's `refs/attachments/*` and reconcile them with
  the merged issues;
- pushes upload the bytes before the refs, with `git lfs push`. With
  `Sync.pushWith(arena, remote, .{ .before_push = hook })` (or `syncWith`),
  your hook receives the objects instead, for example to upload them
  through your own LFS client. If the hook fails, nothing is pushed;
- without a hook, objects to upload and no git-lfs fail the push with
  `LfsUnavailable`, and a failed `git lfs push` with `LfsUploadFailed`,
  both before any ref is pushed. A push with nothing to upload needs no
  git-lfs;
- `PushReport.lfs_uploaded` counts the objects handed over.

Bytes are never downloaded during a sync. Call `att.fetch` when an image is
shown, or for a whole list up front.

### Custom backends

The LFS operations are optional in the backend contract
(`contract.hasLfs`):

```zig
fn lfsRead(self, arena, LfsStore, sha256_hex) Error!?[]const u8
fn lfsWrite(self, LfsStore, sha256_hex, data) Error!void   // atomic, replaces
fn lfsList(self, arena, LfsStore) Error![]const []const u8
// and, to move objects to and from remotes (contract.hasLfsTransport):
fn lfsAvailable(self, arena) Error!bool                    // git-lfs installed
fn lfsPush(self, arena, remote, sha256_hexes) (Error || LfsTransportError)!void
fn lfsFetch(self, arena, remote, local_refs) (Error || LfsTransportError)!void
```

A backend without them still works for everything else, and attachments
fail with `AttachmentsUnsupported`. A backend with the stores but without
transport works locally, and a push with objects to upload fails with
`LfsUnavailable` unless a `before_push` hook uploads them.
