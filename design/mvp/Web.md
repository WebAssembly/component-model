# Web API for Components

This explainer describes how WebAssembly Components (hereafter 'components') can be used in a web engine. It could also be used in non-web engines (such as Node) that support the subset of WebIDL used in this document.

This spec would be layered on a future component embedder interface (similar to how the JS-API is layered on the core spec embedder interface).

**This is a draft and is not complete. Major details are unresolved, and there are bugs. See "Open Questions" at the end for a sampling of them.**

## Goals

1. Components can import and use most web and JS API's
2. Components can export an API useable by JS
3. Components interact with the web platform in similar ways to JS:
  a. Components can feature test whether API's are present
  b. Components work whether they are importing a web API, or a JS polyfill, or a component polyfill
  c. Components are tolerant of web API evolution
  d. Components misuse of a web API's result in failure at that call-site, not link time errors
4. Components have improved performance when calling web API's compared to today

## Non-goals

1. Components importing every kind of web API
1. Components exporting any kind of JS API

## Design

To meet our goals, we need to define interactions (also known as 'bindings') between components, web API's, and JS.

The scripting interface for web API's is handled (almost but not entirely) by WebIDL, so bindings for web API's effectively means bindings for WebIDL. WebIDL already has a "JavaScript Bindings" section which defines how JS interacts with WebIDL. There are no other bindings yet supported by WebIDL.

There are roughly three paths forward here:

1. Define bindings between components and JS - components transitively have access to web API's through the pre-existing JS-WebIDL bindings.
2. (1) and also define bindings between components and WebIDL - components get a separate direct path to web API's.
3. Define bindings between components and WebIDL - components transitively have access to JS through the pre-existing JS-WebIDL bindings.

There are pros/cons to each. Let's go through them.

### A. Define only bindings between Components and JS

This is the smallest step from where we are today. A component's imports and exports are described in terms of JS values, and the web platform is reached the same way JS reaches it.

Goals #1, #2 and #3 mostly fall out for free. Web API's are already exposed to JS, so importing one is just importing the JS function that reflects it, and exporting to JS is given by the binding. Feature testing, polyfilling and API evolution are all properties the WebIDL-JS binding already supports, so they keep working without us specifying anything new.

The problem is goal #4. Once a call into a web API is defined as a call through JS, JS semantics are observable at every step. Lookups on the global object and on prototypes can be intercepted, argument coercion can run user code through `valueOf`, `toString` and iterators, and the callee may be a Proxy. An engine can speculate and fast-path the common case, but it cannot skip those steps in general. TODO(elaborate).

JS (specifically ECMA-262) also is missing many concepts that components require. Components have resources, streams, sized integers and guaranteed-valid unicode strings. WebIDL has interface types, `ReadableStream`, sized integer types and `USVString`. JS just has objects and doubles. Going through JS means lowering all of those concepts down to their JS representations so that the JS-WebIDL bindings can immediately raise them back up. Both conversions still have to be specified, and information can be lost in the middle.

### B. Define bindings between Components and JS and also Components and WebIDL

This is a superset of option A, so it inherits the pros/cons of that. In addition, we add a parallel binding between components and WebIDL to get goal #4 as well. Components that only need to talk to JS use the JS binding, and components that use web API's use the WebIDL binding.

The cost is that we write and maintain two bindings, and they have to harmonize.

### C. Define only bindings between Components and WebIDL

JS already has well-defined bindings to WebIDL. If we define bindings from components to WebIDL, we get direct and efficient access to web API's (goal #4) and transitively get access to JS (goals #1 and #2).

Like #1 we only have one specification to draft and maintain.

The open question is goal #3. We need to decide how feature testing, polyfills and API evolution work in the direct WebIDL binding. This is new conceptual ground that needs careful design.

### Conclusion

We should take option C. Option A has too many cons, while option B is twice the work to implement and maintain. Option C has the potential to get us everything we want at the smallest conceptual burden.

## Walkthrough

Let's walk through how this all works in practice. After this will be an in-depth explainer of the exact proposed rules.

### A greeter

Start with a component that imports nothing:

```wit
package example:greeter;

world greeter {
  export greet: func(name: string) -> string;
}
```

Exports are converted to canonical WebIDL which is then exposed to JS through the existing WebIDL-to-JS machinery. A component `string` is a sequence of unicode scalar values, which is exactly what WebIDL calls a `USVString`, so this component is described as:

```webidl
namespace {
  USVString greet(USVString name);
};
```

What JS gets is an ordinary object with an ordinary method on it:

```js
const { instance } = await WebAssembly.instantiate(bytes);
instance.exports.greet("world");  // "hello, world"
```

The JS caller interacts with greet like any normal WebIDL operation. For example, `greet(42)` converts the number to a string and passes `"42"`, and `greet()` throws a `TypeError` for the missing argument.

### A logger

Now a component that imports:

```wit
package example:logger;

world logger {
  import log: func(message: string);
  export run: func();
}
```

The obvious thing to pass is `console.log`:

```js
const { instance } = await WebAssembly.instantiate(bytes, {
  log: console.log,
});
```

`console.log` is a web API, so the engine already knows its [WebIDL signature](https://console.spec.whatwg.org/#console-namespace):
```
undefined log(any... data);
```

it takes any number of arguments of any type. The component's `message` is a string, and a string is one of the things it can take, so there is nothing to convert and nothing to check.

#### Polyfilling it

Now suppose `console.log` isn't available, or we want to capture the output. Pass a plain JS function instead:

```js
const lines = [];
const log = (message) => { lines.push(message); };
const { instance } = await WebAssembly.instantiate(bytes, {
  log,
});
```

A plain JS function has no WebIDL signature, so we treat it as one that takes anything and returns anything, and convert the component's values to JS values on the way in.

Since both work, the choice can be made in JS before the component is instantiated:

```js
const log = globalThis.console?.log ?? myPolyfill;
```

### Searching the DOM

Now let's import a resource type and a more complex API.

```wit
package example:search;

interface dom {
  resource element {
    query-selector: func(selectors: string) -> option<element>;
    get-attribute: func(name: string) -> option<string>;
    scroll-into-view: func(align-to-top: bool);
  }
}

world search {
  import dom;
  export find: func(root: borrow<element>, selectors: string) -> option<string>;
}
```

To satisfy all of that, you can just import `Element` itself:

```js
const { instance } = await WebAssembly.instantiate(bytes, { element: Element });

instance.exports.find(document.body, "h1");  // "page-title" or null
```

One import value covers the resource and all three of its methods. `Element` names the interface, and the methods are found on `Element.prototype`, which is where JS finds them too. Component names are kebab-case and JS names are camelCase, so `query-selector` is matched with `querySelector`.

Binding the resource to `Element` also influences how the component's own exports look. Its `find` takes an element, so what JS sees is:

```webidl
namespace {
  USVString? find(Element root, USVString selectors);
};
```

JS must pass a real element or else it gets a `TypeError`.

#### When the API evolves

`scroll-into-view` is interesting here, because `scrollIntoView` has evolved over time. It used to take a single boolean, but now it takes either a boolean or an options dictionary. The component above was written against the old version and still asks for a `bool`.

This is okay. When an argument is allowed to be one of several types, we try the component's value against each of them and use the first one that fits, and a boolean still fits.

Mismatched argument counts get a similar treatment. Extra arguments are dropped, and arguments the component doesn't pass behave as if a JS caller had left them out.

Arguments that don't actually match do fail, but they fail at the call rather than at load. If a component asks for `scroll-into-view: func(align-to-top: string)`, a string is neither a boolean nor an options dictionary, so that call traps. Instantiation still succeeds, `find` still works, and a component that never calls `scroll-into-view` never traps.

## The WebAssembly Namespace

Extend the imperative WebAssembly JS-API interfaces to also allow validation/compilation/instantiation of components in addition to modules.

```webidl
interface Component {
    constructor([AllowResizable] AllowSharedBufferSource bytes);
}

interface ComponentInstance {
    constructor(Component component, object args);
}

typedef (Component or Module) InstantiateSource;

[Exposed=*]
namespace WebAssembly {
    // Same as before, but now will detect if the bytes are a component or module and dispatch differently.
    boolean validate([AllowResizable] AllowSharedBufferSource bytes, optional WebAssemblyCompileOptions options = {});
    Promise<Module> compile([AllowResizable] AllowSharedBufferSource bytes, optional WebAssemblyCompileOptions options = {});
    Promise<WebAssemblyInstantiatedSource> instantiate(
        [AllowResizable] AllowSharedBufferSource bytes, optional object importObject, optional WebAssemblyCompileOptions options = {});

    // Now takes an InstantiateSource instead of just a Module.
    Promise<Instance> instantiate(
        InstantiateSource moduleObject, optional object importObject);
}
```

## WebAssembly ESM-Integration

TODO.

## Names

Component names are [`label`s](Explainer.md#import-and-export-names) and must be transformed when looking up what JS/Web interface they refer to.

TODO: Define `pascal case`(|name|)
TODO: Define `camel case`(|name|)

## Types and values

Components and WebIDL maintain separate type systems, so any value crossing the boundary needs a defined translation in both directions.

This section specifies that translation as four [abstract operations](https://tc39.es/ecma262/#sec-algorithm-conventions-abstract-operations):
  1. CanonicalWebIDLType - pick the WebIDL type that best represents a given component value type
  2. ToCanonicalWebIDLValue - infallibly convert from a component value to a canonical WebIDL value
  3. FromCanonicalWebIDLValue - infallibly convert from a canonical WebIDL value to a component value
  4. CoerceWebIDLValue - convert from one WebIDL type to another

### Resource types

A component resource type in the web embedding is a [WebIDL object type](https://webidl.spec.whatwg.org/#dfn-object-type). Resource defined in a component are given a WebIDL interface that represents them as WebIDL object types.

When a component imports a resource type, if a WebIDL [interface object](https://webidl.spec.whatwg.org/#dfn-interface-object) is given then the type of the interface it represents is used. Otherwise the generic `object` type is used instead.

The interface object is what identifies the interface, not its constructor. Most interfaces on the platform are not constructible, since `new Element()` throws and `Element` has no `constructor` operation at all, but `Element` is still the value a JS author reaches for to name the type, and it is still the object carrying the prototype that `[method]` imports are resolved from. Keying on constructibility instead would make nearly every DOM interface unimportable.

### CanonicalWebIDLType

`CanonicalWebIDLType(componentValType)` computes the canonical WebIDL type used to represent a component value type. Specialized component types are handled directly rather than being despecialized first, since many have natural WebIDL counterparts.

| Component type | Canonical WebIDL type |
|---|---|
| `bool` | `boolean` |
| `s8` / `u8` | `byte` / `octet` |
| `s16` / `u16` | `short` / `unsigned short` |
| `s32` / `u32` | `long` / `unsigned long` |
| `s64` / `u64` | `long long` / `unsigned long long` |
| `f32` / `f64` | `unrestricted float` / `unrestricted double` |
| `char` | `USVString` (length 1, asserted at conversion time) |
| `string` | `USVString` |
| `list<T>` | `sequence<CanonicalWebIDLType(T)>` |
| `list<T, N>` (fixed-length) | `sequence<CanonicalWebIDLType(T)>` (length-N invariant) |
| `record { f: T, ... }` | an anonymous `dictionary` type with required member `camel case(f)` of `CanonicalWebIDLType(T)` per field |
| `tuple<T0, T1, ...>` | `sequence<CanonicalWebIDLType(T0) or CanonicalWebIDLType(T1) or ...>` |
| `flags "L"+` | an anonymous `dictionary` type with optional `boolean` member `camel case(L)` per label, default `false` |
| `enum "L"+` | an anonymous `enumeration` with the same label set |
| `option<T>` where T is not option<_> | `CanonicalWebIDLType(T)?` |
| `option<T>` where T is option<_> | fallthrough to generic variant case below |
| `result<T?, E?>` | fallthrough to generic variant case below. This is also special cased elsewhere when used as return value of a function. |
| `variant (case "L" T?)+` | an anonymous `dictionary { KindEnum kind; (union of case payload types)? value; }` and an anonymous `enumeration KindEnum` with the same label set |
| `own<R>` / `borrow<R>` | the WebIDL type chosen for `R` by `read the component type import` |
| `future<T>` | `Promise<CanonicalWebIDLType(T)>` |
| `stream<T>` | `ReadableStream`? |
| `error-context` | TODO |

Notes:
 - `f32`/`f64` map to `unrestricted float`/`unrestricted double` rather than the restricted forms because the component model permits NaN values, while restricted WebIDL float types forbid NaN and infinity.
 - For `stream<T>`, the element type `T` is not encoded into the WebIDL type; element-level conversion occurs at read time.
 - `record` fields and `flags` labels are dictionary members, so they are `camel case`d. `enum` and `variant` case labels are enumeration values, which JS sees as strings, so they are used verbatim. See "Names". Two fields or labels of the same type that `camel case` to the same string are a link-time error, as elsewhere.

### ToCanonicalWebIDLValue

`ToCanonicalWebIDLValue(componentValue)` converts a component value to the canonical WebIDL value of type `CanonicalWebIDLType(componentValType)`. This algorithm is infallible.

Dispatch on the component value type:
- `bool` → IDL `boolean`
- Integer types → IDL number of the matching IDL integer type
- `f32` / `f64` → IDL `unrestricted float` / `unrestricted double`
- `char` → `USVString` of length 1 from the Unicode scalar value
- `string` → `USVString`
- `list<T>` → `sequence` with each element recursively converted by `ToCanonicalWebIDLValue`
- `record { f: T, ... }` → a `dictionary` value with each field recursively converted
- `tuple<T0, T1, ...>` → a `sequence` value with each field recursively converted
- `flags` → a `dictionary` value with each set label `true`, each unset label `false`
- `enum` → the `enumeration` value matching the label
- `option<T>` where T is not option<_> → `null` for `none`; else `ToCanonicalWebIDLValue` the inner value.
- `variant` → `{ kind: label, value: ToCanonicalWebIDLValue(payload) }` (omit `value` for cases which don't have a payload)
- `own<R>` / `borrow<R>` → the host interface object wrapping the handle; `own` resources use a `FinalizationRegistry` to invoke the destructor; `borrow` wrappers are invalidated after the call returns
- `future<T>` → an IDL `Promise` wrapping the future (TODO)
- `stream<T>` → an IDL `ReadableStream` wrapping the stream (TODO)
- `error-context` → TODO

### FromCanonicalWebIDLValue

`FromCanonicalWebIDLValue(webIDLValue, targetComponentType)` converts a canonical WebIDL value back to a component value of `targetComponentType`. The algorithm is driven by `targetComponentType` and assumes `webIDLValue` is of type `CanonicalWebIDLType(targetComponentType)`. This algorithm is infallible.

Each case is the inverse of the corresponding `ToCanonicalWebIDLValue` rule above.

### CoerceWebIDLValue

`CoerceWebIDLValue(fromWebIDLValue, toWebIDLType)` coerces a WebIDL value to a different WebIDL type. This algorithm is defined entirely over IDL values without invoking JavaScript semantics. It may throw `TypeError` (or `RangeError` under `[EnforceRange]`).

Coercions are restricted to within the same [WebIDL overload type class](https://webidl.spec.whatwg.org/#idl-overloading) — numeric types coerce only to other numeric types, string types only to other string types, and so on. This gives the following invariant: if `CoerceWebIDLValue(v, t1)` and `CoerceWebIDLValue(v, t2)` both succeed, then `t1` and `t2` fall in the same overload type class and therefore are not distinguishable. Coercing a value will not change which overload should be selected. This is in contrast to JS, which performs two-step overload selection first comparing the JS value kind to find a candidate and then performing more permissive coercions to try and call the candidate.

`fromWebIDLValue` may itself be `undefined` — e.g. a missing WebIDL operation argument with no declared default (see "create a component function for WebIDL operation" below). Each dispatch case below calls out its `undefined`-source behavior where it differs from throwing; where a rule mirrors a well-known ECMAScript abstract operation's behavior on `undefined` (`ToBoolean`, `ToNumber`, `ToString`), that's a description of the resulting value, not an invocation — the algorithm still never runs JavaScript semantics.

Dispatch on `toWebIDLType`:

- **`any`** — return `fromWebIDLValue` unchanged.
- **`undefined`** — accept only `undefined`; else throw `TypeError`.
- **`boolean`** —
    - source `boolean`: identity.
    - source `undefined`: `false` (matches `ToBoolean(undefined)`).
    - other sources: throw `TypeError`.
- **Integer types** (`byte`, `octet`, `short`, `unsigned short`, `long`, `unsigned long`, `long long`, `unsigned long long`) —
    - source any integer or float type: apply the IDL integer-conversion rules (modular reduction by default, clamping under `[Clamp]`, range check under `[EnforceRange]`) on the source's mathematical value.
    - source `undefined`: treated as `NaN` (matches `ToNumber(undefined)`), then the same integer-conversion rules apply to that `NaN` — so `[EnforceRange]` throws (non-finite), `[Clamp]` clamps to `0`, and the default rule modularly reduces to `0`.
    - source `bigint`: range-checked; valid only for `long long` and `unsigned long long`.
    - other sources: throw `TypeError`.
- **Float types** (`float`, `unrestricted float`, `double`, `unrestricted double`) —
    - source any integer or float type: convert by IEEE-754 round-to-nearest-even; restricted forms (`float`, `double`) throw `TypeError` for `NaN` or `±Infinity`.
    - source `undefined`: treated as `NaN` (matches `ToNumber(undefined)`); as above, restricted forms throw and unrestricted forms keep the `NaN`.
    - other sources: throw `TypeError`.
- **`bigint`** —
    - source `bigint`: identity.
    - source integer type: exact conversion.
    - source float: the value must be a finite integer; else throw `TypeError`.
    - other sources (including `undefined`, matching `BigInt(undefined)` throwing in JS): throw `TypeError`.
- **`DOMString`** —
    - source `DOMString`, `USVString`, or `ByteString`: identity (re-typed).
    - source `enumeration`: the label string.
    - source `undefined`: the literal string `"undefined"` (matches `ToString(undefined)`).
    - source `null` under `[LegacyNullToEmptyString]`: the empty string.
    - other sources: throw `TypeError`.
- **`USVString`** —
    - source `USVString`: identity.
    - source `DOMString` or `ByteString`: replace lone surrogates with U+FFFD; reinterpret otherwise.
    - source `enumeration`: the label string, then apply surrogate replacement.
    - source `undefined`: the literal string `"undefined"` (already valid USV; no replacement needed).
    - other sources: throw `TypeError`.
- **`ByteString`** —
    - source `ByteString`: identity.
    - source `DOMString` or `USVString`: each code unit must be `≤ U+00FF`; else throw `TypeError`.
    - source `enumeration`: the label string, then check the range.
    - source `undefined`: the literal string `"undefined"` (already valid ByteString).
    - other sources: throw `TypeError`.
- **`object`** — accept any non-primitive IDL value (interface, dictionary, sequence, record, callback, Promise); else throw `TypeError` (including for `undefined`).
- **`symbol`** — accept only `symbol`; else throw `TypeError`.
- **Interface `I`** — accept iff the source is an interface value whose type is `I` or a derived interface of `I`; else throw `TypeError`.
- **Callback function** — accept iff the source is a callback; else throw `TypeError`.
- **`dictionary D`** — accept iff the source is a dictionary value (or a record whose entry set covers all required members of `D`). For each declared member `m: T` of `D`: retrieve `m` from the source and recurse with `CoerceWebIDLValue(srcM, T)`. Missing required member: throw `TypeError`. Extra members in the source are ignored. TODO: per real WebIDL, an `undefined` source should build an all-defaults dictionary instead of throwing, once dictionary coercion itself is specified in more detail.
- **Enumeration `E`** — accept iff the source is a string value (any string type, or another enumeration whose label is in `E`'s label set); else throw `TypeError` (an `undefined` source is therefore rejected unless a label is literally `"undefined"`).
- **`sequence<T>`** — accept iff the source is a sequence (or frozen/observable array). Convert each element via `CoerceWebIDLValue(elem, T)`.
- **`record<K, V>`** — accept iff the source is a `record<k, v>. Convert each key via `CoerceWebIDLValue(k, K) and value via `CoerceWebIDLValue(v, V)`.
- **`T?` (nullable)** — if the source is `null` or `undefined`, return `null`; else `CoerceWebIDLValue(source, T)`. (A deliberate simplification: an `undefined` source could instead recurse into `T`'s own `undefined`-handling, but a missing nullable-typed value is simpler to just treat as `null` outright.)
- **Union types** — try each member type in declaration order; return the result of the first `CoerceWebIDLValue` call that does not throw. If all throw, throw `TypeError`. (An `undefined` source therefore succeeds against whichever member type accepts it, e.g. the first numeric or string member in declaration order.)
- **Buffer source types** — identity if the source is the same buffer-source kind; else throw `TypeError`. `[AllowShared]` and `[AllowResizable]` gate acceptance.
- **`FrozenArray<T>`** / **`ObservableArray<T>`** — as `sequence<T>`, but produce a frozen or observable array.
- **`Promise<T>`** — TODO.
- **`ReadableStream`** — TODO.

Notes:
- `[Clamp]` and `[EnforceRange]` are properties of the target parameter or member site. They parameterize the integer-conversion rules above.
- This algorithm does not invoke any JavaScript abstract operation. All source values are fully-typed IDL values (including `undefined`, which is itself a valid IDL value, not a JS one).

## Validation/Compilation

Validation and compilation of components just defer to the underlying component embedding interface. This explainer adds nothing to it.

## Instantiation

Instantiating a component is a two step process:
1. `Read the imports object` to translate from web/js values to component values
1. `Create the exports object` to translate from component values to web/js values

This is the core of the web embedding and where most of the logic lives.

### Read the imports object

The top-level `read the imports` algorithm walks the component's imports and resolves each to a JS value via property lookups on the |importsObject|, mirroring the Core JS-API's algorithm of the same name. The resolved JS values are then handed to the per-kind algorithms (`read the component function import`, `read the component type import`, `read the component value import`) to produce the component definitions used during instantiation.

While walking, the algorithm recognizes the common pattern of a resource type import accompanied by `[constructor]`, `[static]`, and `[method]` function imports tied to it. A resource type import is read first and should be given a WebIDL interface object (see "Resource Types"). The tagged function imports then read from that interface object and its prototype directly. This allows the common case of importing an interface to be satisfied by just passing the interface object.

Every name looked up on a JS object is `camel case`d first (see "Names").

To `read the imports` given |component| and |importsObject|:
1. If |component| has no imports:
    1. Return an empty list.
1. If `Type`(|importsObject|) is not Object:
    1. Throw a `TypeError`.
1. If two names within any of the following groups `camel case` to the same string, throw a `TypeError`:
    1. The names of the imports that are resolved on |importsObject| (that is, every import except a `[constructor]`, `[method]` or `[static]` function import whose resource type is itself imported).
    1. For each resource type import R, the `[method]` names tied to R.
    1. For each resource type import R, the `[static]` names tied to R.
1. Let |resourceInterfaceObjects| be a new empty map keyed by resource type.
1. Let |imports| be a new empty list.

1. For each |import| of |component|.Imports, in declaration order:
    1. If |import| is a type import:
        1. TODO: handle non-resource type imports.
        1. Let |importValue| be ? `GetV`(|importsObject|, `camel case`(|import|.Name)).
        1. Set |resourceInterfaceObjects|[|import|.ResourceType] to |importValue|.
    1. Else if |import| is a function import:
        1. If |import| is tagged `[constructor]<R>`:
            1. Let R be the resource whose `own<R>` type is the function's return type.
        1. Else if |import| is tagged `[method]`:
            1. Let R be the resource whose `borrow<R>` type is the function's first parameter (the `self` position).
        1. Else if |import| is tagged `[static]`:
            1. Let R be the resource named in the `[static]<R>.<name>` tag.
        1. Else:
            1. Let R be undefined.

        1. If R is defined and |resourceInterfaceObjects|[R] exists:
            1. Let |interfaceObject| be |resourceInterfaceObjects|[R].
            1. If tagged `[constructor]`:
                1. Let |importValue| be |interfaceObject|.
            1. Else if tagged `[static]`:
                1. Let |importValue| be ? `GetV`(|interfaceObject|, `camel case`(|import|.StaticName)).
            1. Else if tagged `[method]`:
                1. Let |prototype| be ? `GetV`(|interfaceObject|, "prototype").
                1. If `Type`(|prototype|) is not Object, throw a `TypeError`.
                1. Let |importValue| be ? `GetV`(|prototype|, `camel case`(|import|.MethodName)).
        1. Else:
            1. Let |importValue| be ? `GetV`(|importsObject|, `camel case`(|import|.Name)).
    1. Else:
        1. Let |importValue| be ? `GetV`(|importsObject|, `camel case`(|import|.Name)).

    1. Let |resolved| be `read a component import` given |import| and |importValue|.
    1. Append |resolved| to |imports|.
1. Return |imports|.

To `read a component import` given |import| and |importValue|:
1. Match |import|.Kind:
    1. **Instance**: TODO.
    1. **Function**: return `read the component function import` given |import|.Type and |importValue|.
    1. **Type**: return `read the component type import` given |import|.TypeBound and |importValue|.
    1. **Value**: return `read the component value import` given |import|.Type and |importValue|.

To `read the component function import` given |componentFuncType| and |importValue|:
1. If |importValue| is not callable:
    1. Throw TypeError.
1. If |importValue| is an exported component function:
    1. Return the wrapped component function.
1. If |importValue| is a WebIDL interface object:
    1. If the interface it represents has a constructor operation:
        1. Let |importValue| be that constructor operation.
    1. Else:
        1. Let |importValue| be an operation that throws a `TypeError` when invoked, matching what calling the interface object does.
1. Else if |importValue| is not a WebIDL operation:
    1. Let |importValue| = `create a WebIDL operation for a JS callable`.
1. Return `create a component function for WebIDL operation` for |importValue|

To `read the component type import` given |componentTypeBound| and |importValue|:
1. If |componentTypeBound| is not `(sub resource)`:
    1. TODO.
1. If |importValue| is not a WebIDL interface object:
    1. Return WebIDL `object`.
1. Return the interface type that |importValue| represents.

To `read the component value import` given |componentValType| and |importValue|:
1. Let |canonicalType| be `CanonicalWebIDLType`(|componentValType|).
1. Let |canonicalValue| be the result of converting |importValue| to IDL type |canonicalType| using WebIDL's [convert an ECMAScript value to an IDL value](https://webidl.spec.whatwg.org/#js-type-mapping) algorithm. If that algorithm throws, propagate the exception.
1. Return `FromCanonicalWebIDLValue`(|canonicalValue|, |componentValType|).

Notes:
    - Unlike function imports, value import conversion failures surface at instantiation, not at first use.

To `create a WebIDL operation for a JS callable` given |callable|:
1. TODO: sketch this out more.
1. Return an operation with a `any (any...)` WebIDL signature that immediately invokes |callable|.

To `create a component function for WebIDL operation` given |operation| and |componentFuncType|:
1. Let |paramComponentTypes| be |componentFuncType|.Params.
1. Let |returnComponentType| be |componentFuncType|.Return.
1. If |returnComponentType| is `result<T, E>`:
    1. Let |okComponentType| = T.
    1. Let |errorComponentType| = E.
    1. Let |throwing| = true.
1. Else:
    1. Let |okComponentType| = |returnComponentType|.
    1. Let |throwing| = false.
1. If |operation| is an overload set:
    1. Compute |canonicalParamType_i| = `CanonicalWebIDLType`(|paramComponentTypes|[i]) for each i.
    1. Look for the unique overload whose declared parameter type at the distinguishing argument index has the same WebIDL overload type class as |canonicalParamType_i| at that index, considering only positions present in both.
    1. If an overload was found:
        1. Let |selectedOperation| be that overload.
    1. Else:
        1. let |selectedOperation| be a placeholder that traps when invoked.
1. Else:
    1. Let |selectedOperation| = |operation|.
1. Let |result| = Construct a component host function with type |componentFuncType| whose body, given component args [|v_0|, ..., |v_{N_c - 1}|]:
    1. If |selectedOperation| is the trap placeholder, trap.
    1. Let |declaredParamTypes| = |selectedOperation|.Params
    1. Let |N_o| = |declaredParamTypes|.length.
    1. If |selectedOperation|'s final declared parameter is variadic:
        1. Let |fixedCount| = |N_o| - 1.
        1. Let |variadicElemType| be that parameter's element type/
    1. Else:
        1. Let |fixedCount| = |N_o|.
        1. Let |variadicElemType| be undefined.
    1. For each i in [0, |fixedCount|):
        1. If i < |N_c|:
            1. Let |args|[i] = `CoerceWebIDLValue`(`ToCanonicalWebIDLValue`(|v_i|), |declaredParamTypes|[i]). If this throws, trap.
        1. Else if the i-th declared parameter has a default value expression (WebIDL's `optional T x = defaultExpr`):
            1. Let |args|[i] be that default value, already of type |declaredParamTypes|[i].
        1. Else:
            1. Let |args|[i] = `CoerceWebIDLValue`(`undefined`, |declaredParamTypes|[i]). If this throws, trap.
    1. Let |variadicArgs| be a fresh empty IDL sequence with element type |variadicElemType|.
    1. If |variadicElemType| is defined:
        1. For each j in [|fixedCount|, |N_c|):
            1. Append `CoerceWebIDLValue`(`ToCanonicalWebIDLValue`(|v_j|), |variadicElemType|) to |variadicArgs|. If this throws, trap.
        1. Pass |variadicArgs| as the variadic invocation arguments to |selectedOperation|.
    1. Else:
        1. Component args |v_{|fixedCount|}|, ..., |v_{N_c - 1}| are ignored when |N_c| > |fixedCount|.
    1. Invoke |selectedOperation|(|args|).
        1. If the invocation throws |error|:
            1. If the function is marked throwing:
                1. Let |canonicalError| = `CoerceWebIDLValue`(|error|, `CanonicalWebIDLType`(|errorComponentType|)). If this throws, trap.
                1. Return `result.error(`FromCanonicalWebIDLValue`(|canonicalError|, |errorComponentType|))`.
            1. Else: trap.
        1. Else: let |webIDLResult| = the returned WebIDL value.
    1. Let |canonicalReturn| = `CoerceWebIDLValue`(|webIDLResult|, `CanonicalWebIDLType`(|okComponentType|)). If this throws, trap.
    1. Let |componentResult| = `FromCanonicalWebIDLValue`(|canonicalReturn|, |okComponentType|).
    1. If |throwing|:
        1. Return `result.ok(|componentResult|)`.
    1. Else:
        1. Return |componentResult|.
1. Return |result|.

Notes:
- Construction always succeeds. Type and arity mismatches surface as runtime traps when the function is invoked; not at instantiation time.
- Pre-resolved overload selection runs once at instantiation. The component import has a fixed function type that is used to select the closest overload.
- Param-length mismatches are JS-permissive: a missing arg uses its declared default value if the parameter has one, else falls back to `undefined` (subject to per-param `CoerceWebIDLValue` rules, including its `undefined`-source cases above); extras are dropped.
- Variadic operations are spread one-per-element from the component caller's trailing args.
- TODO: should we special case a list<T> passed as the final argument to a variadic overload?
- TODO: can we get away with only ever having static overload selection?

### Create the exports object

The `create the exports object` algorithm analyzes the component's exports, builds a set of WebIDL fragments (interfaces, namespace members, dictionaries, enumerations) describing them, and then defers to WebIDL's existing [JS binding](https://webidl.spec.whatwg.org/#javascript-binding) to materialize JS values for those fragments. The returned object is a fresh JS object whose properties are the materialized exports.

Tagged function exports are mapped to interface members just as in `read the imports`:
- `[constructor]<R>`: The operation becomes the interface `R`'s constructor. By strong-uniqueness, there can only be one for an interface, and we don't have to worry about overloading a constructor.
- `[method]<R>.<name>`: The operation becomes a regular interface member named `camel case`(|name|) on `R`.
- `[static]<R>.<name>`: The operation becomes a static interface member named `camel case`(|name|) on `R`.

Resource types become interfaces named `pascal case`(|name|), and everything else becomes a member named `camel case`(|name|); see "Names".

To `create the exports object` given a |componentInstance|:
1. Let |fragments| be a new empty set of WebIDL fragments.
1. Let |resourceInterfaces| be a new empty map keyed by component resource type.
1. Let |namespace| be an fresh anonymous WebIDL `namespace` fragment that will host plain function and value exports. Add it to |fragments|.
1. For each |export| of |componentInstance|.|component|.Exports, in declaration order:
    1. Match |export|.Kind:
        1. **Type (resource)**:
            1. If the resource is re-exported from imports:
                1. Let |interface| be the WebIDL interface that was selected for that resource by `read the component type import` at instantiation.
            1. Else (resource defined in the component):
                1. Let |interface| be a fresh WebIDL `interface` fragment named `pascal case`(|export|.Name).
                1. Add a `[LegacyNamespace=|namespace|]` extended attribute to |interface|.
                1. Add |interface| to |fragments|.
                1. If no `[constructor]<R>` export targets this resource:
                    1. Give |interface| a constructor operation that throws when called (matching WebIDL's "no [Constructor]" semantics).
            1. Set |resourceInterfaces|[|export|.ResourceType] to |interface|.
        1. **Function**:
            1. Let |operation| be `create an operation from a component function` given |export|.Func.
            1. If |export| is tagged `[constructor]<R>`:
                1. Let |interface| be |resourceInterfaces|[R].
                1. Assert |interface| has no contructor operation yet.
                1. Add |operation| to |interface| as its constructor operation.
            1. Else if |export| is tagged `[method]<R>.<name>`:
                1. Let |interface| be |resourceInterfaces|[R].
                1. Add |operation| to |interface| as a regular interface member named `camel case`(|name|).
            1. Else if |export| is tagged `[static]<R>.<name>`:
                1. Let |interface| be |resourceInterfaces|[R].
                1. Add |operation| to |interface| as a static interface member named `camel case`(|name|).
            1. Else:
                1. Add |operation| to |namespace| as a regular member named `camel case`(|export|.Name).
        1. **Value**:
            1. Let |canonicalType| be `CanonicalWebIDLType`(|export|.Type) and |canonicalValue| be `ToCanonicalWebIDLValue`(|export|.Value).
            1. Add a constant of type |canonicalType| with value |canonicalValue| to |namespace|, named `camel case`(|export|.Name).
        1. **Instance**:
            1. TODO: Can we just recurse here?
    1. If |export| added a name to a fragment that already contained that name, throw a `TypeError`.
1. Let |exportsObject| be the result of [creating a namespace object](https://webidl.spec.whatwg.org/#namespace-object) for |namespace|.
1. Return |exportsObject|.

Notes:
- Re-exported imported resources reuse the same WebIDL interface they were bound to at instantiation, so JS callers see the same identity on both sides of the boundary.
- Component-defined resources without a `[constructor]<R>` export get an interface whose constructor throws.
- Component-defined resources generate a WebIDL interface without any inheritance.
- The WebIDL JS binding needs to be modified to handle an anonymous namespace that is not exposed on a global. This seems like a relatively simple modification to make.

To `create an operation from a component function` given |componentFunc|:
1. Let |componentFuncType| be |componentFunc|.Type.
1. Let |componentParamTypes| be |componentFuncType|.Params.
1. Let |componentResultType| be |componentFuncType|.Result.
1. If |componentResultType| is `result<T, E>` (top-level):
    1. Let |okComponentType| = T.
    1. Let |errorComponentType| = E.
    1. Let |throwing| = true.
1. Else: let
    1. Let |okComponentType| = |componentResultType|;
    1. Let |throwing| = false.
1. Let |webIDLParamTypes|[i] be `CanonicalWebIDLType`(|componentParamTypes|[i]) for each i
1. Let |webIDLResultType| be `CanonicalWebIDLType`(|okComponentType|).
1. Construct a WebIDL operation with parameter types |webIDLParamTypes| and return type |webIDLResultType|, whose body, given |webIDLParamValues|:
    1. For each i in |webIDLParamValues|:
        1. Let |componentParamValues|[i] = `FromCanonicalWebIDLValue`(|webIDLParamValues[i]|, |componentParamTypes|[i]).
    1. Let |componentResult| = Invoke |componentFunc| with [|componentParamValues|[0], ..., |componentParamValues|[n-1]].
        1. TODO: What if the call traps?
        1. If |throwing| and |componentResult| is `error(`|e|`)`:
            1. Let |exception| be `create a component exception` for `|e|`
            1. Throw |exception|.
        1. Else if |throwing| and the result is `result.ok(`|v|`)`:
            1. Let |componentResult| be |v|.
        1. Else:
            1. Let |componentResult| be the returned component value.
    1. Return `ToCanonicalWebIDLValue`(|componentResult|).
1. Return the operation.

To `create a component exception` for component value `|error|`:
    1. TODO: Create an instance of `ComponentException`, a derived interface of `DOMException`.

## Open questions

1. How can you dynamically pass different branches of a WebIDL union?
  - The current rules work for statically passing different branches, but not dynamically.
  - Passing a variant doesn't work. It's canonical WebIDL value is different from a union.
1. How to specify finalization and destructors?
1. How does own/borrow interact with WebIDL platform objects?
1. How do we support WebIDL callback function types?
1. How do we support downcasting/upcasting of WebIDL interfaces?
1. How to import/export attribute getters/setters?
1. How to export a component as an interface that is derived from another interface?
