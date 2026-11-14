type var = string Wasm.Source.phrase

type definition = definition' Wasm.Source.phrase
and definition' =
  | Textual of Ast.VarAst.component
  | Encoded of string * string
  | Quoted of string * string
type assertion = assertion' Wasm.Source.phrase
and assertion' =
  | AssertInvalid of definition * string
  | AssertMalformed of definition * string
type command = command' Wasm.Source.phrase
and command' =
  | Assertion of assertion
  | Component of Ast.Var.binder * definition
  | Meta of meta
and meta = meta' Wasm.Source.phrase
and meta' =
  | Input of var option * string
  (*  | Output of var option * string option*)
  | Script of var option * script
and script = command list

exception Syntax of Wasm.Source.region * string
