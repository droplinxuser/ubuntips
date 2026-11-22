---
title: "PHP-FPM, FrankenPHP, RoadRunner or Swoole? The PHP layer decides less than you think"
date: 2026-11-23T07:30:00+08:00
description: "Eleven ways to execute PHP, one application-shaped workload, then the real WordPress, XenForo and Chevereto pages. Worker runtimes are 1.4-1.6x faster, but the applications cannot use them without a port; PHP-FPM stays the default."
tags: ["php", "php-fpm", "frankenphp", "roadrunner", "swoole", "openswoole", "workerman", "reactphp", "amphp", "opcache", "benchmark", "xenforo", "wordpress", "chevereto"]
---

The [last cycle](/posts/which-web-server-for-a-php-origin/) compared six web servers in front of the same PHP-FPM pool and found that the server core was noise: every nginx-family build landed inside the run-to-run spread, and the 100x factor was the generic page cache. That left the obvious next question.

**If the web server does not decide, does the way PHP itself runs?**

PHP-FPM is the default in my [provisioning script](/posts/one-idempotent-script/). The alternatives have loud claims: FrankenPHP embeds PHP in a Go server, RoadRunner and Swoole keep the application in memory between requests, Workerman and ReactPHP and AMPHP turn PHP into an event loop, and PHP-CGI is the old baseline everybody replaced. So this cycle put all of them on the same workload, and then put the three applications on the ones that can actually run them unmodified.

The short answer: **keep PHP-FPM**. For WordPress, XenForo and Chevereto the request time is the database and the template, not the SAPI. The persistent-worker runtimes are genuinely 1.4-1.6x faster, but they are an application port, not a server swap.

## Two questions, two test beds

Comparing a server that runs the application unmodified with one that needs a rewritten front controller is not one benchmark. I used two layers.

**Layer 1 — the real applications.** PHP-FPM 8.5, PHP-CGI 8.5 and FrankenPHP 1.14 (which embeds PHP 8.6) served the actual WordPress, XenForo and Chevereto document roots over TLS on `:443`, one server at a time, with **no page cache** — a cache would hide the PHP path being measured. Same database, same Valkey, same files, 100 connections, 8 seconds, three rounds, order reversed on even rounds. Member tiers used real session cookies.

**Layer 2 — the runtime ceiling.** A shared application-shaped workload: a 60-file framework bootstrap, two MariaDB statements, one Valkey `GET`, a 13 KB template with 160 rows, a SHA-256 of the page and a JSON round-trip. PHP-FPM, PHP-CGI, FrankenPHP classic, FrankenPHP worker, RoadRunner 3.0, Swoole 6.2, OpenSwoole, Workerman 5.2, ReactPHP 1.12, AMPHP 3.4 and PHP's built-in server each got 12 workers (ReactPHP and AMPHP: twelve event-loop processes sharing the port), the same OPcache and tracing JIT (`opcache.jit=tracing`, 64 MB), the same Angie in front, gzip off, `wrk -t4 -c64 -d8s`, 3 rounds. CPU is each backend's cgroup usage divided by the requests completed; Angie's CPU is reported separately.

OpenLiteSpeed was left out for the same two reasons as last cycle: its LSCache module only stores responses an application plugin marks (Chevereto and XenForo have no such plugin), and its fast path is LSAPI, a different PHP SAPI, so measuring it against PHP-FPM would compare two PHP builds rather than two servers.

The host is the same disposable 6-core/12-thread Xeon E-2236 with 62 GB RAM and NVMe RAID0, mitigations off, restored to its pristine package manifest afterwards.

## Layer 2: the same work, every execution model

| Runtime | req/s (median) | spread | p50 | p99 | PHP CPU ms/req | RSS |
|---|---:|---:|---:|---:|---:|---:|
| Workerman 5.2 | 13,872 | 3.3% | 4.57 ms | 5.72 ms | 0.373 | 420 MB |
| Swoole 6.2 | **14,034** | 4.4% | 4.26 ms | 14.48 ms | 0.370 | 437 MB |
| OpenSwoole | 13,310 | 4.6% | 4.97 ms | 7.82 ms | 0.430 | 403 MB |
| FrankenPHP worker | 9,620 | 13.8% | 6.57 ms | **8.34 ms** | 0.653 | 152 MB |
| PHP built-in server | 9,294 | 4.7% | 6.80 ms | 8.79 ms | 0.608 | 382 MB |
| PHP-CGI 8.5 | 9,215 | 14.2% | 6.84 ms | 8.79 ms | 0.620 | 319 MB |
| PHP-FPM 8.5 (baseline) | 8,884 | 15.9% | 7.14 ms | 8.91 ms | 0.604 | 281 MB |
| RoadRunner 3.0 | 7,917 | 0.7% | 7.98 ms | 9.75 ms | 0.899 | 910 MB |
| FrankenPHP classic | 7,633 | 13.6% | 8.15 ms | 13.33 ms | 0.918 | 207 MB |
| AMPHP 3.4 | 6,505 | 2.1% | 8.90 ms | 33.59 ms | 0.971 | 936 MB |
| ReactPHP 1.12 | 2,165 | 11.1% | 27.85 ms | 33.82 ms | 0.279 | 72 MB |

Three things stood out.

**The bootstrap is not where the time goes.** The 60-file include costs about 0.05 ms with OPcache; the two queries and the render dominate. That is why PHP-FPM, which pays the bootstrap on every request, and FrankenPHP worker, which boots once, land in the same band. The worker win exists, but only inside FrankenPHP: classic 7.6k → worker 9.6k req/s (+26%) and p99 13.3 → 8.3 ms (-38%).

**The framework around the worker matters more than the worker.** RoadRunner (0.90 ms of CPU per request) and AMPHP (0.97) spend as much on PSR-7 request objects, Goridge IPC or the event loop as the bootstrap saves. Workerman and Swoole avoid that layer and halve the CPU: 0.37-0.43 ms per request against 0.60 for FPM. ReactPHP has the lowest CPU per request of all (0.28 ms) and the worst throughput at 100 connections (2.2k req/s, 27.9 ms p50): one event loop per process is efficient and does not scale for this concurrency profile.

**CGI is not slower than FPM.** It is inside the spread, and it uses far more memory in the real-app layer because it has no shared pool manager. There is no production reason to move to it.

## Layer 1: the applications you actually run

No page cache, 100 connections, medians of three rounds. `0` non-2xx in every row.

| Server | WP post | XF thread | Chevereto home | WP member | XF member | PHP CPU (WP/XF/Chev) |
|---|---:|---:|---:|---:|---:|---:|
| PHP-FPM | 143 | 324 | **1,482** | 137 | **271** | 69.6 / 30.8 / 5.4 ms |
| PHP-CGI | **154** | **348** | 1,674 | **148** | 283 | 69.0 / 31.5 / 5.2 ms |
| FrankenPHP | **157** | 341 | 830 | 143 | 254 | 69.4 / 32.6 / 11.2 ms |

WordPress and XenForo are application-bound. A WordPress post renders in 143-157 req/s and a XenForo thread in 324-348 req/s across three completely different execution models; the difference between servers is smaller than some servers' own round-to-round spread. FrankenPHP is competitive there — and then loses 44% on Chevereto (830 vs 1,482 req/s, 11.2 ms of PHP CPU against 5.4), with no redirects and no errors, just a heavier request path for that application.

This is the part the marketing tables cannot show: the server does not make the page cheaper. Two database statements, a 13 KB render and a 5 ms CPU budget per request are what they are.

## The verdict

- **Keep PHP-FPM.** It is the fastest or within noise of the fastest on every application tier, it has a pool manager, a slow log, graceful reloads and the lowest memory of the FastCGI options. Nothing here justifies replacing it.
- **Consider Swoole/OpenSwoole or Workerman only with an application project.** They are the real 1.4-1.6x win, and they require every PHP file to be safe in a long-lived process: static state, leaked request data, sessions, `$_ENV` not being reset. WordPress, XenForo and Chevereto are not written for it; you would need a worker-safe front controller and a compatibility pass, and XenForo would need an add-on.
- **FrankenPHP is a viable server, not a faster one.** Worker mode is a genuine improvement over its own classic mode and it uses the least memory of the FastCGI-style group (152 MB), but it does not beat FPM on this workload and regresses Chevereto. Its embedded PHP 8.6 is convenient and another thing to track.
- **RoadRunner and AMPHP are slower than FPM** on this workload. ReactPHP is efficient per request and wrong for 100 connections.
- **If you want a big PHP win, it is still cache and queries.** The same host does 115k-144k req/s on cached guest pages versus 143-1,674 on the uncached ones. A different PHP server moves the needle by less than 10%.

## The security finding that came out of the same run

The cycle's other change started as an audit item and turned into a real leak. The guest caches bypassed on a fixed list of session cookie names and treated every other cookie as page-neutral. A plugin session or an SSO token outside that list could render a personalised page that was then stored for every guest.

The caches are now **default-deny**: one `map` with one PCRE pass per request (and no regex when there is no Cookie header) accepts only analytics/consent cookies, CDN and bot-management cookies, and the applications' own page-neutral guest cookies. Anything unknown is rendered by PHP and never stored. A language selector still bypasses, because it changes the page until it joins the cache key.

The end-to-end Anubis run caught what the source tests could not. Anubis sets `techaro.lol-anubis-auth-*` on every visitor; the first version of the rule treated it as unknown, so **every** request on an Anubis-fronted host became a cache bypass. With the pass cookie in the allowlist the same request is a cache hit, and Anubis costs 0.0008 ms of CPU per request.

That is the argument for keeping the disposable-host audit: the unit tests knew the rule, the cookie suite knew the applications, and only a request through the real proxy chain found the cookie the proxy itself sets.

## What was measured, in one place

- 11 runtimes on one application-shaped workload, 3 rounds each.
- 3 servers on 3 real applications, 5 tiers, 3 rounds, no page cache.
- 1,612 unit checks, 227 dry runs, 67 security probes, 86 guest-cache cookie cases, 0 unexpected responses from the functional suite.
- One install + two `--optimize` runs: 3,076 configuration facts, zero differences.
- Restored to the same 696-package manifest afterwards.

The harness is in the repository: `tests/stress-site/php-server-shootout.sh` and
`tests/stress-site/php-appsim/`. The full method and every row are in the
cycle's `AUDIT-20261123-1.21.61.md`, linked from the repository. Numbers age;
the method is what you can repeat.
