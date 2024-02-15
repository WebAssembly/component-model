# Component Model Explainer

This explainer walks through the assembly-level definition of a
[component](../high-level) and the proposed embedding of components into native
JavaScript runtimes. For a more user-focussed explanation, take a look at the
**[Component Model Documentation]**.

* [Gated features](#gated-features)
* [Grammar](#grammar)
  * [Component definitions](#component-definitions)
    * [Index spaces](#index-spaces)
  * [Instance definitions](#instance-definitions)
  * [Alias definitions](#alias-definitions)
  * [Type definitions](#type-definitions)
    * [Fundamental value types](#fundamental-value-types)
      * [Numeric types](#numeric-types)
      * [Container types](#container-types)
      * [Handle types](#handle-types)
    * [Specialized value types](#specialized-value-types)
    * [Definition types](#definition-types)
    * [Declarators](#declarators)
    * [Type checking](#type-checking)
  * [Canonical definitions](#canonical-definitions)
    * [Canonical ABI](#canonical-built-ins)
    * [Canonical built-ins](#canonical-built-ins)
  * [Start definitions](#-start-definitions)
  * [Import and export definitions](#import-and-export-definitions)
* [Component invariants](#component-invariants)
* [JavaScript embedding](#JavaScript-embedding)
  * [JS API](#JS-API)
  * [ESM-integration](#ESM-integration)
* [Examples](#examples)
* [TODO](#TODO)

## Gated Features

By default, the features described in this explainer (as well as the supporting
[Binary.md](Binary.md), [WIT.md](WIT.md) and [CanonicalABI.md](CanonicalABI.md))
have been implemented and are included in the [WASI Preview 2] stability
milestone. Features that are not part of Preview 2 are demarcated by one of the
emoji symbols listed below; these emojis will be removed once they are
implemented, considered stable and included in a future milestone:
* 🪙: value imports/exports and component-level start function
* 🪺: nested namespaces and packages in import/export names

(Based on the previous [scoping and layering] proposal to the WebAssembly CG,
this repo merges and supersedes the [module-linking] and [interface-types]
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
```ebnf
component  ::= (component <id>? <definition>*)
definition ::= core-prefix(<core:module>)
             | core-prefix(<core:instance>)
             | core-prefix(<core:type>)
             | <component>
             | <instance>
             | <alias>
             | <type>
             | <canon>
             | <start> 🪺
             | <import>
             | <export>

where core-prefix(X) parses '(' 'core' Y ')' when X parses '(' Y ')'
```
Components are like Core WebAssembly modules in that their contained
definitions are acyclic: definitions can only refer to preceding definitions
(in the AST, text format and binary format). However, unlike modules,
components can arbitrarily interleave different kinds of definitions.

The `core-prefix` meta-function transforms a grammatical rule for parsing a
Core WebAssembly definition into a grammatical rule for parsing the same
definition, but with a `core` token added right after the leftmost paren.
For example, `core:module` accepts `(module (func))` so
`core-prefix(<core:module>)` accepts `(core module (func))`. Note that the
inner `func` doesn't need a `core` prefix; the `core` token is used to mark the
*transition* from parsing component definitions into core definitions.

The [`core:module`] production is unmodified by the Component Model and thus
components embed Core WebAssembly (text and binary format) modules as currently
standardized, allowing reuse of an unmodified Core WebAssembly implementation.
The next two productions, `core:instance` and `core:alias`, are not currently
included in Core WebAssembly, but would be if Core WebAssembly adopted the
[module-linking] proposal. These two new core definitions are introduced below,
alongside their component-level counterparts. Finally, the existing
[`core:type`] production is extended below to add core module types as proposed
for module-linking. Thus, the overall idea is to represent core definitions (in
the AST, binary and text format) as-if they had already been added to Core
WebAssembly so that, if they eventually are, the implementation of decoding and
validation can be shared in a layered fashion.

The next kind of definition is, recursively, a component itself. Thus,
components form trees with all other kinds of definitions only appearing at the
leaves. For example, with what's defined so far, we can write the following
component:
```wasm
(component
  (component
    (core module (func (export "one") (result i32) (i32.const 1)))
    (core module (func (export "two") (result f32) (f32.const 2)))
  )
  (core module (func (export "three") (result i64) (i64.const 3)))
  (component
    (component
      (core module (func (export "four") (result f64) (f64.const 4)))
    )
  )
  (component)
)
```
This top-level component roots a tree with 4 modules and 1 component as
leaves. However, in the absence of any `instance` definitions (introduced
next), nothing will be instantiated or executed at runtime; everything here is
dead code.


#### Index Spaces

[Like Core WebAssembly][Core Indices], the Component Model places each
`definition` into one of a fixed set of *index spaces*, allowing the
definition to be referred to by subsequent definitions (in the text and binary
format) via a nonnegative integral *index*. When defining, validating and
executing a component, there are 5 component-level index spaces:
* (component) functions
* (component) values
* (component) types
* component instances
* components

5 core index spaces that also exist in WebAssembly 1.0:
* (core) functions
* (core) tables
* (core) memories
* (core) globals
* (core) types

and 2 additional core index spaces that contain core definition introduced by
the Component Model that are not in WebAssembly 1.0 (yet: the [module-linking]
proposal would add them):
* module instances
* modules

for a total of 12 index spaces that need to be maintained by an implementation
when, e.g., validating a component. These 12 index spaces correspond 1:1 with
the terminals of the `sort` production defined below and thus "sort" and
"index space" can be used interchangeably.

Also [like Core WebAssembly][Core Identifiers], the Component Model text format
allows *identifiers* to be used in place of these indices, which are resolved
when parsing into indices in the AST (upon which validation and execution is
defined). Thus, the following two components are equivalent:
```wasm
(component
  (core module (; empty ;))
  (component   (; empty ;))
  (core module (; empty ;))
  (export "C" (component 0))
  (export "M1" (core module 0))
  (export "M2" (core module 1))
)
```
```wasm
(component
  (core module $M1 (; empty ;))
  (component $C    (; empty ;))
  (core module $M2 (; empty ;))
  (export "C" (component $C))
  (export "M1" (core module $M1))
  (export "M2" (core module $M2))
)
```


### Instance Definitions

Whereas modules and components represent immutable *code*, instances associate
code with potentially-mutable *state* (e.g., linear memory) and thus are
necessary to create before being able to *run* the code. Instance definitions
create module or component instances by selecting a module or component and
then supplying a set of named *arguments* which satisfy all the named *imports*
of the selected module or component.

The syntax for defining a core module instance is:
```ebnf
core:instance       ::= (instance <id>? <core:instancexpr>)
core:instanceexpr   ::= (instantiate <core:moduleidx> <core:instantiatearg>*)
                      | <core:inlineexport>*
core:instantiatearg ::= (with <core:name> (instance <core:instanceidx>))
                      | (with <core:name> (instance <core:inlineexport>*))
core:sortidx        ::= (<core:sort> <u32>)
core:sort           ::= func
                      | table
                      | memory
                      | global
                      | type
                      | module
                      | instance
core:inlineexport   ::= (export <core:name> <core:sortidx>)
```
When instantiating a module via `instantiate`, the two-level imports of the
core modules are resolved as follows:
1. The first `core:name` of the import is looked up in the named list of
   `core:instantiatearg` to select a core module instance. (In the future,
   other `core:sort`s could be allowed if core wasm adds single-level
   imports.)
2. The second `core:name` of the import is looked up in the named list of
   exports of the core module instance found by the first step to select the
   imported core definition.

Each `core:sort` corresponds 1:1 with a distinct [index space] that contains
only core definitions of that *sort*. The `u32` field of `core:sortidx`
indexes into the sort's associated index space to select a definition.

Based on this, we can link two core modules `$A` and `$B` together with the
following component:
```wasm
(component
  (core module $A
    (func (export "one") (result i32) (i32.const 1))
  )
  (core module $B
    (func (import "a" "one") (result i32))
  )
  (core instance $a (instantiate $A))
  (core instance $b (instantiate $B (with "a" (instance $a))))
)
```
To see examples of other sorts, we'll need `alias` definitions, which are
introduced in the next section.

The `<core:inlineexport>*` form of `core:instanceexpr` allows module instances
to be created by directly tupling together preceding definitions, without the
need to `instantiate` a helper module. The `<core:inlineexport>*` form of
`core:instantiatearg` is syntactic sugar that is expanded during text format
parsing into an out-of-line instance definition referenced by `with`. To show
an example of these, we'll also need the `alias` definitions introduced in the
next section.

The syntax for defining component instances is symmetric to core module
instances, but with an expanded component-level definition of `sort`:
```ebnf
instance       ::= (instance <id>? <instanceexpr>)
instanceexpr   ::= (instantiate <componentidx> <instantiatearg>*)
                 | <inlineexport>*
instantiatearg ::= (with <string> <sortidx>)
                 | (with <string> (instance <inlineexport>*))
string         ::= <core:name>
sortidx        ::= (<sort> <u32>)
sort           ::= core <core:sort>
                 | func
                 | value 🪙
                 | type
                 | component
                 | instance
inlineexport   ::= (export <exportname> <sortidx>)
```
Because component-level function, type and instance definitions are different
than core-level function, type and instance definitions, they are put into
disjoint index spaces which are indexed separately. Components may import
and export various core definitions (when they are compatible with the
[shared-nothing] model, which currently means only `module`, but may in the
future include `data`). Thus, component-level `sort` injects the full set
of `core:sort`, so that they may be referenced (leaving it up to validation
rules to throw out the core sorts that aren't allowed in various contexts).

The `string` production reuses the `core:name` quoted-string-literal syntax of
Core WebAssembly (which appears in core module imports and exports and can
contain any valid UTF-8 string).

🪙 The `value` sort refers to a value that is provided and consumed during
instantiation. How this works is described in the
[start definitions](#start-definitions) section.

To see a non-trivial example of component instantiation, we'll first need to
introduce a few other definitions below that allow components to import, define
and export component functions.


### Alias Definitions

Alias definitions project definitions out of other components' index spaces and
into the current component's index spaces. As represented in the AST below,
there are three kinds of "targets" for an alias: the `export` of a component
instance, the `core export` of a core module instance and a definition of an
`outer` component (containing the current component):
```ebnf
alias            ::= (alias <aliastarget> (<sort> <id>?))
aliastarget      ::= export <instanceidx> <string>
                   | core export <core:instanceidx> <core:name>
                   | outer <u32> <u32>
```
If present, the `id` of the alias is bound to the new index added by the alias
and can be used anywhere a normal `id` can be used.

In the case of `export` aliases, validation ensures `string` is an export in the
target instance and has a matching sort.

In the case of `outer` aliases, the `u32` pair serves as a [de Bruijn
index], with first `u32` being the number of enclosing components/modules to
skip and the second `u32` being an index into the target's sort's index space.
In particular, the first `u32` can be `0`, in which case the outer alias refers
to the current component. To maintain the acyclicity of module instantiation,
outer aliases are only allowed to refer to *preceding* outer definitions.

Components containing outer aliases effectively produce a [closure] at
instantiation time, including a copy of the outer-aliased definitions. Because
of the prevalent assumption that components are immutable values, outer aliases
are restricted to only refer to immutable definitions: non-resource types,
modules and components. (In the future, outer aliases to all sorts of
definitions could be allowed by recording the statefulness of the resulting
component in its type via some kind of "`stateful`" type attribute.)

Both kinds of aliases come with syntactic sugar for implicitly declaring them
inline:

For `export` aliases, the inline sugar extends the definition of `sortidx`
and the various sort-specific indices:
```ebnf
sortidx     ::= (<sort> <u32>)          ;; as above
              | <inlinealias>
Xidx        ::= <u32>                   ;; as above
              | <inlinealias>
inlinealias ::= (<sort> <u32> <string>+)
```
If `<sort>` refers to a `<core:sort>`, then the `<u32>` of `inlinealias` is a
`<core:instanceidx>`; otherwise it's an `<instanceidx>`. For example, the
following snippet uses two inline function aliases:
```wasm
(instance $j (instantiate $J (with "f" (func $i "f"))))
(export "x" (func $j "g" "h"))
```
which are desugared into:
```wasm
(alias export $i "f" (func $f_alias))
(instance $j (instantiate $J (with "f" (func $f_alias))))
(alias export $j "g" (instance $g_alias))
(alias export $g_alias "h" (func $h_alias))
(export "x" (func $h_alias))
```

For `outer` aliases, the inline sugar is simply the identifier of the outer
definition, resolved using normal lexical scoping rules. For example, the
following component:
```wasm
(component
  (component $C ...)
  (component
    (instance (instantiate $C))
  )
)
```
is desugared into:
```wasm
(component $Parent
  (component $C ...)
  (component
    (alias outer $Parent $C (component $Parent_C))
    (instance (instantiate $Parent_C))
  )
)
```

Lastly, for symmetry with [imports][func-import-abbrev], aliases can be written
in an inverted form that puts the sort first:
```wasm
    (func $f (import "i" "f") ...type...) ≡ (import "i" "f" (func $f ...type...))   (WebAssembly 1.0)
          (func $f (alias export $i "f")) ≡ (alias export $i "f" (func $f))
   (core module $m (alias export $i "m")) ≡ (alias export $i "m" (core module $m))
(core func $f (alias core export $i "f")) ≡ (alias core export $i "f" (core func $f))
```

With what's defined so far, we're able to link modules with arbitrary renamings:
```wasm
(component
  (core module $A
    (func (export "one") (result i32) (i32.const 1))
    (func (export "two") (result i32) (i32.const 2))
    (func (export "three") (result i32) (i32.const 3))
  )
  (core module $B
    (func (import "a" "one") (result i32))
  )
  (core instance $a (instantiate $A))
  (core instance $b1 (instantiate $B
    (with "a" (instance $a))                      ;; no renaming
  ))
  (core func $a_two (alias core export $a "two")) ;; ≡ (alias core export $a "two" (core func $a_two))
  (core instance $b2 (instantiate $B
    (with "a" (instance
      (export "one" (func $a_two))                ;; renaming, using out-of-line alias
    ))
  ))
  (core instance $b3 (instantiate $B
    (with "a" (instance
      (export "one" (func $a "three"))            ;; renaming, using <inlinealias>
    ))
  ))
)
```
To show analogous examples of linking components, we'll need component-level
type and function definitions which are introduced in the next two sections.


### Type Definitions

The syntax for defining core types extends the existing core type definition
syntax, adding a `module` type constructor:
```ebnf
core:type        ::= (type <id>? <core:deftype>)              (GC proposal)
core:deftype     ::= <core:functype>                          (WebAssembly 1.0)
                   | <core:structtype>                        (GC proposal)
                   | <core:arraytype>                         (GC proposal)
                   | <core:moduletype>
core:moduletype  ::= (module <core:moduledecl>*)
core:moduledecl  ::= <core:importdecl>
                   | <core:type>
                   | <core:alias>
                   | <core:exportdecl>
core:alias       ::= (alias <core:aliastarget> (<core:sort> <id>?))
core:aliastarget ::= outer <u32> <u32>
core:importdecl  ::= (import <core:name> <core:name> <core:importdesc>)
core:exportdecl  ::= (export <core:name> <core:exportdesc>)
core:exportdesc  ::= strip-id(<core:importdesc>)

where strip-id(X) parses '(' sort Y ')' when X parses '(' sort <id>? Y ')'
```

Here, `core:deftype` (short for "defined type") is inherited from the [gc]
proposal and extended with a `module` type constructor. If [module-linking] is
added to Core WebAssembly, an `instance` type constructor would be added as
well but, for now, it's left out since it's unnecessary. Also, in the MVP,
validation will reject `core:moduletype` defining or aliasing other
`core:moduletype`s, since, before module-linking, core modules cannot
themselves import or export other core modules.

The body of a module type contains an ordered list of "module declarators"
which describe, at a type level, the imports and exports of the module. In a
module-type context, import and export declarators can both reuse the existing
[`core:importdesc`] production defined in WebAssembly 1.0, with the only
difference being that, in the text format, `core:importdesc` can bind an
identifier for later reuse while `core:exportdesc` cannot.

With the Core WebAssembly [type-imports], module types will need the ability to
define the types of exports based on the types of imports. In preparation for
this, module types start with an empty type index space that is populated by
`type` declarators, so that, in the future, these `type` declarators can refer to
type imports local to the module type itself. For example, in the future, the
following module type would be expressible:
```wasm
(component $C
  (core type $M (module
    (import "" "T" (type $T))
    (type $PairT (struct (field (ref $T)) (field (ref $T))))
    (export "make_pair" (func (param (ref $T)) (result (ref $PairT))))
  ))
)
```
In this example, `$M` has a distinct type index space from `$C`, where element
0 is the imported type, element 1 is the `struct` type, and element 2 is an
implicitly-created `func` type referring to both.

Lastly, the `core:alias` module declarator allows a module type definition to
reuse (rather than redefine) type definitions in the enclosing component's core
type index space via `outer` `type` alias. In the MVP, validation restricts
`core:alias` module declarators to *only* allow `outer` `type` aliases but,
in the future, more kinds of aliases would be meaningful and allowed.

As an example, the following component defines two semantically-equivalent
module types, where the former defines the function type via `type` declarator
and the latter refers via `alias` declarator. Note that, since core type
definitions are validated in a Core WebAssembly context that doesn't "know"
anything about components, the module type `$C2` can't name `$C` directly in
the text format but must instead use the appropriate [de Bruijn] index (`1`).
In both cases, the defined/aliased function type is given index `0` since
module types always start with an empty type index space.
```wasm
(component $C
  (core type $C1 (module
    (type (func (param i32) (result i32)))
    (import "a" "b" (func (type 0)))
    (export "c" (func (type 0)))
  ))
  (core type $F (func (param i32) (result i32)))
  (core type $C2 (module
    (alias outer 1 $F (type))
    (import "a" "b" (func (type 0)))
    (export "c" (func (type 0)))
  ))
)
```

Component-level type definitions are symmetric to core-level type definitions,
but use a completely different set of value types. Unlike [`core:valtype`]
which is low-level and assumes a shared linear memory for communicating
compound values, component-level value types assume no shared memory and must
therefore be high-level, describing entire compound values.
```ebnf
type          ::= (type <id>? <deftype>)
deftype       ::= <defvaltype>
                | <resourcetype>
                | <functype>
                | <componenttype>
                | <instancetype>
defvaltype    ::= bool
                | s8 | u8 | s16 | u16 | s32 | u32 | s64 | u64
                | float32 | float64
                | char | string
                | (record (field "<label>" <valtype>)+)
                | (variant (case <id>? "<label>" <valtype>?)+)
                | (list <valtype>)
                | (tuple <valtype>+)
                | (flags "<label>"+)
                | (enum "<label>"+)
                | (option <valtype>)
                | (result <valtype>? (error <valtype>)?)
                | (own <typeidx>)
                | (borrow <typeidx>)
valtype       ::= <typeidx>
                | <defvaltype>
resourcetype  ::= (resource (rep i32) (dtor <funcidx>)?)
functype      ::= (func <paramlist> <resultlist>)
paramlist     ::= (param "<label>" <valtype>)*
resultlist    ::= (result "<label>" <valtype>)*
                | (result <valtype>)
componenttype ::= (component <componentdecl>*)
instancetype  ::= (instance <instancedecl>*)
componentdecl ::= <importdecl>
                | <instancedecl>
instancedecl  ::= core-prefix(<core:type>)
                | <type>
                | <alias>
                | <exportdecl>
importdecl    ::= (import <importname> bind-id(<externdesc>))
exportdecl    ::= (export <exportname> bind-id(<externdesc>))
externdesc    ::= (<sort> (type <u32>) )
                | core-prefix(<core:moduletype>)
                | <functype>
                | <componenttype>
                | <instancetype>
                | (value <valtype>) 🪙
                | (type <typebound>)
typebound     ::= (eq <typeidx>)
                | (sub resource)

where bind-id(X) parses '(' sort <id>? Y ')' when X parses '(' sort Y ')'
```

#### Fundamental value types

The value types in `valtype` can be broken into two categories: *fundamental*
value types and *specialized* value types, where the latter are defined by
expansion into the former. The *fundamental value types* have the following
sets of abstract values:
| Type                      | Values |
| ------------------------- | ------ |
| `bool`                    | `true` and `false` |
| `s8`, `s16`, `s32`, `s64` | integers in the range [-2<sup>N-1</sup>, 2<sup>N-1</sup>-1] |
| `u8`, `u16`, `u32`, `u64` | integers in the range [0, 2<sup>N</sup>-1] |
| `float32`, `float64`      | [IEEE754] floating-point numbers, with a single NaN value |
| `char`                    | [Unicode Scalar Values] |
| `record`                  | heterogeneous [tuples] of named values |
| `variant`                 | heterogeneous [tagged unions] of named values |
| `list`                    | homogeneous, variable-length [sequences] of values |
| `own`                     | a unique, opaque address of a resource that will be destroyed when this value is dropped |
| `borrow`                  | an opaque address of a resource that must be dropped before the current export call returns |

How these abstract values are produced and consumed from Core WebAssembly
values and linear memory is configured by the component via *canonical lifting
and lowering definitions*, which are introduced [below](#canonical-definitions).
For example, while abstract `variant`s contain a list of `case`s labelled by
name, canonical lifting and lowering map each case to an `i32` value starting
at `0`.

##### Numeric types

While core numeric types are defined in terms of sets of bit-patterns and
operations that interpret the bits in various ways, component-level numeric
types are defined in terms of sets of values. This allows the values to be
translated between source languages and protocols that use different
value representations.

Core integer types are just bit-patterns that don't distinguish between signed
and unsigned, while component-level integer types are sets of integers that
either include negative values or don't. Core floating-point types have many
distinct NaN bit-patterns, while component-level floating-point types have only
a single NaN value. And boolean values in core wasm are usually represented as
`i32`s where operations interpret all-zeros as `false`, while at the
component-level there is a `bool` type with `true` and `false` values.

##### Container types

The `record`, `variant`, and `list` types allow for grouping, categorizing,
and sequencing contained values.

##### Handle types

The `own` and `borrow` value types are both *handle types*. Handles logically
contain the opaque address of a resource and avoid copying the resource when
passed across component boundaries. By way of metaphor to operating systems,
handles are analogous to file descriptors, which are stored in a table and may
only be used indirectly by untrusted user-mode processes via their integer
index in the table. In the Component Model, handles are lifted-from and
lowered-into `i32` values that index an encapsulated per-component-instance
*handle table* that is maintained by the canonical function definitions
described [below](#canonical-definitions). The uniqueness and dropping
conditions mentioned above are enforced at runtime by the Component Model
through these canonical definitions. The `typeidx` immediate of a handle type
must refer to a `resource` type (described below) that statically classifies
the particular kinds of resources the handle can point to.

#### Specialized value types

The sets of values allowed for the remaining *specialized value types* are
defined by the following mapping:
```
                    (tuple <valtype>*) ↦ (record (field "𝒊" <valtype>)*) for 𝒊=0,1,...
                    (flags "<label>"*) ↦ (record (field "<label>" bool)*)
                     (enum "<label>"+) ↦ (variant (case "<label>")+)
                    (option <valtype>) ↦ (variant (case "none") (case "some" <valtype>))
(result <valtype>? (error <valtype>)?) ↦ (variant (case "ok" <valtype>?) (case "error" <valtype>?))
                                string ↦ (list char)
```
Note that, at least initially, variants are required to have a non-empty list of
cases. This could be relaxed in the future to allow an empty list of cases, with
the empty `(variant)` effectively serving as a [empty type] and indicating
unreachability.

#### Definition types

The remaining 4 type constructors in `deftype` use `valtype` to describe
shared-nothing functions, resources, components, and component instances:

The `func` type constructor describes a component-level function definition
that takes and returns a list of `valtype`. In contrast to [`core:functype`],
the parameters and results of `functype` can have associated names which
validation requires to be unique. To improve the ergonomics and performance of
the common case of single-value-returning functions, function types may
additionally have a single unnamed return type. For this special case, bindings
generators are naturally encouraged to return the single value directly without
wrapping it in any containing record/object/struct.

The `resource` type constructor creates a fresh type for each instance of the
containing component (with "freshness" and its interaction with general
type-checking described in more detail [below](#type-checking)). Resource types
can be referred to by handle types (such as `own` and `borrow`) as well as the
canonical built-ins described [below](#canonical-built-ins). The `rep`
immediate of a `resource` type specifies its *core representation type*, which
is currently fixed to `i32`, but will be relaxed in the future (to at least
include `i64`, but also potentially other types). When the last handle to a
resource is dropped, the resource's `dtor` function will be called (if
present), allowing the implementing component to perform clean-up like freeing
linear memory allocations.

The `instance` type constructor describes a list of named, typed definitions
that can be imported or exported by a component. Informally, instance types
correspond to the usual concept of an "interface" and instance types thus serve
as static interface descriptions. In addition to the S-Expression text format
defined here, which is meant to go inside component definitions, interfaces can
also be defined as standalone, human-friendly text files in the [`wit`](WIT.md)
[Interface Definition Language].

The `component` type constructor is symmetric to the core `module` type
constructor and contains *two* lists of named definitions for the imports
and exports of a component, respectively. As suggested above, instance types
can show up in *both* the import and export types of a component type.

Both `instance` and `component` type constructors are built from a sequence of
"declarators", of which there are four kinds&mdash;`type`, `alias`, `import` and
`export`&mdash;where only `component` type constructors can contain `import`
declarators. The meanings of these declarators is basically the same as the
core module declarators introduced above, but expanded to cover the additional
capabilities of the component model.

#### Declarators

The `importdecl` and `exportdecl` declarators correspond to component `import`
and `export` definitions, respectively, allowing an identifier to be bound for
use by subsequent declarators. The definitions of `label`, `importname` and
`exportname` are given in the [imports and exports](#import-and-export-definitions)
section below. Following the precedent of [`core:typeuse`], the text format
allows both references to out-of-line type definitions (via `(type <typeidx>)`)
and inline type expressions that the text format desugars into out-of-line type
definitions.

🪙 The `value` case of `externdesc` describes a runtime value that is imported or
exported at instantiation time as described in the
[start definitions](#start-definitions) section below.

The `type` case of `externdesc` describes an imported or exported type along
with its "bound":

The `sub` bound declares that the imported/exported type is an *abstract type*
which is a *subtype* of some other type. Currently, the only supported bound is
`resource` which (following the naming conventions of the [GC] proposal) means
"any resource type". Thus, only resource types can be imported/exported
abstractly, not arbitrary value types. This allows type imports to always be
compiled independently of their arguments using a "universal representation" for
handle values (viz., `i32`, as defined by the [Canonical ABI](CanonicalABI.md)).
In the future, `sub` may be extended to allow referencing other resource types,
thereby allowing abstract resource subtyping.

The `eq` bound says that the imported/exported type must be structurally equal
to some preceding type definition. This allows:
* an imported abstract type to be re-exported;
* components to introduce another label for a preceding abstract type (which
  can be necessary when implementing multiple independent interfaces with the
  same resource); and
* components to attach transparent type aliases to structural types to be
  reflected in source-level bindings (e.g., `(export "bytes" (type (eq (list u64))))`
  could generate in C++ a `typedef std::vector<uint64_t> bytes` or in JS an
  exported field named `bytes` that aliases `Uint64Array`.

Relaxing the restrictions of `core:alias` declarators mentioned above, `alias`
declarators allow both `outer` and `export` aliases of `type` and `instance`
sorts. This allows the type exports of `instance`-typed import and export
declarators to be used by subsequent declarators in the type:
```wasm
(component
  (import "fancy-fs" (instance $fancy-fs
    (export $fs "fs" (instance
      (export "file" (type (sub resource)))
      ;; ...
    ))
    (alias export $fs "file" (type $file))
    (export "fancy-op" (func (param "f" (borrow $file))))
  ))
)
```

The `type` declarator is restricted by validation to disallow `resource` type
definitions. Thus, the only resource types possible in an `instancetype` or
`componenttype` are introduced by `importdecl` or `exportdecl`.

With what's defined so far, we can define component types using a mix of type
definitions:
```wasm
(component $C
  (type $T (list (tuple string bool)))
  (type $U (option $T))
  (type $G (func (param "x" (list $T)) (result $U)))
  (type $D (component
    (alias outer $C $T (type $C_T))
    (type $L (list $C_T))
    (import "f" (func (param "x" $L) (result (list u8))))
    (import "g" (func (type $G)))
    (export "g2" (func (type $G)))
    (export "h" (func (result $U)))
    (import "T" (type $T (sub resource)))
    (import "i" (func (param "x" (list (own $T)))))
    (export $T' "T2" (type (eq $T)))
    (export $U' "U" (type (sub resource)))
    (export "j" (func (param "x" (borrow $T')) (result (own $U'))))
  ))
)
```
Note that the inline use of `$G` and `$U` are syntactic sugar for `outer`
aliases.

#### Type Checking

Like core modules, components have an up-front validation phase in which the
definitions of a component are checked for basic consistency. Type checking
is a central part of validation and, e.g., occurs when validating that the
`with` arguments of an [`instantiate`](#instance-definitions) expression are
type-compatible with the `import`s of the component being instantiated.

To incrementally describe how type-checking works, we'll start by asking how
*type equality* works for non-resource, non-handle, local type definitions and
build up from there.

Type equality for almost all types (except as described below) is purely
*structural*. In a structural setting, types are considered to be Abstract
Syntax Trees whose nodes are type constructors with types like `u8` and
`string` considered to be "nullary" type constructors that appear at leaves and
non-nullary type constructors like `list` and `record` appearing at parent
nodes. Then, type equality is defined to be AST equality. Importantly, these
type ASTs do *not* contain any type indices or depend on index space layout;
these binary format details are consumed by decoding to produce the AST. For
example, in the following compound component:
```wasm
(component $A
  (type $ListString1 (list string))
  (type $ListListString1 (list $ListString1))
  (type $ListListString2 (list $ListString1))
  (component $B
    (type $ListString3 (list string))
    (type $ListListString3 (list $ListString3))
    (type $ListString4 (alias outer $A $ListString))
    (type $ListListString4 (list $ListString4))
    (type $ListListString5 (alias outer $A $ListString2))
  )
)
```
all 5 variations of `$ListListStringX` are considered equal since, after
decoding, they all have the same AST.

Next, the type equality relation on ASTs is relaxed to a more flexible
[subtyping] relation. Currently, subtyping is only relaxed for `instance` and
`component` types, but may be relaxed for more type constructors in the future
to better support API Evolution (being careful to understand how subtyping
manifests itself in the wide variety of source languages so that
subtype-compatible updates don't inadvertantly break source-level clients).

Component and instance subtyping allows a subtype to export more and import
less than is declared by the supertype, ignoring the exact order of imports and
exports and considering only names. For example, here, `$I1` is a subtype of
`$I2`:
```wat
(component
  (type $I1 (instance
    (export "foo" (func))
    (export "bar" (func))
    (export "baz" (func))
  ))
  (type $I2 (instance
    (export "bar" (func))
    (export "foo" (func))
  ))
)
```
and `$C1` is a subtype of `$C2`:
```wat
(component
  (type $C1 (component
    (import "a" (func))
    (export "x" (func))
    (export "y" (func))
  ))
  (type $C2 (component
    (import "a" (func))
    (import "b" (func))
    (export "x" (func))
  ))
)
```

When we next consider type imports and exports, there are two distinct
subcases of `typebound` to consider: `eq` and `sub`.

The `eq` bound adds a type equality rule (extending the built-in set of
subtyping rules mentioned above) saying that the imported type is structurally
equivalent to the type referenced in the bound. For example, in the component:
```wasm
(component
  (type $L1 (list u8))
  (import "L2" (type $L2 (eq $L1)))
  (import "L3" (type $L2 (eq $L1)))
  (import "L4" (type $L2 (eq $L3)))
)
```
all four `$L*` types are equal (in subtyping terms, they are all subtypes of
each other).

In contrast, the `sub` bound introduces a new *abstract* type which the rest of
the component must conservatively assume can be *any* type that is a subtype of
the bound. What this means for type-checking is that each subtype-bound type
import/export introduces a *fresh* abstract type that is unequal to every
preceding type definition. Currently (and likely in the MVP), the only
supported type bound is `resource` (which means "any resource type") and thus
the only abstract types are abstract *resource* types. As an example, in the
following component:
```wasm
(component
  (import "T1" (type $T1 (sub resource)))
  (import "T2" (type $T2 (sub resource)))
)
```
the types `$T1` and `$T2` are not equal.

Once a type is imported, it can be referred to by subsequent equality-bound
type imports, thereby adding more types that it is equal to. For example, in
the following component:
```wasm
(component $C
  (import "T1" (type $T1 (sub resource)))
  (import "T2" (type $T2 (sub resource)))
  (import "T3" (type $T3 (eq $T2)))
  (type $ListT1 (list (own $T1)))
  (type $ListT2 (list (own $T2)))
  (type $ListT3 (list (own $T3)))
)
```
the types `$T2` and `$T3` are equal to each other but not to `$T1`. By the
above transitive structural equality rules, the types `$List2` and `$List3` are
equal to each other but not to `$List1`.

Handle types (`own` and `borrow`) are structural types (like `list`) but, since
they refer to resource types, transitively "inherit" the freshness of abstract
resource types. For example, in the following component:
```wasm
(component
  (import "T" (type $T (sub resource)))
  (import "U" (type $U (sub resource)))
  (type $Own1 (own $T))
  (type $Own2 (own $T))
  (type $Own3 (own $U))
  (type $ListOwn1 (list $Own1))
  (type $ListOwn2 (list $Own2))
  (type $ListOwn3 (list $Own3))
  (type $Borrow1 (borrow $T))
  (type $Borrow2 (borrow $T))
  (type $Borrow3 (borrow $U))
  (type $ListBorrow1 (list $Borrow1))
  (type $ListBorrow2 (list $Borrow2))
  (type $ListBorrow3 (list $Borrow3))
)
```
the types `$Own1` and `$Own2` are equal to each other but not to `$Own3` or
any of the `$Borrow*`.  Similarly, `$Borrow1` and `$Borrow2` are equal to
each other but not `$Borrow3`. Transitively, the types `$ListOwn1` and
`$ListOwn2` are equal to each other but not `$ListOwn3` or any of the
`$ListBorrow*`. These type-checking rules for type imports mirror the
*introduction* rule of [universal types]  (∀T).

The above examples all show abstract types in terms of *imports*, but the same
"freshness" condition applies when aliasing the *exports* of another component
as well. For example, in this component:
```wasm
(component
  (import "C" (component $C
    (export "T1" (type (sub resource)))
    (export $T2 "T2" (type (sub resource)))
    (export "T3" (type (eq $T2)))
  ))
  (instance $c (instantiate $C))
  (alias export $c "T1" (type $T1))
  (alias export $c "T2" (type $T2))
  (alias export $c "T3" (type $T3))
)
```
the types `$T2` and `$T3` are equal to each other but not to `$T1`. These
type-checking rules for aliases of type exports mirror the *elimination* rule
of [existential types]  (∃T).

Next, we consider resource type *definitions* which are a *third* source of
abstract types. Unlike the abstract types introduced by type imports and
exports, resource type definitions provide canonical built-ins for setting and
getting a resource's private representation value (that are introduced
[below](#canonical-built-ins)). These built-ins are necessarily scoped to the
component instance that generated the resource type, thereby hiding access to a
resource type's representation from the outside world. Because each component
instantiation generates fresh resource types distinct from all preceding
instances of the same component, resource types are ["generative"].

For example, in the following example component:
```wasm
(component
  (type $R1 (resource (rep i32)))
  (type $R2 (resource (rep i32)))
  (func $f1 (result (own $R1)) (canon lift ...))
  (func $f2 (param (own $R2)) (canon lift ...))
)
```
the types `$R1` and `$R2` are unequal and thus the return type of `$f1`
is incompatible with the parameter type of `$f2`.

The generativity of resource type definitions matches the abstract typing rules
of type exports mentioned above, which force all clients of the component to
bind a fresh abstract type. For example, in the following component:
```wasm
(component
  (component $C
    (type $r1 (export "r1") (resource (rep i32)))
    (type $r2 (export "r2") (resource (rep i32)))
  )
  (instance $c1 (instantiate $C))
  (instance $c2 (instantiate $C))
  (type $c1r1 (alias export $c1 "r1"))
  (type $c1r2 (alias export $c1 "r2"))
  (type $c2r1 (alias export $c2 "r1"))
  (type $c2r2 (alias export $c2 "r2"))
)
```
all four types aliases in the outer component are unequal, reflecting the fact
that each instance of `$C` generates two fresh resource types.

If a single resource type definition is exported more than once, the exports
after the first are equality-bound to the first export. For example, the
following component:
```wasm
(component
  (type $r (resource (rep i32)))
  (export "r1" (type $r))
  (export "r2" (type $r))
)
```
is assigned the following `componenttype`:
```wasm
(component
  (export $r1 "r1" (type (sub resource)))
  (export "r2" (type (eq $r1)))
)
```
Thus, from an external perspective, `r1` and `r2` are two labels for the same
type.

If a component wants to hide this fact and force clients to assume `r1` and
`r2` are distinct types (thereby allowing the implementation to actually use
separate types in the future without breaking clients), an explicit type can be
ascribed to the export that replaces the `eq` bound with a less-precise `sub`
bound.
```wasm
(component
  (type $r (resource (rep i32)))
  (export "r1" (type $r)
  (export "r2" (type $r) (type (sub resource)))
)
```
This component is assigned the following `componenttype`:
```wasm
(component
  (export "r1" (type (sub resource)))
  (export "r2" (type (sub resource)))
)
```
The assignment of this type to the above component mirrors the *introduction*
rule of [existential types]  (∃T).

When supplying a resource type (imported *or* defined) to a type import via
`instantiate`, type checking performs a substitution, replacing all uses of the
`import` in the instantiated component with the actual type supplied via
`with`. For example, the following component validates:
```wasm
(component $P
  (import "C1" (component $C1
    (import "T" (type $T (sub resource)))
    (export "foo" (func (param (own $T))))
  ))
  (import "C2" (component $C2
    (import "T" (type $T (sub resource)))
    (import "foo" (func (param (own $T))))
  ))
  (type $R (resource (rep i32)))
  (instance $c1 (instantiate $C1 (with "T" (type $R))))
  (alias export $c1 "foo" (func $foo))
  (instance $c2 (instantiate $C2 (with "T" (type $R)) (with "foo" (func $foo))))
)
```
This depends critically on the `T` imports of `$C1` and `$C2` having been
replaced by `$R` when validating the instantiations of `$c1` and `$c2`. These
type-checking rules for instantiating type imports mirror the *elimination*
rule of [universal types]  (∀T).

Importantly, this type substitution performed by the parent is not visible to
the child at validation- or run-time. In particular, the type checks performed
by the [Canonical ABI](CanonicalABI.md#context) use distinct type tags for
distinct type imports and associate type tags with *handles*, not the underlying
*resource*, leveraging the shared-nothing nature of components to type-tag handles
at component boundaries and avoid the usual [type-exposure problems with
dynamic casts][non-parametric parametricity].

In summary: all type constructors are *structural* with the exception of
`resource`, which is *abstract* and *generative*. Type imports and exports that
have a subtype bound also introduce abstract types and follow the standard
introduction and elimination rules of universal and existential types.

Lastly, since "nominal" is often taken to mean "the opposite of structural", a
valid question is whether any of the above is "nominal typing". Inside a
component, resource types act "nominally": each resource type definition
produces a new local "name" for a resource type that is distinct from all
preceding resource types. The interesting case is when resource type equality
is considered from *outside* the component, particularly when a single
component is instantiated multiple times. In this case, a single resource type
definition that is exported with a single `exportname` will get a fresh type
with each component instance, with the abstract typing rules mentioned above
ensuring that each of the component's instance's resource types are kept
distinct. Thus, in a sense, the generativity of resource types *generalizes*
traditional name-based nominal typing, providing a finer granularity of
isolation than otherwise achievable with a shared global namespace.


### Canonical Definitions

From the perspective of Core WebAssembly running inside a component, the
Component Model is an [Embedding]. As such, the Component Model defines the
Core WebAssembly imports passed to [`module_instantiate`] and how Core
WebAssembly exports are called via [`func_invoke`]. This allows the Component
Model to specify how core modules are linked together (as shown above) but it
also allows the Component Model to arbitrarily synthesize Core WebAssembly
functions (via [`func_alloc`]) that are imported by Core WebAssembly. These
synthetic core functions are created via one of several *canonical definitions*
defined below.

#### Canonical ABI

To implement or call a component-level function, we need to cross a
shared-nothing boundary. Traditionally, this problem is solved by defining a
serialization format. The Component Model MVP uses roughly this same approach,
defining a linear-memory-based [ABI] called the "Canonical ABI" which
specifies, for any `functype`, a [corresponding](CanonicalABI.md#flattening)
`core:functype` and [rules](CanonicalABI.md#lifting-and-lowering) for copying
values into and out of linear memory. The Component Model differs from
traditional approaches, though, in that the ABI is configurable, allowing
multiple different memory representations of the same abstract value. In the
MVP, this configurability is limited to the small set of `canonopt` shown
below. However, Post-MVP, [adapter functions] could be added to allow far more
programmatic control.

The Canonical ABI is explicitly applied to "wrap" existing functions in one of
two directions:
* `lift` wraps a core function (of type `core:functype`) to produce a component
  function (of type `functype`) that can be passed to other components.
* `lower` wraps a component function (of type `functype`) to produce a core
  function (of type `core:functype`) that can be imported and called from Core
  WebAssembly code inside the current component.

Canonical definitions specify one of these two wrapping directions, the function
to wrap and a list of configuration options:
```ebnf
canon    ::= (canon lift core-prefix(<core:funcidx>) <canonopt>* bind-id(<externdesc>))
           | (canon lower <funcidx> <canonopt>* (core func <id>?))
canonopt ::= string-encoding=utf8
           | string-encoding=utf16
           | string-encoding=latin1+utf16
           | (memory <core:memidx>)
           | (realloc <core:funcidx>)
           | (post-return <core:funcidx>)
```
While the production `externdesc` accepts any `sort`, the validation rules
for `canon lift` would only allow the `func` sort. In the future, other sorts
may be added (viz., types), hence the explicit sort.

The `string-encoding` option specifies the encoding the Canonical ABI will use
for the `string` type. The `latin1+utf16` encoding captures a common string
encoding across Java, JavaScript and .NET VMs and allows a dynamic choice
between either Latin-1 (which has a fixed 1-byte encoding, but limited Code
Point range) or UTF-16 (which can express all Code Points, but uses either
2 or 4 bytes per Code Point). If no `string-encoding` option is specified, the
default is UTF-8. It is a validation error to include more than one
`string-encoding` option.

The `(memory ...)` option specifies the memory that the Canonical ABI will
use to load and store values. If the Canonical ABI needs to load or store,
validation requires this option to be present (there is no default).

The `(realloc ...)` option specifies a core function that is validated to
have the following core function type:
```wasm
(func (param $originalPtr i32)
      (param $originalSize i32)
      (param $alignment i32)
      (param $newSize i32)
      (result i32))
```
The Canonical ABI will use `realloc` both to allocate (passing `0` for the
first two parameters) and reallocate. If the Canonical ABI needs `realloc`,
validation requires this option to be present (there is no default).

The `(post-return ...)` option may only be present in `canon lift`
and specifies a core function to be called with the original return values
after they have finished being read, allowing memory to be deallocated and
destructors called. This immediate is always optional but, if present, is
validated to have parameters matching the callee's return type and empty
results.

Based on this description of the AST, the [Canonical ABI explainer][Canonical
ABI] gives a detailed walkthrough of the static and dynamic semantics of `lift`
and `lower`.

One high-level consequence of the dynamic semantics of `canon lift` given in
the Canonical ABI explainer is that component functions are different from core
functions in that all control flow transfer is explicitly reflected in their
type. For example, with Core WebAssembly [exception-handling] and
[stack-switching], a core function with type `(func (result i32))` can return
an `i32`, throw, suspend or trap. In contrast, a component function with type
`(func (result string))` may only return a `string` or trap. To express
failure, component functions can return `result` and languages with exception
handling can bind exceptions to the `error` case. Similarly, the forthcoming
addition of [future and stream types] would explicitly declare patterns of
stack-switching in component function signatures.

Similar to the `import` and `alias` abbreviations shown above, `canon`
definitions can also be written in an inverted form that puts the sort first:
```wasm
(func $f (import "i" "f") ...type...) ≡ (import "i" "f" (func $f ...type...))       (WebAssembly 1.0)
(func $g ...type... (canon lift ...)) ≡ (canon lift ... (func $g ...type...))
(core func $h (canon lower ...))      ≡ (canon lower ... (core func $h))
```
Note: in the future, `canon` may be generalized to define other sorts than
functions (such as types), hence the explicit `sort`.

Using canonical function definitions, we can finally write a non-trivial
component that takes a string, does some logging, then returns a string.
```wasm
(component
  (import "logging" (instance $logging
    (export "log" (func (param string)))
  ))
  (import "libc" (core module $Libc
    (export "mem" (memory 1))
    (export "realloc" (func (param i32 i32) (result i32)))
  ))
  (core instance $libc (instantiate $Libc))
  (core func $log (canon lower
    (func $logging "log")
    (memory (core memory $libc "mem")) (realloc (func $libc "realloc"))
  ))
  (core module $Main
    (import "libc" "memory" (memory 1))
    (import "libc" "realloc" (func (param i32 i32) (result i32)))
    (import "logging" "log" (func $log (param i32 i32)))
    (func (export "run") (param i32 i32) (result i32)
      ... (call $log) ...
    )
  )
  (core instance $main (instantiate $Main
    (with "libc" (instance $libc))
    (with "logging" (instance (export "log" (func $log))))
  ))
  (func $run (param string) (result string) (canon lift
    (core func $main "run")
    (memory (core memory $libc "mem")) (realloc (func $libc "realloc"))
  ))
  (export "run" (func $run))
)
```
This example shows the pattern of splitting out a reusable language runtime
module (`$Libc`) from a component-specific, non-reusable module (`$Main`). In
addition to reducing code size and increasing code-sharing in multi-component
scenarios, this separation allows `$libc` to be created first, so that its
exports are available for reference by `canon lower`. Without this separation
(if `$Main` contained the `memory` and allocation functions), there would be a
cyclic dependency between `canon lower` and `$Main` that would have to be
broken using an auxiliary module performing `call_indirect`.

#### Canonical Built-ins

In addition to the `lift` and `lower` canonical function definitions which
adapt *existing* functions, there are also a set of canonical "built-ins" that
define core functions out of nothing that can be imported by core modules to
dynamically interact with Canonical ABI entities like resources (and, when
async is added to the proposal, [tasks][Future and Stream Types]).
```ebnf
canon ::= ...
        | (canon resource.new <typeidx> (core func <id>?))
        | (canon resource.drop <typeidx> (core func <id>?))
        | (canon resource.rep <typeidx> (core func <id>?))
```
The `resource.new` built-in has type `[i32] -> [i32]` and creates a new
resource (with resource type `typeidx`) with the given `i32` value as its
representation and returning the `i32` index of a new handle pointing to this
resource.

The `resource.drop` built-in has type `[i32] -> []` and drops a resource handle
(with resource type `typeidx`) at the given `i32` index. If the dropped handle
owns the resource, the resource's `dtor` is called, if present.

The `resource.rep` built-in has type `[i32] -> [i32]` and returns the `i32`
representation of the resource (with resource type `typeidx`) pointed to by the
handle at the given `i32` index.

As an example, the following component imports the `resource.new` built-in,
allowing it to create and return new resources to its client:
```wasm
(component
  (import "Libc" (core module $Libc ...))
  (core instance $libc (instantiate $Libc))
  (type $R (resource (rep i32) (dtor (func $libc "free"))))
  (core func $R_new (param i32) (result i32)
    (canon resource.new $R)
  )
  (core module $Main
    (import "canon" "R_new" (func $R_new (param i32) (result i32)))
    (func (export "make_R") (param ...) (result i32)
      (return (call $R_new ...))
    )
  )
  (core instance $main (instantiate $Main
    (with "canon" (instance (export "R_new" (func $R_new))))
  ))
  (export $R' "r" (type $R))
  (func (export "make-r") (param ...) (result (own $R'))
    (canon lift (core func $main "make_R"))
  )
)
```
Here, the `i32` returned by `resource.new`, which is an index into the
component's handle-table, is immediately returned by `make_R`, thereby
transferring ownership of the newly-created resource to the export's caller.

See the [CanonicalABI.md](CanonicalABI.md#canonical-definitions) for detailed
definitions of each of these built-ins and their interactions.


### 🪙 Start Definitions

Like modules, components can have start functions that are called during
instantiation. Unlike modules, components can call start functions at multiple
points during instantiation with each such call having parameters and results.
Thus, `start` definitions in components look like function calls:
```ebnf
start ::= (start <funcidx> (value <valueidx>)* (result (value <id>?))*)
```
The `(value <valueidx>)*` list specifies the arguments passed to `funcidx` by
indexing into the *value index space*. Value definitions (in the value index
space) are like immutable `global` definitions in Core WebAssembly except that
validation requires them to be consumed exactly once at instantiation-time
(i.e., they are [linear]). The arity and types of the two value lists are
validated to match the signature of `funcidx`.

As with all definition sorts, values may be imported and exported by
components. As an example value import:
```wasm
(import "env" (value $env (record (field "locale" (option string)))))
```
As this example suggests, value imports can serve as generalized [environment
variables], allowing not just `string`, but the full range of `valtype`.

With this, we can define a component that imports a string and computes a new
exported string at instantiation time:
```wasm
(component
  (import "name" (value $name string))
  (import "libc" (core module $Libc
    (export "memory" (memory 1))
    (export "realloc" (func (param i32 i32 i32 i32) (result i32)))
  ))
  (core instance $libc (instantiate $Libc))
  (core module $Main
    (import "libc" ...)
    (func (export "start") (param i32 i32) (result i32)
      ... general-purpose compute
    )
  )
  (core instance $main (instantiate $Main (with "libc" (instance $libc))))
  (func $start (param string) (result string) (canon lift
    (core func $main "start")
    (memory (core memory $libc "mem")) (realloc (func $libc "realloc"))
  ))
  (start $start (value $name) (result (value $greeting)))
  (export "greeting" (value $greeting))
)
```
As this example shows, start functions reuse the same Canonical ABI machinery
as normal imports and exports for getting component-level values into and out
of core linear memory.


### Import and Export Definitions

Both import and export definitions append a new element to the index space of
the imported/exported `sort` which can be optionally bound to an identifier in
the text format. In the case of imports, the identifier is bound just like Core
WebAssembly, as part of the `externdesc` (e.g., `(import "x" (func $x))` binds
the identifier `$x`). In the case of exports, the `<id>?` right after the
`export` is bound while the `<id>` inside the `<sortidx>` is a reference to the
preceding definition being exported (e.g., `(export $x "x" (func $f))` binds a
new identifier `$x`).
```ebnf
import ::= (import "<importname>" bind-id(<externdesc>))
export ::= (export <id>? "<exportname>" <sortidx> <externdesc>?)
```
All import names are required to be unique and all export names are required to
be unique. The rest of the grammar for imports and exports defines a structured
syntax for the contents of import and export names. Syntactically, these names
appear inside quoted string literals. The grammar thus restricts the contents
of these string literals to provide more structured information that can be
mechanically interpreted by toolchains and runtimes to support idiomatic
developer workflows and source-language bindings. The rules defining this
structured name syntax below are to be interpreted as a *lexical* grammar
defining a single token and thus whitespace is not automatically inserted, all
terminals are single-quoted, and everything unquoted is a meta-character.
```ebnf
exportname    ::= <plainname>
                | <interfacename>
importname    ::= <exportname>
                | <depname>
                | <urlname>
                | <hashname>
plainname     ::= <label>
                | '[constructor]' <label>
                | '[method]' <label> '.' <label>
                | '[static]' <label> '.' <label>
label         ::= <word>
                | <label> '-' <word>
word          ::= [a-z] [0-9a-z]*
                | [A-Z] [0-9A-Z]*
interfacename ::= <namespace> <label> <projection> <version>?
                | <namespace>+ <label> <projection>+ <version>? 🪺
namespace     ::= <label> ':'
projection    ::= '/' <label>
version       ::= '@' <valid semver>
depname       ::= 'unlocked-dep=<' <pkgnamequery> '>'
                | 'locked-dep=<' <pkgname> '>' ( ',' <hashname> )?
pkgnamequery  ::= <pkgpath> <verrange>?
pkgname       ::= <pkgpath> <version>?
pkgpath       ::= <namespace> <label>
                | <namespace>+ <label> <projection>* 🪺
verrange      ::= '@*'
                | '@{' <verlower> '}'
                | '@{' <verupper> '}'
                | '@{' <verlower> ' ' <verupper> '}'
verlower      ::= '>=' <valid semver>
verupper      ::= '<' <valid semver>
urlname       ::= 'url=<' <nonbrackets> '>' (',' <hashname>)?
                | 'relative-url=<' <nonbrackets> '>' (',' <hashname>)?
nonbrackets   ::= [^<>]*
hashname      ::= 'integrity=<' <integrity-metadata> '>'
```
Components provide seven options for naming imports:
* a **plain name** that leaves it up to the developer to "read the docs"
  or otherwise figure out what to supply for the import;
* an **interface name** that is assumed to uniquely identify a higher-level
  semantic contract that the component is requesting an *unspecified* wasm
  or native implementation of;
* a **URL name** that the component is requesting be resolved to a *particular*
  wasm implementation by [fetching] the URL.
* a **relative URL name** that the component is requesting be resolved to a
  *particular* wasm implementation by [fetching] the URL using the importing
  component's URL as the [base URL];
* a **hash name** containing a content-hash of the bytes of a *particular*
  wasm implemenentation but not specifying location of the bytes.
* a **locked dependency name** that the component is requesting be resolved via
  some contextually-supplied registry to a *particular* wasm implementation
  using the given hierarchical name and version; and
* an **unlocked dependency name** that the component is requesting be resolved
  via some contextually-supplied registry to *one of a set of possible* of wasm
  implementations using the given hierarchical name and version range.

Not all hosts are expected to support all seven import naming options and, in
general, build tools may need to wrap a to-be-deployed component with an outer
component that only uses import names that are understood by the target host.
For example:
* an offline host may only implement a fixed set of interface names, requiring
  a build tool to **bundle** URL, dependency and hash names (replacing the
  imports with nested definitions);
* browsers may only support plain and URL names (with plain names resolved via
  import map or [JS API]), requiring the build process to publish or bundle
  dependencies, converting dependency names into nested definitions or URL
  names;
* a production server environment may only allow deployment of components
  importing from a fixed set of interface and locked dependency names, thereby
  requiring all dependencies to be locked and deployed beforehand;
* host embeddings without a direct developer interface (such as the JS API or
  import maps) may reject all plain names, requiring the build process to
  resolve these beforehand;
* hosts without content-addressable storage may reject hash names (as they have
  no way to locate the contents).

The grammar and validation of URL names allows the embedded URLs to contain any
sequence of UTF-8 characters (other than angle brackets, which are used to
[delimit the URL]), leaving the well-formedness of the URL to be checked as
part of the process of fetching the URL (which can fail for any number of
additional reasons beyond validation).

When a particular implementation is indicated via URL or dependency name,
`importname` allows the component to additionally specify a cryptographic hash
of the expected binary representation of the wasm implementation, reusing the
[`integrity-metadata`] production defined by the W3C Subresource Integrity
specification. When this hash is present, a component can express its intention
to reuse another component or core module with the same degree of specificity
as if the component or core module was nested directly, thereby allowing
components to factor out common dependencies without compromising runtime
behavior. When *only* the hash is present (in a `hashname`), the host must
locate the contents using the hash (e.g., using an [OCI Registry]).

The "registry" referred to by dependency names serves to map a hierarchical
name and version to a particular module, component or exported definition. For
example, in the full generality of nested namespaces and packages (🪺), in a
registry name `a:b:c/d/e/f`, `a:b:c` traverses a path through namespaces `a`
and `b` to a component `c` and `/d/e/f` traverses the exports of `c` (where `d`
and `e` must be component exports but `f` can be anything). Given this abstract
definition, a number of concrete data sources can be interpreted by developer
tooling as "registries":
* a live registry (perhaps accessed via [`warg`])
* a local filesystem directory (perhaps containing vendored dependencies)
* a fixed set of host-provided functionality (see also the [built-in modules] proposal)
* a programmatically-created tree data structure (such as the `importObject`
  parameter of [`WebAssembly.instantiate()`])

The `valid semver` production is as defined by the [Semantic Versioning 2.0]
spec and is meant to be interpreted according to that specification. The
`verrange` production embeds a minimal subset of the syntax for version ranges
found in common package managers like `npm` and `cargo` and is meant to be
interpreted with the same [semantics][SemVerRange]. (Mostly this
interpretation is the usual SemVer-spec-defined ordering, but note the
particular behavior of pre-release tags.)

The `plainname` production captures several language-neutral syntactic hints
that allow bindings generators to produce more idiomatic bindings in their
target language. At the top-level, a `plainname` allows functions to be
annotated as being a constructor, method or static function of a preceding
resource. In each of these cases, the first `label` is the name of the resource
and the second `label` is the logical field name of the function. This
additional nesting information allows bindings generators to insert the
function into the nested scope of a class, abstract data type, object,
namespace, package, module or whatever resources get bound to. For example, a
function named `[method]C.foo` could be bound in C++ to a member function `foo`
in a class `C`. The JS API [below](#JS-API) describes how the native JavaScript
bindings could look. Validation described in [Binary.md](Binary.md) inspects
the contents of `plainname` and ensures that the function has a compatible
signature.

The `label` production used inside `plainname` as well as the labels of
`record` and `variant` types are required to have [kebab case]. The reason for
this particular form of casing is to unambiguously separate words and acronyms
(represented as all-caps words) so that source language bindings can convert a
`label` into the idiomatic casing of that language. (Indeed, because hyphens
are often invalid in identifiers, kebab case practically forces language
bindings to make such a conversion.) For example, the `label` `is-XML` could be
mapped to `isXML`, `IsXml`, `is_XML` or `is_xml`, depending on the target
language/convention. The highly-restricted character set ensures that
capitalization is trivial and does not require consulting Unicode tables.

Components provide two options for naming exports, symmetric to the first two
options for naming imports:
* a **plain name** that leaves it up to the developer to "read the docs"
  or otherwise figure out what the export does and how to use it; and
* an **interface name** that is assumed to uniquely identify a higher-level
  semantic contract that the component is claiming to implement with the
  given exported definition.

As an example, the following component uses all 9 cases of imports and exports:
```wasm
(component
  (import "custom-hook" (func (param string) (result string)))
  (import "wasi:http/handler" (instance
    (export "request" (type $request (sub resource)))
    (export "response" (type $response (sub resource)))
    (export "handle" (func (param (own $request)) (result (own $response))))
  ))
  (import "url=<https://mycdn.com/my-component.wasm>" (component ...))
  (import "relative-url=<./other-component.wasm>,integrity=<sha256-X9ArH3k...>" (component ...))
  (import "locked-dep=<my-registry:sqlite@1.2.3>,integrity=<sha256-H8BRh8j...>" (component ...))
  (import "unlocked-dep=<my-registry:imagemagick@{>=1.0.0}>" (instance ...))
  (import "integrity=<sha256-Y3BsI4l...>" (component ...))
  ... impl
  (export "wasi:http/handler" (instance $http_handler_impl))
  (export "get-JSON" (func $get_json_impl))
)
```
Here, `custom-hook` and `get-JSON` are plain names for functions whose semantic
contract is particular to this component and not defined elsewhere. In
contrast, `wasi:http/handler` is the name of a separately-defined interface,
allowing the component to request the ability to make outgoing HTTP requests
(through imports) and receive incoming HTTP requests (through exports) in a way
that can be mechanically interpreted by hosts and tooling.

The remaining 4 imports show the different ways that a component can import
external implementations. Here, the URL and locked dependency imports use
`component` types, allowing this component to privately create and wire up
instances using `instance` definitions. In contrast, the unlocked dependency
import uses an `instance` type, anticipating a subsequent tooling step (likely
the one that performs dependency resolution) to select, instantiate and provide
the instance.

Validation of `export` requires that all transitive uses of resource types in
the types of exported functions or values refer to resources that were either
imported or exported (concretely, via the type index introduced by an `import`
or `export`). The optional `<externdesc>?` in `export` can be used to
explicitly ascribe a type to an export which is validated to be a supertype of
the definition's type, thereby allowing a private (non-exported) type
definition to be replaced with a public (exported) type definition.

For example, in the following component:
```wasm
(component
  (import "R1" (type $R1 (sub resource)))
  (type $R2 (resource (rep i32)))
  (export $R2' "R2" (type $R2))
  (func $f1 (result (own $R1)) (canon lift ...))
  (func $f2 (result (own $R2)) (canon lift ...))
  (func $f2' (result (own $R2')) (canon lift ...))
  (export "f1" (func $f1))
  ;; (export "f2" (func $f2)) -- invalid
  (export "f2" (func $f2) (func (result (own $R2'))))
  (export "f2" (func $f2'))
)
```
the commented-out `export` is invalid because its type transitively refers to
`$R2`, which is a private type definition. This requirement is meant to address
the standard [avoidance problem] that appears in module systems with abstract
types. In particular, it ensures that a client of a component is able to
externally define a type compatible with the exports of the component.


## Component Invariants

As a consequence of the shared-nothing design described above, all calls into
or out of a component instance necessarily transit through a component function
definition. Thus, component functions form a "membrane" around the collection
of core module instances contained by a component instance, allowing the
Component Model to establish invariants that increase optimizability and
composability in ways not otherwise possible in the shared-everything setting
of Core WebAssembly. The Component Model proposes establishing the following
three runtime invariants:
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
(splitting the 32-bit [`core:version`] field into a 16-bit `version` field and
a 16-bit `layer` field with `0` for modules and `1` for components).

Once compiled, a `WebAssembly.Component` could be instantiated using the
existing JS API `WebAssembly.instantiate(Streaming)`. Since components have the
same basic import/export structure as modules, this means extending the [*read
the imports*] logic to support single-level imports as well as imports of
modules, components and instances. Since the results of instantiating a
component is a record of JavaScript values, just like an instantiated module,
`WebAssembly.instantiate` would always produce a `WebAssembly.Instance` object
for both module and component arguments.

Types are a new sort of definition that are not ([yet][type-imports]) present
in Core WebAssembly and so the [*read the imports*] and [*create an exports
object*] steps need to be expanded to cover them:

For type exports, each type definition would export a JS constructor function.
This function would be callable iff a `[constructor]`-annotated function was
also exported. All `[method]`- and `[static]`-annotated functions would be
dynamically installed on the constructor's prototype chain. In the case of
re-exports and multiple exports of the same definition, the same constructor
function object would be exported (following the same rules as WebAssembly
Exported Functions today). In pathological cases (which, importantly, don't
concern the global namespace, but involve the same actual type definition being
imported and re-exported by multiple components), there can be collisions when
installing constructors, methods and statics on the same constructor function
object. In such cases, a conservative option is to undo the initial
installation and require all clients to instead use the full explicit names
as normal instance exports.

For type imports, the constructors created by type exports would naturally
be importable. Additionally, certain JS- and Web-defined objects that correspond
to types (e.g., the `RegExp` and `ArrayBuffer` constructors or any Web IDL
[interface object]) could be imported. The `ToWebAssemblyValue` checks on
handle values mentioned below can then be defined to perform the associated
[internal slot] type test, thereby providing static type guarantees for
outgoing handles that can avoid runtime dynamic type tests.

Lastly, when given a component binary, the compile-then-instantiate overloads
of `WebAssembly.instantiate(Streaming)` would inherit the compound behavior of
the abovementioned functions (again, using the `layer` field to eagerly
distinguish between modules and components).

For example, the following component:
```wasm
;; a.wasm
(component
  (import "one" (func))
  (import "two" (value string)) 🪙
  (import "three" (instance
    (export "four" (instance
      (export "five" (core module
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
  two: "hi", 🪙
  three: {
    four: {
      five: await WebAssembly.compileStreaming(fetch('./b.wasm'))
    }
  }
});
```

The other significant addition to the JS API would be the expansion of the set
of WebAssembly types coerced to and from JavaScript values (by [`ToJSValue`]
and [`ToWebAssemblyValue`]) to include all of [`valtype`](#type-definitions).
At a high level, the additional coercions would be:

| Type | `ToJSValue` | `ToWebAssemblyValue` |
| ---- | ----------- | -------------------- |
| `bool` | `true` or `false` | `ToBoolean` |
| `s8`, `s16`, `s32` | as a Number value | `ToInt8`, `ToInt16`, `ToInt32` |
| `u8`, `u16`, `u32` | as a Number value | `ToUint8`, `ToUint16`, `ToUint32` |
| `s64` | as a BigInt value | `ToBigInt64` |
| `u64` | as a BigInt value | `ToBigUint64` |
| `float32`, `float64` | as a Number value | `ToNumber` |
| `char` | same as [`USVString`] | same as [`USVString`], throw if the USV length is not 1 |
| `record` | TBD: maybe a [JS Record]? | same as [`dictionary`] |
| `variant` | see below | see below |
| `list` | create a typed array copy for number types; otherwise produce a JS array (like [`sequence`]) | same as [`sequence`] |
| `string` | same as [`USVString`]  | same as [`USVString`] |
| `tuple` | TBD: maybe a [JS Tuple]? | TBD |
| `flags` | TBD: maybe a [JS Record]? | same as [`dictionary`] of optional `boolean` fields with default values of `false` |
| `enum` | same as [`enum`] | same as [`enum`] |
| `option` | same as [`T?`] | same as [`T?`] |
| `result` | same as `variant`, but coerce a top-level `error` return value to a thrown exception | same as `variant`, but coerce uncaught exceptions to top-level `error` return values |
| `own`, `borrow` | see below | see below |

Notes:
* Function parameter names are ignored since JavaScript doesn't have named
  parameters.
* If a function's result type list is empty, the JavaScript function returns
  `undefined`. If the result type list contains a single unnamed result, then
  the return value is specified by `ToJSValue` above. Otherwise, the function
  result is wrapped into a JS object whose field names are taken from the result
  names and whose field values are specified by `ToJSValue` above.
* In lieu of an existing standard JS representation for `variant`, the JS API
  would need to define its own custom binding built from objects. As a sketch,
  the JS values accepted by `(variant (case "a" u32) (case "b" string))` could
  include `{ tag: 'a', value: 42 }` and `{ tag: 'b', value: "hi" }`.
* For `option`, when Web IDL doesn't support particular type
  combinations (e.g., `(option (option u32))`), the JS API would fall back to
  the JS API of the unspecialized `variant` (e.g.,
  `(variant (case "some" (option u32)) (case "none"))`, despecializing only
  the problematic outer `option`).
* When coercing `ToWebAssemblyValue`, `own` and `borrow` handle types would
  dynamically guard that the incoming JS value's dynamic type was compatible
  with the imported resource type referenced by the handle type. For example,
  if a component contains `(import "Object" (type $Object (sub resource)))` and
  is instantiated with the JS `Object` constructor, then `(own $Object)` and
  `(borrow $Object)` could accept JS `object` values.
* When coercing `ToJSValue`, handle values would be wrapped with JS objects
  that are instances of the handles' resource type's exported constructor
  (described above). For `own` handles, a [`FinalizationRegistry`] would be
  used to drop the `own` handle (thereby calling the resource destructor) when
  its wrapper object was unreachable from JS. For `borrow` handles, the wrapper
  object would become dynamically invalid (throwing on any access) at the end
  of the export call.
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
the same places where modules can be loaded today, branching on the `layer`
field in the binary format to determine whether to decode as a module or a
component.

For URL import names, the embedded URL would be used as the [Module Specifier].
For plain names, the whole plain name would be used as the [Module Specifier]
(and an import map would be needed to map the string to a URL). For locked and
unlocked dependency names, ESM-integration would likely simply fail loading the
module, requiring a bundler to map these registry-relative names to URLs.

TODO: ESM-integration for interface imports and exports is still being
worked out in detail.

The main remaining question is how to deal with component imports having a
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
```html
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
* optional imports, definitions and exports (subsuming
  [WASI Optional Imports](https://github.com/WebAssembly/WASI/blob/main/legacy/optional-imports.md)
  and maybe [conditional-sections](https://github.com/WebAssembly/conditional-sections/issues/22))



[Structure Section]: https://webassembly.github.io/spec/core/syntax/index.html
[Text Format Section]: https://webassembly.github.io/spec/core/text/index.html
[Binary Format Section]: https://webassembly.github.io/spec/core/binary/index.html
[Core Indices]: https://webassembly.github.io/spec/core/syntax/modules.html#indices
[Core Identifiers]: https://webassembly.github.io/spec/core/text/values.html#text-id

[Index Space]: https://webassembly.github.io/spec/core/syntax/modules.html#indices
[Abbreviations]: https://webassembly.github.io/spec/core/text/conventions.html#abbreviations

[`core:name`]: https://webassembly.github.io/spec/core/syntax/values.html#syntax-name
[`core:module`]: https://webassembly.github.io/spec/core/text/modules.html#text-module
[`core:type`]: https://webassembly.github.io/spec/core/text/modules.html#types
[`core:importdesc`]: https://webassembly.github.io/spec/core/text/modules.html#text-importdesc
[`core:externtype`]: https://webassembly.github.io/spec/core/syntax/types.html#external-types
[`core:valtype`]: https://webassembly.github.io/spec/core/text/types.html#value-types
[`core:typeuse`]: https://webassembly.github.io/spec/core/text/modules.html#type-uses
[`core:functype`]: https://webassembly.github.io/spec/core/text/types.html#function-types
[func-import-abbrev]: https://webassembly.github.io/spec/core/text/modules.html#text-func-abbrev
[`core:version`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-version

[Embedding]: https://webassembly.github.io/spec/core/appendix/embedding.html
[`module_instantiate`]: https://webassembly.github.io/spec/core/appendix/embedding.html#mathrm-module-instantiate-xref-exec-runtime-syntax-store-mathit-store-xref-syntax-modules-syntax-module-mathit-module-xref-exec-runtime-syntax-externval-mathit-externval-ast-xref-exec-runtime-syntax-store-mathit-store-xref-exec-runtime-syntax-moduleinst-mathit-moduleinst-xref-appendix-embedding-embed-error-mathit-error
[`func_invoke`]: https://webassembly.github.io/spec/core/appendix/embedding.html#mathrm-func-invoke-xref-exec-runtime-syntax-store-mathit-store-xref-exec-runtime-syntax-funcaddr-mathit-funcaddr-xref-exec-runtime-syntax-val-mathit-val-ast-xref-exec-runtime-syntax-store-mathit-store-xref-exec-runtime-syntax-val-mathit-val-ast-xref-appendix-embedding-embed-error-mathit-error
[`func_alloc`]: https://webassembly.github.io/spec/core/appendix/embedding.html#mathrm-func-alloc-xref-exec-runtime-syntax-store-mathit-store-xref-syntax-types-syntax-functype-mathit-functype-xref-exec-runtime-syntax-hostfunc-mathit-hostfunc-xref-exec-runtime-syntax-store-mathit-store-xref-exec-runtime-syntax-funcaddr-mathit-funcaddr

[`WebAssembly.instantiate()`]: https://developer.mozilla.org/en-US/docs/WebAssembly/JavaScript_interface/instantiate
[`FinalizationRegistry`]: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/FinalizationRegistry
[Fetching]: https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API
[base URL]: https://developer.mozilla.org/en-US/docs/Web/API/URL/URL
[`integrity-metadata`]: https://www.w3.org/TR/SRI/#the-integrity-attribute
[Semantic Versioning 2.0]: https://semver.org/spec/v2.0.0.html
[Delimit The URL]: https://www.rfc-editor.org/rfc/rfc3986#appendix-C

[JS API]: https://webassembly.github.io/spec/js-api/index.html
[*read the imports*]: https://webassembly.github.io/spec/js-api/index.html#read-the-imports
[*create an exports object*]: https://webassembly.github.io/spec/js-api/index.html#create-an-exports-object
[Interface Object]: https://webidl.spec.whatwg.org/#interface-object
[`ToJSValue`]: https://webassembly.github.io/spec/js-api/index.html#tojsvalue
[`ToWebAssemblyValue`]: https://webassembly.github.io/spec/js-api/index.html#towebassemblyvalue
[`USVString`]: https://webidl.spec.whatwg.org/#es-USVString
[`sequence`]: https://webidl.spec.whatwg.org/#es-sequence
[`dictionary`]: https://webidl.spec.whatwg.org/#es-dictionary
[`enum`]: https://webidl.spec.whatwg.org/#es-enumeration
[`T?`]: https://webidl.spec.whatwg.org/#es-nullable-type
[`Get`]: https://tc39.es/ecma262/#sec-get-o-p
[Import Reflection]: https://github.com/tc39-transfer/proposal-import-reflection
[Module Record]: https://tc39.es/ecma262/#sec-abstract-module-records
[Module Specifier]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ModuleSpecifier
[Named Imports]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-NamedImports
[Imported Default Binding]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ImportedDefaultBinding
[JS Tuple]: https://github.com/tc39/proposal-record-tuple
[JS Record]: https://github.com/tc39/proposal-record-tuple
[Internal Slot]: https://tc39.es/ecma262/#sec-object-internal-methods-and-internal-slots
[Built-in Modules]: https://github.com/tc39/proposal-built-in-modules

[Kebab Case]: https://en.wikipedia.org/wiki/Letter_case#Kebab_case
[De Bruijn Index]: https://en.wikipedia.org/wiki/De_Bruijn_index
[Closure]: https://en.wikipedia.org/wiki/Closure_(computer_programming)
[Empty Type]: https://en.wikipedia.org/w/index.php?title=Empty_type
[IEEE754]: https://en.wikipedia.org/wiki/IEEE_754
[Unicode Scalar Values]: https://unicode.org/glossary/#unicode_scalar_value
[Tuples]: https://en.wikipedia.org/wiki/Tuple
[Tagged Unions]: https://en.wikipedia.org/wiki/Tagged_union
[Sequences]: https://en.wikipedia.org/wiki/Sequence
[ABI]: https://en.wikipedia.org/wiki/Application_binary_interface
[Environment Variables]: https://en.wikipedia.org/wiki/Environment_variable
[Linear]: https://en.wikipedia.org/wiki/Substructural_type_system#Linear_type_systems
[Interface Definition Language]: https://en.wikipedia.org/wiki/Interface_description_language
[Subtyping]: https://en.wikipedia.org/wiki/Subtyping
[Universal Types]: https://en.wikipedia.org/wiki/System_F
[Existential Types]: https://en.wikipedia.org/wiki/System_F

[Generative]: https://www.researchgate.net/publication/2426300_A_Syntactic_Theory_of_Type_Generativity_and_Sharing
[Avoidance Problem]: https://counterexamples.org/avoidance.html
[Non-Parametric Parametricity]: https://people.mpi-sws.org/~dreyer/papers/npp/main.pdf

[module-linking]: https://github.com/WebAssembly/module-linking/blob/main/proposals/module-linking/Explainer.md
[interface-types]: https://github.com/WebAssembly/interface-types/blob/main/proposals/interface-types/Explainer.md
[type-imports]: https://github.com/WebAssembly/proposal-type-imports/blob/master/proposals/type-imports/Overview.md
[exception-handling]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md
[stack-switching]: https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Overview.md
[esm-integration]: https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration
[gc]: https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md
[WASI Preview 2]: https://github.com/WebAssembly/WASI/tree/main/preview2

[Adapter Functions]: FutureFeatures.md#custom-abis-via-adapter-functions
[Canonical ABI]: CanonicalABI.md
[Shared-Nothing]: ../high-level/Choices.md
[Use Cases]: ../high-level/UseCases.md
[Host Embeddings]: ../high-level/UseCases.md#hosts-embedding-components

[Component Model Documentation]: https://component-model.bytecodealliance.org
[`wizer`]: https://github.com/bytecodealliance/wizer
[`warg`]: https://warg.io
[SemVerRange]: https://semver.npmjs.com/
[OCI Registry]: https://github.com/opencontainers/distribution-spec

[Scoping and Layering]: https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8
[Future and Stream Types]: https://docs.google.com/presentation/d/1MNVOZ8hdofO3tI0szg_i-Yoy0N2QPU2C--LzVuoGSlE
