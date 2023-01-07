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
    flags.append("-DMINIZ_USE_UNALIGNED_LOADS_AND_STORES=1") catch unreachable;
    if (exe.target.getCpuArch().endian() == .Little) {
        flags.append("-DMINIZ_LITTLE_ENDIAN=1") catch unreachable;
    }

    var lib = exe.builder.addStaticLibrary("zmini", thisDir() ++ "/src/main.zig");
    lib.setBuildMode(exe.build_mode);
    lib.setTarget(exe.target);
    lib.linkLibC();
    lib.addIncludePath(thisDir() ++ "/src/c/");
    lib.addCSourceFile(
        thisDir() ++ "/src/c/miniz.c",
        flags.items,
    );
    exe.linkLibrary(lib);
    exe.addIncludePath(thisDir() ++ "/src/c/");
}

pub fn getPkg() std.build.Pkg {
    return .{
        .name = "zmini",
        .source = .{
            .path = thisDir() ++ "/src/main.zig",
        },
    };
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
