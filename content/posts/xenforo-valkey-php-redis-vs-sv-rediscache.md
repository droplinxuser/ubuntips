---
title: "XenForo on Valkey: do you need php-redis?"
date: 2026-11-21T14:45:00+08:00
description: "Six XenForo cache setups, 300 load-test runs, MariaDB local and simulated remote. The PHP extension barely matters; the cache itself does."
tags: ["xenforo", "valkey", "redis", "php", "mariadb", "benchmark"]
---

XenForo can store its cache in Redis or Valkey in two ways. The core provider needs the `php-redis` extension. The popular SV RedisCache add-on ships its own pure-PHP client (Credis) and works with no extension at all. I wanted to know whether `php-redis` is worth making a hard requirement for every XenForo server, so I measured it.

Short answer: no. On the forum, thread and mixed pages the two clients are within about 2% of each other, with the database on the same box or on a simulated remote server. The only larger gaps came from single noisy rounds, and they favoured the pure-PHP client. What matters is that the cache is on, and that the SV add-ons are installed.

## The six setups

| Setup | PHP extensions | Cache provider | Serializer | SV add-ons |
|---|---|---|---|---|
| **A** | redis + igbinary | SV RedisCache, using phpredis | igbinary | RedisCache, RedisFloodCheck, RedisViewCounter |
| **A+** | redis + igbinary | same as A, persistent connections | igbinary | all three |
| **B** | igbinary only | SV RedisCache, pure-PHP Credis | igbinary | all three |
| **C** | none | SV RedisCache, pure-PHP Credis | PHP `serialize` | all three |
| **D** | redis + igbinary | XenForo core `'provider' => 'Redis'` | igbinary | disabled |
| **E** | none | cache off | n/a | installed, no backend |

C is the "no extensions" setup that many forums already run. Every other result below is compared against it.

## Test bed

- One dedicated server: 6-core / 12-thread Xeon, 62 GB RAM, Ubuntu 26.04.
- Angie, PHP-FPM 8.5 (`pm = static`, 12 children), MariaDB, and Valkey on a Unix socket. Everything was installed and tuned by the same provisioning script used for these notes.
- XenForo 2.3.13 filled with generated content. SV StandardLib, RedisCache 2.18.12, RedisFloodCheck and RedisViewCounter were installed.
- 64 logged-in members, picked at random on every request, reading 300 threads and 47 forums. Read state was pre-warmed so it did not grow during the runs.
- [wrk](https://github.com/wg/wrk) at 24 connections for 20 seconds, for four page types: home, thread, forum list, and a mixed set. Two single-connection runs (`thread-c1`, `home-c1`) measured plain page latency.
- Setups were run in rotated order across rounds: 3 rounds for the local and 0.9 ms databases, 2 for the others. All figures are medians.

I only measured logged-in traffic. That is the traffic that always reaches PHP and the cache, while guest pages can be served from the web server's page cache.

### Keeping each setup honest

Cache benchmarks are easy to fool, so the harness did this before every setup:

1. Write a neutral config, toggle the add-ons, then install or remove the PHP packages.
2. Write the setup's config, restart PHP-FPM, flush the cache database and drain XenForo's job queue.
3. Log all 64 members back in.
4. Check that the expected FPM modules are loaded, that most keys in a sample of up to 150 use the expected serializer, and that the SV add-ons are in the expected state. A setup that failed any check was skipped. None did.

The XenForo cron job was disabled while measuring, so background jobs could not land in one setup's numbers. All 300 timed runs completed with zero errors. In a separate functional pass, each setup also posted a forum reply (HTTP 200) with no XenForo error-log entries and no PHP log lines.

### Simulating a remote MariaDB

Some large forums run MariaDB on a separate server. To approximate that on one box, XenForo connected over TCP to `127.0.0.1`, and `tc netem` delayed only MariaDB traffic on the loopback interface:

```bash
tc qdisc add dev lo root handle 1: prio bands 4 priomap 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
tc qdisc add dev lo parent 1:1 handle 10: netem delay 1000us
tc filter add dev lo parent 1: protocol ip prio 1 u32 match ip dport 3306 0xffff flowid 1:1
tc filter add dev lo parent 1: protocol ip prio 1 u32 match ip sport 3306 0xffff flowid 1:1
```

The priomap sends all other loopback traffic to the fourth band, which has no delay, so only port-3306 traffic goes through netem. Remove it afterwards with `tc qdisc del dev lo root`.

Both directions are delayed, so a 250 µs setting gave a measured `SELECT 1` median of **0.9 ms**, and 1,000 µs gave **2.2 ms**. Before each latency block, the harness measured the round trip (median of 500 `SELECT 1` queries) and aborted if it fell outside the expected range. A TCP run with no delay served as a control: TCP alone cost about 2% against the Unix socket. Persistent database connections (`p:` host prefix) were on in every run.

This simulates network latency only. A real remote server also has its own CPU, disk and network jitter.

## Results

Throughput relative to C, for the forum, thread and mixed pages:

| Setup | Local socket | Remote, 0.9 ms | Remote, 2.2 ms |
|---|---|---|---|
| A (php-redis + igbinary) | +1.2 to +1.4% | −0.1 to +1.0% | +0.1 to +0.7% |
| A+ (persistent) | +1.5 to +1.9% | +1.1 to +1.4% | not run |
| B (igbinary only) | +1.0 to +1.6% | +0.7 to +1.1% | not run |
| D (core provider, no SV) | +2.6 to +3.4% | −0.8 to +0.1% | −4.8 to −6.2% |
| E (no cache) | +2.8 to +4.4% | −4.3 to −5.6% | −14.8 to −19.9% |

Raw throughput for the mixed page set, in requests per second:

| Setup | Local socket | Remote, 0.9 ms | Remote, 2.2 ms |
|---|---|---|---|
| A | 332 | 272 | 173 |
| C | 329 | 273 | 171 |
| D | 337 | 272 | 161 |
| E | 338 | 260 | 143 |

What a remote database does to a thread page with setup C:

| MariaDB round trip | Thread req/s | One request at a time (p50) |
|---|---|---|
| 0.03 ms (Unix socket) | 350 | 19.2 ms |
| 0.9 ms | 299 | 35.0 ms |
| 2.2 ms | 188 | 64.6 ms |

## Why the PHP client barely matters

A thread page makes about **six** cache calls. Here is the cost of one page, with the database on the local socket:

| Setup | PHP CPU ms | Valkey ms | Valkey calls | DB queries |
|---|---|---|---|---|
| A | 25.89 | 0.274 | 6.0 | 10.7 |
| B | 26.00 | 0.272 | 6.0 | 10.7 |
| C | 26.26 | 0.307 | 6.0 | 10.7 |
| D | 25.52 | 0.272 | 6.0 | 11.7 |
| E | 25.73 | 0.004 | 0 | 14.8 |

php-redis saves about **0.03 ms** of cache time per page, out of roughly 26 ms of PHP time. No client library can win much there.

A micro-benchmark of the two clients, run directly against the Valkey socket (median of 3 runs, µs per operation):

| Operation | phpredis | Credis |
|---|---|---|
| GET + unserialize, PHP serializer | 35.5 | 37.6 |
| GET + unserialize, igbinary | 20.3 | 22.5 |
| MGET × 20, PHP serializer | 55.1 | 63.2 |
| MGET × 20, igbinary | 28.3 | 35.3 |
| SET, igbinary | 13.4 | 15.1 |
| connect + PING + close | 28.5 | 31.5 |

The serializer matters more than the client. igbinary nearly halves read cost with either library, and it shrank the sample cache entry from 7,907 bytes to 1,965. phpredis is only about 2 to 8 µs faster per call.

## Why the cache matters more with a remote database

On the Unix socket a query costs almost nothing. Skipping the cache saves a little PHP work, so the no-cache setup (E) actually comes out about 3% ahead.

The cache removes about four queries per page (14.8 down to 10.7). Once each query crosses a network, every one avoided saves a round trip. At 0.9 ms the cache is worth 4 to 6% of throughput. At 2.2 ms it is worth 15 to 20%, and single-request latency is up to 21% better.

The SV add-ons show the same pattern. XenForo's core provider (D) uses php-redis but drops the SV flood-check and view-counter add-ons, and adds about one query per page. With a local database that is free. At 2.2 ms D falls about 5 to 6% behind C on the forum, thread and mixed pages.

## One false alarm

The first home-page run with the 0.9 ms database showed 18.4 queries per request instead of the usual 14.3, which looked like a TCP-only code path. The three-round median for that page was back at 14.3, the same as over the local socket. It was a cold first pass after the switch, which is a good reason never to trust a single run.

## What I changed

Nothing, and that is the result. My provisioning script already:

- installs neither `php-redis` nor `php-igbinary` on a fresh server;
- installs `php-redis` only when a XenForo `config.php` selects the core Redis provider, the one case that actually needs it.

If you run XenForo with a separate database server:

1. **Keep a cache on.** SV RedisCache on a local Valkey socket is worth up to a fifth of your throughput at 2 ms database latency.
2. **Keep the SV add-ons.** They remove database work the core provider does not.
3. **Don't install php-redis for speed.** A 0 to 2% difference is inside normal run-to-run noise.
4. **Add php-igbinary if cache memory matters.** It cuts the size of cache entries about 4× and needs no php-redis. Otherwise it is optional.
5. **Measure your own database round trip.** Going from 0.9 ms to 2.2 ms cost more throughput than any cache choice here. Keeping the database server close to the web server is the biggest win available.
