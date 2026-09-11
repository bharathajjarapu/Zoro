# Zoro

A personal AI orchestrator: one binary, one owner, one channel. It remembers,
schedules, delegates to fresh-context subagents, and asks permission in plain
conversation. Telegram is the product; the terminal is how you develop it.

Written in Zig 0.16 with exactly one vendored C dependency (SQLite).

## Requirements

- Zig **0.16.0** — the 0.16 stdlib differs sharply from 0.15 and from most
  material online.
- A Telegram bot token from [@BotFather](https://t.me/BotFather), your numeric
  Telegram user id, and the chat id of your private chat with the bot.
- An OpenAI-compatible endpoint and key.

Nothing else. No package manager, no runtime downloads.

## Build

```sh
zig build                      # debug binary at zig-out/bin/zoro
zig build -Doptimize=ReleaseFast
zig build test --summary all   # the whole suite
```

The first build compiles the vendored SQLite amalgamation and takes about two
minutes. It is cached after that.

## Configure

Copy `.env.example` to `.env` and fill it in. Environment variables override the
file, so secrets can stay out of it entirely.

| Key | Required | Meaning |
|---|---|---|
| `LLM_API_KEY` | yes | Key for the OpenAI-compatible endpoint |
| `LLM_MODEL` | yes | Model name, e.g. `gpt-4.1-mini` |
| `TELEGRAM_TOKEN` | daemon only | Bot token from BotFather |
| `OWNER_ID` | daemon only | Your numeric Telegram user id |
| `CHAT_ID` | daemon only | The private chat id to serve |
| `LLM_BASE_URL` | no | Defaults to `https://api.openai.com/v1` |
| `LLM_VISION_MODEL` | no | Profile used when you send a picture; defaults to `LLM_MODEL` |
| `ZORO_DATA_DIR` | no | Database, diary and lock file. Default `data` |
| `ZORO_SKILLS_DIR` | no | Where `SKILL.md` files live. Default `skills` |
| `ZORO_WORKSPACE` | no | The only directory files may be read from or attached. Default `workspace` |

An unrecognised `ZORO_*` or `LLM_*` key is logged as a warning rather than
ignored, because a typo in a token name is otherwise silent.

## First run

Start in the terminal — no bot token needed, and the same database:

```sh
zig build
./zig-out/bin/zoro run "remember that my landlord is Priya"
./zig-out/bin/zoro chat
```

Then switch on the daemon:

```sh
./zig-out/bin/zoro          # long-polls Telegram until SIGINT
```

Message the bot from the chat whose id you configured. Anything from another
user or chat is dropped without a reply.

## Commands

| Command | What it does |
|---|---|
| `zoro` | Telegram daemon (default) |
| `zoro run "<prompt>"` | One turn, print the reply, exit |
| `zoro chat` | Interactive REPL, same agent and database |
| `zoro diary [date]` | Print a day's diary (`today`, `yesterday`, or `YYYY-MM-DD`) |
| `zoro memory "<query>"` | BM25 search; prints ref, kind, score |
| `zoro tasks` | Tasks with status, priority, goal, and result |
| `zoro routines` | Routines with status, failures, and skipped runs |
| `zoro --version` | Zoro and SQLite versions |

Inspection commands run while the daemon is running: the single-process lock
covers the Telegram poller, not the database.

## Skills and routines

A skill is a directory under the skills dir holding a `SKILL.md`:

```markdown
---
name: morning-brief
description: Summarize overnight mail and today's calendar
schedule: "0 7 * * *"        # this field is what makes it a routine
timezone: Asia/Kolkata
authority: notify            # notify | safe | critical
allowed-tools: fetch_url recall notify_owner
---

Plain English instructions the agent follows when this runs.
```

Only the name and description are always in context; the body loads on demand.
The agent writes its own skills with `save_skill` — that is the whole
extensibility story. It cannot gain new *capabilities* without a rebuild.

**Authority is enforced, not advisory.** A `notify` routine is handed no tool
that mutates anything. A `safe` or `critical` routine stays switched off until
you approve it in chat, and a `critical` one asks again before every single run.
The tier is read from disk on every tick and checked against your approvals, so
the agent rewriting its own frontmatter to claim a higher tier switches the
routine off rather than promoting it.

Missed runs get one catch-up, never a replay storm, and a missed `critical`
routine is skipped and recorded rather than executed.

## Delegation

The primary hands independent work to at most three subagents at once. Each gets
a fresh context — the parent's messages are not passed — twelve tool rounds, one
retry, and an explicit tool allowlist. Subagents cannot spawn subagents and have
no Telegram access; results go to the primary, which synthesizes and speaks with
one voice.

A subagent with no named tool list is read-only, so the default delegate is a
researcher that cannot touch your files. Send `stop` to cancel everything in
flight — it cancels that batch, not every batch after it. The primary can also call off a
single task and redirect it while the others keep running, and your messages are
answered immediately either way.

Consequential work is verified with a second model call before it is reported as
done; bounded research is not, because paying twice for a summary is waste. A
subagent that fails its success criterion produces one follow-up rather than a
false success.

## Container

Rootless Podman on Debian Slim. The image carries a static binary, a CA bundle
and nothing else — no package manager at runtime.

```sh
podman build -t zoro:latest -f Containerfile .
podman run -d --name zoro \
  --userns=keep-id:uid=10001,gid=10001 \
  --cap-drop=ALL --security-opt=no-new-privileges \
  -v ./data:/data:Z -v ./skills:/skills:Z -v ./workspace:/workspace:Z \
  --env-file .env \
  zoro:latest
```

Image size: **87 MB** (`localhost/zoro:dev`, built 2026-08-21). Restarting
preserves memory, tasks and routines; the agent can read nothing outside its
three mounts.

## Layout

```
src/              the product
  main.zig        process entry point and composition root
  app/            configuration and terminal commands
  agent/          model loop and fresh-context workers
  channel/        Telegram polling, auth, media, and delivery
  data/           SQLite, memory, tasks, secrets, and outbox
  net/            bounded HTTP and guarded web fetching
  automation/     skills, schedules, and routine execution
  tools/          tool registry and implementations
  testing/        shared test support; never reaches the binary
vendor/sqlite3/   pinned, checksummed amalgamation
docs/             ARCHITECTURE.md is the source of truth for design
```

## Not built yet

Two limits from `docs/ARCHITECTURE.md` are designed but not enforced:

- **The daily spend cap.** No ticket covers metering. Every model call, image
  turns included, goes through one path in `src/agent/root.zig`, so it lands in
  one place.
- **The 10 s web request timeout.** Unreachable in Zig 0.16 — `std.http.Client`
  ignores the timeout field it accepts. A hung host stalls that turn and the
  poll loop with it. The 2 MB body cap and per-host rate limit still apply.
