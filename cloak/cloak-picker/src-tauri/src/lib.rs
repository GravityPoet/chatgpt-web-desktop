use cloak_core::{
    build_launch_plan, create_account as core_create_account,
    delete_account as core_delete_account, launch_account as core_launch_account,
    list_accounts as core_list_accounts, rename_account as core_rename_account,
    set_proxy as core_set_proxy, set_region as core_set_region,
    toggle_locale as core_toggle_locale, Account, CloakConfig, LaunchOptions, LaunchPlan,
};

fn config() -> Result<CloakConfig, String> {
    CloakConfig::from_env().map_err(|err| err.to_string())
}

#[tauri::command]
fn list_accounts() -> Result<Vec<Account>, String> {
    core_list_accounts(&config()?).map_err(|err| err.to_string())
}

#[tauri::command]
fn create_account(name: String) -> Result<Account, String> {
    core_create_account(&config()?, &name).map_err(|err| err.to_string())
}

#[tauri::command]
fn rename_account(old_name: String, new_name: String) -> Result<Account, String> {
    core_rename_account(&config()?, &old_name, &new_name).map_err(|err| err.to_string())
}

#[tauri::command]
fn delete_account(name: String) -> Result<(), String> {
    core_delete_account(&config()?, &name).map_err(|err| err.to_string())
}

#[tauri::command]
fn set_proxy(name: String, value: Option<String>) -> Result<Account, String> {
    core_set_proxy(&config()?, &name, value.as_deref()).map_err(|err| err.to_string())
}

#[tauri::command]
fn set_region(name: String, value: Option<String>) -> Result<Account, String> {
    core_set_region(&config()?, &name, value.as_deref()).map_err(|err| err.to_string())
}

#[tauri::command]
fn toggle_locale(name: String) -> Result<Account, String> {
    core_toggle_locale(&config()?, &name).map_err(|err| err.to_string())
}

#[tauri::command]
fn launch_dry_run(name: String) -> Result<LaunchPlan, String> {
    let mut options = LaunchOptions::from_env(true);
    options.dry_run = true;
    build_launch_plan(&config()?, &name, &options).map_err(|err| err.to_string())
}

#[tauri::command]
fn launch_account(name: String) -> Result<(), String> {
    let options = LaunchOptions::from_env(false);
    core_launch_account(&config()?, &name, &options).map_err(|err| err.to_string())
}

pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            list_accounts,
            create_account,
            rename_account,
            delete_account,
            set_proxy,
            set_region,
            toggle_locale,
            launch_dry_run,
            launch_account
        ])
        .run(tauri::generate_context!())
        .expect("error while running Cloak picker");
}

