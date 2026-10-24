# Nginx Cache Warmup

Prime Nginx FastCGI/proxy cache by crawling a sitemap — so the first real visitor gets a cache **HIT** instead of a cold **MISS**.

## What it does

- Fetches every URL from a sitemap (or sitemap index, recursed one level) with parallel curl workers
- Skips/includes URLs via `--skip` / `--only` regexes (handy for excluding `/cart`, `/checkout`, `/my-account`)
- Per-worker `--delay`, custom `--user-agent`, extra `--header`s, per-request `--timeout`
- Summary: counts by status class, average response time, list of failed URLs
- `--output report.md` appends a Markdown summary; `--dry-run` lists URLs without fetching

## Usage

```bash
./warmup.sh --sitemap https://example.com/sitemap.xml --concurrency 10 \
    --skip '/cart|/checkout|/my-account' --output warmup-report.md
```

## Cron

Warm the cache after deploys or nightly:

```cron
15 3 * * * /opt/nginx-cache-warmup/warmup.sh --sitemap https://example.com/sitemap.xml --concurrency 8 --output /var/log/warmup.md >/dev/null 2>&1
```

## License

MIT
