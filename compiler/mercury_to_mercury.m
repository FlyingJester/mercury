%-----------------------------------------------------------------------------%

% Main author: fjh.

% This program converts the parse tree structure provided by prog_io
% back into Mercury source text.

%-----------------------------------------------------------------------------%

:- module mercury_to_mercury.
:- interface.

:- import_module list, string, io, prog_io.

:- pred convert_to_mercury(string, list(item_and_context),
				io__state, io__state).
:- mode convert_to_mercury(input, input, di, uo).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module prog_out, prog_util.
:- import_module globals, options.

%-----------------------------------------------------------------------------%

convert_to_mercury(ProgName, Items) -->
	io__stderr_stream(StdErr),
	{ string__append(ProgName, ".int", OutputFileName) },
	io__tell(OutputFileName, Res),
	( { Res = ok } ->
		lookup_option(verbose, bool(Verbose)),
		( { Verbose = yes } ->
			io__write_string(StdErr, "% Writing output to "),
			io__write_string(StdErr, OutputFileName),
			io__write_string(StdErr, "...\n")
		;
			[]
		),
		io__write_string(":- module ("),
		io__write_constant(term_atom(ProgName)),
		io__write_string(").\n"),
		io__write_string(":- interface.\n"),
		mercury_output_item_list(Items),
		( { Verbose = yes } ->
			io__write_string(StdErr, "% done\n")
		;
			[]
		),
		io__told
	;
		io__write_string(StdErr, "Error: couldn't open file `"),
		io__write_string(StdErr, OutputFileName),
		io__write_string(StdErr, "' for output.\n")
	).

%-----------------------------------------------------------------------------%

	% output the declarations one by one 

:- pred mercury_output_item_list(list(item_and_context), io__state, io__state).
:- mode mercury_output_item_list(input, di, uo).

mercury_output_item_list([]) --> [].
mercury_output_item_list([Item - Context | Items]) -->
	( mercury_output_item(Item, Context) ->
		[]
	;
		% mercury_output_item should always succeed
		% if it fails, report an internal error
		io__stderr_stream(StdErr),
		io__set_output_stream(StdErr, OldStream),
		io__write_string("\n"),
		prog_out__write_context(Context),
		io__write_string("mercury_to_mercury internal error.\n"),
		io__write_string("Failed to process the following item:\n"),
		io__write_anything(Item),
		io__write_string("\n"),
		io__set_output_stream(OldStream, _)
	),
	mercury_output_item_list(Items).

%-----------------------------------------------------------------------------%

:- pred mercury_output_item(item, term__context, io__state, io__state).
:- mode mercury_output_item(input, input, di, uo).

	% dispatch on the different types of items

mercury_output_item(type_defn(VarSet, TypeDefn, _Cond), Context) -->
	maybe_output_line_number(Context),
	mercury_output_type_defn(VarSet, TypeDefn, Context).

mercury_output_item(inst_defn(VarSet, InstDefn, _Cond), Context) -->
	maybe_output_line_number(Context),
	mercury_output_inst_defn(VarSet, InstDefn, Context).

mercury_output_item(mode_defn(VarSet, ModeDefn, _Cond), Context) -->
	maybe_output_line_number(Context),
	mercury_output_mode_defn(VarSet, ModeDefn, Context).

mercury_output_item(pred(VarSet, PredName, TypesAndModes, Det, _Cond), Context)
		-->
	maybe_output_line_number(Context),
	mercury_output_pred_decl(VarSet, PredName, TypesAndModes, Det, Context).

mercury_output_item(mode(VarSet, PredName, Modes, Det, _Cond), Context) -->
	maybe_output_line_number(Context),
	mercury_output_mode_decl(VarSet, PredName, Modes, Det, Context).

mercury_output_item(module_defn(VarSet, ModuleDefn), Context) -->
	maybe_output_line_number(Context),
	mercury_output_module_defn(VarSet, ModuleDefn, Context).

mercury_output_item(clause(VarSet, PredName, Args, Body), Context) -->
	maybe_output_line_number(Context),
	mercury_output_clause(VarSet, PredName, Args, Body, Context).

mercury_output_item(nothing, _) --> [].

%-----------------------------------------------------------------------------%

:- pred mercury_output_module_defn(varset, module_defn, term__context,
			io__state, io__state).
:- mode mercury_output_module_defn(input, input, input, di, uo).

mercury_output_module_defn(_VarSet, Module, _Context) -->
	( { Module = import(module(ImportedModules)) } ->
		io__write_string(":- import_module "),
		mercury_write_module_spec_list(ImportedModules),
		io__write_string(".\n")
	;
		% XXX unimplemented
		io__write_string("% unimplemented module declaration\n")
	).

:- pred mercury_write_module_spec_list(list(module_specifier),
					io__state, io__state).
:- mode mercury_write_module_spec_list(in, di, uo).

mercury_write_module_spec_list([]) --> [].
mercury_write_module_spec_list([ModuleName | ModuleNames]) -->
	io__write_constant(term_atom(ModuleName)),
	( { ModuleNames = [] } ->
		[]
	;
		io__write_string(", "),
		mercury_write_module_spec_list(ModuleNames)
	).

:- pred mercury_output_inst_defn(varset, inst_defn, term__context,
			io__state, io__state).
:- mode mercury_output_inst_defn(input, input, input, di, uo).

:- mercury_output_inst_defn(_, X, _, _, _) when X.	% NU-Prolog indexing

mercury_output_inst_defn(VarSet, abstract_inst(Name, Args), Context) -->
	io__write_string(":- inst ("),
	{ unqualify_name(Name, Name2) },
	mercury_output_term(term_functor(term_atom(Name2), Args, Context),
			VarSet),
	io__write_string(").\n").
mercury_output_inst_defn(VarSet, eqv_inst(Name, Args, Body), Context) -->
	io__write_string(":- inst ("),
	{ unqualify_name(Name, Name2) },
	mercury_output_term(term_functor(term_atom(Name2), Args, Context),
			VarSet),
	io__write_string(") = "),
	mercury_output_inst(Body, VarSet),
	io__write_string(".\n").

:- pred mercury_output_inst_list(list(inst), varset, io__state, io__state).
:- mode mercury_output_inst_list(in, in, di, uo).

mercury_output_inst_list([], _) --> [].
mercury_output_inst_list([Inst | Insts], VarSet) -->
	mercury_output_inst(Inst, VarSet),
	( { Insts = [] } ->
		[]
	;
		io__write_string(", "),
		mercury_output_inst_list(Insts, VarSet)
	).

:- pred mercury_output_inst(inst, varset, io__state, io__state).
:- mode mercury_output_inst(in, in, di, uo).

mercury_output_inst(free, _) -->
	io__write_string("free").
mercury_output_inst(bound(BoundInsts), VarSet) -->
	io__write_string("bound("),
	mercury_output_bound_insts(BoundInsts, VarSet),
	io__write_string(")").
mercury_output_inst(ground, _) -->
	io__write_string("ground").
mercury_output_inst(inst_var(Var), VarSet) -->
	mercury_output_var(Var, VarSet).
mercury_output_inst(abstract_inst(Name, Args), VarSet) -->
	mercury_output_sym_name(Name),
	( { Args = [] } ->
		[]
	;
		io__write_string("("),
		mercury_output_inst_list(Args, VarSet),
		io__write_string(")")
	).
mercury_output_inst(user_defined_inst(Name, Args), VarSet) -->
	mercury_output_inst(abstract_inst(Name, Args), VarSet).

:- pred mercury_output_bound_insts(list(bound_inst), varset, io__state,
		io__state).
:- mode mercury_output_bound_insts(in, in, di, uo).

mercury_output_bound_insts([], _) --> [].
mercury_output_bound_insts([functor(Name, Args) | BoundInsts], VarSet) -->
	io__write_constant(Name),
	( { Args = [] } ->
		[]
	;
		io__write_string("("),
		mercury_output_inst_list(Args, VarSet),
		io__write_string(")")
	),
	( { BoundInsts = [] } ->
		[]
	;
		io__write_string(" ; "),
		mercury_output_bound_insts(BoundInsts, VarSet)
	).

:- pred mercury_output_mode_defn(varset, mode_defn, term__context,
			io__state, io__state).
:- mode mercury_output_mode_defn(input, input, input, di, uo).

:- mercury_output_mode_defn(_, X, _, _, _) when X. 	% NU-Prolog indexing.

mercury_output_mode_defn(VarSet, eqv_mode(Name, Args, Mode), Context) -->
	io__write_string(":- mode ("),
	{ unqualify_name(Name, Name2) },
	mercury_output_term(term_functor(term_atom(Name2), Args, Context),
			VarSet),
	io__write_string(") :: "),
	mercury_output_mode(Mode, VarSet),
	io__write_string(".\n").

:- pred mercury_output_mode_list(list(mode), varset, io__state, io__state).
:- mode mercury_output_mode_list(in, in, di, uo).

mercury_output_mode_list([], _VarSet) --> [].
mercury_output_mode_list([Mode | Modes], VarSet) -->
	mercury_output_mode(Mode, VarSet),
	( { Modes = [] } ->
		[]
	;
		io__write_string(", "),
		mercury_output_mode_list(Modes, VarSet)
	).

:- pred mercury_output_mode(mode, varset, io__state, io__state).
:- mode mercury_output_mode(in, in, di, uo).

mercury_output_mode(InstA -> InstB, VarSet) -->
	io__write_string("("),
	mercury_output_inst(InstA, VarSet),
	io__write_string(" -> "),
	mercury_output_inst(InstB, VarSet),
	io__write_string(")").
mercury_output_mode(user_defined_mode(Name, Args), VarSet) -->
	mercury_output_sym_name(Name),
	( { Args = [] } ->
		[]
	;
		io__write_string("("),
		mercury_output_inst_list(Args, VarSet),
		io__write_string(")")
	).

%-----------------------------------------------------------------------------%

:- pred mercury_output_type_defn(varset, type_defn, term__context,
			io__state, io__state).
:- mode mercury_output_type_defn(input, input, input, di, uo).

mercury_output_type_defn(VarSet, TypeDefn, Context) -->
	mercury_output_type_defn_2(TypeDefn, VarSet, Context).

:- pred mercury_output_type_defn_2(type_defn, varset, term__context,
			io__state, io__state).
:- mode mercury_output_type_defn_2(input, input, input, di, uo).

mercury_output_type_defn_2(uu_type(_Name, _Args, _Body), _VarSet, Context) -->
	io__stderr_stream(StdErr),
	io__set_output_stream(StdErr, OldStream),
	prog_out__write_context(Context),
	io__write_string("warning: undiscriminated union types not yet supported.\n"),
	io__set_output_stream(OldStream, _).

mercury_output_type_defn_2(abstract_type(Name, Args), VarSet, Context) -->
	io__write_string(":- type ("),
	{ unqualify_name(Name, Name2) },
	mercury_output_term(term_functor(term_atom(Name2), Args, Context),
			VarSet),
	io__write_string(").\n").

mercury_output_type_defn_2(eqv_type(Name, Args, Body), VarSet, Context) -->
	io__write_string(":- type ("),
	{ unqualify_name(Name, Name2) },
	mercury_output_term(term_functor(term_atom(Name2), Args, Context),
			VarSet),
	io__write_string(") == "),
	mercury_output_term(Body, VarSet),
	io__write_string(".\n").

mercury_output_type_defn_2(du_type(Name, Args, Ctors), VarSet, Context) -->
	io__write_string(":- type ("),
	{ unqualify_name(Name, Name2) },
	mercury_output_term(term_functor(term_atom(Name2), Args, Context),
			VarSet),
	io__write_string(")\n\t--->\t"),
	mercury_output_ctors(Ctors, VarSet),
	io__write_string(".\n").

:- pred mercury_output_ctors(list(constructor), varset,
				io__state, io__state).
:- mode mercury_output_ctors(input, input, di, uo).

mercury_output_ctors([], _) --> [].
mercury_output_ctors([Name - ArgTypes | Ctors], VarSet) -->
	% we need to quote ';'/2 and '{}'/2
	{ length(ArgTypes, Arity) },
	(
		{ Arity = 2 },
		{ Name = unqualified(";") ; Name = unqualified("{}") }
	->
		io__write_string("{ ")
	;
		[]
	),
	mercury_output_sym_name(Name),
	(
		{ ArgTypes = [ArgType | Rest] }
	->
		io__write_string("("),
		mercury_output_term(ArgType, VarSet),
		mercury_output_remaining_terms(Rest, VarSet),
		io__write_string(")")
	;
		[]
	),
	(
		{ Arity = 2 },
		{ Name = unqualified(";") ; Name = unqualified("{}") }
	->
		io__write_string(" }")
	;
		[]
	),
	( { Ctors \= [] } ->
		io__write_string("\n\t;\t")
	;	
		[]
	),
	mercury_output_ctors(Ctors, VarSet).

%-----------------------------------------------------------------------------%

:- pred mercury_output_pred_decl(varset, sym_name, list(type_and_mode),
		determinism, term__context, io__state, io__state).
:- mode mercury_output_pred_decl(input, input, input, input, input, di, uo).

mercury_output_pred_decl(VarSet, PredName, TypesAndModes, Det, Context) -->
	{ split_types_and_modes(TypesAndModes, Types, MaybeModes) },
	mercury_output_pred_type(VarSet, PredName, Types, Context),
	(
		{ MaybeModes = yes(Modes) }
	->
		mercury_output_mode_decl(VarSet, PredName, Modes, Det, Context)
	;
		[]
	).

:- pred mercury_output_pred_type(varset, sym_name, list(type),
		term__context, io__state, io__state).
:- mode mercury_output_pred_type(input, input, input, input, di, uo).

mercury_output_pred_type(VarSet, PredName, Types, _Context) -->
	io__write_string(":- pred "),
	mercury_output_sym_name(PredName),
	(
		{ Types = [Type | Rest] }
	->
		io__write_string("("),
		mercury_output_term(Type, VarSet),
		mercury_output_remaining_terms(Rest, VarSet),
		io__write_string(")")
	;
		[]
	),

	% We need to handle is/2 specially, because it's used for
	% determinism annotations (`... is det'), and so the compiler
	% will misinterpret a bare `:- pred is(int, int_expr)' as
	% `:- pred int is int_expr' and then report some very confusing
	% error message.  Thus you _have_ to give a determinism
	% annotation in the pred declaration for is/2, eg.
	% `:- pred int(int, int_expr) is det.'
	% (Yes, this made me puke too.)

	(
		{ PredName = unqualified("is") },
		{ length(Types, 2) }
	->
		io__write_string(" is det")
	;
		[]
	),
	io__write_string(".\n").

:- pred mercury_output_remaining_terms(list(term), varset,
					io__state, io__state).
:- mode mercury_output_remaining_terms(input, input, di, uo).

mercury_output_remaining_terms([], _VarSet) --> [].
mercury_output_remaining_terms([Term | Terms], VarSet) -->
	io__write_string(", "),
	mercury_output_term(Term, VarSet),
	mercury_output_remaining_terms(Terms, VarSet).

%-----------------------------------------------------------------------------%

	% Output a mode declaration for a predicate.

:- pred mercury_output_mode_decl(varset, sym_name, list(mode), determinism,
			term__context, io__state, io__state).
:- mode mercury_output_mode_decl(input, input, input, input, input, di, uo).

mercury_output_mode_decl(VarSet, PredName, Modes, Det, _Context) -->
	io__write_string(":- mode "),
	mercury_output_sym_name(PredName),
	(
		{ Modes \= [] }
	->
		io__write_string("("),
		mercury_output_mode_list(Modes, VarSet),
		io__write_string(")")
	;
		[]
	),
	( { Det = unspecified } ->
		[]
	;
		io__write_string(" is "),
		mercury_output_det(Det)
	),
	io__write_string(".\n").

:- pred mercury_output_det(determinism, io__state, io__state).
:- mode mercury_output_det(in, di, uo).

mercury_output_det(det) -->
	io__write_string("det").
mercury_output_det(semidet) -->
	io__write_string("semidet").
mercury_output_det(nondet) -->
	io__write_string("nondet").

:- pred mercury_output_sym_name(sym_name, io__state, io__state).
:- mode mercury_output_sym_name(in, di, uo).

mercury_output_sym_name(Name) -->
	{ unqualify_name(Name, Name2) },
	io__write_constant(term_atom(Name2)).

%-----------------------------------------------------------------------------%

	% Output a clause.

:- pred mercury_output_clause(varset, sym_name, list(term), goal, term__context,
			io__state, io__state).
:- mode mercury_output_clause(input, input, input, input, input, di, uo).

mercury_output_clause(VarSet, PredName, Args, Body, Context) -->
	{ unqualify_name(PredName, PredName2) },
	mercury_output_term(term_functor(term_atom(PredName2), Args, Context),
			VarSet),
	(
		{ Body = true }
	->
		[]
	;
		io__write_string(" :-\n\t"),
		mercury_output_goal(Body, VarSet, 1)
	),
	io__write_string(".\n").

:- pred mercury_output_goal(goal, varset, int, io__state, io__state).
:- mode mercury_output_goal(input, input, input, di, uo).

mercury_output_goal(fail, _, _) -->
	io__write_string("fail").

mercury_output_goal(true, _, _) -->
	io__write_string("true").

mercury_output_goal(some(Vars, Goal), VarSet, Indent) -->
	( { Vars = [] } ->
		mercury_output_goal(Goal, VarSet, Indent)
	;
		io__write_string("(some ["),
		mercury_output_vars(Vars, VarSet),
		io__write_string("] "),
		{ Indent1 is Indent + 1 },
		mercury_output_newline(Indent1),
		mercury_output_goal(Goal, VarSet, Indent1),
		mercury_output_newline(Indent),
		io__write_string(")")
	).

mercury_output_goal(all(Vars, Goal), VarSet, Indent) -->
	( { Vars = [] } ->
		mercury_output_goal(Goal, VarSet, Indent)
	;
		io__write_string("(all ["),
		mercury_output_vars(Vars, VarSet),
		io__write_string("] "),
		{ Indent1 is Indent + 1 },
		mercury_output_newline(Indent1),
		mercury_output_goal(Goal, VarSet, Indent1),
		mercury_output_newline(Indent),
		io__write_string(")")
	).

mercury_output_goal(if_then_else(Vars, A, B, C), VarSet, Indent) -->
	io__write_string("(if"),
	mercury_output_some(Vars, VarSet),
	{ Indent1 is Indent + 1 },
	mercury_output_newline(Indent1),
	mercury_output_goal(A, VarSet, Indent1),
	mercury_output_newline(Indent),
	io__write_string("then"),
	mercury_output_newline(Indent1),
	mercury_output_goal(B, VarSet, Indent1),
	mercury_output_newline(Indent),
	io__write_string("else"),
	mercury_output_newline(Indent1),
	mercury_output_goal(C, VarSet, Indent1),
	mercury_output_newline(Indent),
	io__write_string(")").

mercury_output_goal(if_then(Vars, A, B), VarSet, Indent) -->
	io__write_string("(if"),
	mercury_output_some(Vars, VarSet),
	{ Indent1 is Indent + 1 },
	mercury_output_newline(Indent1),
	mercury_output_goal(A, VarSet, Indent1),
	mercury_output_newline(Indent),
	io__write_string("then"),
	mercury_output_newline(Indent1),
	mercury_output_goal(B, VarSet, Indent1),
	mercury_output_newline(Indent),
	io__write_string(")").

mercury_output_goal(not(Vars, Goal), VarSet, Indent) -->
	io__write_string("(\+"),
	mercury_output_some(Vars, VarSet),
	{ Indent1 is Indent + 1 },
	mercury_output_newline(Indent1),
	mercury_output_goal(Goal, VarSet, Indent),
	mercury_output_newline(Indent),
	io__write_string(")").

mercury_output_goal((A,B), VarSet, Indent) -->
	mercury_output_goal(A, VarSet, Indent),
	io__write_string(","),
	mercury_output_newline(Indent),
	mercury_output_goal(B, VarSet, Indent).

mercury_output_goal((A;B), VarSet, Indent) -->
	io__write_string("("),
	{ Indent1 is Indent + 1 },
	mercury_output_newline(Indent1),
	mercury_output_goal(A, VarSet, Indent1),
	mercury_output_disj(B, VarSet, Indent),
	mercury_output_newline(Indent),
	io__write_string(")").

mercury_output_goal(call(Term), VarSet, Indent) -->
	mercury_output_call(Term, VarSet, Indent).

mercury_output_goal(unify(A, B), VarSet, _Indent) -->
	mercury_output_term(A, VarSet),
	io__write_string(" = "),
	mercury_output_term(B, VarSet).

:- pred mercury_output_call(term, varset, int, io__state, io__state).
:- mode mercury_output_call(input, input, input, di, uo).

mercury_output_call(Term, VarSet, _Indent) -->
	mercury_output_term(Term, VarSet).

:- pred mercury_output_disj(goal, varset, int, io__state, io__state).
:- mode mercury_output_disj(input, input, input, di, uo).

mercury_output_disj(Goal, VarSet, Indent) -->
	mercury_output_newline(Indent),
	io__write_string(";"),
	{ Indent1 is Indent + 1 },
	mercury_output_newline(Indent1),
	(
		{ Goal = (A;B) }
	->
		mercury_output_goal(A, VarSet, Indent1),
		mercury_output_disj(B, VarSet, Indent)
	;
		mercury_output_goal(Goal, VarSet, Indent1)
	).

:- pred mercury_output_some(list(var), varset, io__state, io__state).
:- mode mercury_output_some(input, input, di, uo).

mercury_output_some(Vars, VarSet) -->
	(
		{ Vars = [] }
	->
		[]
	;
		io__write_string(" some ["),
		mercury_output_vars(Vars, VarSet),
		io__write_string("]")
	).

%-----------------------------------------------------------------------------%

:- pred mercury_output_newline(int, io__state, io__state).
:- mode mercury_output_newline(input, di, uo).

mercury_output_newline(Indent) -->
	io__write_char('\n'),
	mercury_output_tabs(Indent).

:- pred mercury_output_tabs(int, io__state, io__state).
:- mode mercury_output_tabs(input, di, uo).

mercury_output_tabs(Indent) -->
	(if 
		{ Indent = 0 }
	then
		[]
	else
		io__write_char('\t'),
		{ Indent1 is Indent - 1 },
		mercury_output_tabs(Indent1)
	).

%-----------------------------------------------------------------------------%

:- pred mercury_output_list_args(term, varset, io__state, io__state).
:- mode mercury_output_list_args(input, input, di, uo).

mercury_output_list_args(Term, VarSet) -->
	(
	    	{ Term = term_functor(term_atom("."), Args, _),
		  Args = [X, Xs]
	    	}
	->
		io__write_string(", "),
		mercury_output_term(X, VarSet),
		mercury_output_list_args(Xs, VarSet)
	;
		{ Term = term_functor(term_atom("[]"), [], _) }
	->
		[]
	;
		io__write_string(" | "),
		mercury_output_term(Term, VarSet)
	).

	% write a term to standard output.

:- pred mercury_output_term(term, varset, io__state, io__state).
:- mode mercury_output_term(input, input, di, uo).

mercury_output_term(term_variable(Var), VarSet) -->
	mercury_output_var(Var, VarSet).
mercury_output_term(term_functor(Functor, Args, _), VarSet) -->
	(
	    	{ Functor = term_atom("."),
		  Args = [X, Xs]
	    	}
	->
		io__write_string("["),
		mercury_output_term(X, VarSet),
		mercury_output_list_args(Xs, VarSet),
		io__write_string("]")
	;
		{ Args = [PrefixArg],
		  Functor = term_atom(FunctorName),
		  mercury_unary_prefix_op(FunctorName)
	    	}
	->
		io__write_string("("),
		io__write_constant(Functor),
		io__write_string(" "),
		mercury_output_term(PrefixArg, VarSet),
		io__write_string(")")
	;
		{ Args = [PostfixArg],
		  Functor = term_atom(FunctorName),
		  mercury_unary_postfix_op(FunctorName)
	    	}
	->
		io__write_string("("),
		mercury_output_term(PostfixArg, VarSet),
		io__write_string(" "),
		io__write_constant(Functor),
		io__write_string(")")
	;
		{ Args = [Arg1, Arg2],
		  Functor = term_atom(FunctorName),
		  mercury_infix_op(FunctorName)
		}
	->
		io__write_string("("),
		mercury_output_term(Arg1, VarSet),
		io__write_string(" "),
		io__write_constant(Functor),
		io__write_string(" "),
		mercury_output_term(Arg2, VarSet),
		io__write_string(")")
	;
		io__write_constant(Functor),
		(
			{ Args = [Y | Ys] }
		->
			io__write_string("("),
			mercury_output_term(Y, VarSet),
			mercury_output_remaining_terms(Ys, VarSet),
			io__write_string(")")
		;
			[]
		)
	).

	% output a comma-separated list of variables

:- pred mercury_output_vars(list(var), varset, io__state, io__state).
:- mode mercury_output_vars(input, input, di, uo).

mercury_output_vars([], _VarSet) --> [].
mercury_output_vars([Var | Vars], VarSet) -->
	mercury_output_var(Var, VarSet),
	mercury_output_vars_2(Vars, VarSet).

:- pred mercury_output_vars_2(list(var), varset, io__state, io__state).
:- mode mercury_output_vars_2(input, input, di, uo).

mercury_output_vars_2([], _VarSet) --> [].
mercury_output_vars_2([Var | Vars], VarSet) -->
	io__write_string(", "),
	mercury_output_var(Var, VarSet),
	mercury_output_vars_2(Vars, VarSet).

	% Output a single variable.
	% Variables that didn't have names are given the name "V_<n>"
	% where <n> is there variable id.
	% Variables whose name originally started with `V_' have their
	% name changed to start with `V__' to avoid name clashes.

:- pred mercury_output_var(var, varset, io__state, io__state).
:- mode mercury_output_var(input, input, di, uo).

mercury_output_var(Var, VarSet) -->
	(
		{ varset__lookup_name(VarSet, Var, Name) }
	->
		{ mercury_convert_var_name(Name, ConvertedName) },
		io__write_string(ConvertedName)
	;
		{ term__var_to_int(Var, Id),
		  string__int_to_string(Id, Num),
		  string__append("V_", Num, VarName)
		},
		io__write_string(VarName)
	).

%-----------------------------------------------------------------------------%

	% Predicates to test whether a functor is a Mercury operator

:- pred mercury_infix_op(string).
:- mode mercury_infix_op(input).

mercury_infix_op("-->").
mercury_infix_op(":-").
mercury_infix_op("::").
mercury_infix_op("where").
mercury_infix_op("sorted").	/* NU-Prolog */
mercury_infix_op("else").
mercury_infix_op("then").
mercury_infix_op(";").
mercury_infix_op("->").
mercury_infix_op(",").
mercury_infix_op("to").		/* NU-Prolog */
mercury_infix_op("all").		
mercury_infix_op("gAll").	/* NU-Prolog */
mercury_infix_op("some").		
mercury_infix_op("gSome").	/* NU-Prolog */
mercury_infix_op("<=").
mercury_infix_op("<=>").
mercury_infix_op("=>").
mercury_infix_op("when").	/* NU-Prolog */
mercury_infix_op("or").		/* NU-Prolog */
mercury_infix_op("and").	/* NU-Prolog */
mercury_infix_op("=").
mercury_infix_op("=..").
mercury_infix_op("=:=").
mercury_infix_op("=<").
mercury_infix_op("==").
mercury_infix_op("=\=").
mercury_infix_op(">").
mercury_infix_op(">=").
mercury_infix_op("<").
mercury_infix_op("<=").
mercury_infix_op("@<").		/* Prolog */
mercury_infix_op("@=<").	/* Prolog */
mercury_infix_op("@>").		/* Prolog */
mercury_infix_op("@>=").	/* Prolog */
mercury_infix_op("=").
mercury_infix_op("~=").		/* NU-Prolog */
mercury_infix_op("is").		
mercury_infix_op(".").		
mercury_infix_op(":").		
mercury_infix_op("+").
mercury_infix_op("-").
mercury_infix_op("/\\").
mercury_infix_op("\\/").
mercury_infix_op("*").
mercury_infix_op("/").
mercury_infix_op("//").
mercury_infix_op(">>").
mercury_infix_op("<<").
mercury_infix_op("**").
mercury_infix_op("mod").
mercury_infix_op("^").

:- pred mercury_unary_prefix_op(string).
:- mode mercury_unary_prefix_op(input).

mercury_unary_prefix_op(":-").
mercury_unary_prefix_op(":-").
mercury_unary_prefix_op("?-").
mercury_unary_prefix_op("pred").
mercury_unary_prefix_op("type").
mercury_unary_prefix_op("useIf").
mercury_unary_prefix_op("::").
mercury_unary_prefix_op("delete").
mercury_unary_prefix_op("insert").
mercury_unary_prefix_op("update").
mercury_unary_prefix_op("sorted").
mercury_unary_prefix_op("if").
mercury_unary_prefix_op("dynamic").
mercury_unary_prefix_op("pure").
mercury_unary_prefix_op("\+").
mercury_unary_prefix_op("lib").
mercury_unary_prefix_op("listing").
mercury_unary_prefix_op("man").
mercury_unary_prefix_op("nospy").
mercury_unary_prefix_op("not").
mercury_unary_prefix_op("once").
mercury_unary_prefix_op("spy").
mercury_unary_prefix_op("wait").
mercury_unary_prefix_op("~").
mercury_unary_prefix_op("+").
mercury_unary_prefix_op("-").

:- pred mercury_unary_postfix_op(string).
:- mode mercury_unary_postfix_op(input).

mercury_unary_postfix_op("sorted").

%-----------------------------------------------------------------------------%

	% Convert a Mercury variable into a Mercury variable name.  
	% This is tricky because the compiler may introduce new variables
	% who either don't have names at all, or whose names end in
	% some sequence of primes (eg. Var''').
	% We have to be careful that every possible variable
	% is mapped to a distinct name.  Variables without names are
	% given names starting with `V_' followed by a sequence of digits
	% corresponding to their variable id.
	% To ensure that this doesn't clash with any existing names,
	% any variables whose name originally started with `V_' get
	% another `V_' inserted at the start of their name.

	% Compiler's internal name	Converted name
	% ------------------------	--------------
	% none				V_[0-9]*
	% .*'+				V_[0-9]*_.*
	% V_.*				V_V_.*
	% anthing else			same as original name

:- pred mercury_convert_var_name(string, string).
:- mode mercury_convert_var_name(input, output) is det.

mercury_convert_var_name(Name, ConvertedName) :-
	( string__append(_, "'", Name) ->
		strip_trailing_primes(Name, StrippedName, NumPrimes),
		string__append("V_", StrippedName, Tmp1),
		string__int_to_string(NumPrimes, NumString),
		string__append(Tmp1, "_", Tmp2),
		string__append(Tmp2, NumString, ConvertedName)
	; string__prefix(Name, "V_") ->
		string__append("V_", Name, ConvertedName)
	;
		ConvertedName = Name
	).

:- pred strip_trailing_primes(string, string, int).
:- mode strip_trailing_primes(in, in, out).

strip_trailing_primes(Name0, Name, Num) :-
	( string__append(Name1, "'", Name0) ->
		strip_trailing_primes(Name1, Name, Num0),
		Num is Num0 + 1
	;
		Num = 0,
		Name = Name0
	).
	
%-----------------------------------------------------------------------------%

:- pred maybe_output_line_number(term__context, io__state, io__state).
:- mode maybe_output_line_number(in, di, uo).

maybe_output_line_number(Context) -->
	( { mercury_option_write_line_numbers } ->
		io__write_string("% "),
		prog_out__write_context(Context),
		io__write_string("\n")
	).

	% XXX - This predicate should be a command-line option.

:- pred mercury_option_write_line_numbers.
mercury_option_write_line_numbers :- true.

%-----------------------------------------------------------------------------%
