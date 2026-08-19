# WebAssembly Components JS-API Explainer

This explainer describes how WebAssembly Components (hereafter 'components') can be used from JS.

See the [reference](./JS-Reference.md) for an in-depth walkthrough.

**This is a draft and is not complete. Major details are unresolved. See "Status" at the end.**

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

A. Define bindings between components and JS - components transitively have access to web API's through the pre-existing JS-WebIDL bindings.
B. (A) and also define bindings between components and WebIDL - components get a separate direct path to web API's.
C. Define bindings between components and WebIDL - components transitively have access to JS through the pre-existing JS-WebIDL bindings.

There are pros/cons to each. Let's go through them.

### A. Define only bindings between Components and JS

This is the smallest step from where we are today. A component's imports and exports are described in terms of JS values, and the web platform is reached the same way JS reaches it.

Goals #1, #2 and #3 mostly fall out for free. Web API's are already exposed to JS, so importing one is just importing the JS function that reflects it, and exporting to JS is given by the binding. Feature testing, polyfilling and API evolution are all properties the WebIDL-JS binding already supports, so they keep working without us specifying anything new.

The objection to A has always been goal #4. If a call into a web API is defined as a call through JS, JS semantics are observable at every step. Lookups on the global object and on prototypes can be intercepted, argument coercion can run user code through `valueOf`, `toString` and iterators, and the callee may be a Proxy. An engine can try to speculate these away, but that is not always easy.

### B. Define bindings between Components and JS and also Components and WebIDL

This is a superset of option A, so it inherits the pros/cons of that.

In addition, we add a parallel binding between components and WebIDL to get goal #4 as well. Components that only need to talk to JS use the JS binding, and components that use web API's use the WebIDL binding.

The cost is that we write and maintain two bindings, and they have to harmonize.

### C. Define only bindings between Components and WebIDL

JS already has well-defined bindings to WebIDL. If we define bindings from components to WebIDL, we get direct and efficient access to web API's (goal #4) and transitively get access to JS (goals #1 and #2).

Like A we only have one specification to draft and maintain.

The cost is goal #3. Feature testing, polyfills and API evolution are all things A inherits and C has to reinvent, and that is new conceptual ground.

### Conclusion

We should take option A. Its one disadvantage against C was goal #4, and we believe that we can work around that by carefully writing value conversion rules so that engines can fuse conversion from component values to WebIDL without any speculation.

## Walkthrough

### A greeter

Start with a component that imports nothing:

```wit
package example:greeter;

world greeter {
  export greet: func(name: string) -> string;
}
```

```js
const { instance } = await WebAssembly.instantiate(bytes);

instance.exports.greet("world");  // "hello, world"
```

`exports` holds one property per export and `greet` is an ordinary function. Component names are kebab-case and JS names are camelCase, so an export named `greet-loudly` would be `greetLoudly`.

Arguments are converted rather than type checked, the way a WebIDL operation converts its own:

```js
instance.exports.greet(42);  // "hello, 42"
instance.exports.greet();    // TypeError
```

Passing too few arguments is a `TypeError`. Extra arguments are ignored.

### A logger

Now a component that imports:

```wit
package example:logger;

world logger {
  import log: func(message: string);
  export run: func();
}
```

```js
const { instance } = await WebAssembly.instantiate(bytes, { log: console.log });

instance.exports.run();  // logs "hello"
```

The component's `message` becomes a String and we call `log` with it. Nothing inspects what `log` is, so any callable does, and a polyfill is as good as the real thing:

```js
const lines = [];
const log = (message) => { lines.push(message); };

const { instance } = await WebAssembly.instantiate(bytes, { log });
```

Which means feature testing is just JS, done before instantiating:

```js
const log = globalThis.console?.log ?? myPolyfill;
```

### When a call fails

A `result<T, E>` return is not handed to JS as a value. On the way out it throws, and on the way in a thrown value is caught:

```wit
package example:parse;

world parser {
  import lookup: func(key: string) -> result<string, string>;
  export parse: func(text: string) -> result<u32, string>;
}
```

```js
const { instance } = await WebAssembly.instantiate(bytes, {
  lookup: (key) => { throw `no such key: ${key}`; },
});

instance.exports.parse("42");  // 42

try {
  instance.exports.parse("$name");
} catch (e) {
  e instanceof WebAssembly.ComponentError;  // true
  e.payload;                                // "no such key: name"
}
```

`payload` is the `E` value converted to JS. In the other direction the thrown JS value is converted to `E`, so `lookup` returns `result.error("no such key: name")` and the component is free to handle it instead of propagating it.

An import that throws where the component asked for a plain return type has nowhere to put the error, and traps.

### Importing a resource

Components see JS objects as resources. A resource type import and the functions on it are satisfied by a single JS value, the constructor:

```wat
(component
  (import "element" (type $element (sub resource)))
  (import "[method]element.query-selector" (func
    (param "self" (borrow $element)) (param "selectors" string)
    (result (option (own $element)))))
  (import "[method]element.get-attribute" (func
    (param "self" (borrow $element)) (param "name" string)
    (result (option string))))
  (export "find" (func
    (param "root" (borrow $element)) (param "selectors" string)
    (result (option string))))
)
```

```js
const { instance } = await WebAssembly.instantiate(bytes, { element: Element });

instance.exports.find(document.body, "h1");  // "page-title" or null
```

`Element` covers the type and both methods. The type import checks for `@@isWasmResourceOf`, and the methods are read off `Element.prototype` under their camelCase names, which is where JS finds them too.

Because `find` takes a `borrow` of the *imported* type, JS keeps passing raw elements. Passing anything else fails the same brand check and is a `TypeError`, and `option<string>` comes back as `null`.

### Exporting a resource

A resource a component defines and exports becomes a class:

```wit
package example:counter;

world w {
  export api: interface {
    resource counter {
      constructor();
      increment: func() -> u32;
    }
  }
}
```

```js
const { instance } = await WebAssembly.instantiate(bytes);
const { Counter } = instance.exports.api;

using c = new Counter();
c.increment();  // 1
c.increment();  // 2
```

Type names are PascalCase, so `counter` is `Counter`. `new` runs the component's `constructor`, methods live on `Counter.prototype`, and `Symbol.dispose` drops the handle. Dropping is what runs the component's destructor, so a `Counter` nobody disposes is dropped when it is collected, through a `FinalizationRegistry`.

A `borrow` the component hands out is different: it is only valid for the duration of the call it appeared in, and using it afterwards is a `TypeError`.

### Loading with ESM

[ESM-integration](https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration) extends to components. The loader branches on the `layer` field of the binary, so a component loads anywhere a module does today.

Each component import becomes a JS import, and its module specifier is the import's [`external-id`](Explainer.md#import-and-export-definitions) if it has one and its name otherwise:

```wit
world my-component {
  @external-id("https://esm.unpkg.com/slugify@1.6.6")
  import slugify: func(text: string) -> string;
}
```

## Values at a glance

| Component type | JS |
|---|---|
| `bool` | Boolean |
| `s8`-`s32`, `u8`-`u32` | Number, an exact integer |
| `s64`, `u64` | BigInt |
| `f32`, `f64` | Number, including NaN and infinities |
| `char` | String of exactly one Unicode scalar value |
| `string` | String, well formed |
| `list<u8>` | `Uint8Array` |
| `list<T>`, `list<T, N>`, `tuple<T, U>` | Array |
| `record { a-b: T }` | null-prototype object, `{ aB }` |
| `flags "a" "b"` | null-prototype object of Booleans, `{ a, b }` |
| `enum "a" "b"` | String, the label verbatim |
| `option<T>` | `null`, or the payload |
| `variant`, `option<option<T>>` | `{ kind, value }` |
| `result<T, E>` | thrown and caught in return position, else `{ kind, value }` |
| `map<K, V>` | `Map` |
| `own<R>`, `borrow<R>` | the value the type import was given, or an instance of its class |
| `future<T>`, `stream<T>`, `error-context` | not yet specified |

Conversions in are looser than conversions out, in the same places WebIDL's are. A `record` takes any object with the right own properties, a `list` takes an Array or any iterable, and a `map` takes a `Map`, an iterable of pairs, or a plain object when `K` is `string`. See [ToJSValue](./JS-Reference.md#tojsvalue) and [ToComponentValue](./JS-Reference.md#tocomponentvalue).

## Status

- `future`, `stream` and `error-context` have no binding yet, and neither do async start functions or top-level await.

Everything else we know is open is collected in the reference's [open questions](./JS-Reference.md#open-questions).
