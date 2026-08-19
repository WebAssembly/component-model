open Ast
module Source = Wasm.Source
open Source
module V = struct
  include Ast.VarAst
  include Ast.Var
end
module I = struct
  include Ast.IntAst
  include Ast.Int32_AstParams
end

module CoreCtx = Wasm.ParseUtil
module VarMap = CoreCtx.VarMap
type space = CoreCtx.space
  = {mutable map : int32 VarMap.t; mutable count : int32}
let empty () = {map = VarMap.empty; count = 0l}
type core_types = {ct_space : space; mutable ct_list : I.core_deftype_ list}
let empty_core_types () = {ct_space = empty (); ct_list = []}

let atmap'
      (f : 'a -> Source.region -> 'b)
      (x : 'a Source.phrase)
    : 'b Source.phrase
  = { Source.it = f x.Source.it x.Source.at; Source.at = x.Source.at; }
let atmap (f : 'a -> 'b) : 'a Source.phrase -> 'b Source.phrase
  = atmap' (fun x r -> f x)

let unimplemented err = raise (Sys_error ("Unimplemented " ^ err))

type core_ctx =
  { core_types     : core_types
  ; core_funcs     : space
  ; core_modules   : space
  ; core_instances : space
  ; core_tables    : space
  ; core_mems      : space
  ; core_globals   : space
  }
let empty_core_ctx () =
  { core_types     = empty_core_types ()
  ; core_funcs     = empty ()
  ; core_modules   = empty ()
  ; core_instances = empty ()
  ; core_tables    = empty ()
  ; core_mems      = empty ()
  ; core_globals   = empty ()
  }

type ctx_for_definition
type ctx_for_core_module_decl
type ctx_for_component_decl
type _ desugar_def =
  | DD_def : I.definition -> ctx_for_definition desugar_def
  | DD_cmd : I.core_moduledecl -> ctx_for_core_module_decl desugar_def
  | DD_cd : I.instance_decl -> ctx_for_component_decl desugar_def
let from_def_dd (def : ctx_for_definition desugar_def) : I.definition
  = match def with
  | DD_def d -> d
let from_cmd_dd (def : ctx_for_core_module_decl desugar_def) : I.core_moduledecl
  = match def with
  | DD_cmd d -> d
let from_cd_dd_i (def : ctx_for_component_decl desugar_def) : I.instance_decl
  = match def with
  | DD_cd d -> d
let from_cd_dd (def : ctx_for_component_decl desugar_def) : I.component_decl
  = let id = from_cd_dd_i def in
    I.Component_instance id @@ id.at
type some_ctx =
  | SC : 'a ctx -> some_ctx
and 'a ctx =
  { parent     : some_ctx option
  ; name       : var option
  ; core_ctx   : core_ctx
  ; types      : space
  ; components : space
  ; instances  : space
  ; funcs      : space
  ; values     : space
  ; mutable desugar_defs_pre : 'a desugar_def list
  ; mutable desugar_defs_post : 'a desugar_def list
  }
type definition_ctx = ctx_for_definition ctx
type core_module_decl_ctx = ctx_for_core_module_decl ctx
type component_decl_ctx = ctx_for_component_decl ctx

let empty_ctx_ parent name =
  { parent       = parent
  ; name         = name
  ; core_ctx     = empty_core_ctx ()
  ; types        = empty ()
  ; components   = empty ()
  ; instances    = empty ()
  ; funcs        = empty ()
  ; values       = empty ()
  ; desugar_defs_pre = []
  ; desugar_defs_post = []
  }
let empty_ctx () = empty_ctx_ None
let new_ctx parent = empty_ctx_ (Some parent)

let name_of_core_sort core_sort =
  "core " ^
    match core_sort.it with
    | Core_func -> "function"
    | Core_table -> "table"
    | Core_memory -> "memory"
    | Core_global -> "global"
    | Core_type -> "type"
    | Core_module -> "module"
    | Core_instance -> "instance"
let space_of_core_sort core_ctx core_sort =
  match core_sort.it with
  | Core_func -> core_ctx.core_funcs
  | Core_table -> core_ctx.core_tables
  | Core_memory -> core_ctx.core_mems
  | Core_global -> core_ctx.core_globals
  | Core_type -> core_ctx.core_types.ct_space
  | Core_module -> core_ctx.core_modules
  | Core_instance -> core_ctx.core_instances
let name_of_sort sort =
  match sort.it with
  | CoreSort cs -> name_of_core_sort cs
  | Func -> "func"
  | Value -> "value"
  | Type -> "type"
  | Component -> "component"
  | Instance -> "instance"
let space_of_sort ctx sort =
  match sort.it with
  | CoreSort cs -> space_of_core_sort ctx.core_ctx cs
  | Func -> ctx.funcs
  | Value -> ctx.values
  | Type -> ctx.types
  | Component -> ctx.components
  | Instance -> ctx.instances

(* TODO: 2^32 range checks in various places in both here and the written
   version *)
let anon ctx sort n =
  let space = space_of_sort ctx sort in
  let i = space.count in
  space.count <- Int32.add i n;
  if Wasm.I32.lt_u space.count n then
    Putil.error Source.no_region
      ("too many " ^ name_of_sort sort ^ " bindings");
  i


let to_outer_name (b : V.binder) : var option
  = match b with
  | V.Var_binder v -> Some v
  | _ -> None

type 'c export_func = 'c ctx -> sort -> externname -> I.ident -> unit
let bind_ : 'c. 'c export_func -> 'c ctx -> sort -> V.binder -> unit
  = fun export_func ctx sort x ->
  let space = space_of_sort ctx sort in
  let i = anon ctx sort 1l in
  match x with
  | V.No_binder -> ()
  | V.Var_binder v -> space.map <- VarMap.add v.it i space.map
  | V.Export_binders ns -> ignore (List.map (fun n -> export_func ctx sort n i) ns)
let bind_export_def ctx sort n i
  = ctx.desugar_defs_post <-
      DD_def (I.ExportDef ({ I.e_name = n;
                             I.e_value = { I.s_sort = sort; I.s_idx = i; }
                                         @@ no_region;
                             I.e_type = None }
                           @@ no_region)
              @@ no_region)
       ::ctx.desugar_defs_post
let bind = bind_ bind_export_def
let bind_export_no : 'c. 'c export_func
  = fun ctx srt n i -> Putil.error no_region "export binding not allowed here"
let bind_NE
    : 'c. 'c ctx -> sort -> V.binder -> unit
  = fun ctx sort x -> bind_ bind_export_no ctx sort x
let bind_type_ export_func ctx x t
  = bind_ export_func ctx (Type @@ t.at) x
let bind_type = bind_type_ bind_export_def
let bind_type_NE = bind_type_ bind_export_no
let bind_core_type_ export_func ctx x t
  = bind_ export_func ctx (CoreSort (Core_type @@ t.at) @@ t.at) x;
    ctx.core_ctx.core_types.ct_list <-
      ctx.core_ctx.core_types.ct_list @ [t]
let bind_core_type = bind_core_type_ bind_export_def
let bind_core_type_NE = bind_core_type_ bind_export_no

type 'a make_alias_type =
  'a ctx -> sort -> region -> int32 -> int32 -> I.ident
let lookup_here ctx sort x =
  try
    Some (VarMap.find x.it (space_of_sort ctx sort).map)
  with Not_found -> None
let rec lookup_opt
        : 'a 'b. 'a make_alias_type -> 'a ctx -> 'b ctx -> int
          -> sort -> var -> I.ident option
  = fun make_alias ctx_orig ctx n sort x ->
  match lookup_here ctx sort x with
  | Some id -> Some (make_alias ctx_orig sort x.at (Int32.of_int n) id)
  | None -> match ctx.parent with
            | None -> None
            | Some (SC ctx') ->
               lookup_opt make_alias ctx_orig ctx' (n+1) sort x
let lookup_ (make_alias : 'a make_alias_type) (ctx : 'a ctx)
      (sort : sort) (x : var) =
  match lookup_opt make_alias ctx ctx 0 sort x  with
  | Some id -> id
  | None -> Putil.error x.at ("unknown " ^ name_of_sort sort ^ " " ^ x.it)
let make_alias_def ctx sort at oi id
  = if oi = 0l then id
    else (ctx.desugar_defs_pre <-
            DD_def (I.AliasDef ({ I.a_target = I.Alias_outer (oi, id) @@ at
                                ; I.a_sort = sort } @@ at) @@ at)
            ::ctx.desugar_defs_pre;
          anon ctx sort 1l)
let lookup = lookup_ make_alias_def
let make_alias_cmd ctx sort at oi id
  = match sort.it with
  | CoreSort s' ->
     if oi = 0l then id
     else (ctx.desugar_defs_pre <-
             DD_cmd (I.Core_md_aliasdecl
                       ({ I.c_a_target = I.Core_alias_outer (oi, id) @@ at
                        ; I.c_a_sort = s' } @@ at) @@ at)
             ::ctx.desugar_defs_pre;
           anon ctx sort 1l)
  | _ -> Putil.error sort.at ("can't reference non-core sort "
                               ^ name_of_sort sort ^ " in core:moduledecl")
let lookup_cmd = lookup_ make_alias_cmd
let make_alias_cd ctx sort at oi id
  = if oi = 0l then id
    else (ctx.desugar_defs_pre <-
            DD_cd (I.Instance_alias ({ I.a_target = I.Alias_outer (oi, id) @@ at
                                     ; I.a_sort = sort } @@ at) @@ at)
            ::ctx.desugar_defs_pre;
          anon ctx sort 1l)
let lookup_cd = lookup_ make_alias_cd
(* for alias stuff *)
let rec raw_lookup_n : 'a. 'a ctx -> int -> sort -> var -> I.ident
  = fun ctx n sort x ->
  if n = 0 then
    match lookup_here ctx sort x with
    | None -> Putil.error x.at ("Nothing named exists in that context")
    | Some idx -> idx
  else match ctx.parent with
       | None -> Putil.error x.at ("Fewer than " ^ string_of_int n
                                   ^ " surrounding contexts")
       | Some (SC ctx') -> raw_lookup_n ctx' (n-1) sort x
let rec find_parent_index : 'a. 'a ctx -> var -> int32
  = fun ctx var ->
  if Some var.it = Option.map (fun x -> x.it) ctx.name then 0l
  else match ctx.parent with
       | None -> Putil.error var.at ("No parent context named " ^ var.it)
       | Some (SC ctx') -> Int32.succ (find_parent_index ctx' var)

let rec desugar_ident
          (ctx : definition_ctx)
          (s : sort) (i : V.ident)
    : I.ident
  = match i with
  | V.Idx i -> i.it
  | V.Var v -> lookup ctx s v
  | V.Export (s', i, ns) ->
     let sort_eq a b = match a.it, b.it with
       | CoreSort aa, CoreSort bb -> aa.it = bb.it
       | _, _ -> a.it = b.it in
     if not (sort_eq s' s) then
       Putil.error s'.at ("sort_idx: export: " ^ name_of_sort s'
                          ^ " != " ^ name_of_sort s);
     let rgn = Putil.span_regions s'.at (List.hd (List.rev ns)).at in
     let if_core core noncore = match s'.it with
       | CoreSort _ -> core
       | _ -> noncore
     in
     let i_sort =
       if_core (CoreSort (Core_instance @@ rgn) @@ rgn) (Instance @@ rgn) in
     let i' = desugar_ident ctx i_sort i in
     let go i s'' n =
       let target =
         if_core (I.Alias_core_export (i, n)) (I.Alias_export (i, n)) in
       ctx.desugar_defs_pre <-
         DD_def (I.AliasDef ({ I.a_target = target @@ rgn
                             ; I.a_sort = s'' } @@ rgn)
                 @@ rgn)::ctx.desugar_defs_pre;
       anon ctx s'' 1l
     in
     let rec go' i ns = match ns with
       | [] -> Putil.error s.at "sort_idx: export: no names"
       | [n] -> go i s' n
       | n::ns -> let i' = go i i_sort n in go' i' ns
     in go' i' ns
  | _ -> Putil.error s.at "ident: unexpected inline instance"
let desugar_ident_cmd
      (ctx : core_module_decl_ctx) (s : sort) (i : V.ident)
    : I.ident
  = match i with
  | V.Idx i -> i.it
  | V.Var v -> lookup_cmd ctx s v
  | _ -> Putil.error s.at "ident: unexpected inline instance or export"
let rec desugar_ident_cd
      (ctx : component_decl_ctx) (s : sort) (i : V.ident)
    : I.ident
  = match i with
  | V.Idx i -> i.it
  | V.Var v -> lookup_cd ctx s v
  | V.Export (s', i, ns) ->
     let sort_eq a b = match a.it, b.it with
       | CoreSort aa, CoreSort bb -> aa.it = bb.it
       | _, _ -> a.it = b.it in
     if not (sort_eq s' s) then
       Putil.error s'.at ("sort_idx: export: " ^ name_of_sort s'
                          ^ " != " ^ name_of_sort s);
     let rgn = Putil.span_regions s'.at (List.hd (List.rev ns)).at in
     let if_core core noncore = match s'.it with
       | CoreSort _ -> core
       | _ -> noncore
     in
     let i_sort =
       if_core (CoreSort (Core_instance @@ rgn) @@ rgn) (Instance @@ rgn) in
     let i' = desugar_ident_cd ctx i_sort i in
     let go i s'' n =
       let target =
         if_core (I.Alias_core_export (i, n)) (I.Alias_export (i, n)) in
       ctx.desugar_defs_pre <-
         DD_cd (I.Instance_alias ({ I.a_target = target @@ rgn
                                  ; I.a_sort = s'' } @@ rgn)
                @@ rgn)::ctx.desugar_defs_pre;
       anon ctx s'' 1l
     in
     let rec go' i ns = match ns with
       | [] -> Putil.error s.at "sort_idx: export: no names"
       | [n] -> go i s' n
       | n::ns -> let i' = go i i_sort n in go' i' ns
     in go' i' ns
  | _ -> Putil.error s.at "ident: unexpected inline instance"

let desugar_sort_idx' (ctx : definition_ctx) (sc : V.sort_idx')
    : I.sort_idx'
  = { I.s_sort = sc.V.s_sort
    ; I.s_idx = desugar_ident ctx sc.V.s_sort sc.V.s_idx }
let desugar_sort_idx (ctx : definition_ctx) : V.sort_idx -> I.sort_idx
  = atmap (desugar_sort_idx' ctx)
let desugar_core_sort_idx' (ctx : definition_ctx) (sc : V.core_sort_idx')
  = { I.c_s_sort = sc.V.c_s_sort
    ; I.c_s_idx = desugar_ident ctx
                    (CoreSort sc.V.c_s_sort @@ sc.V.c_s_sort.at)
                    sc.V.c_s_idx }
let desugar_core_sort_idx (ctx : definition_ctx)
    : V.core_sort_idx -> I.core_sort_idx
  = atmap (desugar_core_sort_idx' ctx)

let desugar_core_export' (ctx : definition_ctx) (ce : V.core_export')
    : I.core_export'
  = { I.c_e_name = ce.V.c_e_name
    ; I.c_e_value = desugar_core_sort_idx ctx ce.V.c_e_value }
let desugar_core_export (ctx : definition_ctx)
    : V.core_export -> I.core_export
  = atmap (desugar_core_export' ctx)

let desugar_core_instantiate_arg_inline_instance
      (ctx : definition_ctx) (es : V.core_export list)
    : I.core_sort_idx
  = let at = Putil.span_regions (List.hd es).at (List.hd (List.rev es)).at in
    let es' = List.map (desugar_core_export ctx) es in
    ctx.desugar_defs_pre <-
      DD_def (I.CoreDef (I.CoreInstanceDef (I.Core_instantiate_inline es' @@ at))
              @@ at)::ctx.desugar_defs_pre;
    let cs = Core_instance @@ at in
    { I.c_s_sort = cs
    ; I.c_s_idx = anon ctx (CoreSort cs @@ at) 1l } @@ at
let desugar_core_instantiate_arg' (ctx : definition_ctx)
      (ia : V.core_instantiate_arg')
    : I.core_instantiate_arg'
  = { I.c_ia_name = ia.V.c_ia_name
    ; I.c_ia_value = match ia.V.c_ia_value.it.V.c_s_idx with
                     | V.CoreInlineInstance es ->
                        desugar_core_instantiate_arg_inline_instance ctx es
                     | _ -> desugar_core_sort_idx ctx ia.V.c_ia_value }
let desugar_core_instantiate_arg (ctx : definition_ctx)
    : V.core_instantiate_arg -> I.core_instantiate_arg
  = atmap (desugar_core_instantiate_arg' ctx)
let desugar_core_instance_expr'
      (ctx : definition_ctx) (ie : V.core_instance_expr') at
    : I.core_instance_expr'
  = match ie with
  | V.Core_instantiate_module (mid, args) ->
     I.Core_instantiate_module
       ( desugar_ident ctx (CoreSort (Core_module @@ at) @@ at) mid
       , List.map (desugar_core_instantiate_arg ctx) args)
  | V.Core_instantiate_inline es ->
     I.Core_instantiate_inline (List.map (desugar_core_export ctx) es)
let desugar_core_instance_expr (ctx : definition_ctx)
    : V.core_instance_expr -> I.core_instance_expr
  = atmap' (desugar_core_instance_expr' ctx)

let collect_core_space_binders at (cspace : Wasm.ParseUtil.space) : var list
  = List.map (fun (x, y) -> x @@ at)
      (Wasm.ParseUtil.VarMap.bindings cspace.Wasm.ParseUtil.map)
let collect_core_binders at (cctx : Wasm.ParseUtil.context) : var list
  = let open Wasm.ParseUtil in
    List.concat_map (collect_core_space_binders at)
      [cctx.types.space; cctx.tables; cctx.memories;
       cctx.funcs; cctx.locals; cctx.globals;
       cctx.datas; cctx.elems]
let core_ctx_for_ctx (ctx : core_module_decl_ctx)
    : CoreCtx.context
  = let index_functypes = fun i d ->
      match d.it with
      | I.Core_deftype__deftype cd ->
         (match cd.it with
          | I.Core_deftype_functype ft -> Some (i, ft))
      | _ -> None in
    let indexed_functypes =
      List.mapi (fun i' (i, d) -> (i, i', d))
        (List.filter_map (fun x -> x)
           (List.mapi index_functypes ctx.core_ctx.core_types.ct_list)) in
    let new_map = VarMap.filter_map
                    (fun n i ->
                      Option.map (fun (_, i', _) -> Int32.of_int i')
                        (List.find_opt (fun (i', _, _) -> Int32.to_int i == i')
                           indexed_functypes))
                    ctx.core_ctx.core_types.ct_space.map in
    let open CoreCtx in
    { (empty_context ())
    with CoreCtx.types =
           { space = { map = new_map
                     ; count = Int32.of_int (List.length indexed_functypes)
                     }
           ; list = List.map (fun (_, _, d) -> d) indexed_functypes
           }
    }
let desugar_core_externdesc (ctx : core_module_decl_ctx)
      (id : V.core_externdesc) at
    : I.core_externdesc * V.binder
  = let cctx = core_ctx_for_ctx ctx in
    let id' = id cctx () in
    let binder = match collect_core_binders at cctx with
      | [] -> V.No_binder
      | [v] -> V.Var_binder v
      | _ -> Putil.error at "Too many core binders" in
    ((cctx, id'), binder)
let desugar_core_importdecl' (ctx : core_module_decl_ctx)
      (id : V.core_importdecl') at
    : I.core_importdecl' * V.binder
  = let x, b = desugar_core_externdesc ctx id.V.c_id_ty at in
    { I.c_id_name1 = id.V.c_id_name1
    ; I.c_id_name2 = id.V.c_id_name2
    ; I.c_id_ty = x }, b
let desugar_core_importdecl (ctx : core_module_decl_ctx)
      (id : V.core_importdecl)
    : I.core_importdecl * V.binder
  = let x, b = desugar_core_importdecl' ctx id.it id.at in
    { it = x; at = id.at }, b
let desugar_core_deftype' (ctx : 'a ctx) (t : V.core_deftype')
    : I.core_deftype'
  = match t with
  | V.Core_deftype_functype ft -> I.Core_deftype_functype ft
let desugar_core_deftype (ctx : 'a ctx)
    : V.core_deftype -> I.core_deftype
  = atmap (desugar_core_deftype' ctx)
let core_id_to_sort (cid : Wasm.Ast.import_desc) : sort
  = let open Wasm.Ast in
    CoreSort ((match cid.it with
               | FuncImport _ -> Core_func
               | TableImport _ -> Core_table
               | MemoryImport _ -> Core_memory
               | GlobalImport _ -> Core_global) @@ cid.at) @@ cid.at
let desugar_core_alias_target' (ctx : core_module_decl_ctx) sort
      (t : V.core_alias_target') at : I.core_alias_target'
  = match t with
  | V.Core_alias_export (id, name) ->
     I.Core_alias_export ( desugar_ident_cmd ctx
                             (CoreSort (Core_instance @@ at) @@ at) id
                         , name)
  | V.Core_alias_outer (oi, ident) ->
     let oin = match oi with
       | V.Idx i -> i.it
       | V.Var v -> find_parent_index ctx v
       | _ -> Putil.error at "Inadmissible outer index" in
     let idx = match ident with
       | V.Idx i -> i.it
       | V.Var v -> raw_lookup_n ctx (Int32.to_int oin) (CoreSort sort @@ at) v
       | _ -> Putil.error at "Inadmissible index" in
     I.Core_alias_outer (oin, idx)
let desugar_core_alias_target (ctx : core_module_decl_ctx) sort
    : V.core_alias_target -> I.core_alias_target
  = atmap' (desugar_core_alias_target' ctx sort)
let desugar_core_alias' (ctx : core_module_decl_ctx) (a : V.core_alias')
    : I.core_alias'
  = { I.c_a_target = desugar_core_alias_target ctx a.V.c_a_sort a.V.c_a_target
    ; I.c_a_sort = a.V.c_a_sort }
let desugar_core_alias (ctx : core_module_decl_ctx)
    : V.core_alias -> I.core_alias
  = atmap (desugar_core_alias' ctx)
let desugar_core_exportdecl' (ctx : core_module_decl_ctx)
      (d : V.core_exportdecl') at : I.core_exportdecl'
  = { I.c_ed_name = d.V.c_ed_name
    ; I.c_ed_ty = fst (desugar_core_externdesc ctx d.V.c_ed_ty at) }
let desugar_core_exportdecl (ctx : core_module_decl_ctx)
    : V.core_exportdecl -> I.core_exportdecl
  = atmap' (desugar_core_exportdecl' ctx)
let desugar_core_moduledecl' (ctx : core_module_decl_ctx)
      (d : V.core_moduledecl')
    : I.core_moduledecl'
  = match d with
  | V.Core_md_importdecl i ->
     let id, b = desugar_core_importdecl ctx i in
     bind_NE ctx (core_id_to_sort (snd id.it.I.c_id_ty)) b;
     I.Core_md_importdecl id
  | V.Core_md_typedecl bt ->
     let dt = desugar_core_deftype ctx bt.V.body in
     bind_core_type_NE ctx bt.V.binder (I.Core_deftype__deftype dt @@ dt.at);
     I.Core_md_typedecl dt
  | V.Core_md_aliasdecl ba ->
     let a = desugar_core_alias ctx ba.V.body in
     bind_NE ctx (CoreSort a.it.I.c_a_sort @@ a.at) ba.V.binder;
     I.Core_md_aliasdecl a
  | V.Core_md_exportdecl e ->
     let e' = desugar_core_exportdecl ctx e in
     I.Core_md_exportdecl e'
let desugar_core_moduledecl (ctx : core_module_decl_ctx)
    : V.core_moduledecl -> I.core_moduledecl
  = atmap (desugar_core_moduledecl' ctx)
let rec desugar_core_moduledecls (ctx : core_module_decl_ctx)
          (ds : V.core_moduledecl list)
        : I.core_moduledecl list
  = match ds with
  | [] -> []
  | d ::ds ->
     let d' = desugar_core_moduledecl ctx d in
     let dpres = List.map from_cmd_dd (List.rev ctx.desugar_defs_pre) in
     let dposts = List.map from_cmd_dd ctx.desugar_defs_post in
     ctx.desugar_defs_pre <- [];
     ctx.desugar_defs_post <- [];
     dpres @ (d' :: dposts @ desugar_core_moduledecls ctx ds)
let desugar_core_moduletype' (ctx : 'a ctx) (t : V.core_moduletype')
    : I.core_moduletype'
  = { I.decls = desugar_core_moduledecls (new_ctx (SC ctx) None) t.V.decls }
let desugar_core_moduletype (ctx : 'a ctx)
    : V.core_moduletype -> I.core_moduletype
  = atmap (desugar_core_moduletype' ctx)
let desugar_core_deftype_' (ctx : definition_ctx) (t : V.core_deftype_')
    : I.core_deftype_'
  = match t with
  | V.Core_deftype__deftype t ->
     I.Core_deftype__deftype (desugar_core_deftype ctx t)
  | V.Core_deftype__moduletype t ->
     I.Core_deftype__moduletype (desugar_core_moduletype ctx t)
let desugar_core_deftype_ (ctx : definition_ctx)
    : V.core_deftype_ -> I.core_deftype_
  = atmap (desugar_core_deftype_' ctx)

let desugar_core_definition
      (ctx : definition_ctx) (def : V.core_definition) at
    : I.core_definition
  = match def with
  | V.CoreModuleDef bm ->
     bind ctx (CoreSort (Core_module @@ at) @@ at) bm.V.binder;
     I.CoreModuleDef bm.V.body
  | V.CoreInstanceDef bi ->
     let ie = desugar_core_instance_expr ctx bi.V.body in
     bind ctx (CoreSort (Core_instance @@ at) @@ at) bi.V.binder;
     I.CoreInstanceDef ie
  | V.CoreTypeDef bt ->
     let dt = desugar_core_deftype_ ctx bt.V.body in
     bind_core_type ctx bt.V.binder dt;
     I.CoreTypeDef dt

let desugar_inline_export' (ctx : definition_ctx) (e : V.inline_export')
    : I.inline_export'
  = { I.ie_name = e.V.ie_name
    ; I.ie_value = desugar_sort_idx ctx e.V.ie_value }
let desugar_inline_export (ctx : definition_ctx)
    : V.inline_export -> I.inline_export
  = atmap (desugar_inline_export' ctx)

let inline_export'_to_export' (e : I.inline_export') : I.export'
  = { I.e_name = e.I.ie_name
    ; I.e_value = e.I.ie_value
    ; I.e_type = None }
let inline_export_to_export : I.inline_export -> I.export
  = atmap inline_export'_to_export'

let desugar_instantiate_arg_inline_instance
      (ctx : definition_ctx) (es : V.inline_export list)
    : I.sort_idx
  = let at = Putil.span_regions (List.hd es).at (List.hd (List.rev es)).at in
    let es' = List.map (desugar_inline_export ctx) es in
    ctx.desugar_defs_pre <-
      DD_def (I.InstanceDef (I.Instantiate_inline es' @@ at) @@ at)
      ::ctx.desugar_defs_pre;
    { I.s_sort = Instance @@ at
    ; I.s_idx = anon ctx (Instance @@ at) 1l } @@ at
let desugar_instantiate_arg' (ctx : definition_ctx) (ia : V.instantiate_arg')
    : I.instantiate_arg'
  = { I.ia_name = ia.V.ia_name
    ; I.ia_value = match ia.V.ia_value.it.V.s_idx with
                   | V.InlineInstance es ->
                      desugar_instantiate_arg_inline_instance ctx es
                   | _ -> desugar_sort_idx ctx ia.V.ia_value }
let desugar_instantiate_arg (ctx : definition_ctx)
    : V.instantiate_arg -> I.instantiate_arg
  = atmap (desugar_instantiate_arg' ctx)
let desugar_instance_expr' (ctx : definition_ctx) (ie : V.instance_expr') at
    : I.instance_expr'
  = match ie with
  | V.Instantiate_component (cid, args) ->
     I.Instantiate_component
       ( desugar_ident ctx (Component @@ at) cid
       , List.map (desugar_instantiate_arg ctx) args)
  | V.Instantiate_inline es ->
     I.Instantiate_inline (List.map (desugar_inline_export ctx) es)
let desugar_instance_expr (ctx : definition_ctx)
    : V.instance_expr -> I.instance_expr
  = atmap' (desugar_instance_expr' ctx)

let desugar_alias_target'
      (ctx : 'a ctx) (desugar_ident : 'a ctx -> sort -> V.ident -> I.ident)
      sort (t : V.alias_target') at
    : I.alias_target'
  = match t with
  | V.Alias_export (id, name) ->
     I.Alias_export ( desugar_ident ctx (Instance @@ at) id
                    , name)
  | V.Alias_core_export (id, name) ->
     I.Alias_core_export ( desugar_ident ctx
                             (CoreSort (Core_instance @@ at) @@ at) id
                         , name)
  | V.Alias_outer (oi, ident) ->
     let oin = match oi with
       | V.Idx i -> i.it
       | V.Var v -> find_parent_index ctx v
       | _ -> Putil.error at "Inadmissible outer index" in
     let idx = match ident with
       | V.Idx i -> i.it
       | V.Var v -> raw_lookup_n ctx (Int32.to_int oin) sort v
       | _ -> Putil.error at "Inadmissible index" in
     I.Alias_outer (oin, idx)
let desugar_alias_target
      (ctx : 'a ctx) (desugar_ident : 'a ctx -> sort -> V.ident -> I.ident) sort
    : V.alias_target -> I.alias_target
  = atmap' (desugar_alias_target' ctx desugar_ident sort)
let desugar_alias' ctx desugar_ident (a : V.alias')
    : I.alias'
  = { I.a_target = desugar_alias_target ctx desugar_ident
                     a.V.a_sort a.V.a_target
    ; I.a_sort = a.V.a_sort }
let desugar_alias
      (ctx : 'a ctx) (desugar_ident : 'a ctx -> sort -> V.ident -> I.ident)
    : V.alias -> I.alias
  = atmap (desugar_alias' ctx desugar_ident)

type 'a desugar_type_params =
  { _desugar_ident : 'a ctx -> sort -> V.ident -> I.ident
  ; _deinline_type : 'a ctx -> I.def_type -> I.ident
  }
let desugar_type_params_def : ctx_for_definition desugar_type_params
  = { _desugar_ident = desugar_ident
    ; _deinline_type =
        fun ctx t ->
        ctx.desugar_defs_pre <-
          DD_def (I.TypeDef t @@ no_region)::ctx.desugar_defs_pre;
        let type_idx = ctx.types.count in
        bind_type_ bind_export_no ctx V.No_binder t;
        (*print_endline ("debug: deinline_type: " ^ string_of_region t.at
                       ^ " = " ^ Int32.to_string type_idx);*)
        type_idx (* hack *)
    }
let desugar_type_params_decl : ctx_for_component_decl desugar_type_params
  = { _desugar_ident = desugar_ident_cd
    ; _deinline_type =
        fun ctx t ->
        ctx.desugar_defs_pre <-
          DD_cd (I.Instance_type t @@ no_region)::ctx.desugar_defs_pre;
        let type_idx = ctx.types.count in
        bind_type_ bind_export_no ctx V.No_binder t;
        type_idx (* hack *)
    }

let rec desugar_record_field' (ctx : 'a ctx) (params : 'a desugar_type_params)
          (rf : V.record_field') at
    : I.record_field'
  = { I.rf_name = rf.V.rf_name
    ; I.rf_type = desugar_val_type ctx params at rf.V.rf_type }
and desugar_record_field (ctx : 'a ctx) (params : 'a desugar_type_params)
    : V.record_field -> I.record_field
  = atmap' (desugar_record_field' ctx params)
and desugar_variant_case' (ctx : 'a ctx) (params : 'a desugar_type_params)
      vcs (vc : V.variant_case') at
    : I.variant_case'
  = { I.vc_name = vc.V.vc_name
    ; I.vc_type = Option.map (desugar_val_type ctx params at) vc.V.vc_type
    ; I.vc_default =
        match vc.V.vc_default with
        | None -> None
        | Some (V.Idx i) -> Some i.it
        | Some (V.Var v) ->
           let ivcs = List.mapi (fun i a -> (i, a)) vcs in
           let (i, _) = List.find (fun (i, vc) ->
                            match vc.V.binder with
                            | V.Var_binder v' -> v'.it = v.it
                            | _ -> false) ivcs in
           Some (Int32.of_int i)
        | Some _ -> Putil.error at "Default must be index or var"
    }
and desugar_variant_case (ctx : 'a ctx) (params : 'a desugar_type_params) vcs
    : V.variant_case V.bound -> I.variant_case
  = fun vc -> atmap' (desugar_variant_case' ctx params vcs) vc.V.body
and desugar_def_val_type' (ctx : 'a ctx) (params : 'a desugar_type_params)
      (t : V.def_val_type') at
    : I.def_val_type'
  = match t with
  | V.Record rfs -> I.Record (List.map (desugar_record_field ctx params) rfs)
  | V.Variant vcs -> I.Variant (List.map (desugar_variant_case ctx params vcs) vcs)
  | V.List vt -> I.List (desugar_val_type ctx params at vt)
  | V.Tuple vts -> I.Tuple (List.map (desugar_val_type ctx params at) vts)
  | V.Flags ns -> I.Flags ns
  | V.Enum ns -> I.Enum ns
  | V.Union vts -> I.Union (List.map (desugar_val_type ctx params at) vts)
  | V.Option vt -> I.Option (desugar_val_type ctx params at vt)
  | V.Expected (vt1, vt2) ->
     I.Expected ( Option.map (desugar_val_type ctx params at) vt1
                , Option.map (desugar_val_type ctx params at) vt2)
  | V.Own v -> (match v with
                | V.Idx _ | V.Var _ ->
                   I.Own (params._desugar_ident ctx (Type @@ at) v)
                | _ -> Putil.error at "Resource type must be var or index")
  | V.Borrow v -> (match v with
                   | V.Idx _ | V.Var _ ->
                      I.Borrow (params._desugar_ident ctx (Type @@ at) v)
                | _ -> Putil.error at "Resource type must be var or index")
  | V.Bool -> I.Bool
  | V.Signed i -> I.Signed i
  | V.Unsigned i -> I.Unsigned i
  | V.Float f -> I.Float f
  | V.Char -> I.Char
  | V.String -> I.String
and desugar_def_val_type ctx params
    : V.def_val_type -> I.def_val_type
  = atmap' (desugar_def_val_type' ctx params)
and desugar_val_type (ctx : 'a ctx) (params : 'a desugar_type_params) at
      (vt : V.val_type)
    : I.val_type
  = match vt with
  | V.TVar id -> params._desugar_ident ctx (Type @@ at) id
  | V.TInline t -> let t' = desugar_def_val_type ctx params t in
                   params._deinline_type ctx (I.Deftype_val t' @@ t'.at)
let desugar_func_ios' (ctx : 'a ctx) (params : 'a desugar_type_params)
      (io : V.func_ios') at : I.func_ios'
  = match io with
  | V.Fio_one vt -> I.Fio_one (desugar_val_type ctx params at vt)
  | V.Fio_many nts ->
     I.Fio_many (List.map (fun (n, vt) ->
                     (n, desugar_val_type ctx params at vt)) nts)
let desugar_func_ios (ctx : 'a ctx) (params : 'a desugar_type_params)
    : V.func_ios -> I.func_ios
  = atmap' (desugar_func_ios' ctx params)
let desugar_func_type' ctx params
      (ft : V.func_type') : I.func_type'
  = { I.ft_params = desugar_func_ios ctx params ft.V.ft_params
    ; I.ft_result = desugar_func_ios ctx params ft.V.ft_result }
let desugar_func_type ctx params
    : V.func_type -> I.func_type
  = atmap (desugar_func_type' ctx params)
let rec desugar_type_decls
          (ctx : 'c ctx)
          (desugar_decl : 'c ctx -> 'a -> 'b)
          (from_dd : 'c desugar_def -> 'b)
          (decls : 'a list)
  = match decls with
  | [] -> []
  | d::ds ->
     let d' = desugar_decl ctx d in
     let dpres = List.map from_dd (List.rev ctx.desugar_defs_pre) in
     let dposts = List.map from_dd ctx.desugar_defs_post in
     ctx.desugar_defs_pre <- [];
     ctx.desugar_defs_post <- [];
     dpres @ (d' :: dposts @ desugar_type_decls ctx desugar_decl from_dd ds)
let exportdesc_to_sort ed
  = match ed.it with
  | I.Export_sort_id (s, _) -> s
  | I.Export_core_mod _ -> CoreSort (Core_module @@ ed.at) @@ ed.at
  | I.Export_func _ -> Func @@ ed.at
  | I.Export_comp _ -> Component @@ ed.at
  | I.Export_inst _ -> Instance @@ ed.at
  | I.Export_val  _-> Value @@ ed.at
  | I.Export_type _ -> Type @@ ed.at
let rec desugar_def_type_typeuse ctx params at dt
  = match dt with
  | V.TVar id -> params._desugar_ident ctx (Type @@ at) id
  | V.TInline t -> let t' = desugar_def_type ctx params None t in
                   params._deinline_type ctx t'
and desugar_type_bound' ctx params (tc : V.type_bound') at : I.type_bound'
  = match tc with
  | V.Tbound_subr -> I.Tbound_subr
  | V.Tbound_eq dt -> I.Tbound_eq (desugar_def_type_typeuse ctx params at dt)
and desugar_type_bound ctx params (tb : V.type_bound) : I.type_bound
  = atmap' (desugar_type_bound' ctx params) tb
and desugar_exportdesc' ctx params name (ed : V.exportdesc') at : I.exportdesc'
  = match ed with
  | V.Export_sort_id (s, id) ->
     I.Export_sort_id (s, params._desugar_ident ctx (Type @@ at) id)
  | V.Export_core_mod cmt ->
     I.Export_core_mod (desugar_core_moduletype ctx cmt)
  | V.Export_func ft ->
     I.Export_func (desugar_func_type ctx params ft)
  | V.Export_comp ct ->
     I.Export_comp (desugar_component_type ctx params name ct)
  | V.Export_inst it ->
     I.Export_inst (desugar_instance_type ctx params name it)
  | V.Export_val vt ->
     I.Export_val (desugar_val_type ctx params at vt)
  | V.Export_type tb ->
     I.Export_type (desugar_type_bound ctx params tb)
and desugar_exportdesc
    : 'c. 'c ctx -> 'c desugar_type_params -> var option
      -> V.exportdesc -> I.exportdesc
  = fun ctx params name -> atmap' (desugar_exportdesc' ctx params name)
and desugar_export_decl' ctx params (ed : V.exportdecl')
    : I.exportdecl' * V.binder
  = { I.ed_name = ed.V.ed_name
    ; I.ed_type = desugar_exportdesc ctx params
                    (to_outer_name ed.V.ed_type.V.binder) ed.V.ed_type.V.body },
    ed.V.ed_type.V.binder
and desugar_export_decl ctx params (ed : V.exportdecl)
    : I.exportdecl * V.binder
  = let ed', x = desugar_export_decl' ctx params ed.it in
    { at = ed.at; it = ed' }, x
and desugar_instance_decl'
  = fun ctx params decl ->
  match decl with
  | V.Instance_type bdt ->
     let t' = desugar_def_type ctx params
                (to_outer_name bdt.V.binder) bdt.V.body in
     bind_type_NE ctx bdt.V.binder t';
     I.Instance_type t'
  | V.Instance_alias ba ->
     let a = desugar_alias ctx params._desugar_ident ba.V.body in
     bind_NE ctx ba.V.body.it.V.a_sort ba.V.binder;
     I.Instance_alias a
  | V.Instance_export ed ->
     let ed', b  = desugar_export_decl ctx params ed in
     (match ed.it.V.ed_type.V.body.it, b with
      | V.Export_type _, x -> bind_NE ctx (Type @@ ed.at) x
      | _, V.No_binder -> ()
      | _, _ -> Putil.error ed.at "Binder not allowed on non-type export");
     I.Instance_export ed'
and desugar_instance_decl (ctx : component_decl_ctx) params
    : V.instance_decl -> I.instance_decl
  = atmap (desugar_instance_decl' ctx params)
and desugar_instance_type' ctx params name
      : V.instance_decl list -> I.instance_decl list
  = desugar_type_decls
      (new_ctx (SC ctx) name)
      (fun c d -> desugar_instance_decl c desugar_type_params_decl d)
      from_cd_dd_i
and desugar_instance_type
    : 'c. 'c ctx -> 'c desugar_type_params -> var option
      -> V.instance_type -> I.instance_type
  = fun ctx params name -> atmap (desugar_instance_type' ctx params name)
and desugar_import_decl' ctx params (id : V.importdecl')
    : I.importdecl' * V.binder
  = { I.id_name = id.V.id_name
    ; I.id_type = desugar_exportdesc ctx params
                    (to_outer_name id.V.id_type.V.binder) id.V.id_type.V.body },
    id.V.id_type.V.binder
and desugar_import_decl ctx params (id : V.importdecl)
    : I.importdecl * V.binder
  = let id', x = desugar_import_decl' ctx params id.it in
    { at = id.at; it = id' }, x
and desugar_component_decl' ctx params (decl : V.component_decl')
    : I.component_decl'
  = match decl with
  | V.Component_import id ->
     let id', b = desugar_import_decl ctx params id in
     bind_NE ctx (exportdesc_to_sort id'.it.I.id_type) b;
     I.Component_import id'
  | V.Component_instance id ->
     I.Component_instance (desugar_instance_decl ctx params id)
and desugar_component_decl ctx params
    : V.component_decl -> I.component_decl
  = atmap (desugar_component_decl' ctx params)
and desugar_component_type' ctx params name
    : V.component_decl list -> I.component_decl list
  = desugar_type_decls
      (new_ctx (SC ctx) name)
      (fun c d -> desugar_component_decl c desugar_type_params_decl d)
      from_cd_dd
and desugar_component_type
    : 'c. 'c ctx -> 'c desugar_type_params -> var option
      -> V.component_type -> I.component_type
  = fun ctx params name -> atmap (desugar_component_type' ctx params name)
and desugar_def_type' ctx params name (dt : V.def_type') at
    : I.def_type'
  = match dt with
  | V.Deftype_val dvt ->
     I.Deftype_val (desugar_def_val_type ctx params dvt)
  | V.Deftype_func ft ->
     I.Deftype_func (desugar_func_type ctx params ft)
  | V.Deftype_comp ct ->
     I.Deftype_comp (desugar_component_type ctx params name ct)
  | V.Deftype_inst it ->
     I.Deftype_inst (desugar_instance_type ctx params name it)
  | V.Deftype_rsrc fi ->
     I.Deftype_rsrc (Option.map (params._desugar_ident ctx (Func @@ at)) fi)
and desugar_def_type
    : 'c. 'c ctx -> 'c desugar_type_params -> var option
      -> V.def_type -> I.def_type
  = fun ctx params name -> atmap' (desugar_def_type' ctx params name)

let desugar_canon_opt' ctx (o : V.canon_opt') at : I.canon_opt'
  = match o with
  | V.String_utf8 -> I.String_utf8
  | V.String_utf16 -> I.String_utf16
  | V.String_latin1_utf16 -> I.String_latin1_utf16
  | V.Memory cmid ->
     I.Memory (desugar_ident ctx (CoreSort (Core_memory @@ at) @@ at) cmid)
  | V.Realloc cfid ->
     I.Realloc (desugar_ident ctx (CoreSort (Core_func @@ at) @@ at) cfid)
  | V.PostReturn cfid ->
     I.PostReturn (desugar_ident ctx (CoreSort (Core_func @@ at) @@ at) cfid)
let desugar_canon_opt ctx : V.canon_opt -> I.canon_opt
  = atmap' (desugar_canon_opt' ctx)
let desugar_canon' ctx (d : V.canon') at : I.canon'
  = match d with
  | V.Canon_lift (cfid, ed, opts) ->
     let cfid' = desugar_ident ctx (CoreSort (Core_func @@ at) @@ at) cfid in
     let ed' = desugar_exportdesc ctx desugar_type_params_def None ed in
     let opts' = List.map (desugar_canon_opt ctx) opts in
     I.Canon_lift (cfid', ed', opts')
  | V.Canon_lower (fid, opts) ->
     let fid' = desugar_ident ctx (Func @@ at) fid in
     let opts' = List.map (desugar_canon_opt ctx) opts in
     I.Canon_lower (fid', opts')
  | V.Canon_resource_builtin { it = V.CRB_new dt; _ } ->
     let dt' = desugar_def_type_typeuse ctx desugar_type_params_def at dt in
     I.Canon_resource_builtin (I.CRB_new dt' @@ at)
  | V.Canon_resource_builtin { it = V.CRB_drop vt; _ } ->
     let vt' = desugar_val_type ctx desugar_type_params_def at vt in
     I.Canon_resource_builtin (I.CRB_drop vt' @@at)
  | V.Canon_resource_builtin { it = V.CRB_rep dt; _ } ->
     let dt' = desugar_def_type_typeuse ctx desugar_type_params_def at dt in
     I.Canon_resource_builtin (I.CRB_rep dt' @@ at)
let desugar_canon ctx : V.canon -> I.canon
  = atmap' (desugar_canon' ctx)

let desugar_start' ctx (s : V.start') at : I.start' * unit V.bound list
  = { I.s_func = desugar_ident ctx (Func @@ at) s.V.s_func
    ; I.s_params = List.map (desugar_ident ctx (Value @@ at)) s.V.s_params
    ; I.s_result = List.map (fun v -> v.V.body) s.V.s_result }, s.V.s_result
let desugar_start ctx (s : V.start) : I.start * unit V.bound list
  = let s', bs = desugar_start' ctx s.it s.at in
    { it = s'; at = s.at }, bs

let desugar_import' ctx (i : V.import') : I.import' * V.binder
  = { I.i_name = i.V.i_name
    ; I.i_type = desugar_exportdesc ctx desugar_type_params_def
                   (to_outer_name i.V.i_type.V.binder) i.V.i_type.V.body },
    i.V.i_type.V.binder
let desugar_import ctx (i : V.import) : I.import * V.binder
  = let i', b = desugar_import' ctx i.it in
    { it = i'; at = i.at }, b

let desugar_export' ctx (e : V.export') : I.export'
  = { I.e_name = e.V.e_name
    ; I.e_value = desugar_sort_idx ctx e.V.e_value
    ; I.e_type = Option.map (desugar_exportdesc ctx desugar_type_params_def None) e.V.e_type}
let desugar_export ctx : V.export -> I.export
  = atmap (desugar_export' ctx)

let rec desugar_definition' (ctx : definition_ctx) (def : V.definition') at
        : I.definition'
  = match def with
  | V.CoreDef c -> I.CoreDef (desugar_core_definition ctx c at)
  | V.ComponentDef c ->
     let dc = _desugar_component (SC ctx) c in
     bind ctx (Component @@ c.at) c.it.V.binder;
     I.ComponentDef dc
  | V.InstanceDef bi ->
     let ie = desugar_instance_expr ctx bi.V.body in
     bind ctx (Instance @@ at) bi.V.binder;
     I.InstanceDef ie
  | V.AliasDef ba ->
     let a = desugar_alias ctx desugar_ident ba.V.body in
     bind ctx ba.V.body.it.V.a_sort ba.V.binder;
     I.AliasDef a
  | V.TypeDef dt ->
     let dt' = desugar_def_type ctx desugar_type_params_def
                 (to_outer_name dt.V.binder) dt.V.body in
     bind_type ctx dt.V.binder dt';
     I.TypeDef dt'
  | V.CanonDef bc ->
     let c = desugar_canon ctx bc.V.body in
     let sort = match c.it with
       | I.Canon_lift _ -> Func @@ c.at
       | I.Canon_lower _ -> CoreSort (Core_func @@ c.at) @@ c.at
       | I.Canon_resource_builtin _ -> CoreSort (Core_func @@ c.at) @@ c.at in
     bind ctx sort bc.V.binder;
     I.CanonDef c
  | V.StartDef s ->
     let s', bs = desugar_start ctx s in
     ignore (List.map (fun b -> bind ctx (Value @@ s'.at) b.V.binder) bs);
     I.StartDef s'
  | V.ImportDef i ->
     let i', b = desugar_import ctx i in
     bind ctx (exportdesc_to_sort i'.it.I.i_type) b;
     I.ImportDef i'
  | V.ExportDef be ->
     let e' = desugar_export ctx be.V.body in
     bind ctx (e'.it.I.e_value.it.I.s_sort) be.V.binder;
     I.ExportDef e'
and desugar_definition (ctx : definition_ctx) : V.definition -> I.definition
  = atmap' (desugar_definition' ctx)

and desugar_definitions (ctx : definition_ctx) (defs : V.definition list)
    : I.definition list
  = match defs with
  | [] -> []
  | d::ds ->
     let d' = desugar_definition ctx d in
     let dpres = List.map from_def_dd (List.rev ctx.desugar_defs_pre) in
     let dposts = List.map from_def_dd ctx.desugar_defs_post in
     ctx.desugar_defs_pre <- [];
     ctx.desugar_defs_post <- [];
     dpres @ (d' :: dposts @ desugar_definitions ctx ds)

and _desugar_component' (ctx : some_ctx) (c : V.component' V.bound) at
    : I.component'
  = { I.defns = desugar_definitions
                  (new_ctx ctx (match c.V.binder with
                                | V.No_binder -> None
                                | V.Var_binder v -> Some v
                                | V.Export_binders _ -> Putil.error at "bad"))
                  c.V.body.V.defns; }
and _desugar_component (ctx : some_ctx) : V.component -> I.component
  = atmap' (fun c -> _desugar_component' ctx c)

let desugar_component c = _desugar_component (SC (empty_ctx () None)) c
