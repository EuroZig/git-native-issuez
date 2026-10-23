//! Top-level usage. Like upstream, usage goes to stdout and exits with 1.

const context = @import("../context.zig");
const common = @import("../common.zig");

pub const text =
    \\usage: git issue <command> [<args>]
    \\
    \\Upstream-compatible commands:
    \\   create      Create a new issue
    \\   ls          List issues
    \\   show        Show an issue with its comments
    \\   comment     Add a comment to an issue
    \\   edit        Change issue metadata
    \\   state       Close or reopen an issue
    \\   search      Search issues by text
    \\   merge       Merge issues from a remote
    \\   fsck        Check issue data integrity
    \\   init        Configure the repository for issue tracking
    \\   version     Print version information
    \\
    \\git-native-issuez commands:
    \\   push        Push issues to a remote
    \\   sync        Merge from and push to a remote
    \\   status      Show unpushed, quarantined and conflicted issues
    \\   quarantine  Resolve a quarantined issue
    \\
    \\Run 'git issue <command> --help' for details on a command.
    \\Provider import/export (GitHub, GitLab, ...): use upstream git-native-issue's
    \\git-issue-import / git-issue-export on the same repository.
    \\
;

pub fn usage(comptime B: type, ctx: *context.Context(B)) u8 {
    ctx.out.writeAll(text) catch {};
    return common.exit_error;
}
