cat >> $HGRCPATH <<EOF
[extensions]
narrow=
[experimental]
# Some of these tests use the deprecated treemanifest format on purpose
treemanifest.warn=no
EOF
