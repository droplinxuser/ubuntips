---
title: "Who compresses a logged-in XenForo page? 12 % of PHP, one fastcgi_param, and a clock that lied"
date: 2026-11-23T15:30:00+08:00
description: "Profiling the member pages of a XenForo forum showed zlib eating 12 % of PHP-FPM CPU: XenForo gzips its own pages at level 9 inside the worker. Moving that to Angie gave +5 % on the forum index and +9 % on thread pages. Along the way, a CPU turbo budget faked a 27 % speed-up, and three other ideas did not survive measurement."
tags: ["xenforo", "php-fpm", "angie", "nginx", "brotli", "gzip", "performance", "benchmark", "opcache", "turbo"]
---

Guest pages on my forums are a solved problem. They come out of Angie's FastCGI cache at 125–135k requests per second on the 12-thread test box, and the remaining cost is TLS. The pages that still cost real money are the ones nobody can cache: **logged-in members**. Every member view runs XenForo end to end, and on this hardware that meant about 260 thread pages per second.

So this cycle had one question: **what is left on the logged-in path that the server, not the application, can make cheaper?** My [provisioning script](/posts/one-idempotent-script/) already does the usual list: OPcache with the tracing JIT, one PHP-FPM worker per CPU thread, persistent database connections, sessions and cache in Valkey, MariaDB's thread pool. Guessing would only re-run old experiments, so I started with a profile.

## Where a member page spends its time

The setup, the same for every number below: a Xeon E-2236 (6 cores / 12 threads, 62 GB, NVMe RAID0), Ubuntu 26.04, PHP 8.5, Angie, MariaDB, Valkey, and XenForo 2.3.13 with 200 threads and 2,600 posts. Load comes from `wrk` over loopback TLS with 100 connections, logged in as a forum member. CPU mitigations were off for this cycle.

Per-service CPU per request, from each service's cgroup counters during the member thread tier:

| Service | CPU per thread page | share |
|---|---:|---:|
| PHP-FPM | 36.9 ms | 92 % |
| MariaDB | 2.4 ms | 6 % |
| Angie (TLS + compression) | 0.28 ms | 0.7 % |
| Valkey | 0.22 ms | 0.5 % |

That is what "PHP-bound" looks like. Then `perf record -a` during the same load, grouped by library:

```
12.04%  php-fpm8.5   libz.so.1.3.1
 7.08%  php-fpm8.5   php-fpm8.5
 5.19%  php-fpm8.5   [JIT] tid 38507     (x12 workers, ~62 % together)
 4.91%  worker_thread mariadbd
 4.27%  php-fpm8.5   libc.so.6
```

**zlib, 12 % of every sample on the machine, all of it inside PHP.** (The `[JIT] tid` lines are mostly the PHP interpreter itself, not JIT output: `opcache.huge_code_pages` copies the binary's code onto anonymous huge pages, and perf can no longer name it.)

## The application was compressing its own pages

XenForo gzips every page itself, at level 9, whenever the request's `Accept-Encoding` mentions gzip. One curl per header against a member page tells you who did the work:

```
Accept-Encoding: gzip, br              -> content-encoding: gzip   (XenForo)
Accept-Encoding: br, gzip  (Cloudflare) -> content-encoding: gzip   (XenForo)
Accept-Encoding: br                    -> content-encoding: br     (Angie)
```

What stung is that I had fixed this before. Three days ago I measured the split: guests keep XenForo's gzip, because the page cache stores that compressed body once and every hit reuses it; members get plain HTML that the web server compresses. But I shipped the fix as a small block appended to each forum's `src/config.php`, and only `setup.sh --optimize` writes it. **A forum installed after the server, which is the normal order, ran XenForo's level-9 gzip for every member until someone happened to run `--optimize`.** This cycle's own test deployment was one of them.

The fix belongs where the decision already lives: in the web server. The uncached XenForo handler now withholds the header from PHP:

```nginx
include snippets/fastcgi-php-noinfo.conf;
fastcgi_param HTTP_PROXY "";
fastcgi_param HTTP_ACCEPT_ENCODING "";
```

PHP sees no `Accept-Encoding` (a probe script printed `NULL`), sends plain HTML, and Angie compresses it with Brotli or gzip at level 4, outside the PHP pool. The cached-guest location still passes the cache key's encoding, so cache hits keep serving XenForo's stored gzip and are never compressed twice. The configuration tree is copied by both a fresh install and `--optimize`, so one changed file reaches new servers and running ones alike, and nothing in any forum directory gets edited.

## The numbers

Same host, same forum, old and new handler swapped inside each round and the order rotated each round, three rounds, all twelve tiers, with the CPU clock pinned (more on that below):

| Tier | before | after | change | p99 before → after |
|---|---:|---:|---:|---:|
| XenForo member, forum index | 473 req/s | 497 req/s | **+5.1 %** | 272 → 221 ms |
| XenForo member, thread page | 261 req/s | 285 req/s | **+9.2 %** | 566 → 503 ms |
| XenForo guest thread (cached) | 124,445 | 124,750 | +0.2 % | unchanged |
| WordPress member home | 118 | 118 | 0 % | unchanged |
| Chevereto member explore | 510 | 512 | +0.4 % | unchanged |

The spreads did not overlap: the thread page ran 260–264 req/s before and 284–285 after. Per thread page, PHP went from **41.6 to 34.7 ms of CPU**. Angie picked up about 2 ms for Brotli, so the whole server still does 10 % less work per page (45.5 → 40.8 ms). Brotli at level 4 is a fraction of what level-9 gzip costs, and it runs in Angie's event loop instead of holding one of only twelve PHP workers. The bytes barely moved: 17.6 KB from XenForo's gzip 9, 17.1 KB from Angie's Brotli 4.

## The clock that lied

Halfway through, the numbers jumped. After a PHP-FPM restart the member tiers read **594 and 361 req/s, against 510 and 285 just before**, with no configuration change. For an hour I chased a "long-lived worker" theory: JIT buffer exhaustion, heap fragmentation, persistent connections. The JIT buffer was fine (XenForo uses under 1 MB of the 64 MB), and a mixed WordPress/Chevereto load did not slow XenForo down.

Then I printed the CPU clock next to each run:

| Run | req/s | mean clock | PHP ms per page |
|---|---:|---:|---:|
| steady | 350 | 4.5 GHz | 27.4 |
| steady | 347 | 4.5 GHz | 27.5 |
| next | 326 | 4.1 GHz | 30.0 |
| after a PHP reload | 332 | 4.1 GHz | 29.4 |

PHP's CPU per request follows the clock exactly: 4.5 / 4.1 = 1.10 = 30.0 / 27.4. This CPU's turbo is limited by power, not temperature. It may draw 112 W for a while (PL2), then has to drop to 80 W (PL1), which means 4.1 GHz with all cores busy and lower still after a heavy run. The thermal throttle counters were zero and the package sat at 35 °C. My "restart effect" was the preceding test letting the box idle, which refilled the turbo budget for whatever ran next. It is also why, two cycles ago, whichever variant ran first in a block always looked 16–24 % better.

The fix is boring: pin the ceiling below the sustained all-core clock while benchmarking.

```bash
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
  echo 3600000 > "$f"
done
```

At 3.6 GHz, two back-to-back runs read 285 and 286. The test harness now does this (`set-clock.sh`), and every benchmark row prints the mean clock beside the result. If your benchmark box turbos, its results come out in GHz, not in config changes.

## What did not make it

Three other ideas were measured and dropped:

- **PHP's heap on transparent huge pages** (`USE_ZEND_ALLOC_HUGE_PAGES=1`). The host already runs THP in `madvise` mode, so only PHP's request heap would get 2 MB pages. A single request worked. Under 100 connections the pool **stopped answering**: 0–5 req/s and 60 timeouts, in all three rounds. Not shipped, and now written down so nobody tries it again.
- **More PHP-FPM workers.** 12, 15 and 18 workers on 12 threads: 580 / 577 / 580 req/s on the index, all within noise. One worker per thread stays.
- **A lower Brotli level for dynamic HTML.** Level 1 is +4–6 % on member pages but sends 40 % more bytes to every direct visitor (23.9 KB vs 17.1 KB). Levels 2 and 3 were inside the noise. The default stays 4; the README now lists the trade-off, and an origin whose only client is Cloudflare can choose 1.

## Zero-error, as usual

Fresh install in 2:36 with 0 warnings; 1,496 unit checks, 227 dry runs, 67/67 security probes, 86/86 guest-cache cookie cases, functional suite 0 unexpected. Two new regression checks: one asserts the handler withholds the header (and the cached location does not), and one requests a member page with `br, gzip` and requires Brotli back, which only Angie produces. `--optimize` on a server with the old handler rolled the change out, and a second `--optimize` changed 0 of 3,034 recorded settings. The test host went back to its pristine 696-package manifest with 0 changed files under `/etc`. The first restore attempt left behind the 8 GB swap file that `--purge` keeps on purpose, so the restore tool now removes it.

## What I would tell the next person

- **Profile by library before tuning.** "PHP is slow" was true and useless. "12 % of the box is zlib inside PHP" took one `perf report --sort dso` to find, and one line to fix.
- **A fix stored in application files is only half a fix.** If the web server can make the decision, make it there. Otherwise every application installed after your setup runs never gets it.
- **Print the clock beside every benchmark.** On a turbo CPU, an idle gap between two runs is a configuration change you didn't make.
