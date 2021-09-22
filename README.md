# Component Model design and specification

This repository contains documents describing the high-level [goals],
[use cases], [design choices] and [FAQ] of the component model.

In the future, as proposals get merged, the repository will additionally
contain the spec, a reference interpreter, a test suite, and directories for
each proposal with the proposal's explainer and specific design documents.

## Design Process & Contributing

At this early stage, this repository only contains high-level design documents
and discussions about the Component Model in general. Detailed explainers,
specifications and discussions are broken into the following two repositories
which, together, will form the "MVP" of the Component Model:

* The [module-linking] proposal will initialize the Component Model
  specification, adding the ability for WebAssembly to import, nest,
  instantiate and link multiple Core WebAssembly modules without host-specific
  support.

* The [interface-types] proposal will extend the Component Model specification
  with a new set of high-level types for defining shared-nothing,
  language-neutral "components".

All Component Model work is done as part of the [W3C WebAssembly Community Group].
To contribute to any of these repositories, see the Community Group's
[Contributing Guidelines].


[goals]: design/high-level/Goals.md
[use cases]: design/high-level/UseCases.md
[design choices]: design/high-level/Choices.md
[FAQ]: design/high-level/FAQ.md
[module-linking]: https://github.com/webassembly/module-linking/
[interface-types]: https://github.com/webassembly/interface-types/
[W3C WebAssembly Community Group]: https://www.w3.org/community/webassembly/
[Contributing Guidelines]: https://webassembly.org/community/contributing/
