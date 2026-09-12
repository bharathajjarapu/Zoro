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
- A TinyFish API key for web search and fetching.

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
| `TINYFISH_API_KEY` | web tools | Key for TinyFish Search and Fetch |
| `TELEGRAM_TOKEN` | daemon only | Bot token from BotFather |
| `OWNER_ID` | daemon only | Your numeric Telegram user id |
| `CHAT_ID` | daemon only | The private chat id to serve |
| `LLM_BASE_URL` | no | Defaults to `https://api.openai.com/v1` |
| `ZORO_HOME` | no | Stable application root. Default `$XDG_DATA_HOME/zoro` or `$HOME/.local/share/zoro` |
| `ZORO_ENV_FILE` | no | Runtime env file. Default `$ZORO_HOME/.env` |
| `ZORO_DATA_DIR` | no | Database, diary and lock directory. Default `$ZORO_HOME/data` |
| `ZORO_SKILLS_DIR` | no | Skill directory. Default `$ZORO_HOME/skills` |
| `ZORO_WORKSPACE` | no | Guarded file root. Default `$ZORO_HOME/workspace` |
| `ZORO_INBOX_DIR` | no | Telegram inbox inside the workspace |
| `ZORO_TMP_DIR` | no | Temporary runtime files. Default `$ZORO_HOME/tmp` |
| `ZORO_SHELL` | no | `deny`, `allowlist`, or `ask`. Default `ask` |

Relative path overrides resolve under `ZORO_HOME`; absolute overrides stay
absolute. An unrecognised `ZORO_*` or `LLM_*` key logs its name only.
Configuration values are never logged or embedded at build time.

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
| `zoro status` | Recovery state and pending, failed, and uncertain counts |
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
`save_skill` creates a reviewable proposal. Learned skills cannot add tools,
models, schedules, or authority. Applying or rolling back a proposal requires
an exact owner approval. The agent cannot gain new capabilities without a
rebuild.

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
researcher that cannot touch your files. Send `stop` to cancel work in flight.
The primary can stop one task while the others continue.

Consequential work is verified with a second model call before it is reported as
done; bounded research is not, because paying twice for a summary is waste. A
subagent that fails its success criterion produces one follow-up rather than a
false success.

## Container

Rootless Podman on Alpine. The image carries one musl binary, BusyBox `sh`,
`apk`, and CA certificates.

```sh
podman build -t zoro:latest -f Containerfile .
podman run -d --name zoro \
  --userns=keep-id:uid=10001,gid=10001 \
  --cap-drop=ALL --security-opt=no-new-privileges \
  -v ./data:/data:Z -v ./workspace:/workspace:Z \
  --env-file .env \
  zoro:latest
```

Restarting preserves memory, tasks, routines, learning proposals, and queued
delivery. Runtime files stay under `/data`; agent-created files stay under the
guarded `/workspace` mount.

Add future command-line tools with `apk add --no-cache` in the Containerfile.
The running agent is non-root and its shell policy cannot invoke `apk`.

## Workspace and Telegram

File tools use workspace-relative paths, reject traversal and symlinks, cap
reads and downloads, and replace writes atomically. Identity files
(`SOUL.md`, `IDENTITY.md`, `USER.md`, `MEMORY.md`) have a separate approved
update path. The shell accepts JSON argument arrays, uses pinned executables and
a clean environment, and kills the process group on timeout or cancellation.

Telegram uses long polling for one private owner chat. Accepted updates and
outgoing messages are durable. Internal work and recovery state stays out of
the chat. It supports natural typing indicators, `/stop`, conservative HTML,
bounded message splitting, callbacks, native media sends, guarded incoming
files, locations, stickers, and BotFather commands.
Static sticker images and ordinary photos use the configured base model's image
input. Voice and other media are saved; transcription requires an explicitly
supported model path.

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
```

## Limits

Web and model calls have total deadlines, bounded bodies, cancellation, SSRF
checks, and shared rate limits. TinyFish remains the search and fetch service;
its pricing and quotas can change. Zoro does not install packages or execute
learned code. Daily model-spend metering is not implemented.
