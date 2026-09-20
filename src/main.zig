const std = @import("std");
const sqlite = @import("c");
const config = @import("app/config.zig");
const Db = @import("data/db.zig").Db;
const task_data = @import("data/tasks.zig");
const agent = @import("agent/root.zig");
const cli = @import("channel/cli.zig");
const telegram = @import("channel/telegram.zig");
const tools = @import("tools/root.zig");
const learning_tools = @import("tools/learning.zig");
const scheduler = @import("automation/scheduler.zig");
const default_skills = @import("automation/defaults.zig");
const worker = @import("agent/worker.zig");
const http = @import("net/http.zig");

const log = std.log.scoped(.zoro);

/// Kept in step with `build.zig.zon` by hand.
const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // Already reported in the owner's terms; a stack trace would only bury it.
        error.MissingConfig, error.ChatHttp, error.TelegramApiError, error.TelegramHttp, error.TelegramRejected, error.InvalidTelegramToken => std.process.exit(1),
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
    if (eql(u8, cmd, "status")) return cmdStatus(init);

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
    \\  zoro status     report recovery state and counts
    \\  zoro --version  print the zoro and SQLite versions
    \\  zoro help       print this
    \\
;

fn daemon(init: std.process.Init) !void {
    var cfg = try config.loadRuntime(init.gpa, init.io, init.environ_map);
    defer cfg.deinit(init.gpa);
    try createRuntimeDirs(init.gpa, init.io, cfg);

    const token = cfg.telegram_token orelse return config.missing("TELEGRAM_TOKEN");
    const owner_id = cfg.owner_id orelse return config.missing("OWNER_ID");
    const chat_id = cfg.chat_id orelse return config.missing("CHAT_ID");
    if (cfg.api_key == null) return config.missing("LLM_API_KEY");
    if (cfg.model == null) return config.missing("LLM_MODEL");

    const diary_dir = try diaryDir(init, cfg);

    var db = try openDb(init.io, cfg.data_dir);
    defer db.close();
    try db.initSchema();

    var lock = try telegram.tryLock(init.io, cfg.data_dir) orelse {
        log.err("telegram already running on this machine", .{});
        return error.AlreadyRunning;
    };
    defer lock.close(init.io);
    try task_data.recoverApprovals(&db, std.math.maxInt(i64));
    try learning_tools.reconcile(&db, init.gpa, init.io, cfg.workspace, cfg.skills_dir, std.Io.Timestamp.now(init.io, .real).toSeconds());

    var client = http.StdHttp.init(init.gpa, init.io);
    defer client.deinit();
    var live_client = http.StdHttp.init(init.gpa, init.io);
    defer live_client.deinit();

    var limiter: @import("net/web.zig").Limiter = .{};
    var crew: Crew = undefined;
    try crew.init(init, cfg, &db, &limiter);
    defer crew.deinit();

    var assistant = makeAgent(init, cfg, &db, &client, diary_dir, &limiter);
    assistant.workers = &crew.pool.state;
    assistant.pool = &crew.pool;
    var bot: telegram.Bot = .{
        .gpa = init.gpa,
        .io = init.io,
        .http = client.http(),
        .live_http = live_client.http(),
        .db = &db,
        .agent = &assistant,
        .token = token,
        .owner_id = owner_id,
        .chat_id = chat_id,
        .fetch = client.getter(),
        .workspace = cfg.workspace,
        .inbox = try cfg.inboxRelative(),
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
    var sched_agent = makeAgent(init, cfg, &sched_db, &sched_http, diary_dir, &limiter);
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

    var terminal: Terminal = undefined;
    try terminal.init(init);
    defer terminal.deinit();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    try cli.oneShot(&terminal.agent, prompt, &out.interface);
}

fn cmdChat(init: std.process.Init) !void {
    var terminal: Terminal = undefined;
    try terminal.init(init);
    defer terminal.deinit();

    var in_buf: [cli.max_prompt]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err_buf: [256]u8 = undefined;
    var err_out = std.Io.File.stderr().writer(init.io, &err_buf);
    try cli.chat(&terminal.agent, &in.interface, &out.interface, &err_out.interface);
}

/// Inspection only: WAL lets this run while the daemon holds the poller lock.
fn cmdDiary(init: std.process.Init, args: anytype) !void {
    var store: Store = undefined;
    var out = try store.open(init);
    defer store.deinit();

    const date = args.next();
    const now = std.Io.Timestamp.now(init.io, .real).toSeconds();
    try cli.printDiary(init.gpa, init.io, try diaryDir(init, store.cfg), date, now, &out.interface);
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

    var store: Store = undefined;
    var out = try store.open(init);
    defer store.deinit();

    const now = std.Io.Timestamp.now(init.io, .real).toSeconds();
    try cli.printMemory(&store.db, init.gpa, query, now, &out.interface);
}

fn cmdTasks(init: std.process.Init) !void {
    var store: Store = undefined;
    var out = try store.open(init);
    defer store.deinit();
    try cli.printTasks(&store.db, init.gpa, &out.interface);
}

fn cmdRoutines(init: std.process.Init) !void {
    var store: Store = undefined;
    var out = try store.open(init);
    defer store.deinit();
    try cli.printRoutines(&store.db, &out.interface);
}

fn cmdStatus(init: std.process.Init) !void {
    var store: Store = undefined;
    var out = try store.open(init);
    defer store.deinit();
    try cli.printStatus(&store.db, &out.interface);
}

/// Each worker owns its database and HTTP client.
const Crew = struct {
    dbs: [worker.max_live]Db = undefined,
    https: [worker.max_live]http.StdHttp = undefined,
    open: usize = 0,
    pool: worker.Pool = undefined,

    fn init(self: *Crew, process: std.process.Init, cfg: config.Config, db: *Db, limiter: *@import("net/web.zig").Limiter) !void {
        self.open = 0;
        errdefer self.closeOpen();
        const diary_dir = try diaryDir(process, cfg);

        var protos: [worker.max_live]agent.Agent = undefined;
        for (&self.dbs, &self.https, &protos) |*database, *client, *proto| {
            database.* = try openDb(process.io, cfg.data_dir);
            self.open += 1;
            client.* = http.StdHttp.init(process.gpa, process.io);
            proto.* = makeAgent(process, cfg, database, client, diary_dir, limiter);
        }
        self.pool = worker.Pool.init(process.gpa, db, protos);
    }

    fn deinit(self: *Crew) void {
        self.pool.deinit();
        self.closeOpen();
    }

    fn closeOpen(self: *Crew) void {
        for (self.dbs[0..self.open], self.https[0..self.open]) |*database, *client| {
            client.deinit();
            database.close();
        }
        self.open = 0;
    }
};

const Terminal = struct {
    store: Store,
    io: std.Io,
    lock: std.Io.File,
    http: http.StdHttp,
    crew: Crew,
    limiter: @import("net/web.zig").Limiter,
    agent: agent.Agent,

    fn init(self: *Terminal, process: std.process.Init) !void {
        self.io = process.io;
        try self.store.init(process);
        errdefer self.store.deinit();
        self.lock = try telegram.tryLock(process.io, self.store.cfg.data_dir) orelse return error.AlreadyRunning;
        errdefer self.lock.close(process.io);
        try task_data.recoverApprovals(&self.store.db, std.math.maxInt(i64));
        try learning_tools.reconcile(&self.store.db, process.gpa, process.io, self.store.cfg.workspace, self.store.cfg.skills_dir, std.Io.Timestamp.now(process.io, .real).toSeconds());
        if (self.store.cfg.api_key == null) return config.missing("LLM_API_KEY");
        if (self.store.cfg.model == null) return config.missing("LLM_MODEL");

        self.http = http.StdHttp.init(process.gpa, process.io);
        errdefer self.http.deinit();

        self.limiter = .{};
        try self.crew.init(process, self.store.cfg, &self.store.db, &self.limiter);
        errdefer self.crew.deinit();

        self.agent = makeAgent(process, self.store.cfg, &self.store.db, &self.http, try diaryDir(process, self.store.cfg), &self.limiter);
        self.agent.workers = &self.crew.pool.state;
        self.agent.pool = &self.crew.pool;
    }

    fn deinit(self: *Terminal) void {
        self.crew.deinit();
        self.http.deinit();
        self.lock.close(self.io);
        self.store.deinit();
        self.* = undefined;
    }
};

const Store = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    db: Db,
    out_buf: [4096]u8 = undefined,

    fn init(self: *Store, process: std.process.Init) !void {
        self.gpa = process.gpa;
        self.cfg = try config.loadRuntime(process.gpa, process.io, process.environ_map);
        errdefer self.cfg.deinit(self.gpa);
        try createRuntimeDirs(process.gpa, process.io, self.cfg);
        self.db = try openDb(process.io, self.cfg.data_dir);
        errdefer self.db.close();
        try self.db.initSchema();
    }

    /// The returned writer borrows `self.out_buf`.
    fn open(self: *Store, process: std.process.Init) !std.Io.File.Writer {
        try self.init(process);
        return std.Io.File.stdout().writer(process.io, &self.out_buf);
    }

    fn deinit(self: *Store) void {
        self.db.close();
        self.cfg.deinit(self.gpa);
        self.* = undefined;
    }
};

/// The process arena owns the returned path.
fn diaryDir(process: std.process.Init, cfg: config.Config) ![]const u8 {
    return std.fmt.allocPrint(process.arena.allocator(), "{s}/diary", .{cfg.data_dir});
}

/// Requires checked API key and model values.
fn makeAgent(process: std.process.Init, cfg: config.Config, db: *Db, client: *http.StdHttp, diary: []const u8, limiter: *@import("net/web.zig").Limiter) agent.Agent {
    return .{
        .gpa = process.gpa,
        .io = process.io,
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
        .fetch = client.getter(),
        .tinyfish_key = cfg.tinyfish_key,
        .shared_limiter = limiter,
        .shell_mode = cfg.shell_mode,
    };
}

fn createRuntimeDirs(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !void {
    for ([_][]const u8{ cfg.data_dir, cfg.workspace, cfg.skills_dir, cfg.tmp_dir }) |path| {
        try std.Io.Dir.cwd().createDirPath(io, path);
    }
    try default_skills.install(gpa, io, cfg.skills_dir);
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
    _ = sqlite.sqlite3_initialize();
    return std.mem.span(sqlite.sqlite3_libversion());
}

test "sqlite is linked with fts5 and bm25" {
    _ = sqlite.sqlite3_initialize();

    var db: ?*sqlite.sqlite3 = null;
    try std.testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_open(":memory:", &db));
    defer _ = sqlite.sqlite3_close(db);

    const setup =
        \\CREATE VIRTUAL TABLE chunks USING fts5(text, tokenize='porter');
        \\INSERT INTO chunks(text) VALUES('booked the appointment for tuesday');
    ;
    try std.testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_exec(db, setup, null, null, null));

    // Porter handles inflections, not synonyms.
    var stmt: ?*sqlite.sqlite3_stmt = null;
    const sql = "SELECT bm25(chunks) FROM chunks WHERE chunks MATCH 'appointments'";
    try std.testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer _ = sqlite.sqlite3_finalize(stmt);

    try std.testing.expectEqual(sqlite.SQLITE_ROW, sqlite.sqlite3_step(stmt));
    try std.testing.expect(sqlite.sqlite3_column_double(stmt, 0) < 0); // bm25 scores are negative
}

test "sqlite reports the pinned version" {
    try std.testing.expectEqualStrings("3.51.0", sqliteVersion());
}

test {
    _ = @import("data/db.zig");
    _ = @import("app/config.zig");
    _ = @import("agent/root.zig");
    _ = @import("channel/cli.zig");
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
    _ = @import("app/workspace.zig");
    _ = @import("data/identity.zig");
    _ = @import("data/learning.zig");
    _ = @import("tools/workspace.zig");
    _ = @import("tools/shell.zig");
}

test "a signal asks for shutdown instead of killing the process" {
    stop.install();
    defer stop.restoreDefault();

    try std.testing.expect(!stop.requested());
    try std.posix.raise(.INT);
    try std.testing.expect(stop.requested());
}
