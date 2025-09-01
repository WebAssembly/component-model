# Reference Tests

This directory contains Component Model reference tests, grouped by functionality.

## Running in Wasmtime

A single `.wast` test can be run via:
```
wasmtime wast -W component-model-async=y the-test.wast
```
All the tests can be run from this directory via:
```
find . -name "*.wast" | xargs wasmtime wast -W component-model-async=y
```
