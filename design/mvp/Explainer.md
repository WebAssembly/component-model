# Component Model Explainer

This explainer walks through the assembly-level definition of a
[component](../high-level) and the proposed embedding of components into
native JavaScript runtimes.

* [Grammar](#grammar)
  * [Component definitions](#component-definitions)
  * [Instance definitions](#instance-definitions)
  * [Alias definitions](#alias-definitions)
  * [Type definitions](#type-definitions)
  * [Canonical definitions](#canonical-definitions)
  * [Start definitions](#start-definitions)
  * [Import and export definitions](#import-and-export-definitions)
* [Component invariants](#component-invariants)
* [JavaScript embedding](#JavaScript-embedding)
  * [JS API](#JS-API)
  * [ESM-integration](#ESM-integration)
* [Examples](#examples)
* [TODO](#TODO)

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
```
component  ::= (component <id>? <definition>*)
definition ::= core-prefix(<core:module>)
             | core-prefix(<core:instance>)
             | core-prefix(<core:alias>)
             | core-prefix(<core:type>)
             | <component>
             | <instance>
             | <alias>
             | <type>
             | <canon>
             | <start>
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
components embed Core WebAssemby (text and binary format) modules as currently
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


### Instance Definitions

Whereas modules and components represent immutable *code*, instances associate
code with potentially-mutable *state* (e.g., linear memory) and thus are
necessary to create before being able to *run* the code. Instance definitions
create module or component instances by selecting a module or component and
then supplying a set of named *arguments* which satisfy all the named *imports*
of the selected module or component.

The syntax for defining a core module instance is:
```
core:instance       ::= (instance <id>? <core:instancexpr>)
core:instanceexpr   ::= (instantiate <core:moduleidx> <core:instantiatearg>*)
                      | <core:export>*
core:instantiatearg ::= (with <name> (instance <core:instanceidx>))
                      | (with <name> (instance <core:export>*))
core:sortidx        ::= (<core:sort> <u32>)
core:sort           ::= func
                      | table
                      | memory
                      | global
                      | type
                      | module
                      | instance
core:export         ::= (export <name> <core:sortidx>)
```
When instantiating a module via `instantiate`, the two-level imports of the
core modules are resolved as follows:
1. The first `name` of the import is looked up in the named list of
   `core:instantiatearg` to select a core module instance. (In the future,
   other `core:sort`s could be allowed if core wasm adds single-level
   imports.)
2. The second `name` of the import is looked up in the named list of exports of
   the core module instance found by the first step to select the imported
   core definition.

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

The `<core:export>*` form of `core:instanceexpr` allows module instances to be
created by directly tupling together preceding definitions, without the need to
`instantiate` a helper module. The "inline" form of `<core:export>*` inside
`(with ...)` is syntactic sugar that is expanded during text format parsing
into an out-of-line instance definition referenced by `with`. To show an
example of these, we'll also need the `alias` definitions introduced in the
next section.

The syntax for defining component instances is symmetric to core module
instances, but with an expanded component-level definition of `sort`:
```
instance       ::= (instance <id>? <instanceexpr>)
instanceexpr   ::= (instantiate <componentidx> <instantiatearg>*)
                 | <export>*
instantiatearg ::= (with <name> <sortidx>)
                 | (with <name> (instance <export>*))
sortidx        ::= (<sort> <u32>)
sort           ::= core <core:sort>
                 | func
                 | value
                 | type
                 | component
                 | instance
export         ::= (export <name> <sortidx>)
```
Because component-level function, type and instance definitions are different
than core-level function, type and instance definitions, they are put into
disjoint index spaces which are indexed separately. Components may import
and export various core definitions (when they are compatible with the
[shared-nothing] model, which currently means only `module`, but may in the
future include `data`). Thus, component-level `sort` injects the full set
of `core:sort`, so that they may be referenced (leaving it up to validation
rules to throw out the core sorts that aren't allowed in various contexts).

The `value` sort refers to a value that is provided and consumed during
instantiation. How this works is described in the
[start definitions](#start-definitions) section.

To see a non-trivial example of component instantiation, we'll first need to
introduce a few other definitions below that allow components to import, define
and export component functions.


### Alias Definitions

Alias definitions project definitions out of other components' index spaces and
into the current component's index spaces. As represented in the AST below,
there are two kinds of "targets" for an alias: the `export` of an instance and
a definition in an index space of an `outer` component (containing the current
component):
```
core:alias       ::= (alias <core:aliastarget> (<core:sort> <id>?))
core:aliastarget ::= export <core:instanceidx> <name>

alias            ::= (alias <aliastarget> (<sort> <id>?))
aliastarget      ::= export <instanceidx> <name>
                   | outer <u32> <u32>
```
The `core:sort`/`sort` immediate of the alias specifies which index space in
the target component is being read from and which index space of the containing
component is being added to. If present, the `id` of the alias is bound to the
new index added by the alias and can be used anywhere a normal `id` can be
used.

In the case of `export` aliases, validation ensures `name` is an export in the
target instance and has a matching sort.

In the case of `outer` aliases, the `u32` pair serves as a [de Bruijn
index], with first `u32` being the number of enclosing components to skip
and the second `u32` being an index into the target component's sort's index
space. In particular, the first `u32` can be `0`, in which case the outer
alias refers to the current component. To maintain the acyclicity of module
instantiation, outer aliases are only allowed to refer to *preceding* outer
definitions.

There is no `outer` option in `core:aliastarget` because it would only be able
to refer to enclosing *core* modules and module types and, until
module-linking, modules and module types can't nest. In a module-linking
future, outer aliases would be added, making `core:alias` symmetric to `alias`.

Components containing outer aliases effectively produce a [closure] at
instantiation time, including a copy of the outer-aliased definitions. Because
of the prevalent assumption that components are immutable values, outer aliases
are restricted to only refer to immutable definitions: types, modules and
components. (In the future, outer aliases to all sorts of definitions could be
allowed by recording the statefulness of the resulting component in its type
via some kind of "`stateful`" type attribute.)

Both kinds of aliases come with syntactic sugar for implicitly declaring them
inline:

For `export` aliases, the inline sugar has the form `(sort <instanceidx> <name>+)`
and can be used in place of a `sortidx` or any sort-specific index (such as a
`typeidx` or `funcidx`). For example, the following snippet uses two inline
function aliases:
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
(func $f (import "i" "f") ...type...) ≡ (import "i" "f" (func $f ...type...))       (WebAssembly 1.0)
(func $g (alias export $i "g1"))      ≡ (alias export $i "g1" (func $g))
(core func $g (alias export $i "g1")) ≡ (core alias export $i "g1" (func $g))
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
    (with "a" (instance $a))                  ;; no renaming
  ))
  (core func $a_two (alias export $a "two"))  ;; ≡ (core alias export $a "two" (func $a_two))
  (core instance $b2 (instantiate $B
    (with "a" (instance
      (export "one" (func $a_two))            ;; renaming, using out-of-line alias
    ))
  ))
  (core instance $b3 (instantiate $B
    (with "a" (instance
      (export "one" (func $a "three"))        ;; renaming, using inline alias sugar
    ))
  ))
)
```
To show analogous examples of linking components, we'll need component-level
type and function definitions which are introduced in the next two sections.


### Type Definitions

The syntax for defining core types extends the existing core type definition
syntax, adding a `module` type constructor:
```
core:type       ::= (type <id>? <core:deftype>)               (GC proposal)
core:deftype    ::= <core:functype>                           (WebAssembly 1.0)
                  | <core:structtype>                         (GC proposal)
                  | <core:arraytype>                          (GC proposal)
                  | <core:moduletype>
core:moduletype ::= (module <core:moduledecl>*)
core:moduledecl ::= <core:importdecl>
                  | <core:type>
                  | <core:exportdecl>
core:importdecl ::= (import <name> <name> <core:importdesc>)
core:exportdecl ::= (export <name> <core:exportdesc>)
core:exportdesc ::= strip-id(<core:importdesc>)

where strip-id(X) parses '(' sort Y ')' when X parses '(' sort <id>? Y ')'
```

Here, `core:deftype` (short for "defined type") is inherited from the [gc]
proposal and extended with a `module` type constructor. If module-linking is
added to Core WebAssembly, an `instance` type constructor would be added as
well but, for now, it's left out since it's unnecessary. Also, in the MVP,
validation will reject nested `core:moduletype`, since, before module-linking,
core modules cannot themselves import or export other core modules.

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
```
(component $C
  (type $M (module
    (import "" "T" (type $T))
    (type $PairT (struct (field (ref $T)) (field (ref $T))))
    (export "make_pair" (func (param (ref $T)) (result (ref $PairT))))
  ))
)
```
In this example, `$M` has a distinct type index space from `$C`, where element
0 is the imported type, element 1 is the `struct` type, and element 2 is an
implicitly-created `func` type referring to both.

Component-level type definitions are symmetric to core-level type definitions,
but use a completely different set of value types. Unlike [`core:valtype`]
which is low-level and assumes a shared linear memory for communicating
compound values, component-level value types assume no shared memory and must
therefore be high-level, describing entire compound values.
```
type          ::= (type <id>? <deftype>)
deftype       ::= <defvaltype>
                | <functype>
                | <componenttype>
                | <instancetype>
defvaltype    ::= unit
                | bool
                | s8 | u8 | s16 | u16 | s32 | u32 | s64 | u64
                | float32 | float64
                | char | string
                | (record (field <name> <valtype>)*)
                | (variant (case <name> <valtype> (refines <name>)?)+)
                | (list <valtype>)
                | (tuple <valtype>*)
                | (flags <name>*)
                | (enum <name>+)
                | (union <valtype>+)
                | (option <valtype>)
                | (expected <valtype> <valtype>)
valtype       ::= <typeidx>
                | <defvaltype>
functype      ::= (func (param <name>? <valtype>)* (result <valtype>))
componenttype ::= (component <componentdecl>*)
instancetype  ::= (instance <instancedecl>*)
componentdecl ::= <importdecl>
                | <instancedecl>
instancedecl  ::= <type>
                | <alias>
                | <exportdecl>
importdecl    ::= (import <name> bind-id(<externdesc>))
exportdecl    ::= (export <name> <externdesc>)
externdesc    ::= (<sort> (type <u32>) )
                | core-prefix(<core:moduletype>)
                | <functype>
                | <componenttype>
                | <instancetype>
                | (value <valtype>)
                | (type <typebound>)
typebound     ::= (eq <typeidx>)

where bind-id(X) parses '(' sort <id>? Y ')' when X parses '(' sort Y ')'
```
The value types in `valtype` can be broken into two categories: *fundamental*
value types and *specialized* value types, where the latter are defined by
expansion into the former. The *fundamental value types* have the following
sets of abstract values:
| Type                      | Values |
| ------------------------- | ------ |
| `bool`                    | `true` and `false` |
| `s8`, `s16`, `s32`, `s64` | integers in the range [-2<sup>N-1</sup>, 2<sup>N-1</sup>-1] |
| `u8`, `u16`, `u32`, `u64` | integers in the range [0, 2<sup>N</sup>-1] |
| `float32`, `float64`      | [IEEE754] floating-pointer numbers with a single, canonical "Not a Number" ([NaN]) value |
| `char`                    | [Unicode Scalar Values] |
| `record`                  | heterogeneous [tuples] of named values |
| `variant`                 | heterogeneous [tagged unions] of named values |
| `list`                    | homogeneous, variable-length [sequences] of values |

The `float32` and `float64` values have their NaNs canonicalized to a single
value so that:
1. consumers of NaN values are free to use the rest of the NaN payload for
   optimization purposes (like [NaN boxing]) without needing to worry about
   whether the NaN payload bits were significant; and
2. producers of NaN values across component boundaries do not develop brittle
   assumptions that NaN payload bits are preserved by the other side (since
   they often aren't).

The subtyping between all these types is described in a separate
[subtyping explainer](Subtyping.md). Of note here, though: the optional
`refines` field in the `case`s of `variant`s is exclusively concerned with
subtyping. In particular, a `variant` subtype can contain a `case` not present
in the supertype if the subtype's `case` `refines` (directly or transitively)
some `case` in the supertype.

The sets of values allowed for the remaining *specialized value types* are
defined by the following mapping:
```
            (tuple <valtype>*) ↦ (record (field "𝒊" <valtype>)*) for 𝒊=0,1,...
               (flags <name>*) ↦ (record (field <name> bool)*)
                          unit ↦ (record)
                (enum <name>+) ↦ (variant (case <name> unit)+)
            (option <valtype>) ↦ (variant (case "none") (case "some" <valtype>))
            (union <valtype>+) ↦ (variant (case "𝒊" <valtype>)+) for 𝒊=0,1,...
(expected <valtype> <valtype>) ↦ (variant (case "ok" <valtype>) (case "error" <valtype>))
                        string ↦ (list char)
```
Note that, at least initially, variants are required to have a non-empty list of
cases. This could be relaxed in the future to allow an empty list of cases, with
the empty `(variant)` effectively serving as a [empty type] and indicating
unreachability.

The remaining 3 type constructors in `deftype` use `valtype` to describe
shared-nothing functions, components and component instances:

The `func` type constructor describes a component-level function definition
that takes and returns `valtype`. In contrast to [`core:functype`] which, as a
low-level compiler target for a stack machine, returns zero or more results,
`functype` always returns a single type, with `unit` being used for functions
that don't return an interesting value (analogous to "void" in some languages).
Having a single return type simplifies the binding of `functype` into a wide
variety of source languages. As syntactic sugar, the text format of `functype`
additionally allows `result` to be absent, interpreting this as `(result
unit)`.

The `instance` type constructor represents the result of instantiating a
component and thus is the same as a `component` type minus the description
of imports.

The `component` type constructor is symmetric to the core `module` type
constructor and is built from a sequence of "declarators" which are used to
describe the imports and exports of the component. There are four kinds of
declarators:

As with core modules, `importdecl` and `exportdecl` classify component `import`
and `export` definitions, with `importdecl` allowing an identifier to be
bound for use within the type. Following the precedent of [`core:typeuse`], the
text format allows both references to out-of-line type definitions (via
`(type <typeidx>)`) and inline type expressions that the text format desugars
into out-of-line type definitions.

The `value` case of `externdesc` describes a runtime value that is imported or
exported at instantiation time as described in the
[start definitions](#start-definitions) section below.

The `type` case of `externdesc` describes an imported or exported type along
with its bounds. The bounds currently only have an `eq` option that says that
the imported/exported type must be exactly equal to the referenced type. There
are two main use cases for this in the short-term:
* Type exports allow a component or interface to associate a name with a
  structural type (e.g., `(export "nanos" (type (eq u64)))`) which bindings
  generators can use to generate type aliases (e.g., `typedef uint64_t nanos;`).
* Type imports and exports can provide additional information to toolchains and
  runtimes for defining the behavior of host APIs.

When [resource and handle types] are added to the explainer, `typebound` will
be extended with a `sub` option (symmetric to the [type-imports] proposal) that
allows importing and exporting *abstract* types.

Lastly, component and instance types also include an `alias` declarator for
projecting the exports out of imported instances and sharing types with outer
components. As an example, the following component defines two equivalent
component types, where the former defines the function type via `type`
declarator and the latter via `alias` declarator. In both cases, the type is
given index `0` since component types start with an empty type index space.
```wasm
(component $C
  (type $C1 (component
    (type (func (param string) (result string)))
    (import "a" (func (type 0)))
    (export "b" (func (type 0)))
  ))
  (type $F (func (param string) (result string)))
  (type $C2 (component
    (alias outer $C $F (type))
    (import "a" (func (type 0)))
    (export "b" (func (type 0)))
  ))
)
```

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
    (import "g" (func (type $G)))
    (export "g" (func (type $G)))
    (export "h" (func (result $U)))
  ))
)
```
Note that the inline use of `$G` and `$U` are syntactic sugar for `outer`
aliases.


### Canonical Definitions

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
```
canon    ::= (canon lift core-prefix(<core:funcidx>) <canonopt>* bind-id(<externdesc>))
           | (canon lower <funcidx> <canonopt>* (core func <id>?))
canonopt ::= string-encoding=utf8
           | string-encoding=utf16
           | string-encoding=latin1+utf16
           | (memory core-prefix(<core:memidx>))
           | (realloc core-prefix(<core:funcidx>))
           | (post-return core-prefix(<core:funcidx>))
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
failure, component functions can return `expected` and languages with exception
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

Using canonical definitions, we can finally write a non-trivial component that
takes a string, does some logging, then returns a string.
```wasm
(component
  (import "wasi:logging" (instance $logging
    (export "log" (func (param string)))
  ))
  (import "libc" (core module $Libc
    (export "mem" (memory 1))
    (export "realloc" (func (param i32 i32) (result i32)))
  ))
  (core instance $libc (instantiate $Libc))
  (core func $log (canon lower
    (func $logging "log")
    (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))
  ))
  (core module $Main
    (import "libc" "memory" (memory 1))
    (import "libc" "realloc" (func (param i32 i32) (result i32)))
    (import "wasi:logging" "log" (func $log (param i32 i32)))
    (func (export "run") (param i32 i32) (result i32 i32)
      ... (call $log) ...
    )
  )
  (core instance $main (instantiate $Main
    (with "libc" (instance $libc))
    (with "wasi:logging" (instance (export "log" (func $log))))
  ))
  (func $run (param string) (result string) (canon lift
    (core func $main "run")
    (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))
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


### Start Definitions

Like modules, components can have start functions that are called during
instantiation. Unlike modules, components can call start functions at multiple
points during instantiation with each such call having parameters and results.
Thus, `start` definitions in components look like function calls:
```
start ::= (start <funcidx> (value <valueidx>)* (result (value <id>))?)
```
The `(value <valueidx>)*` list specifies the arguments passed to `funcidx` by
indexing into the *value index space*. Value definitions (in the value index
space) are like immutable `global` definitions in Core WebAssembly except that
validation requires them to be consumed exactly once at instantiation-time
(i.e., they are [linear]).

As with all definition sorts, values may be imported and exported by
components. As an example value import:
```
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
    (func (export "start") (param i32 i32) (result i32 i32)
      ... general-purpose compute
    )
  )
  (core instance $main (instantiate $Main (with "libc" (instance $libc))))
  (func $start (param string) (result string) (canon lift
    (core func $main "start")
    (memory (core memory $libc "mem")) (realloc (core func $libc "realloc"))
  ))
  (start $start (value $name) (result (value $greeting)))
  (export "greeting" (value $greeting))
)
```
As this example shows, start functions reuse the same Canonical ABI machinery
as normal imports and exports for getting component-level values into and out
of core linear memory.


### Import and Export Definitions

Lastly, imports and exports are defined in terms of the above as:
```
import ::= <importdecl>
export ::= (export <name> <sortidx>)
```
All import and export names within a component must be unique, respectively.

With what's defined so far, we can write a component that imports, links and
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
  (instance $d1 (instantiate $D
    (with "c" (instance $c))
  ))
  (instance $d2 (instantiate $D
    (with "c" (instance
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
(splitting the 32-bit [`core:version`] field into a 16-bit `version` field and
a 16-bit `layer` field with `0` for modules and `1` for components).

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
the abovementioned functions (again, using the `layer` field to eagerly
distinguish between modules and components).

For example, the following component:
```wasm
;; a.wasm
(component
  (import "one" (func))
  (import "two" (value string))
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
and [`ToWebAssemblyValue`]) to include all of [`valtype`](#type-definitions).
At a high level, the additional coercions would be:

| Type | `ToJSValue` | `ToWebAssemblyValue` |
| ---- | ----------- | -------------------- |
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

Like the JS API, [esm-integration] can be extended to load components in all
the same places where modules can be loaded today, branching on the `layer`
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
[Text Format Section]: https://webassembly.github.io/spec/core/text/index.html
[Binary Format Section]: https://webassembly.github.io/spec/core/binary/index.html

[Index Space]: https://webassembly.github.io/spec/core/syntax/modules.html#indices
[Abbreviations]: https://webassembly.github.io/spec/core/text/conventions.html#abbreviations

[`core:module`]: https://webassembly.github.io/spec/core/text/modules.html#text-module
[`core:type`]: https://webassembly.github.io/spec/core/text/modules.html#types
[`core:importdesc`]: https://webassembly.github.io/spec/core/text/modules.html#text-importdesc
[`core:externtype`]: https://webassembly.github.io/spec/core/syntax/types.html#external-types
[`core:valtype`]: https://webassembly.github.io/spec/core/text/types.html#value-types
[`core:typeuse`]: https://webassembly.github.io/spec/core/text/modules.html#type-uses
[`core:functype`]: https://webassembly.github.io/spec/core/text/types.html#function-types
[func-import-abbrev]: https://webassembly.github.io/spec/core/text/modules.html#text-func-abbrev
[`core:version`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-version

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
[Empty Type]: https://en.wikipedia.org/w/index.php?title=Empty_type
[IEEE754]: https://en.wikipedia.org/wiki/IEEE_754
[NaN]: https://en.wikipedia.org/wiki/NaN
[NaN Boxing]: https://wingolog.org/archives/2011/05/18/value-representation-in-javascript-implementations
[Unicode Scalar Values]: https://unicode.org/glossary/#unicode_scalar_value
[Tuples]: https://en.wikipedia.org/wiki/Tuple
[Tagged Unions]: https://en.wikipedia.org/wiki/Tagged_union
[Sequences]: https://en.wikipedia.org/wiki/Sequence
[ABI]: https://en.wikipedia.org/wiki/Application_binary_interface
[Environment Variables]: https://en.wikipedia.org/wiki/Environment_variable
[Linear]: https://en.wikipedia.org/wiki/Substructural_type_system#Linear_type_systems

[module-linking]: https://github.com/WebAssembly/module-linking/blob/main/design/proposals/module-linking/Explainer.md
[interface-types]: https://github.com/WebAssembly/interface-types/blob/main/proposals/interface-types/Explainer.md
[type-imports]: https://github.com/WebAssembly/proposal-type-imports/blob/master/proposals/type-imports/Overview.md
[exception-handling]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md
[stack-switching]: https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Overview.md
[esm-integration]: https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration
[gc]: https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md

[Adapter Functions]: FutureFeatures.md#custom-abis-via-adapter-functions
[Canonical ABI]: CanonicalABI.md
[Shared-Nothing]: ../high-level/Choices.md

[`wizer`]: https://github.com/bytecodealliance/wizer

[Scoping and Layering]: https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8
[Resource and Handle Types]: https://docs.google.com/presentation/d/1ikwS2Ps-KLXFofuS5VAs6Bn14q4LBEaxMjPfLj61UZE
[Future and Stream Types]: https://docs.google.com/presentation/d/1WtnO_WlaoZu1wp4gI93yc7T_fWTuq3RZp8XUHlrQHl4
