const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);
    link(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}

pub fn link(exe: *std.build.LibExeObjStep) void {
    var flags = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer flags.deinit();
    flags.append("-Wno-return-type-c-linkage") catch unreachable;
    flags.append("-fno-sanitize=undefined") catch unreachable;

    var lib = exe.builder.addStaticLibrary("zmini", comptime thisDir() ++ "/src/main.zig");
    lib.setBuildMode(exe.build_mode);
    lib.setTarget(exe.target);
    lib.linkLibC();
    lib.addIncludeDir(thisDir() ++ "/src/c/");
    lib.addCSourceFile(
        comptime thisDir() ++ "/src/c/miniz.c",
        flags.items,
    );
    exe.linkLibrary(lib);
}

pub fn getPkg() std.build.Pkg {
    return .{
        .name = "zmini",
        .source = .{
            .path = comptime thisDir() ++ "/src/main.zig",
        },
    };
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
