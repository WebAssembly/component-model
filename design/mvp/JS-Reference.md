# WebAssembly Components JS-API Reference

This is the in-depth reference for the WebAssembly Component JS-API. See the [explainer](./JS-Explainer.md) for a higher-level introduction.

**This is a draft and is not complete. Major details are unresolved, and there are bugs.**

## Goals

1. Components can import and use most web and JS APIs
2. Components can export an API usable by JS
3. Components interact with the web platform in similar ways to JS:
  a. Components can feature test whether APIs are present
  b. Components work whether they are importing a web API, or a JS polyfill, or a component polyfill
  c. Components are tolerant of web API evolution
  d. Component misuse of a web API results in failure at that call-site, not a link time error
4. Components have improved performance when calling web APIs compared to today

## Non-goals

1. Components importing every kind of web API
1. Components exporting any kind of JS API

## The WebAssembly namespace

We extend the imperative WebAssembly JS-API interfaces to also allow validation, compilation, and instantiation of components in addition to modules.

```webidl
[LegacyNamespace=WebAssembly, Exposed=*]
interface Component {
    constructor([AllowResizable] AllowSharedBufferSource bytes, optional WebAssemblyCompileOptions options = {});
};

[LegacyNamespace=WebAssembly, Exposed=*]
interface ComponentInstance {
    constructor(Component component, optional object importsObject);
    readonly attribute object exports;
};

typedef (Component or Module) InstantiateSource;

dictionary WebAssemblyInstantiatedComponentSource {
    required Component component;
    required ComponentInstance instance;
};

[Exposed=*]
namespace WebAssembly {
    // Same as before, but now will detect if the bytes are a component or module and dispatch differently.
    boolean validate([AllowResizable] AllowSharedBufferSource bytes, optional WebAssemblyCompileOptions options = {});
    Promise<Module> compile([AllowResizable] AllowSharedBufferSource bytes, optional WebAssemblyCompileOptions options = {});
    Promise<(WebAssemblyInstantiatedSource or WebAssemblyInstantiatedComponentSource)> instantiate(
        [AllowResizable] AllowSharedBufferSource bytes, optional object importObject, optional WebAssemblyCompileOptions options = {});

    // Now takes an InstantiateSource instead of just a Module, and returns a
    // ComponentInstance for a Component.
    Promise<(Instance or ComponentInstance)> instantiate(
        InstantiateSource moduleObject, optional object importObject);
};
```

We also add an error type for component functions that return `result<_, E>` to JS:

```webidl
[LegacyNamespace=WebAssembly, Exposed=*]
interface ComponentError : Error {
    constructor(optional DOMString message = "", optional any data);
    readonly attribute any data;
};
```

`data` is the converted `E` value. See [Create the exports object](#create-the-exports-object).

## Validation/compilation

Validation and compilation of components defer to the underlying component embedding interface. This reference adds nothing to it.

## Entry points

A `Component` has the following slots:
  1. [[Component]] - the compiled component.
  1. [[EnabledBuiltins]] - the enabled builtins.

A `ComponentInstance` has the following slots:
  1. [[ComponentInstance]] - the component instance.
  1. [[Exports]] - the [exports object](#create-the-exports-object).
  1. [[HostResourceTypes]] - map from [abstract type key](#abstract-and-transparent-types) to [host resource type](#host-resource-types-and-values).
  1. [[GuestResourceClasses]] - map from [abstract type key](#abstract-and-transparent-types) to [guest resource class](#guest-resource-classes).

To `construct a Component` given |bytes| and |options|:
1. Let |stableBytes| be a copy of the bytes held by |bytes|.
1. Let |enabledBuiltins| be the result of parsing [`builtins`](#builtin-imports) from |options|.
1. Let |component| be the result of compiling |stableBytes| as a component, per the embedding interface.
1. If compilation fails:
    1. Throw a `WebAssembly.CompileError`.
1. Set **this**.[[Component]] to |component|.
1. Set **this**.[[EnabledBuiltins]] to |enabledBuiltins|.

To `construct a ComponentInstance` given a `Component` |component|, and |importsObject|:
1. Let |enabledBuiltins| be |component|.[[EnabledBuiltins]].
1. Let |result| be ? [`instantiate a component from an imports object`](#instantiation) given |component|.[[Component]], |importsObject|, |enabledBuiltins|.
1. Set **this**.[[ComponentInstance]] to |result|.[[ComponentInstance]].
1. Set **this**.[[Exports]] to |result|.[[Exports]].
1. Set **this**.[[HostResourceTypes]] to |result|.[[HostResourceTypes]].
1. Set **this**.[[GuestResourceClasses]] to |result|.[[GuestResourceClasses]].

The `exports` getter returns **this**.[[Exports]].

`validate` is modified to validate the bytes as a component if the `layer` field of the binary indicates a component.
`compile`/`instantiate` are modified to asynchronously compile/instantiate the bytes as a component if the `layer` field indicates a component.

## Names

Component import/export `plainname`s contain [`label`s](Explainer.md#import-and-export-definitions) that must be transformed into an identifier for use with JS.

Component import/export `interfacename`s (such as `wasi:http/handler@1.0.0`) are used as-is when converted to JS strings or as [module specifiers](#webassembly-esm-integration).

We define `PascalCase(label)` and `CamelCase(label)` below.

| `label` | `PascalCase` | `CamelCase` |
|---|---|---|
| `element` | `Element` | `element` |
| `query-selector` | `QuerySelector` | `querySelector` |
| `inner-HTML` | `InnerHTML` | `innerHTML` |
| `XML-http-request` | `XMLHttpRequest` | `xmlHttpRequest` |
| `URL` | `URL` | `url` |
| `a1-2-3` | `A123` | `a123` |

`LabelOf`(|name|), where |name| is a `plainname`, returns the label that names the definition in JS:
1. Let |stripped| be |name| with every `[...]` annotation removed.
1. If |stripped| is `r.n`:
    1. Return `n`.
1. Return |stripped|.

`Fragments`(|label|):
1. Return the List of Strings produced by splitting |label| on occurrences of U+002D (-). The hyphens themselves are discarded.

`Capitalize`(|fragment|):
1. If |fragment| is an [`acronym`](Explainer.md#import-and-export-definitions):
    1. Return |fragment|.
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
1. If |decl|.Name is an `interfacename`:
    1. Return |decl|.Name.
1. If |decl| is a type declaration:
    1. Return `PascalCase`(`LabelOf`(|decl|.Name)).
1. Return `CamelCase`(`LabelOf`(|decl|.Name)).

An import's specifier is its [`external-id`](Explainer.md#import-and-export-definitions) attribute if it has one, and its JS name otherwise:

`JSSpecifier`(|decl|):
1. If |decl| has an `external-id` attribute:
    1. Return that attribute's name.
1. Return `JSName`(|decl|).

## Types and values

Components and JS maintain separate type/value systems, so any value crossing the boundary needs a defined translation in both directions.

This section specifies that translation as two abstract operations:
1. `ToJSValue` - convert a component value to a JS value.
1. `ToComponentValue` - convert a JS value to a component value of a given type.

Roundtripping from `ToJSValue` back through `ToComponentValue` is designed to be strictly the identity function with the following exceptions:
  1. A `map` with duplicate keys keeps only the last pair per key (see [`ToJSValueMap`](#tojsvalue))
  1. Float NaNs are [canonicalized](CanonicalABI.md#loading)

Every object a conversion creates belongs to the *conversion realm*: the realm of the `WebAssembly` namespace the component was instantiated through.

### ToJSValue

`ToJSValue(componentValue, componentValType)` converts a component value to a JS value. It is infallible.

Dispatch on `componentValType`:

- `bool` → Boolean.
- Integer types other than `s64`/`u64` → Number, an exact integer.
- `s64` / `u64` → BigInt.
- `f32` / `f64` → Number, including NaN and infinities.
- `char` → String containing exactly the one Unicode scalar value.
- `string` → String [(well formed)](https://tc39.es/ecma262/#sec-isstringwellformedunicode).
- `list<u8>` → a Uint8Array over a fresh ArrayBuffer holding the bytes.
- `list<T>` → `ToJSValueList`(the elements, T).
- `list<T, N>` → as `list<T>`; `length` is `N`.
- `tuple<T0, T1, ...>` → as `list`, with element `i` converted as `T_i`.
- `record { f: T, ... }` → `ToJSValueRecord`(|componentValue|, the fields).
- `flags "L"+` → `ToJSValueFlags`(|componentValue|, the labels).
- `enum "L"+` → String, the label verbatim.
- `option<T>` where T is not `option<_>` → **null** for `none`, else `ToJSValue`(the payload, T).
- `variant`, and `option<option<_>>`, and `result` outside return position → `ToJSValueVariant`(|componentValue|, the cases). In return position a `result` is unwrapped instead, into a return value or a thrown `ComponentError` (see [Read the imports](#read-the-imports-object) and [Create the exports object](#create-the-exports-object)).
- `map<K, V>` → `ToJSValueMap`(|componentValue|, K, V).
- `own<R>` / `borrow<R>` → See [Resource types](#resource-types).
- `future<T>` → a Promise (TODO).
- `stream<T>` → a `ReadableStream` (TODO).
- `error-context` → TODO.

`ToJSValueList(values, T)`:
1. Let |n| be the number of |values|.
1. Let |array| be `ArrayCreate`(|n|).
1. For each i in [0, |n|):
    1. Perform `CreateDataPropertyOrThrow`(|array|, `ToString`(𝔽(i)), `ToJSValue`(|values|[i], T)).
1. Return |array|.

`ToJSValueRecord(value, fields)`:
1. Let |object| be `OrdinaryObjectCreate`(**null**).
1. For each field `f: T` of |fields|, in declaration order:
    1. Perform `CreateDataPropertyOrThrow`(|object|, `CamelCase`(f), `ToJSValue`(|value|'s `f`, T)).
1. Return |object|.

`ToJSValueFlags(value, labels)`:
1. Let |object| be `OrdinaryObjectCreate`(**null**).
1. For each label `L` of |labels|:
    1. Perform `CreateDataPropertyOrThrow`(|object|, `CamelCase`(L), |value|'s `L` bit as a Boolean).
1. Return |object|.

`ToJSValueVariant(value, cases)`:
1. Let |object| be `OrdinaryObjectCreate`(**null**).
1. Perform `CreateDataPropertyOrThrow`(|object|, "kind", `PascalCase`(`CaseLabelOf`(|value|, |cases|))).
1. If that case has a payload of type T:
    1. Perform `CreateDataPropertyOrThrow`(|object|, "value", `ToJSValue`(`PayloadOf`(|value|), T)).
1. Return |object|.

`ToJSValueMap(value, K, V)`:
1. Let |map| be a new ordinary `Map` object with an empty [[MapData]] and the conversion realm's `%Map.prototype%`.
1. For each pair (k, v) of |value|, in order:
    1. Let |key| be `ToJSValue`(k, K).
    1. Let |mapValue| be `ToJSValue`(v, V).
    1. If [[MapData]] has an entry whose key is `SameValueZero` to |key|:
        1. Set that entry's value to |mapValue|.
    1. Else:
        1. Append an entry (|key|, |mapValue|) to [[MapData]].
1. Return |map|.

A `map<K, V>` is a [specialization](Explainer.md#type-definitions) of `list<tuple<K, V>>` where the last pair for a key defines its value. So `[(a,1),(a,2)]` round-trips from a component value to JS and back as `[(a,2)]`.

### ToComponentValue

`ToComponentValue(jsValue, targetComponentType)` converts a JS value to a component value. It may throw if the JS value doesn't match the component value type.

Dispatch on `targetComponentType`:

- `bool` → `ToBoolean`(|jsValue|).
- Integer types → `ToComponentValueInteger`(|jsValue|, the type).
- Float types → `ToComponentValueFloat`(|jsValue|, the type).
- `char` → ? `ToString`(|jsValue|); it must consist of exactly one Unicode scalar value, else throw a `TypeError`. A lone surrogate is not a scalar value and is therefore a `TypeError`.
- `string` → ? `ToString`(|jsValue|), then replace each unpaired surrogate with U+FFFD (matching WebIDL `USVString`).
- `list<u8>` → `ToComponentValueBytes`(|jsValue|).
- `list<T>` → `ToComponentValueList`(|jsValue|, T).
- `list<T, N>` → as `list<T>`, then the length must be exactly `N`, else throw a `TypeError`.
- `tuple<T0, ...>` → as `list`, then the length must be exactly the arity, and element `i` converts to `T_i`.
- `record { f: T, ... }` → `ToComponentValueRecord`(|jsValue|, the fields).
- `flags "L"+` → `ToComponentValueFlags`(|jsValue|, the labels).
- `enum` → ? `ToString`(|jsValue|) must be one of the labels, else throw a `TypeError`.
- `option<T>` where T is not `option<_>` → **null** and **undefined** both give `none`; anything else gives `some(ToComponentValue(jsValue, T))` (matching how WebIDL treats a nullable type).
- `variant`, and `option<option<_>>`, and `result` outside return position → `ToComponentValueVariant`(|jsValue|, the cases). In return position a `result` is unwrapped instead: a JS return value becomes `result.ok`, and a thrown exception becomes `result.error` (see [Read the imports](#read-the-imports-object) and [Create the exports object](#create-the-exports-object)).
- `map<K, V>` → `ToComponentValueMap`(|jsValue|, K, V).
- `own<R>` / `borrow<R>` → See [Resource types](#resource-types).
- `future<T>` → TODO.
- `stream<T>` → TODO.
- `error-context` → TODO.

`ToComponentValueInteger(jsValue, t)`:
1. If |t| is `s64` or `u64` and `Type`(|jsValue|) is BigInt:
    1. Let |n| be |jsValue|'s value.
    1. If |n| is outside |t|'s range:
        1. Throw a `TypeError`.
    1. Return |n|.
1. Let |number| be ? `ToNumber`(|jsValue|).
1. If |number| is `NaN` or an infinity:
    1. Throw a `TypeError`.
1. Let |n| be |number| truncated toward zero.
1. If |n| is outside |t|'s range:
    1. Throw a `TypeError`.
1. Return |n|.

`ToComponentValueFloat(jsValue, t)`:
1. Let |num| be ? `ToNumber`(|jsValue|).
1. If |t| is `f32`:
    1. Set |num| to |num| rounded to the nearest f32 value (ties to even).
1. Return |num|.

`NaN` and infinities are accepted (matching WebIDL `unrestricted float`/`unrestricted double`).

`ToComponentValueBytes(jsValue)`:
1. If |jsValue| has a [[TypedArrayName]] internal slot whose value is "Uint8Array":
    1. If |jsValue|'s underlying buffer is detached or |jsValue| is out of bounds:
        1. Throw a `TypeError`.
    1. Return one `u8` per byte of |jsValue|, in order.
1. Return `ToComponentValueList`(|jsValue|, `u8`).

A `Uint8Array` is copied directly, since that is what `ToJSValue` produces. Anything else (including other typed arrays) goes through the iterable path.

`ToComponentValueList(jsValue, T)`:
1. If |jsValue| is not an Object:
    1. Throw a `TypeError`.
1. Let |method| be ? `GetMethod`(|jsValue|, `%Symbol.iterator%`).
1. If |method| is **undefined**:
    1. Throw a `TypeError`.
1. Let |iteratorRecord| be ? `GetIteratorFromMethod`(|jsValue|, |method|).
1. Let |list| be an empty component list of type `T`.
1. Repeat:
    1. Let |next| be ? `IteratorStepValue`(|iteratorRecord|).
    1. If |next| is **done**, return |list|.
    1. Set |list| to |list| with ? `ToComponentValue`(|next|, `T`) appended to the end.

`ToComponentValueRecord(jsValue, fields)`:
1. If |jsValue| is not an Object:
    1. Throw a `TypeError`.
1. Let |record| be a new component record value with one field per |fields|.
1. For each field `f: T` of |fields|, in declaration order:
    1. Let |m| be ? `Get`(|jsValue|, `CamelCase`(f)).
    1. If |m| is **undefined** and `T` is not `option<_>`:
        1. Throw a `TypeError`.
    1. Set |record|'s `f` field to ? `ToComponentValue`(|m|, T).
1. Return |record|.

`ToComponentValueFlags(jsValue, labels)`:
1. If |jsValue| is not an Object:
    1. Throw a `TypeError`.
1. Let |flags| be a new component flags value with every bit initially **false**.
1. For each label `L` of |labels|:
    1. Set |flags|'s `L` bit to `ToBoolean`(? `Get`(|jsValue|, `CamelCase`(L))).
1. Return |flags|.

An absent property is therefore **false**, matching a `boolean` dictionary member defaulted to **false**.

`ToComponentValueVariant(jsValue, cases)`:
1. If |jsValue| is not an Object:
    1. Throw a `TypeError`.
1. Let |kind| be ? `ToString`(? `Get`(|jsValue|, "kind")).
1. If there is no case of |cases| whose label `L` has `PascalCase`(`L`) equal to |kind|:
    1. Throw a `TypeError`.
1. Let |case| be that case.
1. If |case| has a payload type T:
    1. Let |payload| be ? `ToComponentValue`(? `Get`(|jsValue|, "value"), T).
    1. Return a variant value of |case| whose payload is |payload|.
1. Return a variant value of |case| with no payload.

`ToComponentValueMap(jsValue, K, V)`:
1. If |jsValue| is not an Object:
    1. Throw a `TypeError`.
1. If ? `GetMethod`(|jsValue|, `%Symbol.iterator%`) is not **undefined**:
    1. Return `ToComponentValueList`(|jsValue|, `tuple<K, V>`).
1. If K is not `string`:
    1. Throw a `TypeError`.
1. Return one pair per own enumerable string-keyed property of |jsValue|, in property order, reading each value with ? `Get` and converting it with `ToComponentValue`(_, V).

If the value is not iterable, we fall back to converting the object the way WebIDL's `record<DOMString, V>` would, for compatibility.

## Resource types

A component resource type can be defined in a component (i.e. a guest resource), or else as an imported abstract type (i.e. a host resource).

The component JS-API defines:

1. How a JS value satisfies a resource type import.
1. A spec representation of host resource types and values.
1. A JS representation of guest resource types and values.

### Embedder extensions

We sketch two operations here that will be formalized more fully in the [embedding interface](CanonicalABI.md#embedding).

To `create a resource type for host` given a host function |destructor|:
1. Return a fresh component resource type whose representation is host-defined and whose destructor is |destructor|.

To `drop a guest resource` given a resource type |resourceType| and a guest rep |rep| owned by the host:
1. Perform the effect of [`canon resource.drop`](CanonicalABI.md#canon-resourcedrop) on an owning handle holding |resourceType| and |rep|, invoking |resourceType|'s destructor. There is no handle table entry to remove, because the host was holding the rep.
1. If that traps:
    1. Throw a `WebAssembly.RuntimeError`.

### Abstract and transparent types

Imported and exported resource types are either abstract or transparently equivalent to a previous abstract import or export.

```
(component
  (import "r1" (type $r1 (sub resource)))
  (import "r2" (type (eq $r1)))
  (import "r3" (type (sub resource)))

  (export "r4" (type $r4 (sub resource)))
  (export "r5" (type (eq $r4)))
  (export "r6" (type (sub resource)))

  (export "r7" (type (eq $r3)))
)
```

`r1`, `r3`, `r4`, `r6` are the abstract types of this component type, while `r2`, `r5`, and `r7` are transparently equal to one of the abstract types.

Host/guest resource types below are created only for abstract types, and stored in maps on the component instance. The map is keyed by an *abstract type key*, which is an import/export declaration for an abstract type.

An *abstract type key* can be found for any import/export type declaration by following `(eq R)` until you reach a `(sub resource)`.

### Host resource types (i.e. imported)

#### Brand checks

A resource type import is satisfied by a constructor. Each time a JS value needs to be converted to a value of that resource type, it is *brand checked* against the constructor.

To `brand check` given a JS value |jsValue| and an Object |constructor|:
1. If |constructor| is a WebIDL [interface object](https://webidl.spec.whatwg.org/#dfn-interface-object):
    1. Return **true** if and only if |jsValue| is a platform object that [implements](https://webidl.spec.whatwg.org/#implements) the interface |constructor| is the interface object of.
1. If |constructor| has a [[ConstructorFunc]] internal slot (i.e. it is a [guest resource class](#guest-resource-classes)):
    1. Return **true** if and only if |jsValue| has a [[ResourceClass]] internal slot whose value is |constructor|.
1. Return ? `InstanceofOperator`(|jsValue|, |constructor|).

Which case applies is fixed for the lifetime of |constructor|.

The first two cases are real brand checks. The `instanceof` fallback only inspects the prototype chain, so a value that was never created by |constructor| can pass it. In the future we may add a way for JS to supply a custom brand check.

#### Host resource types and values

A *host resource type* is what the JS-API creates to satisfy a resource type import. It is a Record with the following fields:

| Field | Value |
|---|---|
| [[ComponentResourceType]] | the component resource type produced by `create a resource type for host` |
| [[ConstructorObject]] | the JS constructor that satisfied the import |

A *host resource value* is the `rep` of a host resource type. It too is a Record:

| Field | Value |
|---|---|
| [[Type]] | the host resource type this is a rep of |
| [[JSValue]] | the JS value, held strongly |

A host resource value just holds a strong reference to the underlying value. No user-level destructors are run when it is dropped.

One host resource type is created per imported [abstract type](#abstract-and-transparent-types). Two abstract type imports satisfied by the same JS constructor become distinct component resource types, and a handle for one cannot be passed where the other is expected.

A map from imported abstract type to host resource type is built by [`read the imports`](#read-the-imports-object) and stored on a [component instance](#entry-points).

#### Conversions for host resources

For a resource type `R` whose abstract type is one of the component's type imports:

- `ToJSValue(rep, own<R> | borrow<R>)`:
    1. Let |instance| be the surrounding component instance.
    1. Let |abstractTypeKey| be the *abstract type key* of |R|.
    1. Let |hostType| be |instance|.[[HostResourceTypes]][|abstractTypeKey|].
    1. Assert: |rep| is a host resource value whose [[Type]] is |hostType|.
    1. Return |rep|.[[JSValue]].
- `ToComponentValue(jsValue, own<R> | borrow<R>)`:
    1. Let |instance| be the surrounding component instance.
    1. Let |abstractTypeKey| be the *abstract type key* of |R|.
    1. Let |hostType| be |instance|.[[HostResourceTypes]][|abstractTypeKey|].
    1. Let |matches| be ? `brand check` given |jsValue| and |hostType|.[[ConstructorObject]].
    1. If |matches| is **false**:
        1. Throw a `TypeError`.
    1. Return a host resource value whose [[Type]] is |hostType| and whose [[JSValue]] is |jsValue|.

Converting the same JS value to a host resource type yields fresh handle indices. There is no canonicalization of indices.

### Guest resource types (i.e. exported)

#### Re-exported host resource types

A component's type may export a resource type that is transparently equal to one of its imported resource types (see [abstract types](#abstract-and-transparent-types)). This currently [throws](#create-the-exports-object), but may be relaxed in the future.

An exported resource type that is only privately a re-export of an imported type, i.e. the component's type declares it as a fresh abstract export, will wrap the original host resource type in a new [guest resource class](#guest-resource-classes). This keeps callers from observing whether an exported resource type is a re-export or defined in the component.

#### Guest resource classes

A unique JS *guest resource class* is created for each exported [abstract type](#abstract-and-transparent-types). A map from [abstract type key](#abstract-and-transparent-types) to guest resource class is stored on the component instance.

A guest resource class is a built-in function object with the following slots:
1. [[ResourceType]] - the guest resource type.
1. [[ConstructorFunc]] - the component function that implements `new`, or **empty**.
1. [[ComponentInstance]] - the component instance the class belongs to.

To `create a guest resource class` given a component instance |componentInstance|, resource type |resourceType|, String |name| and an integer |arity|:
1. Let |prototype| be `OrdinaryObjectCreate`(`%Object.prototype%`).
1. Let |constructor| be a built-in function object with name |name| and length |arity|.
1. Set |constructor|.[[ResourceType]] to |resourceType|.
1. Set |constructor|.[[ConstructorFunc]] to **empty**.
1. Set |constructor|.[[ComponentInstance]] to |componentInstance|.
1. Set |constructor|'s [[Call]] behaviour to throw a `TypeError`.
1. Set |constructor|'s [[Construct]] behaviour, given JS arguments |args| and |newTarget|, to perform:
    1. If |constructor|.[[ConstructorFunc]] is **empty**:
        1. Throw a `TypeError`.
    1. Let |rep| be ? `invoke a component function` given |constructor|.[[ConstructorFunc]], `[constructor]`, **undefined** and |args|.
    1. Return ? `create a guest resource instance` given |constructor|, |rep|, **true** and |newTarget|.
1. Perform `DefinePropertyOrThrow`(|prototype|, `%Symbol.dispose%`, PropertyDescriptor { [[Value]]: a built-in function that performs `drop a guest resource instance` given its **this** value, [[Writable]]: **true**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
1. Perform `DefinePropertyOrThrow`(|prototype|, `%Symbol.toStringTag%`, PropertyDescriptor { [[Value]]: |name|, [[Writable]]: **false**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
1. Perform `DefinePropertyOrThrow`(|prototype|, "constructor", PropertyDescriptor { [[Value]]: |constructor|, [[Writable]]: **true**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
1. Perform `DefinePropertyOrThrow`(|constructor|, "prototype", PropertyDescriptor { [[Value]]: |prototype|, [[Writable]]: **false**, [[Enumerable]]: **false**, [[Configurable]]: **false** }).
1. Let |tagged| be the `[constructor]`, `[method]` and `[static]` function exports in |componentInstance|'s scope that target |resourceType|.
1. If |tagged| has a `[constructor]` export |c|:
    1. Set |constructor|.[[ConstructorFunc]] to |c|.Func.
1. For each `[method]` or `[static]` export |e| of |tagged|, in declaration order:
    1. If |e| is tagged `[method]`:
        1. Let |target| be |prototype|.
        1. Let |reserved| be "constructor".
    1. Else if |e| is tagged `[static]`:
        1. Let |target| be |constructor|
        1. Let |reserved| be "prototype".
    1. If `JSName`(|e|) is |reserved|:
        1. Throw a `TypeError`.
    1. If |e| is tagged `[get]` or `[set]`:
        1. Perform `define an accessor for a component function` given |target|, |e| and **false**.
    1. Else:
        1. Let |func| be `create a JS function for a component function` given |e|.Func, `JSName`(|e|) and |e|'s tag.
        1. Perform `DefinePropertyOrThrow`(|target|, `JSName`(|e|), PropertyDescriptor { [[Value]]: |func|, [[Writable]]: **true**, [[Enumerable]]: **false**, [[Configurable]]: **true** }).
1. Return |constructor|.

A method named `constructor` and a static named `prototype` are rejected because they would unexpectedly change JS class semantics.

`[get]` and `[set]` exports become the two halves of one accessor property, on `prototype` when tagged `[method]` and on the class itself when tagged `[static]`. Validation requires a `[set]` to be preceded in the same scope by the `[get]` it pairs with, so the getter is always defined first and the setter only fills in the accessor's [[Set]] field.

#### Guest resource instances

An instance of a guest resource class has the following slots:
1. [[ResourceClass]] - the resource class this is an instance of.
1. [[Rep]] - the rep, or **empty** once the handle has been dropped.
1. [[Own]] - whether this instance owns the resource.
1. [[LendCount]] - how many outstanding `borrow`s were lent from this instance.

It holds the same state a handle table entry does, plus the class it belongs to.

To `create a guest resource instance` given a resource class |class|, |rep|, |own| and an optional |newTarget|:
1. Let |defaultProto| be the value of |class|'s `"prototype"` property.
1. If |newTarget| is present:
    1. Let |proto| be ? `Get`(|newTarget|, "prototype").
    1. If `Type`(|proto|) is not Object:
        1. Set |proto| to |defaultProto|.
1. Else:
    1. Let |proto| be |defaultProto|.
1. Let |instance| be `OrdinaryObjectCreate`(|proto|, « [[ResourceClass]], [[Rep]], [[Own]], [[LendCount]] »).
1. Set |instance|.[[ResourceClass]] to |class|.
1. Set |instance|.[[Rep]] to |rep|.
1. Set |instance|.[[Own]] to |own|.
1. Set |instance|.[[LendCount]] to 0.
1. If |own| is **true**:
    1. Register |instance| in the [guest resource `FinalizationRegistry`](#guest-resource-finalizationregistry) with held value |instance| and unregister token |instance|.
1. Return |instance|.

#### Conversions for guest resources

The *current lender list* is a per-call spec state. `invoke a component function` establishes it for a JS-to-component call. Each instance lowered as a `borrow` during that call has its [[LendCount]] incremented and is appended to the list, which protects it from being dropped while lent. When the call returns, every [[LendCount]] in the list is decremented.

For a resource type `R` whose [abstract type](#abstract-and-transparent-types) is one of the component's type exports:

- `ToJSValue(rep, own<R>)`:
    1. Let |instance| be the surrounding component instance.
    1. Let |abstractTypeKey| be the *abstract type key* of |R|.
    1. Let |class| be |instance|.[[GuestResourceClasses]][|abstractTypeKey|].
    1. Return `create a guest resource instance` given |class|, |rep| and **true**.
- `ToJSValue(rep, borrow<R>)`:
    1. Assert: unreachable.
    1. This can only happen if an exported function returns a borrow, which is not allowed.
- `ToComponentValue(jsValue, own<R>)`:
    1. Let |instance| be the surrounding component instance.
    1. Let |abstractTypeKey| be the *abstract type key* of |R|.
    1. Let |class| be |instance|.[[GuestResourceClasses]][|abstractTypeKey|].
    1. If |jsValue| does not have a [[ResourceClass]] internal slot, or |jsValue|.[[ResourceClass]] is not |class|:
        1. Throw a `TypeError`.
    1. If |jsValue|.[[Rep]] is **empty**, or |jsValue|.[[Own]] is **false**, or |jsValue|.[[LendCount]] is not 0:
        1. Throw a `TypeError`.
    1. Let |rep| be |jsValue|.[[Rep]].
    1. Set |jsValue|.[[Rep]] to **empty**.
    1. Unregister |jsValue| from the [guest resource `FinalizationRegistry`](#guest-resource-finalizationregistry).
    1. Return |rep|.
- `ToComponentValue(jsValue, borrow<R>)`:
    1. Let |instance| be the surrounding component instance.
    1. Let |abstractTypeKey| be the *abstract type key* of |R|.
    1. Let |class| be |instance|.[[GuestResourceClasses]][|abstractTypeKey|].
    1. If |jsValue| does not have a [[ResourceClass]] internal slot, or |jsValue|.[[ResourceClass]] is not |class|:
        1. Throw a `TypeError`.
    1. If |jsValue|.[[Rep]] is **empty**:
        1. Throw a `TypeError`.
    1. Assert: a lender list is currently established.
    1. Increment |jsValue|.[[LendCount]].
    1. Append |jsValue| to the current lender list.
    1. Return |jsValue|.[[Rep]].

#### Guest resource FinalizationRegistry

There is an unexposed "guest resource `FinalizationRegistry`" created per-Realm of the WebAssembly namespace object. The callback for it invokes `drop a guest resource instance` with the held value.

TODO: the held value cannot be the instance itself, as registering an object with itself as the held value keeps it alive forever. The [[Rep]], [[Own]] and [[LendCount]] state needs to move into a separate record that the instance references and the registry holds.

To `drop a guest resource instance` given |resourceInstance|:
1. If |resourceInstance|.[[Rep]] is **empty** or |resourceInstance|.[[Own]] is **false**:
    1. Return **undefined**.
1. Let |class| be |resourceInstance|.[[ResourceClass]].
1. If |resourceInstance|.[[LendCount]] is not 0:
    1. Throw a `TypeError`.
1. Let |rep| be |resourceInstance|.[[Rep]].
1. Set |resourceInstance|.[[Rep]] to **empty**.
1. Unregister |resourceInstance| from the guest resource `FinalizationRegistry`.
1. Perform `drop a guest resource` given |class|.[[ResourceType]] and |rep|.
1. Return **undefined**.

The [[LendCount]] check can only fail on the `%Symbol.dispose%` path, because a lent instance is kept alive by the current lender list.

## Instantiation

To `instantiate a component` given |component|, a list of component definitions |imports|, and |hostResourceTypes|:
1. Let |instance| be the result of instantiating |component| with |imports|.
1. If instantiation traps:
    1. Throw a `WebAssembly.RuntimeError`.
1. Perform ? `create guest resource classes` given |instance|.
1. Let |exportsObject| be ? `create the exports object` given |instance|.
1. Return a Record whose [[ComponentInstance]] is |instance|, [[Exports]] is |exportsObject|, [[HostResourceTypes]] is |hostResourceTypes|, and [[GuestResourceClasses]] is |instance|.[[GuestResourceClasses]].

To `instantiate a component from an imports object` given |component|, |importsObject|, and |enabledBuiltins|:
1. Let |imports| and |hostResourceTypes| be ? `read the imports` given |component|, |importsObject|, and |enabledBuiltins|.
1. Return ? `instantiate a component` given |component|, |imports|, and |hostResourceTypes|.

### Read the imports object

The top-level `read the imports` algorithm walks the component's imports and resolves each to a JS value via property lookups on the |importsObject|, mirroring the core JS-API's algorithm of the same name.

The resolved JS values are then handed to the per-sort algorithms (`read the function import`, `read the type import`, and the rest) to produce the component definitions used during instantiation.

While walking, the algorithm recognizes the pattern of a resource type import accompanied by `[constructor]`, `[static]`, and `[method]` function imports tied to it. A resource type import is read first and looks for a constructor (see [resource types](#resource-types)). The tagged function imports then read from the constructor and its prototype directly. This allows the common case of importing a class to be satisfied by just passing the constructor.

Passing an exported component definition to a component import via the JS-API/ESM-integration is treated as if the import were a JS value. There is no "direct linking" that bypasses going through JS semantics. This is different from core wasm, where exported functions are linked directly when imported and have stricter type checks. This is intentional to prevent the implementation detail of how a JS function was implemented from leaking. Components can still be nested and directly linked inside a single component binary.

To `read the imports` given |component|, |importsObject|, and |enabledBuiltins|:
1. Let |hostResourceTypes| be an empty map from [abstract type key](#abstract-and-transparent-types) to [host resource type record](#host-resource-types-and-values).
1. If |component| has no imports:
    1. Return an empty list and |hostResourceTypes|.
1. Let |imports| be ? `read a scope of imports` given |component|.Imports, |importsObject|, |enabledBuiltins|, and |hostResourceTypes|.
1. Return |imports| and |hostResourceTypes|.

To `read a scope of imports` given a list of import declarations |importDecls|, |importsObject|, |enabledBuiltins|, and |hostResourceTypes|:
1. Let |definitions| be a new empty list.
1. For each |importDecl| of |importDecls|, in declaration order:
    1. Let |name| be `JSSpecifier`(|importDecl|).
    1. Let |staticReceiver| be **undefined**.
    1. Let |builtin| be `resolve a builtin specifier` given |name| and |enabledBuiltins|.
    1. If |builtin| is not **empty**:
        1. Let |importValue| be |builtin|.
    1. Else:
        1. If |importDecl|.Sort is **func** and |importDecl|.Name is tagged `[constructor]<R>`, `[method]([get]|[set])?<R>.<name>` or `[static]([get]|[set])?<R>.<name>`:
            1. Let |abstractTypeKey| be the *abstract type key* of |R|.
            1. Assert: |hostResourceTypes|[|abstractTypeKey|] exists. (Validation requires that declaration to precede this one in the same scope)
            1. Let |constructorFunction| be |hostResourceTypes|[|abstractTypeKey|].[[ConstructorObject]].
            1. If the tag is `[constructor]`:
                1. Let |importValue| be |constructorFunction|.
            1. Else if the tag is `[method]` or `[static]`:
                1. If the tag is `[static]`:
                    1. Let |lookupTarget| be |constructorFunction|.
                    1. Set |staticReceiver| to |lookupTarget|.
                1. Else:
                    1. Let |lookupTarget| to ? `Get`(|constructorFunction|, "prototype").
                    1. If `Type`(|lookupTarget|) is not Object:
                        1. Throw a `WebAssembly.LinkError`.

                1. If |importDecl|.Name is also tagged `[get]` or `[set]`:
                    1. Let |importValue| be ? `find an accessor` given |lookupTarget|, |name| and that annotation.
                1. Else:
                    1. Let |importValue| be ? `Get`(|lookupTarget|, |name|).
        1. Else:
            1. If `Type`(|importsObject|) is not Object:
                1. Throw a `TypeError`.

            1. If |importDecl|.Sort is **func** and |importDecl|.Name is tagged `[get]<name>` or `[set]<name>`:
                1. Set |staticReceiver| to |importsObject|.
                1. Let |importValue| be ? `find an accessor` given |importsObject|, |name| and that annotation.
            1. Else:
                1. Let |importValue| be ? `Get`(|importsObject|, |name|).
    1. Let |resolved| be ? `read an import` given |importDecl|, |importValue|, |staticReceiver| and |hostResourceTypes|.
    1. Append |resolved| to |definitions|.
1. Return |definitions|.

To `read an import` given |importDecl|, |importValue|, |staticReceiver| and |hostResourceTypes|:
1. Match |importDecl|.Sort:
    1. **core module**: return ? `read the core module import` given |importDecl|.ModuleType and |importValue|.
    1. **func**: return ? `read the function import` given |importDecl|.FuncType, |importValue|, |importDecl|.Name's tag and |staticReceiver|.
    1. **type**: return ? `read the type import` given |importDecl|, |importValue|, and |hostResourceTypes|.
    1. **value**: return ? `read the value import` given |importDecl|.ValType and |importValue|.
    1. **instance**: return ? `read the instance import` given |importDecl|.InstanceType, |importValue| and |hostResourceTypes|.
    1. **component**: return ? `read the component import` given |importDecl|.ComponentType and |importValue|.

To `read the core module import` given |coreModuleType| and |importValue|:
1. If |importValue| does not have a [[Module]] internal slot:
    1. Throw a `WebAssembly.LinkError`.
1. If the type of |importValue|.[[Module]] is not equal to |coreModuleType|:
    1. Throw a `WebAssembly.LinkError`.
1. Return |importValue|.[[Module]].

To `read the component import` given |componentType| and |importValue|:
1. If |importValue| does not have a [[Component]] internal slot:
    1. Throw a `WebAssembly.LinkError`.
1. If the type of |importValue|.[[Component]] is not a subtype of |componentType|:
    1. Throw a `WebAssembly.LinkError`.
1. Return |importValue|.[[Component]].

To `read the instance import` given |instanceType|, |importValue| and |hostResourceTypes|:
1. If `Type`(|importValue|) is not Object:
    1. Throw a `WebAssembly.LinkError`.
1. Let |definitions| be ? `read a scope of imports` given |instanceType|.Exports, |importValue|, an empty set of enabled builtins, and |hostResourceTypes|.
1. Return a component instance whose exports are |definitions|.

To `read the type import` given |importDecl|, |importValue|, and |hostResourceTypes|:
1. Let |abstractTypeKey| be the *abstract type key* of |importDecl|.
1. If |hostResourceTypes|[|abstractTypeKey|] exists:
    1. Return |hostResourceTypes|[|abstractTypeKey|].[[ComponentResourceType]].
1. If `IsCallable`(|importValue|) is **false**:
    1. Throw a `WebAssembly.LinkError`.
1. Let |destructor| be a host function that, given a host resource value, releases its reference to [[JSValue]] and returns.
1. Let |resourceType| be `create a resource type for host` given |destructor|.
1. Let |hostResourceType| be a new host resource type record whose [[ComponentResourceType]] is |resourceType| and [[ConstructorObject]] is |importValue|.
1. Set |hostResourceTypes|[|abstractTypeKey|] to |hostResourceType|.
1. Return |resourceType|.

To `find an accessor` given an object |target|, a property key |key| and |kind|, which is either `[get]` or `[set]`:
1. Let |object| be |target|.
1. Repeat, while |object| is not **null**:
    1. Let |desc| be ? |object|.[[GetOwnProperty]](|key|).
    1. If |desc| is not **undefined**:
        1. If `IsAccessorDescriptor`(|desc|) is **false**:
            1. Return **undefined**.
        1. If |kind| is `[get]`, return |desc|.[[Get]].
        1. Return |desc|.[[Set]].
    1. Set |object| to ? |object|.[[GetPrototypeOf]]().
1. Return **undefined**.

The walk stops at the first own property it finds, as an ordinary property access does. A data property that shadows an accessor further up the chain therefore resolves to **undefined** and becomes a `LinkError`.

To `read the function import` given |componentFuncType|, |importValue|, |importNameTag| and |staticReceiver|:
1. If `IsCallable`(|importValue|) is **false**:
    1. Throw a `WebAssembly.LinkError`.
1. If |importNameTag| is `[constructor]<R>` and `IsConstructor`(|importValue|) is **false**:
    1. Throw a `WebAssembly.LinkError`.
1. Let |callable| be |importValue|.

1. Let |callKind|, |receiverRule| and |paramOffset| be determined by |importNameTag|:
    1. `[constructor]<R>`: `Construct`, no receiver, offset 0.
    1. `[method]`-tagged: `Call`, receiver is component argument 0 (the `borrow<R>` self), offset 1.
    1. `[static]`-tagged: `Call`, receiver is |staticReceiver|, offset 0.
    1. no-tag: `Call`, receiver is |staticReceiver|, offset 0.
1. Let |paramTypes| be |componentFuncType|.Params.
1. Let |resultType| be |componentFuncType|.Result.
1. If |resultType| is a `result`:
    1. Let |okType| be its `ok` payload type, or **empty** if it has none.
    1. Let |errorType| be its `error` payload type, or **empty** if it has none.
    1. Let |throwing| be **true**.
1. Else:
    1. Let |okType| be |resultType|, or **empty** if |componentFuncType| has no result.
    1. Let |throwing| be **false**.
1. Return a component host function of type |componentFuncType| whose body, given component arguments « |v_0|, ..., |v_{n-1}| » where |n| is |paramTypes|.length, performs:
    1. Let |args| be a new empty List.
    1. For each i in [|paramOffset|, |n|):
        1. Append `ToJSValue`(|v_i|, |paramTypes|[i]) to |args|.
    1. If |callKind| is `Construct`:
        1. Let |completion| be `Construct`(|callable|, |args|).
    1. Else:
        1. If |receiverRule| is "component argument 0":
            1. Let |thisArg| be `ToJSValue`(|v_0|, |paramTypes|[0]).
        1. Else:
            1. Let |thisArg| be |receiverRule|.
        1. Let |completion| be `Call`(|callable|, |thisArg|, |args|).
    1. If |completion| is an abrupt completion:
        1. If |throwing| is **false**:
            1. Trap.
        1. If |errorType| is **empty**:
            1. Return `result.error`.
        1. Let |errorValue| be `ToComponentValue`(|completion|.[[Value]], |errorType|).
        1. If that throws:
            1. Trap.
        1. Return `result.error(|errorValue|)`.
    1. If |okType| is **empty**:
        1. If |throwing| is **true**:
            1. Return `result.ok`.
        1. Return with no result.
    1. Let |componentResult| be `ToComponentValue`(|completion|.[[Value]], |okType|).
    1. If that throws:
        1. Trap.
    1. If |throwing| is **true**:
        1. Return `result.ok(|componentResult|)`.
    1. Else:
        1. Return |componentResult|.

To `read the value import` given |componentValType| and |importValue|:
1. Return ? `ToComponentValue`(|importValue|, |componentValType|).

### Builtin imports

The component JS-API can provide builtins to imports just as the core JS-API does.

Builtin imports are opt-in via the `builtins` field of `WebAssemblyCompileOptions` when used in the JS-API. [ESM-integration](#webassembly-esm-integration) enables all builtins by default.

This spec defines one builtin specifier:

| Specifier | Resolves to |
|---|---|
| `wasm:js/global` | [the global object](#the-global-object) |

To `resolve a builtin specifier` given a String |specifier| and a set of Strings |enabledBuiltins|:
1. If |specifier| does not start with "wasm:":
    1. Return **empty**.
1. Let |name| be the portion of |specifier| after "wasm:".
1. If |name| is not in |enabledBuiltins|:
    1. Return **empty**.
1. If |name| is "js/global":
    1. Return the [conversion realm](#types-and-values)'s global object.
1. Return **empty**.

#### The global object

`wasm:js/global` can be used to import JS/web APIs off of the global object. It simply resolves to the `globalThis` of the [conversion realm](#types-and-values), and then the normal [`read the imports`](#read-the-imports-object) rules can take it from there.

### Create the exports object

The `create the exports object` algorithm walks the component's exports and builds a fresh JS object whose properties are the exports.

Exported resource types become [guest resource classes](#guest-resource-classes) named `JSName`(|export|), and tagged function exports are mapped onto them just as in `read the imports`:
- `[constructor]<R>`: the function becomes `R`'s constructor behaviour. Names are strongly-unique, so there can only be one.
- `[method]<R>.<name>`: the function becomes a method named `JSName`(|export|) on `R.prototype`.
- `[static]<R>.<name>`: the function becomes a static method named `JSName`(|export|) on `R`.
- `[method][get]<R>.<name>` and `[method][set]<R>.<name>`: the functions become the getter and setter of an accessor property named `JSName`(|export|) on `R.prototype`.
- `[static][get]<R>.<name>` and `[static][set]<R>.<name>`: the same, but on `R`.

A `[get]` or `[set]` export that is not attached to a resource type becomes an accessor property on the exports object itself. All other exported component definitions are given JS definitions named `JSName`(|export|) on the exports object.

To `create guest resource classes` given a component instance |componentInstance|:
1. Let |guestResourceClasses| be an empty map from [abstract type key](#abstract-and-transparent-types) to [guest resource class](#guest-resource-classes).
1. Let |component| be |componentInstance|.[[Component]].
1. For each type export |export| of |component|'s type, in declaration order, recursing into exported instances:
    1. Let |abstractTypeKey| be the *abstract type key* of |export|.
    1. If |abstractTypeKey| is one of |component|'s type imports:
        1. Throw a `TypeError`.
    1. If |guestResourceClasses|[|abstractTypeKey|] exists:
        1. Continue.
    1. Let |resourceType| be the component resource type |export| refers to in |componentInstance|.
    1. Let |arity| be the parameter count of the `[constructor]` export targeting |export|, or 0 if there is none.
    1. Let |class| be `create a guest resource class` given |componentInstance|, |resourceType|, `JSName`(|export|) and |arity|.
    1. Set |guestResourceClasses|[|abstractTypeKey|] to |class|.
1. Set |componentInstance|.[[GuestResourceClasses]] to |guestResourceClasses|.

To `create the exports object` given a |componentInstance|:
1. Let |exportsObject| be `OrdinaryObjectCreate`(**null**).
1. For each |export| of |componentInstance|.Exports, in declaration order:
    1. If |export|.Name is tagged `[constructor]<R>`, `[method]<R>.<name>` or `[static]<R>.<name>`, with or without a `[get]` or `[set]` annotation:
        1. Continue.
    1. If |export|.Name is tagged `[get]<name>` or `[set]<name>`:
        1. Perform `define an accessor for a component function` given |exportsObject|, |export| and **true**.
        1. Continue.
    1. Let |key| be `JSName`(|export|).
    1. Match |export|.Sort:
        1. **core module**:
            1. Let |value| be a new `Module` whose [[Module]] is |export|.Module.
        1. **type**:
            1. Let |abstractTypeKey| be the *abstract type key* of |export|.
            1. Let |value| be |componentInstance|.[[GuestResourceClasses]][|abstractTypeKey|].
        1. **func**:
            1. Let |value| be `create a JS function for a component function` given |export|.Func, |key| and no tag.
        1. **value**:
            1. Let |value| be `ToJSValue`(|export|.Value, |export|.Type).
        1. **instance**:
            1. Let |value| be ? `create the exports object` given the exported instance.
        1. **component**:
            1. Let |value| be a new `Component` whose [[Component]] is |export|.Component.
    1. Perform `CreateDataPropertyOrThrow`(|exportsObject|, |key|, |value|).
1. Perform `SetIntegrityLevel`(|exportsObject|, "frozen").
1. Return |exportsObject|.

To `create a JS function for a component function` given |componentFunc|, |name| and |exportNameTag|:
1. Let |paramOffset| be 1 if |exportNameTag| is tagged `[method]`, else 0.
1. If |componentFunc|.Result is a `result`:
    1. Let |okType| be its `ok` payload type, or **empty** if it has none.
1. Else:
    1. Let |okType| be |componentFunc|.Result, or **empty** if |componentFunc| has no result.
1. Return a built-in function object with name |name| and length |componentFunc|.Params.length - |paramOffset|, whose behaviour, given a **this** value |thisValue| and JS arguments |args|, performs:
    1. Let |componentResult| be ? `invoke a component function` given |componentFunc|, |exportNameTag|, |thisValue| and |args|.
    1. If |okType| is **empty**:
        1. Return **undefined**.
    1. Return `ToJSValue`(|componentResult|, |okType|).

To `define an accessor for a component function` given an object |target|, a function export |export| and a Boolean |enumerable|:
1. Let |key| be `JSName`(|export|).
1. Let |prefix| be "get " if |export|.Name is tagged `[get]`, and "set " otherwise.
1. Let |name| be the string-concatenation of |prefix| and |key|.
1. Let |func| be `create a JS function for a component function` given |export|.Func, |name|, and |export|'s tag.
1. If |export|.Name is tagged `[get]`:
    1. Perform `DefinePropertyOrThrow`(|target|, |key|, PropertyDescriptor { [[Get]]: |func|, [[Set]]: **undefined**, [[Enumerable]]: |enumerable|, [[Configurable]]: **true** }).
1. Else:
    1. Perform `DefinePropertyOrThrow`(|target|, |key|, PropertyDescriptor { [[Set]]: |func| }).

The `[set]` case defines a partial descriptor, so it only replaces the [[Set]] field of the func property the matching `[get]` export already defined. The `"get "`/`"set "` prefix on the function name follows how JS names accessor functions.

To `invoke a component function` given |componentFunc|, |exportNameTag|, |thisValue| and a List of JS values |args|:
1. Let |paramTypes| be |componentFunc|.Params.
1. Let |resultType| be |componentFunc|.Result.
1. Let |paramOffset| be 1 if |exportNameTag| is tagged `[method]`, else 0.
1. If |resultType| is a `result`:
    1. Let |okType| be its `ok` payload type, or **empty** if it has none.
    1. Let |errorType| be its `error` payload type, or **empty** if it has none.
    1. Let |throwing| be **true**.
1. Else:
    1. Let |okType| be |resultType|, or **empty** if |componentFunc| has no result.
    1. Let |throwing| be **false**.
1. If the number of |args| is less than |paramTypes|.length - |paramOffset|:
    1. Throw a `TypeError`.
1. Let |lenders| be a new empty List.
1. Let |previousLenders| be the current lender list.
1. Set the current lender list to |lenders|.
1. Once the remaining steps complete, either normally or abruptly, perform:
    1. Decrement the [[LendCount]] of every instance in |lenders|.
    1. Set the current lender list to |previousLenders|.
1. Let |values| be a new empty List.
1. If |paramOffset| is 1:
    1. Append ? `ToComponentValue`(|thisValue|, |paramTypes|[0]) to |values|.
1. For each i in [0, |paramTypes|.length - |paramOffset|): append ? `ToComponentValue`(|args|[i], |paramTypes|[i + |paramOffset|]) to |values|.
1. Let |componentResult| be the result of invoking |componentFunc| with |values|.
1. If the call traps:
    1. Throw a `WebAssembly.RuntimeError`.
1. If |throwing| is **true** and |componentResult| is `result.error(|e|)`:
    1. Throw `create a component error` for |e| and |errorType|.
1. If |okType| is **empty**:
    1. Return **empty**.
1. If |throwing| is **true**:
    1. Return the `result.ok` payload of |componentResult|.
1. Else:
    1. Return |componentResult|.

To `create a component error` for an optional component value |e| and component type |errorType|:
1. If |errorType| is **empty**:
    1. Let |payload| be **undefined**.
1. Else:
    1. Let |payload| be `ToJSValue`(|e|, |errorType|).
1. Return a new `ComponentError` whose `data` is |payload| and whose `message` is implementation-defined.

## WebAssembly ESM-integration

[ESM-integration](https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration) extends to components. The module loader branches on the `layer` field of the binary to decide whether the bytes decode as a module or a component, so a component can be loaded anywhere a module can be today.

Each component import has a [module specifier](https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ModuleSpecifier) given by `JSSpecifier`(|decl|).

Which binding of the resolved module the component receives depends on the import's type:

| Import type | JS equivalent | Value |
|---|---|---|
| bare type, function, value | `import v from "JSSpecifier(|decl|)"` | the [default export](https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-ImportedDefaultBinding) |
| instance | `import { a, b } from "JSSpecifier(|decl|)"` | one [named import](https://tc39.es/ecma262/multipage/ecmascript-language-scripts-and-modules.html#prod-NamedImports) per untagged export of the instance type, named `JSName` of that export |
| core module, component | `import source M from "JSSpecifier(|decl|)"` | the module source, as a `Module` or `Component` |

Reading the imports snapshots the resolved values, and so components cannot participate in cycles. This matches how core modules work today with ESM-integration.

Each resolved value is handed to [`read an import`](#read-the-imports-object) and the resulting definitions are passed to [`instantiate a component`](#instantiation).

A component's exports become the bindings of its module namespace object. There is one binding per `JSName`(|export|), holding what [`create the exports object`](#create-the-exports-object) puts under that name, and no `default` binding.

## Follow ups

1. How to dynamically pass a union value? Statically passing a single case of the union works, but not dynamic choice.
1. How to import multiple overloads of a function? Can we just use `external-id`?
1. How to support class inheritance and casting?
1. Do we support a reference equality protocol? `ToJSValue` creates a fresh resource instance per lift, so two `borrow`s of one component-defined resource are two JS objects that do not compare equal. Reps are opaque and reusable after a drop, so an identity map would need careful invalidation.
1. Do we let a JS constructor supply its own brand check?
1. Should a `[get]`/`[set]` import fall back to a `Get`/`Set` on the target when the property is not an accessor? That would let data properties, `Proxy` traps and module namespace bindings satisfy a property import.
1. How does a component feature test an import?
1. How does a component pass one of its own functions to a JS callback, e.g. `add-event-listener`?
1. What is the precise timing of `Get`/`Set` during lifting/lowering if a wasm trap happens.
1. Top-level await, and async start functions.
