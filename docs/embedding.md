# Embedding in a host

Zig callers use allocators, typed specs, optional values, tagged edits and
error unions. C callers use value helpers and owned handles. Go callers
receive ordinary values, use contexts and `errors.Is`/`errors.As`, and
close repository handles. No C-owned memory escapes into a Go result.

## Zig

Open settings once with `issuez.open` and use its `repo`, `milestones()`,
`attachments()`, and other parts. An omitted edit field leaves it alone;
`.clear` clears it, and `.set` provides its typed value:

```zig
const h = try issuez.open(GitProcess, arena, &git);
const receipt = try h.repo.update(arena, id, .{ .edit = .{
    .description = body,
    .expect_edits = form_version,
    .due_date = .{ .set = .{ .year = 2026, .month = 12, .day = 1 } },
    .priority = .clear,
} }, .{});
```

`expect_edits` compares the description's edit count, or the targeted
comment's count for a comment edit. The check runs on every CAS retry;
unrelated comments or labels can land without failing the text edit.
`.expect` compares the whole issue tip instead. Incompatible operations
are errors, including fields alongside a reaction or deletion.

For an exact read, pass an `IssueRef` containing the captured tip to
`Repo.load` or `Catalog.load`. The ref need not still point at that tip.
The caller's allocator owns the result.

Staging is a GitProcess convenience; generic backends retain
`Repo.adoptFrom`. A staging repository shares the target's objects and
has private refs:

```zig
var stage = try git.beginImport(arena);
defer stage.deinit();
var replay = try issuez.Repo(GitProcess).fromSettings(&stage.git, h.repo.settings);
replay.limits = h.repo.limits;
_ = try replay.create(arena, .{ .title = "Imported issue" });
_ = try stage.commit(arena, &git);
```

Do not write while committing or deinitializing staging. Aborting removes
its private refs; unreachable objects are left to Git's normal garbage
collection. `Attachments.prepare` returns a typed spec that a host can
include in a write after storing the image bytes itself.

## C

All fallible functions return a status; optional `issuez_error **` receives
owned details. Free each successful output with its matching `_free`
function. Strings and nested records borrowed from an output remain valid
until that output is freed. No caller-allocated ABI record changed for
these APIs.

For an external image store, open with `issuez_opt_attachment_store(0)`,
then prepare an image:

```c
issuez_prepared_attachment *prepared = NULL;
int rc = issuez_attachment_prepare(repo, ISSUEZ_STR(""), name, bytes,
                                  cancel, &prepared, &err);
/* Check rc. Store bytes using issuez_prepared_attachment_info(prepared):
   id, sanitized name, media_type, size and sha256. */
issuez_op ops[] = {
    issuez_set_title(ISSUEZ_STR("An image")),
    issuez_prepared_attachment_op(prepared),
};
issuez_write *w = NULL;
rc = issuez_issue_create(repo, ops, 2, &actor, cancel, &w, &err);
issuez_prepared_attachment_free(prepared);
/* Check rc; free w when done. */
```

The prepared op borrows its metadata. Keep its handle until the write
returns. The writer checks metadata, attachment counts and limits, but
trusts the host to have stored the validated bytes. Prepared metadata is
rejected when repository-local byte storage is enabled.

`issuez_repo_begin_import` returns an owned staging repo inheriting the
target's open options and effective settings. Use ordinary issue and
milestone writes on it, then `issuez_repo_commit_import` to publish all
shared refs in one transaction. Close staging after success or failure;
it retains the target until closed. A conflicting target ref publishes
nothing. Do not write concurrently with commit or close.

`issuez_issue_load_at` and `issuez_milestone_load_at` read captured tips.
`issuez_write_load_issue` and `issuez_write_load_milestone` use the
receipt's exact tip. Reads can fail if objects have since been purged and
collected; they do not retain historical objects. Reload failure does not
undo the earlier write.

## Go

Use `Edit` builders for partial updates. Scalar state and dates remain
Go values; absence and clearing are explicit through omitted methods and
`Clear...` methods. A write's returned receipt says whether it changed
anything. `Reload()` also returns the exact written state:

```go
w, err := repo.Update(ctx, id,
    new(issuez.Edit).SetDescription(body).ExpectEdits(formVersion),
    actor, issuez.Reload())
if err != nil {
    var detail *issuez.Error
    if errors.As(err, &detail) && detail.Write != nil {
        // The mutation committed; only its reload failed. Do not retry it.
    }
    return err
}
// w.Issue.Tip == w.NewTip
```

A mutation cancelled before commit did not happen. Cancellation of a
subsequent reload returns a non-nil receipt alongside the error and in
`Error.Write`, with `errors.Is(err, context.Canceled)` or
`context.DeadlineExceeded` preserved.

`LoadAt(ctx, id, tip, LoadHistory(), Since(previousTip))` reads changes up
to a captured tip. `LoadMilestoneAt` provides the same exact-state read
for milestones. `Snapshot.Tips` is an ordinary Go map; binary marshaling
encodes its current contents and returns independent bytes. Synchronize
map mutations when sharing snapshots between goroutines.

For an external image store, `PrepareAttachment` returns an ordinary
`AttachmentSpec` with the chosen ID, sanitized name and LFS metadata.
Store the bytes first, then call `Edit.AddPreparedAttachment(spec)` on a
repo opened with `WithAttachmentStore(false)`.

An import uses the ordinary Go close/commit pattern:

```go
stage, err := repo.BeginImport(ctx)
if err != nil {
    return err
}
defer stage.Close()
if _, err := stage.Create(ctx, new(issuez.Edit).SetTitle("Imported"), actor); err != nil {
    return err
}
_, err = stage.Commit(ctx)
return err
```

A successful commit closes staging. A failed commit leaves it open for
retry or `Close`. The target may be closed while staging is alive. Do not
write to staging concurrently with commit or close.
