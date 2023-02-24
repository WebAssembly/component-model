# The `wit` format

The Wasm Interface Type (WIT) format is an [IDL] to provide tooling for the
[WebAssembly Component Model][components] in two primary ways:

* WIT is a developer-friendly format to describe the imports and exports to a
  component. It is easy to read and write and provides the foundational basis
  for producing components from guest languages as well as consuming components
  in host languages.

* WIT packages are the basis of sharing types and definitions in an ecosystem of
  components. Authors can import types from other WIT packages when generating a
  component, publish a WIT package representing a host embedding, or collaborate
  on a WIT definition of a shared set of APIs between platforms.

A WIT package is a collection of WIT documents. Each WIT document is defined in
a file that uses the file extension `wit`, for example `foo.wit`, and is encoded
as valid utf-8 bytes. Each WIT document contains a collection of
[`interface`s][interfaces] and [`world`s][worlds]. Types can be imported from
sibling documents (files) within a package and additionally from other packages
through a URLs.

This document will go through the purpose of the syntactic constructs of a WIT
document, a pseudo-formal [grammar specification][lexical-structure], and
additionally a specification of the [binary format][binary-format] of a WIT
package suitable for distribution.

[IDL]: https://en.wikipedia.org/wiki/Interface_description_language
[components]: https://github.com/webassembly/component-model

## WIT Interfaces
[interfaces]: #wit-interfaces

The concept of an "interface" is central in WIT as a collection of [functions]
and [types]. An interface can be thought of as an instance in the WebAssembly
Component Model, for example a unit of functionality imported from the host or
implemented by a component for consumption on a host. All functions and types
belong to an interface.

An example of an interface is:

```wit
interface host {
  log: func(msg: string)
}
```

represents an interface called `host` which provides one function, `log`, which
takes a single `string` argument. If this were imported into a component then it
would correspond to:

```wasm
(component
  (import "host" (instance $host
    (export "log" (func (param "msg" string)))
  ))
  ;; ...
)
```

An `interface` can contain [`use`][use] statements, [type][types] definitions,
and [function][functions] definitions. For example:

```wit
interface wasi-fs {
  use pkg.types.{errno}

  record stat {
    ino: u64,
    size: u64,
    // ...
  }

  stat-file: func(path: string) -> result<stat, errno>
}
```

More information about [`use`][use] and [types] are described below, but this
is an example of a collection of items within an `interface`. All items defined
in an `interface`, including [`use`][use] items, are considered as exports from
the interface. This means that types can further be used from the interface by
other interfaces. An interface has a single namespace which means that none of
the defined names can collide.

A WIT document can contain any number of interfaces listed at the top-level and
in any order. The WIT validator will ensure that all references between
interfaces are well-formed and acyclic.

An interface may optionally be listed as the `default` of a document. For
example:

```wit
default interface types {
  // ...
}
```

This will come up later when describing [`use` statements][use] and indicates
that when a document is imported from the `types` name here, for example, does
not need to be specified as it's the `default`.

## WIT Worlds
[worlds]: #wit-worlds

WIT documents can contain a `world` definition at the top-level in addition to
[`interface`][interfaces] definitions. A world is a complete description of
both imports and exports of a component. A world can be thought of as an
equivalent of a `component` type in the component model. For example this
world:

```wit
world my-world {
  import host: interface {
    log: func(param: string)
  }

  export run: func()
}
```

can be thought of as this component type:

```wasm
(type $my-world (component
  (import "host" (instance
    (export "log" (func (param "param" string)))
  ))
  (export "run" (func))
))
```

Worlds describe a concrete component and are the basis of bindings generation. A
guest language will use a `world` to determine what functions are imported, what
they're named, and what functions are exported, in addition to their names.

Worlds can contain any number of imports and exports, and can be either a
function or an interface.

```wit
world command {
  import fs: wasi-fs.fs
  import random: wasi-random.random
  import clock: wasi-clock.clock
  // ...

  export main: func(args: list<string>)
}
```

An imported or exported interface corresponds to an imported or exported
instance in the component model. Functions are equivalent to bare component
functions.

Additionally interfaces can be defined "inline" as a form of sugar for defining
it at the top-level

```wit
interface out-of-line {
  the-function: func()
}

world your-world {
  import out-of-line: self.out-of-line
  // ... is roughly equivalent to ...
  import out-of-line2: interface {
    the-function: func()
  }
}
```

The name of the `import` or `export` is the name of the corresponding item in
the final component. This can be different from the [`interface`][interfaces]
name but must be a [valid identifier][identifiers].

There can be multiple `world` descriptions in a single WIT document. When
generating bindings from a WIT document one world must be marked as `default` or
an explicitly named world must be chosen:

```wit
default world my-world {
  // ...
}
```

If no `default` world is specified in the WIT document and no named world is
explicitly chosen then bindings cannot be generated.

## WIT Packages and `use`
[use]: #wit-packages-and-use

A WIT package represents a unit of distribution that can be published to a
registry, for example, and used by other WIT packages and documents. WIT
packages are a flat list of documents, defined in `*.wit` files. The current
thinking for a convention is that projects will have a `wit` folder where all
`wit/*.wit` files within are members of a WIT package.

Within a single WIT document (file) a `use` statement can be used to import
between interfaces, for example:

```wit
interface types {
  enum errno { /* ... */ }

  type size = u32
}

interface my-host-functions {
  use self.types.{errno, size}
}
```

Here the `use` starts with `self` which indicates that something from the
current document is being used. Then the interface named `types` is listed,
followed by a list of type names to use from the interface. The interface
`types` may textually come either after or before the `use` directive's
`interface`.  Interfaces linked with `use` are not allowed to be cyclic.

Names imported via `use` can be renamed as they're imported as well:

```wit
interface my-host-functions {
  use self.types.{errno as my-errno}
}
```

Documents in a WIT package may also import from each other, for example the
above can be rewritten as:

```wit
// types.wit
default interface types {
  enum errno { /* ... */ }

  type size = u32
}

// host.wit
interface my-host-functions {
  use pkg.types.{errno, size}
}
```

The `pkg` keyword indicates that the `use` statement starts at the package root,
as opposed to the `self` keyword described above starting in the local document.
Additionally note the usage of `default interface` in the `types.wit` file which
simplifies the `use`. WIT documents can also import from any interface defined
within another document, however:

```wit
// types.wit
default interface types { /* .. */ }

interface more-types {
  type another-type = string
}

// host.wit
interface my-host-functions {
  use pkg.types.more-types.{another-type}
}
```

Here `more-types` in the `use` path indicates that it's the specific interface
being referenced. Documents in a WIT package must be named after a [valid
identifier][identifiers] and be unique within the package. Documents cannot
contain cycles between them as well with `use` statements.

When importing or exporting an [interface][interfaces] in a [world][worlds]
the same syntax is used after the `:` as `use`:

```wit
world my-world {
  import host: self.host
  import other-functionality: pkg.sibling-file
  import more-functionality: pkg.sibling-file.specific-interface
}

interface host {
  // ...
}
```

The `use` statement so far has always started with `self` or `pkg`, but it may
also start with any valid identifier:

```wit
interface foo {
  use package.other-document.{some-type}
}
```

This form indicates that the identifier `package` corresponds to some externally
specified package. Resolution of this WIT document requires the name `package`
to be provided via external configuration. For example a registry might indicate
that `package` was downloaded to a particular path at a particular version. The
name `package` could also perhaps be another package defined in the local
project which is configured via bindings generation.

This syntax allows `use` paths starting with any identifier other than `self`
and `pkg` to create a set of names that the document needs to be resolved
correctly. These names are considered the dependency packages of the current
package being parsed. Note that the set of names here are local to this package
do not need to conflict with dependency names in other packages. This enables
each package to be resolved entirely separately and, if necessary, the name
`foo` could mean different things to different packages.

> **Note**: The tooling for and mechanism for precisely how these external names
> are defined is not specified here. This is something that will be iterated on
> to create documentation of the tooling in question and community standards
> about how best to do this.
>
> As an example, however, imagine a CLI tool to generate C bindings for creating
> a component that takes, as input, the world to generate.
>
>   generate-c-bindings pkg.my-component
>
> The specification of `pkg` here indicates that a locally-written WIT file
> is being consumed. This could look inside of a `wit` folder in the current
> directory for a package to parse as a set of WIT files. Inside this package
> the `my-component` document would be selected and it would be expected to have
> a `default world`.
>
> Similarly an invocation such as:
>
>   generate-c-bindings pkg.my-component --extern wasi=./wit/wasi
>
> Could indicate that the identifier `wasi` within `my-component` would be
> resolved to a WIT package located in the `./wit/wasi` folder. Instead of
> `./wit/wasi` it could even pass `./wit/wasi.wasm` which would be the binary
> encoding of the `wasi` package. This sort of filesystem-based heuristic could
> be applied by the `generate-c-bindings` tool as well.
>
> Alternatively there could also be a tool which takes a configuration file:
>
> ```toml
> [wit-dependencies]
> wasi = "1.0"
> ```
>
> Where running `wit-registry` (a hypothetical CLI command) would parse this
> file, resolve it fully, and download the `wasi` package and place it somewhere
> along with perhaps a `resolve.json` file. This `resolve.json` could then be
> consumed by `generate-c-bindings` as an additional method for defining the
> dependency graph of components.
>
> Note that these scenarios are all hypothetical at this time and are the rough
> direction that tooling is expected to go in. This will evolve over time but is
> intended to set the stage for "what actually happens when I refer to a
> dependency package" where the high-level idea is that it's a concern external
> to the WIT package itself and resolved by higher-level tooling.

### Transitive imports and worlds

A `use` statement is not implemented by copying type information around but
instead retains that it's a reference to a type defined elsewhere. This
representation is plumbed all the way through to the final component, meaning
that `use`d types have an impact on the structure of the final generated
component.

For example this document:

```wit
interface shared {
  record metadata {
    // ...
  }
}

world my-world {
  import host: interface {
    use self.shared.{metadata}

    get: func() -> metadata
  }
}
```

would generate this component:

```wasm
(component
  (import "shared" (instance $shared
    (type $metadata (record (; ... ;)))
    (export "metadata" (type (eq $metadata)))
  ))
  (alias export $shared "metadata" (type $metadata))
  (import "host" (instance $host
    (export "get" (func (result $metadata)))
  ))
)
```

Here it can be seen that despite the `world` only listing `host` as an import
the component additionally imports a `shared` instance. This is due to the fact
that the `use { ... } from shared` implicitly requires that `shared` is imported
into the component as well.

Note that the name `"shared"` here is derived from the name of the `interface`
which can also lead to conflicts:

```wit
// shared1.wit
default interface shared { /* ... */ }

// shared2.wit
default interface shared { /* ... */ }

// world.wit
world my-world {
  import foo: interface {
    use pkg.shared1.{a-type}
  }
  import bar: interface {
    use pkg.shared2.{other-type}
  }
}
```

This is an invalid WIT document because `my-world` needs to import two
unique interfaces called `shared`. To disambiguate a manual import is required:

```
world my-world {
  import shared1: pkg.shared1
  import shared2: pkg.shared2

  import foo: interface {
    use pkg.shared1.{a-type}
  }
  import bar: interface {
    use pkg.shared2.{other-type}
  }
}
```

For `export`ed interfaces any transitively `use`d interface is assumed to be an
import unless it's explicitly listed as an export.

> **Note**: It's planned in the future to have "power user syntax" to configure
> this on a more fine-grained basis for exports, for example being able to
> configure that a `use`'d interface is a particular import or a particular
> export.

## WIT Functions
[functions]: #wit-functions

Functions are defined in an [`interface`][interfaces] or are listed as an
`import` or `export` from a [`world`][worlds]. Parameters to a function must all
be named and have unique names:

```wit
interface foo {
  a1: func()
  a2: func(x: u32)
  a3: func(y: u64, z: float32)
}
```

Functions can return at most one unnamed type:

```wit
interface foo {
  a1: func() -> u32
  a2: func() -> string
}
```

And functions can also return multiple types by naming them:

```wit
interface foo {
  a: func() -> (a: u32, b: float32)
}
```

Note that returning multiple values from a function is not equivalent to
returning a tuple of values from a function. These options are represented
distinctly in the component binary format.

## WIT Types
[types]: #wit-types

Types in WIT files can only be defined in [`interface`s][interfaces] at this
time. The types supported in WIT is the same set of types supported in the
component model itself:

```wit
interface foo {
  // "package of named fields"
  record r {
    a: u32,
    b: string,
  }

  // values of this type will be one of the specified cases
  variant human {
    baby,
    child(u32), // optional type payload
    adult,
  }

  // similar to `variant`, but no type payloads
  enum errno {
    too-big,
    too-small,
    too-fast,
    too-slow,
  }

  // similar to `variant`, but doesn't require naming cases and all variants
  // have a type payload -- note that this is not a C union, it still has a
  // discriminant
  union input {
    u64,
    string,
  }

  // a bitflags type
  flags permissions {
    read,
    write,
    exec,
  }

  // type aliases are allowed to primitive types and additionally here are some
  // examples of other types
  type t1 = u32
  type t2 = tuple<u32, u64>
  type t3 = string
  type t4 = option<u32>
  type t5 = result<_, errno>            // no "ok" type
  type t6 = result<string>              // no "err" type
  type t7 = result<char, errno>         // both types specified
  type t8 = result                      // no "ok" or "err" type
  type t9 = list<string>
  type t10 = t9
}
```

The `record`, `variant`, `enum`, `union`, and `flags` types must all have names
associated with them. The `list`, `option`, `result`, `tuple`, and primitive
types do not need a name and can be mentioned in any context. This restriction
is in place to assist with code generation in all languages to leverage
language-builtin types where possible while accommodating types that need to be
defined within each language as well.

## WIT Identifiers
[identifiers]: #wit-identifiers

Identifiers in WIT documents are required to be valid component identifiers,
meaning that they're "kebab cased". This currently is restricted to ascii
characters and numbers that are `-` separated.

For more information on this see the [binary format](./Binary.md).

# Lexical structure
[lexical-structure]: #lexical-structure

The `wit` format is a curly-braced-based format where whitespace is optional (but
recommended). A `wit` document is parsed as a unicode string, and when stored in
a file is expected to be encoded as utf-8.

Additionally, wit files must not contain any bidirectional override scalar
values, control codes other than newline, carriage return, and horizontal tab,
or codepoints that Unicode officially deprecates or strongly discourages.

The current structure of tokens are:

```ebnf
token ::= whitespace
        | comment
        | operator
        | keyword
        | identifier
```

Whitespace and comments are ignored when parsing structures defined elsewhere
here.

### Whitespace

A `whitespace` token in `wit` is a space, a newline, a carriage return, or a
tab character:

```ebnf
whitespace ::= ' ' | '\n' | '\r' | '\t'
```

### Comments

A `comment` token in `wit` is either a line comment preceded with `//` which
ends at the next newline (`\n`) character or it's a block comment which starts
with `/*` and ends with `*/`. Note that block comments are allowed to be nested
and their delimiters must be balanced

```ebnf
comment ::= '//' character-that-isnt-a-newline*
          | '/*' any-unicode-character* '*/'
```

There is a special type of comment called `documentation comment`. A
`doc-comment` is either a line comment preceded with `///` which ends at the next
newline (`\n`) character or it's a block comment which starts with `/**` and ends
with `*/`. Note that block comments are allowed to be nested and their delimiters
must be balanced

```ebnf
doc-comment ::= '///' character-that-isnt-a-newline*
          | '/**' any-unicode-character* '*/'
```

### Operators

There are some common operators in the lexical structure of `wit` used for
various constructs. Note that delimiters such as `{` and `(` must all be
balanced.

```ebnf
operator ::= '=' | ',' | ':' | ';' | '(' | ')' | '{' | '}' | '<' | '>' | '*' | '->'
```

### Keywords

Certain identifiers are reserved for use in `wit` documents and cannot be used
bare as an identifier. These are used to help parse the format, and the list of
keywords is still in flux at this time but the current set is:

```ebnf
keyword ::= 'use'
          | 'type'
          | 'resource'
          | 'func'
          | 'u8' | 'u16' | 'u32' | 'u64'
          | 's8' | 's16' | 's32' | 's64'
          | 'float32' | 'float64'
          | 'char'
          | 'record'
          | 'enum'
          | 'flags'
          | 'variant'
          | 'union'
          | 'bool'
          | 'string'
          | 'option'
          | 'list'
          | 'result'
          | 'as'
          | 'static'
          | 'interface'
          | 'tuple'
          | 'future'
          | 'stream'
          | 'world'
          | 'import'
          | 'export'
          | 'default'
```

## Top-level items

A `wit` document is a sequence of items specified at the top level. These items
come one after another and it's recommended to separate them with newlines for
readability but this isn't required.

Concretely, the structure of a `wit` document is:
```ebnf
wit-document ::= (interface-item | world-item)*
```

## Item: `world`

Worlds define a [componenttype](https://github.com/WebAssembly/component-model/blob/main/design/mvp/Explainer.md#type-definitions) as a collection of imports and exports.

Concretely, the structure of a world is:

```ebnf
world-item ::= 'default'? 'world' id '{' world-items* '}'

world-items ::= export-item | import-item | use-item | typedef-item

export-item ::= 'export' id ':' extern-type
import-item ::= 'import' id ':' extern-type

extern-type ::= func-type | interface-type

interface-type ::= 'interface' '{' interface-items* '}'
                 | use-path
```

Note that worlds can import types and define their own types to be exported
from the root of a component and used within functions imported and exported.

## Item: `interface`

Interfaces can be defined in a `wit` document. Interfaces have a name and a
sequence of items and functions.

Specifically interfaces have the structure:

```ebnf
interface-item ::= 'default'? 'interface' id '{' interface-items* '}'

interface-items ::= typedef-item
                  | use-item
                  | func-item

typedef-item ::= resource-item
               | variant-items
               | record-item
               | union-items
               | flags-items
               | enum-items
               | type-item

func-item ::= id ':' func-type

func-type ::= 'func' param-list result-list

param-list ::= '(' named-type-list ')'

result-list ::= nil
              | '->' ty
              | '->' '(' named-type-list ')'

named-type-list ::= nil
                  | named-type ( ',' named-type )*

named-type ::= id ':' ty
```

## Item: `use`

A `use` statement enables importing type or resource definitions from other
wit documents. The structure of a use statement is:

```wit
use self.interface.{a, list, of, names}
use pkg.document.some-type
use my-dependency.document.other-type
```

Specifically the structure of this is:

```ebnf
use-item ::= 'use' use-path '.' '{' use-names-list '}'

use-names-list ::= use-names-item
                 | use-names-item ',' use-names-list?

use-names-item ::= id
                 | id 'as' id

use-path ::= id ('.' id)*
```

Note: Here `use-names-list?` means at least one `use-name-list` term.

## Items: type

There are a number of methods of defining types in a `wit` document, and all of
the types that can be defined in `wit` are intended to map directly to types in
the [interface types specification](https://github.com/WebAssembly/interface-types).

### Item: `type` (alias)

A `type` statement declares a new named type in the `wit` document. This name can
be later referred to when defining items using this type. This construct is
similar to a type alias in other languages

```wit
type my-awesome-u32 = u32
type my-complicated-tuple = tuple<u32, s32, string>
```

Specifically the structure of this is:

```ebnf
type-item ::= 'type' id '=' ty
```

### Item: `record` (bag of named fields)

A `record` statement declares a new named structure with named fields. Records
are similar to a `struct` in many languages. Instances of a `record` always have
their fields defined.

```wit
record pair {
    x: u32,
    y: u32,
}

record person {
    name: string,
    age: u32,
    has-lego-action-figure: bool,
}
```

Specifically the structure of this is:

```ebnf
record-item ::= 'record' id '{' record-fields '}'

record-fields ::= record-field
                | record-field ',' record-fields?

record-field ::= id ':' ty
```

### Item: `flags` (bag-of-bools)

A `flags` represents a bitset structure with a name for each bit. The `flags`
type is represented as a bit flags representation in
the canonical ABI.

```wit
flags properties {
    lego,
    marvel-superhero,
    supervillan,
}
```

Specifically the structure of this is:

```ebnf
flags-items ::= 'flags' id '{' flags-fields '}'

flags-fields ::= id
               | id ',' flags-fields?
```

### Item: `variant` (one of a set of types)

A `variant` statement defines a new type where instances of the type match
exactly one of the variants listed for the type. This is similar to a "sum" type
in algebraic datatypes (or an `enum` in Rust if you're familiar with it).
Variants can be thought of as tagged unions as well.

Each case of a variant can have an optional type associated with it which is
present when values have that particular case's tag.

All `variant` type must have at least one case specified.

```wit
variant filter {
    all,
    none,
    some(list<string>),
}
```

Specifically the structure of this is:

```ebnf
variant-items ::= 'variant' id '{' variant-cases '}'

variant-cases ::= variant-case
                | variant-case ',' variant-cases?

variant-case ::= id
               | id '(' ty ')'
```

### Item: `enum` (variant but with no payload)

An `enum` statement defines a new type which is semantically equivalent to a
`variant` where none of the cases have a payload type. This is special-cased,
however, to possibly have a different representation in the language ABIs or
have different bindings generated in for languages.

```wit
enum color {
    red,
    green,
    blue,
    yellow,
    other,
}
```

Specifically the structure of this is:

```ebnf
enum-items ::= 'enum' id '{' enum-cases '}'

enum-cases ::= id
             | id ',' enum-cases?
```

### Item: `union` (variant but with no case names)

A `union` statement defines a new type which is semantically equivalent to a
`variant` where all of the cases have a payload type and the case names are
numerical. This is special-cased, however, to have a different representation
in the language ABIs or have different bindings generated in for languages.

```wit
union configuration {
    string,
    list<string>,
}
```

Specifically the structure of this is:

```ebnf
union-items ::= 'union' id '{' union-cases '}'

union-cases ::= ty
              | ty ',' union-cases?
```

## Types

As mentioned previously the intention of `wit` is to allow defining types
corresponding to the interface types specification. Many of the top-level items
above are introducing new named types but "anonymous" types are also supported,
such as built-ins. For example:

```wit
type number = u32
type fallible-function-result = result<u32, string>
type headers = list<string>
```

Specifically the following types are available:

```ebnf
ty ::= 'u8' | 'u16' | 'u32' | 'u64'
     | 's8' | 's16' | 's32' | 's64'
     | 'float32' | 'float64'
     | 'char'
     | 'bool'
     | 'string'
     | tuple
     | list
     | option
     | result
     | handle
     | id

tuple ::= 'tuple' '<' tuple-list '>'
tuple-list ::= ty
             | ty ',' tuple-list?

list ::= 'list' '<' ty '>'

option ::= 'option' '<' ty '>'

result ::= 'result' '<' ty ',' ty '>'
         | 'result' '<' '_' ',' ty '>'
         | 'result' '<' ty '>'
         | 'result'
```

The `tuple` type is semantically equivalent to a `record` with numerical fields,
but it frequently can have language-specific meaning so it's provided as a
first-class type.

Similarly the `option` and `result` types are semantically equivalent to the
variants:

```wit
variant option {
    none,
    some(ty),
}

variant result {
    ok(ok-ty)
    err(err-ty),
}
```

These types are so frequently used and frequently have language-specific
meanings though so they're also provided as first-class types.

Finally the last case of a `ty` is simply an `id` which is intended to refer to
another type or resource defined in the document. Note that definitions can come
through a `use` statement or they can be defined locally.

## Handles

There are two types of handles in Wit: "owned" handles and "borrowed" handles.
Owned handles represent the passing of unique ownership of a resource between
two components. When the owner of an owned handle drops that handle, the
resource is destroyed. In contrast, a borrowed handle represents a temporary
loan of a handle from the caller to the callee for the duration of the call.

The syntax for handles is:
```ebnf
handle ::= id
         | 'borrow' '<' id '>'
```

The `id` case denotes an owned handle, where `id` is the name of a preceding
`resource` item. Thus, the "default" way that resources are passed between
components is via transfer of unique ownership.

The resource method syntax defined above is syntactic sugar that expands into
separate function items that take a first parameter named `self` of type
`borrow`. For example, the compound definition:
```
resource file {
    read: func(n: u32) -> list<u8>
}
```
is expanded into:
```
resource file
%[method]file.read: func(self: borrow<file>, n: u32) -> list<u8>
```
where `%[method]file.read` is the desugared name of a method according to the
Component Model's definition of [`name`](Explainer.md).


## Identifiers

Identifiers in `wit` can be defined with two different forms. The first is a
[kebab-case] identifier defined by the [`name`](Explainer.md#instance-definitions)
production in the Component Model text format.

```wit
foo: func(bar: u32) -> ()

red-green-blue: func(r: u32, g: u32, b: u32) -> ()
```

This form can't name identifiers which have the same name as wit keywords, so
the second form is the same syntax with the same restrictions as the first, but
prefixed with '%':

```wit
%foo: func(%bar: u32) -> ()

%red-green-blue: func(%r: u32, %g: u32, %b: u32) -> ()

// This form also supports identifiers that would otherwise be keywords.
%variant: func(%enum: s32) -> ()
```

[kebab-case]: https://en.wikipedia.org/wiki/Letter_case#Kebab_case

## Name resolution

A `wit` document is resolved after parsing to ensure that all names resolve
correctly. For example this is not a valid `wit` document:

```wit
type foo = bar  // ERROR: name `bar` not defined
```

Type references primarily happen through the `id` production of `ty`.

Additionally names in a `wit` document can only be defined once:

```wit
type foo = u32
type foo = u64  // ERROR: name `foo` already defined
```

Names do not need to be defined before they're used (unlike in C or C++),
it's ok to define a type after it's used:

```wit
type foo = bar

record bar {
    age: u32,
}
```

Types, however, cannot be recursive:

```wit
type foo = foo  // ERROR: cannot refer to itself

record bar1 {
    a: bar2,
}

record bar2 {
    a: bar1,  // ERROR: record cannot refer to itself
}
```

# Binary Format
[binary-format]: #binary-format

In addition to a textual format WIT packages can also be encoded to a binary
format. The binary format for WIT is represented as a WebAssembly Component
binary with a specific structure. The purpose of the WIT binary format is to:

* Provide a way to clearly define what an `interface` and a `world` map to in
  the component model. For example a host is said to implement an `interface` if
  it provides a subtype of the `instance` type defined in a component. Similarly
  a component is said to implement a `world` if the component's type is a
  subtype of the `world`'s type.

* Provide a means by which the textual format of WIT can be evolved while
  minimizing impact to the ecosystem. Similar to how the WebAssembly text format
  has changed over time it's envisioned that it may be necessary to change the
  WIT format for new features as new component model features are implemented.
  The binary format provides a clear delineation of what to ubiquitously consume
  without having to be so concerned with text format parsers.

* A binary format is intended to be more efficient parse and store.

The binary format for a WIT document can also be thought of in a loose sense as
a fully-resolved and indexed representation of a WIT document. Constructs such
as `use` are preserved but all name resolution has been boiled away to index
references. Additionally the transitive import set is all finalized as well.

An example of the binary format is that this document:

```wit
// host.wit
interface console {
  log: func(arg: string)
}
```

would correspond to:

```wasm
(component
  (type (export "host") (component
    (type $console (instance
      (export "log" (func (param "arg" string)))
    ))
    (export "console" (instance (type $console)))
  ))
)
```

Here it can be seen how an `interface` corresponds to an `instance` in the
component model. Note that the WIT document is encoded entirely within the type
section of a component and does not actually represent any concrete instances.
This is done to implement `use` statements:

```wit
// host.wit
interface types {
  enum level {
    info,
    debug,
  }
}

interface console {
  use self.types.{level}
  log: func(level: level, msg: string)
}
```

would correspond to:

```wasm
(component
  (type (export "host") (component
    (type $types (instance
      (type $level (enum "info" "debug"))
      (export "level" (type (eq $level)))
    ))
    (export $types "types" (instance (type $types)))
    (alias export $types "level" (type $level))
    (type $console (instance
      (export $level' "level" (type (eq $level)))
      (export "log" (func (param "level" $level') (param "msg" string)))
    ))
    (export "console" (instance (type $console)))
  ))
)
```

Here the `alias` of `"level"` indicates that the exact type is being used from a
different interface.

A `world` is represented as a component type.

```wit
// host.wit
world the-world {
  export test: func()
  export run: func()
}
```

would correspond to:

```wasm
(component
  (type (export "host") (component
    (export "the-world" (component
      (export "test" (func))
      (export "run" (func))
    ))
  ))
)
```

Component types in the WebAssembly component binary format cannot close over
outer instances so interfaces referred to by a component are redefined, at least
the parts needed, within the component:


```wit
// host.wit
world the-world {
  import console: console
}

interface console {
  log: func(arg: string)
}
```

would correspond to:

```wasm
(component
  (type (export "host") (component
    (type $console (instance
      (export "log" (func (param "arg" string)))
    ))
    (export "console" (instance (type $console)))
    (export "the-world" (component
      (import "console" (instance
        (export "log" (func (param "arg" string)))
      ))
    ))
  ))
)
```

Each WIT document in a package becomes a top-level export of the component:

```wit
// foo.wit
interface foo {}

// bar.wit
interface bar {}
```

would correspond to:

```wasm
(component
  (type (export "foo") (component
    (type $foo (instance
    ))
    (export "foo" (instance (type $foo)))
  ))
  (type (export "bar") (component
    (type $bar (instance
    ))
    (export "bar" (instance (type $bar)))
  ))
)
```

Imports of packages are encoded as imports to the outermost component
type as well.

```wit
// foo.wit
interface foo {
  use registry-package.types.{some-type}
}
```

would correspond to:

```wasm
(component
  (type (export "foo") (component
    (import "types" "URL" (instance $types
      (type $some-type ...)
      (export "some-type" (type (eq $some-type)))
    ))
    (alias export $types "some-type" (type $some-type))
    (type $foo (instance
      (export "some-type" (type (eq $some-type)))
    ))
    (export "foo" (instance (type $foo)))
  ))
)
```

Note that `URL` would be provided by external tooling providing the definition
of `registry-package` here as well.

Putting all of this together an example of development of the `wasi-http`
package would be:

```wit
// wasi-http repo

// wit/types.wit
default interface types {
  resource request { ... }
  resource response { ... }
}

// wit/handler.wit
default interface handler {
  use pkg.types.{request, response}
  handle: func(request) -> response
}

// wit/proxy.wit
default world proxy {
  import console: wasi-logging.backend
  import origin: pkg.handler
  export handler: pkg.handler
}
```

and its corresponding binary encoding would be:

```wasm
(component
  ;; corresponds to `wit/types.wit`
  (type (export "types") (component
    (export "types" (instance
      (type $request (record))
      (type $response (record))
      (export "request" (type (eq $request)))
      (export "response" (type (eq $response)))
    ))
  ))
  ;; corresponds to `wit/handler.wit`
  (type (export "handler") (component
    ;; interfaces not required in a document are imported here. The name "types"
    ;; with no URL refers to the `types` document in this package.
    (import "types" "pkg:/types/types" (instance $types
      (type $request (record))
      (type $response (record))
      (export "request" (type (eq $request)))
      (export "response" (type (eq $response)))
    ))

    ;; aliases represent `use` from the imported document
    (alias export $types "request" (type $request))
    (alias export $types "response" (type $response))
    (export "handler" (instance
      (export $request' "request" (type (eq $request)))
      (export $response' "response" (type (eq $response)))
      (export "handle" (func (param "request" $request') (result $response')))
    ))
  ))
  ;; corresponds to `wit/proxy.wit`
  (type (export "proxy") (component
    (export "proxy" (component
      ;; This world transitively depends on "types" so it's listed as an
      ;; import.
      (import "types" "pkg:/types/types" (instance $types
        (type $request (record))
        (type $response (record))
        (export "request" (type (eq $request)))
        (export "response" (type (eq $response)))
      ))
      (alias export $types "request" (type $request))
      (alias export $types "response" (type $response))

      ;; This is filled in with the contents of what `wasi-logging.backend`
      ;; resolved to
      (import "console" "dep:/foo/bar/baz" (instance
        ;; ...
      ))
      (import "origin" "pkg:/handler/handler" (instance
        (export $request' "request" (type (eq $request)))
        (export $response' "response" (type (eq $response)))
        (export "handle" (func (param "request" $request') (result $response')))
      ))
      (export "handler" "pkg:/handler/handler" (instance
        (export $request' "request" (type (eq $request)))
        (export $response' "response" (type (eq $response)))
        (export "handle" (func (param "request" $request') (result $response')))
      ))
    ))
  ))
)
```
