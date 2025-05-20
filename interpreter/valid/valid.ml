module Source = Wasm.Source
open Source
open Ast
open Etypes
open Etype_pp
open Elaborate
open Substitute
open Subtype
module I = Ast.IntAst

exception Invalid = Etypes.Invalid

module CA = Wasm.Ast

let infer_core_import (ctx : ctx) (cmd : CA.module_) (i : CA.import)
    : core_import_decl
  = { cid_name1 = Wasm.Utf8.encode i.it.CA.module_name @@ i.at
    ; cid_name2 = Wasm.Utf8.encode i.it.CA.item_name @@ i.at
    ; cid_desc = Wasm.Ast.import_type cmd i
    }
let infer_core_export (ctx : ctx) (cmd : CA.module_) (e : CA.export)
    : core_export_decl
  = { ced_name = Wasm.Utf8.encode e.it.CA.name @@ e.at
    ; ced_desc = Wasm.Ast.export_type cmd e
    }
let infer_core_module (ctx : ctx) (cmd : Wasm.Ast.module_) : core_module_type
  =
  { cmt_imports = List.map (infer_core_import ctx cmd) cmd.it.CA.imports
  ; cmt_instance = {
      cit_exports = List.map (infer_core_export ctx cmd) cmd.it.CA.exports
    }
  }

let check_uniqueness_ : 'a. string -> ('a -> string) -> 'a phrase list -> 'a phrase -> unit
  = fun err project all this ->
  if (List.length
        (List.filter (fun this' -> project this'.it = project this.it) all)
      <> 1)
  then raise (Invalid (this.at, err ^ project this.it))
  else ()
let check_uniqueness : 'a. string -> ('a -> string) -> 'a phrase list -> unit
  = fun err project all ->
  List.iter (check_uniqueness_ err project all) all

let find_core_instantiate_arg_named ctx cias name =
  try List.find (fun cia -> cia.it.I.c_ia_name.it = name.it) cias
  with Not_found ->
    raise (Invalid (name.at, "Expected to find instantiate arg " ^ name.it))
let find_core_export_named ctx cit name
  = try List.find (fun ced -> ced.ced_name.it = name.it) cit.cit_exports
    with Not_found ->
      raise (Invalid (name.at, "Expected to find export " ^ name.it))
let check_core_instantiate_import ctx cias cid
  = let cia = find_core_instantiate_arg_named ctx cias cid.cid_name1 in
    if (cia.it.I.c_ia_value.it.I.c_s_sort.it <> Ast.Core_instance)
    then raise (Invalid (cia.at, "Only two-level imports are suported"))
    else ();
    let cit = List.nth ctx.core_ctx.core_instances
                (Int32.to_int cia.it.I.c_ia_value.it.I.c_s_idx) in
    let ced = find_core_export_named ctx cit cid.cid_name2 in
    subtype_core_extern_desc ctx ced.ced_desc cid.cid_desc
let infer_core_export (ctx : ctx) (e : I.core_export) : core_export_decl
  = { ced_name = e.it.I.c_e_name
    ; ced_desc =
        let i = Int32.to_int e.it.I.c_e_value.it.I.c_s_idx in
        let open Wasm.Types in
        match e.it.I.c_e_value.it.I.c_s_sort.it with
        | Core_func -> ExternFuncType (List.nth ctx.core_ctx.core_funcs i)
        | Core_table -> ExternTableType (List.nth ctx.core_ctx.core_tables i)
        | Core_memory -> ExternMemoryType (List.nth ctx.core_ctx.core_mems i)
        | Core_global -> ExternGlobalType (List.nth ctx.core_ctx.core_globals i)
        | s -> raise (Invalid (e.at, "Cannot inline-export core sort "
                                     ^ show_core_sort' s))
    }
let infer_core_instance (ctx : ctx) (es : I.core_export list)
    : core_instance_type
  =  { cit_exports = List.map (infer_core_export ctx) es }
let infer_core_defn (ctx : ctx) (d : I.core_definition)
    : ctx
  = match d with
  | I.CoreModuleDef cmd ->
     let cmt = infer_core_module ctx cmd in
     { ctx with
       core_ctx = { ctx.core_ctx with
                    core_modules = ctx.core_ctx.core_modules @ [cmt] } }
  | I.CoreInstanceDef { it = I.Core_instantiate_module (cmid, cias);
                        at = at } ->
     let cmt = List.nth ctx.core_ctx.core_modules (Int32.to_int cmid) in
     List.iter (check_core_instantiate_import ctx cias) cmt.cmt_imports;
     check_uniqueness "Duplicate instantiate arg name "
       (fun x -> x.I.c_ia_name.it) cias;
     { ctx with
       core_ctx = { ctx.core_ctx with
                    core_instances = ctx.core_ctx.core_instances
                                     @ [cmt.cmt_instance]}}
  | I.CoreInstanceDef { it = I.Core_instantiate_inline es ; _ } ->
     check_uniqueness "Duplicate core export name "
       (fun x -> x.I.c_e_name.it) es;
     let i = infer_core_instance ctx es in
     { ctx with
       core_ctx = { ctx.core_ctx with
                    core_instances = ctx.core_ctx.core_instances @ [i] } }
  | I.CoreTypeDef cdt ->
     let t = elab_core_deftype_ ctx cdt in
     { ctx with
       core_ctx = { ctx.core_ctx with
                    core_types = ctx.core_ctx.core_types @ [t] } }

let rec mark_dead_sort_idxs (ctx : ctx) (sis : I.sort_idx list) : ctx
  = match sis with
  | [] -> ctx
  | si::sis' ->
     let ii = Int32.to_int si.it.I.s_idx in
     let ctx' = match si.it.I.s_sort.it with
       | Value ->
          { ctx with
            values =
              List.mapi (fun i vad ->
                  if i = ii
                  then (if not vad.ad_live
                        then raise (Invalid (si.at, "Cannot reuse dead value"))
                        else { vad with ad_live = false })
                  else vad) ctx.values }
       | Instance ->
          { ctx with
            instances =
              List.mapi (fun i iad ->
                  if i = ii
                  then
                    { itad_exports =
                        List.map (mark_dead_ed si.at) iad.itad_exports }
                  else iad) ctx.instances }
       | _ -> ctx
     in mark_dead_sort_idxs ctx' sis'
let mark_dead_ias (ctx : ctx) (ias : I.instantiate_arg list) : ctx
  = mark_dead_sort_idxs ctx (List.map (fun ia -> ia.it.I.ia_value) ias)
let mark_dead_ies (ctx : ctx) (ies : I.inline_export list) : ctx
  = mark_dead_sort_idxs ctx (List.map (fun ie -> ie.it.I.ie_value) ies)

let find_instantiate_arg_named (n : name) (ias : I.instantiate_arg list)
    : I.instantiate_arg
  = try List.find (fun ia -> ia.it.I.ia_name.it = n.it) ias
    with Not_found ->
      let at = match ias with | [] -> n.at | ia::_ -> ia.at in
      raise (Invalid (at, "Must provide import " ^ n.it))

let rec iibb_search_inst
      (ctx : ctx) (exps : extern_decl list) (i : int) (ed : extern_decl)
  =
  let find_ed' () =
    List.find (fun x -> x.ed_name.it.en_name.it = ed.ed_name.it.en_name.it)
      exps in
  match ed.ed_desc with
  | ED_type (DT_var (TV_bound i)) -> (* jackpot! *)
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
let iibb_search_ed
      (ctx : ctx) (ias : I.instantiate_arg list) (i : int) (ed : extern_decl)
    : def_type option
  =
  let find_ia () = find_instantiate_arg_named ed.ed_name.it.en_name ias in
  match ed.ed_desc with
  | ED_type (DT_var (TV_bound i)) -> (* jackpot! *)
     (match (find_ia ()).it.I.ia_value.it with
      | { I.s_sort = { it = Type ; _ } ; I.s_idx = ti } ->
         Some (List.nth ctx.types (Int32.to_int ti))
      | _ -> raise (Invalid ((find_ia ()).at,
                             "Cannot instantiate type import "
                             ^ ed.ed_name.it.en_name.it ^ "with non-type")))
  | ED_instance it ->
     (match (find_ia ()).it.I.ia_value.it with
      | { I.s_sort = { it = Instance ; _ } ; I.s_idx = ii } ->
         let inst = (List.nth ctx.instances (Int32.to_int ii)) in
         let exps = List.map (fun x -> x.ad_contents) inst.itad_exports in
         List.find_map (iibb_search_inst ctx exps (i + List.length it.it_evars))
           it.it_exports
      | _ -> raise (Invalid ((find_ia ()).at,
                             "Cannot instantiate instance import "
                             ^ ed.ed_name.it.en_name.it ^ "with non-instance")))
  | _ -> None
let infer_instantiate_bvar_binding
      (ctx : ctx) (is : extern_decl list) (ias : I.instantiate_arg list) (i : int) (v : boundedtyvar)
    : def_type
  = match v with
  | Tbound_eq dt -> dt
  | Tbound_subr ->
     match List.find_map (iibb_search_ed ctx ias i) is with
     | None -> raise (Invalid (no_region, "!! Impossible: un-imported uvar"))
     | Some dt -> dt
let infer_instantiate_bvar_bindings
      (ctx : ctx) (ct : component_type) (ias : I.instantiate_arg list) : bsubst
  = List.mapi (fun i v -> Some (infer_instantiate_bvar_binding ctx ct.ct_imports ias i v))
      (List.rev ct.ct_uvars)

let infer_sort_idx_ed (ctx : ctx) (si : I.sort_idx) : extern_desc
  =
  let i = Int32.to_int si.it.I.s_idx in
  match si.it.I.s_sort.it with
  | CoreSort { it = Core_module ; _ } ->
     ED_core_module (List.nth ctx.core_ctx.core_modules i)
  | Func -> ED_func (List.nth ctx.funcs i)
  | Value -> ED_value (List.nth ctx.values i).ad_contents
  | Type -> ED_type (List.nth ctx.types i)
  | Instance ->
     ED_instance
       { it_evars = []; it_exports = List.map (fun x -> x.ad_contents)
                                       (List.nth ctx.instances i).itad_exports }
  | Component -> ED_component (List.nth ctx.components i)
  | _ -> raise (Invalid (si.at, "Cannot instantiate an import with sort "
                                ^ show_sort' si.it.I.s_sort.it))

let check_instantiate_import (ctx : ctx) (ias : I.instantiate_arg list) (im : extern_decl) : unit
  = let ia = find_instantiate_arg_named im.ed_name.it.en_name ias in
    let ed = infer_sort_idx_ed ctx ia.it.I.ia_value in
    pp_begin ();
    subtype_extern_desc ctx ed im.ed_desc;
    let _ = pp_end () in ()

let max_flat_params : int = 16
let max_flat_results : int = 1

let rec flatten_val_type (vt : val_type) : Wasm.Types.result_type
  = let open Wasm.Types in
    match vt with
    | Bool -> [NumType I32Type]
    | Unsigned VI_8 | Unsigned VI_16 | Unsigned VI_32
      | Signed VI_8 | Signed VI_16 | Signed VI_32 ->
       [NumType I32Type]
    | Unsigned VI_64 | Signed VI_64 ->
       [NumType I64Type]
    | Float VF_32 -> [NumType F32Type]
    | Float VF_64 -> [NumType F64Type]
    | Char -> [NumType I32Type]
    | List _ -> [NumType I32Type; NumType I32Type]
    | Record rfs -> List.concat_map flatten_record_field rfs
    | Variant vcs -> flatten_variant vcs
    | Own _ | Borrow _ -> [NumType I32Type]
and flatten_record_field (rf : record_field) : Wasm.Types.result_type
  = flatten_val_type rf.rf_type
and flatten_variant (vcs : variant_case list) : Wasm.Types.result_type
  = flatten_variant_discriminant (List.length vcs)
    @ flatten_variant_merge (List.map flatten_variant_case vcs)
and variant_discriminant (n : int) : val_type
  = Unsigned
      (if n <= 256
       then VI_8
       else if n <= 65536
       then VI_16
       else if n <= 4294967296
       then VI_32
       else raise (Invalid (no_region, "Cannot have " ^ string_of_int n)))
and flatten_variant_discriminant (n : int) : Wasm.Types.result_type
  = flatten_val_type (variant_discriminant n)
and flatten_variant_case (vc : variant_case) : Wasm.Types.result_type
  = match vc.vc_type with
  | None -> []
  | Some vt -> flatten_val_type vt
and flatten_variant_merge (ts : Wasm.Types.result_type list)
    : Wasm.Types.result_type
  = match ts with
  | [] -> []
  | ts1::ts2s ->
     let ts2 = flatten_variant_merge ts2s in
     flatten_variant_merge_rts ts1 ts2
and flatten_variant_merge_rts
      (ts1 : Wasm.Types.result_type) (ts2 : Wasm.Types.result_type)
    : Wasm.Types.result_type
  = match ts1, ts2 with
  | [], _ -> ts2
  | _, [] -> ts1
  | t1::t1s, t2::t2s ->
     (flatten_variant_merge_ts t1 t2)::(flatten_variant_merge_rts t1s t2s)
and flatten_variant_merge_ts
      (t1 : Wasm.Types.value_type) (t2 : Wasm.Types.value_type)
    : Wasm.Types.value_type
  = let open Wasm.Types in
    if t1 = t2 then t1
    else if (t1 = NumType I32Type && t2 = NumType F32Type)
            || (t1 = NumType F32Type && t2 = NumType I32Type)
    then NumType I32Type
    else NumType I64Type

let flatten_func_ios (fio : func_ios) : Wasm.Types.result_type
  = match fio with
  | Fio_one vt -> flatten_val_type vt
  | Fio_many nvts ->
     List.concat_map (fun (n, vt) -> flatten_val_type vt) nvts

let flatten_func_type (is_lower : bool) (ft : func_type)
    : core_func_type
  = let open Wasm.Types in
    let ps = flatten_func_ios ft.ft_params in
    let ps' = if List.length ps > max_flat_params
              then [NumType I32Type] else ps in
    let rs = flatten_func_ios ft.ft_result in
    let (ps'', rs') =
      if List.length rs > max_flat_results
      then if is_lower
           then (ps' @ [NumType I32Type], [])
           else (ps', [NumType I32Type])
      else (ps', rs) in
    FuncType (ps'', rs')

let check_canon_opts (ctx : ctx) (os : I.canon_opt list) : unit
  = ()

let fio_vts fio
  = match fio with
  | Fio_one vt -> [vt]
  | Fio_many vts -> List.map (fun (n, vt) -> vt) vts

let check_exportable (ctx : ctx) (ed : extern_desc) : unit
  = wf_extern_desc ctx { pos_param = false; pos_export = true; } ed

let rec infer_component_defn (ctx : ctx) (d : I.definition)
    : ctx * extern_decl option * extern_decl option
  = match d.it with
  | I.CoreDef cd -> (infer_core_defn ctx cd, None, None)
  | I.ComponentDef c ->
     let ct = infer_component ctx c in
     ({ ctx with components = ctx.components @ [ct] }, None, None)
  | I.InstanceDef ({ it = I.Instantiate_component (cid, ias) ; _ }) ->
     let ct = List.nth ctx.components (Int32.to_int cid) in
     check_uniqueness "Duplicate instantiate arg name "
       (fun x -> x.I.ia_name.it) ias;
     let uvar_insts = infer_instantiate_bvar_bindings ctx ct ias in
     let ct_imports = List.map (subst_extern_decl (bsubst_subst uvar_insts))
                        ct.ct_imports in
     let ct_instance = subst_instance_type (bsubst_subst uvar_insts)
                         ct.ct_instance in
     List.iter (check_instantiate_import ctx ias) ct_imports;
     let ctx' = instance_to_context ctx true false ct_instance in
     let ctx'' = mark_dead_ias ctx' ias in
     (ctx'', None, None)
  | I.InstanceDef ({ it = I.Instantiate_inline ies; _ }) ->
     check_uniqueness "Duplicate inline export name "
       (fun x -> x.I.ie_name.it.en_name.it) ies;
     let ctx' = mark_dead_ies ctx ies in
     ({ ctx' with
        instances =
          ctx'.instances @
            [ { itad_exports =
                  List.map (fun ie ->
                      make_live { ed_name = ie.it.I.ie_name
                                ; ed_desc = infer_sort_idx_ed ctx
                                              ie.it.I.ie_value
                        }) ies } ] }, None, None)
  | I.AliasDef a ->
     let ctx', at = resolve_alias ctx a in
     (match a.it.I.a_sort.it, at with
      | CoreSort { it = Core_module; _ }, Either.Left (CT_module cmt) ->
         ({ ctx' with
            core_ctx = { ctx'.core_ctx with
                         core_modules = ctx'.core_ctx.core_modules
                                        @ [ cmt ] } }, None, None)
      | CoreSort { it = Core_type; _ }, Either.Left ct ->
         ({ ctx' with
            core_ctx = { ctx'.core_ctx with
                         core_types = ctx'.core_ctx.core_types
                                      @ [ ct ] } }, None, None)
      | CoreSort { it = Core_table; _}, Either.Left (CT_table tt) ->
         ({ ctx' with
            core_ctx = { ctx'.core_ctx with
                         core_tables = ctx'.core_ctx.core_tables
                                       @ [ tt ] } }, None, None)
      | CoreSort { it = Core_memory; _}, Either.Left (CT_memory mt) ->
         ({ ctx' with
            core_ctx = { ctx'.core_ctx with
                         core_mems = ctx'.core_ctx.core_mems
                                     @ [ mt ] } }, None, None)
      | CoreSort { it = Core_global; _}, Either.Left (CT_global gt) ->
         ({ ctx' with
            core_ctx = { ctx'.core_ctx with
                         core_globals = ctx'.core_ctx.core_globals
                                      @ [ gt ] } }, None, None)
      | CoreSort { it = Core_func; _}, Either.Left (CT_func ft) ->
         ({ ctx' with
            core_ctx = { ctx'.core_ctx with
                         core_funcs = ctx'.core_ctx.core_funcs
                                      @ [ ft ] } }, None, None)
      | Func, Either.Right (DT_func_type ft) ->
         ({ ctx' with funcs = ctx'.funcs @ [ ft ] }, None, None)
      | Value, Either.Right (DT_val_type vt) ->
         ({ ctx' with values = ctx'.values @ [ make_live vt ]
          }, None, None)
      | Type, Either.Right dt -> ({ ctx' with types = ctx'.types @ [ dt ] }
                                 ,None, None)
      | Instance, Either.Right (DT_instance_type it) ->
         (instance_to_context ctx' true false it, None, None)
      | Component, Either.Right (DT_component_type ct) ->
         ({ ctx' with components = ctx'.components @ [ ct ] }, None, None)
      | _, _ -> raise (Invalid (a.at, "!! Impossible: resolve_alias bad sort")))
  | I.TypeDef { it = I.Deftype_rsrc dtor; _ } ->
  (* This is the only place that resource types are valid,
     and they are generative here *)
     let i = Int32.of_int (List.length ctx.rtypes) in
     ({ ctx with
        rtypes = ctx.rtypes @ [ { rt_dtor = dtor } ];
        types = ctx.types @ [ DT_resource_type i ] }
     ,None, None)
  | I.TypeDef dt ->
     let dt' = elab_def_type ctx dt in
     ({ ctx with types = ctx.types @ [ dt' ] }, None, None)
  | I.CanonDef { it = I.Canon_lift (cfid, ed, cos); _ } ->
     let cfit = List.nth ctx.core_ctx.core_funcs (Int32.to_int cfid) in
     (match elab_extern_desc ctx ed with
      | ([], ED_func fit) ->
         subtype_core_extern_desc ctx (Wasm.Types.ExternFuncType cfit)
           (Wasm.Types.ExternFuncType (flatten_func_type false fit));
         check_canon_opts ctx cos;
         ({ ctx with funcs = ctx.funcs @ [ fit ] }, None, None)
      | _ -> raise (Invalid (d.at, "Canon lift externdesc must be func")))
  | I.CanonDef { it = I.Canon_lower (fid, cos); _ } ->
     let ft = List.nth ctx.funcs (Int32.to_int fid) in
     let cft = flatten_func_type true ft in
     check_canon_opts ctx cos;
     ({ ctx with
        core_ctx = { ctx.core_ctx with
                     core_funcs = ctx.core_ctx.core_funcs @ [ cft ] } }
     ,None, None)
  | I.CanonDef { it = I.Canon_resource_builtin { it = I.CRB_new dt; _ }; _ } ->
     let dt' = resolve_type_use ctx dt in
     (match dt' with
      | DT_resource_type i -> ()
      | _ -> raise (Invalid (d.at, "Canon resource.new requires a resource "
                                   ^ "type defined in this component")));
     let open Wasm.Types in
     let cft = FuncType ([NumType I32Type], [NumType I32Type]) in
     ({ ctx with
        core_ctx = { ctx.core_ctx with
                     core_funcs = ctx.core_ctx.core_funcs @ [ cft ] } }
     ,None, None)
  | I.CanonDef { it = I.Canon_resource_builtin { it = I.CRB_drop vt; _ }; _ } ->
     let vt' = resolve_val_type_use ctx d.at vt in
     (match vt' with
      | Own _ | Borrow _ -> ()
      | _ -> raise (Invalid (d.at, "Canon resource.drop requuires a resource "
                                   ^ "handle type")));
     let open Wasm.Types in
     let cft = FuncType ([NumType I32Type], []) in
     ({ ctx with
        core_ctx = { ctx.core_ctx with
                     core_funcs = ctx.core_ctx.core_funcs @ [ cft ] } }
     ,None, None)
  | I.CanonDef { it = I.Canon_resource_builtin { it = I.CRB_rep dt; _ }; _ } ->
     let dt' = resolve_type_use ctx dt in
     (match dt' with
      | DT_resource_type i -> ()
      | _ -> raise (Invalid (d.at, "Canon resource.rep requires a resource "
                                   ^ "type defined in this component")));
     let open Wasm.Types in
     let cft = FuncType ([NumType I32Type], [NumType I32Type]) in
     ({ ctx with
        core_ctx = { ctx.core_ctx with
                     core_funcs = ctx.core_ctx.core_funcs @ [ cft ] } }
     ,None, None)
  | I.StartDef { it = sd; _ } ->
     let ft = List.nth ctx.funcs (Int32.to_int sd.I.s_func) in
     let vts = fio_vts ft.ft_params in
     let vts' = List.map (fun i ->
                    (List.nth ctx.values (Int32.to_int i)).ad_contents)
                  sd.I.s_params in
     List.iter2 (subtype_val_type ctx) vts' vts;
     let ctx' = mark_dead_sort_idxs ctx
                  (List.map (fun i -> { I.s_sort = Value @@ no_region
                                      ; I.s_idx = i } @@ no_region)
                     sd.I.s_params) in
     let rvts = fio_vts ft.ft_result in
     let nftr = List.length rvts in
     let nftr' = List.length sd.I.s_result in
     (if nftr <> nftr'
      then raise (Invalid (d.at, "Start definition calls function returning "
                                 ^ string_of_int nftr ^ " results, but "
                                 ^ " expects to have "
                                 ^ string_of_int nftr' ^ " results"))
      else ());
     ({ ctx' with values = ctx'.values @ List.map make_live rvts }
     ,None, None)
  | I.ImportDef { it = { I.i_name = ni; I.i_type = it; }; _ } ->
     let v, ed' = elab_extern_desc ctx it in
     let ctx', bsub = bound_to_uvars ctx true v in
     let ed'' = subst_extern_desc (bsubst_subst bsub) ed' in
     (add_extern_desc_to_ctx ctx' true true ed''
     ,Some { ed_name = ni ; ed_desc = ed'' }, None)
  | I.ExportDef { it = { I.e_name = en; I.e_value = si; I.e_type = et }; _ } ->
     let ed = infer_sort_idx_ed ctx si in
     let vs, ed' = match et with
       | None -> ([], ed)
       | Some ed' -> elab_extern_desc ctx ed' in
     let ctx', ed'' = match vs, ed', ed with
       | [v], ED_type (DT_var (TV_bound 0)), ED_type dt ->
          ({ ctx with
             evars = ctx.evars @ [ (v, Some dt) ] }
           ,ED_type (DT_var (TV_free (FTV_evar (0, List.length ctx.evars)))))
       | _, ED_instance it, _ ->
          (ctx, ED_instance { it_evars = vs; it_exports = it.it_exports })
       | [], _, _ -> (ctx, ed')
       | _, _, _ ->
          raise (Invalid (d.at, "Exported type should not have evars"
                                ^ " unless it is a `type` or `instance`")) in
     subtype_extern_desc ctx' ed ed'';
     check_exportable ctx' ed'';
     let ctx'' = mark_dead_sort_idxs ctx' [si] in
     let ctx''' = add_extern_desc_to_ctx ctx'' false false ed'' in
     (ctx''', None, Some { ed_name = en; ed_desc = ed'' })

and ctx_no_live_vals (ctx : ctx) : unit
  =
  let check_this : 'a. ('a alive_dead) -> unit
    = fun ad ->
    if ad.ad_live
    then raise (Invalid (no_region,
                         "All values must be dead at end of component!"))
    else () in
  let check_export_decl (ed : extern_decl_ad) : unit
    = match ed.ad_contents.ed_desc with
    | ED_value _ -> check_this ed
    | ED_instance _ -> check_this ed
    | _ -> () in
  let check_itad (itad : instance_type_ad) : unit
    = let _ = List.map check_export_decl itad.itad_exports in () in
  let _ = List.map check_this ctx.values in
  let _ = List.map check_itad ctx.instances in
  ()

and infer_component (ctx : ctx) (c : I.component) : component_type
  = build_component_type infer_component_defn ctx_no_live_vals ctx true
      c.it.I.defns
