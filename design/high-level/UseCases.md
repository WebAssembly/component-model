# Component Model Use Cases

## Initial (MVP)

This section describes a collection of use cases that characterize active and
developing embeddings of wasm and the limitations of the core wasm
specification that they run into outside of a browser context. The use cases
have a high degree of overlap in their required features and help to define the
scope of an "MVP" (Minimum Viable Product) for the Component Model.

### Hosts embedding components

One way that components are to be used is by being directly instantiated and
executed by a host (an application, system or service embedding a wasm
runtime), using the component model to provide a common format and toolchain so
that each distinct host doesn't have to define its own custom conventions and
sets of tools for solving the same problems.

#### Value propositions to hosts for embedding components

First, it's useful to enumerate some use cases for why the host wants to run
wasm in the first place (instead of using an alternative virtualization or
sandboxing technology):

1. A native language runtime (like node.js or CPython) uses components as a
   portable, sandboxed alternative to the runtime's native plugins, avoiding the
   portability and security problems of native plugins.
2. A serverless platform wishing to move code closer to data or clients uses
   wasm components in place of a fixed scripting language, leveraging wasm's
   strong sandboxing and language neutrality.
3. A serverless platform wishing to spin up fresh execution contexts at high
   volume with low latency uses wasm components due to their low overhead and fast
   instantiation.
4. A system or service adds support for efficient, multi-language "scripting"
   with only a modest amount of engineering effort by embedding an existing
   component runtime, reusing existing WASI standards support where applicable.
5. A large application decouples the updating of modular pieces of the
   application from the updating of the natively-installed base application,
   by distributing and running the modular pieces as wasm components.
6. A monolithic application sandboxes an unsafe library by compiling it into a
   wasm component and then AOT-compiling the wasm component into native code
   linked into the monolithic application (e.g., [RLBox]).
7. A large application practices [Principle of Least Authority] and/or
   [Modular Programming] by decomposing the application into wasm components,
   leveraging the lightweight sandboxing model of wasm to avoid the overhead of
   traditional process-based decomposition.

#### Invoking component exports from the host

Once a host chooses to embed wasm (for one of the preceding reasons), the first
design choice is how host executes the wasm code. The core wasm [start function]
is sometimes used for this purpose, however the lack of parameters or results
miss out on several use cases listed below, which suggest the use of exported
wasm functions with typed signatures instead. However, there are a number of
use cases that go beyond the ability of core wasm:

1. A JS developer `import`s a component (via [ESM-integration]) and calls the
   component's exports as JS functions, passing high-level JS values like strings,
   objects and arrays which are automatically coerced according to the high-level,
   typed interface of the invoked component.
2. A generic wasm runtime CLI allows the user to invoke the exports of a
   component directly from the command-line, automatically parsing argv and env
   vars according to the high-level, typed interface of the invoked component.
3. A generic wasm runtime HTTP server maps HTTP endpoints onto the exports of a
   component, automatically parsing request params, headers and body and
   generating response headers and body according to the high-level, typed
   interface of the invoked component.
4. A host implements a wasm execution platform by invoking wasm component
   exports in response to domain-specific events (e.g., on new request, on new
   chunk of data available for processing, on trigger firing) through a fixed
   interface that is either standardized (e.g., via WASI) or specific to the host.

The first three use cases demonstrate a more general use case of generically
reflecting typed component exports in terms of host-native concepts.

#### Exposing host functionality to components as imports

Once wasm has been invoked by the host, the next design choice is how to expose
the host's native functionality and resources to the wasm code while it executes.
Imports are the natural choice and already used for this purpose, but there are
a number of use cases that go beyond what can be expressed with core wasm
imports:

1. A host defines imports in terms of explicit high-level value types (e.g.,
   numbers, strings, lists, records and variants) that can be automatically
   bound to the calling component's source-language values.
2. A host returns non-value, non-copied resources (like files, storage
   connections and requests/responses) to components via unforgeable handles
   (analogous to Unix file descriptors).
3. A host exposes non-blocking and/or streaming I/O to components through
   language-neutral interfaces that can be bound to different components'
   source languages' concurrency features (such as promises, futures,
   async/await and coroutines).
4. A host passes configuration (e.g., values from config files and secrets) to
   a component through imports of typed high-level values and handles.
5. A component declares that a particular import is "optional", allowing that
   component to execute on hosts with or without the imported functionality.
6. A developer instantiates a component with native host imports in production
   and with mock or emulated imports in local development and testing.

#### Host-determined component lifecycles and associativity

Another design choice when a host embeds wasm is when to create new instances,
when to route events to existing instances, when existing instances are
destroyed, and how, if there are multiple live instances, do they interact with
each other, if at all. Some use cases include:

1. A host creates many ephemeral, concurrent component instances, each of which
   is tied to a particular host-domain-specific entity's lifecycle (e.g. a
   request-response pair, connection, session, job, client or tenant), with a
   component instance being destroyed when the associated entity's
   domain-specified lifecycle completes.
2. A host delivers fine-grained events, for which component instantiation would
   have too much overhead if performed per-event or for which retained mutable
   state is desired, by making multiple export calls on the same component
   instance over time. Export calls can be asynchronous, allowing multiple
   fine-grained events to be processed concurrently. For example, multiple
   packets could be delivered as multiple export calls to the component instance
   for a connection.
3. A host represents associations between longer- and shorter-lived
   host-domain-specific entities (e.g., a "connection's session" or a "session's
   user") by having the shorter-lived component instances (e.g., "connections")
   import the exports of the longer-lived component instances (e.g., "sessions").

### Component composition

The other way components are to be used (other than via direct execution by the
host) is by other components, through component composition.

#### Value propositions to developers for composing components

Enumerating some of the reasons why we might want to compose components in the
first place (instead of simply using the module/package mechanisms built into
the programming language):

1. A component developer reuses code already written in another language
   instead of having to reimplement the functionality from scratch.
2. A component developer writing code in a high-level scripting language (e.g.,
   JS or Python) reuses high-performance code written in a lower-level language
   (e.g., C++ or Rust).
3. A component developer mitigates the impact of supply-chain attacks by
   putting their dependencies into several components and controlling the
   capabilities delegated to each, taking advantage of the strong sandboxing model
   of components.
4. A component runtime implements built-in host functionality as wasm
   components to reduce the [Trusted Computing Base].
5. An application developer applies the Unix philosophy without incurring the
   full cost and OS-dependency of splitting their program into multiple processes
   by instead having each component do one thing well and using the component
   model to compose their program as a hierarchy of components.
6. An application developer composes multiple independently-developed
   components that import and export the same interface (e.g., a HTTP
   request-handling interface) by linking them together, exports-to-imports, being
   able to create recursive, branching DAGs of linked components not otherwise
   expressible with classic Unix-style pipelines.

In all the above use cases, the developer has an additional goal of keeping the
component reuse as a private, fully-encapsulated implementation detail that
their client doesn't need to be aware of (either directly in code, or
indirectly in the developer workflow).

#### Composition primitives

Core wasm already provides the fundamental composition primitives of: imports,
exports and functions, allowing a module to export a function that is imported
by another module. Building from this starting point, there are a number of
use cases that require additional features:

1. Developers importing or exporting functions use high-level value types in
   their function signatures that include strings, lists, records, variants and
   arbitrarily-nested combinations of these. Both developers (the caller and
   callee) get to use the idiomatic values of their respective languages.
   Values are passed by copy so that there is no shared mutation, ownership or
   management of these values before or after the call that either developer
   needs to worry about.
2. Developers importing or exporting functions use opaque typed handles in
   their function signatures to pass resources that cannot or should not be copied
   at the callsite. Both developers (the caller and callee) use their respective
   languages' abstract data type support for interacting with resources. Handles
   can encapsulate `i32` pointers to linear memory allocations that need to be
   safely freed when the last handle goes away.
3. Developers import or export functions with signatures containing
   concurrency-oriented types (e.g., async, future and stream) to address
   concurrency use cases like non-blocking I/O, early return and streaming. Both
   developers (the caller and callee) are able to use their respective languages'
   native concurrency support, if it exists, using the concurrency-oriented types
   to establish a deterministic communication protocol that defines how the
   cross-language composition behaves.
4. A component developer makes a minor [semver] update which changes the
   component's type in a logically backwards-compatible manner (e.g., adding a new
   case to a variant parameter type). The component model ensures that the new
   component stays valid (at link-time and run-time) for use by existing clients
   compiled against the older signature.
5. A component developer uses their language, toolchain and memory
   representation of choice (including, in the future, [GC memory]), with these
   implementation choices fully encapsulated by the component and thus hidden from
   the client. The component developer can switch languages, toolchains or memory
   representations in the future without breaking existing clients.

The above use cases roughly correspond to the use cases of an [RPC] framework,
which have similar goals of crossing language boundaries. The major difference
is the dropping of the distributed computing goals (see [non-goals](Goals.md#non-goals))
and the additional performance goals mentioned [below](#performance).

#### Component dependencies

When a client component imports another component as a dependency, there are a
number of use cases for how the dependency's instance is configured and shared
or not shared with other clients of the same dependency. These use cases
require a greater degree of programmer control than allowed by most languages'
native module systems and most native code linking systems while not requiring
fully dynamic linking (e.g., as provided by the [JS API]).

1. A component developer exposes their component's configuration to clients as
   imports that are supplied when the component is instantiated by the client.
2. A component developer configures a dependency independently of any other
   clients of the same dependency by creating a fresh private instance of the
   dependency and supplying the desired configuration values at instantiation.
3. A component developer imports a dependency as an already-created instance,
   giving the component's clients the responsibility to configure the
   dependency and the freedom to share it with others.
4. A component developer creates a fresh private instance of a dependency to
   isolate the dependency's mutable instance state in order to minimize the
   damage that can be caused in the event of a supply chain attack or
   exploitable bug in the dependency.
5. A component developer imports an already-created instance of a dependency,
   allowing the dependency to use mutable instance state to deduplicate data or
   cache common results, optimizing overall app performance.
6. A component developer imports a WASI interface and does not explicitly pass
   the WASI interface to a privately-created dependency. The developer knows,
   without manually auditing the code of the dependency, that the dependency
   cannot access the WASI interface.
7. A component developer creates a private dependency instance, supplying it a
   virtualized implementation of a WASI interface. The developer knows, without
   manually auditing the code of the dependency, that the dependency exclusively
   uses the virtualized implementation.
8. A component developer creates a fresh private instance of a dependency,
   supplying the component's own functions as imports to the dependency. The
   component does this to parameterize the dependency's behavior with the
   component's own logic or implementation choices (achieving the goals usually
   accomplished using callback registration or [dependency injection]).

### Performance

In pursuit of the above functional use cases, it's important that the component
model not sacrifice the performance properties that motivate the use of wasm in
the first place. Thus, the new features mentioned above should be consistent
with the predictable performance model established by core wasm by supporting
the following use cases:

1. A component runtime implements cross-component calls with efficient, direct
   control flow transfer without thread context switching or synchronization.
2. A component runtime implements component instances without needing to give
   each instance its own event loop, green thread or message queue.
3. A component runtime or optimizing AOT compiler compiles all import and
   export names into indices or more direct forms of reference (up to and
   including direct inlining of cross-component definitions into uses).
4. A component runtime implements value passing between component instances
   without ever creating an intermediate O(n) copy of aggregate data types,
   outside of either component instance's explicitly-allocated linear memory.
5. A component runtime shares the compiled machine code of a component across
   many instances of that component.
6. A component is composed of several core wasm modules that operate on a
   single shared linear memory, some of which contain langauge runtime code
   that is shared by all components produced from the same language toolchain.
   A component runtime shares the compiled machine code of the shared language
   runtime module.
7. A component runtime implements the component model and achieves expected
   performance without using any runtime code generation or Just-in-Time
   compilation.

## Post-MVP

The following are a list of use cases that make sense to support eventually,
but not necessarily in the initial release.

### Runtime dynamic linking

* A component lazily creates an instance of its dependency on the first call
  to its exports.
* A component dynamically instantiates, calls, then destroys its dependency,
  avoiding persistent resource usage by the dependency if the dependency is used
  infrequently and/or preventing the dependency from accumulating state across
  calls which could create supply chain attack risk.
* A component creates a fresh internal instance every time one of its exports
  is called, avoiding any residual state between export calls and aligning with
  the usual assumptions of C programs with a `main()`.

### Parallelism

* A component creates a new (green) thread to execute an export call to a
  dependency, achieving task parallelism while avoiding low-level data races due
  to the absence of shared mutable state between the component and the
  dependency.
* Two component instances connected via stream execute in separate (green)
  threads, achieving pipeline parallelism while preserving determinism due to the
  absence of shared mutable state.

### Copy Minimization

* A component produces or consumes the high-level abstract value types using
  its own arbitrary linear memory representation or procedural interface (like
  iterator or generator) without having to make an intermediate copy in linear
  memory or copy unwanted elements.
* A component is given a "blob" resource representing an immutable array of
  bytes living outside any linear memory that can be semantically copied into
  linear memory in a way that, if supported by the host, can be implemented via
  copy-on-write memory-mapping.
* A component creates a stream directly from a data segment, avoiding the cost
  of first copying the data segment into linear memory and then streaming from
  linear memory.

### Component-level multi-threading

In the absence of these features, a component can assume its exports are
called in a single-threaded manner (just like core wasm). If and when core wasm
gets a primitive [`fork`] instruction, a component may, as a private
implementation detail, have its internal `shared` memory accessed by multiple
component-internal threads. However, these `fork`ed threads would not be able
to call imports, which could break other components' single-threaded assumptions.

* A component explicitly annotates a function export with [`shared`],
  opting in to it being called simultaneously from multiple threads.
* A component explicitly annotates a function import with `shared`, requiring
  the imported function to have been explicitly `shared` and thus callable from
  any `fork`ed thread.



[RLBox]: https://plsyssec.github.io/rlbox_sandboxing_api/sphinx/
[Principle of Least Authority]: https://en.wikipedia.org/wiki/Principle_of_least_privilege
[Modular Programming]: https://en.wikipedia.org/wiki/Modular_programming
[start function]: https://webassembly.github.io/spec/core/intro/overview.html#semantic-phases
[ESM-integration]: https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration
[Trusted Computing Base]: https://en.wikipedia.org/wiki/Trusted_computing_base
[semver]: https://en.wikipedia.org/wiki/Software_versioning
[RPC]: https://en.wikipedia.org/wiki/Remote_procedure_call
[GC memory]: https://github.com/WebAssembly/gc/blob/master/proposals/gc/Overview.md
[JS API]: https://webassembly.github.io/spec/js-api/index.html
[dependency injection]: https://en.wikipedia.org/wiki/Dependency_injection
[`fork`]: https://dl.acm.org/doi/pdf/10.1145/3360559
[`shared`]: https://dl.acm.org/doi/pdf/10.1145/3360559
