type exp = CstI of int
		 | Var of string
		 | Add of exp * exp
		 | Mult of exp * exp
		 | Subt of exp * exp
		 | Div of exp * exp;;

let rec lookup x env =
	match env with
	| [] -> failwith ("Unbound name " ^ x)
	| (y,i)::rest -> if x=y then i
							else lookup x rest;;

let rec eval exp env =
	match exp with
	| CstI i -> i
	| Var x -> lookup x env
	| Add (exp1, exp2) -> (eval exp1 env) + (eval exp2 env)
	| Mult (exp1, exp2) -> (eval exp1 env) * (eval exp2 env)
	| Subt (exp1, exp2) -> (eval exp1 env) - (eval exp2 env)
	| Div (exp1, exp2) -> (eval exp1 env) / (eval exp2 env);;


(* eval function usage example

eval (Div(Mult(CstI 6, CstI 3), Subt(CstI 4, CstI 1))) [];;

)