const COMMANDS: &[&str] = &["track", "identify", "set_consent", "flush", "status"];

fn main() {
    tauri_plugin::Builder::new(COMMANDS).build();
}
