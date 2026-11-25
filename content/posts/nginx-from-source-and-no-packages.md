---
title: "Dropping the packages: compiled nginx, PHP and Valkey, and what the migration tests broke"
date: 2026-11-25T20:00:00+08:00
description: "My setup script now builds nginx, PHP and Valkey from source and installs none of them from packages. Live servers migrate once, on --optimize. Testing that migration and a PHP downgrade chain found eight bugs, including a build log that grew to 1.7 TB. A day later, 1.22.1 dropped pre-compressed static files."
tags: ["nginx", "angie", "php", "valkey", "clang", "migration", "openssl", "chevereto", "xenforo", "wordpress", "ubuntu"]
---

[The last post](/posts/compiling-valkey-and-the-executable-stack/) ended with compiled nginx edging out compiled Angie by 0.5-1.5 % on cached pages. That was enough to change the plan. Version 1.22.0 of my setup script installs no web server, PHP or Valkey packages at all. nginx comes from the latest nginx.org mainline, PHP (FPM and CLI) from php.net, and Valkey from its release tarball. All three are compiled with the same clang, LTO and BOLT recipe as before. MariaDB and Elasticsearch stay packages, because compiling them measured not worth it.

Fewer moving parts was the point. There is one way to install each service, with no package mode to keep working beside it.

## What a server gets now

- **nginx without its name.** The `Server` header is gone, and so is the `<hr><center>nginx</center>` line on error pages. The build checks how many lines its patch changed and refuses a tarball where it no longer applies.
- **Only the PHP extensions the sites use.** WordPress, XenForo and Chevereto each have a set, and the script detects which apps are installed. Extras such as SQLite, GMP, Redis or intl are opt-in with `--php ext=`.
- **No Sury, no Angie repository, no `valkey-server` package.** A plain `--optimize` on an older server migrates it once.

## Migrating a live server

The migration does PHP first, then Valkey, then nginx. Each part rolls back on its own if the new service does not answer for every site the old one served. Packages are purged only after the compiled service has served. Angie configurations that used its ACME module move to the origin's self-signed certificate, which is what Cloudflare's Full mode expects anyway.

I ran it on a copy of a 1.21 server with three apps, an ACME vhost and an `auth_basic` vhost. It stopped three times, and each time Angie went on serving:

1. The pre-flight scan read the Angie package's own default file as an operator file, and blocked on its status API line.
2. The cutover check expected the catch-all `Host: localhost` to answer like Angie's welcome page.
3. A part that had rolled back was never retried, even by a fixed release. It is now retried when the migration code changes.

After the fixes, the migration finished, the security and cookie suites passed, and the server survived a reboot.

## A 1.7 TB build log

Then I tried `--upgrade-php=8.6`. The build failed, safely: igbinary does not compile on PHP 8.6 yet, so 8.5 kept serving. Fifteen minutes later, MariaDB was down with a full disk.

The build tool prints the last lines of its log when a step fails, with `tail log >&2`. My script runs that tool with stderr appended to the same log, so `tail` kept reading what it was writing and never reached the end. Now the excerpt is skipped when stderr *is* the log, and every build runs under `ulimit -f`, so no single file can grow past 20 GB.

## Down to PHP 8.1

To see how far down `--upgrade-php` goes, I walked a host from 8.5 to 8.1 and back. Every step either worked or failed with the old version still serving. It found four more bugs:

- **PHP 8.4 and older did not link.** PHP's bundled libtool drops `-fuse-ld=lld` on some links, so clang fell back to GNU ld, which cannot handle the ThinLTO objects. The build now runs clang through a tiny driver that adds lld to every link.
- **PHP 8.1 does not compile against OpenSSL 4**, so the 8.1 series now builds with OpenSSL 3.6.
- **On PHP 8.1, Chevereto answered 500 on every page.** Its Composer platform check wants PHP 8.2. The upgrade now reads that check and refuses the switch before building anything.
- **The after-switch check had reported "3 OK" all along.** It requested `/index.php`, which nginx answers with a redirect without ever running PHP. It now loads each home page.

PHP 8.0 is refused outright: it has had no security fixes since 2023 and does not build against OpenSSL 3. Switching back to the previous version takes about 40 seconds, because one build is always kept for rollback.

## One day later: no more pre-compressed files

In 1.22.1 nginx dropped `gzip_static` and `brotli_static`, along with the job that kept `.br` and `.gz` copies of every static file beside it. Every response is now compressed on the fly with gzip or Brotli.

Two more bugs turned up while testing that release:

- **Building only the Brotli filter failed.** Its config looks for the library one directory deeper than the full module does.
- **A vhost could stop `--optimize`.** One that still said `gzip_static on;` passed when nginx was rebuilt, but a vhost added afterwards stopped the run at `nginx -t`. Now every run comments such a line out and reports it.

1.22.1 is out, and [the mirror](https://github.com/droplinxuser/setup-build-sources) now keeps a copy of every source tarball these builds download, nginx signatures included.
