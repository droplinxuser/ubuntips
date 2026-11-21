---
title: "One idempotent script for the whole Ubuntu web stack"
date: 2026-11-18T10:15:00+08:00
description: "Angie, PHP-FPM, MariaDB, Valkey and Elasticsearch from a single Bash entry point, with a dry run before anything changes."
tags: ["ubuntu", "automation", "bash"]
---

The setup script behind most of these notes has one rule: every run must be safe to repeat. That constraint shapes the whole design.

## Install once, tune often

A full install looks like this:

```bash
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie --php ver=8.5 \
  --mariadb user=demo pass=temp size=auto bind=127.0.0.1 \
  --valkey --elastic host=localhost ram=4g --others all
```

Afterwards, the same script tunes an existing host without reinstalling anything:

```bash
sudo bash setup.sh --basic --optimize --dry-run
sudo bash setup.sh --basic --optimize
```

`--optimize` accepts 22.04, 24.04 and 26.04, so older machines get the same tuning helpers as fresh installs.

## Why parity matters

The most common bug in this class of script is drift: the installer writes one value, the "tune" path writes another, and a host ends up in a state nobody can reproduce. Here every tuned value comes from a helper shared by both paths, and there is a test that installs, optimizes, and compares the resulting configuration byte-for-byte.

## Safety rails worth copying

- **Dry run by default for anything destructive.** `--dry-run` prints the plan and changes nothing.
- **Nothing is deleted.** `--purge` stops services and restores recorded settings; it removes no package, data or log.
- **Every run is logged.** A timestamped log lands in the working directory, which makes "what changed at 02:14" answerable.
- **Single source of truth for web config.** The Angie tree is pulled from a separate repository at run time, so the server config has one owner.

If you maintain your own provisioning script, the parity test is the part I would steal first. Everything else is preference.
