//! The TUI over one repository: the UI state, the store, and carrying out
//! the actions input produces.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");

const ui = @import("ui.zig");
const store_mod = @import("store.zig");
const State = @import("State.zig");
const sync_job = @import("sync_job.zig");
const modal = @import("modal.zig");
const milestone_view = @import("milestone_view.zig");
const filter = @import("filter.zig");
const timeline_edit = @import("timeline_edit.zig");
const star = @import("star.zig");

const core = issuez.format.core;
const shortId = issuez.format.uuid.shortId;

pub fn App(comptime B: type) type {
    return struct {
        const Self = @This();
        pub const Store = store_mod.Store(B);

        store: Store,
        state: State,
        /// Runs syncs in the background; null runs them here, which the
        /// tests do on the simulator.
        runner: ?Runner = null,
        /// Checks for and gives the star the notice asks for, in the
        /// background; null never asks, as in the tests.
        star_runner: ?StarRunner = null,
        /// For syncs run here: the simulator keeps what they write in
        /// it, so it lives as long as the app and is never reset. It
        /// grows with each sync, which only tests run.
        inline_arena: std.heap.ArenaAllocator,

        pub const Runner = struct {
            context: *anyopaque,
            /// error.SyncRunning when one is running already.
            start: *const fn (
                context: *anyopaque,
                remote: []const u8,
                kind: sync_job.Kind,
                auto: bool,
                fetched: bool,
            ) anyerror!void,
        };

        /// Each posts its result back: to `starChecked`, `starDone`.
        pub const StarRunner = struct {
            context: *anyopaque,
            check: *const fn (context: *anyopaque) anyerror!void,
            star: *const fn (context: *anyopaque, gh: bool) anyerror!void,
            /// "Never", written down at once.
            decline: *const fn (context: *anyopaque) void,
        };

        /// In place: the state points into the store.
        pub fn init(self: *Self, gpa: Allocator, backend: *B) void {
            self.store = .init(gpa, backend);
            self.state = .init(gpa, &self.store.snap);
            self.runner = null;
            self.star_runner = null;
            self.inline_arena = .init(gpa);
        }

        pub fn deinit(self: *Self) void {
            self.inline_arena.deinit();
            self.state.deinit();
            self.store.deinit();
            self.* = undefined;
        }

        pub fn draw(self: *Self, win: ui.Window, now_s: i64) Allocator.Error!void {
            assert(self.state.snap == &self.store.snap);
            try self.state.draw(win, now_s);
        }

        /// False once the user quits.
        pub fn handle(self: *Self, input: State.Input, now_ms: i64) Allocator.Error!bool {
            const action = try self.state.handle(input, now_ms);
            return self.perform(action);
        }

        /// Reads the repository again, keeping what is shown. Quietly: for
        /// when the terminal gets the focus back.
        pub fn refresh(self: *Self) void {
            self.store.reload() catch |e| self.failWith(e);
        }

        /// Someone else may have written: the watcher saw the refs or
        /// `settings` (git config) change, or the terminal got the focus
        /// back. Reloads if the refs moved, keeping what is shown, and
        /// says what changed unless an error is showing.
        pub fn changedElsewhere(self: *Self, settings: bool) void {
            const s = &self.state;
            const found = self.store.reloadIfChanged(settings) catch |e| return self.failWith(e);
            const out = found orelse return;
            if (s.status_kind == .err and s.status().len > 0) return;
            if (out.issues == 1) {
                s.info("#{s} changed elsewhere", .{shortId(out.first.slice())});
            } else if (out.issues > 1) {
                s.info("{d} issues changed elsewhere", .{out.issues});
            } else if (out.milestones) {
                s.info("milestones changed elsewhere", .{});
            }
        }

        fn failWith(self: *Self, err: anyerror) void {
            var buf: [400]u8 = undefined;
            const msg = self.store.describe(err, &buf);
            self.state.fail("{s}", .{msg});
            if (err == error.VersionMismatch) {
                self.store.reload() catch {};
                // Told, so saving again replaces what is there now.
                self.state.rebaseModal();
            }
        }

        pub fn perform(self: *Self, action: State.Action) bool {
            const s = &self.state;
            const st = &self.store;
            switch (action) {
                .none => {},
                .quit => return false,
                .reload => {
                    st.reload() catch |e| return self.failed(e);
                    s.info("reloaded: {d} issues", .{st.snap.issues.len});
                },
                .create => |input| {
                    const id = st.create(input) catch |e| return self.failed(e);
                    // The input lives in the modal arena.
                    if (input.parent) |p| {
                        s.info(
                            "created sub-issue #{s} of #{s}",
                            .{ shortId(id.slice()), shortId(p) },
                        );
                    } else s.info("created #{s}", .{shortId(id.slice())});
                    s.closeModal();
                    s.select(id);
                },
                .edit => |e| {
                    var spec = e.spec;
                    spec.expect = s.expectedTip(e.id.slice());
                    st.edit(e.id.slice(), spec) catch |err| return self.failed(err);
                    s.closeModal();
                    s.info("saved", .{});
                },
                .milestone => |m| {
                    st.setMilestone(
                        m.id.slice(),
                        m.name,
                        s.expectedTip(m.id.slice()),
                    ) catch |err| return self.failed(err);
                    s.closeModal();
                    s.info("saved", .{});
                },
                .milestone_link => |m| {
                    st.setMilestoneLink(
                        m.id.slice(),
                        m.link,
                        s.expectedTip(m.id.slice()),
                    ) catch |err| return self.failed(err);
                    s.closeModal();
                    s.info("saved", .{});
                },
                .state => |x| {
                    if (!core.isState(x.state)) {
                        s.fail("'{s}' isn't a state", .{x.state});
                        return true;
                    }
                    st.setState(
                        x.id.slice(),
                        core.State.parse(x.state),
                        s.expectedTip(x.id.slice()),
                    ) catch |err| return self.failed(err);
                    s.info("now {s}", .{x.state});
                    s.closeModal();
                },
                .comment => |c| {
                    st.comment(c.id.slice(), c.text) catch |err| return self.failed(err);
                    s.closeModal();
                    s.info("commented", .{});
                },
                .toggle => |id| {
                    const i = st.snap.find(id.slice()) orelse return true;
                    const done = st.snap.isDone(i);
                    st.setState(
                        id.slice(),
                        if (done) .open else .closed,
                        null,
                    ) catch |err| return self.failed(err);
                    s.info(
                        "{s} #{s}",
                        .{ if (done) "reopened" else "closed", shortId(id.slice()) },
                    );
                },
                .move => |m| self.move(m.id, m.column, m.done),
                .create_milestone => |input| {
                    const id = st.createMilestone(input) catch |e| return self.failed(e);
                    s.info("created milestone {s}", .{input.name});
                    s.closeModal();
                    s.milestones.select(id);
                },
                .edit_milestone => |m| {
                    st.editMilestone(m.id.slice(), m.edit) catch |e| return self.failed(e);
                    s.closeModal();
                    const name = if (st.snap.findMilestone(
                        m.id.slice(),
                    )) |n| st.snap.milestones[n].name else "";
                    if (m.edit.status) |status| {
                        s.info("{s} {s}", .{ switch (status) {
                            .completed => "completed",
                            .retired => "retired",
                            .open => "reopened",
                        }, name });
                    } else s.info("saved {s}", .{name});
                },
                .show_milestone => |m| {
                    s.closeModal();
                    s.openMilestone(.{ .id = m.id });
                    // Only when it opened, and only for this opening.
                    const shown = s.view == .milestone and s.milestone.scope == .id and
                        s.milestone.scope.id.eql(
                            m.id.slice(),
                        );
                    if (m.open_only and shown) milestone_view.showOpenOnly(s);
                },
                .move_issues => |m| self.moveIssues(m.ids, m.link, m.unmark),
                .adopt => |x| self.adopt(x.parent, x.ids),
                .stage => |op| {
                    // Not staged: the dialog stays, with why.
                    if (!timeline_edit.stage(s, op)) return true;
                    s.closeModal();
                    s.info("staged", .{});
                },
                .apply_draft => {
                    s.closeModal();
                    self.applyDraft();
                },
                .leave_timeline => |l| {
                    s.closeModal();
                    if (l.apply) {
                        self.applyDraft();
                        // Still there: it failed, and stays.
                        if (s.timeline.editing) return true;
                    } else {
                        timeline_edit.reset(&s.timeline);
                        s.info("timeline changes discarded", .{});
                    }
                    switch (l.then) {
                        .view => |v| if (v != .timeline) s.switchView(v),
                        .quit => return s.quitUnlessSyncing() != .quit,
                        .issue => |id| s.openIssue(id.slice()),
                        .milestone => |m| s.openMilestone(m),
                    }
                },
                .sync => |kind| self.startSync(kind, false),
                .open_sync_panel => {
                    // Looked at: the badge isn't red anymore.
                    s.sync.failed = false;
                    self.openSyncPanel();
                },
                .resolve => |x| {
                    if (self.refuseWhileSyncing()) return true;
                    st.resolve(x.id.slice(), x.how) catch |e| return self.failed(e);
                    s.info(
                        "{s}",
                        .{
                            if (x.how == .accept_remote) "took the remote version; yours is " ++
                                "kept under refs/issuez-sync/" else "kept yours",
                        },
                    );
                    self.openSyncPanel();
                },
                .choose_remote => |name| {
                    if (self.refuseWhileSyncing()) return true;
                    st.chooseRemote(name) catch |e| return self.failed(e);
                    s.info("syncs go to {s} now", .{name});
                    self.openSyncPanel();
                },
                .star => |choice| self.starChoice(choice),
                .quick_create => |input| {
                    const id = st.create(input) catch |e| return self.failed(e);
                    s.info(
                        "created #{s}: {s}; next title, or esc",
                        .{ shortId(id.slice()), input.title },
                    );
                    s.select(id);
                    if (s.modal) |*md| if (md.* == .prompt) md.prompt.input.clear();
                },
            }
            // The write went through; showing it didn't.
            if (st.takeReloadError()) |e| self.failWith(e);
            return true;
        }

        /// `failWith`, then go on.
        fn failed(self: *Self, err: anyerror) bool {
            self.failWith(err);
            return true;
        }

        /// A sync with the remote, in the background with a runner.
        pub fn startSync(self: *Self, kind: sync_job.Kind, auto: bool) void {
            const s = &self.state;
            const name = self.store.snap.remote.name orelse {
                if (!auto) self.noRemote();
                return;
            };
            if (s.sync.running) |r| {
                if (!auto) s.info(
                    "a {s} with {s} is running already",
                    .{ r.label(), s.sync.runningRemote() },
                );
                return;
            }
            // Fetched from it just now: a push needs one connection only.
            const fetched = kind == .push and s.sync.fetched_at > 0 and
                std.mem.eql(
                    u8,
                    s.sync.fetchedFrom(),
                    name,
                ) and s.now_s - s.sync.fetched_at < sync_job.fetch_fresh_s;
            if (self.runner) |r| {
                r.start(r.context, name, kind, auto, fetched) catch |e| {
                    if (e == error.SyncRunning) {
                        if (!auto) s.info("a sync is running already", .{});
                        return;
                    }
                    var summary: sync_job.Summary = .{ .kind = kind, .auto = auto };
                    summary.setRemote(name);
                    var buf: [400]u8 = undefined;
                    summary.fail(
                        "{s} with {s} couldn't start: {s}",
                        .{ kind.label(), name, self.store.describe(e, &buf) },
                    );
                    return self.syncDone(summary, s.now_s);
                };
            }
            s.sync.running = kind;
            s.sync.setRunningRemote(name);
            s.sync.auto = auto;
            s.sync.phase = null;
            if (!auto) s.info("{s} with {s}…", .{ kind.label(), name });
            if (self.runner != null) return;
            const summary = sync_job.run(
                B,
                self.store.backend,
                self.inline_arena.allocator(),
                name,
                kind,
                auto,
                fetched,
                null,
            );
            self.syncDone(summary, s.now_s);
        }

        /// Writes that would race the running sync's are refused.
        fn refuseWhileSyncing(self: *Self) bool {
            const s = &self.state;
            const kind = s.sync.running orelse return false;
            s.fail(
                "the {s} with {s} is running: try again when it's done",
                .{ kind.label(), s.sync.runningRemote() },
            );
            return true;
        }

        /// Why there is no remote to sync with.
        fn noRemote(self: *Self) void {
            const problem = self.store.snap.remote.problem;
            if (problem.len > 0) return self.state.fail("{s}", .{problem});
            self.state.fail(
                "no remote: add one with git remote add origin <url>, then y syncs",
                .{},
            );
        }

        pub fn syncPhase(self: *Self, phase: issuez.sync.Phase) void {
            const s = &self.state;
            s.sync.phase = phase;
            if (!s.sync.auto and (s.status_kind != .err or s.status().len == 0)) {
                s.info(
                    "{s} with {s}: {s}…",
                    .{ s.sync.running.?.label(), s.sync.runningRemote(), @tagName(phase) },
                );
            }
        }

        /// The job is over: what it did shows, and everything reloads.
        pub fn syncDone(self: *Self, summary: sync_job.Summary, now_s: i64) void {
            const s = &self.state;
            s.sync.running = null;
            s.sync.phase = null;
            s.sync.last = summary;
            s.sync.last_at = now_s;
            s.sync.failed = !summary.ok;
            if (summary.fetched) s.sync.setFetched(summary.remote(), now_s);
            var buf: [512]u8 = undefined;
            const text = sync_job.report(&buf, &s.sync.last.?);
            if (!summary.ok) {
                // An automatic one's failure shows in the badge only: it
                // would come back every few minutes.
                if (!summary.auto) s.fail("{s}", .{text});
            } else if (!summary.auto or summary.incoming > 0 or summary.quarantined > 0 or
                summary.conflicts > 0)
            {
                s.info("{s}", .{text});
            }
            // Records moved too, not only issues: read it all again.
            self.store.reload() catch |e| return self.failWith(e);
            // An open panel shows the new state.
            if (s.modal) |*m| if (m.* == .sync_panel) self.openSyncPanel();
        }

        /// Every few seconds: an automatic fetch and merge when
        /// `issue.autoSync` says it's time.
        pub fn tick(self: *Self, now_s: i64) void {
            self.tickStar(now_s);
            const s = &self.state;
            const minutes = self.store.snap.settings.auto_sync_minutes orelse return;
            if (self.store.snap.remote.name == null or s.sync.running != null) return;
            const since = @max(s.sync.last_at, s.sync.auto_at);
            if (since == 0) {
                // The first one a while after starting, not at once.
                s.sync.auto_at = now_s;
                return;
            }
            if (now_s - since < @as(i64, minutes) * 60) return;
            // Also when it can't start: the next try is minutes away.
            s.sync.auto_at = now_s;
            self.startSync(.merge, true);
        }

        /// The star notice: checked for once the session has run a while,
        /// gone again after a few minutes untouched.
        fn tickStar(self: *Self, now_s: i64) void {
            const u = &self.state.star;
            switch (u.phase) {
                .idle => {
                    const r = self.star_runner orelse return;
                    if (u.started_at == 0) {
                        u.started_at = now_s;
                        return;
                    }
                    if (now_s - u.started_at < u.timing.session_s) return;
                    u.phase = .checking;
                    r.check(r.context) catch {
                        u.phase = .off;
                    };
                },
                .shown => if (now_s - u.shown_at >= u.timing.visible_s) {
                    u.phase = .off;
                },
                .checking, .starring, .off => {},
            }
        }

        pub fn starChecked(self: *Self, check: star.Check, now_s: i64) void {
            const u = &self.state.star;
            if (u.phase != .checking) return;
            if (check == .off) {
                u.phase = .off;
                return;
            }
            u.phase = .shown;
            u.gh = check == .ask_gh;
            u.shown_at = now_s;
        }

        fn starChoice(self: *Self, choice: ui.StarChoice) void {
            const s = &self.state;
            const u = &s.star;
            if (u.phase != .shown) return;
            // Chosen in `!`'s dialog, or on the notice.
            s.closeModal();
            switch (choice) {
                .star => {
                    const r = self.star_runner orelse return;
                    u.phase = .starring;
                    r.star(r.context, u.gh) catch {
                        u.phase = .off;
                        s.info("★ star it at {s}: thank you!", .{star.url});
                    };
                },
                .later => {
                    u.phase = .off;
                    s.info("★ later, then", .{});
                },
                .never => {
                    u.phase = .off;
                    if (self.star_runner) |r| r.decline(r.context);
                    s.info("★ it won't ask again", .{});
                },
            }
        }

        pub fn starDone(self: *Self, outcome: star.Outcome) void {
            const s = &self.state;
            s.star.phase = .off;
            switch (outcome) {
                .starred => s.info("★ starred {s} on GitHub: thank you!", .{star.repo}),
                .opened => s.info("★ opened {s} in the browser: thank you!", .{star.url}),
                .no_browser => s.info("★ star it at {s}: thank you!", .{star.url}),
            }
        }

        /// The sync panel, with what local refs say now.
        fn openSyncPanel(self: *Self) void {
            const s = &self.state;
            const st = &self.store;
            const snap = &st.snap;
            const name = snap.remote.name orelse {
                s.closeModal();
                return self.noRemote();
            };
            // The same row stays selected, if it's still there.
            var was: ?struct { tag: std.meta.Tag(modal.SyncPanel.Row), id: store_mod.Id } = null;
            if (s.modal) |*m| if (m.* == .sync_panel) {
                const p = &m.sync_panel;
                if (p.selected < p.rows.len) was = switch (p.rows[p.selected]) {
                    .unpushed => |u| .{ .tag = .unpushed, .id = u.id },
                    .quarantined => |q| .{ .tag = .quarantined, .id = q.id },
                    .conflict => |c| .{ .tag = .conflict, .id = c.id },
                    .heading, .empty => null,
                };
            };
            s.closeModal();
            const a = s.modalArena();
            const status = (st.syncStatus(a) catch |e| return self.failWith(e)) orelse return;
            const Row = modal.SyncPanel.Row;
            var rows: std.ArrayList(Row) = .empty;
            const label = struct {
                fn issue(
                    arena: std.mem.Allocator,
                    sn: *const store_mod.Snapshot,
                    id: []const u8,
                    fallback: []const u8,
                ) []const u8 {
                    if (sn.find(id)) |i| return std.fmt.allocPrint(
                        arena,
                        "#{s} {s}",
                        .{ shortId(id), sn.issues[i].title },
                    ) catch "";
                    if (sn.findMilestone(id)) |n| return std.fmt.allocPrint(
                        arena,
                        "milestone {s}",
                        .{sn.milestones[n].name},
                    ) catch "";
                    return std.fmt.allocPrint(
                        arena,
                        "#{s} {s}",
                        .{ shortId(id), fallback },
                    ) catch "";
                }
            };
            rows.append(
                a,
                .{
                    .heading = std.fmt.allocPrint(
                        a,
                        "Not pushed ({d})",
                        .{status.unpushed.len},
                    ) catch "",
                },
            ) catch {};
            for (status.unpushed) |u| rows.append(a, .{ .unpushed = .{
                .id = .of(u.id),
                .label = label.issue(a, snap, u.id, "?"),
                .new = u.new,
                .milestone = u.namespace == .milestones,
            } }) catch {};
            if (status.unpushed.len == 0) rows.append(
                a,
                .{ .empty = "everything is pushed" },
            ) catch {};
            rows.append(
                a,
                .{
                    .heading = std.fmt.allocPrint(
                        a,
                        "Quarantined ({d})",
                        .{status.quarantined.len},
                    ) catch "",
                },
            ) catch {};
            for (status.quarantined) |q| rows.append(a, .{ .quarantined = .{
                .id = .of(q.id),
                .label = label.issue(a, snap, q.id, q.title),
                .reason = if (q.reason) |rs| rs.describe() else "no longer applies; the next " ++
                    "sync clears it",
                .kept = q.kept_local,
                .local = if (q.namespace == .milestones) snap.findMilestone(
                    q.id,
                ) != null else snap.find(q.id) != null,
                .milestone = q.namespace == .milestones,
            } }) catch {};
            if (status.quarantined.len == 0) rows.append(
                a,
                .{ .empty = "nothing refused" },
            ) catch {};
            // A row per field in conflict.
            var conflicts: usize = 0;
            for (snap.issues) |issue| {
                if (!issue.deleted) conflicts += issue.conflicts.len;
            }
            rows.append(
                a,
                .{ .heading = std.fmt.allocPrint(a, "In conflict ({d})", .{conflicts}) catch "" },
            ) catch {};
            for (snap.issues) |issue| {
                if (issue.deleted) continue;
                for (issue.conflicts) |cf| rows.append(a, .{ .conflict = .{
                    .id = .of(issue.id),
                    .label = label.issue(a, snap, issue.id, ""),
                    .what = std.fmt.allocPrint(
                        a,
                        "{f}: kept '{s}', lost '{s}'",
                        .{ cf.target, cf.value, cf.lost },
                    ) catch "",
                    .field = fieldOf(cf.target),
                } }) catch {};
            }
            if (conflicts == 0) rows.append(
                a,
                .{ .empty = "no concurrent edits left over" },
            ) catch {};
            var panel: modal.SyncPanel = .{
                .remote = a.dupe(u8, name) catch "",
                .url = st.remoteUrl(a, name),
                // The snapshot's arena goes with the next reload.
                .problem = a.dupe(u8, snap.remote.problem) catch "",
                .rows = rows.items,
            };
            panel.first();
            if (was) |w| for (rows.items, 0..) |row, n| {
                const id = switch (row) {
                    .unpushed => |u| u.id,
                    .quarantined => |q| q.id,
                    .conflict => |c| c.id,
                    .heading, .empty => continue,
                };
                if (row == w.tag and std.mem.eql(u8, id.slice(), w.id.slice())) {
                    panel.selected = @intCast(n);
                    break;
                }
            };
            s.openModal(.{ .sync_panel = panel });
        }

        /// The detail view's field a conflicting trailer is.
        pub fn fieldOf(t: issuez.model.issue.Conflict.Target) ?modal.Field {
            const key = switch (t) {
                .field => |k| k,
                else => return null,
            };
            const map = [_]struct { []const u8, modal.Field }{
                .{ "State", .state },                 .{ "X-Workflow-State", .workflow },
                .{ "Priority", .priority },           .{ "Assignee", .assignee },
                .{ "Labels", .labels },               .{ "Milestone", .milestone },
                .{ "X-Milestone-Id", .milestone },    .{ "X-Milestone-Mode", .milestone },
                .{ "X-Parent", .parent },             .{ "X-Blocked-By", .blocked_by },
                .{ "X-Start-Date", .start },          .{ "X-Due-Date", .due },
                .{ "X-Estimate-Minutes", .estimate },
            };
            for (map) |m| if (std.ascii.eqlIgnoreCase(m[0], key)) return m[1];
            return null;
        }

        /// The timeline's draft in one write: every change or none. On
        /// success edit mode ends.
        fn applyDraft(self: *Self) void {
            const s = &self.state;
            const st = &self.store;
            const t = &s.timeline;
            const a = s.input_arena.allocator();
            const plan = t.draft.plan(a, &st.snap) catch return s.fail("out of memory", .{});
            if (plan.count() == 0) {
                timeline_edit.reset(t);
                return s.info("nothing to apply", .{});
            }
            if (timeline_edit.refuse(s, plan)) return;
            var items: std.ArrayList(store_mod.BatchItem) = .empty;
            var dues: std.ArrayList(store_mod.DueItem) = .empty;
            const date = struct {
                fn f(d: ?issuez.format.fields.Date) issuez.engine.EditSpec.DateEdit {
                    return if (d) |v| .{ .set = v } else .clear;
                }
            }.f;
            for (plan.issues) |*c| {
                const base = t.draft.baseOf(c.id.slice()).?;
                var spec: issuez.engine.EditSpec = .{ .expect = base.tip };
                if (c.start) |v| spec.start_date = date(v);
                if (c.due) |v| spec.due_date = date(v);
                if (c.estimate) |v| spec.estimate_minutes = if (v) |m| .{ .set = m } else .clear;
                if (c.link) |l| switch (l) {
                    .id => |*id| spec.milestone = .linked(a.dupe(u8, id.slice()) catch ""),
                    .none => spec.milestone = .{ .link = .none },
                    .inherit => spec.milestone = .{ .link = .inherit },
                };
                var add: std.ArrayList([]const u8) = .empty;
                for (c.add) |*x| add.append(a, a.dupe(u8, x.slice()) catch "") catch {};
                var remove: std.ArrayList([]const u8) = .empty;
                for (c.remove) |*x| remove.append(a, a.dupe(u8, x.slice()) catch "") catch {};
                spec.add_blocked_by = add.items;
                spec.remove_blocked_by = remove.items;
                items.append(
                    a,
                    .{ .id = a.dupe(u8, c.id.slice()) catch "", .spec = spec },
                ) catch return s.fail("out of memory", .{});
            }
            for (plan.milestones) |*c| {
                const base = t.draft.baseOf(c.id.slice()).?;
                dues.append(
                    a,
                    .{
                        .id = a.dupe(u8, c.id.slice()) catch "",
                        .due = date(c.due),
                        .expect = base.tip,
                    },
                ) catch return s.fail("out of memory", .{});
            }
            st.applyPlan(items.items, dues.items) catch |e| return self.failWith(e);
            const n = plan.count();
            timeline_edit.reset(t);
            s.info("applied {d} {s}", .{ n, if (n == 1) "change" else "changes" });
        }

        /// One write for all of them: each moves, or none does.
        pub fn moveIssues(
            self: *Self,
            ids: []const store_mod.Id,
            link: store_mod.MilestoneLink,
            unmark: []const store_mod.Id,
        ) void {
            const s = &self.state;
            const st = &self.store;
            var items: std.ArrayList(store_mod.BatchItem) = .empty;
            const a = s.input_arena.allocator();
            const moved = a.alloc(
                bool,
                st.snap.issues.len,
            ) catch return s.fail("out of memory", .{});
            @memset(moved, false);
            // Deleted meanwhile, by a sync or elsewhere.
            var gone: u32 = 0;
            for (ids) |*id| {
                const i = st.snap.find(id.slice()) orelse {
                    gone += 1;
                    continue;
                };
                if (st.snap.issues[i].deleted) {
                    gone += 1;
                    continue;
                }
                // Already there: nothing to write.
                const there = switch (link) {
                    .id => |mid| if (st.snap.proj.milestone[i]) |m| std.mem.eql(
                        u8,
                        m,
                        mid,
                    ) and st.snap.issues[i].milestone_id != null else false,
                    .none => st.snap.proj.milestone[i] == null and !filter.inherits(&st.snap, i),
                    .inherit => filter.inherits(&st.snap, i),
                };
                if (there) continue;
                moved[i] = true;
                var spec: issuez.engine.EditSpec = .{ .expect = st.snap.issues[i].tip };
                spec.milestone = switch (link) {
                    .id => |mid| .linked(mid),
                    .none => .{ .link = .none },
                    .inherit => .{ .link = .inherit },
                };
                items.append(
                    a,
                    .{ .id = id.slice(), .spec = spec },
                ) catch return s.fail("out of memory", .{});
            }
            const to: []const u8 = switch (link) {
                .none => "no milestone",
                .inherit => "the parent's milestone",
                .id => |mid| if (st.snap.findMilestone(mid)) |n| a.dupe(
                    u8,
                    st.snap.milestones[n].name,
                ) catch "" else "?",
            };
            const gone_note = if (gone == 0) "" else std.fmt.allocPrint(
                a,
                "; {d} {s} gone meanwhile",
                .{ gone, if (gone == 1) "issue is" else "issues are" },
            ) catch "";
            if (items.items.len == 0) {
                s.closeModal();
                if (gone == ids.len) return s.fail("{s}: nothing to move", .{gone_note[2..]});
                return s.info("already in {s}{s}", .{ to, gone_note });
            }
            const inheriting = inheritors(
                &st.snap,
                a,
                moved,
            ) catch return s.fail("out of memory", .{});
            // The IDs are in the modal arena, which closing it resets.
            const what = if (items.items.len == 1)
                std.fmt.allocPrint(a, "#{s}", .{shortId(items.items[0].id)}) catch ""
            else
                std.fmt.allocPrint(a, "{d} issues", .{items.items.len}) catch "";
            st.editBatch(items.items) catch |e| return self.failWith(e);
            // `unmark` is in the modal arena too: before closing it.
            s.milestone.unmark(a, &st.snap, unmark) catch {};
            s.closeModal();
            if (inheriting > 0) {
                s.info(
                    "moved {s} to {s}, with {d} sub-issues that inherit{s}",
                    .{ what, to, inheriting, gone_note },
                );
            } else s.info("moved {s} to {s}{s}", .{ what, to, gone_note });
        }

        /// The descendants that move along with the `moved` issues: they
        /// follow their parent's milestone, through a chain of such
        /// parents, and don't move themselves.
        fn inheritors(
            snap: *const store_mod.Snapshot,
            a: Allocator,
            moved: []const bool,
        ) Allocator.Error!u32 {
            var count: u32 = 0;
            var stack: std.ArrayList(u32) = .empty;
            for (moved, 0..) |m, i| if (m) try stack.append(a, @intCast(i));
            // Each issue has one parent: none is reached twice.
            while (stack.pop()) |i| {
                for (snap.proj.children[i]) |c| {
                    if (moved[c] or !filter.followsParent(snap, c)) continue;
                    count += 1;
                    try stack.append(a, c);
                }
            }
            return count;
        }

        /// One write for all of them: each becomes a sub-issue of
        /// `parent`, or none does.
        fn adopt(self: *Self, parent: store_mod.Id, ids: []const store_mod.Id) void {
            const s = &self.state;
            const st = &self.store;
            const a = s.input_arena.allocator();
            // The IDs are in the modal arena, which closing it resets.
            const p = a.dupe(u8, parent.slice()) catch return s.fail("out of memory", .{});
            const pi = st.snap.find(
                p,
            ) orelse return s.fail("#{s} isn't here any more", .{shortId(p)});
            var items: std.ArrayList(store_mod.BatchItem) = .empty;
            for (ids) |*id| {
                const i = st.snap.find(id.slice()) orelse continue;
                if (st.snap.proj.parent[i] == pi) continue;
                const full = a.dupe(u8, id.slice()) catch return s.fail("out of memory", .{});
                items.append(
                    a,
                    .{
                        .id = full,
                        .spec = .{ .parent = .{ .set = p }, .expect = st.snap.issues[i].tip },
                    },
                ) catch return s.fail("out of memory", .{});
            }
            if (items.items.len == 0) {
                s.closeModal();
                return s.info("already sub-issues of #{s}", .{shortId(p)});
            }
            const what = if (items.items.len == 1)
                std.fmt.allocPrint(a, "#{s}", .{shortId(items.items[0].id)}) catch ""
            else
                std.fmt.allocPrint(a, "{d} issues", .{items.items.len}) catch "";
            st.editBatch(items.items) catch |e| return self.failWith(e);
            s.closeModal();
            s.info(
                "added {s} as {s} of #{s}",
                .{ what, if (items.items.len == 1) "a sub-issue" else "sub-issues", shortId(p) },
            );
        }

        /// A card to another column: close it, reopen it, set its workflow
        /// state.
        fn move(self: *Self, id: store_mod.Id, column: []const u8, to_done: bool) void {
            const s = &self.state;
            const st = &self.store;
            const i = st.snap.find(id.slice()) orelse return;
            const done = st.snap.isDone(i);
            if (to_done) {
                if (done) return;
                st.setState(id.slice(), .closed, null) catch |e| return self.failWith(e);
                s.info("closed #{s}", .{shortId(id.slice())});
                return;
            }
            // The column name lives in the snapshot a write replaces.
            var name_buf: [256]u8 = undefined;
            if (column.len > name_buf.len) return self.failWith(error.UnknownWorkflowState);
            @memcpy(name_buf[0..column.len], column);
            const name = name_buf[0..column.len];
            const workflow = if (std.mem.eql(u8, name, "(none)")) "" else name;
            // Checked before reopening, so a refused state changes nothing.
            if (workflow.len > 0)
                st.snap.settings.checkWorkflow(workflow) catch |e| return self.failWith(e);
            if (done) {
                st.setState(id.slice(), .open, null) catch |e| return self.failWith(e);
                if (st.takeReloadError()) |e| return self.failWith(e);
            }
            const now = st.snap.find(id.slice()) orelse return;
            // The column it shows in, the default state included.
            const current = st.snap.proj.workflow(now) orelse "";
            if (!std.mem.eql(u8, current, workflow)) {
                st.edit(id.slice(), .{ .workflow = .fromInput(workflow) }) catch |e|
                    return self.failWith(e);
            }
            s.info(
                "#{s} → {s}",
                .{ shortId(id.slice()), if (workflow.len == 0) "(none)" else workflow },
            );
        }
    };
}
