---
title: "Why my from-source PHP was slower, and the one-line answer: ICU"
date: 2026-11-24T23:00:00+08:00
description: "A from-source php-fpm executed 9 % fewer instructions per page than a clang build using Sury's extensions, yet ran 1-2 % slower. The cause was ICU: the intl extension made the binary 102 MB and multiplied data-TLB misses by 4.5. Without it, the merged build is the fastest: +11 % on logged-in XenForo pages."
tags: ["php", "php-fpm", "clang", "bolt", "perf", "icu", "xenforo", "wordpress", "chevereto", "performance", "benchmark"]
---

In [the previous post](/posts/three-php-fpm-builds-package-clang-lean/) I compared three php-fpm builds: Ondřej Surý's package, a clang + BOLT rebuild that keeps Sury's extensions, and a build where everything is compiled from upstream source. The two compiled builds came out close, each winning on different pages. I wanted to know why, and then merge them into one.

Short version: **the from-source build did less work per page but stalled more, and the reason was ICU**, the Unicode library behind PHP's `intl` extension. Without it, the merged build beats both: **+11 % on logged-in XenForo pages, +8 % on WordPress, +6 % on uncached Chevereto pages** against the package.

## Measuring instead of guessing

Same Xeon E-2236 test host, same PHP 8.5.13 and `php.ini`, 12 PHP-FPM workers, a fresh install with WordPress, XenForo and Chevereto. I built each candidate difference into its own binary, with link-time optimisation but no BOLT, so the build itself was compared and not the BOLT profile. Then I ran `perf stat` on the workers for 20 seconds under the same logged-in XenForo load:

| Build | Instructions per page | dTLB misses (20 s) | Binary |
|---|---:|---:|---:|
| Sury package | 91.6 M | 52 M | — |
| clang + Sury extensions | 93.6 M | 52 M | 21.5 MB |
| everything from source (with intl) | **85.5 M** | **233 M** | 102 MB |

The from-source build runs about 9 % fewer instructions per page. Everything is in one binary, so calls between PHP and its extensions skip the dynamic-linking indirection, and LTO can optimise across all of it. But its data-TLB misses were 4.5 times higher. Those are the misses in the CPU's cache of address translations; each one costs a page-table walk. That's where the gain went: in the rotated five-round benchmark the from-source build came out 1-2 % *behind*.

The biggest thing in that 102 MB binary was ICU and its data tables. None of my three applications needs it:

* XenForo ships Symfony's intl polyfills and only calls intl to romanize URLs, which is off by default.
* WordPress checks `function_exists()` before every intl call.
* Chevereto doesn't use it.

So I dropped intl. The binary went to 60 MB, the dTLB misses went back to 53 M (the same as the package), and it now links nothing from Ubuntu but glibc and libsystemd.

## Two theories that were wrong

* **`-fPIC` vs `-fPIE`.** The from-source build compiled PHP's own code as position-independent *library* code, which reaches global variables through an extra indirection. That sounded like a likely culprit. Rebuilding it as position-independent *executable* code changed nothing measurable.
* **Huge pages hiding the code from BOLT.** My setup turns on `opcache.huge_code_pages`, which copies php-fpm's code into anonymous 2 MB pages at startup. `perf` then can't name the interpreter's functions; 90 % of the cycles showed up as anonymous memory. I suspected BOLT was optimising from a partial profile. It wasn't: sampling with huge pages off profiled 2,549 functions against 2,541 with them on, and the two binaries ran at the same speed.

## The result

Fresh install, five rotated rounds, CPU clock pinned, every build optimised with BOLT from live traffic:

| Page (requests/s) | Sury package | clang + Sury extensions | merged, from source |
|---|---:|---:|---:|
| XenForo member thread | 237 | 258 (+8.9 %) | **263 (+11.0 %)** |
| XenForo member home | 415 | 448 (+8.0 %) | **457 (+10.1 %)** |
| WordPress member home | 139 | 148 (+6.5 %) | **150 (+7.9 %)** |
| Chevereto home, uncached | 1,474 | 1,539 (+4.4 %) | **1,561 (+5.9 %)** |

On every page, the merged build's *slowest* round beat the old clang build's median. So my setup script now has just one compiled option, built entirely from upstream sources with only the modules the three applications use.

## Every download has a backup

A test build stopped when ftp.gnu.org didn't answer for several minutes. Now every download has a second source: the project's own site first, then GitHub or a second official mirror. LLVM itself falls back from apt.llvm.org to its official GitHub release tarball. Published checksums are verified whichever source served the file, and a Git snapshot gets its build scripts generated. PCRE2 and libjpeg-turbo live only on GitHub, so both of their sources are GitHub.

## A benchmark that broke the server

One benchmark run broke halfway through: WordPress returned empty pages, Chevereto returned errors, XenForo requests hung. It wasn't the new binary. Chevereto starts a PHP session file in `/tmp` for every visitor without a cookie. The benchmark was sending 1,500 such requests a second, and over 24 minutes (PHP's default session lifetime) that adds up to about 2 million files. `/tmp` on this server is a memory-backed filesystem limited to about a million files. Once it was full, MariaDB couldn't create its temporary tables, and every site on the server failed.

Real traffic stays far below that rate, and my setup already turns Chevereto's session cleanup on. But if you load-test Chevereto, clear `/tmp/sess_*` between runs. My benchmark script now does.
