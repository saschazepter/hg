# configuration related constants

from __future__ import annotations

import enum

from typing import (
    NamedTuple,
    Union,
)

# keep typing simple for now
ConfigLevelT = str
LEVEL_BUNDLED_RESOURCE = 'RESOURCE'
# the values a handful of environment variables provide, read right before
# the user level so the user can override them.
#
# This level never holds any file.
LEVEL_ENV_ITEMS = 'env-items'
# the configuration files listed in $HGRCPATH
#
# When that variable is set, these files replace the bundled, system and user
# ones.
LEVEL_HGRCPATH = 'HGRCPATH'
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


class SHADOW(enum.Enum):
    """what hides a value we just wrote in a managed configuration file

    See `config.set_at_source` and `ui.register_config_write`.
    """

    # another definition of the same configuration level wins, typically a
    # value the user wrote by hand
    SAME_LEVEL = 'same-level'
    # a definition from a higher configuration level wins, as it should
    HIGHER_LEVEL = 'higher-level'
    # a value coming from the environment wins
    ENVIRONMENT = 'environment'
    # a process local override wins, it goes away with the command
    OVERRIDE = 'override'

    def __repr__(self) -> str:
        return 'SHADOW.%s' % self.name


class Shadowing(NamedTuple):
    """the definition that hides a value we wrote

    See `config.set_at_source` and `ui.register_config_write`.
    """

    # the value in use instead of the one we wrote
    value: bytes
    # where it comes from, as "<file>:<line>"
    source: bytes
    # how that definition relates to the value we wrote
    status: SHADOW
    # configuration level it comes from, None for our own level
    config_level: ConfigLevelT | None = None

    def __repr__(self) -> str:
        return 'Shadowing(%r, %r, %r, %r)' % (
            self.value,
            self.source,
            self.status,
            self.config_level,
        )


# a ``section.name`` configuration key, as parsed from a command argument
ConfigKeyT = tuple[bytes, bytes]
# a ``section.name=value`` specification, as parsed from a command argument
ConfigSpecT = tuple[bytes, bytes, bytes]

ConfigItemT = tuple[bytes, bytes, bytes, bytes]
ResourceIDT = tuple[bytes, bytes]
FileRCT = bytes
ComponentT = tuple[
    ConfigLevelT,
    bytes,
    Union[
        list[ConfigItemT],
        FileRCT,
        ResourceIDT,
    ],
]
