---
title: "Three php-fpm builds side by side: Sury, clang + BOLT, and everything from source"
date: 2026-11-24T20:00:00+08:00
description: "My earlier compiled-PHP tests found nothing. Two flaws in my build harness were hiding the gain: GCC was built without its global registers, and BOLT was never tried. With both fixed, a BOLT-optimised php-fpm is 5-10 % faster on logged-in XenForo pages. Building every library from upstream as well added nothing measurable."
tags: ["php", "php-fpm", "clang", "llvm", "bolt", "lto", "xenforo", "wordpress", "chevereto", "performance", "benchmark"]
---

Two earlier posts on this blog, [Is a compiled PHP faster?](/posts/is-a-compiled-php-faster/) and [Everything on: LTO + PGO made PHP slower](/posts/everything-on-lto-pgo-made-php-slower/), concluded that building PHP yourself buys nothing once the tracing JIT is on. This round says that was wrong, or at least incomplete. Two flaws in my build harness were hiding the gain, and the tool that finds it is one I had never tried: **LLVM BOLT**.

Short version: **a php-fpm built with clang, ThinLTO and BOLT serves logged-in XenForo pages 5-10 % faster than Ondřej Surý's package.** Compiling every library from upstream on top of that (newest OpenSSL, ICU, curl, PCRE2, all static) added nothing I could measure. My setup script now offers all three builds behind one switch, so I can measure them again whenever versions change.

## What was wrong before

* **GCC was built with its global registers off.** PHP's GCC build keeps the VM's hot state in fixed CPU registers (the "HYBRID" VM). My harness had turned that off, so every GCC arm started handicapped.
* **BOLT was never in the matrix.** PGO and LTO make the compiler smarter about what to inline. BOLT works on the finished binary instead: it records which branches the live workers actually take (with `perf` and the CPU's branch records) and lays the machine code out so the hot paths sit together and the cold paths move out of the way. PHP's interpreter is a big binary with a small hot core, which is exactly the kind of program that benefits.

PHP 8.5 built with clang 19 or newer also uses a newer interpreter design (the "tail-call" VM), which GCC can't build. That's part of why the clang arms lead.

## The compiler round

All on the same Xeon E-2236 test host (6 cores, 12 threads), PHP 8.5.13, the same `php.ini` (OPcache 512 MB, tracing JIT 64 MB), 12 PHP-FPM workers, Angie in front, a seeded XenForo forum with 20,000 users and 103,000 posts. Load came from `wrk` on the same machine, five rounds with the order rotated each round, and the CPU clock pinned at 3.6 GHz so turbo fade couldn't favour whoever went first.

| Build (logged-in XenForo thread / home, vs Sury) | Thread | Home |
|---|---:|---:|
| clang `-O3 -march=native` | +2.9 % | +2.6 % |
| clang + ThinLTO | +6.7 % | +6.5 % |
| clang + PGO | +3.8 % | +4.3 % |
| clang + PGO + BOLT | +9.0 % | +9.1 % |
| GCC with global registers | +1.9 % | +2.2 % |
| clang + ThinLTO + BOLT | **+11.0 %** | **+13.2 %** |

PGO turned out not to be needed: ThinLTO plus BOLT beat PGO plus BOLT, and it needs no training build. Cached guest pages didn't move at all, because Angie serves those without touching PHP.

## Building it so the package still works

A custom PHP binary is only useful if updates don't break it. My first version keeps everything the package provides: it compiles **the package's own PHP version with exactly the package's compiled-in core**, linked against Ubuntu's libraries like the package, so Sury's shared extensions, `php.ini`, pools and systemd unit keep working unchanged. Only the binary that systemd starts changes, through a unit drop-in. Before switching over, the new binary has to report the same modules and the same INI defaults as the package (`php-fpm -i`), and `php-fpm -t` has to accept the live pool configuration.

An APT hook watches for security updates: the moment the package's PHP version changes, the server goes back to the package binary and rebuilds in the background. BOLT runs after the site has served real traffic for a while; it samples the workers for 60 seconds and rewrites the binary.

## The "everything from upstream" version

Then I went further: the newest PHP from php.net, redis and igbinary from PECL, and every library php-fpm links (OpenSSL 4.1, ICU 79, curl 8.23, PCRE2 10.49, libxml2, zlib, libsodium, GMP, libjpeg-turbo, libpng, libwebp, libzip) from each project's own releases, compiled with the same flags, linked statically, with ThinLTO across PCRE2, zlib and libxml2. The compiler, LLVM 23, came from apt.llvm.org rather than Ubuntu's archive. Only glibc, libstdc++ and libsystemd still come from Ubuntu. The versions sit in a small file beside the setup script, each one `latest` or a pin, and a daily timer rebuilds when any project ships a new release.

Getting there took three fixes:

* **igbinary 3.2.16 doesn't build against PHP 8.5.** It includes a header PHP 8.5 removed. In PHP 8.4 that header held a single line including Zend's string header, so recreating the wrapper fixes it (Sury patches it the same way).
* **BOLT refused the binary.** GMP's hand-written x86-64 assembly keeps jump tables of code offsets in data, and BOLT can't move code that data points into like that: 88 such references. GMP is only used for push-notification crypto, so it is now built in plain C, and BOLT is happy.
* **The binary is 100 MB on disk**, mostly ICU's data plus the relocations BOLT needs. Those sections aren't loaded into worker memory, so RAM use doesn't change.

The result: **level with the simpler build.** On the forum it measured +7.9 % / +9.3 % against the simpler build's +10.4 % / +10.1 %, a difference inside the run-to-run spread. With the tracing JIT on, page time goes into PHP's VM and the JIT's generated code, not into OpenSSL or PCRE2. Newer libraries are nice to have, but they don't make pages faster.

## Only the modules the applications need

The upstream build compiles in only what my three applications use: WordPress, XenForo and Chevereto. I took the list from XenForo's installer checks, Chevereto's own integrity check and WordPress Site Health, and from the code itself. The CLI is out (XenForo's cron still runs on the package's `php`). So are posix, pcntl, sockets, tokenizer, phar, xsl, calendar, ftp and gettext. **ImageMagick is out too**: Chevereto uses imagick only when it's loaded and accepts GD otherwise, and XenForo and WordPress already default to GD, so all three now run on GD.

The same policy now applies to the package build: Sury enables every installed extension for every SAPI, so the setup script disables the extra fourteen for php-fpm only. The CLI keeps all of them. On a server that also runs some other PHP application it leaves everything enabled and says why.

## Three builds, three applications

For the final comparison I wiped the test host back to its original packages, installed from scratch with all three applications, built and BOLT-optimised each mode through the setup script itself, and ran the same benchmark on the smaller standard data set:

| Page (requests/s, median of 5) | Sury package | clang + Sury extensions + BOLT | everything from source + BOLT |
|---|---:|---:|---:|
| XenForo member thread | 224 | 237 (+5.8 %) | 234 (+4.5 %) |
| XenForo member home | 418 | 443 (+6.0 %) | 439 (+5.0 %) |
| WordPress member home | 139 | 132 (−5.0 %, wide spread) | 142 (+2.2 %) |
| Chevereto home, uncached | 1,228 | 1,328 (+8.1 %) | 1,339 (+9.0 %) |
| XenForo guest home, cached | 116.4k | inside the spread | 0.0 % |

All three builds passed the same functional, security and cache tests with all three applications, including Chevereto uploads on GD. One thing changed from the forum round: there, the BOLT profile came from XenForo traffic only, and XenForo gained 10 %. Here, one profile has to serve three applications, and XenForo's share drops to about 6 %. If a server runs mainly one application, profile it on that application.

## What I'm running

The default stays the package: no toolchain on the server, and Sury's security updates as soon as they're published. For a busy XenForo forum, the clang build with BOLT is the one I'd pick. It's the simplest of the compiled builds, keeps the package's extensions, and has the best member-page numbers. The everything-from-source build stays available, so I can run this comparison again the next time OpenSSL, ICU or LLVM ships a major version.
