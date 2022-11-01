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
instances, but with an expanded component-level definition of `sort` and
more restricted version of `name`:
```
instance       ::= (instance <id>? <instanceexpr>)
instanceexpr   ::= (instantiate <componentidx> <instantiatearg>*)
                 | <inlineexport>*
instantiatearg ::= (with <name> <sortidx>)
                 | (with <name> (instance <inlineexport>*))
sortidx        ::= (<sort> <u32>)
sort           ::= core <core:sort>
                 | func
                 | value
                 | type
                 | component
                 | instance
inlineexport   ::= (export <name> <sortidx>)
name           ::= <word>
                 | <name>-<word>
word           ::= [a-z][0-9a-z]*
                 | [A-Z][0-9A-Z]*
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

The component-level definition of `name` above corresponds to [kebab case]. The
reason for this particular form of casing is to unambiguously separate words
and acronyms (represented as all-caps words) so that source language bindings
can convert a `name` into the idiomatic casing of that language. (Indeed,
because hyphens are often invalid in identifiers, kebab case practically forces
language bindings to make such a conversion.) For example, the `name` `is-XML`
could be mapped to `isXML`, `IsXml` or `is_XML`, depending on the target
language. The highly-restricted character set ensures that capitalization is
trivial and does not require consulting Unicode tables. Having this structured
data encoded as a plain string provides a single canonical name for use in
tools and language-agnostic contexts, without requiring each to invent its own
custom interpretation. While the use of `name` above is mostly for internal
wiring, `name` is used in a number of productions below that are
developer-facing and imply bindings generation.

To see a non-trivial example of component instantiation, we'll first need to
introduce a few other definitions below that allow components to import, define
and export component functions.


### Alias Definitions

Alias definitions project definitions out of other components' index spaces and
into the current component's index spaces. As represented in the AST below,
there are three kinds of "targets" for an alias: the `export` of a component
instance, the `core export` of a core module instance and a definition of an
`outer` component (containing the current component):
```
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
are restricted to only refer to immutable definitions: types, modules and
components. (In the future, outer aliases to all sorts of definitions could be
allowed by recording the statefulness of the resulting component in its type
via some kind of "`stateful`" type attribute.)

Both kinds of aliases come with syntactic sugar for implicitly declaring them
inline:

For `export` aliases, the inline sugar extends the definition of `sortidx`
and the various sort-specific indices:
```
sortidx     ::= (<sort> <u32>)          ;; as above
              | <inlinealias>
Xidx        ::= <u32>                   ;; as above
              | <inlinealias>
inlinealias ::= (<sort> <u32> <name>+)
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
    (with "a" (instance $a))                     ;; no renaming
  ))
  (core func $a_two (alias core export $a "two") ;; ≡ (alias core export $a "two" (core func $a_two))
  (core instance $b2 (instantiate $B
    (with "a" (instance
      (export "one" (func $a_two))               ;; renaming, using out-of-line alias
    ))
  ))
  (core instance $b3 (instantiate $B
    (with "a" (instance
      (export "one" (func $a "three"))           ;; renaming, using <inlinealias>
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

Component-level type definitions are similar to core-level type definitions,
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
defvaltype    ::= bool
                | s8 | u8 | s16 | u16 | s32 | u32 | s64 | u64
                | float32 | float64
                | char | string
                | (record (field <name> <valtype>)*)
                | (variant (case <id>? <name> <valtype>? (refines <id>)?)+)
                | (list <valtype>)
                | (tuple <valtype>*)
                | (flags <name>*)
                | (enum <name>+)
                | (union <valtype>+)
                | (option <valtype>)
                | (result <valtype>? (error <valtype>)?)
valtype       ::= <typeidx>
                | <defvaltype>
functype      ::= (func <paramlist> <resultlist>)
paramlist     ::= (param <name> <valtype>)*
resultlist    ::= (result <name> <valtype>)*
                | (result <valtype>)
componenttype ::= (component <componentdecl>*)
instancetype  ::= (instance <instancedecl>*)
componentdecl ::= <importdecl>
                | <instancedecl>
instancedecl  ::= core-prefix(<core:type>)
                | <type>
                | <alias>
                | <exportdecl>
importdecl    ::= (import <externname> bind-id(<externdesc>))
exportdecl    ::= (export <externname> bind-id(<externdesc>))
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
                        (enum <name>+) ↦ (variant (case <name>)+)
                    (option <valtype>) ↦ (variant (case "none") (case "some" <valtype>))
                    (union <valtype>+) ↦ (variant (case "𝒊" <valtype>)+) for 𝒊=0,1,...
(result <valtype>? (error <valtype>)?) ↦ (variant (case "ok" <valtype>?) (case "error" <valtype>?))
                                string ↦ (list char)
```
Note that, at least initially, variants are required to have a non-empty list of
cases. This could be relaxed in the future to allow an empty list of cases, with
the empty `(variant)` effectively serving as a [empty type] and indicating
unreachability.

The remaining 3 type constructors in `deftype` use `valtype` to describe
shared-nothing functions, components and component instances:

The `func` type constructor describes a component-level function definition
that takes and returns a list of `valtype`. In contrast to [`core:functype`],
the parameters and results of `functype` can have associated names which
validation requires to be unique. To improve the ergonomics and performance of
the common case of single-value-returning functions, function types may
additionally have a single unnamed return type. For this special case, bindings
generators are naturally encouraged to return the single value directly without
wrapping it in any containing record/object/struct.

The `instance` type constructor describes a list of named, typed definitions
that can be imported or exported by a component. Informally, instance types
correspond to the usual concept of an "interface" and instance types thus serve
as static interface descriptions. In addition to the S-Expression text format
defined here, which is meant to go inside component definitions, interfaces can
also be defined as standalone, human-friendly text files in the [`wit`](WIT.md)
[Interface Definition Language].

The `component` type constructor is symmetric to the core `module` type
constructor and contains *two* lists of named definitions for the imports and
exports of a component, respectively. As suggested above, instance types can
show up in *both* the import and export types of a component type.

Both `instance` and `component` type constructors are built from a
sequence of "declarators". There are four basic forms of declarators:
type declarators (including both core and component types); alias
declarators; export declarators; and import declarators (which may be
present only in component types).

As with core modules, `importdecl` and `exportdecl` classify component
`import` and `export` definitions, with `importdecl` allowing an
identifier to be bound for use within the type. The definition of
`externname` is given in the [imports and
exports](#import-and-export-definitions) section below. Following the
precedent of [`core:typeuse`], the text format allows both references
to out-of-line type definitions (via `(type <typeidx>)`) and inline
type expressions that the text format desugars into out-of-line type
definitions.

The `type` and `core:type` declarators simply introduce a simple type
alias into the local type index space. These entries are fully
transparent to consumers of the component type, and any later
references to theme could (semantically, if not syntactically) be
replaced by the definition provided, as in fact they are during
validation elaboration.

Export declarators take a name and an extern descriptor describing the
entry that they are exporting. However, they also create an entry in a
local (to the current module or instance type declaration) index space
for the appropriate sort, which may be used by later declarators to
refer to the concept of this export. In the future, this will be used
to export bounded resource types as part of the addition of [resource
and handle types]. In the short term, allowing the export of existing
non-resource types (always with an equality type-bound) has two main
use cases:
* Type exports allow a component or interface to associate a name with a
  structural type (e.g., `(export "nanos" (type (eq u64)))`) which bindings
  generators can use to generate type aliases (e.g., `typedef uint64_t nanos;`).
* Type imports and exports can provide additional information to toolchains and
  runtimes for defining the behavior of host APIs.

Note that both `(type ...)` and `({im,ex}port ... (type ...))`
declarators introduce entries to the type index space. The difference
is that the former are treated completely as aliases, with no identity
of their own, while the latter are intended to associate future
declarators with the exported type, so that the latter is correctly
used in WIT/bindings/etc. When resource types are added, only the
latter form will allow adding abstract resource types to the index
space.

As an example, consider:
``` wasm
(component $C
  (type $D (component
    (type $u u32)
    (export "nanos" (type $n (eq u32)))
    (export "foo" (func (param "in" $u) (result $n))))
```

While both types are allocated in the same index space, they are
treated differently in e.g. WIT:
```wit
type nanos = u32
foo: func(in: u32) -> nanos
```

Component import and alias declarators are analagous to the core module
declarators introduced above, and have essentially the same meaning, although
they also (like the import and alias _definitions_ present inside a component)
create entries in the local index spaces that may later be exported. As with
core modules, `importdecl` classifies a component's `import` definitions.

Note that values are imported or exported at _instantiation time_, as described
in the [start-definitions](#start-definitions) section below.

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
    (memory (core memory $libc "mem")) (realloc (func $libc "realloc"))
  ))
  (core module $Main
    (import "libc" "memory" (memory 1))
    (import "libc" "realloc" (func (param i32 i32) (result i32)))
    (import "wasi:logging" "log" (func $log (param i32 i32)))
    (func (export "run") (param i32 i32) (result i32)
      ... (call $log) ...
    )
  )
  (core instance $main (instantiate $Main
    (with "libc" (instance $libc))
    (with "wasi:logging" (instance (export "log" (func $log))))
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


### Start Definitions

Like modules, components can have start functions that are called during
instantiation. Unlike modules, components can call start functions at multiple
points during instantiation with each such call having parameters and results.
Thus, `start` definitions in components look like function calls:
```
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

Lastly, imports and exports are defined as:
```
import     ::= (import <externname> bind-id(<externdesc>))
export     ::= (export <externname> <sortidx>)
externname ::= <name> <URL>?
```
Components split the single externally-visible name of imports and exports into
two sub-fields: a kebab-case `name` (as defined [above](#instance-definitions))
and a `URL` (defined by the [URL Standard], noting that, in this URL Standard,
the term "URL" subsumes what has historically been called a [URI], including
URLs that "identify" as opposed to "locate"). This subdivision of external
names allows component producers to represent a variety of intentions for how a
component is to be instantiated and executed so that a variety of hosts can
portably execute the component.

The `name` field of `externname` is required to be unique. Thus, a single
`name` has been used in the preceding definitions of `with` and `alias` to
uniquely identify imports and exports.

In guest source-code bindings, the `name` is meant to be translated to
source-language identifiers (applying case-conversion, as described
[above](#instance-definitions)) attached to whatever source-language constructs
represent the imports and exports (functions, globals, types, classes, etc).
For example, given an import in a component type:
```
(import "one-two" (instance
  (export "three-four" (func (param string) (result string)))
))
```
a Rust bindings generator for a component targeting this type could produce an
`extern crate one_two` containing the function `three_four`. Similarly, a
[JS Embedding](#js-embedding) could allow `import {threeFour} from 'one-two'`
to resolve to the imported function. Conversely, given an export in a component
type:
```
(export "one-two" (instance
  (export "three-four" (func (param string) (result string)))
))
```
a Rust bindings generator for a component with this export could produce a
trait `OneTwo` requiring a function `three_four` while the JS Embedding would
expect the JS module implementing this component type to export a variable
`oneTwo` containing an object with a field `threeFour` containing a function.

The `name` field can also be used by *host* source-code bindings, defining the
source-language identifiers that are to be used when instantiating a component
and accessing its exports. For example, the [JS API]'s
[`WebAssembly.instantiate()`] would use import `name`s in the [*read the
imports*] step and use export `name`s in the [*create an exports object*] step.

The optional `URL` field of `externname` allows a component author to refer to
an *externally-defined* specification of what an import "wants" or what an
export has "implemented". One example is a URL naming a standard interface such
as `wasi:filesystem` (assuming that WASI registered the `wasi:` URI scheme with
IANA). Pre-standard, non-standard or proprietary interfaces could be referred
to by an `https:` URL in an interface registry. For imports, a URL could
alternatively refer to a *particular implementation* (e.g., at a hosted storage
location) or a *query* for a *set of possible implementations* (e.g., using the
query API of a public registry). Because of the wide variety of hosts executing
components, the Component Model doesn't specify how URLs are to be interpreted,
just that they are grammatically URLs. Even `https:` URLs may or may not be
literally fetched by the host (c.f. [import maps]).

When present, `URL`s must *also* be unique (*in addition* the abovementioned
uniqueness of `name`s). Thus, a `URL` can *also* be used to uniquely identify
the subset of imports or exports that have `URL`s.

While the `name` field is meant for source-code bindings generators, the `URL`
field is meant for automated interpretation by hosts and toolchains. In
particular, hosts are expected to identify their host-implemented imports and
host-called exports by `URL`, not `name`. This allows hosts to implement a
wide collection of independently-developed interfaces where `name`s are chosen
for developer ergonomics (and name collisions are handled independently in
the binding generators, which is needed in any case) and `URL`s serve as
the invariant identifier that concretely links the guest to host. If there was
only a `name`, interface authors would be forced to implicitly coordinate
across the ecosystem to avoid collisions (which in general, isn't possible)
while if there was only a `URL`, the developer-friendly identifiers would have
to be specified manually by every developer or derived in an ad hoc fashion
from the `URL`, whose contents may vary widely. This dual-name scheme is thus
proposed to resolve these competing requirements.

Inside the component model, this dual-name scheme shows up in [subtyping](#Subtyping.md),
where the component subtyping simply ignores the `name` field when the `URL`
field is present. For example, the component:
```
(component
  (import "fs" "wasi:filesystem" ...)
)
```
can be supplied for the `x` import of the component:
```
(component
  (import "x" (component
    (import "filesystem" "wasi:filesystem" ...)
  ))
)
```
because the `name`s are ignored and the `URL`s match. This subtyping is
symmetric to what was described above for hosts, allowing components to
serve as the "host" of other components, enabling [virtualization](examples/LinkTimeVirtualization.md).

Since the concrete artifacts defining the host/guest interface is a collection
of [Wit files](WIT.md), Wit must naturally allow interface authors to specify
both the `name` and `URL` of component imports and exports. While the syntax is
still very much [in flux](https://github.com/WebAssembly/component-model/pull/83),
a hypothetical simplified interface between a guest and host might look like:
```
// wasi:cli/Command
default world Command {
  import fs: "wasi:filesystem"
  import console: "wasi:cli/console"
  export main: "wasi:cli/main"
}
```
where `wasi:filesystem`, `wasi:cli/console` and `wasi:cli/main` are separately
defined interfaces that map to instance types. This "World" definition then
maps to the following component type:
```
(component $Command
  (import "fs" "wasi:filesystem" (instance ... filesystem function exports ...))
  (import "console" "wasi:cli/console" (instance ... log function exports ...))
  (export "main" "wasi:cli/main" (instance (export "main" (func ...))))
)
```
A component *targeting* `wasi:cli/Command` would thus need to be a *subtype* of
`$Command` (importing a subset of these imports and exporting a superset of
these exports) while a host *supporting* `wasi:cli/Command` would need to be
a *supertype* of `$Command` (offering a superset of these imports and expecting
to call a subset of these exports).

Importantly, this `wasi:cli/Command` World has been able to define the short
developer-facing names like `fs` and `console` without worrying if there are
any other Worlds that conflict with these names. If a host wants to implement
`wasi:cli/Command` and some other World that also happens to pick `fs`, either
the `URL` fields are the same, and so the two imports can be unified, or the
`URL` fields are different, and the host supplies two distinct imports,
identified by `URL`.


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

Once compiled, a `WebAssembly.Component` could be instantiated using the
existing JS API `WebAssembly.instantiate(Streaming)`. Since components have the
same basic import/export structure as modules, this means extending the [*read
the imports*] logic to support single-level imports (of kebab-case component
import names converted to lowerCamelCase JavaScript identifiers) as well as
imports of modules, components and instances. Since the results of
instantiating a component is a record of JavaScript values, just like an
instantiated module, `WebAssembly.instantiate` would always produce a
`WebAssembly.Instance` object for both module and component arguments
(again, with kebab-case component export names converted to lowerCamelCase).

Since the JavaScript embedding is generic, loading all component types, it
needs to allow the JS client to refer to either of the `name` or `URL` fields
of component `externname`s. On the import side, this means that, when a `URL`
is present, *read the imports* will first attempt to [`Get`] the `URL` and, on
failure, `Get` the `name`. On the export side, this means that *both* the
`name` and `URL` are exposed as exports in the export object (both holding the
same value). Since `name` and `URL` are necessarily disjoint sets of strings
(in particular, `URL`s must contain a `:`, `name` must not), there should not
be any conflicts in either of these cases.

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
| `bool` | `true` or `false` | `ToBoolean` |
| `s8`, `s16`, `s32` | as a Number value | `ToInt8`, `ToInt16`, `ToInt32` |
| `u8`, `u16`, `u32` | as a Number value | `ToUint8`, `ToUint16`, `ToUint32` |
| `s64` | as a BigInt value | `ToBigInt64` |
| `u64` | as a BigInt value | `ToBigUint64` |
| `float32`, `float64` | as a Number, mapping the canonical NaN to [JS NaN] | `ToNumber` mapping [JS NaN] to the canonical NaN |
| `char` | same as [`USVString`] | same as [`USVString`], throw if the USV length is not 1 |
| `record` | TBD: maybe a [JS Record]? | same as [`dictionary`] |
| `variant` | see below | see below |
| `list` | create a typed array copy for number types; otherwise produce a JS array (like [`sequence`]) | same as [`sequence`] |
| `string` | same as [`USVString`]  | same as [`USVString`] |
| `tuple` | TBD: maybe a [JS Tuple]? | TBD |
| `flags` | TBD: maybe a [JS Record]? | same as [`dictionary`] of optional `boolean` fields with default values of `false` |
| `enum` | same as [`enum`] | same as [`enum`] |
| `option` | same as [`T?`] | same as [`T?`] |
| `union` | same as [`union`] | same as [`union`] |
| `result` | same as `variant`, but coerce a top-level `error` return value to a thrown exception | same as `variant`, but coerce uncaught exceptions to top-level `error` return values |

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
* For `union` and `option`, when Web IDL doesn't support particular type
  combinations (e.g., `(option (option u32))`), the JS API would fall back to
  the JS API of the unspecialized `variant` (e.g.,
  `(variant (case "some" (option u32)) (case "none"))`, despecializing only
  the problematic outer `option`).
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
the same places where modules can be loaded today, branching on the `layer`
field in the binary format to determine whether to decode as a module or a
component.

When the `URL` field of an imported `externname` is present, the `URL` is
used as the module specifier, using the same resolution path as JS module.
Otherwise, the `name` field is used as the module specifier, which requires
[Import Maps] support to resolve to a `URL`.

The main question is how to deal with component imports having a
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

[`WebAssembly.instantiate()`]: https://developer.mozilla.org/en-US/docs/WebAssembly/JavaScript_interface/instantiate

[JS API]: https://webassembly.github.io/spec/js-api/index.html
[*read the imports*]: https://webassembly.github.io/spec/js-api/index.html#read-the-imports
[*create the exports*]: https://webassembly.github.io/spec/js-api/index.html#create-an-exports-object
[`ToJSValue`]: https://webassembly.github.io/spec/js-api/index.html#tojsvalue
[`ToWebAssemblyValue`]: https://webassembly.github.io/spec/js-api/index.html#towebassemblyvalue
[`USVString`]: https://webidl.spec.whatwg.org/#es-USVString
[`sequence`]: https://webidl.spec.whatwg.org/#es-sequence
[`dictionary`]: https://webidl.spec.whatwg.org/#es-dictionary
[`enum`]: https://webidl.spec.whatwg.org/#es-enumeration
[`T?`]: https://webidl.spec.whatwg.org/#es-nullable-type
[`union`]: https://webidl.spec.whatwg.org/#es-union
[`Get`]: https://tc39.es/ecma262/#sec-get-o-p
[JS NaN]: https://tc39.es/ecma262/#sec-ecmascript-language-types-number-type
[Import Reflection]: https://github.com/tc39-transfer/proposal-import-reflection
[Module Record]: https://tc39.es/ecma262/#sec-abstract-module-records
[Module Specifier]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ModuleSpecifier
[Named Imports]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-NamedImports
[Imported Default Binding]: https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ImportedDefaultBinding
[JS Tuple]: https://github.com/tc39/proposal-record-tuple
[JS Record]: https://github.com/tc39/proposal-record-tuple

[Kebab Case]: https://en.wikipedia.org/wiki/Letter_case#Kebab_case
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
[Interface Definition Language]: https://en.wikipedia.org/wiki/Interface_description_language

[URL Standard]: https://url.spec.whatwg.org
[URI]: https://en.wikipedia.org/wiki/Uniform_Resource_Identifier
[Import Maps]: https://wicg.github.io/import-maps/

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
[Use Cases]: ../high-level/UseCases.md
[Host Embeddings]: ../high-level/UseCases.md#hosts-embedding-components

[`wizer`]: https://github.com/bytecodealliance/wizer

[Scoping and Layering]: https://docs.google.com/presentation/d/1PSC3Q5oFsJEaYyV5lNJvVgh-SNxhySWUqZ6puyojMi8
[Resource and Handle Types]: https://docs.google.com/presentation/d/1ikwS2Ps-KLXFofuS5VAs6Bn14q4LBEaxMjPfLj61UZE
[Future and Stream Types]: https://docs.google.com/presentation/d/1MNVOZ8hdofO3tI0szg_i-Yoy0N2QPU2C--LzVuoGSlE
