---
title: "Setup script 1.22.5, before and after: XenForo 17-32 % faster on the same box"
date: 2026-11-27T23:04:00+08:00
description: "I benchmarked the whole 1.22.5 release against 1.22.4 the way a server gets it: an --optimize run, a reboot, then load. Cached XenForo pages went from 122k to 161k req/s, uncached pages 17-22 % faster, p99 14-20 % lower, and PHP-FPM uses half the memory. Most of it is the kernel; the rest is a new allocator for PHP, a lower Brotli level and AWS-LC under nginx. The benchmark also caught a bug that would have stopped every updated server from rebuilding PHP."
tags: ["xenforo", "nginx", "php", "aws-lc", "mimalloc", "brotli", "kernel", "benchmark"]
---

The 1.22.5 cycle of [my setup script](/posts/nginx-from-source-and-no-packages/) had one rule: an option that is at least 2 % faster on some XenForo tier, and slower on none, becomes the default. An opt-in that turned out no faster gets deleted, code and all. Every candidate was measured alone first. This post measures the release as a whole.

## How I measured

One box, the Xeon E-2236 (6 cores, 12 threads, 62 GB, NVMe RAID0) with Ubuntu 26.04 and its 7.0 kernel, the clock pinned at 3.6 GHz. The same XenForo forum, the same data, the same member account.

For each run, I applied one release the way a server gets it: two `--optimize` runs under background load (build, then the BOLT profile), then a reboot, because the kernel command line is part of the release. After 60 idle seconds, `wrk` ran five rounds of five tiers:

- **guest home, cached:** served by nginx from its page cache;
- **guest home and guest thread, uncached:** a guest cookie that bypasses the cache, so PHP renders every page;
- **member home and member thread:** logged in, always PHP.

I alternated the releases: 1.22.4 three times and 1.22.5 twice, so a drift in the box would show up as disagreement between runs of the same release. It didn't. Each tier's number below is the mean of the runs' medians.

## The result

| Tier | 1.22.4 (req/s) | 1.22.5 (req/s) | Change |
|---|---:|---:|---:|
| Guest home, cached | 121,862 | 160,848 | +32.0 % |
| Guest home, uncached | 545 | 657 | +20.6 % |
| Guest thread, uncached | 379 | 442 | +16.7 % |
| Member home | 487 | 593 | +21.7 % |
| Member thread | 290 | 339 | +16.9 % |

The 1.22.4 runs agreed within 2 % on every PHP tier, and so did the 1.22.5 runs, so these gaps are not noise. Tail latency fell with them:

| Tier | p99, 1.22.4 | p99, 1.22.5 | Change |
|---|---:|---:|---:|
| Guest home, cached | 0.90 ms | 0.77 ms | -14 % |
| Guest home, uncached | 207 ms | 172 ms | -17 % |
| Guest thread, uncached | 338 ms | 282 ms | -17 % |
| Member home | 242 ms | 194 ms | -20 % |
| Member thread | 467 ms | 402 ms | -14 % |

And memory, summed over every process while `wrk` ran:

| | 1.22.4 | 1.22.5 |
|---|---:|---:|
| PHP-FPM | 641 MB | 322 MB |
| nginx | 224 MB | 187 MB |

One detail in the raw rows: the first cached round of every 1.22.4 run scored zero. Right after the reboot it met the page cache still being filled, and the harness rejects a round whose cache status is not a hit. With that zero counted, each median is the second-lowest good round, at most 0.5 % below the median of the four good rounds. So the cached gain is overstated by at most half a percent.

## Where the gain comes from

The release changed five things at once:

| | 1.22.4 | 1.22.5 |
|---|---|---|
| Kernel | Spectre/Meltdown mitigations on | `mitigations=off` |
| nginx TLS library | OpenSSL 4.1 | AWS-LC 5.15 |
| PHP's malloc | glibc | mimalloc |
| Dynamic Brotli | level 4 | level 1 |
| OPcache | | `enable_file_override=1` |

Two of my 1.22.5 runs had every change but one, by accident (more on that below): PHP kept its 1.22.4 build with glibc's malloc. That splits off mimalloc cleanly:

| Tier | 1.22.5 without the PHP rebuild, vs 1.22.4 | mimalloc on top |
|---|---:|---:|
| Guest home, cached | +32.0 % | 0.0 % |
| Guest home, uncached | +16.7 % | +3.3 % |
| Guest thread, uncached | +12.5 % | +3.8 % |
| Member home | +17.7 % | +3.4 % |
| Member thread | +13.1 % | +3.4 % |

Inside the first column, my earlier one-at-a-time runs put dynamic Brotli level 1 at about +4.5 % on the PHP tiers and AWS-LC at a few percent on the cached tier. The rest is the kernel. In round numbers:

- **`mitigations=off`:** about +26-29 % on cached pages and +8-13 % on PHP pages. A cached hit is mostly system calls, and every one paid for the page-table switch and the buffer clearing.
- **Brotli level 1:** about +4.5 % on PHP pages, where nginx compresses each response fresh.
- **mimalloc in PHP:** +3.3-3.8 % on every PHP tier, and all of the halved PHP-FPM memory. The runs without it used 639-641 MB, the same as 1.22.4.
- **AWS-LC:** 2-5 % on cached pages, and a fifth to a quarter less nginx memory in the one-at-a-time runs. PHP pages did not move.
- **`enable_file_override`:** it earned its place earlier in the cycle, at +3.9 % on member home next to two baselines. In the later sweep it was inside the noise, so most of the 1.22.5 gain comes from the other four.

## What each one costs

**`mitigations=off`** removes the kernel's protection between local processes. My servers are single-tenant, run only my own code and accept SSH keys only, so a hostile local process is already a lost server. On a shared host, keep the mitigations on.

**Brotli level 1** reverses [the compression post](/posts/who-compresses-a-logged-in-xenforo-page/), which measured the same speed gain and kept level 4 for its cost: 40 % more bytes on a member thread page (23.9 KB instead of 17.1 KB). This time I measured the guest home page, where the cost is 16 % (11.1 KB instead of 9.5 KB), so it depends on the page.

That post already said an origin whose only client is Cloudflare can take level 1, and every one of my servers is such an origin. The extra bytes travel from the origin to Cloudflare, whose network is not the bottleneck. A server that answers visitors directly pays them on every page. `SETUP_BROTLI_LEVEL=4` restores the old level. Levels 2 and 3 fell between 1 and 4 on the PHP tiers.

**`enable_file_override`** answers `file_exists()` and similar calls for cached scripts from OPcache, so a deleted PHP file can look present until OPcache revalidates it.

**AWS-LC** is a reversal of [the TLS library post](/posts/nginx-with-openssl-aws-lc-or-boringssl/), where OpenSSL stayed the default because the others take features away. The first of those features was kTLS, and kTLS is now gone from the script (see below), so that reason no longer applies. What remains:

- `ssl_conf_command` doesn't exist on AWS-LC, and my config doesn't use it.
- PHP stays on OpenSSL, since its OpenSSL extension supports neither alternative.
- Session resumption is half there. I wrote that AWS-LC has no shared session cache, and that was too strong. With session tickets off, TLS 1.2 sessions resume from nginx's shared cache (five of five reconnects). TLS 1.3 sessions do not: AWS-LC resumes them only through tickets, while OpenSSL resumed them from the cache.

  So a TLS 1.3 client that reconnects straight to the origin pays a full handshake. With an ECDSA certificate, AWS-LC's full handshake costs about half the CPU of OpenSSL's. With the RSA-2048 certificates the script makes for Cloudflare's Full mode, it costs about 20 % less. Behind Cloudflare the edge keeps its origin connections open anyway.

**mimalloc** has no cost I could find. PHP's own memory manager still serves request memory; mimalloc only replaces malloc underneath it.

## What got deleted

These were opt-ins that measured no faster, so their code is gone. A config that still names one gets a warning and the default; nothing fails.

- **`TLS_LIB=openssl`:** slower than AWS-LC on cached pages.
- **`TLS_LIB=boringssl`:** below AWS-LC, with no OCSP stapling either. With both gone, nginx no longer builds OpenSSL at all.
- **`PHP_BUILD_MALLOC=glibc` and `jemalloc`:** below mimalloc on every tier.
- **mimalloc and jemalloc for nginx:** within the noise of glibc's malloc.
- **`BOLT_NOLBR`:** a BOLT profile from plain cycle samples, for CPUs without branch records. It was 1-3 % slower than no BOLT at all.
- **kTLS:** 12-36 % slower on the cached XenForo page, on both the Xeon and an AMD EPYC, and no faster on PHP pages. This reverses part of [the kTLS post](/posts/ktls-with-nginx-and-a-200-ms-stall/). That post measured 40-44 % less nginx CPU on large files and kept `KTLS=1` for servers that mainly send them.

  That saving was real. But my servers send forum pages through Cloudflare, not downloads, and AWS-LC has no kTLS anyway. A large-file server that terminates its own TLS would be better served by a different build than this script's.

## The bug the benchmark found

My first two 1.22.5 runs were only 13-18 % faster on PHP pages, and PHP-FPM memory didn't move at all. The `--optimize` log explained it: the PHP build had failed, with `libxml/parser.h` not found. The safety net worked as designed. It stopped before switching anything, PHP kept running on its 1.22.4 build, and the run exited with an error. But the same thing would have happened on every server that updated, on every run.

The cause was in 1.22.5 itself. The script caches the static libraries PHP links against, keyed by CPU, compiler and versions. 1.22.5 changed how the key is computed, so the cache migration renames an existing cache to its new key instead of compiling every library again. The rename was the bug: the libraries' pkg-config and libtool files still named the old directory, so the compiler looked for headers in a directory that no longer existed.

Every unit test passed, because the fake cache in the test had no pkg-config files. Now the migration rewrites the old name in every file of the cache. Both names are `deps-` plus 16 hex digits, so even binaries keep their length. If any reference survives, it drops the cache and builds every library. The test now includes a pkg-config file and a binary.

I then recreated a 1.22.4 cache on the box and ran 1.22.5 twice more. Both built PHP on mimalloc, and those two runs are the 1.22.5 numbers above. The rule I take from this: a release benchmark has to install the release the way a real update does, from the previous version's state. A clean install would have passed.

The raw rows, the per-option sweeps and the harness are in the setup script's repository, in `tests/stress-site/AUDIT-20261127-1.22.5.md`.
