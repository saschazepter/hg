use core::str;
use std::{cell::Ref, collections::hash_map::Entry, ffi::OsString};

use chrono::{DateTime, FixedOffset, Local};
use format_bytes::format_bytes;
use hg::{
    encoding::Encoder,
    errors::IoResultExt as _,
    operations::{
        annotate, AnnotateOptions, AnnotateOutput, ChangesetAnnotation,
    },
    repo::Repo,
    revlog::{changelog::Changelog, RevisionOrWdir},
    utils::{hg_path::HgPath, strings::CleanWhitespace},
    FastHashMap, Node, Revision,
};

use crate::{error::CommandError, utils::path_utils::resolve_file_args};

pub const HELP_TEXT: &str = "
show changeset information by line for each file
";

pub fn args() -> clap::Command {
    clap::command!("annotate")
        .alias("blame")
        .arg(
            clap::Arg::new("files")
                .help("files to annotate")
                .required(true)
                .num_args(1..)
                .value_name("FILE")
                .value_parser(clap::value_parser!(OsString)),
        )
        .arg(
            clap::Arg::new("rev")
                .help("annotate the specified revision")
                .short('r')
                .long("rev")
                .value_name("REV")
                .default_value("."),
        )
        .arg(
            clap::Arg::new("follow")
                .help(
                    "follow copies/renames and list the filename (DEPRECATED)",
                )
                .long("follow")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("no-follow")
                .help("don't follow copies and renames")
                .long("no-follow")
                .action(clap::ArgAction::SetTrue)
                .conflicts_with("follow"),
        )
        .arg(
            clap::Arg::new("text")
                .help("treat all files as text")
                .short('a')
                .long("text")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("user")
                .help("list the author (long with -v)")
                .short('u')
                .long("user")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("number")
                .help("list the revision number (default)")
                .short('n')
                .long("number")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("changeset")
                .help("list the changeset")
                .short('c')
                .long("changeset")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("date")
                .help("list the date (short with -q)")
                .short('d')
                .long("date")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("file")
                .help("list the filename")
                .short('f')
                .long("file")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("line-number")
                .help("show the line number at the first appearance")
                .short('l')
                .long("line-number")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("quiet")
                .help("show short date for -d")
                .short('q')
                .long("quiet")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("verbose")
                .help("show full username for -u")
                .short('v')
                .long("verbose")
                .action(clap::ArgAction::SetTrue)
                .conflicts_with("quiet"),
        )
        .arg(
            clap::Arg::new("ignore-all-space")
                .help("ignore white space when comparing lines")
                .short('w')
                .long("ignore-all-space")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("ignore-space-change")
                .help("ignore changes in the amount of white space")
                .short('b')
                .long("ignore-space-change")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("ignore-blank-lines")
                .help("ignore changes whose lines are all blank")
                .short('B')
                .long("ignore-blank-lines")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("ignore-space-at-eol")
                .help("ignore changes in whitespace at EOL")
                .short('Z')
                .long("ignore-space-at-eol")
                .action(clap::ArgAction::SetTrue),
        )
        .about(HELP_TEXT)
}

#[tracing::instrument(level = "debug", skip_all, name = "rhg annotate")]
pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let config = invocation.config;
    if config.has_non_empty_section(b"annotate") {
        return Err(CommandError::unsupported(
            "rhg annotate does not support any [annotate] configs",
        ));
    }

    let repo = invocation.repo?;
    let args = invocation.subcommand_args;

    let rev = args.get_one::<String>("rev").expect("rev has a default");
    let rev = hg::revset::resolve_single(rev, repo)?;

    let files = match args.get_many::<OsString>("files") {
        None => vec![],
        Some(files) => resolve_file_args(repo, files)?,
    };

    let options = AnnotateOptions {
        treat_binary_as_text: args.get_flag("text"),
        follow_copies: !args.get_flag("no-follow"),
        whitespace: if args.get_flag("ignore-all-space") {
            Some(CleanWhitespace::All)
        } else if args.get_flag("ignore-space-change") {
            Some(CleanWhitespace::Collapse)
        } else if args.get_flag("ignore-space-at-eol") {
            Some(CleanWhitespace::AtEol)
        } else {
            // We ignore the --ignore-blank-lines flag (present for consistency
            // with other commands) since it has no effect on annotate.
            None
        },
    };

    let mut include = Include {
        user: args.get_flag("user"),
        number: args.get_flag("number"),
        changeset: args.get_flag("changeset"),
        date: args.get_flag("date"),
        file: args.get_flag("file") || args.get_flag("follow"),
        line_number: args.get_flag("line-number"),
    };
    if !(include.user || include.file || include.date || include.changeset) {
        include.number = true;
    }
    if include.line_number && !(include.number || include.changeset) {
        return Err(CommandError::abort(
            "abort: at least one of -n/-c is required for -l",
        ));
    }

    let verbosity = match (args.get_flag("quiet"), args.get_flag("verbose")) {
        (false, false) => Verbosity::Default,
        (true, false) => Verbosity::Quiet,
        (false, true) => Verbosity::Verbose,
        (true, true) => unreachable!(),
    };

    let wdir_config = if rev.is_wdir() {
        let user = config.username()?;
        Some(WdirConfig { user })
    } else {
        None
    };

    let mut formatter = Formatter::new(
        repo,
        invocation.ui.encoder(),
        FormatterConfig {
            include,
            verbosity,
            wdir_config,
        },
    )?;
    let mut stdout = invocation.ui.stdout_buffer();
    for path in files {
        match annotate(repo, &path, rev, options)? {
            AnnotateOutput::Text(text) => {
                let annotations = formatter.format(&path, text.annotations)?;
                for (annotation, line) in annotations.iter().zip(&text.lines) {
                    stdout.write_all(&format_bytes!(
                        b"{}: {}", annotation, line
                    ))?;
                }
                if let Some(line) = text.lines.last() {
                    if !line.ends_with(b"\n") {
                        stdout.write_all(b"\n")?;
                    }
                }
            }
            AnnotateOutput::Binary => {
                stdout.write_all(&format_bytes!(
                    b"{}: binary file\n",
                    path.as_bytes()
                ))?;
            }
            AnnotateOutput::NotFound => {
                return Err(CommandError::abort(match rev.exclude_wdir() {
                    Some(rev) => {
                        let short =
                            repo.changelog()?.node_from_rev(rev).short();
                        format!("abort: {path}: no such file in rev {short:x}",)
                    }
                    None => {
                        format!("abort: {path}: No such file or directory")
                    }
                }));
            }
        }
    }
    stdout.flush()?;

    Ok(())
}

struct Formatter<'a> {
    repo: &'a Repo,
    changelog: Ref<'a, Changelog>,
    dirstate_p1: Revision,
    encoder: &'a Encoder,
    config: FormatterConfig,
    cache: FastHashMap<RevisionOrWdir, ChangesetData>,
}

struct FormatterConfig {
    include: Include,
    verbosity: Verbosity,
    wdir_config: Option<WdirConfig>,
}

struct Include {
    user: bool,
    number: bool,
    changeset: bool,
    date: bool,
    file: bool,
    line_number: bool,
}

impl Include {
    fn count(&self) -> usize {
        // Rust guarantees false is 0 and true is 1.
        self.user as usize
            + self.number as usize
            + self.changeset as usize
            + self.date as usize
            + self.file as usize
            + self.line_number as usize
    }
}

enum Verbosity {
    Quiet,
    Default,
    Verbose,
}

/// Information to use for lines that changed in the working directory.
struct WdirConfig {
    user: Vec<u8>,
}

#[derive(Default)]
struct ChangesetData {
    user: Option<Vec<u8>>,
    changeset: Option<Vec<u8>>,
    date: Option<Vec<u8>>,
}

/// Whether the "+" sigil calculation is for --number or --changeset.
#[derive(PartialEq, Eq)]
enum SigilFor {
    Number,
    Changeset,
}

impl ChangesetData {
    fn create(
        revision: RevisionOrWdir,
        path: &HgPath,
        repo: &Repo,
        changelog: &Changelog,
        config: &FormatterConfig,
    ) -> Result<Self, CommandError> {
        let include = &config.include;
        if !(include.user || include.changeset || include.date) {
            return Ok(Self::default());
        }
        match revision.exclude_wdir() {
            Some(revision) => {
                let entry = changelog.entry(revision)?;
                let data = entry.data()?;
                let node = *entry.as_revlog_entry().node();
                Ok(Self::new(data.user(), node, data.timestamp()?, config))
            }
            None => {
                let p1 = repo.dirstate_parents()?.p1;
                let fs_path = hg::utils::hg_path::hg_path_to_path_buf(path)?;
                let meta =
                    repo.working_directory_vfs().symlink_metadata(&fs_path)?;
                let mtime = meta.modified().when_reading_file(&fs_path)?;
                let mtime = DateTime::<Local>::from(mtime).fixed_offset();
                let user =
                    &config.wdir_config.as_ref().expect("should be set").user;
                Ok(Self::new(user, p1, mtime, config))
            }
        }
    }

    fn new(
        user: &[u8],
        changeset: Node,
        date: DateTime<FixedOffset>,
        config: &FormatterConfig,
    ) -> Self {
        let mut result = ChangesetData::default();
        if config.include.user {
            let user = match config.verbosity {
                Verbosity::Verbose => user,
                _ => hg::utils::strings::short_user(user),
            };
            result.user = Some(user.to_vec());
        }
        if config.include.changeset {
            result.changeset =
                Some(format!("{:x}", changeset.short()).into_bytes());
        }
        if config.include.date {
            let date = date.format(match config.verbosity {
                Verbosity::Quiet => "%Y-%m-%d",
                _ => "%a %b %d %H:%M:%S %Y %z",
            });
            result.date = Some(format!("{}", date).into_bytes());
        }
        result
    }
}

impl<'a> Formatter<'a> {
    fn new(
        repo: &'a Repo,
        encoder: &'a Encoder,
        config: FormatterConfig,
    ) -> Result<Self, CommandError> {
        let changelog = repo.changelog()?;
        let dirstate_p1 =
            changelog.rev_from_node(repo.dirstate_parents()?.p1.into())?;
        Ok(Self {
            repo,
            changelog,
            dirstate_p1,
            encoder,
            config,
            cache: FastHashMap::default(),
        })
    }

    fn format(
        &mut self,
        path: &HgPath,
        annotations: Vec<ChangesetAnnotation>,
    ) -> Result<Vec<Vec<u8>>, CommandError> {
        let mut lines: Vec<Vec<Vec<u8>>> =
            Vec::with_capacity(annotations.len());
        let num_fields = self.config.include.count();
        let mut widths = vec![0usize; num_fields];
        // Clear the wdir cache entry, otherwise `rhg annotate --date f1 f2`
        // would use f1's mtime for lines in f2 attributed to wdir.
        self.cache.remove(&RevisionOrWdir::wdir());
        for annotation in annotations {
            let rev = annotation.revision;
            let data = match self.cache.entry(rev) {
                Entry::Occupied(occupied) => occupied.into_mut(),
                Entry::Vacant(vacant) => vacant.insert(ChangesetData::create(
                    rev,
                    path,
                    self.repo,
                    &self.changelog,
                    &self.config,
                )?),
            };
            let mut fields = Vec::with_capacity(num_fields);
            if let Some(user) = &data.user {
                fields.push(user.clone());
            }
            if self.config.include.number {
                let number = rev.exclude_wdir().unwrap_or(self.dirstate_p1);
                let sigil = fmt_sigil(&self.config, rev, SigilFor::Number);
                fields.push(format_bytes!(b"{}{}", number, sigil));
            }
            if let Some(changeset) = &data.changeset {
                let sigil = fmt_sigil(&self.config, rev, SigilFor::Changeset);
                fields.push(format_bytes!(b"{}{}", changeset, sigil));
            }
            if let Some(date) = &data.date {
                fields.push(date.clone());
            }
            if self.config.include.file {
                fields.push(annotation.path.into_vec());
            }
            if self.config.include.line_number {
                fields.push(format_bytes!(b"{}", annotation.line_number));
            }
            for (field, width) in fields.iter().zip(widths.iter_mut()) {
                *width = std::cmp::max(
                    *width,
                    self.encoder.column_width_bytes(field),
                );
            }
            lines.push(fields);
        }
        let total_width = widths.iter().sum::<usize>() + num_fields - 1;
        Ok(lines
            .iter()
            .map(|fields| {
                let mut bytes = Vec::with_capacity(total_width);
                for (i, (field, width)) in
                    fields.iter().zip(widths.iter()).enumerate()
                {
                    if i > 0 {
                        let colon = self.config.include.line_number
                            && i == num_fields - 1;
                        bytes.push(if colon { b':' } else { b' ' });
                    }
                    let padding =
                        width - self.encoder.column_width_bytes(field);
                    bytes.resize(bytes.len() + padding, b' ');
                    bytes.extend_from_slice(field);
                }
                bytes
            })
            .collect())
    }
}

fn fmt_sigil(
    config: &FormatterConfig,
    rev: RevisionOrWdir,
    which: SigilFor,
) -> &'static [u8] {
    // The "+" sigil is only used for '--rev wdir()'.
    if config.wdir_config.is_none() {
        return b"";
    };
    // With --number --changeset, put it after the changeset.
    if which == SigilFor::Number && config.include.changeset {
        return b"";
    }
    if rev.is_wdir() {
        b"+"
    } else {
        b" "
    }
}
