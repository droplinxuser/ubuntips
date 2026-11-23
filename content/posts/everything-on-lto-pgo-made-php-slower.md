---
title: "Everything on: LTO, PGO and -march=native made PHP 8.5 slower"
date: 2026-11-23T19:30:00+08:00
description: "A follow-up to the four-build PHP test: turn on every CentminMod compiler option, add LTO and two-stage PGO trained on real XenForo traffic, and compile every module from source. The result is 5 to 10 % slower than the distribution package, not faster."
tags: ["php", "php-fpm", "opcache", "jit", "pgo", "lto", "xenforo", "performance", "benchmark", "compiler"]
---

The [last post](/posts/is-a-compiled-php-faster/) compared Sury, Ubuntu's archive, and a source build with `-O3 -march=native`, and found nothing: the tracing JIT generates the hot code at run time, so the C compiler barely matters. The obvious follow-up question is fair: **what if you turn on everything?** LTO, profile-guided optimisation, function alignment, the interposition and PLT switches, and every module compiled from source against the new tree.

So I did that. The short version: **the more I enabled, the slower it got.** LTO alone was neutral. PGO, alone or with LTO, cost 5–10 % on the application tiers and 18–25 % on a CPU-only probe.

## What "everything on" means

| Flag | Why it is there |
|---|---|
| `-O3 -m64 -march=native -mtune=native` | CentminMod's Intel path (`MARCH_TARGETNATIVE=y`) |
| `-falign-functions=32` | CentminMod's `GCC_FALIGN_FUNCTION=y` |
| `-fno-semantic-interposition` | let the optimiser assume no symbol interposition, so it can inline across the binary |
| `-flto -fno-fat-lto-objects -fuse-linker-plugin` | CentminMod's `PHP_LTO=y` shape, with bfd instead of gold |
| `-fprofile-generate` → train → `-fprofile-use` | CentminMod's `PHP_PGO=y`, but trained on real XenForo and WordPress traffic instead of phpbench |
| `--disable-gcc-global-regs` | PHP's own switch for LTO builds |

The module set is XenForo's, compiled into the binary: mysqli, gd (jpeg, freetype, webp), curl, mbstring, xml/dom/simplexml, zip, gmp, exif, bcmath, sockets, OPcache with the JIT. On top of that, **redis 6.3.0 and imagick 3.8.1 were built from PECL sources with the new tree's `phpize`**, so the extensions are not borrowed from the distribution either (except that the shared library dependencies — libgd, libcurl, libxml2 — stay system packages, which is what "source compiled PHP" means in practice).

One module would not build: **igbinary 3.2.16 still includes `ext/standard/php_smart_string.h`, which PHP 8.5 removed.** Redis 6.3.0 detects that and builds without it. XenForo's core Redis provider uses PHP's serializer, so the application does not notice.

## How PGO was trained

PGO has two stages and the training has to match what you measure, so I built an instrumented `php-fpm`, put it behind the same Angie vhosts, and drove the real applications through it:

| Training run | Load | Requests/s |
|---|---|---:|
| XenForo member thread | 12 connections, 30 s | 144 |
| XenForo member home | 12 connections, 20 s | 258 |
| WordPress member home | 12 connections, 15 s | 94 |
| WordPress member post | 12 connections, 15 s | 93 |
| C-builtin probe | 12 connections, 10 s | 1,053 |

That produced **779 `.gcda` files**. The rebuild with `-fprofile-use` reported zero missing profiles, so every object really was optimised with data. Then the arm was switched back in and the benchmark ran exactly like the others: clock pinned at 3.6 GHz, 3 rounds, arms rotated, 100 connections, 10 s per tier.

## The numbers

Sury is the package every host runs today (8.5.13). "LTO" adds LTO and the alignment/interposition flags to the previous post's `-O3 -march=native` build (which measured flat on all four tiers). "LTO+PGO" adds the two-stage profile. "PGO" is the same without LTO. Each arm is its own 3-round run against Sury on the same host and clock; medians, spread in parentheses.

| Tier | Sury | + LTO | + LTO + PGO | + PGO only |
|---|---:|---:|---:|---:|
| XenForo member thread | 246 (244–247) | 236 (219–246) | 213 (211–221) | 230 (213–231) |
| XenForo member home | 419 (408–422) | 393 (365–421) | 359 (359–385) | 398 (368–399) |
| WordPress member home | 141 (129–142) | 140 (137–140) | 131 (130–131) | 133 (133–133) |
| WordPress member post | 138 (127–139) | 138 (128–139) | 131 (121–131) | 131 (121–131) |

The source-native column is from the previous post and is flat; the absolute Sury numbers move a little between runs because the host restarts PHP between arms, so compare each row with its own Sury column, not across rows.

Against Sury: LTO is a wash (−0.7 % to +0.0 %). LTO + PGO is **−9.7 % on the XenForo thread, −9.1 % on the home page, −3.0 % on WordPress home, flat on WordPress post**. PGO alone is **−6.5 %, −5.0 %, −5.7 %, −5.1 %**. On the XenForo tiers the spreads do not overlap; on WordPress the PGO spreads are so tight that the median drop is still the signal.

The cleanest evidence is the CPU-only probe, run 15 times per arm with no web server in the loop:

| Build | JIT | C builtins | Userland loops | Objects |
|---|---|---:|---:|---:|
| Sury | tracing | 3.014 ms | 0.216 ms | 0.523 ms |
| LTO + PGO | tracing | 3.589 ms (+19 %) | 0.226 ms (+5 %) | 0.538 ms (+3 %) |
| Sury | off | 2.537 ms | 0.125 ms | 0.047 ms |
| LTO + PGO | off | 3.160 ms (+25 %) | 0.135 ms (+8 %) | 0.055 ms (+17 %) |

The minimum of 15 runs is shown; medians agree within 1 %. The "everything on" binary is slower **even with the JIT off**, where the interpreter is supposed to be exactly what PGO optimises. So this is not a JIT artefact: the generated code itself is worse for this workload.

## Why would PGO make it slower?

Three things I can point at, and one I cannot rule out:

1. **The profile is collected on an instrumented binary.** Instrumentation adds counters to every edge and runs 1.5–2× slower (144 req/s on the thread during training against 230 after). The edge frequencies it records are real, but the code layout it produces is tuned to a program that spends time updating counters nobody will run in production.
2. **PGO makes GCC more aggressive, not just smarter.** With `-fprofile-use` GCC enables more inlining, loop peeling and function reordering. PHP's interpreter is a very large switch with a lot of cold code; profile-driven inlining can bloat the hot path and cost instruction cache. `-falign-functions=32` adds padding on top of that.
3. **The JIT is itself a big C program.** It compiles PHP code while the request runs, so the profile also steers the optimiser inside the JIT compiler, where the training workload (a fixed set of applications) may not represent the next trace it has to compile.
4. **What I cannot rule out:** a GCC 15 code-generation issue specific to this combination. The result is reproducible across three builds and both applications, but it is one compiler version on one CPU. Re-run the harness before generalising.

The lesson from the previous post still holds and is now stronger: **with `opcache.jit=tracing`, the code that runs your PHP is generated at run time.** Compiler flags reach the interpreter, the runtime helpers and the JIT compiler — never the code that actually renders the page. Optimising that 20 % harder cannot buy 20 %; here it bought negative numbers.

## What failed before it ran

Three build-system traps, in case you try this at home:

* **`-fno-plt` with LTO does not link.** The link failed with hundreds of `undefined reference to '.L1'`-style errors from bfd: PLT-less calls plus LTO partitioning produced local labels with no definition. Dropping `-fno-plt` and `-flto-partition=max` fixed it.
* **PGO rebuild trips over `conftest.c`.** The second `configure` reuses the same `/root/work/php-src-max/conftest.c` path, whose profile from the first stage no longer matches, and GCC treats it as an error (`-Werror=coverage-mismatch`). Deleting the `*conftest*` profile files and adding `-Wno-error=coverage-mismatch` fixes it.
* **A silent training run.** My first training pass finished in 47 seconds instead of 90: the `.url` files written by the exercise script already contain a full URL, and I was prefixing the host again, so `wrk` rejected every URL and the script swallowed the error. 779 `.gcda` files existed anyway, because starting and stopping FPM writes them. If a PGO result looks impossible, check that the training actually made requests.

## What I would do

- **Keep the distribution package.** Sury is as fast as any build measured, nine patch releases newer than the Ubuntu archive, and its extensions are patched for the current PHP (PECL redis did not compile on 8.5 at all until 6.3.0).
- **If you compile anyway, enable LTO only if you want it, and leave PGO off** until you have measured it on your own workload. On this stack it is a 5–10 % tax, not a free win.
- **Measure with the JIT in the state you ship.** A PGO win on a JIT-off interpreter is irrelevant if production runs the tracing JIT.

The harness for all of this is in `tests/bench-php-matrix/` in [ubuntu-setup-script](https://github.com/droplinxuser/ubuntu-setup-script): `build-php-max.sh` (plain/LTO/PGO stages, every module from source), `train-php-pgo.sh`, `switch-php-arm.sh`, and `bench-php-sources.sh`. The host went back to its pristine 696-package manifest afterwards.
