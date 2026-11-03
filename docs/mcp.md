# MCP server

`git issue mcp` serves the repository's issues to coding agents over the
[Model Context Protocol](https://modelcontextprotocol.io/specification/2025-11-25):
newline-delimited JSON-RPC on stdin and stdout. It is part of the default
(full) build; `zig build -Dminimal` or `-Dmcp=false` leaves it out.

```
git issue mcp [--repo <path>]
```

`--repo` names the repository; the default is the current directory. The
server opens it on the first tool call, so it starts outside a repository
too; each call then fails with "not a git repository: <path>". Every tool
call reads the repository afresh, so the server sees what `git issue`,
another clone's sync or another agent wrote in the meantime.

Every tool also takes an optional `repo`, the absolute path of any
directory in another repository; the server opens it the same way and
keeps up to 16 open. A client starts the server once per session and
doesn't tell it when the agent changes directory, so an agent working in
another repository passes `repo`.

The server doesn't use the client's roots. Claude Code's are the directory
it was started in and any `--add-dir` directories, and they don't change
when the agent changes directory either. The `--add-dir` directories are
all they would add, and with several roots the server can't tell which one
a call is for, so the agent passes `repo` there too.

## Clients

For Claude Code, once for every project:

```sh
git issue mcp install
```

That runs `claude mcp add --scope user git-issue -- /abs/path/git-issue mcp`:
the absolute path, since a client started from a desktop often has a
shorter PATH than a terminal. `--scope local` registers it for the current
project only; `--scope project` writes `git issue mcp` to the repository's
`.mcp.json`, to commit, so everyone working on it gets the server.
`--name` changes the server's name.

`git issue mcp install --print` prints the configuration that clients
configured with JSON take (Claude Desktop, Cursor, ...):

```json
{
  "mcpServers": {
    "git-issue": {
      "command": "/abs/path/git-issue",
      "args": ["mcp"]
    }
  }
}
```

A client without a working directory (Claude Desktop) needs `"--repo",
"/path/to/repo"` in `args`, or tools called with `repo`.

To try it, run `npx @modelcontextprotocol/inspector git issue mcp`.

## Tools

| Tool | Does |
| --- | --- |
| `list_issues` | Issues that aren't done, newest first; filters for state, label, assignee, priority, problems, conflicts and deleted issues, a sort order, a limit (default 100) and the total |
| `show_issue` | One issue with its description and its updates, each a `comment` or an `update` (`kind`; deleted comments left out) |
| `search_issues` | Issues whose title, fields, description or comments contain a text, with the matching lines; a limit (default 50) and the total |
| `list_milestones` | The milestone catalog with each milestone's progress |
| `create_issue` | A new issue, with labels, assignee, priority, milestone, parent, blockers, dates, estimate and workflow state |
| `comment_issue` | A comment on an issue |
| `edit_issue` | Title, description and fields in one commit; an empty value clears a field |
| `set_issue_state` | Close, reopen or set another state, with reason, fixing commit and release |

Every tool returns structured content and declares its output schema. The
issue fields follow `git issue ls --json` ([json.md](json.md)), except that
`fields` is a list of `{ "key", "value" }`, `attachments` is a count,
`problems` have no `key` and `value`, and a field without a value is left
out instead of `null`. `show_issue`'s comments follow `show --json`'s
without `deleted` (deleted comments are left out) and `attachments`. Issues
also have:

- `version`: the issue's tip commit. Pass it as `expect_version` to a write:
  if the issue changed since, the write fails instead of overwriting the
  change.
- `done`: the state is `closed` or one of `git config issue.doneStates`.

Milestones follow the command line's rules: `milestone` is a name, which
links the one open catalog milestone with exactly that name and is otherwise
written as plain text; `milestone_id` takes a catalog milestone by ID prefix
or name; `milestone_mode` is `inherit`, `none` or `explicit`.

Issues are named by their UUID or a unique prefix, like on the command line.
Errors (an ambiguous prefix, closing an issue with open sub-issues, an
unknown workflow state, ...) come back as tool errors with a message saying
what to do.

## Not in the server

Sync with remotes (`git issue sync <remote>`), attachments, milestone
changes, deletion and quarantine stay on the command line for now.

The tools are built on the library (`Repo`, `query`, `projection`,
`Catalog`), not on the CLI's commands; see [design.md](design.md).
