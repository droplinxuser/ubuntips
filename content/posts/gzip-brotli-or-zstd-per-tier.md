---
title: "gzip, Brotli or zstd? It depends on what you are compressing"
date: 2026-11-22T20:00:00+08:00
description: "Measured per tier on one origin: precompressed Brotli made static files 22-30x faster, zstd cut the CPU of compressing member pages by 61%, and the guest cache was already right. Plus a cookie trick that leaked member pages to guests."
tags: ["compression", "zstd", "brotli", "gzip", "angie", "xenforo", "wordpress", "benchmark", "security"]
---

"Which compression should my web server use?" usually gets one answer for the whole site. On a PHP origin there are really three different jobs, and they want three different answers:

1. **Pages served from the guest cache.** Compressed once when the page is stored, then sent as-is to every visitor.
2. **Pages rendered for logged-in members.** Compressed on every request, while PHP is already the bottleneck.
3. **Static files** (CSS, JavaScript, fonts). The same bytes for everyone, compressed on every request unless you precompress them.

This cycle of my [provisioning script](/posts/one-idempotent-script/) audit measured all three with gzip, Brotli and zstd. In short:

| Tier | Before | Now | Effect |
|---|---|---|---|
| Static files | Brotli 4, compressed per request | precompressed `.br` (Brotli 11) + `.gz` | **22-30x** the requests per second, 13-18% fewer bytes for Brotli clients |
| Member pages | Brotli 4 | **zstd 3** for browsers that accept it, Brotli 4 for the rest | 61% less Angie CPU per page for 6% more bytes |
| Guest cache | stored gzip | stored gzip (level 6 instead of 4 for WordPress/Chevereto) | 5% fewer bytes per hit |

The same audit also found a way to make the guest cache store a member's page and serve it to everyone. That's at the end.

> **Update, 23 November 2026:** zstd is out again in release 1.21.59. Every site I run sits behind Cloudflare, and Cloudflare asks origins for `br, gzip` only, so on those servers the zstd module never answered a single request. `--optimize` now removes its configuration and the module. The measurements below still stand; they just only matter for a server that browsers reach directly. The same release also stopped the guest cache from keeping a separate copy of every page for each browser's exact `Accept-Encoding` header (Chrome, Safari and Cloudflare each filled their own), so all of them now share one cached page per encoding.

## The test bed

- One dedicated server: 6-core / 12-thread Xeon, 62 GB RAM, Ubuntu 26.04.1, CPU mitigations on.
- Angie 1.12 with the Brotli and zstd modules, PHP-FPM 8.5, MariaDB, Valkey and Elasticsearch, all installed by the script.
- WordPress 7.1.4, XenForo 2.3.13 (20,000 seeded users and 10,000 threads) and Chevereto 4.5.9.
- Load from [wrk](https://github.com/wg/wrk) on the server itself over HTTPS: 100 connections, 10 seconds after a 2-second warm-up, three runs per row, median shown.
- CPU per request is read from the systemd cgroups of Angie and PHP-FPM (`cpu.stat` before and after each run, divided by the requests completed), so it measures the server, not the load generator.

### First, a measurement mistake worth knowing about

My first baseline ran each encoding's three runs back to back. The first encoding of a page came out up to 24% faster than the others, even when all of them were served the *same stored bytes*. The CPU had more boost headroom for whichever run started first.

Every comparison below therefore rotates the encodings (or configurations) within each round: A, B, C, then A, B, C again. Rotation shrinks the effect but doesn't remove it: whatever runs first in a round still gets a small head start. I put the old default first, so if anything the gains below are understated. If you benchmark anything on a desktop-class CPU, rotate too, or you'll measure the order rather than the change.

### What the clients actually ask for

- Current Chrome, Edge and Firefox send `Accept-Encoding: gzip, deflate, br, zstd`.
- Safari sends `gzip, deflate, br`.
- **Cloudflare asks your origin for `br, gzip` only.** zstd is something Cloudflare offers at its own edge, after re-encoding your response ([Cloudflare docs](https://developers.cloudflare.com/speed/optimization/content/compression/index.md)).

So for a site behind Cloudflare, zstd at the origin only ever reaches visitors who connect to the origin directly. Keep that in mind for the member-page numbers.

## 1. Static files: stop compressing them per request

Before, every request for a script or stylesheet was compressed on the fly with Brotli level 4. The XenForo core script (177 KB) is a good example (rotated A/B, `Accept-Encoding: br, gzip`):

| XenForo core JS | bytes | requests/s | Angie CPU per request |
|---|---:|---:|---:|
| Brotli 4, per request | 54,618 | 2,063 | 3.9 ms |
| uncompressed (for reference) | 177,015 | 22,570 | 0.30 ms |
| **precompressed `.br` file (Brotli 11)** | **46,412** | **62,808** | **0.11 ms** |

The 99th-percentile latency fell from 76 ms to under 5 ms.

The precompressed file is served faster than the *uncompressed* one, because it's a quarter of the size. It's also 15% smaller than the per-request Brotli, since level 11 is affordable when it runs once.

WordPress's block stylesheet went from 4,290 to 93,204 requests per second, and jQuery from 3,620 to 81,741. Clients that only accept gzip get the `.gz` file: the same speed-up, but only 4-10% fewer bytes.

### Why Brotli and not zstd for the files

I expected zstd to win, so I measured it. Over 10 MB of XenForo scripts:

| encoder | output | time |
|---|---:|---:|
| gzip -9 | 3.10 MB | 1.0 s |
| zstd -19 | 2.84 MB | 12.3 s |
| **Brotli 11** | **2.67 MB** | 13.1 s |

For the same build time, Brotli 11 is 6% smaller. zstd's strength is *speed*, and speed doesn't matter for a file you compress once. So the script writes `.br` and `.gz` siblings only.

One Angie detail matters here. With the zstd static module loaded, a browser that accepts both is served the larger `.zst` file. Without it, the browser gets the `.br` file. I don't load it.

### Precompression without stale files

Precompressed siblings have one classic failure: the source changes and the sibling doesn't. The audit found four ways that could happen:

- **A file shrinks.** It drops below the 1 KB minimum, gets skipped from then on, and its old, larger sibling stays.
- **A rollback.** `tar`, `rsync -a` or `cp -p` restores an *older* modification time, so "source newer than sibling" never fires.
- **An upgrade mid-pass.** The upgrade rewrites a file while it's being compressed.
- **Precompression is switched off.** The siblings stay on disk, and `gzip_static` keeps serving them.

The cron helper now rebuilds a sibling whenever the two modification times *differ*. It checks the source's size and time before and after compressing, and it removes what it made when the feature is off or a site goes away.

The first pass over a XenForo + WordPress host took several minutes, so it now runs in the background instead of holding up the script.

## 2. Member pages: zstd where the browser accepts it

*Removed again in 1.21.59: see the update at the top. Behind Cloudflare, Brotli 4 is what member pages get.*

A logged-in XenForo thread page (127 KB of HTML) can't be cached. It's rendered by PHP and compressed by Angie on every request. Here are the three encoders at the levels that matter, rotated (from two rotation sessions, each with its own Brotli 4 reference: 380 and 379 requests/s):

| encoder | bytes | Angie CPU per request | requests/s |
|---|---:|---:|---:|
| none | 127,423 | 0.45 ms | 411 |
| gzip 4 | 20,305 | 2.03 ms | 380 |
| gzip 6 | 19,183 | 2.87 ms | 370 |
| Brotli 3 | 19,205 | 1.39 ms | 393 |
| Brotli 4 (old default) | 18,319 | 2.13 ms | 379 |
| Brotli 5 | 16,940 | 3.74 ms | 356 |
| zstd 1 | 20,563 | 0.66 ms | 409 |
| **zstd 3** | **19,414** | **0.84 ms** | **404** |
| zstd 5 | 18,196 | 1.41 ms | 391 |
| zstd 6 | 17,855 | 1.81 ms | 386 |

zstd 6 is smaller *and* cheaper than Brotli 4, and zstd 5 matches its size at a third less CPU. I picked **zstd 3**. It costs 6% more bytes than Brotli 4 (about 1.1 KB on this page) for 61% less Angie CPU per request (about 77% less for the compression itself), and its time to first byte is 1 ms below Brotli 4's. On a server where PHP is the bottleneck, CPU is the scarcer resource. Level 4 adds CPU for almost nothing.

### The module order trap

With both modules loaded, my first test sent Brotli to *every* client, including ones that listed zstd first. In Angie (as in nginx), the output filter that loads **last runs first**. My zstd module file was named `40-zstd.conf`, which sorts before `50-brotli.conf`, so Brotli always got there first. Renamed to `60-zstd.conf`:

| client sends | gets |
|---|---|
| `gzip, deflate, br, zstd` (Chrome, Firefox, Edge) | zstd |
| `br, gzip` (Cloudflare) | Brotli |
| `gzip, deflate, br` (Safari) | Brotli |
| `zstd;q=0, br` | Brotli |

If you load both modules, check which one actually answers.

### What did not help

WordPress and Chevereto compress their own pages in PHP (`zlib.output_compression`), so the guest cache can store the compressed copy. I tested letting Angie compress member pages instead, as the script already does for XenForo. For a browser: 145 vs 144 requests per second, inside the run-to-run spread. For the Cloudflare `br, gzip` path Angie was about 3% *slower* (145 vs 141). No change shipped.

## 3. The guest cache: already right, with one small fix

A cached page is compressed once, when it's stored, and then sent to every visitor. The cost of the encoder barely matters; its size does. The stored body is gzip, because that's what PHP and XenForo produce. Any client that accepts gzip, which is every browser and Cloudflare, gets it in about 0.1 ms of CPU.

Sizes of the actual pages:

| page | gzip 4 | gzip 6 | gzip 9 | Brotli 11 | zstd 19 |
|---|---:|---:|---:|---:|---:|
| WordPress post | 14,895 | 14,163 | 14,088 | 12,158 | 13,261 |
| XenForo thread | 13,965 | 13,331 | 13,257 | 10,425 | 11,880 |
| Chevereto gallery | 12,723 | 12,018 | 11,934 | 9,699 | 11,134 |

- **WordPress and Chevereto now store level 6 instead of 4.** Each hit gets 5% fewer bytes, for about a third of a millisecond more when a page is first stored. XenForo already uses level 9.
- **Stored Brotli would be the real win: 14-22% smaller than the stored gzip.** But PHP would have to produce it, and no PHP Brotli extension is packaged for Ubuntu.
- **Stored zstd isn't worth it.** Level 19 costs about 70 ms per page, and Cloudflare never asks for zstd.

## 4. A member page served to guests

Each cycle also runs a code audit. This time every finding went to two independent reviewers, each told to try to refute it. The most serious result this time was in the guest cache.

The cache decides "member or guest" by looking for the session cookie, for XenForo `xf_session=`. PHP, however, rewrites cookie *names* before the application sees them: `.`, space and `[` become `_`. So a member who sends their own session ID as

```
Cookie: xf.session=<their session id>
```

is a guest to the web server and logged in to XenForo. On the test server, two such requests stored the member's thread page, and the next visitor *without any cookie* received it from the cache: the member's name, account links and form tokens. The same works for `wordpress.logged.in_<hash>`.

It needs a valid session of your own, so it doesn't steal anyone else's account. It does put your logged-in page in front of every guest for the cache lifetime, and it breaks their forms.

The fix accepts every separator PHP folds, so the pattern matches `xf.session`, `xf session`, `xf[session` and `xf_session` alike. It also doesn't depend on the `xf_` prefix, so forums with a custom cookie prefix are covered. A cookie *name* containing `%` is treated as a member, as a margin. I checked the common guest cookies (Google Analytics, Matomo, Hotjar, consent banners); they stay cacheable.

If you run any full-page cache in front of PHP with a cookie-based bypass, test it with a dotted cookie name.

The audit also found that the script's own optimizer stripped two other cache safeguards on every run, and that turning on Anubis could open an origin that was meant to accept only its front proxy. Both are fixed, with tests.

## PHP 8.6

The missing Redis, igbinary and Imagick extensions for PHP 8.6 are now packaged. An 8.5 → 8.6 → 8.5 round trip ran clean with all three applications, in under two minutes each way.

- **WordPress and Chevereto run cleanly on 8.6.**
- **XenForo 2.3.13 stays on 8.5 for now.** Its normal pages work on 8.6. In debug mode every page fails, because XenForo turns one 8.6 deprecation into an error. Two libraries it bundles, the Braintree payment SDK and a mail transport class called `Null`, no longer compile.

## What this does not prove

- **Loopback numbers are ceilings.** They measure the server's cost per request. Over a real network, the byte savings matter more and the CPU savings show up as headroom.
- **Content grew during the cycle.** Seeding and the test suites added posts and images between the first and last runs. I compare page tiers only through the rotated A/B runs, not through the first and last matrices. Static files were byte-identical throughout.
- **Behind Cloudflare, the member-page change does nothing.** Cloudflare asks for Brotli or gzip, and that path didn't change. The static and guest-cache changes apply either way.
- **zstd's "6% more bytes" is one page type.** The CSS and JavaScript numbers point the same way, but your HTML may differ.

## What changed

All of this shipped in release 1.21.58 of [ubuntu-setup-script](https://github.com/droplinxuser/ubuntu-setup-script) and its Angie configuration. If you tune compression yourself:

1. **Precompress static files with Brotli 11 and gzip -9.** Rebuild a sibling whenever its modification time differs from the source's, not only when the source is newer.
2. **Use zstd 3 for dynamic responses, and load it after Brotli, if browsers reach your server directly.** Keep Brotli 4 for clients that don't ask for zstd. Behind Cloudflare, skip it: Cloudflare only asks the origin for Brotli or gzip (the script removed zstd in 1.21.59 for this reason).
3. **Store cached pages compressed.** Spend a higher level once rather than a low level on every hit.
4. **Rotate what you compare within each round.** Otherwise you're measuring your CPU's boost budget.
