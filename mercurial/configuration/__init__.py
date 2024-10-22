# configuration related constants

from __future__ import annotations

from typing import (
    List,
    Tuple,
    Union,
)

# keep typing simple for now
ConfigLevelT = str
LEVEL_USER = 'user'  # "user" is the default level and never passed explicitly
LEVEL_LOCAL = 'local'
LEVEL_GLOBAL = 'global'
LEVEL_SHARED = 'shared'
LEVEL_NON_SHARED = 'non_shared'
EDIT_LEVELS = (
    LEVEL_USER,
    LEVEL_LOCAL,
    LEVEL_GLOBAL,
    LEVEL_SHARED,
    LEVEL_NON_SHARED,
)

ConfigItemT = Tuple[bytes, bytes, bytes, bytes]
ResourceIDT = Tuple[bytes, bytes]
FileRCT = bytes
ComponentT = Tuple[
    bytes,
    Union[
        List[ConfigItemT],
        FileRCT,
        ResourceIDT,
    ],
]
