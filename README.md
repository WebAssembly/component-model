# Component Model design and specification

This repository is where the Component Model is being standardized. For a more
user-focused explanation, take a look at the **[Component Model Documentation]**.

This repository contains:
* high-level [goals], [use cases], [design choices] and [FAQ] docs
* low-level [WIT], [text format], [binary format], [concurrency] and [ABI] docs
* a growing [WAST test suite]

In the future, this repository will additionally contain a [formal spec] and a
reference interpreter.

## Milestones

The Component Model is currently being developed incrementally as part of [WASI]
"Developer Preview" releases. The Component Model features enabled as part of a
WASI Developer Preview release are kept stable by producer and consumer tools so
that they can be used outside the browser in production settings to collect
real-world feedback.

The current WASI Developer Preview releases are:
* 0.2.0: the first release based on the Component Model; includes
         shared-nothing and shared-everything [linking], a variety of high-level
         value types, `resource` types with handles, and [WIT].
* 0.3.0: the first release with native [concurrency] support in the Component
         Model and [WIT]; adds `async` functions, `stream`s and `future`s as
         well as new [ABI] built-in functions (additions are marked by the 🔀
         emoji throughout the repo).

Subsequent WASI Developer Preview releases will include other emoji-[gated
features] such as cooperative threads (🧵).

## Contributing

All Component Model work is done as part of the [W3C WebAssembly Community Group].
To contribute to any of these repositories, see the Community Group's
[Contributing Guidelines].


[Component Model Documentation]: https://component-model.bytecodealliance.org/
[Goals]: design/high-level/Goals.md
[Use Cases]: design/high-level/UseCases.md
[Design Choices]: design/high-level/Choices.md
[FAQ]: design/high-level/FAQ.md
[WIT]: design/mvp/WIT.md
[Text Format]: design/mvp/Explainer.md
[Binary Format]: design/mvp/Binary.md
[Concurrency]: design/mvp/Concurrency.md
[ABI]: design/mvp/CanonicalABI.md
[WAST test suite]: test/
[formal spec]: spec/
[Linking]: design/mvp/Linking.md
[Gated Features]: design/mvp/Explainer.md#gated-features
[W3C WebAssembly Community Group]: https://www.w3.org/community/webassembly/
[Contributing Guidelines]: https://webassembly.org/community/contributing/
[WASI]: https://github.com/WebAssembly/WASI
