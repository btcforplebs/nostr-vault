//! The app links one fips. libnvfips takes fips directly and again through
//! web-relay-vault; if their pins differ, Cargo builds both and the relay link
//! runs on a second copy of the node's types.

const LOCK: &str = include_str!("../Cargo.lock");

/// The `source` line of every `[[package]]` built from the fips crate.
fn fips_sources() -> Vec<&'static str> {
    LOCK.split("[[package]]")
        .filter(|pkg| pkg.contains("\nname = \"fips\"\n") || pkg.contains("\nname = \"fips-mesh\"\n"))
        .filter_map(|pkg| pkg.lines().find(|l| l.starts_with("source = ")))
        .collect()
}

#[test]
fn one_fips_in_the_lock() {
    let sources = fips_sources();
    assert_eq!(sources.len(), 1, "{sources:#?}");
}

#[test]
fn fips_is_v0_5_3() {
    let pkg = LOCK
        .split("[[package]]")
        .find(|pkg| pkg.contains("\nname = \"fips-mesh\"\n"))
        .expect("fips-mesh in Cargo.lock");
    assert!(pkg.contains("\nversion = \"0.5.3\"\n"), "{pkg}");
}

/// fips v0.5.3 moved rustls to 0.23.46 for RUSTSEC-2026-0346..0349. A rev bump
/// leaves transitive deps where the lock had them, so check ours moved too.
#[test]
fn rustls_has_the_v0_5_3_advisory_fixes() {
    for pkg in LOCK.split("[[package]]").filter(|p| p.contains("\nname = \"rustls\"\n")) {
        let v = pkg.lines().find_map(|l| l.strip_prefix("version = \"")).expect("version").trim_end_matches('"');
        let patch: u32 = v.strip_prefix("0.23.").expect("rustls 0.23.x").parse().unwrap();
        assert!(patch >= 46, "rustls {v} predates the v0.5.3 TLS advisory fixes");
    }
}
