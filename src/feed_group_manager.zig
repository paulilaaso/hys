const std = @import("std");
const types = @import("types");
const rss_reader = @import("rss_reader");

/// FeedGroupManager handles loading, saving, and managing feed groups.
pub const FeedGroupManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    feeds_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8) !FeedGroupManager {
        const feeds_dir = try std.Io.Dir.path.join(allocator, &.{ base_dir, "feeds" });

        var manager = FeedGroupManager{
            .allocator = allocator,
            .io = io,
            .feeds_dir = feeds_dir,
        };

        try manager.ensureFeedsDir();
        return manager;
    }

    pub fn deinit(self: FeedGroupManager) void {
        self.allocator.free(self.feeds_dir);
    }

    fn ensureFeedsDir(self: FeedGroupManager) !void {
        std.Io.Dir.cwd().createDirPath(self.io, self.feeds_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    /// Load a complete feed group with metadata into the given arena allocator.
    /// All strings in the returned FeedGroup are allocated via arena_allocator.
    pub fn loadGroupWithMetadata(self: FeedGroupManager, arena_allocator: std.mem.Allocator, group_name: []const u8) !types.FeedGroup {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{group_name});
        defer self.allocator.free(filename);

        const file_path = try std.Io.Dir.path.join(self.allocator, &.{ self.feeds_dir, filename });
        defer self.allocator.free(file_path);

        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(1024 * 1024 * 10)) catch |err| switch (err) {
            error.FileNotFound => {
                return types.FeedGroup{
                    .name = try arena_allocator.dupe(u8, group_name),
                    .display_name = null,
                    .feeds = &.{},
                };
            },
            else => return err,
        };
        defer self.allocator.free(contents);

        return self.parseGroupWithMetadata(arena_allocator, group_name, contents);
    }

    /// Update the display name of a group
    pub fn setGroupDisplayName(self: FeedGroupManager, group_name: []const u8, display_name: ?[]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var group = try self.loadGroupWithMetadata(arena.allocator(), group_name);
        group.display_name = if (display_name) |name| try arena.allocator().dupe(u8, name) else null;

        try self.saveGroupWithMetadata(group);
    }

    /// Get the display name of a group
    pub fn getGroupDisplayName(self: FeedGroupManager, group_name: []const u8) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const group = try self.loadGroupWithMetadata(arena.allocator(), group_name);

        return if (group.display_name) |name| try self.allocator.dupe(u8, name) else null;
    }

    /// Save a complete feed group with metadata
    pub fn saveGroupWithMetadata(self: FeedGroupManager, group: types.FeedGroup) !void {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{group.name});
        defer self.allocator.free(filename);

        const file_path = try std.Io.Dir.path.join(self.allocator, &.{ self.feeds_dir, filename });
        defer self.allocator.free(file_path);

        const GroupData = struct {
            text: ?[]const u8,
            feeds: []const types.FeedConfig,
        };

        const group_data = GroupData{
            .text = group.display_name,
            .feeds = group.feeds,
        };

        var atomic_file = try std.Io.Dir.cwd().createFileAtomic(self.io, file_path, .{ .make_path = true, .replace = true });
        defer atomic_file.deinit(self.io);
        var json_buf: [4096]u8 = undefined;
        var json_writer = atomic_file.file.writer(self.io, &json_buf);
        try json_writer.interface.print("{f}", .{std.json.fmt(group_data, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        })});
        try json_writer.flush();
        try atomic_file.replace(self.io);
    }

    /// Save updated ETags/Last-Modified headers for a group after fetching.
    pub fn saveUpdatedHeaders(
        self: FeedGroupManager,
        group_name: []const u8,
        fetched_feeds: []const types.FeedConfig,
        fetched_feed_group_names: []const []const u8,
    ) !void {
        var has_fetched = false;
        for (fetched_feed_group_names) |fgn| {
            if (std.mem.eql(u8, fgn, group_name)) {
                has_fetched = true;
                break;
            }
        }
        if (!has_fetched) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const group = try self.loadGroupWithMetadata(arena.allocator(), group_name);

        for (group.feeds) |*feed| {
            if (!feed.enabled) continue;

            for (fetched_feeds, 0..) |fetched_feed, idx| {
                if (std.mem.eql(u8, fetched_feed_group_names[idx], group_name) and
                    std.mem.eql(u8, fetched_feed.xmlUrl, feed.xmlUrl))
                {
                    if (fetched_feed.etag) |new_etag| {
                        feed.etag = try arena.allocator().dupe(u8, new_etag);
                    }
                    if (fetched_feed.lastModified) |new_lm| {
                        feed.lastModified = try arena.allocator().dupe(u8, new_lm);
                    }
                    break;
                }
            }
        }

        try self.saveGroupWithMetadata(group);
    }

    /// Check if a group exists
    pub fn groupExists(self: FeedGroupManager, group_name: []const u8) bool {
        const filename = std.fmt.allocPrint(self.allocator, "{s}.json", .{group_name}) catch return false;
        defer self.allocator.free(filename);

        const file_path = std.Io.Dir.path.join(self.allocator, &.{ self.feeds_dir, filename }) catch return false;
        defer self.allocator.free(file_path);

        std.Io.Dir.cwd().access(self.io, file_path, .{}) catch return false;
        return true;
    }

    /// Add a feed to a specific group
    pub fn addFeedToGroup(self: FeedGroupManager, group_name: []const u8, url: []const u8, name: ?[]const u8) !void {
        try rss_reader.validateFeedUrl(url);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const group = try self.loadGroupWithMetadata(arena.allocator(), group_name);

        for (group.feeds) |feed| {
            if (std.mem.eql(u8, feed.xmlUrl, url)) {
                return error.FeedAlreadyExists;
            }
        }

        const sanitized_url = try rss_reader.RssReader.sanitizeFeedData(url, arena.allocator());
        var sanitized_name: ?[]const u8 = null;
        if (name) |n| {
            sanitized_name = try rss_reader.RssReader.sanitizeFeedData(n, arena.allocator());
        }

        var feeds_list = try arena.allocator().alloc(types.FeedConfig, group.feeds.len + 1);
        for (group.feeds, 0..) |f, i| {
            feeds_list[i] = f;
        }
        feeds_list[group.feeds.len] = types.FeedConfig{
            .xmlUrl = sanitized_url,
            .text = sanitized_name,
            .enabled = true,
        };

        const updated_group = types.FeedGroup{
            .name = group.name,
            .display_name = group.display_name,
            .feeds = feeds_list,
        };

        try self.saveGroupWithMetadata(updated_group);
    }

    /// Add a feed config (with all metadata) to a specific group
    pub fn addFeedConfigToGroup(self: FeedGroupManager, group_name: []const u8, feed_config: types.FeedConfig) !void {
        try rss_reader.validateFeedUrl(feed_config.xmlUrl);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const group = try self.loadGroupWithMetadata(arena.allocator(), group_name);

        for (group.feeds) |feed| {
            if (std.mem.eql(u8, feed.xmlUrl, feed_config.xmlUrl)) {
                return error.FeedAlreadyExists;
            }
        }

        const arena_allocator = arena.allocator();
        const xmlUrl = try arena_allocator.dupe(u8, feed_config.xmlUrl);
        const text = if (feed_config.text) |t| try arena_allocator.dupe(u8, t) else null;
        const title = if (feed_config.title) |t| try arena_allocator.dupe(u8, t) else null;
        const htmlUrl = if (feed_config.htmlUrl) |h| try arena_allocator.dupe(u8, h) else null;
        const description = if (feed_config.description) |d| try arena_allocator.dupe(u8, d) else null;
        const language = if (feed_config.language) |l| try arena_allocator.dupe(u8, l) else null;
        const version = if (feed_config.version) |v| try arena_allocator.dupe(u8, v) else null;
        const etag = if (feed_config.etag) |e| try arena_allocator.dupe(u8, e) else null;
        const lastModified = if (feed_config.lastModified) |lm| try arena_allocator.dupe(u8, lm) else null;

        var feeds_list = try arena_allocator.alloc(types.FeedConfig, group.feeds.len + 1);
        for (group.feeds, 0..) |f, i| {
            feeds_list[i] = f;
        }
        feeds_list[group.feeds.len] = types.FeedConfig{
            .xmlUrl = xmlUrl,
            .text = text,
            .enabled = feed_config.enabled,
            .title = title,
            .htmlUrl = htmlUrl,
            .description = description,
            .language = language,
            .version = version,
            .etag = etag,
            .lastModified = lastModified,
        };

        const updated_group = types.FeedGroup{
            .name = group.name,
            .display_name = group.display_name,
            .feeds = feeds_list,
        };

        try self.saveGroupWithMetadata(updated_group);
    }

    /// Get enabled feeds from a specific group, allocating feed data into arena_allocator.
    pub fn getEnabledFeeds(self: FeedGroupManager, arena_allocator: std.mem.Allocator, group_name: []const u8) !types.FeedList {
        const group = try self.loadGroupWithMetadata(arena_allocator, group_name);

        return try types.filterEnabledFeeds(self.allocator, types.FeedList{
            .items = group.feeds,
            .capacity = group.feeds.len,
        });
    }

    /// Get a list of all available group names by scanning the feeds directory
    pub fn getAllGroupNames(self: FeedGroupManager) ![]const []const u8 {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.feeds_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &[_][]const u8{},
            else => return err,
        };
        defer dir.close(self.io);

        var groups = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer {
            for (groups.items) |name| self.allocator.free(name);
            groups.deinit();
        }

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (std.mem.startsWith(u8, entry.name, ".")) continue;

                const name_len = entry.name.len - 5;
                const group_name = try self.allocator.dupe(u8, entry.name[0..name_len]);
                try groups.append(group_name);
            }
        }

        std.mem.sort([]const u8, groups.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);

        return groups.toOwnedSlice();
    }

    fn parseGroupWithMetadata(self: FeedGroupManager, arena_allocator: std.mem.Allocator, group_name: []const u8, contents: []const u8) !types.FeedGroup {
        const GroupData = struct {
            text: ?[]const u8 = null,
            feeds: []const struct {
                xmlUrl: []const u8,
                text: ?[]const u8 = null,
                enabled: bool = true,
                title: ?[]const u8 = null,
                htmlUrl: ?[]const u8 = null,
                description: ?[]const u8 = null,
                language: ?[]const u8 = null,
                version: ?[]const u8 = null,
                etag: ?[]const u8 = null,
                lastModified: ?[]const u8 = null,
            },
        };

        // Temporary arena for JSON parsing
        var json_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer json_arena.deinit();

        const parsed = std.json.parseFromSliceLeaky(GroupData, json_arena.allocator(), contents, .{
            .ignore_unknown_fields = true,
        }) catch {
            return self.parseLegacyFeedArray(arena_allocator, group_name, contents);
        };

        // Allocate FeedConfigs in the long-lived arena_allocator — no errdefers needed
        var feeds = try arena_allocator.alloc(types.FeedConfig, parsed.feeds.len);

        for (parsed.feeds, 0..) |raw_feed, i| {
            feeds[i] = types.FeedConfig{
                .xmlUrl = try arena_allocator.dupe(u8, raw_feed.xmlUrl),
                .text = if (raw_feed.text) |t| try arena_allocator.dupe(u8, t) else null,
                .enabled = raw_feed.enabled,
                .title = if (raw_feed.title) |t| try arena_allocator.dupe(u8, t) else null,
                .htmlUrl = if (raw_feed.htmlUrl) |h| try arena_allocator.dupe(u8, h) else null,
                .description = if (raw_feed.description) |d| try arena_allocator.dupe(u8, d) else null,
                .language = if (raw_feed.language) |l| try arena_allocator.dupe(u8, l) else null,
                .version = if (raw_feed.version) |v| try arena_allocator.dupe(u8, v) else null,
                .etag = if (raw_feed.etag) |e| try arena_allocator.dupe(u8, e) else null,
                .lastModified = if (raw_feed.lastModified) |lm| try arena_allocator.dupe(u8, lm) else null,
            };
        }

        return types.FeedGroup{
            .name = try arena_allocator.dupe(u8, group_name),
            .display_name = if (parsed.text) |t| try arena_allocator.dupe(u8, t) else null,
            .feeds = feeds,
        };
    }

    /// Parse legacy array format [{ xmlUrl, text, ... }] and convert to FeedGroup
    fn parseLegacyFeedArray(self: FeedGroupManager, arena_allocator: std.mem.Allocator, group_name: []const u8, contents: []const u8) !types.FeedGroup {
        const RawFeedConfig = struct {
            xmlUrl: []const u8,
            text: ?[]const u8 = null,
            enabled: bool = true,
            title: ?[]const u8 = null,
            htmlUrl: ?[]const u8 = null,
            description: ?[]const u8 = null,
            language: ?[]const u8 = null,
            version: ?[]const u8 = null,
            etag: ?[]const u8 = null,
            lastModified: ?[]const u8 = null,
        };

        // Temporary arena for JSON parsing
        var json_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer json_arena.deinit();

        const parsed = std.json.parseFromSliceLeaky([]RawFeedConfig, json_arena.allocator(), contents, .{
            .ignore_unknown_fields = true,
        }) catch {
            return error.ParseFailed;
        };

        var feeds = try arena_allocator.alloc(types.FeedConfig, parsed.len);

        for (parsed, 0..) |raw_feed, i| {
            feeds[i] = types.FeedConfig{
                .xmlUrl = try arena_allocator.dupe(u8, raw_feed.xmlUrl),
                .text = if (raw_feed.text) |t| try arena_allocator.dupe(u8, t) else null,
                .enabled = raw_feed.enabled,
                .title = if (raw_feed.title) |t| try arena_allocator.dupe(u8, t) else null,
                .htmlUrl = if (raw_feed.htmlUrl) |h| try arena_allocator.dupe(u8, h) else null,
                .description = if (raw_feed.description) |d| try arena_allocator.dupe(u8, d) else null,
                .language = if (raw_feed.language) |l| try arena_allocator.dupe(u8, l) else null,
                .version = if (raw_feed.version) |v| try arena_allocator.dupe(u8, v) else null,
                .etag = if (raw_feed.etag) |e| try arena_allocator.dupe(u8, e) else null,
                .lastModified = if (raw_feed.lastModified) |lm| try arena_allocator.dupe(u8, lm) else null,
            };
        }

        return types.FeedGroup{
            .name = try arena_allocator.dupe(u8, group_name),
            .display_name = null,
            .feeds = feeds,
        };
    }
};
