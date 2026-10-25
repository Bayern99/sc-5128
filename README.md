# SC #5128 contribution package

A self-contained public package for [`supercollider/supercollider#5128`](https://github.com/supercollider/supercollider/issues/5128): a minimal reproducer plus a technical report that separates retained logs, historical run summaries, and a static source hypothesis.

The application that exposed the fault has private source and is not linked here.

## Contents

| File | Purpose |
| --- | --- |
| [`upstream-sc-5128-report.md`](upstream-sc-5128-report.md) | Full report: symptom, static GC hypothesis, reproducer, controls, untested fix directions, evidence status. |
| [`repro-5128.scd`](repro-5128.scd) | Standalone reproducer. No Server, no GUI, ~12–20 s. |
| [`issue-comment.md`](issue-comment.md) | Draft comment for the upstream issue; relative filenames until the public SHA is filled in. |
| [`evidence/`](evidence/) | Small RED/GREEN excerpts and their archive provenance. |

## Running the reproducer

```sh
sclang repro-5128.scd
```

Expected on a faulting run: `rowsAreArrays=false ... fault=nonArrayRow receiver=Frame`. The fault is probabilistic; a clean run reaches `dropped=1728` with all three voices at `640`. The script requires no quarks, though the host sclang may load extensions or quarks at startup.

## Status

- No new experiments were run for this package; all counts are from the earlier investigation's retained logs or recorded summaries.
- No fix was compiled or proposed as a patch. §5 of the report lists untested candidate directions.
- The report treats #5128 as a suspected match, not a confirmed duplicate, and does not claim runtime behavior on versions other than the tested 3.14.1 bundle.
- The 20/25 fault count is a historical recorded outcome; per-run logs were not retained, and the series is not claimed to be a controlled quark-free baseline.

## Evidence

See [`evidence/provenance.txt`](evidence/provenance.txt) for the source archive SHA-256 values, archive member paths, and exact line ranges. The retained application log shows the `Instance of Frame` receiver; the retained circular-`put` control shows `192` events, `1728` evictions, `640/640/640`, and `probeFault=none`.

## Publication note

Until a public commit exists, `issue-comment.md` refers to `upstream-sc-5128-report.md` and `repro-5128.scd` by relative name. Replace those references with the public blob URLs once the public SHA is known, and bump the relative links in this README if the package is mirrored.
