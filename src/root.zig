//! Git-native issue tracking, compatible with the git-native-issue format.
//! See examples/ for complete programs.

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

test {
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
    _ = model.issue;
    _ = engine;
    _ = sync;
    _ = query;
    _ = projection;
}
