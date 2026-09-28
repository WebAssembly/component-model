# Component Model Explainer

The Component Model defines a new executable container format for WebAssembly
modules, called a **component**, that specifies how its modules link together
and interact with the outside world. A useful working metaphor is that a wasm
component is to a wasm module as an ELF executable or a Docker container is to
x86 or ARM machine code.

This Explainer introduces the major features of the Component Model by walking
through a sequence of example components written in the text format, which
extends the Core WebAssembly text format (WAT). The Explainer stops before
describing the concurrency features introduced as part of the 0.3 Developer
Preview release; these are covered by the [Concurrency Explainer]. For more
background on the original high-level goals, use cases and design choices, see
the [`high-level`] directory.

## Hello, World!

Like modules, components have imports and exports with names and types through
which components interact with the outside world. However, unlike modules,
component-level value types are high level and meant to be converted directly to
and from source-language values by automated bindings generators or built-in
language support.

As a first example, here is a component with no imports and a single export that
returns the `string` value `"hello world"`:
```wat
(component
  (core module $Main
    (memory (export "core-mem") 1)
    (data (i32.const 16) "hello world")
    (func (export "core-greeting") (result i32)
      (local $retp i32)
      (local.set $retp (i32.const 0))
      (i32.store offset=0 (local.get $retp) (i32.const 16)) ;; ptr
      (i32.store offset=4 (local.get $retp) (i32.const 11)) ;; len
      (local.get $retp)
    )
  )
  (core instance $main (instantiate $Main))
  (func $greeting (result string)
    (canon lift (core func $main "core-greeting")
      (memory (core memory $main "core-mem"))
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

The body of the `core-greeting` function in `$Main` returns `"hello world"` by
returning a (pointer, length) pair pointing to UTF-8 bytes in linear memory.
Currently, the Component Model ABI does not take advantage of multi-value
return (due to producer toolchain limitations) and thus the (pointer, length)
pair must instead be returned through linear memory, with the address of the
*pair* returned as the actual `i32` return value. (In the next iteration of the
Component Model ABI, multi-value return will likely be included.)

Next, `(core instance $main (instantiate $Main))` creates a new instance of
`$Main` each time the containing component is instantiated. Without this `core
instance` definition, zero instances of `$Main` would be created and `$Main`
would be dead code. It is also possible to instantiate a single module multiple
times with multiple `core instance` definitions.

Next, `(func $greeting ...)` defines a new component-level function using a
`canon` (short for "Canonical ABI") definition to specify exactly how this new
function is to be implemented via **ABI options**. In particular, the example's
`canon` definition specifies:
* to `lift` the core function `core-greeting` exported by the instance `$main`
  to produce a component-level function of type `(func (result string))`;
* to use the memory `core-mem` exported by the instance `$main` to load the
  string's contents; and
* to decode the string's contents using UTF-8.

Currently, the other two `string-encoding` options are `utf16` and
`latin1+utf16` (which corresponds to the [compact strings] optimization). `utf8`
is the default and so `string-encoding` could have been omitted in this example.

Given the ABI options supplied to `canon lift`, the Component Model specifies
how the given component-level type (`(func (result string))`) is "[flattened]"
into a core-level type (`(func (result i32))`). The Component Model's validation
rules for `canon lift` require that this flattened type matches the given core
function (`core-greeting`). With [memory64 🐘], when the `memory` ABI option
refers to a 64-bit memory, the pointers and lengths mentioned above are replaced
with `i64`. In the future, a new ABI option will likely be added for [wasm-gc]
to replace these integer offsets with typed GC references.

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
Notably, the `core-mem` and `core-greeting` module exports are not present in
the component's type because they are encapsulated by the component and not
accessible to the outside world. Similarly, the ABI options `memory` and
`string-encoding` are not present, as they are also encapsulated implementation
details. This means that any of these core details can change without changing
the component's public interface or breaking existing client code.

## Receiving and returning dynamically-sized values

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
    (memory (export "core-mem") 1)
    (data (i32.const 16) "hello ")
    (func $libc-malloc (param i32) (result i32) ...)
    (func $libc-realloc (param i32 i32) (result i32) ...)
    (func $libc-free (param i32) ...)
    (func (export "core-realloc")
          (param $oldPtr i32) (param $oldSize i32) (param $align i32) (param $newSize i32)
          (result i32)
      (call $libc-realloc (local.get $oldPtr) (local.get $newSize))
    )
    (func (export "core-greeting") (param $namePtr i32) (param $nameLen i32) (result i32)
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
    (func (export "core-greeting-post-return") (param $retp i32)
      (call $libc-free (i32.load offset=0 (; = $ptr ;) (local.get $retp)))
    )
  )
  (core instance $main (instantiate $Main))
  (func (export "greeting") (param "name" string) (result string)
    (canon lift (core func $main "core-greeting")
      (memory (core memory $main "core-mem"))
      (realloc (core func $main "core-realloc"))
      (post-return (core func $main "core-greeting-post-return"))
    )
  )
)
```
When a client calls the component-level `greeting` function, before `$Main`'s
`core-greeting` export is called, the wasm runtime first calls `core-realloc` to
allocate space in `core-mem` to copy the `name` argument into. Depending on the
caller's and callee's chosen `string-encoding`, transcoding may be required and
`realloc` may need to be called multiple times to resize in the process. The
final return value of `realloc` and the encoded length of the `string` are then
passed into `core-greeting`.

The `$retp` value passed to `core-greeting-post-return` is the same as the
`$retp` value returned by `core-greeting`. If there is no dynamic allocation, as
in the previous example, the `post-return` ABI option can be omitted.

(In the next iteration of the Component Model ABI, to address some limitations
with the current approach (including: out-of-memory handling, custom allocators,
recursive value types and zero-copy forwarding) the `realloc` ABI option will
likely be replaced (in a non-breaking transitional manner) with a combination of
caller-supplied buffers and [lazy] value copying.)

The Component Model's validation rules assign this component definition the
following type:
```wat
(component
  (export "greeting" (func (param "name" string) (result string)))
)
```
Again, all the `core-*` definitions and ABI options are encapsulated, exposing
only the single component-level export. As shown here, unlike core functions,
component-level functions include parameter names as part of the function type
so that they can be used to provide ergonomic automatic language bindings.

## Imports and module linking

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
    (memory (export "core-mem") 1)
    (func (export "core-realloc") (param i32 i32 i32 i32) (result i32) ...)
  )
  (core instance $alloc (instantiate $Alloc))
  (import "name" (func $name (result string)))
  (import "actions" (instance $actions
    (export "greet" (func (param "message" string)))
  ))
  (core func $core-name (canon lower (func $name)
    (memory (core memory $alloc "core-mem"))
    (realloc (core func $alloc "core-realloc"))
  ))
  (core func $core-greet (canon lower (func $actions "greet")
    (memory (core memory $alloc "core-mem"))
  ))
  (core module $Main
    (import "alloc" "core-mem" (memory 1))
    (import "alloc" "core-realloc" (func (param i32 i32 i32 i32) (result i32)))
    (import "lowered" "core-name" (func (param $outPtr i32)))
    (import "lowered" "core-greet" (func (param $ptr i32) (param $len i32)))
    (func $start
      ... call core-name, generate "hello {name}", call core-greet ...
    )
    (start $start)
  )
  (core instance (instantiate $Main
    (with "alloc" (instance $alloc))
    (with "lowered" (instance
      (export "core-name" (func $core-name))
      (export "core-greet" (func $core-greet))
    ))
  ))
)
```
Walking through the definitions in order:

The first two definitions define and instantiate the `$Alloc` module to produce
an `$alloc` module instance containing `core-mem` and `core-realloc` functions
that can be used as ABI options in the following `canon lower` definitions.

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
(core func $core-greet (canon lower (func $greet) ...))
```

Next, `(core module $Main ...)` shows the [flattened] core function types of the
`lower`ed `core-name` and `core-greet` functions (which will be explicitly
linked to these imports by the `instantiate` expression below).

In the case of `core-name`, due to the aforementioned current lack of
multi-value return, the pointer and length of the `string` result are written to
a caller-supplied 8-byte buffer passed as the single `i32` parameter. The
`memory` ABI option is used for both the caller-supplied buffer and the `string`
contents. The `realloc` ABI option is called to allocate the `string` contents.
(As mentioned above, UTF-8 is the default `string-encoding`.)

In the case of `core-greet`, the pointer and length of the `string` parameter
are passed as the pointer and length `i32` parameters and the `memory` ABI
option is used to read the `string` contents. Since there are no dynamically
allocated results, there is no `realloc` ABI option required.

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
    (export "greet" (func (param "message" string)))
  ))
)
```
Notably, the fact that this component contains two core modules which share
`core-mem` is kept an encapsulated implementation detail. Also absent is any
imported ambient namespace used to link the modules as is required by, e.g., ELF
to resolve shared object dependencies. Thus, components are more like Docker
containers, which keep their filesystem an encapsulated detail of the container.

## Value types

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
[fixed-length `list` 🔧] values as scalar Core WebAssembly parameters and
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
    (memory (export "core-mem") 1)
    (func (export "core-realloc") (param i32 i32 i32 i32) (result i32) ...)
    (func (export "core-sum") (param $ptr i32) (param $len i32) (result i32)
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
  (type $pair-internal (record (field "first" u8) (field "second" u32)))
  (export $Pair "byte-word-pair" (type $pair-internal))
  (func (export "sum") (param "input" (list $Pair)) (result u32)
    (canon lift (core func $main "core-sum")
      (memory (core memory $main "core-mem"))
      (realloc (core func $main "core-realloc"))
    )
  )
)
```
To help bindings generators in languages that do not have structural `record` or
`variant` types, the Component Model imposes an additional [external visibility]
requirement on imported and exported functions: `record` and `variant` types
must have an externally-visible name assigned to them by an `import` or an
`export`. For example, in C, where `struct`s (mostly) require a name, an
automated bindings generator for the above component could generate a `struct`
named `byte_word_pair` instead of being forced to synthesize a `struct` name out
of thin air.

To support this external-visibility requirement, component-level `export`
definitions introduce a new index for whatever they're exporting. This new index
aliases the original definition (like an `alias` definition) but also counts as
being "externally visible". Thus, in the above example, the `$Pair` identifier
bound by:
```wat
(export $Pair "byte-word-pair" (type $pair-internal))
```
refers to a new `type` index introduced by the `export` definition that aliases
the `type` index `$pair-internal`. This allows `$Pair` to be used in `sum`'s
function type; attempting to use `$pair-internal` would be a validation error.

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

## Importing resource types

Some values may be too big or expensive to copy (like HTTP requests and
responses) and some external resources can't be copied at all (like sockets and
database connections). In such cases, some form of *reference* must be passed
instead. While components can emulate references in the usual way with integer
or string "ids", this approach is more error-prone and less secure (ids can
easily be forged, leaked, used after free, and used with the wrong type) and
less ergonomic by default (ids have no default integration with language
features like GC, scoped resource management and type systems). Instead, to
avoid forcing component interfaces to use ids, the Component Model provides
built-in support for **resource types** and **handle types**.

For example, the following component imports a `file` resource type along with
functions to acquire, use and drop `file` handles:
```wat
(component
  (import "file" (type $file (sub resource)))
  (import "open" (func $open
    (param "path" string) (result (own $file))))
  (import "[method]file.read" (func $read
    (param "self" (borrow $file)) (param "n" u32) (result (list u8))))
  (core module $Alloc ... )
  (core instance $alloc (instantiate $Alloc))
  (core func $core-open (canon lower (func $open) ... ))
  (core func $core-read (canon lower (func $read) ... ))
  (core func $core-drop (canon resource.drop $file))
  (core module $Main
    (import "alloc" "core-mem" (memory 1))
    (import "file" "core-open" (func $open (param $ptr i32) (param $len i32) (result $file i32)))
    (import "file" "core-read" (func $read (param $file i32) (param $n i32) (param $retp i32)))
    (import "file" "core-drop" (func $drop (param $file i32)))
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
      (export "core-open" (func $core-open))
      (export "core-read" (func $core-read))
      (export "core-drop" (func $core-drop))
    ))
  ))
)
```
Walking through the definitions in order:

The `(import "file" (type $file (sub resource)))` definition adds a new `type`
index (bound to `$file`) for an abstract resource type (`sub resource` stands
for "a `sub`type of the top `resource` type). A **resource type** is *not* a
value type and thus cannot be used in the same places as other value types (e.g.
`(func (result $file))` is not a valid type). Instead, resource types can *only*
be used to define **handle types**, of which there are currently two: `own` and
`borrow`. Handles types *are* value types and can thus be used like other value
types with the exception that `borrow` cannot appear anywhere in a function
return type (e.g., `(func (param "l" (list (borrow $file))))` is a valid type
while `(func (result (list (borrow $file))))` is not).

The `(import "open" (func ... (result (own $file))))` definition imports a
function that returns an **owned** `file` handle. An "owned" handle represents
unique ownership and, when the handle is "dropped" (by calling `resource.drop`,
below) the backing resource is destroyed. In some cases, such as traditional
files and file descriptors, or a C++ `std::shared_ptr`, the uniquely-owned
"resource" is just a reference count paired with a pointer to an underlying
shared resource that is destroyed when the reference count reaches zero.

Next, `(import "[method]file.read" (func ...))` imports a function that takes a
`borrow`ed handle to a `$file`. The `borrow` handle implies certain ABI rules
that both the caller and callee must follow or else they trap. In particular,
the *caller* promises to *not* call `resource.drop` on the lent handle before
the call returns and the *callee* agrees *to* call `resource.drop` on the
borrowed handle before the call returns. When both sides uphold their end,
this rule prevents use-after-free of the resource.

The `[method]file.read` name is just a name string, but it matches a grammatical
pattern that tells the bindings generator: if your language has any special
"constructor" idioms, you might want to expose this function as a constrctor for
the `file` resource. However, this is just a name string for a function and so
languages like C can always just emit a regular function with a mangled name
based on the resource name (like `new_file`).

Other annotations include `[static]` and, with [getters and setters 📡], `[get]`
and `[set]`, with more likely over time. While validation checks that annotated
functions have the right shape (e.g., a `[method]` must take a `borrow` named
`self` as its first parameter), these are still just functions, and so a
bindings generator that doesn't understand an annotation can fall back to a
plain function with a mangled name.

... `resource.drop`

... `module`

In the ABI, handles are `i32` indices into a per-component-instance *handle
table*, similar to how Unix file descriptors index a per-process table in the
kernel. Thus, the lowered constructor adds a new `own` handle to the table and
returns its index, the lowered `read` takes a handle index as `self`, and
`resource.drop` removes a handle from the table. When an `own` handle is
dropped, the resource's destructor is called inside the component that
implements `file`.

... show the type

## Defining and exporting resource types

In addition to importing resource types, components can also *implement* them,
as in the following component which implements `file`:
```wat
(component
  (core module $Alloc ...)  ;; exports "mem", "realloc" and "free"
  (core instance $alloc (instantiate $Alloc))
  (type $file (resource (rep i32) (dtor (core func $alloc "free"))))
  (core func $new (canon resource.new $file))
  (core module $Main
    (import "file" "new" (func $new (param i32) (result i32)))
    ...
    (func (export "open") (param $pathPtr i32) (param $pathLen i32) (result i32)
      ...                              ;; allocate a struct at $struct
      (call $new (local.get $struct))  ;; return a new own handle
    )
    (func (export "read") (param $self i32) (param $n i32) (result i32)
      ...                              ;; $self is the struct's address
    )
  )
  (core instance $main (instantiate $Main
    (with "file" (instance (export "new" (func $new))))
    ...
  ))
  (export $file' "file" (type $file))
  (func (export "[constructor]file") (param "path" string) (result (own $file'))
    (canon lift (core func $main "open") ...)
  )
  (func (export "[method]file.read")
    (param "self" (borrow $file')) (param "n" u32) (result (list u8))
    (canon lift (core func $main "read") ...)
  )
)
```
Here, `(type $file (resource ...))` defines a new resource type, each value of
which is represented in core code by an `i32` called its *rep*, which, in this
example, is the address of a struct in linear memory. When an `own` handle is
dropped, the `dtor` is called with the rep.

TODO: mention the [external visbility] requirement for resource types

`resource.new` takes a rep and returns a new `own` handle in the
implementation's own handle table, which, when returned from the lifted
constructor, is *moved* into the caller's table.

Because the `self` parameter of `read` is a `borrow` being passed to the
component that implements `file`, the Canonical ABI passes the rep directly as
an optimization, and so the core `read` receives the struct's address. In other
cases (such as when receiving an `own` handle), the implementation receives a
handle index and must call `resource.rep` to get the rep:
```wat
(core func $rep (canon resource.rep $file))  ;; (param i32) (result i32)
```
Since validation only allows `resource.new` and `resource.rep` in the component
that defines the resource type, only the implementation can ever see reps.

The implementation of `file` can thus rely on the absence of use-after-free,
double-free and type confusion, no matter what clients do:
* `read` is never passed the rep of a dropped `file`;
* the destructor is called at most once per `file`;
* `read` is never passed the rep of some other resource type.

The Component Model enforces these guarantees with checks (and traps) on every
handle operation, e.g., ensuring that an `own` handle isn't dropped while it is
lent out and that a `borrow` handle is dropped before its call returns.

## Component linking

So far, we've only seen `instantiate` link core *modules* inside a component,
but `instantiate` can also link *components*. Why link components instead of
modules?
* The code is written in different languages that can't be statically linked
  together (e.g., Python and Go).
* The code is built separately, by separate projects with separate releases.

These are the same reasons for using separate containers, making component
linking analogous to `docker compose`.

Another reason for component linking is virtualization, in which an "adapter"
component implements an interface in terms of other interfaces (e.g.,
implementing the WASI filesystem on top of Web APIs). For example, in the
following component, a parent component links such an adapter with a component
that imports the WASI filesystem:
```wat
(component
  (import "indexed-db" (instance $idb ...))
  (component $FsAdapter
    (import "indexed-db" (instance ...))
    ...
    (export "wasi:filesystem/types" (instance ...))
  )
  (component $App
    (import "wasi:filesystem/types" (instance ...))
    ...
    (export "run" (func ...))
  )
  (instance $fs (instantiate $FsAdapter
    (with "indexed-db" (instance $idb))
  ))
  (instance $app (instantiate $App
    (with "wasi:filesystem/types" (instance $fs "wasi:filesystem/types"))
  ))
  (export "run" (func $app "run"))
)
```
Here, `$FsAdapter` and `$App` are child components nested inline, since
`(component ...)` defines a component just like `(core module ...)` defines a
module. Without the `core` prefix, `instance` and `instantiate` create
component instances.

The parent first instantiates `$FsAdapter`, passing it `indexed-db`, and then
instantiates `$App`, passing it `$fs`'s `wasi:filesystem/types` export via
`(instance $fs "wasi:filesystem/types")`, which is an inline alias of that
export (like `(core func $main "core-greeting")` above). Each `with` argument
is checked by validation against the type of the child's import. Lastly, the
parent re-exports `$app`'s `run`.

Calls from `$App` into `$FsAdapter` are direct function calls, not messages
over a socket, with `$App`'s `canon lower` and `$FsAdapter`'s `canon lift`
together defining how values are copied from `$App`'s memory into
`$FsAdapter`'s memory and with each side picking its own ABI options.

As a result, this component can be run in a browser as a single self-contained
file, without the browser needing to implement (or an import map needing to
supply) a WASI filesystem. Moreover, even though there are lots of ways to
virtualize a filesystem (e.g., in memory or on IndexedDB), other components on
the same page can virtualize it differently without interference, since each
parent picks for its own children.

More generally, a parent has full control over its children, deciding when
they're instantiated and what they can call. For example, since `$App` can only
call what the parent passes it, `$App` can't call `indexed-db` directly. Thus,
a parent can *sandbox* its children with whatever policy it wants and can even
wrap its own core code around all of a child's imports and exports (see
[donut wrapping] for more).

## Factoring out shared code

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
      (export "core-mem" (memory 1))
      (export "core-realloc" (func (param i32 i32 i32 i32) (result i32)))
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
Model documentation), but there are two technical points worth making here.

First, WIT is a producer-toolchain language, which means that runtimes and
browsers don't need to implement WIT. Instead, toolchains use WIT to generate
bindings and build `.wasm` binaries which hosts then load according to the
Component Model [binary format].

Second, WIT is types. ("WIT" officially stands for "Wasm Interface Type", but
"WIT Is Types" works too.) The meaning of a WIT package is a set of
component-level `type` definitions that can roundtrip through a component's
type section. For example, the following WIT world:
```wit
package local:demo;

world greeter {
  import name: func() -> string;
  import greet: func(msg: string);
}
```
is the component type shown in [Imports and module linking] and roundtrips
through this component:
```wat
(component
  (type (export "greeter") (component
    (export "local:demo/greeter" (component
      (import "name" (func (result string)))
      (import "greet" (func (param "msg" string)))
    ))
  ))
)
```
See `WIT.md`'s [package format] section for the full mapping.

## Further reading

* Using the Component Model in practice: [Component Model Documentation]
* Module and component linking: [Linking.md](Linking.md)
* Concurrency support: [Concurrency.md](Concurrency.md)
* The text format, in depth: [Text.md](Text.md)
* The binary format, in depth: [Binary.md](Binary.md)
* The Canonical ABI, in depth: [CanonicalABI.md](CanonicalABI.md)
* WIT, in depth: [WIT.md](WIT.md)
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

[factor out shared code]: #factoring-out-shared-code

[memory64 🐘]: Text.md#gated-features
[fixed-length `list` 🔧]: Text.md#gated-features
[getters and setters 📡]: Text.md#gated-features
[wasm-gc]: https://github.com/WebAssembly/component-model/issues/525


[Component Model Documentation]: https://component-model.bytecodealliance.org
[WIT]: https://component-model.bytecodealliance.org/design/wit.html
[Package Format]: WIT.md#package-format
[OCI Registries]: https://github.com/opencontainers/distribution-spec/blob/main/spec.md#definitions
[`import source`]: https://github.com/tc39/proposal-source-phase-imports


[Lazy]: https://github.com/WebAssembly/component-model/issues/383
[ESM-integration]: https://github.com/WebAssembly/component-model/pull/686
