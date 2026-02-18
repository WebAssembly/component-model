open Wasm_components
open Wasm_components.Script
open Wasm.Source


(* Errors & Tracing *)

module Script = Wasm.Error.Make ()
module Abort = Wasm.Error.Make ()
module Assert = Wasm.Error.Make ()
module IO = Wasm.Error.Make ()

exception Abort = Abort.Error
exception Assert = Assert.Error
exception IO = IO.Error

let trace name = if !Flags.trace then print_endline ("-- " ^ name)


(* File types *)

let binary_ext = "wasm"
let sexpr_ext = "wat"
let script_binary_ext = "bin.wast"
let script_ext = "wast"
let js_ext = "js"

let dispatch_file_ext on_binary on_sexpr on_script_binary on_script on_js file =
  if Filename.check_suffix file binary_ext then
    on_binary file
  else if Filename.check_suffix file sexpr_ext then
    on_sexpr file
  else if Filename.check_suffix file script_binary_ext then
    on_script_binary file
  else if Filename.check_suffix file script_ext then
    on_script file
  else if Filename.check_suffix file js_ext then
    on_js file
  else
    raise (Sys_error (file ^ ": unrecognized file type"))

(* Input *)

let error at category msg =
  trace ("Error: ");
  prerr_endline (Wasm.Source.string_of_region at ^ ": " ^ category ^ ": " ^ msg);
  false

let input_from get_script run =
  try
    let script = get_script () in
    trace "Running...";
    run script;
    true
  with
  | Wasm.Decode.Code (at, msg) -> error at "decoding error" msg
  | Wasm.Parse.Syntax (at, msg) -> error at "syntax error" msg
  | Syntax (at, msg) -> error at "syntax error" msg
  | Valid.Invalid (at, msg) ->
     Printexc.print_backtrace stdout;
     error at "invalid module" msg
  | Wasm.Import.Unknown (at, msg) -> error at "link failure" msg
  | Wasm.Eval.Link (at, msg) -> error at "link failure" msg
  | Wasm.Eval.Trap (at, msg) -> error at "runtime trap" msg
  | Wasm.Eval.Exhaustion (at, msg) -> error at "resource exhaustion" msg
  | Wasm.Eval.Crash (at, msg) -> error at "runtime crash" msg
  | Wasm.Encode.Code (at, msg) -> error at "encoding error" msg
  | Script.Error (at, msg) -> error at "script error" msg
  | IO (at, msg) -> error at "i/o error" msg
  | Assert (at, msg) -> error at "assertion failure" msg
  | Abort _ -> false

let input_script start name lexbuf run =
  input_from (fun _ -> Wasm_components.Parse.parse name lexbuf start) run

let input_sexpr name lexbuf run =
  input_from (fun _ ->
      let x, c = Wasm_components.Parse.parse name lexbuf
                   Wasm_components.Parse.Component in
      [Component (x, Textual c @@ no_region) @@ no_region]) run

let input_binary name buf run =
  input_from (fun _ ->
    raise (Sys_error "i don't do this yet (2)")) run

let input_sexpr_file input file run =
  trace ("Loading (" ^ file ^ ")...");
  let ic = open_in file in
  try
    let lexbuf = Lexing.from_channel ic in
    trace "Parsing...";
    let success = input file lexbuf run in
    close_in ic;
    success
  with exn -> close_in ic; raise exn

let input_binary_file file run =
  trace ("Loading (" ^ file ^ ")...");
  let ic = open_in_bin file in
  try
    let len = in_channel_length ic in
    let buf = Bytes.make len '\x00' in
    really_input ic buf 0 len;
    trace "Decoding...";
    let success = input_binary file (Bytes.to_string buf) run in
    close_in ic;
    success
  with exn -> close_in ic; raise exn

let input_js_file file run =
  raise (Sys_error (file ^ ": unrecognized input file type"))

let input_file file run =
  trace ("Input file (\"" ^ String.escaped file ^ "\")...");
  dispatch_file_ext
    input_binary_file
    (input_sexpr_file input_sexpr)
    (input_sexpr_file (input_script Wasm_components.Parse.Script))
    (input_sexpr_file (input_script Wasm_components.Parse.Script))
    input_js_file
    file run

let input_string string run =
  trace ("Running (\"" ^ String.escaped string ^ "\")...");
  let lexbuf = Lexing.from_string string in
  trace "Parsing...";
  input_script Wasm_components.Parse.Script "string" lexbuf run


(* Interactive *)

let continuing = ref false

let lexbuf_stdin buf len =
  let prompt = if !continuing then "  " else "> " in
  print_string prompt; flush_all ();
  continuing := true;
  let rec loop i =
    if i = len then i else
    let ch = input_char stdin in
    Bytes.set buf i ch;
    if ch = '\n' then i + 1 else loop (i + 1)
  in
  let n = loop 0 in
  if n = 1 then continuing := false else trace "Parsing...";
  n

let input_stdin run =
  let lexbuf = Lexing.from_function lexbuf_stdin in
  let rec loop () =
    let success = input_script Wasm_components.Parse.Script "stdin" lexbuf run in
    if not success then Lexing.flush_input lexbuf;
    if Lexing.(lexbuf.lex_curr_pos >= lexbuf.lex_buffer_len - 1) then
      continuing := false;
    loop ()
  in
  try loop () with End_of_file ->
    print_endline "";
    trace "Bye."

(* Configuration *)

let quote : script ref = ref []
let desugar_ctx : Wasm_components.Desugar.definition_ctx
  = Wasm_components.Desugar.empty_ctx () None
let valid_ctx : Wasm_components.Etypes.ctx ref
  = ref (Wasm_components.Etypes.empty_ctx None false)

(* Printing *)

let print_component_type t =
  Etype_pp.pp_line (fun () -> Etype_pp.emit_component_type !valid_ctx t)

(* Running *)

let rec run_definition def : Wasm_components.Ast.IntAst.component
  = match def.it with
  | Textual c ->
     Wasm_components.Desugar._desugar_component (Desugar.SC desugar_ctx) c
  | Encoded (name, bs) ->
     raise (Sys_error "Binary modules not yet supported")
  | Quoted (name, s) ->
     trace "Parsing quote...";
     let x, c =
       Wasm_components.Parse.parse name (Lexing.from_string s)
         Wasm_components.Parse.Component in
     run_definition (Textual c @@ no_region)

let extract_msg s =
  let rec strip_spaces s = if String.starts_with ~prefix:" " s
                           then strip_spaces (String.sub s 1 (String.length s - 1))
                           else s in
  strip_spaces (List.hd (List.rev (String.split_on_char '\n' s)))
let assert_message at name msg' re =
  let msg = extract_msg msg' in
  if
    String.length msg < String.length re ||
    String.sub msg 0 (String.length re) <> re
  then begin
    print_endline ("Result: \"" ^ msg ^ "\"");
    print_endline ("Expect: \"" ^ re ^ "\"");
    Assert.error at ("wrong " ^ name ^ " error")
  end

let run_assertion ass =
  match ass.it with
  | AssertMalformed (def, re) ->
    trace "Asserting malformed...";
    (match ignore (run_definition def) with
    | exception Parse.Syntax (_, msg) -> assert_message ass.at "parsing" msg re
    | _ -> Assert.error ass.at "expected decoding/parsing error"
    )

  | AssertInvalid (def, re) ->
    trace "Asserting invalid...";
    (match
      let m = run_definition def in
      let _ = Valid.infer_component !valid_ctx m in
      Assert.error ass.at "expected validation error"
    with
    | exception Wasm_components.Valid.Invalid (_, msg) ->
      assert_message ass.at "validation" msg re
    | _ -> Assert.error ass.at "expected validation error"
    )

let rec run_command
          (cmd : Wasm_components.Script.command) : unit =
  match cmd.it with
  | Component (x_opt, def) ->
     let c = run_definition def in
     if not !Flags.unchecked then begin
         trace "Checking...";
         let t = Valid.infer_component !valid_ctx c in
         if !Flags.print_sig then begin
             trace "Signature:";
             print_component_type t
           end;
         Wasm_components.Desugar.bind desugar_ctx (Ast.Component @@ no_region)
           x_opt;
         valid_ctx := { !valid_ctx with
                        Etypes.components = !valid_ctx.Etypes.components
                                            @ [ t ] }
       end;
     () (* TODO: actually run it *)
  | Assertion ass ->
    quote := cmd :: !quote;
    if not !Flags.dry then begin
      run_assertion ass
    end
  | Meta cmd ->
     run_meta cmd
and run_meta cmd =
  match cmd.it with
  | Script (x_opt, script) ->
    run_quote_script script;

  | Input (x_opt, file) ->
    (try if not (input_file file run_quote_script) then
      Abort.error cmd.at "aborting"
    with Sys_error msg -> IO.error cmd.at msg)

and run_script script =
  List.iter run_command script

and run_quote_script (script : Wasm_components.Script.script) =
  let save_quote = !quote in
  quote := [];
  (try run_script script with exn -> quote := save_quote; raise exn);
  quote := !quote @ save_quote

let run_file file = input_file file run_script
let run_string string = input_string string run_script
let run_stdin () = input_stdin run_script
