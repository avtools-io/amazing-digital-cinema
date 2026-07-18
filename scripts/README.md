# Maintenance Scripts

## Checking README links

Maintainers can check all links in `README.md` with:

```sh
./scripts/check-links.sh
```

The checker requires `curl`. It retries transient responses with exponential backoff, limits checks to one concurrent request per host and exits with a non-zero status when it finds dead links. Narrowly scoped response exceptions and retry settings are maintained in `check-policies.json`.

Pass another Markdown file as the first argument when needed:

```sh
./scripts/check-links.sh path/to/file.md
```
