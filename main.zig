const std = @import("std");
const posix = std.posix;
const stdout = std.Io.File.stdout();
const stdin = std.Io.File.stdin();
const cwd = std.Io.Dir.cwd();

const State = enum(u8) {
    Menu = 0,
    C,
};

var state: State = undefined;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    std.debug.assert(@intFromEnum(State.Menu) == 0 and
        @intFromEnum(State.C) == 1);

    if (args.len == 1) {
        state = .Menu;
    }

    const io = init.io;

    try stdout.writeStreamingAll(io, "\x1b[H\x1b[2J");
    try stdout.writeStreamingAll(io, "Welcome to Devin!\n");
    try stdout.writeStreamingAll(
        io,
        "Devin is development utility to initialize a project for linux\n\n",
    );

    switch (state) {
        .Menu => try menuState(io, arena),
        else => unreachable,
    }
}

fn menuState(io: std.Io, allocator: std.mem.Allocator) !void {
    const original_settings = posix.tcgetattr(0) catch |err| {
        std.log.err("{}", .{err});
        return;
    };

    var raw_settings = original_settings;
    raw_settings.lflag.ECHO = false;
    raw_settings.lflag.ICANON = false;

    posix.tcsetattr(0, .NOW, raw_settings) catch |err| {
        std.log.err("{}", .{err});
        return;
    };

    defer posix.tcsetattr(0, .NOW, original_settings) catch unreachable;

    try stdout.writeStreamingAll(io, "Choose which project to initialize:\n\n");
    try stdout.writeStreamingAll(io, "1. C/C++ Project\n");
    try stdout.writeStreamingAll(io, "\nPress appropiate number to select...\n");
    var buf: [1]u8 = undefined;
    while (true) {
        const bytes_read = try stdin.readStreaming(io, &.{&buf});
        const str = buf[0..bytes_read];
        const num = std.fmt.parseUnsigned(u32, str, 10) catch {
            continue;
        };
        const state_len = std.meta.fieldNames(State).len;
        if (num != 0 and num <= state_len - 1) {
            state = @enumFromInt(num);
            break;
        } else {}
    }

    switch (state) {
        .C => try cState(io, allocator),
        else => unreachable,
    }
}

const CAction = enum(u8) {
    InitTidyConfig = 0,
    InitFormatConfig,

    pub fn toString(self: CAction) []const u8 {
        return switch (self) {
            .InitTidyConfig => "Initialize .clang-tidy config",
            .InitFormatConfig => "Initialize .clang-format config",
        };
    }
};

fn cState(io: std.Io, allocator: std.mem.Allocator) !void {
    try stdout.writeStreamingAll(io, "\x1b[H\x1b[2J");
    try stdout.writeStreamingAll(io, "Configure C/C++ Project...\n\n");

    var selected = try fzfMultiSelectEnum(CAction, io, allocator);
    defer selected.deinit(allocator);

    for (selected.items) |s| {
        std.debug.print("selected {}\n", .{s});
    }
}

fn shouldWriteFile(io: std.Io, path: []const u8) !bool {
    var fileExist = true;
    cwd.access(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            fileExist = false;
        }
    };

    if (fileExist) {
        try stdout.writeStreamingAll(io, path);
        try stdout.writeStreamingAll(io, " file already exist in current directory, overwrite it? [y/N]\n\n");
        while (true) {
            var buf: [1]u8 = undefined;
            const bytes_read = try stdin.readStreaming(io, &.{&buf});
            const str = buf[0..bytes_read];
            const proceed = std.mem.eql(u8, str, "y") or
                std.mem.eql(u8, str, "Y");
            const abort = std.mem.eql(u8, str, "n") or
                std.mem.eql(u8, str, "N") or
                std.mem.eql(u8, str, "\n");
            if (proceed) return true;
            if (abort) {
                return false;
            }
        }
    }
    return true;
}

fn getCurrentDirAbsolutePath(io: std.Io, path_buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    var absolute_path: []const u8 = undefined;
    if (cwd.realPathFile(io, ".", path_buf)) |path_len| {
        absolute_path = path_buf[0..path_len];
    } else |err| {
        std.log.err("Failed to get current directory: {any}\n", .{err});
        return error.FailedToGetCurrentDir;
    }
    return absolute_path;
}

fn fzfMultiSelectEnum(comptime T: type, io: std.Io, allocator: std.mem.Allocator) !std.ArrayList(T) {
    const options = std.meta.fieldNames(T);
    const input = try std.mem.join(allocator, "\n", options);
    defer allocator.free(input);

    var child = try std.process.spawn(
        io,
        .{ .argv = &.{
            "fzf",       "--multi",
            "--bind",    "space:toggle",
            "--bind",    "start:hide-input",
            "--marker",  "x ",
            "--pointer", ">",
            "--reverse", "--height",
            "40%",
        }, .stdin = .pipe, .stdout = .pipe },
    );
    defer child.kill(io);

    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;

    var buf: [256]u8 = undefined;
    const n = try child.stdout.?.readStreaming(io, &.{&buf});
    const output_str = std.mem.trimEnd(u8, buf[0..n], "\n");
    std.debug.assert(output_str.len != 0);

    var it = std.mem.tokenizeScalar(u8, output_str, '\n');

    var values: std.ArrayList(T) = try .initCapacity(allocator, options.len);

    while (it.next()) |line| {
        try values.append(allocator, std.meta.stringToEnum(T, line).?);
    }

    return values;
}
