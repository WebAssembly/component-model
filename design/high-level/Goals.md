# Component Model High-Level Goals

(For comparison, see WebAssembly's [original High-Level Goals].)

1. Define a portable, load- and run-time-efficient binary format for
   separately-compiled components built from WebAssembly core modules that
   enable portable, cross-language composition.
2. Support the definition of portable, virtualizable, statically-analyzable,
   capability-safe, language-agnostic interfaces, especially those being 
   defined by [WASI].
3. Maintain and enhance WebAssembly's unique value proposition:
   * *Language neutrality*: avoid biasing the component model toward just one
     language or family of languages.
   * *Embeddability*: design components to be embedded in a diverse set of
     host execution environments, including browsers, servers, intermediaries,
     small devices and data-intensive systems.
   * *Optimizability*: maximize the static information available to
     Ahead-of-Time compilers to minimize the cost of instantiation and
     startup.
   * *Formal semantics*: define the component model within the same semantic
     framework as core wasm.
   * *Web platform integration*: ensure components can be natively supported
      in browsers by extending the existing WebAssembly integration points: the
      [JS API], [Web API] and [ESM-integration]. Before native support is
      implemented, ensure components can be polyfilled in browsers via
      Ahead-of-Time compilation to currently-supported browser functionality.
4. Define the component model *incrementally*: starting from a set of
   [initial use cases] and expanding the set of use cases over time,
   prioritized by feedback and experience.

## Non-goals

1. Don't attempt to solve 100% of WebAssembly embedding scenarios.
   * Some scenarios will require features in conflict with the above-mentioned goal.
   * With the layered approach to specification, unsupported embedding
     scenarios can be solved via alternative layered specifications or by
     directly embedding the existing WebAssembly core specification.
2. Don't attempt to solve problems that are better solved by some combination
   of the toolchain, the platform or higher layer specifications, including:
   * package management and version control;
   * deployment and live upgrade / dynamic reconfiguration;
   * persistence and storage; and
   * distributed computing and partial failure.
2. Don't specify a set of "component services".
   * Specifying services that may be implemented by a host and exposed to
     components is the domain of WASI and out of scope of the component model.
   * See also the [WASI FAQ entry](FAQ.md#how-does-wasi-relate-to-the-component-model).


[original High-Level Goals]: https://github.com/WebAssembly/design/blob/main/HighLevelGoals.md
[WASI]: https://github.com/WebAssembly/WASI/blob/main/README.md
[JS API]: https://webassembly.github.io/spec/js-api/index.html
[Web API]: https://webassembly.github.io/spec/web-api/index.html
[ESM-integration]: https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration
[initial use cases]: UseCases.md#Initial-MVP
