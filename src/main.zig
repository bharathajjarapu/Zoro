const std = @import("std");
const c = @import("c");
const config = @import("app/config.zig");
const Db = @import("data/db.zig").Db;
const agent = @import("agent/root.zig");
const cli = @import("app/cli.zig");
const telegram = @import("channel/telegram.zig");
const tools = @import("tools/root.zig");
const scheduler = @import("automation/scheduler.zig");
const worker = @import("agent/worker.zig");
const http = @import("net/http.zig");

const log = std.log.scoped(.zoro);

/// Kept in step with `build.zig.zon` by hand.
const version = "0.0.0";

/// Zig supplies process memory, arguments, and I/O.
pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // Already reported in the owner's terms; a stack trace would only bury it.
        error.MissingConfig, error.ChatHttp, error.TelegramApiError, error.TelegramHttp, error.InvalidTelegramToken => std.process.exit(1),
        error.AlreadyRunning => std.process.exit(2),
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse return daemon(init);

    const eql = std.mem.eql;
    if (eql(u8, cmd, "--version")) return print(init.io, "zoro {s} (sqlite {s})\n", .{ version, sqliteVersion() });
    if (eql(u8, cmd, "help") or eql(u8, cmd, "--help")) return print(init.io, usage, .{});
    if (eql(u8, cmd, "run")) return cmdRun(init, &args);
    if (eql(u8, cmd, "chat")) return cmdChat(init);
    if (eql(u8, cmd, "diary")) return cmdDiary(init, &args);
    if (eql(u8, cmd, "memory")) return cmdMemory(init, &args);
    if (eql(u8, cmd, "tasks")) return cmdTasks(init);
    if (eql(u8, cmd, "routines")) return cmdRoutines(init);

    log.err("unknown command: {s}", .{cmd});
    try print(init.io, usage, .{});
    std.process.exit(2);
}

const usage =
    \\usage:
    \\  zoro            run the Telegram daemon
    \\  zoro run PROMPT one-shot turn, print the reply, exit
    \\  zoro chat       interactive REPL (same agent, same database)
    \\  zoro diary [DATE]  print a day's diary (today if omitted)
    \\  zoro memory QUERY  BM25 search; prints ref, kind, score
    \\  zoro tasks      list tasks with status, priority, and goal
    \\  zoro routines   list routines with status, failures, and skipped runs
    \\  zoro --version  print the zoro and SQLite versions
    \\  zoro help       print this
    \\
;

fn daemon(init: std.process.Init) !void {
    var cfg = try config.load(init.gpa, init.io, ".env");
    defer cfg.deinit(init.gpa);
    cfg.overlay(init.environ_map);

    const token = cfg.telegram_token orelse return config.missing("TELEGRAM_TOKEN");
    const owner_id = cfg.owner_id orelse return config.missing("OWNER_ID");
    const chat_id = cfg.chat_id orelse return config.missing("CHAT_ID");
    if (cfg.api_key == null) return config.missing("LLM_API_KEY");
    if (cfg.model == null) return config.missing("LLM_MODEL");

    const diary_dir = try diaryDir(init, cfg);

    var db = try openDb(init.io, cfg.data_dir);
    defer db.close();
    try db.migrate();

    var lock = try telegram.tryLock(init.io, cfg.data_dir) orelse {
        log.err("telegram already running on this machine", .{});
        return error.AlreadyRunning;
    };
    defer lock.close(init.io);

    var client = http.StdHttp.init(init.gpa, init.io);
    defer client.deinit();

    var crew: Crew = undefined;
    try crew.init(init, cfg, &db);
    defer crew.deinit();

    var a = makeAgent(init, cfg, &db, &client, diary_dir);
    a.workers = &crew.pool.state;
    a.pool = &crew.pool;
    var bot: telegram.Bot = .{
        .gpa = init.gpa,
        .io = init.io,
        .http = client.http(),
        .db = &db,
        .agent = &a,
        .token = token,
        .owner_id = owner_id,
        .chat_id = chat_id,
        .fetch = client.getter(),
        .workspace = cfg.workspace,
    };

    bot.getMe() catch |err| {
        log.err("telegram refused the token ({t}); check TELEGRAM_TOKEN", .{err});
        return err;
    };
    stop.install();

    var sched_db = try openDb(init.io, cfg.data_dir);
    defer sched_db.close();
    var sched_http = http.StdHttp.init(init.gpa, init.io);
    defer sched_http.deinit();
    var sched_agent = makeAgent(init, cfg, &sched_db, &sched_http, diary_dir);
    const sched = try std.Thread.spawn(.{}, scheduler.loop, .{ &sched_agent, &stop.requested });
    defer sched.join();

    log.info("polling", .{});
    try bot.run(&stop.requested);
    log.info("shutting down", .{});
}

/// run/chat: no Telegram token; the operator is the owner.
fn cmdRun(init: std.process.Init, args: anytype) !void {
    var buf: [cli.max_prompt]u8 = undefined;
    const prompt = cli.takePrompt(&buf, args) catch {
        log.err("prompt longer than {d} bytes", .{cli.max_prompt});
        std.process.exit(2);
    } orelse {
        try print(init.io, usage, .{});
        std.process.exit(2);
    };

    var t: Terminal = undefined;
    try t.init(init);
    defer t.deinit();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    try cli.oneShot(&t.agent, prompt, &out.interface);
}

fn cmdChat(init: std.process.Init) !void {
    var t: Terminal = undefined;
    try t.init(init);
    defer t.deinit();

    var in_buf: [cli.max_prompt]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err_buf: [256]u8 = undefined;
    var err_out = std.Io.File.stderr().writer(init.io, &err_buf);
    try cli.chat(&t.agent, &in.interface, &out.interface, &err_out.interface);
}

/// Inspection only: WAL lets this run while the daemon holds the poller lock.
fn cmdDiary(init: std.process.Init, args: anytype) !void {
    var s: Store = undefined;
    var out = try s.open(init);
    defer s.deinit();

    const date = args.next();
    const now = std.Io.Timestamp.now(init.io, .real).toSeconds();
    try cli.printDiary(init.gpa, init.io, try diaryDir(init, s.cfg), date, now, &out.interface);
}

fn cmdMemory(init: std.process.Init, args: anytype) !void {
    var buf: [cli.max_prompt]u8 = undefined;
    const query = cli.takePrompt(&buf, args) catch {
        log.err("query longer than {d} bytes", .{cli.max_prompt});
        std.process.exit(2);
    } orelse {
        try print(init.io, usage, .{});
        std.process.exit(2);
    };

    var s: Store = undefined;
    var out = try s.open(init);
    defer s.deinit();

    const now = std.Io.Timestamp.now(init.io, .real).toSeconds();
    try cli.printMemory(&s.db, init.gpa, query, now, &out.interface);
}

fn cmdTasks(init: std.process.Init) !void {
    var s: Store = undefined;
    var out = try s.open(init);
    defer s.deinit();
    try cli.printTasks(&s.db, init.gpa, &out.interface);
}

fn cmdRoutines(init: std.process.Init) !void {
    var s: Store = undefined;
    var out = try s.open(init);
    defer s.deinit();
    try cli.printRoutines(&s.db, &out.interface);
}

/// Each worker owns its database and HTTP client.
const Crew = struct {
    dbs: [worker.max_live]Db = undefined,
    https: [worker.max_live]http.StdHttp = undefined,
    open: usize = 0,
    pool: worker.Pool = undefined,

    fn init(self: *Crew, p: std.process.Init, cfg: config.Config, db: *Db) !void {
        self.open = 0;
        errdefer self.closeOpen();
        const diary_dir = try diaryDir(p, cfg);

        var protos: [worker.max_live]agent.Agent = undefined;
        for (&self.dbs, &self.https, &protos) |*wdb, *h, *proto| {
            wdb.* = try openDb(p.io, cfg.data_dir);
            self.open += 1;
            h.* = http.StdHttp.init(p.gpa, p.io);
            proto.* = makeAgent(p, cfg, wdb, h, diary_dir);
        }
        self.pool = worker.Pool.init(p.gpa, db, protos);
    }

    fn deinit(self: *Crew) void {
        self.pool.deinit();
        self.closeOpen();
    }

    fn closeOpen(self: *Crew) void {
        for (self.dbs[0..self.open], self.https[0..self.open]) |*wdb, *h| {
            h.deinit();
            wdb.close();
        }
        self.open = 0;
    }
};

const Terminal = struct {
    store: Store,
    http: http.StdHttp,
    crew: Crew,
    agent: agent.Agent,

    fn init(self: *Terminal, p: std.process.Init) !void {
        try self.store.init(p);
        errdefer self.store.deinit();
        if (self.store.cfg.api_key == null) return config.missing("LLM_API_KEY");
        if (self.store.cfg.model == null) return config.missing("LLM_MODEL");

        self.http = http.StdHttp.init(p.gpa, p.io);
        errdefer self.http.deinit();

        try self.crew.init(p, self.store.cfg, &self.store.db);
        errdefer self.crew.deinit();

        self.agent = makeAgent(p, self.store.cfg, &self.store.db, &self.http, try diaryDir(p, self.store.cfg));
        self.agent.workers = &self.crew.pool.state;
        self.agent.pool = &self.crew.pool;
    }

    fn deinit(self: *Terminal) void {
        self.crew.deinit();
        self.http.deinit();
        self.store.deinit();
        self.* = undefined;
    }
};

const Store = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    db: Db,
    out_buf: [4096]u8 = undefined,

    fn init(self: *Store, p: std.process.Init) !void {
        self.gpa = p.gpa;
        self.cfg = try config.load(p.gpa, p.io, ".env");
        errdefer self.cfg.deinit(self.gpa);
        self.cfg.overlay(p.environ_map);
        self.db = try openDb(p.io, self.cfg.data_dir);
        errdefer self.db.close();
        try self.db.migrate();
    }

    /// The returned writer borrows `self.out_buf`.
    fn open(self: *Store, p: std.process.Init) !std.Io.File.Writer {
        try self.init(p);
        return std.Io.File.stdout().writer(p.io, &self.out_buf);
    }

    fn deinit(self: *Store) void {
        self.db.close();
        self.cfg.deinit(self.gpa);
        self.* = undefined;
    }
};

/// The process arena owns the returned path.
fn diaryDir(p: std.process.Init, cfg: config.Config) ![]const u8 {
    return std.fmt.allocPrint(p.arena.allocator(), "{s}/diary", .{cfg.data_dir});
}

/// Requires checked API key and model values.
fn makeAgent(p: std.process.Init, cfg: config.Config, db: *Db, client: *http.StdHttp, diary: []const u8) agent.Agent {
    return .{
        .gpa = p.gpa,
        .io = p.io,
        .db = db,
        .http = client.http(),
        .api_key = cfg.api_key.?,
        .base_url = cfg.base_url orelse agent.default_base_url,
        .model = cfg.model.?,
        .tools = &tools.builtins,
        .workspace = cfg.workspace,
        .skills_dir = cfg.skills_dir,
        .diary_dir = diary,
        .web_api = client.webApi(),
        .tinyfish_key = cfg.tinyfish_key,
    };
}

fn openDb(io: std.Io, dir: []const u8) !Db {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return Db.open(try std.fmt.bufPrintZ(&buf, "{s}/zoro.db", .{dir}));
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var file = std.Io.File.stdout().writer(io, &buf);
    try file.interface.print(fmt, args);
    try file.interface.flush();
}

/// Signal handlers require process-global shutdown state.
const stop = struct {
    var flag: std.atomic.Value(bool) = .init(false);

    fn install() void {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }

    /// Async-signal-safe: one atomic store and nothing else.
    fn onSignal(_: std.posix.SIG) callconv(.c) void {
        flag.store(true, .release);
    }

    fn requested() bool {
        return flag.load(.acquire);
    }

    /// Restores default signal behavior after tests.
    fn restoreDefault() void {
        flag.store(false, .release);
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }
};

/// SQLITE_OMIT_AUTOINIT means nothing initialises SQLite for us.
fn sqliteVersion() []const u8 {
    _ = c.sqlite3_initialize();
    return std.mem.span(c.sqlite3_libversion());
}

test "sqlite is linked with fts5 and bm25" {
    _ = c.sqlite3_initialize();

    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    defer _ = c.sqlite3_close(db);

    const setup =
        \\CREATE VIRTUAL TABLE chunks USING fts5(text, tokenize='porter');
        \\INSERT INTO chunks(text) VALUES('booked the appointment for tuesday');
    ;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, setup, null, null, null));

    // Porter handles inflections, not synonyms.
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT bm25(chunks) FROM chunks WHERE chunks MATCH 'appointments'";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);

    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expect(c.sqlite3_column_double(stmt, 0) < 0); // bm25 scores are negative
}

test "sqlite reports the pinned version" {
    try std.testing.expectEqualStrings("3.51.0", sqliteVersion());
}

test {
    _ = @import("data/db.zig");
    _ = @import("app/config.zig");
    _ = @import("agent/root.zig");
    _ = @import("app/cli.zig");
    _ = @import("channel/telegram.zig");
    _ = @import("data/memory.zig");
    _ = @import("tools/root.zig");
    _ = @import("automation/skills.zig");
    _ = @import("net/web.zig");
    _ = @import("data/secrets.zig");
    _ = @import("data/tasks.zig");
    _ = @import("automation/scheduler.zig");
    _ = @import("automation/cron.zig");
    _ = @import("data/outbox.zig");
    _ = @import("agent/worker.zig");
    _ = @import("net/http.zig");
}

test "a signal asks for shutdown instead of killing the process" {
    stop.install();
    defer stop.restoreDefault();

    try std.testing.expect(!stop.requested());
    try std.posix.raise(.INT);
    try std.testing.expect(stop.requested());
}
