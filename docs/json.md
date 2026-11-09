# `--json` output

Read commands take `--json` and print JSON instead of text, for scripts and
for programs that don't link the Zig library. The schema only grows: fields
are added, never renamed, retyped or removed. Unknown fields should be
ignored. Text output is unchanged (and upstream-compatible where it was).

| Command | Prints |
| --- | --- |
| `git issue ls --json` (with every `ls` filter) | array of [issues](#issue) |
| `git issue show <id> --json` | one [issue](#issue) with `description` and `comments` |
| `git issue tree [<id>] --json` | array of [nodes](#node) |
| `git issue search <text> --json` | array of `{ "issue": issue, "matches": [lines] }` |
| `git issue status [<remote>] --json` | [status](#status) |
| `git issue attach ls <id> --json` | array of [attachments](#attachment) with `availability` |
| `git issue milestone ls --json` | array of [milestones](#milestone) |
| `git issue milestone show <m> --json` | [milestone](#milestone) with `progress` and `issues` |

Conventions:
- IDs are full UUIDs (`short_id` is the 7-character display form).
- Times are RFC 3339 with the offset of the commit's author
  (`2026-10-20T20:55:58+05:30`): `created` the issue author's, `updated`
  the last writer's.
- Dates are `YYYY-MM-DD`.
- A field without a value is `null`. Empty lists are `[]`.
- Text is always a JSON string. git allows any bytes, so bytes that
  aren't valid UTF-8 are replaced by U+FFFD.

## Issue

```json
{
  "id": "bd787fc5-d633-489d-b44f-c93a8f1dba8a",
  "short_id": "bd787fc",
  "title": "Login broken",
  "state": "open",
  "deleted": false,
  "labels": ["bug", "ui"],
  "assignee": "ada@example.com",
  "assignees": ["ada@example.com", "bob@example.com"],
  "priority": "high",
  "milestone": "v1.0",
  "milestone_id": "95586de8-b8e3-47c9-ba85-887af6b78eba",
  "parent": null,
  "blocked_by": [],
  "start": null,
  "due": "2026-12-01",
  "estimate_minutes": 120,
  "workflow": "in-progress",
  "locked": false,
  "lock_reason": null,
  "ref": null,
  "author": { "name": "Ada", "email": "ada@example.com" },
  "created": "2026-10-20T20:55:58+05:30",
  "updated": "2026-10-21T09:12:03+05:30",
  "fields": { "Priority": "high", "Milestone": "v1.0" },
  "conflicts": [{ "field": "Priority", "kept": "high", "lost": "low" }],
  "attachments": [],
  "reactions": [{ "comment": null, "emoji": ":+1:", "users": ["ada@example.com"] }],
  "closed": null,
  "effective_milestone_id": "95586de8-b8e3-47c9-ba85-887af6b78eba",
  "effective_workflow": "in-progress",
  "progress": { "closed": 1, "total": 3 },
  "blocked": false,
  "problems": []
}
```

- `assignee` is the email, also for the `<uuid> <email>` form.
  `assignees` lists everyone assigned, by email (format.md §3); `assignee`
  is one of them, usually the first, `null` when there are none.
- `milestone` is the readable text. `milestone_id` is the catalog link as
  written; `effective_milestone_id` follows `inherit` up the parent chain.
- `number` is the issue's number in its host (`X-Number`), `null` when it
  has none. `locked`, `lock_reason` and `ref` are `X-Locked`,
  `X-Lock-Reason` and `X-Ref`.
- `workflow` is as written. `effective_workflow` includes the default for
  open issues without one.
- `fields` holds every other trailer field with a value, as written (for
  example `Fixed-By`, `Provider-ID` or other extensions).
- `reactions` are grouped by target (`comment` is the comment's ID, `null`
  for the issue's own) and emoji, `users` by email.
- `conflicts` lists fields edited concurrently: `kept` won, `lost` lost.
- `closed` says who closed a done issue (`closed` or one of
  `issue.doneStates`) and when: `{ "author": { "name", "email" },
  "author_id", "date", "commit" }`, the last commit that set a done state.
  `null` for an issue that isn't done, or was created done.
- `progress` counts the issue's leaves; it is `null` for an issue without
  sub-issues that aren't deleted. `closed` counts done leaves (`closed` and
  `issue.doneStates`).
- `blocked` is true when an open blocker remains.
- `problems` are objects `{ "kind", "other", "key", "value", "description" }`,
  for example `parent_cycle` or `milestone_retired`. `kind` is the
  machine-readable name; `description` is the text `ls --problems` prints.
- `ls --json` and `search --json` issues have no `description` or `comments`.
  `search --json` issues also have no projection fields
  (`effective_milestone_id`, `effective_workflow`, `progress`, `blocked`,
  `problems`).

With `show --json`, the issue also has:

```json
  "description": "Clicking Sign in crashes.",
  "comments": [
    {
      "id": "1c0e3933b900007b3e513b8b33fb15245148e165",
      "kind": "comment",
      "author": { "name": "Ada", "email": "ada@example.com" },
      "date": "2026-10-20T20:57:44+05:30",
      "subject": "Here's a screenshot",
      "text": "Second paragraph.",
      "state_change": null,
      "merge": false,
      "edited": false,
      "deleted": false,
      "purged": false,
      "attachments": ["720964d9-80f3-4953-bf91-3b32b2897504"],
      "changes": [ { "key": "Labels", "op": "add", "old": null, "new": "ui" } ],
      "history": [
        {
          "id": "1c0e3933b900007b3e513b8b33fb15245148e165",
          "kind": "original",
          "author": { "name": "Ada", "email": "ada@example.com" },
          "date": "2026-10-20T20:57:44+05:30",
          "text": "Here's a screenshot\n\nSecond paragraph."
        }
      ]
    }
  ],
  "description_history": [ { "id": "…", "kind": "original", "author": { … }, "date": "…", "text": "…" } ],
  "created_changes": [ { "key": "State", "op": "set", "old": null, "new": "open" } ]
```

- `id` is the commit, the ID `comment --edit/--delete/--restore` takes.
- `comments` has every commit after the first, apart from events
  (description edits and comment edits, deletions and restores, which
  show as the text they changed). `kind` is `comment` for text someone
  wrote, and `update` for a commit that only changed fields or the state,
  merged or recorded an export: its `text` is empty and its `subject` is
  the commit message, the default one saying what changed ("Update
  labels") or the message given with the change.
- `text` is the body without its trailers (the edited text for edited
  comments).
- `deleted` comments are included, so check the flag before showing them.
- `attachments` are the IDs this comment added.
- `changes` (per comment) is what that commit changed in the resolved
  fields, and `created_changes` what the first commit set: `op` is `set`
  or `clear` for a field, `add` or `remove` for a member of a set
  (`Labels`, `X-Blocked-By`) or an attachment (`X-Attachment`, by UUID).
  Values are as written. A merge's are only what the merge itself
  resolved, compared with what its parents merge to.
- `purged` (per comment): `git issue purge --comment` took its text,
  attachments and origin (format.md §10). Its fields and changes stay.
- `original_author` and `original_id`, on the issue and on each comment,
  say where imported text came from (`X-Original-Author`,
  `X-Original-Id`); `null` otherwise. Host fields (`X-Forgejo-...`) are in
  `fields`.
- `history` (per comment) and `description_history` hold every version,
  oldest first: `original` (the comment or the issue's root), then each
  `edit`, `delete` and `restore` event, with its commit `id` and author.
  `text` is the whole text after it (subject and body for a comment);
  delete and restore keep the text they hide and show. After concurrent
  edits the current text is the one §4 of format.md resolves to, which
  needn't be the last version.

## Node

```json
{ "issue": { … }, "children": [ { "issue": { … }, "children": [] } ] }
```

Nodes follow the same rules as `tree`: without `--all`, closed subtrees
with nothing open are left out, and a deleted issue's children take its
place.

## Attachment

```json
{
  "id": "720964d9-80f3-4953-bf91-3b32b2897504",
  "name": "shot.png",
  "media_type": "image/png",
  "size": 45,
  "sha256": "6422564120b76bbc05819b296f96f7e82593e60bb33f3ecf2abaad1cdbf85339",
  "added_in": "1c0e3933b900007b3e513b8b33fb15245148e165",
  "added_by": { "name": "Ada", "email": "ada@example.com" },
  "availability": "local"
}
```

`availability` (`attach ls` only) is `local`, `missing` (the bytes aren't in
this clone yet: `git issue attach fetch`) or `corrupt` (stored at the wrong
size; `attach ls` doesn't read the bytes, `git issue fsck` hashes them). The
bytes themselves come from `git issue attach cat`.

## Status

```json
{
  "remotes": [
    {
      "name": "origin",
      "pending": ["bd787fc5-d633-489d-b44f-c93a8f1dba8a"],
      "quarantined": [
        {
          "id": "…",
          "kind": "issue",
          "title": "…",
          "remote_tip": "…",
          "reason": "unrelated_history",
          "kept_local": false
        }
      ]
    }
  ],
  "conflicts": [{ "id": "…", "field": "Priority", "kept": "high", "lost": "low" }]
}
```

`kind` is `issue` or `milestone`. `reason` is `unrelated_history`,
`rewound` or `invalid_issue`, or `null` when the quarantine clears on the
next merge.

## Milestone

```json
{
  "id": "95586de8-b8e3-47c9-ba85-887af6b78eba",
  "short_id": "95586de",
  "name": "v1.0",
  "status": "open",
  "due": "2026-12-01",
  "description": "",
  "conflicts": []
}
```

`milestone show --json` adds `"progress": { "closed", "total" }` (the leaf
issues) and `"issues"`, the IDs of every issue in the milestone. That
includes inherited ones and excludes deleted ones.
