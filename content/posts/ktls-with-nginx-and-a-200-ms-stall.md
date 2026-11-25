---
title: "kTLS with nginx: 44 % less CPU on big files, and a 200 ms stall"
date: 2026-11-26T06:00:00+08:00
description: "Kernel TLS lets nginx encrypt files with sendfile(). On this server it first did not work at all: a 1 MB file never finished, because of one sysctl my own script sets. Fixed, kTLS cut nginx's CPU on large files by 40-44 % but made small responses 38 % slower. It stays off."
tags: ["nginx", "ktls", "openssl", "tls", "sysctl", "kernel", "benchmark"]
---

With kernel TLS, nginx and OpenSSL do the handshake as usual and then hand the session keys to the kernel. From then on the kernel encrypts. That lets nginx use `sendfile()` on HTTPS too, so file data never passes through user space. The usual claim is a big CPU saving on static files.

Turning it on takes three things:

1. OpenSSL built with `enable-ktls`. My build tool now has `KTLS=1` for that.
2. `ssl_conf_command Options KTLS;` and `sendfile on;` in nginx.
3. The `tls` kernel module.

I used the harness from [the TLS-library post](/posts/nginx-with-openssl-aws-lc-or-boringssl/), with OpenSSL 3.5 and 4.1, each with and without kTLS.

## First result: nothing worked

The kTLS builds answered small requests, but a 1 MB file never finished. It stopped after a few hundred kilobytes, and wrk logged zero completed requests in 10 seconds. The error log was empty. `strace` on a worker showed the pattern:

```text
sendfile(3, 12, [16384], 1032192) = -1 EAGAIN
epoll_wait(...) = 1          # 207 ms later
sendfile(3, 12, [16384] => [32768], 1032192) = 16384
sendfile(3, 12, [32768], 1015808) = -1 EAGAIN
epoll_wait(...) = 1          # 207 ms later
```

The kernel took one 16 KB TLS record, then reported the socket full. nginx was only told it could write again by a timer about 200 ms later. That works out to 80 KB per second.

The cause turned out to be a sysctl my own setup script writes:

```text
net.ipv4.tcp_notsent_lowat = 16384
```

It keeps the unsent part of each socket's buffer small, so HTTP/2 can still reprioritise streams. A socket counts as writable only while less than 16 KB is waiting to go out. One kTLS record from `sendfile()` is 16 KB of data plus TLS overhead, so it is always just over the mark. And the queued record was apparently not pushed out right away, so nothing woke nginx until the timer fired.

Changing the value settled it:

| tcp_notsent_lowat | 1 MB file |
|---|---|
| 16384 | does not finish in 5 s |
| 32768 | does not finish in 5 s |
| 131072 | 3 ms |
| kernel default (unlimited) | 3 ms |

It was the same with OpenSSL 3.5 and 4.1 on kernel 7.0. Without kTLS, the low value does no harm, and raising it changed nothing for the non-kTLS builds either.

## Second result: what kTLS buys

All four builds, with the mark at 131072. Same host and method: nginx on 8 logical CPUs, wrk on 4, clock pinned, 5 rounds, medians. The column header says when kTLS was on.

| | OpenSSL 4.1 | 4.1 + kTLS | change |
|---|---:|---:|---:|
| 16 MB file: nginx CPU per file | 17.8 ms | 10.6 ms | **-40 %** |
| 1 MB file: nginx CPU per file | 1.32 ms | 0.75 ms | **-44 %** |
| 1 MB file: MB/s | 4,024 | 3,891 | -3 % |
| XenForo page (105 KB): req/s | 37,152 | 35,934 | -3 % |
| XenForo page: nginx CPU per request | 0.173 ms | 0.135 ms | -22 % |
| 1 KB keep-alive: req/s | 236,655 | 147,937 | **-38 %** |
| 1 KB keep-alive: nginx CPU per request | 0.033 ms | 0.046 ms | +40 % |
| full handshake: nginx CPU | 0.41 ms | 0.44 ms | +7 % |

OpenSSL 3.5 gave the same picture within a few percent.

- **Large files cost 40-44 % less CPU.** Throughput did not rise, because on loopback the client is the limit. On a real network that CPU would be free for other work.
- **Small responses get slower.** For a 1 KB body, setting up the record in the kernel costs more than OpenSSL encrypting it in user space. That was 38 % fewer requests per second.
- **Every connection pays a little.** Handing the keys to the kernel adds about 7 % to the handshake.

## Why it stays off

My servers mostly send two kinds of responses:

- **PHP pages.** These do not use `sendfile()` at all, so kTLS never sees them.
- **Cached pages and small assets.** These sit where kTLS is neutral or slower.

On top of that, kTLS would need `tcp_notsent_lowat` raised for the whole host, which gives up the HTTP/2 behaviour that setting is there for. On a forum or blog origin behind Cloudflare, that trade comes out negative.

kTLS is worth it on a server that mainly sends large static files, such as downloads, video or image hosting, and that terminates TLS itself. For that case, `KTLS=1` is in the build tool. The requirement is now written next to it and next to the sysctl line, and the benchmark refuses to run a kTLS build below 131072, so nobody measures a stall by mistake.

One more thing broke along the way. A stalled worker survived its master being killed, and kept accepting connections on the next build's ports through `reuseport`. My first library comparison quietly mixed two builds before I noticed the kTLS counters ticking on a build that had no kTLS. The harness now kills the workers too, and refuses to start on a busy port.
