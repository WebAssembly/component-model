# Component Model AST Explainer

This explainer walks through the grammar of a [component](../high-level) and
the proposed embedding of components into native JavaScript runtimes. For a
more user-focused explanation, take a look at the
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
      * [Error Context type](#-error-context-type)
      * [Container types](#container-types)
      * [Handle types](#handle-types)
      * [Asynchronous value types](#asynchronous-value-types)
    * [Specialized value types](#specialized-value-types)
    * [Definition types](#definition-types)
    * [Declarators](#declarators)
    * [Type checking](#type-checking)
  * [Canonical definitions](#canonical-definitions)
    * [Canonical ABI](#canonical-abi)
    * [Canonical built-ins](#canonical-built-ins)
      * [Resource built-ins](#resource-built-ins)
      * [Async built-ins](#-async-built-ins)
      * [Error Context built-ins](#-error-context-built-ins)
      * [Threading built-ins](#-threading-built-ins)
  * [Value definitions](#-value-definitions)
  * [Start definitions](#-start-definitions)
  * [Import and export definitions](#import-and-export-definitions)
    * [Name uniqueness](#name-uniqueness)
* [Component invariants](#component-invariants)
* [JavaScript embedding](#JavaScript-embedding)
  * [JS API](#JS-API)
  * [ESM-integration](#ESM-integration)
* [Examples](#examples)

## Gated Features

By default, the features described in this explainer (as well as the supporting
[Binary.md](Binary.md), [WIT.md](WIT.md) and [CanonicalABI.md](CanonicalABI.md))
have been implemented and are included in the [WASI Preview 2] stability
milestone. Features that are not part of Preview 2 are demarcated by one of the
emoji symbols listed below; these emojis will be removed once they are
implemented, considered stable and included in a future milestone:
* 🪙: value imports/exports and component-level start function
* 🪺: nested namespaces and packages in import/export names
* 🔀: async
  * 🚝: marking some builtins as `async`
  * 🚟: using `async` with `canon lift` without `callback` (stackful lift)
* 🧵: threading built-ins
* 🔧: fixed-length lists
* 📝: the `error-context` type

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
             | <value> 🪙

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
The next production, `core:instance`, is not currently included in Core
WebAssembly, but would be if Core WebAssembly adopted the [module-linking]
proposal. This new core definition is introduced below, alongside its
component-level counterpart. Finally, the existing [`core:type`] production is
extended below to add core module types as proposed for module-linking. Thus,
the overall idea is to represent core definitions (in the AST, binary and text
format) as-if they had already been added to Core WebAssembly so that, if they
eventually are, the implementation of decoding and validation can be shared in
a layered fashion.

The next kind of definition is, recursively, a component itself. Thus,
components form trees with all other kinds of definitions only appearing at the
leaves. For example, with what's defined so far, we can write the following
component:
```wat
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
```wat
(component
  (core module (; empty ;))
  (component   (; empty ;))
  (core module (; empty ;))
  (export "C" (component 0))
  (export "M1" (core module 0))
  (export "M2" (core module 1))
)
```
```wat
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
create module or component instances by selecting a module or component to
**instantiate** and then supplying a set of named *arguments* which satisfy all
the named *imports* of the selected module or component. This low-level
instantiation mechanism allows the Component Model to simultaneously support
multiple different styles of traditional [linking](Linking.md).

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
```wat
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
instantiatearg ::= (with <name> <sortidx>)
                 | (with <name> (instance <inlineexport>*))
name           ::= <core:name>
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

The `name` production reuses the `core:name` quoted-string-literal syntax of
Core WebAssembly (which appears in core module imports and exports and can
contain any valid UTF-8 string).

🪙 The `value` sort refers to a value that is provided and consumed during
instantiation. How this works is described in the
[value definitions](#value-definitions) section.

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
aliastarget      ::= export <instanceidx> <name>
                   | core export <core:instanceidx> <core:name>
                   | outer <u32> <u32>
```
If present, the `id` of the alias is bound to the new index added by the alias
and can be used anywhere a normal `id` can be used.

In the case of `export` aliases, validation ensures `name` is an export in the
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
inlinealias ::= (<sort> <u32> <name>+)
```
If `<sort>` refers to a `<core:sort>`, then the `<u32>` of `inlinealias` is a
`<core:instanceidx>`; otherwise it's an `<instanceidx>`. For example, the
following snippet uses two inline function aliases:
```wat
(instance $j (instantiate $J (with "f" (func $i "f"))))
(export "x" (func $j "g" "h"))
```
which are desugared into:
```wat
(alias export $i "f" (func $f_alias))
(instance $j (instantiate $J (with "f" (func $f_alias))))
(alias export $j "g" (instance $g_alias))
(alias export $g_alias "h" (func $h_alias))
(export "x" (func $h_alias))
```

For `outer` aliases, the inline sugar is simply the identifier of the outer
definition, resolved using normal lexical scoping rules. For example, the
following component:
```wat
(component
  (component $C ...)
  (component
    (instance (instantiate $C))
  )
)
```
is desugared into:
```wat
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
```wat
    (func $f (import "i" "f") ...type...) ≡ (import "i" "f" (func $f ...type...))   (WebAssembly 1.0)
          (func $f (alias export $i "f")) ≡ (alias export $i "f" (func $f))
   (core module $m (alias export $i "m")) ≡ (alias export $i "m" (core module $m))
(core func $f (alias core export $i "f")) ≡ (alias core export $i "f" (core func $f))
```

With what's defined so far, we're able to link modules with arbitrary renamings:
```wat
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
core:rectype     ::= ... from the Core WebAssembly spec
core:typedef     ::= ... from the Core WebAssembly spec
core:subtype     ::= ... from the Core WebAssembly spec
core:comptype    ::= ... from the Core WebAssembly spec
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

Here, `core:comptype` (short for "composite type") as defined in the [GC]
proposal is extended with a `module` type constructor. The GC proposal also
adds recursion and explicit subtyping between core wasm types. Owing to
their different requirements and intended modes of usage, module types
support implicit subtyping and are not recursive. Thus, the existing core
validation rules would require the declared supertypes of module types to be
empty and disallow recursive use of module types.

In the MVP, validation will also reject `core:moduletype` defining or aliasing
other `core:moduletype`s, since, before module-linking, core modules cannot
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
```wat
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
`core:alias` module declarators to *only* allow `outer` `type` aliases (into an
enclosing component's or component-type's core type index space). In the
future, more kinds of aliases would be meaningful and allowed.

As an example, the following component defines two semantically-equivalent
module types, where the former defines the function type via `type` declarator
and the latter refers via `alias` declarator.
```wat
(component $C
  (core type $C1 (module
    (type (func (param i32) (result i32)))
    (import "a" "b" (func (type 0)))
    (export "c" (func (type 0)))
  ))
  (core type $F (func (param i32) (result i32)))
  (core type $C2 (module
    (alias outer $C $F (type))
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
                | f32 | f64
                | char | string
                | error-context 📝
                | (record (field "<label>" <valtype>)+)
                | (variant (case "<label>" <valtype>?)+)
                | (list <valtype>)
                | (list <valtype> <u32>) 🔧
                | (tuple <valtype>+)
                | (flags "<label>"+)
                | (enum "<label>"+)
                | (option <valtype>)
                | (result <valtype>? (error <valtype>)?)
                | (own <typeidx>)
                | (borrow <typeidx>)
                | (stream <typeidx>?) 🔀
                | (future <typeidx>?) 🔀
valtype       ::= <typeidx>
                | <defvaltype>
resourcetype  ::= (resource (rep i32) (dtor async? <funcidx> (callback <funcidx>)?)?)
functype      ::= (func (param "<label>" <valtype>)* (result <valtype>)?)
componenttype ::= (component <componentdecl>*)
instancetype  ::= (instance <instancedecl>*)
componentdecl ::= <importdecl>
                | <instancedecl>
instancedecl  ::= core-prefix(<core:type>)
                | <type>
                | <alias>
                | <exportdecl>
                | <value> 🪙
importdecl    ::= (import <importname> bind-id(<externdesc>))
exportdecl    ::= (export <exportname> bind-id(<externdesc>))
externdesc    ::= (<sort> (type <u32>) )
                | core-prefix(<core:moduletype>)
                | <functype>
                | <componenttype>
                | <instancetype>
                | (value <valuebound>) 🪙
                | (type <typebound>)
typebound     ::= (eq <typeidx>)
                | (sub resource)
valuebound    ::= (eq <valueidx>) 🪙
                | <valtype> 🪙

where bind-id(X) parses '(' sort <id>? Y ')' when X parses '(' sort Y ')'
```
Because there is nothing in this type grammar analogous to the [gc] proposal's
[`rectype`], none of these types are recursive.

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
| `f32`, `f64`              | [IEEE754] floating-point numbers, with a single NaN value |
| `char`                    | [Unicode Scalar Values] |
| `error-context` 📝        | an immutable, non-deterministic, host-defined value meant to aid in debugging |
| `record`                  | heterogeneous [tuples] of named values |
| `variant`                 | heterogeneous [tagged unions] of named values |
| `list`                    | homogeneous, variable- or fixed-length [sequences] of values |
| `own`                     | a unique, opaque address of a resource that will be destroyed when this value is dropped |
| `borrow`                  | an opaque address of a resource that must be dropped before the current export call returns |
| `stream` 🔀               | an asynchronously-passed list of homogeneous values |
| `future` 🔀               | an asynchronously-passed single value |

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

##### 📝 Error Context type

Values of `error-context` type are immutable, non-deterministic, host-defined
and meant to be propagated from failure sources to callers in order to aid in
debugging. Currently `error-context` values contain only a "debug message"
string whose contents are determined by the host. Core wasm can create
`error-context` values given a debug string, but the host is free to
arbitrarily transform (discard, preserve, prefix or suffix) this
wasm-provided string. In the future, `error-context` could be enhanced with
other additional or more-structured context (like a backtrace or a chain of
originating error contexts).

The intention of this highly-non-deterministic semantics is to provide hosts
the full range of flexibility to:
* append a basic callstack suitable for forensic debugging in production;
* optimize for performance in high-volume production scenarios by slicing or
  discarding debug messages;
* optimize for developer experience in debugging scenarios when debug metadata
  is present by appending expensive-to-produce symbolicated callstacks.

A consequence of this, however, is that components *must not* depend on the
contents of `error-context` values for behavioral correctness. In particular,
case analysis of the contents of an `error-context` should not determine
*error recovery*; explicit `result` or `variant` types must be used in the
function return type instead (e.g.,
`(func (result (tuple (stream u8) (future $my-error)))`).

##### Container types

The `record`, `variant`, and `list` types allow for grouping, categorizing,
and sequencing contained values.

🔧 When the optional `<u32>` immediate of the `list` type constructor is present,
the list has a fixed length and the representation of the list in memory is
specialized to this length.

##### Handle types

The `own` and `borrow` value types are both *handle types*. Handles logically
contain the opaque address of a resource and avoid copying the resource when
passed across component boundaries. By way of metaphor to operating systems,
handles are analogous to file descriptors, which are stored in a table and may
only be used indirectly by untrusted user-mode processes via their integer
index in the table.

In the Component Model, handles are lifted-from and lowered-into `i32` values
that index an encapsulated per-component-instance *handle table* that is
maintained by the canonical function definitions described
[below](#canonical-definitions). In the future, handles could be
backwards-compatibly lifted and lowered from [reference types]  (via the
addition of a new `canonopt`, as introduced [below](#canonical-abi)).

The uniqueness and dropping conditions mentioned above are enforced at runtime
by the Component Model through these canonical definitions. The `typeidx`
immediate of a handle type must refer to a `resource` type (described below)
that statically classifies the particular kinds of resources the handle can
point to.

##### Asynchronous value types

The `stream` and `future` value types are both *asynchronous value types* that
are used to deliver values incrementally over the course of a single async
function call, instead of copying the values all-at-once as with other
(synchronous) value types like `list`. The mechanism for performing these
incremental copies avoids the need for intermediate buffering inside the
`stream` or `future` value itself and instead uses buffers of memory whose
size and allocation is controlled by the core wasm in the source and
destination components. Thus, in the abstract, `stream` and `future` can be
thought of as inter-component control-flow or synchronization mechanisms.

Just like with handles, in the Component Model, async value types are
lifted-from and lowered-into `i32` values that index an encapsulated
per-component-instance table that is maintained by the canonical ABI built-ins
[below](#canonical-definitions). The Component-Model-defined ABI for creating,
writing-to and reading-from `stream` and `future` values is meant to be bound
to analogous source-language features like promises, futures, streams,
iterators, generators and channels so that developers can use these familiar
high-level concepts when working directly with component types, without the
need to manually write low-level async glue code. For languages like C without
language-level concurrency support, these ABIs (described in detail in the
[Canonical ABI explainer]) can be exposed directly as function imports and used
like normal low-level Operation System I/O APIs.

A `stream<T>` asynchronously passes zero or more `T` values in one direction
between a source and destination, batched in chunks for efficiency. Streams
are useful for:
* improving latency by incrementally processing values as they arrive;
* delivering potentially-large lists of values that might OOM wasm if passed
  as a `list<T>`;
* long-running or infinite streams of events.

A `future` is a special case of `stream` and (in non-error scenarios) delivers
exactly one value before being automatically closed. Because all imports can
be [called asynchronously](Async.md), futures are not necessary to express a
traditional `async` function -- all functions are effectively `async`. Instead
futures are useful in more advanced scenarios where a parameter or result
value may not be ready at the same time as the other synchronous parameters or
results.

The `T` element type of `stream` and `future` is an optional `valtype`. As with
variant-case payloads and function results, when `T` is absent, the "value(s)"
being asynchronously passed can be thought of as [unit] values. In such cases,
there is no representation of the value in Core WebAssembly (pointers into
linear memory are ignored) however the *timing* of completed reads and writes
and the number of elements they contain are observable and meaningful. Thus, empty futures and streams can be useful for
timing-related APIs.

Currently, validation rejects `(stream T)` and `(future T)` when `T`
transitively contains a `borrow`. This restriction could be relaxed in the
future by extending the call-scoping rules of `borrow` to streams and futures.

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

Specialized value types have the same set of semantic values as their
corresponding despecialized types, but have distinct type constructors
(which are not type-equal to the unspecialized type constructors) and
thus have distinct binary encodings. This allows specialized value types to
convey a more specific intent. For example, `result` isn't just a variant,
it's a variant that *means* success or failure, so source-code bindings
can expose it via idiomatic source-language error reporting. Additionally,
this can sometimes allow values to be represented differently. For example,
`string` in the Canonical ABI uses various Unicode encodings while
`list<char>` uses a sequence of 4-byte `char` code points.  Similarly,
`flags` in the Canonical ABI uses a bit-vector while an equivalent record
of boolean fields uses a sequence of boolean-valued bytes.

Note that, at least initially, variants are required to have a non-empty list of
cases. This could be relaxed in the future to allow an empty list of cases, with
the empty `(variant)` effectively serving as an [empty type] and indicating
unreachability.

#### Definition types

The remaining 4 type constructors in `deftype` use `valtype` to describe
shared-nothing functions, resources, components, and component instances:

The `func` type constructor describes a component-level function definition
that takes a list of `valtype` parameters with [strongly-unique] names and
optionally returns a `valtype`.

The `resource` type constructor creates a fresh type for each instance of the
containing component (with "freshness" and its interaction with general
type-checking described in more detail [below](#type-checking)). Resource types
can be referred to by handle types (such as `own` and `borrow`) as well as the
canonical built-ins described [below](#canonical-built-ins). The `rep`
immediate of a `resource` type specifies its *core representation type*, which
is currently fixed to `i32`, but will be relaxed in the future (to at least
include `i64`, but also potentially other types). When the last handle to a
resource is dropped, the resource's destructor function specified by the `dtor`
immediate will be called (if present), allowing the implementing component to
perform clean-up like freeing linear memory allocations. Destructors can be
declared `async`, with the same meaning for the `async` and `callback`
immediates as described below for `canon lift`.

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
[value definitions](#value-definitions) section below.

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
```wat
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
definitions, thereby preventing "private" resource type definitions from
appearing in component types and avoiding the [avoidance problem]. Thus, the
only resource types possible in an `instancetype` or `componenttype` are
introduced by `importdecl` or `exportdecl`.

With what's defined so far, we can define component types using a mix of type
definitions:
```wat
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
    (export "T2" (type $T' (eq $T)))
    (export "U" (type $U' (sub resource)))
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
```wat
(component $A
  (type $ListString1 (list string))
  (type $ListListString1 (list $ListString1))
  (type $ListListString2 (list $ListString1))
  (component $B
    (type $ListString2 (list string))
    (type $ListListString3 (list $ListString2))
    (type $ListString3 (alias outer $A $ListString1))
    (type $ListListString4 (list $ListString3))
    (type $ListListString5 (alias outer $A $ListListString1))
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
subtype-compatible updates don't inadvertently break source-level clients).

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
```wat
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
```wat
(component
  (import "T1" (type $T1 (sub resource)))
  (import "T2" (type $T2 (sub resource)))
)
```
the types `$T1` and `$T2` are not equal.

Once a type is imported, it can be referred to by subsequent equality-bound
type imports, thereby adding more types that it is equal to. For example, in
the following component:
```wat
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
```wat
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
```wat
(component
  (import "C" (component $C
    (export "T1" (type (sub resource)))
    (export "T2" (type $T2 (sub resource)))
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
```wat
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
```wat
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
```wat
(component
  (type $r (resource (rep i32)))
  (export "r1" (type $r))
  (export "r2" (type $r))
)
```
is assigned the following `componenttype`:
```wat
(component
  (export "r1" (type $r1 (sub resource)))
  (export "r2" (type (eq $r1)))
)
```
Thus, from an external perspective, `r1` and `r2` are two labels for the same
type.

If a component wants to hide this fact and force clients to assume `r1` and
`r2` are distinct types (thereby allowing the implementation to actually use
separate types in the future without breaking clients), an explicit type can be
ascribed to the export that replaces the `eq` bound with a less-precise `sub`
bound (using syntax introduced [below](#import-and-export-definitions)).
```wat
(component
  (type $r (resource (rep i32)))
  (export "r1" (type $r))
  (export "r2" (type $r) (type (sub resource)))
)
```
This component is assigned the following `componenttype`:
```wat
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
```wat
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
the child at validation- or run-time. In particular, there are no runtime
casts that can "see through" to the original type parameter, avoiding
avoiding the usual [type-exposure problems with dynamic casts][non-parametric parametricity].

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
Component Model is an [embedder]. As such, the Component Model defines the
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
           | async 🔀
           | (callback <core:funcidx>) 🔀
           | always-task-return 🔀
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
default is `utf8`. It is a validation error to include more than one
`string-encoding` option.

The `(memory ...)` option specifies the memory that the Canonical ABI will
use to load and store values. If the Canonical ABI needs to load or store,
validation requires this option to be present (there is no default).

The `(realloc ...)` option specifies a core function that is validated to
have the following core function type:
```wat
(func (param $originalPtr i32)
      (param $originalSize i32)
      (param $alignment i32)
      (param $newSize i32)
      (result i32))
```
The Canonical ABI will use `realloc` both to allocate (passing `0` for the
first two parameters) and reallocate. If the Canonical ABI needs `realloc`,
validation requires this option to be present (there is no default).

The `(post-return ...)` option may only be present in `canon lift` when
`async` is not present and specifies a core function to be called with the
original return values after they have finished being read, allowing memory to
be deallocated and destructors called. This immediate is always optional but,
if present, is validated to have parameters matching the callee's return type
and empty results.

🔀 The `async` option specifies that the component wants to make (for imports)
or support (for exports) multiple concurrent (asynchronous) calls. This option
can be applied to any component-level function type and changes the derived
Canonical ABI significantly. See the [async explainer](Async.md) for more
details. When a function signature contains a `future` or `stream`, validation
of `canon lower` requires the `async` option to be set (since a synchronous
call to a function using these types is highly likely to deadlock).

🔀 The `(callback ...)` option may only be present in `canon lift` when the
`async` option has also been set and specifies a core function that is
validated to have the following core function type:
```wat
(func (param $ctx i32)
      (param $event i32)
      (param $payload i32)
      (result $done i32))
```
Again, see the [async explainer](Async.md) for more details.

🔀 The `always-task-return` option may only be present in `canon lift` when
`post-return` is not set and specifies that even synchronously-lifted functions
will call `canon task.return` to return their results instead of returning
them as core function results. This is a simpler alternative to `post-return`
for freeing memory after lifting and thus `post-return` may be deprecated in
the future.

Based on this description of the AST, the [Canonical ABI explainer] gives a
detailed walkthrough of the static and dynamic semantics of `lift` and `lower`.

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
```wat
(func $f (import "i" "f") ...type...) ≡ (import "i" "f" (func $f ...type...))       (WebAssembly 1.0)
(func $g ...type... (canon lift ...)) ≡ (canon lift ... (func $g ...type...))
(core func $h (canon lower ...))      ≡ (canon lower ... (core func $h))
```
Note: in the future, `canon` may be generalized to define other sorts than
functions (such as types), hence the explicit `sort`.

Using canonical function definitions, we can finally write a non-trivial
component that takes a string, does some logging, then returns a string.
```wat
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
dynamically interact with Canonical ABI entities like resources and
[tasks][Future and Stream Types] 🔀.
```ebnf
canon ::= ...
        | (canon resource.new <typeidx> (core func <id>?))
        | (canon resource.drop <typeidx> async? (core func <id>?))
        | (canon resource.rep <typeidx> (core func <id>?))
        | (canon context.get <valtype> <u32> (core func <id>?)) 🔀
        | (canon context.set <valtype> <u32> (core func <id>?)) 🔀
        | (canon backpressure.set (core func <id>?)) 🔀
        | (canon task.return (result <valtype>)? <canonopt>* (core func <id>?)) 🔀
        | (canon yield async? (core func <id>?)) 🔀
        | (canon waitable-set.new (core func <id>?)) 🔀
        | (canon waitable-set.wait async? (memory <core:memidx>) (core func <id>?)) 🔀
        | (canon waitable-set.poll async? (memory <core:memidx>) (core func <id>?)) 🔀
        | (canon waitable-set.drop (core func <id>?)) 🔀
        | (canon waitable.join (core func <id>?)) 🔀
        | (canon subtask.drop (core func <id>?)) 🔀
        | (canon stream.new <typeidx> (core func <id>?)) 🔀
        | (canon stream.read <typeidx> <canonopt>* (core func <id>?)) 🔀
        | (canon stream.write <typeidx> <canonopt>* (core func <id>?)) 🔀
        | (canon stream.cancel-read <typeidx> async? (core func <id>?)) 🔀
        | (canon stream.cancel-write <typeidx> async? (core func <id>?)) 🔀
        | (canon stream.close-readable <typeidx> (core func <id>?)) 🔀
        | (canon stream.close-writable <typeidx> (core func <id>?)) 🔀
        | (canon future.new <typeidx> (core func <id>?)) 🔀
        | (canon future.read <typeidx> <canonopt>* (core func <id>?)) 🔀
        | (canon future.write <typeidx> <canonopt>* (core func <id>?)) 🔀
        | (canon future.cancel-read <typeidx> async? (core func <id>?)) 🔀
        | (canon future.cancel-write <typeidx> async? (core func <id>?)) 🔀
        | (canon future.close-readable <typeidx> (core func <id>?)) 🔀
        | (canon future.close-writable <typeidx> (core func <id>?)) 🔀
        | (canon error-context.new <canonopt>* (core func <id>?)) 📝
        | (canon error-context.debug-message <canonopt>* (core func <id>?)) 📝
        | (canon error-context.drop (core func <id>?)) 📝
        | (canon thread.spawn_ref <typeidx> (core func <id>?)) 🧵
        | (canon thread.spawn_indirect <typeidx> <core:tableidx> (core func <id>?)) 🧵
        | (canon thread.available_parallelism (core func <id>?)) 🧵
```

##### Resource built-ins

###### `resource.new`

| Synopsis                   |                            |
| -------------------------- | -------------------------- |
| Approximate WIT signature  | `func<T>(rep: T.rep) -> T` |
| Canonical ABI signature    | `[rep:i32] -> [i32]`       |

The `resource.new` built-in creates a new resource (of resource type `T`) with
`rep` as its representation, and returns a new handle pointing to the new
resource. Validation only allows `resource.rep T` to be used within the
component that defined `T`.

In the Canonical ABI, `T.rep` is defined to be the `$rep` in the
`(type $T (resource (rep $rep) ...))` type definition that defined `T`. While
it's designed to allow different types in the future, it is currently
hard-coded to always be `i32`.

(See also [`canon_resource_new`] in the Canonical ABI explainer.)

###### `resource.drop`

When the `async` immediate is false:

| Synopsis                   |                                    |
| -------------------------- | ---------------------------------- |
| Approximate WIT signature  | `func<T>(t: T)`                    |
| Canonical ABI signature    | `[t:i32] -> []`                    |

When the `async` immediate is true:

| Synopsis                   |                                    |
| -------------------------- | ---------------------------------- |
| Approximate WIT signature  | `func<T>(t: T) -> option<subtask>` |
| Canonical ABI signature    | `[t:i32] -> [i32]`                 |

The `resource.drop` built-in drops a resource handle `t` (with resource type
`T`). If the dropped handle owns the resource, the resource's `dtor` is called,
if present. Validation only allows `resource.rep T` to be used within the
component that defined `T`.

When the `async` immediate is true, the returned value indicates whether the
drop completed eagerly, or if not, identifies the in-progress drop.

In the Canonical ABI, the returned `i32` is either `0` (if the drop completed
eagerly) or the index of the in-progress drop subtask (representing the
in-progress `dtor` call). (See also [`canon_resource_drop`] in the Canonical
ABI explainer.)

###### `resource.rep`

| Synopsis                   |                          |
| -------------------------- | ------------------------ |
| Approximate WIT signature  | `func<T>(t: T) -> T.rep` |
| Canonical ABI signature    | `[t:i32] -> [i32]`       |

The `resource.rep` built-in returns the representation of the resource (with
resource type `T`) pointed to by the handle `t`. Validation only allows
`resource.rep T` to be used within the component that defined `T`.

In the Canonical ABI, `T.rep` is defined to be the `$rep` in the
`(type $T (resource (rep $rep) ...))` type definition that defined `T`. While
it's designed to allow different types in the future, it is currently
hard-coded to always be `i32`.

As an example, the following component imports the `resource.new` built-in,
allowing it to create and return new resources to its client:
```wat
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
(See also [`canon_resource_rep`] in the Canonical ABI explainer.)

##### 🔀 Async built-ins

See the [async explainer](Async.md) for high-level context and terminology and
the [Canonical ABI explainer] for detailed runtime semantics.

###### 🔀 `context.get`

| Synopsis                   |                    |
| -------------------------- | ------------------ |
| Approximate WIT signature  | `func<T,i>() -> T` |
| Canonical ABI signature    | `[] -> [T]`        |

The `context.get` built-in returns the `i`th element of the [current task]'s
[context-local storage] array. Validation currently restricts `i` to be less
than 2 and `t` to be `i32`, but will be relaxed in the future (as described
[here][context-local storage]). (See also [`canon_context_get`] in the
Canonical ABI explainer for details.)

###### 🔀 `context.set`

| Synopsis                   |                   |
| -------------------------- | ----------------- |
| Approximate WIT signature  | `func<T,i>(v: T)` |
| Canonical ABI signature    | `[T] -> []`       |

The `context.set` built-in sets the `i`th element of the [current task]'s
[context-local storage] array to the value `v`. Validation currently
restricts `i` to be less than 2 and `t` to be `i32`, but will be relaxed in the
future (as described [here][context-local storage]). (See also
[`canon_context_set`] in the Canonical ABI explainer for details.)

###### 🔀 `backpressure.set`

| Synopsis                   |                       |
| -------------------------- | --------------------- |
| Approximate WIT signature  | `func(enable: bool)`  |
| Canonical ABI signature    | `[enable:i32] -> []`  |

The `backpressure.set` built-in allows the async-lifted callee to toggle a
per-component-instance flag that, when set, prevents new incoming export calls
to the component (until the flag is unset). This allows the component to exert
[backpressure]. (See also [`canon_backpressure_set`] in the Canonical ABI
explainer for details.)

###### 🔀 `task.return`

The `task.return` built-in takes as parameters the result values of the
currently-executing task. This built-in must be called exactly once per export
activation. The `canon task.return` definition takes component-level return
type and the list of `canonopt` to be used to lift the return value. When
called, the declared return type and the `string-encoding` and `memory`
`canonopt`s are checked to exactly match those of the current task. (See also
"[Returning]" in the async explainer and [`canon_task_return`] in the Canonical
ABI explainer.)

###### 🔀 `yield`

| Synopsis                   |                    |
| -------------------------- | ------------------ |
| Approximate WIT signature  | `func<async?>()`   |
| Canonical ABI signature    | `[] -> []`         |

The `yield` built-in allows the runtime to switch to other tasks, enabling a
long-running computation to cooperatively interleave execution. If the `async`
immediate is present, the runtime can switch to other tasks in the *same*
component instance, which the calling core wasm must be prepared to handle. If
`async` is not present, only tasks in *other* component instances may be
switched to. (See also [`canon_yield`] in the Canonical ABI explainer for
details.)

###### 🔀 `waitable-set.new`

| Synopsis                   |                          |
| -------------------------- | ------------------------ |
| Approximate WIT signature  | `func() -> waitable-set` |
| Canonical ABI signature    | `[] -> [i32]`            |

The `waitable-set.new` built-in returns the `i32` index of a new [waitable
set]. The `waitable-set` type is not a true WIT-level type but instead serves
to document associated built-ins below. Waitable sets start out empty and are
populated explicitly with [waitables] by `waitable.join`. (See also
[`canon_waitable_set_new`] in the Canonical ABI explainer for details.)

###### 🔀 `waitable-set.wait`

| Synopsis                   |                                                |
| -------------------------- | ---------------------------------------------- |
| Approximate WIT signature  | `func<async?>(s: waitable-set) -> event`       |
| Canonical ABI signature    | `[s:i32 payload-addr:i32] -> [event-code:i32]` |

where `event`, `event-code`, and `payload` are defined in WIT as:
```wit
record event {
    kind: event-code,
    payload: payload,
}
enum event-code {
    none,
    call-starting,
    call-started,
    call-returned,
    stream-read,
    stream-write,
    future-read,
    future-write,
}
record payload {
    payload1: u32,
    payload2: u32,
}
```

The `waitable-set.wait` built-in waits for any one of the [waitables] in the
given [waitable set] `s` to make progress and then returns an `event`
describing the event. The `event-code` `none` is never returned. Waitable sets
may be `wait`ed upon when empty, in which case the caller will necessarily
block until another task adds a waitable to the set that can make progress.

If the `async` immediate is present, other tasks in the same component instance
can be started (via export call) or resumed while the current task blocks. If
`async` is not present, the current component instance will not execute any
code until `wait` returns (however, *other* component instances may execute
code in the interim).

In the Canonical ABI, the return value provides the `event-code`, and the
`payload` value is stored at the address passed as the `payload-addr`
parameter. (See also [`canon_waitable_set_wait`] in the Canonical ABI explainer
for details.)

###### 🔀 `waitable-set.poll`

| Synopsis                   |                                                |
| -------------------------- | ---------------------------------------------- |
| Approximate WIT signature  | `func<async?>(s: waitable-set) -> event`       |
| Canonical ABI signature    | `[s:i32 payload-addr:i32] -> [event-code:i32]` |

where `event`, `event-code`, and `payload` are defined as in
[`waitable-set.wait`](#-waitable-setwait).

The `waitable-set.poll` built-in returns the `event-code` `none` if no event
was available without blocking. `poll` implicitly performs a `yield`, allowing
other tasks to be scheduled before `poll` returns. The `async?` immediate is
passed to `yield`, determining whether other code in the same component
instance may execute.

The Canonical ABI of `waitable-set.poll` is the same as `waitable-set.wait`
(with the `none` case indicated by returning `0`). (See also
[`canon_waitable_set_poll`] in the Canonical ABI explainer for details.)

###### 🔀 `waitable-set.drop`

| Synopsis                   |                          |
| -------------------------- | ------------------------ |
| Approximate WIT signature  | `func(s: waitable-set)` |
| Canonical ABI signature    | `[s:i32] -> []`    |

The `waitable-set.drop` built-in removes the indicated [waitable set] from the
current instance's table of waitable sets, trapping if the waitable set is not
empty or if another task is concurrently `wait`ing on it. (See also
[`canon_waitable_set_drop`] in the Canonical ABI explainer for details.)

###### 🔀 `waitable.join`

| Synopsis                   |                                                      |
| -------------------------- | ---------------------------------------------------- |
| Approximate WIT signature  | `func(w: waitable, maybe_set: option<waitable-set>)` |
| Canonical ABI signature    | `[w:i32, maybe_set:i32] -> []`                       |

The `waitable.join` built-in may be called given a [waitable] and an optional
[waitable set]. `join` first removes `w` from any waitable set that it is a
member of and then, if `maybe_set` is not `none`, `w` is added to that set.
Thus, `join` can be used to arbitrarily add, change and remove waitables from
waitable sets in the same component instance, preserving the invariant that a
waitable can be in at most one set.

In the Canonical ABI, `w` is an index into the component instance's [waitables]
table and can be any type of waitable (`subtask` or
`{readable,writable}-{stream,future}-end`). A value of `0` represents a `none`
`maybe_set`, since `0` is not a valid table index. (See also
[`canon_waitable_join`] in the Canonical ABI explainer for details.)

###### 🔀 `subtask.drop`

| Synopsis                   |                          |
| -------------------------- | ------------------------ |
| Approximate WIT signature  | `func(subtask: subtask)` |
| Canonical ABI signature    | `[subtask:i32] -> []`    |

The `subtask.drop` built-in removes the indicated [subtask] from the current
instance's table of [waitables], trapping if the subtask hasn't returned. (See
[`canon_subtask_drop`] in the Canonical ABI explainer for details.)

###### 🔀 `stream.new` and `future.new`

| Synopsis                                   |                                       |
| ------------------------------------------ | ------------------------------------- |
| Approximate WIT signature for `stream.new` | `func<T>() -> writable-stream-end<T>` |
| Approximate WIT signature for `future.new` | `func<T>() -> writable-future-end<T>` |
| Canonical ABI signature                    | `[] -> [writable-end:i32]`            |

The `stream.new` and `future.new` built-ins return the [writable end] of a new
`stream<T>` or `future<T>`. (See also [`canon_stream_new`] in the Canonical ABI
explainer for details.)

The types `readable-stream-end<T>` and `writable-stream-end<T>` are not WIT
types; they are the conceptual lower-level types that describe how the
canonical built-ins use the readable and writable ends of a `stream<T>`.
`writable-stream-end<T>`s are obtained from `stream.new`. A
`readable-stream-end<T>` is created by calling `stream.new` to create a fresh
"unpaired" `writable-stream<T>` and then lifting it as the `stream<T>`
parameter of an import call or the `stream<T>` result of an export call. This
lifted `stream<T>` value is then lowered by the receiving component into a
`readable-stream-end<T>` that is "paired" with the original
`writable-stream-end<T>`.

An analogous relationship exists among `readable-future-end<T>`,
`writable-future-end<T>`, and the WIT `future<T>`.

###### 🔀 `stream.read` and `stream.write`

| Synopsis                                     |                                                                             |
| -------------------------------------------- | --------------------------------------------------------------------------- |
| Approximate WIT signature for `stream.read`  | `func<T>(e: readable-stream-end<T>, b: writable-buffer<T>) -> read-status`  |
| Approximate WIT signature for `stream.write` | `func<T>(e: writable-stream-end<T>, b: readable-buffer<T>) -> write-status` |
| Canonical ABI signature                      | `[stream-end:i32 ptr:i32 num:i32] -> [i32]`                                 |

where `read-status` is defined in WIT as:
```wit
enum read-status {
    // The operation completed and read this many elements.
    complete(u32),

    // The operation did not complete immediately, so callers must wait for
    // the operation to complete by using `task.wait` or by returning to the
    // event loop.
    blocked,

    // The end of the stream has been reached.
    closed,
}
```

and `write-status` is the same as `read-status` except without the optional
error on `closed`, so it is defined in WIT as:
```wit
enum write-status {
    // The operation completed and wrote this many elements.
    complete(u32),

    // The operation did not complete immediately, so callers must wait for
    // the operation to complete by using `task.wait` or by returning to the
    // event loop.
    blocked,

    // The reader is no longer reading data.
    closed,
}
```

The `stream.read` and `stream.write` built-ins take the matching [readable or
writable end] of a stream as the first parameter and a buffer for the `T`
values to be read from or written to. The return value is either the number of
elements (possibly zero) that have been eagerly read or written, a sentinel
indicating that the operation did not complete yet (`blocked`), or a sentinel
indicating that the stream is closed (`closed`). For reads, `closed` has an
optional error context describing the error that caused to the stream to close.

In the Canonical ABI, the buffer is passed as a pointer to a buffer in linear
memory and the size in elements of the buffer. (See [`canon_stream_read`] in
the Canonical ABI explainer for details.)

`read-status` and `write-status` are lowered in the Canonical ABI as:
 - The value `0xffff_ffff` represents `blocked`.
 - Otherwise, if the bit `0x8000_0000` is set, the value represents `closed`.
 - Otherwise, the value represents `complete` and contains the number of
   element read or written.

(See [`pack_async_copy_result`] in the Canonical ABI explainer for details.)

###### 🔀 `future.read` and `future.write`

| Synopsis                                     |                                                                                |
| -------------------------------------------- | ------------------------------------------------------------------------------ |
| Approximate WIT signature for `future.read`  | `func<T>(e: readable-future-end<T>, b: writable-buffer<T; 1>) -> read-status`  |
| Approximate WIT signature for `future.write` | `func<T>(e: writable-future-end<T>, b: readable-buffer<T; 1>) -> write-status` |
| Canonical ABI signature                      | `[future-end:i32 ptr:i32] -> [i32]`                                            |

where `read-status` and `write-status` are defined as in
[`stream.read` and `stream.write`](#-streamread-and-streamwrite).

The `future.{read,write}` built-ins take the matching [readable or writable
end] of a future as the first parameter, and a buffer for a single `T` value to
read into or write from. The return value is either `complete` if the future
value was eagerly read or written, a sentinel indicating that the operation did
not complete yet (`blocked`), or a sentinel indicating that the future is
closed (`closed`).

The number of elements returned when the value is `complete` is at most `1`.

The `<T; 1>` in the buffer types indicates that these buffers may hold at most
one `T` element.

In the Canonical ABI, the buffer is passed as a pointer to a buffer in linear
memory. (See [`canon_future_read`] in the Canonical ABI explainer for details.)

###### 🔀 `stream.cancel-read`, `stream.cancel-write`, `future.cancel-read`, and `future.cancel-write`

| Synopsis                                            |                                                      |
| --------------------------------------------------- | ---------------------------------------------------- |
| Approximate WIT signature for `stream.cancel-read`  | `func<T>(e: readable-stream-end<T>) -> read-status`  |
| Approximate WIT signature for `stream.cancel-write` | `func<T>(e: writable-stream-end<T>) -> write-status` |
| Approximate WIT signature for `future.cancel-read`  | `func<T>(e: readable-future-end<T>) -> read-status`  |
| Approximate WIT signature for `future.cancel-write` | `func<T>(e: writable-future-end<T>) -> write-status` |
| Canonical ABI signature                             | `[e: i32] -> [i32]`                                  |

where `read-status` and `write-status` are defined as in
[`stream.read` and `stream.write`](#-streamread-and-streamwrite).

The `stream.cancel-read`, `stream.cancel-write`, `future.cancel-read`, and
`future.cancel-write` built-ins take the matching [readable or writable end] of
a stream or future that has an outstanding `blocked` read or write. If
cancellation finished eagerly, the return value is `complete`, and provides the
number of elements read or written into the given buffer (`0` or `1` for a
`future`). If cancellation blocks, the return value is `blocked` and the caller
must `task.wait`. If the stream or future is closed, the return value is
`closed`.

For `future.*`, the number of elements returned when the value is `complete`
is at most `1`.

In the Canonical ABI with the `callback` option, returning to the event loop is
equivalent to a `task.wait`, and a `{STREAM,FUTURE}_{READ,WRITE}` event will be
delivered to indicate the completion of the `read` or `write`. (See
[`canon_stream_cancel_read`] in the Canonical ABI explainer for details.)

###### 🔀 `stream.close-readable`, `stream.close-writable`, `future.close-readable`, and `future.close-writable`

| Synopsis                                              |                                                                  |
| ----------------------------------------------------- | ---------------------------------------------------------------- |
| Approximate WIT signature for `stream.close-readable` | `func<T>(e: readable-stream-end<T>)` |
| Approximate WIT signature for `stream.close-writable` | `func<T>(e: writable-stream-end<T>)` |
| Approximate WIT signature for `future.close-readable` | `func<T>(e: readable-future-end<T>)` |
| Approximate WIT signature for `future.close-writable` | `func<T>(e: writable-future-end<T>)` |
| Canonical ABI signature                               | `[end:i32 err:i32] -> []`                                        |

The `{stream,future}.close-{readable,writable}` built-ins remove the indicated
[stream or future] from the current component instance's table of [waitables],
trapping if the stream or future has a mismatched direction or type or are in
the middle of a `read` or `write`.

##### 📝 Error Context built-ins

###### 📝 `error-context.new`

| Synopsis                         |                                          |
| -------------------------------- | ---------------------------------------- |
| Approximate WIT signature        | `func(message: string) -> error-context` |
| Canonical ABI signature          | `[ptr:i32 len:i32] -> [i32]`             |

The `error-context.new` built-in returns a new `error-context` value. The given
string is non-deterministically transformed to produce the `error-context`'s
internal [debug message](#error-context-type).

In the Canonical ABI, the returned value is an index into a
per-component-instance table. (See also [`canon_error_context_new`] in the
Canonical ABI explainer.)

###### 📝 `error-context.debug-message`

| Synopsis                         |                                         |
| -------------------------------- | --------------------------------------- |
| Approximate WIT signature        | `func(errctx: error-context) -> string` |
| Canonical ABI signature          | `[errctxi:i32 ptr:i32] -> []`           |

The `error-context.debug-message` built-in returns the
[debug message](#error-context-type) of the given `error-context`.

In the Canonical ABI, it writes the debug message into `ptr` as an 8-byte
(`ptr`, `length`) pair, according to the Canonical ABI for `string`, given the
`<canonopt>*` immediates. (See also [`canon_error_context_debug_message`] in
the Canonical ABI explainer.)

###### 📝 `error-context.drop`

| Synopsis                         |                               |
| -------------------------------- | ----------------------------- |
| Approximate WIT signature        | `func(errctx: error-context)` |
| Canonical ABI signature          | `[errctxi:i32] -> []`         |

The `error-context.drop` built-in drops the given `error-context` value from
the component instance.

In the Canonical ABI, `errctxi` is an index into a per-component-instance
table. (See also [`canon_error_context_drop`] in the Canonical ABI explainer.)

##### 🧵 Threading built-ins

The [shared-everything-threads] proposal adds component model built-ins for
thread management. These are specified as built-ins and not core WebAssembly
instructions because browsers expect this functionality to come from existing
Web/JS APIs.

###### 🧵 `thread.spawn_ref`

| Synopsis                   |                                                            |
| -------------------------- | ---------------------------------------------------------- |
| Approximate WIT signature  | `func<FuncT>(f: FuncT, c: FuncT.params[0]) -> bool`        |
| Canonical ABI signature    | `[f:(ref null (shared (func (param i32))) c:i32] -> [i32]` |

The `thread.spawn_ref` built-in spawns a new thread by invoking the shared
function `f` while passing `c` to it, returning whether a thread was
successfully spawned. While it's designed to allow different types in the
future, the type of `c` is currently hard-coded to always be `i32`.

(See also [`canon_thread_spawn_ref`] in the Canonical ABI explainer.)


###### 🧵 `thread.spawn_indirect`

| Synopsis                   |                                                   |
| -------------------------- | ------------------------------------------------- |
| Approximate WIT signature  | `func<FuncT>(i: u32, c: FuncT.params[0]) -> bool` |
| Canonical ABI signature    | `[i:i32 c:i32] -> [i32]`                          |

The `thread.spawn_indirect` built-in spawns a new thread by retrieving the
shared function `f` from a table using index `i` and traps if the type of `f` is
not equal to `FuncT` (much like the `call_indirect` core instruction). Once `f`
is retrieved, this built-in operates like `thread.spawn_ref` above, including
the limitations on `f`'s parameters.

(See also [`canon_thread_spawn_indirect`] in the Canonical ABI explainer.)

###### 🧵 `thread.available_parallelism`

| Synopsis                   |                 |
| -------------------------- | --------------- |
| Approximate WIT signature  | `func() -> u32` |
| Canonical ABI signature    | `[] -> [i32]`   |

The `thread.available_parallelism` built-in returns the number of threads that
can be expected to execute in parallel.

The concept of "available parallelism" corresponds is sometimes referred to
as "hardware concurrency", such as in [`navigator.hardwareConcurrency`] in
JavaScript.

(See also [`canon_thread_available_parallelism`] in the Canonical ABI
explainer.)

### 🪙 Value Definitions

Value definitions (in the value index space) are like immutable `global` definitions
in Core WebAssembly except that validation requires them to be consumed exactly
once at instantiation-time (i.e., they are [linear]).

Components may define values in the value index space using following syntax:

```ebnf
value    ::= (value <id>? <valtype> <val>)
val      ::= false | true
           | <core:i64>
           | <f64canon>
           | nan
           | '<core:stringchar>'
           | <core:name>
           | (record <val>+)
           | (variant "<label>" <val>?)
           | (list <val>*)
           | (tuple <val>+)
           | (flags "<label>"*)
           | (enum "<label>")
           | none | (some <val>)
           | ok | (ok <val>) | error | (error <val>)
           | (binary <core:datastring>)
f64canon ::= <core:f64> without the `nan:0x` case.
```

The validation rules for `value` require the `val` to match the `valtype`.

The `(binary ...)` expression form provides an alternative syntax allowing the binary contents
of the value definition to be written directly in the text format, analogous to data segments,
avoiding the need to understand type information when encoding or decoding.

For example:
```wat
(component
  (value $a bool true)
  (value $b u8  1)
  (value $c u16 2)
  (value $d u32 3)
  (value $e u64 4)
  (value $f s8  5)
  (value $g s16 6)
  (value $h s32 7)
  (value $i s64 8)
  (value $j f32 9.1)
  (value $k f64 9.2)
  (value $l char 'a')
  (value $m string "hello")
  (value $n (record (field "a" bool) (field "b" u8)) (record true 1))
  (value $o (variant (case "a" bool) (case "b" u8)) (variant "b" 1))
  (value $p (list (result (option u8)))
    (list
      error
      (ok (some 1))
      (ok none)
      error
      (ok (some 2))
    )
  )
  (value $q (tuple u8 u16 u32) (tuple 1 2 3))

  (type $abc (flags "a" "b" "c"))
  (value $r $abc (flags "a" "c"))

  (value $s (enum "a" "b" "c") (enum "b"))

  (value $t bool (binary "\00"))
  (value $u string (binary "\07example"))

  (type $complex
    (tuple
      (record
        (field "a" (option string))
        (field "b" (tuple (option u8) string))
      )
      (list char)
      $abc
      string
    )
  )
  (value $complex1 (type $complex)
    (tuple
      (record
        none
        (tuple none "empty")
      )
      (list)
      (flags)
      ""
    )
  )
  (value $complex2 (type $complex)
    (tuple
      (record
        (some "example")
        (tuple (some 42) "hello")
      )
      (list 'a' 'b' 'c')
      (flags "b" "a")
      "hi"
    )
  )
)
```

As with all definition sorts, values may be imported and exported by
components. As an example value import:
```wat
(import "env" (value $env (record (field "locale" (option string)))))
```
As this example suggests, value imports can serve as generalized [environment
variables], allowing not just `string`, but the full range of `valtype`.

Values can also be exported.  For example:
```wat
(component
  (import "system-port" (value $port u16))
  (value $url string "https://example.com")
  (export "default-url" (value $url))
  (export "default-port" (value $port))
)
```
The inferred type of this component is:
```wat
(component
  (import "system-port" (value $port u16))
  (value $url string "https://example.com")
  (export "default-url" (value (eq $url)))
  (export "default-port" (value (eq $port)))
)
```
Thus, by default, the precise constant or import being exported is propagated
into the component's type and thus its public interface.  In this way, value exports
can act as semantic configuration data provided by the component to the host
or other client tooling.
Components can also keep the exact value being exported abstract (so that the
precise value is not part of the type and public interface) using the "type ascription"
feature mentioned in the [imports and exports](#import-and-export-definitions) section below.

### 🪙 Start Definitions

Like modules, components can have start functions that are called during
instantiation. Unlike modules, components can call start functions at multiple
points during instantiation with each such call having parameters and results.
Thus, `start` definitions in components look like function calls:
```ebnf
start ::= (start <funcidx> (value <valueidx>)* (result (value <id>?))*)
```
The `(value <valueidx>)*` list specifies the arguments passed to `funcidx` by
indexing into the *value index space*. The arity and types of the two value lists are
validated to match the signature of `funcidx`.

With this, we can define a component that imports a string and computes a new
exported string at instantiation time:
```wat
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
All import names are required to be [strongly-unique]. Separately, all export
names are also required to be [strongly-unique]. The rest of the grammar for
imports and exports defines a structured syntax for the contents of import and
export names. Syntactically, these names appear inside quoted string literals.
The grammar thus restricts the contents of these string literals to provide
more structured information that can be mechanically interpreted by toolchains
and runtimes to support idiomatic developer workflows and source-language
bindings. The rules defining this structured name syntax below are to be
interpreted as a *lexical* grammar defining a single token and thus whitespace
is not automatically inserted, all terminals are single-quoted, and everything
unquoted is a meta-character.
```ebnf
exportname    ::= <plainname>
                | <interfacename>
importname    ::= <exportname>
                | <depname>
                | <urlname>
                | <hashname>
plainname     ::= <label>
                | '[async]' <label> 🔀
                | '[constructor]' <label>
                | '[method]' <label> '.' <label>
                | '[async method]' <label> '.' <label> 🔀
                | '[static]' <label> '.' <label>
                | '[async static]' <label> '.' <label> 🔀
label         ::= <fragment>
                | <label> '-' <fragment>
fragment      ::= <word>
                | <acronym>
word          ::= [a-z] [0-9a-z]*
acronym       ::= [A-Z] [0-9A-Z]*
interfacename ::= <namespace> <label> <projection> <version>?
                | <namespace>+ <label> <projection>+ <version>? 🪺
namespace     ::= <words> ':'
words         ::= <word>
                | <words> '-' <word>
projection    ::= '/' <label>
version       ::= '@' <valid semver>
depname       ::= 'unlocked-dep=<' <pkgnamequery> '>'
                | 'locked-dep=<' <pkgname> '>' ( ',' <hashname> )?
pkgnamequery  ::= <pkgpath> <verrange>?
pkgname       ::= <pkgpath> <version>?
pkgpath       ::= <namespace> <words>
                | <namespace>+ <words> <projection>* 🪺
verrange      ::= '@*'
                | '@{' <verlower> '}'
                | '@{' <verupper> '}'
                | '@{' <verlower> ' ' <verupper> '}'
verlower      ::= '>=' <valid semver>
verupper      ::= '<' <valid semver>
urlname       ::= 'url=<' <nonbrackets> '>' (',' <hashname>)?
nonbrackets   ::= [^<>]*
hashname      ::= 'integrity=<' <integrity-metadata> '>'
```
Components provide six options for naming imports:
* a **plain name** that leaves it up to the developer to "read the docs"
  or otherwise figure out what to supply for the import;
* an **interface name** that is assumed to uniquely identify a higher-level
  semantic contract that the component is requesting an *unspecified* wasm
  or native implementation of;
* a **URL name** that the component is requesting be resolved to a *particular*
  wasm implementation by [fetching] the URL.
* a **hash name** containing a content-hash of the bytes of a *particular*
  wasm implementation but not specifying location of the bytes.
* a **locked dependency name** that the component is requesting be resolved via
  some contextually-supplied registry to a *particular* wasm implementation
  using the given hierarchical name and version; and
* an **unlocked dependency name** that the component is requesting be resolved
  via some contextually-supplied registry to *one of a set of possible* of wasm
  implementations using the given hierarchical name and version range.

Not all hosts are expected to support all six import naming options and, in
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
part of the process of [parsing] the URL in preparation for [fetching] the URL.
The [base URL] operand passed to the URL spec's parsing algorithm is determined
by the host and may be absent, thereby disallowing relative URLs. Thus, the
parsing and fetching of a URL import are host-defined operations that happen
after the decoding and validation of a component, but before instantiation of
that component.

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
resource and/or being asynchronous.

When a function is annotated with `constructor`, `method` or `static`, the
first `label` is the name of the resource and the second `label` is the logical
field name of the function. This additional nesting information allows bindings
generators to insert the function into the nested scope of a class, abstract
data type, object, namespace, package, module or whatever resources get bound
to. For example, a function named `[method]C.foo` could be bound in C++ to a
member function `foo` in a class `C`. The JS API [below](#JS-API) describes how
the native JavaScript bindings could look. Validation described in
[Binary.md](Binary.md) inspects the contents of `plainname` and ensures that
the function has a compatible signature.

When a function is annotated with `async`, bindings generators are expected to
emit whatever asynchronous language construct is appropriate (such as an
`async` function in JS, Python or Rust). Note the absence of
`[async constructor]`. See the [async
explainer](Async.md#sync-and-async-functions) for more details.

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
```wat
(component
  (import "custom-hook" (func (param string) (result string)))
  (import "wasi:http/handler" (instance
    (export "request" (type $request (sub resource)))
    (export "response" (type $response (sub resource)))
    (export "handle" (func (param (own $request)) (result (own $response))))
  ))
  (import "url=<https://mycdn.com/my-component.wasm>" (component ...))
  (import "url=<./other-component.wasm>,integrity=<sha256-X9ArH3k...>" (component ...))
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
```wat
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

Similar to type exports, value exports may also ascribe a type to keep the precise
value from becoming part of the type and public interface.

For example:
```wat
(component
  (value $url string "https://example.com")
  (export "default-url" (value $url) (value string))
)
```

The inferred type of this component is:
```wat
(component
  (export "default-url" (value string))
)
```

Note, that the `url` value definition is absent from the component type

### Name Uniqueness

The goal of the `label`, `exportname` and `importname` productions defined and
used above is to allow automated bindings generators to map these names into
something more idiomatic to the language. For example, the `plainname`
`[method]my-resource.my-method` might get mapped to a method named `myMethod`
nested inside a class `MyResource`. To unburden bindings generators from having
to consider pathological cases where two unique-in-the-component names get
mapped to the same source-language identifier, Component Model validation
imposes a stronger form of uniqueness than simple string equality on all the
names that appear within the same scope.

To determine whether two names (defined as sequences of [Unicode Scalar
Values]) are **strongly-unique**:
* If one name is `l` and the other name is `[constructor]l` (for the same
  `label` `l`), they are strongly-unique.
* Otherwise:
  * Lowercase all the `acronym`s (uppercase letters) in both names.
  * Strip any `[...]` annotation prefix from both names.
  * The names are strongly-unique if the resulting strings are unequal.

Thus, the following names are strongly-unique:
* `foo`, `foo-bar`, `[constructor]foo`, `[method]foo.bar`, `[method]foo.baz`

but attempting to add *any* of the following names would be a validation error:
* `foo`, `foo-BAR`, `[constructor]foo-BAR`, `[async]foo`, `[method]foo.BAR`

Note that additional validation rules involving types apply to names with
annotations. For example, the validation rules for `[constructor]foo` require
`foo` to be a resource type. See [Binary.md](Binary.md#import-and-export-definitions)
for details.


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
2. The Component Model disallows reentrance by trapping if a callee's
   component-instance is already on the stack when the call starts.
   (For details, see [`trap_if_on_stack`](CanonicalABI.md#task-state)
   in the Canonical ABI explainer.) This default prevents obscure
   composition-time bugs and also enables more-efficient non-reentrant
   runtime glue code. This rule will be relaxed by an opt-in
   function type attribute in the [future](Async.md#todo).


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
```wat
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
```wat
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
| `f32`, `f64` | as a Number value | `ToNumber` |
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
```wat
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



[Structure Section]: https://webassembly.github.io/spec/core/syntax/index.html
[Text Format Section]: https://webassembly.github.io/spec/core/text/index.html
[Binary Format Section]: https://webassembly.github.io/spec/core/binary/index.html
[Core Indices]: https://webassembly.github.io/spec/core/syntax/modules.html#indices
[Core Identifiers]: https://webassembly.github.io/spec/core/text/values.html#text-id

[Index Space]: https://webassembly.github.io/spec/core/syntax/modules.html#indices
[Abbreviations]: https://webassembly.github.io/spec/core/text/conventions.html#abbreviations

[`core:i64`]: https://webassembly.github.io/spec/core/text/values.html#text-int
[`core:f64`]: https://webassembly.github.io/spec/core/syntax/values.html#floating-point
[`core:stringchar`]: https://webassembly.github.io/spec/core/text/values.html#text-string
[`core:name`]: https://webassembly.github.io/spec/core/syntax/values.html#syntax-name
[`core:module`]: https://webassembly.github.io/spec/core/text/modules.html#text-module
[`core:type`]: https://webassembly.github.io/spec/core/text/modules.html#types
[`core:importdesc`]: https://webassembly.github.io/spec/core/text/modules.html#text-importdesc
[`core:externtype`]: https://webassembly.github.io/spec/core/syntax/types.html#external-types
[`core:valtype`]: https://webassembly.github.io/spec/core/text/types.html#value-types
[`core:typeuse`]: https://webassembly.github.io/spec/core/text/modules.html#type-uses
[`core:functype`]: https://webassembly.github.io/spec/core/text/types.html#function-types
[`core:datastring`]: https://webassembly.github.io/spec/core/text/modules.html#text-datastring
[func-import-abbrev]: https://webassembly.github.io/spec/core/text/modules.html#text-func-abbrev
[`core:version`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-version

[Embedder]: https://webassembly.github.io/spec/core/appendix/embedding.html
[`module_instantiate`]: https://webassembly.github.io/spec/core/appendix/embedding.html#mathrm-module-instantiate-xref-exec-runtime-syntax-store-mathit-store-xref-syntax-modules-syntax-module-mathit-module-xref-exec-runtime-syntax-externval-mathit-externval-ast-xref-exec-runtime-syntax-store-mathit-store-xref-exec-runtime-syntax-moduleinst-mathit-moduleinst-xref-appendix-embedding-embed-error-mathit-error
[`func_invoke`]: https://webassembly.github.io/spec/core/appendix/embedding.html#mathrm-func-invoke-xref-exec-runtime-syntax-store-mathit-store-xref-exec-runtime-syntax-funcaddr-mathit-funcaddr-xref-exec-runtime-syntax-val-mathit-val-ast-xref-exec-runtime-syntax-store-mathit-store-xref-exec-runtime-syntax-val-mathit-val-ast-xref-appendix-embedding-embed-error-mathit-error
[`func_alloc`]: https://webassembly.github.io/spec/core/appendix/embedding.html#mathrm-func-alloc-xref-exec-runtime-syntax-store-mathit-store-xref-syntax-types-syntax-functype-mathit-functype-xref-exec-runtime-syntax-hostfunc-mathit-hostfunc-xref-exec-runtime-syntax-store-mathit-store-xref-exec-runtime-syntax-funcaddr-mathit-funcaddr

[`WebAssembly.instantiate()`]: https://developer.mozilla.org/en-US/docs/WebAssembly/JavaScript_interface/instantiate
[`FinalizationRegistry`]: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/FinalizationRegistry
[Fetching]: https://fetch.spec.whatwg.org/
[Parsing]: https://url.spec.whatwg.org/#url-parsing
[Base URL]: https://url.spec.whatwg.org/#concept-base-url
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
[Unit]: https://en.wikipedia.org/wiki/Unit_type

[Generative]: https://www.researchgate.net/publication/2426300_A_Syntactic_Theory_of_Type_Generativity_and_Sharing
[Avoidance Problem]: https://counterexamples.org/avoidance.html
[Non-Parametric Parametricity]: https://people.mpi-sws.org/~dreyer/papers/npp/main.pdf

[module-linking]: https://github.com/WebAssembly/module-linking/blob/main/proposals/module-linking/Explainer.md
[interface-types]: https://github.com/WebAssembly/interface-types/blob/main/proposals/interface-types/Explainer.md
[type-imports]: https://github.com/WebAssembly/proposal-type-imports/blob/master/proposals/type-imports/Overview.md
[exception-handling]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md
[stack-switching]: https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md
[esm-integration]: https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration
[gc]: https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md
[`rectype`]: https://webassembly.github.io/gc/core/text/types.html#text-rectype
[shared-everything-threads]: https://github.com/WebAssembly/shared-everything-threads
[WASI Preview 2]: https://github.com/WebAssembly/WASI/tree/main/wasip2#readme
[reference types]: https://github.com/WebAssembly/reference-types/blob/master/proposals/reference-types/Overview.md

[Strongly-unique]: #name-uniqueness

[Adapter Functions]: FutureFeatures.md#custom-abis-via-adapter-functions
[Canonical ABI explainer]: CanonicalABI.md
[`canon_context_get`]: CanonicalABI.md#-canon-contextget
[`canon_context_set`]: CanonicalABI.md#-canon-contextset
[`canon_backpressure_set`]: CanonicalABI.md#-canon-backpressureset
[`canon_task_return`]: CanonicalABI.md#-canon-taskreturn
[`canon_yield`]: CanonicalABI.md#-canon-yield
[`canon_waitable_set_new`]: CanonicalABI.md#-canon-waitable-setnew
[`canon_waitable_set_wait`]: CanonicalABI.md#-canon-waitable-setwait
[`canon_waitable_set_poll`]: CanonicalABI.md#-canon-waitable-setpoll
[`canon_waitable_set_drop`]: CanonicalABI.md#-canon-waitable-setdrop
[`canon_waitable_join`]: CanonicalABI.md#-canon-waitablejoin
[`canon_stream_new`]: CanonicalABI.md#-canon-streamfuturenew
[`canon_stream_read`]: CanonicalABI.md#-canon-streamfuturereadwrite
[`canon_future_read`]: CanonicalABI.md#-canon-streamfuturereadwrite
[`canon_stream_cancel_read`]: CanonicalABI.md#-canon-streamfuturecancel-readwrite
[`canon_subtask_drop`]: CanonicalABI.md#-canon-subtaskdrop
[`canon_resource_new`]: CanonicalABI.md#canon-resourcenew
[`canon_resource_drop`]: CanonicalABI.md#canon-resourcedrop
[`canon_resource_rep`]: CanonicalABI.md#canon-resourcerep
[`canon_error_context_new`]: CanonicalABI.md#-canon-error-contextnew
[`canon_error_context_debug_message`]: CanonicalABI.md#-canon-error-contextdebug-message
[`canon_error_context_drop`]: CanonicalABI.md#-canon-error-contextdrop
[`canon_thread_spawn_ref`]: CanonicalABI.md#-canon-threadspawn_ref
[`canon_thread_spawn_indirect`]: CanonicalABI.md#-canon-threadspawn_indirect
[`canon_thread_available_parallelism`]: CanonicalABI.md#-canon-threadavailable_parallelism
[`pack_async_copy_result`]: CanonicalABI.md#-canon-streamfuturereadwrite
[the `close` built-ins]: CanonicalABI.md#-canon-streamfutureclose-readablewritable
[Shared-Nothing]: ../high-level/Choices.md
[Use Cases]: ../high-level/UseCases.md
[Host Embeddings]: ../high-level/UseCases.md#hosts-embedding-components

[Task]: Async.md#task
[Current Task]: Async.md#current-task
[Context-Local Storage]: Async.md#context-local-storage
[Subtask]: Async.md#subtask
[Stream or Future]: Async.md#streams-and-futures
[Readable or Writable End]: Async.md#streams-and-futures
[Writable End]: Async.md#streams-and-futures
[Waiting]: Async.md#waiting
[Waitables]: Async.md#waiting
[Waitable Set]: Async.md#waiting
[Backpressure]: Async.md#backpressure
[Returning]: Async.md#returning

[Component Model Documentation]: https://component-model.bytecodealliance.org
[`wizer`]: https://github.com/bytecodealliance/wizer
[`warg`]: https://warg.io
[SemVerRange]: https://semver.npmjs.com/
[OCI Registry]: https://github.com/opencontainers/distribution-spec

[Scoping and Layering]: https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8
[Future and Stream Types]: https://docs.google.com/presentation/d/1MNVOZ8hdofO3tI0szg_i-Yoy0N2QPU2C--LzVuoGSlE

[`navigator.hardwareConcurrency`]: https://developer.mozilla.org/en-US/docs/Web/API/Navigator/hardwareConcurrency
