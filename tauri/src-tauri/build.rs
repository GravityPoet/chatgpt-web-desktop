fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "set_native_webview_zoom",
            "start_blob_download",
            "append_blob_download",
            "finish_blob_download",
            "cancel_blob_download",
            "cmd_create_profile",
            "cmd_clone_profile",
            "cmd_rename_profile",
            "cmd_delete_profile",
            "cmd_set_homepage",
            "cmd_import_cookies",
            "cmd_export_cookies",
            "cmd_import_profile",
            "cmd_burn_current_profile",
        ]),
    ))
    .expect("failed to run build script");
}
