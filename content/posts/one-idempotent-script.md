---
title: "One idempotent script for the whole Ubuntu web stack"
date: 2026-11-18T10:15:00+08:00
sticky: true
description: "Angie, PHP-FPM, MariaDB, Valkey and Elasticsearch from a single Bash entry point: every command, option and safety rule in one place."
tags: ["ubuntu", "automation", "bash"]
---

The setup script behind most of these notes has one rule: every run must be safe to repeat. That constraint shapes the whole design, and it is the part most provisioning scripts get wrong.

This post is the long version of the script's README: what it installs, what each flag does, what it refuses to touch, and how to verify a host afterwards. The source is at [droplinxuser/ubuntu-setup-script](https://github.com/droplinxuser/ubuntu-setup-script).

## Why idempotence is the hard part

A script that only has to work once can do almost anything: append to a file, create a user, restart a service, assume the default config is still there. The second run is where the trouble starts. Appending twice duplicates a directive. Creating a user that already exists may reset its groups. Restarting a service in the middle of a config write can leave it running on half a file.

The usual failure is quieter than an error message. It is *drift*: the server installed six months ago and patched twice no longer matches the one installed yesterday, and nothing in the repository describes the difference. The next person to touch it is guessing.

So the script separates *recording* from *changing*, makes every write derived rather than appended, and gives every operation a preview.

## Requirements

| Item | Detail |
|---|---|
| OS | Ubuntu **26.04 LTS or newer** for installs; `--optimize`, `--upgrade-php`, `--diagnostics` and `--restart-all` also accept 22.04 and 24.04 |
| Shell | Bash 4.4+, root |
| Network | Ubuntu, Angie, Sury, Elastic and NodeSource repositories, plus GitHub for the web-server config tree (or a local checkout) |
| Resources | Elasticsearch needs ~1.5 GB of disk plus its heap; MariaDB its buffer pool; PHP one static worker per `pm.max_children` slot |

A host can only run **one PHP-FPM version** at a time: Angie and the pool both use `/run/php/php-fpm.sock`. Changing versions is what `--upgrade-php` is for; `--php ver=X` is a first installation and refuses to replace a version that is already there.

## The command surface

`--basic` is required for every install, and all of its values are optional. Only the services named on the command line are touched.

| Command | Purpose |
|---|---|
| `--basic [server=] [host=] [swap=] [time=]` | OS baseline; required for every install |
| `--angie [anubis=yes\|no]` | Angie web server, config tree, optional Anubis bot filter |
| `--php [ver=] [children=] [max_requests=]` | PHP-FPM |
| `--mariadb user= pass= [size=] [bind=]` | MariaDB |
| `--valkey [ram=] [policy=] [io_threads=]` | Valkey cache |
| `--elastic [host=] [ram=]` | Elasticsearch |
| `--others ITEM... \| all` | helper packages |
| `--domain DOMAIN [app=] [db=] [user=] [pass=] [sql=]` | vhost, certificate, optional database |
| `--optimize [anubis=yes\|no]` | tune the OS and every installed service in place |
| `--upgrade-php=X.Y` | replace the installed PHP version in place |
| `--diagnostics` | write a redacted, read-only report |
| `--restart-all` | ordered restart of every active service |
| `--purge [TARGET...]` | stop and disable services, restore recorded settings |
| `--dry-run` / `--check` | print the plan, change nothing; works with every command |

A full install looks like this:

```bash
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie --php ver=8.5 \
  --mariadb user=demo pass=temp size=auto bind=127.0.0.1 \
  --valkey --elastic host=localhost ram=4g --others all
```

...and a minimal one like this:

```bash
sudo bash setup.sh --basic --angie --php
```

## `--basic`

| Option | Default | Effect |
|---|---|---|
| `server=dedi\|vps` | auto-detect | install-time hint; `dedi` sets the `performance` CPU governor. `--optimize` re-detects the class from the hardware |
| `host=FQDN` | `<threads>c-<RAM>g-<storage>` | hostname via `hostnamectl`; a repeat run without `host=` keeps the current name |
| `swap=SIZE` | only when total swap is 0 or below half of RAM | `/swapfile` of exactly that size, capped at half of RAM |
| `time=REGION/CITY` | `Asia/Manila` | timezone; a repeat run without `time=` keeps the current zone |
| `mitigations=off\|on` | not touched | adds/removes `mitigations=off` in a managed GRUB drop-in; effective at the next reboot, and the run checks the generated boot menu actually carries it |

`mitigations=off` is measured and tempting, and it is also a real trade: it removes the kernel's protection between local processes. The README is explicit that it belongs on hosts where only you run code — one key-only administrator, no shared hosting, no untrusted local users.

`--basic` changes hostname, resolver, sysctls, limits, firewall and timezone. The repository's own advice is to test it on a disposable server first; that is not boilerplate.

## Angie

`--angie [anubis=yes|no]`.

- Installs `angie` and `angie-module-brotli`.
- Deploys the configuration tree from a **separate repository** (`server-configs-nginx`) with its own deployer; `CONFIG_SOURCE_DIR=/path` uses a local checkout, `CONFIG_REPO_URL`/`CONFIG_REPO_REF` select a fork or branch.
- Applies the hardware profile and guest caches through the same `angie_apply_profile` that `--optimize` uses.
- Ships systemd `LimitNOFILE` and `/etc/default/angie`, generates `http.d/cloudflare.conf`, restarts the service.

Guest caches for WordPress and XenForo report their state in a single `X-Cache-Status` header (`HIT`, `MISS`, `BYPASS`, `EXPIRED`). Cached locations disable per-hit AIO and Brotli on purpose: the body is already compressed, so re-running either filter only costs CPU.

An upstream that a deployed vhost still references but the canonical tree no longer defines is preserved in `http.d/zz-setup-preserved-upstreams.conf` instead of letting `angie -t` fail with "host not found in upstream". The include is regenerated each run and retired once the repository defines the name again.

### Anubis, optionally

`--angie anubis=yes` puts a bot filter in front of every site. It is not installed unless asked for, works on fresh and existing hosts, and `--optimize anubis=no` restores direct TLS, removes the generated Angie files and stops/disables the service while keeping the binary for a fast re-enable.

## PHP-FPM

| Option | Default | Effect |
|---|---|---|
| `ver=X.Y` | newest Sury build | version to install |
| `children=auto\|N` | auto | `pm.max_children`; an explicit value wins |
| `max_requests=N` | threads × 1024 | recycle a worker after N requests |

The pool is always `pm = static`. The worker count is logical CPUs × a factor chosen by storage and topology:

| Situation | Workers per CPU |
|---|---|
| Local MariaDB on flash | 1.0 |
| Shared/virtual CPU, or a remote database | 1.5 |
| Spinning disks | 2.0 |

That is then capped by the shared-memory plan (at most RAM/2 at 96 MB per worker, 512 maximum). The measured advice is blunt: on the 16-thread audit host, 16 workers did 834 req/s and 32 workers did 808 req/s — extra workers only contend for the same cores.

Also managed: `request_terminate_timeout 300s`, slow log at 10 s, `rlimit_files 524288`, systemd `LimitNOFILE=524288`, `UMask=0027`, and `KillSignal=SIGQUIT` so a restart closes persistent MariaDB connections gracefully instead of logging "Aborted connection" warnings.

`php.ini` gets `memory_limit` 256–512M (128M under 2 GB RAM), OPcache 128–512 MB with interned strings, a 4–16 MB realpath cache, and JIT **always tracing**, with the buffer at OPcache/8. There is no JIT mode switch; an old `SETUP_PHP_JIT` value is ignored with a notice. Measured: tracing beat JIT-off by 5% on XenForo members, `function` mode lost 6–8%, and a 256 MB buffer was slower than 64 or 128 MB.

Extensions default to the XenForo profile: `fpm cli opcache mysql gd curl xml zip gmp mbstring`. **No `redis`/`igbinary` by default** — XenForo runs on SV RedisCache's pure-PHP client, and WordPress runs without an object-cache drop-in. `--domain` installs what an app cannot run without (Chevereto pulls `redis`/`igbinary` and `imagick`); `--upgrade-php` carries whatever the old version had.

The PHP step also repairs the web server: `fastcgi_param PATH_TRANSLATED` in every `h5bp/php*.conf`, and it comments out per-request `PHP_ADMIN_VALUE open_basedir` — PHP-FPM caches admin values per worker, so one vhost's setting otherwise leaks onto every other vhost in the shared pool.

## MariaDB

| Option | Default | Effect |
|---|---|---|
| `user=U` | required | admin user for `localhost`, `127.0.0.1` and `::1` (needed with `skip_name_resolve`) |
| `pass=P` | required | also written to `/etc/mysqlbkup.cnf`, mode 600 |
| `size=auto\|4gb` | auto | buffer pool = live data+index +5%, 128 MB minimum, capped at 80% of RAM when MariaDB is the only data service, otherwise half |
| `bind=ADDR[,ADDR...]` | `127.0.0.1` | loopback by default; `IPV4` resolves the public address. TCP 3306 is never opened in the firewall |

The interesting part is `size=auto`. It measures the live data, so an empty database gets 128 MB and a database that grew gets a larger pool — and a pool that is more than one step above its target is shrunk online rather than holding RAM the data does not use. That is why the README tells you to run `--optimize` again after a large `sql=` import: the plan is re-measured, not guessed.

The hardware profile sets the redo log to a quarter of the pool, I/O capacity by disk type (NVMe 10000/20000, SSD 4000/8000, HDD 400/800), `thread_handling=pool-of-threads`, `max_connections` at PHP workers × 1.25 + 50, table caches, temp tables, `flush_log_at_trx_commit=2`, and slow/error logs under `/var/www/logs/mariadb/`.

Validation matters more than any of these values: generated files are checked with `mariadbd --help --verbose` before any restart. The install also embeds `mysqltuner.pl` and a `mysqlbackup` utility that keeps 30 dumps.

A less obvious base setting: `innodb_snapshot_isolation = 0`, so `REPEATABLE READ` keeps MySQL's behaviour and XenForo does not hit MariaDB error 1020.

## Valkey

| Option | Default | Effect |
|---|---|---|
| `ram=SIZE` | data +20%, 128 MB minimum | `maxmemory`; an explicit value is used verbatim |
| `policy=NAME` | `allkeys-lru` | `maxmemory-policy` |
| `io_threads=N` | 1 | extra socket I/O threads |

Managed config: loopback `bind`, `protected-mode`, a Unix socket at `/run/valkey/valkey.sock` (mode 770, `www-data` in the `valkey` group), `save ""`, `appendonly no`, `maxclients` at PHP workers × 4 + 2000 (minimum 10000), and `hz 10`.

Two operational notes:

- With `redis-server` installed, `--valkey` is **skipped with a warning** and `--optimize` tunes the existing Redis with the same profile. If both exist, Valkey wins.
- Runtime values are applied with `CONFIG SET`; a restart (which empties the cache) happens only for startup-only keys. On a cache that is allowed to evict, filling its maxmemory is normal, not a reason to shrink it.

## Elasticsearch

`--elastic [host=] [ram=]`. Defaults to `localhost` and `auto` heap: index store/4 rounded to 512 MB, between 512 MB and 25% of RAM, 31 GB ceiling.

Managed: single-node discovery, X-Pack security off (keep it off unless you have TLS and a firewall), `bootstrap.memory_lock`, thread pools sized from CPUs, a 200 MB content limit, `vm.max_map_count`, and — when the index fits in the memory plan — `index.store.preload: ["*"]`, so index files are loaded at open rather than on first query.

It also fixes the yellow health a single node reports because of unassigned replicas, by setting replicas to 0 plus a low-priority template. A probe endpoint follows `http.host`/`network.host`/`http.port` if you change them.

## Others and domains

`--others` takes one or more of `smartmon`, `nvme`, `gif`, `nodejs`, `sysstat`, or `all`. Node.js comes from NodeSource with the major pinned by `SETUP_NODE_MAJOR` (default 26); an installed major is never switched silently, because the native-addon ABI changes.

`--domain` is standalone but needs Angie (and MariaDB when `db=` is given), can be repeated, and supports these vhost templates: `basic`, `xf`, `wordpress`, `flarum`, `pingvin`, `chevereto`, `polr`, `lychee`, `shlink`, `sfs`, `php`, `node`.

It creates the document root (`/var/www/<domain>/public`), a self-signed certificate under `/etc/angie/ssl/<domain>/`, and a vhost tested with `angie -t`. Existing vhosts and databases are preserved, and application code is not installed. A dump import runs only into an empty database, and a dump carrying its own `CREATE DATABASE`/`USE` for another schema is refused before anything loads.

A domain install ends with the same tuning pass `--optimize` performs, because a new vhost changes the plan: the PHP worker cap, OPcache file budget, guest cache, and the managed wp-cron / XenForo job entries.

## The security pass

Every `--basic` and `--optimize` run includes hardening aimed at the web root:

- **WordPress:** `wp-config.php` owned `root:www-data` at mode 640, `DISALLOW_FILE_EDIT` and `DISALLOW_FILE_MODS`, `DISABLE_WP_CRON` with a managed cron entry, `WP_DEBUG_DISPLAY=false`, `FORCE_SSL_ADMIN`, placeholder salts replaced, and a globally privileged `DB_USER` narrowed to its own database.
- **Malware:** known webshells quarantined under `/var/lib/setup-quarantine/`; suspicious admins, risky plugins, world-writable files and oversized archives reported.
- **APT:** every third-party repository pinned to its own `signed-by` keyring, so one vendor's key cannot validate another vendor's package.
- **Audit:** reports SSH password authentication, public 80/443 and a non-loopback Elasticsearch.

SSH hardening, brute-force protection and origin-only firewalling are left to the operator on purpose. They depend on how a host is reached — bastion, VPN, provider firewall — and a script guessing wrong there locks people out.

## `--optimize`, and parity with install

`--optimize` tunes the OS and every installed service in place on 22.04, 24.04 and 26.04. It **never installs, starts or purges a managed service**, and never touches swap, the resolver or the firewall. The only package it may add is `angie-module-brotli` (plus Anubis when asked), and the only one it may remove is certbot, once nothing uses it.

Angie is synced from the config repository and tested; the service is reloaded **once, and only when the tree digest changed**. A failed sync or test restores the previous tree and unit drop-in. Every application guest cache reports through the same `X-Cache-Status` header.

For Cloudflare-proxied sites (SSL mode *Full*), it can move a vhost off certbot to the host's self-signed default pair. That only happens when every name in the server block is an exact host name resolving solely to Cloudflare; a wildcard or regex name keeps the block where it is. The change is then proven by a probe that must echo fresh digits through Cloudflare before the vhost is accepted — a cached answer, a challenge or a 526 is not proof. Without proof, the vhost is restored byte for byte.

The property that makes this trustworthy is a test, not a promise: **a fresh install followed by `--optimize` produces the same configuration, byte-for-byte.** That catches ordering, whitespace, file-mode and include-order differences a human would miss, and it means "install, then optimize" is a safe way to learn the script.

## `--upgrade-php`

`--upgrade-php=X.Y` replaces PHP in place. It is standalone and cannot be combined with install flags, `--optimize`, `--purge`, `--diagnostics`, `--restart-all` or `--domain`.

The order is what makes it safe:

1. **Snapshot** every PHP package, extension, `apt-mark` state, operator `.ini`, extra pool and the old `/etc/php` tree under `/var/lib/setup.sh/`.
2. **Preflight the applications.** It detects WordPress, XenForo and Chevereto roots (including a Redis object-cache drop-in and a XenForo `config.php` that selects the core Redis provider) and checks the target repository for every hard requirement. If a site would lose an extension, it stops **before the purge**, with PHP still serving. `SETUP_PHP_ALLOW_MISSING_EXT=1` accepts the loss explicitly.
3. **Purge**, then **install** the target and map every old extension. An extension the new release has not published is reported and retried by the next upgrade; core PHP still installs.
4. **Migrate** operator ini files and extra pools, validate with `php-fpm -t`, preserve `date.timezone`.
5. **Tune** with the same tuner as install, then repoint Angie from a TCP `127.0.0.1:9000` upstream to the new Unix socket if needed.
6. **Verify** CLI version, units, every pool socket, that OPcache really loads, and that Angie has no leftover TCP handler. A Markdown report with rollback commands lands in `/var/log/setup-php-upgrade-<timestamp>.md`. If the tuned FPM does not start, the old version is rolled back.

The resulting files are byte-identical to a fresh `--basic … --php ver=X.Y` install, and a following `--optimize` changes nothing.

## Maintenance

| Command | Behavior |
|---|---|
| `--diagnostics` | one mode-600 `diagnostics.log`: hardware, network, sysctls, units, per-service config and runtime stats, slow/error logs, ownership, UFW, SSH, cron, package state. Read-only, credentials redacted |
| `--restart-all [--dry-run]` | repairs `/var/www` log ownership, stops Angie and active PHP-FPM, restarts Valkey/Redis, Elasticsearch (waits for HTTP) and MariaDB (waits for `SELECT 1`), then starts PHP-FPM and Angie. Only units that were active are touched |
| `--purge [TARGET...]` | stops and disables the selected services and removes managed cron entries |

`--purge` targets are `all` (default), `basic`, `angie`, `php`, `mariadb`, `valkey`, `elastic`, `others`. Nothing is uninstalled or deleted: no package, no data, no log. `basic` restores the recorded hostname line, timezone, DNS, every sysctl the profile wrote, limits, the pre-install CPU governor, the unattended-upgrades state and UFW state, while leaving SSH rules and `/swapfile` alone.

That is the whole point of the recorded state in `/var/lib/setup.sh`: restore means *restore what was there*, not *assume the default*.

## Tuning pins and environment overrides

Every automatic value has an override, and the overrides are scoped:

| Example | Scope |
|---|---|
| `SETUP_PHP_WORKERS_PER_CPU=1.5` | install or one run; `--optimize` ignores it |
| `SETUP_MARIADB_IO_CAPACITY="4000 8000"` | install or one run; `--optimize` ignores it |
| `SETUP_BROTLI_LEVEL=6` | dynamic Brotli level |
| `SETUP_PRECOMPRESS_ASSETS=1` | pre-compress XenForo/WordPress assets and refresh from cron |
| `SETUP_PHP_PAGE_GZIP=0` | stop PHP gzipping WordPress/Chevereto pages into the cache |
| `SETUP_WP_GUEST_CACHE=0` | leave WordPress vhosts uncached instead of adding the include |
| `SETUP_UFW_SSH_LIMIT=0` | skip `ufw limit` on SSH, for an automation host |

The distinction matters: values recorded in `/etc/default/setup-tuning` persist across `--optimize`, while tuning pins made for a single run are cleared so the next run returns to the profile. Hand-editing the generated files does neither — the next `--optimize` will quietly correct you.

## Testing

The repository tests the claims, not just the code:

- `tests/test-tuning.sh` (no root) covers the tuning helpers, memory plan, config repairs and rollback.
- `tests/test-dry-run-matrix.sh` runs every flag, app type, purge mode and representative invalid input through `--dry-run`.
- CI runs both plus `shellcheck`.
- `tests/deploy-audit/` captures a host manifest or the managed config before and after, which is how install/`--optimize` parity is checked.
- `tests/stress-site/` deploys a synthetic full stack and drives it with local and remote load harnesses; `tests/bench-php-matrix/` holds the XenForo/PHP matrix and its reports.

## Files and state

| Path | Purpose |
|---|---|
| `/run/setup.sh.lock` | run lock |
| `/var/lib/setup.sh/` | originals for `--purge basic`, package-origin markers, PHP upgrade snapshots |
| `/etc/default/setup-tuning` | host facts and feature choices kept across runs |
| `/etc/angie/` | Angie tree, vhosts, certificates, managed maps |
| `/etc/php/<ver>/fpm/…` | `zz-setup-optimize.ini`, `custom_dan.ini`, `pool.d/www.conf` |
| `/etc/mysql/mariadb.conf.d/` | `50-server.cnf` base block, `99-setup-optimize.cnf` profile |
| `/etc/valkey/valkey.conf`, `/run/valkey/valkey.sock` | cache config and socket |
| `/etc/elasticsearch/…` | managed block and JVM heap file |
| `/var/www/logs/<service>/` | one rotated log tree for every service |
| `/var/log/setup-optimize-*.md`, `diagnostics.log`, `setup_*.log` | reports and run logs |

Credentials are never stored in the repository. The MariaDB password is written only to `/etc/mysqlbkup.cnf` on the target host.

## Adopting it on a host you already have

You do not need a fresh machine:

1. `--diagnostics` and read the drift section.
2. `--optimize --dry-run` and check the plan against what you expect.
3. `--optimize` in a window, then `--diagnostics` again.
4. Keep the run log with the change ticket.

If a value is wrong for your workload, override it through the documented variables and keep the override recorded, rather than editing generated files that the next run will rewrite.

## What it does not do

- It is **not** a configuration-management system: no agent, no inventory, no central state. The unit of truth is the repository plus `/var/lib/setup.sh` on the host.
- It does **not** alter application schemas: no `ALTER TABLE`, no index creation, no data change on a forum or CMS database. The README documents measured fixes that are deliberately left to the operator, such as a covering index for the XenForo Media Gallery count query.
- It does **not** replace monitoring. A host tuned correctly in March can be wrong in June because someone edited one file; `--diagnostics` finds that when you run it, and a periodic run is what turns it into a policy.

Within those limits, the design goal is simple: any run, on any supported host, leaves a state you can describe, repeat and undo.
