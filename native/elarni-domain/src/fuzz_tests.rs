//! Mutation fuzzing of the provider-facing parsers that `cargo test` runs on stable:
//! cargo-fuzz needs a nightly toolchain that CI does not carry. Each target mutates the
//! fixtures of this crate's tests and keeps the mutants it accepts, so later rounds go
//! deeper. `ELARNI_FUZZ_ITERATIONS=200000 cargo test -p elarni-domain fuzz_ -- --nocapture`
//! runs longer and then also fails an input slower than a second; `ELARNI_FUZZ_SEED`
//! picks another sequence. A failure prints the input that caused it.
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Debug;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use crate::compiler::{compile_xray_config, compile_xray_outbound_config_with_options};
use crate::model::{
    CompileRequest, PacketBackend, RouteModel, RuntimeOptions, SecretMaterial, SecretRef,
};
use crate::parser::parse_hy2_uri;
use crate::profile::{compile_profile, prepare_config, profile_endpoints};
use crate::routing::{ManagedMatchMode, decode_routing, parse_managed_domains};

const SOURCES: &[&str] = &[
    include_str!("tests.rs"),
    include_str!("profile_tests.rs"),
    include_str!("vless_tests.rs"),
    include_str!("router_fixtures.rs"),
];
const GO_FIXTURE: &str =
    include_str!("../../../Vendor/libXray/share/testdata/compiled_routing.json");

const TOKENS: &[&str] = &[
    "%",
    "%25",
    "%ff",
    "%00",
    "%2C",
    ":",
    "@",
    ",",
    "-",
    "[",
    "]",
    "[::1]",
    "?",
    "&",
    "=",
    "#",
    "/",
    "0",
    "1",
    "5",
    "3600",
    "65535",
    "65536",
    "4294967296",
    "-1",
    "+1",
    "é",
    "\u{202e}",
    " ",
    "\n",
    "\"",
    "\\",
    "{",
    "}",
    "null",
    "hy2://",
    "hysteria2://",
    "auth=",
    "port=",
    "ports=",
    "mportHopInt=",
    "hop-interval=",
    "obfs=salamander",
    "obfs-password=",
    "insecure=1",
    "security=",
    "alpn=",
    "sni=",
    "fp=",
    "up=",
    "down=",
    "full:",
    "domain:",
    "regexp:",
    "geosite:",
    "geoip:",
    "happ://routing/add/",
    "incy://routing/onadd/",
    "routing/off",
];

struct Fuzzer {
    state: u64,
    iterations: usize,
    long: bool,
}

impl Fuzzer {
    fn new() -> Self {
        let env = |name| {
            std::env::var(name)
                .ok()
                .and_then(|value| value.parse().ok())
        };
        let iterations: Option<u64> = env("ELARNI_FUZZ_ITERATIONS");
        Self {
            state: env("ELARNI_FUZZ_SEED").unwrap_or(0x9E37_79B9_7F4A_7C15) | 1,
            iterations: iterations.unwrap_or(1_000) as usize,
            long: iterations.is_some(),
        }
    }

    fn next(&mut self) -> u64 {
        // xorshift64*: enough spread for choosing mutations, no dependency.
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        self.state.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, bound: usize) -> usize {
        (self.next() % bound.max(1) as u64) as usize
    }

    /// Checks the seeds, then mutants of the corpus; `check` reports whether it accepted one.
    fn run<T: Clone + Debug>(
        &mut self,
        name: &str,
        seeds: Vec<T>,
        mutate: impl Fn(&mut Self, &T, &[T]) -> T,
        check: impl Fn(&T) -> bool,
    ) {
        assert!(!seeds.is_empty(), "{name}: no seeds");
        let limit = seeds.len() + 4096;
        let mut corpus = seeds.clone();
        for seed in &seeds {
            self.check_one(name, seed, &check);
        }
        let started = Instant::now();
        for _ in 0..self.iterations {
            let parent = &corpus[self.below(corpus.len())];
            let input = mutate(self, parent, &corpus);
            if self.check_one(name, &input, &check) && corpus.len() < limit {
                corpus.push(input);
            }
        }
        let elapsed = started.elapsed();
        eprintln!(
            "{name}: {} seeds, {} mutants in {elapsed:.1?} ({:.0}/s), {} accepted kept",
            seeds.len(),
            self.iterations,
            self.iterations as f64 / elapsed.as_secs_f64().max(1e-9),
            corpus.len() - seeds.len()
        );
    }

    fn check_one<T: Debug>(&self, name: &str, input: &T, check: &impl Fn(&T) -> bool) -> bool {
        let started = Instant::now();
        let accepted = match catch_unwind(AssertUnwindSafe(|| check(input))) {
            Ok(accepted) => accepted,
            Err(panic) => {
                eprintln!("{name} failed on input: {input:?}");
                resume_unwind(panic)
            }
        };
        let elapsed = started.elapsed();
        assert!(
            !self.long || elapsed < Duration::from_secs(1),
            "{name} took {elapsed:?} on input: {input:?}"
        );
        accepted
    }
}

fn mutate_text(fuzzer: &mut Fuzzer, seed: &String, corpus: &[String]) -> String {
    let mut bytes = seed.as_bytes().to_vec();
    for _ in 0..=fuzzer.below(4) {
        let at = fuzzer.below(bytes.len() + 1);
        let span = 1 + fuzzer.below(16);
        match fuzzer.below(6) {
            0 if at < bytes.len() => bytes[at] ^= 1 << fuzzer.below(8),
            1 if at < bytes.len() => drop(bytes.drain(at..(at + span).min(bytes.len()))),
            2 if at < bytes.len() => {
                let copy = bytes[at..(at + span).min(bytes.len())].to_vec();
                bytes.splice(at..at, copy);
            }
            3 if !corpus.is_empty() => {
                let other = corpus[fuzzer.below(corpus.len())].as_bytes();
                let from = fuzzer.below(other.len() + 1);
                let to = (from + span * 4).min(other.len());
                bytes.splice(at..at, other[from..to].iter().copied());
            }
            4 => bytes.insert(at, fuzzer.next() as u8),
            _ => drop(bytes.splice(at..at, TOKENS[fuzzer.below(TOKENS.len())].bytes())),
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

/// A random node: each level stops with probability 1/3 or at a leaf.
fn pick<'a>(fuzzer: &mut Fuzzer, mut value: &'a mut Value) -> &'a mut Value {
    loop {
        let children = match &*value {
            Value::Object(map) => map.len(),
            Value::Array(items) => items.len(),
            _ => 0,
        };
        if children == 0 || fuzzer.below(3) == 0 {
            return value;
        }
        let index = fuzzer.below(children);
        value = match value {
            Value::Object(map) => map.values_mut().nth(index).expect("index below length"),
            Value::Array(items) => &mut items[index],
            _ => unreachable!("only containers have children"),
        };
    }
}

/// Replaces, removes, duplicates or adds nodes, taking subtrees and keys from `donors`.
fn mutate_json(fuzzer: &mut Fuzzer, seed: &Value, donors: &[Value], keys: &[String]) -> Value {
    let mut value = seed.clone();
    for _ in 0..=fuzzer.below(3) {
        let mut donor = donors[fuzzer.below(donors.len())].clone();
        let donor = pick(fuzzer, &mut donor).clone();
        let numbers = [
            json!(0),
            json!(-1),
            json!(1),
            json!(443),
            json!(65535),
            json!(65536),
            json!(u64::MAX),
            json!(i64::MIN),
            json!(0.5),
            json!(1e308),
        ];
        let choice = fuzzer.below(10);
        let number = numbers[fuzzer.below(numbers.len())].clone();
        let key = keys[fuzzer.below(keys.len())].clone();
        let node = pick(fuzzer, &mut value);
        match choice {
            0 => *node = Value::Null,
            1 => *node = Value::Bool(fuzzer.below(2) == 0),
            2 => *node = number,
            3 => {
                *node = json!(mutate_text(
                    fuzzer,
                    &node.as_str().unwrap_or("").to_owned(),
                    &[]
                ))
            }
            4 => *node = json!([]),
            5 => *node = json!({}),
            6 => *node = donor,
            7 => match node {
                Value::Object(map) if !map.is_empty() => {
                    let key = map.keys().nth(fuzzer.below(map.len())).cloned();
                    map.remove(&key.expect("index below length"));
                }
                Value::Array(items) if !items.is_empty() => {
                    let index = fuzzer.below(items.len());
                    if fuzzer.below(2) == 0 {
                        items.remove(index);
                    } else {
                        items.insert(index, items[index].clone());
                    }
                }
                _ => *node = donor,
            },
            _ => match node {
                Value::Object(map) => drop(map.insert(key, donor)),
                Value::Array(items) => items.push(donor),
                _ => *node = donor,
            },
        }
    }
    value
}

/// The JSON values written as `json!(...)` in this crate's tests that parse as plain JSON.
fn fixture_values() -> Vec<Value> {
    let mut values = Vec::new();
    for source in SOURCES {
        for (start, _) in source.match_indices("json!(") {
            let text = &source[start + 6..];
            let (mut depth, mut quoted, mut escaped) = (0usize, false, false);
            for (index, c) in text.char_indices() {
                match c {
                    _ if escaped => escaped = false,
                    '\\' if quoted => escaped = true,
                    '"' => quoted = !quoted,
                    '{' | '[' if !quoted => depth += 1,
                    '}' | ']' if !quoted => {
                        depth = depth.saturating_sub(1);
                        if depth == 0 {
                            if let Ok(value) = serde_json::from_str(&expand_nodes(&text[..=index]))
                            {
                                values.push(value);
                            }
                            break;
                        }
                    }
                    _ if depth == 0 && !c.is_whitespace() => break,
                    _ => {}
                }
            }
        }
    }
    values
}

/// Writes out the `node("tag", "address")` calls that most profile fixtures use.
fn expand_nodes(text: &str) -> String {
    let (mut expanded, mut rest) = (String::new(), text);
    while let Some(start) = rest.find("node(\"") {
        expanded.push_str(&rest[..start]);
        rest = &rest[start + 6..];
        let call = rest.split_once("\", \"").and_then(|(tag, tail)| {
            let (address, tail) = tail.split_once("\")")?;
            (!tag.contains('"') && !address.contains('"')).then_some((tag, address, tail))
        });
        match call {
            Some((tag, address, tail)) => {
                expanded.push_str(&crate::profile_tests::node(tag, address).to_string());
                rest = tail;
            }
            None => expanded.push_str("node(\""),
        }
    }
    expanded + rest
}

fn keys_of(value: &Value, keys: &mut BTreeSet<String>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                keys.insert(key.clone());
                keys_of(child, keys);
            }
        }
        Value::Array(items) => items.iter().for_each(|child| keys_of(child, keys)),
        _ => {}
    }
}

fn routes() -> RouteModel {
    serde_json::from_value(json!({
        "rules": [{"action": "block", "domains": ["full:blocked.test"], "ips": []},
            {"action": "direct", "domains": ["geosite:private"], "ips": ["198.51.100.0/24"]}],
        "dnsServers": ["192.0.2.53"], "staticHosts": {"pinned.test": ["203.0.113.9"]},
        "fallbackAction": "proxy", "domainStrategy": "IPIfNonMatch"}))
    .expect("fixture routes")
}

fn reference(id: &str) -> SecretRef {
    SecretRef { id: id.to_owned() }
}

#[test]
fn fuzz_hy2_uri_parser_and_compiler() {
    let mut seeds = BTreeSet::new();
    for source in SOURCES {
        for scheme in ["\"hy2://", "\"hysteria2://"] {
            for (start, _) in source.match_indices(scheme) {
                let literal = &source[start + 1..];
                if let Some(end) = literal.find('"') {
                    seeds.insert(literal[..end].to_owned());
                }
            }
        }
    }
    let routes = routes();
    Fuzzer::new().run("hy2", seeds.into_iter().collect(), mutate_text, |uri| {
        let _ = parse_hy2_uri(uri, reference("fuzz.auth"), None);
        let Ok(parsed) = parse_hy2_uri(uri, reference("fuzz.auth"), Some(reference("fuzz.obfs")))
        else {
            return false;
        };
        let endpoint = &parsed.endpoint;
        assert!(
            !endpoint.host.is_empty() && endpoint.port != 0 && !parsed.authentication.is_empty()
        );
        // ffi.rs expects the obfuscation metadata whenever a password comes back.
        assert_eq!(
            parsed.obfuscation_password.is_some(),
            endpoint.obfuscation.is_some()
        );
        let request = CompileRequest {
            endpoint: parsed.endpoint,
            authentication: SecretMaterial {
                secret_ref: reference("fuzz.auth"),
                value: parsed.authentication,
            },
            obfuscation_password: parsed.obfuscation_password.map(|value| SecretMaterial {
                secret_ref: reference("fuzz.obfs"),
                value,
            }),
            routes: routes.clone(),
            socks_port: 1080,
            packet_backend: PacketBackend::NativeTun2Proxy,
            tun_mtu: 1500,
            runtime: RuntimeOptions::default(),
        };
        if let Ok(config) = compile_xray_config(&request) {
            serde_json::from_slice::<Value>(&config).expect("compiled config is JSON");
        }
        true
    });
}

#[test]
fn fuzz_routing_imports() {
    let mut seeds = vec![
        "happ://routing/off".to_owned(),
        "example.com\n# comment\nsub.example.org".to_owned(),
    ];
    // Every field a Happ routing profile can set, beside the tests' minimal one.
    let full = json!({"Name": "fuzz", "GlobalProxy": "true", "RouteOrder": "direct-block-proxy",
        "RemoteDNSType": "DoH", "RemoteDNSDomain": "https://dns.example/dns-query", "RemoteDNSIP": "1.1.1.1",
        "DomesticDNSType": "DoU", "DomesticDNSIP": "8.8.8.8", "DomesticDNSDomains": ["domain:example.org"],
        "DnsHosts": {"dns.example": "1.1.1.1"}, "DirectSites": ["geosite:private", "full:direct.example"],
        "DirectIp": ["geoip:private", "10.0.0.0/8"], "ProxySites": ["domain:proxy.example"],
        "ProxyIp": ["203.0.113.0/24"], "BlockSites": ["regexp:^ads\\."], "BlockIp": ["198.51.100.1"],
        "DomainStrategy": "IPIfNonMatch", "FakeDNS": "true"});
    assert!(
        decode_routing(&full.to_string()).is_ok(),
        "full routing seed"
    );
    for value in fixture_values()
        .into_iter()
        .chain([full])
        .filter(|value| decode_routing(&value.to_string()).is_ok())
    {
        let encoded = STANDARD.encode(value.to_string());
        seeds.extend([
            value.to_string(),
            format!("happ://routing/add/{encoded}"),
            format!("incy://routing/onadd/{encoded}"),
        ]);
    }
    Fuzzer::new().run("routing", seeds, mutate_text, |input| {
        for mode in [ManagedMatchMode::Exact, ManagedMatchMode::Subdomains] {
            let _ = parse_managed_domains(input, mode);
        }
        match decode_routing(input) {
            Ok(import) => {
                serde_json::to_value(&import).expect("routing import serializes");
                true
            }
            Err(_) => false,
        }
    });
}

#[test]
fn fuzz_profile_compiler() {
    // Profiles and lone outbounds seed the corpus; every fixture value donates subtrees and keys.
    let mut donors = fixture_values();
    let compiled: BTreeMap<String, Value> = serde_json::from_str(GO_FIXTURE).expect("Go fixture");
    donors.extend(compiled.into_values());
    let seeds: Vec<Value> = donors
        .iter()
        .filter_map(|value| {
            if value.get("outbounds").is_some() {
                Some(value.clone())
            } else {
                value.get("protocol").map(|_| json!({"outbounds": [value]}))
            }
        })
        .collect();
    let mut keys = BTreeSet::new();
    donors.iter().for_each(|donor| keys_of(donor, &mut keys));
    let keys: Vec<String> = keys.into_iter().collect();
    let (routes, runtime) = (routes(), RuntimeOptions::default());
    let mutate =
        |fuzzer: &mut Fuzzer, seed: &Value, _: &[Value]| mutate_json(fuzzer, seed, &donors, &keys);
    Fuzzer::new().run("profile", seeds, mutate, |profile| {
        if let Ok(endpoints) = profile_endpoints(profile) {
            let resolved = endpoints
                .iter()
                .map(|endpoint| (endpoint.host.clone(), "192.0.2.1".to_owned()))
                .collect();
            let _ = prepare_config(
                profile.clone(),
                &resolved,
                &BTreeSet::new(),
                true,
                &BTreeSet::new(),
            );
        }
        for outbound in profile["outbounds"].as_array().into_iter().flatten() {
            if let Ok((config, _)) = compile_xray_outbound_config_with_options(
                outbound.clone(),
                &routes,
                1080,
                PacketBackend::XrayTun,
                1500,
                &runtime,
            ) {
                serde_json::from_slice::<Value>(&config).expect("compiled outbound is JSON");
            }
        }
        let mut accepted = false;
        for (overlay, backend) in [
            (None, PacketBackend::NativeTun2Proxy),
            (Some(&routes), PacketBackend::XrayTun),
        ] {
            if let Ok(result) = compile_profile(
                profile.clone(),
                overlay,
                1080,
                backend,
                1500,
                &runtime,
                None,
            ) {
                let config: Value =
                    serde_json::from_slice(&result.config).expect("compiled profile is JSON");
                let _ = profile_endpoints(&config);
                accepted = true;
            }
        }
        accepted
    });
}
