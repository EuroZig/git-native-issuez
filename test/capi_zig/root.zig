//! The C API's tests, from Zig through the generated header and the
//! static library, as an embedder calls it. Each
//! test is named after the functions it covers: `tools/capi_coverage.zig`
//! checks every function has one.

test {
    _ = @import("version_test.zig");
    _ = @import("hosting_test.zig");
    _ = @import("abi_test.zig");
    _ = @import("types_test.zig");
    _ = @import("errors_test.zig");
    _ = @import("ops_test.zig");
    _ = @import("cancel_test.zig");
    _ = @import("repo_test.zig");
    _ = @import("resolve_test.zig");
    _ = @import("issue_read_test.zig");
    _ = @import("query_test.zig");
    _ = @import("issue_write_test.zig");
    _ = @import("milestone_test.zig");
    _ = @import("projection_test.zig");
    _ = @import("sync_test.zig");
    _ = @import("push_check_test.zig");
    _ = @import("purge_test.zig");
    _ = @import("attachment_test.zig");
    _ = @import("helpers_test.zig");
    _ = @import("threads_test.zig");
}
