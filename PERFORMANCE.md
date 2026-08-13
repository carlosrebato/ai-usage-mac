# Performance

AI Usage is designed to remain idle between provider refreshes and to ingest
only appended Claude and Codex session data.

## Release 0.1.0 baseline

The notarized universal Release was sampled every ten seconds for one hour on
13 August 2026. Both providers were connected, automatic refresh was enabled,
and Codex was actively producing the session used by this benchmark.

| Metric | Result |
| --- | ---: |
| Samples | 360 |
| CPU, average | 0.271% |
| CPU, median | 0.000% |
| CPU, 95th percentile | 0.700% |
| RSS, average | 59.36 MB |
| RSS, median | 56.75 MB |
| Physical footprint, average | 73.17 MB |
| Disk read | 83.35 MB/hour |
| Disk written | 1.11 MB/hour |

The maximum CPU sample occurred during startup/index initialization. There was
no sustained CPU load or memory growth. The historic SQLite database is no
longer queried at every two-minute provider poll. Its derived totals are cached
until the fifteen-minute incremental scan reports an actual index change.

Disk reads include provider refreshes and newly appended Codex JSONL bytes. In
this run, the first fifteen-minute scan observed the active benchmark session;
later unchanged scans did not re-read or re-aggregate the historical database.

The raw CSV is intentionally generated locally rather than committed because
it contains timestamps and machine-specific process characteristics.

## Reproduce

Build and install a signed Release, find its PID, then run:

```sh
Scripts/measure-release-performance.sh PID 3600 10 \
  .artifacts/release-performance-1h.csv
```

Do not run Xcode builds, test suites, secret scanners, or other heavy jobs during
the measurement. Compare average and median values, the 95th percentile, disk
deltas, and whether RSS trends upward over time.
