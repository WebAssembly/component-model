# Reference Tests

This directory contains Component Model reference tests, grouped by functionality.

## Running in Wasmtime

(Until the `component-model-async` and `component-model-async-builtins` features
are enabled by default, they must be explicitly enabled as shown below.)

A single `.wast` test can be run with full backtrace on trap via:
```
WASMTIME_BACKTRACE_DETAILS=1 wasmtime wast -W component-model-async=y -W component-model-async-builtins=y -W component-model-threading=y -W component-model-async-stackful=y -W exceptions=y the-test.wast
```
All the tests can be run from this directory via:
```
find . -name "*.wast" | xargs wasmtime wast -W component-model-async=y -W component-model-async-builtins=y -W component-model-threading=y -W component-model-async-stackful=y -W exceptions=y
```
