//! `git issue version`. Upstream's tests match on the `git-issue version `
//! prefix, so keep it.

const std = @import("std");
const context = @import("../context.zig");
const common = @import("../common.zig");

/// `build.zig.zon`'s version, with `git describe`'s distance and commit
/// unless built from its tag (`describeVersion` in build.zig).
pub const version: []const u8 = @import("issuez").version;

pub const help =
    \\usage: git issue version
    \\
    \\Print version information.
    \\
    \\Options:
    \\   -h, --help    Show this help
    \\
;

pub fn main(comptime B: type, ctx: *context.Context(B), args: []const []const u8) u8 {
    for (args) |arg| if (common.isHelp(arg)) {
        ctx.out.writeAll(help) catch {};
        return common.exit_ok;
    };
    ctx.out.print("git-issue version {s}\n", .{version}) catch return common.exit_error;
    return common.exit_ok;
}
