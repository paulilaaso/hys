const std = @import("std");
const types = @import("types");
const formatter = @import("formatter");
const config = @import("config");

test "FeedConfig field access" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed.xml",
        .text = "Example Feed",
        .enabled = true,
        .title = "Example Title",
        .htmlUrl = "https://example.com",
        .description = "A test feed",
        .type = "rss",
        .language = "en",
        .version = "2.0",
    };

    try std.testing.expectEqualStrings("https://example.com/feed.xml", feed.xmlUrl);
    try std.testing.expectEqualStrings("Example Feed", feed.text.?);
    try std.testing.expect(feed.enabled);
    try std.testing.expectEqualStrings("Example Title", feed.title.?);
    try std.testing.expectEqualStrings("https://example.com", feed.htmlUrl.?);
    try std.testing.expectEqualStrings("A test feed", feed.description.?);
    try std.testing.expectEqualStrings("rss", feed.type.?);
    try std.testing.expectEqualStrings("en", feed.language.?);
    try std.testing.expectEqualStrings("2.0", feed.version.?);
}

test "FeedConfig with null fields" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed.xml",
        .text = null,
        .enabled = false,
    };

    try std.testing.expect(feed.text == null);
    try std.testing.expect(!feed.enabled);
    try std.testing.expectEqualStrings("https://example.com/feed.xml", feed.xmlUrl);
}

test "filterEnabledFeeds only returns enabled feeds" {
    const allocator = std.testing.allocator;

    var source = types.FeedList.empty;
    defer source.deinit(allocator);

    try source.append(allocator, types.FeedConfig{
        .xmlUrl = "https://feed1.com/rss",
        .enabled = true,
    });
    try source.append(allocator, types.FeedConfig{
        .xmlUrl = "https://feed2.com/rss",
        .enabled = false,
    });
    try source.append(allocator, types.FeedConfig{
        .xmlUrl = "https://feed3.com/rss",
        .enabled = true,
    });

    var filtered = try types.filterEnabledFeeds(allocator, source);
    defer filtered.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), filtered.items.len);
    try std.testing.expect(filtered.items[0].enabled);
    try std.testing.expect(filtered.items[1].enabled);
}

test "RssItem field access" {
    const item = types.RssItem{
        .title = "Article Title",
        .description = "Article description",
        .link = "https://example.com/article",
        .pubDate = "2024-12-05",
        .timestamp = 1733356800,
        .guid = "guid-12345",
        .feedName = "Example Feed",
    };

    try std.testing.expectEqualStrings("Article Title", item.title.?);
    try std.testing.expectEqualStrings("Article description", item.description.?);
    try std.testing.expectEqualStrings("https://example.com/article", item.link.?);
    try std.testing.expectEqual(item.timestamp, 1733356800);
}

test "DisplayConfig has sensible defaults" {
    const display = types.DisplayConfig{};
    try std.testing.expectEqual(@as(usize, 120), display.maxTitleLength);
    try std.testing.expectEqual(@as(usize, 300), display.maxDescriptionLength);
    try std.testing.expectEqual(@as(usize, 20), display.maxItemsPerFeed);
    try std.testing.expect(display.showPublishDate);
    try std.testing.expect(display.showDescription);
    try std.testing.expect(display.showLink);
    try std.testing.expect(display.truncateUrls);
}

test "NetworkConfig has sensible defaults" {
    const network = types.NetworkConfig{};
    try std.testing.expectEqual(0.2, network.maxFeedSizeMB);
}

test "HistoryConfig has sensible defaults" {
    const history = types.HistoryConfig{};
    try std.testing.expectEqual(@as(u32, 50), history.retentionDays);
}

test "getCodepointDisplayWidth handles ASCII" {
    try std.testing.expectEqual(@as(usize, 1), formatter.getCodepointDisplayWidth('a'));
    try std.testing.expectEqual(@as(usize, 1), formatter.getCodepointDisplayWidth('Z'));
    try std.testing.expectEqual(@as(usize, 1), formatter.getCodepointDisplayWidth('5'));
}

test "getCodepointDisplayWidth handles CJK" {
    try std.testing.expectEqual(@as(usize, 2), formatter.getCodepointDisplayWidth(0x1100));
    try std.testing.expectEqual(@as(usize, 2), formatter.getCodepointDisplayWidth(0x4E00));
    try std.testing.expectEqual(@as(usize, 2), formatter.getCodepointDisplayWidth(0xAC00));
}

test "getCodepointDisplayWidth handles combining marks" {
    try std.testing.expectEqual(@as(usize, 0), formatter.getCodepointDisplayWidth(0x0300));
}

test "Formatter creates with default values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const display = types.DisplayConfig{};
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const fmt = formatter.Formatter.init(allocator, io, &env_map, display);

    try std.testing.expect(fmt.terminal_width > 0);
    try std.testing.expect(fmt.terminal_width < 1000);
    try std.testing.expect(fmt.writer == null);
}

test "Formatter.initDirect sets writer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const display = types.DisplayConfig{};
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var buf: [4096]u8 = undefined;
    const file_writer = std.Io.File.stdout().writer(io, &buf);
    const fmt = formatter.Formatter.initDirect(allocator, io, &env_map, display, file_writer.interface);

    try std.testing.expect(fmt.writer != null);
}

test "COLORS constants are non-empty" {
    try std.testing.expect(config.COLORS.RESET.len > 0);
    try std.testing.expect(config.COLORS.BOLD.len > 0);
    try std.testing.expect(config.COLORS.RED.len > 0);
    try std.testing.expect(config.COLORS.GREEN.len > 0);
    try std.testing.expect(config.COLORS.YELLOW.len > 0);
    try std.testing.expect(config.COLORS.BLUE.len > 0);
    try std.testing.expect(config.COLORS.CYAN.len > 0);
    try std.testing.expect(config.COLORS.GRAY.len > 0);
}

test "GlobalConfig default creation" {
    const global = types.GlobalConfig{
        .display = types.DisplayConfig{},
        .history = types.HistoryConfig{},
        .network = types.NetworkConfig{},
    };

    try std.testing.expectEqual(@as(usize, 120), global.display.maxTitleLength);
    try std.testing.expectEqual(@as(u32, 50), global.history.retentionDays);
    try std.testing.expectEqual(0.2, global.network.maxFeedSizeMB);
}

test "FeedGroup.getDisplayName returns display_name when set" {
    const group = types.FeedGroup{
        .name = "tech",
        .display_name = "Technology News",
        .feeds = &.{},
    };

    try std.testing.expectEqualStrings("Technology News", group.getDisplayName());
}

test "FeedGroup.getDisplayName returns name when display_name is null" {
    const group = types.FeedGroup{
        .name = "tech",
        .display_name = null,
        .feeds = &.{},
    };

    try std.testing.expectEqualStrings("tech", group.getDisplayName());
}

test "LastRunState initialization" {
    const state = types.LastRunState{
        .timestamp = 1733356800,
        .items = &.{},
    };

    try std.testing.expectEqual(@as(i64, 1733356800), state.timestamp.?);
    try std.testing.expectEqual(@as(usize, 0), state.items.len);
}

test "CurlError field access" {
    const err = types.CurlError{
        .message = "Test error message",
    };

    try std.testing.expectEqualStrings("Test error message", err.message);
}

test "Empty feed list is valid" {
    const allocator = std.testing.allocator;

    var list = types.FeedList.empty;
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "All disabled feeds returns empty list" {
    const allocator = std.testing.allocator;

    var source = types.FeedList.empty;
    defer source.deinit(allocator);

    try source.append(allocator, types.FeedConfig{
        .xmlUrl = "https://feed1.com/rss",
        .enabled = false,
    });
    try source.append(allocator, types.FeedConfig{
        .xmlUrl = "https://feed2.com/rss",
        .enabled = false,
    });

    var filtered = try types.filterEnabledFeeds(allocator, source);
    defer filtered.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), filtered.items.len);
}

test "RssItem with all null fields" {
    const item = types.RssItem{};

    try std.testing.expect(item.title == null);
    try std.testing.expect(item.description == null);
    try std.testing.expect(item.link == null);
    try std.testing.expect(item.pubDate == null);
    try std.testing.expect(item.guid == null);
    try std.testing.expect(item.feedName == null);
    try std.testing.expectEqual(@as(i64, 0), item.timestamp);
}

test "Very long feed URL" {
    const long_url = "https://example.com/" ++ "a" ** 1000;

    const feed = types.FeedConfig{
        .xmlUrl = long_url,
    };

    try std.testing.expectEqual(long_url.len, feed.xmlUrl.len);
}

test "Unicode in feed name" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed",
        .text = "🚀 Rocket News 日本語",
    };

    try std.testing.expectEqualStrings("🚀 Rocket News 日本語", feed.text.?);
}

test "writeJsonEscaped escapes quotes" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    try formatter.writeJsonEscaped(&buffer, "Hello \"World\"");
    try std.testing.expectEqualStrings("Hello \\\"World\\\"", buffer.items);
}

test "writeJsonEscaped escapes backslashes" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    try formatter.writeJsonEscaped(&buffer, "path\\to\\file");
    try std.testing.expectEqualStrings("path\\\\to\\\\file", buffer.items);
}

test "writeJsonEscaped escapes newlines and tabs" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    try formatter.writeJsonEscaped(&buffer, "line1\nline2\ttab");
    try std.testing.expectEqualStrings("line1\\nline2\\ttab", buffer.items);
}

test "writeJsonEscaped strips ANSI CSI sequences" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    try formatter.writeJsonEscaped(&buffer, "\x1b[33mYellow\x1b[0m Text");
    try std.testing.expectEqualStrings("Yellow Text", buffer.items);
}

test "writeJsonEscaped strips ANSI OSC hyperlink sequences" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    try formatter.writeJsonEscaped(&buffer, "\x1b]8;;https://example.com\x1b\\Link Text\x1b]8;;\x1b\\");
    try std.testing.expectEqualStrings("Link Text", buffer.items);
}

test "writeJsonEscaped handles mixed content" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    try formatter.writeJsonEscaped(&buffer, "Title: \"Test\"\n\x1b[1mBold\x1b[0m");
    try std.testing.expectEqualStrings("Title: \\\"Test\\\"\\nBold", buffer.items);
}

test "writeJsonEscaped preserves unicode" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    try formatter.writeJsonEscaped(&buffer, "日本語 🚀 emoji");
    try std.testing.expectEqualStrings("日本語 🚀 emoji", buffer.items);
}

test "writeJsonEscaped escapes control characters" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    try formatter.writeJsonEscaped(&buffer, "null\x00char");
    try std.testing.expectEqualStrings("null\\u0000char", buffer.items);
}

pub fn main() !void {
    std.debug.print("Running comprehensive test suite for Hys\n", .{});
    std.debug.print("========================================\n\n", .{});
}
