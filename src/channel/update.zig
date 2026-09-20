const std = @import("std");
const testing = std.testing;
const workspace = @import("../app/workspace.zig");

pub const max_text = 64 * 1024;
pub const max_file = workspace.max_transfer;
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
        for (self.items) |*update| update.deinit(gpa);
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
    text: []u8,
    owner_text: ?[]u8 = null,
    photo: ?[]u8 = null,
    preview_id: ?[]u8 = null,
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
        if (self.owner_text) |text| gpa.free(text);
        if (self.photo) |photo| gpa.free(photo);
        if (self.preview_id) |preview| gpa.free(preview);
        if (self.reply_text) |text| gpa.free(text);
        if (self.file_id) |id| gpa.free(id);
        if (self.file_name) |name| gpa.free(name);
        if (self.mime) |mime| gpa.free(mime);
        if (self.unique_id) |id| gpa.free(id);
        if (self.emoji) |emoji| gpa.free(emoji);
        if (self.sticker_type) |kind| gpa.free(kind);
        if (self.callback_id) |id| gpa.free(id);
        if (self.callback_data) |data| gpa.free(data);
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
    width: i64 = 0,
    height: i64 = 0,
};

const RawFile = struct {
    file_id: []const u8 = "",
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    file_size: ?i64 = null,
    thumbnail: ?RawPhoto = null,
};

const RawSticker = struct {
    file_id: []const u8 = "",
    file_unique_id: []const u8 = "",
    file_size: ?i64 = null,
    emoji: ?[]const u8 = null,
    is_animated: bool = false,
    is_video: bool = false,
    thumbnail: ?RawPhoto = null,
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
    for (sizes) |photo| {
        if (photo.file_id.len == 0 or (photo.file_size orelse 0) > max_file) continue;
        const area = @as(i128, @max(photo.width, 0)) * @as(i128, @max(photo.height, 0));
        const best_area = if (best) |current| @as(i128, @max(current.width, 0)) * @as(i128, @max(current.height, 0)) else -1;
        if (best == null or area > best_area or (area == best_area and (photo.file_size orelse 0) > (best.?.file_size orelse 0))) best = photo;
    }
    return best;
}

/// Adds bounded attachment metadata before download.
fn describe(gpa: std.mem.Allocator, caption: []const u8, file: RawFile) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}[attachment: {s}, {s}, {d} bytes]", .{
        caption,
        if (caption.len == 0) "" else "\n",
        file.file_name orelse "unnamed",
        file.mime_type orelse "unknown type",
        file.file_size orelse 0,
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
        for (items.items) |*update| update.deinit(gpa);
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
            var update: Update = undefined;
            {
                const chat_type = try gpa.dupe(u8, if (msg) |message| message.chat.type else "");
                errdefer gpa.free(chat_type);
                const text = try gpa.dupe(u8, "");
                errdefer gpa.free(text);
                update = .{
                    .update_id = raw.update_id,
                    .from_id = cb.from.id,
                    .chat_id = if (msg) |message| message.chat.id else 0,
                    .chat_type = chat_type,
                    .message_id = if (msg) |message| message.message_id else 0,
                    .kind = .callback,
                    .text = text,
                };
            }
            errdefer update.deinit(gpa);
            update.callback_id = try gpa.dupe(u8, cb.id[0..@min(cb.id.len, max_callback)]);
            const data = cb.data orelse "";
            if (data.len <= max_callback) update.callback_data = try gpa.dupe(u8, data);
            try items.append(gpa, update);
            continue;
        }
        if (raw.message_reaction) |reaction| {
            const from = reaction.user orelse continue;
            if (from.is_bot) continue;
            var update: Update = undefined;
            {
                const chat_type = try gpa.dupe(u8, reaction.chat.type);
                errdefer gpa.free(chat_type);
                const text = try gpa.dupe(u8, "");
                errdefer gpa.free(text);
                update = .{
                    .update_id = raw.update_id,
                    .from_id = from.id,
                    .chat_id = reaction.chat.id,
                    .chat_type = chat_type,
                    .message_id = reaction.message_id,
                    .kind = .reaction,
                    .text = text,
                };
            }
            errdefer update.deinit(gpa);
            try items.append(gpa, update);
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
        if (msg.document) |document| {
            file = document;
            kind = .document;
        }
        if (msg.audio) |audio| {
            file = audio;
            kind = .audio;
        }
        if (msg.voice) |voice| {
            file = voice;
            kind = .voice;
        }
        if (msg.video) |video| {
            file = video;
            kind = .video;
        }
        if (msg.animation) |animation| {
            file = animation;
            kind = .animation;
        }
        if (file) |value| if (value.file_id.len == 0) {
            file = null;
            kind = .text;
        };
        const sticker = msg.sticker;
        if (sticker != null) kind = .sticker;
        if (msg.location != null) kind = .location;
        if (caption.len == 0 and picture == null and file == null and sticker == null and msg.location == null) continue;

        var update: Update = undefined;
        {
            const chat_type = try gpa.dupe(u8, msg.chat.type);
            errdefer gpa.free(chat_type);
            const reply_text = if (msg.reply_to_message) |reply| blk: {
                const text = reply.text orelse reply.caption orelse break :blk null;
                break :blk if (text.len <= max_text) try gpa.dupe(u8, text) else null;
            } else null;
            errdefer if (reply_text) |text| gpa.free(text);
            const text = if (file) |value| try describe(gpa, caption, value) else try gpa.dupe(u8, caption);
            errdefer gpa.free(text);
            const owner_text = if (caption.len == 0) null else try gpa.dupe(u8, caption);
            errdefer if (owner_text) |owner| gpa.free(owner);
            update = .{
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
        errdefer update.deinit(gpa);
        if (picture) |photo| {
            update.photo = try gpa.dupe(u8, photo.file_id);
            update.file_size = photo.file_size;
        }
        if (file) |value| {
            update.file_id = try gpa.dupe(u8, value.file_id);
            update.file_name = if (value.file_name) |name| try gpa.dupe(u8, name) else null;
            update.mime = if (value.mime_type) |mime| try gpa.dupe(u8, mime) else null;
            update.file_size = value.file_size;
            if (value.thumbnail) |photo| {
                if (photo.file_id.len != 0) update.preview_id = try gpa.dupe(u8, photo.file_id);
            }
        }
        if (sticker) |value| {
            if (value.file_id.len == 0) {
                update.deinit(gpa);
                continue;
            }
            update.file_id = try gpa.dupe(u8, value.file_id);
            update.unique_id = try gpa.dupe(u8, value.file_unique_id);
            update.emoji = if (value.emoji) |emoji| try gpa.dupe(u8, emoji) else null;
            update.file_size = value.file_size;
            update.sticker_type = try gpa.dupe(u8, if (value.is_video) "video" else if (value.is_animated) "animated" else "static");
            if (value.thumbnail) |photo| {
                if (photo.file_id.len != 0) update.preview_id = try gpa.dupe(u8, photo.file_id);
            }
        }
        if (msg.location) |loc| {
            update.latitude = loc.latitude;
            update.longitude = loc.longitude;
        }
        try items.append(gpa, update);
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

test "photo selection uses dimensions when size is absent" {
    const body =
        \\{"ok":true,"result":[{"update_id":1,"message":{"from":{"id":1},"chat":{"id":1,"type":"private"},"photo":[{"file_id":"small","width":90,"height":90},{"file_id":"large","width":1280,"height":720}]}}]}
    ;
    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);
    try testing.expectEqualStrings("large", batch.items[0].photo.?);
}

test "animated sticker keeps its image preview" {
    const body =
        \\{"ok":true,"result":[{"update_id":1,"message":{"from":{"id":1},"chat":{"id":1,"type":"private"},"sticker":{"file_id":"video","file_unique_id":"same","is_video":true,"thumbnail":{"file_id":"preview","width":128,"height":128}}}}]}
    ;
    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);
    try testing.expectEqualStrings("video", batch.items[0].sticker_type.?);
    try testing.expectEqualStrings("preview", batch.items[0].preview_id.?);
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
