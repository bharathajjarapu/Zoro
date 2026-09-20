---
name: publish-static
description: Temporarily publish one completed static folder through Cloudflare
---

Publish only a dedicated workspace folder containing a completed `index.html`.
Inspect it first. Refuse secrets, credentials, personal identifiers not intended
for sharing, `.part` files, directory escapes, or downloaded untrusted HTML.

Cloudflare Drop has no documented direct upload API for this client. Follow its
official agent path with owner-installed Wrangler 4.102.0 or later. Never run
`npm`, `npx`, or install packages. Use exactly:

`wrangler deploy <folder> --name <short-name> --temporary --compatibility-date <today-YYYY-MM-DD>`

The `shell` tool will request approval because this makes content public. After
approval, verify the live `workers.dev` URL with `watch_url`. Return both the
live URL and claim URL. Treat the claim URL as a sensitive bearer credential,
show it only to the owner, never save it to memory or diary, and state that it
expires after 60 minutes. If Wrangler is unavailable, report that single
prerequisite; do not substitute an undocumented endpoint.
