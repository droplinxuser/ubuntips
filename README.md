# ubuntips.com

Source for [ubuntips.com](https://ubuntips.com), a blog about provisioning,
tuning and hardening Ubuntu servers.

Static site generated with [Hugo](https://gohugo.io) and deployed to GitHub
Pages by GitHub Actions on every push to `main`.

## Writing a post

```bash
.tools/hugo new content posts/my-post.md
# edit content/posts/my-post.md, set draft: false
.tools/hugo server        # preview at http://localhost:1313
git add -A && git commit -m "post: my post" && git push
```

Front matter used by the templates:

```yaml
---
title: "Post title"
date: 2026-11-21T09:00:00+08:00
description: "One sentence used in listings, search and social previews."
tags: ["ubuntu", "nginx"]
# sticky: true   # pins the post above all dated posts on home and /posts/
---
```

A table of contents and heading anchors are generated automatically for every
post with `##` or `###` headings.

## Local preview

The Hugo binary is portable and lives in `.tools/` (git-ignored). To fetch it
again on a fresh machine, download the signed `.pkg` from the Hugo releases page
and extract it without installing:

```bash
curl -fsSL -o /tmp/hugo.pkg \
  https://github.com/gohugoio/hugo/releases/download/v0.170.1/hugo_0.170.1_darwin-universal.pkg
pkgutil --expand-full /tmp/hugo.pkg /tmp/hugo-pkg
cp /tmp/hugo-pkg/Payload/hugo .tools/hugo && chmod +x .tools/hugo
```

`enableGitInfo` is on, so Hugo reads the commit date of each post to fill
`lastmod` (used by the sitemap and JSON-LD and shown as "Updated" on the page).
That requires a real `git` on `PATH`; a stub that only prompts for developer
tools will fail the build.

## Layout

| Path | Purpose |
|---|---|
| `content/posts/` | Markdown posts |
| `layouts/` | Templates (no external theme) |
| `assets/css/`, `assets/js/` | Styles and scripts, minified + fingerprinted |
| `assets/og/` | Per-post OG cards generated in CI (git-ignored) |
| `static/img/` | Default card, icons |
| `static/_headers` | Cache/security policy for header-capable hosts |
| `tools/gen-og-cards.sh` | Renders per-post OG cards in CI |
| `tools/check-links.pl` | Internal-link check run by CI |
| `static/CNAME` | Keeps the custom domain on every deploy |
| `.github/workflows/pages.yml` | Build, check and deploy to GitHub Pages |

## Features

- **Table of contents** above each long post, collapsible on mobile (and closed
  after tapping a link), with the current section highlighted while scrolling
  and `#` anchors for deep links.
- **System/light/dark theme** toggle that cycles through all three. The explicit
  choice is stored in `localStorage`; the script that applies it loads before
  the stylesheet so there is no flash, and it keeps the browser's
  `theme-color` in sync.
- **Copy buttons** on every code block.
- **Related posts** (by shared tags) with a "More posts" fallback.
- **Client-side search** with keyboard navigation (`/`, arrows, Enter, Escape),
  ARIA combobox semantics, an announced result count, ranked results with the
  matched text highlighted, and shareable `?q=` URLs.
- **Share button** on every post (Web Share API, clipboard fallback).
- **Pinned posts** via `sticky: true`.
- **Tag index** at `/tags/` with counts, and clean plain pages (About) without
  post chrome.
- **Edit this page** link on every post, pointing at the GitHub editor.
- **404 page** with search and the latest posts.
- **Skip to content** link that moves keyboard focus to `<main>`, semantic
  headings and focus styles.
- **Full-text RSS and JSON Feed** (`/index.xml`, `/feed.json`), both discoverable
  from every page.

## Social previews

Each post gets its own 1200×630 card, generated during CI by
`tools/gen-og-cards.sh`: a seed `hugo` build writes `public/index.json`, the
script renders one HTML card per post and screenshots it with headless Chrome.
Cards land in `assets/og/<slug>.png` (git-ignored); Hugo derives a 320×168
thumbnail in both WebP and PNG at build time, so no ImageMagick is needed.

- Card URL: `/og/<slug>.png`
- Thumbnail: `/og/<slug>-<hash>.webp` with a PNG `<picture>` fallback
- Fallback: `static/img/og-default.png`

Override for a single post with front matter:

```yaml
images: ["/img/custom-card.png"]
ogImageAlt: "Alt text for the card"
```

Locally, no cards exist, so pages fall back to `og-default.png` and lists omit
the thumbnail. That is expected; run `./tools/gen-og-cards.sh` on a machine with
Chrome if you want them locally.

## SEO

- `layouts/robots.txt` allows everything and points to the sitemap.
- `layouts/index.xml` emits a full-text RSS feed.
- `layouts/sitemap.xml` sets priorities per page kind, keeps `lastmod` from git,
  and leaves out tag pages that hold a single post. The unused `categories`
  taxonomy is disabled.
- Listing pages (posts and tags) have a real `<h1>`, and tag pages get their own
  meta description and `CollectionPage` + `ItemList` structured data.
- The home page title carries the tagline (`Ubuntu Tips — Practical notes on
  Ubuntu servers`) instead of the bare site name.
- Pages with fewer than two posts in a tag are `noindex, follow`.
- `.well-known/security.txt` is published for vulnerability reports.
- `layouts/partials/head.html` emits canonical, robots, Open Graph, Twitter,
  theme-color, a CSP and the stylesheet/script tags.
- `layouts/partials/schema.html` emits JSON-LD: `BlogPosting` + `BreadcrumbList`
  on posts, `AboutPage`/`WebPage` on plain pages, `CollectionPage` + `ItemList`
  on listings, and `WebSite` + `Organization` on the home page, with
  `dateModified` from git.
- Every page advertises the site feed (or its section feed) for RSS discovery.
- Icons: `favicon.ico`, `favicon.svg`, PNG fallbacks, `apple-touch-icon`,
  `site.webmanifest`.
- The author for every post comes from `params.author` (`Draft`), so new posts
  inherit it without front matter.

## Machine-readable files

| Path | Purpose |
|---|---|
| `/sitemap.xml` | URLs, per-kind priorities, git `lastmod` |
| `/index.xml` | Full-text RSS |
| `/feed.json` | JSON Feed 1.1 |
| `/index.json` | Search index (used by the header box) |
| `/llms.txt` | Compact map of the site for AI agents |
| `/llms-full.txt` | Every post in plain text |
| `/opensearch.xml` | Browser search integration (uses `?q=`) |
| `/.well-known/security.txt` | Vulnerability-report contact |

## Caching and security headers

`static/_headers` carries the intended policy:

| Path | Cache |
|---|---|
| `/*.html`, `/` | `max-age=0, must-revalidate` |
| `/*.xml`, `/*.json` | `max-age=600` |
| `/css/*`, `/js/*` | 1 year, immutable (filenames are fingerprinted) |
| `/img/*`, `/og/*` | 1 week, stale-while-revalidate |

It also sets HSTS, `X-Content-Type-Options`, `X-Frame-Options: DENY`,
`Referrer-Policy`, `Permissions-Policy` and a CSP.

**GitHub Pages ignores `_headers`** and always answers with
`cache-control: max-age=600`; it also sends no HSTS or CSP. The HTML therefore
carries a CSP `<meta>` as a partial substitute, with `style-src 'self'` (no
inline styles anywhere in the markup) and a `Referrer-Policy` meta. To get the
full policy, either serve the artifact through Cloudflare (proxy the DNS
records, SSL mode *Full*) and add a Cache Rule for `/css/*`, `/js/*` and
`/og/*`, or move hosting to Cloudflare Pages, which reads `_headers` directly.

## Search

The header search box loads `/index.json` and filters client-side. The index
contains title, URL, date, description, tags and the first 4,000 characters of
plain text per post, so deep terms in a long post are still searchable while
the payload stays small. Searches are deep-linkable with `?q=`, and the home
page's structured data advertises that URL as a `SearchAction`.

## CI

`pages.yml` installs the pinned Hugo version, builds once to seed the post list,
generates social cards, builds the final site, checks that every internal link
resolves, and deploys.

Three guards run before deploy:

- Hugo fails the build when `--printPathWarnings` reports duplicate target
  paths.
- `tools/check-links.pl` fails on any internal `href`/`src` (including every
  `srcset` candidate) that does not map to a file in `public/`, and on any
  `#fragment` with no matching `id` in the target page.
- `tools/check-html.pl` fails on a missing or duplicate `<h1>`, an `<img>`
  without `alt`, a duplicate `id`, or a skipped heading level (Hugo's redirect
  stubs are skipped).

Dependabot updates the action versions weekly.
