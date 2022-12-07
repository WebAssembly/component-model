# The `wit` format

The Wasm Interface Type (WIT) text format is a developer-friendly format to
describe the imports and exports of a component. The WIT format can be thought
of as an IDL of sorts to describe APIs that are grouped together as
[`interface`s][interfaces] inside of a [`world`][worlds]. WIT text files are
shared between producers of components and consumers of components as a format
for bindings generation in host and guest languages. The WIT text format
additionally provides a developer-friendly way to inspect an existing
component and learn about its imports and exports.

The WIT text format uses the file extension `wit`, for example `foo.wit` is
a WIT document. The contents of a `*.wit` file must be valid utf-8 bytes. WIT
documents can contain two items at the top-level: [`interface`][interfaces] and
[`world`][worlds].

## WIT Interfaces
[interfaces]: #wit-interfaces

An `interface` in WIT is a collection of [functions] and [types] which
corresponds to an instance in the component model. Interfaces can either be
imported or exported from [worlds] and represent imported and exported
instances.  For example this `interface`:

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
  (import "host" (insance $host
    (export "log" (func (param "msg" string)))
  ))
  ;; ...
)
```

An `interface` can contain [`use`][use] statements, [type][types] definitions,
and [function][functions] definitions. For example:

```wit
interface wasi-fs {
  use { errno } from "wasi-types"

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
documents are well-formed and acyclic.

## WIT Worlds
[worlds]: #wit-worlds

WIT documents can contain a `world` annotation at the top-level in addition to
[`interface`][interfaces]. A world is a complete description of both imports and
exports of a component. A world can be thought of as an equivalent of a
`component` type in the component model. For example this world:

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
world wasi {
  import wasi-fs: "wasi-fs"
  import wasi-random: "wasi-random"
  import wasi-clock: "wasi-clock"
  // ...

  export command: func(args: list<string>)
}
```

Additionally interfaces can be defined "inline" as a form of sugar for defining
it at the top-level

```wit
interface out-of-line {
  the-function: func()
}

world your-world {
  import out-of-line: out-of-line
  // ... is equivalent to ...
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
}
```

If no `default` world is specified in the WIT document and no named world is
explicitly chosen then bindings cannot be generated.

## WIT File Organization
[use]: #wit-file-organization

WIT files can be organized into separate files for maintainability and
reusability. This enables a sort of module system for WIT syntax where files may
import from one another.

> **Note**: The precise semantics of imports and how everything maps out is
> still being design. Basic filesystem-based organization works but it's
> intended to extend to URL-based organization in the near future. For example
> the strings below are intended to integrate into a registry-based workflow as
> well in addition to looking up files on the filesystem.

Within a single WIT file the `use` statement can be used to import between
interfaces:

```wit
interface types {
  enum errno { /* ... */ }

  type size = u32
}

interface my-host-functions {
  use { errno, size } from types
}
```

Here the `from` directive of the `use` is not quoted which means that it's
resolved relative to the WIT file itself. The `interface types` may come either
after or before the `use` directive's `interface`.

The `use` directive is not allowed to create cycles and must always form an
acyclic graph of dependencies between interfaces.

Names imported via `use` can be renamed as they're imported as well:

```wit
interface my-host-functions {
  use { errno as my-errno } from types
}
```

When importing or exporting an [interface][interfaces] in a [world][worlds]
unquoted names refer to [interfaces] defined elsewhere in the file:

```wit
world my-world {
  import host: host
}

interface host {
  // ...
}
```

The target of a `use` or the type of an import/export in a `world` may also be a
quoted string:

```wit
interface foo {
  use { /* ... */ } from "./other-file"
}

world my-world {
  import some-import: "./other-file"
  import another-import: "./other-directory/other-file"
}
```

This quoted string form indicates that the import is located in a different WIT
file. At this time all quoted strings must start with `./` or `../` and refer to
a file relative to the location of the current WIT file. This will eventually be
expanded to allow something along the lines of `"wasi:fs"` or similar but the
precise semantics here have not been defined.

The above directives, for example, will import from `./other-file.wit` (or
`./other-file.wit.md` as described [below][markdown]) and
`./other-directory/other-file.wit` (or `./other-directory/other-file.wit.md`).
The `.wit` extension is automatically appended to the lookup path and `.wit.md`
is tested if the `.wit` file doesn't exist.

Additionally the above directives require that `other-file.wit` contains an
interface marked `default`. Similar to [`default` worlds][worlds] a WIT file may
have multiple [`interface`s][interfaces] inside it and the import must happen
from one of them, so `default` is used to disambiguate:

```wit
// other-file.wit
default interface foo {
  // ...
}


// my-file.wit
default interface foo {
  use { /* ... */ } from "./other-file"
}
```

A `use` directive can also explicitly list the requested interface to select a
non-`default` one:

```wit
// other-file.wit
interface foo {
  // ...
}


// my-file.wit
default interface foo {
  use { /* ... */ } from foo in "./other-file"
}
```

Like before within a WIT file `use` statements must be acyclic between files as
well.

Splitting a WIT document into multiple files does not have an impact on its
final structure and it's purely a convenience to developers. Resolution of a WIT
document happens as-if everything were contained in one document (modulo
"hygienic" renaming where `use`-with-identifier still only works within one
file). This means that a WIT document can always be represented as a single
large WIT document with everything contained and separate-file organization is
not necessary.

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
    use { metadata } from shared

    get: func() -> metadata
  }
}
```

would generate this component :

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
the component additionally import a `shared` instance. This is due to the fact
that the `use { ... } from shared` implicitly requires that `shared` is imported
to the component as well.

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
    use { a-type } from "shared1"
  }
  import bar: interface {
    use { other-type } from "shared2"
  }
}
```

This is an invalid WIT document due because `my-world` needs to import two
unique interfaces called `shared`. To disambiguate a manual import is required:

```
world my-world {
  import shared1: "shared1"
  import shared2: "shared1"

  import foo: interface {
    use { a-type } from "shared1"
  }
  import bar: interface {
    use { other-type } from "shared2"
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

## WIT in Markdown
[markdown]: #wit-in-markdown

The WIT text format can also additionally be parsed from markdown files with the
extension `wit.md`, for example `foo.wit.md`:

    # This would be

    Some markdown text

    ```wit
    // interspersed with actual `*.wit`
    interface my-interface {
    ```

    ```wit
    // which can be broken up between multiple blocks
    }
    ```

Triple-fence code blocks with the `wit` marker will be extracted from a markdown
file and concatenated into a single string which is then parsed as a normal
`*.wit` file.

# Lexical structure

The `wit` format is a curly-braced-based format where whitespace is optional (but
recommended). A `wit` document is parsed as a unicode string, and when stored in
a file is expected to be encoded as utf-8.

Additionally, wit files must not contain any bidirectional override scalar
values, control codes other than newline, carriage return, and horizontal tab,
or codepoints that Unicode officially deprecates or strongly discourages.

The current structure of tokens are:

```wit
token ::= whitespace
        | comment
        | operator
        | keyword
        | identifier
        | strlit
```

Whitespace and comments are ignored when parsing structures defined elsewhere
here.

### Whitespace

A `whitespace` token in `wit` is a space, a newline, a carriage return, or a
tab character:

```wit
whitespace ::= ' ' | '\n' | '\r' | '\t'
```

### Comments

A `comment` token in `wit` is either a line comment preceded with `//` which
ends at the next newline (`\n`) character or it's a block comment which starts
with `/*` and ends with `*/`. Note that block comments are allowed to be nested
and their delimiters must be balanced

```wit
comment ::= '//' character-that-isnt-a-newline*
          | '/*' any-unicode-character* '*/'
```

There is a special type of comment called `documentation comment`. A
`doc-comment` is either a line comment preceded with `///` which ends at the next
newline (`\n`) character or it's a block comment which starts with `/**` and ends
with `*/`. Note that block comments are allowed to be nested and their delimiters
must be balanced

```wit
doc-comment ::= '///' character-that-isnt-a-newline*
          | '/**' any-unicode-character* '*/'
```

### Operators

There are some common operators in the lexical structure of `wit` used for
various constructs. Note that delimiters such as `{` and `(` must all be
balanced.

```wit
operator ::= '=' | ',' | ':' | ';' | '(' | ')' | '{' | '}' | '<' | '>' | '*' | '->'
```

### Keywords

Certain identifiers are reserved for use in `wit` documents and cannot be used
bare as an identifier. These are used to help parse the format, and the list of
keywords is still in flux at this time but the current set is:

```wit
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
          | 'from'
          | 'static'
          | 'interface'
          | 'tuple'
          | 'future'
          | 'stream'
          | 'world'
          | 'import'
          | 'export'
          | 'default'
          | 'in'
```

## Top-level items

A `wit` document is a sequence of items specified at the top level. These items
come one after another and it's recommended to separate them with newlines for
readability but this isn't required.

Concretely, the structure of a `wit` document is:
```
wit-document ::= (interface-item | world-item)*
```

## Item: `world`

Worlds define a [componenttype](https://github.com/WebAssembly/component-model/blob/main/design/mvp/Explainer.md#type-definitions) as a collection of imports and exports.

Concretely, the structure of a world is:

```wit
world-item ::= 'default'? 'world' id '{' world-items* '}'

world-items ::= export-item | import-item

export-item ::= 'export' id ':' extern-type
import-item ::= 'import' id ':' extern-type

extern-type ::= func-type | interface-type

interface-type ::= 'interface' '{' interface-items* '}'
                 | use-from
```

## Item: `interface`

Interfaces can be defined in a `wit` document. Interfaces have a name and a sequence of items and functions.

Specifically interfaces have the structure:

```wit
interface-item ::= 'default'? 'interface' id '{' interface-items* '}'

interface-items ::= resource-item
                  | variant-items
                  | record-item
                  | union-items
                  | flags-items
                  | enum-items
                  | type-item
                  | use-item
                  | func-item

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
use * from other-file
use { a, list, of, names } from another-file
use { name as other-name } from interface in "yet-another-file"
```

Specifically the structure of this is:

```wit
use-item ::= 'use' use-names 'from' use-from

use-names ::= '*'
            | '{' use-names-list '}'

use-names-list ::= use-names-item
                 | use-names-item ',' use-names-list?

use-names-item ::= id
                 | id 'as' id

use-from ::= id
           | strlit
           | id 'in' strlit
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

```wit
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

```wit
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

```wit
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

```wit
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

```wit
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

```wit
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

```wit
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

In addition to a textual format WIT files can also be encoded to a binary
format. The binary format is itself a WebAssembly component and is chosen to be
a more stable artifact over time than the text format in case text format
updates are required. Additionally being represented by the component binary
format means that it's guaranteed that all features of WIT are representable in
the component model.

The binary format for a WIT document can also be thought of in a loose sense as
a fully-resolved and indexed representation of a WIT document. Constructs such
as `use` are preserved but all name resolution has been boiled away to index
references. Additionally the transitive import set is all finalized as well.

An example of the binary format is that this document:

```wit
interface host {
  log: func(arg: string)
}

world the-world {
  import host: host
  export run: func()
}
```

would correspond to:

```wasm
(component
  (type $wit (instance
    (type $host (instance
      (export "log" (func (param "arg" string)))
    ))
    (export "host" (type $host))

    (type $the-world (component
      (import "host" (instance (type $host)))
      (export "run" (func))
    ))
    (export "the-world" (type $the-world))
  ))
  (export "wit" (type $wit))
)
```

Here it can be seen that the entire document itself is represented as an
`instance` type with named exports. Within this `instance` type each export is
either itself an `instance` or a `component` with `instance`s corresponding to
an `interface` in WIT and `component`s corresponding to `world`s. The outer
component has a single export named `wit` which points to the instance type that
describes the document.

Types defined within a WIT interface are additionally defined within the wasm
`instance`. Additionally `use` of types between interfaces is encoded with
aliases between them.

```wit
interface shared {
  record metadata {
    // ...
  }
}

world the-world {
  import host: interface {
    use { metadata } from shared

    get: func() -> metadata
  }

  export db: interface {
    use { metadata } from shared

    get: func(data: metadata) -> string
  }
}
```

would correspond to:

```wasm
(component
  (type $wit (instance
    (type $shared (instance
      (type $metadata (record (; ... ;)))
      (export "metadata" (type (eq $metadata)))
    ))
    (export $shared "shared" (type $shared))
    (alias export $shared "metadata" (type $outer-metadata))

    (type $host (instance
      (export $metadata "metadata" (type $outer-metadata))
      (export "get" (func (result $metadata)))
    ))
    (export $host "host" (type $host))

    (type $db (instance
      (export $metadata "metadata" (type $outer-metadata))
      (export "get" (func (param "data" $metadata) (result string)))
    ))
    (export $db "db" (type $db))

    (type $the-world (component
      (import "shared" (instance (type $shared)))
      (import "host" (instance (type $host)))
      (export "db" (instance (type $db)))
    ))
    (export "the-world" (type $the-world))
  ))
  (export "wit" (type $wit))
)
```

A `world` in a WIT document describes a concrete component, and is represented
in this binary representation as a `component` type (e.g. `$the-world` above).
Tooling which creates a WebAssembly component from a `world` is expected to
create a component that is a subtype of this type.
