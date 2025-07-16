#!/bin/sh
#
# add color to the output of `importlab --trim --tree`
#
# cycles are flagged with `cycle {}` so we make the "cycle" red and the content
# of the cycle yellow to make them easy to spot.
#
# the module starting with '::' are internal module that we don't really care
# about (the subgraph is filtered by `--trim`)
#
# The "+" before module mark "direct" (vs "local") import and we don't really
# care about that.
#
# We replace new lines by null bytes during process as it is easier to have sed
# not do multiline work.

if [ -z "$TERM" ]; then
    TERM=ansi
    export TERM
fi

RED="$(tput setaf 1)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 4)"
BLACK="$(tput sgr0)"
tr '\n' '\0' \
  | sed 's/\bcycle\b/'${RED}'\0'${BLACK}'/g' \
  | sed -E 's/\{[^{]+\}/'${YELLOW}'\0'${BLACK}'/g' \
  | sed 's,:: [^\x0]*,'${BLUE}'\0'${BLACK}',g' \
  | tr '\0' '\n'
