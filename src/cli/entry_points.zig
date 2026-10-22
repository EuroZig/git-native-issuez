//! Subcommands also installed as `git-issue-<sub>`, for scripts that call
//! upstream's binaries directly.
//!
//! Never add `import`, `export` or `sync` here: those names belong to
//! upstream's provider bridges, which must stay reachable when both tools
//! are installed.

const std = @import("std");

pub const names = [_][]const u8{
    "create", "ls", "show", "comment", "edit", "state", "search", "fsck", "init",
};

/// Names reserved for upstream's provider bridges.
pub fn isReservedForUpstream(name: []const u8) bool {
    return std.mem.eql(u8, name, "sync") or
        std.mem.startsWith(u8, name, "import") or
        std.mem.startsWith(u8, name, "export");
}
