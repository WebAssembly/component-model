# Component Model Binary Format Explainer

This document defines the binary format for the AST defined in the
[explainer](Explainer.md). The top-level production is `component` and the
convention is that a file suffixed in `.wasm` may contain either a
[`core:module`] *or* a `component`, using the `kind` field to discriminate
between the two in the first 8 bytes (see [below](#component-definitions) for
more details).

Note: this document is not meant to completely define the decoding or validation
rules, but rather merge the minimal need-to-know elements of both, with just
enough detail to create a prototype. A complete definition of the binary format
and validation will be present in the [formal specification](../../spec/).


## Component Definitions

(See [Component Definitions](Explainer.md#component-definitions) in the explainer.)
```
component ::= <component-preamble> s*:<section>* => (component flatten(s*))
preamble  ::= <magic> <version> <kind>
magic     ::= 0x00 0x61 0x73 0x6D
version   ::= 0x0a 0x00
kind      ::= 0x01 0x00
section   ::=    section_0(<core:custom>)   => ϵ
            | t*:section_1(vec(<type>))     => t*
            | i*:section_2(vec(<import>))   => i*
            | f*:section_3(vec(<func>))     => f*
            | m: section_4(<core:module>)   => m
            | c: section_5(<component>)     => c
            | i*:section_6(vec(<instance>)) => i*
            | e*:section_7(vec(<export>))   => e*
            | s: section_8(<start>)         => s
            | a*:section_9(vec(<alias>))    => a*
```
Notes:
* Reused Core binary rules: [`core:section`], [`core:custom`], [`core:module`]
* The `version` given above is pre-standard. As the proposal changes before
  final standardization, `version` will be bumped from `0xa` upwards to
  coordinate prototypes. When the standard is finalized, `version` will be
  changed one last time to `0x1`. (This mirrors the path taken for the Core
  WebAssembly 1.0 spec.)
* The `kind` field is meant to distinguish modules from components early in the
  binary format. (Core WebAssembly modules already implicitly have a `kind`
  field of `0x0` in their 4 byte [`core:version`] field.)


## Instance Definitions

(See [Instance Definitions](Explainer.md#instance-definitions) in the explainer.)
```
instance     ::= ie:<instance-expr>                                => (instance ie)
instanceexpr ::= 0x00 0x00 m:<moduleidx> a*:vec(<modulearg>)       => (instantiate (module m) (with a)*)
               | 0x00 0x01 c:<componentidx> a*:vec(<componentarg>) => (instantiate (component c) (with a)*)
               | 0x01 e*:vec(<export>)                             => e*
               | 0x02 e*:vec(<core:export>)                        => e*
modulearg    ::= n:<name> 0x02 i:<instanceidx>                     => n (instance i)
componentarg ::= n:<name> 0x00 m:<moduleidx>                       => n (module m)
               | n:<name> 0x01 c:<componentidx>                    => n (component c)
               | n:<name> 0x02 i:<instanceidx>                     => n (instance i)
               | n:<name> 0x03 f:<funcidx>                         => n (func f)
               | n:<name> 0x04 v:<valueidx>                        => n (value v)
               | n:<name> 0x05 t:<typeidx>                         => n (type t)
export       ::= a:<componentarg>                                  => (export a)
name         ::= n:<core:name>                                     => n
```
Notes:
* Reused Core binary rules: [`core:export`], [`core:name`]
* The indices in `modulearg`/`componentarg` are validated according to their
  respective index space, which are built incrementally as each definition is
  validated. In general, unlike core modules, which supports cyclic references
  between (function) definitions, component definitions are strictly acyclic
  and validated in a linear incremental manner, like core wasm instructions.
* The arguments supplied by `instantiate` are validated against the consuming
  module/component according to the [subtyping](Subtyping.md) rules.


## Alias Definitions

(See [Alias Definitions](Explainer.md#alias-definitions) in the explainer.)
```
alias ::= 0x00 0x00 i:<instanceidx> n:<name>     => (alias export i n (module))
        | 0x00 0x01 i:<instanceidx> n:<name>     => (alias export i n (component))
        | 0x00 0x02 i:<instanceidx> n:<name>     => (alias export i n (instance))
        | 0x00 0x03 i:<instanceidx> n:<name>     => (alias export i n (func))
        | 0x00 0x04 i:<instanceidx> n:<name>     => (alias export i n (value))
        | 0x01 0x00 i:<instanceidx> n:<name>     => (alias export i n (func))
        | 0x01 0x01 i:<instanceidx> n:<name>     => (alias export i n (table))
        | 0x01 0x02 i:<instanceidx> n:<name>     => (alias export i n (memory))
        | 0x01 0x03 i:<instanceidx> n:<name>     => (alias export i n (global))
        | ... other Post-MVP Core definition kinds
        | 0x02 0x00 ct:<varu32> i:<moduleidx>    => (alias outer ct i (module))
        | 0x02 0x01 ct:<varu32> i:<componentidx> => (alias outer ct i (component))
        | 0x02 0x05 ct:<varu32> i:<typeidx>      => (alias outer ct i (type))
```
Notes:
* For instance-export aliases (opcodes `0x00` and `0x01`), `i` is validated to
  refer to an instance in the instance index space that exports `n` with the
  specified definition kind.
* For outer aliases (opcode `0x02`), `ct` is validated to be *less or equal
  than* the number of enclosing components and `i` is validated to be a valid
  index in the specified definition's index space of the enclosing component
  indicated by `ct` (counting outward, starting with `0` referring to the
  current component).


## Type Definitions

(See [Type Definitions](Explainer.md#type-definitions) in the explainer.)
```
type              ::= dt:<deftype>                              => dt
                    | it:<intertype>                            => it
deftype           ::= mt:<moduletype>                           => mt
                    | ct:<componenttype>                        => ct
                    | it:<instancetype>                         => it
                    | ft:<functype>                             => ft
                    | vt:<valuetype>                            => vt
moduletype        ::= 0x4f mtd*:vec(<moduletype-def>)           => (module mtd*)
moduletype-def    ::= 0x01 dt:<core:deftype>                    => dt
                    | 0x02 i:<core:import>                      => i
                    | 0x07 n:<name> d:<core:importdesc>         => (export n d)
core:deftype      ::= ft:<core:functype>                        => ft
                    | ... Post-MVP additions                    => ...
componenttype     ::= 0x4e ctd*:vec(<componenttype-def>)        => (component ctd*)
instancetype      ::= 0x4d itd*:vec(<instancetype-def>)         => (instance itd*)
componenttype-def ::= itd:<instancetype-def>                    => itd
                    | 0x02 i:<import>                           => i
instancetype-def  ::= 0x01 t:<type>                             => t
                    | 0x07 n:<name> dt:<deftypeuse>             => (export n dt)
                    | 0x09 a:<alias>                            => a
import            ::= n:<name> dt:<deftypeuse>                  => (import n dt)
deftypeuse        ::= i:<typeidx>                               => type-index-space[i] (must be <deftype>)
functype          ::= 0x4c param*:vec(<param>) t:<intertypeuse> => (func param* (result t))
param             ::= 0x00 t:<intertypeuse>                     => (param t)
                    | 0x01 n:<name> t:<intertypeuse>            => (param n t)
valuetype         ::= 0x4b t:<intertypeuse>                     => (value t)
intertypeuse      ::= i:<typeidx>                               => type-index-space[i] (must be <intertype>)
                    | pit:<primintertype>                       => pit
primintertype     ::= 0x7f                                      => unit
                    | 0x7e                                      => bool
                    | 0x7d                                      => s8
                    | 0x7c                                      => u8
                    | 0x7b                                      => s16
                    | 0x7a                                      => u16
                    | 0x79                                      => s32
                    | 0x78                                      => u32
                    | 0x77                                      => s64
                    | 0x76                                      => u64
                    | 0x75                                      => float32
                    | 0x74                                      => float64
                    | 0x73                                      => char
                    | 0x72                                      => string
intertype         ::= pit:<primintertype>                       => pit
                    | 0x71 field*:vec(<field>)                  => (record field*)
                    | 0x70 case*:vec(<case>)                    => (variant case*)
                    | 0x6f t:<intertypeuse>                     => (list t)
                    | 0x6e t*:vec(<intertypeuse>)               => (tuple t*)
                    | 0x6d n*:vec(<name>)                       => (flags n*)
                    | 0x6c n*:vec(<name>)                       => (enum n*)
                    | 0x6b t*:vec(<intertypeuse>)               => (union t*)
                    | 0x6a t:<intertypeuse>                     => (option t)
                    | 0x69 t:<intertypeuse> u:<intertypeuse>    => (expected t u)
field             ::= n:<name> t:<intertypeuse>                 => (field n t)
case              ::= n:<name> t:<intertypeuse> 0x0             => (case n t)
                    | n:<name> t:<intertypeuse> 0x1 i:<varu32>  => (case n t (defaults-to case-label[i]))
```
Notes:
* Reused Core binary rules: [`core:import`], [`core:importdesc`], [`core:functype`]
* The type opcodes follow the same negative-SLEB128 scheme as Core WebAssembly,
  with type opcodes starting at SLEB128(-1) (`0x7f`) and going down,
  reserving the nonnegative SLEB128s for type indices.
* The (`module`|`component`|`instance`)`type-def` opcodes match the corresponding
  section numbers.
* Module, component and instance types create fresh type index spaces that are
  populated and referenced by their contained definitions. E.g., for a module
  type that imports a function, the `import` `moduletype-def` must be preceded
  by either a `type` or `alias` `moduletype-def` that adds the function type to
  the type index space.
* Currently, the only allowed form of `alias` in instance and module types
  is `(alias outer ct li (type))`. In the future, other kinds of aliases
  will be needed and this restriction will be relaxed.


## Function Definitions

(See [Function Definitions](Explainer.md#function-definitions) in the explainer.)
```
func     ::= body:<funcbody>                                    => (func body)
funcbody ::= 0x00 ft:<typeidx> opt*:vec(<canonopt>) f:<funcidx> => (canon.lift ft opt* f)
           | 0x01 opt*:<canonopt>* f:<funcidx>                  => (canon.lower opt* f)
canonopt ::= 0x00                                               => string=utf8
           | 0x01                                               => string=utf16
           | 0x02                                               => string=latin1+utf16
           | 0x03 i:<instanceidx>                               => (into i)
```
Notes:
* Validation prevents duplicate or conflicting options.
* Validation of `canon.lift` requires `f` to have a `core:functype` that matches
  the canonical-ABI-defined lowering of `ft`. The function defined by
  `canon.lift` has type `ft`.
* Validation of `canon.lower` requires `f` to have a `functype`. The function
  defined by `canon.lower` has a `core:functype` defined by the canonical ABI
  lowering of `f`'s type.
* If the lifting/lowering operations implied by `canon.lift` or `canon.lower`
  require access to `memory`, `realloc` or `free`, then validation will require
  the `(into i)` `canonopt` be present and the corresponding export be present
  in `i`'s `instancetype`.


## Start Definitions

(See [Start Definitions](Explainer.md#start-definitions) in the explainer.)
```
start ::= f:<funcidx> arg*:vec(<valueidx>) => (start f (value arg)*)
```
Notes:
* Validation requires `f` have `functype` with `param` arity and types matching `arg*`.
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

(See [Import and Export Definitions](Explainer.md#import-and-export-definitions) in the explainer.)

As described in the explainer, the binary decode rules of `import` and `export`
have already been defined above.

Notes:
* Validation requires all import and export `name`s are unique.



[`core:version`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-version
[`core:section`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-section
[`core:custom`]: https://webassembly.github.io/spec/core/binary/modules.html#custom-section
[`core:module`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-module
[`core:export`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-export
[`core:name`]: https://webassembly.github.io/spec/core/binary/values.html#binary-name
[`core:import`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-import
[`core:importdesc`]: https://webassembly.github.io/spec/core/binary/modules.html#binary-importdesc
[`core:functype`]: https://webassembly.github.io/spec/core/binary/types.html#binary-functype

[Future Core Type]: https://github.com/WebAssembly/gc/blob/master/proposals/gc/MVP.md#type-definitions
