//! Which milestones the milestones view shows, and in what order.
//!
//! The filter text is words and terms, all of which must match; a
//! leading `-` negates one:
//!
//!     release is:at-risk -is:empty due:<2026-12-31
//!
//! Words match the name, the description or an ID prefix, ignoring ASCII
//! case. `is:` takes `overdue`, `at-risk`, `on-track`, `empty`,
//! `blocked`, `open`, `done`; `has:` and `no:` take `due` and
//! `description`; `due:<D`, `due:>D` and `due:D` compare with a date. A
//! term with a value it doesn't know is false, and `problem` says so.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issuez = @import("issuez");
const Snapshot = @import("store.zig").Snapshot;

const schedule = issuez.schedule;
const Date = issuez.format.fields.Date;
const Health = schedule.Health;

pub const Scope = enum {
    open,
    completed,
    retired,
    all,

    pub fn label(s: Scope) []const u8 {
        return switch (s) {
            .open => "Open",
            .completed => "Completed",
            .retired => "Retired",
            .all => "All",
        };
    }

    pub fn next(s: Scope) Scope {
        return switch (s) {
            .open => .completed,
            .completed => .retired,
            .retired => .all,
            .all => .open,
        };
    }
};

pub const SortKey = enum {
    due,
    name,
    progress,
    open,
    health,
    created,

    pub fn label(k: SortKey) []const u8 {
        return @tagName(k);
    }

    pub fn order(k: SortKey) []const u8 {
        return switch (k) {
            .due => "earliest first",
            .name => "A to Z",
            .progress => "least done first",
            .open => "most open work first",
            .health => "worst first",
            .created => "newest first",
        };
    }
};

pub const Query = struct {
    scope: Scope = .open,
    text: []const u8 = "",
    key: SortKey = .due,
    reverse: bool = false,
};

/// What the view shows of each milestone, computed once a frame:
/// `summaries` and `health` are parallel to the snapshot's milestones,
/// `summaries` with one more for the issues in none.
pub const Data = struct {
    summaries: []const schedule.Summary,
    health: []const Health,
    today: Date,

    /// `today` is the local date, `utc_offset_s` its clock's lead on UTC.
    pub fn of(arena: Allocator, snap: *const Snapshot, today: Date, utc_offset_s: i32) Allocator.Error!Data {
        const summaries = try schedule.summarize(arena, snap.proj, snap.milestones, today);
        const health = try arena.alloc(Health, snap.milestones.len);
        for (snap.milestones, summaries[0..snap.milestones.len], health) |m, sum, *h| {
            h.* = schedule.health(m, sum, today, utc_offset_s);
        }
        return .{ .summaries = summaries, .health = health, .today = today };
    }
};

const max_terms = 32;

const Term = struct {
    negate: bool,
    key: enum { word, is, has, no, due },
    value: []const u8,
};

fn parseTerms(text: []const u8, out: *[max_terms]Term) []const Term {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |raw| {
        if (n == max_terms) break;
        var tok = raw;
        const negate = tok.len > 1 and tok[0] == '-';
        if (negate) tok = tok[1..];
        var term: Term = .{ .negate = negate, .key = .word, .value = tok };
        if (std.mem.findScalar(u8, tok, ':')) |colon| {
            const k = tok[0..colon];
            const v = tok[colon + 1 ..];
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(k, "is")) term = .{ .negate = negate, .key = .is, .value = v };
            if (eq(k, "has")) term = .{ .negate = negate, .key = .has, .value = v };
            if (eq(k, "no")) term = .{ .negate = negate, .key = .no, .value = v };
            if (eq(k, "due")) term = .{ .negate = negate, .key = .due, .value = v };
        }
        out[n] = term;
        n += 1;
    }
    return out[0..n];
}

const is_values = [_][]const u8{ "overdue", "at-risk", "risk", "on-track", "empty", "blocked", "open", "done", "completed" };
const has_values = [_][]const u8{ "due", "description" };

fn known(values: []const []const u8, v: []const u8) bool {
    for (values) |x| if (std.ascii.eqlIgnoreCase(x, v)) return true;
    return false;
}

/// `due:`'s operator and date; null when it isn't one.
fn dueTerm(v: []const u8) ?struct { op: u8, date: Date } {
    if (v.len == 0) return null;
    const op = v[0];
    const rest = if (op == '<' or op == '>') v[1..] else v;
    return .{ .op = op, .date = Date.parse(rest) orelse return null };
}

/// What is wrong with the filter text, for the status line; null when
/// nothing is. Formatted into `buf`.
pub fn problem(buf: []u8, text: []const u8) ?[]const u8 {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |_| count += 1;
    var terms_buf: [max_terms]Term = undefined;
    for (parseTerms(text, &terms_buf)) |t| {
        const ok = switch (t.key) {
            .word => true,
            .is => known(&is_values, t.value),
            .has, .no => known(&has_values, t.value),
            .due => dueTerm(t.value) != null,
        };
        if (ok) continue;
        const want = switch (t.key) {
            .word => unreachable,
            .is => "overdue, at-risk, on-track, empty, blocked, open, done",
            .has, .no => "due, description",
            .due => "<YYYY-MM-DD, >YYYY-MM-DD or YYYY-MM-DD",
        };
        return std.fmt.bufPrint(buf, "unknown {t}:{s}, try {s}", .{ t.key, t.value, want }) catch "unknown filter term";
    }
    if (count > max_terms) return std.fmt.bufPrint(buf, "only the first {d} filter terms count", .{max_terms}) catch null;
    return null;
}

fn termMatches(snap: *const Snapshot, data: Data, n: u32, t: Term) bool {
    const m = snap.milestones[n];
    const sum = data.summaries[n];
    const eq = std.ascii.eqlIgnoreCase;
    const v = t.value;
    return switch (t.key) {
        .word => std.ascii.findIgnoreCase(m.name, v) != null or
            std.ascii.findIgnoreCase(m.description, v) != null or
            std.ascii.startsWithIgnoreCase(m.id, v),
        .is => if (eq(v, "overdue"))
            data.health[n] == .overdue
        else if (eq(v, "at-risk") or eq(v, "risk"))
            data.health[n] == .at_risk
        else if (eq(v, "on-track"))
            data.health[n] == .on_track
        else if (eq(v, "empty"))
            sum.issues == 0
        else if (eq(v, "blocked"))
            sum.blocked > 0
        else if (eq(v, "open"))
            m.status == .open
        else if (eq(v, "done") or eq(v, "completed"))
            m.status == .completed
        else
            false,
        .has, .no => blk: {
            if (!known(&has_values, v)) break :blk false;
            const has = if (eq(v, "due")) m.due != null else m.description.len > 0;
            break :blk if (t.key == .has) has else !has;
        },
        .due => blk: {
            const d = m.due orelse break :blk false;
            const due = dueTerm(v) orelse break :blk false;
            const o = d.order(due.date);
            break :blk switch (due.op) {
                '<' => o == .lt,
                '>' => o == .gt,
                else => o == .eq,
            };
        },
    };
}

fn inScope(status: issuez.format.fields.MilestoneStatus, scope: Scope) bool {
    return switch (scope) {
        .open => status == .open,
        .completed => status == .completed,
        .retired => status == .retired,
        .all => true,
    };
}

/// The milestones shown, by position in the snapshot's. `snap.milestones
/// .len` stands for the issues in none, shown last with scope open or all
/// and no filter text.
pub fn rows(arena: Allocator, snap: *const Snapshot, q: Query, data: Data) Allocator.Error![]const u32 {
    var terms_buf: [max_terms]Term = undefined;
    const terms = parseTerms(q.text, &terms_buf);
    var out: std.ArrayList(u32) = .empty;
    next: for (snap.milestones, 0..) |m, idx| {
        const n: u32 = @intCast(idx);
        if (!inScope(m.status, q.scope)) continue;
        for (terms) |t| if (termMatches(snap, data, n, t) == t.negate) continue :next;
        try out.append(arena, n);
    }
    const ctx: Order = .{ .snap = snap, .data = data, .key = q.key, .reverse = q.reverse };
    std.mem.sort(u32, out.items, ctx, Order.lessThan);
    if (terms.len == 0 and (q.scope == .open or q.scope == .all)) {
        try out.append(arena, @intCast(snap.milestones.len));
    }
    return out.items;
}

const Order = struct {
    snap: *const Snapshot,
    data: Data,
    key: SortKey,
    reverse: bool,

    fn compare(o: Order, a: u32, b: u32) std.math.Order {
        const x = o.snap.milestones[a];
        const y = o.snap.milestones[b];
        const sx = o.data.summaries[a];
        const sy = o.data.summaries[b];
        return switch (o.key) {
            .due => dueOrder(x.due, y.due),
            .name => nameOrder(x.name, y.name),
            .progress => fracOrder(sx, sy),
            .open => std.math.order(openLeaves(sy), openLeaves(sx)),
            .health => std.math.order(o.data.health[a].rank(), o.data.health[b].rank()),
            .created => std.math.order(y.created, x.created),
        };
    }

    fn lessThan(o: Order, a: u32, b: u32) bool {
        var ord = o.compare(a, b);
        if (o.reverse) ord = ord.invert();
        if (ord == .eq) {
            // Then the catalog's order (due, name), then the ID: stable.
            ord = dueOrder(o.snap.milestones[a].due, o.snap.milestones[b].due);
            if (ord == .eq) ord = nameOrder(o.snap.milestones[a].name, o.snap.milestones[b].name);
            if (ord == .eq) ord = std.mem.order(u8, o.snap.milestones[a].id, o.snap.milestones[b].id);
        }
        return ord == .lt;
    }
};

/// The work left: open leaves, as the progress counts them.
pub fn openLeaves(s: schedule.Summary) u32 {
    return s.leaves.total - s.leaves.closed;
}

/// None last.
fn dueOrder(a: ?Date, b: ?Date) std.math.Order {
    if (a == null and b == null) return .eq;
    if (a == null) return .gt;
    if (b == null) return .lt;
    return a.?.order(b.?);
}

fn nameOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        const o = std.math.order(std.ascii.toLower(a[i]), std.ascii.toLower(b[i]));
        if (o != .eq) return o;
    }
    return std.math.order(a.len, b.len);
}

/// Least done first; empty ones last.
fn fracOrder(a: schedule.Summary, b: schedule.Summary) std.math.Order {
    if (a.leaves.total == 0 and b.leaves.total == 0) return .eq;
    if (a.leaves.total == 0) return .gt;
    if (b.leaves.total == 0) return .lt;
    const x = @as(u64, a.leaves.closed) * b.leaves.total;
    const y = @as(u64, b.leaves.closed) * a.leaves.total;
    return std.math.order(x, y);
}

const testing = std.testing;

/// Four milestones and the summaries the tests need.
const Fixture = struct {
    milestones: [4]issuez.milestone.Milestone,
    summaries: [5]schedule.Summary,
    health: [4]Health,
    snap: Snapshot,

    fn init(fx: *Fixture) void {
        const ms = struct {
            fn of(id: []const u8, name: []const u8, due: ?[]const u8, status: issuez.format.fields.MilestoneStatus) issuez.milestone.Milestone {
                return .{
                    .id = id,
                    .tip = undefined,
                    .name = name,
                    .description = if (std.mem.eql(u8, name, "Beta")) "the beta release" else "",
                    .due = if (due) |d| Date.parse(d).? else null,
                    .status = status,
                    .created = 0,
                    .conflicts = &.{},
                };
            }
        }.of;
        fx.milestones = .{
            ms("aa11", "Alpha", "2026-12-01", .open),
            ms("BB22", "Beta", "2026-11-01", .open),
            ms("cc33", "Gamma", null, .open),
            ms("dd44", "Delta", "2026-10-01", .completed),
        };
        fx.summaries = .{
            .{ .issues = 4, .leaves = .{ .closed = 1, .total = 4 } },
            .{ .issues = 2, .leaves = .{ .closed = 1, .total = 2 } },
            .{},
            .{ .issues = 3, .leaves = .{ .closed = 3, .total = 3 } },
            .{},
        };
        fx.health = .{ .on_track, .overdue, .no_date, .done };
        fx.snap = .{ .proj = undefined, .milestones = &fx.milestones };
    }

    fn data(fx: *const Fixture) Data {
        return .{ .summaries = &fx.summaries, .health = &fx.health, .today = Date.parse("2026-11-04").? };
    }

    /// The names shown, "-" for none.
    fn names(fx: *const Fixture, q: Query) ![]const u8 {
        const a = testing.allocator;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const out = try rows(arena.allocator(), &fx.snap, q, fx.data());
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(a);
        for (out) |n| {
            if (text.items.len > 0) try text.append(a, ' ');
            try text.appendSlice(a, if (n < fx.milestones.len) fx.milestones[n].name else "-");
        }
        return text.toOwnedSlice(a);
    }

    fn expect(fx: *const Fixture, q: Query, want: []const u8) !void {
        const got = try fx.names(q);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
};

test "rows: scope, words, negation, terms; none only unfiltered" {
    var fx: Fixture = undefined;
    fx.init();
    // By due date, none last, with scope open or all and no text.
    try fx.expect(.{}, "Beta Alpha Gamma -");
    try fx.expect(.{ .scope = .all }, "Delta Beta Alpha Gamma -");
    try fx.expect(.{ .scope = .completed }, "Delta");
    try fx.expect(.{ .scope = .retired }, "");
    // Words: name, description, ID prefix in any case.
    try fx.expect(.{ .text = "ALPHA" }, "Alpha");
    try fx.expect(.{ .text = "release" }, "Beta");
    try fx.expect(.{ .text = "bb" }, "Beta");
    try fx.expect(.{ .text = "-alpha" }, "Beta Gamma");
    try fx.expect(.{ .text = "is:overdue" }, "Beta");
    try fx.expect(.{ .text = "-is:overdue" }, "Alpha Gamma");
    try fx.expect(.{ .text = "is:empty" }, "Gamma");
    try fx.expect(.{ .scope = .all, .text = "is:done" }, "Delta");
    try fx.expect(.{ .text = "has:due" }, "Beta Alpha");
    try fx.expect(.{ .text = "no:due" }, "Gamma");
    try fx.expect(.{ .text = "has:description" }, "Beta");
    try fx.expect(.{ .text = "due:<2026-12-01" }, "Beta");
    try fx.expect(.{ .text = "due:>2026-11-01" }, "Alpha");
    try fx.expect(.{ .text = "due:2026-12-01" }, "Alpha");
    // Unknown values match nothing; negated, everything.
    try fx.expect(.{ .text = "is:whatever" }, "");
    try fx.expect(.{ .text = "no:whatever" }, "");
    try fx.expect(.{ .text = "-no:whatever" }, "Beta Alpha Gamma");
    try fx.expect(.{ .text = "due:soon" }, "");
}

test "rows: sort keys, reverse, ties in catalog order" {
    var fx: Fixture = undefined;
    fx.init();
    try fx.expect(.{ .key = .name }, "Alpha Beta Gamma -");
    try fx.expect(.{ .key = .name, .reverse = true }, "Gamma Beta Alpha -");
    // Least done first, empty last.
    try fx.expect(.{ .key = .progress }, "Alpha Beta Gamma -");
    try fx.expect(.{ .key = .health }, "Beta Alpha Gamma -");
    // Alpha has 3 open, Beta 1; Gamma and Delta none: tied, by due date.
    try fx.expect(.{ .key = .open, .scope = .all }, "Alpha Beta Delta Gamma -");
    // Reversed, the ties keep the catalog's order.
    try fx.expect(.{ .key = .open, .scope = .all, .reverse = true }, "Delta Gamma Beta Alpha -");
}

test problem {
    var buf: [128]u8 = undefined;
    try testing.expect(problem(&buf, "alpha is:overdue -has:due due:<2026-01-01 v1:beta") == null);
    try testing.expectStringStartsWith(problem(&buf, "is:late").?, "unknown is:late");
    try testing.expectStringStartsWith(problem(&buf, "-no:owner").?, "unknown no:owner");
    try testing.expectStringStartsWith(problem(&buf, "due:<soon").?, "unknown due:<soon");
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..max_terms + 1) |_| try many.appendSlice(testing.allocator, "x ");
    try testing.expectEqualStrings("only the first 32 filter terms count", problem(&buf, many.items).?);
    var terms_buf: [max_terms]Term = undefined;
    try testing.expectEqual(@as(usize, max_terms), parseTerms(many.items, &terms_buf).len);
}
