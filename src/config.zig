const std = @import("std");
const types = @import("types");
const rss_reader = @import("rss_reader");
const FeedGroupManager = @import("feed_group_manager").FeedGroupManager;

pub const ConfigError = error{
    DirectoryCreationFailed,
    ConfigReadFailed,
    ParseFailed,
    FeedAlreadyExists,
    ConfigWriteFailed,
    OutOfMemory,
};

pub const COLORS = struct {
    pub const RESET = "\x1b[0m";
    pub const BOLD = "\x1b[1m";
    pub const RED = "\x1b[31m";
    pub const GREEN = "\x1b[32m";
    pub const YELLOW = "\x1b[33m";
    pub const BLUE = "\x1b[34m";
    pub const CYAN = "\x1b[36m";
    pub const GRAY = "\x1b[90m";
    pub const ORANGE = "\x1b[38;5;208m";
    pub const UNDERLINE = "\x1b[4m";
    pub const NO_UNDERLINE = "\x1b[24m";
};

pub const BRAILLE_ANIMATION = [_][]const u8{
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
};

pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config_dir: []u8,
    config_file: []u8,
    feed_group_manager: FeedGroupManager,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8) !ConfigManager {
        const config_dir = try std.Io.Dir.path.join(allocator, &.{ home_dir, ".hys" });
        const config_file = try std.Io.Dir.path.join(allocator, &.{ config_dir, "config.json" });

        var manager = ConfigManager{
            .allocator = allocator,
            .io = io,
            .config_dir = config_dir,
            .config_file = config_file,
            .feed_group_manager = try FeedGroupManager.init(allocator, io, config_dir),
        };

        try manager.ensureConfigDir();
        return manager;
    }

    pub fn deinit(self: ConfigManager) void {
        self.feed_group_manager.deinit();
        self.allocator.free(self.config_dir);
        self.allocator.free(self.config_file);
    }

    fn ensureConfigDir(self: ConfigManager) ConfigError!void {
        std.Io.Dir.cwd().createDirPath(self.io, self.config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return ConfigError.DirectoryCreationFailed,
        };
    }

    /// Load global configuration (display and history settings only)
    pub fn loadGlobalConfig(self: ConfigManager) ConfigError!types.GlobalConfig {
        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, self.config_file, self.allocator, .limited(1024 * 1024 * 10)) catch |err| switch (err) {
            error.FileNotFound => {
                const default_config = ConfigManager.defaultGlobalConfig();
                try self.saveGlobalConfig(default_config);
                return default_config;
            },
            else => return ConfigError.ConfigReadFailed,
        };
        defer self.allocator.free(contents);

        return self.parseGlobalConfig(contents);
    }

    fn defaultGlobalConfig() types.GlobalConfig {
        return .{
            .display = .{},
            .history = .{},
            .network = .{},
        };
    }

    fn parseGlobalConfig(self: ConfigManager, contents: []const u8) ConfigError!types.GlobalConfig {
        const RawConfig = struct {
            display: ?types.DisplayConfig = null,
            history: ?types.HistoryConfig = null,
            network: ?types.NetworkConfig = null,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(RawConfig, arena.allocator(), contents, .{
            .ignore_unknown_fields = true,
        }) catch return ConfigError.ParseFailed;
        defer parsed.deinit();

        return types.GlobalConfig{
            .display = parsed.value.display orelse types.DisplayConfig{},
            .history = parsed.value.history orelse types.HistoryConfig{},
            .network = parsed.value.network orelse types.NetworkConfig{},
        };
    }

    pub fn saveGlobalConfig(self: ConfigManager, config: types.GlobalConfig) ConfigError!void {
        var atomic_file = std.Io.Dir.cwd().createFileAtomic(self.io, self.config_file, .{ .make_path = true, .replace = true }) catch return ConfigError.ConfigWriteFailed;
        defer atomic_file.deinit(self.io);
        var json_buf: [4096]u8 = undefined;
        var json_writer = atomic_file.file.writer(self.io, &json_buf);
        json_writer.interface.print("{f}", .{std.json.fmt(config, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        })}) catch return ConfigError.ConfigWriteFailed;
        json_writer.flush() catch return ConfigError.ConfigWriteFailed;
        atomic_file.replace(self.io) catch return ConfigError.ConfigWriteFailed;
    }

    pub fn getConfigPath(self: ConfigManager) []const u8 {
        return self.config_file;
    }

    pub fn addFeed(self: ConfigManager, url: []const u8, name: ?[]const u8) !void {
        return self.addFeedToGroup("main", url, name);
    }

    pub fn addFeedToGroup(self: ConfigManager, group_name: []const u8, url: []const u8, name: ?[]const u8) !void {
        return self.feed_group_manager.addFeedToGroup(group_name, url, name);
    }

    pub fn addFeedConfigToGroup(self: ConfigManager, group_name: []const u8, feed_config: types.FeedConfig) !void {
        return self.feed_group_manager.addFeedConfigToGroup(group_name, feed_config);
    }

    pub fn getEnabledFeeds(self: ConfigManager, arena_allocator: std.mem.Allocator) !types.FeedList {
        return self.feed_group_manager.getEnabledFeeds(arena_allocator, "main");
    }

    /// Get enabled feeds from a specific group, allocating feed data into arena_allocator.
    pub fn getEnabledFeedsFromGroup(self: ConfigManager, arena_allocator: std.mem.Allocator, group_name: []const u8) !types.FeedList {
        return self.feed_group_manager.getEnabledFeeds(arena_allocator, group_name);
    }

    pub fn groupExists(self: ConfigManager, group_name: []const u8) bool {
        return self.feed_group_manager.groupExists(group_name);
    }

    pub fn getGroupDisplayName(self: ConfigManager, group_name: []const u8) !?[]const u8 {
        return self.feed_group_manager.getGroupDisplayName(group_name);
    }

    pub fn setGroupDisplayName(self: ConfigManager, group_name: []const u8, display_name: ?[]const u8) !void {
        return self.feed_group_manager.setGroupDisplayName(group_name, display_name);
    }

    /// Load a complete feed group with metadata into the given arena allocator.
    pub fn loadGroupWithMetadata(self: ConfigManager, arena_allocator: std.mem.Allocator, group_name: []const u8) !types.FeedGroup {
        return self.feed_group_manager.loadGroupWithMetadata(arena_allocator, group_name);
    }

    pub fn getAllGroupNames(self: ConfigManager) ![]const []const u8 {
        return self.feed_group_manager.getAllGroupNames();
    }
};
