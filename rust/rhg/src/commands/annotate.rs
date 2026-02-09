use core::str;
use std::cell::Ref;
use std::collections::hash_map::Entry;
use std::ffi::OsString;

use chrono::DateTime;
use chrono::FixedOffset;
use chrono::Local;
use format_bytes::format_bytes;
use hg::FastHashMap;
use hg::Node;
use hg::Revision;
use hg::WORKING_DIRECTORY_HEX;
use hg::WORKING_DIRECTORY_REVISION;
use hg::encoding::Encoder;
use hg::errors::HgError;
use hg::errors::IoResultExt as _;
use hg::operations::AnnotateOptions;
use hg::operations::AnnotateOutput;
use hg::operations::ChangesetAnnotatedFile;
use hg::operations::annotate;
use hg::repo::Repo;
use hg::revlog::RevisionOrWdir;
use hg::revlog::changelog::Changelog;
use hg::utils::hg_path::HgPath;
use hg::utils::strings::CleanWhitespace;

use crate::error::CommandError;
use crate::ui::StdoutBuffer;
use crate::utils::path_utils::resolve_file_args;

pub const HELP_TEXT: &str = "
show changeset information by line for each file
";

pub fn args() -> clap::Command {
    clap::command!("annotate")
        .alias("blame")
        .args_override_self(true)
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
        .arg(
            clap::Arg::new("template")
                .help("display with template")
                .short('T')
                .long("template"),
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

    let template = match args.get_one::<String>("template") {
        None => Template::Default,
        Some(name) if name == "json" => Template::Json,
        _ => {
            return Err(CommandError::unsupported("only -Tjson is suppported"));
        }
    };

    let wdir_config = if rev.is_wdir() {
        let user = config.username()?;
        Some(WdirConfig { user })
    } else {
        None
    };

    let format_config =
        FormatConfig { template, include, verbosity, wdir_config };

    let file_results = files.iter().map(|path| -> FileResult {
        (path.as_ref(), annotate(repo, path, rev, options))
    });

    print_output(repo, invocation.ui, &format_config, rev, file_results)
}

struct FormatConfig {
    template: Template,
    include: Include,
    verbosity: Verbosity,
    wdir_config: Option<WdirConfig>,
}

enum Template {
    Default,
    Json,
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

/// Information that we can cache per changeset.
/// For [`Template::Json`], the values are JSON encoded.
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

type FileResult<'a> = (&'a HgPath, Result<AnnotateOutput, HgError>);

fn print_output<'a>(
    repo: &Repo,
    ui: &crate::Ui,
    config: &FormatConfig,
    rev: RevisionOrWdir,
    file_results: impl Iterator<Item = FileResult<'a>>,
) -> Result<(), CommandError> {
    let encoder = ui.encoder();
    let stdout = &mut ui.stdout_buffer();
    let dirstate_p1 =
        repo.changelog()?.rev_from_node(repo.dirstate_parents()?.p1.into())?;
    let mut cache = Cache::new(repo)?;
    match config.template {
        Template::Default => {
            for (path, output) in file_results {
                match output? {
                    AnnotateOutput::Text(file) => {
                        print_lines_default(
                            file,
                            config,
                            stdout,
                            encoder,
                            cache.for_path(path),
                            dirstate_p1,
                        )?;
                    }
                    AnnotateOutput::Binary => {
                        stdout.write_all(&format_bytes!(
                            b"{}: binary file\n",
                            path.as_bytes()
                        ))?;
                    }
                    AnnotateOutput::NotFound => {
                        return handle_not_found(repo, rev, path);
                    }
                }
            }
        }
        Template::Json => {
            stdout.write_all(b"[")?;
            let mut file_sep: &[u8] = b"\n";
            for (path, output) in file_results {
                stdout.write_all(file_sep)?;
                file_sep = b",\n";
                stdout.write_all(b" {\n")?;
                match output? {
                    AnnotateOutput::Text(file) => {
                        print_lines_json(
                            file,
                            config,
                            stdout,
                            cache.for_path(path),
                        )?;
                    }
                    AnnotateOutput::Binary => {}
                    AnnotateOutput::NotFound => {
                        return handle_not_found(repo, rev, path);
                    }
                }
                let path = json_string(path.as_bytes())?;
                stdout
                    .write_all(&format_bytes!(b"  \"path\": {}\n }", path))?;
            }
            stdout.write_all(b"\n]\n")?;
        }
    }
    stdout.flush()?;
    Ok(())
}

type Stdout<'a> = StdoutBuffer<'a, std::io::BufWriter<std::io::StdoutLock<'a>>>;

fn print_lines_default(
    file: ChangesetAnnotatedFile,
    config: &FormatConfig,
    stdout: &mut Stdout,
    encoder: &Encoder,
    mut cache: CacheForPath,
    dirstate_p1: Revision,
) -> Result<(), CommandError> {
    // Serialize the annotation fields (revision, user, etc.) for each line
    // and keep track of their maximum lengths so that we can align them.
    let mut field_lists: Vec<Vec<Vec<u8>>> =
        Vec::with_capacity(file.annotations.len());
    let num_fields = config.include.count();
    let mut widths = vec![0usize; num_fields];
    for annotation in file.annotations {
        let rev = annotation.revision;
        let data = cache.get_data(rev, config)?;
        let mut fields = Vec::with_capacity(num_fields);
        if let Some(user) = &data.user {
            fields.push(user.clone());
        }
        if config.include.number {
            let number = rev.exclude_wdir().unwrap_or(dirstate_p1);
            let sigil = fmt_sigil(config, rev, SigilFor::Number);
            fields.push(format_bytes!(b"{}{}", number, sigil));
        }
        if let Some(changeset) = &data.changeset {
            let sigil = fmt_sigil(config, rev, SigilFor::Changeset);
            fields.push(format_bytes!(b"{}{}", changeset, sigil));
        }
        if let Some(date) = &data.date {
            fields.push(date.clone());
        }
        if config.include.file {
            fields.push(annotation.path.into_vec());
        }
        if config.include.line_number {
            fields.push(format_bytes!(b"{}", annotation.line_number));
        }
        for (field, width) in fields.iter().zip(widths.iter_mut()) {
            *width = std::cmp::max(*width, encoder.column_width_bytes(field));
        }
        field_lists.push(fields);
    }
    // Print each line of the file prefixed by aligned annotations.
    let total_width = widths.iter().sum::<usize>() + num_fields - 1;
    for (fields, line) in field_lists.iter().zip(file.lines.iter()) {
        let mut annotation = Vec::with_capacity(total_width);
        for (i, (field, width)) in fields.iter().zip(widths.iter()).enumerate()
        {
            if i > 0 {
                let colon = config.include.line_number && i == num_fields - 1;
                annotation.push(if colon { b':' } else { b' ' });
            }
            let padding = width - encoder.column_width_bytes(field);
            annotation.resize(annotation.len() + padding, b' ');
            annotation.extend_from_slice(field);
        }
        stdout.write_all(&format_bytes!(b"{}: {}", annotation, line))?;
    }
    if let Some(line) = file.lines.last() {
        if !line.ends_with(b"\n") {
            stdout.write_all(b"\n")?;
        }
    }
    Ok(())
}

fn print_lines_json(
    file: ChangesetAnnotatedFile,
    config: &FormatConfig,
    stdout: &mut Stdout,
    mut cache: CacheForPath,
) -> Result<(), CommandError> {
    stdout.write_all(br#"  "lines": ["#)?;
    let mut line_sep: &[u8] = b"";
    for (annotation, line) in file.annotations.iter().zip(file.lines.iter()) {
        stdout.write_all(line_sep)?;
        line_sep = b", ";

        let mut property_sep: &[u8] = b"";
        let mut property = |key: &[u8], value: &[u8]| {
            let res = format_bytes!(br#"{}"{}": {}"#, property_sep, key, value);
            property_sep = b", ";
            res
        };

        stdout.write_all(b"{")?;
        let rev = annotation.revision;
        let data = cache.get_data(rev, config)?;
        if let Some(date_json) = &data.date {
            stdout.write_all(&property(b"date", date_json))?;
        }
        stdout.write_all(&property(b"line", &json_string(line)?))?;
        if config.include.line_number {
            let lineno = annotation.line_number.to_string();
            stdout.write_all(&property(b"lineno", lineno.as_bytes()))?;
        }
        if let Some(changeset_json) = &data.changeset {
            stdout.write_all(&property(b"node", changeset_json))?;
        }
        if config.include.file {
            let path = json_string(annotation.path.as_bytes())?;
            stdout.write_all(&property(b"path", &path))?;
        }
        if config.include.number {
            let number = match rev.exclude_wdir() {
                Some(rev) => rev.0,
                None => WORKING_DIRECTORY_REVISION.0,
            };
            stdout
                .write_all(&property(b"rev", number.to_string().as_bytes()))?;
        }
        if let Some(user_json) = &data.user {
            stdout.write_all(&property(b"user", user_json))?;
        }
        stdout.write_all(b"}")?;
    }
    stdout.write_all(b"],\n")?;
    Ok(())
}

fn handle_not_found(
    repo: &Repo,
    rev: RevisionOrWdir,
    path: &HgPath,
) -> Result<(), CommandError> {
    Err(CommandError::abort(match rev.exclude_wdir() {
        Some(rev) => {
            let short = repo.changelog()?.node_from_rev(rev).short();
            format!("abort: {path}: no such file in rev {short:x}",)
        }
        None => {
            format!("abort: {path}: No such file or directory")
        }
    }))
}

/// Returns the sigil to put after the revision number or changeset.
fn fmt_sigil(
    config: &FormatConfig,
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
    if rev.is_wdir() { b"+" } else { b" " }
}

/// A cache of [`ChangesetData`] for each changeset we've seen.
struct Cache<'a> {
    repo: &'a Repo,
    changelog: Ref<'a, Changelog>,
    map: FastHashMap<RevisionOrWdir, ChangesetData>,
}

impl<'a> Cache<'a> {
    fn new(repo: &'a Repo) -> Result<Self, CommandError> {
        Ok(Self { repo, changelog: repo.changelog()?, map: Default::default() })
    }

    fn for_path(&mut self, path: &'a HgPath) -> CacheForPath<'_, 'a> {
        CacheForPath { cache: self, path }
    }
}

/// [`Cache`] scoped to annotating a particular file.
struct CacheForPath<'a, 'b> {
    cache: &'a mut Cache<'b>,
    path: &'a HgPath,
}

impl CacheForPath<'_, '_> {
    fn get_data(
        &mut self,
        rev: RevisionOrWdir,
        config: &FormatConfig,
    ) -> Result<&ChangesetData, CommandError> {
        Ok(match self.cache.map.entry(rev) {
            Entry::Occupied(occupied) => occupied.into_mut(),
            Entry::Vacant(vacant) => vacant.insert(ChangesetData::create(
                rev,
                self.path,
                self.cache.repo,
                &self.cache.changelog,
                config,
            )?),
        })
    }
}

impl Drop for CacheForPath<'_, '_> {
    fn drop(&mut self) {
        // Clear the wdir cache entry, otherwise `rhg annotate --date f1 f2`
        // would use f1's mtime for lines in f2 attributed to wdir.
        self.cache.map.remove(&RevisionOrWdir::wdir());
    }
}

impl ChangesetData {
    fn create(
        revision: RevisionOrWdir,
        path: &HgPath,
        repo: &Repo,
        changelog: &Changelog,
        config: &FormatConfig,
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
                Self::new(data.user(), node, data.timestamp()?, config)
            }
            None => {
                let node = match config.template {
                    Template::Default => repo.dirstate_parents()?.p1,
                    Template::Json => Node::from_hex(WORKING_DIRECTORY_HEX)
                        .expect("wdir hex should parse"),
                };
                let fs_path = hg::utils::hg_path::hg_path_to_path_buf(path)?;
                let meta =
                    repo.working_directory_vfs().symlink_metadata(&fs_path)?;
                let mtime = meta.modified().when_reading_file(&fs_path)?;
                let mtime = DateTime::<Local>::from(mtime).fixed_offset();
                let user =
                    &config.wdir_config.as_ref().expect("should be set").user;
                Self::new(user, node, mtime, config)
            }
        }
    }

    fn new(
        user: &[u8],
        changeset: Node,
        date: DateTime<FixedOffset>,
        config: &FormatConfig,
    ) -> Result<Self, CommandError> {
        let mut result = ChangesetData::default();
        if config.include.user {
            let user = match config.template {
                Template::Default => match config.verbosity {
                    Verbosity::Verbose => user.to_vec(),
                    _ => hg::utils::strings::short_user(user).to_vec(),
                },
                Template::Json => json_string(user)?,
            };
            result.user = Some(user.to_vec());
        }
        if config.include.changeset {
            let hex = match config.template {
                Template::Default => format!("{:x}", changeset.short()),
                Template::Json => format!("\"{:x}\"", changeset),
            };
            result.changeset = Some(hex.into_bytes());
        }
        if config.include.date {
            let date = match config.template {
                Template::Default => {
                    format!(
                        "{}",
                        date.format(match config.verbosity {
                            Verbosity::Quiet => "%Y-%m-%d",
                            _ => "%a %b %d %H:%M:%S %Y %z",
                        })
                    )
                }
                Template::Json => format!(
                    "[{}.0, {}]",
                    date.timestamp(),
                    date.offset().utc_minus_local(),
                ),
            };
            result.date = Some(date.into_bytes());
        }
        Ok(result)
    }
}

fn json_string(text: &[u8]) -> Result<Vec<u8>, CommandError> {
    serde_json::to_vec(&String::from_utf8_lossy(text)).map_err(|err| {
        CommandError::abort(format!(
            "failed to serialize string to JSON: {err}"
        ))
    })
}
