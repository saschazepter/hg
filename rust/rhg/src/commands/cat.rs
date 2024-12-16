use crate::error::CommandError;
use crate::utils::path_utils::resolve_file_args;
use clap::Arg;
use format_bytes::format_bytes;
use hg::operations::cat;
use std::ffi::OsString;

pub const HELP_TEXT: &str = "
Output the current or given revision of files
";

pub fn args() -> clap::Command {
    clap::command!("cat")
        .arg(
            Arg::new("rev")
                .help("search the repository as it is in REV")
                .short('r')
                .long("rev")
                .value_name("REV"),
        )
        .arg(
            clap::Arg::new("files")
                .required(true)
                .num_args(1..)
                .value_name("FILE")
                .value_parser(clap::value_parser!(std::ffi::OsString))
                .help("Files to output"),
        )
        .about(HELP_TEXT)
}

#[logging_timer::time("trace")]
pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let cat_enabled = invocation.config.get_bool(b"rhg", b"cat")?;
    if !cat_enabled {
        return Err(CommandError::unsupported(
            "cat is disabled in rhg (enable it with 'rhg.cat = true' \
            or enable fallback with 'rhg.on-unsupported = fallback')",
        ));
    }

    let repo = invocation.repo?;

    let rev = invocation.subcommand_args.get_one::<String>("rev");
    let files = match invocation.subcommand_args.get_many::<OsString>("files")
    {
        None => vec![],
        Some(files) => resolve_file_args(repo, files)?,
    };

    let files = files.iter().map(|file| file.as_ref()).collect();
    // TODO probably move this to a util function like `repo.default_rev` or
    // something when it's used somewhere else
    let rev = match rev {
        Some(r) => r.to_string(),
        None => format!("{:x}", repo.dirstate_parents()?.p1),
    };

    let output = cat(repo, &rev, files)?;
    for (_file, contents) in output.results {
        invocation.ui.write_stdout(&contents)?;
    }
    if !output.missing.is_empty() {
        let short = format!("{:x}", output.node.short()).into_bytes();
        for path in &output.missing {
            invocation.ui.write_stderr(&format_bytes!(
                b"{}: no such file in rev {}\n",
                path.as_bytes(),
                short
            ))?;
        }
    }
    if output.found_any {
        Ok(())
    } else {
        Err(CommandError::Unsuccessful)
    }
}
