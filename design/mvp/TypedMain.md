# Typed Main

Previous WASI Command APIs were not able to strongly type the resource and data inputs to commands and instead relied on functions for reading command line arguments and environment variables.

Typed Main enables components to define value imports for their arguments (including file resources) and environment variables allowing the host to parse and validate them for the component.

This proposal defines a way to infer the command line arguments names, ordering, etc. from the component type (represented here in [WIT](https://github.com/WebAssembly/component-model/blob/main/design/mvp/WIT.md)) and optionally augmenting this with annotated info (represented here as [Structured Annotations](https://github.com/WebAssembly/component-model/issues/58)). The anotation information will be encoded in a custom section in a not-yet-specified way.

## Arguments
* Value imports are can be supplied as positional arguments in the order they are defined
* Value imports can be supplied as long-form named arguments with their defined name
* The ordering of named arguments with respect to each other and positional arguments is not constrained
* If a named argument is present, parsing of positional argument skips over it to the next position

```rust
input: string
pattern: string
replace: string
```

### Usage
```
$ replace "some-thing" "-" "_"
$ replace --input "some-thing" --pattern "-" --replace "_"
$ replace --pattern "-" --replace "_" "some-thing"
```

## File Preopen Arguments
* If the type of a value import is a WASI file, the host reads the corresponding argument as a path and preopens it.
* The preopen must occur even for file paths which do not exist (as long as their parent does), so that output file paths can be supported.

```rust
import { file } from ...

input: file
output: file
```

### Usage
```bash
$ copy ./input.txt --output ./output.txt
```

## Optional Arguments
* Value imports with type `option<T>` are optional arguments
* If an optional argument is not provided, the value import takes value `none`
* All arguments defined after an optional argument must be optional

```rust
import { file } from ...

input: file
output: option<file>
```

### Usage
```bash
$ foo ./input.txt ./output.txt
$ foo ./input.txt
```

## Flags
* Value imports with type `bool` inferred to be flags.
* Flags have value `true` if present and `false` if absent.
* By default, flags are "long"
    * Equivalent to annotation `@flag(long)`
    * Specified in long form with no associated value e.g. `--foobar`
    * Name is inferred to be the value import name
    * Name can be explicitly set `@flag(long = "foobar")`
    * Does not support grouping
* Flags can annotated as "short"
    * Using annotation `@flag(short)`
    * Specified in short form with no associated value e.g.`-f`
    * Name is inferred to be first character of value import name
    * Name can be explicitly set `@flag(short = "f")`
    * Supports grouping `-a -b -c` = `-abc`
* Flag can be short and long `@flag(short, long)`, value `true` if either are present

```rust
@flag(short)
help: bool

verbose: bool

@flag(short = "x", long)
execute: bool
```

### Usage
```bash
$ foo -h
$ foo --verbose
$ foo -x
$ foo --execute -x --verbose
```

## Short Named Arguments
* By default named arguments are "long" (inferred as `@arg(pos, named, long)`).
* By annotating them with with the `short` parameter, they can be used in short form e.g. `-i`
* Name inference and manual assignment works the same as flags

```rust
import { file } from ...

input: file

@arg(named, short, long)
output: option<file>
```

### Usage
```bash
$ foo ./input.txt --output ./output.txt
$ foo ./input.txt -o ./output.txt
```
