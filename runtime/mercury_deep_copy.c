/*
** Copyright (C) 1997 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** This module defines the deep_copy() function.
*/

#include "mercury_imp.h"
#include "mercury_deep_copy.h"
#include "mercury_type_info.h"

#define in_range(X)	((X) >= lower_limit && (X) <= upper_limit)

/* for make_type_info(), we keep a list of allocated memory cells */
struct MemoryCellNode {
	void *data;
	struct MemoryCellNode *next;
};
typedef struct MemoryCellNode *MemoryList;

/*
** Prototypes.
*/
static Word get_base_type_layout_entry(Word data, Word *type_info);
static Word deep_copy_arg(Word data, Word *type_info, Word *arg_type_info,
	Word *lower_limit, Word *upper_limit);
static Word * make_type_info(Word *term_type_info, Word *arg_pseudo_type_info,
	MemoryList *allocated);
static void deallocate(MemoryList allocated_memory_cells);
static Word * deep_copy_type_info(Word *type_info,
	Word *lower_limit, Word *upper_limit);

MR_DECLARE_STRUCT(mercury_data___base_type_info_pred_0);
MR_DECLARE_STRUCT(mercury_data___base_type_info_func_0);

/*
** deep_copy(): see mercury_deep_copy.h for documentation.
**
** Due to the depth of the control here, we'll use 4 space indentation.
*/
Word 
deep_copy(Word data, Word *type_info, Word *lower_limit, Word *upper_limit)
{
    Word layout_entry, *entry_value, *data_value;
    int data_tag, entry_tag; 

    int arity, i;
    Word *argument_vector, *type_info_vector;

    Word new_data;

	
    data_tag = tag(data);
    data_value = (Word *) body(data, data_tag);

    layout_entry = get_base_type_layout_entry(data_tag, type_info);

    entry_tag = tag(layout_entry);
    entry_value = (Word *) body(layout_entry, entry_tag);

    switch(entry_tag) {

        case TYPELAYOUT_CONST_TAG: /* and TYPELAYOUT_COMP_CONST_TAG */

            /* Some builtins need special treatment */
            if ((Word) entry_value <= TYPELAYOUT_MAX_VARINT) {
                int builtin_type = unmkbody(entry_value);

                switch(builtin_type) {

                    case TYPELAYOUT_UNASSIGNED_VALUE:
                        fatal_error("Attempt to use an UNASSIGNED tag "
                            "in deep_copy");
                        break;

                    case TYPELAYOUT_UNUSED_VALUE:
                        fatal_error("Attempt to use an UNUSED tag "
                            "in deep_copy");
                        break;

                    case TYPELAYOUT_STRING_VALUE:
                        if (in_range(data_value)) {
                            incr_saved_hp_atomic(new_data, 
                                (strlen((String) data_value) + sizeof(Word)) 
                                / sizeof(Word));
                            strcpy((String) new_data, (String) data_value);
                        } else {
                            new_data = data;
                        }
                        break;

                    case TYPELAYOUT_FLOAT_VALUE:
			#ifdef BOXED_FLOAT
                	    if (in_range(data_value)) {
				/*
				** force a deep copy by converting to float
				** and back
				*/
	 			new_data = float_to_word(word_to_float(data));
			    } else {
				new_data = data;
			    }
			#else
			    new_data = data;
			#endif
			break;

                    case TYPELAYOUT_INT_VALUE:
                        new_data = data;
                        break;

                    case TYPELAYOUT_CHARACTER_VALUE:
                        new_data = data;
                        break;

                    case TYPELAYOUT_UNIV_VALUE: 
                            /* if the univ is stored in range, copy it */ 
                        if (in_range(data_value)) {
                            Word *new_data_ptr;

                                /* allocate space for a univ */
                            incr_saved_hp(new_data, 2);
                            new_data_ptr = (Word *) new_data;
                            new_data_ptr[UNIV_OFFSET_FOR_TYPEINFO] = 
				(Word) deep_copy_type_info( (Word *)
				    data_value[UNIV_OFFSET_FOR_TYPEINFO],
				    lower_limit, upper_limit);
                            new_data_ptr[UNIV_OFFSET_FOR_DATA] = deep_copy(
                                data_value[UNIV_OFFSET_FOR_DATA], 
                                (Word *) data_value[UNIV_OFFSET_FOR_TYPEINFO],
                                lower_limit, upper_limit);
                        } else {
                            new_data = data;
                        }
                        break;

                    case TYPELAYOUT_PREDICATE_VALUE:
                    {
                        /*
			** predicate closures store the number of curried
                        ** arguments as their first argument, the
                        ** Code * as their second, and then the
                        ** arguments
                        **
                        ** Their type-infos have a pointer to
                        ** base_type_info for pred/0, arity, and then
                        ** argument typeinfos.
                        **/
                        if (in_range(data_value)) {
                            int args;
                            Word *new_closure;

                            /* get number of curried arguments */
                            args = data_value[0];

                            /* create new closure */
                            incr_saved_hp(LVALUE_CAST(Word, new_closure),
				args + 2);

                            /* copy number of arguments */
                            new_closure[0] = args;

                            /* copy pointer to code for closure */
                            new_closure[1] = data_value[1];

                            /* copy arguments */
                            for (i = 0; i < args; i++) {
                                new_closure[i + 2] = deep_copy(
				    data_value[i + 2],
                                    (Word *) type_info[i +
					TYPEINFO_OFFSET_FOR_PRED_ARGS],
                                    lower_limit, upper_limit);
                            }
                            new_data = (Word) new_closure;
			} else {
			    new_data = data;
			}
                        break;
                    }

                    case TYPELAYOUT_VOID_VALUE:
                        fatal_error("Attempt to use a VOID tag in deep_copy");
                        break;

                    case TYPELAYOUT_ARRAY_VALUE:
                        if (in_range(data_value)) {
			    MR_ArrayType *new_array;
			    MR_ArrayType *old_array;
			    Integer array_size;

			    old_array = (MR_ArrayType *) data_value;
			    array_size = old_array->size;
			    new_array = MR_make_array(array_size);
			    new_array->size = array_size;
			    for (i = 0; i < array_size; i++) {
				new_array->elements[i] = old_array->elements[i];
			    }
			    new_data = (Word) new_array;
			} else {
			    new_data = data;
			}
			break;

                    case TYPELAYOUT_TYPEINFO_VALUE:
			new_data = (Word) deep_copy_type_info(data_value,
			    lower_limit, upper_limit);
                        break;

                    case TYPELAYOUT_C_POINTER_VALUE:
                        if (in_range(data_value)) {
			    /*
			    ** This error occurs if we try to deep_copy() a
			    ** `c_pointer' type that points to memory allocated
			    ** on the Mercury heap.
			    */
                            fatal_error("Attempt to use a C_POINTER tag "
				    "in deep_copy");
                        } else {
                            new_data = data;
                        }
                        break;

                    default:
                        fatal_error("Invalid tag value in deep_copy");
                        break;
                }
            } else {
                    /* a constant or enumeration */
                new_data = data;	/* just a copy of the actual item */
            }
            break;

        case TYPELAYOUT_SIMPLE_TAG: 

            argument_vector = data_value;

                /*
		** If the argument vector is in range, copy the
                ** arguments.
                */
            if (in_range(argument_vector)) {
                arity = entry_value[TYPELAYOUT_SIMPLE_ARITY_OFFSET];
                type_info_vector = entry_value + TYPELAYOUT_SIMPLE_ARGS_OFFSET;

                    /* allocate space for new args. */
                incr_saved_hp(new_data, arity);

                    /* copy arguments */
                for (i = 0; i < arity; i++) {
		    field(0, new_data, i) =
			deep_copy_arg(argument_vector[i],
				type_info, (Word *) type_info_vector[i],
				lower_limit, upper_limit);
                }
                    /* tag this pointer */
                new_data = (Word) mkword(data_tag, new_data);
            } else {
                new_data = data;
            }
            break;

        case TYPELAYOUT_COMPLICATED_TAG:
        {
            Word secondary_tag;
            Word *new_entry;

                /*
		** if the vector containing the secondary
                ** tags and the arguments is in range, 
                ** copy it.
                */
            if (in_range(data_value)) {
                secondary_tag = *data_value;
                argument_vector = data_value + 1;
                new_entry = (Word *) entry_value[secondary_tag +1];
                arity = new_entry[TYPELAYOUT_SIMPLE_ARITY_OFFSET];
                type_info_vector = new_entry + 
                    TYPELAYOUT_SIMPLE_ARGS_OFFSET;

                /*
		** allocate space for new args, and 
                ** secondary tag 
                */
                incr_saved_hp(new_data, arity + 1);

                    /* copy secondary tag */
                field(0, new_data, 0) = secondary_tag;

                    /* copy arguments */
                for (i = 0; i < arity; i++) {
                    field(0, new_data, i + 1) = 
			deep_copy_arg(argument_vector[i],
				type_info, (Word *) type_info_vector[i],
				lower_limit, upper_limit);
                }

                /* tag this pointer */
                new_data = (Word) mkword(data_tag, new_data);
            } else {
                new_data = data;
            }
            break;
        }

        case TYPELAYOUT_EQUIV_TAG: /* and TYPELAYOUT_NO_TAG */
            /* note: we treat no_tag types just like equivalences */

            if ((Word) entry_value < TYPELAYOUT_MAX_VARINT) {
                new_data = deep_copy(data,
		    (Word *) type_info[(Word) entry_value],
                    lower_limit, upper_limit);
            } else {
		/*
		** offset 0 is no-tag indicator
		** offset 1 is the pseudo-typeinfo
		** (as per comments in base_type_layout.m)
		** XXX should avoid use of hard-coded offset `1' here
		*/
		new_data = deep_copy_arg(data,
				type_info, (Word *) entry_value[1],
				lower_limit, upper_limit);
            }
            break;

        default:
            fatal_error("Unknown layout tag in deep copy");
            break;
    }

    return new_data;
} /* end deep_copy() */


Word 
get_base_type_layout_entry(Word data_tag, Word *type_info)
{
	Word *base_type_info, *base_type_layout;
	base_type_info = MR_TYPEINFO_GET_BASE_TYPEINFO(type_info);
	base_type_layout = MR_BASE_TYPEINFO_GET_TYPELAYOUT(base_type_info);
	return base_type_layout[data_tag];
}

/*
** deep_copy_arg is like deep_copy() except that it takes a
** pseudo_type_info (namely arg_pseudo_type_info) rather than
** a type_info.  The pseudo_type_info may contain type variables,
** which refer to arguments of the term_type_info.
*/
static Word
deep_copy_arg(Word data, Word *term_type_info, Word *arg_pseudo_type_info,
		Word *lower_limit, Word *upper_limit)
{
	MemoryList allocated_memory_cells;
	Word *new_type_info;
	Word new_data;

	allocated_memory_cells = NULL;
	new_type_info = make_type_info(term_type_info, arg_pseudo_type_info,
					&allocated_memory_cells);
	new_data = deep_copy(data, new_type_info, lower_limit, upper_limit);
	deallocate(allocated_memory_cells);

	return new_data;
}

/*
** deallocate() frees up a list of memory cells
*/
static void
deallocate(MemoryList allocated)
{
	while (allocated != NULL) {
	    MemoryList next = allocated->next;
	    free(allocated->data);
	    free(allocated);
	    allocated = next;
	}
}

	/* 
	** Given a type_info (term_type_info) which contains a
	** base_type_info pointer and possibly other type_infos
	** giving the values of the type parameters of this type,
	** and a pseudo-type_info (arg_pseudo_type_info), which contains a
	** base_type_info pointer and possibly other type_infos
	** giving EITHER
	** 	- the values of the type parameters of this type,
	** or	- an indication of the type parameter of the
	** 	  term_type_info that should be substituted here
	**
	** This returns a fully instantiated type_info, a version of the
	** arg_pseudo_type_info with all the type variables filled in.
	** If there are no type variables to fill in, we return the
	** arg_pseudo_type_info, unchanged. Otherwise, we allocate
	** memory using malloc().  Any such memory allocated will be
	** inserted into the list of allocated memory cells.
	** It is the caller's responsibility to free these cells
	** by calling deallocate() on the list when they are no longer
	** needed.
	**
	** This code could be tighter. In general, we want to
	** handle our own allocations rather than using malloc().
	**
	** NOTE: If you are changing this code, you might also need
	** to change the code in create_type_info in library/std_util.m,
	** which does much the same thing, only allocating on the 
	** heap instead of using malloc.
	*/

Word *
make_type_info(Word *term_type_info, Word *arg_pseudo_type_info,
	MemoryList *allocated) 
{
	int i, arity, extra_args;
	Word *base_type_info;
	Word *arg_type_info;
	Word *type_info;

	/* 
	** The arg_pseudo_type_info might be a polymorphic variable.
	** If so, then substitute its value, and then we're done.
	*/
	if (TYPEINFO_IS_VARIABLE(arg_pseudo_type_info)) {
		arg_type_info = (Word *) 
			term_type_info[(Word) arg_pseudo_type_info];
		if (TYPEINFO_IS_VARIABLE(arg_type_info)) {
			fatal_error("make_type_info: "
				"unbound type variable");
		}
		return arg_type_info;
	}

	base_type_info = MR_TYPEINFO_GET_BASE_TYPEINFO(arg_pseudo_type_info);

	/* no arguments - optimise common case */
	if (base_type_info == arg_pseudo_type_info) {
		return arg_pseudo_type_info;
	} 

        if (MR_BASE_TYPEINFO_IS_HO(base_type_info)) {
                arity = MR_TYPEINFO_GET_HIGHER_ARITY(arg_pseudo_type_info);
                extra_args = 2;
        } else {
                arity = MR_BASE_TYPEINFO_GET_TYPE_ARITY(base_type_info);
                extra_args = 1;
        }

	/*
	** Iterate over the arguments, figuring out whether we
	** need to make any substitutions.
	** If so, copy the resulting argument type-infos into
	** a new type_info.
	*/
	type_info = NULL;
	for (i = extra_args; i < arity + extra_args; i++) {
		arg_type_info = make_type_info(term_type_info,
			(Word *) arg_pseudo_type_info[i], allocated);
		if (TYPEINFO_IS_VARIABLE(arg_type_info)) {
			fatal_error("make_type_info: "
				"unbound type variable");
		}
		if (arg_type_info != (Word *) arg_pseudo_type_info[i]) {
			/*
			** We made a substitution.
			** We need to allocate a new type_info,
			** if we haven't done so already.
			*/
			if (type_info == NULL) {
				MemoryList node;
				/*
				** allocate a new type_info and copy the
				** data across from arg_pseduo_type_info
				*/
				type_info = checked_malloc(
					(arity + extra_args) * sizeof(Word));
				memcpy(type_info, arg_pseudo_type_info,
					(arity + extra_args) * sizeof(Word));
				/*
				** insert this type_info cell into the linked
				** list of allocated memory cells, so we can
				** free it later on
				*/
				node = checked_malloc(sizeof(*node));
				node->data = type_info;
				node->next = *allocated;
				*allocated = node;
			}
			type_info[i] = (Word) arg_type_info;
		}
	}
	if (type_info == NULL) {
		return arg_pseudo_type_info;
	} else {
		return type_info;
	}

} /* end make_type_info() */

Word *
deep_copy_type_info(Word *type_info, Word *lower_limit, Word *upper_limit)
{
	if (in_range(type_info)) {
		Word *base_type_info;
		Word *new_type_info;
		Integer arity, i;

		/* XXX this doesn't handle higher-order types properly */

		base_type_info = MR_TYPEINFO_GET_BASE_TYPEINFO(type_info);
		arity = MR_BASE_TYPEINFO_GET_TYPE_ARITY(base_type_info);
		incr_saved_hp(LVALUE_CAST(Word, new_type_info), arity + 1);
		new_type_info[0] = type_info[0];
		for (i = 1; i < arity + 1; i++) {
			new_type_info[i] = (Word) deep_copy_type_info(
				(Word *) type_info[i],
				lower_limit, upper_limit);
		}
		return new_type_info;
	} else {
		return type_info;
	}
}
