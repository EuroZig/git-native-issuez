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
- Times are RFC 3339 with the author's offset (`2026-10-20T20:55:58+05:30`).
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
  "priority": "high",
  "milestone": "v1.0",
  "milestone_id": "95586de8-b8e3-47c9-ba85-887af6b78eba",
  "parent": null,
  "blocked_by": [],
  "start": null,
  "due": "2026-12-01",
  "estimate_minutes": 120,
  "workflow": "in-progress",
  "author": { "name": "Ada", "email": "ada@example.com" },
  "created": "2026-10-20T20:55:58+05:30",
  "updated": "2026-10-21T09:12:03+05:30",
  "fields": { "Priority": "high", "Milestone": "v1.0" },
  "conflicts": [{ "field": "Priority", "kept": "high", "lost": "low" }],
  "attachments": [],
  "effective_milestone_id": "95586de8-b8e3-47c9-ba85-887af6b78eba",
  "effective_workflow": "in-progress",
  "progress": { "closed": 1, "total": 3 },
  "blocked": false,
  "problems": []
}
```

- `assignee` is the email, also for the `<uuid> <email>` form.
- `milestone` is the readable text. `milestone_id` is the catalog link as
  written; `effective_milestone_id` follows `inherit` up the parent chain.
- `workflow` is as written. `effective_workflow` includes the default for
  open issues without one.
- `fields` holds every other trailer field with a value, as written (for
  example `Fixed-By`, `Provider-ID` or other extensions).
- `conflicts` lists fields edited concurrently: `kept` won, `lost` lost.
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
      "author": { "name": "Ada", "email": "ada@example.com" },
      "date": "2026-10-20T20:57:44+05:30",
      "subject": "Here's a screenshot",
      "text": "Second paragraph.",
      "state_change": null,
      "merge": false,
      "edited": false,
      "deleted": false,
      "attachments": ["720964d9-80f3-4953-bf91-3b32b2897504"]
    }
  ]
```

- `id` is the commit, the ID `comment --edit/--delete/--restore` takes.
- `text` is the body without its trailers (the edited text for edited
  comments).
- `deleted` comments are included, so check the flag before showing them.
- `attachments` are the IDs this comment added.

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
this clone yet: `git issue attach fetch`) or `corrupt`. The bytes themselves
come from `git issue attach cat`.

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
