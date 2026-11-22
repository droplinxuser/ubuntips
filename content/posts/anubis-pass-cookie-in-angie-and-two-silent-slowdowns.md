---
title: "Checking Anubis cookies in Angie, and two slowdowns no log reported"
date: 2026-11-22T10:00:00+08:00
description: "Checking the Anubis pass cookie in Angie made browser traffic 3.1× faster. The same audit found a cache compressing every hit and a stale CDN breaking apt."
tags: ["anubis", "angie", "njs", "php", "wordpress", "apt", "benchmark"]
---

Every release of my [provisioning script](/posts/one-idempotent-script/) goes through the same audit before it ships. A dedicated test server starts from a clean Ubuntu 26.04 install. It gets the full stack, three real applications and a set of load and security tests, and then it is restored to the exact package set it started with.

This cycle found three problems. None of them showed up as an error in a log:

1. **Anubis cost real visitors about 70% of the throughput.** A browser that had already solved the challenge still went through the Anubis proxy on every request. Angie now checks the cookie itself: 17.7k → **55.2k requests per second** for cached forum pages.
2. **A site deployed in the normal order never got its fast cache path.** Cached WordPress pages were served at 6.6k requests per second instead of 93k, because Angie was compressing every cache hit.
3. **The install failed on a CDN that served mismatched files.** The retry logic waited 7.5 minutes for a "mirror sync" that was really a stale cache, then gave up.

## The test bed

- One dedicated server: 6-core / 12-thread Xeon, 62 GB RAM, Ubuntu 26.04.1, CPU mitigations on.
- Angie, PHP-FPM 8.5 (`pm = static`, one worker per CPU thread), MariaDB, Valkey, Elasticsearch and Node.js, all installed by the script.
- Three applications from their release archives: WordPress 7.1.4, XenForo 2.3.13 (filled with 20,000 users, 10,000 threads and about 90,000 posts by a seeder add-on) and Chevereto 4.5.9.
- Load from [wrk](https://github.com/wg/wrk) on the server itself over HTTPS, 100 connections for 10 seconds after a 2-second warm-up. My workstation is too far away for a meaningful number: from there every site topped out at 160-172 requests per second, bounded by network latency rather than by the server.

## 1. Anubis: let Angie check the pass cookie

[Anubis](https://github.com/TecharoHQ/anubis) is a proof-of-work bot filter. The browser solves a small puzzle once and gets a signed cookie; Anubis checks that cookie on later requests and proxies them to the site. In my setup it sits between the TLS terminator and the application:

```
client → Angie :443 → Anubis (Unix socket) → Angie vhost (Unix socket) → PHP
```

A previous release already sent requests that Anubis would allow without a cookie straight to the backend: search engines, and non-browser clients that the policy lets through anyway. Browsers still went through Anubis on every request, including the ones that had already solved the challenge. That is most of your human traffic.

On the test server a cached XenForo page answered **17.7k requests per second** for a browser with a valid cookie (measured in the previous cycle, same server and harness). For comparison, the same page with Anubis switched off entirely does about 97k. With Anubis on, a request that skips it still makes one extra hop between two Angie servers, so the realistic ceiling for this setup is about 62k.

### What Anubis actually checks

I read the Anubis 1.28.2 source to see what it checks before it proxies a request that matched a challenge rule. There is no server-side session. Everything lives in the cookie, a JWT signed with HS512 when a shared secret is configured. A real token from the test server decodes to:

```json
{
  "action": "CHALLENGE",
  "challenge": "<uuid>",
  "exp": 1795863094,
  "iat": 1795258294,
  "method": "fast",
  "nbf": 1795258234,
  "policyRule": "<rule hash>",
  "restriction": "<sha256 of the client address>"
}
```

The `restriction` claim is the SHA-256 of the `X-Real-IP` header that Anubis receives. My terminator sets that header from `$remote_addr`, so the token is bound to the visitor's address, and hashing `$remote_addr` in Angie gives the same value. I confirmed that against a real token, not just the source. The cookie name also carries a suffix derived from the cookie settings (`techaro.lol-anubis-auth-<8 hex>`), which my first attempt missed.

### Doing the same check in Angie

Angie's njs module (`angie-module-njs`, in the Angie repository) can compute an HMAC. A `js_set` variable decides the upstream for browser requests only:

```nginx
js_shared_dict_zone zone=anubis_pass:4m timeout=600s evict type=number;
js_import anubis_pass from /etc/angie/njs/anubis_pass.js;
include /etc/angie/ssl/anubis/pass-key.conf;   # js_var with the secret, root-only
js_set $anubis_pass_route anubis_pass.route;

map $http_user_agent $anubis_ua_route {
    default                anubis_backend;    # policy default-allow
    ""                     anubis;            # empty UA: challenge
    "~*(?:Googlebot|...)"  anubis_backend;    # allowed crawlers
    "~*(?:GPTBot|...)"     anubis;            # Anubis answers the deny
    "~Mozilla"             $anubis_pass_route;
}
```

`$anubis_pass_route` is only evaluated when the map lands on that line, so search engines, API clients and AI crawlers never run JavaScript at all. The check mirrors Anubis and falls back to it on anything unexpected (abridged; the verdict cache is left out here):

```js
function route(r) {
    const v = r.variables, now = Date.now() / 1000;
    if (!r.headersIn.Cookie || !v.anubis_pass_key) { return 'anubis'; }  // no cookie, or no secret
    // ... the one-shot Referer cookie after a challenge -> 'anubis'
    const m = COOKIE.exec(r.headersIn.Cookie);
    if (!m) { return 'anubis'; }
    const sig = crypto.createHmac('sha512', v.anubis_pass_key)
        .update(m[1] + '.' + m[2]).digest('base64url');
    if (!same(sig, m[3])) { return 'anubis'; }   // constant-time compare
    try {
        if (json(m[1]).alg !== 'HS512') { return 'anubis'; }
        const c = json(m[2]);
        if (typeof c.exp !== 'number' || c.exp <= now) { return 'anubis'; }
        if (typeof c.nbf === 'number' && c.nbf > now) { return 'anubis'; }
        if (c.action !== 'CHALLENGE') { return 'anubis'; }
        if (!(c.iat >= Number(v.anubis_pass_epoch))) { return 'anubis'; }
        if (c.restriction !== undefined &&
            c.restriction !== sha256hex(v.remote_addr)) { return 'anubis'; }
    } catch (e) {
        return 'anubis';
    }
    return 'anubis_backend';
}
```

The guards matter. With an empty or missing secret, anyone could sign a cookie with an empty HMAC key, so no secret must mean "everything goes to Anubis". Without `typeof c.exp === 'number'`, a token with no `exp` at all would never expire, and without the `try`, a malformed payload would make `js_set` throw instead of falling back to Anubis.

One check could not be copied exactly. Anubis compares `policyRule` with the hash of the rule that matched, and that hash is computed inside Anubis. The Angie check uses a stand-in: the token must have been issued after the policy file last changed (`$anubis_pass_epoch`). A token from before a policy change goes back to Anubis, which judges it against the current rule.

### Measuring the overhead

Verifying an HMAC-SHA512 and parsing JSON on every request is not free. Here is the browser path step by step, on a cached XenForo page with a valid cookie:

| Variant | Requests/s |
|---|---:|
| Through Anubis (before this release) | 17,710 |
| njs, full check on every request | 42,061 |
| njs + verdict cache (shipped) | **55,192** |
| `js_set` that returns a constant (njs floor) | 62,610 |
| No check at all, browsers straight to the backend | 62,206 |

The verdict cache is a 4 MB njs shared dictionary. Once a token has been verified from an address, that token from that address skips the HMAC for up to 10 minutes (the zone's `timeout`), never past the token's `exp`; a full zone evicts the oldest entries. The key is the token signature, the visitor address, the policy epoch and a fingerprint of the secret:

- An entry is written only after the signature checks out, and the key includes the requester's own address, so nobody can plant a verdict for someone else.
- The dictionary survives an Angie reload (not a restart). The epoch and the secret fingerprint are what stop an edited policy or a rotated secret from reusing old verdicts.
- The key covers the signature, not the payload. That is safe only because nothing reads the claims after a cache hit. Do not extend this design to pass cached claims to the application.

The shipped version is about 11% below not checking at all. WordPress with a pass cookie went from 16.7k to **50.0k** requests per second.

Behaviour checks, all on the forum home page with a browser User-Agent:

| Request | Result |
|---|---|
| Valid cookie | forum page |
| No cookie | Anubis challenge |
| One character of the signature changed | Anubis challenge |
| AI crawler User-Agent with a valid cookie | Anubis deny page |

The security, cache-cookie and functional suites passed with the filter on, and no njs line appeared in the error log. Without the module, browsers simply stay on the Anubis path. `SETUP_ANUBIS_PASS_EDGE=0` turns the check off.

### A permissions bug found in the same hour

The first version wrote the secret to `/etc/angie/anubis-pass-key.conf` with mode 0600. After the next run it was 0644. The script normalises the whole Angie tree to root-owned 0644 files, except `ssl/`, which holds private keys. So the secret now lives in `/etc/angie/ssl/anubis/` (directory 0700, file 0600), and the test re-checks the mode after every run. The general rule is worth writing down: if a tool resets permissions on a directory tree, keep secrets out of it.

Two more places the secret ends up: `angie -T` prints every included file, so never paste that output anywhere public, and every Angie worker holds it in memory. Anyone with the secret can mint pass cookies for any address, so rotate it if either one leaks.

## 2. A cache that compressed every hit

The first load test of the cycle looked like this:

| Cached page | Last cycle | This cycle |
|---|---:|---:|
| XenForo home | 97k | 97.6k |
| WordPress home | 93k | **6.6k** |
| Chevereto explore | 129k | **9.3k** |

Angie was at 800% CPU, about 1.2 ms per request. The headers told the story. XenForo's cached page came back with `content-encoding: gzip` and a `content-length`; WordPress and Chevereto came back with `content-encoding: br` and no length. Angie was compressing the stored page again on every hit.

XenForo compresses its own output, so its cache entry is stored compressed. WordPress and Chevereto do not. The script fixes that with a per-directory PHP section, so the FastCGI cache stores PHP's gzip output:

```ini
[PATH=/var/www/example.com/public]
zlib.output_compression = On
zlib.output_compression_level = 4
```

That section was only written for directories that already contained `wp-config.php` or Chevereto's `app/env.php` when the tuner ran. The normal order on a new site is "create the vhost, then upload the application". The tuner ran on an empty directory, saw no WordPress, and wrote nothing. Nothing would fix it until someone happened to run the optimizer again.

The vhost now decides. If it uses the WordPress or Chevereto cache configuration and that cache key varies by encoding (the condition that makes a gzip body safe to store), the directory gets the section whether the application is there yet or not. After the fix:

| Cached page | Before | After |
|---|---:|---:|
| WordPress home | 6,576 | **93,385** |
| WordPress post | 6,419 | **90,309** |
| Chevereto explore | 9,346 | **140,016** |
| Chevereto image | 7,149 | **130,180** |

Chevereto caches pages for an hour, so its old uncompressed entries had to expire (or be cleared) before the new numbers showed. On a live site that is the only cost of the change.

## 3. A CDN that served two versions of one repository

The first install attempt stopped after 7 minutes 57 seconds:

```
E: Failed to fetch https://packages.sury.org/php/dists/resolute/main/binary-amd64/Packages.xz
   File has unexpected size (142672 != 141444). Mirror sync in progress?
```

The script already retried this error four times, at 30, 60, 120 and 240 seconds, because a repository that is publishing a new index really can be inconsistent for a minute or two. Every retry failed. The response headers showed why:

| File | Generated | Age in the CDN cache |
|---|---|---|
| `InRelease` (the signed index) | 09:01 | 45 minutes |
| `Packages.xz` | 09:31 | 38 minutes |
| `Packages` (uncompressed) | 09:01 | consistent with `InRelease` |

This was not a sync in progress. The CDN was holding a signed index from 09:01 next to a compressed package list from 09:31, and the waits were never going to outlast its cache. The uncompressed `Packages` file, though, was from the same build as the stale `InRelease`, and it matched.

Telling apt not to use any compressed index fetches exactly that file:

```bash
apt-get update \
  -o Dir::Etc::SourceList=/path/to/empty-file \
  -o Dir::Etc::SourceParts=/path/to/dir-with-only-the-failing-source \
  -o APT::Get::List-Cleanup=false \
  -o Acquire::CompressionTypes::xz=false -o Acquire::CompressionTypes::gz=false \
  -o Acquire::CompressionTypes::bz2=false -o Acquire::CompressionTypes::lzma=false \
  -o Acquire::CompressionTypes::lz4=false -o Acquire::CompressionTypes::zst=false
```

`List-Cleanup=false` matters. Without it, an update that sees only one source deletes the package lists of every other repository. Now, on a size or hash mismatch, the script takes the failing hosts from apt's error lines and refetches, uncompressed, only the source files that mention them. Only after that does it fall back to the timed retries, so the bigger uncompressed download is paid only when something is wrong. On the rerun the install logged one info line, finished in 2 minutes 4 seconds and had no warnings.

## Everything else the cycle checked

| Check | Result |
|---|---|
| Fresh install (all services) | 2:04, 0 warnings |
| Fresh install vs install + `--optimize` | identical: 0 settings differ (3,029 compared; 3,049 with Anubis on) |
| Unit tests / dry-run combinations | 1,418 / 1,418 and 225 / 225 |
| Security probes, Anubis off and on | 65 / 65 each |
| Guest-cache cookie tests, Anubis off and on | 62 / 62 each |
| Functional run of all three applications | 0 unexpected responses |
| PHP 8.5 deprecations, warnings, notices, fatals | 0 in all three applications |
| Restore to the starting state, after a reboot | 696 = 696 packages, 0 changed files in `/etc` |

Logged-in pages, which always reach PHP: XenForo 269 (home) and 216 (thread) requests per second, WordPress 164 and 149. Those are in line with earlier cycles.

### OPcache JIT, once more

| JIT profile | XenForo thread | WordPress home | Chevereto home (uncached) |
|---|---:|---:|---:|
| tracing, 64 MB (shipped; first / last run) | 215 / 216 | 160 / 150 | 1,498 / 1,399 |
| off | 219 | 137 | 1,509 |
| function | 234 | 152 | 1,528 |
| tracing with tuned trace limits | 219 | 153 | 1,469 |

The shipped profile was measured first and last; it moved by up to 7% between those two runs alone. `function` is ahead on XenForo and behind on WordPress, and switching the JIT off costs WordPress the most. Nothing here beats run-to-run noise consistently, so the profile stays: tracing JIT, 64 MB buffer, static pool, one worker per CPU thread.

### PHP 8.6

PHP 8.6.0 is packaged, but the redis, igbinary and imagick extensions are not yet. Chevereto needs redis and imagick, and the test forum uses XenForo's own Redis cache provider, so the script's `--upgrade-php=8.6` dry run refuses. Compiling every file of each application under 8.6 found:

- **Chevereto 4.5.9:** clean.
- **XenForo 2.3.13:** one deprecation, a template-compiler class named `Is`. PHP 8.6 deprecates `is` as a class name, so XenForo will need to rename it.
- **WordPress 7.1.4:** deprecations only in the bundled `sodium_compat` polyfill (not loaded when the sodium extension is present) and in two files of core (`php-compat/readonly.php`, `wp-admin/network/site-users.php`).

## What this does not prove

- **Only browsers are challenged.** The managed policy is default-allow: a client that does not send a `Mozilla` User-Agent reaches the backend without a challenge, through Anubis and at the edge alike. That keeps API clients, cron jobs and monitors working, but a scraper only has to drop the browser User-Agent. If you need more, add a catch-all challenge rule and remove the `default anubis_backend` line.
- **The edge check skips the policy for cookie holders.** It is safe here because every rule a browser can match is either a challenge or a User-Agent rule that the map mirrors. If your policy denies or weighs browsers by path, header, address range, ASN or country, a visitor with a valid cookie would skip those rules. Mirror them in Angie or keep browsers on Anubis.
- **The Angie check substitutes one Anubis rule.** Anubis rejects a token whose rule hash differs from the rule that matched now; the Angie check accepts any challenge token issued after the last policy change. With the managed policy, that difference is limited to which of two browser rules issued the token.
- **The binding is to an address, not a person.** Everyone behind the same NAT, CGNAT or VPN exit shares that address. Once solved, a token can be replayed from that address until it expires (7 days here), and requests that pass at the edge no longer appear in Anubis's logs or metrics.
- **The edge learns about policy and secret changes only when the script runs.** Angie keeps its own copy of the secret and the policy timestamp. If you edit the policy or rotate the Anubis secret by hand, rerun the script and reload Angie; until then, tokens signed with the old secret still skip Anubis until they expire.
- **Behind a CDN or load balancer, the address must be right.** If Angie sits behind Cloudflare or another proxy, `$remote_addr` must be restored with `set_real_ip_from` limited to that proxy's ranges. Without it every visitor shares the proxy's address; trusting the header from anyone lets anyone claim any address.
- **It is tied to one Anubis version.** The check mirrors Anubis 1.28.2. If a future release renames the cookie, the regex stops matching and every browser goes back to Anubis, which is safe. If it adds a new check to its cookie validation, the Angie copy will not know about it. The version is pinned for that reason, and an upgrade means re-reading that function.
- **Loopback numbers are a ceiling.** wrk with a single cookie measures the cost of the request path, not thousands of distinct visitors filling the verdict cache. Real clients add TLS handshakes and slower networks, and on a slow link latency dominates: from my workstation every site measured the same 160-172 requests per second. The gains show up as server CPU headroom under load.

## What changed

All three fixes shipped in release 1.21.57 of [ubuntu-setup-script](https://github.com/droplinxuser/ubuntu-setup-script). If you run Anubis in front of Angie yourself, the useful parts are:

1. **Send whatever your policy allows without a cookie straight to the backend.** A User-Agent map does it without any scripting, as long as it mirrors your policy's User-Agent rules in the same order.
2. **Check the pass cookie in the web server, if your policy allows it.** That means every rule a browser can match is a challenge or a User-Agent rule you mirror. Check the HS512 signature and `alg`, the types and values of `exp` and `nbf`, `action`, the address-bound `restriction` claim, and a stand-in for `policyRule` such as "issued after the policy last changed". Fall back to Anubis on anything unexpected.
3. **Cache the verdict for minutes, not for the token's lifetime, and key it by everything that can invalidate it:** the token, the address, the policy and the secret.
4. **Keep the secret where your own tooling will not loosen its permissions.**

And for any cache in front of PHP: look at the `content-encoding` and `content-length` of a cache hit. If the length is missing, your web server is compressing a stored page on every request.
