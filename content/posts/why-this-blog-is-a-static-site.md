---
title: "Why this blog is a static site"
date: 2026-11-20T18:30:00+08:00
description: "No database, no admin panel, nothing to patch. Here is the trade-off."
tags: ["hugo", "static-site", "security"]
---

A blog about hardening servers should not itself be the softest target in the stack. That ruled out the obvious choice.

## The requirements

The site needed to do five things:

- publish Markdown posts with syntax highlighting and tables,
- load fast on a phone over a mediocre connection,
- have nothing that needs a security patch on a Tuesday night,
- cost approximately nothing to run,
- keep every post in git, so a local agent or a shell script can edit it as easily as a person.

That last point matters more than it sounds. If the source of truth is a database, every change has to go through an API, an admin session or a migration. If it is a directory of text files, an editor, a script and a coding agent all work the same way.

## What a conventional blog engine costs

A typical CMS stack is a language runtime, a database, a web admin, a plugin ecosystem and a theme. Each of those is a component that can be exploited, and each has its own release cadence:

| Component | Typical failure mode |
|---|---|
| Runtime (PHP, Node) | RCE in a dependency reachable from a request path |
| Database | Credential leak, SQL injection, unpatched service exposed on a socket |
| Admin panel | Brute force, stolen session, vulnerable plugin endpoint |
| Upload directory | A file that ends in `.php` and gets executed |
| Plugins and themes | Abandoned code, supply-chain compromise |
| Search add-on | Index corruption, another service to keep running |

None of this is hypothetical; it is the ordinary background noise of running WordPress. The response is a patch routine, a WAF and monitoring. For a blog that changes a few times a month, that is a lot of machinery protecting text.

## What a static site removes

The published site is a directory of files. A request is a file read. Concretely, this site has:

- no database and no database credentials,
- no login form, session cookie or password reset flow,
- no upload endpoint and no writable web root,
- no server-side includes, no template evaluated per request,
- no third-party JavaScript, fonts, or analytics.

The attack surface is the CDN serving files, plus whatever is in this repository. A compromised post can change text; it cannot pivot into a database.

## The pipeline

`hugo.toml` (site config, menus, output formats) plus `content/posts/*.md` is the input. A push to `main` runs `.github/workflows/pages.yml`:

1. install the pinned Hugo version,
2. build once to produce `public/index.json`,
3. render a 1200×630 social card per post with headless Chrome,
4. build the final site (minified, fingerprinted assets),
5. upload the artifact and deploy it to GitHub Pages.

The build is a few seconds, and the same commands work locally:

```bash
hugo new content posts/some-topic.md   # from the archetype
hugo server                            # http://localhost:1313
hugo --minify --gc                     # what CI runs
```

Because the output is static, rollbacks are trivial: revert the commit, push, and the previous version is live again in under a minute. There is no migration and no cache to flush beyond the CDN's own.

## Search without a server

Removing the database also removes the search backend, which is where most "you cannot do that statically" arguments start. Hugo can emit every post as JSON:

```json
{ "title": "...", "url": "/posts/...", "date": "...", "tags": [...], "markdown": "..." }
```

That file is fetched only when the search box is focused, then filtered in the browser. It is not a full-text index — it is a few kilobytes per post and a `String.includes` — but for a blog of this size it returns results instantly and has zero operational cost. At a few thousand posts you would move to a prebuilt index such as Pagefind; the rest of the pipeline would not change.

## The trade-offs, honestly

| Static site | Conventional CMS |
|---|---|
| No in-browser editor by default | Rich admin UI |
| Rebuild required for every change | Instant publish |
| Comments need a third party | Built in |
| Nothing to patch | Patch treadmill |
| Search is client-side | Search server included |
| Preview is local or a branch deploy | Preview is built in |

Each of those has a workaround: a git-based CMS for browser editing, a hosted comment service, Pagefind for search. What you cannot get back is the single-process simplicity of a CMS, where writing a post is one form submission.

## Caching, and the limit of GitHub Pages

Assets are minified and fingerprinted (`style.min.<hash>.css`), so a deploy produces new URLs and no browser can serve stale CSS. That part is solved by the build.

Response headers are not. GitHub Pages sends `cache-control: max-age=600` for everything and ignores `_headers` files. The repository still carries a `static/_headers` with the policy this site wants — HTML revalidated, hashed assets immutable, images cached for a week — because it works unchanged on Cloudflare Pages. To get that policy in front of GitHub Pages you would proxy the DNS records through Cloudflare and add cache rules; the [README](https://github.com/droplinxuser/ubuntips) describes both paths.

It is worth being precise about what that costs: ten minutes of cache lifetime on HTML, not a correctness problem. The fingerprinted asset names mean the worst case is a slightly stale homepage, not a broken stylesheet.

## When a static site is the wrong choice

This setup is a bad fit if any of these are true:

- **Non-technical authors.** If nobody on the team wants to touch git, a CMS is the honest answer.
- **Frequent, tiny edits.** Rebuilding and pushing for a typo fix is fine; doing it fifty times a day is not.
- **Per-user content.** Comments, memberships, dashboards and personalisation need a runtime.
- **Search over a large corpus.** Client-side filtering stops scaling; you need an index service.
- **A publication with a workflow.** Draft review, scheduled publishing and roles are all things a CMS already solved.

## What it costs to run

GitHub Pages serves the site and the certificate for free. The repository holds the source; Actions builds it. There is no VPS, no database volume, no backup job — the backup is `git clone`.

The failure modes are equally small: a bad build fails before deploy, a bad deploy is reverted with one commit, and if the host disappeared tomorrow the whole site would be rebuildable from the repository in minutes.

That is the trade: a little friction when publishing, in exchange for almost nothing to operate. For a blog that is mostly read rather than written, it is the right side of the deal.
