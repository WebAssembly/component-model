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

A WIT package is a collection of WIT [`interface`s][interfaces] and
[`world`s][worlds] defined in files in the same directory that that all use the
file extension `wit`, for example `foo.wit`. Files are encoded as valid utf-8
bytes. Types can be imported between interfaces within a package and
additionally from other packages through IDs.

This document will go through the purpose of the syntactic constructs of a WIT
document, a pseudo-formal [grammar specification][lexical-structure], and
additionally a specification of the [binary format][binary-format] of a WIT
package suitable for distribution.

[IDL]: https://en.wikipedia.org/wiki/Interface_description_language
[components]: https://github.com/webassembly/component-model

## Package identifiers

All WIT packages are assigned an "ID". IDs look like `foo:bar@1.0.0` and have
three components:

* A namespace, for example `foo` in `foo:bar`. This namespace is intended to
  disambiguate between registries, top-level organizations, etc. For example
  WASI interfaces use the `wasi` namespace.

* A package name, for example `clocks` in `wasi:clocks`. A package name groups
  together a set of interfaces and worlds that would otherwise be named with a
  common prefix.

* An optional version, specified as [full semver](https://semver.org/).

Package identifiers are specified at the top of a WIT file via a `package`
declaration:

```wit
package wasi:clocks
```

or

```wit
package wasi:clocks@1.2.0
```

WIT packages can be defined in a collection of files and at least one of them
must specify a `package` identifier. Multiple files can specify a `package` and
they must all agree on what the identifier is.

Package identifiers are used to generate IDs in the component model binary
format for [`interface`s][interfaces] and [`world`s][worlds].

## WIT Interfaces
[interfaces]: #wit-interfaces

The concept of an "interface" is central in WIT as a collection of [functions]
and [types]. An interface can be thought of as an instance in the WebAssembly
Component Model, for example a unit of functionality imported from the host or
implemented by a component for consumption on a host. All functions and types
belong to an interface.

An example of an interface is:

```wit
package local:demo

interface host {
  log: func(msg: string)
}
```

represents an interface called `host` which provides one function, `log`, which
takes a single `string` argument. If this were imported into a component then it
would correspond to:

```wasm
(component
  (import (interface "local:demo/host") (instance $host
    (export "log" (func (param "msg" string)))
  ))
  ;; ...
)
```

An `interface` can contain [`use`][use] statements, [type][types] definitions,
and [function][functions] definitions. For example:

```wit
package wasi:filesystem

interface types {
  use wasi:clocks.wall-clock.{datetime}

  record stat {
    ino: u64,
    size: u64,
    mtime: datetime,
    // ...
  }

  stat-file: func(path: string) -> result<stat>
}
```

More information about [`use`][use] and [types] are described below, but this
is an example of a collection of items within an `interface`. All items defined
in an `interface`, including [`use`][use] items, are considered as exports from
the interface. This means that types can further be used from the interface by
other interfaces. An interface has a single namespace which means that none of
the defined names can collide.

A WIT package can contain any number of interfaces listed at the top-level and
in any order. The WIT validator will ensure that all references between
interfaces are well-formed and acyclic.

## WIT Worlds
[worlds]: #wit-worlds

WIT packages can contain `world` definitions at the top-level in addition to
[`interface`][interfaces] definitions. A world is a complete description of
both imports and exports of a component. A world can be thought of as an
equivalent of a `component` type in the component model. For example this
world:

```wit
package local:demo

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
package local:demo

world command {
  import wasi:filesystem/filesystem
  import wasi:random/random
  import wasi:clocks/monotonic-clock
  // ...

  export main: func(args: list<string>)
}
```

More information about the `wasi:random/random` syntax is available below in the
description of [`use`][use].

An imported or exported interface corresponds to an imported or exported
instance in the component model. Functions are equivalent to bare component
functions.
Additionally interfaces can be defined inline with an explicit kebab-name that
avoids the need to have an out-of-line definition.

```wit
package local:demo

interface out-of-line {
  the-function: func()
}

world your-world {
  import out-of-line
  // ... is roughly equivalent to ...
  import out-of-line: interface {
    the-function: func()
  }
}
```

The kebab name of the `import` or `export` is the name of the corresponding item
in the final component.

In the component model imports to a component either use an ID or a
kebab-name, and in WIT this is reflected in the syntax:

```wit
package local:demo

interface my-interface {
  // ..
}

world command {
  // generates an import of the ID `local:demo/my-interface`
  import my-interface

  // generates an import of the ID `wasi:filesystem/types`
  import wasi:filesystem/types

  // generates an import of the kebab-name `foo`
  import foo: func()

  // generates an import of the kebab-name `bar`
  import bar: interface {
    // ...
  }
}
```

Kebab names cannot overlap and must be unique, even between imports and exports.
IDs, however, can be both imported and exported. The same interface cannot be
explicitly imported or exported twice.

## WIT Packages and `use`
[use]: #wit-packages-and-use

A WIT package represents a unit of distribution that can be published to a
registry, for example, and used by other WIT packages. WIT packages are a flat
list of interfaces and worlds defined in `*.wit` files. The current thinking
for a convention is that projects will have a `wit` folder where all
`wit/*.wit` files within describe a single package.

The purpose of the `use` statement is to enable sharing types between
interfaces, even if they're defined outside of the current package in a
dependency. The `use` statement can be used both within interfaces and worlds
and at the top-level of a WIT file.

#### Interfaces, worlds, and `use`

A `use` statement inside of an `interface` or `world` block can be used to
import types:

```wit
package local:demo

interface types {
  enum errno { /* ... */ }

  type size = u32
}

interface my-host-functions {
  use types.{errno, size}
}
```

The `use` target, `types`, is resolved within the scope of the package to an
interface, in this case defined prior. Afterwards a list of types are provided
as what's going to be imported with the `use` statement. The interface `types`
may textually come either after or before the `use` directive's interface.
Interfaces linked with `use` must be acyclic.

Names imported via `use` can be renamed as they're imported as well:

```wit
package local:demo

interface my-host-functions {
  use types.{errno as my-errno}
}
```

This form of `use` is using a single identifier as the target of what's being
imported, in this case `types`. The name `types` is first looked up within the
scope of the current file, but it will additionally consult the package's
namespace as well. This means that the above syntax still works if the
interfaces are defined in sibling files:

```wit
// types.wit
interface types {
  enum errno { /* ... */ }

  type size = u32
}

// host.wit
package local:demo

interface my-host-functions {
  use types.{errno, size}
}
```

Here the `types` interface is not defined in `host.wit` but lookup will find it
as it's defined in the same package, just instead in a different file.

When importing or exporting an [interface][interfaces] in a [world][worlds]
the same syntax is used in `import` and `export` directives:

```wit
// a.wit
package local:demo

world my-world {
  import host

  export another-interface
}

interface host {
  // ...
}

// b.wit
interface another-interface {
  // ...
}
```

When referring to an interface an ID form can additionally be used to refer to
dependencies. For example above it was seen:

```wit
package local:demo

world my-world {
  import wasi:clocks/monotonic-clock
}
```

Here the interface being referred to is the ID `wasi:clocks/monotonic-clock`.
This is the package identified by `wasi:clocks` and the interface
`monotonic-clock` within that package. This same syntax can be used in `use` as
well:

```wit
package local:demo

interface my-interface {
  use wasi:http/types.{request, response}
}
```

#### Top-level `use`

If a package being referred to has a version number, then using the above syntax
so far it can get a bit repetitive to be referred to:

```wit
package local:demo

interface my-interface {
  use wasi:http/types@1.0.0.{request, response}
}

world my-world {
  import wasi:http/handler@1.0.0
  export wasi:http/handler@1.0.0
}
```

To reduce repetition and to possibly help avoid naming conflicts the `use`
statement can additionally be used at the top-level of a file to rename
interfaces within the scope of the file itself. For example the above could be
rewritten as:

```wit
package local:demo

use wasi:http/types@1.0.0
use wasi:http/handler@1.0.0

interface my-interface {
  use types.{request, response}
}

world my-world {
  import handler
  export handler
}
```

The meaning of this and the previous world are the same, and `use` is purely a
developer convenience for providing smaller names if necessary.

The interface referred to by a `use` is the name that is defined in the current
file's scope:

```wit
package local:demo

use wasi:http/types   // defines the name `types`
use wasi:http/handler // defines the name `handler`
```

Like with interface-level-`use` the `as` keyword can be used to rename the
inferred name:

```wit
package local:demo

use wasi:http/types as http-types
use wasi:http/handler as http-handler
```

Note that these can all be combined to additionally import packages with
multiple versions and renaming as different identifiers.

```wit
package local:demo

use wasi:http/types@1.0.0 as http-types1
use wasi:http/types@2.0.0 as http-types2

// ...
```

### Transitive imports and worlds

A `use` statement is not implemented by copying type information around but
instead retains that it's a reference to a type defined elsewhere. This
representation is plumbed all the way through to the final component, meaning
that `use`d types have an impact on the structure of the final generated
component.

For example this document:

```wit
package local:demo

interface shared {
  record metadata {
    // ...
  }
}

world my-world {
  import host: interface {
    use shared.{metadata}

    get: func() -> metadata
  }
}
```

would generate this component:

```wasm
(component
  (import (interface "local:demo/shared") (instance $shared
    (type $metadata (record (; ... ;)))
    (export "metadata" (type (eq $metadata)))
  ))
  (alias export $shared "metadata" (type $metadata_from_shared))
  (import "host" (instance $host
    (export $metadata_in_host "metadata" (type (eq $metadata_from_shared)))
    (export "get" (func (result $metadata_in_host)))
  ))
)
```

Here it can be seen that despite the `world` only listing `host` as an import
the component additionally imports a `local:demo/shared` interface. This is due
to the fact that the `use shared.{ ... }` implicitly requires that `shared` is
imported into the component as well.

Note that the name `"local:demo/shared"` here is derived from the name of the
`interface` plus the package ID `local:demo`.

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
package local:demo

interface foo {
  a1: func()
  a2: func(x: u32)
  a3: func(y: u64, z: float32)
}
```

Functions can return at most one unnamed type:

```wit
package local:demo

interface foo {
  a1: func() -> u32
  a2: func() -> string
}
```

And functions can also return multiple types by naming them:

```wit
package local:demo

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
package local:demo

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
        | operator
        | keyword
        | integer
        | identifier
```

Whitespace and comments are ignored when parsing structures defined elsewhere
here.

### Whitespace

A `whitespace` token in `wit` is a space, a newline, a carriage return, a
tab character, or a comment:

```ebnf
whitespace ::= ' ' | '\n' | '\r' | '\t' | comment
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
operator ::= '=' | ',' | ':' | ';' | '(' | ')' | '{' | '}' | '<' | '>' | '*' | '->' | '/' | '.' | '@'
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
          | 'record'
          | 'enum'
          | 'flags'
          | 'variant'
          | 'union'
          | 'static'
          | 'interface'
          | 'world'
          | 'import'
          | 'export'
          | 'package'
```

### Integers

Integers are currently only used for package versions and are a contiguous
sequence of digits:

```ebnf
integer ::= [0-9]+
```

## Top-level items

A `wit` document is a sequence of items specified at the top level. These items
come one after another and it's recommended to separate them with newlines for
readability but this isn't required.

Concretely, the structure of a `wit` file is:

```ebnf
wit-file ::= package-decl? (toplevel-use-item | interface-item | world-item)*
```

## Package declaration

WIT files optionally start with a package declaration which defines the ID of
the package.

```ebnf
package-decl        ::= 'package' id ':' id ('@' valid-semver)?
```

The production `valid-semver` is as defined by
[Semantic Versioning 2.0](https://semver.org/) and optional.

## Item: `toplevel-use`

A `use` statement at the top-level of a file can be used to bring interfaces
into the scope of the current file and/or rename interfaces locally for
convenience:

```ebnf
toplevel-use-item ::= 'use' interface ('as' id)?

interface ::= id
            | id ':' id '/' id ('@' valid-semver)?
```

Here `interface` is the ID used to refer to interfaces. The bare form `id`
refers to interfaces defined within the current package, and the full form
refers to interfaces in package dependencies.

The `as` syntax can be optionally used to specify a name that should be assigned
to the interface. Otherwise the name is inferred from `interface`.

## Item: `world`

Worlds define a [componenttype](https://github.com/WebAssembly/component-model/blob/main/design/mvp/Explainer.md#type-definitions) as a collection of imports and exports.

Concretely, the structure of a world is:

```ebnf
world-item ::= 'world' id '{' world-items* '}'

world-items ::= export-item | import-item | use-item | typedef-item

export-item ::= 'export' id ':' extern-type
              | 'export' interface
import-item ::= 'import' id ':' extern-type
              | 'import' interface

extern-type ::= func-type | 'interface' '{' interface-items* '}'
```

Note that worlds can import types and define their own types to be exported
from the root of a component and used within functions imported and exported.
The `interface` item here additionally defines the grammar for IDs used to refer
to `interface` items.

## Item: `interface`

Interfaces can be defined in a `wit` file. Interfaces have a name and a
sequence of items and functions.

Specifically interfaces have the structure:

> **Note**: The symbol `ε`, also known as Epsilon, denotes an empty string.

```ebnf
interface-item ::= 'interface' id '{' interface-items* '}'

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

result-list ::= ϵ
              | '->' ty
              | '->' '(' named-type-list ')'

named-type-list ::= ϵ
                  | named-type ( ',' named-type )*

named-type ::= id ':' ty
```

## Item: `use`

A `use` statement enables importing type or resource definitions from other
wit packages or interfaces. The structure of a use statement is:

```wit
use an-interface.{a, list, of, names}
use my:dependency/the-interface.{more, names as foo}
```

Specifically the structure of this is:

```ebnf
use-item ::= 'use' interface '.' '{' use-names-list '}'

use-names-list ::= use-names-item
                 | use-names-item ',' use-names-list?

use-names-item ::= id
                 | id 'as' id
```

Note: Here `use-names-list?` means at least one `use-name-list` term.

## Items: type

There are a number of methods of defining types in a `wit` package, and all of
the types that can be defined in `wit` are intended to map directly to types in
the [component model](https://github.com/WebAssembly/component-model).

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

### Item: `resource`

A `resource` statement defines a new abstract type for a *resource*, which is
an entity with a lifetime that can only be passed around indirectly via [handle
values](#handles). Resource types are used in interfaces to describe things
that can't or shouldn't be copied by value.

For example, the following Wit defines a resource type and a function that
takes and returns a handle to a `blob`:
```wit
resource blob
transform: func(blob) -> blob
```

As syntactic sugar, resource statements can also declare any number of
*methods*, which are functions that implicitly take a `self` parameter that is
a handle. A resource statement can also contain any number of *static
functions*, which do not have an implicit `self` parameter but are meant to be
lexically nested in the scope of the resource type. Lastly, a resource
statement can contain at most one *constructor* function, which is syntactic
sugar for a function returning a handle of the containing resource type.

For example, the following resource definition:
```wit
resource blob {
    constructor(init: list<u8>)
    write: func(bytes: list<u8>)
    read: func(n: u32) -> list<u8>
    merge: static func(lhs: borrow<blob>, rhs: borrow<blob>) -> blob
}
```
desugars into:
```wit
resource blob
%[constructor]blob: func(self: borrow<blob>, bytes: list<u8>) -> blob
%[method]blob.write: func(self: borrow<blob>, bytes: list<u8>)
%[method]blob.read: func(self: borrow<blob>, n: u32) -> list<u8>
%[static]blob.merge: func(lhs: borrow<blob>, rhs: borrow<blob>) -> blob
```
These `%`-prefixed [`name`s](Explainer.md) embed the resource type name so that
bindings generators can generate idiomatic syntax for the target language or
(for languages like C) fall back to an appropriately-prefixed free function
name.

When a resource type name is used directly (e.g. when `blob` is used as the
return value of the constructor above), it stands for an "owning" handle
that will call the resource's destructor when dropped. When a resource
type name is wrapped with `borrow<...>`, it stands for a "borrowed" handle
that will *not* call the destructor when dropped. As shown above, methods
always desugar to a borrowed self parameter whereas constructors always
desugar to an owned return value.

Specifically, the syntax for a `resource` definition is:
```ebnf
resource-item ::= 'resource' id resource-methods?
resource-methods ::= '{' resource-method* '}'
resource-method ::= func-item
                  | id ':' 'static' func-type
                  | 'constructor' param-list
```

The syntax for handle types is presented [below](#handles).

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

The syntax for handles is:
```ebnf
handle ::= id
         | 'use' '<' id '>'
         | 'consume' '<' id '>'
         | 'borrow' '<' id '>'
         | 'child' id ( 'of' id )?
         | 'child' 'use' '<' id '>' ( 'of' id )?
```

The `id` case translates to the component handle type `(own id)`, where `id`
must resolve to a resource type. Thus, `own` is the "default" handle type. The
other `H<id>` cases map to the analogous `handle` type abbreviations. The
complete 2x3 matrix of ownership and scope is:

| `(handle R ...)` | `own`          | `use`               |
|------------------|----------------|---------------------|
|                  | `R`            | `use<R>`            |
| `(parent p)`     | `child R of p` | `child use<R> of p` |
| `call`           | `consume<R>`   | `borrow<R>`         |


The `child` prefix adds the `parent` scope to the succeeding handle type. If
the `of` suffix is present, then `id` is the name of the parameter that
points to the parent. If the `of` suffix is absent, then a default id of
`self` is used.

The resource method syntax defined above is syntactic sugar that expands into
separate function items that take a first parameter named `self` of type
`borrow`. For example, the compound definition:
```
resource file {
    read-sync: func(n: u32) -> list<u8>
    read-async: func(n: u32) -> child input-stream
}
```
is equivalent to:
```
resource file
%[method]file.read-sync: func(self: borrow<file>, n: u32) -> list<u8>
%[method]file.read-async: func(self: borrow<file>, n: u32) -> child input-stream of self
```
where `%[method]file.read-sync` is the desugared name of a method according to the
Component Model's definition of [`name`](Explainer.md).

TODO: introduce `destructor` as resource sugar for `self: consume<R>`


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
package local:demo

interface console {
  log: func(arg: string)
}
```

would correspond to:

```wasm
(component
  (type $demo (component
    (type $console (instance
      (export "log" (func (param "arg" string)))
    ))
    (export (interface "local:demo/console") (instance (type $console)))
  ))
  (export (interface "local:demo/wit") (type $demo))
)
```

Here it can be seen how an `interface` corresponds to an `instance` in the
component model. Note that the WIT package is encoded entirely within the type
section of a component and does not actually represent any concrete instances.
This is done to implement `use` statements:

```wit
// host.wit
package local:demo

interface types {
  enum level {
    info,
    debug,
  }
}

interface console {
  use types.{level}

  log: func(level: level, msg: string)
}
```

would correspond to:

```wasm
(component
  (type $demo (component
    (type $types' (instance
      (type $level (enum "info" "debug"))
      (export "level" (type (eq $level)))
    ))
    (export $types (interface "local:demo/types") (instance (type $types')))
    (alias export $types "level" (type $level'))
    (type $console (instance
      (alias outer $demo $level' (type $level''))
      (export $level "level" (type (eq $level'')))
      (export "log" (func (param "level" $level) (param "msg" string)))
    ))
    (export (interface "local:demo/console") (instance (type $console)))
  ))
  (export (interface "local:demo/wit") (type $demo))
)
```

Here the `alias` of `"level"` indicates that the exact type is being used from a
different interface.

A `world` is represented as a component type.

```wit
// host.wit
package local:demo

world the-world {
  export test: func()
  export run: func()
}
```

would correspond to:

```wasm
(component
  (type $demo (component
    (type $the-world (component
      (export "test" (func))
      (export "run" (func))
    ))
    (export (interface "local:demo/the-world") (component (type $the-world)))
  ))
  (export (interface "local:demo/wit") (type $demo))
)
```

Component types in the WebAssembly component binary format cannot close over
outer instances so interfaces referred to by a component are redefined, at least
the parts needed, within the component:


```wit
// host.wit
package local:demo

world the-world {
  import console
}

interface console {
  log: func(arg: string)
}
```

would correspond to:

```wasm
(component
  (type $demo (component
    (type $console (instance
      (export "log" (func (param "arg" string)))
    ))
    (export (interface "local:demo/console") (instance (type $console)))
    (type $the-world (component
      (type $console (instance
        (export "log" (func (param "arg" string)))
      ))
      (import (interface "local:demo/console") (instance (type $console)))
    ))
    (export (interface "local:demo/the-world") (component (type $the-world)))
  ))
  (export (interface "local:demo/wit") (type $demo))
)
```

Imports of packages are encoded as imports to the outermost component
type as well.

```wit
// foo.wit
package local:demo

interface foo {
  use wasi:http/types.{some-type}
}
```

would correspond to:

```wasm
(component
  (type (export (interface "local:demo/wit")) (component
    (import (interface "wasi:http/types") (instance $types
      (type $some-type ...)
      (export "some-type" (type (eq $some-type)))
    ))
    (alias export $types "some-type" (type $some-type))
    (type $foo (instance
      (export "some-type" (type (eq $some-type)))
    ))
    (export (interface "local:demo/foo") (instance (type $foo)))
  ))
)
```

Putting all of this together an example of development of the `wasi-http`
package would be:

```wit
// wasi-http repo

// wit/types.wit
interface types {
  resource request { ... }
  resource response { ... }
}

// wit/handler.wit
interface handler {
  use types.{request, response}
  handle: func(request) -> response
}

// wit/proxy.wit
package wasi:http

world proxy {
  import wasi:logging/backend
  import handler
  export handler
}
```

and its corresponding binary encoding would be:

```wasm
(component
  (type $http (component
    ;; interface types
    (type $types (instance
      (type $request (record))
      (type $response (record))
      (export "request" (type (eq $request)))
      (export "response" (type (eq $response)))
    ))
    (export $types (interface "wasi:http/types") (instance (type $types)))
    (alias export $types "request" (type $request'))
    (alias export $types "response" (type $response'))

    ;; interface handler
    (type $handler (instance
      (export $request "request" (type (eq $request')))
      (export $response "response" (type (eq $response')))
      (export "handle" (func (param "request" $request) (result $response)))
    ))
    (export (interface "wasi:http/handler") (instance (type $handler)))

    ;; world proxy
    (type $proxy (component
      ;; import of `wasi:logging/backend`
      (type $backend
        (instance)
      )
      (import (interface "wasi:logging/backend") (instance (type $backend)))

      ;; transitive import of `wasi:http/types`
      (type $types (instance
        (type $request (record))
        (type $response (record))
        (export "request" (type (eq $request)))
        (export "response" (type (eq $response)))
      ))
      (import (interface "wasi:http/types") (instance $types (type $types)))
      (alias export $types "request" (type $request'))
      (alias export $types "response" (type $response'))

      ;; import of `wasi:http/handler`
      (type $handler (instance
        (export $request "request" (type (eq $request')))
        (export $response "response" (type (eq $response')))
        (export "handle" (func (param "request" $request) (result $response)))
      ))
      (import (interface "wasi:http/handler") (instance (type $handler)))

      ;; import of `wasi:http/handler`
      (export (interface "wasi:http/handler") (instance (type $handler)))
    ))
    (export (interface "wasi:http/proxy") (component (type $proxy)))
  ))
  (export (interface "wasi:http/wit") (type $http))
)
```
