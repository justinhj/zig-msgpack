const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Primary library module
    const mod = b.addModule("zig_msgpack", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);

    // Examples
    const example_step = b.step("examples", "Build all examples");

    const examples = [_][]const u8{
        "dumpmsgpack",
        "hellonvim",
    };

    var dumpmsgpack_exe: ?*std.Build.Step.Compile = null;

    for (examples) |example_name| {
        const example = b.addExecutable(.{
            .name = example_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example_name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zig_msgpack", .module = mod },
                },
            }),
        });

        const install_example = b.addInstallArtifact(example, .{});
        example_step.dependOn(&example.step);
        example_step.dependOn(&install_example.step);

        if (std.mem.eql(u8, example_name, "dumpmsgpack")) {
            dumpmsgpack_exe = example;
        }

        const run_example = b.addRunArtifact(example);
        if (b.args) |args| {
            run_example.addArgs(args);
        }
        const run_step = b.step(b.fmt("run-{s}", .{example_name}), b.fmt("Run the {s} example", .{example_name}));
        run_step.dependOn(&run_example.step);
    }

    // Default "run" step executes dumpmsgpack for convenience
    if (dumpmsgpack_exe) |dump_exe| {
        const default_run = b.addRunArtifact(dump_exe);
        if (b.args) |args| {
            default_run.addArgs(args);
        }
        const run_step = b.step("run", "Run the dumpmsgpack example");
        run_step.dependOn(&default_run.step);
    }

    // Default build step
    b.default_step.dependOn(test_step);
    b.default_step.dependOn(example_step);
}
