# Maintenance Scripts

## Checking README links

Maintainers can check all links in `README.md` with:

```sh
./scripts/check-links.sh
```

The checker requires `curl`. It reports restricted and rate-limited responses as warnings and exits with a non-zero status when it finds dead links.

Pass another Markdown file as the first argument when needed:

```sh
./scripts/check-links.sh path/to/file.md
```
