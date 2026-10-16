# Fuzzing

The fuzz target feeds arbitrary bytes to `readInfo`, `decodeComponents` and
`decodePixels`. Every input must end in a result or a `JP2KError`; a crash, an
out-of-memory or a timeout is a bug.

## Run

libFuzzer needs Linux. With Docker:

```sh
docker run --rm -v "$PWD":/w -w /w swift:6.4-noble bash -c \
  'bash Fuzz/build.sh && bash Fuzz/run.sh 1800'
```

`run.sh <seconds>` seeds `Fuzz/corpus` from the fixtures (plus the
conformance inputs when `JP2K_CONFORMANCE_DIR` points at an openjpeg-data
checkout, e.g. `-v "$PWD/.reference/openjpeg-data":/cdata -e JP2K_CONFORMANCE_DIR=/cdata`)
and runs one fuzzing job per CPU. Findings are written to `Fuzz/artifacts/`.

The fork-mode parent reports a small leak inside libFuzzer's own driver when it
exits, so `run.sh` judges a run by libFuzzer's completion line and by the
absence of crash, out-of-memory and timeout artifacts, not by the exit status.

## Turning a finding into a regression test

1. Reproduce and shrink it:
   `Fuzz/.build/jp2k-fuzz -minimize_crash=1 -runs=100000 Fuzz/artifacts/crash-…`
2. Copy the minimised file to `Tests/JP2KTests/Fixtures/corrupt/` with a
   descriptive name and regenerate `MANIFEST.sha256` (see `Scripts/make-fixtures.sh`).
3. Add a test that decodes it and expects the specific `JP2KError`.
4. Fix the decoder until the test passes.
