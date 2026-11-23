---
title: "Is a compiled PHP faster? Four builds, one Xeon, and a JIT that makes the question moot"
date: 2026-11-23T16:00:00+08:00
description: "Sury packages, Ubuntu's archive, and PHP built from source with -O3 -march=native and only the modules XenForo needs. On a PHP-bound forum the difference was inside the noise, and the reason is the tracing JIT."
tags: ["php", "php-fpm", "opcache", "jit", "xenforo", "wordpress", "performance", "benchmark", "compiler"]
---

Every PHP tuning guide eventually says the same thing: compile PHP yourself, with `-O3 -march=native`, and build only the extensions you use. It sounds free. My stack is PHP-bound — 92 % of a logged-in XenForo thread page is PHP-FPM CPU — so if any of that were true it would be the largest remaining win on the server.

It is not true here, and the reason is more interesting than the result: **with the tracing JIT on, the hot code is generated at run time and never passes through the C compiler at all.**

## Four ways to install the same PHP

The test host is the one I use for these audits: a Xeon E-2236 (6 cores / 12 threads, 62 GB, NVMe RAID0), Ubuntu 26.04, Angie, MariaDB, Valkey, and the same three applications as every cycle — WordPress 7.1.4, XenForo 2.3.13 and Chevereto 4.5.9-pro — with 100 loopback connections through TLS.

| Arm | What it is | Version | Flags |
|---|---|---|---|
| **Sury** | what my [setup script](/posts/one-idempotent-script/) installs | 8.5.13 | `-O2`, generic, hardening, no LTO |
| **Ubuntu** | the 26.04 archive, no third-party key | 8.5.4 | `-O2`, generic, hardening |
| **Source, generic** | php.net tarball, minimal XenForo modules | 8.5.13 | `-O2 -march=x86-64` |
| **Source, native** | same, with CentminMod's Intel flags | 8.5.13 | `-O3 -m64 -march=native` |

The last arm is the interesting one. CentminMod's installer sets `MARCH_TARGETNATIVE=y` and leaves LTO and PGO off by default, which resolves to `-O3 -m64 -march=<cpu> -pipe`; on this Coffee Lake Xeon that is `skylake`. The binary is visibly different: 26,148 AVX2 instructions in `php-fpm` against 171 in the distribution builds.

The source arms use only what XenForo needs: mysqli, gd, curl, mbstring, xml, zip, gmp, OPcache. One wrinkle: PECL redis 6.2.0 does not compile on PHP 8.5 (`php_smart_string.h` was removed) and PECL imagick 3.8.0 predates it, so **redis, igbinary and imagick come from the distribution packages on every arm**. That is not a compromise for this test — it means the extension code is identical and only the PHP binary changes.

All four arms read the same managed `php.ini` and pool: 12 static workers, 512 MB OPcache, tracing JIT with a 64 MB buffer, huge code pages, and an OPcache script table sized for the real file count (130,987, thank you Chevereto's vendor directory). The clock was pinned at 3.6 GHz because this host's turbo is power-limited and PHP CPU per request follows the clock 1:1 — a lesson from the [last cycle](/posts/who-compresses-a-logged-in-xenforo-page/).

## The result: nothing

Three rounds, arms rotated forward and backward inside every round, medians in requests per second with the spread in parentheses:

| Tier | Sury | Ubuntu | Source generic | Source native |
|---|---:|---:|---:|---:|
| WordPress member home | 141 (128–142) | 142 (130–143) | 141 (140–142) | 141 (130–142) |
| WordPress member post | 133 (126–133) | 133 (122–133) | 132 (125–133) | 133 (123–134) |
| XenForo member home | 446 (443–449) | 430 (413–447) | 447 (417–451) | 453 (416–454) |
| XenForo member thread | 248 (248–250) | 250 (231–250) | 244 (231–251) | 252 (234–253) |
| Chevereto guest home (uncached) | 1448 (1439–1489) | 1461 (1368–1478) | 1320 (1317–1415) | 1447 (1292–1460) |

WordPress is flat. XenForo spans −3.8 % to +1.6 % with spreads that overlap the baseline. The only number that looks like a difference is the generic build on Chevereto's uncached home, and that tier is not PHP-bound at all (1.35 cores busy), so it is an outlier rather than a build effect. Nothing clears the ~3 % bar I use for shipping a change.

A CLI probe made the picture sharper. I wrote a small script with three sections — C builtins (json, preg, string functions, hash, sort), object work, and a userland loop — and ran each arm 15 times without FPM, so there is no scheduler noise:

| Section | Sury | Ubuntu | Source generic | Source native |
|---|---:|---:|---:|---:|
| C builtins, ms | 3.018 | 3.013 | 3.184 | 3.076 |
| Objects, ms | 0.519 | 0.530 | 0.519 | 0.527 |
| Loops (JIT), ms | 0.218 | 0.215 | 0.218 | 0.218 |

`-O3 -march=native` is 1.9 % **slower** than Sury's plain `-O2` on the C-builtin section, and the generic source build is 5.5 % slower. The loop section is identical to the microsecond for all four builds.

## Why the compiler cannot help

Two things happen when `opcache.jit=tracing` is on:

1. The hot PHP code is translated into machine code **by the JIT at run time**. That code is the same whichever C compiler built the interpreter, which is why the loop section does not move.
2. The C flags only reach the interpreter's own helpers and the extensions. Since the [previous cycle](/posts/who-compresses-a-logged-in-xenforo-page/) moved HTML compression from PHP to Angie, those helpers are a small share of a real page.

A faster C compiler cannot speed up a workload whose hot path is generated code plus MariaDB I/O. You can see the same effect in the first table: the tier that is most PHP-bound (XenForo member thread) is also the one where all four arms are within 3 % of each other, because all four are running the same JIT-emitted code.

## What about the Ubuntu packages?

Ubuntu 26.04's archive has PHP 8.5.4 with every extension these applications need, and it is exactly as fast as Sury within the noise. I still did not add a `repo=` switch to the installer. Two reasons:

* **Sury is 9 patch releases newer.** 8.5.13 against 8.5.4 is real security and bug-fix content, and PHP security releases land there first.
* **A second packaging path is a second thing to test.** The gain is zero, so the cost has to be zero too.

## PHP 8.6, one more time

I also re-ran the version round trip, since "try the newest that works" is part of every cycle. `--upgrade-php=8.6` took 1:23 and carried 14 extensions with none skipped; going back to 8.5 took 1:12.

| Application | 8.5 | 8.6 | Keep |
|---|---|---|---|
| WordPress 7.1.4 | clean | clean | **8.6** |
| XenForo 2.3.13 | works; 2 vendor files fail `php -l` | production pages work, **debug mode 500s on every page** | **8.5** |
| Chevereto 4.5.9-pro | clean | clean | **8.6** |

The two XenForo vendor files (`braintree/Digest.php`, `laminas-mail/Transport/Null.php`) fail the linter on 8.5 as well; there they only break the payment and mail code paths. On 8.6, XenForo's debug mode turns the deprecations into a 500 on every page, which is enough to keep the forum on 8.5.

## Zero-error, as usual

Fresh install in 3:24 with 0 warnings; 1,496 unit checks, 227 dry runs, 67/67 security probes, 86/86 guest-cache cookie cases, functional suite 0 unexpected on 8.5 and on 8.6; two `--optimize` runs with 0 of 3,285 recorded facts different. The host went back to its pristine 696-package manifest, 0 changed files under `/etc`, mitigations back on. One byte-level detail: the audit's `/etc/hosts` line had been appended to a file without a trailing newline, so removing it with `sed` left one; truncating that byte restored the baseline digest.

## What I would tell the next person

- **Measure the workload, not the compiler.** `-march=native` produced 26,000 AVX2 instructions and zero requests per second.
- **The JIT changes what flags can do.** On a JIT-off stack the interpreter is most of the work and compiler flags matter more; here they reach a shrinking share of the time.
- **Do not build extensions for a new PHP minor without checking.** PECL redis did not compile on 8.5 at all; the distribution's patched build is the one that works.
- **Keep the harness.** The scripts are in `tests/bench-php-matrix/` in [ubuntu-setup-script](https://github.com/droplinxuser/ubuntu-setup-script), so when PHP 8.7 or a new JIT arrives the question can be answered again in an afternoon instead of an argument.
