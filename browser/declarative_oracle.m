%-----------------------------------------------------------------------------%
% Copyright (C) 1999-2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
% File: declarative_oracle.m
% Author: Mark Brown
% Purpose:
%	This module implements the oracle for a Mercury declarative debugger.
% It is called by the front end of the declarative debugger to provide 
% information about the intended interpretation of the program being
% debugged.
%
% The module has a knowledge base as a sub-component.  This is a cache
% for all the assumptions that the oracle is currently making.  When
% the oracle is queried, it first checks the KB to see if an answer
% is available there.
%
% If no answer is available in the KB, then the oracle uses the UI 
% (in browser/declarative_user.m) to get the required answer from the
% user.  If any new knowledge is obtained, it is added to the KB so
% the user will not be asked the same question twice.
%

:- module mdb__declarative_oracle.

:- interface.

:- import_module mdb__declarative_debugger.
:- import_module mdb__declarative_execution.
:- import_module mdb.browser_info.

:- import_module io, bool, string.

	% A response that the oracle gives to a query about the
	% truth of an EDT node.
	%
:- type oracle_response(T)
	--->	oracle_answer(decl_answer(T))
	;	exit_diagnosis(T)
	;	abort_diagnosis.

	% The oracle state.  This is threaded around the declarative
	% debugger.
	%
:- type oracle_state.

	% Produce a new oracle state.
	%
:- pred oracle_state_init(io__input_stream::in, io__output_stream::in, 
	browser_info.browser_persistent_state::in, oracle_state::out) is det.

	% Add a module to the set of modules trusted by the oracle
	%
:- pred add_trusted_module(string::in, oracle_state::in, oracle_state::out) 
	is det. 

	% Add a predicate/function to the set of predicates/functions trusted 
	% by the oracle.
	%
:- pred add_trusted_pred_or_func(proc_layout::in, oracle_state::in, 
	oracle_state::out) is det. 

	% Trust all the modules in the Mercury standard library.
	%
:- pred trust_standard_library(oracle_state::in, oracle_state::out) is det.

	% remove_trusted(N, !Oracle).
	% Removes the (N-1)th trusted object from the set of trusted objects.
	% Fails if there are fewer than N-1 trusted modules (or N < 0).
	% The trusted set is turned into a sorted list before finding the
	% (N-1)th element.
	%
:- pred remove_trusted(int::in, oracle_state::in, oracle_state::out)
	is semidet.

	% get_trusted_list(Oracle, MDBCommandFormat, String).
	% Return a string listing the trusted objects.
	% If MDBCommandFormat is true then returns the list so that it can be
	% run as a series of mdb `trust' commands.  Otherwise returns them
	% in a format suitable for display only.
	%
:- pred get_trusted_list(oracle_state::in, bool::in, string::out) is det.

	% Query the oracle about the program being debugged.  The first
	% argument is a node in the evaluation tree, the second argument is the
	% oracle response.  The oracle state is threaded through so its
	% contents can be updated after user responses.
	%
:- pred query_oracle(decl_question(T)::in, oracle_response(T)::out,
	oracle_state::in, oracle_state::out, io__state::di, io__state::uo)
	is cc_multi.

	% Confirm that the node found is indeed an e_bug or an i_bug.  If
	% the bug is overruled, force the oracle to forget everything
	% it knows about the evidence that led to that bug.
	%
:- pred oracle_confirm_bug(decl_bug::in, decl_evidence(T)::in,
	decl_confirmation::out, oracle_state::in, oracle_state::out,
	io__state::di, io__state::uo) is cc_multi.

	% Revise a question in the oracle's knowledge base so that the oracle
	% will get an answer to the question from the user.
	%
:- pred revise_oracle(decl_question(T)::in, oracle_state::in, oracle_state::out)
	is cc_multi.

	% Returns the state of the term browser.
	%
:- func get_browser_state(oracle_state) 
	= browser_info.browser_persistent_state.

	% Sets the state of the term browser.
	%
:- pred set_browser_state(browser_info.browser_persistent_state::in,
	oracle_state::in, oracle_state::out) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module mdb__declarative_user.
:- import_module mdb__tree234_cc.
:- import_module mdb__set_cc.
:- import_module mdb__util.

:- import_module map, bool, std_util, set, int, bimap, counter, assoc_list,
	exception, list.
:- import_module library.

query_oracle(Question, Response, !Oracle, !IO) :-
	answer_known(!.Oracle, Question, MaybeAnswer),
	(
		MaybeAnswer = yes(Answer)
	->
		Response = oracle_answer(Answer)
	;
		make_user_question(!.Oracle ^ kb_revised, Question,
			UserQuestion),
		query_oracle_user(UserQuestion, Response, !Oracle, !IO)
	).

:- pred make_user_question(oracle_kb::in, decl_question(T)::in,
	user_question(T)::out) is cc_multi.

make_user_question(Revised, DeclQuestion, UserQuestion) :-
	query_oracle_kb(Revised, DeclQuestion, MaybeDeclAnswer),
	(
		MaybeDeclAnswer = yes(truth_value(_, DeclTruth))
	->
		UserQuestion = question_with_default(DeclQuestion, DeclTruth)
	;
		UserQuestion = plain_question(DeclQuestion)
	).

:- pred query_oracle_user(user_question(T)::in, oracle_response(T)::out,
	oracle_state::in, oracle_state::out, io__state::di, io__state::uo)
	is cc_multi.

query_oracle_user(UserQuestion, OracleResponse, !Oracle, !IO) :-
	User0 = !.Oracle ^ user_state,
	query_user(UserQuestion, UserResponse, User0, User, !IO),
	(
		UserResponse = user_answer(Question, Answer),
		OracleResponse = oracle_answer(Answer),
		Current0 = !.Oracle ^ kb_current,
		Revised0 = !.Oracle ^ kb_revised,
		retract_oracle_kb(Question, Revised0, Revised),
		assert_oracle_kb(Question, Answer, Current0, Current),
		!:Oracle = (!.Oracle
				^ kb_current := Current)
				^ kb_revised := Revised
	;
		UserResponse = trust_predicate(Question),
		Atom = get_decl_question_atom(Question),
		add_trusted_pred_or_func(Atom ^ proc_layout, !Oracle),
		OracleResponse = oracle_answer(
			ignore(get_decl_question_node(Question)))
	;
		UserResponse = trust_module(Question),
		Atom = get_decl_question_atom(Question),
		ProcId = get_proc_id_from_layout(Atom ^ proc_layout),
		get_pred_attributes(ProcId, Module, _, _, _),
		add_trusted_module(Module, !Oracle),
		OracleResponse = oracle_answer(
			ignore(get_decl_question_node(Question)))
	;
		UserResponse = exit_diagnosis(Node),
		OracleResponse = exit_diagnosis(Node)
	;
		UserResponse = abort_diagnosis,
		OracleResponse = abort_diagnosis
	),
	!:Oracle = !.Oracle ^ user_state := User.

oracle_confirm_bug(Bug, Evidence, Confirmation, Oracle0, Oracle, !IO) :-
	User0 = Oracle0 ^ user_state,
	user_confirm_bug(Bug, Confirmation, User0, User, !IO),
	Oracle1 = Oracle0 ^ user_state := User,
	(
		Confirmation = overrule_bug
	->
		list__foldl(revise_oracle, Evidence, Oracle1, Oracle)
	;
		Oracle = Oracle1
	).

revise_oracle(Question, !Oracle) :-
	Current0 = !.Oracle ^ kb_current,
	query_oracle_kb(Current0, Question, MaybeAnswer),
	(
		MaybeAnswer = yes(Answer)
	->
		retract_oracle_kb(Question, Current0, Current),
		Revised0 = !.Oracle ^ kb_revised,
		assert_oracle_kb(Question, Answer, Revised0, Revised),
		!:Oracle = (!.Oracle
				^ kb_revised := Revised)
				^ kb_current := Current
	;
		true
	).

%-----------------------------------------------------------------------------%

:- type oracle_state
	--->	oracle(
				% Current information about the intended
				% interpretation.  These answers have been
				% given, but have not since been revised.
			kb_current	:: oracle_kb,

				% Old information about the intended
				% interpretation.  These answers were given
				% and subsequently revised, but new answers
				% to the questions have not yet been given.
			kb_revised	:: oracle_kb,

				% User interface.
			user_state	:: user_state,
				
				% Modules and predicates/functions trusted
				% by the oracle. The second argument is an
				% id used to identify an object to remove.
			trusted		:: bimap(trusted_object, int),

				% Counter to allocate ids to trusted objects
			trusted_id_counter	:: counter
		).

oracle_state_init(InStr, OutStr, Browser, Oracle) :-
	oracle_kb_init(Current),
	oracle_kb_init(Old),
	user_state_init(InStr, OutStr, Browser, User),
	% Trust the standard library by default.
	bimap.set(bimap.init, standard_library, 0, Trusted),
	counter.init(1, Counter),
	Oracle = oracle(Current, Old, User, Trusted, Counter).
	
%-----------------------------------------------------------------------------%

:- type trusted_object
	--->	module(string) % all predicates/functions in a module
	;	predicate(
			string,		% module name
			string,		% pred name
			int		% arity
		)
	;	function(
			string,		% module name
			string,		% function name
			int		% arity including return value
		)
	;	standard_library.

add_trusted_module(ModuleName, !Oracle) :-
	counter.allocate(Id, !.Oracle ^ trusted_id_counter, Counter),
	(
		bimap.insert(!.Oracle ^ trusted, module(ModuleName), Id, 
			Trusted)
	->
		!:Oracle = !.Oracle ^ trusted := Trusted,
		!:Oracle = !.Oracle ^ trusted_id_counter := Counter
	;
		true
	).

add_trusted_pred_or_func(ProcLayout, !Oracle) :-
	counter.allocate(Id, !.Oracle ^ trusted_id_counter, Counter),
	ProcId = get_proc_id_from_layout(ProcLayout),
	(
		ProcId = proc(ModuleName, PredOrFunc, _, Name, Arity, _)
	;
		ProcId = uci_proc(ModuleName, _, _, Name, Arity, _),
		PredOrFunc = predicate
	),
	(
		(
			PredOrFunc = predicate,
			bimap.insert(!.Oracle ^ trusted, predicate(ModuleName,
				Name, Arity), Id, Trusted)
		;
			PredOrFunc = function,
			bimap.insert(!.Oracle ^ trusted, function(ModuleName,
				Name, Arity), Id, Trusted)
		)
	->
		!:Oracle = !.Oracle ^ trusted := Trusted,
		!:Oracle = !.Oracle ^ trusted_id_counter := Counter
	;
		true
	).

trust_standard_library(!Oracle) :-
	counter.allocate(Id, !.Oracle ^ trusted_id_counter, Counter),
	(
		bimap.insert(!.Oracle ^ trusted, standard_library, Id,
			Trusted)
	->
		!:Oracle = !.Oracle ^ trusted_id_counter := Counter,
		!:Oracle = !.Oracle ^ trusted := Trusted
	;
		true
	).

remove_trusted(Id, !Oracle) :-
	bimap.search(!.Oracle ^ trusted, _, Id),
	bimap.delete_value(Id, !.Oracle ^ trusted, Trusted),
	!:Oracle = !.Oracle ^ trusted := Trusted. 

get_trusted_list(Oracle, yes, CommandsStr) :-
	TrustedObjects = bimap.ordinates(Oracle ^ trusted),
	list.foldl(format_trust_command, TrustedObjects, "", CommandsStr).
get_trusted_list(Oracle, no, DisplayStr) :-
	IdToObjectMap = bimap.reverse_map(Oracle ^ trusted),
	map.foldl(format_trust_display, IdToObjectMap, "", DisplayStr0),
	(
		DisplayStr0 = ""
	->
		DisplayStr = "There are no trusted modules, predicates " ++
			"or functions.\n"
	;
		DisplayStr = "Trusted Objects:\n" ++ DisplayStr0
	).

:- pred format_trust_command(trusted_object::in, string::in,
	string::out) is det.

format_trust_command(module(ModuleName), S, S ++ "trust " ++ ModuleName++"\n").
format_trust_command(predicate(ModuleName, Name, Arity), S, S ++ Command) :-
	ArityStr = int_to_string(Arity),
	Command = "trust pred*" ++ ModuleName ++ "."++Name ++ "/" ++ ArityStr 
	++ "\n".
format_trust_command(function(ModuleName, Name, Arity), S, S ++ Command) :-
	ArityStr = int_to_string(Arity - 1),
	Command = "trust func*"++ModuleName ++ "." ++ Name++"/" ++ ArityStr ++
	"\n".
format_trust_command(standard_library, S, S ++ "trust std lib\n").

:- pred format_trust_display(int::in, trusted_object::in, string::in, 
	string::out) is det.

format_trust_display(Id, module(ModuleName), S, S ++ Display) :-
	Display = int_to_string(Id) ++ ": module " ++ ModuleName ++ "\n".
format_trust_display(Id, predicate(ModuleName, Name, Arity), S, S ++ Display) 
		:-
	Display = int_to_string(Id) ++ ": predicate " ++ ModuleName ++ "." ++
		Name ++ "/" ++ int_to_string(Arity) ++ "\n".
format_trust_display(Id, function(ModuleName, Name, Arity), S, S ++ Display)
		:-
	Display = int_to_string(Id) ++ ": function " ++ ModuleName ++ "." ++
		Name++"/" ++ int_to_string(Arity - 1) ++ "\n".
format_trust_display(Id, standard_library, S, S ++ Display) :-
	Display = int_to_string(Id) ++ ": the Mercury standard library\n".
		
%-----------------------------------------------------------------------------%

	%
	% This section implements the oracle knowledge base, which
	% stores anything that the debugger knows about the intended
	% interpretation.  This can be used to check the correctness
	% of an EDT node.
	%

	% The type of the knowledge base.  Other fields may be added in
	% the future, such as for assertions made on-the-fly by the user,
	% or assertions in the program text.
	%
:- type oracle_kb
	---> oracle_kb(

		% For ground atoms, the knowledge is represented directly
		% with a map.  This is used, for example, in the common
		% case that the user supplies a truth value for a
		% "wrong answer" node.
		%
		kb_ground_map :: map_cc(final_decl_atom, decl_truth),

		% This map stores knowledge about the completeness of the
		% set of solutions generated by calling the given initial
		% atom.  This is used, for example, in the common case that
		% the user supplies a truth value for a "missing answer"
		% node.
		%
		kb_complete_map :: map_cc(init_decl_atom, decl_truth),

		% Mapping from call atoms to information about which
		% exceptions are possible or impossible.
		%
		kb_exceptions_map :: map_cc(init_decl_atom, known_exceptions)
	).

:- type map_cc(K, V) == tree234_cc(K, V).

:- type known_exceptions
	--->	known_excp(
				% Possible exceptions
			possible	:: set_cc(decl_exception),
				% Impossible exceptions
			impossible	:: set_cc(decl_exception),
				% Exceptions from inadmissible calls
			inadmissible	:: set_cc(decl_exception)
		).

:- pred oracle_kb_init(oracle_kb).
:- mode oracle_kb_init(out) is det.

oracle_kb_init(oracle_kb(G, C, X)) :-
	tree234_cc__init(G),
	tree234_cc__init(C),
	tree234_cc__init(X).

:- pred get_kb_ground_map(oracle_kb, map_cc(final_decl_atom, decl_truth)).
:- mode get_kb_ground_map(in, out) is det.

get_kb_ground_map(KB, KB ^ kb_ground_map).

:- pred set_kb_ground_map(oracle_kb, map_cc(final_decl_atom, decl_truth),
	oracle_kb).
:- mode set_kb_ground_map(in, in, out) is det.

set_kb_ground_map(KB, M, KB ^ kb_ground_map := M).

:- pred get_kb_complete_map(oracle_kb,
	map_cc(init_decl_atom, decl_truth)).
:- mode get_kb_complete_map(in, out) is det.

get_kb_complete_map(KB, KB ^ kb_complete_map).

:- pred set_kb_complete_map(oracle_kb,
	map_cc(init_decl_atom, decl_truth), oracle_kb).
:- mode set_kb_complete_map(in, in, out) is det.

set_kb_complete_map(KB, M, KB ^ kb_complete_map := M).

:- pred get_kb_exceptions_map(oracle_kb,
	map_cc(init_decl_atom, known_exceptions)).
:- mode get_kb_exceptions_map(in, out) is det.

get_kb_exceptions_map(KB, KB ^ kb_exceptions_map).

:- pred set_kb_exceptions_map(oracle_kb,
	map_cc(init_decl_atom, known_exceptions), oracle_kb).
:- mode set_kb_exceptions_map(in, in, out) is det.

set_kb_exceptions_map(KB, M, KB ^ kb_exceptions_map := M).

%-----------------------------------------------------------------------------%

:- pred answer_known(oracle_state::in, decl_question(T)::in,
	maybe(decl_answer(T))::out) is cc_multi.

answer_known(Oracle, Question, MaybeAnswer) :-
	Atom = get_decl_question_atom(Question),
	(
		trusted(Atom ^ proc_layout, Oracle)
	->
		% We tell the analyser that this node doesn't contain a bug,
		% however it's children may still contain bugs, since 
		% trusted procs may call untrusted procs (for example
		% when an untrusted closure is passed to a trusted predicate).
		MaybeAnswer = yes(ignore(get_decl_question_node(Question)))
	;
		query_oracle_kb(Oracle ^ kb_current, Question, MaybeAnswer)
	).	

:- pred trusted(proc_layout::in, oracle_state::in) is semidet.

trusted(ProcLayout, Oracle) :-
	Trusted = Oracle ^ trusted,
	ProcId = get_proc_id_from_layout(ProcLayout),
	(
		ProcId = proc(Module, PredOrFunc, _, Name, Arity, _),
		(
			bimap.search(Trusted, standard_library, _),
			mercury_std_library_module(Module)
		;
			bimap.search(Trusted, module(Module), _)
		;
			PredOrFunc = predicate,
			bimap.search(Trusted, predicate(Module, Name, Arity), 
				_)
		;
			PredOrFunc = function,
			bimap.search(Trusted, function(Module, Name, Arity), _)
		)
	;
		ProcId = uci_proc(_, _, _, _, _, _)
	).

:- pred query_oracle_kb(oracle_kb::in, decl_question(T)::in,
	maybe(decl_answer(T))::out) is cc_multi.

query_oracle_kb(KB, Question, Result) :-
	Question = wrong_answer(Node, _, Atom),
	get_kb_ground_map(KB, Map),
	tree234_cc__search(Map, Atom, MaybeTruth),
	(
		MaybeTruth = yes(Truth),
		Result = yes(truth_value(Node, Truth))
	;
		MaybeTruth = no,
		Result = no
	).

query_oracle_kb(KB, Question, Result) :-
	Question = missing_answer(Node, Call, _Solns),
	get_kb_complete_map(KB, CMap),
	tree234_cc__search(CMap, Call, MaybeTruth),
	(
		MaybeTruth = yes(Truth),
		Result = yes(truth_value(Node, Truth))
	;
		MaybeTruth = no,
		Result = no
	).

query_oracle_kb(KB, Question, Result) :-
	Question = unexpected_exception(Node, Call, Exception),
	get_kb_exceptions_map(KB, XMap),
	tree234_cc__search(XMap, Call, MaybeX),
	(
		MaybeX = no,
		Result = no
	;
		MaybeX = yes(known_excp(Possible, Impossible, Inadmissible)),
		member(Exception, Possible, PossibleBool),
		(
			PossibleBool = yes,
			Result = yes(truth_value(Node, correct))
		;
			PossibleBool = no,
			member(Exception, Impossible, ImpossibleBool),
			(
				ImpossibleBool = yes,
				Result = yes(truth_value(Node, erroneous))
			;
				ImpossibleBool = no,
				member(Exception, Inadmissible,
					InadmissibleBool),
				(
					InadmissibleBool = yes,
					Result = yes(truth_value(Node, 
						inadmissible))
				;	
					InadmissibleBool = no,
					Result = no
				)
			)
		)
	).

	% assert_oracle_kb/3 assumes that the asserted fact is consistent
	% with the current knowledge base.  This will generally be the
	% case, since the user will never be asked questions which
	% the knowledge base knows anything about.
	%
:- pred assert_oracle_kb(decl_question(T), decl_answer(T), oracle_kb,
		oracle_kb).
:- mode assert_oracle_kb(in, in, in, out) is cc_multi.

assert_oracle_kb(_, suspicious_subterm(_, _, _), KB, KB).

assert_oracle_kb(_, ignore(_), KB, KB).

assert_oracle_kb(_, skip(_), KB, KB).

assert_oracle_kb(wrong_answer(_, _, Atom), truth_value(_, Truth), KB0, KB) :-
	get_kb_ground_map(KB0, Map0),
	ProcLayout = Atom ^ final_atom ^ proc_layout,
	%
	% Insert all modes for the atom if the atom is correct and just the
	% one mode if it's not correct.  In general we cannot insert all modes
	% for erroneous or inadmissible atoms since the atom might be
	% erroneous with respect to one mode, but inadmissible with respect to
	% another mode.
	%
	(
		Truth = correct
	->
		foldl(add_atom_to_ground_map(Truth, Atom),
			get_all_modes_for_layout(ProcLayout), Map0, Map)
	;
		add_atom_to_ground_map(Truth, Atom, ProcLayout, Map0, Map)
	),
	set_kb_ground_map(KB0, Map, KB).

assert_oracle_kb(missing_answer(_, Call, _), truth_value(_, Truth), KB0, KB) :-
	get_kb_complete_map(KB0, Map0),
	tree234_cc__set(Map0, Call, Truth, Map),
	set_kb_complete_map(KB0, Map, KB).

assert_oracle_kb(unexpected_exception(_, Call, Exception),
		truth_value(_, Truth), KB0, KB) :-
	get_kb_exceptions_map(KB0, Map0),
	tree234_cc__search(Map0, Call, MaybeX),
	(
		MaybeX = yes(KnownExceptions0)
	;
		MaybeX = no,
		set_cc.init(Possible0),
		set_cc.init(Impossible0),
		set_cc.init(Inadmissible0),
		KnownExceptions0 = known_excp(Possible0, Impossible0,
			Inadmissible0)
	),
	(
		Truth = correct,
		insert(KnownExceptions0 ^ possible, Exception, 
			Possible),
		KnownExceptions = KnownExceptions0 ^ possible := Possible
	;
		Truth = erroneous,
		insert(KnownExceptions0 ^ impossible, Exception, 
			Impossible),
		KnownExceptions = KnownExceptions0 ^ impossible := Impossible
	;
		Truth = inadmissible,
		insert(KnownExceptions0 ^ inadmissible, Exception, 
			Inadmissible),
		KnownExceptions = KnownExceptions0 ^ inadmissible := 	
			Inadmissible
	),
	tree234_cc__set(Map0, Call, KnownExceptions, Map),
	set_kb_exceptions_map(KB0, Map, KB).

:- pred retract_oracle_kb(decl_question(T), oracle_kb, oracle_kb).
:- mode retract_oracle_kb(in, in, out) is cc_multi.

retract_oracle_kb(wrong_answer(_, _, Atom), KB0, KB) :-
	Map0 = KB0 ^ kb_ground_map,
	% delete all modes of the predicate/function
	foldl(remove_atom_from_ground_map(Atom),
		get_all_modes_for_layout(Atom ^ final_atom ^ proc_layout),
		Map0, Map),
	KB = KB0 ^ kb_ground_map := Map.

retract_oracle_kb(missing_answer(_, InitAtom, _), KB0, KB) :-
	CompleteMap0 = KB0 ^ kb_complete_map,
	tree234_cc__delete(CompleteMap0, InitAtom, CompleteMap),
	KB = KB0 ^ kb_complete_map := CompleteMap.

retract_oracle_kb(unexpected_exception(_, InitAtom, Exception), KB0, KB) :-
	ExceptionsMap0 = KB0 ^ kb_exceptions_map,
	tree234_cc__search(ExceptionsMap0, InitAtom, MaybeKnownExceptions0),
	(
		MaybeKnownExceptions0 = yes(known_excp(Possible0, Impossible0,
			Inadmissible0))
	->
		set_cc__delete(Possible0, Exception, Possible),
		set_cc__delete(Impossible0, Exception, Impossible),
		set_cc__delete(Inadmissible0, Exception, Inadmissible),
		KnownExceptions = known_excp(Possible, Impossible,
			Inadmissible),
		tree234_cc__set(ExceptionsMap0, InitAtom, KnownExceptions,
			ExceptionsMap)
	;
		ExceptionsMap = ExceptionsMap0
	),
	KB = KB0 ^ kb_exceptions_map := ExceptionsMap.

:- pred add_atom_to_ground_map(decl_truth::in, final_decl_atom::in, 
	proc_layout::in, map_cc(final_decl_atom, decl_truth)::in,
	map_cc(final_decl_atom, decl_truth)::out) is cc_multi.

add_atom_to_ground_map(Truth, FinalAtom, ProcLayout, Map0, Map) :-
	tree234_cc.set(Map0, final_decl_atom(
		atom(ProcLayout, FinalAtom ^ final_atom ^ atom_args),
		FinalAtom ^ final_io_actions), Truth, Map).

:- pred remove_atom_from_ground_map(final_decl_atom::in, 
	proc_layout::in, map_cc(final_decl_atom, decl_truth)::in,
	map_cc(final_decl_atom, decl_truth)::out) is cc_multi.

remove_atom_from_ground_map(FinalAtom, ProcLayout, Map0, Map) :-
	tree234_cc.delete(Map0, final_decl_atom(
		atom(ProcLayout, FinalAtom ^ final_atom ^ atom_args),
		FinalAtom ^ final_io_actions), Map).

%-----------------------------------------------------------------------------%

get_browser_state(Oracle) = 
	mdb.declarative_user.get_browser_state(Oracle ^ user_state).

set_browser_state(Browser, !Oracle) :-
	mdb.declarative_user.set_browser_state(Browser, !.Oracle ^ user_state,
		User),
	!:Oracle = !.Oracle ^ user_state := User.
