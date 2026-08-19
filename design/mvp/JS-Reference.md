# WebAssembly Components JS-API Reference

This is the in-depth reference for the WebAssembly Component JS-API. See here for the higher-level [explainer](./JS-Explainer.md).

**This is a draft and is not complete. Major details are unresolved, and there are bugs. See "Open Questions" at the end for a sampling of them.**

## The WebAssembly Namespace

Extend the imperative WebAssembly JS-API interfaces to also allow validation/compilation/instantiation of components in addition to modules.

```webidl
interface Component {
    constructor([AllowResizable] AllowSharedBufferSource bytes);
}

interface ComponentInstance {
    constructor(Component component, optional object importsObject);
    readonly attribute object exports;
}

typedef (Component or Module) InstantiateSource;

[Exposed=*]
namespace WebAssembly {
    // Same as before, but now will detect if the bytes are a component or module and dispatch differently.
    boolean validate([AllowResizable] AllowSharedBufferSource bytes, optional WebAssemblyCompileOptions options = {});
    Promise<Module> compile([AllowResizable] AllowSharedBufferSource bytes, optional WebAssemblyCompileOptions options = {});
    Promise<WebAssemblyInstantiatedSource> instantiate(
        [AllowResizable] AllowSharedBufferSource bytes, optional object importObject, optional WebAssemblyCompileOptions options = {});

    // Now takes an InstantiateSource instead of just a Module, and returns a
    // ComponentInstance for a Component.
    Promise<(Instance or ComponentInstance)> instantiate(
        InstantiateSource moduleObject, optional object importObject);
}
```

We also add an error type for components that return `result<_, E>` to JS:

```webidl
[Exposed=*]
interface ComponentError : Error {
    constructor(optional DOMString message = "", optional any payload);
    readonly attribute any payload;
};
```

`payload` is the converted `E` value. See [Create the exports object](#create-the-exports-object).

## Validation/Compilation

Validation and compilation of components just defer to the underlying component embedding interface. This explainer adds nothing to it.

## Names

Component import/export `plainname's` contain [`label`s](Explainer.md#import-and-export-definitions) that must be transformed into an identifier for use with JS and the web.
Component import/export `interfacename's` (such as `wasi:http/handler@1.0.0`) have no JS name and are currently rejected with a `TypeError`.

We define a `PascalCase(label)` and `CamelCase(label)` below which are used throughout this spec.

| `label` | `PascalCase` | `CamelCase` |
|---|---|---|
| `element` | `Element` | `element` |
| `query-selector` | `QuerySelector` | `querySelector` |
| `inner-HTML` | `InnerHTML` | `innerHTML` |
| `XML-http-request` | `XMLHttpRequest` | `xmlHttpRequest` |
| `URL` | `URL` | `url` |
| `a1-2-3` | `A123` | `a123` |

`LabelOf`(|name|), where |name| is a `plainname`, returns the label that names the definition in JS:
1. If |name| is `[method]r.n` or `[static]r.n`, return `n`.
1. If |name| is `[constructor]r`, return `r`.
1. Return |name|.

`Fragments`(|label|):
1. Return the List of Strings produced by splitting |label| on occurrences of U+002D (-). The hyphens themselves are discarded.

`Capitalize`(|fragment|):
1. If |fragment| is an `acronym`, return |fragment|.
1. Return |fragment| with its first character uppercased.

`PascalCase`(|label|):
1. Let |fragments| be `Fragments`(|label|).
1. Let |result| be the empty String.
1. For each |fragment| of |fragments|:
    1. Set |result| to the string-concatenation of |result| and `Capitalize`(|fragment|).
1. Return |result|.

`CamelCase`(|label|):
1. Let |fragments| be `Fragments`(|label|).
1. Let |result| be |fragments|[0] with every character lowercased.
1. For each |fragment| of |fragments| after the first:
    1. Set |result| to the string-concatenation of |result| and `Capitalize`(|fragment|).
1. Return |result|.

The JS name of an import or export declaration is then:

`JSName`(|decl|):
1. If |decl|.Name is an `interfacename`, throw a `TypeError`.
1. If |decl| is a type declaration, return `PascalCase`(`LabelOf`(|decl|.Name)).
1. Return `CamelCase`(`LabelOf`(|decl|.Name)).

TODO: `a-b` and `AB` are [strongly-unique](Explainer.md#name-uniqueness) but both `PascalCase` to the identical `AB`. This can lead to collisions in exports. We don't handle this yet.

## Types and values

Components and JS maintain separate type/value systems, so any value crossing the boundary needs a defined translation in both directions.

This section specifies that translation as two abstract operations:
  1. `ToJSValue` - convert a component value to a JS value. Infallible.
  2. `ToComponentValue` - convert a JS value to a component value of a given type. Fallible.

For every component value type `t` and every component value `v` of type `t`, `ToComponentValue(ToJSValue(v, t), t)` is `v`. The one exception being a `map` with duplicate keys (see [`ToJSValueMap`](#tojsvalue)). 

The abstract operations are carefully designed so that JS scripts cannot intercept round-tripping a component value through JS, or converting a component value to/from a WebIDL value. This allows JS engines to easily fuse conversions and skip creation of intermediate JS values. This is explained in more detail [later](#fusing-component-value-conversions).

### ToJSValue

`ToJSValue(componentValue, componentValType)` converts a component value to a JS value. This algorithm is infallible.

Dispatch on `componentValType`:

- `bool` → Boolean.
- Integer types other than `s64`/`u64` → Number, an exact integer.
- `s64` / `u64` → BigInt.
- `f32` / `f64` → Number, including NaN and infinities.
- `char` → String containing exactly the one Unicode scalar value.
- `string` → String [(well formed)](https://tc39.es/ecma262/#sec-isstringwellformedunicode).
- `list<u8>` → Uint8Array.
- `list<T>` → `ToJSValueList`(the elements, T).
- `list<T, N>` → as `list<T>`; `length` is `N`.
- `tuple<T0, T1, ...>` → as `list`, with element `i` converted as `T_i`.
- `record { f: T, ... }` → `ToJSValueRecord`(|componentValue|, the fields).
- `flags "L"+` → `ToJSValueFlags`(|componentValue|, the labels).
- `enum "L"+` → String, the label verbatim.
- `option<T>` where T is not `option<_>` → `null` for `none`, else `ToJSValue`(the payload, T).
- `variant`, and `option<option<_>>`, and `result` outside return position → `ToJSValueVariant`(|componentValue|, the cases). In return position a `result` is unwrapped instead, into a return value or a thrown `ComponentError` (see [Read the imports](#read-the-imports-object) and [Create the exports object](#create-the-exports-object)).
- `map<K, V>` → `ToJSValueMap`(|componentValue|, K, V).
- `own<R>` / `borrow<R>` → the JS value for an imported `R`, an instance of `R`'s [resource class](#guest-resource-classes) for a component-defined `R`. See [Resource types](#resource-types).
- `future<T>` → a Promise (TODO).
- `stream<T>` → a `ReadableStream` (TODO).
- `error-context` → TODO.

`ToJSValueList(values, T)` returns a *component list object*:
1. Let |n| be the number of |values|.
1. Let |array| be `ArrayCreate`(|n|).
1. For each i in [0, |n|): perform `CreateDataPropertyOrThrow`(|array|, `ToString`(i), `ToJSValue`(|values|[i], T)).
1. Perform `DefinePropertyOrThrow`(|array|, `@@iterator`, PropertyDescriptor { [[Value]]: `%ComponentListValues%`, [[Writable]]: **false**, [[Enumerable]]: **false**, [[Configurable]]: **false** }).
1. Return |array|.

A *component list object* is mostly an ordinary Array object, with the exception of that non-configurable own `@@iterator`. This is important [for fusing value conversions](#fusing-component-value-conversions). `%ComponentListValues%` is a new built-in function that behaves like `%Array.prototype.values%` except that the iterator object it returns:
 - has a null prototype,
 - has an own, non-writable, non-configurable `next` method,
 - and returns, from `next`, a fresh null-prototype object with own `value` and `done` data properties.

`ToJSValueRecord(value, fields)`:
1. Let |object| be `OrdinaryObjectCreate`(**null**).
1. For each field `f: T` of |fields|, in declaration order, perform `CreateDataPropertyOrThrow`(|object|, `CamelCase`(f), `ToJSValue`(|value|'s `f`, T)).
1. Return |object|.

`ToJSValueFlags(value, labels)`:
1. Let |object| be `OrdinaryObjectCreate`(**null**).
1. For each label `L` of |labels|, perform `CreateDataPropertyOrThrow`(|object|, `CamelCase`(L), |value|'s `L` bit as a Boolean).
1. Return |object|.

`ToJSValueVariant(value, cases)`:
1. Let |object| be `OrdinaryObjectCreate`(**null**).
1. Perform `CreateDataPropertyOrThrow`(|object|, "kind", |value|'s case label as a String).
1. If that case has a payload of type `T`, perform `CreateDataPropertyOrThrow`(|object|, "value", `ToJSValue`(the payload, T)).
1. Return |object|.

`ToJSValueMap(value, K, V)`:
1. Let |map| be a new ordinary `Map` object with an empty [[MapData]].
1. For each pair (k, v) of |value|, in order:
    1. Let |key| be `ToJSValue`(k, K) and |mapValue| be `ToJSValue`(v, V).
    1. If [[MapData]] has an entry whose key is `SameValueZero` to |key|, set that entry's value to |mapValue|.
    1. Else, append an entry (|key|, |mapValue|) to [[MapData]].
1. Return |map|.

A `map<K, V>` is a [specialization](Explainer.md#type-definitions) of `list<tuple<K, V>>` where the last pair for a key defines its value. So `[(a,1),(a,2)]` round-trips from a component value to JS and back as `[(a,2)]`. This is the one exception to the round-tripping rules we have.

### ToComponentValue

`ToComponentValue(jsValue, targetComponentType)` converts a JS value to a component value. It may throw if the JS value doesn't match the component value type.

Dispatch on `targetComponentType`:

- `bool` → `ToBoolean`(|jsValue|).
- Integer types → `ToComponentValueInteger`(|jsValue|, the type).
- `f32` / `f64` → `ToNumber`(|jsValue|); for `f32`, round to the nearest f32 value (ties to even). `NaN` and infinities are accepted, as with `unrestricted float`/`unrestricted double`.
- `char` → `ToString`(|jsValue|); it must consist of exactly one Unicode scalar value, else throw a `TypeError`. A lone surrogate is not a scalar value and is therefore a `TypeError`.
- `string` → `ToString`(|jsValue|), then replace each unpaired surrogate with U+FFFD, matching WebIDL `USVString`.
- `list<u8>` → `new Uint8Array(ToComponentValueList(|jsValue|, u8))`
- `list<T>` → `ToComponentValueList`(|jsValue|, T).
- `list<T, N>` → as `list<T>`, then the length must be exactly `N`, else throw a `TypeError`.
- `tuple<T0, ...>` → as `list`, then the length must be exactly the arity, and element `i` converts to `T_i`.
- `record { f: T, ... }` → `ToComponentValueRecord`(|jsValue|, the fields).
- `flags "L"+` → `ToComponentValueFlags`(|jsValue|, the labels).
- `enum` → `ToString`(|jsValue|) must be one of the labels, else throw a `TypeError`.
- `option<T>` where T is not `option<_>` → `null` and **undefined** both give `none`; anything else gives `some(ToComponentValue(jsValue, T))`. This matches how WebIDL treats a nullable type.
- `variant`, and `option<option<_>>`, and `result` outside return position → `ToComponentValueVariant`(|jsValue|, the cases).
- `map<K, V>` → `ToComponentValueMap`(|jsValue|, K, V).
- `own<R>` / `borrow<R>` → a [host resource value](#host-resource-types-and-values) for an imported `R`, the rep held by the given instance of `R`'s [resource class](#guest-resource-classes) for a component-defined `R`. See [Resource types](#resource-types).
- `future<T>` → TODO.
- `stream<T>` → TODO.
- `error-context` → TODO.

`ToComponentValueInteger(jsValue, t)`:
1. If |t| is `s64` or `u64` and `Type`(|jsValue|) is BigInt, let |n| be |jsValue|'s value.
1. Else, let |n| be ? `ToNumber`(|jsValue|) put through WebIDL's [integer conversion](https://webidl.spec.whatwg.org/#abstract-opdef-converttoint) **as if `[EnforceRange]` were present**: `NaN` and infinities throw a `TypeError`, anything else truncates toward zero.
1. If |n| is outside |t|'s range, throw a `TypeError`.
1. Return |n|.

`ToComponentValueList(jsValue, T)`:
1. If |jsValue| is not an Object, throw a `TypeError`.
1. If ? `IsArray`(|jsValue|) is **true** and |jsValue| is not a Proxy exotic object:
    1. Let |len| be ? `LengthOfArrayLike`(|jsValue|).
    1. For each i in [0, |len|): let |e_i| be ? `Get`(|jsValue|, `ToString`(i)), and append `ToComponentValue`(|e_i|, T).
1. Else:
    1. Let |method| be ? `GetMethod`(|jsValue|, `@@iterator`). If |method| is **undefined**, throw a `TypeError`.
    1. Iterate as WebIDL's sequence conversion does, converting each value with `ToComponentValue`(_, T).

The `Array` case does not check `@@iterator`, so a patched `Array.prototype[@@iterator]` does not change what a component sees when handed an Array. This is important for [fusing value conversions](#fusing-component-value-conversions).

`ToComponentValueRecord(jsValue, fields)`:
1. If |jsValue| is not an Object, throw a `TypeError`.
1. For each field `f: T` of |fields|, in declaration order:
    1. Let |m| be ? `GetOwnProperty`(|jsValue|, `CamelCase`(f)).
    1. If |m| is **undefined** and `T` is not `option<_>`, throw a `TypeError`.
    1. The field value is `ToComponentValue`(|m|, T).

Extra properties are ignored.

`ToComponentValueFlags(jsValue, labels)`:
1. If |jsValue| is not an Object, throw a `TypeError`.
1. For each label `L` of |labels|, the bit is `ToBoolean`(? `GetOwnProperty`(|jsValue|, `CamelCase`(L))).

An absent property is therefore `false`, matching a `boolean` dictionary member defaulted to `false`.

`ToComponentValueVariant(jsValue, cases)`:
1. If |jsValue| is not an Object, throw a `TypeError`.
1. Let |kind| be `ToString`(? `GetOwnProperty`(|jsValue|, "kind")). It must be the label of one of |cases|, else throw a `TypeError`.
1. If that case has a payload type `T`, its payload is `ToComponentValue`(? `GetOwnProperty`(|jsValue|, "value"), T). Otherwise `value` is ignored.
1. Return that case.

`ToComponentValueMap(jsValue, K, V)`:
1. If |jsValue| is not an Object, throw a `TypeError`.
1. If |jsValue| has a [[MapData]] internal slot:
    1. Return one pair per entry of [[MapData]], in insertion order, converting each key with `ToComponentValue`(_, K) and each value with `ToComponentValue`(_, V).
1. If ? `GetMethod`(|jsValue|, `@@iterator`) is not **undefined**:
    1. Return `ToComponentValueList`(|jsValue|, `tuple<K, V>`).
1. If `K` is not `string`, throw a `TypeError`.
1. Return one pair per own enumerable string-keyed property of |jsValue|, in property order, converting each value with `ToComponentValue`(_, V).

The `Map` case does not check `@@iterator`, so a patched `Map.prototype[@@iterator]` does not change what a component sees when handed a Map. This is important for [fusing value conversions](#fusing-component-value-conversions).
If a `Map` or `Iterable` is not provided, then we fallback to converting an object following `record<DOMString, V>` rules for compat with WebIDL.

## Resource types

A component resource type can be defined in a component (i.e. a guest resource), or else as an imported abstract type (i.e. a host resource).

The component JS-API defines:
  1. A protocol for defining host resource types in JS.
  2. A spec representation of host resource types and values.
  3. A JS representation of guest resource types and values.

### Embedder extensions

We sketch two things here that should be formalized more fully in the [embedding interface](CanonicalABI.md#embedding).

To `create a host resource type` given a host function |destructor|:
1. Return a fresh component resource type that whose representation is host-defined and whose destructor is |destructor|.

To `drop a host owned resource` given a resource type |resourceType| and a rep |rep| owned by the host:
1. Perform the effect of [`canon resource.drop`](CanonicalABI.md#canon-resourcedrop) on an owning handle holding |resourceType| and |rep|, invoking |resourceType|'s destructor. There is no handle table entry to remove, because the host was holding the rep.
1. If that traps, throw a `WebAssembly.RuntimeError`.

### Host resource types (i.e. imported)

#### The host resource type protocol

We add a new well-known symbol, `@@isWasmResourceOf`, whose value is a predicate over JS values:

```js
Constructor[Symbol.isWasmResourceOf] = (v) => /* return true iff v is an instance of resource type */;
```

A resource type import will check for this symbol during instantiation and snapshot it. The type check will be invoked each time a JS value needs to be converted to a resource value.

If `@@isWasmResourceOf` is not found, then one is synthesized that performs an `instanceof` check.

WebIDL is extended to define this property on every [interface object](https://webidl.spec.whatwg.org/#dfn-interface-object), returning **true** if and only if its argument is a platform object that [implements](https://webidl.spec.whatwg.org/#implements) that interface.

#### Host resource types and values

A *host resource type* is what the JS-API creates to satisfy a resource type import. It is a Record with the following fields:

| Field | Value |
|---|---|
| [[ComponentResourceType]] | the component resource type produced by `create a host resource type` |
| [[ImportValue]] | the JS object that satisfied the import |
| [[IsWasmResourceOf]] | the type check snapshotted from that object |

A *host resource value* is the `rep` of a host resource type. It too is a Record:

| Field | Value |
|---|---|
| [[Type]] | the host resource type this is a rep of |
| [[JSValue]] | the JS value, held strongly |

A host resource value just holds a strong reference to the underlying value. No user-level destructors are run when it is dropped.

To `read the type import` given |componentTypeBound| and |importValue|:
1. If |componentTypeBound| is not `(sub resource)`:
    1. Throw a `TypeError`.
1. If `Type`(|importValue|) is not Object:
    1. Throw a `TypeError`.
1. Let |isWasmResourceOf| be ? `GetV`(|importValue|, `@@isWasmResourceOf`).
1. If |isWasmResourceOf| is not callable:
    1. Let |isWasmResourceOf| be a built-in function that, given |jsValue|, returns ? `InstanceofOperator`(|jsValue|, |importValue|).
1. Let |destructor| be a host function that, given a host resource value, releases its reference to [[JSValue]] and returns.
1. Let |resourceType| be `create a host resource type` given |destructor|.
1. Return a host resource type whose [[ComponentResourceType]] is |resourceType|, whose [[ImportValue]] is |importValue| and whose [[IsWasmResourceOf]] is |isWasmResourceOf|.

One host resource type is created per resource type import declaration per instantiation. Two type imports satisfied by the same JS constructor become distinct component resource types, and a handle for one cannot be passed where the other is expected. Round tripping such a handle through JS does succeed, because JS only ever sees the wrapped value.

#### Conversions for host resource types

For a resource type `R` whose type variable is one of the component's type imports, let |hostType| be the host resource type `read the type import` produced for it:

- `ToJSValue(rep, own<R> | borrow<R>)`:
    1. Assert: |rep| is a host resource value whose [[Type]] is |hostType|.
    1. Return |rep|.[[JSValue]].
- `ToComponentValue(jsValue, own<R> | borrow<R>)`:
    1. If ? `Call`(|hostType|.[[IsWasmResourceOf]], **undefined**, « |jsValue| ») is not **true**, throw a `TypeError`.
    1. Return a host resource value whose [[Type]] is |hostType| and whose [[JSValue]] is |jsValue|.

Converting the same JS value to a host resource type will yield fresh handle indices. There is no canonicalization based on reference equality.

### Guest resource types (i.e. exported)

#### Re-exported host resource types

A component can export an imported resource type in one of two ways:
  1. Transparently - by leaving it `eq`-bound to the import
  2. Opaquely - by ascribing it with `(sub resource)`

This is visible in the component type that the embedder interface can inspect.

Transparent re-exports on top-level components are disallowed and trap during instantiation. This avoids the problem of figuring out how to mutate a pre-existing prototype to add new methods exported by a component.

Opaque re-exports are allowed and wrap the original host resource type in a new guest resource class. This prevents leaking of the implementation decision of whether the resource type export is from an import or defined in the component.

#### Guest resource classes

An exported resource type is given a JS class.

A component's type presents each of its exported resource types as an abstract type variable. A unique JS class is created for each type variable.

For example, the following will create a class for "r1" and "r3", while "r2" will re-use "r1"'s class.

```wat
(component
  (export "r1" (type $r1 (sub resource)))
  (export "r2" (type (eq $r1)))
  (export "r3" (type (sub resource)))
)
```

Guest resource classes are created in multiple phases:
  1. Create constructor and prototype *shells* before instantiation
  2. Instantiate the component, possibly running `start` functions
  3. Finish creating the constructor and prototype, *linking* the methods from the exports

This allows any resource values that escape during `start` to have a fixed prototype already created.

A resource class is a built-in function object with one extra internal slot, [[ConstructorFunc]], holding the component function that implements `new` or **empty**.

To `create resource class shells` given a |component|:
1. For each type export |export| of |component|'s type, in declaration order, recursing into exported instances:
    1. Let |variable| be the abstract type |export| designates.
    1. If |variable| is one of |component|'s type imports, throw a `TypeError`.
    1. If a resource class is already associated with |variable| for this instantiation:
        1. Continue.
    1. Let |arity| be the parameter count of the `[constructor]` export targeting |variable|, or 0 if there is none.
    1. Let |class| be `create a resource class shell` given `JSName`(|export|) and |arity|.
    1. Associate |class| with |variable| for this instantiation.

To `create a resource class shell` given a String |name| and an integer |arity|:
1. Let |prototype| be `OrdinaryObjectCreate`(`%Object.prototype%`).
1. Let |constructor| be a built-in function object with name |name|, length |arity| and a [[ConstructorFunc]] internal slot set to **empty**, whose [[Call]] throws a `TypeError`, and whose [[Construct]], given JS arguments |args| and |newTarget|, performs:
    1. If |constructor|.[[ConstructorFunc]] is **empty**, throw a `TypeError`.
    1. Let |rep| be ? `invoke a component function` given |constructor|.[[ConstructorFunc]], `[constructor]`, **undefined** and |args|.
    1. Let |resourceType| be the runtime resource type |constructor|.[[ConstructorFunc]]'s `own` result refers to.
    1. Return `create a resource instance` given |constructor|, |resourceType|, |rep|, **true** and |newTarget|.
1. Perform `DefinePropertyOrThrow`(|prototype|, `@@dispose`, PropertyDescriptor { [[Value]]: a built-in function that performs `drop a resource instance` given its **this** value, [[Writable]]: **true**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
1. Perform `DefinePropertyOrThrow`(|prototype|, `@@toStringTag`, PropertyDescriptor { [[Value]]: |name|, [[Writable]]: **false**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
1. Perform `DefinePropertyOrThrow`(|prototype|, "constructor", PropertyDescriptor { [[Value]]: |constructor|, [[Writable]]: **true**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
1. Perform `DefinePropertyOrThrow`(|constructor|, "prototype", PropertyDescriptor { [[Value]]: |prototype|, [[Writable]]: **false**, [[Enumerable]]: **false**, [[Configurable]]: **false** }).
1. Perform `DefinePropertyOrThrow`(|constructor|, `@@isWasmResourceOf`, PropertyDescriptor { [[Value]]: a built-in predicate that returns **true** if and only if its argument has a [[ResourceClass]] internal slot whose value is |constructor|, [[Writable]]: **false**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
1. Return |constructor|.

To `link resource classes` given a |componentInstance|:
1. For each type export |export| of |componentInstance|, in declaration order, recursing into exported instances:
    1. Let |variable| be the type variable |export| designates and |class| be the resource class associated with |variable|.
    1. If |class| was already linked by an earlier iteration, continue.
    1. Let |tagged| be the `[constructor]`, `[method]` and `[static]` function exports in |export|'s scope that target |variable|.
    1. If |tagged| has a `[constructor]` export |c|, set |class|.[[ConstructorFunc]] to |c|.Func.
    1. For each `[method]` export |m| of |tagged|:
        1. Perform `DefinePropertyOrThrow`(|class|'s `"prototype"`, `JSName`(|m|), PropertyDescriptor { [[Value]]: `create a JS function for a component function` given |m|.Func, `JSName`(|m|) and |m|'s tag, [[Writable]]: **true**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
    1. For each `[static]` export |s| of |tagged|, define the corresponding property on |class| with the same attributes.

#### Guest resource instances

An instance of a guest resource class holds the same state a handle table entry does, plus the class it belongs to:

| Slot | Value |
|---|---|
| [[ResourceClass]] | the resource class this is an instance of |
| [[ResourceType]] | the runtime component resource type |
| [[Rep]] | the rep, or **empty** once the handle has been dropped, transferred away, or expired |
| [[Own]] | whether this instance owns the resource |
| [[LendCount]] | how many outstanding `borrow`s were lent from this instance |

For each instantiation: a class, a type variable and a runtime resource type are all in one-to-one correspondence, so [[ResourceClass]] is what the conversions type check against and [[ResourceType]] is only there to drop the resource with.

To `create a resource instance` given a resource class |class|, a runtime resource type |resourceType|, |rep|, |own| and an optional |newTarget|:
1. Let |defaultProto| be the value of |class|'s `"prototype"` property.
1. If |newTarget| is present:
    1. Let |proto| be ? `Get`(|newTarget|, "prototype").
    1. If `Type`(|proto|) is not Object, set |proto| to |defaultProto|.
1. Else, let |proto| be |defaultProto|.
1. Let |instance| be `OrdinaryObjectCreate`(|proto|, « [[ResourceClass]], [[ResourceType]], [[Rep]], [[Own]], [[LendCount]] »).
1. Set |instance|.[[ResourceClass]] to |class|.
1. Set |instance|.[[ResourceType]] to |resourceType|.
1. Set |instance|.[[Rep]] to |rep|.
1. Set |instance|.[[Own]] to |own|.
1. Set |instance|.[[LendCount]] to 0.
1. If |own| is **true**, register |instance| in the JS-API's resource `FinalizationRegistry` with held value (|resourceType|, |rep|) and unregister token |instance|.
1. Return |instance|.

For a resource type `R` whose type variable is one of the component's type exports, let |class| be the resource class associated with that variable:

- `ToJSValue(rep, own<R>)`:
    1. Return `create a resource instance` given |class|, `R`, |rep| and **true**.
- `ToJSValue(rep, borrow<R>)`:
    1. Let |instance| be `create a resource instance` given |class|, `R`, |rep| and **false**.
    1. Append |instance| to the current borrow scope.
    1. Return |instance|.
- `ToComponentValue(jsValue, own<R>)`:
    1. If |jsValue| does not have a [[ResourceClass]] internal slot, or |jsValue|.[[ResourceClass]] is not |class|, throw a `TypeError`.
    1. If |jsValue|.[[Rep]] is **empty**, or |jsValue|.[[Own]] is **false**, or |jsValue|.[[LendCount]] is not 0, throw a `TypeError`.
    1. Let |rep| be |jsValue|.[[Rep]]. Set |jsValue|.[[Rep]] to **empty** and unregister |jsValue| from the resource `FinalizationRegistry`.
    1. Return |rep|.
- `ToComponentValue(jsValue, borrow<R>)`:
    1. If |jsValue| does not have a [[ResourceClass]] internal slot, or |jsValue|.[[ResourceClass]] is not |class|, throw a `TypeError`.
    1. If |jsValue|.[[Rep]] is **empty**, throw a `TypeError`.
    1. Increment |jsValue|.[[LendCount]] and append |jsValue| to the current lender list.
    1. Return |jsValue|.[[Rep]].

A fresh instance is created for every lift, so two `borrow`s of the same resource are two JS objects that do not compare equal.

The *current borrow scope* and *current lender list* are per-call spec state:
- `read the function import` establishes a borrow scope for a component-to-JS call. Once the JS call completes, every instance in the scope has its [[Rep]] set to **empty**, so JS holding on to a `borrow` past the call gets a `TypeError` on next use.
- `invoke a component function` establishes a lender list for a JS-to-component call. Once the component call completes, every instance in the list has its [[LendCount]] decremented.

#### Dropping guest resources

To `drop a resource instance` given |instance|:
1. If |instance| does not have a [[ResourceClass]] internal slot, throw a `TypeError`.
1. If |instance|.[[Rep]] is **empty** or |instance|.[[Own]] is **false**, return **undefined**.
1. If |instance|.[[LendCount]] is not 0, throw a `TypeError`.
1. Let |rep| be |instance|.[[Rep]]. Set |instance|.[[Rep]] to **empty** and unregister |instance| from the resource `FinalizationRegistry`.
1. Perform ? `drop a host owned resource` given |instance|.[[ResourceType]] and |rep|.
1. Return **undefined**.

Dropping is idempotent, and dropping a `borrow` instance does nothing because there is nothing to give back. The [[LendCount]] check makes disposing an instance that is currently lent to a component a `TypeError` rather than a trap.

`create a resource instance` adds `own` instances to a resource `FinalizationRegistry`. When the value is finalized, the host performs `drop a host owned resource` with the held (resource type, rep) pair.

### Fusing component value conversions

TODO.

## Instantiation

To `instantiate a component` given |component| and a list of component definitions |imports|:
1. Perform ? `create resource class shells` given |component|.
1. Instantiate |component| with |imports|.
    1. If instantiation traps, throw a `WebAssembly.RuntimeError`.
1. Let |instance| be the resulting component instance.
1. Perform `link resource classes` given |instance|.
1. Let |exportsObject| be ? `create the exports object` given |instance|.
1. Return a new `ComponentInstance` whose [[ComponentInstance]] is |instance| and whose [[Exports]] is |exportsObject|.

To `instantiate a component from an imports object` given |component| and |importsObject|:
1. Let |imports| be ? `read the imports` given |component| and |importsObject|.
1. Return ? `instantiate a component` given |component| and |imports|.

### Read the imports object

The top-level `read the imports` algorithm walks the component's imports and resolves each to a JS value via property lookups on the |importsObject|, mirroring the core JS-API's algorithm of the same name. The resolved JS values are then handed to the per-sort algorithms (`read the function import`, `read the type import` and friends) to produce the component definitions used during instantiation.

While walking, the algorithm recognizes the pattern of a resource type import accompanied by `[constructor]`, `[static]`, and `[method]` function imports tied to it. A resource type import is read first and looks for a constructor (see [resource types](#resource-types)). The tagged function imports then read from the constructor and its prototype directly. This allows the common case of importing a class to be satisfied by just passing the constructor.

Passing an exported component definition to a component import via the JS-API/ESM-integration is treated as if the import was a JS value. There is no "direct linking" that bypasses going through JS semantics. This is different from core wasm, where wasm exported functions are linked directly when imported and have stricter type checks. This is intentional to ensure that implementing an ES module using a component doesn't subtly change the behavior because it starts directly linking to components. Component definitions can still be directly linked within a top-level invocation of `instantiate a component`.

Every name looked up on a JS object is `JSName`(|decl|) (see "Names").

To `read the imports` given |component| and |importsObject|:
1. If |component| has no imports:
    1. Return an empty list.
1. Return ? `read a scope of imports` given |component|.Imports and |importsObject|.

To `read a scope of imports` given a list of declarations |declarations| and |object|:
1. If `Type`(|object|) is not Object:
    1. Throw a `TypeError`.
1. Let |resourceTypes| be a new empty map keyed by resource type declaration, holding host resource types.
1. Let |definitions| be a new empty list.

1. For each |decl| of |declarations|, in declaration order:
    1. Let |name| be `JSName`(|decl|).
    1. If |decl|.Sort is **func** and |decl|.Name is tagged `[constructor]<R>`, `[method]<R>.<name>` or `[static]<R>.<name>`:
        1. Let R be the resource type declared by the type declaration named by the tag's `<R>` label.
        1. Assert: |resourceTypes|[R] exists. (Validation requires that declaration to precede this one in the same scope)
        1. Let |constructorFunction| be |resourceTypes|[R].[[ImportValue]].
        1. If the tag is `[constructor]`:
            1. Let |importValue| be |constructorFunction|.
        1. Else if the tag is `[static]`:
            1. Let |importValue| be ? `GetV`(|constructorFunction|, |name|).
        1. Else:
            1. Let |prototype| be ? `GetV`(|constructorFunction|, "prototype").
            1. If `Type`(|prototype|) is not Object, throw a `TypeError`.
            1. Let |importValue| be ? `GetV`(|prototype|, |name|).
    1. Else:
        1. Let |importValue| be ? `GetV`(|object|, |name|).

    1. Let |resolved| be ? `read an import` given |decl|, |importValue| and |resourceTypes|.
    1. If |decl|.Sort is **type**:
        1. Set |resourceTypes|[|decl|.ResourceType] to |resolved|, and append |resolved|.[[ComponentResourceType]] to |definitions|.
    1. Else, append |resolved| to |definitions|.
1. Return |definitions|.

A type import resolves to a [host resource type](#host-resource-types-and-values), which is a JS-API record wrapping the component resource type. The component only ever gets the resource type, but the record is kept around for the rest of the scope's function imports and for the exports object.

To `read an import` given |decl|, |importValue| and |resourceTypes|:
1. Match |decl|.Sort:
    1. **core module**: return ? `read the core module import` given |decl|.ModuleType and |importValue|.
    1. **func**: return ? `read the function import` given |decl|.FuncType, |importValue|, |decl|.Name's tag and |resourceTypes|.
    1. **type**: return ? `read the type import` given |decl|.TypeBound and |importValue|.
    1. **value**: return ? `read the value import` given |decl|.ValType and |importValue|.
    1. **instance**: return ? `read the instance import` given |decl|.InstanceType and |importValue|.
    1. **component**: return ? `read the component import` given |decl|.ComponentType and |importValue|.

To `read the core module import` given |coreModuleType| and |importValue|:
1. If |importValue| does not have a [[Module]] internal slot:
    1. Throw a `TypeError`.
1. If the type of |importValue|.[[Module]] is not a subtype of |coreModuleType|:
    1. Throw a `WebAssembly.LinkError`.
1. Return |importValue|.[[Module]].

To `read the component import` given |componentType| and |importValue|:
1. If |importValue| does not have a [[Component]] internal slot:
    1. Throw a `TypeError`.
1. If the type of |importValue|.[[Component]] is not a subtype of |componentType|:
    1. Throw a `WebAssembly.LinkError`.
1. Return |importValue|.[[Component]].

To `read the instance import` given |instanceType| and |importValue|:
1. Let |definitions| be ? `read a scope of imports` given |instanceType|.Exports and |importValue|.
1. Return a component instance whose exports are |definitions|.

To `read the function import` given |componentFuncType|, |importValue|, |importNameTag| and |resourceTypes|:
1. If |importValue| is not callable:
    1. Throw a `TypeError`.
1. Let |paramTypes| be |componentFuncType|.Params and |resultType| be |componentFuncType|.Result.
1. Let |callKind|, |receiverRule| and |paramOffset| be determined by |importNameTag|:
    1. `[constructor]<R>`: `Construct`, no receiver, offset 0.
    1. `[method]<R>.<name>`: `Call`, receiver is component argument 0 (the `borrow<R>` self), offset 1.
    1. `[static]<R>.<name>`: `Call`, receiver is |resourceTypes|[R].[[ImportValue]], offset 0.
    1. otherwise: `Call`, receiver is **undefined**, offset 0.
1. If |resultType| is `result<T, E>`:
    1. Let |okType| be T, |errorType| be E, and |throwing| be **true**.
1. Else:
    1. Let |okType| be |resultType| and |throwing| be **false**.
1. Return a component host function of type |componentFuncType| whose body, given component arguments « |v_0|, ..., |v_{n-1}| », performs:
    1. Let |borrowScope| be a new empty List, and set the current borrow scope to |borrowScope|, saving the previous one. However this body completes, set the [[Rep]] of every instance in |borrowScope| to **empty** and restore the previous borrow scope before returning.
    1. If |receiverRule| is "component argument 0":
        1. Let |thisArg| be `ToJSValue`(|v_0|, |paramTypes|[0]).
    1. Else:
        1. Let |thisArg| be the receiver named by |receiverRule|.
    1. Let |args| be a new empty List.
    1. For each i in [|paramOffset|, n):
        1. Append `ToJSValue`(|v_i|, |paramTypes|[i]) to |args|.
    1. If |callKind| is `Construct`, let |completion| be `Construct`(|callable|, |args|); else let |completion| be `Call`(|callable|, |thisArg|, |args|).
    1. If |completion| is an abrupt completion:
        1. If |throwing| is **false**, trap.
        1. Let |errorValue| be `ToComponentValue`(|completion|.[[Value]], |errorType|). If that throws, trap.
        1. Return `result.error(|errorValue|)`.
    1. Let |componentResult| be `ToComponentValue`(|completion|.[[Value]], |okType|). If that throws, trap.
    1. If |throwing| is **true**, return `result.ok(|componentResult|)`; else return |componentResult|.

The borrow scope covers the whole body, so a `borrow<R>` of a component-defined resource is usable for the duration of the call, including from a callback the JS function passes back into the component, and is a `TypeError` to use afterwards.

To `read the value import` given |componentValType| and |importValue|:
1. Return `ToComponentValue`(|importValue|, |componentValType|). If that throws, propagate the exception.

### Create the exports object

The `create the exports object` algorithm walks the component's exports and builds a fresh JS object whose properties are the exports.

Component-defined resource types become [resource classes](#guest-resource-classes) named `JSName`(|export|), and tagged function exports are mapped onto them just as in `read the imports`:
- `[constructor]<R>`: the function becomes `R`'s constructor behaviour. By strong-uniqueness there can only be one.
- `[method]<R>.<name>`: the function becomes a method named `JSName`(|export|) on `R.prototype`.
- `[static]<R>.<name>`: the function becomes a static method named `JSName`(|export|) on `R`.

All other exported components definitions are given JS definitions named `JSName`(|export|) on the exports object.

To `create the exports object` given a |componentInstance|:
1. Let |exportsObject| be `OrdinaryObjectCreate`(**null**).
1. For each |export| of |componentInstance|.|component|.Exports, in declaration order:
    1. If |export|.Name is tagged `[constructor]<R>`, `[method]<R>.<name>` or `[static]<R>.<name>`, it is consumed by `link resource classes` for R; continue.
    1. Let |key| be `JSName`(|export|).
    1. Match |export|.Sort:
        1. **core module**:
            1. Let |value| be a new `Module` whose [[Module]] is |export|.Module.
        1. **type**:
            1. If |export|.Type is not a resource type:
                1. Throw `TypeError`.
            1. Let |variable| be the abstract type |export| designates.
            1. If |variable| is one of the component's type imports:
                1. Throw a `TypeError`.
            1. Else:
                1. Let |value| be the resource class associated with |variable|.
        1. **func**:
            1. Let |value| be `create a JS function for a component function` given |export|.Func, |key| and no tag.
        1. **value**:
            1. Let |value| be `ToJSValue`(|export|.Value, |export|.Type).
        1. **instance**:
            1. Let |value| be ? `create the exports object` given the exported instance.
        1. **component**:
            1. Let |value| be a new `Component` whose [[Component]] is |export|.Component.
    1. Perform `CreateDataPropertyOrThrow`(|exportsObject|, |key|, |value|).
1. Return |exportsObject|.

To `create a JS function for a component function` given |componentFunc|, |name| and |exportNameTag|:
1. Let |paramOffset| be 1 if |exportNameTag| is `[method]<R>.<name>`, else 0.
1. Let |okType| be |componentFunc|.Result's `result` payload type if it is a `result<T, E>`, else |componentFunc|.Result.
1. Return a built-in function object with name |name| and length |componentFunc|.Params.length - |paramOffset|, whose behaviour, given a **this** value |thisValue| and JS arguments |args|, performs:
    1. Let |componentResult| be ? `invoke a component function` given |componentFunc|, |exportNameTag|, |thisValue| and |args|.
    1. Return `ToJSValue`(|componentResult|, |okType|).

A `[method]` export takes its **this** value as the component function's first parameter, which validation guarantees is the `borrow<R>` self, mirroring how `read the function import` maps component argument 0 onto a JS receiver. A `[static]` export ignores its **this** value.

To `invoke a component function` given |componentFunc|, |exportNameTag|, |thisValue| and a List of JS values |args|:
1. Let |paramTypes| be |componentFunc|.Params and |resultType| be |componentFunc|.Result.
1. Let |paramOffset| be 1 if |exportNameTag| is `[method]<R>.<name>`, else 0.
1. If |resultType| is `result<T, E>`:
    1. Let |okType| be T, |errorType| be E, and |throwing| be **true**.
1. Else:
    1. Let |okType| be |resultType| and |throwing| be **false**.
1. Let |lenders| be a new empty List, and set the current lender list to |lenders|, saving the previous one. However this algorithm completes, decrement the [[LendCount]] of every instance in |lenders| and restore the previous lender list before returning.
1. Let |values| be a new empty List.
1. If |paramOffset| is 1, append ? `ToComponentValue`(|thisValue|, |paramTypes|[0]) to |values|.
1. If the number of |args| is less than |paramTypes|.length - |paramOffset|, throw a `TypeError`.
1. For each i in [0, |paramTypes|.length - |paramOffset|):
    1. Append ? `ToComponentValue`(|args|[i], |paramTypes|[i + |paramOffset|]) to |values|.
1. Arguments beyond that are ignored.
1. Let |componentResult| be the result of invoking |componentFunc| with |values|.
    1. If the call traps, throw a `WebAssembly.RuntimeError`.
1. If |throwing| is **true**:
    1. If |componentResult| is `result.error(|e|)`:
        1. Throw `create a component error` for |e| and |errorType|.
    1. Set |componentResult| to the `result.ok` payload.
1. Return |componentResult|.

The lender list covers the whole call, so JS cannot dispose a resource instance it lent to a component while the component still holds the `borrow`, even if the component calls back out to JS to try.

To `create a component error` for component value |e| and component type |errorType|:
1. Let |payload| be `ToJSValue`(|e|, |errorType|).
1. Return a new `ComponentError` whose `payload` is |payload| and an implementation defined `message`.

## WebAssembly ESM-Integration

[ESM-integration](https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration) extends to components. The loader branches on the `layer` field of the binary to decide whether the bytes decode as a module or a component, so a component can be loaded anywhere a module can be today.

Each component import becomes a JS import for the module loader. Its [module specifier](https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ModuleSpecifier) is the import's [`external-id`](Explainer.md#import-and-export-definitions) attribute if it has one, and its `externname` otherwise. A specifier is resolved (not looked up on an object) so it is not converted to a JS name.

Which binding of the resolved module the component gets depends on what the import's type is:

| Import type | JS equivalent | Value |
|---|---|---|
| bare function, value | `import v from "spec"` | the [default export](https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ImportedDefaultBinding) |
| instance | `import { a, b } from "spec"` | one [named import](https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-NamedImports) per export of the instance type, named `JSName` of that export |
| core module, component | `import source M from "spec"` | the module source, as a `Module` or `Component` |

Each resolved value is handed to [`read an import`](#read-the-imports-object) and the resulting definitions are passed to [`instantiate a component`](#instantiation).

A component's exports become the bindings of its module namespace object. There is one binding per `JSName`(|export|), holding what [`create the exports object`](#create-the-exports-object) puts under that name, and no `default` binding.

Reading the imports snapshots the resolved values, and so components cannot participate in cycles. This matches how core modules work today with ESM-integration.

TODO: figure out TLA and async start functions.

## Open questions

1. How to dynamically pass a union value? Static selection works.
1. How to import an overloaded function?
1. How to support class inheritance and casting? Can a component defined resource sub-class an imported resource type?
1. How to support reference equality? `ToJSValue` creates a fresh resource instance per lift, so two `borrow`s of one component-defined resource are two JS objects that do not compare equal. Reps are opaque and reusable after a drop, so an identity map would need careful invalidation.
1. How to import/export properties with getters/setters?
1. What happens if a component traps? Do we have lockdown semantics of some sort?
1. There is no `any` in the component model, so a component's only way to hold an opaque JS value is a resource type import with no brand check hook. Should we define builtin resource types for JS primitive types?
1. A `start` function can pass a resource value to a JS function import and then trap. Disposing the resource value would run a destructor in an uninstantiated component.
