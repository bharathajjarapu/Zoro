const std = @import("std");
const tools = @import("root.zig");
const Db = @import("../data/db.zig").Db;
const identity = @import("../data/identity.zig");
const learning = @import("../data/learning.zig");
const skills = @import("../automation/skills.zig");
const testkit = @import("../testing/testkit.zig");

const file_param = [_]tools.Param{.{ .name = "file", .description = "soul, identity, user, or memory" }};
const proposal_param = [_]tools.Param{
    .{ .name = "file", .description = "soul, identity, user, or memory" },
    .{ .name = "content", .description = "replacement Markdown" },
    .{ .name = "evidence", .description = "owner request quote" },
    .{ .name = "reason", .description = "change reason" },
};
const skill_param = [_]tools.Param{
    .{ .name = "content", .description = "complete SKILL.md" },
    .{ .name = "evidence", .description = "owner evidence" },
    .{ .name = "reason", .description = "reuse reason" },
};
const id_param = [_]tools.Param{.{ .name = "id", .description = "proposal id" }};
const mode_param = [_]tools.Param{.{ .name = "mode", .description = "off, propose, or auto" }};

pub const character_inspect: tools.Def = .{
    .name = "character_inspect",
    .description = "Read one character file.",
    .params = &file_param,
    .primary_only = true,
    .run = runCharacterInspect,
};

pub const character_propose: tools.Def = .{
    .name = "character_propose",
    .description = "Propose a character change.",
    .params = &proposal_param,
    .mutates = true,
    .primary_only = true,
    .run = runCharacterPropose,
};

pub const learning_inspect: tools.Def = .{
    .name = "learning_inspect",
    .description = "Inspect learning proposals.",
    .params = &.{.{ .name = "id", .description = "proposal id", .required = false }},
    .primary_only = true,
    .run = runLearningInspect,
};

pub const learning_propose: tools.Def = .{
    .name = "learning_propose",
    .description = "Propose a reusable skill.",
    .params = &skill_param,
    .mutates = true,
    .primary_only = true,
    .run = runLearningPropose,
};

pub const learning_apply: tools.Def = .{
    .name = "learning_apply",
    .description = "Apply an approved skill.",
    .params = &id_param,
    .mutates = true,
    .primary_only = true,
    .run = runSkillApply,
};

pub const learning_reject: tools.Def = .{
    .name = "learning_reject",
    .description = "Reject a proposal.",
    .params = &id_param,
    .mutates = true,
    .primary_only = true,
    .run = runReject,
};

pub const learning_quarantine: tools.Def = .{
    .name = "learning_quarantine",
    .description = "Quarantine a proposal.",
    .params = &id_param,
    .mutates = true,
    .primary_only = true,
    .run = runQuarantine,
};

pub const learning_rollback: tools.Def = .{
    .name = "learning_rollback",
    .description = "Roll back a skill.",
    .params = &id_param,
    .mutates = true,
    .primary_only = true,
    .run = runSkillRollback,
};

pub const learning_set_mode: tools.Def = .{
    .name = "learning_set_mode",
    .description = "Set learning mode.",
    .params = &mode_param,
    .mutates = true,
    .primary_only = true,
    .run = runMode,
};

/// Register only in `tools.gated`; it writes owner identity.
pub const apply_identity: tools.Def = .{
    .name = "apply_identity",
    .description = "Apply approved character.",
    .params = &id_param,
    .mutates = true,
    .primary_only = true,
    .run = runIdentityApply,
};

/// Register only in `tools.gated`; it restores owner identity.
pub const rollback_identity: tools.Def = .{
    .name = "rollback_identity",
    .description = "Roll back character.",
    .params = &id_param,
    .mutates = true,
    .primary_only = true,
    .run = runIdentityRollback,
};

/// Register only in `tools.gated`; it deletes one fixed owner file.
pub const reset_identity: tools.Def = .{
    .name = "reset_identity",
    .description = "Reset one character file.",
    .params = &file_param,
    .mutates = true,
    .primary_only = true,
    .run = runIdentityReset,
};

const FileArgs = struct { file: []const u8 };
const ProposalArgs = struct { file: []const u8, content: []const u8, evidence: []const u8, reason: []const u8 };
const SkillArgs = struct { content: []const u8, evidence: []const u8, reason: []const u8 };
const IdArgs = struct { id: []const u8 };
const InspectArgs = struct { id: ?[]const u8 = null };
const ModeArgs = struct { mode: []const u8 };

fn runCharacterInspect(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(FileArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const file = try parseFile(parsed.value.file);
    const text = identity.read(ctx.gpa, ctx.io, ctx.workspace, file) catch |err| switch (err) {
        error.FileNotFound => return std.fmt.allocPrint(ctx.gpa, "{s} is not set", .{identity.name(file)}),
        else => return err,
    };
    defer ctx.gpa.free(text);
    return std.fmt.allocPrint(ctx.gpa, "{s}\n\n{s}", .{ identity.name(file), text });
}

fn runCharacterPropose(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(ProposalArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try tools.requireOwnerEvidence(ctx, parsed.value.evidence);
    const file = try parseFile(parsed.value.file);
    try identity.validate(parsed.value.content);
    const old = identity.read(ctx.gpa, ctx.io, ctx.workspace, file) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (old) |text| ctx.gpa.free(text);
    const id = try learning.create(ctx.db, identityTarget(file), null, ctx.source_message, parsed.value.evidence, parsed.value.reason, old, parsed.value.content, now(ctx));
    return std.fmt.allocPrint(ctx.gpa, "pending character proposal #{d} for {s}", .{ id, identity.name(file) });
}

fn runLearningInspect(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(InspectArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.id) |raw| {
        const id = try parseId(raw);
        var proposal = (try learning.get(ctx.db, ctx.gpa, id)) orelse return std.fmt.allocPrint(ctx.gpa, "proposal #{d} was not found", .{id});
        defer proposal.deinit(ctx.gpa);
        return proposalText(ctx.gpa, &proposal);
    }
    const list = try learning.list(ctx.db, ctx.gpa, null);
    defer {
        for (list) |*proposal| proposal.deinit(ctx.gpa);
        ctx.gpa.free(list);
    }
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    errdefer out.deinit();
    try out.writer.print("learning mode: {s}\n", .{@tagName(try learning.mode(ctx.db))});
    for (list) |proposal| try out.writer.print("#{d} {s} {s}\n", .{ proposal.id, @tagName(proposal.status), proposal.target });
    return out.toOwnedSlice();
}

fn runLearningPropose(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(SkillArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try tools.requireOwnerEvidence(ctx, parsed.value.evidence);
    const skill = try skills.validateLearned(parsed.value.content);
    const old = skills.readMarkdown(ctx.gpa, ctx.io, ctx.skills_dir, skill.name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (old) |text| ctx.gpa.free(text);
    const target = try std.fmt.allocPrint(ctx.gpa, "skill-{s}", .{skill.name});
    defer ctx.gpa.free(target);
    const id = try learning.create(ctx.db, target, null, ctx.source_message, parsed.value.evidence, parsed.value.reason, old, parsed.value.content, now(ctx));
    return std.fmt.allocPrint(ctx.gpa, "pending skill proposal #{d}: {s}", .{ id, skill.name });
}

fn runSkillApply(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(IdArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = try parseId(parsed.value.id);
    try applySkill(ctx, id);
    return std.fmt.allocPrint(ctx.gpa, "applied skill proposal #{d}", .{id});
}

fn runReject(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(IdArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = try parseId(parsed.value.id);
    try learning.setStatus(ctx.db, id, .rejected, now(ctx));
    return std.fmt.allocPrint(ctx.gpa, "rejected proposal #{d}", .{id});
}

fn runQuarantine(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(IdArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = try parseId(parsed.value.id);
    try learning.setStatus(ctx.db, id, .quarantined, now(ctx));
    return std.fmt.allocPrint(ctx.gpa, "quarantined proposal #{d}", .{id});
}

fn runSkillRollback(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(IdArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = try parseId(parsed.value.id);
    try rollbackSkill(ctx, id);
    return std.fmt.allocPrint(ctx.gpa, "rolled back skill proposal #{d}", .{id});
}

fn runMode(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(ModeArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const mode = std.meta.stringToEnum(learning.Mode, parsed.value.mode) orelse return error.BadMode;
    try learning.setMode(ctx.db, mode);
    return std.fmt.allocPrint(ctx.gpa, "learning mode: {s}", .{@tagName(mode)});
}

fn runIdentityApply(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(IdArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = try parseId(parsed.value.id);
    try applyIdentity(ctx, id);
    return std.fmt.allocPrint(ctx.gpa, "applied character proposal #{d}", .{id});
}

fn runIdentityRollback(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(IdArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = try parseId(parsed.value.id);
    try rollbackIdentity(ctx, id);
    return std.fmt.allocPrint(ctx.gpa, "rolled back character proposal #{d}", .{id});
}

fn runIdentityReset(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(FileArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const file = try parseFile(parsed.value.file);
    try identity.reset(ctx.io, ctx.workspace, file);
    return std.fmt.allocPrint(ctx.gpa, "reset {s}", .{identity.name(file)});
}

fn applySkill(ctx: *tools.Ctx, id: i64) !void {
    var proposal = (try learning.get(ctx.db, ctx.gpa, id)) orelse return error.ProposalNotFound;
    defer proposal.deinit(ctx.gpa);
    if (proposal.status != .pending) return error.BadTransition;
    const name = skillName(proposal.target) orelse return error.NotSkillProposal;
    const skill = try skills.validateLearned(proposal.proposed);
    if (!std.mem.eql(u8, skill.name, name)) return error.TargetMismatch;
    const old = skills.readMarkdown(ctx.gpa, ctx.io, ctx.skills_dir, name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (old) |text| ctx.gpa.free(text);
    const current = learning.hash(old orelse "");
    if (!std.mem.eql(u8, &current, proposal.old_hash)) return error.StaleProposal;
    try learning.startApply(ctx.db, id, &current, now(ctx));
    _ = try skills.save(ctx.gpa, ctx.io, ctx.skills_dir, proposal.proposed);
    const applied = learning.hash(proposal.proposed);
    try learning.finishApply(ctx.db, id, &applied, now(ctx));
}

fn rollbackSkill(ctx: *tools.Ctx, id: i64) !void {
    var proposal = (try learning.get(ctx.db, ctx.gpa, id)) orelse return error.ProposalNotFound;
    defer proposal.deinit(ctx.gpa);
    if (proposal.status != .applied) return error.BadTransition;
    const name = skillName(proposal.target) orelse return error.NotSkillProposal;
    const applied = proposal.applied_hash orelse return error.NotApplied;
    const current = skills.readMarkdown(ctx.gpa, ctx.io, ctx.skills_dir, name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (current) |text| ctx.gpa.free(text);
    const current_hash = learning.hash(current orelse "");
    if (!std.mem.eql(u8, &current_hash, applied)) return error.StaleProposal;
    try learning.startRollback(ctx.db, id, now(ctx));
    if (proposal.prior_content) |text| {
        _ = try skills.save(ctx.gpa, ctx.io, ctx.skills_dir, text);
    } else {
        try skills.remove(ctx.io, ctx.skills_dir, name);
    }
    try learning.finishRollback(ctx.db, id, now(ctx));
}

fn applyIdentity(ctx: *tools.Ctx, id: i64) !void {
    var proposal = (try learning.get(ctx.db, ctx.gpa, id)) orelse return error.ProposalNotFound;
    defer proposal.deinit(ctx.gpa);
    if (proposal.status != .pending) return error.BadTransition;
    const file = targetFile(proposal.target) orelse return error.NotIdentityProposal;
    const old = identity.read(ctx.gpa, ctx.io, ctx.workspace, file) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (old) |text| ctx.gpa.free(text);
    const current = learning.hash(old orelse "");
    if (!std.mem.eql(u8, &current, proposal.old_hash)) return error.StaleProposal;
    try learning.startApply(ctx.db, id, &current, now(ctx));
    try identity.write(ctx.io, ctx.workspace, file, proposal.proposed);
    const applied = learning.hash(proposal.proposed);
    try learning.finishApply(ctx.db, id, &applied, now(ctx));
}

fn rollbackIdentity(ctx: *tools.Ctx, id: i64) !void {
    var proposal = (try learning.get(ctx.db, ctx.gpa, id)) orelse return error.ProposalNotFound;
    defer proposal.deinit(ctx.gpa);
    if (proposal.status != .applied) return error.BadTransition;
    const file = targetFile(proposal.target) orelse return error.NotIdentityProposal;
    const applied = proposal.applied_hash orelse return error.NotApplied;
    const current = identity.read(ctx.gpa, ctx.io, ctx.workspace, file) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (current) |text| ctx.gpa.free(text);
    const current_hash = learning.hash(current orelse "");
    if (!std.mem.eql(u8, &current_hash, applied)) return error.StaleProposal;
    try learning.startRollback(ctx.db, id, now(ctx));
    if (proposal.prior_content) |text| {
        try identity.write(ctx.io, ctx.workspace, file, text);
    } else {
        try identity.reset(ctx.io, ctx.workspace, file);
    }
    try learning.finishRollback(ctx.db, id, now(ctx));
}

/// Reconciles file writes interrupted between their database phases.
pub fn reconcile(db: *Db, gpa: std.mem.Allocator, io: std.Io, workspace: []const u8, skills_dir: []const u8, at: i64) !void {
    try reconcileStatus(db, gpa, io, workspace, skills_dir, .applying, at);
    try reconcileStatus(db, gpa, io, workspace, skills_dir, .rolling_back, at);
}

fn reconcileStatus(db: *Db, gpa: std.mem.Allocator, io: std.Io, workspace: []const u8, skills_dir: []const u8, status: learning.Status, at: i64) !void {
    const list = try learning.list(db, gpa, status);
    defer {
        for (list) |*proposal| proposal.deinit(gpa);
        gpa.free(list);
    }
    for (list) |*proposal| {
        const current = try contentFor(gpa, io, workspace, skills_dir, proposal.target);
        defer if (current) |text| gpa.free(text);
        const current_hash = learning.hash(current orelse "");
        switch (status) {
            .applying => {
                const proposed_hash = learning.hash(proposal.proposed);
                if (std.mem.eql(u8, &current_hash, &proposed_hash)) {
                    try learning.recoverApply(db, proposal.id, .applied, &proposed_hash, at);
                } else if (std.mem.eql(u8, &current_hash, proposal.old_hash)) {
                    try learning.recoverApply(db, proposal.id, .pending, null, at);
                } else {
                    try learning.recoverApply(db, proposal.id, .quarantined, null, at);
                }
            },
            .rolling_back => {
                const applied = proposal.applied_hash orelse {
                    try learning.recoverRollback(db, proposal.id, .quarantined, at);
                    continue;
                };
                if (std.mem.eql(u8, &current_hash, proposal.old_hash)) {
                    try learning.recoverRollback(db, proposal.id, .rolled_back, at);
                } else if (std.mem.eql(u8, &current_hash, applied)) {
                    try learning.recoverRollback(db, proposal.id, .applied, at);
                } else {
                    try learning.recoverRollback(db, proposal.id, .quarantined, at);
                }
            },
            else => unreachable,
        }
    }
}

fn contentFor(gpa: std.mem.Allocator, io: std.Io, workspace: []const u8, skills_dir: []const u8, target: []const u8) !?[]u8 {
    if (targetFile(target)) |file| {
        return identity.read(gpa, io, workspace, file) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }
    if (skillName(target)) |name| {
        return skills.readMarkdown(gpa, io, skills_dir, name) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }
    return error.UnknownTarget;
}

fn proposalText(gpa: std.mem.Allocator, proposal: *const learning.Proposal) ![]u8 {
    return std.fmt.allocPrint(gpa, "#{d} {s} {s}\nreason: {s}\nevidence: {s}\nold: {s}\nproposed:\n{s}", .{
        proposal.id, @tagName(proposal.status), proposal.target, proposal.reason, proposal.evidence, proposal.old_hash, proposal.proposed,
    });
}

fn parseFile(text: []const u8) !identity.File {
    return std.meta.stringToEnum(identity.File, text) orelse error.BadIdentityFile;
}

fn identityTarget(file: identity.File) []const u8 {
    return switch (file) {
        .soul => "identity-soul",
        .identity => "identity-identity",
        .user => "identity-user",
        .memory => "identity-memory",
    };
}

fn targetFile(target: []const u8) ?identity.File {
    if (std.mem.eql(u8, target, "identity-soul")) return .soul;
    if (std.mem.eql(u8, target, "identity-identity")) return .identity;
    if (std.mem.eql(u8, target, "identity-user")) return .user;
    if (std.mem.eql(u8, target, "identity-memory")) return .memory;
    return null;
}

fn skillName(target: []const u8) ?[]const u8 {
    const prefix = "skill-";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const name = target[prefix.len..];
    return if (skills.validName(name)) name else null;
}

fn now(ctx: *tools.Ctx) i64 {
    return std.Io.Timestamp.now(ctx.io, .real).toSeconds();
}

fn parseId(raw: []const u8) !i64 {
    const id = try std.fmt.parseInt(i64, raw, 10);
    if (id <= 0) return error.BadProposalId;
    return id;
}

test "identity targets are fixed" {
    try std.testing.expectEqual(identity.File.soul, targetFile("identity-soul").?);
    try std.testing.expect(targetFile("../SOUL.md") == null);
}

test "learning evidence must quote the current owner message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db_buf: [160]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &db_buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
    try db.exec("INSERT INTO messages(role, content, owner_text, created) VALUES ('user', 'attachment plus prompt', 'Please remember concise replies.', 1)");
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var ctx: tools.Ctx = .{
        .gpa = std.testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .source_message = db.lastId(),
    };

    try tools.requireOwnerEvidence(&ctx, "concise replies");
    try std.testing.expectError(error.UntrustedEvidence, tools.requireOwnerEvidence(&ctx, "from a web page"));
}

test "reconcile commits an interrupted skill apply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var skills_buf: [192]u8 = undefined;
    const skills_dir = try std.fmt.bufPrint(&skills_buf, "{s}/skills", .{root});
    try std.Io.Dir.cwd().createDirPath(io, skills_dir);

    var db_buf: [192]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &db_buf, "zoro.db"));
    defer db.close();
    try db.initSchema();

    const markdown = "---\nname: weather\ndescription: Forecast\n---\nFetch weather.";
    const id = try learning.create(&db, "skill-weather", null, null, "Owner asked.", "Useful.", null, markdown, 1);
    const old = learning.hash("");
    try learning.startApply(&db, id, &old, 2);
    _ = try skills.save(std.testing.allocator, io, skills_dir, markdown);
    try reconcile(&db, std.testing.allocator, io, root, skills_dir, 3);

    {
        var proposal = (try learning.get(&db, std.testing.allocator, id)).?;
        defer proposal.deinit(std.testing.allocator);
        try std.testing.expectEqual(learning.Status.applied, proposal.status);
    }
    try learning.startRollback(&db, id, 4);
    try skills.remove(io, skills_dir, "weather");
    try reconcile(&db, std.testing.allocator, io, root, skills_dir, 5);

    {
        var proposal = (try learning.get(&db, std.testing.allocator, id)).?;
        defer proposal.deinit(std.testing.allocator);
        try std.testing.expectEqual(learning.Status.rolled_back, proposal.status);
    }
}
