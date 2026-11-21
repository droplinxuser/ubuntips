---
title: "One idempotent script for the whole Ubuntu web stack"
date: 2026-11-18T10:15:00+08:00
description: "Angie, PHP-FPM, MariaDB, Valkey and Elasticsearch from a single Bash entry point, with a dry run before anything changes."
tags: ["ubuntu", "automation", "bash"]
---

The setup script behind most of these notes has one rule: every run must be safe to repeat. That constraint shapes the whole design, and it is the part most provisioning scripts get wrong.

## Why idempotence is the hard part

A script that only has to work once can do almost anything: append to a file, create a user, restart a service, assume the default config is still there. The second run is where the trouble starts. Appending twice duplicates a directive. Creating a user that already exists may reset its groups. Restarting a service in the middle of a config write can leave it running on half a file.

The usual failure is quieter than an error message. It is *drift*: the server that was installed six months ago and patched twice no longer matches the one installed yesterday, and nothing in the repository describes the difference. The next person to touch it is guessing.

So the script is built around three ideas: separate *recording* from *changing*, make every write derived rather than appended, and give every operation a preview.

## The four rules

**1. Explicit targets.** `--basic` is required, and only the services named on the command line are touched. There is no "install everything" default:

```bash
# full stack
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie --php ver=8.5 \
  --mariadb user=demo pass=temp size=auto bind=127.0.0.1 \
  --valkey --elastic host=localhost ram=4g --others all

# minimal host, everything else auto-detected
sudo bash setup.sh --basic --angie --php
```

**2. Dry run first, always available.** `--dry-run` (alias `--check`) validates the arguments and prints the plan without changing anything, and it works for every command, not just installs:

```bash
bash setup.sh --optimize --dry-run
bash setup.sh --upgrade-php=8.6 --dry-run
```

It is deliberately runnable as a normal user, because reading the plan should not require root.

**3. Record before you change.** Original values are stored under `/var/lib/setup.sh`. That is what makes `--purge` able to restore settings rather than guess at them, and it is why a repeated run can leave a value alone instead of rewriting it from a default.

**4. Never delete.** Transient files go under `/tmp`. The script does not unlink anything on the server. `--purge` stops and disables services, removes managed cron entries and restores recorded settings, but it removes no package, no data and no log. A cleanup command that can destroy a database is not a cleanup command you run at 2 a.m.

Every run also writes `setup_<timestamp>-<pid>.log` in the directory it was started from, and when run under `sudo` the log is handed to the invoking user with mode 600. "What changed at 02:14" has an answer.

## A run, annotated

The install path does roughly this, in order:

1. **Validate** the command line and detect the host class (dedicated or virtual) from `systemd-detect-virt`, DMI and cgroups.
2. **Baseline the OS:** timezone, hostname, swap (only when total swap is 0 or below half of RAM, capped at half of RAM), CPU governor, file descriptor and sysctl limits.
3. **Repositories and packages:** third-party repositories are pinned to their own `signed-by` keyrings, so one vendor's key cannot validate another vendor's package.
4. **Services**, each installed and then tuned: Angie, PHP-FPM, MariaDB, Valkey (or an existing Redis), Elasticsearch and the helper packages.
5. **Security pass**, described below.
6. **Report**, including what was skipped and why.

`--optimize` runs the same tuning helpers against what is already installed, without reinstalling anything. It accepts Ubuntu 22.04, 24.04 and 26.04, while fresh installs target 26.04.

The two paths share code on purpose. A separate "installer" and "tuner" always drift apart; here every tuned value comes from one helper used by both.

## Install/optimize parity is a test, not a promise

The repository includes a test that installs a host, runs `--optimize`, and compares the resulting configuration with a fresh install byte-for-byte. That is a stronger claim than "the values match": it catches ordering, whitespace, file mode and include-order differences that a human reading two configs would miss.

It also gives the script a property that is easy to reason about: **a fresh install followed by an optimize is the same machine.** If they ever differ, the test fails in CI before a host is affected.

## What `--purge` actually does

This is the command people are most nervous about, so the semantics are narrow on purpose:

```bash
sudo bash setup.sh --purge            # everything managed
sudo bash setup.sh --purge angie php  # just these services
```

- stops and disables the selected services,
- removes their managed cron entries,
- restores settings recorded in `/var/lib/setup.sh`,
- keeps going past a file it cannot restore and reports it,
- installs nothing, deletes no data, has no "purge the domain" mode.

The point is to return a host to a neutral state without gambling on the contents of `/var/lib/mysql`.

## One owner for the web configuration

The Angie configuration tree is not templated inside the script. It is downloaded at run time from a separate repository, `server-configs-nginx`, and `CONFIG_SOURCE_DIR=/path` uses a local checkout when you are editing it. PHP-FPM templates live in this repository under `configs/php/`, because they are tightly coupled to the worker counts the script calculates.

That split matters: the web server config has exactly one source of truth, and a change to it is reviewed in one place rather than reconstructed from shell `cat` blocks.

## Verify instead of trust

Two commands exist to answer "is this host what the repository says it is?":

```bash
# read-only report; also flags live-vs-profile tuning drift
sudo bash setup.sh --diagnostics
grep -A40 'tuning override sources and live drift' diagnostics.log
```

`--diagnostics` writes a redacted log and changes nothing. It reports the tuning that has drifted, plus non-managed files that still define a key the script manages — the classic cause of "the config looks right but the value is wrong".

`--restart-all` exists for the case after a manual change: an ordered restart of every active service, instead of remembering the dependency order yourself.

## The security pass

Every `--basic` and `--optimize` run also does a hardening pass aimed at the web root, not at SSH:

- WordPress: `wp-config.php` owned `root:www-data` at mode 640, file editing and module installs disabled, cron moved to a managed system cron entry, debug display off, admin SSL forced, placeholder salts replaced, and a database user with global privileges narrowed to its own database.
- Known webshells quarantined under `/var/lib/setup-quarantine/`, with suspicious admins, risky plugins, world-writable files and oversized archives reported.
- Third-party APT repositories pinned to per-repository keyrings.
- An audit of SSH password authentication, public 80/443 and a non-loopback Elasticsearch.

SSH hardening, brute-force protection and origin-only firewalling are deliberately left to the operator. Those depend on how a host is reached — bastion, VPN, provider firewall — and a script guessing wrong there locks people out.

## Adopting it on a host you already have

You do not need a fresh machine:

1. Run `--diagnostics` and read the drift section.
2. Run `--optimize --dry-run` and diff the plan against what you expect.
3. Run `--optimize` during a window, then `--diagnostics` again.
4. Keep the run log with the change ticket.

The script is Bash 4.4+ and root-only, needs network access to the Ubuntu, Angie, Sury, Elastic and NodeSource repositories (or a local config checkout), and sizes MariaDB and PHP from the hardware it finds. If a value is wrong for your workload, override it through the documented environment variables rather than editing the result by hand — otherwise the next `--optimize` will quietly correct you.

## What it is not

It is not a configuration management system, and it does not try to be one. There is no agent, no inventory and no central state; the unit of truth is the repository plus `/var/lib/setup.sh` on the host. That makes it a good fit for a handful of servers and a poor fit for a fleet with per-host roles.

It is also not a substitute for monitoring. A host that was tuned correctly in March can be wrong in June because someone edited one file. `--diagnostics` catches that when you run it; a periodic run in cron is what turns it into a policy.
