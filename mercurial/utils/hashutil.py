from __future__ import annotations

import hashlib

fast_sha1 = hashlib.sha1
try:
    from ..thirdparty import sha1dc  # pytype: disable=import-error

    sha1 = sha1dc.sha1
except (ImportError, AttributeError):
    sha1 = fast_sha1
