#!/bin/sh

# mnp - Mercury NU-Prolog Interpreter
#
# A version of `np' with `np_builtin' and the Mercury library already loaded.

INTERPRETER=${MERCURY_INTERPRETER:-@LIBDIR@/nuprolog/@FULLARCH@/library}

exec $INTERPRETER "$@"
