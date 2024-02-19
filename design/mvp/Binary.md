# Component Model Binary Format Explainer

This document defines the binary format for the AST defined in the
[explainer](Explainer.md). The top-level production is `component` and the
convention is that a file suffixed in `.wasm` may contain either a
[`core:module`] *or* a `component`, using the `layer` field to discriminate
between the two in the first 8 bytes (see [below](#component-definitions) for
more details).

Note: this document is not meant to completely define the decoding or validation
rules, but rather merge the minimal need-to-know elements of both, with just
enough detail to create a prototype. A complete definition of the binary format
and validation will be present in the [formal specification](../../spec/).

See the [explainer introduction](Explainer.md) for an explanation of 🪙.


## Component Definitions

(See [Component Definitions](Explainer.md#component-definitions) in the explainer.)
```ebnf
component ::= <preamble> s*:<section>*            => (component flatten(s*))
preamble  ::= <magic> <version> <layer>
magic     ::= 0x00 0x61 0x73 0x6D
version   ::= 0x0a 0x00
layer     ::= 0x01 0x00
section   ::=    section_0(<core:custom>)         => ϵ
            | m:section_1(<core:module>)          => [core-prefix(m)]
            | i*:section_2(vec(<core:instance>))  => core-prefix(i)*
            | t*:section_3(vec(<core:type>))      => core-prefix(t)*
            | c: section_4(<component>)           => [c]
            | i*:section_5(vec(<instance>))       => i*
            | a*:section_6(vec(<alias>))          => a*
            | t*:section_7(vec(<type>))           => t*
            | c*:section_8(vec(<canon>))          => c*
            | s: section_9(<start>)               => [s]
            | i*:section_10(vec(<import>))        => i*
            | e*:section_11(vec(<export>))        => e*
```
Notes:
* Reused Core binary rules: [`core:section`], [`core:custom`], [`core:module`]
* The `core-prefix(t)` meta-function inserts a `core` token after the leftmost
  paren of `t` (e.g., `core-prefix( (module (func)) )` is `(core module (func))`).
* The `version` given above is pre-standard. As the proposal changes before
  final standardization, `version` will be bumped from `0xa` upwards to
  coordinate prototypes. When the standard is finalized, `version` will be
  changed one last time to `0x1`. (This mirrors the path taken for the Core
  WebAssembly 1.0 spec.)
* The `layer` field is meant to distinguish modules from components early in
  the binary format. (Core WebAssembly modules already implicitly have a
  `layer` field of `0x0` in their 4 byte [`core:version`] field.)


## Instance Definitions

(See [Instance Definitions](Explainer.md#instance-definitions) in the explainer.)
```ebnf
core:instance       ::= ie:<core:instanceexpr>                             => (instance ie)
core:instanceexpr   ::= 0x00 m:<moduleidx> arg*:vec(<core:instantiatearg>) => (instantiate m arg*)
                      | 0x01 e*:vec(<core:inlineexport>)                   => e*
core:instantiatearg ::= n:<core:name> 0x12 i:<instanceidx>                 => (with n (instance i))
core:sortidx        ::= sort:<core:sort> idx:<u32>                         => (sort idx)
core:sort           ::= 0x00                                               => func
                      | 0x01                                               => table
                      | 0x02                                               => memory
                      | 0x03                                               => global
                      | 0x10                                               => type
                      | 0x11                                               => module
                      | 0x12                                               => instance
core:inlineexport   ::= n:<core:name> si:<core:sortidx>                    => (export n si)

instance            ::= ie:<instanceexpr>                                  => (instance ie)
instanceexpr        ::= 0x00 c:<componentidx> arg*:vec(<instantiatearg>)   => (instantiate c arg*)
                      | 0x01 e*:vec(<inlineexport>)                        => e*
instantiatearg      ::= n:<string>  si:<sortidx>                           => (with n si)
string              ::= s:<core:name>                                      => s
sortidx             ::= sort:<sort> idx:<u32>                              => (sort idx)
sort                ::= 0x00 cs:<core:sort>                                => core cs
                      | 0x01                                               => func
                      | 0x02                                               => value 🪙
                      | 0x03                                               => type
                      | 0x04                                               => component
                      | 0x05                                               => instance
inlineexport        ::= n:<exportname> si:<sortidx>                        => (export n si)
```
Notes:
* Reused Core binary rules: [`core:name`], (variable-length encoded) [`core:u32`]
* The `core:sort` values are chosen to match the discriminant opcodes of
  [`core:importdesc`].
* `type` is added to `core:sort` in anticipation of the [type-imports] proposal. Until that
  proposal, core modules won't be able to actually import or export types, however, the
  `type` sort is allowed as part of outer aliases (below).
* `module` and `instance` are added to `core:sort` in anticipation of the [module-linking]
  proposal, which would add these types to Core WebAssembly. Until then, they are useful
  for aliases (below).
* Validation of `core:instantiatearg` initially only allows the `instance`
  sort, but would be extended to accept other sorts as core wasm is extended.
* Validation of `instantiate` requires each `<importname>` in `c` to match a
  `string` in a `with` argument (compared as strings) and for the types to
  match.
* When validating `instantiate`, after each individual type-import is supplied
  via `with`, the actual type supplied is immediately substituted for all uses
  of the import, so that subsequent imports and all exports are now specialized
  to the actual type.
* The indices in `sortidx` are validated according to their `sort`'s index
  spaces, which are built incrementally as each definition is validated.


## Alias Definitions

(See [Alias Definitions](Explainer.md#alias-definitions) in the explainer.)
```ebnf
alias       ::= s:<sort> t:<aliastarget>                => (alias t (s))
aliastarget ::= 0x00 i:<instanceidx> n:<string>         => export i n
              | 0x01 i:<core:instanceidx> n:<core:name> => core export i n
              | 0x02 ct:<u32> idx:<u32>                 => outer ct idx
```
Notes:
* Reused Core binary rules: (variable-length encoded) [`core:u32`]
* For `export` aliases, `i` is validated to refer to an instance in the
  instance index space that exports `n` with the specified `sort`.
* For `outer` aliases, `ct` is validated to be *less or equal than* the number
  of enclosing components and `i` is validated to be a valid
  index in the `sort` index space of the `i`th enclosing component (counting
  outward, starting with `0` referring to the current component).
* For `outer` aliases, validation restricts the `sort` to one
  of `type`, `module` or `component` and additionally requires that the
  outer-aliased type is not a `resource` type (which is generative).


## Type Definitions

(See [Type Definitions](Explainer.md#type-definitions) in the explainer.)
```ebnf
core:type        ::= dt:<core:deftype>                  => (type dt)        (GC proposal)
core:deftype     ::= ft:<core:functype>                 => ft               (WebAssembly 1.0)
                   | st:<core:structtype>               => st               (GC proposal)
                   | at:<core:arraytype>                => at               (GC proposal)
                   | mt:<core:moduletype>               => mt
core:moduletype  ::= 0x50 md*:vec(<core:moduledecl>)    => (module md*)
core:moduledecl  ::= 0x00 i:<core:import>               => i
                   | 0x01 t:<core:type>                 => t
                   | 0x02 a:<core:alias>                => a
                   | 0x03 e:<core:exportdecl>           => e
core:alias       ::= s:<core:sort> t:<core:aliastarget> => (alias t (s))
core:aliastarget ::= 0x01 ct:<u32> idx:<u32>            => outer ct idx
core:importdecl  ::= i:<core:import>                    => i
core:exportdecl  ::= n:<core:name> d:<core:importdesc>  => (export n d)
```
Notes:
* Reused Core binary rules: [`core:import`], [`core:importdesc`], [`core:functype`]
* Validation of `core:moduledecl` rejects `core:moduletype` definitions
  and `outer` aliases of `core:moduletype` definitions inside `type`
  declarators. Thus, as an invariant, when validating a `core:moduletype`, the
  core type index space will not contain any core module types.
* As described in the explainer, each module type is validated with an
  initially-empty type index space.
* `alias` declarators currently only allow `outer` `type` aliases but
  would add `export` aliases when core wasm adds type exports.
* Validation of `outer` aliases cannot see beyond the enclosing core type index
  space. Since core modules and core module types cannot nest in the MVP, this
  means that the maximum `ct` in an MVP `alias` declarator is `1`.

```ebnf
type          ::= dt:<deftype>                            => (type dt)
deftype       ::= dvt:<defvaltype>                        => dvt
                | ft:<functype>                           => ft
                | ct:<componenttype>                      => ct
                | it:<instancetype>                       => it
primvaltype   ::= 0x7f                                    => bool
                | 0x7e                                    => s8
                | 0x7d                                    => u8
                | 0x7c                                    => s16
                | 0x7b                                    => u16
                | 0x7a                                    => s32
                | 0x79                                    => u32
                | 0x78                                    => s64
                | 0x77                                    => u64
                | 0x76                                    => float32
                | 0x75                                    => float64
                | 0x74                                    => char
                | 0x73                                    => string
defvaltype    ::= pvt:<primvaltype>                       => pvt
                | 0x72 lt*:vec(<labelvaltype>)            => (record (field lt)*)    (if |lt*| > 0)
                | 0x71 case*:vec(<case>)                  => (variant case*)
                | 0x70 t:<valtype>                        => (list t)
                | 0x6f t*:vec(<valtype>)                  => (tuple t+)    (if |t*| > 0)
                | 0x6e l*:vec(<label'>)                   => (flags l+)    (if |l*| > 0)
                | 0x6d l*:vec(<label'>)                   => (enum l*)
                | 0x6b t:<valtype>                        => (option t)
                | 0x6a t?:<valtype>? u?:<valtype>?        => (result t? (error u)?)
                | 0x69 i:<typeidx>                        => (own i)
                | 0x68 i:<typeidx>                        => (borrow i)
labelvaltype  ::= l:<label'> t:<valtype>                  => l t
case          ::= l:<label'> t?:<valtype>? 0x00           => (case l t?)
label'        ::= len:<u32> l:<label>                     => l    (if len = |l|)
<T>?          ::= 0x00                                    =>
                | 0x01 t:<T>                              => t
valtype       ::= i:<typeidx>                             => i
                | pvt:<primvaltype>                       => pvt
resourcetype  ::= 0x3f 0x7f f?:<funcidx>?                 => (resource (rep i32) (dtor f)?)
functype      ::= 0x40 ps:<paramlist> rs:<resultlist>     => (func ps rs)
paramlist     ::= lt*:vec(<labelvaltype>)                 => (param lt)*
resultlist    ::= 0x00 t:<valtype>                        => (result t)
                | 0x01 lt*:vec(<labelvaltype>)            => (result lt)*
componenttype ::= 0x41 cd*:vec(<componentdecl>)           => (component cd*)
instancetype  ::= 0x42 id*:vec(<instancedecl>)            => (instance id*)
componentdecl ::= 0x03 id:<importdecl>                    => id
                | id:<instancedecl>                       => id
instancedecl  ::= 0x00 t:<core:type>                      => t
                | 0x01 t:<type>                           => t
                | 0x02 a:<alias>                          => a
                | 0x04 ed:<exportdecl>                    => ed
importdecl    ::= in:<importname'> ed:<externdesc>        => (import in ed)
exportdecl    ::= en:<exportname'> ed:<externdesc>        => (export en ed)
externdesc    ::= 0x00 0x11 i:<core:typeidx>              => (core module (type i))
                | 0x01 i:<typeidx>                        => (func (type i))
                | 0x02 t:<valtype>                        => (value t) 🪙
                | 0x03 b:<typebound>                      => (type b)
                | 0x04 i:<typeidx>                        => (component (type i))
                | 0x05 i:<typeidx>                        => (instance (type i))
typebound     ::= 0x00 i:<typeidx>                        => (eq i)
                | 0x01                                    => (sub resource)
```
Notes:
* The type opcodes follow the same negative-SLEB128 scheme as Core WebAssembly,
  with type opcodes starting at SLEB128(-1) (`0x7f`) and going down,
  reserving the nonnegative SLEB128s for type indices.
* Validation of `valtype` requires the `typeidx` to refer to a `defvaltype`.
* Validation of `own` and `borrow` requires the `typeidx` to refer to a
  resource type.
* Validation of `functype` rejects any transitive use of `borrow` in a
  `result` type. Similarly, validation of components and component types
  rejects any transitive use of `borrow` in an exported value type.
* Validation of `resourcetype` requires the destructor (if present) to have
  type `[i32] -> []`.
* Validation of `instancedecl` (currently) only allows the `type` and
  `instance` sorts in `alias` declarators.
* As described in the explainer, each component and instance type is validated
  with an initially-empty type index space. Outer aliases can be used to pull
  in type definitions from containing components.
* `exportdecl` introduces a new type index that can be used by subsequent type
  definitions. In the `(eq i)` case, the new type index is effectively an alias
  to type `i`. In the `(sub resource)` case, the new type index refers to a
  *fresh* abstract type unequal to every existing type in all existing type
  index spaces. (Note: *subsequent* aliases can introduce new type indices
  equivalent to this fresh type.)
* Validation rejects `resourcetype` type definitions inside `componenttype` and
  `instancettype`. Thus, handle types inside a `componenttype` can only refer
  to resource types that are imported or exported.
* All parameter labels, result labels, record field labels, variant case
  labels, flag labels, enum case labels, component import names, component
  export names, instance import names and instance export names must be
  unique in their containing scope.
* Validation of `externdesc` requires the various `typeidx` type constructors
  to match the preceding `sort`.
* (The `0x00` immediate of `case` may be reinterpreted in the future as the
  `none` case of an optional immediate.)


## Canonical Definitions

(See [Canonical Definitions](Explainer.md#canonical-definitions) in the explainer.)
```ebnf
canon    ::= 0x00 0x00 f:<core:funcidx> opts:<opts> ft:<typeidx> => (canon lift f opts type-index-space[ft])
           | 0x01 0x00 f:<funcidx> opts:<opts>                   => (canon lower f opts (core func))
           | 0x02 rt:<typeidx>                                   => (canon resource.new rt (core func))
           | 0x03 rt:<typdidx>                                   => (canon resource.drop rt (core func))
           | 0x04 rt:<typeidx>                                   => (canon resource.rep rt (core func))
opts     ::= opt*:vec(<canonopt>)                                => opt*
canonopt ::= 0x00                                                => string-encoding=utf8
           | 0x01                                                => string-encoding=utf16
           | 0x02                                                => string-encoding=latin1+utf16
           | 0x03 m:<core:memidx>                                => (memory m)
           | 0x04 f:<core:funcidx>                               => (realloc f)
           | 0x05 f:<core:funcidx>                               => (post-return f)
```
Notes:
* The second `0x00` byte in `canon` stands for the `func` sort and thus the
  `0x00 <u32>` pair standards for a `func` `sortidx` or `core:sortidx`.
* Validation prevents duplicate or conflicting `canonopt`.
* Validation of the individual canonical definitions is described in
  [`CanonicalABI.md`](CanonicalABI.md#canonical-definitions).


## 🪙 Start Definitions

(See [Start Definitions](Explainer.md#start-definitions) in the explainer.)
```ebnf
start ::= f:<funcidx> arg*:vec(<valueidx>) r:<u32> => (start f (value arg)* (result (value))ʳ)
```
Notes:
* Validation requires `f` have `functype` with `param` arity and types matching `arg*`
  and `result` arity `r`.
* Validation appends the `result` types of `f` to the value index space (making
  them available for reference by subsequent definitions).

In addition to the type-compatibility checks mentioned above, the validation
rules for value definitions additionally require that each value is consumed
exactly once. Thus, during validation, each value has an associated "consumed"
boolean flag. When a value is first added to the value index space (via
`import`, `instance`, `alias` or `start`), the flag is clear. When a value is
used (via `export`, `instantiate` or `start`), the flag is set. After
validating the last definition of a component, validation requires all values'
flags are set.


## Import and Export Definitions

(See [Import and Export Definitions](Explainer.md#import-and-export-definitions)
in the explainer.)
```ebnf
import      ::= in:<importname'> ed:<externdesc>                     => (import in ed)
export      ::= en:<exportname'> si:<sortidx> ed?:<externdesc>?      => (export en si ed?)
importname' ::= 0x00 len:<u32> in:<importname>                       => in  (if len = |in|)
exportname' ::= 0x00 len:<u32> en:<exportname>                       => en  (if len = |en|)
```

Notes:
* All exports (of all `sort`s) introduce a new index that aliases the exported
  definition and can be used by all subsequent definitions just like an alias.
* Validation requires that all resource types transitively used in the type of an
  export are introduced by a preceding `importdecl` or `exportdecl`.
* Validation requires any exported `sortidx` to have a valid `externdesc`
  (which disallows core sorts other than `core module`). When the optional
  `externdesc` immediate is present, validation requires it to be a supertype
  of the inferred `externdesc` of the `sortidx`.
* `<importname>` and `<exportname>` refer to the productions defined in the
  [text format](Explainer.md#import-and-export-definitions).
* The `<importname>`s of a component must be unique and the `<exportname>`s of
  a component must be unique as well (defined in terms of raw string equality).
* Validation requires that annotated `plainname`s only occur on `func` imports
  or exports and that the first label of a `[constructor]`, `[method]` or
  `[static]` matches the `plainname` of a preceding `resource` import or
  export, respectively, in the same scope (component, component type or
  instance type).
* Validation of `[constructor]` names requires that the `func` returns a
  `(result (own $R))`, where `$R` is the resource labeled `r`.
* Validation of `[method]` names requires the first parameter of the function
  to be `(param "self" (borrow $R))`, where `$R` is the resource labeled `r`.
* Validation of `[method]` and `[static]` names ensures that all field names
  are disjoint.
* `<valid semver>` is as defined by [https://semver.org](https://semver.org/)
* `<integrity-metadata>` is as defined by the
  [SRI](https://www.w3.org/TR/SRI/#dfn-integrity-metadata) spec.

## Name Section

Like the core wasm [name
section](https://webassembly.github.io/spec/core/appendix/custom.html#name-section)
a similar `name` custom section is specified here for components to be able to
name all the declarations that can happen within a component. Similarly like its
core wasm counterpart validity of this custom section is not required and
engines should not reject components which have an invalid `name` section.

```ebnf
namesec    ::= section_0(namedata)
namedata   ::= n:<name>                (if n = 'component-name')
               name:<componentnamesubsec>?
               sortnames*:<sortnamesubsec>*
namesubsection_N(B) ::= N:<byte> size:<u32> B     (if size == |B|)

componentnamesubsec ::= namesubsection_0(<name>)
sortnamesubsec ::= namesubsection_1(<sortnames>)
sortnames ::= sort:<sort> names:<namemap>

namemap ::= names:vec(<nameassoc>)
nameassoc ::= idx:<u32> name:<name>
```

where `namemap` is the same as for core wasm. A particular `sort` should only
appear once within a `name` section, for example component instances can only be
named once.


[`core:u32`]: https://webassembly.github.io/spec/core/binary/values.html#integers
[`core:section`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-section
[`core:custom`]: https://webassembly.github.io/spec/core/binary/modules.html#custom-section
[`core:module`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-module
[`core:version`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-version
[`core:name`]: https://webassembly.github.io/spec/core/binary/values.html#binary-name
[`core:import`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-import
[`core:importdesc`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-importdesc
[`core:functype`]: https://webassembly.github.io/spec/core/binary/types.html#binary-functype

[type-imports]: https://github.com/WebAssembly/proposal-type-imports/blob/master/proposals/type-imports/Overview.md
[module-linking]: https://github.com/WebAssembly/module-linking/blob/main/proposals/module-linking/Explainer.md
