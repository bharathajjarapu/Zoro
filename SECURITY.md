# Security

Zoro is intended for one owner running their own instance. Its controls reduce accidental access and limit what the agent can do. They do not make a compromised host or provider safe.

## What Zoro protects

- Telegram accepts updates only from the configured owner ID in the configured private chat. Other users, chats, and groups are ignored.
- File tools are restricted to the configured workspace. They reject path traversal and symlinks, cap file sizes, and replace writes atomically. Identity files use an approval path.
- Shell access is off, allowlisted, or approval-based. Commands use fixed executables and JSON arguments, not a shell command string. Keep `ZORO_SHELL=deny` if you do not need shell tools.
- Mutating routines start disabled until approved. Critical routines ask before every run, and missed critical runs are skipped.
- Web fetching requires HTTPS, checks resolved addresses to block private and local networks, and limits response size, redirects, time, and request rate.
- Configuration secrets are redacted by the config formatter. Stored secrets are tied to a host and hidden from the model's secret-name list. Zoro replaces matching values in saved message content after storage, but the original owner text is stored separately and is not scrubbed.

## What to keep in mind

- The model provider receives prompts and any context Zoro sends for a request. Web search and fetch requests go through TinyFish. Review their data handling before use.
- Zoro's SQLite database, including memory and stored secret values, is not encrypted by Zoro. Protect the data directory with operating-system permissions and encrypted disk storage if needed.
- When you submit a secret for storage, Zoro sends it to the model provider once before it can scrub the saved message. Do not submit credentials you cannot share with that provider.
- A local Zoro process runs with the operating-system permissions of its user. The workspace checks are application controls, not a general operating-system sandbox. Rootless Podman with dropped capabilities can add isolation; its protection depends on the host configuration.
- Back up the data directory securely. Anyone who can read it can access saved conversations, memory, and stored secrets.

For a private deployment, use a dedicated OS account, restrict access to `.env` and the data directory, keep dependencies and the host updated, and configure the least shell access you need.
