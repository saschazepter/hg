/*
 * Standalone entry point for the chg binary
 *
 * Copyright (c) 2011 Yuya Nishihara <yuya@tcha.org>
 *
 * This software may be used and distributed according to the terms of the
 * GNU General Public License version 2 or any later version.
 */

int chg_main(int argc, const char *argv[]);

int main(int argc, const char *argv[])
{
	return chg_main(argc, argv);
}
