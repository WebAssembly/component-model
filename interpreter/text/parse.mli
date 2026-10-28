open Putil

type 'a start =
  | Component : (Ast.VarAst.component perhaps_named) start
  | Script : Script.script start

exception Syntax of Wasm.Source.region * string

val parse : string -> Lexing.lexbuf -> 'a start -> 'a (* raises Syntax *)

val string_to_script : string -> Script.script (* raises Syntax *)
val string_to_component : string -> Ast.VarAst.component (* raises Syntax *)
