use core::str;
use std::{collections::hash_map::Entry, ffi::OsString};

use format_bytes::format_bytes;
use hg::{
    encoding::Encoder,
    operations::{
        annotate, AnnotateOptions, AnnotateOutput, ChangesetAnnotation,
    },
    revlog::changelog::Changelog,
    utils::strings::CleanWhitespace,
    FastHashMap, Revision,
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
            clap::Arg::new("no-follow")
                .help("don't follow copies and renames")
                .long("no-follow")
                .action(clap::ArgAction::SetTrue),
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
            CleanWhitespace::All
        } else if args.get_flag("ignore-space-change") {
            CleanWhitespace::Collapse
        } else if args.get_flag("ignore-space-at-eol") {
            CleanWhitespace::AtEol
        } else {
            // We ignore the --ignore-blank-lines flag (present for consistency
            // with other commands) since it has no effect on annotate.
            CleanWhitespace::None
        },
    };

    let mut include = Include {
        user: args.get_flag("user"),
        number: args.get_flag("number"),
        changeset: args.get_flag("changeset"),
        date: args.get_flag("date"),
        file: args.get_flag("file"),
        line_number: args.get_flag("line-number"),
    };
    if !(include.user || include.file || include.date || include.changeset) {
        include.number = true;
    }
    if include.line_number && !(include.number || include.changeset) {
        return Err(CommandError::abort(
            "at least one of -n/-c is required for -l",
        ));
    }

    let verbosity = match (args.get_flag("quiet"), args.get_flag("verbose")) {
        (false, false) => Verbosity::Default,
        (true, false) => Verbosity::Quiet,
        (false, true) => Verbosity::Verbose,
        (true, true) => unreachable!(),
    };

    let changelog = repo.changelog()?;
    let mut formatter = Formatter::new(
        &changelog,
        invocation.ui.encoder(),
        include,
        verbosity,
    );
    let mut stdout = invocation.ui.stdout_buffer();
    for path in files {
        match annotate(repo, &path, rev, options)? {
            AnnotateOutput::Text(text) => {
                let annotations = formatter.format(text.annotations)?;
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
                let short = changelog.node_from_rev(rev).short();
                return Err(CommandError::abort(format!(
                    "{path}: no such file in rev {short:x}",
                )));
            }
        }
    }
    stdout.flush()?;

    Ok(())
}

struct Formatter<'a> {
    changelog: &'a Changelog,
    encoder: &'a Encoder,
    include: Include,
    verbosity: Verbosity,
    cache: FastHashMap<Revision, ChangesetData>,
}

#[derive(Copy, Clone)]
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

#[derive(Copy, Clone)]
enum Verbosity {
    Quiet,
    Default,
    Verbose,
}

#[derive(Default)]
struct ChangesetData {
    user: Option<Vec<u8>>,
    changeset: Option<Vec<u8>>,
    date: Option<Vec<u8>>,
}

impl ChangesetData {
    fn create(
        revision: Revision,
        changelog: &Changelog,
        include: Include,
        verbosity: Verbosity,
    ) -> Result<ChangesetData, CommandError> {
        let mut result = ChangesetData::default();
        if !(include.user || include.changeset || include.date) {
            return Ok(result);
        }
        let entry = changelog.entry(revision)?;
        let data = entry.data()?;
        if include.user {
            let user = match verbosity {
                Verbosity::Verbose => data.user(),
                _ => hg::utils::strings::short_user(data.user()),
            };
            result.user = Some(user.to_vec());
        }
        if include.changeset {
            let changeset = entry.as_revlog_entry().node().short();
            result.changeset = Some(format!("{:x}", changeset).into_bytes());
        }
        if include.date {
            let date = data.timestamp()?.format(match verbosity {
                Verbosity::Quiet => "%Y-%m-%d",
                _ => "%a %b %d %H:%M:%S %Y %z",
            });
            result.date = Some(format!("{}", date).into_bytes());
        }
        Ok(result)
    }
}

impl<'a> Formatter<'a> {
    fn new(
        changelog: &'a Changelog,
        encoder: &'a Encoder,
        include: Include,
        verbosity: Verbosity,
    ) -> Self {
        let cache = FastHashMap::default();
        Self {
            changelog,
            encoder,
            include,
            verbosity,
            cache,
        }
    }

    fn format(
        &mut self,
        annotations: Vec<ChangesetAnnotation>,
    ) -> Result<Vec<Vec<u8>>, CommandError> {
        let mut lines: Vec<Vec<Vec<u8>>> =
            Vec::with_capacity(annotations.len());
        let num_fields = self.include.count();
        let mut widths = vec![0usize; num_fields];
        for annotation in annotations {
            let revision = annotation.revision;
            let data = match self.cache.entry(revision) {
                Entry::Occupied(occupied) => occupied.into_mut(),
                Entry::Vacant(vacant) => vacant.insert(ChangesetData::create(
                    revision,
                    self.changelog,
                    self.include,
                    self.verbosity,
                )?),
            };
            let mut fields = Vec::with_capacity(num_fields);
            if let Some(user) = &data.user {
                fields.push(user.clone());
            }
            if self.include.number {
                fields.push(format_bytes!(b"{}", revision));
            }
            if let Some(changeset) = &data.changeset {
                fields.push(changeset.clone());
            }
            if let Some(date) = &data.date {
                fields.push(date.clone());
            }
            if self.include.file {
                fields.push(annotation.path.into_vec());
            }
            if self.include.line_number {
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
                        let colon =
                            self.include.line_number && i == num_fields - 1;
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
