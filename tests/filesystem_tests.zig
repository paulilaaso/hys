const std = @import("std");
const types = @import("types");
const DailyLimiter = @import("daily_limiter").DailyLimiter;
const FeedGroupManager = @import("feed_group_manager").FeedGroupManager;

// Test suite for filesystem-related operations (DailyLimiter, history, seen hashes)
// Run with: zig build test-filesystem

// ============================================================================
// TEST DAILY LIMITER (using tmpDir for sandboxed testing)
// ============================================================================

const TestLimiter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    seen_ids_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8) !TestLimiter {
        const state_dir = try std.Io.Dir.path.join(allocator, &.{ base_path, "history" });
        const seen_ids_file = try std.Io.Dir.path.join(allocator, &.{ base_path, "seen_ids.bin" });
        std.Io.Dir.cwd().createDirPath(io, state_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return TestLimiter{ .allocator = allocator, .io = io, .state_dir = state_dir, .seen_ids_file = seen_ids_file };
    }

    pub fn deinit(self: TestLimiter) void {
        self.allocator.free(self.state_dir);
        self.allocator.free(self.seen_ids_file);
    }

    pub fn saveToFile(self: TestLimiter, filename: []const u8, items: []const types.RssItem) !void {
        const filepath = try std.Io.Dir.path.join(self.allocator, &.{ self.state_dir, filename });
        defer self.allocator.free(filepath);
        const json = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(types.LastRunState{
            .timestamp = std.Io.Timestamp.now(self.io, .real).toSeconds(), .items = items,
        }, .{ .whitespace = .indent_2 })});
        defer self.allocator.free(json);
        const file = try std.Io.Dir.cwd().createFile(self.io, filepath, .{});
        defer file.close(self.io);
        try file.writePositionalAll(self.io, json, 0);
    }

    pub fn fileExists(self: TestLimiter, filename: []const u8) bool {
        const filepath = std.Io.Dir.path.join(self.allocator, &.{ self.state_dir, filename }) catch return false;
        defer self.allocator.free(filepath);
        std.Io.Dir.cwd().access(self.io, filepath, .{}) catch return false;
        return true;
    }

    pub fn loadSeenHashes(self: TestLimiter) !std.AutoHashMap(u64, void) {
        var hashes = std.AutoHashMap(u64, void).init(self.allocator);
        const file = std.Io.Dir.cwd().openFile(self.io, self.seen_ids_file, .{}) catch |e| switch (e) {
            error.FileNotFound => return hashes,
            else => return e,
        };
        defer file.close(self.io);
        const size = try file.length(self.io);
        if (size == 0 or size % 12 != 0) return hashes;
        const count = size / 12;
        try hashes.ensureTotalCapacity(@intCast(count));
        var buf: [12]u8 = undefined;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const n = try file.readPositional(self.io, &.{&buf}, i * 12);
            if (n < 12) break;
            hashes.putAssumeCapacity(std.mem.readInt(u64, buf[4..12], .little), {});
        }
        return hashes;
    }

    pub fn saveNewHashes(self: TestLimiter, new_hashes: []const u64) !void {
        if (new_hashes.len == 0) return;
        const file = std.Io.Dir.cwd().openFile(self.io, self.seen_ids_file, .{ .mode = .read_write }) catch |e| switch (e) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(self.io, self.seen_ids_file, .{}),
            else => return e,
        };
        defer file.close(self.io);
        const size = try file.length(self.io);
        const ts: u32 = @truncate(@as(u64, @intCast(@max(0, std.Io.Timestamp.now(self.io, .real).toSeconds()))));
        for (new_hashes, 0..) |h, idx| {
            var buf: [12]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], ts, .little);
            std.mem.writeInt(u64, buf[4..12], h, .little);
            try file.writePositionalAll(self.io, &buf, size + idx * 12);
        }
    }
};

test "creates history directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();
    var d = try tmp.dir.openDir(io, "history", .{});
    defer d.close(io);
}

test "saveDay creates file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();
    try lim.saveToFile("test_2024-12-05.json", &.{});
    try std.testing.expect(lim.fileExists("test_2024-12-05.json"));
}

test "hash roundtrip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();
    const h = [_]u64{ 0xDEADBEEF, 0xCAFEBABE };
    try lim.saveNewHashes(&h);
    var loaded = try lim.loadSeenHashes();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 2), loaded.count());
    try std.testing.expect(loaded.contains(0xDEADBEEF));
}

test "empty hashes file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();
    var h = try lim.loadSeenHashes();
    defer h.deinit();
    try std.testing.expectEqual(@as(u32, 0), h.count());
}

test "append hashes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();
    try lim.saveNewHashes(&[_]u64{1});
    try lim.saveNewHashes(&[_]u64{2});
    var h = try lim.loadSeenHashes();
    defer h.deinit();
    try std.testing.expectEqual(@as(u32, 2), h.count());
}

test "pruneSeen rewrites file without crashing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .io = io,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    // Seed the file with an old entry and a newer entry. Pruning should remove the old one
    // and rewrite the file (this used to trigger a double-close panic).
    {
        const file = try std.Io.Dir.cwd().createFile(io, lim.seen_ids_file, .{});
        defer file.close(io);

        const now_i64 = std.Io.Timestamp.now(io, .real).toSeconds();
        const now_u64: u64 = if (now_i64 < 0) 0 else @intCast(now_i64);

        const old_u64 = if (now_u64 > 2 * 24 * 60 * 60) now_u64 - (2 * 24 * 60 * 60) else 0;
        const old_ts: u32 = @truncate(old_u64);
        const new_u64 = @min(now_u64 + 60 * 60, std.math.maxInt(u32));
        const new_ts: u32 = @truncate(new_u64);

        var buf: [24]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], old_ts, .little);
        std.mem.writeInt(u64, buf[4..12], 0x1111, .little);
        std.mem.writeInt(u32, buf[12..16], new_ts, .little);
        std.mem.writeInt(u64, buf[16..24], 0x2222, .little);
        try file.writePositionalAll(io, &buf, 0);
    }

    try limiter.pruneSeen(1);

    const file = try std.Io.Dir.cwd().openFile(io, lim.seen_ids_file, .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(u64, 12), try file.length(io));
    var buf: [12]u8 = undefined;
    const n = try file.readPositional(io, &.{&buf}, 0);
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqual(@as(u64, 0x2222), std.mem.readInt(u64, buf[4..12], .little));
}

test "loadSeenHashes resets corrupted file without crashing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .io = io,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    {
        const file = try std.Io.Dir.cwd().createFile(io, lim.seen_ids_file, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "x", 0);
    }

    var hashes = try limiter.loadSeenHashes();
    defer hashes.deinit();
    try std.testing.expectEqual(@as(u32, 0), hashes.count());

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, lim.seen_ids_file, .{}));
}

test "pruneSeen deletes corrupted file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .io = io,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    {
        const file = try std.Io.Dir.cwd().createFile(io, lim.seen_ids_file, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "corruptdata!x", 0);
    }

    try limiter.pruneSeen(1);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, lim.seen_ids_file, .{}));
}

test "pruneSeen no-op when all entries retained" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .io = io,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    {
        const file = try std.Io.Dir.cwd().createFile(io, lim.seen_ids_file, .{});
        defer file.close(io);

        const now_i64 = std.Io.Timestamp.now(io, .real).toSeconds();
        const now_u64: u64 = if (now_i64 < 0) 0 else @intCast(now_i64);
        const ts: u32 = @intCast(@min(now_u64, std.math.maxInt(u32)));

        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], ts, .little);
        std.mem.writeInt(u64, buf[4..12], 0xAAAA, .little);
        try file.writePositionalAll(io, &buf, 0);
    }

    try limiter.pruneSeen(30);

    const file = try std.Io.Dir.cwd().openFile(io, lim.seen_ids_file, .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(u64, 12), try file.length(io));
    var buf: [12]u8 = undefined;
    const n = try file.readPositional(io, &.{&buf}, 0);
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqual(@as(u64, 0xAAAA), std.mem.readInt(u64, buf[4..12], .little));
}

test "pruneSeen produces empty file when all entries expired" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base_path);
    const lim = try TestLimiter.init(std.testing.allocator, io, base_path);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .io = io,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    {
        const file = try std.Io.Dir.cwd().createFile(io, lim.seen_ids_file, .{});
        defer file.close(io);

        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], 1, .little);
        std.mem.writeInt(u64, buf[4..12], 0xBBBB, .little);
        try file.writePositionalAll(io, &buf, 0);
    }

    try limiter.pruneSeen(1);

    const file = try std.Io.Dir.cwd().openFile(io, lim.seen_ids_file, .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(u64, 0), try file.length(io));
}

