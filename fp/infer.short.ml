module Str = struct
  let implode l =
    let s = Bytes.make (List.length l) ' ' in
    List.iteri (fun i c -> Bytes.set s i c) l;
    s
end

module LazyList = struct
  type 'a node = Nil | Cons of 'a * 'a t
  and 'a t = 'a node Lazy.t
  let empty = lazy Nil
  let singleton x = lazy (Cons (x, empty))
  let force = Lazy.force
  let rec map f l = lazy (
    match force l with
    | Nil -> Nil
    | Cons (h, t) -> Cons (f h, map f t)
  )
  let rec append l1 l2 = lazy (
    match force l1 with
    | Nil -> force l2
    | Cons (h, t) -> Cons (h, append t l2)
  )
  let rec concat ll = lazy (
    match force ll with
    | Nil -> Nil
    | Cons (h, t) -> append h (concat t) |> force
  )
  let is_empty l = force l = Nil
end

module ParserCombinators = struct
  type input = { s: bytes; pos: int }
  type 'a t = input -> ('a * input) LazyList.t
  let unit a s = LazyList.singleton (a, s)
  let zero = unit []
  let (>>=) (type a) (type b) (x : a t) (f : a -> b t) s =
    LazyList.map (fun (a,s) -> f a s) (x s) |> LazyList.concat
  let (>>) x y = x >>= fun _ -> y
  let (<<) x y = x >>= fun a -> y >> unit a
  let (<|>) x y s = let r = x s in if LazyList.is_empty r then y s else r
  let (<$>) f x = x >>= fun a -> unit (f a)
  let rec many x = many1 x <|> zero
  and many1 x = x >>= fun b -> many x >>= fun bs -> unit (b::bs)
  let sep_by x sep =
    let go = x >>= fun b ->
      many (sep >> x) >>= fun bs ->
      unit (b::bs)
    in
    go <|> zero
  let pred f s =
    if s.pos = Bytes.length s.s then
      LazyList.empty
    else
      let c = s.s.[s.pos] in
      if f c then unit c { s with pos = s.pos + 1 } else LazyList.empty
  let ident = Str.implode <$> many1 (pred (fun c ->
    'a'<=c&&c<='z' || 'A'<=c&&c<='Z' || '0'<=c&&c<='9' || c = '_'))
  let space = pred (fun c -> c = ' ' || c = '\t' || c = '\r' || c = '\n')
  let token x = x >>= fun a -> many space >> unit a
  let char c = pred ((=) c)
  let str cs =
    let rec go i =
      if i = Bytes.length cs then
        zero
      else
        char cs.[i] >> go (i+1)
    in
    go 0
  let ident_ = token ident
  let char_ c = token (char c)
  let str_ cs = token (str cs)
end

type expr =
  | Var of string
  | Fun of string list * expr
  | App of expr * expr list
  | Let of string * expr * expr
type level = int
type typ =
  | TConst of string
  | TVar of tv ref
  | TArrow of typ list * typ * levels
  | TApp of typ * typ list * levels
and tv = Unbound of int * level | Link of typ
and levels = { mutable level_old : level; mutable level_new : level }
let gray_level = -1
let generic_level = 19921213

let rec djs_find = function
  | TVar ({contents = Link t} as tv) ->
      let t = djs_find t in
      tv := Link t;
      t
  | t -> t

let get_level t =
  match djs_find t with
  | TConst _ -> 0
  | TVar ({contents = Unbound (_, l)}) -> l
  | TApp (_, _, ls)
  | TArrow (_, _, ls) -> ls.level_new
  | _ -> assert false

module Parser = struct
  include ParserCombinators
  let force = Lazy.force
  let generic_ctr = ref 0
  let tapp f args =
    let l = List.fold_left (fun acc a ->
      max acc (get_level a)) (get_level f) args in
    TApp (f, args, { level_old = l; level_new = l })
  let tarrow args r =
    let l = List.fold_left (fun acc a ->
      max acc (get_level a)) (get_level r) args in
    TArrow (args, r, { level_old = l; level_new = l })
  let typ () =
    let univ = Hashtbl.create 0 in
    let rec parse_ident =
      ident_ >>= fun n ->
      unit @@
        try TVar (ref @@ Link (Hashtbl.find univ n))
        with Not_found -> TConst n
    and parse_tys s = sep_by parse_ty (char_ ',') s
    and parse_ty s = (
      let t1 =
        let rec bracket f =
          (char_ '[' >> parse_tys << char_ ']' >>= fun args ->
          bracket (tapp f args)) <|> unit f
        in
        parse_ident >>= bracket >>= fun f ->
        (str_ "->" >> (fun s -> parse_ty s) >>= fun r ->
        unit @@ tarrow [f] r) <|> unit f
      in
      let t2 =
        char_ '(' >> parse_tys << char_ ')' >>= fun args ->
        (str_ "->" >> parse_ty >>= fun r ->
        unit @@ tarrow args r) <|> unit (List.hd args)
      in
      t1 <|> t2
    ) s
    and parse_top s = (
      (str_ "forall[" >> many ident_ << char_ ']' >>= fun vs ->
      List.iteri (fun i v ->
        decr generic_ctr;
        Hashtbl.replace univ v (TVar (Unbound (!generic_ctr, generic_level) |> ref))) vs;
      parse_ty) <|> parse_ty
    ) s
    in
    parse_top
  let expr =
    let rec parse_let s = (
      str_ "let" >> ident_ >>= fun n ->
      char_ '=' >> parse_expr >>= fun e ->
      str_ "in" >>
      parse_expr >>= fun b ->
      unit @@ Let (n, e, b)
    ) s
    and parse_fun s = (
      str_ "fun" >> many ident_ >>= fun args ->
      str_ "->" >> parse_expr >>= fun b ->
      unit @@ Fun (args, b)
    ) s
    and parse_simple_expr s = (
      let first = (char_ '(' >> parse_expr << char_ ')') <|>
        (ident_ >>= fun n -> unit @@ Var n)
      in
      let rec go a =
        (char_ '(' >> sep_by parse_expr (char_ ',') << char_ ')' >>= fun b ->
        go @@ App (a, b)) <|> unit a
      in
      first >>= go
    ) s
    and parse_expr s = (
      parse_let <|>
      parse_fun <|>
      parse_simple_expr
    ) s
    in
    parse_expr
  let eof s =
    if s.pos = Bytes.length s.s then
      LazyList.singleton ((), s)
    else
      LazyList.empty
  let parse x s =
    match force ((many space >> x << eof) { s; pos = 0 }) with
    | LazyList.Nil -> None
    | LazyList.Cons ((x, _), _) -> Some x
end

exception Cycle
exception Fail
exception Length
let gensym_ctr = ref 0
let gensym () =
  let n = !gensym_ctr in
  incr gensym_ctr;
  n
let reset_gensym () = gensym_ctr := 0
let cur_level = ref 0
let reset_level () = cur_level := 0
let enter_level () = incr cur_level
let leave_level () = decr cur_level
let new_var () = TVar (ref (Unbound (gensym (), !cur_level)))
let new_app f args = TApp (f, args, { level_new = !cur_level; level_old = !cur_level })
let new_arrow args r = TArrow (args, r, { level_new = !cur_level; level_old = !cur_level })

let adj_q = ref []
let reset_adj_q () = adj_q := []
let force_adj_q () =
  let rec go l acc t =
    match djs_find t with
    | TVar ({contents = Unbound (n, l')} as tv) ->
        if l < l' then
          tv := Unbound (n, l);
        acc
    | TApp (_, _, ls)
    | TArrow (_, _, ls) as t ->
        if ls.level_new = gray_level then
          raise Cycle;
        if l < ls.level_new then
          ls.level_new <- l;
        one acc t
    | _ -> acc
  and one acc = function
    | TApp (r, args, ls)
    | TArrow (args, r, ls) as t ->
        if ls.level_old <= !cur_level then
          t::acc
        else if ls.level_old = ls.level_new then
          acc
        else (
          let lvl = ls.level_new in
          ls.level_new <- gray_level;
          let acc = List.fold_left (go lvl) acc args in
          let acc = go lvl acc r in
          ls.level_new <- lvl;
          ls.level_old <- lvl;
          acc
        )
    | _ -> assert false
  in
  adj_q := List.fold_left one [] !adj_q

let rec update_level l = function
  | TConst _ ->
      ()
  | TVar ({contents = Unbound (n, l')} as tv) ->
      if l < l' then
        tv := Unbound (n, l)
  | TApp (_, _, ls)
  | TArrow (_, _, ls) as t ->
      if ls.level_new = gray_level then
        raise Cycle;
      if l < ls.level_new then (
        if ls.level_new = ls.level_old then
          adj_q := t :: !adj_q;
        ls.level_new <- l
      )
  | _ -> assert false

let rec unify t1 t2 =
  let t1 = djs_find t1 in
  let t2 = djs_find t2 in
  if t1 != t2 then
    match t1, t2 with
    | TConst t1, TConst t2 when t1 = t2 ->
        ()
    | TVar ({contents = Unbound (_, l)} as tv), t'
    | t', TVar ({contents = Unbound (_, l)} as tv) ->
        update_level l t';
        tv := Link t'
    | TApp (r1, args1, l1), TApp (r2, args2, l2)
    | TArrow (args1, r1, l1), TArrow (args2, r2, l2) ->
        if l1.level_new = gray_level || l2.level_new = gray_level then
          raise Cycle;
        if List.length args1 <> List.length args2 then
          raise Length;
        let lvl = min l1.level_new l2.level_new in
        l1.level_new <- gray_level;
        l2.level_new <- gray_level;
        List.iter2 (unify_level lvl) args1 args2;
        unify_level lvl r1 r2;
        l1.level_new <- lvl;
        l2.level_new <- lvl
    | _ -> raise Fail

and unify_level l t1 t2 =
  let t1 = djs_find t1 in
  update_level l t1;
  unify t1 t2

let gen t =
  let rec go t =
    match djs_find t with
    | TConst _ ->
        ()
    | TVar ({contents = Unbound (n, l)} as tv) ->
        if l > !cur_level then
          tv := Unbound (n, generic_level)
    | TApp (r, args, ls)
    | TArrow (args, r, ls) ->
        if ls.level_new > !cur_level then (
          List.iter go args;
          go r;
          let lvl = List.fold_left (fun acc a -> max acc (get_level a)) (get_level r) args in
          ls.level_new <- lvl;
          ls.level_old <- lvl
        )
    | _ -> assert false
  in
  force_adj_q ();
  go t

let inst t =
  let subst = Hashtbl.create 0 in
  let rec go = function
    | TVar {contents = Unbound (n, l)} when l = generic_level ->
        (try
          Hashtbl.find subst n
        with Not_found ->
          let tv = new_var () in
          Hashtbl.replace subst n tv;
          tv)
    | TVar {contents = Link t} ->
        go t
    | TApp (f, args, ls) when ls.level_new = generic_level ->
        new_app (go f) (List.map go args)
    | TArrow (args, r, ls) when ls.level_new = generic_level ->
        new_arrow (List.map go args) (go r)
    | t -> t
  in
  go t

let rec typeof env e =
  let rec go = function
    | Var x -> Hashtbl.find env x |> inst
    | Fun (args, e) ->
        let ty_args = List.map (fun x -> new_var ()) args in
        List.iter2 (Hashtbl.add env) args ty_args;
        let ty_e = go e in
        let r = new_arrow ty_args ty_e in
        List.iter (Hashtbl.remove env) args;
        r
    | App (e, args) ->
        let ty_fun = go e in
        let ty_args = List.map go args in
        let ty_res = new_var () in
        unify ty_fun (new_arrow ty_args ty_res);
        ty_res
    | Let (x, e1, e2) ->
        enter_level ();
        let ty_e1 = go e1 in
        leave_level ();
        gen ty_e1;
        Hashtbl.add env x ty_e1;
        let r = go e2 in
        Hashtbl.remove env x;
        r
  in
  go e

let rec check_cycle = function
  | TVar {contents = Link t} ->
      check_cycle t
  | TApp (r, args, ls)
  | TArrow (args, r, ls) ->
      if ls.level_new = gray_level then
        raise Cycle;
      let lvl = ls.level_new in
      ls.level_new <- gray_level;
      List.iter check_cycle args;
      check_cycle r;
      ls.level_new <- lvl
  | _ -> ()

let rec top_typeof env e =
  reset_gensym ();
  reset_level ();
  reset_adj_q ();
  let t = typeof env e in
  check_cycle t;
  t

let rec show t =
  let open Printf in
  let id2name = Hashtbl.create 0 in
  let rec go t =
    match djs_find t with
    | TConst n -> n
    | TVar ({contents = Unbound (n, _)}) ->
        (try
          Hashtbl.find id2name n
        with _ ->
          let i = Hashtbl.length id2name in
          let name = Char.chr (Char.code 'a' + i) |> String.make 1 in
          Hashtbl.replace id2name n name;
          name)
    | TApp (f, args, _) ->
        let u = go f in
        let v = String.concat ", " (List.map go args) in
        sprintf "%s[%s]" u v
    | TArrow (args, r, _) ->
        let f = function
          | TArrow _ -> false
          | _ -> true
        in
        let u = String.concat ", " (List.map go args) in
        let v = go r in
        if List.length args = 1 && f @@ djs_find (List.hd args) then
          sprintf "%s -> %s" u v
        else
          sprintf "(%s) -> %s" u v
    | _ -> assert false
  in
  let s = go t in
  let l = Hashtbl.length id2name in
  if l > 0 then (
    let vs = Hashtbl.fold (fun _ v l -> v::l) id2name [] |> List.sort compare in
    sprintf "forall[%s] %s" (String.concat " " vs) s
  ) else
    s

let extract = function
  | Some x -> x
  | None -> assert false

let core =
  [ "head", "forall[a] list[a] -> a"
  ; "tail", "forall[a] list[a] -> list[a]"
  ; "nil", "forall[a] list[a]"
  ; "cons", "forall[a] (a, list[a]) -> list[a]"
  ; "cons_curry", "forall[a] a -> list[a] -> list[a]"
  ; "map", "forall[a b] (a -> b, list[a]) -> list[b]"
  ; "map_curry", "forall[a b] (a -> b) -> list[a] -> list[b]"
  ; "one", "int"
  ; "zero", "int"
  ; "succ", "int -> int"
  ; "plus", "(int, int) -> int"
  ; "eq", "forall[a] (a, a) -> bool"
  ; "eq_curry", "forall[a] a -> a -> bool"
  ; "not", "bool -> bool"
  ; "true", "bool"
  ; "false", "bool"
  ; "pair", "forall[a b] (a, b) -> pair[a, b]"
  ; "pair_curry", "forall[a b] a -> b -> pair[a, b]"
  ; "first", "forall[a b] pair[a, b] -> a"
  ; "second", "forall[a b] pair[a, b] -> b"
  ; "id", "forall[a] a -> a"
  ; "const", "forall[a b] a -> b -> a"
  ; "apply", "forall[a b] (a -> b, a) -> b"
  ; "apply_curry", "forall[a b] (a -> b) -> a -> b"
  ; "choose", "forall[a] (a, a) -> a"
  ; "choose_curry", "forall[a] a -> a -> a"
  ]

let core_env =
  let env = Hashtbl.create 0 in
  List.iter (fun (var, typ) ->
    let t = Parser.parse (Parser.typ ()) typ |> extract in
    Hashtbl.replace env var t
  ) core;
  env

let type_check line =
  let env = Hashtbl.copy core_env in
  Parser.parse Parser.expr line |> extract |> top_typeof env

let () =
  read_line () |> type_check |> show |> print_endline
