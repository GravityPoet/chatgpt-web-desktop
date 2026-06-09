use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};
use cloak_core::{
    build_launch_plan, create_account, delete_account, launch_account, list_accounts, read_account,
    rename_account, self_check, set_proxy, set_region, toggle_locale, CloakConfig, LaunchOptions,
};

#[derive(Debug, Parser)]
#[command(name = "cloak", version, about = "Cloak account launcher")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Account {
        #[command(subcommand)]
        command: AccountCommand,
    },
    Launch(LaunchArgs),
    SelfCheck {
        #[arg(long)]
        json: bool,
    },
}

#[derive(Debug, Subcommand)]
enum AccountCommand {
    List {
        #[arg(long)]
        json: bool,
    },
    Create {
        name: String,
        #[arg(long)]
        json: bool,
    },
    Rename {
        old: String,
        new: String,
        #[arg(long)]
        json: bool,
    },
    Delete {
        name: String,
    },
    SetProxy {
        name: String,
        value: Option<String>,
        #[arg(long)]
        clear: bool,
        #[arg(long)]
        json: bool,
    },
    SetRegion {
        name: String,
        value: Option<String>,
        #[arg(long)]
        clear: bool,
        #[arg(long)]
        json: bool,
    },
    ToggleLocale {
        name: String,
        #[arg(long)]
        json: bool,
    },
    Show {
        name: String,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Debug, Args)]
struct LaunchArgs {
    name: String,
    #[arg(long)]
    dry_run: bool,
    #[arg(long)]
    json: bool,
    #[arg(long)]
    skip_geo: bool,
}

fn main() -> Result<()> {
    if cloak_core::maybe_run_relay_supervisor()? {
        return Ok(());
    }

    let cli = Cli::parse();
    let config = CloakConfig::from_env().context("load Cloak config")?;

    match cli.command {
        Command::Account { command } => handle_account(command, &config),
        Command::Launch(args) => handle_launch(args, &config),
        Command::SelfCheck { json } => {
            let message = self_check(&config)?;
            if json {
                print_json(&serde_json::json!({ "ok": true, "message": message }))?;
            } else {
                println!("{message}");
            }
            Ok(())
        }
    }
}

fn handle_account(command: AccountCommand, config: &CloakConfig) -> Result<()> {
    match command {
        AccountCommand::List { json } => {
            let accounts = list_accounts(config)?;
            if json {
                print_json(&accounts)?;
            } else {
                for account in accounts {
                    println!(
                        "{}\tseed {}\tregion {}\tlocale {}\tproxy {}",
                        account.name,
                        account.seed,
                        account.region.unwrap_or_else(|| "-".to_string()),
                        if account.locale_enabled { "on" } else { "off" },
                        account.proxy_display
                    );
                }
            }
        }
        AccountCommand::Create { name, json } => {
            let account = create_account(config, &name)?;
            print_account(account, json)?;
        }
        AccountCommand::Rename { old, new, json } => {
            let account = rename_account(config, &old, &new)?;
            print_account(account, json)?;
        }
        AccountCommand::Delete { name } => {
            delete_account(config, &name)?;
            println!("deleted: {name}");
        }
        AccountCommand::SetProxy {
            name,
            value,
            clear,
            json,
        } => {
            let account = set_proxy(config, &name, if clear { None } else { value.as_deref() })?;
            print_account(account, json)?;
        }
        AccountCommand::SetRegion {
            name,
            value,
            clear,
            json,
        } => {
            let account = set_region(config, &name, if clear { None } else { value.as_deref() })?;
            print_account(account, json)?;
        }
        AccountCommand::ToggleLocale { name, json } => {
            let account = toggle_locale(config, &name)?;
            print_account(account, json)?;
        }
        AccountCommand::Show { name, json } => {
            let account = read_account(config, &name)?;
            print_account(account, json)?;
        }
    }
    Ok(())
}

fn handle_launch(args: LaunchArgs, config: &CloakConfig) -> Result<()> {
    let mut options = LaunchOptions::from_env(args.dry_run);
    if args.skip_geo {
        options.skip_geo = true;
    }

    if args.dry_run {
        let plan = build_launch_plan(config, &args.name, &options)?;
        if args.json {
            print_json(&plan)?;
        } else {
            println!("account : {}", plan.account);
            println!("seed    : {}", plan.seed);
            println!(
                "exit ip : {}",
                plan.geo.exit_ip.as_deref().unwrap_or("unknown")
            );
            println!(
                "timezone: {}",
                plan.geo.timezone.as_deref().unwrap_or("unknown")
            );
            println!(
                "locale  : {}",
                plan.locale.as_deref().unwrap_or("off (navigator.languages = browser default)")
            );
            println!("proxy   : {}", plan.proxy.display);
            if plan.extra_extension_paths.is_empty() {
                println!("plugins : none");
            } else {
                println!(
                    "plugins : {}",
                    plan.extra_extension_paths
                        .iter()
                        .map(|path| path.display().to_string())
                        .collect::<Vec<_>>()
                        .join(" ")
                );
                println!(
                    "selftest plugins: {}",
                    if plan.selftest_extension_paths.is_empty() {
                        "none".to_string()
                    } else {
                        plan.selftest_extension_paths
                            .iter()
                            .map(|path| path.display().to_string())
                            .collect::<Vec<_>>()
                            .join(" ")
                    }
                );
            }
            println!("profile : {}", plan.profile_path.display());
            println!("binary  : {}", plan.browser_binary.display());
            print!("argv    : {}", plan.browser_binary.display());
            for arg in &plan.argv {
                print!(" {}", shell_escape(arg));
            }
            println!();
            if !plan.privacy_failures.is_empty() {
                eprintln!("privacy failures:");
                for failure in &plan.privacy_failures {
                    eprintln!("- {failure}");
                }
            }
        }
        return Ok(());
    }

    launch_account(config, &args.name, &options)?;
    Ok(())
}

fn print_account(account: cloak_core::Account, json: bool) -> Result<()> {
    if json {
        print_json(&account)?;
    } else {
        println!("account : {}", account.name);
        println!("seed    : {}", account.seed);
        println!("profile : {}", account.profile_path.display());
        println!("region  : {}", account.region.unwrap_or_else(|| "-".to_string()));
        println!("locale  : {}", if account.locale_enabled { "on" } else { "off" });
        println!("proxy   : {}", account.proxy_display);
    }
    Ok(())
}

fn print_json<T: serde::Serialize>(value: &T) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

fn shell_escape(value: &str) -> String {
    if value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'.' | b'-' | b'_' | b':' | b'=' | b'@'))
    {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}
