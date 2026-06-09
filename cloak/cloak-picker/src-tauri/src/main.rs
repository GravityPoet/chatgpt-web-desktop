fn main() {
    match cloak_core::maybe_run_relay_supervisor() {
        Ok(true) => return,
        Ok(false) => {}
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    }
    cloak_picker_lib::run();
}
