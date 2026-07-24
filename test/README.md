# Reference Tests

This directory contains Component Model reference tests, grouped by functionality.

## Running in Wasmtime

A single `.wast` test can be run with full backtrace on trap via:
```
WASMTIME_BACKTRACE_DETAILS=1 WAST_STRICT_COMPONENT_INDICES=1 wasmtime wast -W component-model-more-async-builtins -W component-model-threading -W component-model-async-stackful -W component-model-implements the-test.wast
```

Sometimes test land ahead of the implementation and fail for a while. These
tests are listed in 'nyi.txt' so that they can be filtered out. Thus, a simple
way to run all the reference tests is:
```
find . -name "*.wast" | grep -vxFf nyi.txt | WAST_STRICT_COMPONENT_INDICES=1 xargs wasmtime wast -W component-model-more-async-builtins -W component-model-threading -W component-model-async-stackful -W component-model-implements
```
