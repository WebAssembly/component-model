open Wasm.Source

type var = Ast.var
type 'a perhaps_named = Ast.Var.binder * 'a

(* Error handling *)

let error at msg = raise (Script.Syntax (at, msg))

(*let parse_error msg =
  error Source.no_region
    (if msg = "syntax error" then "unexpected token" else msg)*)

(* Position handling *)

let convert_pos pos =
  { file = pos.Lexing.pos_fname;
    line = pos.Lexing.pos_lnum;
    column = pos.Lexing.pos_cnum - pos.Lexing.pos_bol
  }

let region lexbuf =
  let left = convert_pos (Lexing.lexeme_start_p lexbuf) in
  let right = convert_pos (Lexing.lexeme_end_p lexbuf) in
  {left = left; right = right}

let span_regions left right =
  { left = left.left; right = right.right }

let position_to_pos position =
  { file = position.Lexing.pos_fname;
    line = position.Lexing.pos_lnum;
    column = position.Lexing.pos_cnum - position.Lexing.pos_bol
  }

let positions_to_region position1 position2 =
  { left = position_to_pos position1;
    right = position_to_pos position2
  }

let ptr x y = positions_to_region x y
