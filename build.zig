const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("avro", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "gld-avrogen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "avro", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run gld-avrogen-zig");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const gen_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/generated_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "avro", .module = mod },
        },
    });
    const gen_tests = b.addTest(.{ .root_module = gen_tests_mod });
    const run_gen_tests = b.addRunArtifact(gen_tests);
    test_step.dependOn(&run_gen_tests.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benches/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "avro", .module = mod },
        },
    });
    const bench_exe = b.addExecutable(.{
        .name = "avro-bench",
        .root_module = bench_mod,
    });
    const bench_step = b.step("bench", "Print ns/op for a representative record");
    const bench_run = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_run.step);
}
