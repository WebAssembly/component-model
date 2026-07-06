# Reference Tests

This directory contains Component Model reference tests, grouped by functionality.

## Running in Wasmtime

A single `.wast` test can be run with full backtrace on trap via:
```
WASMTIME_BACKTRACE_DETAILS=1 wasmtime wast -W component-model-more-async-builtins=y -W component-model-threading=y -W component-model-async-stackful=y -W component-model-implements=y the-test.wast
```

All the tests can be run from this directory via:
```
find . -name "*.wast" | xargs wasmtime wast -W component-model-more-async-builtins=y -W component-model-threading=y -W component-model-async-stackful=y -W component-model-implements=y
```

Sometimes tests are landed ahead of the implementation and fail for a while.
These tests are listed in 'nyi.txt' and can be filtered out via:
```
find . -name "*.wast" | grep -vxFf nyi.txt | xargs wasmtime wast -W component-model-more-async-builtins=y -W component-model-threading=y -W component-model-async-stackful=y -W component-model-implements=y
```
