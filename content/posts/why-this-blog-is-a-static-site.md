---
title: "Why this blog is a static site"
date: 2026-11-20T18:30:00+08:00
description: "No database, no admin panel, nothing to patch. Here is the trade-off."
tags: ["hugo", "static-site", "security"]
---

A blog about hardening servers should not itself be the softest target in the stack. That ruled out the obvious choice.

## What we skipped

A conventional blog engine means a PHP or Node runtime, a database, an admin login, a plugin ecosystem and a steady stream of security releases. All of that exists to render text that changes a few times a month.

For a site of this size, that is a poor trade. A static site has no runtime at request time: the web server opens a file and sends it. There is no login to brute-force, no query to inject into, no upload directory to leave executable.

## What we use

- **Hugo** renders Markdown into HTML. One self-contained binary, sub-second builds.
- **Git** stores every post as a plain `.md` file, so history and rollbacks are free.
- **GitHub Actions** builds the site on every push to `main`.
- **GitHub Pages** serves the output over HTTPS from a CDN.

The content pipeline is literally:

```bash
hugo new content posts/why-static.md
# edit the file
git add -A && git commit -m "post: why static" && git push
```

## The trade-offs, honestly

| Static site | Conventional CMS |
|---|---|
| No in-browser editor by default | Rich admin UI |
| Rebuild required for every change | Instant publish |
| Comments need a third party | Built in |
| Nothing to patch | Patch treadmill |

The first two are solved if you are comfortable in a terminal, or by adding a git-based CMS later. The third is a feature here: if you want to reply, email works.

## Hosting notes

GitHub Pages handles TLS, caching and the CDN. The only DNS work is four apex `A` records (or an `ALIAS`/`ANAME` at your provider) plus a `www` CNAME, then enabling *Enforce HTTPS* in the repository settings. `static/CNAME` keeps the custom domain attached across deploys.
