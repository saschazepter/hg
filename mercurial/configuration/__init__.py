# configuration related constants

from __future__ import annotations

from typing import (
    List,
    Tuple,
    Union,
)

# keep typing simple for now
ConfigLevelT = str
LEVEL_BUNDLED_RESOURCE = 'RESOURCE'
LEVEL_ENV_OVERWRITE = 'ENV-HGRCPATH'
LEVEL_USER = 'user'
LEVEL_LOCAL = 'local'
LEVEL_GLOBAL = 'global'
LEVEL_SHARED = 'shared'
LEVEL_NON_SHARED = 'non_shared'
# only include level that it make sense to edit
# note: "user" is the default level and never passed explicitly
EDIT_LEVELS = (
    LEVEL_USER,
    LEVEL_LOCAL,
    LEVEL_GLOBAL,
    LEVEL_SHARED,
    LEVEL_NON_SHARED,
)
# levels that can works without a repository
NO_REPO_EDIT_LEVELS = (
    LEVEL_USER,
    LEVEL_GLOBAL,
)

ConfigItemT = Tuple[bytes, bytes, bytes, bytes]
ResourceIDT = Tuple[bytes, bytes]
FileRCT = bytes
ComponentT = Tuple[
    ConfigLevelT,
    bytes,
    Union[
        List[ConfigItemT],
        FileRCT,
        ResourceIDT,
    ],
]
