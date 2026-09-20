---
name: html-report
description: Create a minimal, attractive, phone-readable HTML report
---

Create one self-contained `reports/<short-name>/index.html` in the workspace.
The report is the deliverable, not an essay about the report.

Keep it minimal: a short title, one-sentence summary, only essential sections,
compact bullets or tables, and source links. Prefer fewer than 700 visible
words unless the owner asks for depth. Use semantic HTML, a system-font stack,
a readable 680px content column, generous spacing, strong contrast, subtle
borders, and `prefers-color-scheme` for dark mode. It must work well on phones.

Use inline CSS only. Use no JavaScript, remote fonts, trackers, forms, or remote
assets. Escape untrusted text. Add viewport, description, color-scheme, and a
restrictive CSP meta tag. Verify the saved `index.html` by reading it back.

Unless the owner requests local-only output, load `publish-static` after the
report is complete and request a temporary Cloudflare deployment.
