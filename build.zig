const std = @import("std");

// M6 (Zig track): builds the C httpserver with zig cc, and hosts the ztest
// runner (Zig-based replacement for the bash+python test harness).
//
// The C track has landed: `zig build` compiles src/*.c and produces
// ./zig-out/bin/httpserver. C flags are kept in lockstep with the Makefile
// (rubric warnings + -std=gnu17).

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
    //
    // IMPORTANT (task C-lite): the original version of this toggle only ever
    // appended `-fsanitize=$san` to the *C compile* flags. That instruments
    // the object files but does nothing at link time, so the resulting
    // `zig-out/bin/httpserver` was silently uninstrumented -- linking it
    // failed outright once source files that actually race/leak existed
    // (verified: `-Dsan=thread` failed with "undefined symbol: __tsan_init"
    // et al., because Zig links its bundled libtsan runtime only when told to
    // via the Module-level `.sanitize_thread` field, not via a raw C flag).
    // Fixed per-sanitizer below:
    //   thread    -> `exe_mod.sanitize_thread = true` (idiomatic; Zig bundles
    //                its own libtsan and links it automatically -- verified
    //                via `nm` showing `__tsan_init`/`__tsan_read4`/etc. in
    //                the output binary).
    //   undefined -> `exe_mod.sanitize_c = .full` (idiomatic; Zig bundles its
    //                own `ubsan_rt.zig` the same way).
    //   address   -> Zig 0.15.2 has no bundled ASan runtime at all (no
    //                libclang_rt.asan anywhere under `zig lib`); even a bare
    //                `zig cc -fsanitize=address` on a trivial C file fails to
    //                link with the same class of undefined-symbol errors
    //                (`__asan_init`, `__asan_report_load1`, ...). There is no
    //                idiomatic zig-native mechanism to fall back on, so this
    //                variant shells out to the system `clang` (the same
    //                compiler `Makefile` already hardcodes `CC=clang` to) via
    //                `addSystemCommand`: a full clang invocation is a real
    //                linker driver and auto-links its own compiler-rt ASan
    //                archive, which zig's internal linker does not.
    const san = b.option([]const u8, "san", "none|address|thread|undefined (instruments the C httpserver build)") orelse "none";
    if (!std.mem.eql(u8, san, "none") and !std.mem.eql(u8, san, "address") and
        !std.mem.eql(u8, san, "thread") and !std.mem.eql(u8, san, "undefined"))
    {
        std.debug.panic("-Dsan must be one of none|address|thread|undefined, got '{s}'", .{san});
    }

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
    // Module-level APIs (not the old Compile-level ones): libc comes from
    // .link_libc above; these two survive both zig 0.15 and 0.16-dev, where
    // the Compile-level variants (exe.linkLibC() etc.) were removed.
    exe_mod.linkSystemLibrary("pthread", .{});
    exe_mod.addIncludePath(b.path("lib"));

    // TSan/UBSan: idiomatic Module-level toggles. These make Zig itself
    // instrument the C compile *and* link its bundled runtime -- see the
    // block comment above `san`'s declaration for why this differs from
    // (and replaces) a raw `-fsanitize=...` C flag.
    if (std.mem.eql(u8, san, "thread")) {
        exe_mod.sanitize_thread = true;
    } else if (std.mem.eql(u8, san, "undefined")) {
        exe_mod.sanitize_c = .full;
    }

    var c_flags = std.ArrayList([]const u8).empty;
    c_flags.appendSlice(b.allocator, &.{
        "-Wall",
        "-Wextra",
        "-Werror",
        "-pedantic",
        // Kept in lockstep with the Makefile's CFLAGS so `zig build` and `make`
        // compile the C sources against the same language standard.
        "-std=gnu17",
    }) catch @panic("OOM");
    if (std.mem.eql(u8, san, "thread") or std.mem.eql(u8, san, "undefined")) {
        // Better stack traces in sanitizer reports; the sanitizer itself is
        // already wired via the Module fields above, not a C flag here.
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

    if (std.mem.eql(u8, san, "address")) {
        // See the block comment above `san`'s declaration: Zig has no
        // bundled ASan runtime to link against, so this variant is built by
        // shelling out to the system `clang` directly (a real linker driver
        // that auto-links its own compiler-rt ASan archive) instead of going
        // through `exe`/`exe_mod`. `exe` above is left an ordinary,
        // unsanitized build (still installed/runnable via `zig build run`)
        // so this branch doesn't fight it for the same output path.
        std.fs.cwd().makePath("zig-out/bin") catch |err| {
            std.debug.panic("failed to create zig-out/bin: {t}", .{err});
        };

        var asan_argv = std.ArrayList([]const u8).empty;
        asan_argv.appendSlice(b.allocator, &.{
            "clang",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            "-std=gnu17",
            "-pthread",
            "-Ilib",
            "-fsanitize=address",
            "-fno-omit-frame-pointer",
            "-o",
            "zig-out/bin/httpserver",
        }) catch @panic("OOM");
        asan_argv.appendSlice(b.allocator, sources.items) catch @panic("OOM");

        const asan_cmd = b.addSystemCommand(asan_argv.items);
        b.getInstallStep().dependOn(&asan_cmd.step);

        // `exe` is still an ordinary (unsanitized) build for `zig build run`
        // convenience; it must not also try to install to zig-out/bin/httpserver
        // in this branch (that would race the clang-produced ASan binary for
        // the same path), so it's compiled but not installed here.
        exe_mod.addCSourceFiles(.{
            .files = sources.items,
            .flags = c_flags.items,
        });
    } else {
        exe_mod.addCSourceFiles(.{
            .files = sources.items,
            .flags = c_flags.items,
        });

        b.installArtifact(exe);
    }

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
        // pulling in the C httpserver via the global install step.
        run_runner.addArtifactArg(mock_exe);
    }

    const test_http_step = b.step("test-http", "Run the ztest workload suite against a server binary (default: the mock; pass -- <path> for another)");
    test_http_step.dependOn(&run_runner.step);

    // ---- bench: the nginx semantic differential oracle -------------------
    // `zig build differential -- <workload.toml> <hostA:portA> <hostB:portB>
    // <serve_root>` replays a workload against two servers and diffs their
    // observable HTTP semantics (status + GET body bytes). It IMPORTS ztest's
    // wire.zig + toml.zig read-only (same b.path mechanism the mock uses for
    // wire), so it agrees with the driver/server on the wire format and the
    // workload grammar by construction. bench/differential.sh owns launching
    // ./httpserver + nginx and passing the endpoints; see that script.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/differential.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("wire", b.createModule(.{
        .root_source_file = b.path("ztest/src/wire.zig"),
        .target = target,
        .optimize = optimize,
    }));
    bench_mod.addImport("toml", b.createModule(.{
        .root_source_file = b.path("ztest/src/toml.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const bench_exe = b.addExecutable(.{
        .name = "bench-differential",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("differential", "Replay a workload against two servers and diff HTTP semantics (args: <workload.toml> <hostA:portA> <hostB:portB> <serve_root>)");
    bench_step.dependOn(&run_bench.step);
}
