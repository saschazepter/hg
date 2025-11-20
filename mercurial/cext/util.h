/*
 util.h - utility functions for interfacing with the various python APIs.

 This software may be used and distributed according to the terms of
 the GNU General Public License, incorporated herein by reference.
*/

#ifndef _HG_UTIL_H_
#define _HG_UTIL_H_

#include "compat.h"

/* clang-format off */
typedef struct {
	PyObject_HEAD
	int flags;
	int mode;
	int size;
	int mtime_s;
	int mtime_ns;
} dirstateItemObject;
/* clang-format on */

static const int dirstate_flag_wc_tracked = 1 << 0;
static const int dirstate_flag_p1_tracked = 1 << 1;
static const int dirstate_flag_p2_info = 1 << 2;
static const int dirstate_flag_mode_exec_perm = 1 << 3;
static const int dirstate_flag_mode_is_symlink = 1 << 4;
static const int dirstate_flag_has_fallback_exec = 1 << 5;
static const int dirstate_flag_fallback_exec = 1 << 6;
static const int dirstate_flag_has_fallback_symlink = 1 << 7;
static const int dirstate_flag_fallback_symlink = 1 << 8;
static const int dirstate_flag_expected_state_is_modified = 1 << 9;
static const int dirstate_flag_has_meaningful_data = 1 << 10;
static const int dirstate_flag_has_mtime = 1 << 11;
static const int dirstate_flag_mtime_second_ambiguous = 1 << 12;
static const int dirstate_flag_directory = 1 << 13;
static const int dirstate_flag_all_unknown_recorded = 1 << 14;
static const int dirstate_flag_all_ignored_recorded = 1 << 15;

extern PyTypeObject dirstateItemType;
#define dirstate_tuple_check(op) (Py_TYPE(op) == &dirstateItemType)

#ifndef MIN
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#endif
/* VC9 doesn't include bool and lacks stdbool.h based on my searching */
#if defined(_MSC_VER) || __STDC_VERSION__ < 199901L
#define true 1
#define false 0
typedef unsigned char bool;
#else
#include <stdbool.h>
#endif

/* Convert a PyInt or PyLong to a long. Returns false if there is an
   error, in which case an exception will already have been set. */
static inline bool pylong_to_long(PyObject *pylong, long *out)
{
	*out = PyLong_AsLong(pylong);
	/* Fast path to avoid hitting PyErr_Occurred if the value was obviously
	 * not an error. */
	if (*out != -1) {
		return true;
	}
	return PyErr_Occurred() == NULL;
}

#endif /* _HG_UTIL_H_ */
