---
title: "Compiling Valkey, and the BOLT flag that gave my binaries an executable stack"
date: 2026-11-25T13:00:00+08:00
description: "Valkey from source was 35 % slower until I stopped passing CFLAGS on make's command line. Then its unit refused the BOLTed binary, which exposed an executable stack in my compiled PHP and Angie too. Plus nginx vs Angie, compiled the same way."
tags: ["valkey", "redis", "nginx", "angie", "php", "clang", "bolt", "lto", "hardening", "elasticsearch", "mariadb", "performance", "benchmark"]
---

[The last post](/posts/compiling-angie-and-the-missing-hardening/) compiled Angie and fixed the hardening my compiled PHP was missing. This round added Valkey, a single `--source=` switch for all the builds, and a few more questions: could Elasticsearch and MariaDB be compiled too, and is nginx faster than Angie once both are built the same way? Same Xeon E-2236 test host, WordPress, XenForo and Chevereto, rotated rounds, clock pinned.

## One switch

`--source=all`, `--source=angie,php` or `--source=none`, like `--others`. A fresh install uses the packages; a plain `--optimize` keeps whatever builds the server already runs.

## Valkey was 35 % slower, then it wasn't

My first Valkey 9.2 build lost to Ubuntu's 9.0.6 package by 32-41 % on pipelined requests. Counting instructions per request with `perf stat`, which CPU contention cannot skew, made the cause obvious:

| Build | Instructions per pipelined GET/SET |
|---|---:|
| Ubuntu's package | 6,152 |
| Upstream defaults, gcc or clang | 5,770 |
| Mine, `make CFLAGS="..."` | 9,430 |
| Mine, `CFLAGS="..." make` | 5,926 |

A variable on make's command line overrides the assignment in every sub-make. Valkey builds its bundled jemalloc and Lua with their own `-O` flags, and my `CFLAGS=` replaced them with flags that had no `-O` at all, so the allocator ran unoptimised. Passed through the environment instead, the same flags leave the dependencies alone. With BOLT on top, the compiled Valkey beats the package by 3 % on pipelined GET and SET and up to 1.5 % on single requests. Valkey is about 0.3 % of a forum page's CPU, though, so nobody will see it on a page.

## The flag that made my stacks executable

Next, the BOLTed Valkey refused to start. Its systemd unit has `MemoryDenyWriteExecute=yes`, and the binary had no `GNU_STACK` program header. I had been running BOLT with `-use-gnu-stack`, which tells it to reuse that header slot for the new code segment it writes. Without the header, Linux gives the process an executable stack.

My compiled php-fpm and Angie had been BOLTed with the same flag for two releases. Their units do not set `MemoryDenyWriteExecute`, so they started fine, with executable stacks. Without the flag, BOLT moves the program headers instead and keeps `GNU_STACK` read-write. Every build now refuses a BOLT output without it, and the existing builds rebuild on the next `--optimize`.

## nginx vs Angie, compiled the same way

Angie 1.12.5 and nginx 1.31.10, same clang flags, OpenSSL, PCRE2, zlib-ng, Brotli and modules, on identical configuration files:

| Cached guest page (req/s) | Angie package | Angie compiled | nginx compiled |
|---|---:|---:|---:|
| XenForo home | 116,785 | 121,482 | 123,007 |
| Chevereto image | 111,749 | 116,491 | 118,296 |
| WordPress home | 76,453 | 79,023 | 79,714 |

nginx is 0.5-1.5 % ahead on cached pages and level on PHP pages. Compiling matters more than the choice between the two.

## What I did not compile

- **More PHP flags.** `-fno-plt` with link-time `-O3` landed inside the noise; a higher inline threshold was 2-4 % slower and 3 MB larger. The shipped build is still 6.5-11.3 % ahead of the package.
- **MariaDB** uses 8-13 % of the server's CPU on a logged-in page. A 10 % faster build would move pages by about 1 %.
- **Elasticsearch** is Java: the JIT already compiles for the exact CPU. I tried a distribution trimmed to what XenForo Enhanced Search needs instead. Elasticsearch 9 refused, one module after another (`x-pack-core`, `x-pack-security`, `apm`, then settings in its keystore and cluster state). Not worth the reindex and the fragility.

## Smaller things

- Only the login brute-force limiter is left; the generic per-IP limits are gone.
- The compiled Angie now includes `auth_basic`. A directive it cannot serve, like `sub_filter`, is commented out with a marker when the build is activated and restored when it is removed.
- Every source archive the builds download has a third copy in a mirror repository, used only when the upstream sources fail and only if it matches a known hash.
