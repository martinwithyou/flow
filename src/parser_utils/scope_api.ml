(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module LocSet = Utils_js.LocSet
module LocMap = Utils_js.LocMap

type scope = int
type use = Loc.t
type uses = LocSet.t

module Def = struct
  type t = {
    locs: Loc.t list;
    name: int;
    actual_name: string;
  }
  let mem_loc x t = List.mem x t.locs
end

module Scope = struct
  type t = {
    lexical: bool;
    parent: int option;
    defs: Def.t SMap.t;
    locals: Def.t LocMap.t;
    globals: SSet.t;
  }
end

type info = {
  (* number of distinct name ids *)
  max_distinct: int;
  (* map of scope ids to local scopes *)
  scopes: Scope.t IMap.t
}

let all_uses { scopes; _ } =
  IMap.fold (fun _ scope acc ->
    LocMap.fold (fun use _ uses ->
      LocSet.add use uses
    ) scope.Scope.locals acc
  ) scopes LocSet.empty

let def_of_use { scopes; _ } use =
  let def_opt = IMap.fold (fun _ scope acc ->
    match acc with
    | Some _ -> acc
    | None -> LocMap.get use scope.Scope.locals
  ) scopes None in
  match def_opt with
  | Some def -> def
  | None -> failwith "missing def"

let use_is_def info use =
  let def = def_of_use info use in
  Def.mem_loc use def

let uses_of_def { scopes; _ } ?(exclude_def=false) def =
  IMap.fold (fun _ scope acc ->
    LocMap.fold (fun use def' uses ->
      if exclude_def && Def.mem_loc use def' then uses
      else if Def.(def.locs = def'.locs) then LocSet.add use uses else uses
    ) scope.Scope.locals acc
  ) scopes LocSet.empty

let uses_of_use info ?exclude_def use =
  let def = def_of_use info use in
  uses_of_def info ?exclude_def def

let def_is_unused info def =
  LocSet.is_empty (uses_of_def info ~exclude_def:true def)

let scope info scope_id =
  try IMap.find_unsafe scope_id info.scopes with Not_found ->
    failwith ("Scope " ^ (string_of_int scope_id) ^ " not found")

let is_local_use { scopes; _ } use =
  IMap.exists (fun _ scope ->
    LocMap.mem use scope.Scope.locals
  ) scopes

let rec fold_scope_chain info f scope_id acc =
  let s = scope info scope_id in
  let acc = f scope_id s acc in
  match s.Scope.parent with
  | Some parent_id -> fold_scope_chain info f parent_id acc
  | None -> acc

let rev_scope_pointers scopes =
  IMap.fold (fun id scope acc ->
    match scope.Scope.parent with
      | Some scope_id ->
        let children' = match IMap.get scope_id acc with
          | Some children -> children
          | None -> []
        in IMap.add scope_id (id::children') acc
      | None -> acc
  ) scopes IMap.empty

let build_scope_tree info =
  let scopes = info.scopes in
  let children_map = rev_scope_pointers scopes in
  let rec build_scope_tree scope_id =
    let children = match IMap.get scope_id children_map with
      | None -> []
      | Some children_scope_ids -> List.rev_map build_scope_tree children_scope_ids in
    Tree.Node (IMap.find scope_id scopes, children)
  in build_scope_tree 0

(* The bound variables B of a scope are the names defined in that scope.

   The free variables F of the scope are the names in G + C + L - B, where:
   * G contains the global names used in that scope
   * L contains the local names used in that scope
   * C contains the free variables of its children
*)
let rec compute_free_variables = function
  | Tree.Node (scope, children) ->
    let children' = List.map compute_free_variables children in
    let free_children = List.fold_left (fun acc -> function
      | Tree.Node ((_, free), _) -> SSet.union free acc
    ) SSet.empty children' in

    let bound = scope.Scope.defs in
    let is_bound use_name = SMap.exists (fun def_name _ -> def_name = use_name) bound in
    let free =
      scope.Scope.globals |>
      LocMap.fold (fun _loc use_def acc ->
        let use_name = use_def.Def.actual_name in
        if is_bound use_name then acc else SSet.add use_name acc
      ) scope.Scope.locals |>
      SSet.fold (fun use_name acc ->
        if is_bound use_name then acc else SSet.add use_name acc
      ) free_children
    in Tree.Node ((bound, free), children')
