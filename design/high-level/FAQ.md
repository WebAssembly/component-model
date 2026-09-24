# FAQ

### How do WebAssembly Components relate to Web Components

[Web Components](https://developer.mozilla.org/en-US/docs/Web/API/Web_components) are a collection of technologies for creating reusable DOM custom elements. WebAssembly Components are a technology for creating reusable software interfaces (not tied to a single language or UI framework). See these [slides](https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8/edit?slide=id.gced688a2b6_0_9#slide=id.gced688a2b6_0_9) for a rationale for this naming.

Whenever there is a chance of ambiguity, the full WebAssembly (or Wasm) Component name should be used.

### How does WASI relate to the Component Model?

[WASI] is layered on top of the Component Model, with the Component Model
providing the foundational building blocks used to define WASI's interfaces,
including:
* the grammar of types that can be used in WASI interfaces;
* the linking functionality that WASI can assume is used to compose separate
  modules of code, isolate their capabilities and virtualize WASI interfaces;
* the core wasm ABI that core wasm toolchains can compile against when targeting WASI.

By way of comparison to traditional Operating Systems, the Component Model
fills the role of an OS's process model (defining how processes start up and
communicate with each other) while WASI fills the role of an OS's many I/O
interfaces.

Use of WASI does not force the client to target the Component Model, however.
Any core wasm producer can simply target the core wasm ABI defined by the
Component Model for a given WASI interface's signature. This approach reopens
many questions that are answered by the Component Model, particularly when more
than one wasm module is involved, but for single-module scenarios or highly
custom scenarios, this might be appropriate.

### Does the Component Model force every (module | package | library) to have a separate memory?

No, as described in [Linking.md](../mvp/Linking.md), the Component Model supports a
combination of "shared-everything" and "shared-nothing" linking, allowing
developers and producer toolchains to choose the appropriate kind of linking
to use in a particular situation.


[WASI]: https://github.com/WebAssembly/WASI/blob/main/README.md
