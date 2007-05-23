%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2005-2007 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File rbmm.points_to_analysis.m.
% Main author: Quan Phan.
%
% This module implements the region points-to analysis (rpta), which collects 
% for each procedure a region points-to graph representing the splitting of 
% the heap used by the procedure into regions, i.e., which variables are 
% stored in which regions. Because the region model is polymorphic, i.e., we 
% can pass different actual regions for region arguments, the analysis also 
% gathers the alpha mapping, which maps formal region parameters to actual 
% ones at each call site in a procedure. So there are 2 sorts of information:
% region points-to graph (rptg) and alpha mapping.
%
% The analysis is composed of 2 phases:
%	1. intraprocedural analysis: only analyses unifications and compute only
%   rptgs.
%	2. interprocedural analysis: only analyses (plain) procedure calls, 
%   compute both rptgs and alpha mappings.
% 
%
% Currently the analysis ONLY collects the information, do NOT record it into 
% the HLDS.
% 
%-----------------------------------------------------------------------------%

:- module transform_hlds.rbmm.points_to_analysis.
:- interface.

:- import_module hlds.
:- import_module hlds.hlds_module.
:- import_module transform_hlds.rbmm.points_to_info.

%-----------------------------------------------------------------------------%

:- pred region_points_to_analysis(rpta_info_table::out,
    module_info::in, module_info::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds.
:- import_module check_hlds.goal_path. 
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_pred.
:- import_module libs.
:- import_module libs.compiler_util.
:- import_module parse_tree.
:- import_module parse_tree.prog_data. 
:- import_module transform_hlds.dependency_graph.
:- import_module transform_hlds.rbmm.points_to_graph.
:- import_module transform_hlds.smm_common.
:- import_module transform_hlds.ctgc.
:- import_module transform_hlds.ctgc.fixpoint_table.

:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module set.
:- import_module string.
:- import_module svmap.
:- import_module term.

%-----------------------------------------------------------------------------%

region_points_to_analysis(InfoTable, !ModuleInfo) :-
    rpta_info_table_init = InfoTable0,
    intra_proc_rpta(!.ModuleInfo, InfoTable0, InfoTable1),	
    inter_proc_rpta(!.ModuleInfo, InfoTable1, InfoTable).

%----------------------------------------------------------------------------%
%
% Intraprocedural region points-to analysis.
%

:- pred intra_proc_rpta(module_info::in,
    rpta_info_table::in, rpta_info_table::out) is det.

intra_proc_rpta(ModuleInfo, !InfoTable) :-
    module_info_predids(PredIds, ModuleInfo, _),
    list.foldl(intra_proc_rpta_pred(ModuleInfo), PredIds, !InfoTable).

:- pred intra_proc_rpta_pred(module_info::in, pred_id::in, 
    rpta_info_table::in, rpta_info_table::out) is det.

intra_proc_rpta_pred(ModuleInfo, PredId, !InfoTable) :-
    module_info_pred_info(ModuleInfo, PredId, PredInfo),
    ProcIds = pred_info_non_imported_procids(PredInfo),
    list.foldl(intra_proc_rpta_proc(ModuleInfo, PredId), ProcIds, !InfoTable).

:- pred intra_proc_rpta_proc(module_info::in, pred_id::in, proc_id::in, 
    rpta_info_table::in, rpta_info_table::out) is det.

intra_proc_rpta_proc(ModuleInfo, PredId, ProcId, !InfoTable) :-
    PPId = proc(PredId, ProcId),
    intra_analyse_pred_proc(ModuleInfo, PPId, !InfoTable).

:- pred intra_analyse_pred_proc(module_info::in, pred_proc_id::in, 
    rpta_info_table::in, rpta_info_table::out) is det.

intra_analyse_pred_proc(ModuleInfo, PPId, !InfoTable) :-
    ( if    some_are_special_preds([PPId], ModuleInfo)
      then  true
      else
            module_info_proc_info(ModuleInfo, PPId, ProcInfo),
            RptaInfo0 = rpta_info_init(ProcInfo),
            proc_info_get_goal(ProcInfo, Goal),
            intra_analyse_goal(Goal, RptaInfo0, RptaInfo),
            rpta_info_table_set_rpta_info(PPId, RptaInfo, !InfoTable)
    ).

:- pred intra_analyse_goal(hlds_goal::in,
    rpta_info::in, rpta_info::out) is det.

intra_analyse_goal(Goal, !RptaInfo) :- 
    Goal = hlds_goal(GoalExpr, _), 
    intra_analyse_goal_expr(GoalExpr, !RptaInfo).
	
:- pred intra_analyse_goal_expr(hlds_goal_expr::in, 
    rpta_info::in, rpta_info::out) is det.

intra_analyse_goal_expr(conj(_ConjType, Goals), !RptaInfo) :- 
    list.foldl(intra_analyse_goal, Goals, !RptaInfo). 

    % Procedure calls are ignored in the intraprocedural analysis.
    %
intra_analyse_goal_expr(plain_call(_, _, _, _, _, _), !RptaInfo).

intra_analyse_goal_expr(generic_call(_,_,_,_), !RptaInfo) :-
    sorry(this_file,
        "intra_analyse_goal_expr: generic_call not handled").

intra_analyse_goal_expr(switch(_, _, Cases), !RptaInfo) :- 
    list.foldl(intra_analyse_case, Cases, !RptaInfo).

:- pred intra_analyse_case(case::in, rpta_info::in, rpta_info::out) is det.

intra_analyse_case(Case, !RptaInfo) :-
    Case = case(_, Goal),
    intra_analyse_goal(Goal, !RptaInfo).

    % Most of the processing in intraprocedural analysis happens to
    % unifications.
    %
intra_analyse_goal_expr(unify(_, _, _, Unification, _), !RptaInfo) :- 
    process_unification(Unification, !RptaInfo).

intra_analyse_goal_expr(disj(Goals), !RptaInfo) :-
    list.foldl(intra_analyse_goal, Goals, !RptaInfo). 

intra_analyse_goal_expr(negation(Goal), !RptaInfo) :- 
    intra_analyse_goal(Goal, !RptaInfo). 

    % scope 
    % XXX: only analyse the goal. May need to take into account the Reason. 
    %
intra_analyse_goal_expr(scope(_Reason, Goal), !RptaInfo) :- 
%    (
%	    ( Reason = exist_quant(_)
%        ; Reason = promise_solutions(_, _)      % XXX ???
%        ; Reason = promise_purity(_, _)
%        ; Reason = commit(_)                    % XXX ???
%        ; Reason = barrier(_)
%        ; Reason = trace_goal(_, _, _, _, _)
%        ; Reason = from_ground_term(_)
%        ),
        intra_analyse_goal(Goal, !RptaInfo).
%    ;
%        Msg = "intra_analyse_goal_expr: Scope's reason of from_ground_term "
%            ++ "not handled",
%        unexpected(this_file, Msg)
%    ).

intra_analyse_goal_expr(if_then_else(_Vars, If, Then, Else), !RptaInfo) :- 
    intra_analyse_goal(If, !RptaInfo),
    intra_analyse_goal(Then, !RptaInfo),
    intra_analyse_goal(Else, !RptaInfo).

intra_analyse_goal_expr(GoalExpr, !RptaInfo) :-
    GoalExpr = call_foreign_proc(_, _, _, _, _, _, _),
    unexpected(this_file,
        "intra_analyse_goal_expr: call_foreign_proc not handled").

intra_analyse_goal_expr(shorthand(_), !RptaInfo) :- 
    unexpected(this_file, "intra_analyse_goal_expr: shorthand not handled").
    
:- pred process_unification(unification::in,
    rpta_info::in, rpta_info::out) is det.

    % For construction and deconstruction, add edges from LVar to 
    % each of RVars.
process_unification(construct(LVar, ConsId, RVars, _, _, _, _), !RptaInfo) :-
    list.foldl2(process_cons_and_decons(LVar, ConsId), RVars, 
        1, _, !RptaInfo).
	
process_unification(deconstruct(LVar, ConsId, RVars, _, _, _), !RptaInfo) :-
    list.foldl2(process_cons_and_decons(LVar, ConsId), RVars, 
        1, _, !RptaInfo).

:- pred process_cons_and_decons(prog_var::in, cons_id::in, prog_var::in,
    int::in, int::out, rpta_info::in, rpta_info::out) is det.
process_cons_and_decons(LVar, ConsId, RVar, !Component, !RptaInfo) :-
    !.RptaInfo = rpta_info(Graph0, AlphaMapping),
    get_node_by_variable(Graph0, LVar, Node1),
    get_node_by_variable(Graph0, RVar, Node2),
    Sel = [termsel(ConsId, !.Component)],
    ArcContent = rptg_arc_content(Sel),

    % Only add the edge if it is not in the graph
    % It is more suitable to the edge_operator's semantics if we check 
    % this inside the edge_operator. But we also want to know if the edge
    % is actually added or not so it is convenient to check the edge's 
    % existence outside edge_operator. Otherwise we can extend edge_operator
    % with one more argument to indicate that.
    ( if
        edge_in_graph(Node1, ArcContent, Node2, Graph0)
      then
        true
      else
        edge_operator(Node1, Node2, ArcContent, Graph0, Graph1),
        RptaInfo1 = rpta_info(Graph1, AlphaMapping), 

        % After an edge is added, rules P2 and P3 are applied to ensure 
        % the invariants of the graph.
        apply_rule_2(Node1, Node2, ConsId, !.Component, RptaInfo1, RptaInfo2),
        RptaInfo2 = rpta_info(Graph2, _),	
        get_node_by_variable(Graph2, RVar, RVarNode),
        apply_rule_3(RVarNode, RptaInfo2, !:RptaInfo)
    ),
    !:Component = !.Component + 1.

    % Unification is an assignment: merge the corresponding nodes of ToVar 
    % and FromVar.
    % 
process_unification(assign(ToVar, FromVar), !RptaInfo) :-
    !.RptaInfo = rpta_info(Graph0, AlphaMapping),
    get_node_by_variable(Graph0, ToVar, ToNode),
    get_node_by_variable(Graph0, FromVar, FromNode),
    ( if
        ToNode = FromNode
      then
        true
      else
        unify_operator(ToNode, FromNode, Graph0, Graph1),
        RptaInfo1 = rpta_info(Graph1, AlphaMapping),
        % After the merge of two nodes, apply rule P1 to ensure rptg's 
        % invariants.
        apply_rule_1(ToNode, RptaInfo1, !:RptaInfo)
    ).

    % Do nothing with the simple test.
    %
process_unification(simple_test(_, _), !RptaInfo).

    % XXX: do not consider this for the time being.
    %
process_unification(complicated_unify(_, _, _), !RptaInfo).

%-----------------------------------------------------------------------------%
%
% The part for interprocedural analysis.
%

    % The interprocedural analysis requires fixpoint computation,
    % so we will compute a fixpoint for each strongly connected component. 
    %
:- pred inter_proc_rpta(module_info::in, rpta_info_table::in, 
    rpta_info_table::out) is det.

inter_proc_rpta(ModuleInfo0, !InfoTable) :-
    module_info_ensure_dependency_info(ModuleInfo0, ModuleInfo),
    module_info_get_maybe_dependency_info(ModuleInfo, MaybeDepInfo),
    (
        MaybeDepInfo = yes(DepInfo) 
    ->
        hlds_dependency_info_get_dependency_ordering(DepInfo, DepOrdering),
        run_with_dependencies(DepOrdering, ModuleInfo, !InfoTable)
    ;
        unexpected(this_file, "inter_proc_rpta: no dependency information")
    ).

:- pred run_with_dependencies(dependency_ordering::in, module_info::in, 
    rpta_info_table::in, rpta_info_table::out) is det.

run_with_dependencies(Deps, ModuleInfo, !InfoTable) :- 
    list.foldl(run_with_dependency(ModuleInfo), Deps, !InfoTable).

:- pred run_with_dependency(module_info::in, list(pred_proc_id)::in, 
    rpta_info_table::in, rpta_info_table::out) is det.

run_with_dependency(ModuleInfo, SCC, !InfoTable) :- 
    (
        % Analysis ignores special predicates.
        some_are_special_preds(SCC, ModuleInfo)
    ->
        true
    ;
        % For each list of strongly connected components, 
        % perform a fixpoint computation.
        rpta_info_fixpoint_table_init(SCC, !.InfoTable, FPtable0),
        run_with_dependency_until_fixpoint(SCC, FPtable0, ModuleInfo, 
            !InfoTable)
    ).

:- pred run_with_dependency_until_fixpoint(list(pred_proc_id)::in, 
    rpta_info_fixpoint_table::in, module_info::in, rpta_info_table::in, 
    rpta_info_table::out) is det.

run_with_dependency_until_fixpoint(SCC, FPtable0, ModuleInfo, !InfoTable) :-
    list.foldl(inter_analyse_pred_proc(ModuleInfo, !.InfoTable), SCC, 
        FPtable0, FPtable1),
    (
        rpta_info_fixpoint_table_all_stable(FPtable1)
    ->
        % If all rpta_info's in the FPTable are intact
        % update the main InfoTable.
        list.foldl(update_rpta_info_in_rpta_info_table(FPtable1), SCC, 
            !InfoTable)
    ;
        % Some is not fixed, start all over again. 
        rpta_info_fixpoint_table_new_run(FPtable1, FPtable2),
        run_with_dependency_until_fixpoint(SCC, FPtable2, ModuleInfo, 
            !InfoTable)
    ).

:- pred inter_analyse_pred_proc(module_info::in, rpta_info_table::in, 
    pred_proc_id::in, rpta_info_fixpoint_table::in, 
    rpta_info_fixpoint_table::out) is det.

inter_analyse_pred_proc(ModuleInfo, InfoTable, PPId, !FPTable) :- 
    % Look up the caller's rpta_info,
    % it should be there already after the intraprocedural analysis.
    % We start the interprocedural analysis of a procedure with this 
    % rpta_info.
    lookup_rpta_info(PPId, InfoTable, !FPTable, CallerRptaInfo0, _),
	
    % Start the analysis of the procedure's body.
    %
    % We will need the information about program point for storing alpha
    % mapping.
    module_info_proc_info(ModuleInfo, PPId, ProcInfo),
    fill_goal_path_slots(ModuleInfo, ProcInfo, ProcInfo1),

    % Goal now will contain information of program points.
    proc_info_get_goal(ProcInfo1, Goal),

    inter_analyse_goal(ModuleInfo, InfoTable, Goal, !FPTable,
        CallerRptaInfo0, CallerRptaInfo),
   
    % Put into the fixpoint table.
    rpta_info_fixpoint_table_new_rpta_info(PPId, CallerRptaInfo, !FPTable).

	% Analyse a given goal, with module_info and fixpoint table
	% to lookup extra information, starting from an initial abstract
	% substitution, and creating a new one. During this process,
	% the fixpoint table might change (when recursive predicates are
	% encountered).
	%
:- pred inter_analyse_goal(module_info::in, 
    rpta_info_table::in, hlds_goal::in, rpta_info_fixpoint_table::in, 
    rpta_info_fixpoint_table::out, rpta_info::in, rpta_info::out) is det.

inter_analyse_goal(ModuleInfo, InfoTable, Goal, !FPtable, !RptaInfo) :- 
    Goal = hlds_goal(GoalExpr, GoalInfo), 
    inter_analyse_goal_expr(GoalExpr, GoalInfo, ModuleInfo, InfoTable, 
        !FPtable, !RptaInfo).
	
:- pred inter_analyse_goal_expr(hlds_goal_expr::in, hlds_goal_info::in, 
    module_info::in, rpta_info_table::in, rpta_info_fixpoint_table::in, 
    rpta_info_fixpoint_table::out, rpta_info::in, rpta_info::out) is det.

inter_analyse_goal_expr(conj(_ConjType, Goals), _, ModuleInfo, 
        InfoTable, !FPTable, !RptaInfo) :- 
    list.foldl2(inter_analyse_goal(ModuleInfo, InfoTable), Goals,
        !FPTable, !RptaInfo). 

    % There are two rpta_info's: 
    % one is of the currently-analysed procedure (caller) which we are going 
    % to update, the other is of the called procedure (callee).
    %
    % The input RptaInfo0 is caller's, if the procedure calls itself then 
    % this is also that of the callee but we will retrieve it again from the 
    % InfoTable.
    %
inter_analyse_goal_expr(plain_call(PredId, ProcId, ActualParams, _,_, _PName), 
        GoalInfo, ModuleInfo, InfoTable, FPTable0, FPTable,
        !CallerRptaInfo) :- 
    CalleePPId = proc(PredId, ProcId),

    % Get callee's rpta_info.
    % As what I assume now, after the intraprocedural analysis we have all
    % the rpta_info's of all the procedures in the InfoTable, therefore
    % this lookup cannot fail. But it sometimes fails because the callee
    % can be imported procedures, built-ins and so forth which are not 
    % analysed by the intraprocedural analysis. In such cases, I assume that
    % the rpta_info of the caller is not updated, because no information is
    % available from the callee.
    % When IsInit = no, the CalleeRptaInfo is dummy.
    lookup_rpta_info(CalleePPId, InfoTable, FPTable0, FPTable, 
        CalleeRptaInfo, IsInit),
    (
        IsInit = bool.yes
    ;
        IsInit = bool.no,
        CallSite = program_point_init(GoalInfo),
        CalleeRptaInfo = rpta_info(CalleeGraph, _),

        % Collect alpha mapping at this call site.
        module_info_proc_info(ModuleInfo, CalleePPId, CalleeProcInfo),
        proc_info_get_headvars(CalleeProcInfo, FormalParams),
        !.CallerRptaInfo = rpta_info(CallerGraph0, CallerAlphaMappings0),
        alpha_mapping_at_call_site(FormalParams, ActualParams, CalleeGraph, 
            CallerGraph0, CallerGraph,
            map.init, CallerAlphaMappingAtCallSite),
        svmap.set(CallSite, CallerAlphaMappingAtCallSite, 
            CallerAlphaMappings0, CallerAlphaMappings),
        CallerRptaInfo1 = rpta_info(CallerGraph, CallerAlphaMappings),
    
        % Follow the edges from the nodes rooted at the formal parameters
        % (in the callee's graph) and apply the interprocedural rules to
        % complete the alpha mapping and update the caller's graph with
        % the information from the callee's graph.
        map.keys(CallerAlphaMappingAtCallSite, FormalNodes),
        apply_rules(FormalNodes, CallSite, [], CalleeRptaInfo,
            CallerRptaInfo1, !:CallerRptaInfo)
    ).

inter_analyse_goal_expr(generic_call(_, _, _, _), _, _, _, !FPTable,
        !RptaInfo) :-
    unexpected(this_file,
        "inter_analyse_goal_expr: generic_call not handled").

inter_analyse_goal_expr(switch(_, _, Cases), _, ModuleInfo, InfoTable,
        !FPTable, !RptaInfo) :- 
    list.foldl2(inter_analyse_case(ModuleInfo, InfoTable), Cases,
        !FPTable, !RptaInfo).

:- pred inter_analyse_case(module_info::in, 
    rpta_info_table::in, case::in, rpta_info_fixpoint_table::in, 
    rpta_info_fixpoint_table::out, rpta_info::in, rpta_info::out) is det.
inter_analyse_case(ModuleInfo, InfoTable, Case, !FPtable, !RptaInfo) :-
    Case = case(_, Goal),
    inter_analyse_goal(ModuleInfo, InfoTable, Goal, !FPtable, !RptaInfo).

    % Unifications are ignored in interprocedural analysis
    %
inter_analyse_goal_expr(unify(_, _, _, _, _), _, _, _, !FPTable, !RptaInfo). 

inter_analyse_goal_expr(disj(Goals), _, ModuleInfo, InfoTable, 
        !FPTable, !RptaInfo) :- 
    list.foldl2(inter_analyse_goal(ModuleInfo, InfoTable), Goals,
        !FPTable, !RptaInfo). 
       
inter_analyse_goal_expr(negation(Goal), _, ModuleInfo, InfoTable,
        !FPTable, !RptaInfo) :- 
    inter_analyse_goal(ModuleInfo, InfoTable, Goal, !FPTable, !RptaInfo). 

    % XXX: may need to take into account the Reason.
    % for now just analyse the goal.
    %
inter_analyse_goal_expr(scope(_Reason, Goal), _, ModuleInfo, InfoTable,
        !FPTable, !RptaInfo) :-
%    (
%        ( Reason = exist_quant(_)
%        ; Reason = promise_solutions(_, _)      % XXX ???
%        ; Reason = promise_purity(_, _)
%        ; Reason = commit(_)                    % XXX ???
%        ; Reason = barrier(_)
%        ; Reason = trace_goal(_, _, _, _, _)
%        ; Reason = from_ground_term(_)
%        ),
        inter_analyse_goal(ModuleInfo, InfoTable, Goal, !FPTable, !RptaInfo).
%    ;
%        Msg = "inter_analyse_goal_expr: Scope's reason of from_ground_term "
%            ++ "not handled",
%        unexpected(this_file, Msg)
%    ).
  
inter_analyse_goal_expr(if_then_else(_Vars, If, Then, Else), _, ModuleInfo,
        InfoTable, !FPTable, !RptaInfo) :- 
    inter_analyse_goal(ModuleInfo, InfoTable, If, !FPTable, !RptaInfo),
    inter_analyse_goal(ModuleInfo, InfoTable, Then, !FPTable, !RptaInfo),
    inter_analyse_goal(ModuleInfo, InfoTable, Else, !FPTable, !RptaInfo).

inter_analyse_goal_expr(GoalExpr, _, _, _, !FPTable, !RptaInfo) :- 
    GoalExpr = call_foreign_proc(_, _, _, _, _, _, _),
    unexpected(this_file,
        "inter_analyse_goal_expr: foreign code not handled").

inter_analyse_goal_expr(shorthand(_), _, _, _, !FPTable, !RptaInfo) :- 
    unexpected(this_file, 
        "inter_analyse_goal_expr: shorthand goal not handled").

    % As said above, the rpta_info of a procedure when it is looked 
    % up in interprocedural analysis is either in the InfoTable or in the 
    % fixpoint table. If the procedure happens to be imported ones, built-ins,
    % and so on, we returns no and initialize the lookup value to a dummy 
    % value. 
    %
:- pred lookup_rpta_info(pred_proc_id::in, rpta_info_table::in, 
    rpta_info_fixpoint_table::in, rpta_info_fixpoint_table::out,
    rpta_info::out, bool::out) is det.

lookup_rpta_info(PPId, InfoTable, !FPtable, RptaInfo, Init) :- 
    ( if
        % First look up in the current fixpoint table,
        rpta_info_fixpoint_table_get_rpta_info(PPId, RptaInfo0, 
            !.FPtable, FPtable1)
      then
        RptaInfo  = RptaInfo0,
        !:FPtable = FPtable1,
        Init = bool.no 
      else
	    % ... second look up among already recorded rpta_info.
        ( if 
            RptaInfo0 = rpta_info_table_search_rpta_info(PPId, InfoTable)
          then
            RptaInfo = RptaInfo0,
            Init = bool.no
          else
            % Initialize a dummy.
            RptaInfo = rpta_info(rpt_graph_init, map.init),
            Init = bool.yes
        )
    ).

:- pred update_rpta_info_in_rpta_info_table(rpta_info_fixpoint_table::in, 
    pred_proc_id::in, rpta_info_table::in, rpta_info_table::out) is det.

update_rpta_info_in_rpta_info_table(FPTable, PPId, !InfoTable) :-
    rpta_info_fixpoint_table_get_final_rpta_info(PPId, RptaInfo, FPTable), 
    rpta_info_table_set_rpta_info(PPId, RptaInfo, !InfoTable). 

    % Rule 1:
    % After two nodes are unified, it can happen that the unified node has 
    % two edges with the same label pointing to 2 different nodes. This rule 
    % ensures that it happens the 2 nodes will also be unified.
    %
    % After a node is unified, the node itself was probably removed from 
    % the graph so we need to trace "it" by the variables assigned to it.
    % That is why the first argument is the set of variables associated
    % with the unified node.
    %
    % The algorithm is as follows.  
    % 1. If the node has no or one out-arc we have to do nothing and the 
    % predicate quits. 
    % 2. The node has > 1 out-arc, take one of them, find in the rest 
    % another arc that has a same label, unify the end nodes of the two arcs. 
    % Because of this unification of the end nodes, more unifications are 
    % probably triggered.
    % 3. Start all over again with the same node and the *updated* graph. 
    %
:- pred rule_1(set(prog_var)::in, rpt_graph::in, rpt_graph::out) is det.

rule_1(VarSet, !Graph) :-
    get_node_by_varset(!.Graph, VarSet, UnifiedNode),
    rptg_get_edgemap(!.Graph, EdgeMap),
    map.lookup(EdgeMap, UnifiedNode, OutEdgesOfUnifiedNode),
    map.keys(OutEdgesOfUnifiedNode, OutArcsUnifiedNode),
    ( 
        OutArcsUnifiedNode = [A | As],
        merge_nodes_reached_by_same_labelled_arcs(A, As, As, !Graph, 
            Happened),
        (
            Happened = bool.no
        ;
            % Some nodes have been merged, so size of !:Graph is strictly 
            % smaller than that of !.Graph and at some point this predicate 
            % will end up in the then-branch.
            Happened = bool.yes,
            rule_1(VarSet, !Graph)
        )
    ;
        OutArcsUnifiedNode = []
    ).
	
    % This predicate unifies the end nodes of the input arc and of an arc
    % in the list which has the same label as the input arc. When one such 
    % an arc found, the predicate will not look further in the list.
    % The unification of nodes, if happends, will be propagated by calling 
    % rule_1 predicate mutually recursively. 
    %
:- pred merge_nodes_reached_by_same_labelled_arcs(rptg_arc::in,
    list(rptg_arc)::in, list(rptg_arc)::in, rpt_graph::in, rpt_graph::out, 
    bool::out) is det.

    % The loop in this predicate is similar to
    % for i = ... to N - 1
    %    for j = i+1 to N ...
    % ...	
    % this clause is reached at the end of the inner loop. No unification 
    % has happened so far therefore the list of arcs (Rest = [A | As]) 
    % are still safe to use.
    %

    % reach this clause means that no unification of nodes happened and 
    % all the out-arcs have been processed (Rest = []).
    %
merge_nodes_reached_by_same_labelled_arcs(_, [], [], !Graph, bool.no). 

    % Some out-arcs still need to be processed
    %
merge_nodes_reached_by_same_labelled_arcs(_, [], [A | As], !Graph,
        Happened) :-
    merge_nodes_reached_by_same_labelled_arcs(A, As, As, !Graph, Happened).

merge_nodes_reached_by_same_labelled_arcs(Arc, [A | As], Rest, !Graph, 
        Happened) :-
    % For a node, we do not allow two arcs with the same label to another 
    % node. So End and E below must be definitely different nodes and we 
    % only need to compare labels.   
    rptg_arc_contents(!.Graph, Arc, _Start, End, ArcContent),
    rptg_arc_contents(!.Graph, A, _S, E, AC),
    ( if
         ArcContent = AC
      then
         % Unify the two end nodes.
         unify_operator(End, E, !.Graph, Graph1),

         % Apply rule 1 after the above unification.
         rptg_node_contents(Graph1, End, Content),
         rule_1(Content^varset, Graph1, !:Graph),
         Happened = bool.yes 
      else
         % Still not found an arc with the same label, continue the 
         % inner loop.
         merge_nodes_reached_by_same_labelled_arcs(Arc, As, Rest, !Graph,
            Happened)
    ).

    % This predicate wraps rule_1 to work with rpta_info type.
    %
:- pred apply_rule_1(rptg_node::in, rpta_info::in, rpta_info::out) is det.

apply_rule_1(Node, !RptaInfo) :-
    !.RptaInfo = rpta_info(Graph0, AlphaMapping),
    rptg_node_contents(Graph0, Node, Content),
    rule_1(Content^varset, Graph0, Graph1),
    !:RptaInfo = rpta_info(Graph1, AlphaMapping).

    % Rule 2:
    % After an edge <N, Label, M) is added to a graph, it may happen
    % that there exists another edge from N with the same label but 
    % pointing to a node different from M. This rule ensures that if that
    % the case the node will be unified with M.
    % 
    % This predicate is called whenever a new edge has been added to the
    % graph. So when it is called there is at most one existing edge with
    % the same label to a different node. Because of that the predicate
    % need not be recursive.
    %
:- pred rule_2(set(prog_var)::in, set(prog_var)::in, cons_id::in, int::in, 
    rpt_graph::in, rpt_graph::out) is det.

rule_2(SVarSet, EVarSet, ConsId, Component, !Graph) :-
    get_node_by_varset(!.Graph, SVarSet, N),
    get_node_by_varset(!.Graph, EVarSet, M),
    Sel = [termsel(ConsId, Component)], 
    rptg_get_edgemap(!.Graph, EdgeMap),
    map.lookup(EdgeMap, N, OutEdgesN),
    map.keys(OutEdgesN, OutArcsN),
    merge_nodes_reached_by_same_labelled_arc(Sel, M, OutArcsN, !Graph).

    % If an A(rc) in OutArcsN has the same label Sel then merge M
    % with the node (MPrime) that the A(rc) points to.
    %
:- pred merge_nodes_reached_by_same_labelled_arc(selector::in,
    rptg_node::in, list(rptg_arc)::in, rpt_graph::in, rpt_graph::out) is det.

merge_nodes_reached_by_same_labelled_arc(_, _, [], !Graph).
merge_nodes_reached_by_same_labelled_arc(Sel, M, [A | As], !Graph) :-
    rptg_arc_contents(!.Graph, A, _, MPrime, ArcContent),
    ( if
        ArcContent = rptg_arc_content(Selector),
        Selector = Sel,
        MPrime \= M
      then
        unify_operator(M, MPrime, !.Graph, Graph1),
        rptg_node_contents(Graph1, M, Content),
        rule_1(Content^varset, Graph1, !:Graph)
      else
        % still not found an arc with the same label, continue the loop
        merge_nodes_reached_by_same_labelled_arc(Sel, M, As, !Graph)
    ).

    % This predicate wraps rule_2 to work with rpta_info type.
    %
:- pred apply_rule_2(rptg_node::in, rptg_node::in, cons_id::in, int::in,
    rpta_info::in, rpta_info::out) is det.

apply_rule_2(Start, End, ConsId, Component, !RptaInfo) :-
    !.RptaInfo = rpta_info(Graph0, AlphaMapping),
    rptg_node_contents(Graph0, Start, SContent),
    rptg_node_contents(Graph0, End, EContent),
    rule_2(SContent^varset, EContent^varset, ConsId, Component, 
        Graph0, Graph),
    !:RptaInfo = rpta_info(Graph, AlphaMapping).

    % Rule 3:
    % This rule is applied after an edge is added TO the Node to enforce 
    % the invariant that a subterm of the same type as the compounding
    % term is stored in the same region as the compounding term. In
    % the context of region points-to graph it means that there exists
    % a path between 2 nodes of the same type. In that case, this rule
    % will unify the 2 nodes.
    % 
    % This algorithm may not be an efficient one because it checks all
    % the nodes in the graph one by one to see if a node can reach the
    % node or not.
    %
    % We enforce the invariant (in the sense that whenever the invariant
    % is made invalid this rule will correct it) therefore whenever we
    % find a satisfied node and unify it with Node we can stop. This is
    % indicated by Happened.
    % 
:- pred rule_3(rptg_node::in, rpt_graph::in, rpt_graph::out) is det.

rule_3(Node, !Graph) :-
    rptg_get_nodemap(!.Graph, NodeMap),
    map.keys(NodeMap, Nodes),
    (  
        Nodes = [_N | _NS],
        % The graph has some node(s), so check each node to see if it 
        % satisfies the condition of rule 3 or not, if yes unify it
        % with NY (NY is the node that Node may be merged into.)
        get_node_by_node(!.Graph, Node, NY),
        rule_3_2(Nodes, NY, !Graph, Happened),

        % This predicate will quit when Happened = no, i.e. no more
        % nodes need to be unified.
        ( 
            Happened = bool.yes, 
            % A node in Nodes has been unified with NY, so we start all 
            % over again. Note that the node that has been unified has 
            % been removed, so it will not be in the Graph1 in the below 
            % call. So this predicate can terminate at some point (due
            % to the fact that the "size" of !.Graph is smaller than that
            % of !:Graph).
            rule_3(Node, !Graph)
          ;
            % no node in Nodes has been unified with NY, which means that 
            % no more nodes need to be unified, so just quit.
            Happened = bool.no
	)
    ; 
        Nodes = [],
        % no node in the graph, impossible
        unexpected(this_file, "rule_3: impossible having no node in graph")
    ).

    % Check each node in the list to see if it satisfies the condition of 
    % rule 3 or not, i.e., link to another node with the same type. 
    %	1. If the predicate finds out such a node, it unifies it with NY
    %	(also apply rule 1 here) and quit with Happend = 1.
    %	2. if no such a node found, it processes the rest of the list. The 
    %	process continues like that until either 1. happens (the case above) 
    %	or the list becomes empty and the predicate quits with Happened = 0.
    %
:- pred rule_3_2(list(rptg_node)::in, rptg_node::in, rpt_graph::in, 
    rpt_graph::out, bool::out) is det.

rule_3_2([], _, !Graph, bool.no).
rule_3_2([NZ | NZs], NY, !Graph, Happened) :-
    ( if
        rule_3_condition(NZ, NY, !.Graph, NZ1)
      then
        unify_operator(NZ, NZ1, !.Graph, Graph1),
        
        % apply rule 1
        rptg_node_contents(Graph1, NZ, Content),
        rule_1(Content^varset, Graph1, !:Graph),
        Happened = bool.yes
      else
        % try with the rest, namely NS
        rule_3_2(NZs, NY, !Graph, Happened)
    ).

:- pred rule_3_condition(rptg_node::in, rptg_node::in, rpt_graph::in, 
    rptg_node::out) is semidet.

rule_3_condition(NZ, NY, Graph, NZ1) :-
    rptg_path(Graph, NZ, NY, _),
    rptg_lookup_node_type(Graph, NZ) = NZType,
    % A node reachable from NY, with the same type as NZ, the node can
    % be exactly NY
    reachable_and_having_type(Graph, NY, NZType, NZ1),
    NZ \= NZ1.
	
    % This predicate is just to wrap the call to rule_3 so that the 
    % changed graph is put into rpta_info structure.
    %
:- pred apply_rule_3(rptg_node::in, rpta_info::in, rpta_info::out) is det.

apply_rule_3(Node, !RptaInfo) :-
	!.RptaInfo = rpta_info(Graph0, AlphaMapping),
	rule_3(Node, Graph0, Graph),
	!:RptaInfo = rpta_info(Graph, AlphaMapping).


%-----------------------------------------------------------------------------%
%
% Collecting alpha mapping and application of rule P4.
%

	% Build up the alpha mapping (node -> node) and apply rule P4
    % to ensure that it is actually a function.
	%
:- pred alpha_mapping_at_call_site(list(prog_var)::in, list(prog_var)::in, 
    rpt_graph::in, rpt_graph::in, rpt_graph::out, 
    map(rptg_node, rptg_node)::in, map(rptg_node, rptg_node)::out) is det.

alpha_mapping_at_call_site([], [], _, !CallerGraph, !AlphaMap). 
alpha_mapping_at_call_site([], [_ | _], _, !CallerGraph, !AlphaMap) :-
    unexpected(this_file, 
        "alpha_mapping_at_call_site: actuals and formals not match").
alpha_mapping_at_call_site([_ | _], [], _, !CallerGraph, !AlphaMap) :-
    unexpected(this_file, 
        "alpha_mapping_at_call_site: actuals and formals not match").
    % Xi's are formal arguments, Yi's are actual arguments at the call site
    %
alpha_mapping_at_call_site([Xi | Xs], [Yi | Ys], CalleeGraph,
        !CallerGraph, !AlphaMap) :-
    get_node_by_variable(CalleeGraph, Xi, N_Xi),
    get_node_by_variable(!.CallerGraph, Yi, N_Yi),
    ( if
        map.search(!.AlphaMap, N_Xi, N_Y)
      then
            % alpha(N_Xi) = N_Y, alpha(N_Xi) = N_Yi, N_Y != N_Yi
            %
        ( if
            N_Y \= N_Yi
          then
            % Apply rule P4
            unify_operator(N_Y, N_Yi, !.CallerGraph, CallerGraph1),

            % Apply rule P1 after some nodes are unified
            rptg_node_contents(CallerGraph1, N_Y, Content),
            rule_1(Content^varset, CallerGraph1, CallerGraph2)
          else
            CallerGraph2 = !.CallerGraph
        )
      else
        svmap.set(N_Xi, N_Yi, !AlphaMap),
        CallerGraph2 = !.CallerGraph
    ),
    alpha_mapping_at_call_site(Xs, Ys, CalleeGraph,
        CallerGraph2, !:CallerGraph, !AlphaMap).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
%
% Rules P5-P8 complete the alpha mapping at a call site and integrate the
% parts rooted at the formal parameters in the callee's graph into the
% caller's graph.
%
% The application of those rules happens at a call site, so related to a
% caller and a callee.
% 
% We will start from the rooted nodes, follow each outcoming edge in the
% callee's graph exactly once and apply the rules.
%

:- pred apply_rules(list(rptg_node)::in, program_point::in, 
    list(rptg_node)::in, rpta_info::in, rpta_info::in, 
    rpta_info::out) is det.  

apply_rules([], _, _, _, !CallerRptaInfo).
apply_rules([CalleeNode | CalleeNodes0], CallSite, Processed, CalleeRptaInfo,
        !CallerRptaInfo) :-
    % The caller node corresponding to the callee node at this call site.
    !.CallerRptaInfo = rpta_info(_, CallerAlphaMapping0),
    map.lookup(CallerAlphaMapping0, CallSite, AlphaAtCallSite),
    map.lookup(AlphaAtCallSite, CalleeNode, CallerNode),
    
    % Follow CalleeNode and apply rules when traversing its edges.
    apply_rules_node(CallSite, CalleeNode, CalleeRptaInfo, CallerNode,
        !CallerRptaInfo),

    % Continue with the nodes reached from Callee Node.
    CalleeRptaInfo = rpta_info(CalleeGraph, _),
    rptg_successors(CalleeGraph, CalleeNode, SuccessorsCalleeNode),
    set.to_sorted_list(SuccessorsCalleeNode, SsList),
    list.delete_elems(SsList, Processed, ToBeProcessed),
    CalleeNodes = ToBeProcessed ++ CalleeNodes0,
    apply_rules(CalleeNodes, CallSite, [CalleeNode | Processed], 
        CalleeRptaInfo, !CallerRptaInfo).

:- pred apply_rules_node(program_point::in, rptg_node::in, rpta_info::in, 
    rptg_node::in, rpta_info::in, rpta_info::out) is det.

apply_rules_node(CallSite, CalleeNode, CalleeRptaInfo, CallerNode,
        !CallerRptaInfo) :-
    CalleeRptaInfo = rpta_info(CalleeGraph, _),

    % Apply rules P5-P8 for each out-edge of CalleeNode.
    rptg_get_edgemap(CalleeGraph, EdgeMap),
    map.lookup(EdgeMap, CalleeNode, CalleeNodeOutEdges),
    map.keys(CalleeNodeOutEdges, CalleeNodeOutArcs),
    apply_rules_arcs(CalleeNodeOutArcs, CallerNode, CallSite,
        CalleeRptaInfo, !CallerRptaInfo).

:- pred apply_rules_arcs(list(rptg_arc)::in, rptg_node::in, 
    program_point::in, rpta_info::in, rpta_info::in, rpta_info::out) is det.

apply_rules_arcs([], _, _, _, !RptaInfoR).
apply_rules_arcs([Arc | Arcs], CallerNode, CallSite, CalleeRptaInfo,
        !CallerRptaInfo) :-
	rule_5(Arc, CallSite, CalleeRptaInfo, CallerNode, !CallerRptaInfo),
	rule_6(Arc, CallSite, CalleeRptaInfo, CallerNode, !CallerRptaInfo),
	rule_7(Arc, CallSite, CalleeRptaInfo, CallerNode, !CallerRptaInfo),
	rule_8(Arc, CallSite, CalleeRptaInfo, CallerNode, !CallerRptaInfo),
	apply_rules_arcs(Arcs, CallerNode, CallSite, CalleeRptaInfo,
        !CallerRptaInfo).

:- pred rule_5(rptg_arc::in, program_point::in, rpta_info::in, 
    rptg_node::in, rpta_info::in, rpta_info::out) is det.

rule_5(Arc, CallSite, CalleeRptaInfo, CallerNode, !CallerRptaInfo) :-
    % Find an out-arc in the caller's graph that has a same label 
    % the label of the out-arc in callee's graph
    CalleeRptaInfo = rpta_info(CalleeGraph, _),
    rptg_arc_contents(CalleeGraph, Arc, _CalleeNode, CalleeM, Label),
    !.CallerRptaInfo = rpta_info(CallerGraph0, CallerAlphaMapping0),
    get_node_by_node(CallerGraph0, CallerNode, RealCallerNode),
    ( if
        find_arc_from_node_with_same_label(RealCallerNode, Label,
            CallerGraph0, CallerMPrime), 
        map.search(CallerAlphaMapping0, CallSite, AlphaAtCallSite),
        map.search(AlphaAtCallSite, CalleeM, CallerM),
        get_node_by_node(CallerGraph0, CallerM, RealCallerM),
        CallerMPrime \= RealCallerM
      then
        % When the premises of rule P5 are satisfied, nodes are unified and
        % rule P1 applied to ensure invariants.
        unify_operator(RealCallerM, CallerMPrime,
            CallerGraph0, CallerGraph1),
        CallerRptaInfo1 = rpta_info(CallerGraph1, CallerAlphaMapping0),
        apply_rule_1(RealCallerM, CallerRptaInfo1, !:CallerRptaInfo)
      else
        true
    ).

:- pred rule_6(rptg_arc::in, program_point::in, rpta_info::in,
    rptg_node::in, rpta_info::in, rpta_info::out) is det.
rule_6(Arc, CallSite, CalleeRptaInfo, CallerNode, !CallerRptaInfo) :-
    % Find an out-arc in the caller's graph that has a same label 
    % the label of the out-arc in callee's graph.
    CalleeRptaInfo = rpta_info(CalleeGraph, _),
    rptg_arc_contents(CalleeGraph, Arc, _CalleeNode, CalleeM, Label),
    !.CallerRptaInfo = rpta_info(CallerGraph, CallerAlphaMapping0),
    get_node_by_node(CallerGraph, CallerNode, RealCallerNode),
    ( if
        find_arc_from_node_with_same_label(RealCallerNode, Label,
            CallerGraph, CallerM)
      then
        % (CallerNode, sel, CallerM) in the graph.
        map.lookup(CallerAlphaMapping0, CallSite, AlphaAtCallSite0),
        ( if
            map.search(AlphaAtCallSite0, CalleeM, _)
          then
            % alpha(CalleeM) = CallerM so ignore.
            true
          else
            % Apply rule P6 when its premises are satisfied
            % record alpha(CalleeM) = CallerM.
            svmap.set(CalleeM, CallerM, AlphaAtCallSite0, AlphaAtCallSite1),
            svmap.set(CallSite, AlphaAtCallSite1, CallerAlphaMapping0,
                CallerAlphaMapping),
            !:CallerRptaInfo = rpta_info(CallerGraph, CallerAlphaMapping)
        )
      else
        true
    ).

:- pred rule_7(rptg_arc::in, program_point::in, rpta_info::in,
    rptg_node::in, rpta_info::in, rpta_info::out) is det.
rule_7(Arc, CallSite, CalleeRptaInfo, CallerNode, !CallerRptaInfo) :-
    % Find an out-arc in the caller's graph that has a same label 
    % the label of the out-arc in callee's graph.
    CalleeRptaInfo = rpta_info(CalleeGraph, _),
    rptg_arc_contents(CalleeGraph, Arc, _CalleeNode, CalleeM, Label),
    !.CallerRptaInfo = rpta_info(CallerGraph0, CallerAlphaMapping),
    get_node_by_node(CallerGraph0, CallerNode, RealCallerNode),
    ( if
        find_arc_from_node_with_same_label(RealCallerNode, Label,
            CallerGraph0, _)
      then
        true
      else
        % No edge from CallerNode with the label exists.
        ( if
            map.lookup(CallerAlphaMapping, CallSite, AlphaAtCallSite),
            map.search(AlphaAtCallSite, CalleeM, CallerM)
          then
            % Reach here means all the premises of rule P7 are satisfied, 
            % add (CallerNode, sel, CallerM).
            get_node_by_node(CallerGraph0, CallerM, RealCallerM),
            edge_operator(RealCallerNode, RealCallerM, Label,
                CallerGraph0, CallerGraph1),
        
            % Need to apply rule 3.
            rule_3(RealCallerM, CallerGraph1, CallerGraph2),
            !:CallerRptaInfo = rpta_info(CallerGraph2, CallerAlphaMapping)
          else
            true
        )
    ).

:- pred rule_8(rptg_arc::in, program_point::in, rpta_info::in,
    rptg_node::in, rpta_info::in, rpta_info::out) is det.
rule_8(Arc, CallSite, CalleeRptaInfo, CallerNode, !CallerRptaInfo) :-
    % Find an out-arc in the caller's graph that has a same label 
    % the label of the out-arc in callee's graph
    CalleeRptaInfo = rpta_info(CalleeGraph, _),
    rptg_arc_contents(CalleeGraph, Arc, _CalleeNode, CalleeM, Label),
    !.CallerRptaInfo = rpta_info(CallerGraph0, CallerAlphaMapping0),
    get_node_by_node(CallerGraph0, CallerNode, RealCallerNode),
    ( if
        find_arc_from_node_with_same_label(RealCallerNode, Label,
            CallerGraph0, _)
      then
        true
      else
        % No edge from CallerNode with the label exists.
        ( if 
            map.lookup(CallerAlphaMapping0, CallSite, AlphaAtCallSite0),
            map.search(AlphaAtCallSite0, CalleeM, _)
          then
            true
          else
                % rule 8: add node CallerM, alpha(CalleeM) = CallerM, 
                % edge(CallerNode, sel, CallerM)
                %
            rptg_get_node_supply(CallerGraph0, NS0),
            string.append("R", string.int_to_string(NS0 + 1), RegName),
            CallerMContent = rptg_node_content(set.init, RegName, set.init, 
                rptg_lookup_node_type(CalleeGraph, CalleeM)),
            rptg_set_node(CallerMContent, CallerM, 
                CallerGraph0, CallerGraph1),
            edge_operator(RealCallerNode, CallerM, Label,
                CallerGraph1, CallerGraph2),
            
            map.lookup(CallerAlphaMapping0, CallSite, AlphaAtCallSite0),
            svmap.set(CalleeM, CallerM, AlphaAtCallSite0, AlphaAtCallSite),
            svmap.set(CallSite, AlphaAtCallSite,
                CallerAlphaMapping0, CallerAlphaMapping),
                
            rule_3(CallerM, CallerGraph2, CallerGraph),
            !:CallerRptaInfo = rpta_info(CallerGraph, CallerAlphaMapping)
        )
    ).

%-----------------------------------------------------------------------------%
%
% Fixpoint table used in region points-to analysis.
%

:- type rpta_info_fixpoint_table == fixpoint_table(pred_proc_id, rpta_info). 

	% Initialise the fixpoint table for the given set of pred_proc_ids. 
    %
:- pred rpta_info_fixpoint_table_init(list(pred_proc_id)::in, 
    rpta_info_table::in, rpta_info_fixpoint_table::out) is det.

rpta_info_fixpoint_table_init(Keys, InfoTable, Table):-
    Table = init_fixpoint_table(wrapped_init(InfoTable), Keys).

	% Add the results of a new analysis pass to the already existing
	% fixpoint table. 
    %
:- pred rpta_info_fixpoint_table_new_run(rpta_info_fixpoint_table::in, 
    rpta_info_fixpoint_table::out) is det.

rpta_info_fixpoint_table_new_run(!Table) :-
	new_run(!Table).

	% The fixpoint table keeps track of the number of analysis passes. This
	% predicate returns this number.
    %
:- func rpta_info_fixpoint_table_which_run(rpta_info_fixpoint_table) = int.

rpta_info_fixpoint_table_which_run(Table) = which_run(Table).

	% A fixpoint is reached if all entries in the table are stable,
	% i.e. haven't been modified by the last analysis pass. 
    %
:- pred rpta_info_fixpoint_table_all_stable(rpta_info_fixpoint_table::in) 
    is semidet.

rpta_info_fixpoint_table_all_stable(Table) :-
	fixpoint_reached(Table).

	% Enter the newly computed region points-to information for a given 
    % procedure.
	% If the description is different from the one that was already stored
	% for that procedure, the stability of the fixpoint table is set to
	% "unstable". 
	% Aborts if the procedure is not already in the fixpoint table. 
    %
:- pred rpta_info_fixpoint_table_new_rpta_info(
    pred_proc_id::in, rpta_info::in,
    rpta_info_fixpoint_table::in, rpta_info_fixpoint_table::out) is det.

rpta_info_fixpoint_table_new_rpta_info(PPId, RptaInfo, !Table) :-
	EqualityTest = (pred(TabledElem::in, Elem::in) is semidet :-
        rpta_info_equal(Elem, TabledElem)
    ),
    add_to_fixpoint_table(EqualityTest, PPId, RptaInfo, !Table).

	% Retrieve the rpta_info of a given pred_proc_id. If this information 
    % is not available, this means that the set of pred_proc_id's to which
    % the fixpoint table relates are mutually recursive, hence the table
    % is characterised as recursive. 
	% Fails if the procedure is not in the table. 
    %
:- pred rpta_info_fixpoint_table_get_rpta_info(
    pred_proc_id::in, rpta_info::out,
    rpta_info_fixpoint_table::in, rpta_info_fixpoint_table::out) is semidet.

rpta_info_fixpoint_table_get_rpta_info(PPId, RptaInfo, !Table) :-
    get_from_fixpoint_table(PPId, RptaInfo, !Table).	

	% Retreive rpta_info, without changing the table. To be used after 
    % fixpoint has been reached. Aborts if the procedure is not in the table.
    %
:- pred rpta_info_fixpoint_table_get_final_rpta_info(pred_proc_id::in, 
    rpta_info::out, rpta_info_fixpoint_table::in) is det.

rpta_info_fixpoint_table_get_final_rpta_info(PPId, RptaInfo, Table):-
	RptaInfo = get_from_fixpoint_table_final(PPId, Table).

:- func wrapped_init(rpta_info_table, pred_proc_id) = rpta_info.
    
wrapped_init(InfoTable, PPId) = Entry :- 
	( if    Entry0 = rpta_info_table_search_rpta_info(PPId, InfoTable)
	  then  Entry = Entry0
	  else
            % The information we are looking for should be there after the
            % intraprocedural analysis.
		    unexpected(this_file, "wrapper_init: rpta_info should exist.")
	).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "rbmm.points_to_analysis.m".

%-----------------------------------------------------------------------------%
:- end_module rbmm.points_to_analysis.
%-----------------------------------------------------------------------------%