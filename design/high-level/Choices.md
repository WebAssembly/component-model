# Component Model High-Level Design Choices

Based on the [goals](Goals.md) and [use cases](UseCases.md), the component
model makes several high-level design choices that permeate the rest of the
component model.

1. The component model adopts a shared-nothing architecture in which component
   instances fully encapsulate their linear memories, tables, globals and, in
   the future, GC memory. Component interfaces contain only immutable copied
   values, opaque typed handles and immutable uninstantiated modules/components.
   While handles and imports can be used as an indirect form of sharing, the
   [dependency use cases](UseCases.md#component-dependencies) enable this degree
   of sharing to be finely controlled.

2. The component model introduces no global singletons, namespaces, registries,
   locator services or frameworks through which components are configured or
   linked. Instead, all related use cases are addressed through explicit
   parametrization of components via imports (of data, functions, and types)
   with every client of a component having the option to independently
   instantiate the component with its own chosen import values.

3. The component model assumes no global inter-component garbage or cycle
   collector that is able to trace through cross-component cycles. Instead
   resources have lifetimes and require explicit acyclic ownership through
   handles. The explicit lifetimes allow resources to have destructors that are
   called deterministically and can be used to release linear memory
   allocations in non-garbage-collected languages.

4. The component model assumes that Just-In-Time compilation is not available
   at runtime and thus only provides declarative linking features that admit
   Ahead-of-Time compilation, optimization and analysis. While component instances
   can be created at runtime, the components being instantiated as well as their
   dependencies and clients are known before execution begins.
   (See also [this slide](https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8/edit#slide=id.gceaf867ebf_0_10).)
