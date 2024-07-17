# Component Model design and specification

This repository is where the component model is being standardized. For a more
user-focused explanation, take a look at the **[Component Model Documentation]**.

This repository contains the high-level [goals], [use cases], [design choices]
and [FAQ] of the Component Model as well as more-detailed, low-level explainer
docs describing the [IDL], [text format], [binary format], [concurrency model],
[Canonical ABI] and [Core WebAssembly Build Targets].

In the future, this repository will additionally contain a [formal spec],
reference interpreter and test suite.

## Milestones

The Component Model is currently being incrementally developed and stabilized
as part of [WASI Preview 2]. The subsequent [WASI Preview 3] milestone will be
primarily concerned with the addition of [async support][Concurrency Model].

## Contributing

All Component Model work is done as part of the [W3C WebAssembly Community Group].
To contribute to any of these repositories, see the Community Group's
[Contributing Guidelines].


[Component Model Documentation]: https://component-model.bytecodealliance.org/
[Goals]: design/high-level/Goals.md
[Use Cases]: design/high-level/UseCases.md
[Design Choices]: design/high-level/Choices.md
[FAQ]: design/high-level/FAQ.md
[IDL]: design/mvp/WIT.md
[Text Format]: design/mvp/Explainer.md
[Binary Format]: design/mvp/Binary.md
[Concurrency Model]: design/mvp/Async.md
[Canonical ABI]: design/mvp/CanonicalABI.md
[Core WebAssembly Build Targets]: design/mvp/BuildTargets.md
[formal spec]: spec/
[W3C WebAssembly Community Group]: https://www.w3.org/community/webassembly/
[Contributing Guidelines]: https://webassembly.org/community/contributing/
[WASI Preview 2]: https://github.com/WebAssembly/WASI/tree/main/preview2
[WASI Preview 3]: https://github.com/WebAssembly/WASI/tree/main/preview2#looking-forward-to-preview-3
[Async Support]: https://docs.google.com/presentation/d/1MNVOZ8hdofO3tI0szg_i-Yoy0N2QPU2C--LzVuoGSlE/edit?usp=share_link
