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
| `static/css/`, `static/js/` | Styles and the search box |
| `static/CNAME` | Keeps the custom domain on every deploy |
| `.github/workflows/pages.yml` | Build and deploy to GitHub Pages |

## Social previews

`static/img/og-default.png` (1200×630) is the fallback card used by Open Graph,
Twitter and JSON-LD. Override it per page:

```yaml
---
title: "Post title"
date: 2026-11-21T09:00:00+08:00
images: ["/img/my-post-card.png"]
ogImageAlt: "Optional alt text for the card"
---
```

The default card is rendered from `tools/og-card.html` (a 1200×630 HTML page).
To regenerate it, serve the site, open `tools/og-card.html` at a viewport wider
than 1200×630, screenshot it, centre-crop to 2400×1260 and resize to 1200×630.

## Search

The header search box loads `/index.json` (generated from all posts) and filters
client-side. No third-party service is involved.
