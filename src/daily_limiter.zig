const std = @import("std");
const zdt = @import("zdt");
const types = @import("types");
const RssReader = @import("rss_reader").RssReader;

pub const DailyLimiter = struct {
    const entry_size: usize = 12;

    allocator: std.mem.Allocator,
    io: std.Io,
    state_dir: []u8,
    seen_ids_file: []u8,
    group_name: []const u8,
    day_start_hour: u8,
    fetch_interval_days: u32,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, group_name: []const u8, day_start_hour: u8, fetch_interval_days: u32) !DailyLimiter {
        const base_dir = try std.Io.Dir.path.join(allocator, &.{ home_dir, ".hys" });
        defer allocator.free(base_dir);

        const state_dir = try std.Io.Dir.path.join(allocator, &.{ base_dir, "history" });
        const seen_ids_file = try std.Io.Dir.path.join(allocator, &.{ base_dir, "seen_ids.bin" });

        std.Io.Dir.cwd().createDirPath(io, state_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return DailyLimiter{
            .allocator = allocator,
            .io = io,
            .state_dir = state_dir,
            .seen_ids_file = seen_ids_file,
            .group_name = group_name,
            .day_start_hour = day_start_hour,
            .fetch_interval_days = fetch_interval_days,
        };
    }

    pub fn deinit(self: DailyLimiter) void {
        self.allocator.free(self.state_dir);
        self.allocator.free(self.seen_ids_file);
    }

    /// Load history based on chronological fetch order (0 = latest, -1 = previous run, etc.)
    /// All strings in the returned LastRunState are allocated via arena_allocator.
    pub fn loadRunByOffset(self: DailyLimiter, arena_allocator: std.mem.Allocator, offset: i32) !types.LastRunState {
        var history_dir = std.Io.Dir.cwd().openDir(self.io, self.state_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return types.LastRunState{},
            else => return err,
        };
        defer history_dir.close(self.io);

        var file_list = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (file_list.items) |name| self.allocator.free(name);
            file_list.deinit();
        }

        const group_prefix = try std.fmt.allocPrint(self.allocator, "{s}_", .{self.group_name});
        defer self.allocator.free(group_prefix);

        var iterator = history_dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (std.mem.startsWith(u8, entry.name, group_prefix)) {
                    if (entry.name.len > group_prefix.len and std.ascii.isDigit(entry.name[group_prefix.len])) {
                        try file_list.append(try self.allocator.dupe(u8, entry.name));
                    }
                }
            }
        }

        std.mem.sort([]u8, file_list.items, {}, struct {
            fn greaterThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .gt;
            }
        }.greaterThan);

        const target_index: usize = @abs(offset);

        if (target_index >= file_list.items.len) {
            return types.LastRunState{};
        }

        const target_file = file_list.items[target_index];

        const date_start = group_prefix.len;
        const date_end = target_file.len - 5;
        const file_date = if (date_end > date_start)
            try arena_allocator.dupe(u8, target_file[date_start..date_end])
        else
            null;

        var state = try self.loadStateFromDir(arena_allocator, history_dir, target_file);
        state.file_date = file_date;
        return state;
    }

    fn loadState(self: DailyLimiter, arena_allocator: std.mem.Allocator) !types.LastRunState {
        const filename = try self.getStateFilePath();
        defer self.allocator.free(filename);
        return try self.loadStateFromFile(arena_allocator, filename);
    }

    /// Parse a state file, allocating all strings into arena_allocator.
    fn parseStateFile(self: DailyLimiter, arena_allocator: std.mem.Allocator, contents: []const u8) !types.LastRunState {
        if (contents.len == 0) return types.LastRunState{};

        const RawRssItem = struct {
            title: ?[]const u8 = null,
            description: ?[]const u8 = null,
            link: ?[]const u8 = null,
            pubDate: ?[]const u8 = null,
            guid: ?[]const u8 = null,
            feedName: ?[]const u8 = null,
        };

        const RawLastRunState = struct {
            timestamp: ?i64 = null,
            items: ?[]RawRssItem = null,
        };

        // Temporary arena for JSON parsing
        var json_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer json_arena.deinit();

        const parsed = std.json.parseFromSlice(RawLastRunState, json_arena.allocator(), contents, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.debug.print("Error parsing history file: {}\n", .{err});
            return types.LastRunState{};
        };
        defer parsed.deinit();

        // Convert raw items to typed RssItems, allocating strings into arena_allocator
        var items_temp = std.array_list.Managed(types.RssItem).init(self.allocator);
        defer items_temp.deinit();

        if (parsed.value.items) |raw_items| {
            try items_temp.ensureTotalCapacity(raw_items.len);
            for (raw_items) |raw_item| {
                const title = if (raw_item.title) |t| try arena_allocator.dupe(u8, t) else null;
                const description = if (raw_item.description) |d| try arena_allocator.dupe(u8, d) else null;
                const link = if (raw_item.link) |l| try arena_allocator.dupe(u8, l) else null;
                const pubDate = if (raw_item.pubDate) |p| try arena_allocator.dupe(u8, p) else null;
                const guid = if (raw_item.guid) |g| try arena_allocator.dupe(u8, g) else null;
                const feedName = if (raw_item.feedName) |f| try arena_allocator.dupe(u8, f) else null;

                const timestamp = if (pubDate) |pd| RssReader.parseDateString(pd) catch blk: {
                    break :blk @as(i64, @intCast(std.Io.Timestamp.now(self.io, .real).toSeconds()));
                } else 0;

                items_temp.appendAssumeCapacity(types.RssItem{
                    .title = title,
                    .description = description,
                    .link = link,
                    .pubDate = pubDate,
                    .timestamp = timestamp,
                    .guid = guid,
                    .feedName = feedName,
                });
            }
        }

        // Allocate final items array in arena so it lives past items_temp.deinit
        const items_result = try arena_allocator.alloc(types.RssItem, items_temp.items.len);
        for (items_temp.items, 0..) |item, i| {
            items_result[i] = item;
        }

        return types.LastRunState{
            .timestamp = parsed.value.timestamp,
            .items = items_result,
        };
    }

    fn loadStateFromFile(self: DailyLimiter, arena_allocator: std.mem.Allocator, filename: []const u8) !types.LastRunState {
        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, filename, self.allocator, .limited(1024 * 1024 * 10)) catch |err| switch (err) {
            error.FileNotFound => return types.LastRunState{},
            else => return err,
        };
        defer self.allocator.free(contents);

        return try self.parseStateFile(arena_allocator, contents);
    }

    fn loadStateFromDir(self: DailyLimiter, arena_allocator: std.mem.Allocator, dir: std.Io.Dir, filename: []const u8) !types.LastRunState {
        const contents = dir.readFileAlloc(self.io, filename, self.allocator, .limited(1024 * 1024 * 10)) catch |err| switch (err) {
            error.FileNotFound => return types.LastRunState{},
            else => return err,
        };
        defer self.allocator.free(contents);

        return try self.parseStateFile(arena_allocator, contents);
    }

    pub fn saveDay(self: DailyLimiter, items: []const types.RssItem) !void {
        const timestamp = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const filename = try self.getStateFilePath();
        defer self.allocator.free(filename);

        var atomic_file = try std.Io.Dir.cwd().createFileAtomic(self.io, filename, .{ .make_path = true, .replace = true });
        defer atomic_file.deinit(self.io);
        var json_buf: [4096]u8 = undefined;
        var json_writer = atomic_file.file.writer(self.io, &json_buf);
        try json_writer.interface.print("{f}", .{std.json.fmt(types.LastRunState{
            .timestamp = timestamp,
            .items = items,
        }, .{ .whitespace = .indent_2 })});
        try json_writer.flush();
        try atomic_file.replace(self.io);
    }

    fn formatCurrentLocalDate(self: DailyLimiter, buf: *[32]u8) ![]u8 {
        var local_tz = try zdt.Timezone.tzLocal(self.io, self.allocator);
        defer local_tz.deinit();
        var now = try zdt.Datetime.now(self.io, .{ .tz = &local_tz });

        if (self.day_start_hour > 0) {
            const hour_offset: i64 = -@as(i64, @intCast(self.day_start_hour));
            const duration = zdt.Duration.fromTimespanMultiple(hour_offset, .hour);
            now = try now.add(duration);
        }

        const result = try std.fmt.bufPrint(
            buf,
            "{d:0>4}-{d:0>2}-{d:0>2}",
            .{ @abs(now.year), @as(u5, @intCast(now.month)), @as(u5, @intCast(now.day)) },
        );
        return result;
    }

    fn getStateFilePath(self: DailyLimiter) ![]u8 {
        var date_buf: [32]u8 = undefined;
        const date_str = try self.formatCurrentLocalDate(&date_buf);

        var filename_buf: [256]u8 = undefined;
        const filename_only = try std.fmt.bufPrint(&filename_buf, "{s}_{s}.json", .{ self.group_name, date_str });

        return try std.Io.Dir.path.join(self.allocator, &.{ self.state_dir, filename_only });
    }

    pub fn reset(self: DailyLimiter) !void {
        const filename = try self.getStateFilePath();
        defer self.allocator.free(filename);

        std.Io.Dir.cwd().deleteFile(self.io, filename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    pub fn isWithinFetchInterval(self: DailyLimiter) !bool {
        if (self.fetch_interval_days == 0) return false;

        const latest_file = (try self.getLatestHistoryFileName()) orelse return false;
        defer self.allocator.free(latest_file);

        const group_prefix_len = self.group_name.len + 1;
        if (latest_file.len < group_prefix_len + 10) return false;

        const date_str = latest_file[group_prefix_len .. group_prefix_len + 10];

        const ly = try std.fmt.parseInt(i32, date_str[0..4], 10);
        const lm = try std.fmt.parseInt(i32, date_str[5..7], 10);
        const ld = try std.fmt.parseInt(i32, date_str[8..10], 10);
        const latest_rd = dateToRataDie(ly, lm, ld);

        var current_buf: [32]u8 = undefined;
        const current_date_str = try self.formatCurrentLocalDate(&current_buf);
        const cy = try std.fmt.parseInt(i32, current_date_str[0..4], 10);
        const cm = try std.fmt.parseInt(i32, current_date_str[5..7], 10);
        const cd = try std.fmt.parseInt(i32, current_date_str[8..10], 10);
        const current_rd = dateToRataDie(cy, cm, cd);

        const diff = current_rd - latest_rd;
        return diff < self.fetch_interval_days;
    }

    /// Load the latest run for this group.
    /// All strings in the returned LastRunState are allocated via arena_allocator.
    pub fn loadLatestRun(self: DailyLimiter, arena_allocator: std.mem.Allocator) !types.LastRunState {
        const latest_file = (try self.getLatestHistoryFileName()) orelse return error.FileNotFound;
        defer self.allocator.free(latest_file);

        const full_path = try std.Io.Dir.path.join(self.allocator, &.{ self.state_dir, latest_file });
        defer self.allocator.free(full_path);

        return try self.loadStateFromFile(arena_allocator, full_path);
    }

    fn getLatestHistoryFileName(self: DailyLimiter) !?[]u8 {
        var history_dir = std.Io.Dir.cwd().openDir(self.io, self.state_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer history_dir.close(self.io);

        const group_prefix = try std.fmt.allocPrint(self.allocator, "{s}_", .{self.group_name});
        defer self.allocator.free(group_prefix);

        var latest_filename: ?[]u8 = null;

        var iterator = history_dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (std.mem.startsWith(u8, entry.name, group_prefix)) {
                    if (entry.name.len > group_prefix.len and std.ascii.isDigit(entry.name[group_prefix.len])) {
                        if (latest_filename) |existing| {
                            if (std.mem.order(u8, entry.name, existing) == .gt) {
                                self.allocator.free(existing);
                                latest_filename = try self.allocator.dupe(u8, entry.name);
                            }
                        } else {
                            latest_filename = try self.allocator.dupe(u8, entry.name);
                        }
                    }
                }
            }
        }
        return latest_filename;
    }

    fn dateToRataDie(year: i32, month: i32, day: i32) i32 {
        var y = year;
        var m = month;
        if (m < 3) {
            y -= 1;
            m += 12;
        }
        return 365 * y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + @divFloor(153 * m - 457, 5) + day - 306;
    }

    pub fn daysAgoFromDateString(self: DailyLimiter, date_str: []const u8) !i32 {
        if (date_str.len < 10) return error.InvalidDateFormat;

        const file_year = try std.fmt.parseInt(i32, date_str[0..4], 10);
        const file_month = try std.fmt.parseInt(i32, date_str[5..7], 10);
        const file_day = try std.fmt.parseInt(i32, date_str[8..10], 10);
        const file_rd = dateToRataDie(file_year, file_month, file_day);

        var current_buf: [32]u8 = undefined;
        const current_date_str = try self.formatCurrentLocalDate(&current_buf);
        const cy = try std.fmt.parseInt(i32, current_date_str[0..4], 10);
        const cm = try std.fmt.parseInt(i32, current_date_str[5..7], 10);
        const cd = try std.fmt.parseInt(i32, current_date_str[8..10], 10);
        const current_rd = dateToRataDie(cy, cm, cd);

        return current_rd - file_rd;
    }

    pub fn loadSeenHashes(self: DailyLimiter) !std.AutoHashMap(u64, void) {
        var seen_hashes = std.AutoHashMap(u64, void).init(self.allocator);

        var file_size: u64 = 0;
        var entry_count: u64 = 0;
        const is_corrupted = blk: {
            const file = std.Io.Dir.cwd().openFile(self.io, self.seen_ids_file, .{}) catch |err| switch (err) {
                error.FileNotFound => return seen_hashes,
                else => return err,
            };
            defer file.close(self.io);

            file_size = try file.length(self.io);
            if (file_size == 0) return seen_hashes;

            entry_count = file_size / entry_size;
            if (file_size % entry_size != 0) {
                std.log.warn("Deduplication file corrupted. Resetting.", .{});
                break :blk true;
            }

            try seen_hashes.ensureTotalCapacity(@intCast(entry_count));

            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                var entry_bytes: [entry_size]u8 = undefined;
                const bytes_read = try file.readPositionalAll(self.io, &entry_bytes, i * entry_size);
                if (bytes_read < entry_size) return error.UnexpectedEof;

                const hash = std.mem.readInt(u64, entry_bytes[4..12], .little);
                seen_hashes.putAssumeCapacity(hash, {});
            }

            break :blk false;
        };

        if (is_corrupted) {
            std.Io.Dir.cwd().deleteFile(self.io, self.seen_ids_file) catch {};
        }

        return seen_hashes;
    }

    pub fn saveNewHashes(self: DailyLimiter, new_hashes: []const u64) !void {
        if (new_hashes.len == 0) return;

        const file = std.Io.Dir.cwd().openFile(self.io, self.seen_ids_file, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(self.io, self.seen_ids_file, .{}),
            else => return err,
        };
        defer file.close(self.io);

        const ts_i64 = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const ts_u64: u64 = if (ts_i64 < 0) 0 else @intCast(ts_i64);
        const now_timestamp = @as(u32, @min(ts_u64, std.math.maxInt(u32)));

        var offset = try file.length(self.io);
        for (new_hashes) |hash| {
            var entry_bytes: [12]u8 = undefined;
            std.mem.writeInt(u32, entry_bytes[0..4], now_timestamp, .little);
            std.mem.writeInt(u64, entry_bytes[4..12], hash, .little);
            try file.writePositionalAll(self.io, &entry_bytes, offset);
            offset += 12;
        }
    }

    pub fn pruneHistory(self: DailyLimiter, retention_days: u32) !void {
        var history_dir = std.Io.Dir.cwd().openDir(self.io, self.state_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer history_dir.close(self.io);

        var file_list = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (file_list.items) |filename| {
                self.allocator.free(filename);
            }
            file_list.deinit();
        }

        const group_prefix = try std.fmt.allocPrint(self.allocator, "{s}_", .{self.group_name});
        defer self.allocator.free(group_prefix);

        var iterator = history_dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (std.mem.startsWith(u8, entry.name, group_prefix)) {
                    if (entry.name.len > group_prefix.len and std.ascii.isDigit(entry.name[group_prefix.len])) {
                        const filename = try self.allocator.dupe(u8, entry.name);
                        try file_list.append(filename);
                    }
                }
            }
        }

        var local_tz = try zdt.Timezone.tzLocal(self.io, self.allocator);
        defer local_tz.deinit();
        var now = try zdt.Datetime.now(self.io, .{ .tz = &local_tz });

        if (self.day_start_hour > 0) {
            const hour_offset: i64 = -@as(i64, @intCast(self.day_start_hour));
            const duration = zdt.Duration.fromTimespanMultiple(hour_offset, .hour);
            now = try now.add(duration);
        }

        const day_duration = zdt.Duration.fromTimespanMultiple(-@as(i64, @intCast(retention_days)), .day);
        const cutoff = try now.add(day_duration);
        var cutoff_date_buf: [32]u8 = undefined;
        const cutoff_date_str = try std.fmt.bufPrint(
            &cutoff_date_buf,
            "{d:0>4}-{d:0>2}-{d:0>2}",
            .{ @abs(cutoff.year), @as(u5, @intCast(cutoff.month)), @as(u5, @intCast(cutoff.day)) },
        );

        for (file_list.items) |filename| {
            if (filename.len > group_prefix.len + 10) {
                const date_start = group_prefix.len;
                const date_end = date_start + 10;
                const file_date = filename[date_start..date_end];

                if (std.mem.order(u8, file_date, cutoff_date_str) == .lt) {
                    _ = history_dir.deleteFile(self.io, filename) catch {};
                }
            }
        }
    }

    pub fn pruneSeen(self: DailyLimiter, retention_days: u32) !void {
        var valid_entries = std.array_list.Managed([entry_size]u8).init(self.allocator);
        defer valid_entries.deinit();

        var should_rewrite = false;
        const read_result = blk: {
            const file = std.Io.Dir.cwd().openFile(self.io, self.seen_ids_file, .{}) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
            defer file.close(self.io);

            const file_size = try file.length(self.io);
            if (file_size == 0) return;

            const entry_count = file_size / entry_size;
            if (file_size % entry_size != 0) {
                break :blk true;
            }

            const ts_i64 = std.Io.Timestamp.now(self.io, .real).toSeconds();
            const now_u64: u64 = if (ts_i64 < 0) 0 else @intCast(ts_i64);
            const retention_seconds = @as(u64, retention_days) * 24 * 60 * 60;
            const cutoff_u64 = if (now_u64 > retention_seconds) now_u64 - retention_seconds else 0;
            const cutoff_timestamp: u32 = @intCast(@min(cutoff_u64, std.math.maxInt(u32)));

            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                var entry_bytes: [entry_size]u8 = undefined;
                const bytes_read = try file.readPositionalAll(self.io, &entry_bytes, i * entry_size);
                if (bytes_read < entry_size) return error.UnexpectedEof;

                const timestamp = std.mem.readInt(u32, entry_bytes[0..4], .little);

                if (timestamp >= cutoff_timestamp) {
                    try valid_entries.append(entry_bytes);
                }
            }

            if (valid_entries.items.len == entry_count) {
                return;
            }

            should_rewrite = true;
            break :blk false;
        };

        if (read_result) {
            std.Io.Dir.cwd().deleteFile(self.io, self.seen_ids_file) catch {};
            return;
        }

        if (should_rewrite) {
            var atomic_file = try std.Io.Dir.cwd().createFileAtomic(self.io, self.seen_ids_file, .{ .replace = true });
            defer atomic_file.deinit(self.io);

            for (valid_entries.items) |entry_val| {
                try atomic_file.file.writeStreamingAll(self.io, &entry_val);
            }

            try atomic_file.replace(self.io);
        }
    }
};
