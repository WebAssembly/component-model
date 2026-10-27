# Component Model Explainer

The target audience of this explainer is the WebAssembly Community Group (CG)
and folks already quite familiar with Core WebAssembly at the WAT level; for a
more user-focused explanation, take a look at the Bytecode Alliance's
[Component Model documentation].

The Component Model defines a new executable container format for WebAssembly
modules, called a **component**, that specifies how its contents link together
and interact with the outside world. A useful working metaphor is that a wasm
component is to a wasm module as an ELF executable or OCI container is to x86 or
ARM machine code.

## Problem Statement

The original high-level goals, use cases and design choices for the Component
Model that were written before everything else are in the documents in the
[`high-level`] directory. They're rather general and a bit old so we plan to add
a more focused and updated problem statement to put in this section.

## Walkthrough

This section introduces the major features of the Component Model by walking
through a sequence of example components written in the Component Model text
format, which extends the Core WebAssembly text format (WAT). The walkthrough
stops before describing the concurrency features introduced as part of the 0.3
Developer Preview release; these are covered by the [Concurrency Explainer].
Component Model features that have not yet been [released] are marked with an
"emoji-gate", like [🐘], that is also used to gate the specific text format,
binary format, and ABI additions made by the feature in the reference documents.

### Hello, World!

Like modules, components have imports and exports with names and types through
which components interact with the outside world. However, unlike modules,
component-level value types are high level so that they can be converted
directly to and from guest-language and host values by automated bindings
generators or built-in language integration (collectively called "language
bindings").

As a first example, here is a component with no imports and a single export that
returns the `string` value `"hello world"`:
```wat
(component
  (core module $Main
    (memory (export "mem") 1)
    (data (i32.const 16) "hello world")
    (func (export "greeting") (result i32)
      (local $retp i32)
      (local.set $retp (i32.const 0))
      (i32.store offset=0 (local.get $retp) (i32.const 16)) ;; ptr
      (i32.store offset=4 (local.get $retp) (i32.const 11)) ;; len
      (local.get $retp)
    )
  )
  (core instance $main (instantiate $Main))
  (alias core export $main "greeting" (core func $main-greeting))
  (alias core export $main "mem" (core memory $main-mem))
  (func $greeting (result string)
    (canon lift (core func $main-greeting)
      (memory (core memory $main-mem))
      string-encoding=utf8
    )
  )
  (export "greeting" (func $greeting))
)
```
Like a core module, a component is a sequence of definitions, which we'll walk
through in order:

The first definition, `(core module $Main ...)`, embeds a module using the
standard Core WebAssembly text format with one modification: a `core` token is
added before the `module` token. This `core` prefix is added before all core
wasm definitions at component level to uniformly avoid current or future
ambiguities between core- and component-level definitions (e.g., `func` and
`type`).

The body of `greeting` in `$Main` returns `"hello world"` by returning a
(pointer, length) pair pointing to UTF-8 bytes in linear memory. Currently, the
Component Model ABI does not take advantage of multi-value return (due to
producer toolchain limitations) and thus the (pointer, length) pair must instead
be returned through linear memory, with the address of the *pair* returned as
the actual `i32` return value. In the next iteration of the Component Model
ABI, multi-value return will likely be included.

Next, `(core instance $main (instantiate $Main))` creates a new instance of
`$Main` each time the containing component is instantiated. Without this
`core instance` definition, zero instances of `$Main` would be created and
`$Main` would be dead code. It is also possible to instantiate a single module
*multiple* times with multiple `core instance` definitions. Each `core instance`
definition adds a single index to the `core instance` index space; none of the
instance's exports have associated indices (yet).

Next, the two `(alias ...)` definitions project the `greeting` and `mem` exports
out of the `$main` instance, adding new `core func` and `core memory` indices to
the respective index spaces and binding the WAT identifiers `$main-greeting` and
`$main-mem` to these new indices. Export aliases thus allow a component to
project just the exports of interest from an `instantiate`d (or, as we'll see
later, `import`ed) instance.

Next, `(func $greeting ...)` defines a new component-level function using a
`canon` (short for "Canonical ABI") definition that takes a set of **ABI
options** to specify exactly how this new function is to be implemented. In
particular, the example's `canon` definition specifies:
* to `lift` the core `$main-greeting` function to produce a component-level
  function of type `(func (result string))`;
* to use the memory `$main-mem` to load the string's contents; and
* to decode the string's contents using UTF-8.

Currently, the other two `string-encoding` options are `utf16` and
`latin1+utf16` (the latter corresponds to the [compact strings] optimization).
`utf8` is the default and so `string-encoding` could have been omitted in this
example.

Given the ABI options supplied to `canon`, the Component Model specifies how the
given component-level type (`(func (result string))`) is **lowered** into a
core-level type (`(func (result i32))`). The Component Model's validation rules
for `canon lift` require that this lowered type matches the given core
function (`greeting`). With memory64 ([🐘]), when the `memory` ABI option refers
to a 64-bit memory, the pointers and lengths mentioned above are replaced with
`i64`. In the future, a new ABI option will likely be added for [wasm-gc] to
replace these integer offsets with typed GC references.

The Component Model text format also provides **inline aliases** as syntactic
sugar that implicitly emits export aliases as needed. Using inline aliases, the
two `alias` definitions shown in the example can be removed and replaced by a
succinct inline expression identifying the source instance and the export name:
```wat
  ;; equivalently:
  (func $greeting (result string)
    (canon lift (core func $main "greeting")
      (memory (core memory $main "mem"))
      string-encoding=utf8
    )
  )
```

Lastly, `(export "greeting" (func $greeting))` exports the new component-level
function to the outside world with the name `greeting`. As in core wasm, there
is syntactic sugar that allows writing the `export` inline in the function
definition:
```wat
;; equivalently:
(func (export "greeting") (result string) (canon lift ...))
```

The Component Model's validation rules assign this example component the
following type, which can be written in the Component Model's WAT text format as
a component-level `type` definition:
```wat
(type (component
  (export "greeting" (func (result string)))
))
```
Notably, the `mem` and `greeting` module exports are not present in the
component's type because they are encapsulated by the component and not
accessible to the outside world. Similarly, the ABI options `memory` and
`string-encoding` are not present, as they are also encapsulated implementation
details. This means that any of these core details can change without changing
the component's public interface or breaking existing client code.

### Receiving and returning dynamically-sized values

The next example generalizes `greeting` to take a `name` `string` parameter and
return `"hello {name}"`. In this case, the caller's `string` must be copied into
the callee's memory... but where? Since only the callee's module knows how its
memory is laid out, the Component Model requires the callee to provide a
`realloc` function as an ABI option to `canon lift`. Like libc's `realloc`, the
`realloc` function can be used either to allocate fresh memory or to resize a
previous allocation. Symmetrically, there is a `post-return` ABI option that
allows the callee to release any dynamically allocated memory used for the
return value.
```wat
(component
  (core module $Main
    (memory (export "mem") 1)
    (data (i32.const 16) "hello ")
    (func $libc-malloc (param i32) (result i32) ...)
    (func $libc-realloc (param i32 i32) (result i32) ...)
    (func $libc-free (param i32) ...)
    (func (export "realloc")
          (param $oldPtr i32) (param $oldSize i32) (param $align i32) (param $newSize i32)
          (result i32)
      (call $libc-realloc (local.get $oldPtr) (local.get $newSize))
    )
    (func (export "greeting") (param $namePtr i32) (param $nameLen i32) (result i32)
      (local $ptr i32) (local $len i32) (local $retp i32)
      (local.set $len (i32.add (local.get $nameLen) (i32.const 6 (; = strlen("hello ") ;))))
      (local.set $ptr (call $libc-malloc (local.get $len)))
      (memory.copy (local.get $ptr) (i32.const 16 (; = "hello " ;)) (i32.const 6))
      (memory.copy (i32.add (local.get $ptr) (i32.const 6)) (local.get $namePtr) (local.get $nameLen))
      (call $libc-free (local.get $namePtr))
      (local.set $retp (call $libc-malloc (i32.const 8)))
      (i32.store offset=0 (local.get $retp) (local.get $ptr))
      (i32.store offset=4 (local.get $retp) (local.get $len))
      (local.get $retp)
    )
    (func (export "greeting-post-return") (param $retp i32)
      (call $libc-free (i32.load offset=0 (; = $ptr ;) (local.get $retp)))
      (call $libc-free (local.get $retp))
    )
  )
  (core instance $main (instantiate $Main))
  (func (export "greeting") (param "name" string) (result string)
    (canon lift (core func $main "greeting")
      (post-return (core func $main "greeting-post-return"))
      (memory (core memory $main "mem"))
      (realloc (core func $main "realloc"))
    )
  )
)
```
When a client calls the component-level `greeting` function, before `$Main`'s
`greeting` export is called, the wasm runtime first calls `realloc` to
allocate space in `mem` to copy the `name` argument into. Depending on the
caller's and callee's chosen `string-encoding`, transcoding may be required and
`realloc` may need to be called multiple times to resize in the process. The
final return value of `realloc` and the encoded length of the `string` are then
passed into `greeting`.

The `$retp` value passed to `greeting-post-return` is the same as the
`$retp` value returned by `greeting`. If there is no dynamic allocation, as
in the previous example, the `post-return` ABI option can be omitted. In this
example, both the `string`'s contents and the (pointer, length) pair are
dynamically allocated, so both need to be freed by `greeting-post-return`.

In the next iteration of the Component Model ABI, to address some limitations
with the current approach (including: out-of-memory handling, custom allocators,
recursive value types and zero-copy forwarding) the `realloc` ABI option will
likely be replaced (in a non-breaking transitional manner) with a combination of
caller-supplied buffers and [lazy] value copying. Also, as mentioned above,
multi-value return in the next ABI iteration would avoid the need to return the
(pointer, length) pair through memory.

The Component Model's validation rules assign this component definition the
following component-level type:
```wat
(type (component
  (export "greeting" (func (param "name" string) (result string)))
))
```
Again, all the core-level definitions and ABI options are encapsulated, exposing
only the single component-level export. As shown here, unlike core functions,
component-level functions include parameter names as part of the function type
(and thus stable public interface) so that they can be used to provide ergonomic
language bindings in client code.

### Imports and module linking

Component-level imports differ from module-level imports by having only a single
name string. The two-level naming of core-level imports is instead achieved by
having a component import an "`instance`" which itself contains a set of named
exports. Since the exports of an `instance` can also be `instance`s and since
components can also export `instance`s, components support full N-level
hierarchical naming of both imports and exports.

Using imports, the following component also produces `"hello {name}"` but does
so by calling an imported `name` function, which returns the `name`, and then
calling an imported `greet` function to pass out the result. Symmetric to how
core-level functions can be *lifted* into component-level functions via `canon
lift`, component-level functions can be *lowered* into core-level functions via
`canon lower`. All the work happens during a module `start` function and so the
example component has no exports.

The following component *also* demonstrates the nesting and linking of two
modules within the same component. Having multiple modules is a good way to both
factor out shared code and also to break the cyclic relationship between
`canon lower` and the `$Main` module: `$Main` needs to import the `lower`ed
`name` and `greet` functions while `canon lower` needs `memory` and `realloc`
ABI options.
```wat
(component
  (core module $Alloc
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) ...)
  )
  (core instance $alloc (instantiate $Alloc))
  (import "name" (func $name (result string)))
  (import "actions" (instance $actions
    (export "greet" (func (param "msg" string)))
    ;; potentially other exports, all grouped under "actions"
  ))
  (core func $lowered-name (canon lower (func $name)
    (memory (core memory $alloc "mem"))
    (realloc (core func $alloc "realloc"))
  ))
  (core func $lowered-greet (canon lower (func $actions "greet")
    (memory (core memory $alloc "mem"))
  ))
  (core module $Main
    (import "alloc" "mem" (memory 1))
    (import "alloc" "realloc" (func (param i32 i32 i32 i32) (result i32)))
    (import "lowered" "name" (func (param $outPtr i32)))
    (import "lowered" "greet" (func (param $ptr i32) (param $len i32)))
    (func $start
      ... call name, generate "hello {name}", call greet ...
    )
    (start $start)
  )
  (core instance (instantiate $Main
    (with "alloc" (instance $alloc))
    (with "lowered" (instance
      (export "name" (func $lowered-name))
      (export "greet" (func $lowered-greet))
    ))
  ))
)
```
Walking through the definitions in order:

The first two definitions define and instantiate the `$Alloc` module to produce
an `$alloc` module instance containing `mem` and `realloc` functions that can be
used as ABI options in the following `canon lower` definitions.

Next, `(import "name" (func $name (result string)))` adds a new component-level
function to the component-level `func` index space.

Next, `(import "actions" (instance ...))` demonstrates the `instance` type
mentioned above that nests the `greet` function under `actions` (but also
potentially other functions too). This `import` adds a new component-level
`instance` to the `instance` index space. Notably, the `greet` function is *not*
(yet) added to the `func` index space.

Next, the two `(core func (canon lower ...))` definitions *lower* the two
imported component-level functions, adding new core-level functions to the
`core func` index space. Because `name` was already added to the `func` index
space, it is directly referred to by `(func $name)`. Because `greet` is imported
as part of the `$actions` instance, an inline export alias is used to first
project `greet` from `$actions`, implicitly generating the following
component-level export alias:
```wat
;; equivalently:
(alias export $actions "greet" (func $greet))
(core func $lowered-greet (canon lower (func $greet) ...))
```

Next, `(core module $Main ...)` shows the lowered function types of the `name`
and `greet` functions (which will be explicitly linked to these imports by the
`instantiate` expression below).

In the case of `name`, due to the aforementioned current lack of multi-value
return, the pointer and length of the `string` result are written to a
caller-supplied 8-byte buffer passed as the single `i32` parameter. The `memory`
ABI option is used for both the caller-supplied buffer and the `string`
contents. The `realloc` ABI option is called to allocate the `string` contents.
(As mentioned above, UTF-8 is the default `string-encoding`.)

In the case of `greet`, the pointer and length of the `string` parameter are
passed as the pointer and length `i32` parameters and the `memory` ABI option is
used to read the `string` contents. Since there are no dynamically allocated
results, there is no `realloc` ABI option required.

Lastly, the `(core instance (instantiate $Main ...))` definition really ties the
room together by explicitly specifying how each import of `$Main` is satisfied.
For the two `alloc` imports, the export names of `$alloc` exactly match the
second-level import strings in `$Main` and so `instantiate` can simply pass
`(instance $alloc)`. For the two `lowered` imports, since all we have is two
independent `core func` indices, we have to explicitly bundle them together into
an `instance` that is passed into `instantiate`. In both cases, the choice of
the "`alloc`" and "`lowered`" import names in `$Main` is arbitrary and only
needs to match the `with`-names used in `instantiate`. Thus, components have
considerable flexibility to internally remap names between modules as needed.

The Component Model's validation rules assign this example component the
following component-level type which, due to running everything during a module
`start` function, has no exports:
```wat
(type (component
  (import "name" (func (result string)))
  (import "actions" (instance
    (export "greet" (func (param "msg" string)))
  ))
))
```
Notably, the fact that this component contains two core modules which share
`mem` is kept as an encapsulated implementation detail. Also absent is any
imported ambient namespace used to link the modules as is required by, e.g., ELF
to resolve shared object dependencies. Thus, components are more like Docker
containers, which keep their filesystem an encapsulated detail of the container.

### Value types

In addition to the `string` value type that we've seen in the examples above,
the Component Model defines the following primitive value types:
* `bool`
* integers: `s8`, `u8`, `s16`, `u16`, `s32`, `u32`, `s64`, `u64`
* floats: `f32`, `f64`
* `char`, a [Unicode Scalar Value]

as well as the following compound value types:
* `(record (field "label" T)+)`, a fixed set of named fields
* `(variant (case "label" T?)+)`, a discriminated union with named cases and
  optional payloads
* `(list T N?)`, a sequence, possibly with a fixed length ([🔧])

For example, a list of pairs of `u8` and `u32` integers could be defined as:
```wat
(component
  (type $ListPair (list (record (field "first" u8) (field "second" u32))))
)
```
This "folded" form of type expression is syntactic sugar for defining each
intermediate compound value type with a separate `type` definition (giving each
its own `type` index):
```wat
;; equivalently:
(component
  (type $Pair (record (field "first" u8) (field "second" u32)))
  (type $ListPair (list $Pair))
)
```

The Component Model ABI attempts to pass primitive, `record`, `variant`, and
fixed-length `list` values as scalar Core WebAssembly parameters and results
according to the type-lowering rules. However, if there would be more than 16
core parameters (or 1 core result), all parameters (or results) are passed
through linear memory instead. Additionally, the encoded contents of `string`s
and the elements of dynamic-length `list`s are *always* passed through linear
memory. Thus, the ABI also specifies an in-memory representation for all value
types that uses traditional C-like `struct` and `union` packing and alignment
rules.

As an example, the following component exports a `sum` function that receives a
list of `$Pair` and returns the sum of all the fields. The `list` type is
lowered into a `realloc`ed pointer and length, like `string`, where the pointer
points to a contiguous array of 8-byte `record`s where the `first` field is
followed by 3 padding bytes to keep the `second` field aligned.
```wat
(component
  (core module $Main
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) ...)
    (func (export "sum") (param $ptr i32) (param $len i32) (result i32)
      (local $sum i32)
      (loop $next (result i32)
        (if (i32.eqz (local.get $len)) (then (return (local.get $sum))))
        (local.set $sum (i32.add (local.get $sum) (i32.load8_u (local.get $ptr))))
        (local.set $sum (i32.add (local.get $sum) (i32.load offset=4 (local.get $ptr))))
        (local.set $ptr (i32.add (local.get $ptr) (i32.const 8)))
        (local.set $len (i32.sub (local.get $len) (i32.const 1)))
        (br $next)
      )
    )
  )
  (core instance $main (instantiate $Main))
  (type $pair (record (field "first" u8) (field "second" u32)))
  (export $Pair "byte-word-pair" (type $pair))
  (func (export "sum") (param "input" (list $Pair)) (result u32)
    (canon lift (core func $main "sum")
      (memory (core memory $main "mem"))
      (realloc (core func $main "realloc"))
    )
  )
)
```
To help bindings in languages that do not have structural `record` or `variant`
types, the Component Model imposes an additional [external visibility]
requirement on imported and exported functions: `record` and `variant` types
must have an externally-visible name assigned to them by an `import` or an
`export`. For example, in C, where `struct`s (mostly) require a name, the
`struct` name in the language bindings could be `byte_word_pair` instead
of something purely synthetic invented by the language bindings.

To support this external-visibility requirement, component-level `export`
definitions introduce a new index for whatever they're exporting. This new index
aliases the original definition (like an `alias` definition) but also counts as
being "externally visible". Thus, in the above example, the `$Pair` identifier
bound by:
```wat
(export $Pair "byte-word-pair" (type $pair))
```
refers to a new `type` index introduced by the `export` definition that aliases
the `type` index `$pair`. This allows `$Pair` to be used in `sum`'s function
type; attempting to use `$pair` would be a validation error.

The Component Model's validation rules assign this example component the
following component-level type (using no folded or `$identifier` syntactic sugar
for illustrative purposes):
```wat
(type (component
  (type (;0;) (record (field "first" u8) (field "second" u32)))
  (export (;1;) "byte-word-pair" (type (eq 0)))
  (type (;2;) (list 1))
  (type (;3;) (func (param "input" 2) (result u32)))
  (export "sum" (func (type 3)))
))
```
The `(eq 0)` bound inside `(type ...)` says that the export `byte-word-pair` is
introducing a new name that is transparently `eq`ual to `type` index `0`. In the
next section we'll see an alternative to the `eq` bound.

For more-complex value types like lists-of-lists or lists-of-strings (or lists of
records of strings, ...), `realloc` will be called once for each outer `list`
and then once for each inner `list` or `string`, storing the (pointer, length)
pairs in the elements of the outer `list`. For example, a `(list string)` would
represent the value `["hi", "wasm"]` as:
```
(ptr, len=2)
  |
  v
+-------+-------+-------+-------+
| ptr0  | len=2 | ptr1  | len=4 |
+-------+-------+-------+-------+
  |               |
  v               v
+---+---+       +---+---+---+---+
| h | i |       | w | a | s | m |
+---+---+       +---+---+---+---+
```

Beyond `record`, `variant` and `list`, the Component Model defines additional
value types, like `string`, that are technically just specializations of the
general-purpose type. By including these specializations as distinct type
constructors, these types can be given more idiomatic language bindings and, in
some cases, a more efficient ABI representation than the general-purpose type:

| type | specialization of | example language binding | ABI vs. general-purpose type |
| -- | -- | -- | -- |
| `(tuple T+)` | `record` with integer labels | Python `tuple` | same |
| `(flags "label"+)` | `record` with boolean values | C# `[Flags]` | bitfield |
| `(enum "label"+)` | `variant` with empty payloads | C `enum` | same |
| `(option T)` | `variant` with `none` and `some T` cases | Haskell `Maybe` | same |
| `(result T? (error E)?)` | `variant` with `ok T?` and `error E?` cases | Rust `Result` or exception in languages with EH | same |
| `string` | `(list char)` | C++ `std::string` | variable-length encoding |
| `(map K V)` | `(list (tuple K V))` | JS `Map` | same |

The `flags` and `enum` types have the same [external visibility] requirement as
the `record` and `variant` types for the same reasons as mentioned above.

Value types currently cannot be recursive. For example, the following would fail
validation due to the `$json` `type` index not being defined until *after* the
`variant`:
```wat
(type $json (variant
  (case "null")
  (case "bool" bool)
  (case "number" f64)
  (case "string" string)
  (case "array" (list $json))        ;; ❌
  (case "object" (map string $json)) ;; ❌
))
```
The plan is to enable recursive value types in the future, basing the design on
Core WebAssembly's `rec` groups (once the next ABI iteration makes doing so much
simpler with [lazy] copying).

### Importing resource types

For cases where values are too big to copy or can't be copied, the Component
Model provides **resource types** along with **handle types** that refer to
the resource types.

As an example, the following component imports a `file` resource type along with
some functions that take and return `file` handles:
```wat
(component
  (import "file" (type $file (sub resource)))
  (import "open" (func $open
    (param "path" string) (result (own $file))))
  (import "[method]file.read" (func $read
    (param "self" (borrow $file)) (param "n" u32) (result (list u8))))
  (core module $Alloc ...)
  (core instance $alloc (instantiate $Alloc))
  (core func $lowered-open (canon lower (func $open) ...))
  (core func $lowered-read (canon lower (func $read) ...))
  (core func $file-drop (canon resource.drop $file))
  (core module $Main
    (import "alloc" "mem" (memory 1))
    (import "file" "open" (func $open (param $ptr i32) (param $len i32) (result i32)))
    (import "file" "read" (func $read (param $file i32) (param $n i32) (param $retp i32)))
    (import "file" "drop" (func $drop (param $file i32)))
    (data (i32.const 16) "data.txt")
    (func $start
      (local $file i32) (local $retp i32)
      (local.set $file (call $open (i32.const 16 (; = "data.txt" ;)) (i32.const 8)))
      (local.set $retp (i32.const 0))
      (call $read (local.get $file) (i32.const (; n = ;) 64) (local.get $retp))
      ... use $retp.ptr/len
      (call $drop (local.get $file))
    )
    (start $start)
  )
  (core instance $main (instantiate $Main
    (with "alloc" (instance $alloc))
    (with "file" (instance
      (export "open" (func $lowered-open))
      (export "read" (func $lowered-read))
      (export "drop" (func $file-drop))
    ))
  ))
)
```
Walking through the definitions in order:

The `(import "file" (type $file (sub resource)))` definition appends a new
`type` index for a `resource` type. The `(sub resource)` type bound means that
we're importing some abstract `sub`type of `resource`, the supertype of all
resource types. In the future, more expressive resource subtyping will likely be
added, allowing resource types to be imported with bounds `(sub $rt)`, where
`$rt` is some preceding imported or exported resource type. The `sub` bound
contrasts with the `eq` bound shown in the previous section by introducing a
*new*, *abstract* `sub`type instead of adding a new name that is transparently
`eq`ual to a preceding type.

A `resource` type is *not* a value type and thus cannot be used in the same
places as other value types (e.g., `(func (result $file))` is not a valid type).
Instead, resource types can only be used to define *handle types*, of which
there are currently two: `own` and `borrow`. Handle types *are* value types and
thus *can* be used like other value types with the exception that `borrow`
cannot appear anywhere in a function return type (e.g.,
`(func (param "l" (list (borrow $file))))` is a valid type while
`(func (result (list (borrow $file))))` is not).

Next, the `(import "open" (func ...))` definition imports a function that
returns an `own`ed `file` handle. `own` handles imply unique ownership of the
`resource` they point to. When an `own` handle is passed to `resource.drop`, the
pointed-to resource is destroyed. The meaning of destruction is determined by
whoever defined the imported resource type, which can be the host or, as shown
in the next section, another component. In some cases, the "uniquely-owned
resource" is really just a reference count on a shared object and "destroy" just
means "drop the reference count on the shared object" (analogous to destroying a
C++ `std::shared_ptr` or a Unix file descriptor).

Next, the `(import "[method]file.read" (func ...))` definition imports a
function taking a `borrow`ed `file` handle. `borrow` handles imply that *someone
else* owns this resource and that `resource.drop` does *not* destroy the
resource. Calling a function taking a `borrow` does *not* disable the caller's
handle that was passed as an argument during the call and thus receiving a
`borrow` handle does not imply anything about the exclusivity or mutability of
the pointed-to resource. However, to avoid use-after-free, `borrow` handles *do*
have a trap-enforced ABI calling convention where, until the end of the call,
the caller *must not* drop any of their lent handles and, by the end of the
call, the callee *must* have dropped all of their borrowed handles.

While the import string `[method]file.read` is technically just the function's
name, because it starts with `[method]`, it tells language bindings: if your
language has anything method-like, expose this function as a method of `file`.
Languages without methods can instead mangle the `[method]...` name into a valid
non-method function name (e.g., `file_read`) of a function taking `self` as its
first parameter. Beyond `[method]`, other bindings hints include `[static]`,
`[constructor]`, `[get]`, and `[set]` ([📡]). When any of these annotations is
present, to avoid weird corner cases in language bindings, the Component Model
specifies additional validation conditions on the `func` type (e.g., in the case
of `[method]`, there must be a `borrow`ed `self` parameter of the correct named
resource type).

Next, the contents of the `$Alloc` and `canon lower` definitions are left `...`
since they would work the same as in the previous examples.

Next, the `(core func $file-drop (canon resource.drop $file))` definition
demonstrates a new, third kind of `canon` definition: an **ABI built-in**.
ABI built-ins are like instructions in Core WebAssembly: they don't grant
additional capabilities and thus don't have to be imported. Whereas Core
WebAssembly instructions are written directly inside `func` bodies, ABI
built-ins are introduced as new `core func` indices by `canon` definitions that
can be imported and called by core modules just like `lower`ed functions.

Next, the `$Main` module shows the lowered function types of the two imported
functions and the `resource.drop` ABI built-in. In all three functions, handles
are represented as `i32` indices into a *per-component-instance* handle table
that is maintained by the wasm runtime and *not* directly accessible to the
module.
* For `open`, the returned `i32` refers to a *new* handle table element added to
  the handle table right before returning.
* For `read` and `drop`, the `i32` parameter must refer to a valid handle table
  element of the right type or else there is a trap.
* For `drop`, after the checks, the referred-to resource is destroyed and the
  `i32` index is marked invalid but available for subsequent reuse (which is
  safe because the handle table is per-component-instance).

One interesting thing to notice in `$Main` is that there is no core-level
representation of the resource type `$file`: everything is untyped `i32` indices
and type safety is ensured by dynamic casts performed inside `canon`-defined
functions. In the future, new ABI options could be added to lower handles into
`externref` values instead of `i32` values. In the farther future, if Core
WebAssembly is extended with [type-imports], resource types could be
type-imported by modules, allowing the untyped `i32` or `externref` values to be
replaced by typed references that avoid the dynamic casts.

Lastly, the `(core instance (instantiate $Main ...))` definition links
everything together as above, without any distinction between methods,
non-methods, `lower`ed imports, or ABI built-ins.

The Component Model's validation rules assign this example component the
following component-level type:
```wat
(type (component
  (import "file" (type $file (sub resource)))
  (import "open" (func
    (param "path" string) (result (own $file))))
  (import "[method]file.read" (func
    (param "self" (borrow $file)) (param "n" u32) (result (list u8))))
))
```
Notably, the `i32` indices have been encapsulated by the component, so that
components can pass handles between each other without having to share an
ambient handle table (similar to how Unix processes can pass file descriptors
between each other via `sendmsg` without relying on the ambient filesystem).

### Defining and exporting resource types

In addition to *importing* resource types, as shown in the previous example,
components can also *define* and *export* resource types. When a component
defines a resource type, the component gets to pick a **representation type**
for the resource as well as a **destructor function** that is called when
the resource is destroyed. Additionally, the component defining the resource
type (and only that component) can use two ABI built-ins:
* `resource.new`, which boxes a given representation value into a new resource
  pointed to by a new `own`ed handle; and
* `resource.rep`, which returns the representation value of the resource pointed
  to by the given handle.

As an example, the following component defines and exports a `file` resource
type which, along with the exported `open` and `[method]file.read` functions,
could be used to implement (i.e. virtualize) the imports of the previous
section's example component:
```wat
(component
  (core module $Alloc ...)
  (core instance $alloc (instantiate $Alloc))
  (type $file (resource (rep i64) (dtor (core func $alloc "free"))))
  (core func $file-new (canon resource.new $file))
  (core module $Main
    (import "alloc" "mem" (memory i64 1))
    (import "alloc" "malloc" (func $malloc (param i64) (result i64)))
    (import "file" "new" (func $new (param i64) (result i32)))
    (func (export "open") (param $pathPtr i64) (param $pathLen i64) (result i32)
      (local $ptr i64)
      (local.set $ptr (call $malloc (i64.const ...)))
      ... initialize $ptr
      (call $new (local.get $ptr))
    )
    (func (export "read") (param $ptr i64) (param $n i32) (result i64)
      ... use $ptr ... return (list u8) ...
    )
  )
  (core instance $main (instantiate $Main
    (with "alloc" (instance $alloc))
    (with "file" (instance (export "new" (func $file-new))))
  ))
  (export $File "file" (type $file))
  (func (export "open") (param "path" string) (result (own $File))
    (canon lift (core func $main "open") ...)
  )
  (func (export "[method]file.read") (param "self" (borrow $File)) (param "n" u32) (result (list u8))
    (canon lift (core func $main "read") ...)
  )
)
```
Walking through the definitions in order, starting after `$alloc`:

The `(type $file (resource ...))` defines a new resource type with an `i64`
representation type that, when destroyed, calls the `free` function exported by
`$alloc` to free the memory allocation. Currently, `i32` and `i64` [🐘] are the
only allowed representation types but, in the future, as part of [wasm-gc]
support, reference types could be added. In any case, the general idea is that a
resource's representation value is pointer-like and pointer-sized. This example
uses a 64-bit `memory` and thus specifies an `i64` resource representation.

Next, the `(core func $file-new (canon resource.new $file))` definition appends
a new `core func` index for the `resource.new` ABI built-in. As this definition
shows, ABI built-ins can be parameterized by types, just like Core WebAssembly
instructions. In this case, passing `$file` tells `resource.new` which type tag
to attach to the new handle entry (which is later used for the dynamic casts).
Component validation requires the given `type` index to be a resource type that
was defined in the same component, ensuring that components are always able to
encapsulate the construction and representation of their own resource types.

Next, the `$Main` module shows the lowered function type of `resource.new`
which is imported as `file` `new`. The `i64` parameter of `new` matches the
`rep` type of `$file`. Regardless of `rep`, the result is always the `i32` index
of a new `own` handle added to the caller's handle table. Thus, when a component
implements a resource type, it starts out as the owner of all new resources of
that type. Ownership of new resources is then handed out via `own` handles,
which is what `open` does in this example with its `(own $file)` return type.
Specifically, when the `i32` return value of `(call $new ...)` is returned from
`open`, the wasm runtime removes the `own` handle from the callee's handle table
and adds it to the caller's handle table, thereby *transferring* ownership from
the callee to the caller.

The `read` function exported by `$Main` is `lift`ed to implement the
`[method]file.read` function exported by the component. The component-level
first parameter of `[method]file.read` is `(param "self" (borrow $File))` which
would normally be lowered to an `i32` handle index. However, as an ABI-level
optimization, because this `canon lift` definition is inside the same component
that defines `$file`, the first lowered parameter type is `i64`, matching the
`(rep i64)` of `$file`. This optimization skips the per-call overhead of adding
a borrowed handle to the handle table, calling `resource.rep` to get the `i64`,
and then calling `resource.drop` to remove the borrowed handle from the handle
table.

Because of all the static and dynamic checks described above, `open` and `read`
can rely on the following useful guarantees:
* the `$ptr` value passed to `read` actually came from `open`
* `free($ptr)` will be called when the owner drops their handle to the resource
* `read($ptr)` won't be called after `free($ptr)`

Next, the `(core instance (instantiate $Main ...))` definition links everything
together as in previous examples.

Next, the `(export $File "file" (type $file))` definition makes the `$file`
resource type externally visible to clients with the export name `file`.
Resource types have the same [external visibility] requirements as `record`,
`variant`, `enum` and `flags` as described above which means that `$File` (the
`type` index introduced by `export`) must be used in exported functions instead
of `$file`.

Lastly, the two `(func (export ...) ...)` definitions `lift` and `export` the
core-level `open` and `read` functions as the component-level `open` and
`[method]file.read` functions. There are no new or special ABI options needed
for resource types in these functions; just the regular `memory` and `realloc`
ABI options needed for the `string` and `list` params and results.

The Component Model's validation rules assign this example component the
following component-level type (which is the same as the previous example's type
after replacing `import` with `export`):
```wat
(type (component
  (export "file" (type $File (sub resource)))
  (export "open" (func
    (param "path" string) (result (own $File))))
  (export "[method]file.read" (func
    (param "self" (borrow $File)) (param "n" u32) (result (list u8))))
))
```
Notably, the `i64` address type of `memory` and representation type of `file`
are kept as an encapsulated implementation detail of the component and thus this
64-bit component can be imported and called by the 32-bit component shown in the
previous section without a problem. This encapsulation also means that
components can change their memory and resource representation types over time
without breaking clients.

### Structured names and attributes

Earlier sections mentioned how `[method]` and a few other name prefixes can be
used as hints in API names to improve the ergonomics of language bindings (in
languages with these concepts). This section describes several other hints
embedded in imports and exports that can improve language bindings.

The general theme here is that when a hint contributes to a name's uniqueness
and may be mangled into a source-level function name, the hint goes into the
name string, like `[method]`. This allows the name string to be used by simple
tools that "just want a string" (like linkers, debuggers and profilers) without
making these tools care about the additional structure or how to canonically
serialize it into a string. When these conditions don't apply, the hints are
instead put into **attributes** that are part of the import/export definition
but are part of neither the name nor the type. Because best-effort
"content-sniffing" of patterns in arbitrary strings is a recipe for disaster,
the Component Model defines and enforces a strict grammar of allowed name
strings that avoids ambiguous interpretation both now and as new language
binding hints are added in the future.

The first hint aims to allow language bindings to use the idiomatic casing
scheme of their language so that API authors don't have to arbitrarily pick one
that applies to all languages. To do this, multi-word names are required to be
explicitly separated by hyphens (aka [kebab case]) and words must either be
all-lowercase or, if they represent acronyms, all-uppercase. Based on this,
language bindings are expected to case and concatenate the words and acronyms
according to their local style. Consequently, the names `myFoo`, `my-Foo`,
and `my_foo` are not valid and, depending on the language:
* `my-foo` could turn into `my_foo`, `My_foo`, `MY_FOO`, `myFoo` or `MyFoo`; and
* `my-JSON-parser` could turn into `my_json_parser`, `My_json_parser`,
  `MY_JSON_PARSER`, `myJsonParser`, `myJSONParser`, `MyJsonParser` or
  `MyJSONParser`.

Kebab-cased strings can be used in conjunction with `[method]` and other
prefixes, e.g.:
```wat
(component
  (import "file-handle" (type $FD (sub resource)))
  (import "[method]file-handle.read-as-JSON" (func ...))
)
```

While the restricted syntax of kebab-cased strings allows simple, idiomatic
casing in language bindings, it can be a problem if an import or export name
needs to be some arbitrary Unicode string. For example, with ECMAScript Module
integration ([ESM-integration]), components loaded as ESMs would have their
import names interpreted as [module specifier] strings, which can be arbitrary
Unicode strings (including URLs). For these and other use cases, component
imports and exports may have an `external-id` attribute that is separate
from the name (and thus not used for language bindings) and separate from the
type (and thus not part of the static or dynamic semantics). For example, if the
following component is loaded as an ESM, the given URL would be fetched by the
ESM loader and the `slugify` name would be ignored:
```wat
(component
  (import "slugify"
    (external-id "https://esm.unpkg.com/slugify@1.6.6")
    (func (param "text" string) (result string)))
)
```

The next hint aims to improve language bindings when API authors use
hierarchical naming to avoid name clashes in published, possibly-standard names.
In particular, the goal is to avoid long clunky names everywhere by instead
mapping the hierarchical name into the language's existing support for packages,
modules or namespaces. To do this, in addition to the kebab-case **plain names**
shown above, component names can also be **interface names** which are a triplet
of: namespace `:` package name `/` package item name. For example:
```wat
(component
  (import "wasi:http/client" (instance ...))
)
```
Language bindings for guest code running in this component could then see, e.g.,
`client` inside an `http` module inside a `wasi` module. In the future, this
triplet structure may be generalized to allow nesting ([🪺]) of both namespaces
and package names (with the distinction being that the top-level package is
published with a version while the namespaces above it aren't).

Next, to support API authors with versioning, interface names may optionally end
with `@` followed by a [SemVer] version string:
```wat
(component
  (import "wasi:http/client@0.3.0" (instance ...))
)
```
By including the version in the name, hosts can easily provide multiple
side-by-side versions of the same API.

To support name-based linking where names, not indices, identify an import or
export, the Component Model requires all import names in the same component to
be unique (and similarly for exports). However, sometimes a component may want
to import multiple implementations of the same interface name. For example:
*multiple* `wasi:http/client` backends or *multiple* `wasi:keyvalue/store`s. To
resolve this tension, interface names can alternatively be put in an `implements`
attribute of a plain-named import or export. For example:
```wat
(component
  (import "a" (implements "wasi:http/client@0.3.0") (instance ...))
  (import "b" (implements "wasi:http/client@0.3.0") (instance ...))
  (import "c" (implements "wasi:keyvalue/store@0.1.0") (instance ...))
  (import "d" (implements "wasi:keyvalue/store@0.1.0") (instance ...))
)
```
In this example, `a` through `d` are the *names* of the four imports and thus
can be used for name-based linking as usual, while the interface names in the
`implements` attribute are metadata that a runtime or tool can use to resolve
`a` through `d` or provide feedback to the developer during interactive
development or debugging.

Lastly, `implements` and `external-id` can be used together when their
independent use cases both apply, e.g.:
```wat
(component
  (import "a" (implements "wasi:http/client@0.3.0") (external-id "backend~1") (instance ...))
  (import "b" (implements "wasi:http/client@0.3.0") (external-id "backend~2") (instance ...))
  (import "c" (implements "wasi:keyvalue/store@0.1.0") (external-id "redis://localhost:6379/0") (instance ...))
  (import "d" (implements "wasi:keyvalue/store@0.1.0") (external-id "memcached://localhost:11211") (instance ...))
)
```
In this example, `a` through `d` are, as always, the unique names used by
`instantiate` expressions in parent components, manual host linking APIs (like
`WebAssembly.instantiate`) and guest language bindings to unambiguously refer to
these four imports. However, a host or tool that has built-in support for the
`wasi:http/client` and `wasi:keyvalue/store` interfaces can recognize these
interface names in the `implements` attributes and then use the `external-id`
payload strings to automatically generate the four arguments passed to the
imports `a` through `d`.

### Component linking

One way to link components together is using host-specific APIs such as the [JS
API]'s proposed component support in `WebAssembly.instantiate`. However linking
components using host-specific APIs makes the composed application no longer
portable across different kinds of hosts (e.g., between browsers and
non-browsers) and makes the composite no longer distributable as a single
artifact. To address these problems, the Component Model allows components to
nest not just modules but also components and to link these components together
in the same way as shown above for modules. Consequently, a single component can
nest both modules *and* components *and* arbitrarily link them together, using
lifting and lowering definitions to bridge the module/component type boundary
as necessary.

For example, the following example component contains abridged versions of the
`file`-importing and `file`-exporting example components shown in earlier
sections. To better illustrate the full linking story, the `file`-exporting
component is given a new `backing-store` import (presumably used to implement
the `file`) and the `file`-importing component is given an additional
`hash-file` import (that is *not* implemented by the `file`-exporting component)
and a `run` export.
```wat
(component
  (component $FileExporter
    (import "backing-store" (instance ...))
    ...
    (export "file" (type ...))
    (export "open" (func ...))
    (export "[method]file.read" (func ...))
  )
  (component $FileImporter
    (import "file" (type $File (sub resource)))
    (import "open" (func ...))
    (import "[method]file.read" (func ...))
    (import "hash-file" (func (param "file" (borrow $File)) (result u64)))
    ...
    (export "run" (func ...))
  )
  (import "backing-store" (instance $backing-store ...))
  (instance $exporter (instantiate $FileExporter
    (with "backing-store" (instance $backing-store))
  ))
  (core module $FileHasher
    (import "file" "read" (func ...))
    ...
    (func (export "hash") (param $fileHandle i32) (result i64) ...)
  )
  (core func $fileRead
    (canon lower (func $exporter "[method]file.read") ...)
  )
  (core instance $fileHasher (instantiate $FileHasher
    (with "file" (instance (export "read" (func $fileRead))))
  ))
  (alias export $exporter "file" (type $File))
  (func $hashFile (param "file" (borrow $File)) (result u64)
    (canon lift (core func $fileHasher "hash") ...)
  )
  (instance $importer (instantiate $FileImporter
    (with "file" (type $File))
    (with "open" (func $exporter "open"))
    (with "[method]file.read" (func $exporter "[method]file.read"))
    (with "hash-file" (func $hashFile))
  ))
  (export "run" (func $importer "run"))
)
```
Walking through the definitions in order:

The first two `component` definitions add two new indices to the `component`
index space. When one component is nested inside another component, the inner
component is called a **child component** and the outer component is called a
**parent component**. Because components can nest N-deep, parent and child
components form a **component tree**.

Next, the `(import "backing-store" ...)` definition is used to import a
`backing-store` instance that is used to instantiate `$FileExporter` in the
following `(instance $exporter ...)` definition.

When one component `instantiate`s another component, at runtime, the component
instance created by `instantiate` is called a **child component instance** and
the component instance that performed the `instantiate` is called the **parent
component instance**. Because instances can nest N-deep, parents and children
form a (component) **instance tree**. This *instance tree* is meaningfully
different from the aforementioned *component tree* in three ways:
* The *component tree* is static (reflecting nesting of bytes in the binary
  format) while the *instance tree* is dynamic (describing runtime state).
* Parent components can `instantiate` 0..N instances of child components and so
  the component tree can be both "narrower" and "wider" than the instance tree.
* The next section will show how child instances can be created not just
  from nested components, but also *imported* components, in which case the
  component and instance trees can be totally dissimilar.

The next 5 definitions use the `core module`, `canon lower`, `core instance`,
`alias export`, and `canon lift` definitions introduced in the previous sections
to define and instantiate the `$FileHasher` module to implement the `$hashFile`
function. In contrast to the previous examples of lifting and lowering,
`$FileHasher`'s lowered import comes from a sibling component instance
(`$exporter`), not an import, and `$FileHasher`'s lifted export feeds into a
sibling component instance (`$importer`), not an export. This demonstrates the
orthogonality of lifting and lowering from importing and exporting.

Next, the `(instance $importer ...)` definition links everything together,
fulfilling `$FileImporter`'s imports from both the preceding `$exporter` sibling
component instance and the parent's `$hashFile` function. Equivalently, the
first three imports of `$FileImporter` could have been grouped together into a
single `instance` import, which would then replace the first three `(with ...)`
arguments with a single `(with "..." (instance $exporter))` argument.

Lastly, the `(export "run" (func $importer "run"))` definition uses an inline
alias and re-exports `$importer`'s exported `run` function from the parent
component. Without this re-export, `run` would not be callable from outside the
parent component and thus the only child wasm code that got to run would be
the module `start` functions executing during instantiation.

The Component Model's validation rules assign this example component the
following component-level type:
```wat
(type (component
  (import "backing-store" (instance ...))
  (export "run" (func ...))
))
```
Notably, `$FileExporter`, `$FileHasher`, `$FileImporter` and the `file` resource
type shared between them are absent from the type because they are kept as an
encapsulated implementation detail of the parent component. This reflects the
fact that the parent component completely determines (via `instantiate`) how its
children's imports are supplied and exports are used (even when seemingly-global
interface names or `external-id`s are present).

In particular, if a parent component wants to instantiate a child component with
an import `I`, there are 3 choices:
1. the parent can import `I` (as shown above for `backing-store`)
2. the parent can instantiate a child that exports `I` (as shown above for `open`)
3. the parent can implement `I` itself (as shown above for `hash-file`)

Under no circumstance is a child component's import implicitly satisfied
directly by the host or grandparent without going through the parent: if the
child has an import `I` that is not satisfied by a `(with "I" ...)` in the
parent's `instantiate` expression, there is a validation error. This guarantee,
combined with the resource type guarantees mentioned earlier, provides a
foundation for implementing link-time and run-time [capability-based security].

When this parent component is instantiated and the exported `run` function is
called, control flow will transfer directly into `$FileImporter`'s internal
module(s). When `$FileImporter` calls `open` or `[method]file.read`, control
flow will then synchronously call directly into `$FileExporter`'s internal
module(s), and when `$FileImporter` calls `hash-file`, control flow will
synchronously call into `$FileHasher`, which in turn calls into
`$FileExporter`. In all cases, calls happen on the same native stack (without a
context switch, unlike native cross-process communication) and copy any
parameters and results directly between the caller's and callee's memories
(without an intermediate buffer, unlike native pipe- or socket-based
communication). Thus, a parent component is somewhat like the `compose.yaml`
file passed to [Docker Compose] and the two child components are like two
containers that communicate over the private network created by Docker Compose
(just with much, much lower overhead). A more structural difference is that,
unlike `compose.yaml`, a parent component can have its own executable code
(`$FileHasher`) which enables the more-advanced virtualization techniques shown
[below](#virtualization-and-donut-wrapping).

### Factoring out shared code

One benefit of splitting a component's core wasm code into multiple modules is
that runtimes can cache and share the compiled machine code of identical modules
between different components or between different versions of the same
component. To enable this optimization, producer toolchains can split out
separate modules for common utility code like memory allocation, the language
runtime, and chunks of the language's standard library. However, even though
this optimization would deduplicate machine code at runtime, there are still
duplicate wasm bytes in each component's binary. To go further and factor the
common code out of the component binary, components can use **module imports**
to *import* the common module by name.

For example, the following component replaces the nested `$Alloc` definition
that we've seen in previous example components with a core module import:
```wat
(component
  (import "alloc" (core module $Alloc
    (export "mem" (memory 1))
    (export "realloc" (func (param i32 i32 i32 i32) (result i32)))
  ))
  (core instance $alloc (instantiate $Alloc)) ;; unchanged instantiation
  ... the rest is also unchanged
)
```
Notably, the only thing that needs to change is replacing the nested module
definition with an `import` of a matching `core module` type.

But how does the `alloc` import get resolved by the host (and with what)? There
are several options here depending on the toolchain and host environment:
* In the browser:
  * `alloc` could be satisfied by an [import map] generated by the toolchain
    (just like bareword imports in JS modules).
  * `alloc` could be satisfied by JS glue using `WebAssembly.instantiate` in the
    [JS API].
* Outside the browser:
  * `alloc` could be satisfied by a different language's WebAssembly embedding
    API in the same way as with the [JS API].
  * `alloc` could be a name statically baked into the runtime for known common
    modules.
* In both cases:
  * `alloc` could be supplied by a parent component that nests multiple
    components (as child components) along with their shared modules.

As an example of the final option, the following parent component nests a single
`$Alloc` module that is passed into both nested children via `instantiate`:
```wat
(component $Bundle
  (core module $Alloc ...)
  (component $A
    (import "alloc" (core module ...))
    ...
  )
  (component $B
    (import "alloc" (core module ...))
    ...
  )
  (instance $a (instantiate $A (with "alloc" (core module $Alloc)) ...))
  (instance $b (instantiate $B (with "alloc" (core module $Alloc)) ...))
)
```

In addition to the above options, components that only need to run on a single
kind of host can use the `external-id` attribute that was introduced
[above](#structured-names-and-attributes) to attach an arbitrary Unicode string
to the import that is then interpreted by the host as a URL (or whatever
works like a URL on the host, e.g., an [OCI Artifact Reference] referring to a
[Wasm OCI Artifact]).

In a browser setting, [ESM-integration] treats an `external-id` as a [module
specifier] and so the following component could be loaded directly from a
`<script>` tag, having its module import automatically fetched by the ESM
machinery without any JS glue code or import map:
```wat
(component
  (import "alloc" (external-id "https://example.com/common/libc-1-2.wasm")
    (core module $Alloc
      (export "mem" (memory 1))
      (export "realloc" (func (param i32 i32 i32 i32) (result i32)))
    )
  )
  ...
)
```
Compared to the `$Bundle` approach shown above, using imports with URLs allows
modules to be separately cached (along with their compiled machine code) in the
browser's HTTP cache, minimizing the re-fetch and re-compile cost whenever
there is a change. As modern bundlers already do for JS modules, an extended
component-aware bundler could use heuristics and profiling information to
perform selective bundling to balance the number of network requests with
cacheability. The Component Model natively supports this kind of late-stage,
deployment-oriented optimization by allowing language-independent component
tools to generically transform back and forth between imports and nested
definitions.

Lastly, in addition to importing *modules*, components can also import other
*components* via **component imports**. Just like with modules, components are
imported *uninstantiated* via a `component` type that declares both the
component's imports and exports.

In addition to enabling various advanced virtualization scenarios (as shown in
the next section), component imports allow components to serve as executable
[lock files] that can resolve dependencies to the exact desired version of a
module or component. For example, the following component contains no inline
core wasm code and instead imports and links together `$Alloc`, `$A` and `$B`
using `external-id`s that point to particular artifacts via URL, OCI Artifact
Reference, or whatever else the host natively supports.
```wat
(component $LockFile
  (import "alloc" (external-id "...") (core module $Alloc ...))
  (import "a" (external-id "...") (component $A ...))
  (import "b" (external-id "...") (component $B ...))
  (instance $a (instantiate $A (with "alloc" (core module $Alloc)) ...))
  (instance $b (instantiate $B (with "alloc" (core module $Alloc)) ...))
)
```

At the moment, there is limited implementation support for top-level module and
component imports in runtimes, but support will hopefully expand as component
applications progress to the point where these optimizations are valuable.

As this and previous sections demonstrate, the Component Model allows
simultaneously linking together modules (which share core memory and table
state when linked within a single component instance) and components (which
don't). Another way to say this is that the Component Model supports both
**shared-nothing** (component) linking and **shared-everything** (module)
linking. For more on linking, see the [Linking Explainer].

### Virtualization and "donut wrapping"

One powerful application of the Component Model functionality presented above is
[virtualization], in which a parent component interposes on all calls into and
out of a child component to implement the child's expected execution environment
in terms of the parent's base execution environment.

As an example, let's start with a component (or a family of components) that we
want to run with the following type that approximates a reusable, composable
[HTTP Intermediary]:
```wat
(type $HttpGuest (component
  (import "request" (type $Request (sub resource)))
  (import "response" (type $Response (sub resource)))
  ... various other request/response methods/functions
  (import "send" (func (param "r" (own $Request)) (result (own $Response))))
  (export "receive" (func (param "r" (own $Request)) (result (own $Response))))
))
```

Such a component could run directly in an embedding that natively implements
`request`, `response` and `send` and calls `receive`. However, let's say that
we'd instead like to run this component on a host that only natively implements
a lower-level [BSD Sockets] interface, allowing it to only run components that
match the following `$SocketServer` type:
```wat
(type $SocketServer (component
  (import "net" (instance
    (export "socket" (type $Socket (sub resource)))
    (export "[constructor]socket" (func ... (result (own $Socket))))
    (export "[method]socket.accept" (func (param "self" (borrow $Socket)) ...))
    ... various other socket operations
  ))
  (export "serve" (func))
))
```

To run an `$HttpGuest` component on a `$SocketServer` host, we can use the
following `$HttpServer` component, which implements the HTTP protocol in terms
of `$SocketServer` in order to **virtualize** the `$HttpGuest` execution
environment. This example is a bit more involved than the previous examples and
so it's presented in chunks.

The first chunk of `$HttpServer` imports and lowers the `net` import of
`$SocketServer` and defines the `resource.drop` function that is used to drop
unneeded `socket` resources.
```wat
(component $HttpServer
  (import "net" (instance $net
    (export "socket" (type $Socket (sub resource)))
    (export "[constructor]socket" (func ... (result (own $Socket))))
    (export "[method]socket.accept" (func (param "self" (borrow $Socket)) ...))
    ...
  ))
  (alias export $net "socket" (type $socket))
  (canon resource.drop $socket (core func $builtin-socket-drop))
  (core func $lowered-socket-new (canon lower (func $net "[constructor]socket") ...))
  (core func $lowered-socket-accept (canon lower (func $net "[method]socket.accept") ...))
  ...
```

Next, `$HttpServer` needs to internally break a dependency cycle between its own
nested module and the `$HttpGuest` component that is being virtualized: the
guest needs to import `request`, `response` and `send` while the server needs to
import the guest's exported `receive`. To break this cycle, the server can use a
`table` of `funcref` that gets initialized with `ref.null` up front and gets
updated with the real functions at the end. The `$LinkageTable` helper module
defined and instantiated in this next chunk starts this process by defining the
table and all the functions that need to have a cycle broken using
`call_indirect`.
```wat
  (core module $LinkageTable
    (table (export "ftbl") 3 3 funcref)
    (type $FI (func (param i32)))
    (type $FI2I (func (param i32) (result i32)))
    (func (export "request-dtor") (type $FI) (call_indirect (type $FI) (local.get 0) (i32.const 0)))
    (func (export "response-dtor") (type $FI) (call_indirect (type $FI) (local.get 0) (i32.const 1)))
    (func (export "receive") (type $FI2I) (call_indirect (type $FI2I) (local.get 0) (i32.const 2)))
  )
  (core instance $linkage-table (instantiate $LinkageTable))
```

The next chunk defines the `request` and `response` resource types along with
the `resource.{new,rep,drop}` ABI built-ins that allow `$HttpServer`'s nested
module to create, dereference and destroy handles to resource types. As
mentioned above, only the component that *defines* a resource type has access to
`resource.{new,rep}`, which is what allows `$HttpServer` to virtualize these
resource types without the guest components being able to see through the
abstraction. Defining `request` and `response` requires breaking another cycle:
the resource type definitions need destructor functions that are implemented by
the module below, but the module below needs to import the ABI built-ins that
we're trying to define here that require the resource types. Thus,
`$LinkageTable` above includes the destructor functions so that they can be
aliased here and patched below.
```wat
  (type $request (resource (rep i32) (dtor (core func $linkage-table "request-dtor"))))
  (type $response (resource (rep i32) (dtor (core func $linkage-table "response-dtor"))))
  (canon resource.new $request (core func $builtin-request-new))
  (canon resource.rep $request (core func $builtin-request-rep))
  (canon resource.drop $request (core func $builtin-request-drop))
  (canon resource.new $response (core func $builtin-response-new))
  (canon resource.rep $response (core func $builtin-response-rep))
  (canon resource.drop $response (core func $builtin-response-drop))
```

The next chunk defines and instantiates the `$Main` module that implements the
"meat" of the `$HttpServer` component (that implements the HTTP protocol). The
imports of `$Main` allow it to call socket operations, manipulate `request` and
`response` handles, and call the `$HttpGuest`'s `receive` function (passing a
`request` handle created by `request-new` and receiving a `response` handle that
can be dereferenced with `response-rep`). The `send` export of `$Main` is called
recursively by the guest component during a call to `receive`. The final `elem`
segment patches the `request` and `response` destructors which will also be
called recursively during a call to `receive`.
```wat
  (core module $Main
    (import "linkage-table" "ftbl" (table $ftbl 3 3 funcref))
    (import "linkage-table" "receive" (func (param $handle i32) (result i32)))
    (import "lowered" "socket-new" (func ... (result i32)))
    (import "lowered" "socket-accept" (func (param $handle i32) ...))
    ...
    (import "builtin" "socket-drop" (func (param $handle i32)))
    (import "builtin" "request-new" (func (param $rep i32) (result i32)))
    (import "builtin" "request-rep" (func (param $handle i32) (result i32)))
    (import "builtin" "request-drop" (func (param $handle i32)))
    (import "builtin" "response-new" (func (param $rep i32) (result i32)))
    (import "builtin" "response-rep" (func (param $handle i32) (result i32)))
    (import "builtin" "response-drop" (func (param $handle i32)))
    (func (export "send") (param $request i32) (result i32) ...)
    ...
    (func (export "serve") ...)
    (func $request-dtor (param $rep i32) ...)
    (func $response-dtor (param $rep i32) ...)
    (elem (table $ftbl) (i32.const 0) func $request-dtor $response-dtor)
  )
  (core instance $main (instantiate $Main
    (with "linkage-table" (instance $linkage-table))
    (with "lowered" (instance
      (export "socket-new" (func $lowered-socket-new))
      (export "socket-accept" (func $lowered-socket-accept))
      ...
    ))
    (with "builtin" (instance
      (export "socket-drop" (func $builtin-socket-drop))
      (export "request-new" (func $builtin-request-new))
      (export "request-rep" (func $builtin-request-rep))
      (export "request-drop" (func $builtin-request-drop))
      (export "response-new" (func $builtin-response-new))
      (export "response-rep" (func $builtin-response-rep))
      (export "response-drop" (func $builtin-response-drop))
    ))
  ))
  (func (export "serve") (canon lift (core func $main "serve") ...))
```

The next chunk imports and instantiates an arbitrary `$HttpGuest` component
using the definitions above:
```wat
  (type $HttpGuest (component ...))
  (import "guest" (component $Guest (type $HttpGuest)))
  ...
  (func $send (param "r" (own $request)) (result (own $response))
    (canon lift (core func $main "send") ...)
  )
  (instance $guest (instantiate $Guest
    (with "request" (type $request))
    (with "response" (type $response))
    ...
    (with "send" (func $send))
  ))
```

The final chunk closes the cycle between `$Main` and `$guest`'s exported
`receive` function by lowering `receive` and then storing it as a `funcref` in
the `table` of `funcref` contained by `linkage-table` that is called indirectly
above at index `2`.
```wat
  (core func $lowered-receive
    (canon lower (func $guest "receive") ...)
  )
  (core module $PatchLinkageTable
    (import "linkage-table" "ftbl" (table $ftbl 3 3 funcref))
    (import "lowered" "receive" (func $receive (param i32) (result i32)))
    (elem (table $ftbl) (i32.const 2) func $receive)
  )
  (core instance (instantiate $PatchLinkageTable
    (with "linkage-table" (instance $linkage-table))
    (with "lowered" (instance (export "receive" (func $lowered-receive))))
  ))
)
```

The Component Model's validation rules assign `$HttpServer` the following
component-level type which is `$SocketServer` extended with an additional import
of an `$HttpGuest` component:
```wat
(type (component
  (import "net" (instance $net
    (export "socket" (type $Socket (sub resource)))
    (export "[constructor]socket" (func ... (result (own $Socket))))
    (export "[method]socket.accept" (func (param "self" (borrow $Socket)) ...))
    ...
  ))
  (import "guest" (component
    (import "request" (type $Request (sub resource)))
    (import "response" (type $Response (sub resource)))
    ...
    (import "send" (func (param "r" (own $Request)) (result (own $Response))))
    (export "receive" (func (param "r" (own $Request)) (result (own $Response))))
  ))
  (export "serve" (func))
))
```
Looking at this type and using our imagination, we can think of `$HttpServer`
as a donut with an `$HttpGuest`-shaped hole in the middle. Consequently, this
kind of component composition is informally called **donut wrapping** when
the parent component itself implements the child's imports and consumes the
child's exports.

If we'd like to "bind" `$HttpServer` to a particular `$HttpGuest` component, so
that it can be directly instantiated by a `$SocketServer` host, one option is to
bundle `$HttpServer` and the particular guest component into a single
*grand*parent component:
```wat
(component $VirtualizedGuest
  (import "net" (instance $net ...))
  (component $HttpServer ...)
  (component $SomeGuest ...)
  (instance $composite (instantiate $HttpServer
    (with "net" (instance $net))
    (with "guest" (component $SomeGuest))
  ))
  (export "serve" (func $composite "serve"))
)
```

Alternatively, as described in the previous section, to factor out the
`$HttpServer` so that it can be explicitly shared by multiple guest bundles, we
can convert the nested `$HttpServer` definition into an `import` that uses an
`external-id` that is automatically interpreted by the host, e.g.:
```wat
(component $VirtualizedGuest'
  (import "net" (instance $net ...))
  (import "HTTP-server" (external-id "https://...") (component $HttpServer ...))
  (component $SomeGuest ...)
  (instance $composite (instantiate $HttpServer
    (with "net" (instance $net))
    (with "guest" (component $SomeGuest))
  ))
  (export "serve" (func $composite "serve"))
)
```

This example demonstrates a fairly complex linking scenario that would be
difficult, if not impossible, to achieve with traditional linking based on a
single global namespace. Moreover, this example required no new specialized
functionality from what was introduced in previous sections, which demonstrates
the expressive power of decoupling lifting and lowering definitions from import,
export, alias and instantiation definitions.

When `$VirtualizedGuest` is instantiated and the exported `serve` function is
called, control flow will transfer directly into `$Main`, then `$SomeGuest`'s
internal module(s), then back into `$Main`, with all calls between `$Main` and
`$SomeGuest` happening without context switches, system calls, or intermediate
buffers. In a Docker Container setting, a similar degree of interposition can be
achieved by injecting a [sidecar container] that proxies all incoming and
outgoing network traffic but with much, much greater overhead.

This concludes the walkthrough of the Component Model, not including the
[concurrency support](Concurrency.md) introduced by the 0.3 Developer Preview
release.

## WIT

This explainer doesn't cover WIT (for that, see the Bytecode Alliance's [WIT
Overview]), but there are two high-level points worth making here:

First, WIT is a producer-toolchain language, which means that runtimes and
browsers don't need to implement WIT. Instead, toolchains may use WIT to
generate language bindings and build `.wasm` binaries which hosts then load
according to the Component Model binary format. Moreover, use of WIT is not
required to generate `.wasm` binaries; producer toolchains can go straight
through WAT into the binary format.

Second, WIT is meant to be a human-friendly syntax for writing Component Model
types. ("WIT" is usually taken to stand for "WebAssembly Interface Types", but
"WIT Is Types" would work too.) In fact, the semantics of a collection of WIT
files is defined by its mapping to a set of component-level `type` definitions
and a collection of WIT documents is conventionally packaged as exported `type`
definitions of a `.wasm` binary. See the [Package Format] section in `WIT.md`
for some worked examples.

## WASI

This explainer doesn't cover WASI (for that, see [`wasi.dev`]), but there are
two high-level points worth making here:

First, WASI is defined in terms of WIT (which again is just a nice syntax for
Component Model types) which means that each WASI API gets the following
benefits "for free":
* high-level language bindings in a growing set of languages
* a regular, predictable core wasm ABI
* ABI options covering the major axes of guest language representations
* API modularity that allows hosts to be able to successfully implement only
  the custom subset of WASI (and non-WASI) APIs that make sense on that host
* a portable capability-safety and virtualization story via resource types
  and component linking

Second, from the perspective of the Component Model, WASI is not privileged or
special; WASI is just a particular set of names and types that may be imported
or exported by components but otherwise follow all the Component Model rules the
same as any other import or export. The significance of WASI is thus that the
WASI APIs have gone through (and are still going through) a multi-implementation
open standards process that justifies their being implemented and upstreamed
into many different standard libraries, frameworks and packages, thereby forming
the basis of a portable inside-and-outside-the-browser WebAssembly ecosystem.

## Further reading

* Bytecode Alliance [Component Model documentation]
* [Linking Explainer]
* [Concurrency Explainer]
* [JS Explainer]
* [Text format reference]
* [Binary format reference]
* [Canonical ABI reference]
* [WIT reference]


[Component Model documentation]: https://component-model.bytecodealliance.org
[WIT Overview]: https://component-model.bytecodealliance.org/design/wit.html

[`high-level`]: ../high-level
[Released]: ../../README.md#developer-preview-releases
[Linking Explainer]: Linking.md
[Concurrency Explainer]: Concurrency.md
[JS Explainer]: TODO
[ESM-integration]: TODO#TODO
[JS API]: TODO#TODO
[Text format reference]: Text.md
[External Visibility]: Text.md#external-visibility-of-types
[🪺]: Text.md#gated-features
[🐘]: Text.md#gated-features
[🔧]: Text.md#gated-features
[📡]: Text.md#gated-features
[Binary Format reference]: Binary.md
[Canonical ABI reference]: CanonicalABI.md
[WIT reference]: WIT.md
[Package Format]: WIT.md#package-format

[lazy]: https://github.com/WebAssembly/component-model/issues/383
[wasm-gc]: https://github.com/WebAssembly/component-model/issues/525
[type-imports]: https://github.com/WebAssembly/proposal-type-imports/blob/main/proposals/type-imports/Overview.md

[Compact Strings]: https://openjdk.org/jeps/254
[Kebab Case]: https://en.wikipedia.org/wiki/Letter_case#Kebab_case
[SemVer]: https://semver.org/
[Module Specifier]: https://tc39.es/ecma262/#table-modulerequest-fields
[Unicode Scalar Value]: https://unicode.org/glossary/#unicode_scalar_value
[Capability-Based Security]: https://en.wikipedia.org/wiki/Capability-based_security
[Virtualization]: https://en.wikipedia.org/wiki/Virtualization
[HTTP Intermediary]: https://www.rfc-editor.org/info/rfc9110/#section-3.7
[BSD Sockets]: https://en.wikipedia.org/wiki/Berkeley_sockets
[Docker Compose]: https://docs.docker.com/compose/
[Sidecar Container]: https://learn.microsoft.com/en-us/azure/architecture/patterns/sidecar
[Import Map]: https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script/type/importmap
[OCI Artifact Reference]: https://oras.land/docs/concepts/reference/
[Wasm OCI Artifact]: https://tag-runtime.cncf.io/wgs/wasm/deliverables/wasm-oci-artifact/
[Lock Files]: https://docs.npmjs.com/cli/v8/configuring-npm/package-lock-json
[`wasi.dev`]: https://wasi.dev/
