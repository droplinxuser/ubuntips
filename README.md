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

## Layout

| Path | Purpose |
|---|---|
| `content/posts/` | Markdown posts |
| `layouts/` | Templates (no external theme) |
| `assets/css/`, `assets/js/` | Styles and search box, minified + fingerprinted |
| `static/img/` | Social cards, icons, thumbnails |
| `static/_headers` | Cache/security policy for header-capable hosts |
| `tools/gen-og-cards.sh` | Renders per-post OG cards and thumbnails in CI |
| `static/CNAME` | Keeps the custom domain on every deploy |
| `.github/workflows/pages.yml` | Build and deploy to GitHub Pages |

## Social previews

Each post gets its own 1200×630 card, generated during CI by
`tools/gen-og-cards.sh`: a seed `hugo` build writes `public/index.json`, the
script renders one HTML card per post and screenshots it with headless Chrome,
then ImageMagick produces a 600×315 thumbnail. Both files land in
`static/img/og/` (git-ignored), and the templates pick them up automatically.

- Card URL: `/img/og/<slug>.png`
- Thumbnail: `/img/og/<slug>-thumb.png`, used in post lists
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
- `hugo.toml` sets sitemap `changefreq`/`priority`; Hugo emits `sitemap.xml`,
  `index.xml` and `index.json`.
- `layouts/partials/head.html` emits canonical, robots, Open Graph, Twitter and
  theme-color tags, plus `rel=prev/next` on paginated sections.
- `layouts/partials/schema.html` emits JSON-LD: `BlogPosting` + `BreadcrumbList`
  on posts, `WebSite` + `Organization` on the home page.
- Icons: `favicon.svg`, PNG fallbacks, `apple-touch-icon`, `site.webmanifest`.
- The author for every post comes from `params.author` (`Draft`), so new posts
  inherit it without front matter.

## Caching

`static/_headers` carries the intended policy:

| Path | Cache |
|---|---|
| `/*.html`, `/` | `max-age=0, must-revalidate` |
| `/*.xml`, `/*.json` | `max-age=600` |
| `/css/*`, `/js/*` | 1 year, immutable (filenames are fingerprinted) |
| `/img/*` | 1 week, stale-while-revalidate |

**GitHub Pages ignores `_headers`** and always answers with
`cache-control: max-age=600`. The fingerprinted asset names still prevent
stale CSS/JS after a deploy, because the URL changes. To get the full policy,
either serve the same artifact through Cloudflare (proxy the DNS records, SSL
mode *Full*) and add a Cache Rule for `/css/*` and `/js/*`, or move hosting to
Cloudflare Pages, which reads `_headers` directly.

## Search

The header search box loads `/index.json` (generated from all posts) and filters
client-side. No third-party service is involved.
