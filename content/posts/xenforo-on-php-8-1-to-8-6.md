---
title: "XenForo on PHP 8.1 to 8.6: the same build six times"
date: 2026-11-26T05:40:00+08:00
description: "Six PHP series compiled with the same clang recipe and the same extensions, one XenForo forum with 100,000 posts, plain nginx, PHP-FPM and MariaDB. PHP 8.5 and 8.6 serve uncached pages 8-11 % faster than 8.1. 8.2, 8.3 and 8.4 tie, and 8.6 adds nothing over 8.5 yet."
tags: ["php", "xenforo", "benchmark", "nginx", "mariadb", "opcache", "jit", "clang"]
---

[My setup script](/posts/nginx-from-source-and-no-packages/) builds PHP from php.net source, any series from 8.1 up. That makes a fair version test easy for once. Every series gets the same compiler, the same flags, the same extensions and the same pool, so the PHP version is the only thing left that differs.

The question is the obvious one for a forum operator: does upgrading XenForo's PHP still buy speed, and from which version on?

## The setup

- **Host:** the Xeon E-2236 test host (6 cores, 12 threads, 62 GB), Ubuntu 26.04, clock pinned at 3.6 GHz, mitigations off (the host's standing benchmark state).
- **Stack:** compiled nginx 1.31.10, PHP-FPM, MariaDB 11.8. No Valkey, no Elasticsearch, no cache add-ons. XenForo 2.3.13 keeps its sessions in MariaDB and has no cache backend, as an out-of-the-box install does.
- **PHP:** 8.1.34, 8.2.36, 8.3.37, 8.4.28, 8.5.13 and 8.6.0, each built with clang 23 and ThinLTO, without BOLT. All six have the same 27 extensions: XenForo's set without redis and igbinary, which do not build on 8.6 yet.
- **Pool and OPcache:** the same file on every arm. 12 static workers, OPcache 512 MB, tracing JIT with a 64 MB buffer, huge code pages on.
- **Forum:** 20,000 users, 10,000 threads and about 100,000 posts, generated with the Seeder add-on from a fixed seed.

Four tiers, each checked for HTTP 200, a page marker and the expected cache status before a run counts:

| Tier | What it requests |
|---|---|
| T1 | the forum home as a guest, served from nginx's page cache |
| T2 | the same page as a guest with the cache bypassed, so PHP renders it |
| T3 | the forum home, logged in |
| T4 | a logged-in thread with the median number of replies |

Each tier ran at two loads: `wrk -c100` (saturated) and `-c8` (no queue). There were 5 rounds, with the arm order reversed every other round, and a cold restart of PHP-FPM on each switch. The figures are the median of the rounds, with min-max spread.

## Results

Requests per second at 100 connections, change against PHP 8.1 in brackets:

| PHP | T1 cached | T2 guest uncached | T3 member home | T4 member thread |
|---|---:|---:|---:|---:|
| 8.1 | 135,658 | 343 | 308 | 319 |
| 8.2 | 135,739 | 364 (+6.1 %) | 326 (+5.8 %) | 335 (+5.0 %) |
| 8.3 | 135,855 | 362 (+5.5 %) | 325 (+5.5 %) | 333 (+4.4 %) |
| 8.4 | 135,813 | 363 (+5.8 %) | 326 (+5.8 %) | 334 (+4.7 %) |
| 8.5 | 135,786 | 380 (+10.8 %) | 336 (+9.1 %) | 342 (+7.2 %) |
| 8.6 | 135,884 | 381 (+11.1 %) | 336 (+9.1 %) | 344 (+7.8 %) |

Every PHP row had a spread under 1.6 %, and no request failed. The c8 runs gave the same order and nearly the same gaps: 8.5 and 8.6 were +8 to +11 % over 8.1, and 8.2 to 8.4 were +4 to +7 %.

PHP-FPM CPU time per request says the same thing without depending on throughput:

| PHP | T2 | T3 | T4 |
|---|---:|---:|---:|
| 8.1 | 27.1 ms | 31.4 ms | 30.7 ms |
| 8.4 | 26.1 ms | 29.2 ms | 28.9 ms |
| 8.5 | 23.9 ms | 27.1 ms | 27.0 ms |
| 8.6 | 23.8 ms | 26.9 ms | 26.8 ms |

## What it means

- **Cached guests do not care.** T1 never reaches PHP, and all six arms land within 0.2 % of each other. That makes it a good check that the host itself did not drift between arms.
- **There are two steps, not a slope.** 8.1 to 8.2 is worth about 5-6 %. 8.3 and 8.4 add nothing measurable over 8.2: their differences are inside the spread. 8.5 is the second step, another 3-5 %.
- **8.6 ties with 8.5.** It is the first 8.6.0 release, and the gap is within noise on every tier. It also cannot run the PECL Redis extension yet, so a XenForo site with a Redis cache cannot even use it.
- **Logged-in pages gain less than guest pages.** Member pages spend more of their time in MariaDB queries and in permission and session work, and those do not speed up with the PHP version.

So for XenForo on this hardware: PHP 8.5 is the version to run, about 10 % faster than 8.1 on pages PHP renders. Anything from 8.2 to 8.4 is a middle step.

## Caveats

- One confound I could not remove: PHP 8.1 does not compile against OpenSSL 4, so it links OpenSSL 3.6 while the others link 4.1. These are plain-HTTP loopback runs and XenForo makes no TLS calls while rendering a page, so the effect should be nil.
- No BOLT on any arm. BOLT is profile-guided and needs live traffic, and it would have to be trained on each arm separately. The script applies it on `--optimize` under load. [An earlier test](/posts/three-php-fpm-builds-package-clang-lean/) measured a BOLT-optimised build 5-10 % faster than Sury's package on logged-in XenForo pages, so production numbers should sit above these.
- This is one forum on one CPU. A forum with heavy add-ons, or with Elasticsearch search, will show other numbers. The ranking should hold.

The harness is in the setup script's repository under `tests/bench-php-matrix/` (`install-php-series.sh`, `bench-xf-php-series.sh`), along with the raw results.
