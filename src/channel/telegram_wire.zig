const std = @import("std");
const testing = std.testing;
const web = @import("../net/web.zig");

pub const max_text = 64 * 1024;
pub const max_file = web.max_body;
const max_callback = 64;

pub const Kind = enum {
    text,
    photo,
    document,
    audio,
    voice,
    video,
    animation,
    sticker,
    location,
    callback,
    reaction,
};

pub fn utf8ChunkEnd(text: []const u8, max_bytes: usize) usize {
    if (max_bytes == 0) return 0;
    if (text.len <= max_bytes) return text.len;
    var end = max_bytes;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return end;
}

pub const Batch = struct {
    items: []Update = &.{},
    next_offset: ?i64 = null,

    pub fn deinit(self: *Batch, gpa: std.mem.Allocator) void {
        for (self.items) |*u| u.deinit(gpa);
        gpa.free(self.items);
        self.* = undefined;
    }
};

pub const Update = struct {
    update_id: i64,
    from_id: i64,
    chat_id: i64,
    chat_type: []u8,
    message_id: i64 = 0,
    reply_id: ?i64 = null,
    reply_text: ?[]u8 = null,
    kind: Kind = .text,
    /// Text, caption, or attachment description.
    text: []u8,
    owner_text: ?[]u8 = null,
    /// Photo selected for the model.
    photo: ?[]u8 = null,
    file_id: ?[]u8 = null,
    file_name: ?[]u8 = null,
    mime: ?[]u8 = null,
    file_size: ?i64 = null,
    unique_id: ?[]u8 = null,
    emoji: ?[]u8 = null,
    sticker_type: ?[]u8 = null,
    callback_id: ?[]u8 = null,
    callback_data: ?[]u8 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,

    pub fn deinit(self: *Update, gpa: std.mem.Allocator) void {
        gpa.free(self.chat_type);
        gpa.free(self.text);
        if (self.owner_text) |s| gpa.free(s);
        if (self.photo) |p| gpa.free(p);
        if (self.reply_text) |s| gpa.free(s);
        if (self.file_id) |s| gpa.free(s);
        if (self.file_name) |s| gpa.free(s);
        if (self.mime) |s| gpa.free(s);
        if (self.unique_id) |s| gpa.free(s);
        if (self.emoji) |s| gpa.free(s);
        if (self.sticker_type) |s| gpa.free(s);
        if (self.callback_id) |s| gpa.free(s);
        if (self.callback_data) |s| gpa.free(s);
        self.* = undefined;
    }
};

const GetUpdatesResponse = struct {
    ok: bool = false,
    result: []const RawUpdate = &.{},
};

const RawUpdate = struct {
    update_id: i64,
    message: ?RawMessage = null,
    edited_message: ?RawMessage = null,
    callback_query: ?RawCallback = null,
    message_reaction: ?RawReaction = null,
};

const RawMessage = struct {
    message_id: i64 = 0,
    from: ?RawUser = null,
    chat: RawChat,
    text: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    photo: ?[]const RawPhoto = null,
    document: ?RawFile = null,
    audio: ?RawFile = null,
    video: ?RawFile = null,
    voice: ?RawFile = null,
    animation: ?RawFile = null,
    sticker: ?RawSticker = null,
    location: ?RawLocation = null,
    reply_to_message: ?RawReply = null,
};

const RawPhoto = struct {
    file_id: []const u8 = "",
    file_size: ?i64 = null,
};

const RawFile = struct {
    file_id: []const u8 = "",
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    file_size: ?i64 = null,
};

const RawSticker = struct {
    file_id: []const u8 = "",
    file_unique_id: []const u8 = "",
    file_size: ?i64 = null,
    emoji: ?[]const u8 = null,
    is_animated: bool = false,
    is_video: bool = false,
};

const RawReply = struct {
    message_id: i64 = 0,
    text: ?[]const u8 = null,
    caption: ?[]const u8 = null,
};
const RawLocation = struct { latitude: f64, longitude: f64 };
const RawCallback = struct {
    id: []const u8 = "",
    from: RawUser = .{},
    message: ?RawMessage = null,
    data: ?[]const u8 = null,
};
const RawReaction = struct {
    chat: RawChat,
    message_id: i64,
    user: ?RawUser = null,
};

/// Selects the largest photo under the cap.
fn largest(sizes: []const RawPhoto) ?RawPhoto {
    var best: ?RawPhoto = null;
    for (sizes) |p| {
        if (p.file_id.len == 0 or (p.file_size orelse 0) > max_file) continue;
        if (best == null or (p.file_size orelse 0) > (best.?.file_size orelse 0)) best = p;
    }
    return best;
}

/// Adds bounded attachment metadata before download.
fn describe(gpa: std.mem.Allocator, caption: []const u8, f: RawFile) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}[attachment: {s}, {s}, {d} bytes]", .{
        caption,
        if (caption.len == 0) "" else "\n",
        f.file_name orelse "unnamed",
        f.mime_type orelse "unknown type",
        f.file_size orelse 0,
    });
}

const RawChat = struct {
    id: i64,
    type: []const u8 = "",
};

const RawUser = struct {
    id: i64 = 0,
    is_bot: bool = false,
};

pub fn parseUpdates(gpa: std.mem.Allocator, body: []const u8) !Batch {
    const parsed = std.json.parseFromSlice(GetUpdatesResponse, gpa, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidTelegramResponse;
    defer parsed.deinit();
    if (!parsed.value.ok) return error.TelegramApiError;

    var items: std.ArrayList(Update) = .empty;
    errdefer {
        for (items.items) |*u| u.deinit(gpa);
        items.deinit(gpa);
    }

    var next_offset: ?i64 = null;
    for (parsed.value.result) |raw| {
        if (raw.update_id < 0) return error.InvalidTelegramUpdate;
        const candidate = raw.update_id + 1;
        if (next_offset == null or candidate > next_offset.?) next_offset = candidate;

        if (raw.callback_query) |cb| {
            if (cb.from.is_bot or cb.id.len == 0) continue;
            const msg = cb.message;
            var u: Update = undefined;
            {
                const chat_type = try gpa.dupe(u8, if (msg) |m| m.chat.type else "");
                errdefer gpa.free(chat_type);
                const text = try gpa.dupe(u8, "");
                errdefer gpa.free(text);
                u = .{
                    .update_id = raw.update_id,
                    .from_id = cb.from.id,
                    .chat_id = if (msg) |m| m.chat.id else 0,
                    .chat_type = chat_type,
                    .message_id = if (msg) |m| m.message_id else 0,
                    .kind = .callback,
                    .text = text,
                };
            }
            errdefer u.deinit(gpa);
            u.callback_id = try gpa.dupe(u8, cb.id[0..@min(cb.id.len, max_callback)]);
            const data = cb.data orelse "";
            if (data.len <= max_callback) u.callback_data = try gpa.dupe(u8, data);
            try items.append(gpa, u);
            continue;
        }
        if (raw.message_reaction) |reaction| {
            const from = reaction.user orelse continue;
            if (from.is_bot) continue;
            var u: Update = undefined;
            {
                const chat_type = try gpa.dupe(u8, reaction.chat.type);
                errdefer gpa.free(chat_type);
                const text = try gpa.dupe(u8, "");
                errdefer gpa.free(text);
                u = .{
                    .update_id = raw.update_id,
                    .from_id = from.id,
                    .chat_id = reaction.chat.id,
                    .chat_type = chat_type,
                    .message_id = reaction.message_id,
                    .kind = .reaction,
                    .text = text,
                };
            }
            errdefer u.deinit(gpa);
            try items.append(gpa, u);
            continue;
        }

        const msg = raw.message orelse raw.edited_message orelse continue;
        const from = msg.from orelse continue;
        if (from.is_bot) continue;

        const caption = msg.text orelse msg.caption orelse "";
        if (caption.len > max_text) continue;
        const picture = if (msg.photo) |sizes| largest(sizes) else null;
        var file: ?RawFile = null;
        var kind: Kind = if (picture != null) .photo else .text;
        if (msg.document) |f| {
            file = f;
            kind = .document;
        }
        if (msg.audio) |f| {
            file = f;
            kind = .audio;
        }
        if (msg.voice) |f| {
            file = f;
            kind = .voice;
        }
        if (msg.video) |f| {
            file = f;
            kind = .video;
        }
        if (msg.animation) |f| {
            file = f;
            kind = .animation;
        }
        if (file) |f| if (f.file_id.len == 0 or (f.file_size orelse 0) > max_file) {
            file = null;
            kind = .text;
        };
        const sticker = msg.sticker;
        if (sticker != null) kind = .sticker;
        if (msg.location != null) kind = .location;
        if (caption.len == 0 and picture == null and file == null and sticker == null and msg.location == null) continue;

        var u: Update = undefined;
        {
            const chat_type = try gpa.dupe(u8, msg.chat.type);
            errdefer gpa.free(chat_type);
            const reply_text = if (msg.reply_to_message) |reply| blk: {
                const text = reply.text orelse reply.caption orelse break :blk null;
                break :blk if (text.len <= max_text) try gpa.dupe(u8, text) else null;
            } else null;
            errdefer if (reply_text) |text| gpa.free(text);
            const text = if (file) |f| try describe(gpa, caption, f) else try gpa.dupe(u8, caption);
            errdefer gpa.free(text);
            const owner_text = if (caption.len == 0) null else try gpa.dupe(u8, caption);
            errdefer if (owner_text) |owner| gpa.free(owner);
            u = .{
                .update_id = raw.update_id,
                .from_id = from.id,
                .chat_id = msg.chat.id,
                .chat_type = chat_type,
                .message_id = msg.message_id,
                .reply_id = if (msg.reply_to_message) |reply| reply.message_id else null,
                .reply_text = reply_text,
                .kind = kind,
                .text = text,
                .owner_text = owner_text,
            };
        }
        errdefer u.deinit(gpa);
        if (picture) |p| {
            u.photo = try gpa.dupe(u8, p.file_id);
            u.file_size = p.file_size;
        }
        if (file) |f| {
            u.file_id = try gpa.dupe(u8, f.file_id);
            u.file_name = if (f.file_name) |s| try gpa.dupe(u8, s) else null;
            u.mime = if (f.mime_type) |s| try gpa.dupe(u8, s) else null;
            u.file_size = f.file_size;
        }
        if (sticker) |s| {
            if (s.file_id.len == 0 or (s.file_size orelse 0) > max_file) {
                u.deinit(gpa);
                continue;
            }
            u.file_id = try gpa.dupe(u8, s.file_id);
            u.unique_id = try gpa.dupe(u8, s.file_unique_id);
            u.emoji = if (s.emoji) |emoji| try gpa.dupe(u8, emoji) else null;
            u.file_size = s.file_size;
            u.sticker_type = try gpa.dupe(u8, if (s.is_video) "video" else if (s.is_animated) "animated" else "static");
        }
        if (msg.location) |loc| {
            u.latitude = loc.latitude;
            u.longitude = loc.longitude;
        }
        try items.append(gpa, u);
    }

    return .{
        .items = try items.toOwnedSlice(gpa),
        .next_offset = next_offset,
    };
}

test "parseUpdates extracts a private text message from a fixture" {
    const body =
        \\{"ok":true,"result":[{"update_id":10,"message":{"message_id":1,"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"text":"hello"}}]}
    ;
    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), batch.items.len);
    try testing.expectEqual(@as(i64, 10), batch.items[0].update_id);
    try testing.expectEqual(@as(i64, 42), batch.items[0].from_id);
    try testing.expectEqual(@as(i64, 42), batch.items[0].chat_id);
    try testing.expectEqualStrings("private", batch.items[0].chat_type);
    try testing.expectEqualStrings("hello", batch.items[0].text);
    try testing.expectEqual(@as(i64, 11), batch.next_offset.?);
}

test "parseUpdates keeps answerable malformed callbacks and advances the offset" {
    const body =
        \\{"ok":true,"result":[
        \\  {"update_id":1,"message":{"from":{"id":7,"is_bot":true},"chat":{"id":7,"type":"private"},"text":"bot"}},
        \\  {"update_id":2,"callback_query":{"id":"x"}},
        \\  {"update_id":3,"message":{"from":{"id":9,"is_bot":false},"chat":{"id":9,"type":"private"}}}
        \\]}
    ;
    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), batch.items.len);
    try testing.expectEqual(Kind.callback, batch.items[0].kind);
    try testing.expectEqual(@as(i64, 0), batch.items[0].chat_id);
    try testing.expectEqual(@as(i64, 4), batch.next_offset.?);
}

test "utf8ChunkEnd does not split a multi-byte character" {
    const text = "ab€cd";
    try testing.expectEqual(@as(usize, 2), utf8ChunkEnd(text, 4));
    try testing.expectEqual(text.len, utf8ChunkEnd(text, 32));
    try testing.expectEqual(@as(usize, 0), utf8ChunkEnd("€", 1));
    try testing.expectEqual(@as(usize, 0), utf8ChunkEnd("€", 0));
}

test "parseUpdates skips text over 64 KiB and still advances the offset" {
    const oversized = "a" ** (64 * 1024 + 1);
    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"ok\":true,\"result\":[{{\"update_id\":1,\"message\":{{\"from\":{{\"id\":1,\"is_bot\":false}},\"chat\":{{\"id\":1,\"type\":\"private\"}},\"text\":\"{s}\"}}}}]}}",
        .{oversized},
    );
    defer testing.allocator.free(body);

    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), batch.items.len);
    try testing.expectEqual(@as(i64, 2), batch.next_offset.?);
}
