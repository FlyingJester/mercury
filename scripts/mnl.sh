#!/bin/sh

# mnl - Mercury NU-Prolog Linker.
#
# Links NU-Prolog object files together with the Mercury library
# to produce an executable binary.

NULIBDIR=${MERCURY_LIB_DIR:-@LIBDIR@/nuprolog/@FULLARCH@}
LIBRARY_OBJS=${MERCURY_LIB_OBJS:-"@LIBOBJS@"}

options=

while true; do
	case "$1" in
		-e|-u|-o|-F)
			options="$options $1 $2"
			shift 2
			;;
		-*)	options="$options $1"
			shift
			;;
		*)	break 2
			;;
	esac
done

objlist=
for obj in $LIBRARY_OBJS; do
	if echo "$@" | grep "$obj" > /dev/null; then
		true
	else
		objlist="$objlist $NULIBDIR/$obj"
	fi
done

exec nc $options $objlist "$@"
