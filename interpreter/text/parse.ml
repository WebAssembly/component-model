open Putil

type 'a start =
  | Component : (Ast.VarAst.component perhaps_named) start
  | Script : Script.script start

exception Syntax = Wasm.Script.Syntax

(*

  A lexbuf structure has these members:
  - refill: a function which can be called to get more valid bytes
  - lex_buffer: a buffer with a bunch of bytes in it
  - lex_buffer_len: the index into lex_buffer of the last valid byte of data
    within it
  - lex_abs_pos: the absolute position in the stream of index 0 of the
    lex_buffer
  - lex_start_pos: the index of the first valid byte of data in lex_buffer
  - lex_curr_pos: ??? index between lex_start_pos and lex_buffer_len
  - lex_last_pos: ??? index between lex_start_pos and lex_buffer_len
  - lex_last_action: ???
  - lex_eof_reached:
  - lex_mem: ??? indices between lex_start_pos and lex_buffer_len
  - lex_start_p:
  - lex_curr_p:
 *)

type backtracking_lexbuf = {
    bt_lexbuf : Lexing.lexbuf;
    mutable replay_ptr : int option;
    mutable lookahead_buffers : Lexing.lexbuf list;
  }
let dummy_refill lexbuf = error (Putil.region lexbuf) "Dummy lexbuf refill!"
let copy_lexbuf lexbuf =
  let open Lexing in
  let newbuf = Bytes.create (Bytes.length lexbuf.lex_buffer) in
  Bytes.blit lexbuf.lex_buffer 0 newbuf 0 (Bytes.length lexbuf.lex_buffer);
  { lexbuf with
    refill_buff = dummy_refill;
    lex_buffer = newbuf;
    lex_mem = Array.copy lexbuf.lex_mem;
  }
let bt_lexbuf_set_lexbuf bt_lexbuf lexbuf =
  let open Lexing in
  bt_lexbuf.bt_lexbuf.lex_buffer <- lexbuf.lex_buffer;
  bt_lexbuf.bt_lexbuf.lex_buffer_len <- lexbuf.lex_buffer_len;
  bt_lexbuf.bt_lexbuf.lex_abs_pos <- lexbuf.lex_abs_pos;
  bt_lexbuf.bt_lexbuf.lex_start_pos <- lexbuf.lex_start_pos;
  bt_lexbuf.bt_lexbuf.lex_curr_pos <- lexbuf.lex_curr_pos;
  bt_lexbuf.bt_lexbuf.lex_last_pos <- lexbuf.lex_last_pos;
  bt_lexbuf.bt_lexbuf.lex_last_action <- lexbuf.lex_last_action;
  bt_lexbuf.bt_lexbuf.lex_eof_reached <- lexbuf.lex_eof_reached;
  bt_lexbuf.bt_lexbuf.lex_mem <- lexbuf.lex_mem;
  bt_lexbuf.bt_lexbuf.lex_start_p <- lexbuf.lex_start_p;
  bt_lexbuf.bt_lexbuf.lex_curr_p <- lexbuf.lex_curr_p
let rec list_drop n list =
  if n = 0 then list else
    match list with
    | [] -> []
    | x::xs -> list_drop (n-1) xs
let bt_lexbuf_commit bt_lexbuf =
  match bt_lexbuf.replay_ptr with
  | None -> bt_lexbuf.lookahead_buffers <- []
  | Some ptr ->
     bt_lexbuf.lookahead_buffers <- list_drop ptr bt_lexbuf.lookahead_buffers;
     bt_lexbuf.replay_ptr <- Some 0
let bt_lexbuf_mark bt_lexbuf =
  bt_lexbuf_commit bt_lexbuf;
  bt_lexbuf.lookahead_buffers <-
    copy_lexbuf bt_lexbuf.bt_lexbuf::bt_lexbuf.lookahead_buffers;
  bt_lexbuf.replay_ptr <- match bt_lexbuf.replay_ptr with
                          | None -> None
                          | Some n -> Some (n+1)
let bt_lexbuf_abort bt_lexbuf =
  bt_lexbuf_set_lexbuf bt_lexbuf
    (copy_lexbuf (List.hd bt_lexbuf.lookahead_buffers));
  bt_lexbuf.replay_ptr <-
    if List.length bt_lexbuf.lookahead_buffers > 1
    then Some 1
    else None
let bt_lexbuf_refill bt_lexbuf orig_refill lexbuf =
  match bt_lexbuf.replay_ptr with
  | Some ptr ->
     bt_lexbuf_set_lexbuf bt_lexbuf
       (copy_lexbuf (List.nth bt_lexbuf.lookahead_buffers ptr));
     let new_ptr = ptr + 1 in
     bt_lexbuf.replay_ptr <-
       if new_ptr >= List.length bt_lexbuf.lookahead_buffers
       then None
       else Some new_ptr
  | None ->
     orig_refill lexbuf;
     bt_lexbuf.lookahead_buffers <-
       bt_lexbuf.lookahead_buffers @ [copy_lexbuf lexbuf]
let bt_lexbuf_of_lexbuf lexbuf =
  let rec ret = {
      bt_lexbuf = {lexbuf with
                    Lexing.refill_buff =
                      fun lexbuf' ->
                      bt_lexbuf_refill ret lexbuf.Lexing.refill_buff
                        lexbuf'};
      replay_ptr = None;
      lookahead_buffers = [];
    }
  in ret

let lex_core_module (lexbuf : Lexing.lexbuf)
  :  Lexing.position * Wasm.Script.var option * Wasm.Ast.module_
  = let lcm_status : int ref = ref 0
    and paren_depth : int ref = ref 0
    and first_pos : Lexing.position option ref = ref None in
    let token' lexbuf = let tok = Wasm.Lexer.token lexbuf in
                        match !first_pos with
                        | None -> first_pos := Some lexbuf.Lexing.lex_start_p;
                                  tok
                        | Some _ -> tok in
    let (x, d) =
      Wasm.Parser.module1 (fun lexbuf ->
          if !paren_depth = 0
          then match !lcm_status with
               | 0 -> lcm_status := 1; Wasm.Parser.LPAR
               | 1 -> lcm_status := 2; paren_depth := 1; Wasm.Parser.MODULE
               | 2 -> Wasm.Parser.EOF
               | _ -> error (Putil.region lexbuf) "Impossible: bad lcm state"
          else match token' lexbuf with
               | Wasm.Parser.LPAR -> paren_depth := !paren_depth + 1;
                                     Wasm.Parser.LPAR
               | Wasm.Parser.RPAR -> paren_depth := !paren_depth - 1;
                                     Wasm.Parser.RPAR
               | tok -> tok) lexbuf
    in match !first_pos, d.Wasm.Source.it with
       | Some p, Wasm.Script.Textual m -> (p, x, m)
       | _, _ -> error (Putil.region lexbuf)
                   "Impossible: non-Textual module or no lex"

let lex_core_deftype (lexbuf : Lexing.lexbuf)
    : Lexing.position * Wasm.Ast.type_
  = let lcm_status : int ref = ref 0
    and paren_depth : int ref = ref 0
    and first_pos : Lexing.position option ref = ref None in
    let token' lexbuf = let tok = Wasm.Lexer.token lexbuf in
                        match !first_pos with
                        | None -> first_pos := Some lexbuf.Lexing.lex_start_p;
                                  tok
                        | Some _ -> tok in
    let prim_lex () =
      match token' lexbuf with
      | Wasm.Parser.LPAR -> paren_depth := !paren_depth + 1;
                            Wasm.Parser.LPAR
      | Wasm.Parser.RPAR -> paren_depth := !paren_depth - 1;
                            Wasm.Parser.RPAR
      | tok -> tok in
    let ty =
      Wasm.Parser.type_ (fun lexbuf ->
          if !paren_depth = 0
          then match !lcm_status with
               | 0 -> lcm_status := 1; prim_lex ()
               | 1 -> Wasm.Parser.EOF
               | _ -> error (Putil.region lexbuf) "Impossible: bad lcdt state"
          else prim_lex ()) lexbuf
    in match !first_pos with
       | Some p -> p, ty
       | _ -> error (Putil.region lexbuf) "Impossible: no lex"

let lex_core_importdesc (lexbuf : Lexing.lexbuf)
    : Lexing.position * Wasm.Ast.import_desc' Ast.Var.core_externdesc_wrapper
  = let lcm_status : int ref = ref 0
    and paren_depth : int ref = ref 0
    and first_pos : Lexing.position option ref = ref None in
    let token' lexbuf = let tok = Wasm.Lexer.token lexbuf in
                        match !first_pos with
                        | None -> first_pos := Some lexbuf.Lexing.lex_start_p;
                                  tok
                        | Some _ -> tok in
    let prim_lex () =
      match token' lexbuf with
      | Wasm.Parser.LPAR -> paren_depth := !paren_depth + 1;
                            Wasm.Parser.LPAR
      | Wasm.Parser.RPAR -> paren_depth := !paren_depth - 1;
                            Wasm.Parser.RPAR
      | tok -> tok in
    let id =
      Wasm.Parser.import_desc (fun lexbuf ->
          if !paren_depth = 0
          then match !lcm_status with
               | 0 -> lcm_status := 1; prim_lex ()
               | 1 -> Wasm.Parser.EOF
               | _ -> error (Putil.region lexbuf) "Impossible: bad lcdt state"
          else prim_lex ()) lexbuf
    in match !first_pos with
       | Some p -> p, id
       | _ -> error (Putil.region lexbuf) "Impossible: no lex"

type special_lookaheads =
  | SL_none
  | SL_module
  | SL_type
  | SL_string
type next_token_may_be =
  | NT_none
  | NT_core_module
  | NT_core_deftype
  | NT_core_importdesc

let parse' name orig_lexbuf start =
  let bt_lexbuf = bt_lexbuf_of_lexbuf orig_lexbuf in
  let lexbuf = bt_lexbuf.bt_lexbuf in
  let open MenhirLib.General in
  let module Interp = Parser.MenhirInterpreter in
  let input = Interp.lexer_lexbuf_to_supplier Lexer.token lexbuf in
  let failure error_state =
    let env = match[@warning "-4"] error_state with
      | Interp.HandlingError env -> env
      | _ -> assert false in
    match Interp.stack env with
    | lazy Nil -> assert false
    | lazy (Cons (Interp.Element (state, _, start_pos, end_pos), _)) ->
      print_endline (string_of_int (Interp.number state));
      raise (Syntax ({Wasm.Source.left = Putil.convert_pos start_pos;
                      Wasm.Source.right = Putil.convert_pos end_pos},
                     "Parse error")) in
  let is_sl = ref SL_none in
  let is_nt = ref NT_none in
  let rec token_supplier  () =
    is_sl := SL_none;
    match !is_nt with
    | NT_core_module ->
       (is_nt := NT_none;
        bt_lexbuf_mark bt_lexbuf;
        try
          let p, x, m = lex_core_module lexbuf in
          bt_lexbuf_commit bt_lexbuf;
          Parser.COREMOD (x, m), p, lexbuf.Lexing.lex_curr_p
        with
          e -> let msg = Printexc.to_string e
               and stack = Printexc.get_backtrace () in
               Printf.eprintf "there was an error: %s%s\n" msg stack;

               bt_lexbuf_abort bt_lexbuf;
               bt_lexbuf_commit bt_lexbuf; (* there are no other options *)
               token_supplier ())
    | NT_core_deftype ->
       (is_nt := NT_none;
        bt_lexbuf_mark bt_lexbuf;
        try
          let p, t = lex_core_deftype lexbuf in
          bt_lexbuf_commit bt_lexbuf;
          Parser.COREDEFTYPE t, p, lexbuf.Lexing.lex_curr_p
        with
          _ -> bt_lexbuf_abort bt_lexbuf;
               bt_lexbuf_commit bt_lexbuf; (* there are no other options *)
               let tok, p, q = token_supplier () in
               (match tok with
                | Parser.VAR _ -> is_nt := NT_core_deftype
                | _ -> ());
               tok, p, q)
    | NT_core_importdesc ->
       (is_nt := NT_none;
        bt_lexbuf_mark bt_lexbuf;
        try
          let p, id = lex_core_importdesc lexbuf in
          bt_lexbuf_commit bt_lexbuf;
          Parser.COREIMPORTDESC id, p, lexbuf.Lexing.lex_curr_p
        with
          _ -> bt_lexbuf_abort bt_lexbuf;
               bt_lexbuf_commit bt_lexbuf; (* there are no other options *)
               token_supplier ())
    | _ ->
       let tok, p, q = input () in
       (match tok with
        | Parser.MODULE -> is_sl := SL_module
        | Parser.TYPE -> is_sl := SL_type
        | Parser.STRING _ -> is_sl := SL_string
        | _ -> is_sl := SL_none);
       tok, p, q in
  let rec go checkpoint =
    let open Interp in
    match checkpoint with
    | InputNeeded a -> go (offer checkpoint (token_supplier ()))
    | Shifting _ -> go (resume checkpoint)
    | AboutToReduce (_, production) ->
       (match lhs production with
        | X (N N_core_marker) ->
           (match !is_sl with
            | SL_module -> is_nt := NT_core_module
            | SL_type -> is_nt := NT_core_deftype
            | _ -> ());
           go (resume checkpoint)
        | X (N N_core_type_marker) ->
           (match !is_sl with
            | SL_type -> is_nt := NT_core_deftype
            | _ -> ());
           go (resume checkpoint)
        | X (N N_core_importdecl_marker) ->
           (match !is_sl with
            | SL_string -> is_nt := NT_core_importdesc
            | _ -> ());
           go (resume checkpoint)
        | X (N N_core_exportdecl_marker) ->
           (match !is_sl with
            | SL_string -> is_nt := NT_core_importdesc
            | _ -> ());
           go (resume checkpoint)
        | _ -> go (resume checkpoint))
    | HandlingError _ -> failure checkpoint
    | Accepted r -> r
    (* We should always see HandlingError first *)
    | Rejected -> assert false
  in go (start lexbuf.Lexing.lex_curr_p)


let parse (type a) name lexbuf : a start -> a = function
  | Component -> parse' name lexbuf Parser.Incremental.component_module
  | Script -> parse' name lexbuf Parser.Incremental.component_script

let string_to start s =
  let lexbuf = Lexing.from_string s in
  parse "string" lexbuf start

let string_to_script s = string_to Script s
let string_to_component s = snd (string_to Component s)
