---
title: "nginx with OpenSSL 3.5, OpenSSL 4.1, AWS-LC or BoringSSL"
date: 2026-11-26T05:50:00+08:00
description: "The same nginx 1.31 built against four TLS libraries. AWS-LC and BoringSSL need half of OpenSSL's CPU for an ECDSA handshake, post-quantum key exchange included. Keep-alive and bulk transfers tie. OpenSSL 4.1 beats the 3.5 LTS and stays the default, because the others take features away."
tags: ["nginx", "openssl", "aws-lc", "boringssl", "tls", "benchmark", "post-quantum"]
---

[The XenForo post](/posts/xenforo-on-php-8-1-to-8-6/) changed only PHP. This one changes only the TLS library under nginx. Everything else stays fixed: nginx 1.31.10, clang 23 with LTO, and the same PCRE2, zlib-ng and Brotli.

## Which libraries, and which not

- **OpenSSL 3.5.9**, the long-term support series.
- **OpenSSL 4.1.0**, which my script ships today.
- **AWS-LC 5.15.0**, Amazon's fork of BoringSSL. nginx has supported it officially since 1.29.2.
- **BoringSSL** (the 2026-11-05 release), Google's library.

I skipped three. wolfSSL's nginx patch stops at 1.28.1. rustls-libssl only swaps the library under a distribution's dynamically linked nginx, and is still experimental. LibreSSL had nothing to offer here that the others lack.

The build tool can now produce these as side builds: `nginx-build.sh build-arm DIR` with `TLS_LIB=aws-lc` or `boringssl` in its config. AWS-LC and BoringSSL are built as static libraries with cmake. A side build never replaces the running nginx.

## The setup

Each library ran as its own standalone nginx on spare ports, all from one config that uses only what every library supports:

- TLS 1.3 only
- no session cache and no tickets, so every handshake is a full one
- no OCSP stapling
- one certificate per server block, because BoringSSL allows only one

nginx ran on 8 of the host's 12 logical CPUs and wrk on the other 4. The test host is the Xeon E-2236, clock pinned at 3.6 GHz, with 5 rounds, the order reversed every other round, and medians reported. No row failed.

## Handshakes

Every request opens a new connection (`Connection: close`, 1 KB body):

| | OpenSSL 3.5 | OpenSSL 4.1 | AWS-LC | BoringSSL |
|---|---:|---:|---:|---:|
| ECDSA, X25519MLKEM768: req/s | 3,615 | 3,973 | 4,007 | 4,003 |
| nginx CPU per handshake | 0.52 ms | 0.48 ms | 0.25 ms | 0.27 ms |
| ECDSA, X25519: req/s | 3,966 | 4,413 | 4,462 | 4,458 |
| nginx CPU per handshake | 0.45 ms | 0.41 ms | 0.22 ms | 0.23 ms |
| RSA-2048, X25519: req/s | 4,305 | 4,803 | 4,939 | 4,945 |
| nginx CPU per handshake | 1.39 ms | 1.41 ms | 1.14 ms | 1.11 ms |

The req/s row mostly measures the client: wrk does its side of every handshake with Ubuntu's OpenSSL on 4 CPUs, and it runs out first. nginx's own CPU time is the server-side number, and there the gap is large. **AWS-LC and BoringSSL do an ECDSA handshake in half the CPU time OpenSSL needs**, with or without the ML-KEM post-quantum share. With RSA the gap shrinks to about 20 %.

OpenSSL 4.1 is 7-9 % cheaper per ECDSA handshake than 3.5. It also finishes its side faster, so the same client completes 10-12 % more handshakes per second against it.

## Keep-alive and bulk

| | OpenSSL 3.5 | OpenSSL 4.1 | AWS-LC | BoringSSL |
|---|---:|---:|---:|---:|
| 1 KB, keep-alive: req/s | 237,447 | 236,041 | 231,489 | 230,192 |
| XenForo page (105 KB): req/s | 37,359 | 37,182 | 37,426 | 37,319 |
| 1 MB file: MB/s | 4,055 | 3,963 | 4,117 | 4,147 |
| 16 MB file: MB/s | 3,830 | 3,717 | 3,830 | 3,840 |
| nginx CPU per 16 MB | 19.4 ms | 19.4 ms | 17.2 ms | 15.9 ms |

Once the connection is up, they tie. Every difference sits inside the run-to-run spread, and the client is again the limit at about 4 GB/s. AWS-LC and BoringSSL spend 10-18 % less nginx CPU per byte of AES-GCM.

## Why OpenSSL stays

Half the handshake CPU is a real gain. But it only matters to a server that terminates many fresh TLS connections itself. My servers sit behind Cloudflare, which reuses its connections to each origin, so full handshakes there are rare.

Switching would also cost features:

- **AWS-LC:** no kTLS, no `ssl_conf_command`, and no shared session cache, which my nginx config uses.
- **BoringSSL:** all of that, plus no OCSP stapling and one certificate per server block.
- **PHP:** its OpenSSL extension supports neither library, so PHP and nginx would end up on different TLS stacks.

So OpenSSL 4.1 stays the default. It is the fastest OpenSSL here and loses nothing. The other two remain one config line away for benchmarks. A note for my own list: PHP 8.2 to 8.6 currently link OpenSSL 4.1, which is newer than the range php.net supports for its OpenSSL extension (below 4.0). Moving PHP to the 3.5 LTS is a candidate for the next release.

Raw rows and the harness (`tools/nginx-build.sh build-arm`, `tests/stress-site/tls-arms-bench.sh`) are in the setup script's repository. [The next post](/posts/ktls-with-nginx-and-a-200-ms-stall/) uses the same harness for kTLS.
