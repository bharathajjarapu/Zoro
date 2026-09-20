# Zoro

Single-owner AI assistant in one Zig binary. Runs as a Telegram daemon or a
terminal CLI, backed by SQLite.

## Stack

| Part | Detail |
|---|---|
| Language | Zig 0.16, no package manager, ~14k LOC |
| Binary | ~2.9 MB stripped (`ReleaseFast`), plus `anydoc` for document extraction |
| Storage | Vendored SQLite (FTS5, trimmed build), SHA-256 pinned in `build.zig` |
| Model | Any OpenAI-compatible endpoint (`LLM_BASE_URL`) |
| Web | TinyFish search/fetch, HTTPS only, private networks blocked |
| Channels | Telegram (owner + private chat only), CLI |

## Features

- **Memory**: facts, messages, and diary in SQLite; FTS5/BM25 recall; facts need owner evidence.
- **Context**: history bounded by rows and bytes, older turns compacted into summaries.
- **Skills and routines**: `SKILL.md` with cron `schedule`, timezone, and `notify`/`safe`/`critical` authority.
- **Delegation**: up to 3 parallel subagents with fresh context and explicit tool lists.
- **Sandboxing**: workspace-confined file tools, `deny`/`allowlist`/`ask` shell, approval-gated identity files.

## Quick start

```sh
cp .env.example .env   # set LLM_API_KEY, LLM_MODEL, TELEGRAM_TOKEN, OWNER_ID, CHAT_ID
zig build -Doptimize=ReleaseFast
zig build test --summary all
./zig-out/bin/zoro            # Telegram daemon
./zig-out/bin/zoro chat       # terminal chat
```

See [DOCUMENTATION.md](DOCUMENTATION.md) for configuration and commands, and
[SECURITY.md](SECURITY.md) for the threat model.
