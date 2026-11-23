---
title: "Deleting my bot filter: 2,400 lines, one proxy hop, and what an Angie map actually costs"
date: 2026-11-23T09:10:00+08:00
description: "I removed the optional Anubis bot filter from my provisioning stack: what it cost, how to migrate a host without taking the sites down, and an honest measurement of what is left in the Angie request path. The maps were already lean; one regex if was not."
tags: ["angie", "nginx", "anubis", "cloudflare", "fastcgi_cache", "performance", "benchmark", "xenforo", "wordpress", "chevereto"]
---

For two years my [provisioning script](/posts/one-idempotent-script/) had an optional extra: `--angie anubis=yes` put a [Anubis](https://anubis.techaro.lol/) proof-of-work filter in front of every site. Angie terminated TLS on `:443`, proxied to a Unix socket, Anubis ran its policy, and proxied to a second socket where the real vhosts lived. It worked. I even [verified its pass cookies inside Angie with njs](/posts/anubis-pass-cookie-in-angie-and-two-silent-slowdowns/) so repeat visitors skipped the Go hop.

Production now terminates at Cloudflare. That makes the origin-side filter a second, weaker bot filter in series, paying a full request hop for traffic the edge already classified. So this cycle's first job was to delete it, and the second was to answer a smaller question honestly: **what does the Angie request path actually cost now, and can the maps be trimmed further?**

The short version: the filter is gone (2,4xx lines with it), one avoidable PCRE is gone, and the remaining maps measure the same as before, because previous cycles had already done the big work. The interesting part is why 14 of the 16 remaining `if` statements *cannot* become maps, and what happens if you delete a filter without a migration plan.

## What the filter was

`lib/anubis.sh` alone was 1,690 lines. It installed a static Go binary with a pinned SHA-256, wrote a sandboxed systemd unit, a policy YAML, an env file with an HS512 secret, a `tmpfiles.d` drop-in, two Unix-socket upstreams, a generated `default_server`, an njs script that verified the pass cookie in Angie with a shared verdict dictionary, and — for the static assets — a *shadow* server block per vhost that reproduced the application's root and deny rules on a third socket so CSS and fonts never entered the Go proxy.

Then the integration: vhost migration with backups, a TLS-terminator generator, real-IP guard relocation, enable/disable/purge paths, a dry-run matrix, and about 600 lines of unit tests. Every one of the nine modules that touched it had to know about it.

None of that was wasted while it ran. On the cached-page tiers it was the difference between 27.7k and 95–103k req/s, and it used 5.2 of the 12 threads at the worst point. But a bot filter in front of a page cache is pure added cost: the cache hit is already cheap, and the filter still inspects every one of them. At the edge, Cloudflare inspects them on hardware I do not pay for.

## Removing a proxy is not a neutral change

Here is the trap. When the filter is enabled, the real vhosts **do not listen on 443 any more**. Their 443 listener was rewritten to a Unix socket that only Anubis connects to, and a generated terminator owns the public port. Delete the filter's files, restart the web server, and every site is down: nothing listens where Anubis used to forward.

So the release does two things:

1. **`setup.sh` refuses to run on a host that still carries the generated terminators.** It checks for the files only the old release created (`00-anubis-terminators.conf`, `00-anubis-common.conf`, `snippets/anubis-location.conf`, the unit, the state marker) and stops before changing anything. `--diagnostics` still works; `--purge` still works.

2. **`tools/remove-anubis.sh` does the migration in the only safe order.** Restore every vhost from its pre-integration copy, remove the generated Angie files, `angie -t`, and a *graceful reload* — while the filter is still running, so there is no window where the vhosts point at a socket nothing serves. Only then stop and disable the service. A vhost whose backup is missing stops the tool before anything is stopped: it does not guess what your direct-TLS listener looked like.

`--purge` also deletes the binary, `/etc/anubis`, the unit, the user and the group. The default keeps them for a fast re-enable.

The old `anubis=yes` / `anubis=no` / `SETUP_ANUBIS` words are still *recognised* — and rejected with an explanation. Silently ignoring `anubis=yes` would deploy a host the operator believes is protected when it is not, which is worse than an error.

## The free win: Cloudflare TLS was switched off

One finding made the removal more than a clean-up. The Cloudflare TLS migration — move certbot vhosts to the self-signed origin certificate, trust `CF-Connecting-IP`, retire certbot — had a guard: *skip if the Anubis integration is managed*. The filter owned the TLS terminators, so touching certificates would have broken it.

That guard is gone, and the Cloudflare profile now applies to every certbot vhost. On a Cloudflare-proxied origin that is exactly what you want: the origin certificate is self-signed, the visitor address comes from the edge header, and certbot has nothing left to renew. It had simply never run on the hosts that used the filter.

## The second question: "convert every `if` to a `map`"

The shipped Angie tree had 16 `if` statements. The instinct — `if` in nginx is a footgun, maps are evaluated once and are cheap — is right in general, but it does not apply to 14 of these.

An `if` is expensive when its **condition** is expensive: a regex, or a variable interpolation. An `if` whose condition is a 0/1 variable is a single integer test, and there is nothing cheaper in the configuration language:

```nginx
if ($xf_guest_cacheable) { return 418; }
```

You cannot write that as a map. A map produces a *value*; `return` fires unconditionally once you are in the block, and nginx has no "return only if true". The workaround people reach for — mapping to an empty string and returning it — sends a redirect to an empty URL. So the 11 cache-handoff `if`s, the two `if ($x_deny_nf)` in the security locations and the dot-segment gate stay, and they cost an integer test each.

That leaves the two that really were evaluated with a PCRE. Chevereto has a quirk: `/index.php` is not a route, it is the front controller, and the application answers `500 Invalid PHP front controller setup` when a client requests it directly. Both Chevereto PHP files therefore redirected it:

```nginx
if ($request_uri ~ "^/index\.php(?:[?]|$)") { return 301 /$is_args$args; }
```

The reason it reads `$request_uri` and not `$uri` is the interesting bit: `try_files` rewrites every pretty URL to `/index.php` with an internal redirect, and `$uri` becomes `/index.php` — so a rule on `$uri` would redirect the whole site. `$request_uri` keeps the original request line.

But that also means a request Angie did not rewrite has exactly `$request_uri == "$uri$is_args$args"`, while an internal redirect keeps the original `$request_uri` and rebuilds `$uri`. One string comparison replaces the regex, in the rewrite phase, with no PCRE at all:

```nginx
location = /index.php {
if ($request_uri = "$uri$is_args$args") { return 301 /$is_args$args; }
...
}
```

Verified live and by the application suite: `/index.php` → `301 /`, `/index.php?a=1` → `301 /?a=1`, and `/explore` is untouched. The application smoke test's `chev canonical /index.php 301` line still passes.

I also deleted `http.d/referer_map.conf`, which defined `$302_referer` and `$302_method` — two maps that nothing in either repository referenced. Dead configuration is not just clutter; it is a file the next person has to read and rule out.

## The measurement, and what it does not show

Same host for every number: the disposable Xeon E-2236 (6C/12T, 62 GB, NVMe RAID0), Ubuntu 26.04, PHP 8.6, MariaDB, Valkey, Elasticsearch, WordPress 7.1.4, XenForo 2.3.13 with 2,600 posts, Chevereto 4.5.9 with a real image. Mitigations were **on** for the whole cycle. Two Angie trees — the committed 1.6.54 and this cycle's 1.6.55 — deployed by the *same* `setup.sh --optimize`, three passes each, `wrk -t4 -c100 -d10s` over loopback TLS.

| Tier | 1.6.54 median | spread | 1.6.55 median | spread | Δ |
|---|---:|---|---:|---|---:|
| WordPress guest home (cached) | 89,091 | 85,713–93,747 | 89,737 | 89,039–94,445 | +0.7 % |
| WordPress guest post (cached) | 82,706 | 74,597–88,239 | 83,217 | 81,263–90,869 | +0.6 % |
| XenForo guest home (cached) | 122,234 | 121,030–135,260 | 135,471 | 134,779–135,483 | +10.8 %† |
| XenForo guest thread (cached) | 121,844 | 114,287–127,459 | 126,955 | 125,659–127,044 | +4.2 %† |
| Chevereto guest explore (cached) | 130,967 | 130,650–131,032 | 130,662 | 116,627–130,662 | −0.2 %† |
| Chevereto guest image (cached) | 130,732 | 129,896–130,897 | 129,285 | 115,941–129,285 | −1.1 %† |

† Those tiers were bimodal in one tree — a whole pass at ~135k, another at ~121k — so the difference is the drift, not the configuration. Which is why the tier that actually changed was measured again with the trees **alternating**, four rounds each way, so drift hits both sides equally:

| Round | 1.6.54 req/s | p99 | 1.6.55 req/s | p99 |
|---|---:|---:|---:|---:|
| 1 | 142,389 | 0.96 ms | 142,795 | 1.17 ms |
| 2 | 141,521 | 0.97 ms | 141,536 | 0.99 ms |
| 3 | 142,008 | 1.07 ms | 140,767 | 0.92 ms |
| 4 | 140,958 | 1.03 ms | 141,534 | 1.36 ms |
| **median** | **141,765** | | **141,535** | |

**−0.2 %, inside a ±0.6 % spread.** And the per-request cost, from the cgroup delta of each service:

| Cached request | 1.6.54 | 1.6.55 |
|---|---:|---:|
| WordPress guest home | 0.086 ms of Angie CPU | 0.086 ms |
| XenForo guest home | 0.058 ms | 0.058 ms |
| Chevereto guest explore | 0.060 ms | 0.061 ms |

So: **the string comparison did not make cached pages faster, and the regex it replaced did not make them slower.** One anchored PCRE is a fraction of a microsecond against a 60 µs request that is dominated by TLS and the cache lookup. The change is a simplification — one fewer regex in the tree, no PCRE in any `if` — and I am not going to call it a speed-up that the data does not show.

The one number that says where the remaining time goes: ~7.5 cores of Angie serve ~90,000 cached WordPress pages/s on a 12-thread box. Three PCREs per request (the dot-segment map, the URI no-cache map, and the tracking-parameter map when there is a query string) are inside that 86 µs, and every one of them is an anchored alternation that fails in its first characters. Squeezing them further would land under the noise floor above.

Two measurement notes, both learned the hard way:

- **Do not empty a 16 GB FastCGI cache with `find -delete` under a running server.** The cache manager reconciles a million deleted keys and blocks the zone. One entire 10-second tier answered **zero** requests; the next recovered halfway through. A warm cache is the production case.
- A `wrk` left running from an earlier shell halves the next result (93k → 48k). Both are in the audit report so the next cycle does not repeat them.

## Zero-error, as usual

Install: 3:09, 0 warnings, 0 errors. `--domain` for the three applications: 0:24, `angie -t` clean. 1,489 unit checks, 227 dry runs, 67/67 security probes, 86/86 guest-cache cookie cases, functional suite 0 unexpected and 0 PHP diagnostics. `--optimize` from the old tree to the new one changed exactly the six files that were meant to change, of 215 managed facts.

The host went back to its pristine 696-package manifest, rebooted, and comes up with nothing of the stack on it.

## What I would tell the next person

- **A proxy you delete is different from a proxy you disable.** If your vhosts were rewritten to point at it, removal is a migration with an order, and it needs a tool and a refusal — not a `git rm`.
- **`if` is only a footgun when its condition costs something.** Count the regexes in your conditions, not the `if`s; "convert every if to a map" would have been 14 no-ops and a lie.
- **Measure the thing you changed, and say when it did not move.** The temptation here was to ship "one fewer PCRE per request" as a win. At 60 µs per request it is not visible, and a table that says so is worth more than a table that does not.
