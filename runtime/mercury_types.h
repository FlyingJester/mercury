/*
** Copyright (C) 1995-1999 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** mercury_types.h - definitions of some basic types used by the
** code generated by the Mercury compiler and by the Mercury runtime.
*/

/*
** IMPORTANT NOTE:
** This file must not contain any #include statements,
** other than the #include of "mercury_conf.h",
** for reasons explained in mercury_imp.h.
*/

#ifndef MERCURY_TYPES_H
#define MERCURY_TYPES_H

#include "mercury_conf.h"

/*
** This section defines the relevant types from C9X's
** <stdint.h> header, either by including that header,
** or if necessary by emulating it ourselves, with some
** help from the autoconfiguration script.
*/

#ifdef HAVE_STDINT
  #include <stdint.h>
#endif
#ifdef HAVE_INTTYPES
  #include <inttypes.h>
#endif
#ifdef HAVE_SYS_TYPES
  #include <sys/types.h>
#endif

#ifndef MR_HAVE_INTPTR_T
  typedef unsigned MR_WORD_TYPE		uintptr_t;
  typedef MR_WORD_TYPE			intptr_t;
#endif

#ifndef MR_HAVE_INT_LEASTN_T
  typedef unsigned MR_INT_LEAST32_TYPE	uint_least32_t;
  typedef MR_INT_LEAST32_TYPE		int_least32_t;
  typedef unsigned MR_INT_LEAST16_TYPE	uint_least16_t;
  typedef MR_INT_LEAST16_TYPE		int_least16_t;
  typedef unsigned char			uint_least8_t;
  typedef signed char			int_least8_t;
#endif

/* 
** This section defines the basic types that we use.
** Note that we require sizeof(Word) == sizeof(Integer) == sizeof(Code*).
*/

typedef	uintptr_t		Word;
typedef	intptr_t		Integer;
typedef	uintptr_t		Unsigned;
typedef	intptr_t		Bool;

/*
** `Code *' is used as a generic pointer-to-label type that can point
** to any label defined using the Define_* macros in mercury_goto.h.
*/
typedef void			Code;

/*
** Float64 is required for the bytecode.
** XXX: We should also check for IEEE-754 compliance.
*/

#if	MR_FLOAT_IS_64_BIT
	typedef	float			Float64;
#elif	MR_DOUBLE_IS_64_BIT
	typedef	double			Float64;
#elif	MR_LONG_DOUBLE_IS_64_BIT
	typedef	long double		Float64;
#else
	#error	For Mercury bytecode, we require 64-bit IEEE-754 floating point
#endif

/*
** The following four typedefs logically belong in mercury_string.h.
** They are defined here to avoid problems with circular #includes.
** If you modify them, you will need to modify mercury_string.h as well.
*/

typedef char Char;
typedef unsigned char UnsignedChar;

typedef Char *String;
typedef const Char *ConstString;

/* continuation function type, for --high-level-C option */
typedef void (*Cont) (void);

/*
** semidet predicates indicate success or failure by leaving nonzero or zero
** respectively in register r1
** (should this #define go in some other header file?)
*/
#define SUCCESS_INDICATOR r1

#endif /* not MERCURY_TYPES_H */
