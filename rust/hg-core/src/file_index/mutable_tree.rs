//! This module implements an in-memory prefix tree as a layer on top of the
//! tree file from [`super::on_disk`]. It is used for building the tree file
//! from scratch and for appending to it.

use bytes_cast::unaligned::U32Be;
use bytes_cast::BytesCast as _;

use super::on_disk::Error;
use super::on_disk::FileIndexView;
use super::on_disk::TreeEdge;
use super::on_disk::TreeNode;
use super::FileToken;
use crate::file_index::on_disk::NodePointer;
use crate::file_index::on_disk::TreeNodeFlags;
use crate::file_index::on_disk::TreeNodeHeader;
use crate::utils::hg_path::HgPath;
use crate::utils::strings::common_prefix_length;
use crate::utils::strings::SliceExt as _;
use crate::utils::u32_u;
use crate::utils::u_u32;

/// Mutable version of [`TreeNode`].
struct MutableTreeNode<'a> {
    /// See [`TreeNode::token`].
    token: Option<FileToken>,
    /// Edges to children of this node.
    edges: Vec<MutableTreeEdge<'a>>,
}

impl<'a> MutableTreeNode<'a> {
    /// Creates an empty [`MutableTreeNode`].
    fn empty() -> Self {
        Self { token: None, edges: Vec::new() }
    }

    /// Converts a [`TreeNode`] to a [`MutableTreeNode`].
    fn new(
        file_index: &FileIndexView<'a>,
        node: TreeNode<'a>,
    ) -> Result<Self, Error> {
        Ok(Self {
            token: node.token,
            edges: node
                .edges
                .iter()
                .map(|&edge| MutableTreeEdge::new(file_index, edge))
                .collect::<Result<_, _>>()?,
        })
    }
}

/// Mutable version of [`TreeEdge`].
struct MutableTreeEdge<'a> {
    /// The label of this edge.
    label: &'a [u8],
    /// Offset of [`Self::label`] in the list file.
    label_offset: u32,
    /// Pointer to the child node.
    node_pointer: MutableTreeNodePointer,
}

impl<'a> MutableTreeEdge<'a> {
    /// Converts a [`TreeEdge`] to a [`MutableTreeEdge`].
    fn new(
        file_index: &FileIndexView<'a>,
        edge: TreeEdge,
    ) -> Result<Self, Error> {
        Ok(MutableTreeEdge {
            label: file_index.read_span(edge.label())?,
            label_offset: edge.label_offset.get(),
            node_pointer: MutableTreeNodePointer::OffsetOnDisk(
                edge.node_pointer.get(),
            ),
        })
    }
}

/// A pointer to a tree node either in memory or on disk.
#[derive(Copy, Clone)]
enum MutableTreeNodePointer {
    /// Index of a node in [`MutableTree::nodes`].
    Index(u32),
    /// Offset of an existing node in the tree file of [`MutableTree::base`].
    OffsetOnDisk(u32),
}

/// An in-memory prefix tree that can be serialized to a tree file.
pub struct MutableTree<'a> {
    /// If present, we are appending to this file index's tree file.
    base: Option<&'a FileIndexView<'a>>,
    /// Additional nodes. The first element is the new root.
    nodes: Vec<MutableTreeNode<'a>>,
    /// Number of nodes copied from [`Self::base`].
    num_copied_nodes: usize,
    /// Number of nodes copied from [`Self::base`] where the token is set.
    num_copied_tokens: usize,
    /// Number of edges copied from [`Self::base`].
    /// These are the edges that use [`MutableTreeNodePointer::OffsetOnDisk`].
    num_copied_edges: usize,
    /// Number of paths added to the tree.
    num_paths_added: usize,
}

/// Result of serializing a [`MutableTree`].
pub struct SerializedMutableTree {
    /// Bytes to be written or appended to the tree file.
    pub bytes: Vec<u8>,
    /// New total size of the tree file.
    pub tree_file_size: u32,
    /// New root node offset.
    pub tree_root_pointer: u32,
    /// New total number of unused bytes.
    pub tree_unused_bytes: u32,
}

impl<'a> MutableTree<'a> {
    /// Creates a new [`MutableTree`] for writing a new tree file.
    pub fn empty(num_paths_estimate: usize) -> Self {
        Self::new(None, MutableTreeNode::empty(), num_paths_estimate)
    }

    /// Creates a new [`MutableTree`] for appending to an existing tree file.
    pub fn with_base(
        base: &'a FileIndexView<'a>,
        num_new_paths_estimate: usize,
    ) -> Result<Self, Error> {
        Ok(Self::new(
            Some(base),
            MutableTreeNode::new(base, base.root)?,
            num_new_paths_estimate,
        ))
    }

    fn new(
        base: Option<&'a FileIndexView<'a>>,
        root: MutableTreeNode<'a>,
        num_new_paths_estimate: usize,
    ) -> Self {
        // Estimate the number of new nodes to be double the number of paths.
        let mut nodes = Vec::with_capacity(num_new_paths_estimate * 2);
        let num_copied_nodes = if base.is_some() { 1 } else { 0 };
        let num_copied_edges = root.edges.len();
        assert!(root.token.is_none());
        nodes.push(root);
        Self {
            base,
            nodes,
            num_copied_nodes,
            num_copied_tokens: 0,
            num_copied_edges,
            num_paths_added: 0,
        }
    }

    /// Returns true if this tree is building on top of a base file index.
    pub fn has_base(&self) -> bool {
        self.base.is_some()
    }

    /// Returns the number of paths in this tree.
    /// This includes paths from the base file index, if there is one.
    pub fn len(&self) -> usize {
        self.base.map_or(0, |base| base.len()) + self.num_paths_added
    }

    /// Copies the node at the given tree file offset into a new
    /// [`MutableTreeNode`], and returns its index.
    fn copy_node_at(&mut self, offset: u32) -> Result<usize, Error> {
        let file_index = self.base.as_ref().expect("base should be present");
        let node = file_index.read_node(offset)?;
        self.num_copied_nodes += 1;
        self.num_copied_edges += node.edges.len();
        if node.token.is_some() {
            self.num_copied_tokens += 1;
        }
        let node_index = self.nodes.len();
        self.nodes.push(MutableTreeNode::new(file_index, node)?);
        Ok(node_index)
    }

    /// Inserts `(path, token)` into the tree.
    /// `path_offset` is the offset of `path` in the list file.
    /// Path must be nonempty, not contain "\x00", and not be already inserted.
    pub fn insert(
        &mut self,
        path: &'a HgPath,
        token: FileToken,
        path_offset: u32,
    ) -> Result<(), Error> {
        assert!(!path.is_empty());
        let mut remainder = path.as_bytes();
        let mut node_index = 0;
        'outer: loop {
            for (i, edge) in self.nodes[node_index].edges.iter().enumerate() {
                if let Some(suffix) = remainder.drop_prefix(edge.label) {
                    remainder = suffix;
                    let new_node_index = match edge.node_pointer {
                        MutableTreeNodePointer::Index(index) => u32_u(index),
                        MutableTreeNodePointer::OffsetOnDisk(offset) => {
                            self.copy_node_at(offset)?
                        }
                    };
                    self.nodes[node_index].edges[i].node_pointer =
                        MutableTreeNodePointer::Index(u_u32(new_node_index));
                    node_index = new_node_index;
                    continue 'outer;
                }
            }
            break;
        }
        let initial_nodes_len = self.nodes.len();
        let common_prefix_edge = 'outer: {
            if !remainder.is_empty() {
                for edge in &mut self.nodes[node_index].edges {
                    match common_prefix_length(remainder, edge.label) {
                        0 => {}
                        length => break 'outer Some((length, edge)),
                    }
                }
            }
            None
        };
        let consumed = u_u32(path.len() - remainder.len());
        let mut label_offset = path_offset + consumed;
        if let Some((length, edge)) = common_prefix_edge {
            // Can't use nodes.len() here due to borrowing edge.
            node_index = initial_nodes_len;
            let edge_to_intermediate_node = MutableTreeEdge {
                label: &remainder[..length],
                // We arbitrarily choose label_offset (prefix from new path)
                // here instead of edge.label_offset (prefix from old path).
                label_offset,
                node_pointer: MutableTreeNodePointer::Index(u_u32(node_index)),
            };
            let edge_to_old_node = MutableTreeEdge {
                label: &edge.label[length..],
                label_offset: edge.label_offset + u_u32(length),
                node_pointer: edge.node_pointer,
            };
            let intermediate_node =
                MutableTreeNode { token: None, edges: vec![edge_to_old_node] };
            *edge = edge_to_intermediate_node;
            self.nodes.push(intermediate_node);
            remainder = &remainder[length..];
            label_offset += u_u32(length);
        }
        if !remainder.is_empty() {
            let new_node_index = self.nodes.len();
            let node = &mut self.nodes[node_index];
            node_index = new_node_index;
            node.edges.push(MutableTreeEdge {
                label: remainder,
                label_offset,
                node_pointer: MutableTreeNodePointer::Index(u_u32(node_index)),
            });
            // We need edges.len() to fit in TreeNodeHeader::num_children which
            // is a u8. There can be at most 256 because a 257th would share at
            // least 1 byte prefix with another edge and so never get created.
            // Since hg paths do not allow "\x00", "\r", and "\n", the maximum
            // is actually 253. Assert on 255 because that's all we rely on.
            assert!(node.edges.len() <= 255);
            self.nodes.push(MutableTreeNode::empty());
        }
        let node = &mut self.nodes[node_index];
        assert_eq!(node.token, None, "path was already inserted");
        node.token = Some(token);
        self.num_paths_added += 1;
        Ok(())
    }

    /// Serializes the tree to bytes, ready to be written to disk.
    pub fn serialize(&self) -> SerializedMutableTree {
        // Terminology: final = old + additional = old + (copied + fresh).
        let old_size = match self.base {
            Some(index) => u_u32(index.tree_file.len()),
            None => 0,
        };
        let num_additional_nodes = self.nodes.len();
        let num_additional_tokens =
            self.num_copied_tokens + self.num_paths_added;
        let num_fresh_nodes = num_additional_nodes - self.num_copied_nodes;
        let root_is_fresh = self.num_copied_nodes == 0;
        // There is a fresh edge for every fresh node except the root.
        let num_fresh_edges = if root_is_fresh {
            num_fresh_nodes - 1
        } else {
            num_fresh_nodes
        };
        let num_additional_edges = self.num_copied_edges + num_fresh_edges;
        let additional_size = // (comment to improve formatting)
            num_additional_nodes * std::mem::size_of::<TreeNodeHeader>()
            + num_additional_tokens * std::mem::size_of::<FileToken>()
            + num_additional_edges * std::mem::size_of::<TreeEdge>();
        let final_size = old_size + u_u32(additional_size);
        let mut buffer = Vec::<u8>::with_capacity(additional_size);
        let mut stack = vec![(0, 0)];
        const UNSET_POINTER: NodePointer = NodePointer::MAX;
        while let Some((index, fixup_offset)) = stack.pop() {
            if index != 0 {
                // Fix up `TreeEdge::node_pointer` in the incoming edge.
                const N: usize = std::mem::size_of::<NodePointer>();
                let current_offset: [u8; N] =
                    (old_size + u_u32(buffer.len())).to_be_bytes();
                let dest = &mut buffer[fixup_offset..fixup_offset + N];
                debug_assert_eq!(
                    NodePointer::from_be_bytes(dest.try_into().unwrap()),
                    UNSET_POINTER
                );
                dest.copy_from_slice(&current_offset);
            }
            let node = &self.nodes[index];
            let num_children: u8 =
                node.edges.len().try_into().expect(
                    "MutableTree should guarantee edges.len() fits in u8",
                );
            let flags = match node.token {
                None => TreeNodeFlags::empty(),
                Some(_) => TreeNodeFlags::HAS_TOKEN,
            };
            let header = TreeNodeHeader::new(flags, num_children);
            buffer.extend_from_slice(header.as_bytes());
            if let Some(token) = node.token {
                let token: U32Be = token.0.into();
                buffer.extend_from_slice(token.as_bytes());
            }
            for edge in &node.edges {
                let label_length: u16 = edge.label.len().try_into().expect(
                    "MutableTree should guarantee label.len() fits in u16",
                );
                let node_pointer = match edge.node_pointer {
                    MutableTreeNodePointer::Index(index) => {
                        let fixup_offset = buffer.len()
                            + std::mem::offset_of!(TreeEdge, node_pointer);
                        stack.push((u32_u(index), fixup_offset));
                        UNSET_POINTER
                    }
                    MutableTreeNodePointer::OffsetOnDisk(offset) => offset,
                };
                let edge_value = TreeEdge {
                    label_offset: edge.label_offset.into(),
                    label_length: label_length.into(),
                    node_pointer: node_pointer.into(),
                };
                buffer.extend_from_slice(edge_value.as_bytes());
            }
        }
        assert_eq!(buffer.len(), additional_size);
        let old_unused_bytes = match self.base {
            Some(file_index) => file_index.tree_unused_bytes,
            None => 0,
        };
        let additional_unused_bytes = // (comment to improve formatting)
            self.num_copied_nodes * std::mem::size_of::<TreeNodeHeader>()
            + self.num_copied_edges * std::mem::size_of::<TreeEdge>()
            + self.num_copied_tokens * std::mem::size_of::<FileToken>();
        let final_unused_bytes: u32 =
            old_unused_bytes + u_u32(additional_unused_bytes);
        assert!(final_unused_bytes <= old_size);
        SerializedMutableTree {
            bytes: buffer,
            tree_root_pointer: old_size,
            tree_file_size: final_size,
            tree_unused_bytes: final_unused_bytes,
        }
    }
}
