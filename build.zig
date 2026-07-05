const std = @import("std");

// M6 (Zig track): builds the C httpserver with zig cc, and hosts the ztest
// runner (Zig-based replacement for the bash+python test harness).
//
// The C sources under src/ are mid-port (see docs/PLAN.md) and are expected
// to fail to compile until the C track lands M1. That is fine: `zig build`
// should fail with C compiler diagnostics, not with build.zig plumbing
// errors. Once src/ builds, `zig build` produces ./zig-out/bin/httpserver.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Sanitizer toggle for the C build, e.g. `zig build -Dsan=thread`.
    // Lifted from docs/zig-interop.md's Level-0/Level-1 adoption plan: this
    // is the cheap, always-available half of that doc (route the existing
    // C build through zig cc's bundled sanitizers). The rest of that
    // doc -- @cImport-based white-box L1-L3 unit/memory/concurrency tests
    // against internal C symbols -- is a separate, complementary layer to
    // the black-box ztest runner below; see ztest/README.md for how the
    // two relate and why it isn't built yet (the C symbols it would call
    // don't exist/compile until the C track's M1 lands).
    const san = b.option([]const u8, "san", "none|address|thread|undefined (instruments the C httpserver build)") orelse "none";

    // ---- The C httpserver -------------------------------------------------
    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{
        .name = "httpserver",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("pthread");
    exe.addIncludePath(b.path("lib"));

    var c_flags = std.ArrayList([]const u8).empty;
    c_flags.appendSlice(b.allocator, &.{
        "-Wall",
        "-Wextra",
        "-Werror",
        "-pedantic",
        "-std=gnu11",
    }) catch @panic("OOM");
    if (!std.mem.eql(u8, san, "none")) {
        c_flags.append(b.allocator, b.fmt("-fsanitize={s}", .{san})) catch @panic("OOM");
        c_flags.append(b.allocator, "-fno-omit-frame-pointer") catch @panic("OOM");
    }

    // Glob src/*.c so newly ported modules (connection.c, response.c,
    // request.c, ...) are picked up automatically as the C track lands them.
    var src_dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch |err| {
        std.debug.panic("failed to open src/: {t}", .{err});
    };
    defer src_dir.close();

    var sources = std.ArrayList([]const u8).empty;
    var it = src_dir.iterate();
    while (it.next() catch |err| std.debug.panic("failed to iterate src/: {t}", .{err})) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
        sources.append(b.allocator, b.fmt("src/{s}", .{entry.name})) catch @panic("OOM");
    }

    exe.addCSourceFiles(.{
        .files = sources.items,
        .flags = c_flags.items,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the httpserver (built by zig)");
    run_step.dependOn(&run_cmd.step);

    // ---- ztest: unit tests (TOML parser, audit-log checker, ...) --------
    const ztest_mod = b.createModule(.{
        .root_source_file = b.path("ztest/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- ztest: the mock server (pure Zig, used to validate the runner) --
    // Shares ztest's wire.zig (request/response line + header parsing) so
    // the mock and the driver agree on the wire format by construction.
    const mock_mod = b.createModule(.{
        .root_source_file = b.path("ztest/mock/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mock_mod.addImport("wire", b.createModule(.{
        .root_source_file = b.path("ztest/src/wire.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const mock_exe = b.addExecutable(.{
        .name = "mock-httpserver",
        .root_module = mock_mod,
    });
    b.installArtifact(mock_exe);

    const unit_tests = b.addTest(.{
        .root_module = ztest_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run ztest unit tests (TOML parser, audit checker)");
    test_step.dependOn(&run_unit_tests.step);

    // ---- ztest: the HTTP behavior runner ---------------------------------
    // `zig build test-http -- <path-to-server-binary>` drives the server
    // binary (make-built or zig-built) through the workload suite and
    // checks the audit log for well-formedness + linearizability, the way
    // olivertwist/sherlock/watson do together.
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("ztest/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    runner_mod.addImport("ztest", ztest_mod);

    const runner_exe = b.addExecutable(.{
        .name = "ztest-runner",
        .root_module = runner_mod,
    });
    b.installArtifact(runner_exe);

    const run_runner = b.addRunArtifact(runner_exe);
    if (b.args) |args| {
        run_runner.addArgs(args);
    } else {
        // Default: point the runner at the mock server we just built, so
        // `zig build test-http` works out of the box with no arguments.
        // addArtifactArg wires up the dependency on mock_exe without
        // pulling in the (currently broken) C httpserver via the global
        // install step.
        run_runner.addArtifactArg(mock_exe);
    }

    const test_http_step = b.step("test-http", "Run the ztest workload suite against a server binary (default: the mock; pass -- <path> for another)");
    test_http_step.dependOn(&run_runner.step);
}
