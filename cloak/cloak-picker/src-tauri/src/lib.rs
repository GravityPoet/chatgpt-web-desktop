use cloak_core::{
    build_launch_plan, create_account as core_create_account,
    delete_account as core_delete_account, launch_account as core_launch_account,
    list_accounts as core_list_accounts, list_archived_accounts as core_list_archived_accounts,
    list_trashed_accounts as core_list_trashed_accounts, rename_account as core_rename_account,
    set_account_archived as core_set_account_archived,
    set_account_trashed as core_set_account_trashed, set_proxy as core_set_proxy,
    set_region as core_set_region, toggle_locale as core_toggle_locale, Account, CloakConfig,
    LaunchOptions, LaunchPlan,
};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

fn config() -> Result<CloakConfig, String> {
    CloakConfig::from_env().map_err(|err| err.to_string())
}

#[tauri::command]
fn list_accounts() -> Result<Vec<Account>, String> {
    core_list_accounts(&config()?).map_err(|err| err.to_string())
}

#[tauri::command]
fn list_archived_accounts() -> Result<Vec<Account>, String> {
    core_list_archived_accounts(&config()?).map_err(|err| err.to_string())
}

#[tauri::command]
fn list_trashed_accounts() -> Result<Vec<Account>, String> {
    core_list_trashed_accounts(&config()?).map_err(|err| err.to_string())
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
fn restore_account(name: String) -> Result<Account, String> {
    core_set_account_trashed(&config()?, &name, false).map_err(|err| err.to_string())
}

#[tauri::command]
fn archive_account(name: String, archived: bool) -> Result<Account, String> {
    core_set_account_archived(&config()?, &name, archived).map_err(|err| err.to_string())
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
    options.skip_geo = true;
    build_launch_plan(&config()?, &name, &options).map_err(|err| err.to_string())
}

#[tauri::command]
fn launch_preflight(name: String) -> Result<LaunchPlan, String> {
    let mut options = LaunchOptions::from_env(true);
    options.dry_run = true;
    options.skip_geo = false;
    build_launch_plan(&config()?, &name, &options).map_err(|err| err.to_string())
}

#[tauri::command]
fn launch_account(name: String) -> Result<(), String> {
    let options = LaunchOptions::from_env(false);
    core_launch_account(&config()?, &name, &options).map_err(|err| err.to_string())
}

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Regular);

            let window = if let Some(window) = app.get_webview_window("main") {
                window
            } else {
                WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                    .title("Cloak Picker")
                    .inner_size(920.0, 620.0)
                    .min_inner_size(760.0, 540.0)
                    .visible(true)
                    .center()
                    .build()?
            };
            let _ = window.unminimize();
            let _ = window.center();
            window.show()?;
            window.set_focus()?;
            focus_main_window_after_launch(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_accounts,
            list_archived_accounts,
            list_trashed_accounts,
            create_account,
            rename_account,
            delete_account,
            restore_account,
            archive_account,
            set_proxy,
            set_region,
            toggle_locale,
            launch_dry_run,
            launch_preflight,
            launch_account
        ])
        .run(tauri::generate_context!())
        .expect("error while running Cloak picker");
}

#[cfg(target_os = "macos")]
fn focus_main_window_after_launch(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(250));
        let app_for_main_thread = app.clone();
        let _ = app.run_on_main_thread(move || {
            let _ = app_for_main_thread.show();
            if let Some(window) = app_for_main_thread.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        });
    });
}

#[cfg(not(target_os = "macos"))]
fn focus_main_window_after_launch(_: tauri::AppHandle) {}
