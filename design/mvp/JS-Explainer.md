# WebAssembly Components JS-API Explainer

This explainer describes how WebAssembly Components (hereafter 'components' and _not_ [web components](../high-level/FAQ.md#how-do-webassembly-components-relate-to-web-components)) can be used from JS in supported runtimes.

See the [reference](./JS-Reference.md) for an in-depth walkthrough.

**This is a draft and is not complete.**

## Walkthrough

### Components that export a function

Let's start with a component that imports nothing:

```wat
(component
  ...
  (export "greet"
    (func (param "who" string) (result string))
  )
)
```

Given the above component (compiled from the WAT text format to the [binary](./Binary.md) format), you can execute it with:

```js
const { instance } = await WebAssembly.instantiate(bytes);

instance.exports.greet("world");  // "hello, world"
```

The `exports` property of an instance holds one property per export and `greet` is an ordinary JS function

Component names are kebab-case and JS function names are [camelCase](./JS-Reference.md#names), so a function export named `greet-loudly` would be `greetLoudly`.

Arguments are coerced to their expected type, and if that fails a `TypeError` is thrown:

```js
instance.exports.greet(42);  // "hello, 42"
instance.exports.greet();    // TypeError
```

`undefined` is substituted for missing arguments, and extra arguments are ignored, just as in JS.

### Components that import a function

Now a component that imports:

```wat
(component
  (import "log"
    (func (param "message" string))
  )
  ...
  (export "run" (func))
)
```

The import `log` must be a JS callable object, and will be called with a JS String.

We can provide the `console.log` builtin as here:

```js
const imports = { log: console.log };

const { instance } =
  await WebAssembly.instantiate(bytes, imports);

instance.exports.run();  // logs "hello"
```

Or provide a custom implementation:

```js
const lines = [];
const log = (message) => { lines.push(message); };
const imports = { log };

const { instance } =
  await WebAssembly.instantiate(bytes, imports);
```

### Values at a glance

Components and JS maintain separate type/value systems, so any value crossing the boundary needs a defined translation in both directions.

The following table describes how a component value is converted into a JS value.

| Component type | JS type |
|---|---|
| `bool` | Boolean |
| `s8`-`s32`, `u8`-`u32` | Number, an exact integer |
| `s64`, `u64` | BigInt |
| `f32`, `f64` | Number, including NaN and infinities |
| `char` | String of exactly one Unicode scalar value |
| `string` | String, well formed |
| `list<u8>` | `Uint8Array` |
| `list<T>`, `list<T, N>`, `tuple<T, U>` | Array |
| `record { field-name: T, ... }` | null-prototype object, `{ fieldName: T, ... }` |
| `flags "flag-a" "flag-b"` | null-prototype object of Booleans, `{ flagA: bool, flagB: bool }` |
| `enum "case-a" "case-b"` | String, the case label verbatim |
| `option<T>` (if `T` is not `option`) | `null`, or the payload |
| `option<option<T>>` | treated as variant, see below |
| `result<T, E>` (if in return position of function) | if `E` { thrown as a `WebAssembly.ComponentError` } else { `T` } |
| `variant` | `{ kind: string, value: T }` |
| `map<K, V>` | `Map` |
| `own<R>`, `borrow<R>` | the original JS value for an imported resource type, an instance of its class for an exported one |
| `future<T>`, `stream<T>`, `error-context` | not yet specified |

Converting a JS value to a component value accepts all of the above, but also has additional coercions. See [ToJSValue](./JS-Reference.md#tojsvalue) and [ToComponentValue](./JS-Reference.md#tocomponentvalue) for detailed algorithms.

### Loading with ESM

[ESM-integration](https://github.com/WebAssembly/esm-integration/tree/main/proposals/esm-integration) extends to components. The loader branches on the `layer` field of the binary, so a component loads anywhere a core module does today.

Each component import becomes a JS import, and its module specifier is the import's [`external-id`](Explainer.md#import-and-export-definitions) if it has one and its name otherwise:

```wat
(component
  (import "slugify"
    (external-id
      "https://esm.unpkg.com/slugify@1.6.6")
    (func (param "text" string) (result string))
  )
  ...
  (export "run" (func))
)
```

```html
<script type="module">
  import { run } from "./component.wasm";

  // calls the default export of `https://esm.unpkg.com/slugify@1.6.6`
  run();
</script>
```

### Handling expected errors using `result`

Component functions signal failure using a `result<T, E>` value:
  1. Exported component functions that return an error `result` throw JS exceptions.
  1. Imported JS functions that throw JS exceptions are captured as a `result`.

An imported JS function that throws where the component asked for a plain return type results in a trap.

```wat
(component
  (import "lookup"
    (func (param "key" string) (result string (error string)))
  )
  ...
  (export "parse"
    (func (param "text" string) (result u32 (error string)))
  )
)
```

`parse` tries to parse its `text` argument as an integer, and if that fails performs a fallible lookup.

```js
const imports = {
  lookup: (key) => { throw `no such key: ${key}`; },
};
const { instance } =
  await WebAssembly.instantiate(bytes, imports);

instance.exports.parse("42");  // 42

try {
  instance.exports.parse("$name");
} catch (e) {
  e instanceof WebAssembly.ComponentError;  // true
  e.data;                                   // "no such key: $name"
}
```

In the second call, parsing fails and leads to a call to `lookup` which throws a JS exception. This is converted to a `result` and consumed by the component. The component then propagates it to the original JS caller as a thrown `ComponentError` carrying the original message.

### Handling unexpected failures with lockdown

In the case a component is executing and traps, the trap is surfaced as a `WebAssembly.RuntimeError` (as in core wasm), and then the component is locked down to prevent future execution. If an exported function from the component is invoked again, it immediately results in another trap.

```js
import { buggyFunction, normalFunction } from "component.wasm"

// normalFunction doesn't trap
normalFunction();

try {
  // Calling buggyFunction traps and locks down the component.
  buggyFunction()
} catch (err) {
  assert(err instanceof WebAssembly.RuntimeError);
  try {
    // Calling normalFunction again leads to a lockdown trap.
    normalFunction();
  } catch (err) {
    assert(err instanceof WebAssembly.RuntimeError);
  }
}
```

### Importing JS values as resource types

Components can also accept JS values as resources. A resource type import is satisfied by passing a constructor function.

Whenever a JS value must be converted to a resource type, an `instanceof` check is performed against the imported constructor. If the constructor is a [WebIDL interface object](https://webidl.spec.whatwg.org/#interface-object) or an [exported component resource constructor](#exporting-a-resource), a precise [brand check](./JS-Reference.md#brand-checks) is performed.

Any imported function whose name is tagged `[constructor]`, `[method]`, or `[static]` is looked up on the imported constructor instead of the imports object:

| name | import lookup |
|---|---|
| `[constructor]R` | `R` |
| `[method]R.M` | `R.prototype.M` |
| `[static]R.S` | `R.S` |

The above allows most JS classes to be imported as a resource by just passing the constructor function:

```wat
(component
  (import "element"
    (type $element (sub resource))
  )
  (import
    "[method]element.query-selector"
    (func
      (param "self" (borrow $element))
      (param "selectors" string)
      (result (option (own $element)))
    )
  )
  (import "[method]element.get-attribute"
    (func
      (param "self" (borrow $element))
      (param "name" string)
      (result (option string))
    )
  )
  ...
  (export "find"
    (func
      (param "root" (borrow $element))
      (param "selectors" string)
      (result (option string))
    )
  )
)
```

```js
const imports = { element: Element };
const { instance } =
  await WebAssembly.instantiate(bytes, imports);

instance.exports.find(document.body, "h1");  // "page-title" or null
```

Component [`plainnames`](./Explainer.md#import-and-export-definitions) as used in imports/exports are converted to idiomatic JS names ([rules here](./JS-Reference.md#names)). Type names are converted to pascal case, and everything else is converted to camel case. This allows the component imports of  `element` and `get-attribute` to be satisfied with `Element` and `getAttribute` respectively.

### Importing from the JS global

The example above still needs someone to write `{ element: Element }`. A component can skip that and take its imports straight from the global object by importing `wasm:js/global`:

```wat
(component
  (import "wasm:js/global"
    (instance $g
      (export "btoa"
        (func (param "data" string) (result string))
      )

      (export "element" (type $element (sub resource)))
      (export "[method]element.get-attribute"
        (func
          (param "self" (borrow $element))
          (param "name" string)
          (result (option string))
        )
      )
    )
  )
  (alias export $g "element" (type $el))

  ...

  (export "encode-id"
    (func
      (param "el" (borrow $el))
      (result (option string))
    )
  )
)
```

```js
const exports =
  await WebAssembly.instantiate(bytes, { builtins: ["js/global"] }).exports;

exports.encodeId(document.body);
```

Importing from `wasm:js/global` is equivalent to an imports object with: `{ "wasm:js/global": globalThis }`. The normal rules for reading from the imports object still apply.

ESM-integration defaults to enabling `js/global` in the compile options (the `wasm:` prefix is implicit) which allows a component to import and use web APIs without any glue code:

```html
<script type="module">
  import { encodeId } from "./component.wasm";
  encodeId(document.body);
</script>
```

### Exporting a resource

A resource type exported from a component becomes a JS class:

```wat
(component
  ...

  (export "counter" (type $counter (sub resource)))
  (export "[constructor]counter"
    (func (result (own $counter)))
  )
  (export "[method]counter.increment-once"
    (func
      (param "self" (borrow $counter))
      (result u32)
    )
  )
)
```

```js
const { instance } = await WebAssembly.instantiate(bytes);
const { Counter } = instance.exports;

let c = new Counter();
c.incrementOnce();  // 1
c.incrementOnce();  // 2
```

As in the importing a resource case above, component names are converted to JS names. This allows an export of `counter` to become a JS class named `Counter`, and `increment-once` to become `incrementOnce`.

## Status

The following have no binding yet:
- Component model async features such as `async` functions, `future`, `stream`.
- `error-context`.

Everything else we know to be open is collected in the reference's [follow ups](./JS-Reference.md#follow-ups).
