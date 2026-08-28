# Install a small `chg` wrapper script around `hg`.
#
# Used by tests to guarantee that a client/daemon mode is used, in a compatible way.
# Adding HGDAEMONIZEPOLICY=always everywhere would be an option but is quite noisy.
#
# We might consider removing this approach in the future when the use of `chg`
# can be controlled directly in the config.
#
# This is a script rather than a shell function so that `VAR=x chg ...` prefixes
# stay temporary in all POSIX shells; dash would leak them permanently with a
# function.

mkdir -p "$TESTTMP/chg-wrapper"
cat > "$TESTTMP/chg-wrapper/chg" <<'EOF'
#!/bin/sh
HGDAEMONIZEPOLICY=always exec hg "$@"
EOF
chmod +x "$TESTTMP/chg-wrapper/chg"
PATH="$TESTTMP/chg-wrapper:$PATH"
export PATH
