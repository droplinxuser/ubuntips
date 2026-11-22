---
title: "Angie, nginx, FreeNginx, OpenResty, Tengine or Caddy? The cache decides"
date: 2026-11-23T04:00:00+08:00
description: "Six web servers, one PHP-FPM pool, three real applications and the same load generator. The event loop is not what separates them; a generic full-page cache is, and stock Caddy does not have one."
tags: ["angie", "nginx", "freenginx", "openresty", "tengine", "caddy", "openlitespeed", "benchmark", "xenforo", "wordpress", "chevereto", "php"]
---

Every release of my [provisioning script](/posts/one-idempotent-script/) runs the same audit on a disposable server: clean Ubuntu 26.04, the full stack, three real applications, then load and security tests, then a restore to the exact package set it started with.

This cycle's question was different from the usual tuning pass: **which web server should actually sit in front of WordPress, XenForo and Chevereto?** Angie is the current default. nginx is the obvious alternative, and the forks — FreeNginx, OpenResty, Tengine — all promise the same core with a different story. Caddy and OpenLiteSpeed are the two non-nginx designs people ask about.

The short answer: for these applications the event loop is not what separates the candidates. The generic full-page cache is. Every nginx-family build lands inside the run-to-run spread on the same work, Caddy serves the same static file just as quickly, and then it loses by two orders of magnitude on a cached page because its standard build has no page cache at all.

## The test bed

- One dedicated server: 6-core / 12-thread Xeon E-2236, 62 GB RAM, two NVMe drives in RAID0, Ubuntu 26.04.1. CPU mitigations off for the whole cycle (the host's recorded configuration; every server saw the same kernel).
- PHP-FPM 8.5, MariaDB, Valkey, Elasticsearch and the three applications from their release archives: WordPress 7.1.4, XenForo 2.3.13 and Chevereto 4.5.9-pro.
- One server on `:443` at a time, started as a transient systemd unit so its CPU is read from that unit's cgroup. The production stack was stopped; only the web server changed.
- Identical minimal vhosts for every candidate: same document roots, same `try_files` semantics, same TLS certificates, gzip level, keepalive, open-file cache and FastCGI parameters. The nginx-family servers also got the same `fastcgi_cache`: key `host|method|uri|encoding`, any cookie bypasses, 60-second TTL, `ignore_headers Vary Set-Cookie`.
- Nine tiers: two static files, a 16 KB PHP endpoint, cached guest pages for all three applications, an uncached Chevereto page, and WordPress/XenForo member pages. Static and the PHP endpoint were sent with `Accept-Encoding: identity`, so per-request compression did not hide the server path; application tiers used gzip.
- `wrk -t4 -c100 -d8s`, a 2-second warm-up, three rounds. Servers rotate inside each round, because whichever configuration runs first keeps the CPU boost head start — the same trap I hit in the compression cycle.
- Median and min-max spread. On this desktop-class CPU the spread is 10-45% for the static and PHP-micro tiers and 3-10% for cached pages. Anything inside the spread is called noise, not a win.

## Results

| Server | Cached guest (median of the three apps) | WP member | XF member | 16 KB PHP | Static CSS | RSS |
|---|---:|---:|---:|---:|---:|---:|
| Angie 1.12.5 | **126.0k** | 155 | 276 | 33.0k | 29.4k | 495 MB |
| nginx 1.28.3 | 123.1k | 156 | 275 | **36.9k** | 29.0k | 490 MB |
| FreeNginx 1.31.5 | **131.0k** | 155 | 273 | 34.5k | 29.6k | 479 MB |
| OpenResty 1.31.8.1 | 116.8k | 156 | 272 | 36.2k | 27.1k | 500 MB |
| Tengine 3.1.0 (nginx 1.24) | 117.2k | 157 | 273 | 30.5k | **30.7k** | 470 MB |
| Caddy 2.11.9 | **370** (no cache) | 154 | 270 | 22.0k | 28.5k | **78 MB** |

Requests per second, median of three rotated rounds. The cached column is
the median of a WordPress post, a XenForo thread and a Chevereto explore
page; the per-tier spread is 4-49 %, and the spread for the member rows is
under 2 %. Caddy's guest rows are uncached by design: its standard build has
no FastCGI/proxy cache.

## What the numbers say

**The nginx family is one server with several logos.** Angie, nginx, FreeNginx and OpenResty land within the spread of each other on every tier, and the build that leads one application does not lead the next. Tengine's older nginx 1.24 core is in the same band too. If the only question were requests per second per CPU cycle, switching between them would be a coin flip.

**The cache is the product.** A cached WordPress post answers at six figures per second; the same page through PHP answers at about 150. XenForo and Chevereto show the same gap: 125k vs 370, and 134k vs 1,203. That is not a 10% tuning difference; it is the difference between one PHP render every few minutes and one per visitor. Stock Caddy can serve a static file as fast as the nginx builds — and then it has nowhere to put the page. Its standard build has no FastCGI or proxy cache; adding one means a third-party module and a custom build, which is a different support story.

**Caddy is not slow. It is uncached.** Its static row is level with the nginx family, its real-application uncached page is only 5 % behind (1,203 vs 1,274), and it uses one sixth of the memory (78 MB against ~490 MB with 12 workers and a 256 MB cache zone). Its tiny PHP endpoint is 34 % slower, which is the FastCGI path, not the cache. On a site that genuinely cannot cache pages, the choice would be defensible. WordPress, XenForo and Chevereto are not those sites: their guest pages are the traffic.

**OpenLiteSpeed is a different stack.** It has no generic page cache either — LSCache only stores what an application plugin marks, and only WordPress has that plugin. Its fast path is LSAPI, a different PHP SAPI from the PHP-FPM pool every other candidate shared. Measuring it would compare two PHP builds, not two web servers, so it is excluded rather than reported as if it were comparable. If you want OLS, you are choosing its PHP integration and its plugin ecosystem, not a faster event loop.

## The verdict

Keep Angie. It is the same core as nginx for the work that matters here, it carries the modules this stack already uses (Brotli, njs for the Anubis cookie check, the ACME client), and the configuration tree in the repository is built around it. FreeNginx and OpenResty are credible drop-ins if Angie's release cadence ever becomes a problem; nginx itself is the reference. None of them is worth a migration for throughput.

The thing worth migrating *to* is a cache. If a site is on a server without a generic full-page cache, that is the project, not the logo on the binary.

## What else the cycle fixed

The same audit found a release-blocking bug in the provisioning script: a fresh install with `--basic swap=8G` activated the new swap file and then tried to rename it. Linux refuses to rename a file that is active swap, so `--basic` failed and skipped sysctl, PAM limits, cron and the firewall. The fix validates the new file while it is inactive, renames the old one aside, moves the new one into place and only then activates it, with a rollback if `swapon` fails.

The configuration audit also found that a direct client could set `X-Forwarded-Host`, `X-Forwarded-Proto`, `X-Forwarded-For` and `X-Real-IP` for PHP. A cache MISS could render absolute URLs for an attacker's host and then store them; an application's IP allowlist could be spoofed. The headers now come from a trusted peer (the Anubis Unix socket, loopback, or an operator-declared proxy) or from the real peer, and a probe from the public address confirms it. Anubis, which connects over a Unix socket, still passes its header.

Two smaller fixes are in the same release: an adopted Elasticsearch node keeps its `http.host` bind through `--optimize`, and Chevereto's media path no longer disables `sendfile` or sends two contradictory `Cache-Control` headers.

The scripts, the raw tables and the restore manifest are in the [repository](https://github.com/droplinxuser/ubuntu-setup-script).
