const std = @import("std");

/// FeedConfig represents a feed configuration.
/// Memory managed externally via ArenaAllocator.
pub const FeedConfig = struct {
    xmlUrl: []const u8,
    text: ?[]const u8 = null,
    enabled: bool = true,
    title: ?[]const u8 = null,
    htmlUrl: ?[]const u8 = null,
    description: ?[]const u8 = null,
    type: ?[]const u8 = null,
    language: ?[]const u8 = null,
    version: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    lastModified: ?[]const u8 = null,
};

/// FeedList is an alias for ArrayListUnmanaged(FeedConfig)
pub const FeedList = std.ArrayListUnmanaged(FeedConfig);

/// Helper function to filter enabled feeds (does NOT clone, just creates a new slice reference)
pub fn filterEnabledFeeds(allocator: std.mem.Allocator, source: FeedList) !FeedList {
    var enabled_count: usize = 0;
    for (source.items) |feed| {
        if (feed.enabled) enabled_count += 1;
    }

    var list: FeedList = .empty;
    try list.ensureTotalCapacity(allocator, enabled_count);

    for (source.items) |feed| {
        if (feed.enabled) {
            list.appendAssumeCapacity(feed);
        }
    }

    return list;
}

pub const DisplayConfig = struct {
    maxTitleLength: usize = 120,
    maxDescriptionLength: usize = 300,
    maxItemsPerFeed: usize = 20,
    showPublishDate: bool = true,
    showDescription: bool = true,
    showLink: bool = true,
    truncateUrls: bool = true,
    pagerMode: bool = true,
    underlineUrls: bool = true,
    dateFormat: []const u8 = "%Y-%m-%d",
};

pub const HistoryConfig = struct {
    retentionDays: u32 = 50,
    fetchIntervalDays: u32 = 1,
    dayStartHour: u8 = 0,
};

pub const NetworkConfig = struct {
    maxFeedSizeMB: f64 = 0.2,
};

/// GlobalConfig represents the global application configuration.
pub const GlobalConfig = struct {
    display: DisplayConfig,
    history: HistoryConfig = HistoryConfig{},
    network: NetworkConfig = NetworkConfig{},
};

/// FeedGroup represents a collection of feeds with a name and display title.
/// Memory managed externally via ArenaAllocator.
pub const FeedGroup = struct {
    name: []const u8,
    display_name: ?[]const u8,
    feeds: []FeedConfig,

    pub fn getDisplayName(self: FeedGroup) []const u8 {
        return self.display_name orelse self.name;
    }
};

/// ParsedFeed represents a successfully parsed RSS/Atom feed.
/// Owns its memory through an ArenaAllocator to avoid double allocation.
pub const ParsedFeed = struct {
    arena: std.heap.ArenaAllocator,
    title: ?[]const u8,
    description: ?[]const u8 = null,
    link: ?[]const u8 = null,
    language: ?[]const u8 = null,
    generator: ?[]const u8 = null,
    lastBuildDate: ?[]const u8 = null,
    items: []RssItem,
    author_name: ?[]const u8 = null,
    author_uri: ?[]const u8 = null,

    pub fn deinit(self: *ParsedFeed) void {
        self.arena.deinit();
    }
};

/// RssItem represents a parsed RSS feed item.
/// Memory managed externally via ArenaAllocator.
pub const RssItem = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    link: ?[]const u8 = null,
    pubDate: ?[]const u8 = null,
    timestamp: i64 = 0,
    guid: ?[]const u8 = null,
    feedName: ?[]const u8 = null,
    groupName: ?[]const u8 = null,
    groupDisplayName: ?[]const u8 = null,
};

/// LastRunState stores items from the previous run.
/// Memory managed externally via ArenaAllocator.
pub const LastRunState = struct {
    timestamp: ?i64 = null,
    items: []const RssItem = &.{},
    file_date: ?[]const u8 = null,
};

/// CurlError represents an error from the curl fallback.
/// Memory managed externally via ArenaAllocator.
pub const CurlError = struct {
    message: []const u8,
};
