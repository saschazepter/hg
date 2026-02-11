use std::borrow::Cow;
use std::collections::HashMap;
use std::collections::HashSet;
use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::ffi::OsStringExt;
use std::os::unix::prelude::CommandExt;
use std::path::PathBuf;
use std::process::Command;

use clap::Arg;
use clap::ArgMatches;
use clap::command;
use format_bytes::format_bytes;
use format_bytes::join;
use hg::config::Config;
use hg::config::ConfigSource;
use hg::config::PlainInfo;
use hg::exit_codes;
use hg::repo::Repo;
use hg::repo::RepoError;
use hg::requirements;
use hg::utils::files::get_path_from_bytes;
use hg::utils::strings::SliceExt;
use hg::utils::strings::join_display;
use tracing::Level;
use tracing::span;
#[cfg(feature = "full-tracing")]
use tracing_chrome::ChromeLayerBuilder;
#[cfg(feature = "full-tracing")]
use tracing_chrome::FlushGuard;
use tracing_subscriber::EnvFilter;
#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::fmt::format::FmtSpan;
use tracing_subscriber::prelude::*;

use crate::error::CommandError;
use crate::ui::Ui;

mod blackbox;
mod color;
mod error;
mod ui;
pub mod utils {
    pub mod path_utils;
}

fn expand_aliases(
    app: &clap::Command,
    subcommands: &Subcommands,
    mut alias_definitions: Vec<(&[u8], &[u8])>,
    argv: &[OsString],
) -> Result<Vec<OsString>, CommandError> {
    let mut expand_alias =
        |alias: &str| -> Result<Option<Vec<OsString>>, CommandError> {
            let Some(index) = alias_definitions
                .iter()
                .rposition(|(name, _)| *name == alias.as_bytes())
            else {
                return Ok(None);
            };
            let (_, definition) = alias_definitions[index];
            // Aliases can only refer to other aliases defined earlier.
            alias_definitions.truncate(index);
            tracing::debug!(
                "resolved alias '{}' to '{}'",
                alias,
                String::from_utf8_lossy(definition)
            );
            if subcommands.run_fn(alias).is_some() {
                tracing::warn!("alias '{alias}' shadows a subcommand");
            }
            if definition.starts_with(b"!") {
                return Err(CommandError::unsupported("shell alias"));
            }
            if definition.contains(&b'$') {
                return Err(CommandError::unsupported("alias interpolation"));
            }
            let mut iter = shlex::bytes::Shlex::new(definition);
            let args: Vec<_> = iter.by_ref().map(OsString::from_vec).collect();
            if iter.had_error {
                let message = format!(
                    "config error: error in definition for alias '{alias}': \
            invalid quotation or escape"
                );
                return Err(CommandError::abort_with_exit_code(
                    message,
                    exit_codes::CONFIG_ERROR_ABORT,
                ));
            };
            let early_flags = EarlyArgs::parse_flags(&args);
            if !early_flags.is_empty() {
                let message = format!(
                    "config error: error in definition for alias '{alias}': \
            {} may only be given on the command line",
                    join_display(early_flags, "/")
                );
                return Err(CommandError::abort_with_exit_code(
                    message,
                    exit_codes::CONFIG_ERROR_ABORT,
                ));
            }
            Ok(Some(args))
        };

    // First, parse "external" (i.e. unknown) subcommands so that we can try to
    // resolve aliases, including ones that shadow normal subcommands.
    let matches = app
        .clone()
        .allow_external_subcommands(true)
        .try_get_matches_from(argv.iter())?;
    let (alias, alias_matches) =
        matches.subcommand().expect("subcommand required");

    // `trailing_args` only includes arguments *after* the alias,
    // so something like `hg -R repo cat repo/x` will drop the `-R` flag.
    // This is OK because at this point these arguments won't make a
    // difference:
    // - we've already parsed any valid early args with EarlyArgs
    // - we've already validated that there are no unexpected flags
    // (otherwise `try_get_matches_from` above return an error)
    let trailing_args = alias_matches
        .get_many::<OsString>("")
        .expect("allow_external_subcommands always sets the empty string");

    let expanded_argv = match expand_alias(alias)? {
        None => argv.to_vec(),
        Some(mut args) => {
            let binary_name = argv[0].clone();

            // To expand further aliases, just use the first argument instead
            // of re-parsing the whole thing. This matches Python behavior. It
            // means `hg -q alias` is allowed (where -q is an example global
            // option), but `[alias] alias = -q otheralias` is not allowed.
            while let Some(alias) = args.first().and_then(|s| s.to_str()) {
                let Some(expansion) = expand_alias(alias)? else {
                    break;
                };
                args.splice(0..1, expansion);
            }
            let mut expanded_argv = vec![binary_name];
            expanded_argv.extend_from_slice(&args);
            expanded_argv.extend(trailing_args.cloned());
            expanded_argv
        }
    };
    Ok(expanded_argv)
}

#[tracing::instrument(level = "debug", skip_all)]
fn main_with_result(
    argv: Vec<OsString>,
    process_start_time: &blackbox::ProcessStartTime,
    ui: &ui::Ui,
    repo: Result<&Repo, &NoRepoInCwdError>,
    config: &Config,
) -> Result<(), CommandError> {
    let setup_span = span!(Level::DEBUG, "CLI and command setup").entered();
    check_unsupported(config, repo)?;

    let app = command!()
        .subcommand_required(true)
        .arg(
            Arg::new("repository")
                .help("repository root directory")
                .short('R')
                .value_name("REPO")
                // Both ok: `hg -R ./foo log` or `hg log -R ./foo`
                .global(true),
        )
        .arg(
            Arg::new("config")
                .help("set/override config option (use 'section.name=value')")
                .value_name("CONFIG")
                .global(true)
                .long("config")
                // Ok: `--config section.key1=val --config section.key2=val2`
                // Not ok: `--config section.key1=val section.key2=val2`
                .action(clap::ArgAction::Append),
        )
        .arg(
            Arg::new("cwd")
                .help("change working directory")
                .value_name("DIR")
                .long("cwd")
                .global(true),
        )
        .arg(
            Arg::new("color")
                .help(
                    "when to colorize (boolean, always, auto, never, or debug)",
                )
                .value_name("TYPE")
                .long("color")
                .global(true),
        )
        .version("0.0.1");

    let subcommands = subcommands();

    let alias_definitions: Vec<(&[u8], &[u8])> =
        config.iter_section(b"alias").collect();

    let expanded_argv =
        expand_aliases(&app, &subcommands, alias_definitions, &argv)?;

    // Second, parse the expanded argv with subcommand parsers enabled.
    let matches =
        subcommands.add_args(app).try_get_matches_from(expanded_argv)?;
    let (subcommand_name, subcommand_args) =
        matches.subcommand().expect("subcommand required");
    let Some(run) = subcommands.run_fn(subcommand_name) else {
        return Err(CommandError::unsupported(format!(
            "unsuppported subcommand: {subcommand_name}"
        )));
    };

    // Mercurial allows users to define "defaults" for commands, fallback
    // if a default is detected for the current command
    let defaults = config.get_str(b"defaults", subcommand_name.as_bytes())?;
    match defaults {
        // Programmatic usage might set defaults to an empty string to unset
        // it; allow that
        None | Some("") => {}
        Some(_) => {
            let msg = "`defaults` config set";
            return Err(CommandError::unsupported(msg));
        }
    }

    for prefix in ["pre", "post", "fail"].iter() {
        // Mercurial allows users to define generic hooks for commands,
        // fallback if any are detected
        let item = format!("{}-{}", prefix, subcommand_name);
        let hook_for_command =
            config.get_str_no_default(b"hooks", item.as_bytes())?;
        if hook_for_command.is_some() {
            let msg = format!("{}-{} hook defined", prefix, subcommand_name);
            return Err(CommandError::unsupported(msg));
        }
    }

    let invocation = CliInvocation { ui, subcommand_args, config, repo };

    if let Ok(repo) = repo {
        // We don't support subrepos, fallback if the subrepos file is present
        if repo.working_directory_vfs().join(".hgsub").exists() {
            let msg = "subrepos (.hgsub is present)";
            return Err(CommandError::unsupported(msg));
        }
    }

    if config.is_extension_enabled(b"blackbox") {
        let blackbox_span = span!(Level::DEBUG, "blackbox").entered();
        let blackbox =
            blackbox::Blackbox::new(&invocation, process_start_time)?;
        blackbox.log_command_start(argv.iter());
        blackbox_span.exit();
        setup_span.exit();
        let result = run(&invocation);
        let blackbox_span = span!(Level::DEBUG, "blackbox").entered();
        blackbox.log_command_end(
            argv.iter(),
            exit_code(
                &result,
                // TODO: show a warning or combine with original error if
                // `get_bool` returns an error
                config.get_bool(b"ui", b"detailed-exit-code").unwrap_or(false),
            ),
        );
        blackbox_span.exit();
        result
    } else {
        setup_span.exit();
        run(&invocation)
    }
}

fn rhg_main(argv: Vec<OsString>) -> ! {
    // Run this first, before we find out if the blackbox extension is even
    // enabled, in order to include everything in-between in the duration
    // measurements. Reading config files can be slow if they’re on NFS.
    let process_start_time = blackbox::ProcessStartTime::now();

    #[cfg(feature = "full-tracing")]
    let chrome_layer_guard = setup_tracing();
    #[cfg(not(feature = "full-tracing"))]
    setup_tracing();

    // Make sure nothing in a future version of `rhg` sets the global
    // threadpool before we can cap default threads. (This is also called
    // in core because Python uses the same code path, we're adding a
    // redundant check.)
    hg::utils::cap_default_rayon_threads()
        .expect("Rayon threadpool already initialized");

    let early_args = EarlyArgs::parse(&argv);

    let initial_current_dir = early_args.cwd.as_ref().map(|cwd| {
        let cwd = get_path_from_bytes(cwd);
        std::env::current_dir()
            .and_then(|initial| {
                std::env::set_current_dir(cwd)?;
                Ok(initial)
            })
            .unwrap_or_else(|error| {
                exit(
                    &argv,
                    &None,
                    &Ui::new_infallible(&Config::empty()),
                    OnUnsupported::Abort,
                    Err(CommandError::abort(format!(
                        "abort: {}: '{}'",
                        error,
                        cwd.display()
                    ))),
                    false,
                )
            })
    });

    let (non_repo_config, repo_path) =
        config_setup(&argv, early_args, &initial_current_dir);

    let repo_span = span!(Level::DEBUG, "repo setup").entered();

    let simple_exit =
        |ui: &Ui, config: &Config, result: Result<(), CommandError>| -> ! {
            exit(
                &argv,
                &initial_current_dir,
                ui,
                OnUnsupported::from_config(config),
                result,
                // TODO: show a warning or combine with original error if
                // `get_bool` returns an error
                non_repo_config
                    .get_bool(b"ui", b"detailed-exit-code")
                    .unwrap_or(false),
            )
        };
    let early_exit = |config: &Config, error: CommandError| -> ! {
        simple_exit(&Ui::new_infallible(config), config, Err(error))
    };
    let repo_result = match Repo::find(&non_repo_config, repo_path.to_owned()) {
        Ok(repo) => Ok(repo),
        Err(RepoError::NotFound { at }) if repo_path.is_none() => {
            // Not finding a repo is not fatal yet, if `-R` was not given
            Err(NoRepoInCwdError { cwd: at })
        }
        Err(error) => early_exit(&non_repo_config, error.into()),
    };

    let config = if let Ok(repo) = &repo_result {
        repo.config()
    } else {
        &non_repo_config
    };

    let mut config_cow = Cow::Borrowed(config);
    config_cow.to_mut().apply_plain(PlainInfo::from_env());
    if !ui::plain(Some("tweakdefaults"))
        && config_cow
            .as_ref()
            .get_bool(b"ui", b"tweakdefaults")
            .unwrap_or_else(|error| early_exit(config, error.into()))
    {
        config_cow.to_mut().tweakdefaults()
    };
    let config = config_cow.as_ref();
    let ui = Ui::new(config)
        .unwrap_or_else(|error| early_exit(config, error.into()));

    if let Ok(true) = config.get_bool(b"rhg", b"fallback-immediately") {
        exit(
            &argv,
            &initial_current_dir,
            &ui,
            OnUnsupported::fallback(config),
            Err(CommandError::unsupported(
                "`rhg.fallback-immediately is true`",
            )),
            false,
        )
    }

    repo_span.exit();
    let result = main_with_result(
        argv.iter().map(|s| s.to_owned()).collect(),
        &process_start_time,
        &ui,
        repo_result.as_ref(),
        config,
    );

    #[cfg(feature = "full-tracing")]
    // The `Drop` implementation doesn't flush, probably because it would be
    // too expensive in the general case? Not sure, but we want it.
    chrome_layer_guard.flush();
    #[cfg(feature = "full-tracing")]
    // Explicitly run `drop` here to wait for the writing thread to join
    // because `drop` may not be called when `std::process::exit` is called.
    drop(chrome_layer_guard);
    simple_exit(&ui, config, result)
}

#[cfg(feature = "full-tracing")]
/// Enable an env-filtered chrome-trace logger to a file.
/// Defaults to writing to `./trace-{unix epoch in micros}.json`, but can
/// be overridden via the `HG_TRACE_PATH` environment variable.
fn setup_tracing() -> FlushGuard {
    let mut chrome_layer_builder = ChromeLayerBuilder::new();
    // /!\ Keep in sync with hg-pyo3
    if let Ok(path) = std::env::var("HG_TRACE_PATH") {
        chrome_layer_builder = chrome_layer_builder.file(path);
    }
    let (chrome_layer, chrome_layer_guard) = chrome_layer_builder.build();
    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env())
        .with(chrome_layer)
        .init();
    chrome_layer_guard
}

#[cfg(not(feature = "full-tracing"))]
/// Enable an env-filtered logger to stderr
fn setup_tracing() {
    let registry = tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer().with_writer(std::io::stderr))
        .with(EnvFilter::from_default_env());
    let fmt_layer = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stderr)
        .with_span_events(FmtSpan::CLOSE);
    registry.with(fmt_layer).init()
}

#[tracing::instrument(level = "debug", skip_all)]
fn config_setup(
    argv: &[OsString],
    early_args: EarlyArgs,
    initial_current_dir: &Option<PathBuf>,
) -> (Config, Option<PathBuf>) {
    let mut non_repo_config = Config::load_non_repo().unwrap_or_else(|error| {
        // Normally this is decided based on config, but we don’t have that
        // available. As of this writing config loading never returns an
        // "unsupported" error but that is not enforced by the type system.
        let on_unsupported = OnUnsupported::Abort;

        exit(
            argv,
            initial_current_dir,
            &Ui::new_infallible(&Config::empty()),
            on_unsupported,
            Err(error.into()),
            false,
        )
    });

    non_repo_config
        .load_cli_args(early_args.config, early_args.color)
        .unwrap_or_else(|error| {
            exit(
                argv,
                initial_current_dir,
                &Ui::new_infallible(&non_repo_config),
                OnUnsupported::from_config(&non_repo_config),
                Err(error.into()),
                non_repo_config
                    .get_bool(b"ui", b"detailed-exit-code")
                    .unwrap_or(false),
            )
        });

    if let Some(repo_path_bytes) = &early_args.repo {
        lazy_static::lazy_static! {
            static ref SCHEME_RE: regex::bytes::Regex =
                // Same as `_matchscheme` in `mercurial/util.py`
                regex::bytes::Regex::new("^[a-zA-Z0-9+.\\-]+:").unwrap();
        }
        if SCHEME_RE.is_match(repo_path_bytes) {
            exit(
                argv,
                initial_current_dir,
                &Ui::new_infallible(&non_repo_config),
                OnUnsupported::from_config(&non_repo_config),
                Err(CommandError::UnsupportedFeature {
                    message: format_bytes!(
                        b"URL-like --repository {}",
                        repo_path_bytes
                    ),
                }),
                // TODO: show a warning or combine with original error if
                // `get_bool` returns an error
                non_repo_config
                    .get_bool(b"ui", b"detailed-exit-code")
                    .unwrap_or(false),
            )
        }
    }
    let repo_arg = early_args.repo.unwrap_or_default();
    let repo_path: Option<PathBuf> = {
        if repo_arg.is_empty() {
            None
        } else {
            let local_config = {
                if std::env::var_os("HGRCSKIPREPO").is_none() {
                    // TODO: handle errors from find_repo_root
                    if let Ok(current_dir_path) = Repo::find_repo_root() {
                        let config_files = vec![
                            ConfigSource::AbsPath(
                                current_dir_path.join(".hg/hgrc"),
                            ),
                            ConfigSource::AbsPath(
                                current_dir_path.join(".hg/hgrc-not-shared"),
                            ),
                        ];
                        // TODO: handle errors from
                        // `load_from_explicit_sources`
                        Config::load_from_explicit_sources(config_files).ok()
                    } else {
                        None
                    }
                } else {
                    None
                }
            };

            let non_repo_config_val = {
                let non_repo_val = non_repo_config.get(b"paths", &repo_arg);
                match &non_repo_val {
                    Some(val) if !val.is_empty() => home::home_dir()
                        .unwrap_or_else(|| PathBuf::from("~"))
                        .join(get_path_from_bytes(val))
                        .canonicalize()
                        // TODO: handle error and make it similar to python
                        // implementation maybe?
                        .ok(),
                    _ => None,
                }
            };

            let config_val = match &local_config {
                None => non_repo_config_val,
                Some(val) => {
                    let local_config_val = val.get(b"paths", &repo_arg);
                    match &local_config_val {
                        Some(val) if !val.is_empty() => {
                            // presence of a local_config assures that
                            // current_dir
                            // wont result in an Error
                            let canpath = hg::utils::current_dir()
                                .unwrap()
                                .join(get_path_from_bytes(val))
                                .canonicalize();
                            canpath.ok().or(non_repo_config_val)
                        }
                        _ => non_repo_config_val,
                    }
                }
            };
            config_val
                .or_else(|| Some(get_path_from_bytes(&repo_arg).to_path_buf()))
        }
    };
    (non_repo_config, repo_path)
}

fn main() -> ! {
    rhg_main(std::env::args_os().collect())
}

fn exit_code(
    result: &Result<(), CommandError>,
    use_detailed_exit_code: bool,
) -> i32 {
    match result {
        Ok(()) => exit_codes::OK,
        Err(CommandError::Abort { detailed_exit_code, .. }) => {
            if use_detailed_exit_code {
                *detailed_exit_code
            } else {
                exit_codes::ABORT
            }
        }
        Err(CommandError::Unsuccessful) => exit_codes::UNSUCCESSFUL,
        // Exit with a specific code and no error message to let a potential
        // wrapper script fallback to Python-based Mercurial.
        Err(CommandError::UnsupportedFeature { .. }) => {
            exit_codes::UNIMPLEMENTED
        }
        Err(CommandError::InvalidFallback { .. }) => {
            exit_codes::INVALID_FALLBACK
        }
    }
}

fn exit(
    original_args: &[OsString],
    initial_current_dir: &Option<PathBuf>,
    ui: &Ui,
    mut on_unsupported: OnUnsupported,
    result: Result<(), CommandError>,
    use_detailed_exit_code: bool,
) -> ! {
    if let (
        OnUnsupported::Fallback { executable },
        Err(CommandError::UnsupportedFeature { message }),
    ) = (&on_unsupported, &result)
    {
        let mut args = original_args.iter();
        let executable = match executable {
            None => {
                exit_no_fallback(
                    ui,
                    OnUnsupported::Abort,
                    Err(CommandError::abort(
                        "abort: 'rhg.on-unsupported=fallback' without \
                                'rhg.fallback-executable' set.",
                    )),
                    false,
                );
            }
            Some(executable) => executable,
        };
        let executable_path = get_path_from_bytes(executable);
        let this_executable = args.next().expect("exepcted argv[0] to exist");
        if executable_path == *this_executable {
            // Avoid spawning infinitely many processes until resource
            // exhaustion.
            let _ = ui.write_stderr(&format_bytes!(
                b"Blocking recursive fallback. The 'rhg.fallback-executable = {}' config \
                points to `rhg` itself.\n",
                executable
            ));
            on_unsupported = OnUnsupported::Abort
        } else {
            tracing::debug!("falling back (see trace-level log)");
            tracing::trace!("{}", String::from_utf8_lossy(message));
            if let Err(err) = which::which(executable_path) {
                exit_no_fallback(
                    ui,
                    OnUnsupported::Abort,
                    Err(CommandError::InvalidFallback {
                        path: executable.to_owned(),
                        err: err.to_string(),
                    }),
                    use_detailed_exit_code,
                )
            }
            // `args` is now `argv[1..]` since we’ve already consumed
            // `argv[0]`
            let mut command = Command::new(executable_path);
            command.args(args);
            if let Some(initial) = initial_current_dir {
                command.current_dir(initial);
            }
            // We don't use subprocess because proper signal handling is harder
            // and we don't want to keep `rhg` around after a fallback anyway.
            // For example, if `rhg` is run in the background and falls back to
            // `hg` which, in turn, waits for a signal, we'll get stuck if
            // we're doing plain subprocess.
            //
            // If `exec` returns, we can only assume our process is very broken
            // (see its documentation), so only try to forward the error code
            // when exiting.
            let err = command.exec();
            std::process::exit(err.raw_os_error().unwrap_or(exit_codes::ABORT));
        }
    }
    exit_no_fallback(ui, on_unsupported, result, use_detailed_exit_code)
}

fn exit_no_fallback(
    ui: &Ui,
    on_unsupported: OnUnsupported,
    result: Result<(), CommandError>,
    use_detailed_exit_code: bool,
) -> ! {
    match &result {
        Ok(_) => {}
        Err(CommandError::Unsuccessful) => {}
        Err(CommandError::Abort { message, hint, .. }) => {
            // Ignore errors when writing to stderr, we’re already exiting
            // with failure code so there’s not much more we can do.
            if !message.is_empty() {
                let _ = ui.write_stderr(&format_bytes!(b"{}\n", message));
            }
            if let Some(hint) = hint {
                let _ = ui.write_stderr(&format_bytes!(b"({})\n", hint));
            }
        }
        Err(CommandError::UnsupportedFeature { message }) => {
            match on_unsupported {
                OnUnsupported::Abort => {
                    let _ = ui.write_stderr(&format_bytes!(
                        b"unsupported feature: {}\n",
                        message
                    ));
                }
                OnUnsupported::AbortSilent => {}
                OnUnsupported::Fallback { .. } => unreachable!(),
            }
        }
        Err(CommandError::InvalidFallback { path, err }) => {
            let _ = ui.write_stderr(&format_bytes!(
                b"abort: invalid fallback '{}': {}\n",
                path,
                err.as_bytes(),
            ));
        }
    }
    std::process::exit(exit_code(&result, use_detailed_exit_code))
}

mod commands {
    pub mod admin_narrow_client;
    pub mod annotate;
    pub mod cat;
    pub mod config;
    pub mod debug_narrow_fingerprint;
    pub mod debugdata;
    pub mod debugignorerhg;
    pub mod debugrequirements;
    pub mod debugrhgsparse;
    pub mod files;
    pub mod purge;
    pub mod root;
    pub mod script_hgignore;
    pub mod status;
}

pub type RunFn = fn(&CliInvocation) -> Result<(), CommandError>;

struct SubCommand {
    run: RunFn,
    args: clap::Command,
    /// used for reporting name collisions
    origin: String,
}

impl SubCommand {
    fn name(&self) -> String {
        self.args.get_name().to_string()
    }
}

macro_rules! subcommand {
    ($command: ident) => {{
        SubCommand {
            args: commands::$command::args(),
            run: commands::$command::run,
            origin: stringify!($command).to_string(),
        }
    }};
}

struct Subcommands {
    commands: Vec<clap::Command>,
    run: HashMap<String, (String, RunFn)>,
}

/// `Subcommands` construction
impl Subcommands {
    pub fn new() -> Self {
        Self { commands: vec![], run: HashMap::new() }
    }

    pub fn add(&mut self, subcommand: SubCommand) {
        let name = subcommand.name();
        if let Some((origin_old, _)) = self
            .run
            .insert(name.clone(), (subcommand.origin.clone(), subcommand.run))
        {
            panic!(
                "command `{}` is defined in two places (`{}` and `{}`)",
                name, origin_old, subcommand.origin
            )
        }
        self.commands.push(subcommand.args)
    }
}

/// `Subcommands` querying
impl Subcommands {
    pub fn add_args(&self, mut app: clap::Command) -> clap::Command {
        for cmd in self.commands.iter() {
            app = app.subcommand(cmd)
        }
        app
    }

    pub fn run_fn(&self, name: &str) -> Option<RunFn> {
        let (_, run) = self.run.get(name)?;
        Some(*run)
    }
}

fn subcommands() -> Subcommands {
    let subcommands = vec![
        subcommand!(admin_narrow_client),
        subcommand!(annotate),
        subcommand!(cat),
        subcommand!(debugdata),
        subcommand!(debug_narrow_fingerprint),
        subcommand!(debugrequirements),
        subcommand!(debugignorerhg),
        subcommand!(debugrhgsparse),
        subcommand!(files),
        subcommand!(root),
        subcommand!(purge),
        subcommand!(config),
        subcommand!(status),
        subcommand!(script_hgignore),
    ];
    let mut commands = Subcommands::new();
    for cmd in subcommands {
        commands.add(cmd)
    }
    commands
}

pub struct CliInvocation<'a> {
    ui: &'a Ui,
    subcommand_args: &'a ArgMatches,
    config: &'a Config,
    /// References inside `Result` is a bit peculiar but allow
    /// `invocation.repo?` to work out with `&CliInvocation` since this
    /// `Result` type is `Copy`.
    repo: Result<&'a Repo, &'a NoRepoInCwdError>,
}

struct NoRepoInCwdError {
    cwd: PathBuf,
}

/// CLI arguments to be parsed "early" in order to be able to read
/// configuration before using Clap. Ideally we would also use Clap for this,
/// see <https://github.com/clap-rs/clap/discussions/2366>.
///
/// These arguments are still declared when we do use Clap later, so that Clap
/// does not return an error for their presence.
#[derive(Default)]
struct EarlyArgs {
    /// Values of all `--config` arguments. (Possibly none)
    config: Vec<Vec<u8>>,
    /// Value of all the `--color` argument, if any.
    color: Option<Vec<u8>>,
    /// Value of the `-R` or `--repository` argument, if any.
    repo: Option<Vec<u8>>,
    /// Value of the `--cwd` argument, if any.
    cwd: Option<Vec<u8>>,
}

#[derive(Copy, Clone)]
enum EarlyFlag {
    Config,
    Color,
    Cwd,
    Repository,
    Repo,
    R,
}

impl EarlyFlag {
    const fn all() -> &'static [EarlyFlag] {
        use EarlyFlag::*;
        &[Config, Color, Cwd, Repository, Repo, R]
    }

    const fn as_str(&self) -> &'static str {
        match self {
            EarlyFlag::Config => "--config",
            EarlyFlag::Color => "--color",
            EarlyFlag::Cwd => "--cwd",
            EarlyFlag::Repository => "--repository",
            EarlyFlag::Repo => "--repo",
            EarlyFlag::R => "-R",
        }
    }

    const fn value_sep(&self) -> &'static [u8] {
        match self {
            EarlyFlag::R => b"",
            _ => b"=",
        }
    }
}

impl std::fmt::Display for EarlyFlag {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.as_str().fmt(f)
    }
}

impl EarlyArgs {
    fn parse_one<'a>(
        arg: &'a OsString,
        mut next: impl FnMut() -> Option<&'a OsString>,
    ) -> Option<(EarlyFlag, &'a [u8])> {
        let arg = arg.as_bytes();
        for &flag in EarlyFlag::all() {
            let flag_str = flag.as_str().as_bytes();
            if arg == flag_str
                && let Some(value) = next()
            {
                return Some((flag, value.as_bytes()));
            }
            if let Some(rest) = arg.drop_prefix(flag_str)
                && let Some(value) = rest.drop_prefix(flag.value_sep())
            {
                return Some((flag, value));
            }
        }
        None
    }

    fn parse_flags<'a>(
        args: impl IntoIterator<Item = &'a OsString>,
    ) -> Vec<EarlyFlag> {
        let mut args = args.into_iter();
        let mut flags = Vec::new();
        while let Some(arg) = args.next() {
            if let Some((flag, _)) = Self::parse_one(arg, || args.next()) {
                flags.push(flag);
            }
        }
        flags
    }

    fn parse<'a>(args: impl IntoIterator<Item = &'a OsString>) -> Self {
        let mut args = args.into_iter();
        let mut this = Self::default();
        while let Some(arg) = args.next() {
            if let Some((flag, value)) = Self::parse_one(arg, || args.next()) {
                let value = value.to_owned();
                match flag {
                    EarlyFlag::Config => this.config.push(value),
                    EarlyFlag::Color => this.color = Some(value),
                    EarlyFlag::Cwd => this.cwd = Some(value),
                    EarlyFlag::Repository | EarlyFlag::Repo | EarlyFlag::R => {
                        this.repo = Some(value);
                    }
                }
            }
        }
        this
    }
}

/// What to do when encountering some unsupported feature.
///
/// See `HgError::UnsupportedFeature` and `CommandError::UnsupportedFeature`.
enum OnUnsupported {
    /// Print an error message describing what feature is not supported,
    /// and exit with code 252.
    Abort,
    /// Silently exit with code 252.
    AbortSilent,
    /// Try running a Python implementation
    Fallback { executable: Option<Vec<u8>> },
}

impl OnUnsupported {
    const DEFAULT: Self = OnUnsupported::Abort;

    fn fallback_executable(config: &Config) -> Option<Vec<u8>> {
        config.get(b"rhg", b"fallback-executable").map(|x| x.to_owned())
    }

    fn fallback(config: &Config) -> Self {
        OnUnsupported::Fallback {
            executable: Self::fallback_executable(config),
        }
    }

    fn from_config(config: &Config) -> Self {
        match config
            .get(b"rhg", b"on-unsupported")
            .map(|value| value.to_ascii_lowercase())
            .as_deref()
        {
            Some(b"abort") => OnUnsupported::Abort,
            Some(b"abort-silent") => OnUnsupported::AbortSilent,
            Some(b"fallback") => Self::fallback(config),
            None => Self::DEFAULT,
            Some(_) => {
                // TODO: warn about unknown config value
                Self::DEFAULT
            }
        }
    }
}

/// The `*` extension is an edge-case for config sub-options that apply to all
/// extensions. For now, only `:required` exists, but that may change in the
/// future.
const SUPPORTED_EXTENSIONS: &[&[u8]] = &[
    b"blackbox",
    b"share",
    b"sparse",
    b"narrow",
    b"*",
    b"strip",
    b"rebase",
    b"purge",
];

fn check_extensions(config: &Config) -> Result<(), CommandError> {
    if let Some(b"*") = config.get(b"rhg", b"ignored-extensions") {
        // All extensions are to be ignored, nothing to do here
        return Ok(());
    }

    let enabled: HashSet<&[u8]> = config
        .iter_section(b"extensions")
        .filter_map(|(extension, value)| {
            if value == b"!" {
                // Filter out disabled extensions
                return None;
            }
            // Ignore extension suboptions. Only `required` exists for now.
            // `rhg` either supports an extension or doesn't, so it doesn't
            // make sense to consider the loading of an extension.
            let actual_extension =
                extension.split_2(b':').unwrap_or((extension, b"")).0;
            Some(actual_extension)
        })
        .collect();

    let mut unsupported = enabled;
    for supported in SUPPORTED_EXTENSIONS {
        unsupported.remove(supported);
    }

    if let Some(ignored_list) = config.get_list(b"rhg", b"ignored-extensions") {
        for ignored in ignored_list {
            unsupported.remove(ignored.as_slice());
        }
    }

    if unsupported.is_empty() {
        Ok(())
    } else {
        let mut unsupported: Vec<_> = unsupported.into_iter().collect();
        // Sort the extensions to get a stable output
        unsupported.sort();
        Err(CommandError::UnsupportedFeature {
            message: format_bytes!(
                b"extensions: {} (consider adding them to 'rhg.ignored-extensions' config)",
                join(unsupported, b", ")
            ),
        })
    }
}

/// Array of tuples of (auto upgrade conf, feature conf, local requirement)
#[allow(clippy::type_complexity)]
const AUTO_UPGRADES: &[((&str, &str), (&str, &str), &str)] = &[
    (
        (
            "format",
            "use-share-safe.automatic-upgrade-of-mismatching-repositories",
        ),
        ("format", "use-share-safe"),
        requirements::SHARESAFE_REQUIREMENT,
    ),
    (
        (
            "format",
            "use-dirstate-tracked-hint.automatic-upgrade-of-mismatching-repositories",
        ),
        ("format", "use-dirstate-tracked-hint"),
        requirements::DIRSTATE_TRACKED_HINT_V1,
    ),
    (
        (
            "format",
            "use-dirstate-v2.automatic-upgrade-of-mismatching-repositories",
        ),
        ("format", "use-dirstate-v2"),
        requirements::DIRSTATE_V2_REQUIREMENT,
    ),
];

/// Mercurial allows users to automatically upgrade their repository.
/// `rhg` does not have the ability to upgrade yet, so fallback if an upgrade
/// is needed.
fn check_auto_upgrade(
    config: &Config,
    reqs: &HashSet<String>,
) -> Result<(), CommandError> {
    for (upgrade_conf, feature_conf, local_req) in AUTO_UPGRADES.iter() {
        let auto_upgrade = config
            .get_bool(upgrade_conf.0.as_bytes(), upgrade_conf.1.as_bytes())?;

        if auto_upgrade {
            let want_it = config.get_bool(
                feature_conf.0.as_bytes(),
                feature_conf.1.as_bytes(),
            )?;
            let have_it = reqs.contains(*local_req);

            let action = match (want_it, have_it) {
                (true, false) => Some("upgrade"),
                (false, true) => Some("downgrade"),
                _ => None,
            };
            if let Some(action) = action {
                let message = format!(
                    "automatic {} {}.{}",
                    action, upgrade_conf.0, upgrade_conf.1
                );
                return Err(CommandError::unsupported(message));
            }
        }
    }
    Ok(())
}

fn check_unsupported(
    config: &Config,
    repo: Result<&Repo, &NoRepoInCwdError>,
) -> Result<(), CommandError> {
    check_extensions(config)?;

    if std::env::var_os("HG_PENDING").is_some() {
        // TODO: only if the value is `== repo.working_directory`?
        // What about relative v.s. absolute paths?
        Err(CommandError::unsupported("$HG_PENDING"))?
    }

    if let Ok(repo) = repo {
        if repo.has_subrepos()? {
            Err(CommandError::unsupported("sub-repositories"))?
        }
        check_auto_upgrade(config, repo.requirements())?;
    }

    if config.has_non_empty_section(b"encode") {
        Err(CommandError::unsupported("[encode] config"))?
    }

    if config.has_non_empty_section(b"decode") {
        Err(CommandError::unsupported("[decode] config"))?
    }

    Ok(())
}
