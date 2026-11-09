//! `--json` output: the library's JSON (`issuez.json`, docs/json.md),
//! with the CLI's exit codes for a failed write.

const std = @import("std");
const issuez = @import("issuez");
const common = @import("common.zig");
const lib = issuez.json;

pub const Stringify = lib.Stringify;
pub const Error = lib.Error;
pub const IssueOptions = lib.IssueOptions;
pub const begin = lib.begin;
pub const end = lib.end;
pub const conflict = lib.conflict;
pub const string = lib.string;
pub const field = lib.field;
pub const optional = lib.optional;
pub const issue = lib.issue;
pub const attachmentList = lib.attachmentList;
pub const attachment = lib.attachment;
pub const milestones = lib.milestones;
pub const milestone = lib.milestone;
pub const milestoneDetail = lib.milestoneDetail;
pub const problem = lib.problem;

/// The exit code when writing fails: out of memory is reported, like on
/// the text paths, and a closed stdout isn't.
pub fn failed(err: *std.Io.Writer, e: Error) u8 {
    return switch (e) {
        error.OutOfMemory => common.oom(err),
        error.WriteFailed => common.exit_error,
    };
}
