fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "set_native_webview_zoom",
            "start_blob_download",
            "append_blob_download",
            "finish_blob_download",
            "cancel_blob_download",
        ]),
    ))
    .expect("failed to run build script");
}
