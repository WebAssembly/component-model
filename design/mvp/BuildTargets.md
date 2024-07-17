# Core WebAssembly Build Targets Explainer

For any given WIT [`world`], the Component Model defines multiple **Core
WebAssembly build targets** that all logically represent the same world but
provide Core WebAssembly producer toolchains different low-level representation
choices.

* [Motivation](#motivation)
* [Build Targets](#build-targets)
* [Target World](#target-world)
* [Imports and Exports](#imports-and-exports)
  * [WIT-derived Function Imports](#wit-derived-function-imports)
  * [WIT-derived Function Exports](#wit-derived-function-exports)
  * [Memory Exports](#memory-exports)
  * [Initialization Export](#initialization-export)
* [Support Definitions](#supporting-definitions)
  * [Interface Name Canonicalization](#interface-name-canonicalization)
  * [ABI Options](#abi-options)
  * [Current Component Instance and Task](#current-component-instance-and-task)
* [Example](#example)
* [Relation to Compiler Flags](#relation-to-compiler-flags)


## Motivation

While the Component Model's [binary format] provides more [linking]
functionality and optimization choices than the Core WebAssembly build targets
listed below, there are several reasons for having the Component Model
additionally define build targets that use the existing standard [Core
WebAssembly Binary Format]:
* It allows *interface authors* (e.g., in [WASI]) to write their interface
  just once (in WIT) to target both core and component runtimes.
* It allows existing *Core WebAssembly producer toolchains* to more easily
  and incrementally target the Component Model.
* It allows existing *Core WebAssembly runtimes* to implement WIT-defined
  interfaces without having to implement the full Component Model, providing an
  incremental implementation step towards the full Component Model.

Furthermore, any module matching a Core WebAssembly build target can be
trivially wrapped (e.g., by [`wasm-tools component new`]) to become a
semantically-equivalent component and thus these modules can be considered
**simple components**.


## Build Targets

Currently, there is only one build target defined:
* `wasm32`: uses one 32-bit linear memory

Other build targets can be added as needed in the future. In particular, the
following additional build targets are anticipated:
* `wasm64`: uses one 64-bit linear memory (based on [memory64]).
* `wasmgc`: uses managed memory (based on [wasm-gc]).

When the [async] and [shared-everything-threads] proposals stabilize, they
could either be added backwards-compatibly to existing build targets or added
as separate build targets.


## Target World

The rest of this document assumes a single, fixed "target world". This target
world determines a fixed list of import and export names, each with associated
component-level types. For example, if a runtime wants to support "all of WASI
Preview 2", the target world (currently) would be:
```wit
world all-of-WASI {
  include wasi:http/proxy@0.2.0;
  include wasi:cli/command@0.2.0;
}
```
However, a runtime can also choose to support just `wasi:http/proxy` or
`wasi:cli/command` or a subset of one of these worlds: this is a choice every
producer and consumer gets to make independently. WASI and the Component Model
only establish a fixed set of names that *MAY* appear in imports and exports
and, when present, what the agreed-upon semantics *MUST* be.

Additionally, we assume that the target world has been fully resolved into a
pure [`componenttype`] in the same way as when creating a [WIT package] which
means that `include`s have been inlined and `use`d types have been replaced by
direct aliases to the resolved type.


## Imports and Exports

Every build target defines the following set of imports:
 1. [WIT-derived function imports](#wit-derived-imports)

and the union of the following sets of exports:
 1. [WIT-derived function exports](#wit-derived-exports)
 2. [Memory exports](#memory-exports)
 3. [Initialization export](#initialization-export)

Every Core WebAssembly import and export name defined by the build target
starts with a `prefix` string that incorporates the build target:
* For `wasm32` this `prefix` string is `cm32p2`.

The leading `cm` of the `prefix` indicates that this import or export is using
the Component Model's Canonical ABI. The trailing `p2` of the `prefix`
indicates the version of the Canonical ABI assumed by the compiled module,
allowing the Canonical ABI to change as part of future Component Model Preview
or RC releases without ambiguity. Thus, `p2` is distinct from the version of
any particular WASI or other WIT interface and is instead more analogous to the
`version` field of the Component Model [binary format].

A Core WebAssembly module *MAY* include imports and exports other than those
defined by the build target for the target world. However, if an import or
export starts with the `prefix`, it *MUST* be included in the [target world]'s
set of imports and exports defined by the build target and rejected by the
runtime otherwise.

The runtime behavior of the WIT-derived imports and exports is entirely defined
by the [Canonical ABI], as explained in detail below. The only additional
global runtime behavioral rule that does not strictly follow from the Canonical
ABI is:
 * Modules *MUST NOT* call any imports during the Core WebAssembly [`start`]
   function that needs memory (as defined by whether [`flatten_functype`]
   sets `needs.memory`). Hosts *MUST* trap eagerly (at the start of the import
   call) in this case.

This rule allows modules to be run in a wide variety of runtimes (such as
browsers) which do not expose memory until after the `start` function returns.
This matches the general Core WebAssembly toolchain convention that `start`
functions should only be used for module-internal initialization.
General-purpose initialization code that may call imports should instead run
during [initialization](#initialization-export).

Other runtime behaviors that are implied by the Canonical ABI but are worth
stating explicitly here are:
 * The host may not reenter guest wasm code on the same callstack (i.e., once
   a wasm module calls a host import, the host may not recursively call back
   into the calling wasm module instance).
 * Once a module instance traps, the host *MUST NOT* execute any code with
   that module instance in the future.
 * Any WIT-derived export *MAY* be called repeatedly and in any
   order by the host. Producer toolchains *MUST* handle this case without
   trapping or triggering Undefined Behavior (but *MAY* eagerly return an error
   value according to the declared return type).

The following subsections specify the sets of imports and exports enumerated
above:

### WIT-derived Function Imports

The Core WebAssembly function *imports* derived from the [target world] are
defined as follows (with [`prefix`](#imports-and-exports) as defined above and
the [ABI Options] and [current component instance and task] as defined below):

* For each import of a WIT interface `i` with [canonicalized interface name] `cin`:
  * For each function in `i` with name `fn` and type `ft`, the build target includes:
    * `(import "<prefix>|<cin>" "<fn>" <flat-type>)`, where:
      * `flat-type` is [`flatten_functype`]`(ft, 'lower')`,
      * the runtime behavior is defined by [`canon_lower`].
  * For each *original* resource type in `i` with name `rn`, the build target includes:
    * `(import "<prefix>|<cin>" "<rn>_drop" (func (param i32)))`, where:
      * the runtime behavior is defined by [`canon_resource_drop`].
* For each import of a function with name `fn` and type `ft`, the build target includes:
  * `(import "<prefix>" "<fn>" <flat-type>)`, where:
    * `flat-type` and the runtime behavior are defined the same as in the
      interface case above.
* For each export of a WIT interface `i` with [canonicalized interface name] `cin`:
  * For each *original* resource type in `i` with name `rn`, the build target includes:
    * `(import "<prefix>|_ex_<cin>" "<rn>_drop" (func (param i32)))`,
    * `(import "<prefix>|_ex_<cin>" "<rn>_new" (func (param i32) (result i32)))`, and
    * `(import "<prefix>|_ex_<cin>" "<rn>_rep" (func (param i32) (result i32)))`, where:
      * the runtime behavior is defined by [`canon_resource_drop`],
        [`canon_resource_new`] and [`canon_resource_rep`], resp.

Above, the word "original" in "*original* resource type" means a resource type
that isn't defined to be equal to another resource type (using `type foo = bar`
in WIT).

### WIT-derived Function Exports

The Core WebAssembly function *exports* derived from the [target world] are
defined as follows (with [`prefix`](#imports-and-exports) as defined above and
the [ABI Options] and [current component instance and task] as defined below):

* For each export of a WIT interface `i` with [canonicalized interface name] `cin`:
  * For each function in `i` with name `fn` and type `ft`, the build target includes:
    * `(export "<prefix>|<cin>|<fn>" <flat-type>)` and
    * `(export "<prefix>|<cin>|<fn>_post" (func (params <flat-params>)))`, where:
      * `flat-type` is [`flatten_functype`]`(ft, 'lift')`,
      * `flat-params` is `flat-type.results`, and
      * the runtime behavior is defined by [`canon_lift`] with `None` as the
        `caller`, a no-op `on_block` callback, an `on_start` callback that
        provides the host's arguments to the callee and an `on_return` callback
        that returns the callee's results back to the host.
  * For each *original* resource type in `i` with name `rn`, the build target includes:
    * `(export "<prefix>|<cin>|<rn>_dtor" (func (param i32)))`, which is:
      * called by the host when an owned handle returned by a previous export
        call is dropped by the host,
      * passed the same `i32` value that was passed by the guest to `<rn>_new`
        for the resource that is now being destroyed.
* For each export of a function with name `fn` and type `ft`, the build target includes:
  * `(export "<prefix>||<fn>" <flat-type>)` and
  * `(export "<prefix>||<fn>_post" (func (params <flat-params>)))`, where:
    * `flat-type`, `flat-params` and the runtime behavior are defined the same
      as in the interface case above.

These exports are not *required* to exist in a module (if they aren't present,
they just won't be called), but if an export *is* present with the given name,
it *MUST* have the given type. If there is a `<fn>_post` function export,
though, there *MUST* also be a corresponding exported `<fn>`. This `<fn>_post`
function *MUST* only be called by the host immediately following a call to
`<fn>` as defined by `canon_lift`.

### Memory Exports

If [`flatten_functype`] sets `needs.memory` for any WIT-derived function import
or export *used by the module*, the following export *MUST* be present:

* `(export "<prefix>_memory" (memory 0))`

This exported linear memory is used as the `memory` field of [`canonopt`] in
the Canonical ABI.

If [`flatten_functype`] sets `needs.realloc` for any WIT-derived function
import or export *used by the module*, the following export *MUST* be present:

* `(export "<prefix>_realloc" (func (param i32 i32 i32 i32) (result i32)))`

This exported allocation function is used as the `realloc` field of
[`canonopt`] in the Canonical ABI.

### Initialization Export

*Every* build target includes the following optional Core WebAssembly function
export:

* `(export "<prefix>_initialize" (func))`

A producer toolchain can rely on this initialization function being called some
time before any other export call.

## Supporting Definitions

The following supporting definitions are referenced above as part of defining
the WIT-derived imports and exports:

### Interface Name Canonicalization

Given an [`interfacename`] `in`, the **canonicalization** of `in` is given by:
* If `in` has no trailing `@<version>`, the canonicalization is just `in`.
* Otherwise, the canonicalization is `<base>@<canonicalized-version>` where:
  * `in` is split into `<base>@<version>`,
  * `version` is split into `<major>.<minor>.<patch>` followed by the optional
    `-<prerelease>` and `+<build>` fields, as defined by [SemVer 2.0], and
  * `canonicalized-version` is:
    * if the optional `prerelease` field is present:
      * `<major>.<minor>.<patch>-<prerelease>`
    * otherwise, if `major` and `minor` are `0`:
      * `0.0.<patch>`
    * otherwise, if `major` is `0`:
      * `0.<minor>`
    * otherwise:
      * `<major>`.

For example:

| Interface name              | Canonicalized interface name |
| --------------------------- | ---------------------------- |
| `a:b/c`                     | `a:b/c`                      |
| `a:b/c@1.2.3+alpha`         | `a:b/c@1`                    |
| `a:b/c@0.1.2+alpha`         | `a:b/c@0.1`                  |
| `a:b/c@0.0.1+alpha`         | `a:b/c@0.0.1`                |
| `a:b/c@1.2.3-nightly+alpha` | `a:b/c@1.2.3-nightly`        |

The reason for this canonicalization is to avoid requiring every runtime to
implement semver-aware matching wherein all imports of names in the left column
match if they are the same in the right column. Instead, producer toolchains
perform canonicalization at build time so that Core WebAssembly runtimes can
continue to use a simple table of imports matched by string equality.

### ABI Options

The Canonical ABI is parameterized by a small set of ABI options
([`canonopt`]) which are set as follows:

The `memory` and `realloc` options are set by the Memory Exports defined
[above](#memory-exports).

The `post-return` option for a WIT function named `fn` is set to be the
exported `<fn>_post` function defined [above](#wit-derived-function-exports)
if present (otherwise `None`).

Additionally:
* The `string-encoding` is fixed to `utf8`.
* The (unstable Preview 3) `async` field is unset.

When `gc` and `memory64` fields are added to `canonopt`, they would be
mentioned here and configured by the build target.

### Current Component Instance and Task

The Canonical ABI maintains per-component-instance spec-level state that
affects the lifting and lowering of parameters and results in imports and
exports. As described above, Core WebAssembly build targets treat each Core
WebAssembly module as a simple component, and thus there is always a **current
component instance** created for each Core WebAssembly module instance that is
passed as an argument to each Canonical ABI import.

Canonical ABI imports also take a **current task** which contains per-call
spec-level state used to dynamically enforce the rules for reentrance,
`borrow`, and, in a Preview 3 timeframe, async calls). Until Preview 3 async is
enabled for a build target, there is only ever *at most one* task per instance
(corresponding to an active synchronous host-to-wasm call, noting that |host →
wasm → host → wasm| reentrance is disallowed) and thus the current component
instance mentioned above also implies the current task.


## Example

Given the following world:
```wit
package ns:pkg@0.2.1;

interface i {
  resource r {
    constructor(s: string);
    m: func() -> string;
  }
  frob: func(in: r) -> r;
}

world w {
  import f: func() -> string;
  import i;
  import j: interface {
    resource r {
      constructor(s: string);
      m: func() -> string;
    }
    frob: func(in: r) -> r;
  }
  export g: func() -> string;
  export i;
  export j: interface {
    resource r {
      constructor(s: string);
      m: func() -> string;
    }
    frob: func(in: r) -> r;
  }
}
```
the `wasm32` build target includes the following imports and exports (noting
that any particular module can import and export a subset of these, subject to
the requirements mentioned above):
```wat
(module
  (import "cm32p2" "f" (func (param i32)))
  (import "cm32p2|ns:pkg/i@0.2" "[constructor]r" (func (param i32 i32) (result i32)))
  (import "cm32p2|ns:pkg/i@0.2" "[method]r.m" (func (param i32 i32)))
  (import "cm32p2|ns:pkg/i@0.2" "frob" (func (result i32) (result i32)))
  (import "cm32p2|ns:pkg/i@0.2" "r_drop" (func (param i32)))
  (import "cm32p2|j" "[constructor]r" (func (param i32 i32) (result i32)))
  (import "cm32p2|j" "[method]r.m" (func (param i32 i32)))
  (import "cm32p2|j" "frob" (func (result i32) (result i32)))
  (import "cm32p2|j" "r_drop" (func (param i32)))
  (import "cm32p2|_ex_ns:pkg/i@0.2" "r_drop" (func (param i32)))
  (import "cm32p2|_ex_ns:pkg/i@0.2" "r_new" (func (param i32) (result i32)))
  (import "cm32p2|_ex_ns:pkg/i@0.2" "r_rep" (func (param i32) (result i32)))
  (import "cm32p2|_ex_j" "r_drop" (func (param i32)))
  (import "cm32p2|_ex_j" "r_new" (func (param i32) (result i32)))
  (import "cm32p2|_ex_j" "r_rep" (func (param i32) (result i32)))
  (export "cm32p2||g" (func (result i32)))
  (export "cm32p2||g_post" (func (param i32)))
  (export "cm32p2|ns:pkg/i@0.2|[constructor]r" (func (param i32 i32) (result i32)))
  (export "cm32p2|ns:pkg/i@0.2|[method]r.m" (func (param i32) (result i32)))
  (export "cm32p2|ns:pkg/i@0.2|frob" (func (result i32) (result i32)))
  (export "cm32p2|ns:pkg/i@0.2|r_dtor" (func (param i32)))
  (export "cm32p2|j|[constructor]r" (func (param i32 i32) (result i32)))
  (export "cm32p2|j|[method]r.m" (func (param i32) (result i32)))
  (export "cm32p2|j|frob" (func (param i32) (result i32)))
  (export "cm32p2|j|r_dtor" (func (param i32) (result i32)))
  (export "cm32p2_memory" (memory 0))
  (export "cm32p2_realloc" (func (param i32 i32 i32 i32) (result i32)))
  (export "cm32p2_initialize" (func))
)
```
As defined by the Component Model, but worth calling out explicitly: this world
contains 4 distinct resource types with 4 distinct resource tables that have
overlapping index spaces, even though all 4 resources are syntactically named
`r` in the WIT:
1. The `r` in the imported `ns:pkg/i` interface, used by the imported
   `ns:pkg/i@0.2` functions.
2. The `r` in the imported anonymous `j` interface, used by the imported `j`
   functions.
3. The `r` in the exported `ns:pkg/i` interface, used by the exported
   `ns:pkg/i@0.2` functions *and* the imported `_ex_ns:pkg/i@0.2` functions.
4. The `r` in the exported anonymous `j` interface, used by the exported `j`
   functions *and* the imported `_ex_j` functions.

Each resource type has a unique `*_drop` function import, so the number of
`*_drop` functions is the number of resource tables.


## Relation to Compiler Flags

One option for producer toolchains is to always emit a Core WebAssembly build
target and then optionally wrap the result into a component binary as a final
build step (which aligns well with the overall [linking] toolchain pipeline).
In this case, the toolchain unconditionally takes the Core WebAssembly build
target as an argument and then takes an independent flag specifying whether to
emit a Core WebAssembly module or a component.

For example:
* For `wasi-libc`-based toolchains like `wasi-sdk` or `rustc`:
  * The `--target` is `wasm32-wasip2`, combining the `wasm32` build target
    defined in this document with the additional information that the language
    runtime can import [WASI Preview 2]-defined interfaces.
  * The default output is a component, but `-Wl,--emit-module` can be passed to
    instruct the linker to only emit a module.
* For Go:
  * The `GOARCH` is `wasm32` and the `GOOS` is `wasip2`
  * The `-buildmode` would select whether to emit a module or component


[Target World]: #target-world
[Canonicalized Interface Name]: #interface-name-canonicalization
[ABI Options]: #abi-options
[Current Component Instance and Task]: #current-component-instance-and-task

[Async]: Async.md
[Binary Format]: Binary.md
[Canonical ABI]: CanonicalABI.md
[`flatten_functype`]: CanonicalABI.md#flattening
[`canon_lift`]: CanonicalABI.md#canon-lift
[`canon_lower`]: CanonicalABI.md#canon-lower
[`canon_resource_drop`]: CanonicalABI.md#canon-resourcedrop
[`canon_resource_new`]: CanonicalABI.md#canon-resourcenew
[`canon_resource_rep`]: CanonicalABI.md#canon-resourcerep
[`componenttype`]: Explainer.md#type-definitions
[`canonopt`]: Explainer.md#canonical-abi
[`interfacename`]: Explainer.md#import-and-export-definitions
[Linking]: Linking.md
[`world`]: WIT.md#wit-worlds
[WIT Package]: WIT.md#package-format

[Core WebAssembly Binary Format]: https://webassembly.github.io/spec/core/binary/index.html
[`start`]: https://webassembly.github.io/spec/core/syntax/modules.html#start-function

[memory64]: https://github.com/webAssembly/memory64
[wasm-gc]: https://github.com/WebAssembly/gc
[shared-everything-threads]: https://github.com/webAssembly/shared-everything-threads
[WASI]: https://github.com/webAssembly/wasi
[WASI Preview 2]: https://github.com/WebAssembly/WASI/blob/main/preview2/README.md

[`wasm-tools component new`]: https://github.com/bytecodealliance/wasm-tools#tools-included

[SemVer 2.0]: https://semver.org/spec/v2.0.0.html
