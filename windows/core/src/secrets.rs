//! Passwords and API keys live in the operating system's secret store (Windows Credential Manager; the macOS Keychain when run on a Mac), never in the database or in logs.
pub trait SecretStore: Send + Sync {
    fn get(&self, key: &str) -> Option<String>;
    fn set(&self, key: &str, value: &str) -> Result<(), String>;
    fn delete(&self, key: &str);
}

/// The desktop secret store. Android has none reachable from Rust, so the Android app supplies its own `SecretStore`.
#[cfg(not(target_os = "android"))]
pub struct OsSecrets { service: String }
#[cfg(not(target_os = "android"))]
impl OsSecrets { pub fn new(service: &str) -> Self { OsSecrets { service: service.into() } } }
#[cfg(not(target_os = "android"))]
impl SecretStore for OsSecrets {
    fn get(&self, key: &str) -> Option<String> { keyring::Entry::new(&self.service, key).ok()?.get_password().ok() }
    fn set(&self, key: &str, value: &str) -> Result<(), String> { keyring::Entry::new(&self.service, key).map_err(|e| e.to_string())?.set_password(value).map_err(|e| e.to_string()) }
    fn delete(&self, key: &str) { if let Ok(e) = keyring::Entry::new(&self.service, key) { let _ = e.delete_credential(); } }
}

/// For tests and previews: nothing touches the real store.
#[derive(Default)]
pub struct MemorySecrets(std::sync::Mutex<std::collections::HashMap<String, String>>);
impl MemorySecrets {
    /// Every key and value held, for handing changed secrets back to a platform store (Android).
    pub fn entries(&self) -> Vec<(String, String)> { self.0.lock().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect() }
}
impl SecretStore for MemorySecrets {
    fn get(&self, key: &str) -> Option<String> { self.0.lock().unwrap().get(key).cloned() }
    fn set(&self, key: &str, value: &str) -> Result<(), String> { self.0.lock().unwrap().insert(key.into(), value.into()); Ok(()) }
    fn delete(&self, key: &str) { self.0.lock().unwrap().remove(key); }
}

/// App passwords are pasted with spaces ("abcd efgh ijkl mnop"); the server wants them without.
pub fn clean_app_password(p: &str) -> String { p.chars().filter(|c| !c.is_whitespace()).collect() }
pub fn password_key(email: &str) -> String { format!("imap.password.{}", email.to_lowercase()) }

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn memory_store_round_trip() { let s = MemorySecrets::default(); assert!(s.get("k").is_none()); s.set("k", "v").unwrap(); assert_eq!(s.get("k").as_deref(), Some("v")); s.delete("k"); assert!(s.get("k").is_none()); }
    #[test] fn app_passwords_lose_their_spaces_and_keys_are_lowercase() { assert_eq!(clean_app_password("abcd efgh\tijkl mnop"), "abcdefghijklmnop"); assert_eq!(password_key("Me@Example.COM"), "imap.password.me@example.com"); }
}
