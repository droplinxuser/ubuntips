---
title: "clang, PHP 8.4 and the missing zlib: the last round of compiled PHP"
date: 2026-11-23T22:20:00+08:00
description: "The final round of the compiled-PHP question: CentminMod's function alignment on its own, a clang build and PHP 8.4, with every module compiled from source. clang is the only build with a repeatable edge (+3 % on XenForo), 8.4 is slower than 8.5, and my earlier source builds were missing zlib."
tags: ["php", "php-fpm", "opcache", "jit", "clang", "gcc", "xenforo", "wordpress", "performance", "benchmark", "angie", "security"]
---

The last two posts asked whether a compiled PHP beats the distribution package. [First](/posts/is-a-compiled-php-faster/) with `-O3 -march=native`, [then](/posts/everything-on-lto-pgo-made-php-slower/) with LTO and PGO switched on. The answer both times was no. A few CentminMod levers were still unmeasured, so this round covers them: function alignment on its own, **clang instead of GCC**, and **PHP 8.4 against 8.5**. Every module is compiled from source this time, igbinary included.

Short version: **clang is the only build that ever beat the package, by about 3 % on XenForo member pages and nothing elsewhere. PHP 8.4 is slower than 8.5. My earlier source builds were missing zlib.** The zlib gap biased the earlier comparisons in favour of the source builds, so their conclusions still stand, but you should know about it.

## The arms

| Arm | Compiler | Flags | PHP |
|---|---|---|---|
| Sury (the package) | Debian rules | `-O2`, generic | 8.5.13 |
| GCC + falign | GCC 15 | `-O3 -m64 -march=native -mtune=native -falign-functions=32 -fno-semantic-interposition` | 8.5.13 |
| GCC, no falign | GCC 15 | the same without `-falign-functions=32` | 8.5.13 |
| clang | clang | the GCC + falign flags | 8.5.13 |
| PHP 8.4 | GCC 15 | the GCC + falign flags | 8.4.28 |

`-falign-functions=32` is CentminMod's `GCC_FALIGN_FUNCTION=y`, and clang is its `CLANG_PHP=y`. None of the arms use LTO, which the last post measured as neutral.

**All modules from source:** igbinary 3.2.16 would not build against 8.5 last time. **3.2.17RC1 does**, so every arm has igbinary, redis 6.3.0 and imagick 3.8.1 built against its own tree, and no downgrade was needed for it. I measured 8.4 anyway, because I had never compared the two versions on this stack.

## A confession first: the source builds had no zlib

The first run of this matrix gave a "cached" WordPress page at 6,000 requests per second instead of 98,000 whenever a source build was serving. That number is impossible for a cache hit, and it led to the real problem. **My source build script never passed `--with-zlib`.**

This matters because the stack has PHP gzip WordPress and Chevereto pages itself (`zlib.output_compression`). The guest cache then stores the compressed page, and a hit costs Angie almost nothing. Without zlib, PHP sent an uncompressed page, the cache's encoding guard refused to store it, and every "hit" went back to PHP.

On the uncached tiers the same gap meant **less** work for PHP, because Angie did the compression on other cores. So in the two previous posts, the WordPress and Chevereto rows of the source builds had a head start. They still didn't win, so those verdicts hold. XenForo was never affected, because Angie hands XenForo an empty `Accept-Encoding` and compresses member pages itself.

Every build in this post has `--with-zlib --with-sodium`. Before measuring, I checked that a guest page is stored and served from cache under a source build exactly as under the package: `[gzip] MISS`, then `[gzip] HIT`.

## Method

The same rig as before: a Xeon E-2236 (6 cores, 12 threads) running WordPress, XenForo (200 threads, 2,600 posts) and Chevereto behind Angie, with the clock pinned at 3.6 GHz. The CPU is power-limited, and an unpinned clock fakes differences. Loopback `wrk` runs 100 connections for 10 seconds per tier. There are 3 rounds, with the arms rotated forward and then backward, and the cache is emptied before each arm. I report medians and the min–max spread; anything under ~3 % or inside the spread is noise.

## The numbers

Median req/s, delta against the package:

| Tier | Sury | GCC + falign | GCC, no falign | **clang** | PHP 8.4 |
|---|---:|---:|---:|---:|---:|
| WordPress member home | 141 (141–141) | −0.7 % | −2.1 % | ±0 | −3.5 % |
| WordPress member post | 128 (127–129) | −5.5 % | −1.6 % | −0.8 % | −3.9 % |
| XenForo member home | 446 (444–449) | −4.9 % | −2.0 % | **+3.1 % (457–460)** | −2.9 % |
| XenForo member thread | 228 (227–229) | −1.3 % | −1.8 % | **+3.1 % (235–235)** | −3.1 % |
| Chevereto home (uncached) | 1,446 | −2.9 % | −3.5 % | ±0 | −4.3 % |
| Chevereto member explore | 463 | +0.2 % | +3.0 % | +0.6 % | −4.3 % |

clang's XenForo gain showed up in all three matrices I ran (+2.9 %, +3.3 %, +3.1 % on the home page, and +3.4 % and +3.1 % on the thread in two of them). Its spreads don't overlap the package's. It is the first source build in three posts that beat the package anywhere.

A CPU-only probe (15 runs per build, no web server, tracing JIT on) shows the same pattern:

| Section | Sury | GCC + falign | clang | PHP 8.4 |
|---|---:|---:|---:|---:|
| C builtins (json, preg, string, hash, sort) | 3.902 ms | 3.992 ms | 3.936 ms | 4.023 ms |
| Objects and methods | 0.687 ms | 0.699 ms | 0.690 ms | **0.844 ms** |
| JIT-compiled loops | 0.286 ms | 0.290 ms | 0.282 ms | 0.290 ms |

PHP 8.4 is 21 % slower on object and method work, which is exactly what a framework like XenForo spends its time on.

## Verdict

* **The distribution package stays.** clang's 3 % on one application is real but small. It doesn't pay for a compiler toolchain and a manual rebuild for every PHP security release on every server.
* **GCC `-O3 -march=native` loses 1–5 %**, and function alignment isn't the reason: the build without it is no better.
* **Don't downgrade to 8.4 for speed.** It is slower than 8.5 on every tier, and the one module that once needed it (igbinary) now builds on 8.5.

This is the last round of this question unless the compilers or the JIT change. With the tracing JIT, the hot PHP code is generated at run time, so the C compiler only reaches the interpreter's helpers.

## What else changed this cycle

A four-reviewer audit of both repositories, with every finding checked by an adversarial reviewer, kept 9 of 16 findings. The ones worth knowing about:

* **A guest-cache leak on XenForo front proxies.** An earlier release made every FastCGI guest cache refuse requests with cookies it doesn't know, but the reverse-proxy cache was missed. A member page fetched with an SSO or add-on login cookie could be stored for every guest for five minutes. Fixed, with a test that every `proxy_cache` gate in the tree carries the rule.
* **HTTP/3 and unknown names.** The catch-all server only listened over TCP, so the first site to turn on HTTP/3 became the default for every name over QUIC. The catch-all now owns the QUIC listener too. I checked it with OpenSSL 3.5's QUIC client: a real site serves its certificate and an unknown name gets none.
* **Compressed database dumps** (`.sql.zip`, `.sql.xz`, `.sql.zst` and friends) are now denied at any depth, not only `.sql` and `.sql.gz`.
* **A PHP upgrade interrupted halfway no longer leaves a server without PHP.** I tested it by sending `kill -TERM` in the middle of a real upgrade. That test found a second bug: the rollback "succeeded", but every site answered 502. The reinstalled package had already started PHP-FPM on its stock socket, and `systemctl enable --now` doesn't restart a unit that is already running. The rollback now restarts PHP-FPM and checks that the right socket is listening.
* Automatic swap no longer switches the live swap file off before the new one exists. A MariaDB install that fails to restart restores its previous configuration. Two PHP versions running side by side now share the planned worker pool instead of each taking all of it.

None of these changes moved a cached tier outside its spread in an A/B against the previous configuration.
