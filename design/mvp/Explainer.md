# Component Model Explainer

The Component Model defines a new executable container format for WebAssembly
modules, called a **component**, that specifies how its contents link together
and interact with the outside world. A useful working metaphor is that a wasm
component is to a wasm module as an ELF executable or OCI container is to x86 or
ARM machine code.

## Problem Statement

The original high-level goals, use cases and design choices for the Component
Model that were written before everything else are in the documents in the
[`high-level`] directory. They're rather general and a bit old, so we're
currently working on a more focused and updated-for-2026 problem statement to
put in this section.

## Walkthrough

This section introduces the major features of the Component Model by walking
through a sequence of example components written in the Component Model text
format, which extends the Core WebAssembly text format (WAT). The walkthrough
stops before describing the concurrency features introduced as part of the 0.3
Developer Preview release; these are covered by the [Concurrency Explainer].

### Hello, World!

Like modules, components have imports and exports with names and types through
which components interact with the outside world. However, unlike modules,
component-level value types are high level and meant to be converted directly to
and from source-language values by automated bindings generators or built-in
language integration (collectively called "language bindings").

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
  (func $greeting (result string)
    (canon lift (core func $main "greeting")
      (memory (core memory $main "mem"))
      string-encoding=utf8
    )
  )
  (export "greeting" (func $greeting))
)
```
Like a core module, a component is a sequence of definitions, which we'll walk
through in order.

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
`$Main` each time the containing component is instantiated. Without this `core
instance` definition, zero instances of `$Main` would be created and `$Main`
would be dead code. It is also possible to instantiate a single module multiple
times with multiple `core instance` definitions.

Next, `(func $greeting ...)` defines a new component-level function using a
`canon` (short for "Canonical ABI") definition to specify exactly how this new
function is to be implemented via **ABI options**. In particular, the example's
`canon` definition specifies:
* to `lift` the core function `greeting` exported by the instance `$main` to
  produce a component-level function of type `(func (result string))`;
* to use the memory `mem` exported by the instance `$main` to load the
  string's contents; and
* to decode the string's contents using UTF-8.

Currently, the other two `string-encoding` options are `utf16` and
`latin1+utf16` (which corresponds to the [compact strings] optimization). `utf8`
is the default and so `string-encoding` could have been omitted in this example.

Given the ABI options supplied to `canon lift`, the Component Model specifies
how the given component-level type (`(func (result string))`) is "[flattened]"
into a core-level type (`(func (result i32))`). The Component Model's validation
rules for `canon lift` require that this flattened type matches the given core
function (`greeting`). With memory64 ([🐘]), when the `memory` ABI option refers
to a 64-bit memory, the pointers and lengths mentioned above are replaced with
`i64`. In the future, a new ABI option will likely be added for [wasm-gc] to
replace these integer offsets with typed GC references.

Lastly, `(export "greeting" (func $greeting))` exports the new component-level
function to the outside world with the name `greeting`. As in core wasm, there
is syntactic sugar that allows writing the `export` inline in the function
definition:
```wat
;; equivalently:
(func (export "greeting") (result string) (canon lift ...))
```

The Component Model's validation rules assign this example component the
following type:
```wat
(component
  (export "greeting" (func (result string)))
)
```
Notably, the `mem` and `greeting` module exports are not present in the
component's type because they are encapsulated by the component and not
accessible to the outside world. Similarly, the ABI options `memory` and
`string-encoding` are not present, as they are also encapsulated implementation
details. This means that any of these core details can change without changing
the component's public interface or breaking existing client code.

### Receiving and returning dynamically-sized values

Now let's generalize `greeting` to take a `name` `string` parameter and return
`"hello {name}"`. In this case, the caller's `string` must be copied into the
*callee's* memory... but where? Since only the callee's module knows how its
memory is laid out, the Component Model requires the callee to provide a
"`realloc`" function as an ABI option to `canon lift`. Like libc's `realloc`,
the `realloc` function can be used either to allocate fresh memory or to resize
a previous allocation. Symmetrically, there is a `post-return` ABI option that
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
      (local.set $retp (i32.const 0))
      (i32.store offset=0 (local.get $retp) (local.get $ptr))
      (i32.store offset=4 (local.get $retp) (local.get $len))
      (local.get $retp)
    )
    (func (export "greeting-post-return") (param $retp i32)
      (call $libc-free (i32.load offset=0 (; = $ptr ;) (local.get $retp)))
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
in the previous example, the `post-return` ABI option can be omitted.

In the next iteration of the Component Model ABI, to address some limitations
with the current approach (including: out-of-memory handling, custom allocators,
recursive value types and zero-copy forwarding) the `realloc` ABI option will
likely be replaced (in a non-breaking transitional manner) with a combination of
caller-supplied buffers and [lazy] value copying.

The Component Model's validation rules assign this component definition the
following type:
```wat
(component
  (export "greeting" (func (param "name" string) (result string)))
)
```
Again, all the core-level definitions and ABI options are encapsulated, exposing
only the single component-level export. As shown here, unlike core functions,
component-level functions include parameter names as part of the function type
so that they can be used to provide ergonomic language bindings.

### Imports and module linking

Component-level imports differ from module-level imports by having only a single
name string. The two-level naming of core-level imports is instead achieved by
having a component import an "`instance`" which itself contains a set of named
exports. Since the exports of an `instance` can also be `instance`s and since
components can also export `instance`s, components support full N-level
hierarchical naming of both imports and exports.

Using imports, the following component also produces `"hello {name}"` but does
so by calling an imported `name` function to return the `name` and then calling
an imported `greet` function to pass out the result. Symmetric to how core-level
functions can be *lifted* into component-level functions via `canon lift`,
component-level functions can be *lowered* into core-level functions via
`canon lower`.

The following component *also* demonstrates the nesting and linking of two
modules within the same component. Having multiple modules is a good way to both
[factor out shared code] and also to break the cyclic relationship between
`canon lower` and the `$Main` module (`$Main` needs to import the `lower`ed
`name` and `greet` functions while `canon lower` needs `memory` and `realloc`
ABI options).
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
mentioned above that nests the `greet` function under `actions`. This `import`
adds a new component-level `instance` to the `instance` index space. Notably,
the `greet` function is *not* (yet) added to the `func` index space.

Next, the two `(core func (canon lower ...))` definitions *lower* the two
imported component-level functions, adding new core-level functions to the
`core func` index space. Because `name` was already added to the `func` index
space, it is directly referred to by `(func $name)`. For `greet`, the expression
`(func $actions "greet")` is an **inline alias** that is syntactic sugar for
emitting the following **alias definition** that precedes `canon lower` and
explicitly projects `greet` out into the `func` index space:
```wat
;; equivalently:
(alias export $actions "greet" (func $greet))
(core func $lowered-greet (canon lower (func $greet) ...))
```

Next, `(core module $Main ...)` shows the flattened core function types of the
`lower`ed `name` and `greet` functions (which will be explicitly linked to these
imports by the `instantiate` expression below).

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
the particular import name strings in `$Main` is arbitrary and only needs to
match the names used by `instantiate`. Thus, components have considerable
flexibility to internally remap names between modules as needed, which will
become more significant when using module and component imports to [factor out
shared code].

The Component Model's validation rules assign this example component the
following type:
```wat
(component
  (import "name" (func (result string)))
  (import "actions" (instance
    (export "greet" (func (param "msg" string)))
  ))
)
```
Notably, the fact that this component contains two core modules which share
`mem` is kept an encapsulated implementation detail. Also absent is any
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
* `(variant (case "label" T?)+)`, a discriminated union with optional payloads
* `(list T N?)`, a sequence, possibly with a fixed length

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
fixed-length `list` ([🔧]) values as scalar Core WebAssembly parameters and
results according to the [flattening] rules. However, if there would be more
than 16 flat parameters or 1 flat result, all parameters (or results) are passed
through linear memory instead. Additionally, the encoded contents of `string`s
and the elements of dynamic-length `list`s are *always* passed through linear
memory. Thus, the ABI also specifies an in-memory representation for all value
types that uses traditional C-like `struct` and `union` packing and alignment
rules.

As an example, the following component exports a `sum` function that receives a
list of `$Pair` and returns the sum of all the fields. The `list` type is
flattened into a `realloc`ed pointer and length, like `string`, where the
pointer points to a contiguous array of 8-byte `record`s where the `first` field
is followed by 3 padding bytes to keep the `second` field aligned.
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
`export`. For example, in C, where `struct`s (mostly) require a name, the the
`struct` name in the language bindings could be `byte_word_pair` instead
something purely synthetic.

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

| type | specialization of | example language binding | ABI |
| -- | -- | -- | -- |
| `(tuple T*)` | `record` with integer labels | Python `tuple` | same |
| `(flags "label"*)` | `record` with boolean values | C# `[Flags]` | bitfield |
| `(enum "label"+)` | `variant` with empty payloads | C `enum` | same |
| `(option T)` | `variant` with `none` and `some T` cases | Haskell `Maybe` | same |
| `(result T? (error E)?)` | `variant` with `ok T?` and `error E?` cases | Rust `Result` | same |
| `string` | `(list char)` | C++ `std::string` | variable-length encoding |
| `(map K V)` | `(list (tuple K V))` | JS `Map` | same |

The `flags` and `enum` types have the same [external visibility] requirement as
the `record` and `variant` types for the same reasons as mentioned above.

Value types currently cannot be recursive. For example, the following would fail
validation due to `$json` not being defined until *after* the `variant`:
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
Core WebAssembly's `rec` groups (once the next ABI iteration makes doing so
much simpler with [lazy] rather than eager copying).

### Importing resource types

For cases where values are too big to copy or can't be copied, the Component
Model provides **resource types** and **handle types**.

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
    (import "file" "open" (func $open (param $ptr i32) (param $len i32) (result $file i32)))
    (import "file" "read" (func $read (param $file i32) (param $n i32) (param $retp i32)))
    (import "file" "drop" (func $drop (param $file i32)))
    (data (i32.const 16) "data.txt")
    (func $start
      (local $file i32) (local $retp i32)
      (local.set $file (call $open (i32.const 16 (; = "data.txt" ;)) (i32.const 8)))
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
`type` index for a `resource` type. The `(sub resource)` expression means that
we're importing a `sub`type of some base `resource` type that we don't yet know
anything about. In the future, resource subtyping will be added, allowing
resources to import with bounds `(sub $rt)`, where `$rt` is some preceding
imported resource type.

A `resource` type is *not* a value type and thus cannot be used in the same
places as other value types (e.g. `(func (result $file))` is not a valid type).
Instead, resource types can only be used to define *handle types*, of which
there are currently two: `own` and `borrow`. Handles types *are* value types and
thus *can* be used like other value types with the exception that `borrow`
cannot appear anywhere in a function return type (e.g., `(func (param "l" (list
(borrow $file))))` is a valid type while `(func (result (list (borrow $file))))`
is not).

Next, the `(import "open" (func ...))` definition imports a function that
returns an `own`ed `file` handle. `own` handles imply unique ownership of the
`resource` they point to. When an `own` handle is passed to `resource.drop`, the
pointed-to resource is destroyed. In some cases, the "uniquely-owned resource"
is really just a reference count on a shared object and "destroy" just means
"drop the reference count on the shared object" (analogous to destroying a C++
`std::shared_ptr` or a Unix file descriptor).

Next, the `(import "[method]file.read" (func ...))` definition imports a
function taking a `borrow`ed `file` handle. `borrow` handles imply that *someone
else* owns this resource and that `resource.drop` does *not* destroy the
resource. Calling a function taking a `borrow` does *not* disable the caller's
handle that was passed as an argument during the call and thus receiving a
`borrow` handle does not imply anything about exclusivity or mutability of the
pointed-to resource. However, to avoid use-after-free, `borrow` handles *do*
have a trap-enforced ABI calling convention where, until the end of the call,
the caller *must not* drop any of their lent handles and, by the end of the
call, the callee *must* have droped all of their borrowed handles.

While the import string `[method]file.read` is technically just the function's
name, because it starts with `[method]`, it tells language bindings: if your
language has anything method-like, expose this function as a method of `file`.
Languages without methods can instead mangle the `[method]...` name into a valid
non-method function name (e.g. `file_read`) of a funtion taking `self` as its
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
ABI built-ins are like instructions in Core WebAssembly: they represent pure
computation, not external I/O capabilities, and thus they don't have to be
`lower`ed from an `import`. Whereas Core WebAssembly instructions are written
directly inside `func` bodies, ABI built-ins are introduced as new `core func`
indices by `canon` definitions that can be imported and called by core modules
with a flattened type, just like `lower`ed functions.

Next, the `$Main` module shows the flattened function types of the two imported
functions and the `resource.drop` ABI built-in. In all three functions, handles
are represented as `i32` indices into a *per-component-instance* handle table
that is maintained by the wasm runtime and *not* directly accessible to the
module.
* For `open`, the returned `i32` refers to a *new* handle table element added to
  the handle table right before returning.
* For `read` and `drop`, the `i32` parameter must refer to a valid handle table
  element of the right type or else there is a trap.
* For `drop`, after the checks, the referred-to resource is destroyed and the
  handle table element is marked invalid and available for subsequent reuse.

One interesting thing to notice in `$Main` is that there is no core-level
representation of the resource type `$file`: everything is untyped `i32` indices
and type safety is ensured by dynamic casts performed inside `canon`-defined
functions. In the future, if Core WebAssembly is extended with [type imports],
resource types could be type-imported by modules and then the untyped `i32`
indices could be replaced by typed references.

Lastly, the `(core instance (instantiate $Main ...))` definition links
everything together as above, without any distinction between methods and
non-methods or `lower`ed imports and ABI built-ins.

The Component Model's validation rules assign this example component the
following type:
```wat
(component
  (import "file" (type $file (sub resource)))
  (import "open" (func
    (param "path" string) (result (own $file))))
  (import "[method]file.read" (func
    (param "self" (borrow $file)) (param "n" u32) (result (list u8))))
)
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
the resource is dropped. Additionally, the component defining the resource type
(and only that component) can use two ABI built-ins:
* `resource.new`, which boxes up a given representation value into a new
  resource pointed to by a new `own`ed handle; and
* `resource.rep`, which returns the representation value of the resource pointed
  to by a given handle.

As an example, the following component defines and exports a `file` resource
type which, along with the exported `open` and `[method]file.read` functions,
could implement the imports of the previous section's example component:
```wat
(component
  (core module $Alloc ...)
  (core instance $alloc (instantiate $Alloc))
  (type $file (resource (rep i32) (dtor (core func $alloc "free"))))
  (core func $file-new (canon resource.new $file))
  (core module $Main
    (import "alloc" "mem" (memory 1))
    (import "alloc" "malloc" (func $malloc (param i32) (result i32)))
    (import "file" "new" (func $new (param i32) (result i32)))
    (func (export "open") (param $pathPtr i32) (param $pathLen i32) (result i32)
      (local $ptr i32)
      (local.set $ptr (call $malloc (i32.const ...)))
      ... initialize $ptr
      (call $new (local.get $ptr))
    )
    (func (export "read") (param $ptr i32) (param $n i32) (result i32)
      ... use $ptr ... return list<u8> ...
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
Walking through the definitions in order (starting after `$alloc`):

The `(type $file (resource ...))` defines a new resource type with an `i32`
representation type that when destroys, calls the `free` function exported by
`$alloc` to free the memory allocation. Currently, `i32` and (with memory64
[🐘]) `i64` are the only allowed representation types, but in the future, with
[wasm-gc], reference types could be added. But the general idea is that the
representation value is a roughly pointer-sized value.

Next, the `(core func $file-new (canon resource.new $file))` definition appends
a new `core func` index for the `resource.new` ABI built-in. As this definition
shows, ABI built-ins can be parameterized by types, just like Core WebAssembly
instructions. In this case, passing `$file` tells `resource.new` which type tag
to attach to the new handle entry (which is later used for the dynamic casts).
Component validation requires the given `type` index to be a resource type that
was defined in the same component, ensuring that components are able to
encapsulate the construction and representation of their own resource types.

Next, the `$Main` module shows the flattened function type of `resource.new`
which is imported as `file` `new`. The `i32` parameter of `new` matches the
`rep` type of `$file`. Regardless of `rep`, the result is always the `i32` index
of a new `own` handle added to the caller's handle table. Thus, when a component
implements a resource types, it starts out as the owner of all new resources of
that type. Ownership of new resources is then handed out via `own` handles,
which is what `open` does in this example with its `(own $file)` return type.
Specifically, when the `i32` return value of `(call $new ...)` is returned from
`open`, the wasm runtime removes the `own` handle from the callee's handle table
and adds it to the caller's handle table, thereby *transferring* ownership* from
the callee to the caller.

The `read` function exported by `$Main` is `lift`ed to implement the
`[method]file.read` function exported by the component. The component-level
first parameter of `[method]file.read` is `(param "self" (borrow $file))` and
the corresponding first parameter of `read` is `(param i32)`. As an ABI-level
optimization, this `i32` is *not* the index of a `borrow` handle but, rather,
it's the unboxed representation value of the resource pointed to by the given
`borrow` handle. This optimization applies only when passing a `(borrow $R)`
handle to the component instance that defined `$R` and it skips the overhead of
adding a handle, calling `resource.rep`, and then calling `resource.drop` to
drop the handle.

Because of all the static and dynamic checks described above, `open` and `read`
can rely on the following useful guarantees:
* the `$ptr` value actually came from `open`
* `free($ptr)` will be called when the client no longer needs the resource
* `read` won't be called again after `free($ptr)`

Next, the `(core instance (instantiate $Main ...))` definition links everything
together as in previous examples.

Next, the `(export $File "file" (type $file))` definition makes the `$file`
resource type externally visible to clients with the export name `file`.
Resource types have the same [external visibility] requirements as `record`,
`variant`, `enum` and `flags` as described above which means that `$File` (the
`type` index introduced by `export`) must be used in exported functions instead
of `$file` (the `type` index introduced by `type`).

Lastly, the two `(func (export ...) ...)` definitions `lift` and `export` the
core-level `open` and `read` functions as the component-level `open` and
`[method]file.read` functions. There no new or special ABI options needed for
resource types in these functions; just the regular `memory` and `realloc`
ABI options needed for the `string` and `list` values.

The Component Model's validation rules assign this example component the
following type which is the same as the previous example's type after replacing
`import` with `export`:
```wat
(component
  (export "file" (type $File (sub resource)))
  (export "open" (func
    (param "path" string) (result (own $File))))
  (export "[method]file.read" (func
    (param "self" (borrow $File)) (param "n" u32) (result (list u8))))
)
```
Notably, the `i32` `rep` type of `file` is kept an encapsulated implementation
detail of the component and thus, e.g., a component can shift from `(rep i32)`
to `(rep i64)` (and later, with [wasm-gc], `(rep (ref $T))`) without changing
its public interface.

### Structured names and attributes

The preceding examples show import and export names beginning with `[method]`,
`[static]`, and other prefixes that inform language bindings. This section
describes several other hints embedded in name string that inform language
bindings. Because best-effort "content-sniffing" of patterns on arbitrary
strings is a recipe for disaster, the Component Model defines a grammar of
allowed name strings that avoids ambiguous interpretation both now and as new
language binding hints are added in the future.

The first hint aims to allow langauge bindings to use the idiomatic casing
scheme of their language so that API authors don't have to arbitrarily pick one
that applies to all languages. To do this, multi-word names are required to be
explicitly separated by hypthens (aka [kebab case]) and words must either be
all-lowercase or, if they represent acronyms, all-uppercase. Based on this,
language bindings are expected to case and concatenate the words and acronyms
according to their local style. For example, depending on the language:
* `my-foo` could turn into `my_foo`, `MY_FOO`,`myFoo` or `MyFoo`;
* `my-JSON-parser` could turn into `my_json_parser`, `MY_JSON_PARSER`,
  `myJsonParser`, `myJSONParser`, `MyJsonParser` or `MyJSONParser`; and
* `myFoo` and `my_foo` are not valid names.

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
really needs to be some arbitrary Unicode string. For example, with ECMAScript
Module (ESM) integration as proposed in [CM/#686], components loaded as ESMs
would have their import names interpreted as [module specifier] strings, which
can be arbitrary Unicode strings (including URLs). For these and other use
cases, component imports and exports may have an `external-id` **attribute**
that is separate from the name (and thus not used for language bindings) and
separate from the type (and thus not part of the static or dynamic semantics).
For example, if the following component is loaded as an ESM, the given URL would
be fetched by the ESM loader:
```wat
(component
  (import "slugify"
    (external-id "https://esm.unpkg.com/slugify@1.6.6")
    (func (param "text" string) (result string)))
)
```

The next hint aims to improve language bindings when API authors use
hierarchical naming to avoid name clashes in published, possibly-standard names.
In particular, the goal is to avoid long clunky names everywhere by mapping the
hierarchical name into the languages' existing support for packages, modules or
namespaces. To do this, in addition to the kebab-case **plain names** shown
above, component names can also be **interface names** which are a triplet of:
namespace `:` package name `/` package item name. For example, WASI imports us
interface names:
```wat
(component
  (import "wasi:http/client" (instance ...))
)
```

Next, to support API authors with versioning, interface names may optionally end
with `@` followed by a [semver] version string:
```wat
(component
  (import "wasi:http/client@0.3.0" (func ...))
)
```
By including the version in the name, hosts can easily provide multiple
side-by-side versions of the same API.

To support name-based linking where names, not indices, identify an import or
export, the Component Model requires all import names in the same component to
be unique (and similarly for exports). However, sometimes a component may want
to import multiple implementations of the same interface name. For example:
*multiple* `wasi:http/client` backends or *mutiple* `wasi:keyvalue/store`s. To
resolve this tension, interface names can alternatively be put in an `implements`
attribute of a plain-named import or export. For example:
```wat
(component
  (import "a" (implements "wasi:http/client@0.3.1") (instance ...))
  (import "b" (implements "wasi:http/client@0.3.1") (instance ...))
  (import "c" (implements "wasi:keyvalue/store@0.1.0") (instance ...))
  (import "d" (implements "wasi:keyvalue/store@0.1.0") (instance ...))
)
```
Keying off its static, built-in knowledge of "`wasi:http/client`" and
`wasi:keyvalue/store`", a host can look at this component at compile or load
time and know to use the plain names `a`/`b`/`c`/`d` (or `external-id`s, if they
were present) to lookup up the appropriate HTTP backend or key-value store.

### Component linking

One way to link components together is using host-specific APIs such as the [JS
API]'s `WebAssembly.instantiate` or the [C API]'s `wasm_instance_new`. However
linking components using host-specific APIs makes the composed application no
longer portable across different kinds of hosts (e.g., between browsers and
non-browsers) and makes the composite no longer distributable as a single
artifact. Instead, the Component Model allows components to contain nested
components and link them together in the same way as shown above for modules.

For example, the following example component contains abridged versions of the
`file`-importing and `file`-exporting example components shown in the last two
sections. To better illustrate the full linking story, the `file`-exporting
component is given a new `backing-store` import (presumably used to implement
the `file`) and the `file`-importing component is given a new `run` export
(presumably to do something useful with the imported `file`).
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
    (import "filesystem" (instance $file
      (export "file" (type ...))
      (export "open" (func ...))
      (export "[method]file.read" (func ...))
    ))
    ...
    (export "run" (func ...))
  )
  (import "backing-store" (instance $backing-store ...))
  (instance $exporter (instantiate $FileExporter
    (with "backing-store" (instance $backing-store))
  ))
  (instance $importer (instantiate $FileImporter
    (with "filesystem" (instance $exporter))
  ))
  (export "run" (func $importer "run"))
)
```
Walking through the definitions in order:

The first two `component` definitions add two new indices to the `component`
index space. When one component is nested inside another component, the inner
component is called a **child component** and the outer component is called a
**parent component**. Because components can nest N-deep, parents and children
form a tree.

Next, the `(import "backing-store" ...)` definition in the top-level component
is used to supply the `backing-store` import of `$FileExporter`. In general, if
a parent component wants to instantiate a child component with an import `I`,
there are 3 choices:
1. import `I` from the parent (as shown here for `backing-store`)
2. instantiate a child that exports `I` (as shown here for `filesystem`)
3. implement `I` in the parent using a `core module` + `canon lift` (not shown
   here; sometimes called [donut wrapping])

In particular, under no circumstance is a child component's import satisfied
directly by the host; if the child has an import `I` that is not satisfied by a
`(with "I" ...)` in the parent's `instantiate` expression, there is a validation
error. This guarantee, combined with the resource guarantees mentioned in the
last section, provide a foundation for implementing [capability-based security].

Next, the `(instance ... (instantiate ...))` definitions link everything
together, passing the parent's `backing-store` into the first child and linking
the first child to the second child. When one component `instantiate`s another
component, at runtime, the component instance created by `instantiate` is called
a **child component instance** and the component instance that performed the
`instantiate` is called the **parent component instance**.

Because instances can nest N-deep, parents and children form a (component)
**instance tree**. This instance tree is meaningfully different from the
component tree mentioned above in three ways:
* The *component tree* is static (reflecting nesting of bytes in the binary
  format) while the *instance tree* is dynamic (describing mutable state).
* Parent components can `instantiate` 0..N instances of child components and so
  the component tree can be both "narrower" and "wider" than the instance tree.
* The next section will show how child instances can be created not just
  from child components, but also *imported* and *outer-aliased* components, in
  which case the component and instance trees can be totally dissimilar.

Lastly, the `(export "run" (func $importer "run"))` definition re-exports
`$importer`'s exported `run` function from the parent component. Without this
re-export, `run` would not be callable from outside the parent component.

When this example component is loaded and the host calls this re-exported `run`,
control flow will transfer directly into `$FileImporter`'s internal module(s).
When `$FileImporter` calls its lowered import, control flow will then
synchronously call into `$FileExporter`'s internal module(s) on the same native
stack without a context switch (unlike usual cross-process communication) after
copying the `string` and `list` parameters directly from the caller's memory
into the callee's memory without an intermediate buffer (unlike usual pipe- or
socket-based communication). Thus, from a 10,000 foot view, the parent component
is rather like the `compose.yaml` file passed to [Docker Compose] and the two
child components are like two containers that communicate over a socket created
by Docker Compose (just with much lower overhead).

The Component Model's validation rules assign this example component the
following type:
```wat
(component
  (import "backing-store" (instance ...))
  (export "run" (func $consumer "run"))
)
```
Notably, the child components and the `file` resource type shared between them
are kept an encapsulated implementation detail of the parent component and
cannot interfere with the host or another component that has its own distinct
implementation of `file`.

### Factoring out shared code

As the previous sections demonstrate, components can link *both* modules (which
share core memory and table state) and components (which don't). Another way to
say this is that the Component Model supports both **shared-nothing** and
**shared-everything** linking.

TODO: redo this section

Because the examples above nest core modules and child components inline, many
components may end up containing copies of the same `libc`. While an optimizing
engine can deduplicate these copies and share compiled code by content hash,
each copy must still be downloaded and stored. We can do better if we can assume
a shared naming system, such as URLs in the browser or [OCI registries] in the
cloud.

For example, here is the component from [above](#imports-and-module-linking),
with the inline `$Libc` replaced by an import:
```wat
(component
  (import "libc" (external-id "https://example.com/libc-1.0.wasm")
    (core module $Libc
      (export "mem" (memory 1))
      (export "realloc" (func (param i32 i32 i32 i32) (result i32)))
    )
  )
  (import "name" (func $name (result string)))
  (import "greet" (func $greet (param "msg" string)))
  (core instance $libc (instantiate $Libc))
  ...
)
```
The import's type is a core module type listing `$Libc`'s exports, while the
`external-id` attribute gives the module's URL. With [ESM-integration],
the `external-id` is used as the module specifier, so that the browser simply
fetches and compiles the URL (like a JS [`import source`]), allowing other
components importing the same URL to share the same compiled module while each
still creates its own private instance with its own memory. Outside the
browser, a host could similarly interpret `external-id` as an OCI reference,
analogous to container images sharing a common base layer.

As with JS module bundling, a late-stage bundler can choose to inline or outline
each core module. Bundlers can also go in the opposite direction, e.g.,
combining three components into one parent component containing a single copy
of `libc`:
```wat
(component $Bundle
  (core module $Libc ...)
  (component $A
    (alias outer $Bundle $Libc (core module $Libc))
    (core instance $libc (instantiate $Libc))
    ...
  )
  (component $B
    (alias outer $Bundle $Libc (core module $Libc))
    (core instance $libc (instantiate $Libc))
    ...
  )
  (component $C
    (alias outer $Bundle $Libc (core module $Libc))
    (core instance $libc (instantiate $Libc))
    ...
  )
  (instance $a (instantiate $A))
  (instance $b (instantiate $B (with "a" (instance $a))))
  (instance $c (instantiate $C (with "b" (instance $b))))
  ...
)
```
Here, `alias outer` brings a definition of an enclosing component into scope.
(Just writing `$Libc` also works, since the text format inserts the
`alias outer` automatically.) Thus, the three children share `$Libc`'s code
while each still having its own `libc` instance and memory.

The Component Model makes these transformations simple and mechanical by
ensuring that they aren't semantically visible: core code can't tell whether
`libc` was inlined, imported or aliased.

## WIT

This Explainer doesn't introduce WIT (for that, see [WIT] in the Component
Model documentation), but there are two high-level points worth making here:

First, WIT is a producer-toolchain language, which means that runtimes and
browsers don't need to implement WIT. Instead, toolchains may use WIT to
generate language bindings and build `.wasm` binaries which hosts then load
according to the Component Model [binary format]. Moreover, use of WIT is not
required to generate `.wasm` binaries; producer toolchains can go straight
through WAT into the binary format.

Second, WIT is meant to be a human-friendly syntax for writing Component Model
types. ("WIT" is usually taken to stand for "WebAssembly Interface Types", but
"WIT Is Types" would work too.) Thus, the meaning of a collection of WIT files
is defined by its mapping to a set of component-level `type` definitions. In
fact a collection of WIT documents is conventionally packaged as binary `.wasm`
file. See the [Package Format] section in `WIT.md` for some worked examples.

## WASI

This Explainer doesn't introduce WASI (for that, see [`wasi.dev`]), but there
are a few high-level points worth making here.

TODO: prosify
* WASI APIs are defined in WIT and thus get all the goodies:
  * all the ABI options (`string-encoding`, 32-vs-64-bit, gc...) for every WASI interface
  * language bindings (including, with 0.3, concurrency runtime integration)
  * the semantics of resource types and capability safety story
  * great virtualization story via component linking (e.g., for WASI on the Web)
* of course anyone else can write their own WIT interface and get the same benefits
  * WASI is just particular names and types
  * the special thing about WASI (vs my own custom WIT interface) is that it's
    being standardized with stable releases and so it can be upstreamed into
    toolchains/libraries (which is a social, not technical, distinction).

## Further reading

TODO

* Using the Component Model: [Component Model Documentation]
* Linking Explainer: [Linking.md](Linking.md)
* Concurrency Explainer: [Concurrency.md](Concurrency.md)
* Text format: [Text.md](Text.md)
* Binary format: [Binary.md](Binary.md)
* Canonical ABI: [CanonicalABI.md](CanonicalABI.md)
* WIT: [WIT.md](WIT.md)
* JS Explainer: TODO
* WASI: [wasi.dev](https://wasi.dev)



[Binary Format]: Binary.md
[Concurrency Explainer]: Concurrency.md
[`high-level`]: ../high-level
[Flattened]: CanonicalABI.md#flattening
[Flattening]: CanonicalABI.md#flattening
[Compact Strings]: https://openjdk.org/jeps/254
[External Visibility]: Text.md#external-visibility-of-types
[Unicode Scalar Value]: https://unicode.org/glossary/#unicode_scalar_value
[Imports and module linking]: #imports-and-module-linking
[Donut Wrapping]: Linking.md#higher-order-shared-nothing-linking-aka-donut-wrapping
[Linking Explainer]: Linking.md
[factor out shared code]: #factoring-out-shared-code
[CM/#686]: https://github.com/WebAssembly/component-model/pull/686
[Module Specifier]: https://tc39.es/ecma262/#table-modulerequest-fields

[🐘]: Text.md#gated-features
[🔧]: Text.md#gated-features
[📡]: Text.md#gated-features
[🪺]: Text.md#gated-features
[lazy]: https://github.com/WebAssembly/component-model/issues/383
[wasm-gc]: https://github.com/WebAssembly/component-model/issues/525
[type imports]: https://github.com/WebAssembly/proposal-type-imports/blob/main/proposals/type-imports/Overview.md

[Component Model Documentation]: https://component-model.bytecodealliance.org
[WIT]: https://component-model.bytecodealliance.org/design/wit.html
[`wasi.dev`]: https://wasi.dev/
[Package Format]: WIT.md#package-format
[OCI Registries]: https://github.com/opencontainers/distribution-spec/blob/main/spec.md#definitions
[`import source`]: https://github.com/tc39/proposal-source-phase-imports

[C API]: https://github.com/WebAssembly/wasm-c-api/blob/main/include/wasm.h
[JS API]: https://webassembly.github.io/spec/js-api/
[Capability-Based Security]: https://en.wikipedia.org/wiki/Capability-based_security
[Kebab Case]: https://en.wikipedia.org/wiki/Letter_case#Kebab_case
[Docker Compose]: https://docs.docker.com/compose/
[semver]: https://semver.org/
