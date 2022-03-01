# Component Model Explainer

This explainer walks through the assembly-level definition of a
[component](../high-level) and the proposed embedding of components into a
native JavaScript runtime.

* [Grammar](#grammar)
  * [Component definitions](#component-definitions)
  * [Instance definitions](#instance-definitions)
  * [Alias definitions](#alias-definitions)
  * [Type definitions](#type-definitions)
  * [Function definitions](#function-definitions)
  * [Start definitions](#start-definitions)
  * [Import and export definitions](#import-and-export-definitions)
* [Component invariants](#component-invariants)
* [JavaScript embedding](#JavaScript-embedding)
  * [JS API](#JS-API)
  * [ESM-integration](#ESM-integration)
* [Examples](#examples)
* [TODO](#TODO)

(Based on the previous [scoping and layering] proposal to the WebAssembly CG,
this repo merges and supersedes the [Module Linking] and [Interface Types]
proposals, pushing some of their original features into the post-MVP [future
feature](FutureFeatures.md) backlog.)


## Grammar

This section defines components using an EBNF grammar that parses something in
between a pure Abstract Syntax Tree (like the Core WebAssembly spec's
[Structure Section]) and a complete text format (like the Core WebAssembly
spec's [Text Format Section]). The goal is to balance completeness with
succinctness, with just enough detail to write examples and define a [binary
format](Binary.md) in the style of the [Binary Format Section], deferring full
precision to the [formal specification](../../spec/).

The main way the grammar hand-waves is regarding definition uses, where indices
referring to `X` definitions (written `<Xidx>`) should, in the real text
format, explicitly allow identifiers (`<id>`), checking at parse time that the
identifier resolves to an `X` definition and then embedding the resolved index
into the AST.

Additionally, standard [abbreviations] defined by the Core WebAssembly text
format (e.g., inline export definitions) are assumed but not explicitly defined
below.


### Component Definitions

At the top-level, a `component` is a sequence of definitions of various kinds:
```
component  ::= (component <id>? <definition>*)
definition ::= <core:module>
             | <component>
             | <instance>
             | <alias>
             | <type>
             | <func>
             | <start>
             | <import>
             | <export>
```
Core WebAssembly modules (henceforth just "modules") are also sequences of
(different kinds of) definitions. However, unlike modules, components allow
arbitrarily interleaving the different kinds of definitions. As we'll see
below, this arbitrary interleaving reflects the need for different kinds of
definitions to be able to refer back to each other. Importantly, though,
component definitions are acyclic: definitions can only refer back to preceding
definitions (in the AST, text format or binary format).

The first kind of component definition is a module, as defined by the existing
Core WebAssembly specification's [`core:module`] top-level production. Thus,
components physically embed one or more modules and can be thought of as a
kind of container format for modules.

The second kind of definition is, recursively, a component itself. Thus,
components form trees with modules (and all other kinds of definitions) only
appearing at the leaves.

With what's defined so far, we can define the following component:
```wasm
(component
  (component
    (module (func (export "one") (result i32) (i32.const 1)))
    (module (func (export "two") (result f32) (f32.const 2)))
  )
  (module (func (export "three") (result i64) (i64.const 3)))
  (component
    (component
      (module (func (export "four") (result f64) (f64.const 4)))
    )
  )
  (component)
)
```
This top-level component roots a tree with 4 modules and 1 component as
leaves. However, in the absence of any `instance` definitions (introduced
next), nothing will be instantiated or executed at runtime: everything here is
dead code.


### Instance Definitions

Whereas modules and components represent immutable *code*, instances associate
code with potentially-mutable *state* (e.g., linear memory) and thus are
necessary to create before being able to *run* the code. Instance definitions
create module or component instances by selecting a module/component and
supplying a set of named *arguments* which satisfy all the named *imports* of
the selected module/component:
```
instance     ::= (instance <id>? <instanceexpr>)
instanceexpr ::= (instantiate (module <moduleidx>) (import <name> <modulearg>)*)
               | (instantiate (component <componentidx>) (import <name> <componentarg>)*)
               | <export>*
               | core <core:export>*
modulearg    ::= (instance <instanceidx>)
               | (instance <core:export>*)
componentarg ::= (module <moduleidx>)
               | (component <componentidx>)
               | (instance <instanceidx>)
               | (func <funcidx>)
               | (value <valueidx>)
               | (type <typeidx>)
               | (instance <export>*)
export       ::= (export <name> <componentarg>)
```
When instantiating a module via `(instantiate (module $M) <modulearg>*)`, the
two-level imports of the module `$M` are resolved as follows:
1. The first `name` of an import is looked up in the named list of `modulearg`
   to select a module instance.
2. The second `name` of an import is looked up in the named list of exports of
   the module instance found by the first step to select the imported
   core definition (a `func`, `memory`, `table`, `global`, etc).

Based on this, we can link two modules `$A` and `$B` together with the
following component:
```wasm
(component
  (module $A
    (func (export "one") (result i32) (i32.const 1))
  )
  (module $B
    (func (import "a" "one") (result i32))
  )
  (instance $a (instantiate (module $A)))
  (instance $b (instantiate (module $B) (import "a" (instance $a))))
)
```
Components, as we'll see below, have single-level imports, i.e., each import
has only a single `name`, and thus every different kind of definition can be
passed as a `componentarg` when instantiating a component, not just instances.
Component instantiation will be revisited below after introducing the
prerequisite type and import definitions.

Lastly, the `(instance <export>*)` and `(instance <core:export>*)`
expressions allow component and module instances to be created by directly
tupling together preceding definitions, without the need to `instantiate`
anything. The "inline" forms of these expressions in `modulearg`
and `componentarg` are text format sugar for the "out of line" form in
`instanceexpr`. To show an example of how these instance-creation forms are
useful, we'll first need to introduce the `alias` definitions in the next
section.


### Alias Definitions

Alias definitions project definitions out of other components' index spaces
into the current component's index spaces. As represented in the AST below,
there are two kinds of "targets" for an alias: the `export` of a component
instance, or a local definition of an `outer` component that contains the
current component:
```
alias       ::= (alias <aliastarget> <aliaskind>)
aliastarget ::= export <instanceidx> <name>
              | outer <outeridx> <idx>
aliaskind   ::= (module <id>?)
              | (component <id>?)
              | (instance <id>?)
              | (func <id>?)
              | (value <id>?)
              | (type <id>?)
              | (table <id>?)
              | (memory <id>?)
              | (global <id>?)
              | ... other Post-MVP Core definition kinds
```
Aliases add a new element to the index space indicated by `aliaskind`.
(Validation ensures that the `aliastarget` does indeed refer to a matching
definition kind.) The `id` in `aliaskind` is bound to this new index and
thus can be used anywhere a normal `id` can be used.

In the case of `export` aliases, validation requires that `instanceidx` refers
to an instance which exports `name`.

In the case of `outer` aliases, the (`outeridx`, `idx`) pair serves as a
[de Bruijn index], with `outeridx` being the number of enclosing components to
skip and `idx` being an index into the target component's `aliaskind` index
space. In particular, `outeridx` can be `0`, in which case the outer alias
refers to the current component. To maintain the acyclicity of module
instantiation, outer aliases are only allowed to refer to *preceding* outer
definitions.

Components containing outer aliases effectively produce a [closure] at
instantiation time, including a copy of the outer-aliased definitions. Because
of the prevalent assumption that components are (stateless) *values*, outer
aliases are restricted to only refer to stateless definitions: components,
modules and types. (In the future, outer aliases to all kinds of definitions
could be allowed by recording the statefulness of the resulting component in
its type via some kind of "`stateful`" type attribute.)

Both kinds of aliases come with syntactic sugar for implicitly declaring them
inline:

For `export` aliases, the inline sugar has the form `(kind <instanceidx> <name>+)`
and can be used anywhere a `kind` index appears in the AST. For example, the
following snippet uses an inline function alias:
```wasm
(instance $j (instantiate (component $J) (import "f" (func $i "f"))))
(export "x" (func $j "g" "h"))
```
which is desugared into:
```wasm
(alias export $i "f" (func $f_alias))
(instance $j (instantiate (component $J) (import "f" (func $f_alias))))
(alias export $j "g" (instance $g_alias))
(alias export $g_alias "h" (func $h_alias))
(export "x" (func $h_alias))
```

For `outer` aliases, the inline sugar is simply the identifier of the outer
definition, resolved using normal lexical scoping rules. For example, the
following component:
```wasm
(component
  (module $M ...)
  (component
    (instance (instantiate (module $M)))
  )
)
```
is desugared into:
```wasm
(component $C
  (module $M ...)
  (component
    (alias outer $C $M (module $C_M))
    (instance (instantiate (module $C_M)))
  )
)
```

With what's defined so far, we're able to link modules with arbitrary renamings:
```wasm
(component
  (module $A
    (func (export "one") (result i32) (i32.const 1))
    (func (export "two") (result i32) (i32.const 2))
    (func (export "three") (result i32) (i32.const 3))
  )
  (module $B
    (func (import "a" "one") (result i32))
  )
  (instance $a (instantiate (module $A)))
  (instance $b1 (instantiate (module $B)
    (import "a" (instance $a))          ;; no renaming
  ))
  (alias export $a "two" (func $a_two))
  (instance $b2 (instantiate (module $B)
    (import "a" (instance
      (export "one" (func $a_two))      ;; renaming, using explicit alias
    ))
  ))
  (instance $b3 (instantiate (module $B)
    (import "a" (instance
      (export "one" (func $a "three"))  ;; renaming, using inline alias sugar
    ))
  ))
)
```
To show analogous examples of linking components, we'll first need to define
a new set of types and functions for components to use.


### Type Definitions

The type grammar below defines two levels of types, with the second level
building on the first:
1. `intertype` (also referred to as "interface types" below): the set of
    types of first-class, high-level values communicated across shared-nothing
    component interface boundaries
2. `deftype`: the set of types of second-class component definitions which are
   imported/exported at instantiation-time.

The top-level `type` definition is used to define types out-of-line so that
they can be reused via `typeidx` by future definitions.
```
type              ::= (type <id>? <typeexpr>)
typeexpr          ::= <deftype>
                    | <intertype>
deftype           ::= <moduletype>
                    | <componenttype>
                    | <instancetype>
                    | <functype>
                    | <valuetype>
moduletype        ::= (module <id>? <moduletype-def>*)
moduletype-def    ::= <core:deftype>
                    | <core:import>
                    | (export <name> <core:importdesc>)
core:deftype      ::= <core:functype>
                    | ... Post-MVP additions
componenttype     ::= (component <id>? <componenttype-def>*)
componenttype-def ::= <import>
                    | <instancetype-def>
import            ::= (import <name> <deftype>)
instancetype      ::= (instance <id>? <instancetype-def>*)
instancetype-def  ::= <type>
                    | <alias>
                    | (export <name> <deftype>)
functype          ::= (func <id>? (param <name>? <intertype>)* (result <intertype>))
valuetype         ::= (value <id>? <intertype>)
intertype         ::= unit | bool
                    | s8 | u8 | s16 | u16 | s32 | u32 | s64 | u64
                    | float32 | float64
                    | char | string
                    | (record (field <name> <intertype>)*)
                    | (variant (case <name> <intertype> (defaults-to <name>)?)*)
                    | (list <intertype>)
                    | (tuple <intertype>*)
                    | (flags <name>*)
                    | (enum <name>*)
                    | (union <intertype>*)
                    | (option <intertype>)
                    | (expected <intertype> <intertype>)
```
On a technical note: this type grammar uses `<intertype>` and `<deftype>`
recursively to allow it to more-precisely indicate the kinds of types allowed.
The formal spec AST would instead use a `<typeidx>` with validation rules to
restrict the target type while the formal text format would use something like
[`core:typeuse`], allowing any of: (1) a `typeidx`, (2) an identifier `$T`
resolving to a type definition (using `(type $T)` in cases where there is a
grammatical ambiguity), or (3) an inline type definition that is desugared into
a deduplicated out-of-line type definition.

On another technical note: the optional `id` in all the `deftype` type
constructors (e.g., `(module <id>? ...)`) is only allowed to be present in the
context of `import` since this is the only context in which binding an
identifier makes sense.

Starting with interface types, the set of values allowed for the *fundamental*
interface types is given by the following table:
| Type                      | Values |
| ------------------------- | ------ |
| `unit`                    | just one [uninteresting value] |
| `bool`                    | `true` and `false` |
| `s8`, `s16`, `s32`, `s64` | integers in the range [-2<sup>N-1</sup>, 2<sup>N-1</sup>-1] |
| `u8`, `u16`, `u32`, `u64` | integers in the range [0, 2<sup>N</sup>-1] |
| `float32`, `float64`      | [IEEE754] floating-pointer numbers with a single, canonical "Not a Number" ([NaN]) value |
| `char`                    | [Unicode Scalar Values] |
| `record`                  | heterogeneous [tuples] of named `intertype` values |
| `variant`                 | heterogeneous [tagged unions] of named `intertype` values |
| `list`                    | homogeneous, variable-length [sequences] of `intertype` values |

The sets of values allowed for the remaining *specialized* interface types are
defined by the following mapping:
```
                            string ↦ (list char)
              (tuple <intertype>*) ↦ (record (field "𝒊" <intertype>)*) for 𝒊=0,1,...
                   (flags <name>*) ↦ (record (field <name> bool)*)
                    (enum <name>*) ↦ (variant (case <name> unit)*)
              (option <intertype>) ↦ (variant (case "none") (case "some" <intertype>))
              (union <intertype>*) ↦ (variant (case "𝒊" <intertype>)*) for 𝒊=0,1,...
(expected <intertype> <intertype>) ↦ (variant (case "ok" <intertype>) (case "error" <intertype>))
```
Building on these interface types, there are four kinds of types describing the
four kinds of importable/exportable component definitions. (In the future, a
fifth type will be added for [resource types][Resource and Handle Types].)

A `functype` describes a component function whose parameters and results are
`intertype` values. Thus `functype` is completely disjoint from
[`core:functype`] in the WebAssembly Core spec, whose parameters and results
are [`core:valtype`] values. Morever, since `core:functype` can only appear
syntactically within the `(module ...)` S-expression of a `moduletype`, there
is never a need to syntactically distinguish `functype` from `core:functype`
in the text format: the context dictates which one a `(func ...)` S-expression
parses into.

A `valuetype` describes a single `intertype` value this is to be consumed
exactly once during component instantiation. How this happens is described
below along with [`start` definitions](#start-definitions).

As described above, components and modules are immutable values representing
code that cannot be run until instantiated via `instance` definition. Thus,
`moduletype` and `componenttype` describe *uninstantiated code*. `moduletype`
and `componenttype` contain not just import and export definitions, but also
type and alias definitions, allowing them to capture type sharing relationships
between imports and exports. This type sharing becomes necessary (not just a
size optimization) with the upcoming addition of [type imports and exports] to
Core WebAssembly and, symmetrically, [resource and handle types] to the
Component Model.

The `instancetype` type constructor describes component instances, which are
named tuples of other definitions. Although `instance` definitions can produce
both module *and* component instances, only *component* instances can be
imported or exported (due to the overall [shared-nothing design](../high-level/Choices.md)
of the Component Model) and thus only *component* instances need explicit type
definitions. Consequently, the text format of `instancetype` does not include
a syntax for defining *module* instance types. As with `componenttype` and
`moduletype`, `instancetype` allows nested type and alias definitions to allow
type sharing.

Lastly, to ensure cross-language interoperability, `moduletype`,
`componenttype` and `instancetype` all require import and export names to be
unique (within a particular module, component, instance or type thereof). In
the case of `moduletype` and two-level imports, this translates to requiring
that import name *pairs* must be *pair*-wise unique. Since the current Core
WebAssembly validation rules allow duplicate imports, this means that some
valid modules will not be typeable and will fail validation if used with the
Component Model.

The subtyping between all these types is described in a separate
[subtyping explainer](Subtyping.md).

With what's defined so far, we can define component types using a mix of inline
and out-of-line type definitions:
```wasm
(component $C
  (type $T (list (tuple string bool)))
  (type $U (option $T))
  (type $G (func (param (list $T)) (result $U)))
  (type $D (component
    (alias outer $C $T (type $C_T))
    (type $L (list $C_T))
    (import "f" (func (param $L) (result (list u8))))
    (import "g" $G)
    (export "g" $G)
    (export "h" (func (result $U)))
  ))
)
```
Note that the inline use of `$G` and `$U` are inline `outer` aliases.


### Function Definitions

To implement or call functions of type [`functype`](#type-definitions), we need
to be able to call across a shared-nothing boundary. Traditionally, this
problem is solved by defining a serialization format for copying data across
the boundary. The Component Model MVP takes roughly this same approach,
defining a linear-memory-based [ABI] called the *Canonical ABI* which
specifies, for any imported or exported `functype`, a corresponding
`core:functype` and rules for copying values into or out of linear memory. The
Component Model differs from traditional approaches, though, in that the ABI is
configurable, allowing different memory representations for the same abstract
value. In the MVP, this configurability is limited to the small set of
`canonopt` shown below. However, Post-MVP, [adapter functions] could be added
to allow far more programmatic control.

The Canonical ABI, which is described in a separate [explainer](CanonicalABI.md),
is explicitly applied to "wrap" existing functions in one of two directions:
* `canon.lift` wraps a Core WebAssembly function (of type `core:functype`)
  inside the current component to produce a Component Model function (of type
  `functype`) that can be exported to other components.
* `canon.lower` wraps a Component Model function (of type `functype`) that can
  have been imported from another component to produce a Core WebAssembly
  function (of type `core:functype`) that can be imported and called from Core
  WebAssembly code within the current component.

Based on this, MVP function definitions simply specify one of these two
wrapping directions along with a set of Canonical ABI configurations.
```
func     ::= (func <id>? <funcbody>)
funcbody ::= (canon.lift <functype> <canonopt>* <funcidx>)
           | (canon.lower <canonopt>* <funcidx>)
canonopt ::= string=utf8
           | string=utf16
           | string=latin1+utf16
           | (into <instanceidx>)
```
Validation fails if multiple conflicting options, such as two `string`
encodings, are given. The `latin1+utf16` encoding is [defined](CanonicalABI.md#latin1-utf16)
in the Canonical ABI explainer. If no string-encoding option is specified, the
default is `string=utf8`.

The `into` option specifies a target instance which supplies the memory that
the canonical ABI should operate on as well as functions that the canonical ABI
can call to allocate, reallocate and free linear memory. Validation requires that
the given `instanceidx` is a module instance exporting the following fields:
```
(export "memory" (memory 1))
(export "realloc" (func (param i32 i32 i32 i32) (result i32)))
(export "free" (func (param i32 i32 i32)))
```
The 4 parameters of `realloc` are: original allocation (or `0` for none), original
size (or `0` if none), alignment and new desired size. The 3 parameters of `free`
are the pointer, size and alignment.

With this, we can finally write a non-trivial component that takes a string,
does some logging, then returns a string.
```wasm
(component
  (import "wasi:logging" (instance $logging
    (export "log" (func (param string)))
  ))
  (import "libc" (module $Libc
    (export "memory" (memory 1))
    (export "realloc" (func (param i32 i32) (result i32)))
    (export "free" (func (param i32)))
  ))
  (instance $libc (instantiate (module $Libc)))
  (func $log
    (canon.lower (into $libc) (func $logging "log"))
  )
  (module $Main
    (import "libc" "memory" (memory 1))
    (import "libc" "realloc" (func (param i32 i32) (result i32)))
    (import "libc" "free" (func (param i32)))
    (import "wasi:logging" "log" (func $log (param i32 i32)))
    (func (export "run") (param i32 i32) (result i32 i32)
      ... (call $log) ...
    )
  )
  (instance $main (instantiate (module $Main)
    (import "libc" (instance $libc))
    (import "wasi:logging" (instance (export "log" (func $log))))
  ))
  (func (export "run")
    (canon.lift (func (param string) (result string)) (into $libc) (func $main "run"))
  )
)
```
This example shows the pattern of splitting out a reusable language runtime
module (`$Libc`) from a component-specific, non-reusable module (`$Main`). In
addition to reducing code size and increasing code-sharing in multi-component
scenarios, this separation allows `$libc` to be created first, so that its
exports are available for reference by `canon.lower`. Without this separation
(if `$Main` contained the `memory` and allocation functions), there would be a
cyclic dependency between `canon.lower` and `$Main` that would have to be
broken by the toolchain emitting an auxiliary module that broke the cycle using
a shared `funcref` table and `call_indirect`.

Component Model functions are different from Core WebAssembly functions in that
all control flow transfer is explicitly reflected in their type (`functype`).
For example, with Core WebAssembly [exception handling] and [stack switching],
a `(func (result i32))` can return an `i32`, throw, suspend or trap. In
contrast, a Component Model `(func (result string))` may only return a `string`
or trap. To express failure, Component Model functions should return an
[`expected`](#type-definitions) type and languages with exception handling will
bind exceptions to the `error` case. Similarly, the future addition of
[future and stream types] would explicitly declare patterns of stack-switching
in Component Model function signatures.


### Start Definitions

Like modules, components can have start functions that are called during
instantiation. Unlike modules, components can call start functions at multiple
points during instantiation with each such call having interface-typed
parameters and results. Thus, `start` definitions in components look like
function calls:
```
start ::= (start <funcidx> (value <valueidx>)* (result (value <id>))?)
```
The `(value <valueidx>)*` list specifies the arguments passed to `funcidx` by
indexing into the *value index space*. Value definitions (in the value index
space) are like immutable `global` definitions in Core WebAssembly except they
must be consumed exactly once at instantiation-time.

As with any other definition kind, value definitions may be supplied to
components through `import` definitions. Using the grammar of `import` already
defined [above](#type-definitions), an example *value import* can be written:
```
(import "env" (value $env (record (field "locale" (option string)))))
```
As this example suggests, value imports can serve as generalized [environment
variables], allowing not just `string`, but the full range of interface types
to describe the imported configuration schema.

With this, we can define a component that imports a string and computes a new
exported string, all at instantiation time:
```wasm
(component
  (import "name" (value $name string))
  (import "libc" (module $Libc
    (export "memory" (memory 1))
    (export "realloc" (func (param i32 i32 i32 i32) (result i32)))
    (export "free" (func (param i32 i32 i32)))
  ))
  (instance $libc (instantiate (module $Libc)))
  (module $Main
    (import "libc" ...)
    (func (export "start") (param i32 i32) (result i32 i32)
      ... general-purpose compute
    )
  )
  (instance $main (instantiate (module $Main) (import "libc" (instance $libc))))
  (func $start
    (canon.lift (func (param string) (result string)) (into $libc) (func $main "start"))
  )
  (start $start (value $name) (result (value $greeting)))
  (export "greeting" (value $greeting))
)
```
As this example shows, start functions reuse the same Canonical ABI machinery
as normal imports and exports for getting interface typed values into and out
of linear memory.


### Import and Export Definitions

The rules for [`import`](#type-definitions) and [`export`](#instance-definitions)
definitions have actually already been defined above (with the caveat that the
real text format for `import` definitions would additionally allow binding an
identifier (e.g., adding the `$foo` in `(import "foo" (func $foo))`):
```
import ::= already defined above as part of <type>
export ::= already defined above as part of <instance>
```

With what's defined so far, we can define a component that imports, links and
exports other components:
```wasm
(component
  (import "c" (instance $c
    (export "f" (func (result string)))
  ))
  (import "d" (component $D
    (import "c" (instance $c
      (export "f" (func (result string)))
    ))
    (export "g" (func (result string)))
  ))
  (instance $d1 (instantiate (component $D)
    (import "c" (instance $c))
  ))
  (instance $d2 (instantiate (component $D)
    (import "c" (instance
      (export "f" (func $d1 "g"))
    ))
  ))
  (export "d2" (instance $d2))
)
```
Here, the imported component `d` is instantiated *twice*: first, with its
import satisfied by the imported instance `c`, and second, with its import
satisfied with the first instance of `d`. While this seems a little circular,
note that all definitions are acyclic as is the resulting instance graph.


## Component Invariants

As a consequence of the shared-nothing design described above, all calls into
or out of a component instance necessarily transit through a component function
definition. Thus, component functions form a "membrane" around the collection
of module instances contained by a component instance, allowing the Component
Model to establish invariants that increase optimizability and composability in
ways not otherwise possible in the shared-everything setting of Core
WebAssembly. The Component Model proposes establishing the following three
runtime invariants:
1. Components define a "lockdown" state that prevents continued execution
   after a trap. This both prevents continued execution with corrupt state and
   also allows more-aggressive compiler optimizations (e.g., store reordering).
   This was considered early in Core WebAssembly standardization but rejected
   due to the lack of clear trapping boundary. With components, each component
   instance is given a mutable "lockdown" state that is set upon trap and
   implicitly checked at every execution step by component functions. Thus,
   after a trap, it's no longer possible to observe the internal state of a
   component instance.
2. Components prevent unexpected reentrance by setting the "lockdown" state
   (in the previous bullet) whenever calling out through an import, clearing
   the lockdown state on return, thereby preventing reentrant export calls in
   the interim. This establishes a clear contract between separate components
   that both prevents obscure composition-time bugs and also enables
   more-efficient non-reentrant runtime glue code (particularly in the middle
   of the [Canonical ABI](CanonicalABI.md)). This implies that components by
   default don't allow concurrency and multi-threaded access will trap.
3. Components enforce the current informal rule that `start` functions are
   only for "internal" initialization by trapping if a component attempts to
   call a component import during instantiation. In Core WebAssembly, this
   invariant is not viable since cross-module calls are often necessary when
   initializing shared linear memory (e.g., calling `libc`'s `malloc`).
   However, at the granularity of components, this invariant appears viable and
   would allow runtimes and toolchains considerable optimization flexibility
   based on the resulting purity of instantiation. As one example, tools like
   [`wizer`] could be used to *transparently* snapshot the post-instantiation
   state of a component to reuse in future instantiations. As another example,
   a component runtime could optimize the instantiation of a component DAG by
   transparently instantiating non-root components lazily and/or in parallel.


## JavaScript Embedding

### JS API

The [JS API] currently provides `WebAssembly.compile(Streaming)` which take
raw bytes from an `ArrayBuffer` or `Response` object and produces
`WebAssembly.Module` objects that represent decoded and validated modules. To
natively support the Component Model, the JS API would be extended to allow
these same JS API functions to accept component binaries and produce new
`WebAssembly.Component` objects that represent decoded and validated
components. The [binary format of components](Binary.md) is designed to allow
modules and components to be distinguished by the first 8 bytes of the binary
(splitting the 32-bit [`version`] field into a 16-bit `version` field and a
16-bit `kind` field with `0` for modules and `1` for components).

Once compiled, a `WebAssemby.Component` could be instantiated using the
existing JS API `WebAssembly.instantiate(Streaming)`. Since components have the
same basic import/export structure as modules, this mostly just means extending
the [*read the imports*] logic to support single-level imports as well as
imports of modules, components and instances. Since the results of
instantiating a component is a record of JavaScript values, just like an
instantiated module, `WebAssembly.instantiate` would always produce a
`WebAssembly.Instance` object for both module and component arguments.

Lastly, when given a component binary, the compile-then-instantiate overloads
of `WebAssembly.instantiate(Streaming)` would inherit the compound behavior of
the abovementioned functions (again, using the `version` field to eagerly
distinguish between modules and components).

For example, the following component:
```wasm
;; a.wasm
(component
  (import "one" (func))
  (import "two" (value string))
  (import "three" (instance
    (export "four" (instance
      (export "five" (module
        (import "six" "a" (func))
        (import "six" "b" (func))
      ))
    ))
  ))
  ...
)
```
and module:
```wasm
;; b.wasm
(module
  (import "six" "a" (func))
  (import "six" "b" (func))
  ...
)
```
could be successfully instantiated via:
```js
WebAssembly.instantiateStreaming(fetch('./a.wasm'), {
  one: () => (),
  two: "hi",
  three: {
    four: {
      five: await WebAssembly.compileStreaming(fetch('./b.wasm'))
    }
  }
});
```

The other significant addition to the JS API would be the expansion of the set
of WebAssembly types coerced to and from JavaScript values (by [`ToJSValue`]
and [`ToWebAssemblyValue`]) to include all of [`intertype`](#type-definitions).
At a high level, the additional coercions would be:

| Interface Type | `ToJSValue` | `ToWebAssemblyValue` |
| -------------- | ----------- | -------------------- |
| `unit` | `null` | accept everything |
| `bool` | `true` or `false` | `ToBoolean` |
| `s8`, `s16`, `s32` | as a Number value | `ToInt32` |
| `u8`, `u16`, `u32` | as a Number value | `ToUint32` |
| `s64` | as a BigInt value | `ToBigInt64` |
| `u64` | as a BigInt value | `ToBigUint64` |
| `float32`, `float64` | as a Number, mapping the canonical NaN to [JS NaN] | `ToNumber` mapping [JS NaN] to the canonical NaN |
| `char` | same as [`USVString`] | same as [`USVString`], throw if the USV length is not 1 |
| `record` | TBD: maybe a [JS Record]? | same as [`dictionary`] |
| `variant` | TBD | TBD |
| `list` | same as [`sequence`] | same as [`sequence`] |
| `string` | same as [`USVString`]  | same as [`USVString`] |
| `tuple` | TBD: maybe a [JS Tuple]? | TBD |
| `flags` | TBD: maybe a [JS Record]? | same as [`dictionary`] of `boolean` fields |
| `enum` | same as [`enum`] | same as [`enum`] |
| `option` | same as [`T?`] | same as [`T?`] |
| `union` | same as [`union`] | same as [`union`] |
| `expected` | same as `variant`, but coerce a top-level `error` return value to a thrown exception | same as `variant`, but coerce uncaught exceptions to top-level `error` return values |

Notes:
* The forthcoming addition of [resource and handle types] would additionally
  allow coercion to and from the remaining Symbol and Object JavaScript value
  types.
* The forthcoming addition of [future and stream types] would allow `Promise`
  and `ReadableStream` values to be passed directly to and from components
  without requiring handles or callbacks.
* When an imported JavaScript function is a built-in function wrapping a Web
  IDL function, the specified behavior should allow the intermediate JavaScript
  call to be optimized away when the types are sufficiently compatible, falling
  back to a plain call through JavaScript when the types are incompatible or
  when the engine does not provide a separate optimized call path.


### ESM-integration

Like the JS API, [ESM-integration] can be extended to load components in all
the same places where modules can be loaded today, branching on the `kind`
field in the binary format to determine whether to decode as a module or a
component. The main question is how to deal with component imports having a
single string as well as the new importable component, module and instance
types. Going through these one by one:

For component imports of module type, we need a new way to request that the ESM
loader parse or decode a module without *also* instantiating that module.
Recognizing this same need from JavaScript, there is a TC39 proposal called
[Import Reflection] that adds the ability to write, in JavaScript:
```js
import Foo from "./foo.wasm" as "wasm-module";
assert(Foo instanceof WebAssembly.Module);
```
With this extension to JavaScript and the ESM loader, a component import
of module type can be treated the same as `import ... as "wasm-module"`.

Component imports of component type would work the same way as modules,
potentially replacing `"wasm-module"` with `"wasm-component"`.

In all other cases, the (single) string imported by a component is first
resolved to a [Module Record] using the same process as resolving the
[Module Specifier] of a JavaScript `import`. After this, the handling of the
imported Module Record is determined by the import type:

For imports of instance type, the ESM loader would treat the exports of the
instance type as if they were the [Named Imports] of a JavaScript `import`.
Thus, single-level imports of instance type act like the two-level imports
of Core WebAssembly modules where the first-level has been factored out. Since
the exports of an instance type can themselves be instance types, this process
must be performed recursively.

Otherwise, function or value imports are treated like an [Imported Default Binding]
and the Module Record is converted to its default value. This allows the following
component:
```wasm
;; bar.wasm
(component
  (import "./foo.js" (func (result string)))
  ...
)
```
to be satisfied by a JavaScript module via ESM-integration:
```js
// foo.js
export default () => "hi";
```
when `bar.wasm` is loaded as an ESM:
```
<script src="bar.wasm" type="module"></script>
```


## Examples

For some use-case-focused, worked examples, see:
* [Link-time virtualization example](examples/LinkTimeVirtualization.md)
* [Shared-everything dynamic linking example](examples/SharedEverythingDynamicLinking.md)
* [Component Examples presentation](https://docs.google.com/presentation/d/11lY9GBghZJ5nCFrf4MKWVrecQude0xy_buE--tnO9kQ)


## TODO

The following features are needed to address the [MVP Use Cases](../high-level/UseCases.md)
and will be added over the coming months to complete the MVP proposal:
* concurrency support ([slides][Future And Stream Types])
* abstract ("resource") types ([slides][Resource and Handle Types])
* optional imports, definitions and exports (subsuming
  [WASI Optional Imports](https://github.com/WebAssembly/WASI/blob/main/legacy/optional-imports.md)
  and maybe [conditional-sections](https://github.com/WebAssembly/conditional-sections/issues/22))



[Structure Section]: https://webassembly.github.io/spec/core/syntax/index.html
[`core:module`]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-module
[`core:export`]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-export
[`core:import`]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-import
[`core:importdesc`]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-importdesc
[`core:functype`]: https://webassembly.github.io/spec/core/syntax/types.html#syntax-functype
[`core:valtype`]: https://webassembly.github.io/spec/core/syntax/types.html#value-types

[Text Format Section]: https://webassembly.github.io/spec/core/text/index.html
[Abbreviations]: https://webassembly.github.io/spec/core/text/conventions.html#abbreviations
[`core:typeuse`]: https://webassembly.github.io/spec/core/text/modules.html#type-uses
[func-import-abbrev]: https://webassembly.github.io/spec/core/text/modules.html#text-func-abbrev

[Binary Format Section]: https://webassembly.github.io/spec/core/binary/index.html
[`version`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-version

[JS API]: https://webassembly.github.io/spec/js-api/index.html
[*read the imports*]: https://webassembly.github.io/spec/js-api/index.html#read-the-imports
[`ToJSValue`]: https://webassembly.github.io/spec/js-api/index.html#tojsvalue
[`ToWebAssemblyValue`]: https://webassembly.github.io/spec/js-api/index.html#towebassemblyvalue
[`USVString`]: https://webidl.spec.whatwg.org/#es-USVString
[`sequence`]: https://webidl.spec.whatwg.org/#es-sequence
[`dictionary`]: https://webidl.spec.whatwg.org/#es-dictionary
[`enum`]: https://webidl.spec.whatwg.org/#es-enumeration
[`T?`]: https://webidl.spec.whatwg.org/#es-nullable-type
[`union`]: https://webidl.spec.whatwg.org/#es-union
[JS NaN]: https://tc39.es/ecma262/#sec-ecmascript-language-types-number-type
[Import Reflection]: https://github.com/tc39-transfer/proposal-import-reflection
[Module Record]: https://tc39.es/ecma262/#sec-abstract-module-records
[Module Specifier]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ModuleSpecifier
[Named Imports]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-NamedImports
[Imported Default Binding]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ImportedDefaultBinding

[JS Tuple]: https://github.com/tc39/proposal-record-tuple
[JS Record]: https://github.com/tc39/proposal-record-tuple

[De Bruijn Index]: https://en.wikipedia.org/wiki/De_Bruijn_index
[Closure]: https://en.wikipedia.org/wiki/Closure_(computer_programming)
[Uninteresting Value]: https://en.wikipedia.org/wiki/Unit_type#In_programming_languages
[IEEE754]: https://en.wikipedia.org/wiki/IEEE_754
[NaN]: https://en.wikipedia.org/wiki/NaN
[Unicode Scalar Values]: https://unicode.org/glossary/#unicode_scalar_value
[Tuples]: https://en.wikipedia.org/wiki/Tuple
[Tagged Unions]: https://en.wikipedia.org/wiki/Tagged_union
[Sequences]: https://en.wikipedia.org/wiki/Sequence
[ABI]: https://en.wikipedia.org/wiki/Application_binary_interface
[Environment Variables]: https://en.wikipedia.org/wiki/Environment_variable

[Module Linking]: https://github.com/webassembly/module-linking/
[Interface Types]: https://github.com/webassembly/interface-types/
[Type Imports and Exports]: https://github.com/WebAssembly/proposal-type-imports
[Exception Handling]: https://github.com/webAssembly/exception-handling
[Stack Switching]: https://github.com/WebAssembly/stack-switching
[ESM-integration]: https://github.com/WebAssembly/esm-integration

[Adapter Functions]: FutureFeatures.md#custom-abis-via-adapter-functions
[Canonical ABI]: CanonicalABI.md

[`wizer`]: https://github.com/bytecodealliance/wizer

[Scoping and Layering]: https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8
[Resource and Handle Types]: https://docs.google.com/presentation/d/1ikwS2Ps-KLXFofuS5VAs6Bn14q4LBEaxMjPfLj61UZE
[Future and Stream Types]: https://docs.google.com/presentation/d/1WtnO_WlaoZu1wp4gI93yc7T_fWTuq3RZp8XUHlrQHl4
