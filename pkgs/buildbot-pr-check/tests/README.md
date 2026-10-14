# Tests for buildbot-pr-check

This directory contains integration tests using VCR.py to record and replay HTTP
interactions.

## Running Tests

```bash
# Run tests with recorded cassettes
pytest

# Record new cassettes (makes real HTTP requests)
python tests/record_cassettes.py
```

## Test Coverage

The replay tests cover GitHub `Mic92/dotfiles#3016` parent-build failures and
evaluation errors, and a successful Gitea `clan/clan-core#4235` build.

## VCR Cassettes

The cassettes are stored in `tests/cassettes/` and contain recorded HTTP
responses from:

- GitHub API
- Gitea API
- Buildbot API

Ordinary `pytest` runs use VCR's `record_mode="none"`: missing interactions
fail instead of making unplanned network requests. The explicit
`python tests/record_cassettes.py` command enables `record_mode="once"` for
missing interactions; it does not refresh existing responses.

The recording hook removes response `Set-Cookie` headers, and VCR filters
request authorization and cookie headers. Recorded session cookies were
present in earlier Git revisions; changing the current cassettes does not
remove them from history. Before publishing repository history, coordinate
credential-owner assessment/invalidation and a review of all reachable refs.
