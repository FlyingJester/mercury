%---------------------------------------------------------------------------%
% Copyright (C) 1994-1998 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% file: call_gen.m
%
% main author: conway.
%
% This module provides predicates for generating procedure calls,
% including calls to higher-order pred variables.
%
%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- module call_gen.

:- interface.

:- import_module prog_data, hlds_pred, hlds_data, hlds_goal, llds, code_info.
:- import_module term, list, set, assoc_list, std_util.

:- pred call_gen__generate_higher_order_call(code_model, var, list(var),
			list(type), argument_modes, determinism,
			hlds_goal_info, code_tree, code_info, code_info).
:- mode call_gen__generate_higher_order_call(in, in, in, in, in, in, in, out,
				in, out) is det.

:- pred call_gen__generate_class_method_call(code_model, var, int, list(var),
			list(type), argument_modes, determinism, hlds_goal_info,
			code_tree, code_info, code_info).
:- mode call_gen__generate_class_method_call(in, in, in, in, in, in, in, in,
				out, in, out) is det.

:- pred call_gen__generate_call(code_model, pred_id, proc_id, list(var),
			hlds_goal_info, code_tree, code_info, code_info).
:- mode call_gen__generate_call(in, in, in, in, in, out, in, out) is det.

:- pred call_gen__generate_builtin(code_model, pred_id, proc_id, list(var),
			code_tree, code_info, code_info).
:- mode call_gen__generate_builtin(in, in, in, in, out, in, out) is det.

:- pred call_gen__partition_args(assoc_list(var, arg_info),
						list(var), list(var)).
:- mode call_gen__partition_args(in, out, out) is det.

:- pred call_gen__input_arg_locs(list(pair(var, arg_info)), 
				list(pair(var, arg_loc))).
:- mode call_gen__input_arg_locs(in, out) is det.

:- pred call_gen__output_arg_locs(list(pair(var, arg_info)), 
				list(pair(var, arg_loc))).
:- mode call_gen__output_arg_locs(in, out) is det.

:- pred call_gen__save_variables(set(var), code_tree,
						code_info, code_info).
:- mode call_gen__save_variables(in, out, in, out) is det.

%---------------------------------------------------------------------------%

:- implementation.

:- import_module hlds_module, code_util.
:- import_module arg_info, type_util, mode_util, unify_proc, instmap.
:- import_module trace, globals, options.
:- import_module bool, int, tree, map.
:- import_module varset, require.

%---------------------------------------------------------------------------%

call_gen__generate_call(CodeModel, PredId, ModeId, Arguments, GoalInfo, Code)
		-->

		% Find out which arguments are input and which are output.
	code_info__get_pred_proc_arginfo(PredId, ModeId, ArgInfo),
	{ assoc_list__from_corresponding_lists(Arguments, ArgInfo, ArgsInfos) },

		% Save the known variables on the stack, except those
		% generated by this call.
	{ call_gen__select_out_args(ArgsInfos, OutArgs) },
	call_gen__save_variables(OutArgs, SaveCode),

		% Save possibly unknown variables on the stack as well
		% if they may be needed on backtracking, and figure out the
		% call model.
	call_gen__prepare_for_call(CodeModel, FlushCode, CallModel, _, _),

		% Move the input arguments to their registers.
	code_info__setup_call(ArgsInfos, caller, SetupCode),

	trace__prepare_for_call(TraceCode),

		% Figure out what locations are live at the call point,
		% for use by the value numbering optimization.
	{ call_gen__input_args(ArgInfo, InputArguments) },
	call_gen__generate_call_livevals(OutArgs, InputArguments, LiveCode),

		% Figure out what variables will be live at the return point,
		% and where, for use in the accurate garbage collector, and
		% in the debugger.
	code_info__get_instmap(InstMap),
	{ goal_info_get_instmap_delta(GoalInfo, InstMapDelta) },
	{ instmap__apply_instmap_delta(InstMap, InstMapDelta,
		AfterCallInstMap) },
	{ call_gen__output_arg_locs(ArgsInfos, OutputArguments) },
		% We must update the code generator state to reflect
		% the situation after the call before building
		% the return liveness info. No later code in this
		% predicate depends on the old state.
	call_gen__rebuild_registers(ArgsInfos),
	call_gen__generate_return_livevals(OutArgs, OutputArguments,
		AfterCallInstMap, OutLiveVals),

		% Make the call.
	code_info__get_module_info(ModuleInfo),
	code_info__make_entry_label(ModuleInfo, PredId, ModeId, yes, Address),
	code_info__get_next_label(ReturnLabel),
	{ call_gen__call_comment(CodeModel, CallComment) },
	{ CallCode = node([
		call(Address, label(ReturnLabel), OutLiveVals, CallModel)
			- CallComment,
		label(ReturnLabel)
			- "continuation label"
	]) },

	call_gen__handle_failure(CodeModel, FailHandlingCode),

	{ Code =
		tree(SaveCode,
		tree(FlushCode,
		tree(SetupCode,
		tree(TraceCode,
		tree(LiveCode,
		tree(CallCode,
		     FailHandlingCode))))))
	}.

%---------------------------------------------------------------------------%

	%
	% For a higher-order call,
	% we split the arguments into inputs and outputs, put the inputs
	% in the locations expected by do_call_<detism>_closure in
	% runtime/mercury_ho_call.c, generate the call to that code,
	% and pick up the outputs from the locations that we know
	% the runtime system leaves them in.
	%
	% Lambda.m transforms the generated lambda predicates to
	% make sure that all inputs come before all outputs, so that
	% the code in the runtime system doesn't have trouble figuring out
	% which registers the arguments go in.
	%

call_gen__generate_higher_order_call(_OuterCodeModel, PredVar, Args, Types,
		Modes, Det, GoalInfo, Code) -->
	{ Modes = argument_modes(ArgIKT, ArgModes) },
	{ determinism_to_code_model(Det, CodeModel) },
	code_info__get_module_info(ModuleInfo),
	{ module_info_globals(ModuleInfo, Globals) },
	{ arg_info__ho_call_args_method(Globals, ArgsMethod) },
	{ instmap__init_reachable(BogusInstMap) },	% YYY
	{ make_arg_infos(ArgsMethod, Types, ArgModes, CodeModel, BogusInstMap,
		ArgIKT, ModuleInfo, ArgInfos) },
	{ assoc_list__from_corresponding_lists(Args, ArgInfos, ArgsInfos) },
	{ call_gen__partition_args(ArgsInfos, InVars, OutVars) },
	{ set__list_to_set(OutVars, OutArgs) },
	call_gen__save_variables(OutArgs, SaveCode),

	call_gen__prepare_for_call(CodeModel, FlushCode, CallModel,
		DoHigherCall, _),

		% place the immediate input arguments in registers
		% starting at r4.
	call_gen__generate_immediate_args(InVars, 4, InLocs, ImmediateCode),
	code_info__generate_stack_livevals(OutArgs, LiveVals0),
	{ set__insert_list(LiveVals0,
		[reg(r, 1), reg(r, 2), reg(r, 3) | InLocs], LiveVals) },
	(
		{ CodeModel = model_semi }
	->
		{ FirstArg = 2 }
	;
		{ FirstArg = 1 }
	),

	{ call_gen__outvars_to_outargs(OutVars, FirstArg, OutArguments) },
	{ call_gen__output_arg_locs(OutArguments, OutLocs) },
	code_info__get_instmap(InstMap),
	{ goal_info_get_instmap_delta(GoalInfo, InstMapDelta) },
	{ instmap__apply_instmap_delta(InstMap, InstMapDelta,
		AfterCallInstMap) },

	code_info__produce_variable(PredVar, PredVarCode, PredRVal),
	(
		{ PredRVal = lval(reg(r, 1)) }
	->
		{ CopyCode = empty }
	;
		{ CopyCode = node([
			assign(reg(r, 1), PredRVal) - "Copy pred-term"
		]) }
	),

	{ list__length(InVars, NInVars) },
	{ list__length(OutVars, NOutVars) },
	{ ArgNumCode = node([
		assign(reg(r, 2), const(int_const(NInVars))) -
			"Assign number of immediate input arguments",
		assign(reg(r, 3), const(int_const(NOutVars))) -
			"Assign number of output arguments"
	]) },

	trace__prepare_for_call(TraceCode),

		% We must update the code generator state to reflect
		% the situation after the call before building
		% the return liveness info. No later code in this
		% predicate depends on the old state.
	call_gen__rebuild_registers(OutArguments),
	call_gen__generate_return_livevals(OutArgs, OutLocs, AfterCallInstMap, 
		OutLiveVals),

	code_info__get_next_label(ReturnLabel),
	{ CallCode = node([
		livevals(LiveVals)
			- "",
		call(DoHigherCall, label(ReturnLabel), OutLiveVals, CallModel)
			- "Setup and call higher order pred",
		label(ReturnLabel)
			- "Continuation label"
	]) },

	call_gen__handle_failure(CodeModel, FailHandlingCode),

	{ Code =
		tree(SaveCode,
		tree(FlushCode,
		tree(ImmediateCode,
		tree(PredVarCode,
		tree(CopyCode,
		tree(ArgNumCode,
		tree(TraceCode,
		tree(CallCode,
		     FailHandlingCode))))))))
	}.

%---------------------------------------------------------------------------%

	%
	% For a class method call,
	% we split the arguments into inputs and outputs, put the inputs
	% in the locations expected by do_call_<detism>_class_method in
	% runtime/mercury_ho_call.c, generate the call to that code,
	% and pick up the outputs from the locations that we know
	% the runtime system leaves them in.
	%

call_gen__generate_class_method_call(_OuterCodeModel, TCVar, MethodNum, Args,
		Types, ArgModes, Det, GoalInfo, Code) -->
	{ determinism_to_code_model(Det, CodeModel) },
	code_info__get_globals(Globals),
	code_info__get_module_info(ModuleInfo),

	{ globals__get_args_method(Globals, ArgsMethod) },
	( { ArgsMethod = compact } ->
		[]
	;
		{ error("Sorry, typeclasses with simple args_method not yet implemented") }
	),
	{ ArgModes = argument_modes(InstTable, Modes) },
	{ instmap__init_reachable(BogusInstMap) },	% YYY
	{ make_arg_infos(ArgsMethod, Types, Modes, CodeModel,
		BogusInstMap, InstTable, ModuleInfo, ArgInfo) },
	{ assoc_list__from_corresponding_lists(Args, ArgInfo, ArgsAndArgInfo) },
	{ call_gen__partition_args(ArgsAndArgInfo, InVars, OutVars) },
	{ set__list_to_set(OutVars, OutArgs) },
	call_gen__save_variables(OutArgs, SaveCode),
	call_gen__prepare_for_call(CodeModel, FlushCode, CallModel,
		_, DoMethodCall),

		% place the immediate input arguments in registers
		% starting at r5.
	call_gen__generate_immediate_args(InVars, 5, InLocs, ImmediateCode),
	code_info__generate_stack_livevals(OutArgs, LiveVals0),
	{ set__insert_list(LiveVals0,
		[reg(r, 1), reg(r, 2), reg(r, 3), reg(r, 4) | InLocs], 
			LiveVals) },
	(
		{ CodeModel = model_semi }
	->
		{ FirstArg = 2 }
	;
		{ FirstArg = 1 }
	),
	{ call_gen__outvars_to_outargs(OutVars, FirstArg, OutArguments) },
	{ call_gen__output_arg_locs(OutArguments, OutLocs) },
	code_info__get_instmap(InstMap),
	{ goal_info_get_instmap_delta(GoalInfo, InstMapDelta) },
	{ instmap__apply_instmap_delta(InstMap, InstMapDelta,
		AfterCallInstMap) },

	code_info__produce_variable(TCVar, TCVarCode, TCVarRVal),
	(
		{ TCVarRVal = lval(reg(r, 1)) }
	->
		{ CopyCode = empty }
	;
		{ CopyCode = node([
			assign(reg(r, 1), TCVarRVal)
				- "Copy typeclass info"
		]) }
	),
	{ list__length(InVars, NInVars) },
	{ list__length(OutVars, NOutVars) },
	{ SetupCode = node([
		assign(reg(r, 2), const(int_const(MethodNum))) -
			"Index of class method in typeclass info",
		assign(reg(r, 3), const(int_const(NInVars))) -
			"Assign number of immediate input arguments",
		assign(reg(r, 4), const(int_const(NOutVars))) -
			"Assign number of output arguments"
	]) },

	trace__prepare_for_call(TraceCode),

		% We must update the code generator state to reflect
		% the situation after the call before building
		% the return liveness info. No later code in this
		% predicate depends on the old state.
	call_gen__rebuild_registers(OutArguments),
	call_gen__generate_return_livevals(OutArgs, OutLocs, AfterCallInstMap, 
		OutLiveVals),

	code_info__get_next_label(ReturnLabel),
	{ CallCode = node([
		livevals(LiveVals)
			- "",
		call(DoMethodCall, label(ReturnLabel), OutLiveVals, CallModel)
			- "Setup and call class method",
		label(ReturnLabel)
			- "Continuation label"
	]) },

	call_gen__handle_failure(CodeModel, FailHandlingCode),

	{ Code =
		tree(SaveCode,
		tree(FlushCode,
		tree(ImmediateCode,
		tree(TCVarCode,
		tree(CopyCode,
		tree(SetupCode,
		tree(TraceCode,
		tree(CallCode,
		     FailHandlingCode))))))))
	}.

%---------------------------------------------------------------------------%

:- pred call_gen__prepare_for_call(code_model, code_tree, call_model,
	code_addr, code_addr, code_info, code_info).
:- mode call_gen__prepare_for_call(in, out, out, out, out, in, out) is det.

call_gen__prepare_for_call(CodeModel, FlushCode, CallModel, Higher, Method) -->
	code_info__succip_is_used,
	(
		{ CodeModel = model_det },
		{ CallModel = det },
		{ Higher = do_det_closure },
		{ Method = do_det_class_method },
		{ FlushCode = empty }
	;
		{ CodeModel = model_semi },
		{ CallModel = semidet },
		{ Higher = do_semidet_closure },
		{ Method = do_semidet_class_method },
		{ FlushCode = empty }
	;
		{ CodeModel = model_non },
		code_info__may_use_nondet_tailcall(TailCall),
		{ CallModel = nondet(TailCall) },
		{ Higher = do_nondet_closure },
		{ Method = do_nondet_class_method },
		code_info__flush_resume_vars_to_stack(FlushCode),
		code_info__set_resume_point_and_frame_to_unknown
	).

:- pred call_gen__handle_failure(code_model, code_tree, code_info, code_info).
:- mode call_gen__handle_failure(in, out, in, out ) is det.

call_gen__handle_failure(CodeModel, FailHandlingCode) -->
	( { CodeModel = model_semi } ->
		code_info__get_next_label(ContLab),
		{ FailTestCode = node([
			if_val(lval(reg(r, 1)), label(ContLab))
				- "test for success"
		]) },
		code_info__generate_failure(FailCode),
		{ ContLabelCode = node([
			label(ContLab)
				- ""
		]) },
		{ FailHandlingCode =
			tree(FailTestCode,
			tree(FailCode, 
			     ContLabelCode))
		}
	;
		{ FailHandlingCode = empty }
	).

:- pred call_gen__call_comment(code_model, string).
:- mode call_gen__call_comment(in, out) is det.

call_gen__call_comment(model_det,  "branch to det procedure").
call_gen__call_comment(model_semi, "branch to semidet procedure").
call_gen__call_comment(model_non,  "branch to nondet procedure").

%---------------------------------------------------------------------------%

call_gen__save_variables(Args, Code) -->
	code_info__get_known_variables(Variables0),
	{ set__list_to_set(Variables0, Vars0) },
	{ set__difference(Vars0, Args, Vars1) },
	code_info__get_globals(Globals),
	{ globals__lookup_bool_option(Globals, typeinfo_liveness, 
		TypeinfoLiveness) },
	( 
		{ TypeinfoLiveness = yes }
	->
		code_info__get_proc_info(ProcInfo),
		{ proc_info_get_typeinfo_vars_setwise(ProcInfo, Vars1, 
			TypeInfoVars) },
		{ set__union(Vars1, TypeInfoVars, Vars) }
	;
		{ Vars = Vars1 }
	),
	{ set__to_sorted_list(Vars, Variables) },
	call_gen__save_variables_2(Variables, Code).

:- pred call_gen__save_variables_2(list(var), code_tree, code_info, code_info).
:- mode call_gen__save_variables_2(in, out, in, out) is det.

call_gen__save_variables_2([], empty) --> [].
call_gen__save_variables_2([Var | Vars], Code) -->
	( code_info__var_is_free_alias(Var) ->
		code_info__save_reference_on_stack(Var, CodeA)
	;
		code_info__save_variable_on_stack(Var, CodeA)
	),
	call_gen__save_variables_2(Vars, CodeB),
	{ Code = tree(CodeA, CodeB) }.

%---------------------------------------------------------------------------%

:- pred call_gen__rebuild_registers(assoc_list(var, arg_info),
							code_info, code_info).
:- mode call_gen__rebuild_registers(in, in, out) is det.

call_gen__rebuild_registers(Args) -->
	code_info__clear_all_registers,
	call_gen__rebuild_registers_2(Args).

:- pred call_gen__rebuild_registers_2(assoc_list(var, arg_info),
							code_info, code_info).
:- mode call_gen__rebuild_registers_2(in, in, out) is det.

call_gen__rebuild_registers_2([]) --> [].
call_gen__rebuild_registers_2([Var - arg_info(ArgLoc, Mode) | Args]) -->
	(
		{ Mode = top_out }
	->
		{ code_util__arg_loc_to_register(ArgLoc, Register) },
		code_info__set_var_location(Var, Register)
	;
		{ Mode = ref_out }
	->
		{ code_util__arg_loc_to_register(ArgLoc, Register) },
		code_info__set_var_reference_location(Var, Register)
	;
		{ true }
	),
	call_gen__rebuild_registers_2(Args).

%---------------------------------------------------------------------------%

call_gen__generate_builtin(CodeModel, PredId, ProcId, Args, Code) -->
	code_info__get_module_info(ModuleInfo),
	{ predicate_module(ModuleInfo, PredId, ModuleName) },
	{ predicate_name(ModuleInfo, PredId, PredName) },
	{
		code_util__translate_builtin(ModuleName, PredName,
			ProcId, Args, MaybeTestPrime, MaybeAssignPrime)
	->
		MaybeTest = MaybeTestPrime,
		MaybeAssign = MaybeAssignPrime
	;
		error("Unknown builtin predicate")
	},
	(
		{ CodeModel = model_det },
		(
			{ MaybeTest = no },
			{ MaybeAssign = yes(Var - Rval) }
		->
			code_info__cache_expression(Var, Rval),
			{ Code = empty }
		;
			{ error("Malformed det builtin predicate") }
		)
	;
		{ CodeModel = model_semi },
		(
			{ MaybeTest = yes(Test) }
		->
			( { Test = binop(BinOp, X0, Y0) } ->
				call_gen__generate_builtin_arg(X0, X, CodeX),
				call_gen__generate_builtin_arg(Y0, Y, CodeY),
				{ Rval = binop(BinOp, X, Y) },
				{ ArgCode = tree(CodeX, CodeY) }
			; { Test = unop(UnOp, X0) } ->
				call_gen__generate_builtin_arg(X0, X, ArgCode),
				{ Rval = unop(UnOp, X) }
			;
				{ error("Malformed semi builtin predicate") }
			),
			code_info__fail_if_rval_is_false(Rval, TestCode),
			( { MaybeAssign = yes(Var - AssignRval) } ->
				code_info__cache_expression(Var, AssignRval)
			;
				[]
			),
			{ Code = tree(ArgCode, TestCode) }
		;
			{ error("Malformed semi builtin predicate") }
		)
	;
		{ CodeModel = model_non },
		{ error("Nondet builtin predicate") }
	).

%---------------------------------------------------------------------------%

:- pred call_gen__generate_builtin_arg(rval, rval, code_tree,
	code_info, code_info).
:- mode call_gen__generate_builtin_arg(in, out, out, in, out) is det.

call_gen__generate_builtin_arg(Rval0, Rval, Code) -->
	( { Rval0 = var(Var) } ->
		code_info__produce_variable(Var, Code, Rval)
	;
		{ Rval = Rval0 },
		{ Code = empty }
	).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

call_gen__partition_args([], [], []).
call_gen__partition_args([V - arg_info(_Loc,Mode) | Rest], Ins, Outs) :-
	(
		arg_mode_is_input(Mode)
	->
		call_gen__partition_args(Rest, Ins0, Outs),
		Ins = [V | Ins0]
	;
		call_gen__partition_args(Rest, Ins, Outs0),
		Outs = [V | Outs0]
	).

%---------------------------------------------------------------------------%

:- pred call_gen__select_out_args(assoc_list(var, arg_info), set(var)).
:- mode call_gen__select_out_args(in, out) is det.

call_gen__select_out_args([], Out) :-
	set__init(Out).
call_gen__select_out_args([V - arg_info(_Loc, Mode) | Rest], Out) :-
	call_gen__select_out_args(Rest, Out0),
	(
		arg_mode_is_output(Mode)
	->
		set__insert(Out0, V, Out)
	;
		Out = Out0
	).

%---------------------------------------------------------------------------%

:- pred call_gen__input_args(list(arg_info), list(arg_loc)).
:- mode call_gen__input_args(in, out) is det.

call_gen__input_args([], []).
call_gen__input_args([arg_info(Loc, Mode) | Args], Vs) :-
	(
		arg_mode_is_input(Mode)
	->
		Vs = [Loc |Vs0]
	;
		Vs = Vs0
	),
	call_gen__input_args(Args, Vs0).

%---------------------------------------------------------------------------%

call_gen__input_arg_locs([], []).
call_gen__input_arg_locs([Var - arg_info(Loc, Mode) | Args], Vs) :-
	(
		arg_mode_is_input(Mode)
	->
		Vs = [Var - Loc | Vs0]
	;
		Vs = Vs0
	),
	call_gen__input_arg_locs(Args, Vs0).

call_gen__output_arg_locs([], []).
call_gen__output_arg_locs([Var - arg_info(Loc, Mode) | Args], Vs) :-
	(
		arg_mode_is_output(Mode)
	->
		Vs = [Var - Loc | Vs0]
	;
		Vs = Vs0
	),
	call_gen__output_arg_locs(Args, Vs0).

%---------------------------------------------------------------------------%

:- pred call_gen__generate_call_livevals(set(var), list(arg_loc), code_tree,
							code_info, code_info).
:- mode call_gen__generate_call_livevals(in, in, out, in, out) is det.

call_gen__generate_call_livevals(OutArgs, InputArgs, Code) -->
	code_info__generate_stack_livevals(OutArgs, LiveVals0),
	{ call_gen__insert_arg_livevals(InputArgs, LiveVals0, LiveVals) },
	{ Code = node([
		livevals(LiveVals) - ""
	]) }.

%---------------------------------------------------------------------------%

:- pred call_gen__insert_arg_livevals(list(arg_loc),
					set(lval), set(lval)).
:- mode call_gen__insert_arg_livevals(in, in, out) is det.

call_gen__insert_arg_livevals([], LiveVals, LiveVals).
call_gen__insert_arg_livevals([L | As], LiveVals0, LiveVals) :-
	code_util__arg_loc_to_register(L, R),
	set__insert(LiveVals0, R, LiveVals1),
	call_gen__insert_arg_livevals(As, LiveVals1, LiveVals).

%---------------------------------------------------------------------------%

:- pred call_gen__generate_return_livevals(set(var), list(pair(var, arg_loc)),
		instmap, list(liveinfo), code_info, code_info).
:- mode call_gen__generate_return_livevals(in, in, in, out, in, out) is det.

call_gen__generate_return_livevals(OutArgs, OutputArgs, AfterCallInstMap, 
		LiveVals) -->
	code_info__generate_stack_livelvals(OutArgs, AfterCallInstMap, 
		LiveVals0),
	code_info__get_globals(Globals),
	{ globals__want_return_layouts(Globals, WantReturnLayout) },
	call_gen__insert_arg_livelvals(OutputArgs, WantReturnLayout,
		AfterCallInstMap, LiveVals0, LiveVals).

% Maybe a varlist to type_id list would be a better way to do this...

%---------------------------------------------------------------------------%

:- pred call_gen__insert_arg_livelvals(list(pair(var, arg_loc)), bool, 
	instmap, list(liveinfo), list(liveinfo), code_info, code_info).
:- mode call_gen__insert_arg_livelvals(in, in, in, in, out, in, out) is det.

call_gen__insert_arg_livelvals([], _, _, LiveVals, LiveVals) --> [].
call_gen__insert_arg_livelvals([Var - L | As], WantReturnLayout,
		AfterCallInstMap, LiveVals0, LiveVals) -->
	code_info__get_varset(VarSet),
	{ varset__lookup_name(VarSet, Var, Name) },
	{ code_util__arg_loc_to_register(L, R) },
	(
		{ WantReturnLayout = yes }
	->
		{ instmap__lookup_var(AfterCallInstMap, Var, Inst) },

		code_info__variable_type(Var, Type),
		{ type_util__vars(Type, TypeVars) },
		code_info__find_typeinfos_for_tvars(TypeVars, TypeParams),
		code_info__get_inst_table(InstTable),
		{ QualifiedInst = qualified_inst(InstTable, Inst) },
		{ VarInfo = var(Var, Name, Type, QualifiedInst) },
		{ LiveVal = live_lvalue(direct(R), VarInfo, TypeParams) }
	;
		{ map__init(Empty) },
		{ LiveVal = live_lvalue(direct(R), unwanted, Empty) }
	),
	call_gen__insert_arg_livelvals(As, WantReturnLayout, AfterCallInstMap, 
		[LiveVal | LiveVals0], LiveVals).

%---------------------------------------------------------------------------%

:- pred call_gen__generate_immediate_args(list(var), int, list(lval), code_tree,
							code_info, code_info).
:- mode call_gen__generate_immediate_args(in, in, out, out, in, out) is det.

call_gen__generate_immediate_args([], _N, [], empty) --> [].
call_gen__generate_immediate_args([V | Vs], N0, [Lval | Lvals], Code) -->
	{ Lval = reg(r, N0) },
	code_info__place_var(V, Lval, Code0),
	{ N1 is N0 + 1 },
	call_gen__generate_immediate_args(Vs, N1, Lvals, Code1),
	{ Code = tree(Code0, Code1) }.

%---------------------------------------------------------------------------%

:- pred call_gen__outvars_to_outargs(list(var), int, assoc_list(var,arg_info)).
:- mode call_gen__outvars_to_outargs(in, in, out) is det.

call_gen__outvars_to_outargs([], _N, []).
call_gen__outvars_to_outargs([V | Vs], N0, [V - Arg | ArgInfos]) :-
	Arg = arg_info(N0, top_out),
	N1 is N0 + 1,
	call_gen__outvars_to_outargs(Vs, N1, ArgInfos).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%
