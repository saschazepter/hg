# ui.py - Type annotations for ui related objects
#
# Copyright 2025 Matt Harbison <mharbison72@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from typing import (
    Protocol,
    Sequence,
)


class IHttpPasswordMgr(Protocol):
    """A protocol class for the ``mercurial.ui.httppasswordmgrdbproxy`` class."""

    def add_password(
        self,
        realm: bytes | str,
        uris: bytes | str | Sequence[bytes | str],
        user: bytes | str,
        passwd: bytes | str,
    ):
        """
        Add a password to the database.

        ``uris`` can be either a single URI, or a sequence of URIs. realm, user
         and passwd must be strings or bytes. This causes (user, passwd) to be
         used as authentication tokens when authentication for realm and a
         super-URI of the given URIs is given.
        """

    def find_user_password(
        self, realm: bytes | str, uri: bytes | str
    ) -> tuple[bytes | None, bytes | None]:
        """
        Get user/password for given realm and URI, if any.

        This method will return (None, None) if there is no matching
        user/password.  The realm None will be searched if the given realm has
        no matching user/password.
        """
