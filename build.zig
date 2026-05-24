const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version baked into the binary (`toggl version`). The release workflow
    // passes `-Dversion=<tag>`; local builds report "dev".
    const version = b.option([]const u8, "version", "Version string for `toggl version`") orelse "dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // A single executable built from src/main.zig. The other src/*.zig files
    // are pulled in via relative `@import`, so they don't need to be wired up
    // here.
    const exe = b.addExecutable(.{
        .name = "toggl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Reserve Mach-O header padding so a code-signature load command can be
    // added after the fact. Without this, signing an x86_64 macOS build (which
    // Zig doesn't self-sign) fails with "insufficient room to write code
    // signature load command". Harmless/ignored on non-macOS targets.
    if (target.result.os.tag == .macos) {
        exe.headerpad_max_install_names = true;
    }

    // Make the baked version importable as `@import("build_options")`.
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    // `zig build run -- <args>` runs the CLI with arguments.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the toggl CLI");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs any `test {}` blocks in the source.
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
