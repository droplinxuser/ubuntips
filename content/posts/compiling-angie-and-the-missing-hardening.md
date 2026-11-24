---
title: "Compiling Angie too, and the hardening my compiled PHP was missing"
date: 2026-11-25T06:00:00+08:00
description: "Angie compiled from source served cached pages 4-6 % faster; zlib-ng cut its gzip cost by a fifth. PGO, AutoFDO and a static glibc were measured; and the from-source php-fpm got back the stack protector and RELRO that upstream clang leaves off."
tags: ["angie", "nginx", "php", "php-fpm", "clang", "bolt", "pgo", "autofdo", "glibc", "zlib-ng", "brotli", "hardening", "performance", "benchmark"]
---

[The last post](/posts/why-the-from-source-php-was-slower/) ended with one compiled php-fpm, built from upstream sources. This time I asked for the rest of the stack: Angie compiled the same way, glibc and libsystemd from source, smaller binaries, zlib-ng and Brotli, and the optimisations a distribution like CachyOS uses. Same Xeon E-2236 test host, fresh install with WordPress, XenForo and Chevereto, rotated benchmark rounds with the CPU clock pinned.

## First, a security gap

Ubuntu's gcc turns on a set of hardening flags by default: stack protector, stack-clash probes, `_FORTIFY_SOURCE`, CET landing pads, full RELRO. Upstream clang from apt.llvm.org turns on none of them. My compiled php-fpm had been built without all five, while the package it replaces has every one. It now passes them explicitly, for PHP and for every library. It costs 0.5-2 % before BOLT, and it stays.

## Angie from source

The configuration I deploy uses a small part of Angie: HTTP/1, 2 and 3, TLS, realip, pre-compressed files, threads and Brotli. The package also carries mail, stream, ACME, WebDAV, mp4 streaming, SSI, gRPC and more. The source build has only what the configuration uses, OpenSSL, PCRE2 and zlib-ng compiled in, clang `-O3 -march=native` with link-time optimisation:

| Cached guest page (req/s) | package | compiled |
|---|---:|---:|
| XenForo home | 115,148 | 122,195 (+6.1 %) |
| Chevereto image | 111,791 | 117,839 (+5.4 %) |
| XenForo thread | 108,464 | 113,621 (+4.8 %) |
| Chevereto explore | 112,752 | 118,060 (+4.7 %) |
| WordPress home | 76,393 | 79,286 (+3.8 %) |
| WordPress post | 73,524 | 76,177 (+3.6 %) |

That was before BOLT. Built the way `setup.sh` now builds it, with BOLT trained on 60 seconds of live traffic, the gains grew: **WordPress guest pages +12.4 % and +11.5 %**, XenForo +6.6 % and +4.4 %, Chevereto +6.1 % and +2.2 %. The binary is 13.5 MB and links nothing from Ubuntu but libc and libm. Logged-in pages didn't change: PHP sets their pace.

The binary has its own prefix, so it loads its own Brotli module from the same `modules-enabled/` directory and reads `/etc/angie` unchanged. Every start runs `angie -t` with the build; a configuration that needs a module the build leaves out sends Angie back to the package.

## Gzip and Brotli

Here Angie compresses the logged-in pages, so compression costs Angie CPU, not PHP CPU. Per XenForo member page:

| Angie CPU per page | package | zlib 1.4 | zlib-ng 2.3.3 |
|---|---:|---:|---:|
| gzip | 1.19 ms | 1.15 ms | **0.94 ms** |
| Brotli (1.2.1 in both builds) | 1.91 ms | 1.83 ms | 1.82 ms |

zlib-ng cut the gzip cost by a fifth. The Angie build uses it. PHP gzips WordPress and Chevereto pages itself so the guest cache can store them compressed, and there zlib-ng in PHP gave **+7.3 % on uncached Chevereto pages**. Both builds use it now. A PHP Brotli extension wouldn't help: none of the three applications compresses with it, and Angie already does.

## PGO and AutoFDO, CachyOS style

CachyOS ships packages built for x86-64-v3, v4 and Zen 4, plus profile-guided builds of selected packages. A binary distribution has to pick a level for everyone. My builds compile on the server they run on, with `-march=native`, which covers the same ground and targets the exact CPU. The missing piece was profile feedback before BOLT. I tried both kinds:

| Logged-in pages vs the package | XenForo thread | XenForo home | WordPress | Chevereto uncached |
|---|---:|---:|---:|---:|
| LTO + BOLT | **+10.6 %** | **+6.8 %** | +6.5 % | +3.8 % |
| instrumented PGO + BOLT | +8.3 % | +6.6 % | **+7.2 %** | **+4.9 %** |
| AutoFDO + BOLT | +6.4 % | +3.7 % | +3.6 % | +0.6 % |

Instrumented PGO means building an instrumented binary, running the real applications on it, then rebuilding with the profile. It came out mixed: slower on XenForo threads, slightly faster elsewhere. BOLT already reorders the code from a profile of the same traffic, and most of what PGO adds overlaps with it. AutoFDO (sampled profiles, the approach CachyOS uses for its kernel) was slower everywhere. Neither is worth a second build and a training run, so the build stays LTO + BOLT.

## A static glibc, and why it isn't the default

glibc 2.44 builds from source and links statically. The first problem: PHP's huge code pages feature copies the program's code to 2 MB pages by remapping it in place, and its remap function called `mmap` and `memcpy`. In a static binary those sit inside the code being remapped, so php-fpm crashed at startup. I patched the function to make its own system calls, and the binary started.

It still served nothing. Every worker died with an assertion inside glibc. When a worker switches to the `www-data` user, glibc reads `/etc/nsswitch.conf`, which on Ubuntu lists `systemd` for user lookups. glibc then loads Ubuntu's `libnss_systemd`, which brings Ubuntu's own glibc 2.43 into a program built with 2.44, and glibc refuses the mix. Making it work would mean shipping a whole private glibc runtime next to the binary. So glibc stays Ubuntu's, like for every other package on the server, and the experiment code is gone.

libsystemd was easier: PHP-FPM calls exactly one function from it, `sd_notify()`, to tell systemd it's ready. A 50-line static implementation of that protocol replaces the library. The compiled php-fpm now links only libc and libm.

## Smaller

The binary that runs is now stripped: 48.4 MB with BOLT, down from 60.4 MB. `xmlreader` is gone (WordPress only uses it when libxml2 is broken). So are about twenty OpenSSL ciphers and protocols nobody here uses, and the linker drops unused code and folds identical functions. Of what remains, 10.4 MB is fileinfo's built-in file-type database, which Chevereto and XenForo need for uploads.

## And the nginx repository's CI

The configuration repository had no CI since 4 November, when the old workflows went with the legacy files. It now installs Angie and runs `angie -t` against the tree and all 14 site templates on every push.
