const std = @import("std");
const types = @import("types");

test "FeedConfig preserves all OPML fields" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed.xml",
        .text = "Example Feed",
        .enabled = true,
        .title = "Example Title",
        .htmlUrl = "https://example.com",
        .description = "A test description",
        .type = "rss",
        .language = "en",
        .version = "2.0",
    };

    try std.testing.expectEqualStrings("https://example.com/feed.xml", feed.xmlUrl);
    try std.testing.expectEqualStrings("Example Feed", feed.text.?);
    try std.testing.expectEqualStrings("Example Title", feed.title.?);
    try std.testing.expectEqualStrings("https://example.com", feed.htmlUrl.?);
    try std.testing.expectEqualStrings("A test description", feed.description.?);
    try std.testing.expectEqualStrings("rss", feed.type.?);
    try std.testing.expectEqualStrings("en", feed.language.?);
    try std.testing.expectEqualStrings("2.0", feed.version.?);
}

test "FeedConfig handles null optional fields" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed.xml",
        .text = null,
        .enabled = true,
        .title = null,
        .htmlUrl = null,
        .description = null,
        .type = null,
        .language = null,
        .version = null,
    };

    try std.testing.expect(feed.text == null);
    try std.testing.expect(feed.title == null);
    try std.testing.expect(feed.htmlUrl == null);
    try std.testing.expect(feed.description == null);
    try std.testing.expect(feed.type == null);
    try std.testing.expect(feed.language == null);
    try std.testing.expect(feed.version == null);
}

test "FeedGroup stores display_name separately from name" {
    const group = types.FeedGroup{
        .name = "tech_news",
        .display_name = "Technology News",
        .feeds = &.{},
    };

    try std.testing.expectEqualStrings("tech_news", group.name);
    try std.testing.expectEqualStrings("Technology News", group.display_name.?);
    try std.testing.expectEqualStrings("Technology News", group.getDisplayName());
}

test "FeedGroup.getDisplayName falls back to name when display_name is null" {
    const group = types.FeedGroup{
        .name = "tech",
        .display_name = null,
        .feeds = &.{},
    };

    try std.testing.expectEqualStrings("tech", group.getDisplayName());
}

test "FeedConfig handles special XML characters in fields" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed?a=1&b=2",
        .text = "Tom & Jerry <Show>",
        .description = "Contains \"quotes\" and 'apostrophes'",
    };

    try std.testing.expect(std.mem.find(u8, feed.xmlUrl, "&") != null);
    try std.testing.expect(std.mem.find(u8, feed.text.?, "&") != null);
    try std.testing.expect(std.mem.find(u8, feed.text.?, "<") != null);
    try std.testing.expect(std.mem.find(u8, feed.description.?, "\"") != null);
}

test "FeedConfig handles unicode in text fields" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed",
        .text = "日本語ニュース 🚀",
        .description = "émoji et français",
    };

    try std.testing.expectEqualStrings("日本語ニュース 🚀", feed.text.?);
    try std.testing.expectEqualStrings("émoji et français", feed.description.?);
}

test "empty FeedList is valid" {
    const allocator = std.testing.allocator;
    var list = types.FeedList.empty;
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "FeedConfig with very long URL" {
    var long_url_buf: [1200]u8 = undefined;
    var i: usize = 0;
    const prefix = "https://example.com/very/long/path/";
    @memcpy(long_url_buf[0..prefix.len], prefix);
    i = prefix.len;
    while (i < 1100) : (i += 1) {
        long_url_buf[i] = 'a';
    }

    const long_url = long_url_buf[0..i];

    const feed = types.FeedConfig{
        .xmlUrl = long_url,
    };

    try std.testing.expectEqual(i, feed.xmlUrl.len);
}
