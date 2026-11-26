---
title: "Moving servers off Sury PHP and Angie packages: five bugs I found first"
date: 2026-11-26T11:00:00+08:00
description: "Before running my setup script's one-time migration on live servers, I rebuilt their package-based setup on a test box and in VMs, for every PHP series from 8.1 to 8.6 and for Ubuntu 24.04. The migration worked on the first host shape I had tested, and broke in five different ways on the others. Fixed, it makes cached pages 13-19 % faster and PHP pages up to 14 % faster."
tags: ["php", "nginx", "valkey", "migration", "ubuntu", "jit", "opcache", "benchmark"]
---

My servers still run the old way: Angie from its apt repository, PHP from the Sury repository, Valkey from Ubuntu's package. The current version of [my setup script](/posts/nginx-from-source-and-no-packages/) compiles nginx, PHP and Valkey from source instead, and its `--optimize` run migrates an old host once: it builds everything while the packages keep serving, switches each service over, checks it, and only then removes the packages.

I had tested that migration on one host: Ubuntu 26.04 with PHP 8.5. My live servers are not all like that. Some run Ubuntu 24.04, some PHP 8.3. So before touching any of them, I rebuilt the old setup with the previous release of the script and migrated it, for every PHP series from 8.1 to 8.6:

- PHP 8.5 with a second PHP 8.3 still running, on the test box itself (a Xeon E-2236);
- Ubuntu 24.04 with PHP 8.3 and Ubuntu's Valkey 7.2, in a VM;
- single PHP 8.1, 8.2, 8.4 and 8.6 hosts, in 8 GB VMs;
- a 2-core, 4 GB proxy that runs Angie only.

After each migration I ran the same checks: a walk through WordPress, XenForo and Chevereto as guest, member and admin, 78 security probes, and 109 cache-safety checks.

## 1. Cron ran PHP without its extensions

During the switch, the migration hands `/etc/php/8.5/cli` over to the new build. But `/usr/bin/php8.5` stays Sury's binary until the old packages are removed. In that gap, Sury's PHP starts with a configuration directory it no longer recognises: it loaded 2 of the 7 extensions the apps need.

On a single-version host that gap lasts seconds. On the host with a second PHP version it never ends, because the Sury packages cannot go while 8.3 still uses them. My script runs WordPress and XenForo jobs every minute through `/usr/bin/php`, and every one of them would have failed quietly.

The fix: at the switch, the old binary is moved aside with `dpkg-divert` and the new CLI takes its path. A package update during the gap still writes to the moved-aside copy, never to the path cron uses.

## 2. Valkey did not compile on Ubuntu 24.04

The 24.04 host built nginx and PHP fine, and stopped at Valkey:

```
fmacros.h:83:5: error: expected parameter declarator
   83 | int sprintf(char *str, const char *format, ...)
```

Valkey re-declares `sprintf` to mark it deprecated. With `_FORTIFY_SOURCE=3`, Ubuntu 24.04's glibc defines `sprintf` as a macro when clang compiles. Valkey's Lua module includes the header after `<stdio.h>`, so the declaration turns into garbage. 26.04's newer glibc does not use that macro, which is why I never saw it. The build now skips that one declaration where `sprintf` is a macro. Ubuntu's Valkey kept serving until then, so nothing broke. Afterwards the 7.2 package was replaced by 9.2.

## 3. 61 MB of JIT buffer crashed PHP

The 8 GB VMs found the strangest one. On PHP 8.1, pages loaded fine, but logins and form posts answered 502. The kernel log showed workers dying on a jump into JIT code:

```
php-fpm: segfault at 5ff00a30 ... error 15 in anon_hugepage
```

On PHP 8.6 the service did not start at all: `mprotect() failed [22]`. My script sizes OPcache at RAM/16 and the JIT buffer at an eighth of that. With 7.9 GB that is 495 MB and 61 MB, two odd numbers, and with huge pages the JIT region ends up badly aligned. I tested it on the 8.1 build, 40 rounds of five pages each:

| OPcache / JIT | segfaults | 502s |
|---|---:|---:|
| 495 / 61 MB | 10 | 200 |
| 495 / 60 MB | 0 | 0 |
| 496 / 61 MB | 0 | 0 |
| 494 / 60 MB | 0 | 0 |

PHP 8.5 accepts either. The old Sury packages for 8.1, 8.2, 8.4 and 8.6 fail the same way. Both sizes are now rounded down to whole 2 MB. My live PHP servers have 32 GB or more and already used 512/64, so they were never affected.

## 4. "Reload: OK", and PHP was down

While I hunted that bug, the script itself took PHP down. It wrote the bad JIT size, tested the config once, and that test passed. `systemctl reload` returned success. The re-executed master then exited half a second later. The report said "Reload: OK".

Reloads now wait three seconds and check that the master is still alive. A failed reload rolls back and starts the service again. And a PHP service that had crashed (not one I stopped myself) is started again once its new configuration passes `php-fpm -t`.

## 5. PHP 8.6 drops old names that extensions still use

PHP 8.6 removed a pile of old compatibility macros: `zval_dtor`, `INI_STR`, `XtOffsetOf` and others. The igbinary and redis extensions still use them. Sury patches its own packages for that, and now my build restores those names too. That was enough for igbinary.

phpredis 6.3.0 needs more than that: its session code uses internals that 8.6 changed. So for now the script knows redis builds up to 8.5. An 8.6 host that needs redis (Chevereto, or XenForo with a Redis cache) is refused before anything is built, with that reason, and keeps its Sury PHP. An 8.6 host without them migrates.

## Did it pay off?

After the fixes, every host migrated cleanly and passed all checks, with zero segfaults. A reboot brought every service back. Then I measured what the migration buys. I rebuilt the old PHP 8.5 setup on the test box and ran 12 load tiers, 5 rounds, with the clock pinned at 3.6 GHz. Then I migrated, let the builds optimise themselves under traffic, rebooted, and ran the same tiers again. Medians of requests per second:

| Page | Angie + Sury | compiled | change |
|---|---:|---:|---:|
| WordPress home, guest (cached) | 99,561 | 113,001 | +13.5 % |
| XenForo thread, guest (cached) | 128,373 | 153,066 | +19.2 % |
| Chevereto explore, guest (cached) | 135,272 | 154,370 | +14.1 % |
| WordPress home, member | 141 | 152 | +7.8 % |
| XenForo home, member | 448 | 492 | +9.8 % |
| Chevereto home, guest (uncached) | 1,668 | 1,894 | +13.5 % |

PHP needed 8-14 % less CPU per page on those tiers. Three member tiers moved less than the round-to-round spread, so I count them as ties.

The live servers get the fixed version on their next `--optimize`. Without these test runs, the first real host to show these bugs would have been a live 24.04 server.
