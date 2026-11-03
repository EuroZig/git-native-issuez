//! `git issue mcp --help`. A module of its own, imported by the CLI too, so
//! that builds without the MCP server still have it for completions and man
//! pages.

pub const text =
    \\usage: git issue mcp [--repo <path>]
    \\   or: git issue mcp install [--scope <scope>] [--name <name>] [--print]
    \\
    \\Serve the repository's issues to MCP clients (coding agents) over
    \\stdio: newline-delimited JSON-RPC on stdin and stdout. Tools list,
    \\show and search issues and milestones, and create, comment on, edit,
    \\close and reopen issues. For a client's configuration, the command is
    \\`git` with the arguments `issue mcp`. Each tool takes an optional
    \\repo, the absolute path of another repository.
    \\
    \\install registers the server with Claude Code (`claude mcp add`), by
    \\this binary's absolute path; with --scope project, as `git issue mcp`
    \\in the repository's .mcp.json, to commit. --print prints the JSON that
    \\Claude Desktop, Cursor and other clients take instead.
    \\
    \\Options:
    \\   --repo <path>     The repository (default: the current directory)
    \\   --scope <scope>   user (every project, the default), local (this
    \\                     project, for you) or project (.mcp.json)
    \\   --name <name>     The server's name (default: git-issue)
    \\   --print           Print the client configuration as JSON
    \\   -h, --help        Show this help
    \\
;
