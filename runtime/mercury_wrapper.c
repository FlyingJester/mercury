/*
INIT mercury_sys_init_wrapper
ENDINIT
*/
/*
** Copyright (C) 1994-1998 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** file: wrapper.mod
** main authors: zs, fjh
**
**	This file contains the startup and termination entry points
**	for the Mercury runtime.
**
**	It defines mercury_runtime_init(), which is invoked from
**	mercury_init() in the C file generated by util/mkinit.c.
**	The code for mercury_runtime_init() initializes various things, and
**	processes options (which are specified via an environment variable).
**
**	It also defines mercury_runtime_main(), which invokes
**	call_engine(do_interpreter), which invokes main/2.
**
**	It also defines mercury_runtime_terminate(), which performs
**	various cleanups that are needed to terminate cleanly.
*/

#include	"mercury_imp.h"

#include	<stdio.h>
#include	<ctype.h>
#include	<string.h>

#include	"mercury_timing.h"
#include	"mercury_getopt.h"
#include	"mercury_init.h"
#include	"mercury_dummy.h"

/* global variables concerned with testing (i.e. not with the engine) */

/* command-line options */

/* size of data areas (including redzones), in kilobytes */
/* (but we later multiply by 1024 to convert to bytes) */
size_t		heap_size =      	4096;
size_t		detstack_size =  	2048;
size_t		nondstack_size =  	128;
size_t		solutions_heap_size =	1024;
size_t		trail_size =		128;

/* size of the redzones at the end of data areas, in kilobytes */
/* (but we later multiply by 1024 to convert to bytes) */
size_t		heap_zone_size =	16;
size_t		detstack_zone_size =	16;
size_t		nondstack_zone_size =	16;
size_t		solutions_heap_zone_size = 16;
size_t		trail_zone_size =	16;

/* primary cache size to optimize for, in kilobytes */
/* (but we later multiply by 1024 to convert to bytes) */
size_t		pcache_size =    8192;

/* other options */

int		r1val = -1;
int		r2val = -1;
int		r3val = -1;

bool		check_space = FALSE;

static	bool	benchmark_all_solns = FALSE;
static	bool	use_own_timer = FALSE;
static	int	repeats = 1;

/* timing */
int		time_at_last_stat;
int		time_at_start;
static	int	time_at_finish;

/* time profiling */
enum MR_TimeProfileMethod
		MR_time_profile_method = MR_profile_user_plus_system_time;

const char *	progname;
int		mercury_argc;	/* not counting progname */
char **		mercury_argv;
int		mercury_exit_status = 0;

bool		MR_profiling = TRUE;

/*
** EXTERNAL DEPENDENCIES
**
** - The Mercury runtime initialization, namely mercury_runtime_init(),
**   calls the functions init_gc() and init_modules(), which are in
**   the automatically generated C init file; mercury_init_io(), which is
**   in the Mercury library; and it calls the predicate io__init_state/2
**   in the Mercury library.
** - The Mercury runtime main, namely mercury_runtime_main(),
**   calls main/2 in the user's program.
** - The Mercury runtime finalization, namely mercury_runtime_terminate(),
**   calls io__finalize_state/2 in the Mercury library.
**
** But, to enable Quickstart of shared libraries on Irix 5,
** and in general to avoid various other complications
** with shared libraries and/or Windows DLLs,
** we need to make sure that we don't have any undefined
** external references when building the shared libraries.
** Hence the statically linked init file saves the addresses of those
** procedures in the following global variables.
** This ensures that there are no cyclic dependencies;
** the order is user program -> library -> runtime -> gc,
** where `->' means "depends on", i.e. "references a symbol of".
*/

void	(*address_of_mercury_init_io)(void);
void	(*address_of_init_modules)(void);
#ifdef CONSERVATIVE_GC
void	(*address_of_init_gc)(void);
#endif

Code	*program_entry_point;
		/* normally mercury__main_2_0 (main/2) */
void	(*MR_library_initializer)(void);
		/* normally ML_io_init_state (io__init_state/2)*/
void	(*MR_library_finalizer)(void);
		/* normally ML_io_finalize_state (io__finalize_state/2) */


#ifdef USE_GCC_NONLOCAL_GOTOS

#define	SAFETY_BUFFER_SIZE	1024	/* size of stack safety buffer */
#define	MAGIC_MARKER_2		142	/* a random character */

#endif

static	void	process_args(int argc, char **argv);
static	void	process_environment_options(void);
static	void	process_options(int argc, char **argv);
static	void	usage(void);
static	void	make_argv(const char *, char **, char ***, int *);

#ifdef MEASURE_REGISTER_USAGE
static	void	print_register_usage_counts(void);
#endif

Declare_entry(do_interpreter);

/*---------------------------------------------------------------------------*/

void
mercury_runtime_init(int argc, char **argv)
{
#if NUM_REAL_REGS > 0
	Word c_regs[NUM_REAL_REGS];
#endif

	/*
	** Save the callee-save registers; we're going to start using them
	** as global registers variables now, which will clobber them,
	** and we need to preserve them, because they're callee-save,
	** and our caller may need them ;-)
	*/
	save_regs_to_mem(c_regs);

#ifndef	SPEED
	/*
	** Ensure stdio & stderr are unbuffered even if redirected.
	** Using setvbuf() is more complicated than using setlinebuf(),
	** but also more portable.
	*/

	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
#endif

#ifdef CONSERVATIVE_GC
	GC_quiet = TRUE;

	/*
	** Call GC_INIT() to tell the garbage collector about this DLL.
	** (This is necessary to support Windows DLLs using gnu-win32.)
	*/
	GC_INIT();

	/*
	** call the init_gc() function defined in <foo>_init.c,
	** which calls GC_INIT() to tell the GC about the main program.
	** (This is to work around a Solaris 2.X (X <= 4) linker bug,
	** and also to support Windows DLLs using gnu-win32.)
	*/
	(*address_of_init_gc)();

	/* double-check that the garbage collector knows about
	   global variables in shared libraries */
	GC_is_visible(fake_reg);

	/* The following code is necessary to tell the conservative */
	/* garbage collector that we are using tagged pointers */
	{
		int i;

		for (i = 1; i < (1 << TAGBITS); i++) {
			GC_register_displacement(i);
		}
	}
#endif

	/* process the command line and the options in the environment
	   variable MERCURY_OPTIONS, and save results in global vars */
	process_args(argc, argv);
	process_environment_options();

#if (defined(USE_GCC_NONLOCAL_GOTOS) && !defined(USE_ASM_LABELS)) || \
		defined(PROFILE_CALLS) || defined(PROFILE_TIME)
	do_init_modules();
#endif

	(*address_of_mercury_init_io)();

	/* start up the Mercury engine */
	init_engine();

	/* initialize profiling */
	if (MR_profiling) MR_prof_init();

	/*
	** We need to call save_registers(), since we're about to
	** call a C->Mercury interface function, and the C->Mercury
	** interface convention expects them to be saved.  And before we
	** can do that, we need to call restore_transient_registers(),
	** since we've just returned from a C call.
	*/
	restore_transient_registers();
	save_registers();

	/* initialize the Mercury library */
	(*MR_library_initializer)();

	/*
	** Restore the callee-save registers before returning,
	** since they may be used by the C code that called us.
	*/
	restore_regs_from_mem(c_regs);

} /* end runtime_mercury_main() */

void 
do_init_modules(void)
{
	static	bool	done = FALSE;

	if (! done) {
		(*address_of_init_modules)();
		done = TRUE;
	}
}

/*
** Given a string, parse it into arguments and create an argv vector for it.
** Returns args, argv, and argc.  It is the caller's responsibility to oldmem()
** args and argv when they are no longer needed.
*/

static void
make_argv(const char *string, char **args_ptr, char ***argv_ptr, int *argc_ptr)
{
	char *args;
	char **argv;
	const char *s = string;
	char *d;
	int args_len = 0;
	int argc = 0;
	int i;
	
	/*
	** First do a pass over the string to count how much space we need to
	** allocate
	*/

	for (;;) {
		/* skip leading whitespace */
		while(isspace((unsigned char)*s)) {
			s++;
		}

		/* are there any more args? */
		if(*s != '\0') {
			argc++;
		} else {
			break;
		}

		/* copy arg, translating backslash escapes */
		if (*s == '"') {
			s++;
			/* "double quoted" arg - scan until next double quote */
			while (*s != '"') {
				if (s == '\0') {
					fatal_error(
				"Mercury runtime: unterminated quoted string\n"
				"in MERCURY_OPTIONS environment variable\n"
					);
				}
				if (*s == '\\')
					s++;
				args_len++; s++;
			}
			s++;
		} else {
			/* ordinary white-space delimited arg */
			while(*s != '\0' && !isspace((unsigned char)*s)) {
				if (*s == '\\')
					s++;
				args_len++; s++;
			}
		}
		args_len++;
	} /* end for */

	/*
	** Allocate the space
	*/
	args = make_many(char, args_len);
	argv = make_many(char *, argc + 1);

	/*
	** Now do a pass over the string, copying the arguments into `args'
	** setting up the contents of `argv' to point to the arguments.
	*/
	s = string;
	d = args;
	for(i = 0; i < argc; i++) {
		/* skip leading whitespace */
		while(isspace((unsigned char)*s)) {
			s++;
		}

		/* are there any more args? */
		if(*s != '\0') {
			argv[i] = d;
		} else {
			argv[i] = NULL;
			break;
		}

		/* copy arg, translating backslash escapes */
		if (*s == '"') {
			s++;
			/* "double quoted" arg - scan until next double quote */
			while (*s != '"') {
				if (*s == '\\')
					s++;
				*d++ = *s++;
			}
			s++;
		} else {
			/* ordinary white-space delimited arg */
			while(*s != '\0' && !isspace((unsigned char)*s)) {
				if (*s == '\\')
					s++;
				*d++ = *s++;
			}
		}
		*d++ = '\0';
	} /* end for */

	*args_ptr = args;
	*argv_ptr = argv;
	*argc_ptr = argc;
} /* end make_argv() */


/**  
 **  process_args() is a function that sets some global variables from the
 **  command line.  `mercury_arg[cv]' are `arg[cv]' without the program name.
 **  `progname' is program name.
 **/

static void
process_args( int argc, char ** argv)
{
	progname = argv[0];
	mercury_argc = argc - 1;
	mercury_argv = argv + 1;
}


/**
 **  process_environment_options() is a function to parse the MERCURY_OPTIONS
 **  environment variable.  
 **/ 

static void
process_environment_options(void)
{
	char*	options;

	options = getenv("MERCURY_OPTIONS");
	if (options != NULL) {
		char	*arg_str, **argv;
		char	*dummy_command_line;
		int	argc;
		int	c;

		/*
		   getopt() expects the options to start in argv[1],
		   not argv[0], so we need to insert a dummy program
		   name (we use "x") at the start of the options before
		   passing them to make_argv() and then to getopt().
		*/
		dummy_command_line = make_many(char, strlen(options) + 3);
		strcpy(dummy_command_line, "x ");
		strcat(dummy_command_line, options);
		
		make_argv(dummy_command_line, &arg_str, &argv, &argc);
		oldmem(dummy_command_line);

		process_options(argc, argv);

		oldmem(arg_str);
		oldmem(argv);
	}

}

static void
process_options(int argc, char **argv)
{
	unsigned long size;
	int c;

	while ((c = getopt(argc, argv, "acC:d:hLlP:pr:s:tT:w:xz:1:2:3:")) != EOF)
	{
		switch (c)
		{

		case 'a':
			benchmark_all_solns = TRUE;
			break;

		case 'c':
			check_space = TRUE;
			break;

		case 'C':
			if (sscanf(optarg, "%lu", &size) != 1)
				usage();

			pcache_size = size * 1024;

			break;

		case 'd':	
			if (streq(optarg, "b"))
				nondstackdebug = TRUE;
			else if (streq(optarg, "c"))
				calldebug    = TRUE;
			else if (streq(optarg, "d"))
				detaildebug  = TRUE;
			else if (streq(optarg, "g"))
				gotodebug    = TRUE;
			else if (streq(optarg, "G"))
#ifdef CONSERVATIVE_GC
			GC_quiet = FALSE;
#else
			fatal_error("-dG: GC not enabled");
#endif
			else if (streq(optarg, "s"))
				detstackdebug   = TRUE;
			else if (streq(optarg, "h"))
				heapdebug    = TRUE;
			else if (streq(optarg, "f"))
				finaldebug   = TRUE;
			else if (streq(optarg, "p"))
				progdebug   = TRUE;
			else if (streq(optarg, "m"))
				memdebug    = TRUE;
			else if (streq(optarg, "r"))
				sregdebug    = TRUE;
			else if (streq(optarg, "t"))
				tracedebug   = TRUE;
			else if (streq(optarg, "a")) {
				calldebug      = TRUE;
				nondstackdebug = TRUE;
				detstackdebug  = TRUE;
				heapdebug      = TRUE;
				gotodebug      = TRUE;
				sregdebug      = TRUE;
				finaldebug     = TRUE;
				tracedebug     = TRUE;
#ifdef CONSERVATIVE_GC
				GC_quiet = FALSE;
#endif
			}
			else
				usage();

			use_own_timer = FALSE;
			break;

		case 'h':
			usage();
			break;

		case 'L': 
			do_init_modules();
			break;

		case 'l': {
			List	*ptr;
			List	*label_list;

			label_list = get_all_labels();
			for_list (ptr, label_list) {
				Label	*label;
				label = (Label *) ldata(ptr);
				printf("%lu %lx %s\n",
					(unsigned long) label->e_addr,
					(unsigned long) label->e_addr,
					label->e_name);
			}

			exit(0);
		}

		case 'p':
			MR_profiling = FALSE;
			break;

#ifdef	PARALLEL
		case 'P':
				if (sscanf(optarg, "%u", &numprocs) != 1)
					usage();
				
				if (numprocs < 1)
					usage();

				break;
#endif

		case 'r':	
			if (sscanf(optarg, "%d", &repeats) != 1)
				usage();

			break;

		case 's':
			if (sscanf(optarg+1, "%lu", &size) != 1)
				usage();

			if (optarg[0] == 'h')
				heap_size = size;
			else if (optarg[0] == 'd')
				detstack_size = size;
			else if (optarg[0] == 'n')
				nondstack_size = size;
			else if (optarg[0] == 'l')
				entry_table_size = size *
					1024 / (2 * sizeof(List *));
#ifdef MR_USE_TRAIL
			else if (optarg[0] == 't')
				trail_size = size;
#endif
			else
				usage();

			break;

		case 't':	
			use_own_timer = TRUE;

			calldebug      = FALSE;
			nondstackdebug = FALSE;
			detstackdebug  = FALSE;
			heapdebug      = FALSE;
			gotodebug      = FALSE;
			sregdebug      = FALSE;
			finaldebug     = FALSE;
			break;

		case 'T':
			if (streq(optarg, "r")) {
				MR_time_profile_method = MR_profile_real_time;
			} else if (streq(optarg, "v")) {
				MR_time_profile_method = MR_profile_user_time;
			} else if (streq(optarg, "p")) {
				MR_time_profile_method =
					MR_profile_user_plus_system_time;
			} else {
				usage();
			}
			break;

		case 'w': {
			Label *which_label;

			which_label = lookup_label_name(optarg);
			if (which_label == NULL)
			{
				fprintf(stderr, "Mercury runtime: "
					"label name `%s' unknown\n",
					optarg);
				exit(1);
			}

			program_entry_point = which_label->e_addr;

			break;
		}
		case 'x':
#ifdef CONSERVATIVE_GC
			GC_dont_gc = TRUE;
#endif

			break;

		case 'z':
			if (sscanf(optarg+1, "%lu", &size) != 1)
				usage();

			if (optarg[0] == 'h')
				heap_zone_size = size;
			else if (optarg[0] == 'd')
				detstack_zone_size = size;
			else if (optarg[0] == 'n')
				nondstack_zone_size = size;
#ifdef MR_USE_TRAIL
			else if (optarg[0] == 't')
				trail_zone_size = size;
#endif
			else
				usage();

			break;

		case '1':	
			if (sscanf(optarg, "%d", &r1val) != 1)
				usage();

			break;

		case '2':	
			if (sscanf(optarg, "%d", &r2val) != 1)
				usage();

			break;

		case '3':	
			if (sscanf(optarg, "%d", &r3val) != 1)
				usage();

			break;

		default:	
			usage();

		} /* end switch */
	} /* end while */
} /* end process_options() */

static void 
usage(void)
{
	printf("Mercury runtime usage:\n"
		"MERCURY_OPTIONS=\"[-hclLtxp] [-T[rvp]] [-d[abcdghs]]\n"
        "                  [-[szt][hdn]#] [-C#] [-r#]  [-w name] [-[123]#]\"\n"
		"-h \t\tprint this usage message\n"
		"-c \t\tcheck cross-function stack usage\n"
		"-l \t\tprint all labels\n"
		"-L \t\tcheck for duplicate labels\n"
		"-t \t\ttime program execution\n"
		"-x \t\tdisable garbage collection\n"
		"-p \t\tdisable profiling\n"
		"-Tr \t\tprofile real time (using ITIMER_REAL)\n"
		"-Tv \t\tprofile user time (using ITIMER_VIRTUAL)\n"
		"-Tp \t\tprofile user + system time (using ITIMER_PROF)\n"
		"-dg \t\tdebug gotos\n"
		"-dc \t\tdebug calls\n"
		"-db \t\tdebug backtracking\n"
		"-dh \t\tdebug heap\n"
		"-ds \t\tdebug detstack\n"
		"-df \t\tdebug final success/failure\n"
		"-da \t\tdebug all\n"
		"-dm \t\tdebug memory allocation\n"
		"-dG \t\tdebug garbage collection\n"
		"-dd \t\tdetailed debug\n"
		"-sh<n> \t\tallocate n kb for the heap\n"
		"-sd<n> \t\tallocate n kb for the det stack\n"
		"-sn<n> \t\tallocate n kb for the nondet stack\n"
#ifdef MR_USE_TRAIL
		"-st<n> \t\tallocate n kb for the trail\n"
#endif
		"-sl<n> \t\tallocate n kb for the label table\n"
		"-zh<n> \t\tallocate n kb for the heap redzone\n"
		"-zd<n> \t\tallocate n kb for the det stack redzone\n"
		"-zn<n> \t\tallocate n kb for the nondet stack redzone\n"
#ifdef MR_USE_TRAIL
		"-zt<n> \t\tallocate n kb for the trail redzone\n"
#endif
		"-C<n> \t\tprimary cache size in kbytes\n"
#ifdef PARALLEL
		"-P<n> \t\tnumber of processes to use for parallel execution\n"
		"\t\tapplies only if Mercury is configured with --enable-parallel\n"
#endif
		"-r<n> \t\trepeat n times\n"
		"-w<name> \tcall predicate with given name (default: main/2)\n"
		"-1<x> \t\tinitialize register r1 with value x\n"
		"-2<x> \t\tinitialize register r2 with value x\n"
		"-3<x> \t\tinitialize register r3 with value x\n");
	fflush(stdout);
	exit(1);
} /* end usage() */

/*---------------------------------------------------------------------------*/

void 
mercury_runtime_main(void)
{
#if NUM_REAL_REGS > 0
	Word c_regs[NUM_REAL_REGS];
#endif

#if !defined(SPEED) && defined(USE_GCC_NONLOCAL_GOTOS)
	unsigned char	safety_buffer[SAFETY_BUFFER_SIZE];
#endif

	static	int	repcounter;

	/*
	** Save the C callee-save registers
	** and restore the Mercury registers
	*/
	save_regs_to_mem(c_regs);
	restore_registers();

#if !defined(SPEED) && defined(USE_GCC_NONLOCAL_GOTOS)
	/*
	** double-check to make sure that we're not corrupting
	** the C stack with these non-local gotos, by filling
	** a buffer with a known value and then later checking
	** that it still contains only this value
	*/

	global_pointer_2 = safety_buffer;	/* defeat optimization */
	memset(safety_buffer, MAGIC_MARKER_2, SAFETY_BUFFER_SIZE);
#endif

#ifndef SPEED
#ifndef CONSERVATIVE_GC
	heap_zone->max      = heap_zone->min;
#endif
	detstack_zone->max  = detstack_zone->min;
	nondetstack_zone->max = nondetstack_zone->min;
#endif

	time_at_start = MR_get_user_cpu_miliseconds();
	time_at_last_stat = time_at_start;

	for (repcounter = 0; repcounter < repeats; repcounter++) {
		debugmsg0("About to call engine\n");
		call_engine(ENTRY(do_interpreter));
		debugmsg0("Returning from call_engine()\n");
	}

        if (use_own_timer) {
		time_at_finish = MR_get_user_cpu_miliseconds();
	}

#if defined(USE_GCC_NONLOCAL_GOTOS) && !defined(SPEED)
	{
		int i;

		for (i = 0; i < SAFETY_BUFFER_SIZE; i++)
			MR_assert(safety_buffer[i] == MAGIC_MARKER_2);
	}
#endif

	if (detaildebug) {
		debugregs("after final call");
	}

#ifndef	SPEED
	if (memdebug) {
		printf("\n");
#ifndef	CONSERVATIVE_GC
		printf("max heap used:      %6ld words\n",
			(long) (heap_zone->max - heap_zone->min));
#endif
		printf("max detstack used:  %6ld words\n",
			(long)(detstack_zone->max - detstack_zone->min));
		printf("max nondstack used: %6ld words\n",
			(long) (nondetstack_zone->max - nondetstack_zone->min));
	}
#endif

#ifdef MEASURE_REGISTER_USAGE
	printf("\n");
	print_register_usage_counts();
#endif

        if (use_own_timer) {
		printf("%8.3fu ",
			((double) (time_at_finish - time_at_start)) / 1000);
	}

	/*
	** Save the Mercury registers and
	** restore the C callee-save registers before returning,
	** since they may be used by the C code that called us.
	*/
	save_registers();
	restore_regs_from_mem(c_regs);

} /* end mercury_runtime_main() */

#ifdef MEASURE_REGISTER_USAGE
static void 
print_register_usage_counts(void)
{
	int	i;

	printf("register usage counts:\n");
	for (i = 0; i < MAX_RN; i++) {
		if (1 <= i && i <= ORD_RN) {
			printf("r%d", i);
		} else {
			switch (i) {

			case SI_RN:
				printf("succip");
				break;
			case HP_RN:
				printf("hp");
				break;
			case SP_RN:
				printf("sp");
				break;
			case CF_RN:
				printf("curfr");
				break;
			case MF_RN:
				printf("maxfr");
				break;
			case MR_TRAIL_PTR_RN:
				printf("MR_trail_ptr");
				break;
			case MR_TICKET_COUNTER_RN:
				printf("MR_ticket_counter");
				break;
			default:
				printf("UNKNOWN%d", i);
				break;
			}
		}

		printf("\t%lu\n", num_uses[i]);
	} /* end for */
} /* end print_register_usage_counts() */
#endif

Define_extern_entry(do_interpreter);
Declare_label(global_success);
Declare_label(global_fail);
Declare_label(all_done);

MR_MAKE_STACK_LAYOUT_ENTRY(do_interpreter);
MR_MAKE_STACK_LAYOUT_INTERNAL_WITH_ENTRY(global_success, do_interpreter);
MR_MAKE_STACK_LAYOUT_INTERNAL_WITH_ENTRY(global_fail, do_interpreter);
MR_MAKE_STACK_LAYOUT_INTERNAL_WITH_ENTRY(all_done, do_interpreter);

BEGIN_MODULE(interpreter_module)
	init_entry(do_interpreter);
	init_label(global_success);
	init_label(global_fail);
	init_label(all_done);
BEGIN_CODE

Define_entry(do_interpreter);
	push(MR_hp);
	push(MR_succip);
	push(MR_maxfr);
	mkframe("interpreter", 1, LABEL(global_fail));

	if (program_entry_point == NULL) {
		fatal_error("no program entry point supplied");
	}

#ifdef  PROFILE_TIME
	if (MR_profiling) MR_prof_turn_on_time_profiling();
#endif

	noprof_call(program_entry_point, LABEL(global_success));

Define_label(global_success);
#ifndef	SPEED
	if (finaldebug) {
		save_transient_registers();
		printregs("global succeeded");
		if (detaildebug)
			dumpnondstack();
	}
#endif

	if (benchmark_all_solns)
		redo();
	else
		GOTO_LABEL(all_done);

Define_label(global_fail);
#ifndef	SPEED
	if (finaldebug) {
		save_transient_registers();
		printregs("global failed");

		if (detaildebug)
			dumpnondstack();
	}
#endif

Define_label(all_done);

#ifdef  PROFILE_TIME
	if (MR_profiling) MR_prof_turn_off_time_profiling();
#endif

	MR_maxfr = (Word *) pop();
	MR_succip = (Code *) pop();
	MR_hp = (Word *) pop();

#ifndef SPEED
	if (finaldebug && detaildebug) {
		save_transient_registers();
		printregs("after popping...");
	}
#endif

	proceed();
#ifndef	USE_GCC_NONLOCAL_GOTOS
	return 0;
#endif
END_MODULE

/*---------------------------------------------------------------------------*/

int
mercury_runtime_terminate(void)
{
#if NUM_REAL_REGS > 0
	Word c_regs[NUM_REAL_REGS];
#endif
	/*
	** Save the callee-save registers; we're going to start using them
	** as global registers variables now, which will clobber them,
	** and we need to preserve them, because they're callee-save,
	** and our caller may need them.
	*/
	save_regs_to_mem(c_regs);

	(*MR_library_finalizer)();

	if (MR_profiling) MR_prof_finish();

	terminate_engine();

	/*
	** Restore the callee-save registers before returning,
	** since they may be used by the C code that called us.
	*/
	restore_regs_from_mem(c_regs);

	return mercury_exit_status;
}

/*---------------------------------------------------------------------------*/
void mercury_sys_init_wrapper(void); /* suppress gcc warning */
void mercury_sys_init_wrapper(void) {
	interpreter_module();
}
