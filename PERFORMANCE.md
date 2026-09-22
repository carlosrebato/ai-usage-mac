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

## Index correctness benchmark

On 22 September 2026, the opt-in index benchmark processed 1,468,263,432 bytes
across the retained 90-day Claude and Codex history. An immediate incremental
pass read zero bytes. A second database rebuilt from scratch produced identical
weekly token/cost totals and identical daily token series for both providers.
The two complete imports and comparison finished in 213.2 seconds.

Reproduce locally without printing conversation content:

```sh
RUN_LOCAL_METRICS_BENCHMARK=1 swift test \
  --filter indexesRealLogsOnceAndMatchesACleanRebuild
```

## Reproduce

Build and install a signed Release, find its PID, then run:

```sh
Scripts/measure-release-performance.sh PID 3600 10 \
  .artifacts/release-performance-1h.csv
```

Do not run Xcode builds, test suites, secret scanners, or other heavy jobs during
the measurement. Compare average and median values, the 95th percentile, disk
deltas, and whether RSS trends upward over time.
