---
title: "Introducing Ubuntu Tips"
date: 2026-11-21T09:00:00+08:00
description: "A place to write down the things that took too long to figure out the first time."
tags: ["meta"]
---

Most of the notes on this site started as comments in a shell script.

Provisioning an Ubuntu host is not hard, but it is full of decisions that are easy to get subtly wrong: the PHP-FPM process manager that looks fine at idle and collapses under load, the MariaDB buffer pool sized for a machine you no longer run, the sysctl values that only matter at 10,000 requests per second. Once you have worked them out, you write them down somewhere.

This blog is that "somewhere". It is also an experiment in publishing: everything here is Markdown in a git repository, rendered by Hugo, and served as static files. No database, no admin panel, no plugin updates. The [next post](/posts/why-this-blog-is-a-static-site/) explains that decision in detail.

## What gets published

The posts fall into four rough categories:

- **Tuning notes.** Why a value is what it is, what it costs, and how to check that it actually applied. A number without a verification step is a rumour.
- **Build and provisioning.** The design of the [setup script](https://github.com/droplinxuser/ubuntu-setup-script) that installs and tunes the whole stack, including the parts that exist only to make reruns safe.
- **Benchmarks with a method.** Load tests are easy to make look convincing. Posts that include numbers also include the test bed, the order the setups ran in, and what was done to keep each run honest.
- **Post-mortems.** The change that looked safe in a dry run, the package that silently changed a default, the "optimisation" that was inside noise.

Expect the occasional opinion, but the useful parts are the commands, the configuration, and the measurements.

## How the numbers are made

Benchmarks on this site come from one dedicated host: a 6-core/12-thread Xeon with 62 GB of RAM running Ubuntu 26.04, with Angie, PHP-FPM, MariaDB and Valkey installed and tuned by the same script the posts describe. Content is generated, the load generator is [wrk](https://github.com/wg/wrk), and run order is rotated so one setup does not always get the warm cache.

Two rules apply to every post with a table of results:

1. **Medians, not best runs.** Single runs are treated as anecdotes, because they are. One early home-page result in the XenForo post was 30% off until the three-round median brought it back in line.
2. **State the limits.** A benchmark that simulates a remote database with `tc netem` measures network latency and nothing else. It does not reproduce a remote server's CPU, disk or jitter. Saying so is part of the result.

Where a claim cannot be measured on this hardware, the post says so rather than extrapolating.

## How the site is built

The workflow is deliberately boring:

```bash
# write a post
hugo new content posts/some-topic.md

# preview
hugo server

# publish
git add -A && git commit -m "post: some topic" && git push
```

A push to `main` triggers GitHub Actions, which builds the site and deploys it to GitHub Pages. Social cards, sitemap and structured data are generated in the same run. The whole build takes seconds, and the published output is a directory of HTML, CSS and images.

This also means the site has no runtime to patch. There is no login to brute-force, no query string to inject into, and no upload directory to leave executable. For a blog about server hardening, that felt like the minimum bar.

## What you will not find

- **Comments.** If you want to reply, email or open an issue on the repository. Moderation queues are a hobby I am not taking up.
- **A newsletter popup.** The [RSS feed](/index.xml) is the subscription mechanism.
- **Tracking scripts.** No analytics, no third-party fonts, no embeds that phone home.
- **Sponsored posts.** If that ever changes, the post will say so at the top.

## Corrections

If a command is wrong, a value is stale, or a measurement does not reproduce, the fix is a pull request or an issue on the repository. Posts are versioned in git, so the history of a correction is public, which is more than most blogs can say.

## Following along

Subscribe to the [RSS feed](/index.xml) and you will get new posts without an algorithm deciding what you see. Start with [why this blog is a static site](/posts/why-this-blog-is-a-static-site/) and [the one idempotent script](/posts/one-idempotent-script/) if you want the two ideas the rest of the site builds on.
