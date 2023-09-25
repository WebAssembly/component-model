# Component Model design and specification

This repository is where the component model is being standardized. For a more user-focussed explanation, take a look at the **[Component Model Documentation]**.

This repository describes the high-level [goals], [use cases], [design choices]
and [FAQ] of the component model as well as a more-detailed [assembly-level explainer], [IDL],
[binary format] and [ABI] covering the initial Minimum Viable Product (MVP)
release.

In the future, this repository will additionally contain a [formal spec],
reference interpreter and test suite.

## Milestones

The Component Model is currently being incrementally developed and stabilized
as part of [WASI Preview 2]. The subsequent "Preview 3" milestone will be
primarily concerned with the addition of [async support].

## Contributing

All Component Model work is done as part of the [W3C WebAssembly Community Group].
To contribute to any of these repositories, see the Community Group's
[Contributing Guidelines].

[Component Model Documentation]: https://component-model.bytecodealliance.org/
[goals]: design/high-level/Goals.md
[use cases]: design/high-level/UseCases.md
[design choices]: design/high-level/Choices.md
[FAQ]: design/high-level/FAQ.md
[assembly-level explainer]: design/mvp/Explainer.md
[IDL]: design/mvp/WIT.md
[binary format]: design/mvp/Binary.md
[ABI]: design/mvp/CanonicalABI.md
[formal spec]: spec/
[W3C WebAssembly Community Group]: https://www.w3.org/community/webassembly/
[Contributing Guidelines]: https://webassembly.org/community/contributing/
[WASI Preview 2]: https://github.com/WebAssembly/WASI/tree/main/preview2
[Async Support]: https://docs.google.com/presentation/d/1MNVOZ8hdofO3tI0szg_i-Yoy0N2QPU2C--LzVuoGSlE/edit?usp=share_link
