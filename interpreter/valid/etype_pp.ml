open Wasm.Source

open Etypes
open Ast

let pp_indent : int ref = ref 0
let pp_wrap : int ref = ref 80
let pp_pos : int ref = ref 0
let pp_linum : int ref = ref 0
type pp_var_ctx =
  { pvc_parent : pp_var_ctx option
  ; pvc_uvars : string list
  ; pvc_evars : string list
  ; pvc_bvars : string list
  }
let empty_pp_var_ctx : pp_var_ctx
  = { pvc_parent = None
    ; pvc_uvars = []
    ; pvc_evars = []
    ; pvc_bvars = []
    }
let pp_vars : pp_var_ctx ref
  = ref empty_pp_var_ctx
let pp_var_idx : int ref = ref 0
let pp_output : string list ref = ref []

let _output s = pp_output := s::!pp_output

let rec nr_codepoints n i s =
  (* wrong, but good enough & doesn't require an external unicode library *)
  if i >= String.length s
  then n
  else
    let ud = String.get_utf_8_uchar s 0 in
    nr_codepoints (n+1) (i+Uchar.utf_decode_length ud) s

let emit_newline s =
  pp_pos := !pp_indent + nr_codepoints 0 0 s;
  pp_linum := !pp_linum + 1;
  _output "\n";
  _output (String.make !pp_indent ' ');
  _output s

let emit_ s =
  let orig_pos = !pp_pos in
  let new_pos = orig_pos + nr_codepoints 0 0 s in
  if new_pos >= !pp_wrap
  then (emit_newline s; !pp_indent)
  else (pp_pos := new_pos; _output s; orig_pos)

let emit s =
  let _ = emit_ s in ()

let emit_indent_begin s f =
  let orig_indent = !pp_indent in
  let orig_pos = emit_ s in
  pp_indent := orig_pos;
  f ();
  pp_indent := orig_indent

let with_indent_here f =
  let orig_indent = !pp_indent in
  pp_indent := !pp_pos;
  f ();
  pp_indent := orig_indent

let emit_indent_end s f =
  emit s;
  with_indent_here f

let rec emit_list sep f xs =
  match xs with
  | [] -> ()
  | x::xs ->
     let orig_linum = !pp_linum in
     with_indent_here (fun () -> f x);
     if !pp_linum <> orig_linum
     then emit_newline sep
     else emit sep;
     emit_list sep f xs

let emit_bracketed_list start stop sep f xs =
  let old_line = !pp_linum in
  emit_indent_begin start
    (fun () ->
      emit_list sep f xs;
      if !pp_linum <> old_line
      then emit_newline stop
      else emit stop)


let pp_begin () =
  pp_linum := 0;
  pp_pos := 0;
  pp_wrap := 60;
  pp_indent := 2;
  pp_vars := empty_pp_var_ctx;
  pp_var_idx := 0;
  pp_output := []
let pp_end () =
  let out = String.concat "" (List.rev !pp_output) in
  pp_output := []; out
let pp_string f =
  pp_begin ();
  f ();
  pp_end ()

let pp_line f =
  print_endline (pp_string f)

let pp_debug prefix f =
  pp_line (fun () -> emit prefix; emit ": "; f ())

let emit_core_extern_desc (ctx : ctx) (ced : core_extern_desc) : unit
  = emit (Wasm.Types.string_of_extern_type ced)

let emit_core_export_decl (ctx : ctx) (ced : core_export_decl) : unit
  = emit ced.ced_name.it; emit " ";
    emit_indent_end ": " (fun () ->
        emit_core_extern_desc ctx ced.ced_desc)

let emit_core_export_decls (ctx : ctx) (ceds : core_export_decl list) : unit
  = emit_bracketed_list "{ " "} " "; " (emit_core_export_decl ctx) ceds

let emit_core_import_decls (ctx : ctx) (ceds : core_import_decl list) : unit
  = ()

let emit_core_instance_type (ctx : ctx) (cit : core_instance_type) : unit
  = emit_core_export_decls ctx cit.cit_exports

let emit_core_module_type (ctx : ctx) (cmt : core_module_type) : unit
  = ()

let emit_val_int_size (ctx : ctx) (vis : val_int_size) : unit
  = match vis with
  | VI_8 -> emit "8 "
  | VI_16 -> emit "16 "
  | VI_32 -> emit "32 "
  | VI_64 -> emit "64 "
let emit_val_float_size (ctx : ctx) (vis : val_float_size) : unit
  = match vis with
  | VF_32 -> emit "32 "
  | VF_64 -> emit "64 "


let rec emit_val_type (ctx : ctx) (vt : val_type) : unit
  = match vt with
  | Bool -> emit "bool "
  | Signed i -> emit "s"; emit_val_int_size ctx i
  | Unsigned i -> emit "u"; emit_val_int_size ctx i
  | Float f -> emit "f"; emit_val_float_size ctx f
  | Char -> emit "char "
  | List vt ->
     emit_indent_end "list(" (fun () -> emit_val_type ctx vt; emit ") ")
  | Record rfs ->
     emit_bracketed_list "{ " "} " "; " (emit_record_field ctx) rfs
  | Variant vcs ->
     emit_bracketed_list "< " "> " "| " (emit_variant_case ctx) vcs
  | Own dt ->
     emit_indent_end "own(" (fun () -> emit_def_type ctx dt; emit ") ")
  | Borrow dt ->
     emit_indent_end "borrow(" (fun () -> emit_def_type ctx dt; emit ") ")
and emit_record_field (ctx : ctx) (rf : record_field) : unit
  = emit rf.rf_name.it; emit " ";
    emit_indent_end ": " (fun () -> emit_val_type ctx rf.rf_type)
and emit_variant_case (ctx : ctx) (vc : variant_case) : unit
  = emit vc.vc_name.it;
    (match vc.vc_default with
     | None -> emit " "
     | Some d -> emit "("; emit (Int32.to_string d); emit ") ");
    (match vc.vc_type with
     | None -> ()
     | Some vt -> emit_indent_end ": " (fun () -> emit_val_type ctx vt));

and emit_func_io (ctx : ctx) (fio : func_ios) : unit
  = match fio with
  | Fio_one vt -> emit_val_type ctx vt
  | Fio_many nvts ->
     emit_bracketed_list "[ " "] " "; "
       (fun (n, vt) -> emit n.it; emit " ";
                       emit_indent_end ": " (fun () ->
                           emit_val_type ctx vt))
       nvts

and emit_func_type (ctx : ctx) (ft : func_type) : unit
  = emit_func_io ctx ft.ft_params; emit "-> "; emit_func_io ctx ft.ft_result

and emit_def_type (ctx : ctx) (dt : def_type) : unit
  = match dt with
  | DT_var (TV_bound i) -> emit (List.nth !pp_vars.pvc_bvars i)
  | DT_var (TV_free (FTV_evar (o, i))) ->
     emit_indent_end "evar(" (fun () ->
         emit (string_of_int o); emit ", "; emit (string_of_int i); emit ")")
  | DT_var (TV_free (FTV_uvar (o, i))) ->
     emit_indent_end "uvar(" (fun () ->
         emit (string_of_int o); emit ", "; emit (string_of_int i); emit ")")
  | DT_resource_type idx ->
     emit_indent_end "resource " (fun () -> emit (Int32.to_string idx))
  | DT_val_type vt -> emit_val_type ctx vt
  | DT_func_type ft -> emit_func_type ctx ft
  | DT_instance_type it -> emit_instance_type ctx it
  | DT_component_type ct -> emit_component_type ctx ct

and emit_extern_desc (ctx : ctx) (ed : extern_desc) : unit
  = match ed with
  | ED_core_module cmt -> emit_core_module_type ctx cmt
  | ED_func ft -> emit_func_type ctx ft
  | ED_value vt -> emit_val_type ctx vt
  | ED_type dt -> emit_def_type ctx dt
  | ED_instance it -> emit_instance_type ctx it
  | ED_component ct -> emit_component_type ctx ct

and emit_extern_decl (ctx : ctx) (ed : extern_decl) : unit
  = emit ed.ed_name.it.en_name.it; emit " ";
    emit_indent_end ": " (fun () -> emit_extern_desc ctx ed.ed_desc)

and emit_extern_decls (ctx : ctx) (eds : extern_decl list) : unit
  = emit_bracketed_list "{ " "} " "; " (emit_extern_decl ctx) eds

and next_var_name () : string
  = let next_idx = !pp_var_idx + 1 in
    pp_var_idx := next_idx;
    "α" ^ string_of_int next_idx

and emit_type_bound (ctx : ctx) (tb : type_bound) : unit
  = match tb with
  | Tbound_eq dt ->
     emit_indent_end "eq " (fun () -> emit_def_type ctx dt)
  | Tbound_subr -> emit "sub resource"

and emit_bound_var (ctx : ctx) (v : boundedtyvar) : unit
  = let var = next_var_name () in
    pp_vars := { !pp_vars with pvc_bvars = var::!pp_vars.pvc_bvars };
    emit_indent_begin "(" (fun () ->
        with_indent_here (fun () -> emit var);
        emit_indent_end ": " (fun () -> emit_type_bound ctx v);
        emit ")")

and emit_bound_vars (ctx : ctx) (vs : boundedtyvar list) : unit
  = emit_list " " (emit_bound_var ctx) vs

and emit_instance_type (ctx : ctx) (it : instance_type) : unit
  = emit_indent_begin "∃ " (fun () ->
        let old_vars = !pp_vars in
        with_indent_here (fun () -> emit_bound_vars ctx it.it_evars);
        emit ". ";
        with_indent_here (fun () -> emit_extern_decls ctx it.it_exports);
        pp_vars := old_vars)

and emit_component_type (ctx : ctx) (ct : component_type) : unit
  = emit_indent_begin "∀ " (fun () ->
        let old_vars = !pp_vars in
        with_indent_here (fun () -> emit_bound_vars ctx ct.ct_uvars);
        emit ". ";
        with_indent_here (fun () -> emit_extern_decls ctx ct.ct_imports);
        emit "→ ";
        emit_instance_type ctx ct.ct_instance;
        pp_vars := old_vars)

let pp_core_extern_desc ctx x =
  pp_string (fun () -> emit_core_extern_desc ctx x)

let pp_core_export_decl ctx x =
  pp_string (fun () -> emit_core_export_decl ctx x)

let pp_core_export_decls ctx x =
  pp_string (fun () -> emit_core_export_decls ctx x)

let pp_core_import_decls ctx x =
  pp_string (fun () -> emit_core_import_decls ctx x)

let pp_core_instance_type ctx x =
  pp_string (fun () -> emit_core_instance_type ctx x)

let pp_val_type ctx x =
  pp_string (fun () -> emit_val_type ctx x)

let pp_def_type ctx x =
  pp_string (fun () -> emit_def_type ctx x)

let pp_extern_desc ctx x =
  pp_string (fun () -> emit_extern_desc ctx x)

let pp_extern_decls ctx x =
  pp_string (fun () -> emit_extern_decls ctx x)

let pp_instance_type ctx x =
  pp_string (fun () -> emit_instance_type ctx x)

let pp_component_type ctx x = pp_string (fun () -> emit_component_type ctx x)
