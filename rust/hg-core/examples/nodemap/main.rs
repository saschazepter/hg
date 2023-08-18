// Copyright 2019-2020 Georges Racinet <georges.racinet@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use hg::revlog::node::*;
use hg::revlog::nodemap::*;
use hg::revlog::*;
use memmap2::MmapOptions;
use rand::Rng;
use std::fs::File;
use std::io;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

mod index;
use index::Index;

fn mmap_index(repo_path: &Path) -> Index {
    let mut path = PathBuf::from(repo_path);
    path.extend([".hg", "store", "00changelog.i"].iter());
    Index::load_mmap(path)
}

fn mmap_nodemap(path: &Path) -> NodeTree {
    let file = File::open(path).unwrap();
    let mmap = unsafe { MmapOptions::new().map(&file).unwrap() };
    let len = mmap.len();
    NodeTree::load_bytes(Box::new(mmap), len)
}

/// Scan the whole index and create the corresponding nodemap file at `path`
fn create(index: &Index, path: &Path) -> io::Result<()> {
    let mut file = File::create(path)?;
    let start = Instant::now();
    let mut nm = NodeTree::default();
    for rev in 0..index.len() {
        let rev = Revision(rev as BaseRevision);
        nm.insert(index, index.node(rev).unwrap(), rev).unwrap();
    }
    eprintln!("Nodemap constructed in RAM in {:?}", start.elapsed());
    file.write_all(&nm.into_readonly_and_added_bytes().1)?;
    eprintln!("Nodemap written to disk");
    Ok(())
}

fn query(index: &Index, nm: &NodeTree, prefix: &str) {
    let start = Instant::now();
    let res = NodePrefix::from_hex(prefix).map(|p| nm.find_bin(index, p));
    println!("Result found in {:?}: {:?}", start.elapsed(), res);
}

fn bench(index: &Index, nm: &NodeTree, queries: usize) {
    let len = index.len() as u32;
    let mut rng = rand::thread_rng();
    let nodes: Vec<Node> = (0..queries)
        .map(|_| {
            *index
                .node(Revision((rng.gen::<u32>() % len) as BaseRevision))
                .unwrap()
        })
        .collect();
    if queries < 10 {
        let nodes_hex: Vec<String> =
            nodes.iter().map(|n| format!("{:x}", n)).collect();
        println!("Nodes: {:?}", nodes_hex);
    }
    let mut last: Option<Revision> = None;
    let start = Instant::now();
    for node in nodes.iter() {
        last = nm.find_bin(index, node.into()).unwrap();
    }
    let elapsed = start.elapsed();
    println!(
        "Did {} queries in {:?} (mean {:?}), last was {:x} with result {:?}",
        queries,
        elapsed,
        elapsed / (queries as u32),
        nodes.last().unwrap(),
        last
    );
}

fn main() {
    use clap::{Parser, Subcommand};

    #[derive(Parser)]
    #[command()]
    /// Nodemap pure Rust example
    struct App {
        // Path to the repository, always necessary for its index
        #[arg(short, long)]
        repository: PathBuf,
        // Path to the nodemap file, independent of REPOSITORY
        #[arg(short, long)]
        nodemap_file: PathBuf,
        #[command(subcommand)]
        command: Command,
    }

    #[derive(Subcommand)]
    enum Command {
        /// Create `NODEMAP_FILE` by scanning repository index
        Create,
        /// Query `NODEMAP_FILE` for `prefix`
        Query { prefix: String },
        /// Perform #`QUERIES` random successful queries on `NODEMAP_FILE`
        Bench { queries: usize },
    }

    let app = App::parse();

    let repo = &app.repository;
    let nm_path = &app.nodemap_file;

    let index = mmap_index(repo);
    let nm = mmap_nodemap(nm_path);

    match &app.command {
        Command::Create => {
            println!(
                "Creating nodemap file {} for repository {}",
                nm_path.display(),
                repo.display()
            );
            create(&index, Path::new(nm_path)).unwrap();
        }
        Command::Bench { queries } => {
            println!(
                "Doing {} random queries in nodemap file {} of repository {}",
                queries,
                nm_path.display(),
                repo.display()
            );
            bench(&index, &nm, *queries);
        }
        Command::Query { prefix } => {
            println!(
                "Querying {} in nodemap file {} of repository {}",
                prefix,
                nm_path.display(),
                repo.display()
            );
            query(&index, &nm, prefix);
        }
    }
}
