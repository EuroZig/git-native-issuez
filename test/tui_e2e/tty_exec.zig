//! Runs a command on a terminal: in a session of its own, with the
//! terminal as its controlling terminal (the TUI opens /dev/tty) and as
//! its stdin, stdout and stderr. `std.process.spawn` can't do that, so
//! the TUI tests spawn this, which then becomes the command.
//!
//!   tty-exec <tty path> <rows> <cols> <command> [args...]

const std = @import("std");
const c = std.c;

extern "c" fn ioctl(fd: c.fd_t, request: c_ulong, ...) c_int;

const linux = @import("builtin").os.tag == .linux;
/// std.c has it for Linux only; macOS and the BSDs: _IO('t', 97).
const TIOCSCTTY: c_ulong = if (linux) std.os.linux.T.IOCSCTTY else 0x20007461;
/// _IOW('t', 103, struct winsize) off Linux.
const TIOCSWINSZ: c_ulong = if (linux) std.os.linux.T.IOCSWINSZ else 0x80087467;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 5) {
        std.debug.print("usage: tty-exec <tty path> <rows> <cols> <command> [args...]\n", .{});
        return 2;
    }
    const size: std.posix.winsize = .{
        .row = try std.fmt.parseInt(u16, args[2], 10),
        .col = try std.fmt.parseInt(u16, args[3], 10),
        .xpixel = 0,
        .ypixel = 0,
    };

    // Spawned, so not a process group leader: setsid works.
    if (c.setsid() < 0) return fail("setsid");
    const tty_path = try arena.dupeSentinel(u8, args[1], 0);
    const tty = c.open(tty_path, .{ .ACCMODE = .RDWR });
    if (tty < 0) return fail("open the tty");
    if (ioctl(tty, TIOCSCTTY, @as(c_int, 0)) != 0) return fail("TIOCSCTTY");
    // Before the command starts: a TUI reads it first thing.
    if (ioctl(tty, TIOCSWINSZ, &size) != 0) return fail("TIOCSWINSZ");
    for ([_]c.fd_t{ 0, 1, 2 }) |fd| if (c.dup2(tty, fd) < 0) return fail("dup2");
    if (tty > 2) _ = c.close(tty);

    const argv = try arena.allocSentinel(?[*:0]const u8, args.len - 4, null);
    for (args[4..], argv) |arg, *out| out.* = (try arena.dupeSentinel(u8, arg, 0)).ptr;
    const envp = try init.environ_map.createPosixBlock(arena, .{});
    _ = c.execve(argv[0].?, argv.ptr, envp.slice.ptr);
    return fail("execve");
}

fn fail(what: []const u8) u8 {
    std.debug.print("tty-exec: {s} failed (errno {d})\n", .{ what, @backingInt(c.errno(-1)) });
    return 127;
}
