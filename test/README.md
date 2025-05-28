# Reference Tests

This directory contains Component Model reference tests, grouped by functionality.

## Running in Wasmtime

All tests currently run and (except temporarily while spec changes are rolling out)
pass using the [`dev` release of `wasip3-prototyping`](https://github.com/bytecodealliance/wasip3-prototyping/releases/tag/dev).

A single `.wast` test can be run via:
```
wasmtime wast -W component-model-async=y the-test.wast
```
All the tests can be run from this directory via:
```
find . -name "*.wast" | xargs wasmtime-p3 wast -W component-model-async=y
```
