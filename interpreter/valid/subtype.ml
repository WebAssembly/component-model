open Ast
open Wasm.Source
open Etypes
open Etype_pp
open Substitute

let subtype_trace = true

let subtype_err k s1 s2
  = raise (Invalid (no_region, "Could not show that " ^ k ^ " " ^ s1 ^

                                 " is a subtype of " ^ s2))

let subtype_core_extern_desc (ctx : ctx)
      (ed1 : core_extern_desc) (ed2 : core_extern_desc) : unit
  = if Wasm.Types.match_extern_type ed1 ed2
    then ()
    else subtype_err "core type"
           (Wasm.Types.string_of_extern_type ed1)
           (Wasm.Types.string_of_extern_type ed2)

let subtype_core_export_decls' (ctx : ctx)
      (ceds1 : core_export_decl list) (ced2 : core_export_decl) : unit
  = try
    let ced1 = List.find (fun x -> x.ced_name.it = ced2.ced_name.it) ceds1 in
    subtype_core_extern_desc ctx ced1.ced_desc ced2.ced_desc
  with Not_found ->
    raise (Invalid (no_region,
                    pp_string (fun () ->
                        emit "No extern desc named ";
                        emit ced2.ced_name.it;
                        emit " in ";
                        emit_core_export_decls ctx ceds1)))

let subtype_core_export_decls (ctx : ctx)
      (ceds1 : core_export_decl list) (ceds2 : core_export_decl list) : unit
  = List.iter (subtype_core_export_decls' ctx ceds1) ceds2

let subtype_core_instance_type (ctx : ctx)
      (cit1 : core_instance_type) (cit2 : core_instance_type) : unit
  = subtype_core_export_decls ctx cit1.cit_exports cit2.cit_exports

let subtype_core_import_decls' (ctx : ctx)
      (cids1 : core_import_decl list) (cid2 : core_import_decl) : unit
  = try
    let cid1 = List.find (fun x -> x.cid_name1.it = cid2.cid_name1.it
                                   && x.cid_name2.it = cid2.cid_name2.it)
                 cids1 in
    subtype_core_extern_desc ctx cid1.cid_desc cid2.cid_desc
  with Not_found ->
    raise (Invalid (no_region,
                    pp_string (fun () ->
                        emit "No extern desc named ";
                        emit cid2.cid_name1.it;
                        emit ".";
                        emit cid2.cid_name2.it;
                        emit " in ";
                        emit_core_import_decls ctx cids1)))

let subtype_core_import_decls (ctx : ctx)
      (cids1 : core_import_decl list) (cids2 : core_import_decl list) : unit
  = List.iter (subtype_core_import_decls' ctx cids1) cids2

let subtype_core_module_type (ctx : ctx)
      (cmt1 : core_module_type) (cmt2 : core_module_type) : unit
  = subtype_core_import_decls ctx cmt2.cmt_imports cmt1.cmt_imports;
    subtype_core_instance_type ctx cmt1.cmt_instance cmt2.cmt_instance

type resolved_tyvar =
  | RTV_definite of def_type
  | RTV_bound of int
  | RTV_evar of int * int * type_bound
  | RTV_uvar of int * int * type_bound

let rec resolve_tyvar (ctx : ctx) (tv : tyvar) : resolved_tyvar
  = let rec lookup_uvar ctx o i =
      match o with
      | 0 -> (match List.nth ctx.uvars i with
              | (Tbound_eq dt, _) -> Either.Left dt
              | (tb, _) -> Either.Right tb)
      | _ -> (match ctx.parent_ctx with
              | Some ctx' -> lookup_uvar ctx' (o - 1) i
              | None -> raise (Invalid (no_region, "Uvar refers to non-existent outer component")))
    in
    let rec lookup_evar ctx o i =
      match o with
      | 0 -> (match List.nth ctx.evars i with
              | (_, Some dt) -> Either.Left dt
              | (Tbound_eq dt, None) -> Either.Left dt
              | (tb, None) -> Either.Right tb)
      | _ -> (match ctx.parent_ctx with
              | Some ctx' -> lookup_evar ctx' (o - 1) i
              | None -> raise (Invalid (no_region, "Evar refers to non-existent outer component")))
    in
    let resolve_deftype_tyvar d =
      match d with
      | DT_var tv -> resolve_tyvar ctx tv
      | _ -> RTV_definite d
    in
    match tv with
    | TV_bound b -> RTV_bound b
    | TV_free (FTV_evar (o, i)) ->
       (match lookup_evar ctx o i with
        | Either.Left d -> resolve_deftype_tyvar d
        | Either.Right tb -> RTV_evar (o, i, tb))
    | TV_free (FTV_uvar (o, i)) ->
       (match lookup_uvar ctx o i with
        | Either.Left d -> resolve_deftype_tyvar d
        | Either.Right tb -> RTV_uvar (o, i, tb))

let rec subtype_val_type (ctx : ctx)
      (vt1 : val_type) (vt2 : val_type) : unit
  = match vt1, vt2 with
  | Bool, Bool -> ()
  | Signed s1, Signed s2
    | Unsigned s1, Unsigned s2 ->
     if s1 = s2 then ()
     else subtype_err "val type" (pp_val_type ctx vt1) (pp_val_type ctx vt2)
  | Float f1, Float f2 ->
     if f1 = f2 then ()
     else subtype_err "val type" (pp_val_type ctx vt1) (pp_val_type ctx vt2)
  | Char, Char -> ()
  | List vt1', List vt2' ->
     subtype_val_type ctx vt1' vt2'
  | Record rfs1, Record rfs2 ->
     List.iter (fun rf2 ->
         try
           let rf1 =
             List.find (fun rf1 -> rf1.rf_name.it = rf2.rf_name.it) rfs1
           in subtype_val_type ctx rf1.rf_type rf2.rf_type
         with | Not_found ->
                 raise (Invalid (no_region,
                                 "Could not find record field "
                                 ^ rf2.rf_name.it ^ " in record type "
                                 ^ pp_val_type ctx vt1))) rfs2
  | Variant vcs1, Variant vcs2 ->
     List.iter (fun vc1 ->
         try
           let vc2 =
             List.find (fun vc2 -> vc1.vc_name.it  = vc2.vc_name.it) vcs2
           in subtype_val_type_option ctx vc1.vc_type vc2.vc_type
         with | Not_found ->
                 raise (Invalid (no_region,
                                 "Could not find variant case "
                                 ^ vc1.vc_name.it ^ " in variant type "
                                 ^ pp_val_type ctx vt2))) vcs1
  | Own dt1, Own dt2 ->
     def_type_is_resource ctx dt1;
     def_type_is_resource ctx dt2;
     subtype_def_type ctx dt1 dt2
  | Borrow dt1, Borrow dt2 ->
     def_type_is_resource ctx dt1;
     def_type_is_resource ctx dt2;
     subtype_def_type ctx dt1 dt2
  | _, _ -> subtype_err "val type" (pp_val_type ctx vt1) (pp_val_type ctx vt2)

and subtype_val_type_option (ctx : ctx)
    (vt1 : val_type option) (vt2 : val_type option) : unit
  = match vt1, vt2 with
  | None, None -> ()
  | None, Some vt -> raise (Invalid (no_region,
                                     "Expected " ^ pp_val_type ctx vt
                                     ^ ", got nothing."))
  | Some _, None -> ()
  | Some vt1, Some vt2 -> subtype_val_type ctx vt1 vt2

and subtype_func_ios (ctx : ctx) (fi1 : func_ios) (fi2 : func_ios) : unit
  = match fi1, fi2 with
  | Fio_one vt1, Fio_one vt2 -> subtype_val_type ctx vt1 vt2
  | Fio_many vts1, Fio_many vts2 ->
     List.iter (fun (vn2, vt2) ->
         try let (_, vt1) = List.find (fun (vn1, _) -> vn1.it = vn2.it) vts1
             in subtype_val_type ctx vt1 vt2
         with | Not_found ->
                 raise (Invalid (no_region,
                                 "Could not find function argument " ^ vn2.it)))
       vts2
  | _, _ ->
     raise (Invalid (no_region, "Cannot match Fio_one against Fio_many"))

and subtype_func_type (ctx : ctx) (ft1 : func_type) (ft2 : func_type) : unit
  = subtype_func_ios ctx ft2.ft_params ft1.ft_params;
    subtype_func_ios ctx ft1.ft_result ft2.ft_result

and iibb_search_inst
      (ctx : ctx) (exps : extern_decl list) (i : int) (ed : extern_decl)
  =
  let find_ed' () =
    List.find (fun x -> x.ed_name.it.en_name.it = ed.ed_name.it.en_name.it)
      exps in
  match ed.ed_desc with
  | ED_type (DT_var (TV_bound i')) when i = i' -> (* jackpot! *)
     let ed' = find_ed' () in
     (match ed'.ed_desc with
      | ED_type dt -> Some dt
      | _ -> raise (Invalid (ed'.ed_name.at,
                             "Cannot instantiate type import "
                             ^ ed.ed_name.it.en_name.it ^ "with non-type")))
  | ED_instance it ->
     let ed' = find_ed' () in
     (match ed'.ed_desc with
      | ED_instance it' ->
         List.find_map (iibb_search_inst ctx it'.it_exports (i + List.length it.it_evars))
           it.it_exports
      | _ -> raise (Invalid (ed'.ed_name.at,
                             "Cannot instantiate instance import "
                             ^ ed.ed_name.it.en_name.it ^ "with non-instance")))
  | _ -> None

and matchit_bvar_binding (ctx : ctx)
      (es : extern_decl list) (is : extern_decl list)
      (i : int) (v : boundedtyvar)
    : def_type
  = match v with
  | Tbound_eq dt -> dt
  | Tbound_subr ->
     match List.find_map (iibb_search_inst ctx es i) is with
     | None -> raise (Invalid (no_region, "!! Impossible: un-exported evar"))
     | Some dt -> dt

and matchit_bvar_bindings (ctx : ctx)
      (es : extern_decl list) (it : instance_type)
    : bsubst
  = List.mapi (fun i v -> Some (matchit_bvar_binding ctx es it.it_exports i v))
      (List.rev it.it_evars)

and match_instance_type (ctx : ctx)
      (es : extern_decl list) (it : instance_type)
    : bsubst
  = if subtype_trace
    then (emit_extern_decls ctx es;
          emit_newline "  <: ";
          with_indent_here (fun () -> emit_instance_type ctx it);
          emit_newline "");
    let evar_insts = matchit_bvar_bindings ctx es it in
    let es' = List.map (subst_extern_decl (bsubst_subst evar_insts))
                it.it_exports in
    subtype_extern_decls ctx es es';
    evar_insts

and subtype_instance_type (ctx : ctx)
      (it1 : instance_type) (it2 : instance_type)
    : unit
  = if subtype_trace
    then (emit_instance_type ctx it1;
          emit_newline "  <: ";
          with_indent_here (fun () -> emit_instance_type ctx it2);
          emit_newline "");
    let ctx', bsubst = bound_to_uvars ctx false it1.it_evars in
    let it1es
      = List.map (subst_extern_decl (bsubst_subst bsubst)) it1.it_exports in
    let _ = match_instance_type ctx' it1es it2 in
    ()

and subtype_component_type (ctx : ctx)
      (ct1 : component_type) (ct2 : component_type)
    : unit
  = if subtype_trace
    then (emit_component_type ctx ct1;
          emit_newline "  <: ";
          with_indent_here (fun () -> emit_component_type ctx ct2);
          emit_newline "");
    let ctx', bsubst = bound_to_uvars ctx false ct2.ct_uvars in
    let ct2imes =
      List.map (subst_extern_decl (bsubst_subst bsubst)) ct2.ct_imports in
    let ct2in' =
      subst_instance_type (bsubst_subst bsubst) ct2.ct_instance in
    let ct1im' = { it_evars = ct1.ct_uvars; it_exports = ct1.ct_imports } in
    let ct1subst = match_instance_type ctx' ct2imes ct1im' in
    let ct1in' = subst_instance_type (bsubst_subst ct1subst) ct1.ct_instance in
    subtype_instance_type ctx' ct1in' ct2in'

and subtype_var_var (ctx : ctx) (v1 : tyvar) (v2 : tyvar) : unit
  = match resolve_tyvar ctx v1, resolve_tyvar ctx v2 with
  | RTV_definite dt1, RTV_definite dt2 ->
     subtype_def_type ctx dt1 dt2
  | RTV_uvar (o1, i1, _), RTV_uvar (o2, i2, _) ->
     if o1 = o2 && i1 = i2
     then ()
     else raise (Invalid (no_region,
                          pp_string (fun () ->
                              emit "Type variable ";
                              emit ("u" ^ string_of_int o1 ^ "."
                                    ^ string_of_int i1);
                              emit " is not ";
                              emit ("u" ^ string_of_int o2 ^ "."
                                    ^ string_of_int i2))))
  | RTV_evar (o1, i1, _), RTV_evar (o2, i2, _) ->
     if o1 = o2 && i1 = i2
     then ()
     else raise (Invalid (no_region,
                          pp_string (fun () ->
                              emit "Type variable ";
                              emit ("e" ^ string_of_int o1 ^ "."
                                    ^ string_of_int i1);
                              emit " is not ";
                              emit ("e" ^ string_of_int o2 ^ "."
                                    ^ string_of_int i2))))
  | RTV_bound _, _
    | _, RTV_bound _ ->
     raise (Invalid (no_region, "!! Impossible: extra bvar in subtype_var"))
  | _, _ ->
     raise (Invalid (no_region, "Variable is not subtype"))

and subtype_var_def_type (ctx : ctx) (tv : tyvar) (dt : def_type) : unit
  = match resolve_tyvar ctx tv with
  | RTV_definite dt' -> subtype_def_type ctx dt' dt
  | _ -> raise (Invalid (no_region, "Variable cannot match def_type"))
and subtype_def_type_var (ctx : ctx) (dt : def_type) (tv : tyvar) : unit
  = match resolve_tyvar ctx tv with
  | RTV_definite dt' -> subtype_def_type ctx dt dt'
  | _ -> raise (Invalid (no_region, "Variable cannot match def_type"))

and subtype_def_type (ctx : ctx) (dt1 : def_type) (dt2 : def_type) : unit
  = match dt1, dt2 with
  | DT_var tv1, DT_var tv2 -> subtype_var_var ctx tv1 tv2
  | DT_var tv, _ -> subtype_var_def_type ctx tv dt2
  | _, DT_var tv -> subtype_def_type_var ctx dt1 tv
  | DT_resource_type i1, DT_resource_type i2 ->
     if i1 = i2 then ()
     else raise (Invalid (no_region, "Resource type " ^ Int32.to_string i1
                                     ^ " is not " ^ Int32.to_string i2))
  | DT_val_type vt1, DT_val_type vt2 -> subtype_val_type ctx vt1 vt2
  | DT_func_type ft1, DT_func_type ft2 -> subtype_func_type ctx ft1 ft2
  | DT_instance_type it1, DT_instance_type it2 ->
     subtype_instance_type ctx it1 it2
  | DT_component_type ct1, DT_component_type ct2 ->
     subtype_component_type ctx ct1 ct2
  | _, _ -> raise (Invalid (no_region, "Def type " ^ pp_def_type ctx dt1
                                       ^ " is not of the same sort as "
                                       ^ pp_def_type ctx dt2))

and subtype_extern_desc (ctx : ctx)
      (ed1 : extern_desc) (ed2 : extern_desc)
    : unit
  = match ed1, ed2 with
  | ED_core_module cmt1, ED_core_module cmt2 ->
     subtype_core_module_type ctx cmt1 cmt2
  | ED_func ft1, ED_func ft2 ->
     subtype_func_type ctx ft1 ft2
  | ED_value vt1, ED_value vt2 ->
     subtype_val_type ctx vt1 vt2
  | ED_type dt1, ED_type dt2 ->
     subtype_def_type ctx dt1 dt2 (* TODO CHECK - this should be right
                                     though, I think *)
  | ED_instance it1, ED_instance it2 ->
     subtype_instance_type ctx it1 it2
  | ED_component ct1, ED_component ct2 ->
     subtype_component_type ctx ct1 ct2
  | _, _ -> raise (Invalid (no_region, "Extern desc "
                                       ^ pp_extern_desc ctx ed1
                                       ^ " is not of the same sort as "
                                       ^ pp_extern_desc ctx ed2))

and subtype_extern_decls' (ctx : ctx)
      (eds1 : extern_decl list) (ed2 : extern_decl)
    : unit
  = try
    let ed1 = List.find (fun x -> x.ed_name.it.en_name.it = ed2.ed_name.it.en_name.it) eds1 in
    subtype_extern_desc ctx ed1.ed_desc ed2.ed_desc
  with Not_found ->
    raise (Invalid (no_region,
                    pp_string (fun () ->
                        emit "No extern desc named ";
                        emit ed2.ed_name.it.en_name.it;
                        emit " in ";
                        emit_extern_decls ctx eds1)))
and subtype_extern_decls (ctx : ctx)
      (eds1 : extern_decl list) (eds2 : extern_decl list)
    : unit
  = if subtype_trace
    then (emit_extern_decls ctx eds1;
          emit_newline "  <: ";
          with_indent_here (fun () -> emit_extern_decls ctx eds2);
          emit_newline "");
    List.iter (subtype_extern_decls' ctx eds1) eds2

and def_type_is_resource (ctx : ctx) (dt : def_type) : unit
  = match dt with
  | DT_var tv ->
     (match resolve_tyvar ctx tv with
      | RTV_definite dt' -> def_type_is_resource ctx dt'
      | RTV_bound _ ->
         raise (Invalid (no_region, "!! Impossible: extra bvar in dtir"))
      | RTV_uvar (_, _, Tbound_subr) -> ()
      | RTV_evar (_, _, Tbound_subr) -> ()
      | _ -> raise (Invalid (no_region,
                             "Tyvar does not resolve to resource type")))
  | DT_resource_type i -> ()
  | _ -> raise (Invalid (no_region, "Def type " ^ pp_def_type ctx dt
                                    ^ "is not resource type"))
