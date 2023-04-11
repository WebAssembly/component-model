# HTTP And Handles Example

This example demonstrates the different types of handles as they would show up
in an HTTP interface.

TODO:
* incomplete
* not using `future`/`stream` or manually async
* See wasi-http for real proposal.

```wit
package wasi:http

world proxy {
  import handler
  export handler
}
```
TODO:
* explain basic structure

```wit
interface handler {
  use types.{request, response}
  handle: func(request) -> result<response>
}
```
TODO:
* explain `own`

```wit
interface types {
  use wasi:io/streams.{input-stream, output-stream}

  resource fields {
    get: func(key: string) -> list<string>
    ...
  }
  type headers = fields
  type trailers = fields
}
```
TODO:
* show `get` method expansion into `borrow`

```wit
interface types {
  // ... continued

  resource request {
    constructor(headers, output-stream, ...)
    headers: func() -> child use<headers>
    consume: func() -> child input-stream
    ...
  }

  resource response { ... }
}
```
TODO:
* explain `child`
* maybe model the whole `incoming-body` using `consume`?


[WASI HTTP]: https://github.com/webAssembly/wasi-http
