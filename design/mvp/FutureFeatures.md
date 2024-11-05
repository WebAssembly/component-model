# Future Features

As with Core WebAssembly 1.0, the Component Model 1.0 aims to be a Minimum
Viable Product (MVP), assuming incremental, backwards-compatible
standardization to continue after the initial "1.0" release. The following is
an incomplete list of specific features intentionally punted from the MVP. See
also the high-level [post-MVP use cases](../high-level/UseCases.md#post-mvp)
and [non-goals](../high-level/Goals.md#non-goals).


## Blast zones

While the Component Model MVP allows strong software isolation of capabilities
(in the form of link-time imports and runtime handles) there is currently no
way for a host component to execute a guest component robustly in the face of
traps or runaway resource memory/CPU usage. A post-MVP "blast zone" feature
would allow a parent component to dynamically instantiate a child component in
a separate "blast zone" such that a trap in the blast zone could be safely and
predictably handled by the parent outside the blast zone. Furthermore, the
parent could use a non-deterministic timeout or resource quota trigger to
preemptively inject a trap into the blast zone.


## Custom ABIs via "adapter functions"

The original Interface Types proposal includes the goal of avoiding a fixed
serialization format, as this often incurs extra copying when the source or
destination language-runtime data structures don't precisely match the fixed
serialization format. A significant amount of work was spent designing a
language of [adapter functions] that provided fairly general programmatic
control over the process of serializing and deserializing high-level values.
(The Interface Types Explainer currently contains a snapshot of this design.)
However, a significant amount of additional design work remained, including
(likely) changing the underlying semantic foundations from lazy evaluation to
algebraic effects.

In pursuit of a timely MVP and as part of the overall [scoping and layering
proposal], the goal of avoiding a fixed serialization format was dropped from
the MVP by instead defining a [Canonical ABI](CanonicalABI.md) in the MVP.
However, the current design anticipates a future extension whereby lifting and
lowering functions can be generated not just from `canon lift` and `canon
lower`, but, alternatively, general-purpose serialization/deserialization code.

In this future state, `canon lift` and `canon lower` could be specified by
simple expansion into the general-purpose code, making these instructions
effectively macros. However, even in this future state, there is still value in
having a fixedly-defined Canonical ABI as it allows more-aggressive
optimization of calls between components (which both use the Canonical ABI) and
between a component and the host (which often must use a fixed ABI for calling
to and from the statically-compiled host implementation language). See
[`list.lift_canon` and `list.lower_canon`] for more details.


## Shared-everything Module Linking in Core WebAssembly

[Originally][Core Module Linking], Module Linking was proposed as an addition
to the Core WebAssembly specification, adding only the new concepts of instance
and module definitions (which, like other kinds of definitions, could be
imported and exported). As part of the overall [scoping and layering proposal],
Module Linking has moved into a layer above WebAssembly and merged with the
Interface Types proposal. However, it may still make sense and be complementary
to the Component Model to add Module Linking to Core WebAssembly in the future
as originally proposed.



[Interface Types Proposal]: https://github.com/WebAssembly/interface-types/blob/main/proposals/interface-types/Explainer.md
[Module Linking Proposal]: https://github.com/WebAssembly/module-linking/blob/main/proposals/module-linking/Explainer.md
[Adapter Functions]: https://github.com/WebAssembly/interface-types/blob/main/proposals/interface-types/Explainer.md#adapter-functions
[Scoping and Layering Proposal]: https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8
[`list.lift_canon` and `list.lower_canon`]: https://github.com/WebAssembly/interface-types/blob/main/proposals/interface-types/Explainer.md#optimization-canonical-representation
[Component Invariants]: Explainer.md#component-invariants
[GC-free Runtime Instantiation]: https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8/edit#slide=id.gd06989d984_1_274
[Core Module Linking]: https://github.com/WebAssembly/module-linking/blob/63cd6c0e3ac5c0cdb798a985790f51ccdd77af00/proposals/module-linking/Explainer.md
