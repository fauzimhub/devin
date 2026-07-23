const std = @import("std");
const posix = std.posix;
const stdout = std.Io.File.stdout();
const stdin = std.Io.File.stdin();
const cwd = std.Io.Dir.cwd();

const State = enum(i8) {
    NoState = -1,
    Menu,
    Make,
    Tidy,
};

const state_map = std.StaticStringMap(State).initComptime(.{
    .{ "menu", .Menu },
    .{ "make", .Make },
    .{ "tidy", .Tidy },
});

const MenuState = enum(u8) {
    C = 0,
};

var state: State = undefined;
const BuildMode = enum(i8) {
    Invalid = -2,
    Unset,
    All,
    Debug,
    ReleaseSafe,
    ReleaseSmall,
    ReleaseFast,

    pub fn buildDir(self: BuildMode) []const u8 {
        return switch (self) {
            .Debug => "build",
            .ReleaseSafe => "build-safe",
            .ReleaseSmall => "build-small",
            .ReleaseFast => "build-fast",
            else => "",
        };
    }

    pub fn flags(self: BuildMode) []const u8 {
        return switch (self) {
            .Debug => "-DCMAKE_BUILD_TYPE=Debug",
            .ReleaseSafe => "-DCMAKE_BUILD_TYPE=ReleaseSafe",
            .ReleaseSmall => "-DCMAKE_BUILD_TYPE=ReleaseSmall",
            .ReleaseFast => "-DCMAKE_BUILD_TYPE=Fast",
            else => "",
        };
    }
};

const buildmode_map = std.StaticStringMap(BuildMode).initComptime(.{
    .{ "debug", .Debug },
    .{ "safe", .ReleaseSafe },
    .{ "small", .ReleaseSmall },
    .{ "fast", .ReleaseFast },
});


pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    std.debug.assert(@intFromEnum(State.Menu) == 0 and
        @intFromEnum(State.C) == 1);

    if (args.len == 1) {
        state = .Menu;
    } else if (args.len == 2 and std.mem.eql(u8, args[1], "make")) {
        state = .Make;
    } else {
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
        .Menu => try menuState(io, gpa),
        .Make => try makeState(io, gpa),
        else => return,
    }
}

fn makeState(io: std.Io, allocator: std.mem.Allocator) !void {
    const argv = &.{ "cmake", "-G", "Ninja", "-S", ".", "-B", "build" };
    try stdout.writeStreamingAll(io, "Executing CMake using Ninja as build system generator, placing all generated files into build/ directory...\n\n");
    const cmd_str = try std.mem.join(allocator, " ", argv);
    try stdout.writeStreamingAll(io, cmd_str);
    try stdout.writeStreamingAll(io, "\n\n");

    var child = try std.process.spawn(io, .{
        .argv = argv,
    });
    defer allocator.free(cmd_str);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                try stdout.writeStreamingAll(io, "CMake failed.\n");
                return error.CmakeFailed;
            }
        },
        else => return error.CmakeTerminatedAbnormally,
    }

    try stdout.writeStreamingAll(io, "\nCMake succeeded.\n");
}

fn menuState(io: std.Io, allocator: std.mem.Allocator) !void {
    var menu_state: MenuState = undefined;
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
        const menu_state_len = std.meta.fieldNames(MenuState).len;
        if (num != 0 and num - 1 < menu_state_len) {
            menu_state = @enumFromInt(num - 1);
            break;
        } else {}
    }

    switch (menu_state) {
        .C => try cState(io, allocator),
        // else => unreachable,
    }
}

const CAction = enum(u8) {
    InitTidyConfig = 0,
    InitFormatConfig,
    InitCMake,
    InitDoxyfile,

    pub fn toString(self: CAction) []const u8 {
        return switch (self) {
            .InitTidyConfig => "Initialize .clang-tidy config",
            .InitFormatConfig => "Initialize .clang-format config",
            .InitCMake => "Initialize CMakeLists.txt",
            .InitDoxyfile => "Initialize Doxyfile",
        };
    }
};

fn cState(io: std.Io, allocator: std.mem.Allocator) !void {
    try stdout.writeStreamingAll(io, "\x1b[H\x1b[2J");
    try stdout.writeStreamingAll(io, "Configure C/C++ Project...\n\n");

    var selected = try fzfMultiSelectEnum(CAction, io, allocator);
    defer selected.deinit(allocator);

    if (selected.items.len == 0) {
        try stdout.writeStreamingAll(io, "No actions selected, exiting.\n");
        return;
    }

    try stdout.writeStreamingAll(io, "\x1b[H\x1b[2J");
    try stdout.writeStreamingAll(io, "You selected:\n\n");
    for (selected.items) |s| {
        try stdout.writeStreamingAll(io, "  - ");
        try stdout.writeStreamingAll(io, s.toString());
        try stdout.writeStreamingAll(io, "\n");
    }
    try stdout.writeStreamingAll(io, "\nProceed? [y/N]\n");

    while (true) {
        var buf: [1]u8 = undefined;
        const bytes_read = try stdin.readStreaming(io, &.{&buf});
        const str = buf[0..bytes_read];
        const proceed = std.mem.eql(u8, str, "y") or
            std.mem.eql(u8, str, "Y");
        const abort = std.mem.eql(u8, str, "n") or
            std.mem.eql(u8, str, "N") or
            std.mem.eql(u8, str, "\n") or
            std.mem.eql(u8, str, "\x1b");
        if (proceed) break;
        if (abort) {
            try stdout.writeStreamingAll(io, "Cancelled.\n");
            return;
        }
    }

    for (selected.items) |s| {
        switch (s) {
            .InitTidyConfig => try initTidyConfig(io),
            .InitFormatConfig => try initFormatConfig(io),
            .InitCMake => try initCMake(io),
            .InitDoxyfile => try initDoxyfile(io),
        }
    }
}

fn initCMake(io: std.Io) !void {
    const name = "CMakeLists.txt";
    try stdout.writeStreamingAll(io, "\x1b[H\x1b[2J");
    try stdout.writeStreamingAll(io, "Initialize " ++ name ++ " file in current directory...\n\n");

    if (!try shouldWriteFile(io, name)) return;

    try stdout.writeStreamingAll(io, "Should we make CMakeLists.txt C or C++?\n\n");
    try stdout.writeStreamingAll(io, "1. C\n");
    try stdout.writeStreamingAll(io, "2. C++\n\n");

    var num: u8 = undefined;
    while (true) {
        var buf: [1]u8 = undefined;
        const bytes_read = try stdin.readStreaming(io, &.{&buf});
        const str = buf[0..bytes_read];

        num = std.fmt.parseUnsigned(u8, str, 10) catch {
            continue;
        };
        if (num == 1 or num == 2) {
            break;
        } else {}
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = try getCurrentDirAbsolutePath(io, &path_buf);
    const project_name = std.fs.path.basename(absolute_path);

    var print_buf: [2048]u8 = undefined;
    var text: []const u8 = undefined;
    if (num == 1) {
        text = try std.fmt.bufPrint(
            &print_buf,
            \\cmake_minimum_required(VERSION 3.20)
            \\project({s} LANGUAGES C)
            \\set(CMAKE_C_STANDARD 99)
            \\set(CMAKE_C_STANDARD_REQUIRED ON)
            \\set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
            \\set(CMAKE_CONFIGURATION_TYPES
            \\Debug ReleaseFast ReleaseSafe ReleaseSmall
            \\    CACHE STRING "Available build types" FORCE)
            \\if(NOT CMAKE_BUILD_TYPE)
            \\    set(CMAKE_BUILD_TYPE Debug)
            \\endif()
            \\set(CMAKE_C_FLAGS_DEBUG   "-O0 -g")
            \\set(CMAKE_C_FLAGS_RELEASEFAST   "-O3 -s -DNDEBUG")
            \\set(CMAKE_C_FLAGS_RELEASESAFE  "-O2 -DNDEBUG -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection")
            \\set(CMAKE_C_FLAGS_RELEASESMALL    "-Os -s -DNDEBUG")
            \\add_executable(${{PROJECT_NAME}}
            \\    src/main.c)
            \\target_compile_options(${{PROJECT_NAME}} PRIVATE
            \\    -pedantic
            \\    -Wall
            \\    -Wextra
            \\    -Wconversion
            \\    -Wsign-conversion)
            \\
        ,
            .{project_name},
        );
    } else if (num == 2) {
        text = try std.fmt.bufPrint(
            &print_buf,
            \\cmake_minimum_required(VERSION 3.20)
            \\project({s} LANGUAGES CXX)
            \\set(CMAKE_CXX_STANDARD 17)
            \\set(CMAKE_CXX_STANDARD_REQUIRED ON)
            \\set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
            \\set(CMAKE_CONFIGURATION_TYPES
            \\Debug ReleaseFast ReleaseSafe ReleaseSmall
            \\    CACHE STRING "Available build types" FORCE)
            \\if(NOT CMAKE_BUILD_TYPE)
            \\    set(CMAKE_BUILD_TYPE Debug)
            \\endif()
            \\set(CMAKE_CXX_FLAGS_DEBUG   "-O0 -g")
            \\set(CMAKE_CXX_FLAGS_RELEASEFAST   "-O3 -s -DNDEBUG")
            \\set(CMAKE_CXX_FLAGS_RELEASESAFE  "-O2 -DNDEBUG -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection")
            \\set(CMAKE_CXX_FLAGS_RELEASESMALL    "-Os -s -DNDEBUG")
            \\add_executable(${{PROJECT_NAME}}
            \\    src/main.cpp)
            \\target_compile_options(${{PROJECT_NAME}} PRIVATE
            \\    -pedantic
            \\    -Wall
            \\    -Weffc++
            \\    -Wextra
            \\    -Wconversion
            \\    -Wsign-conversion)
            \\
        ,
            .{project_name},
        );
    }

    try createFileInSubPath(io, name, text);

    try stdout.writeStreamingAll(io, name ++ " generated in ");
    try stdout.writeStreamingAll(io, absolute_path);
    try stdout.writeStreamingAll(io, "\n");
}

fn isFileExist(io: std.Io, path: []const u8) bool {
    var exist = true;
    cwd.access(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            exist = false;
        }
    };
    return exist;
}
fn shouldWriteFile(io: std.Io, path: []const u8) !bool {
    if (isFileExist(io, path)) {
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

fn createFileInSubPath(io: std.Io, sub_path: []const u8, text: []const u8) !void {
    const file = try cwd.createFile(io, sub_path, .{
        .read = true,
        .permissions = std.Io.File.Permissions.fromMode(0o644),
        .truncate = true,
    });
    defer file.close(io);

    var buffer: [256]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(text);
    try writer.flush();

    return;
}

fn initDoxyfile(io: std.Io) !void {
    const name = "Doxyfile";
    try stdout.writeStreamingAll(io, "\x1b[H\x1b[2J");
    try stdout.writeStreamingAll(io, "Initialize " ++ name ++ " file in current directory...\n\n");

    if (!try shouldWriteFile(io, name)) return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = try getCurrentDirAbsolutePath(io, &path_buf);
    const project_name = std.fs.path.basename(absolute_path);

    var print_buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &print_buf,
        \\PROJECT_NAME           = "{s}"
        \\OUTPUT_DIRECTORY       = docs
        \\INPUT                  = src
        \\RECURSIVE              = YES
        \\EXTRACT_ALL            = YES
        \\GENERATE_LATEX         = NO
        \\GENERATE_HTML          = YES
        \\
    ,
        .{project_name},
    );

    try createFileInSubPath(io, name, text);

    try stdout.writeStreamingAll(io, name ++ " generated in ");
    try stdout.writeStreamingAll(io, absolute_path);
    try stdout.writeStreamingAll(io, "\n");
}

fn initTidyConfig(io: std.Io) !void {
    const name = ".clang-tidy";
    try stdout.writeStreamingAll(io, "\x1b[H\x1b[2J");
    try stdout.writeStreamingAll(io, "Initialize " ++ name ++ " file in current directory...\n\n");

    if (!try shouldWriteFile(io, name)) return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = try getCurrentDirAbsolutePath(io, &path_buf);

    var print_buf: [256]u8 = undefined;

    const text = try std.fmt.bufPrint(
        &print_buf,
        \\Checks: "bugprone-*,modernize-*,readability-*,performance-*,portability-*,clang-analyzer-*,-modernize-use-trailing-return-type"
        \\WarningsAsErrors: ""
        \\HeaderFilterRegex: "{s}/src/.*"
        \\FormatStyle: none
        \\
    ,
        .{absolute_path},
    );

    try createFileInSubPath(io, name, text);

    try stdout.writeStreamingAll(io, name ++ " generated in ");
    try stdout.writeStreamingAll(io, absolute_path);
    try stdout.writeStreamingAll(io, "\n");
}

fn initFormatConfig(io: std.Io) !void {
    const name = ".clang-format";
    try stdout.writeStreamingAll(io, "\x1b[H\x1b[2J");
    try stdout.writeStreamingAll(io, "Initialize " ++ name ++ " file in current directory...\n\n");

    if (!try shouldWriteFile(io, name)) return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = try getCurrentDirAbsolutePath(io, &path_buf);

    var print_buf: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &print_buf,
        \\# Google C/C++ Code Style settings
        \\# https://clang.llvm.org/docs/ClangFormatStyleOptions.html
        \\# Author: Kehan Xue, kehan.xue (at) gmail.com
        \\Language: Cpp
        \\BasedOnStyle: Google
        \\AccessModifierOffset: -1
        \\AlignAfterOpenBracket: Align
        \\AlignConsecutiveAssignments: None
        \\AlignOperands: Align
        \\AllowAllArgumentsOnNextLine: true
        \\AllowAllConstructorInitializersOnNextLine: true
        \\AllowAllParametersOfDeclarationOnNextLine: false
        \\AllowShortBlocksOnASingleLine: Empty
        \\AllowShortCaseLabelsOnASingleLine: false
        \\AllowShortFunctionsOnASingleLine: Inline
        \\AllowShortIfStatementsOnASingleLine: Never
        \\AllowShortLambdasOnASingleLine: Inline
        \\AllowShortLoopsOnASingleLine: false
        \\AlwaysBreakAfterReturnType: None
        \\AlwaysBreakTemplateDeclarations: Yes
        \\BinPackArguments: true
        \\BreakBeforeBraces: Custom
        \\BraceWrapping:
        \\  AfterCaseLabel: false
        \\  AfterClass: false
        \\  AfterStruct: false
        \\  AfterControlStatement: Never
        \\  AfterEnum: false
        \\  AfterFunction: false
        \\  AfterNamespace: false
        \\  AfterUnion: false
        \\  AfterExternBlock: false
        \\  BeforeCatch: false
        \\  BeforeElse: false
        \\  BeforeLambdaBody: false
        \\  IndentBraces: false
        \\  SplitEmptyFunction: false
        \\  SplitEmptyRecord: false
        \\  SplitEmptyNamespace: false
        \\BreakBeforeBinaryOperators: None
        \\BreakBeforeTernaryOperators: true
        \\BreakConstructorInitializers: BeforeColon
        \\BreakInheritanceList: BeforeColon
        \\ColumnLimit: 80
        \\CompactNamespaces: false
        \\ContinuationIndentWidth: 4
        \\Cpp11BracedListStyle: true
        \\DerivePointerAlignment: false
        \\EmptyLineBeforeAccessModifier: LogicalBlock
        \\FixNamespaceComments: true
        \\IncludeBlocks: Preserve
        \\IndentCaseLabels: true
        \\IndentPPDirectives: None
        \\IndentWidth: 2
        \\KeepEmptyLinesAtTheStartOfBlocks: true
        \\MaxEmptyLinesToKeep: 1
        \\NamespaceIndentation: None
        \\ObjCSpaceAfterProperty: false
        \\ObjCSpaceBeforeProtocolList: true
        \\PointerAlignment: Left
        \\ReflowComments: false
        \\SeparateDefinitionBlocks: Always
        \\SpaceAfterCStyleCast: false
        \\SpaceAfterLogicalNot: false
        \\SpaceAfterTemplateKeyword: true
        \\SpaceBeforeAssignmentOperators: true
        \\SpaceBeforeCpp11BracedList: false
        \\SpaceBeforeCtorInitializerColon: true
        \\SpaceBeforeInheritanceColon: true
        \\SpaceBeforeParens: ControlStatements
        \\SpaceBeforeRangeBasedForLoopColon: true
        \\SpaceBeforeSquareBrackets: false
        \\SpaceInEmptyParentheses: false
        \\SpacesBeforeTrailingComments: 2
        \\SpacesInAngles: false
        \\SpacesInCStyleCastParentheses: false
        \\SpacesInContainerLiterals: false
        \\SpacesInParentheses: false
        \\SpacesInSquareBrackets: false
        \\Standard: c++11
        \\TabWidth: 4
        \\UseTab: Never
        \\
    ,
        .{},
    );

    try createFileInSubPath(io, name, text);

    try stdout.writeStreamingAll(io, name ++ " generated in ");
    try stdout.writeStreamingAll(io, absolute_path);
    try stdout.writeStreamingAll(io, "\n");
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

    var values: std.ArrayList(T) = try .initCapacity(allocator, options.len);

    var buf: [256]u8 = undefined;
    const n = child.stdout.?.readStreaming(io, &.{&buf}) catch |err|
        switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };

    const output_str = std.mem.trimEnd(u8, buf[0..n], "\n");
    var it = std.mem.tokenizeScalar(u8, output_str, '\n');

    while (it.next()) |line| {
        try values.append(allocator, std.meta.stringToEnum(T, line).?);
    }

    return values;
}
