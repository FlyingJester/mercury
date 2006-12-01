%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2006 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: mdprof_feedback.m.
% Author: tannier.
%
% This module contains the code for writing to a file the CSSs whose CSDs' 
% average/median call sequence counts (own and desc) exceed the given threshold.
% 
% The generated file will then be used by the compiler for implicit parallelism.
%
%-----------------------------------------------------------------------------%

:- module mdprof_feedback.
:- interface.

:- import_module io.

%-----------------------------------------------------------------------------%

:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module conf.
:- import_module measurements.
:- import_module profile.
:- import_module startup.

:- import_module array.
:- import_module bool.
:- import_module char.
:- import_module getopt.
:- import_module int.
:- import_module library.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module require.
:- import_module string.

%-----------------------------------------------------------------------------%

main(!IO) :-
    io.progname_base("mdprof_feedback", ProgName, !IO),
    io.command_line_arguments(Args0, !IO),
    getopt.process_options(option_ops_multi(short, long, defaults),
        Args0, Args, MaybeOptions),
    (
        MaybeOptions = ok(Options),
        lookup_bool_option(Options, help, Help),
        lookup_bool_option(Options, version, Version),
        ( Version = yes ->
            write_version_message(ProgName, !IO)
        ; Help = yes ->
            write_help_message(ProgName, !IO)
        ; 
            ( Args = [Input, Output] ->
                lookup_string_option(Options, distribution, Distribution),
                ( construct_distribution(Distribution, DistributionType) ->
                    lookup_int_option(Options, threshold, Threshold),
                    lookup_bool_option(Options, verbose, Verbose),
                    read_deep_file(Input, Verbose, MaybeProfile, !IO),
                    (
                        MaybeProfile = ok(Deep),
                        compute_css_list_above_threshold(0, Deep, Threshold, 
                            DistributionType, [], CSSListAboveThreshold),
                        generate_feedback_file(CSSListAboveThreshold, Deep, 
                            DistributionType, Threshold, Output, !IO)
                    ;
                        MaybeProfile = error(Error),
                        io.stderr_stream(Stderr, !IO),
                        io.set_exit_status(1, !IO),
                        io.format(Stderr, "%s: error reading deep file: %s\n",
                            [s(ProgName), s(Error)], !IO)
                    )   
                ;
                    io.set_exit_status(1, !IO),
                    write_help_message(ProgName, !IO)
                )
            ;
                io.set_exit_status(1, !IO),
                write_help_message(ProgName, !IO)
            )
        )
    ;
        MaybeOptions = error(Msg),
        io.stderr_stream(Stderr, !IO),
        io.set_exit_status(1, !IO),
        io.format(Stderr, "%s: error parsing options: %s\n",
            [s(ProgName), s(Msg)], !IO)
    ).

:- pred write_help_message(string::in, io::di, io::uo) is det.

write_help_message(ProgName) -->
    io.format("Usage: %s [<options>] <input> <output>\n", [s(ProgName)]),
    io.format("<input> must name a deep profiling data file.\n", []),
    io.format("<output> is the file generated by this program.\n", []),
    io.format("You may specify one of the following options:\n", []),
    io.format("--help      Generate this help message.\n", []),
    io.format("--version   Report the program's version number.\n", []),
    io.format("--verbose   Generate progress messages.\n", []),
    io.format("--threshold <value>\n", []),
    io.format("            Set the threshold to <value>.\n",[]),
    io.format("--distrib average|median\n",[]),
    io.format("            average : Write to <output> the call sites\n",[]),
    io.format("            static whose call sites dynamic's average\n",[]),
    io.format("            call sequence counts exceed the given\n",[]),  
    io.format("            threshold (default option).\n",[]),
    io.format("            median : Write to <output> the call sites\n",[]),
    io.format("            static whose call sites dynamic's median\n",[]),
    io.format("            call sequence counts exceed the given\n",[]),
    io.format("            threshold.\n",[]).

:- pred write_version_message(string::in, io::di, io::uo) is det.

write_version_message(ProgName, !IO) :-
    library.version(Version),
    io.write_string(ProgName, !IO),
    io.write_string(": Mercury deep profiler", !IO),
    io.nl(!IO),
    io.write_string(Version, !IO),
    io.nl(!IO).

%-----------------------------------------------------------------------------%

    % Read a deep profiling data file.
    % 
:- pred read_deep_file(string::in, bool::in, maybe_error(deep)::out,
    io::di, io::uo) is det.

read_deep_file(Input, Verbose, MaybeProfile, !IO) :-
    server_name(Machine, !IO),
    (
        Verbose = yes,
        io.stdout_stream(Stdout, !IO),
        MaybeOutput = yes(Stdout)
    ;
        Verbose = no,
        MaybeOutput = no
    ),
    read_and_startup(Machine, [Input], no, MaybeOutput, [], [], MaybeProfile, 
        !IO).

    % Determine those CSSs whose CSDs' average/median call sequence counts 
    % exceed the given threshold.
    % 
:- pred compute_css_list_above_threshold(int::in, deep::in, int::in, 
    distribution_type::in, list(call_site_static)::in, 
    list(call_site_static)::out) is det.

compute_css_list_above_threshold(Index, Deep, Threshold, Distribution,
        !CSSAcc) :-
    array.size(Deep ^ call_site_statics, Size),
    ( Index = Size ->
        true
    ;
        CallSiteCall = array.lookup(Deep ^ call_site_calls, Index),
        CSDListList = map.values(CallSiteCall),
        CSDList = list.condense(CSDListList),
        list.length(CSDList, NumCSD),
        ( NumCSD = 0 ->
            % The CSS doesn't have any CSDs.
            Callseqs = 0
        ;
            ( 
                Distribution = average,
                list.foldr(sum_callseqs_csd_ptr(Deep), CSDList,
                    0, SumCallseqs),
                % NOTE: we have checked that NumCSD is not zero above.
                Callseqs = SumCallseqs // NumCSD
            ;
                Distribution = median,
                list.sort(compare_csd_ptr(Deep), CSDList, CSDListSorted),
                IndexMedian = NumCSD // 2,
                list.index0_det(CSDListSorted, IndexMedian, MedianPtr),
                sum_callseqs_csd_ptr(Deep, MedianPtr, 0, Callseqs)
            )
        ),
        ( Callseqs >= Threshold ->
            CSS = array.lookup(Deep ^ call_site_statics, Index),
            !:CSSAcc = [ CSS | !.CSSAcc ],
            compute_css_list_above_threshold(Index + 1, Deep, Threshold, 
                Distribution, !CSSAcc)
        ;
            compute_css_list_above_threshold(Index + 1, Deep, Threshold, 
                Distribution, !CSSAcc)
        ) 
    ).

    % Add the call sequence counts (own and desc) of CSDPtr to the accumulator.
    % 
:- pred sum_callseqs_csd_ptr(deep::in, call_site_dynamic_ptr::in,
    int::in, int::out) is det.

sum_callseqs_csd_ptr(Deep, CSDPtr, !Sum) :-
    lookup_call_site_dynamics(Deep ^ call_site_dynamics, CSDPtr, CSD),
    lookup_csd_desc(Deep ^ csd_desc, CSDPtr, IPO),
    !:Sum = !.Sum + callseqs(CSD ^ csd_own_prof) + inherit_callseqs(IPO).

    % Compare two CSD pointers on the basis of their call sequence counts 
    % (own and desc).
    % 
:- pred compare_csd_ptr(deep::in, call_site_dynamic_ptr::in, 
    call_site_dynamic_ptr::in, comparison_result::out) is det.

compare_csd_ptr(Deep, CSDPtrA, CSDPtrB, Result) :-
    sum_callseqs_csd_ptr(Deep, CSDPtrA, 0, SumA),
    sum_callseqs_csd_ptr(Deep, CSDPtrB, 0, SumB),
    compare(Result, SumA, SumB).

    % Generate a profiling feedback file that contains the CSSs whose CSDs' 
    % average/median call sequence counts (own and desc) exceed the given 
    % threshold. 
    % 
:- pred generate_feedback_file(list(call_site_static)::in, deep::in, 
    distribution_type::in, int::in, string::in, io::di, io::uo) is det.
    
generate_feedback_file(CSSList, Deep, Distribution, Threshold, Output, !IO) :-
    io.open_output(Output, Result, !IO),
    (
        Result = io.error(Err),
        io.stderr_stream(Stderr, !IO),
        io.write_string(Stderr, io.error_message(Err) ++ "\n", !IO)
    ;
        Result = ok(Stream),
        io.write_string(Stream, "Profiling feedback file\n", !IO),
        io.write_string(Stream, "Version = 1.0\n", !IO),
        (
            Distribution = average,
            io.write_string(Stream, "Distribution = average\n", !IO)
        ;
            Distribution = median,
            io.write_string(Stream, "Distribution = median\n", !IO)
        ),
        io.format(Stream, "Threshold = %i\n", [i(Threshold)], !IO),
        write_css_list(CSSList, Deep, Stream, !IO),
        io.close_output(Stream, !IO)
    ).

    % Write to the output the list of CSSs.     
    % 
:- pred write_css_list(list(call_site_static)::in, deep::in, output_stream::in, 
    io::di, io::uo) is det.
   
write_css_list([], _, _, !IO).
write_css_list([ CSS | CSSList0 ], Deep, OutStrm, !IO) :-
        
    % Print the caller.
    lookup_proc_statics(Deep ^ proc_statics, CSS ^ css_container, Caller),
    io.write_string(OutStrm, Caller ^ ps_raw_id ++ " ", !IO),
        
    % Print the slot number of the CSS.
    io.write_int(OutStrm, CSS ^ css_slot_num, !IO),
    io.write_string(OutStrm, " ", !IO),
    
    % Print the callee.
    (
        CSS ^ css_kind = normal_call_and_callee(PSPtr, _),
        lookup_proc_statics(Deep ^ proc_statics, PSPtr, Callee),
        io.format(OutStrm, "normal_call %s\n", [s(Callee ^ ps_raw_id)], !IO)
    ;
        CSS ^ css_kind = special_call_and_no_callee,
        io.write_string(OutStrm, "special_call\n", !IO)
    ;
        CSS ^ css_kind = higher_order_call_and_no_callee,
        io.write_string(OutStrm, "higher_order_call\n", !IO)
    ;
        CSS ^ css_kind = method_call_and_no_callee,
        io.write_string(OutStrm, "method_call\n", !IO)
    ;
        CSS ^ css_kind = callback_and_no_callee,
        io.write_string(OutStrm, "callback\n", !IO)
    ),
    write_css_list(CSSList0, Deep, OutStrm, !IO).

%-----------------------------------------------------------------------------%

:- type option
    --->    threshold
    ;       help
    ;       verbose
    ;       version
    ;       distribution.

:- type distribution_type
    --->    average
    ;       median.

:- type option_table == option_table(option).

:- pred short(char::in, option::out) is semidet.

short('V',  verbose).
short('t',  threshold).
short('h',  help).
short('v',  version).
short('d',  distribution).


:- pred long(string::in, option::out) is semidet.

long("threshold",           threshold).
long("help",                help).
long("verbose",             verbose).
long("version",             version).
long("distrib",             distribution).
long("distribution",        distribution).

:- pred defaults(option::out, option_data::out) is multi.

defaults(threshold,         int(100000)).
defaults(help,              bool(no)).
defaults(verbose,           bool(no)).
defaults(version,           bool(no)).
defaults(distribution,      string("average")).

:- pred construct_distribution(string::in, distribution_type::out) is semidet.

construct_distribution("average",    average).
construct_distribution("median",     median).

%-----------------------------------------------------------------------------%
:- end_module mdprof_feedback.
%-----------------------------------------------------------------------------%