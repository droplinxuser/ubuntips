---
title: "OpenLiteSpeed and LSCache against Angie for a large XenForo forum"
date: 2026-11-24T01:15:00+08:00
description: "A four-way shootout on a seeded XenForo forum: Angie with PHP-FPM and its FastCGI cache, the same with a clang-built PHP, and OpenLiteSpeed with LSAPI and the official LiteSpeed Cache add-on. Angie serves cached guests 16-23 % faster, members are a tie, and the add-on's documented setup shows logged-in members the guest page."
tags: ["xenforo", "openlitespeed", "litespeed", "lscache", "angie", "php-fpm", "lsapi", "clang", "performance", "benchmark", "security"]
---

The question for this round was simple: **what is the fastest way to serve a large XenForo forum on one server?** My setup runs Angie in front of PHP-FPM, with a FastCGI page cache for guests. The usual answer from the LiteSpeed side is OpenLiteSpeed: its own PHP interface (LSAPI) and a built-in page cache, LSCache, which XenForo can use through the official LiteSpeed Cache add-on. I had left OpenLiteSpeed out of earlier shootouts because, without that add-on, it has no page cache for XenForo at all. With the add-on, it gets a fair fight.

Short version: **Angie serves cached guest pages 16-23 % faster. Logged-in members are a tie. Under overload, Angie treats every visitor the same, while OpenLiteSpeed makes some of them wait for seconds.** And the add-on, set up the way its documentation says, shows logged-in members the cached guest page.

## The four setups

All four run on the same Xeon E-2236 test host (6 cores, 12 threads) with the same PHP 8.5.13, the same `php.ini` (OPcache 512 MB, tracing JIT), 12 PHP processes, the same TLS certificate and the same forum.

| Setup | Web server | PHP | Guest page cache |
|---|---|---|---|
| Angie + Sury | Angie | Ondřej Surý's PHP-FPM package | FastCGI cache, 5 min |
| Angie + clang | Angie | PHP-FPM built with clang `-O3 -march=native` | FastCGI cache, 5 min |
| OpenLiteSpeed | OpenLiteSpeed 1.9.4 | LiteSpeed's own lsphp85 over LSAPI | LSCache + XenForo add-on, 5 min |
| OpenLiteSpeed + clang | OpenLiteSpeed 1.9.4 | the clang build as lsphp | LSCache + add-on |

The forum was grown with a seeder to **20,000 users, 10,200 threads and 103,000 posts**, so the member pages do real database work. The load came from `wrk` on the same machine. Every round ran each setup in turn (the order reversed every other round), the guest caches were emptied before each one, and the CPU clock was pinned at 3.6 GHz, because this CPU's turbo fades under load and would otherwise favour whoever goes first.

## Getting OpenLiteSpeed to a fair start

OpenLiteSpeed needed three changes before the numbers meant anything, and none of them is obvious:

1. **It refused to start PHP at all.** I run PHP as `www-data`, which owns the forum files. OpenLiteSpeed won't launch PHP processes for a user ID below 100 unless you lower `minUID`, so every request was a 503.
2. **It quietly turned keep-alive down to 100 requests.** I had given it the same limit Angie uses, 65,536 requests per connection. That is above OpenLiteSpeed's maximum of 32,767, so it fell back to 100: a new TLS handshake every 100 requests, which would have cost it badly in a benchmark. The only clue was one warning line in its log.
3. **Logged-in members got the cached guest page.** This is the one that matters if you run it in production.

## The add-on's documented setup shows members the guest page

The LiteSpeed Cache add-on for XenForo works with a few rewrite rules: look the request up in the cache, and store the page unless the visitor has a member cookie. The add-on itself sets a marker cookie when someone logs in.

The catch is the lookup. `CacheLookup on` serves the stored guest copy to *any* request that matches. The marker cookie only exists for logins made after the add-on was installed. A member who logged in earlier, or who comes back through XenForo's "stay logged in" cookie, doesn't have it. Testing with exactly such a member returned `x-litespeed-cache: hit` and a page with no logged-in user on it.

This is not a privacy leak. The add-on never lets a logged-in page be stored, so nobody sees another member's page. But members see a logged-out forum, and in a benchmark every "member" request would actually measure the cache. One extra rule fixes it, placed before the lookup:

```apache
RewriteRule .* - [E="cache-vary:xf_session,xf_user,xf_lscxf_logged_in,xf_session_admin"]
CacheLookup on
```

The cache key now includes XenForo's session cookies, so a member's request never matches the guest copy and goes to PHP, as it does through Angie. A "no-cache" rule before or after the lookup did not help; the vary did.

## Guests: Angie is clearly faster

Median of five rounds, requests per second, 100 connections:

| Cached guest page | Angie + Sury | Angie + clang | OpenLiteSpeed | OpenLiteSpeed + clang |
|---|---:|---:|---:|---:|
| Forum index | **125,033** | 124,869 | 96,732 (−22.6 %) | 96,672 |
| Thread | **99,354** | 98,675 | 83,292 (−16.2 %) | 83,582 |

The result was the same at 400 connections. Measured per cached hit, OpenLiteSpeed spends 14-22 % more CPU than Angie (0.077 ms against 0.063 ms on the index), and it never got the machine past about 10 of its 12 threads. On a big forum most traffic is guests and crawlers, so this is the number that decides how much the server can take.

The PHP build makes no difference here, as expected: a cache hit never reaches PHP.

## Members: a tie, once the benchmark was honest

The first matrices gave OpenLiteSpeed a 6-9 % lead on member pages. That looked like a real point in its favour, so I measured it again and found two problems in my own harness:

* **LSAPI processes outlive OpenLiteSpeed.** For a few seconds after OpenLiteSpeed stops, its PHP processes keep running and burning CPU. Whatever setup ran next was measured on a busier machine and lost about 10 %. The switch script now waits until every one of them has exited.
* **The summary column labelled "p99" was actually the median.** A one-character bug in the column number, there for three cycles. It only affected the latency column of that script, not the throughput. Fixed.

Measured again, with the machine clean between setups and the two servers alternating:

| Member page | Angie | OpenLiteSpeed | Difference |
|---|---:|---:|---:|
| Thread | 221 req/s | 223 req/s | +0.9 % |
| Forum index | 248 req/s | 257 req/s | +3.6 % |

The thread page is a tie. The index is right at the 3 % line I use as the noise threshold. The CPU per page is the same: 47.6 ms for Angie plus PHP-FPM against 47.9 ms for OpenLiteSpeed plus lsphp. Compression isn't the difference either: Angie's gzip costs the same as its brotli on these pages.

## Under overload, one stack is fair and the other isn't

There is one more difference, and `wrk` hides it. `wrk` only records how long *finished* requests took. So I ran the member load at full saturation and, alongside it, timed 150 page loads from a separate client, the way a new visitor would see them:

| Setup | p50 | p90 | p99 | Failed or stuck (of 150) |
|---|---:|---:|---:|---|
| Angie + Sury | 0.44-0.46 s | 0.45-0.47 s | 0.46-0.48 s | 0-1 (one non-200 answer after 7 s) |
| OpenLiteSpeed | 0.04 s | 0.05-0.21 s | 2.0-3.7 s | **2 per run, still waiting at 30 s** |

Angie and PHP-FPM serve requests in the order they arrive. When the server is saturated, everyone waits about the same 0.45 s. OpenLiteSpeed keeps about a dozen connections moving fast and parks the rest. Most visitors get a quick page, but a parked one waits seconds, and 4 of 300 probe requests were still waiting when they gave up after 30 seconds. On a busy forum, those are the people who leave. Angie wasn't perfect either: three of its four runs (counting the clang build) had one request that came back with an error after 7-9 seconds, which I haven't explained yet.

## Verdict

**I'm keeping Angie, PHP-FPM and the FastCGI cache.**

* **Guests are most of a large forum's traffic, and Angie is 16-23 % faster at serving them** from cache, with less CPU per hit.
* **Members are a tie**, at the same CPU per page.
* **Under overload Angie is fair**, and OpenLiteSpeed is not.
* **OpenLiteSpeed needs care to be correct.** The add-on's documented rules show members the guest page, and two of its limits change silently. Adopting it would also mean a second web server in my setup script, with its own security model, next to an Angie configuration that already carries every guest-cache safety rule and regression test I have built.
* **The clang-built PHP** gave its usual +3 % on member pages and nothing on cached ones, on either server. Same conclusion as [last time](/posts/clang-php-84-and-the-missing-zlib/): not worth a compiler toolchain and a manual rebuild for every PHP security release.

If you already run OpenLiteSpeed with the XenForo add-on, add the `cache-vary` line above and check your keep-alive setting.

## What else changed this cycle

The audit this time ran in two rounds, and every finding was checked by independent reviewers who tried to prove it wrong. The second round reviewed this cycle's own changes and caught one of them before it shipped.

* **A guest-cache bypass with invisible characters.** PHP skips a vertical tab or form feed in front of a cookie name. My cookie allowlist didn't, and neither does Angie's own cookie lookup. So a cookie like `\vsso_token=…` reached PHP as a login cookie the cache never saw, and the page was stored for every guest. On the test host, the second such request filled the cache, and the next normal visitor got that copy. Any cookie header with a control character now skips the cache.
* **The login rate limit now counts IPv6 per /64.** It counted every single IPv6 address separately, so anyone with one VPS could rotate through more addresses than there are grains of sand. Forty addresses from one /64 all got through before the change; now the twelfth attempt is refused.
* **The XenForo front-proxy cache no longer stores a 403 or 429** from the origin, which could take a page down for every guest for five seconds.
* **The tuner now reaches Valkey on its socket.** On a server whose cache listens somewhere other than the default port, every tuning run restarted it twice and emptied it.
* **A Ctrl-C during `--domain` can no longer leave the site down.** The final tuning pass ran in a subshell where a paused web server was invisible to the cleanup code.
* **`/etc/hosts` no longer gains a blank line** with every install and restore. That small drift had been open for three cycles; the cause was `awk` always ending the file with a newline.
