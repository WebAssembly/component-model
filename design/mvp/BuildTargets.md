# Build Targets Explainer

For any given WIT [`world`], the Component Model specification defines multiple
**build targets** that all logically represent the same world. The different
build targets provide producer toolchains different low-level implementation
and optimization choices that don't change the high-level runtime semantics
of the `world`.

Currently, this document defines *two* build targets:
* A `component` build target that contains 0..N core modules using the
  new component [binary format]. Components are able to use any [`canonopt`]
  and take advantage of the full expressivity of [linking].
* A `wasm32-module` build target that uses the [Core WebAssembly binary format]
  with a fixed ABI that uses one linear memory with `i32` pointers.

Other build targets can be added as needed. In particular, the following
additional build targets are anticipated:
* A `wasm64-module` build target that instead uses `i64` pointers based on
  [memory64].
* A `gc-module` build target that instead uses managed memory based on [gc].
* A `{wasm32,wasm64,gc}-shared-module` build target that instead places the
  `shared` attribute on all relevant types based on the developing
  [shared-everything-threads] proposal.

Importantly, any module targeting one of the above build targets can be
trivially wrapped to become a semantically-equivalent component. Thus, these
modules can be considered "simple components", which is why these build targets
are defined in the Component Model spec even though they use Core WebAssembly's
binary format. The reverse cannot be said, however: there are many cases where
components cannot be trivially unwrapped to produce modules compatible with one
of the above build targets. Thus, only the `component` build target captures
the full expressivity of the Component Model.

There are three main reasons for defining multiple build targets for the
Component Model:
* It allows existing *Core WebAssembly producer toolchains* to more-easily
  incrementally target the Component Model. Once a producer toolchain can emit
  simple components, the toolchain can more-easily understand and motivate the
  work required to take advantage of the full Component Model.
* It allows existing *Core WebAssembly runtimes* to partially support the
  Component Model and WIT-defined interfaces (like [WASI]) by natively
  implementing one or more of the module build targets. While this restricts
  the set of content that the runtime can execute, runtimes with limited
  resources may not be able to support multi-module or multi-component
  [linking] in the first place. Also, implementing a module build target can
  also be a good first incremental step toward implementing the rest of the
  Component Model.
* It allows *WIT interface authors* (e.g., in [WASI]) to implicitly support all
  build targets while specifying the semantics of their interface only once and
  without having to understand all the low-level ABI details.

The **component** build target is defined in this repo by the [AST explainer]
and [binary format], which is defined in terms of the AST.

The following sections define the **module** build targets which mostly work
the same way, changing only the parameters fed to the [Canonical ABI].

## Module Build Targets

The specification of the module build targets below assumes a single, fixed WIT
[`world`]. This fixed world implies a fixed list of import and export names,
each with associated component-level types. For example, if a runtime supports
"all of WASI 0.2", the fixed `world` would be:
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

Every module build target defines the following two (possibly-empty) sets of
imports (defined by the sections below):
 1. [WIT-derived imports](#wit-derived-imports)
 2. [Resource imports](#resource-imports)

and the following four (possibly-empty) sets of exports (also defined below):
 1. [WIT-derived exports](#wit-derived-exports)
 2. [Memory exports](#memory-exports)
 3. [Initialization exports](#initialization-exports)
 4. [Post-return exports](#post-return-exports)

With components, only WIT-derived imports and exports appear in the component's
signature; the rest are implementation details that don't share a namespace
with the WIT-derived names. With module build targets, however, all these
imports and exports go into a shared namespace and so, to avoid name clashes,
all non-WIT-derived import and export names are given a `_` prefix (below),
since WIT names cannot (and will not in the future) start with `_`.

The runtime behavior of the WIT-derived imports and exports is defined by the
associated [Canonical ABI] definitions, as described below.

The only additional runtime behavioral rule that does not strictly follow from
the Canonical ABI is:
 * Modules *MUST NOT* call any imports during the Core WebAssembly [`start`] 
   function that access memory (as defined by [`needs_memory`], given the
   import type). Hosts *MUST* trap eagerly in this case.

This rule allows modules to be run in a wide variety of core runtimes
(including browsers) which do not expose memory until after the `start`
function returns. This matches the general Core WebAssembly toolchain
convention that `start` functions should only be used for module-internal
initialization. General-purpose initialization code that may call imports
must instead call the [`_initialize` function](#initialization-exports).

One other runtime detail that is implied by the Component Model rules for
exports, but is worth stating explicitly is:
 * Any WIT-derived export *MAY* be called repeatedly and in any order by the
   host. Producer toolchains *MUST* handle this case without trapping or
   triggering Undefined Behavior.

It is allowed, however, for calls to immediately return an error, matching the
general WASI convention that traps should only be possible due to a low-level
compiler bug or unsafe code. Specifically, in the case of [`wasi:cli/run`],
this means that a producer toolchain must anticipate repeated calls to `run`.
For code that assumes a run-once `main()` function or top-level script, this
suggests that the producer toolchain tracks in a global whether `run` was
already called and, if so, either:
* (easy) immediately returns a failure `result`; or
* (ideally) resets memory and table state so that, from the callee code's point
  of view, it's running for the first time, and from the calling code's point
  of view, it just worked.

The following subsections specify the sets of imports and exports enumerated
above.

### Memory exports

* Must export `_memory` if `needs_memory(world)`
* Must export `_realloc` if `needs_realloc(world)`

### Version Canonicalization

* Define `canonicalize(in)` as ...
  * Rules
  * Examples
  * Rationale

### ABI Options

* For `wasm32-module`, it's ...

### Implicit Component Instance

* One per module, with the initial state as defined by CABI ...

### WIT-derived imports

TODO:

* For each import of an `interface` with an [`interfacename`] `in`:
  * For each function named `fn` with type `ft` in the imported `interface`,
    there is a Core WebAssembly `func` [`import`] where:
    * the first [`name`] string is [`canonicalize`]`(in)`;
    * the second [`name`] string is `fn`;
    * the core function type is [`flatten_functype`]`(ft, 'lower')`; and
    * the runtime behavior is defined by [`canon_lower`] with the [ABI options](#abi-options)
      and [implicit component instance](#implicit-component-instance) as defined above.

For example ...

### WIT-derived exports

TODO:

* For each export of an `interface` with an [`interfacename`] `in`:
  * For each function named `fn` with type `ft` in the exported `interface`,
    there is a Core WebAssembly `func` [`export`] where:
    * the [`name`] string is the concatentation of [`canonicalize`]`(in)` + "`.`" + `fn`;
    * the core function type is [`flatten_functype`]`(ft, 'lift')`;
    * the runtime behavior is defined by [`canon_lift`] with the [ABI options](#abi-options)
      and [implicit component instance](#implicit-component-instance) as defined above.

For example ...

### Resource imports

* May import ... `resource.drop $rt` for any `$rt` imported by the world. (No worlds export resource types yet, but when they do ... `resource.new/rep $rt`.)

### Initialization exports

* May export `_initialize`, if present, called before first export

### Post-return exports

* Optional, called if present, signature if present must be ...


## Relation to compiler flags

TODO: prose-ify

* Proposal for `wasi-sdk`/`wasi-sdk`
  * Target triple + flags that map to `component` vs. `wasm32-module`
  * Why we need "`wasip2`" and future plans
* (is Rust the same?)
* Go: GOOS + -buildtarget


[`world`]: WIT.md#wit-worlds
[Binary Format]: Binary.md
[Linking]: Linking.md
[AST Explaiern]: Explainer.md
[`canonopt`]: Explainer.md#canonical-abi
[Lifting and Lowering Definitions]: Explainer.md#canonical-abi
[`interfacename`]: Explainer.md#import-and-export-definitions
[Canonical ABI]: CanonoicalABI.md
[`needs_memory`]: CanonicalABI.md#TODO
[`flatten_functype`]: CanonicalABI.md#flattening
[`canon_lower`]: CanonicalABI.md#canon-lower
[`canonicalize`]: #version-canonicalization

[Core WebAssembly Binary Format]: https://webassembly.github.io/spec/core/binary/index.html
[`import`]: https://webassembly.github.io/spec/core/syntax/modules.html#imports
[`export`]: https://webassembly.github.io/spec/core/syntax/modules.html#exports
[`name`]: https://webassembly.github.io/spec/core/syntax/values.html#syntax-name

[Memory64]: https://github.com/webAssembly/memory64
[GC]: https://github.com/WebAssembly/gc
[shared-everything-threads]: https://github.com/webAssembly/shared-everything-threads
[WASI]: https://github.com/webAssembly/wasi
[`wasi:cli/run`]: https://github.com/WebAssembly/wasi-cli/blob/main/wit/run.wit

[`wasm-tools`]: https://github.com/bytecodealliance/wasm-tools
