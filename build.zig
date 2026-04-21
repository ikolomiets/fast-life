const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fast_life_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("fast_life", fast_life_module);
    const exe = b.addExecutable(.{
        .name = "fast_life",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Game of Life CLI");
    run_step.dependOn(&run_cmd.step);

    const package_tests = b.addTest(.{
        .root_module = fast_life_module,
    });
    const run_package_tests = b.addRunArtifact(package_tests);

    const main_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_test_module.addImport("fast_life", fast_life_module);
    const main_tests = b.addTest(.{
        .root_module = main_test_module,
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_package_tests.step);
    test_step.dependOn(&run_main_tests.step);
}
