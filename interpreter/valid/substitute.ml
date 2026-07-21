open Etypes

type bsubst = def_type option list
type esubst = (def_type option list) list
type usubst = (def_type option list) list
type fsubst = free_tyvar -> def_type (* called on fvars not caught by esubst/usubst *)
type subst =
  { bvar_sub : bsubst
  ; evar_sub : esubst
  ; uvar_sub : usubst
  ; fvar_sub : fsubst
  }

let empty_fvar_sub (fv : free_tyvar) : def_type
  = DT_var (TV_free fv)

let bsubst_subst (bs : bsubst) : subst
  = { bvar_sub = bs ; evar_sub = [] ; uvar_sub = []; fvar_sub = empty_fvar_sub }
let esubst_subst (es : esubst) : subst
  = { bvar_sub = [] ; evar_sub = es ; uvar_sub = []; fvar_sub = empty_fvar_sub }
let usubst_subst (us : usubst) : subst
  = { bvar_sub = [] ; evar_sub = [] ; uvar_sub = us; fvar_sub = empty_fvar_sub }
let fsubst_subst (fs : fsubst) : subst
  = { bvar_sub = [] ; evar_sub = [] ; uvar_sub = []; fvar_sub = fs }


(* so if i do bound_to_evars ctx [bound1 bound2]
 * then i want to end up with either
 * ctx ++ { evars bound1 bound2 }, 0 -> ctx.evars.length + 1, 1 -> ctx.evars.length
 * or
 * ctx ++ { evars bound2 bound1 }, 0 -> ctx.evars.length, 1 -> ctx.evars.length + 1
 *)

let rec bound_to_evars (ctx : ctx) (vs : boundedtyvar list) : ctx * bsubst
  = match vs with
  | [] -> (ctx, [])
  | v::vs' ->
     let ctx', sub = bound_to_evars { ctx with evars = ctx.evars @ [(v, None)] } vs' in
     (ctx', sub @ [Some (DT_var (TV_free (FTV_evar (0, List.length ctx.evars))))])

let rec bound_to_uvars (ctx : ctx) (imported : bool)
          (vs : boundedtyvar list) : ctx * bsubst
  = match vs with
  | [] -> (ctx, [])
  | v::vs' ->
     let ctx', sub = bound_to_uvars { ctx with
                         uvars = ctx.uvars @ [(v, imported)] } imported vs' in
     (ctx', sub @ [Some (DT_var (TV_free (FTV_uvar (0, List.length ctx.uvars))))])

let rec subst_val_type (s : subst) (vt : val_type) : val_type
  = match vt with
  | Bool -> Bool
  | Signed s -> Signed s
  | Unsigned u -> Unsigned u
  | Float f -> Float f
  | Char -> Char
  | List vt -> List (subst_val_type s vt)
  | Record rfs -> Record (List.map (subst_record_field s) rfs)
  | Variant vcs -> Variant (List.map (subst_variant_case s) vcs)
  | Own dt -> Own (subst_def_type s dt)
  | Borrow dt -> Borrow (subst_def_type s dt)

and subst_record_field (s : subst) (rf : record_field) : record_field
  = { rf_name = rf.rf_name ; rf_type = subst_val_type s rf.rf_type }

and subst_variant_case (s : subst) (vc : variant_case) : variant_case
  = { vc_name = vc.vc_name
    ; vc_type = Option.map (subst_val_type s) vc.vc_type
    ; vc_default = vc.vc_default }

and subst_func_ios (s : subst) (fio : func_ios) : func_ios
  = match fio with
  | Fio_one vt -> Fio_one (subst_val_type s vt)
  | Fio_many nvts ->
     Fio_many (List.map (fun (n, vt) -> (n, subst_val_type s vt)) nvts)

and subst_func_type (s : subst) (ft : func_type) : func_type
  =  { ft_params = subst_func_ios s ft.ft_params
     ; ft_result = subst_func_ios s ft.ft_result }

and subst_def_type (s : subst) (dt : def_type) : def_type
  = match dt with
  | DT_var (TV_bound n) ->
     (try match List.nth s.bvar_sub n with
          | None -> dt
          | Some dt' -> dt'
      with Failure _ -> dt)
  | DT_var (TV_free fv) ->
     let not_explicit () = s.fvar_sub fv in
     (try match fv with
          | FTV_uvar (o, i) ->
             (match List.nth (List.nth s.uvar_sub o) i with
              | None -> not_explicit ()
              | Some dt' -> dt')
          | FTV_evar (o, i) ->
             (match List.nth (List.nth s.evar_sub o) i with
              | None -> not_explicit ()
              | Some dt' -> dt')
      with Failure _ -> not_explicit ())
  | DT_resource_type i -> DT_resource_type i
  | DT_val_type vt -> DT_val_type (subst_val_type s vt)
  | DT_func_type ft -> DT_func_type (subst_func_type s ft)
  | DT_instance_type it -> DT_instance_type (subst_instance_type s it)
  | DT_component_type ct -> DT_component_type (subst_component_type s ct)

and subst_instance_type (s : subst) (it : instance_type) : instance_type
  = let bs' = List.init (List.length it.it_evars) (fun _ -> None) in
    let s' = { s with bvar_sub = bs' @ s.bvar_sub } in
    { it_evars = it.it_evars
    ; it_exports = List.map (subst_extern_decl s') it.it_exports
    }

and subst_component_type (s : subst) (ct : component_type) : component_type
  = let bs' = List.init (List.length ct.ct_uvars) (fun _ -> None) in
    let s' = { s with bvar_sub = bs' @ s.bvar_sub } in
    { ct_uvars = ct.ct_uvars
    ; ct_imports = List.map (subst_extern_decl s') ct.ct_imports
    ; ct_instance = subst_instance_type s' ct.ct_instance
    }

and subst_extern_desc (s : subst) (ed : extern_desc) : extern_desc
  = match ed with
  | ED_core_module cmt -> ED_core_module cmt
  | ED_func ft -> ED_func (subst_func_type s ft)
  | ED_value vt -> ED_value (subst_val_type s vt)
  | ED_type tt -> ED_type (subst_def_type s tt)
  | ED_instance it -> ED_instance (subst_instance_type s it)
  | ED_component ct -> ED_component (subst_component_type s ct)

and subst_extern_decl (s : subst) (ed : extern_decl) : extern_decl
  = { ed_name = ed.ed_name ; ed_desc = subst_extern_desc s ed.ed_desc }
