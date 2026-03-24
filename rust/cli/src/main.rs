use std::path::{Path, PathBuf};
use std::process;

use clap::{Parser, Subcommand};

use disk_cleaner_config::api::ConfigProvider;
use disk_cleaner_config::{load_config, load_profile, create_scanner};

#[derive(Parser)]
#[command(name = "disk-cleaner", version, about = "Multi-language build artifact cleaner")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Language profile(s) to target (repeatable, or "all")
    #[arg(short = 'l', long = "lang", global = true)]
    lang: Vec<String>,

    /// Path to TOML config file
    #[arg(short = 'c', long, global = true)]
    config: Option<PathBuf>,

    /// Root path to search for projects
    #[arg(short = 'p', long, global = true)]
    path: Option<PathBuf>,

    /// Exclude projects matching pattern
    #[arg(short = 'e', long, global = true)]
    exclude: Vec<String>,

    /// Only include projects matching pattern
    #[arg(short = 'i', long, global = true)]
    include: Vec<String>,

    /// Process all projects, ignoring filters
    #[arg(short = 'a', long, global = true)]
    all: bool,

    /// Emit structured JSON lines
    #[arg(short = 'j', long = "json", global = true)]
    json_output: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Remove build artifacts from detected projects (default)
    Clean {
        /// Show what would be cleaned without cleaning
        #[arg(short = 'd', long)]
        dry_run: bool,

        /// Run clean operations in parallel
        #[arg(short = 'P', long)]
        parallel: bool,
    },

    /// Find and report projects without modifying them
    Search {
        /// Search for text or regex pattern within project source files
        #[arg(short = 't', long)]
        text: Option<String>,
    },

    /// Report disk space consumption by build artifacts
    Analyze {
        /// Generic disk usage scan (no profile required)
        #[arg(long)]
        disk_usage: bool,

        /// Directory depth for disk-usage scan
        #[arg(long, default_value = "2")]
        depth: usize,

        /// Benchmark build times
        #[arg(long)]
        benchmark: bool,
    },

    /// Show build process resources and run history
    Monitor {
        /// Show run history only
        #[arg(long)]
        history: bool,
    },

    /// Compact WSL virtual disks to reclaim space (Admin required)
    CompactWsl {
        /// Preview without compacting
        #[arg(short = 'd', long)]
        dry_run: bool,
    },

    /// Show available language profiles
    ListProfiles,
}

fn main() {
    let cli = Cli::parse();

    // Resolve config path
    let config_path = cli.config.unwrap_or_else(|| {
        let mut p = std::env::current_dir().unwrap_or_default();
        p.push("profiles.toml");
        if !p.exists() {
            if let Ok(exe) = std::env::current_exe() {
                if let Some(dir) = exe.parent() {
                    let shared = dir.join("../../powershell/main/config/profiles.toml");
                    if shared.exists() {
                        return shared;
                    }
                }
            }
        }
        p
    });

    let config = match load_config(&config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    // Resolve search path
    let search_path = cli.path.unwrap_or_else(|| {
        let default = config.get_value("settings.default_path");
        if default.is_empty() {
            std::env::current_dir().unwrap_or_default()
        } else {
            PathBuf::from(default)
        }
    });

    // Resolve lang profiles
    let lang = if cli.lang.is_empty() {
        config.get_array("settings.default_profiles")
    } else {
        cli.lang.clone()
    };

    let command = cli.command.unwrap_or(Commands::Clean {
        dry_run: false,
        parallel: false,
    });

    // List profiles — no scanner needed
    if matches!(command, Commands::ListProfiles) {
        println!("Available profiles:");
        println!();
        for key in config.profile_keys() {
            let profile = load_profile(key, &config);
            println!("  {key} - {}", profile.name);
            println!("    marker: {}  |  type: {}", profile.marker, profile.profile_type);
        }
        println!();
        return;
    }

    // Resolve profile keys
    let profile_keys = match resolve_profiles(&lang, &config) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };

    // Create scanner (composition root — DI)
    let ctx = create_scanner(search_path, cli.exclude, cli.include, cli.all, cli.json_output);

    // Dispatch to feature crates via their saf entry points
    match command {
        Commands::Clean { dry_run, parallel } => {
            disk_cleaner_clean::run(&ctx, &profile_keys, &config, dry_run, parallel);
        }
        Commands::Search { text } => {
            disk_cleaner_search::run(&ctx, &profile_keys, &config, text.as_deref());
        }
        Commands::Analyze { disk_usage, depth, benchmark } => {
            if disk_usage {
                disk_cleaner_analyze::run_disk_usage(&ctx, depth);
            } else {
                disk_cleaner_analyze::run(&ctx, &profile_keys, &config, benchmark);
            }
        }
        Commands::Monitor { history } => {
            let config_dir = config_path.parent().unwrap_or(Path::new("."));
            disk_cleaner_monitor::run(&ctx, config_dir, history);
        }
        Commands::CompactWsl { dry_run } => {
            disk_cleaner_compact_wsl::run(&ctx, dry_run);
        }
        Commands::ListProfiles => unreachable!(),
    }
}

fn resolve_profiles(lang: &[String], config: &dyn ConfigProvider) -> Result<Vec<String>, String> {
    let mut resolved = Vec::new();

    for l in lang {
        if l == "all" {
            return Ok(config.profile_keys().iter().map(|s| s.to_string()).collect());
        }
        let name = config.get_value(&format!("profiles.{l}.name"));
        if name.is_empty() {
            return Err(format!(
                "Unknown profile: {l}. Use list-profiles to see available profiles."
            ));
        }
        resolved.push(l.clone());
    }

    if resolved.is_empty() {
        return Err("No profiles selected. Use --lang or set default_profiles in config.".to_string());
    }

    Ok(resolved)
}
