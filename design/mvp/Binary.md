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


## Component Definitions

(See [Component Definitions](Explainer.md#component-definitions) in the explainer.)
```
component ::= <preamble> s*:<section>*            => (component flatten(s*))
preamble  ::= <magic> <version> <layer>
magic     ::= 0x00 0x61 0x73 0x6D
version   ::= 0x0a 0x00
layer     ::= 0x01 0x00
section   ::=    section_0(<core:custom>)         => ϵ
            | m*:section_1(<core:module>)         => [core-prefix(m)]
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
```
core:instance       ::= ie:<instance-expr>                                 => (instance ie)
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

instance            ::= ie:<instance-expr>                                 => (instance ie)
instanceexpr        ::= 0x00 c:<componentidx> arg*:vec(<instantiatearg>)   => (instantiate c arg*)
                      | 0x01 e*:vec(<inlineexport>)                        => e*
instantiatearg      ::= n:<name> si:<sortidx>                              => (with n si)
sortidx             ::= sort:<sort> idx:<u32>                              => (sort idx)
sort                ::= 0x00 cs:<core:sort>                                => core cs
                      | 0x01                                               => func
                      | 0x02                                               => value
                      | 0x03                                               => type
                      | 0x04                                               => component
                      | 0x05                                               => instance
inlineexport        ::= n:<name> si:<sortidx>                              => (export n si)
name                ::= len:<u32> n:<name-chars>                           => n (if len = |n|)
name-chars          ::= w:<word>                                           => w
                      | n:<name> 0x2d w:<word>                             => n-w
word                ::= w:[0x61-0x7a] x*:[0x30-0x39,0x61-0x7a]*            => char(w)char(x)*
                      | W:[0x41-0x5a] X*:[0x30-0x39,0x41-0x5a]*            => char(W)char(X)*
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
* Validation of `instantiate` requires that `name` is present in an
  `externname` of `c` (with a matching type).
* The indices in `sortidx` are validated according to their `sort`'s index
  spaces, which are built incrementally as each definition is validated.

## Alias Definitions

(See [Alias Definitions](Explainer.md#alias-definitions) in the explainer.)
```
alias       ::= s:<sort> t:<aliastarget>                => (alias t (s))
aliastarget ::= 0x00 i:<instanceidx> n:<name>           => export i n
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
  of `type`, `module` or `component`.


## Type Definitions

(See [Type Definitions](Explainer.md#type-definitions) in the explainer.)
```
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
* Validation of `core:moduledecl` (currently) rejects `core:moduletype` definitions
  inside `type` declarators (i.e., nested core module types).
* As described in the explainer, each module type is validated with an
  initially-empty type index space.
* `alias` declarators currently only allow `outer` `type` aliases but
  would add `export` aliases when core wasm adds type exports.
* Validation of `outer` aliases cannot see beyond the enclosing core type index
  space. Since core modules and core module types cannot nest in the MVP, this
  means that the maximum `ct` in an MVP `alias` declarator is `1`.

```
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
                | 0x72 nt*:vec(<namedvaltype>)            => (record (field nt)*)
                | 0x71 case*:vec(<case>)                  => (variant case*)
                | 0x70 t:<valtype>                        => (list t)
                | 0x6f t*:vec(<valtype>)                  => (tuple t*)
                | 0x6e n*:vec(<name>)                     => (flags n*)
                | 0x6d n*:vec(<name>)                     => (enum n*)
                | 0x6c t*:vec(<valtype>)                  => (union t*)
                | 0x6b t:<valtype>                        => (option t)
                | 0x6a t?:<valtype>? u?:<valtype>?        => (result t? (error u)?)
namedvaltype  ::= n:<name> t:<valtype>                    => n t
case          ::= n:<name> t?:<valtype>? r?:<u32>?        => (case n t? (refines case-label[r])?)
<T>?          ::= 0x00                                    =>
                | 0x01 t:<T>                              => t
valtype       ::= i:<typeidx>                             => i
                | pvt:<primvaltype>                       => pvt
functype      ::= 0x40 ps:<paramlist> rs:<resultlist>     => (func ps rs)
paramlist     ::= nt*:vec(<namedvaltype>)                 => (param nt)*
resultlist    ::= 0x00 t:<valtype>                        => (result t)
                | 0x01 nt*:vec(<namedvaltype>)            => (result nt)*
componenttype ::= 0x41 cd*:vec(<componentdecl>)           => (component cd*)
instancetype  ::= 0x42 id*:vec(<instancedecl>)            => (instance id*)
componentdecl ::= 0x03 id:<importdecl>                    => id
                | id:<instancedecl>                       => id
instancedecl  ::= 0x00 t:<core:type>                      => t
                | 0x01 t:<type>                           => t
                | 0x02 a:<alias>                          => a
                | 0x04 ed:<exportdecl>                    => ed
importdecl    ::= en:<externname> ed:<externdesc>         => (import en ed)
exportdecl    ::= en:<externname> ed:<externdesc>         => (export en ed)
externdesc    ::= 0x00 0x11 i:<core:typeidx>              => (core module (type i))
                | 0x01 i:<typeidx>                        => (func (type i))
                | 0x02 t:<valtype>                        => (value t)
                | 0x03 b:<typebound>                      => (type b)
                | 0x04 i:<typeidx>                        => (instance (type i))
                | 0x05 i:<typeidx>                        => (component (type i))
typebound     ::= 0x00 i:<typeidx>                        => (eq i)
```
Notes:
* The type opcodes follow the same negative-SLEB128 scheme as Core WebAssembly,
  with type opcodes starting at SLEB128(-1) (`0x7f`) and going down,
  reserving the nonnegative SLEB128s for type indices.
* Validation of `valtype` requires the `typeidx` to refer to a `defvaltype`.
* Validation of `instancedecl` (currently) only allows `outer` `type` `alias`
  declarators.
* As described in the explainer, each component and instance type is validated
  with an initially-empty type index space. Outer aliases can be used to pull
  in type definitions from containing components.
* Not only type declarators and type import declarators add to the
  type index space; type export declarators do so as well.
* The uniqueness validation rules for `externname` described below are also
  applied at the instance- and component-type level.
* Validation of `externdesc` requires the various `typeidx` type constructors
  to match the preceding `sort`.
* Validation of function parameter and result names, record field names,
  variant case names, flag names, and enum case names requires that the name be
  unique for the func, record, variant, flags, or enum type definition.
* Validation of the optional `refines` clause of a variant case requires that
  the case index is less than the current case's index (and therefore
  cases are acyclic).


## Canonical Definitions

(See [Canonical Definitions](Explainer.md#canonical-definitions) in the explainer.)
```
canon    ::= 0x00 0x00 f:<core:funcidx> opts:<opts> ft:<typeidx> => (canon lift f opts type-index-space[ft])
           | 0x01 0x00 f:<funcidx> opts:<opts>                   => (canon lower f opts (core func))
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
* Validation of `canon lift` requires `f` to have type `flatten(ft)` (defined
  by the [Canonical ABI](CanonicalABI.md#flattening)). The function being
  defined is given type `ft`.
* Validation of `canon lower` requires `f` to be a component function. The
  function being defined is given core function type `flatten(ft)` where `ft`
  is the `functype` of `f`.
* If the lifting/lowering operations implied by `lift` or `lower` require
  access to `memory` or `realloc`, then validation requires these options to be
  present. If present, `realloc` must have core type
  `(func (param i32 i32 i32 i32) (result i32))`.
* The `post-return` option is only valid for `canon lift` and it is always
  optional; if present, it must have core type `(func (param ...))` where the
  number and types of the parameters must match the results of the core function
  being lifted and itself have no result values.


## Start Definitions

(See [Start Definitions](Explainer.md#start-definitions) in the explainer.)
```
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
```
import     ::= en:<externname> ed:<externdesc> => (import en ed)
export     ::= en:<externname> si:<sortidx>    => (export en si)
externname ::= n:<name> u?:<URL>?              => n u?
URL        ::= b*:vec(byte)                    => char(b)*, if char(b)* parses as a URL
```
Notes:
* The "parses as a URL" condition is defined by executing the [basic URL
  parser] with `char(b)*` as *input*, no optional parameters and non-fatal
  validation errors (which coincides with definition of `URL` in JS and `rust-url`).
* Validation requires any exported `sortidx` to have a valid `externdesc`
  (which disallows core sorts other than `core module`).
* The `name` fields of `externname` must be unique among imports and exports,
  respectively. The `URL` fields of `externname` (that are present) must
  independently unique among imports and exports, respectively.
* URLs are compared for equality by plain byte identity.


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

[Basic URL Parser]: https://url.spec.whatwg.org/#concept-basic-url-parser
