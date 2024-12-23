/*
 base85 codec

 Copyright 2006 Brendan Cully <brendan@kublai.com>

 This software may be used and distributed according to the terms of
 the GNU General Public License, incorporated herein by reference.

 Largely based on git's implementation
*/

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include "util.h"

static const char b85chars[] =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~";
static char b85dec[256];

static void b85prep(void)
{
	unsigned i;

	memset(b85dec, 0, sizeof(b85dec));
	for (i = 0; i < sizeof(b85chars); i++) {
		b85dec[(int)(b85chars[i])] = i + 1;
	}
}

static PyObject *b85encode(PyObject *self, PyObject *args)
{
	const unsigned char *text;
	PyObject *out;
	char *dst;
	Py_ssize_t len, olen, i;
	unsigned int acc, val, ch;
	int pad = 0;

	if (!PyArg_ParseTuple(args, "y#|p", &text, &len, &pad)) {
		return NULL;
	}

	if (pad) {
		olen = ((len + 3) / 4 * 5) - 3;
	} else {
		olen = len % 4;
		if (olen) {
			olen++;
		}
		olen += len / 4 * 5;
	}
	if (!(out = PyBytes_FromStringAndSize(NULL, olen + 3))) {
		return NULL;
	}

	dst = PyBytes_AsString(out);

	while (len) {
		acc = 0;
		for (i = 24; i >= 0; i -= 8) {
			ch = *text++;
			acc |= ch << i;
			if (--len == 0) {
				break;
			}
		}
		for (i = 4; i >= 0; i--) {
			val = acc % 85;
			acc /= 85;
			dst[i] = b85chars[val];
		}
		dst += 5;
	}

	if (!pad) {
		_PyBytes_Resize(&out, olen);
	}

	return out;
}

static PyObject *b85decode(PyObject *self, PyObject *args)
{
	PyObject *out = NULL;
	const char *text;
	char *dst;
	Py_ssize_t len, i, j, olen, cap;
	int c;
	unsigned int acc;

	if (!PyArg_ParseTuple(args, "y#", &text, &len)) {
		return NULL;
	}

	olen = len / 5 * 4;
	i = len % 5;
	if (i) {
		olen += i - 1;
	}
	if (!(out = PyBytes_FromStringAndSize(NULL, olen))) {
		return NULL;
	}

	dst = PyBytes_AsString(out);

	i = 0;
	while (i < len) {
		acc = 0;
		cap = len - i - 1;
		if (cap > 4) {
			cap = 4;
		}
		for (j = 0; j < cap; i++, j++) {
			c = b85dec[(int)*text++] - 1;
			if (c < 0) {
				PyErr_Format(
				    PyExc_ValueError,
				    "bad base85 character at position %d",
				    (int)i);
				goto bail;
			}
			acc = acc * 85 + c;
		}
		if (i++ < len) {
			c = b85dec[(int)*text++] - 1;
			if (c < 0) {
				PyErr_Format(
				    PyExc_ValueError,
				    "bad base85 character at position %d",
				    (int)i);
				goto bail;
			}
			/* overflow detection: 0xffffffff == "|NsC0",
			 * "|NsC" == 0x03030303 */
			if (acc > 0x03030303 || (acc *= 85) > 0xffffffff - c) {
				PyErr_Format(
				    PyExc_ValueError,
				    "bad base85 sequence at position %d",
				    (int)i);
				goto bail;
			}
			acc += c;
		}

		cap = olen < 4 ? olen : 4;
		olen -= cap;
		for (j = 0; j < 4 - cap; j++) {
			acc *= 85;
		}
		if (cap && cap < 4) {
			acc += 0xffffff >> (cap - 1) * 8;
		}
		for (j = 0; j < cap; j++) {
			acc = (acc << 8) | (acc >> 24);
			*dst++ = acc;
		}
	}

	return out;
bail:
	Py_XDECREF(out);
	return NULL;
}

static char base85_doc[] = "Base85 Data Encoding";

static PyMethodDef methods[] = {
    {"b85encode", b85encode, METH_VARARGS,
     "Encode text in base85.\n\n"
     "If the second parameter is true, pad the result to a multiple of "
     "five characters.\n"},
    {"b85decode", b85decode, METH_VARARGS, "Decode base85 text.\n"},
    {NULL, NULL},
};

static const int version = 1;

static struct PyModuleDef base85_module = {
    PyModuleDef_HEAD_INIT, "base85", base85_doc, -1, methods,
};

PyMODINIT_FUNC PyInit_base85(void)
{
	PyObject *m;
	b85prep();

	m = PyModule_Create(&base85_module);
	PyModule_AddIntConstant(m, "version", version);
	return m;
}
