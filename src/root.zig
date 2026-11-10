//! Git-native issue tracking, compatible with the git-native-issue format.
//! See examples/ for complete programs. `open` is the one entry: a
//! repository with its settings and every part of the library over it.
//!
//! Zig has no package-private declarations, so the library's parts reach
//! each other through `pub`. Those whose doc starts with "Internal:" are
//! that plumbing: not API, they may change in any release.

/// `build.zig.zon`'s version; built from a git checkout, with `git describe`'s
/// distance and commit, and `-dirty` for uncommitted changes:
/// `0.5.0-12-ga3e21cfa`. What `git issue version`, the MCP server,
/// `issuez_version()` and the Go binding's `Version()` report.
pub const version: []const u8 = @import("version").version;

/// Internal: see sort.zig.
pub const sort = @import("sort.zig");

pub const backend = struct {
    pub const contract = @import("backend/contract.zig");
    pub const object = @import("backend/object.zig");
    pub const GitProcess = @import("backend/GitProcess.zig");
    pub const GitSim = @import("backend/GitSim.zig");

    pub const assertBackend = contract.assertBackend;
};

pub const format = struct {
    pub const trailers = @import("format/trailers.zig");
    pub const labels = @import("format/labels.zig");
    pub const uuid = @import("format/uuid.zig");
    pub const hex = @import("format/hex.zig");
    pub const core = @import("format/core.zig");
    pub const fields = @import("format/fields.zig");
    pub const dates = @import("format/dates.zig");
    pub const attachment = @import("format/attachment.zig");
    pub const time = @import("format/time.zig");
};

pub const model = struct {
    pub const issue = @import("model/issue.zig");
};

pub const engine = @import("engine/repo.zig");
pub const Repo = engine.Repo;
pub const sync = @import("engine/sync.zig");
pub const Sync = sync.Sync;
pub const query = @import("engine/query.zig");
pub const projection = @import("engine/projection.zig");
pub const milestone = @import("engine/milestone.zig");
pub const Catalog = milestone.Catalog;
pub const attachments = @import("engine/attachments.zig");
pub const Attachments = attachments.Attachments;
pub const settings = @import("engine/settings.zig");
pub const errors = @import("engine/errors.zig");
pub const changes = @import("engine/changes.zig");
pub const purge = @import("engine/purge.zig");
pub const remote = @import("engine/remote.zig");
pub const fsck = @import("engine/fsck.zig");
pub const json = @import("engine/json.zig");
pub const store = @import("engine/store.zig");
pub const view = @import("engine/view.zig");
pub const handle = @import("engine/handle.zig");
pub const Handle = handle.Handle;
/// A repository opened with its settings, every part of the library over
/// it (`Handle`).
pub const open = handle.open;
pub const Store = store.Store;
pub const push_check = @import("engine/push_check.zig");
pub const PushCheck = push_check.PushCheck;
pub const local_time = @import("engine/local_time.zig");
pub const schedule = @import("engine/schedule.zig");
pub const Settings = settings.Settings;
/// The 7-character ID upstream prints, of an issue or milestone ID.
pub const shortId = format.uuid.shortId;

// The backends, and the types a caller names most, from where they live.
pub const GitProcess = backend.GitProcess;
pub const GitSim = backend.GitSim;
pub const Oid = engine.Oid;
pub const Signature = engine.Signature;
pub const Issue = engine.Issue;
pub const IssueRef = engine.IssueRef;
pub const Resolution = engine.Resolution;
pub const Limits = engine.Limits;
pub const Created = engine.Created;
pub const CreateSpec = engine.CreateSpec;
pub const Update = engine.Update;
pub const EditSpec = engine.EditSpec;
pub const Edit = engine.Edit;
pub const MilestoneEdit = engine.MilestoneEdit;
pub const CommentSpec = engine.CommentSpec;
pub const StateSpec = engine.StateSpec;
pub const ReactSpec = engine.ReactSpec;
pub const DeleteSpec = engine.DeleteSpec;
pub const CommentEventSpec = engine.CommentEventSpec;
pub const CommentEvent = engine.CommentEvent;
pub const WriteOptions = engine.WriteOptions;
pub const Receipt = engine.Receipt;

test {
    _ = sort;
    _ = backend.contract;
    _ = backend.object;
    _ = backend.GitProcess;
    _ = backend.GitSim;
    _ = format.trailers;
    _ = format.labels;
    _ = format.uuid;
    _ = format.hex;
    _ = format.core;
    _ = format.fields;
    _ = format.dates;
    _ = format.attachment;
    _ = format.time;
    _ = model.issue;
    _ = engine;
    _ = sync;
    _ = purge;
    _ = remote;
    _ = fsck;
    _ = json;
    _ = store;
    _ = view;
    _ = handle;
    _ = push_check;
    _ = query;
    _ = projection;
    _ = milestone;
    _ = attachments;
    _ = settings;
    _ = errors;
    _ = changes;
    _ = local_time;
    _ = schedule;
}
