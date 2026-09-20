const std = @import("std");

const vendored = [_]struct { path: []const u8, sha256: []const u8 }{
    .{ .path = "vendor/sqlite3/sqlite3.c", .sha256 = "dc58f0b5b74e8416cc29b49163a00d6b8bf08a24dd4127652beaaae307bd1839" },
    .{ .path = "vendor/sqlite3/sqlite3.h", .sha256 = "05c48cbf0a0d7bda2b6d0145ac4f2d3a5e9e1cb98b5d4fa9d88ef620e1940046" },
    .{ .path = "vendor/sqlite3/sqlite3ext.h", .sha256 = "ea81fb7bd05882e0e0b92c4d60f677b205f7f1fbf085f218b12f0b5b3f0b9e48" },
    .{ .path = "vendor/anydoc/anydoc", .sha256 = "610013d93cda03f4a51cba78eb951a990a00b9dfab1a6ca2a5a3beda67a4b81a" },
};

/// Compile-time trim of SQLite: each flag removes code we never call.
const sqlite_flags = [_][]const u8{
    "-std=c99",
    "-DSQLITE_ENABLE_FTS5=1", // full-text search + bm25()
    "-DSQLITE_DQS=0", // no double-quoted string literals
    "-DSQLITE_THREADSAFE=1", // safe across worker threads
    "-DSQLITE_DEFAULT_MEMSTATUS=0", // skip malloc bookkeeping
    "-DSQLITE_OMIT_LOAD_EXTENSION=1", // no runtime extension loading
    "-DSQLITE_OMIT_DEPRECATED=1",
    "-DSQLITE_OMIT_SHARED_CACHE=1",
    "-DSQLITE_OMIT_AUTOINIT=1", // db.zig calls sqlite3_initialize()
    "-DSQLITE_USE_ALLOCA=1",
};

pub fn build(builder: *std.Build) void {
    verifyVendored(builder) catch std.process.exit(1);

    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    // Zig 0.16 deprecates @cImport; C is translated in the build graph.
    const translate = builder.addTranslateC(.{
        .root_source_file = builder.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(builder.path("vendor/sqlite3"));
    const c_mod = translate.createModule();

    const exe = builder.addExecutable(.{
        .name = "zoro",
        .root_module = rootModule(builder, target, optimize, c_mod),
    });
    if (optimize != .Debug) {
        exe.root_module.strip = true;
        exe.root_module.unwind_tables = .none;
    }
    builder.installArtifact(exe);
    builder.installBinFile("vendor/anydoc/anydoc", "anydoc");

    const run = builder.addRunArtifact(exe);
    if (builder.args) |args| run.addArgs(args);
    builder.step("run", "Run zoro").dependOn(&run.step);

    const tests = builder.addTest(.{ .root_module = rootModule(builder, target, optimize, c_mod) });
    builder.step("test", "Run tests").dependOn(&builder.addRunArtifact(tests).step);
}

fn rootModule(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_mod: *std.Build.Module,
) *std.Build.Module {
    const module = builder.createModule(.{
        .root_source_file = builder.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_mod }},
    });
    module.addCSourceFile(.{ .file = builder.path("vendor/sqlite3/sqlite3.c"), .flags = &sqlite_flags });
    module.addIncludePath(builder.path("vendor/sqlite3"));
    return module;
}

fn verifyVendored(builder: *std.Build) !void {
    const max_bytes = 16 * 1024 * 1024;
    for (vendored) |file| {
        const path = builder.pathFromRoot(file.path);
        defer builder.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(builder.graph.io, path, builder.allocator, .limited(max_bytes)) catch |err| {
            std.log.err("cannot read {s}: {t}", .{ file.path, err });
            return err;
        };
        defer builder.allocator.free(bytes);

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);

        if (!std.mem.eql(u8, &hex, file.sha256)) {
            std.log.err("checksum mismatch: {s}", .{file.path});
            std.log.err("  expected {s}", .{file.sha256});
            std.log.err("  actual   {s}", .{hex});
            return error.VendoredChecksumMismatch;
        }
    }
}
