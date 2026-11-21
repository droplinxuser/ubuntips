---
title: "Introducing Ubuntu Tips"
date: 2026-11-21T09:00:00+08:00
description: "A place to write down the things that took too long to figure out the first time."
tags: ["meta"]
---

Most of the notes on this site started as comments in a shell script.

Provisioning an Ubuntu host is not hard, but it is full of decisions that are easy to get subtly wrong: the PHP-FPM process manager that looks fine at idle and collapses under load, the MariaDB buffer pool sized for a machine you no longer run, the sysctl values that only matter at 10,000 requests per second. Once you have worked them out, you write them down somewhere.

This blog is that "somewhere".

Expect short, practical posts:

- the reasoning behind a tuning value, and how to verify it actually applied,
- checklists for hardening a fresh host,
- the occasional post-mortem of a change that looked safe in a dry run.

There is no comment section, no newsletter popup and no tracking script. The whole site is Markdown in a git repository, built by Hugo and served as static files. If you want to follow along, the [RSS feed](/index.xml) is the intended way.
