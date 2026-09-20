# Documentation

## Requirements

- Zig 0.16.0
- A model API key and model name for an OpenAI-compatible endpoint
- A TinyFish API key for web search and fetching
- For Telegram, a bot token, your Telegram user ID, and the ID of your private chat

## Build and run

```sh
zig build
./zig-out/bin/zoro run "remember that my landlord is Priya"
./zig-out/bin/zoro chat
./zig-out/bin/zoro
```

The first command builds the debug binary. `zoro` starts the Telegram daemon. The terminal commands use the same database as the daemon.

For an optimized build and the test suite:

```sh
zig build -Doptimize=ReleaseFast
zig build test --summary all
```

## Configuration

Copy `.env.example` to `.env`, or set the values in your environment. Environment variables override the file.

| Variable | Required | Purpose |
|---|---|---|
| `LLM_API_KEY` | Yes | Model provider key |
| `LLM_MODEL` | Yes | Model name |
| `TINYFISH_API_KEY` | For web tools | TinyFish key |
| `TELEGRAM_TOKEN` | For Telegram | Bot token |
| `OWNER_ID` | For Telegram | Your numeric Telegram user ID |
| `CHAT_ID` | For Telegram | The private chat ID Zoro serves |
| `LLM_BASE_URL` | No | Defaults to `https://api.openai.com/v1` |
| `ZORO_HOME` | No | Data root. Defaults to `$XDG_DATA_HOME/zoro` or `$HOME/.local/share/zoro` |
| `ZORO_SHELL` | No | `deny`, `allowlist`, or `ask`. Defaults to `ask` |

Other path settings include `ZORO_DATA_DIR`, `ZORO_ENV_FILE`, `ZORO_SKILLS_DIR`, `ZORO_WORKSPACE`, `ZORO_INBOX_DIR`, and `ZORO_TMP_DIR`. Relative paths resolve under `ZORO_HOME`, except the inbox, which must stay inside the workspace.

## Memory and conversations

Zoro stores memory, diary entries, tasks, routines, and the message queue in SQLite under its data directory. `remember` stores facts from exact owner messages. Conflicting inferred facts do not replace saved facts. `recall` searches with FTS5 and BM25; `/memory` searches from Telegram. `/forget` is available as an agent tool.

Conversation history is bounded by rows and bytes. Zoro can compact older turns into a summary and diary entry. `/compact` compacts on request. `/clear` and `/new` save a summary, then start a fresh conversation.

## Telegram commands

| Command | Purpose |
|---|---|
| `/help` | List commands |
| `/status` | Show work and delivery state |
| `/tasks`, `/routines` | List delegated work and routines |
| `/memory`, `/diary` | Search memory or read the diary |
| `/skills`, `/character`, `/learn` | Inspect skills, character, or learning proposals |
| `/model <name>` | Set the model used for work |
| `/cache` | Show provider-reported prompt cache rates |
| `/compact` | Summarize older conversation turns |
| `/clear`, `/new` | Save a summary and start a new conversation |
| `/stop` | Cancel current work |
| `/learn sticker <alias>`, `/stickers`, `/sticker <alias>` | Save or use a sticker alias |

The CLI also has `diary`, `memory`, `tasks`, `routines`, `status`, and `--version` commands. Run `zoro` without arguments for the daemon.

## Skills and routines

A skill is a directory containing `SKILL.md` in the skills directory. A `schedule` field makes it a routine. Skills describe actions in plain text and can declare a timezone, authority, and allowed tools.

```markdown
---
name: morning-brief
description: Summarize today's forecast
schedule: "0 7 * * *"
timezone: Asia/Kolkata
authority: notify
---

Write a short forecast for today.
```

The four built-in skills are installed only when missing: `weather-watch`, `rss-watch`, `html-report`, and `publish-static`. Learned skills cannot grant tools, schedules, models, or authority. Saving one creates a proposal that needs owner approval before it is applied.

`notify` routines receive no mutating tools. `safe` and `critical` routines start disabled until approved. A `critical` routine asks for approval before each run. Missed routine runs get at most one catch-up; missed critical runs are skipped.

## Delegation and tools

The primary agent can run up to three independent subagents at once. Each starts with a fresh context, a bounded number of tool rounds, and an explicit tool list. A worker without named tools is read-only. Workers cannot spawn workers or send Telegram messages.

File tools stay inside the configured workspace, reject traversal and symlinks, limit file sizes, and write files atomically. Identity files such as `SOUL.md`, `IDENTITY.md`, `USER.md`, and `MEMORY.md` use a separate approval path. See [SECURITY.md](SECURITY.md) for more detail.

Photos, image documents, and static stickers can be sent to the configured model if it supports image input. Telegram files up to 20 MiB are saved in the workspace inbox. Zoro can extract text from PDF, Office, OpenDocument, RTF, EPUB, and CSV files. Scanned PDFs need OCR. Voice, audio, video, and animated files are saved, but reading their contents requires a supported transcription or video path.

## Command reference

| Command | Purpose |
|---|---|
| `zoro` | Run the Telegram daemon until SIGINT |
| `zoro run "<prompt>"` | Run one turn and exit |
| `zoro chat` | Start the interactive terminal chat |
| `zoro diary [today\|yesterday\|YYYY-MM-DD]` | Print a diary entry |
| `zoro memory "<query>"` | Search saved memory |
| `zoro tasks`, `zoro routines` | List tasks or routines |
| `zoro status` | Show recovery and delivery state |
| `zoro --version` | Print Zoro and SQLite versions |

These inspection commands can run while the daemon is active. The single-process lock applies to the Telegram poller.

## Container

The included Containerfile builds an Alpine image. This example runs it as a non-root user with dropped Linux capabilities and mounts persistent data and workspace directories:

```sh
podman build -t zoro:latest -f Containerfile .
podman run -d --name zoro \
  --userns=keep-id:uid=10001,gid=10001 \
  --cap-drop=ALL --security-opt=no-new-privileges \
  -v ./data:/data:Z -v ./workspace:/workspace:Z \
  --env-file .env \
  zoro:latest
```

Container isolation depends on the Podman host configuration. Keep the mounted data and workspace directories private.

## Current limits

- Model and web requests go to the configured providers. TinyFish pricing and quotas may change.
- Zoro does not install packages or execute learned code.
- Schema migrations are not included before production. Use a fresh data directory after schema changes.
- Daily model-spend metering is not implemented.
