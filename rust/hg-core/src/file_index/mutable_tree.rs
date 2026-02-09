//! This module implements an in-memory prefix tree as a layer on top of the
//! tree file from [`super::on_disk`]. It is used for building the tree file
//! from scratch and for appending to it.

use bytes_cast::BytesCast as _;
use itertools::Itertools;

use super::FileToken;
use super::on_disk::Error;
use super::on_disk::FileIndexView;
use super::on_disk::LabelPosition;
use super::on_disk::TreeNode;
use crate::file_index::on_disk::NodePointer;
use crate::file_index::on_disk::PointerOrToken;
use crate::file_index::on_disk::TaggedNodePointer;
use crate::file_index::on_disk::TreeNodeHeader;
use crate::utils::hg_path::HgPath;
use crate::utils::strings::common_prefix_length;
use crate::utils::u_u32;
use crate::utils::u32_u;

/// Mutable version of [`TreeNode`].
struct MutableTreeNode<'a> {
    /// See [`TreeNode::token`].
    token: FileToken,
    /// The label of this node.
    label: &'a [u8],
    /// Children of this node.
    children: Vec<MutableTreeChild>,
}

impl MutableTreeNode<'_> {
    /// Like [`TreeNode::find_child`] but returns the child as well.
    fn find_child(&self, char: u8) -> Option<(usize, &MutableTreeChild)> {
        self.children.iter().find_position(|child| child.char == char)
    }
}

/// A child of a [`MutableTreeNode`].
#[derive(Copy, Clone)]
struct MutableTreeChild {
    /// First character of the child node's label.
    char: u8,
    /// Pointer to the child node.
    pointer: MutableTreeNodePointer,
}

/// A pointer to a tree node either in memory or on disk.
#[derive(Copy, Clone)]
enum MutableTreeNodePointer {
    /// Index of a node in [`MutableTree::nodes`].
    Index(u32),
    /// Offset of an existing node in the tree file of [`MutableTree::base`].
    OffsetOnDisk(u32),
}

impl<'a> MutableTreeNode<'a> {
    /// Creates a leaf [`MutableTreeNode`].
    fn leaf(token: FileToken, label: &'a [u8]) -> Self {
        Self { token, label, children: Vec::new() }
    }
}

/// An in-memory prefix tree that can be serialized to a tree file.
pub struct MutableTree<'a> {
    /// Base file index we are appending to.
    base: FileIndexView<'a>,
    /// Additional nodes. The first element is the new root.
    nodes: Vec<MutableTreeNode<'a>>,
    /// Number of internal (non-leaf) nodes.
    num_internal_nodes: usize,
    /// Number of nodes copied from [`Self::base`].
    num_copied_nodes: usize,
    /// Number of internal (non-leaf) nodes copied from [`Self::base`].
    /// Does not include copied leaf nodes that later gain children.
    num_copied_internal_nodes: usize,
    /// Number of children copied from [`Self::base`].
    num_copied_children: usize,
    /// Number of new paths added.
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

/// How to serialize a [`MutableTree`].
#[derive(Copy, Clone, PartialEq, Eq)]
pub enum SerializeMode {
    /// Produce bytes for appending to a (possibly empty) base tree file.
    Append,
    /// Produce bytes for creating a new tree file. This includes all the nodes
    /// from the base tree, vacuumed to eliminate all unused bytes.
    Vacuum,
}

impl<'a> MutableTree<'a> {
    /// Creates a new [`MutableTree`] for writing a new tree file.
    pub fn empty(num_paths_estimate: usize) -> Result<Self, Error> {
        Self::new(FileIndexView::empty(), num_paths_estimate)
    }

    /// Creates a new [`MutableTree`] for appending to `base`.
    pub fn with_base(
        base: FileIndexView<'a>,
        num_new_paths_estimate: usize,
    ) -> Result<Self, Error> {
        Self::new(base, num_new_paths_estimate)
    }

    fn new(
        base: FileIndexView<'a>,
        num_new_paths_estimate: usize,
    ) -> Result<Self, Error> {
        let mut tree = Self::new_impl(base, num_new_paths_estimate)?;
        tree.copy_node(base.root, 0)?;
        if base.tree_file_size == 0 {
            tree.num_copied_nodes = 0;
            tree.num_copied_internal_nodes = 0;
        }
        Ok(tree)
    }

    fn new_impl(
        base: FileIndexView<'a>,
        num_new_paths_estimate: usize,
    ) -> Result<Self, Error> {
        Ok(Self {
            base,
            // Estimate the number of new nodes to be 2x the number of paths.
            nodes: Vec::with_capacity(num_new_paths_estimate * 2),
            num_internal_nodes: 0,
            num_copied_nodes: 0,
            num_copied_internal_nodes: 0,
            num_copied_children: 0,
            num_paths_added: 0,
        })
    }

    /// Returns the number of distinct tokens in this tree and its base.
    pub fn token_count(&self) -> usize {
        self.base.token_count() + self.num_paths_added
    }

    /// Copies the node if it is on disk. Returns the node's index and label.
    fn maybe_copy_node(
        &mut self,
        pointer: MutableTreeNodePointer,
        position: LabelPosition,
    ) -> Result<(usize, &[u8]), Error> {
        match pointer {
            MutableTreeNodePointer::Index(index) => {
                let index = u32_u(index);
                Ok((index, self.nodes[index].label))
            }
            MutableTreeNodePointer::OffsetOnDisk(offset) => {
                self.copy_node(self.base.read_node(offset)?, position)
            }
        }
    }

    /// Copies the node at the given pointer and label position into a new
    /// [`MutableTreeNode`], and returns its index and label.
    fn copy_node(
        &mut self,
        node: TreeNode<'a>,
        position: LabelPosition,
    ) -> Result<(usize, &[u8]), Error> {
        self.num_copied_nodes += 1;
        if !node.child_ptrs.is_empty() {
            self.num_internal_nodes += 1;
            self.num_copied_internal_nodes += 1;
            self.num_copied_children += node.child_ptrs.len();
        }
        let metadata = self.base.read_metadata(node.token)?;
        let span = FileIndexView::label_span(node, metadata, position);
        let label = self.base.read_span(span)?;
        let mutable_node =
            MutableTreeNode { token: node.token, label, children: Vec::new() };
        let index = self.nodes.len();
        // Push node first, then children, so root node stays at index 0.
        self.nodes.push(mutable_node);
        self.nodes[index].children = self.copy_node_children(node, position)?;
        Ok((index, label))
    }

    /// Converts the children of a node to [`MutableTreeChild`]. If any are
    /// [`PointerOrToken::Token`], pushes them to [`Self::nodes`].
    fn copy_node_children(
        &mut self,
        node: TreeNode<'a>,
        position: LabelPosition,
    ) -> Result<Vec<MutableTreeChild>, Error> {
        let position = position + node.label_length as usize;
        node.child_chars
            .iter()
            .zip(node.child_ptrs)
            .map(|(&char, &ptr)| {
                Ok(MutableTreeChild {
                    char,
                    pointer: match ptr.unpack() {
                        PointerOrToken::Pointer(ptr) => {
                            MutableTreeNodePointer::OffsetOnDisk(ptr)
                        }
                        PointerOrToken::Token(token) => {
                            let (node, _) =
                                self.base.read_leaf_node(token, position)?;
                            let (index, _) = self.copy_node(node, position)?;
                            MutableTreeNodePointer::Index(u_u32(index))
                        }
                    },
                })
            })
            .collect()
    }

    /// Inserts `(path, token)` into the tree.
    /// Path must be nonempty, not contain "\x00", and not be already inserted.
    pub fn insert(
        &mut self,
        path: &'a HgPath,
        token: FileToken,
    ) -> Result<(), Error> {
        assert!(!path.is_empty());
        let path = path.as_bytes();
        let mut position: LabelPosition = 0;
        let mut node_index = 0;
        while let Some((i, child)) =
            self.nodes[node_index].find_child(path[position])
        {
            let (child_index, label) =
                self.maybe_copy_node(child.pointer, position)?;
            let child_pointer =
                MutableTreeNodePointer::Index(u_u32(child_index));
            let remainder = &path[position..];
            let length = common_prefix_length(remainder, label);
            let label_len = label.len(); // work around lifetime issues
            if length != label_len {
                let child_label = &mut self.nodes[child_index].label;
                *child_label = &child_label[length..];
                let intermediate_node = MutableTreeNode {
                    token,
                    label: &remainder[..length],
                    children: vec![MutableTreeChild {
                        char: child_label[0],
                        pointer: child_pointer,
                    }],
                };
                let intermediate_index = self.nodes.len();
                self.nodes.push(intermediate_node);
                self.num_internal_nodes += 1;
                self.nodes[node_index].children[i].pointer =
                    MutableTreeNodePointer::Index(u_u32(intermediate_index));
                node_index = intermediate_index;
                position += length;
                break;
            }
            self.nodes[node_index].children[i].pointer = child_pointer;
            node_index = child_index;
            position += label_len;
            if position == path.len() {
                break;
            }
        }
        let mut remainder = &path[position..];
        while !remainder.is_empty() {
            let clamped_length: u8 =
                remainder.len().try_into().unwrap_or(u8::MAX);
            let (label, after_label) =
                remainder.split_at(clamped_length as usize);
            remainder = after_label;
            let new_node_index = self.nodes.len();
            let node = &mut self.nodes[node_index];
            node_index = new_node_index;
            if node.children.is_empty() {
                self.num_internal_nodes += 1;
            }
            node.children.push(MutableTreeChild {
                char: label[0],
                pointer: MutableTreeNodePointer::Index(u_u32(new_node_index)),
            });
            // We need edges.len() to fit in TreeNodeHeader::num_children which
            // is a u8. There can be at most 256 because a 257th would share at
            // least 1 byte prefix with another edge and so never get created.
            // Since hg paths do not allow "\x00", "\r", and "\n", the maximum
            // is actually 253. Assert on 255 because that's all we rely on.
            assert!(node.children.len() <= 255);
            self.nodes.push(MutableTreeNode::leaf(token, label));
        }
        self.nodes[node_index].token = token;
        self.num_paths_added += 1;
        Ok(())
    }

    /// Serializes the tree according to `mode`, producing bytes ready to be
    /// written to disk. Returns `None` if there is nothing to write.
    pub fn serialize(
        &self,
        mode: SerializeMode,
    ) -> Result<Option<SerializedMutableTree>, Error> {
        assert!(!self.nodes.is_empty(), "must have root node");
        assert_eq!(self.nodes[0].token, FileToken::root());
        let mode = match self.base.tree_file_size {
            // Always treat the first write as an append.
            0 => SerializeMode::Append,
            _ => mode,
        };
        let vacuum = mode == SerializeMode::Vacuum;
        let need_to_write = self.num_paths_added > 0 || vacuum;
        if !need_to_write {
            return Ok(None);
        }
        // Terminology: final = old + additional = old + (copied + fresh).
        let old_size = u32_u(self.base.tree_file_size);
        let old_unused_bytes = u32_u(self.base.tree_unused_bytes);
        let num_fresh_nodes = self.nodes.len() - self.num_copied_nodes;
        let root_is_fresh = self.num_copied_nodes == 0;
        // There is a fresh child for every fresh node except the root.
        let num_fresh_children = if root_is_fresh {
            num_fresh_nodes - 1
        } else {
            num_fresh_nodes
        };
        let num_additional_children =
            self.num_copied_children + num_fresh_children;
        const NODE_SIZE: usize = std::mem::size_of::<TreeNodeHeader>();
        const CHILD_SIZE: usize = std::mem::size_of::<u8>()
            + std::mem::size_of::<TaggedNodePointer>();
        let additional_size = self.num_internal_nodes * NODE_SIZE
            + num_additional_children * CHILD_SIZE;
        let final_size = if vacuum {
            let num_fresh_internal_nodes =
                self.num_internal_nodes - self.num_copied_internal_nodes;
            old_size.saturating_sub(old_unused_bytes)
                + num_fresh_internal_nodes * NODE_SIZE
                + num_fresh_children * CHILD_SIZE
        } else {
            old_size + additional_size
        };
        let capacity = if vacuum { final_size } else { additional_size };
        let mut buffer = Vec::<u8>::with_capacity(capacity);
        let base_offset = if vacuum { 0 } else { old_size };
        const N: usize = std::mem::size_of::<NodePointer>();
        const UNSET_POINTER: [u8; N] = [0xff; N];
        // Stack of (pointer in tree file, incoming edge offset).
        let mut ptr_stack = vec![];
        // Stack of (index in self.nodes, incoming edge offset).
        let mut idx_stack = vec![(0, 0)];
        while let Some((index, fixup_offset)) = idx_stack.pop() {
            if index != 0 {
                // Fix up the incoming pointer.
                let current_offset: [u8; N] =
                    u_u32(base_offset + buffer.len()).to_be_bytes();
                let dest = &mut buffer[fixup_offset..fixup_offset + N];
                debug_assert_eq!(dest, UNSET_POINTER);
                dest.copy_from_slice(&current_offset);
            }
            let node = &self.nodes[index];
            let num_children = node.children.len();
            let num_children: u8 =
                num_children.try_into().expect("num children should fit in u8");
            let label_length = node.label.len();
            let label_length: u8 =
                label_length.try_into().expect("label length should fit in u8");
            let header =
                TreeNodeHeader::new(node.token, label_length, num_children);
            buffer.extend_from_slice(header.as_bytes());
            for child in &node.children {
                buffer.push(child.char);
            }
            for child in &node.children {
                let fixup_offset = buffer.len();
                match child.pointer {
                    MutableTreeNodePointer::Index(index) => {
                        let child_node = &self.nodes[index as usize];
                        if child_node.children.is_empty() {
                            let token = PointerOrToken::Token(child_node.token);
                            buffer.extend_from_slice(token.pack().as_bytes());
                        } else {
                            idx_stack.push((u32_u(index), fixup_offset));
                            buffer.extend_from_slice(&UNSET_POINTER);
                        }
                    }
                    MutableTreeNodePointer::OffsetOnDisk(offset) => {
                        if vacuum {
                            ptr_stack.push((offset, fixup_offset));
                            buffer.extend_from_slice(&UNSET_POINTER);
                        } else {
                            buffer.extend_from_slice(&offset.to_be_bytes())
                        }
                    }
                };
            }
        }
        assert_eq!(buffer.len(), additional_size);
        if !vacuum {
            let additional_unused_bytes = // (comment to improve formatting)
                self.num_copied_internal_nodes * NODE_SIZE
                + self.num_copied_children * CHILD_SIZE;
            let final_unused_bytes = old_unused_bytes + additional_unused_bytes;
            assert!(final_unused_bytes <= old_size);
            return Ok(Some(SerializedMutableTree {
                bytes: buffer,
                tree_root_pointer: u_u32(old_size),
                tree_file_size: u_u32(final_size),
                tree_unused_bytes: u_u32(final_unused_bytes),
            }));
        }
        let tree_file = self.base.tree_file;
        while let Some((ptr, fixup_offset)) = ptr_stack.pop() {
            // Fix up the incoming pointer.
            let current_offset: [u8; N] = u_u32(buffer.len()).to_be_bytes();
            let dest = &mut buffer[fixup_offset..fixup_offset + N];
            debug_assert_eq!(dest, UNSET_POINTER);
            dest.copy_from_slice(&current_offset);
            let slice = tree_file
                .get(u32_u(ptr)..)
                .ok_or(Error::TreeFileOutOfBounds)?;
            let (header, _) = TreeNodeHeader::from_bytes(slice)
                .or(Err(Error::TreeFileEof))?;
            let num_children = header.num_children as usize;
            let (header_and_chars, rest) = slice
                .split_at_checked(
                    std::mem::size_of::<TreeNodeHeader>() + num_children,
                )
                .ok_or(Error::TreeFileEof)?;
            buffer.extend_from_slice(header_and_chars);
            let (child_ptrs, _) =
                TaggedNodePointer::slice_from_bytes(rest, num_children)
                    .or(Err(Error::TreeFileEof))?;
            for &value in child_ptrs {
                match value.unpack() {
                    PointerOrToken::Pointer(child_ptr) => {
                        let fixup_offset = buffer.len();
                        ptr_stack.push((child_ptr, fixup_offset));
                        buffer.extend_from_slice(&UNSET_POINTER);
                    }
                    PointerOrToken::Token(_) => {
                        buffer.extend_from_slice(value.as_bytes())
                    }
                }
            }
        }
        // Only debug assert because this relies on the tree_unused_bytes in the
        // docket being accurate. It should be, but it's not worth an assertion
        // failure in production if it isn't.
        let actual_final_size = buffer.len();
        debug_assert_eq!(actual_final_size, final_size);
        Ok(Some(SerializedMutableTree {
            bytes: buffer,
            tree_root_pointer: 0,
            tree_file_size: u_u32(actual_final_size),
            tree_unused_bytes: 0,
        }))
    }
}
