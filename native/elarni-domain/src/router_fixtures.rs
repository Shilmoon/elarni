//! Compiled configs that Vendor/libXray/share/compiled_routing_test.go loads into
//! Xray's router, so routing changes here are checked against the real matcher.
use serde_json::{Value, json};

use crate::compiler::compile_xray_outbound_config_with_options;
use crate::model::{PacketBackend, PreferredIp, RouteModel, RuntimeOptions};
use crate::profile::compile_profile;

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Vendor/libXray/share/testdata/compiled_routing.json"
);

fn compiled_fixtures() -> Value {
    let client = |tag: &str| {
        json!({"tag": tag, "protocol": "vless", "settings": {"address": "127.0.0.1", "port": 1,
            "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}})
    };
    // Every hostname the router resolves is in dns.hosts, so the tests stay offline. The
    // DNS policy loads the remote resolver's timeout and its route into the real core.
    let routes: RouteModel = serde_json::from_value(json!({
        "rules": [
            {"action": "block", "domains": ["full:blocked.test"], "ips": []},
            {"action": "direct", "domains": [], "ips": ["198.51.100.0/24"]}],
        "dnsServers": ["192.0.2.53"],
        "dnsPolicy": {"remote": {"address": "192.0.2.53"}, "domestic": {"address": "192.0.2.54"}},
        "staticHosts": {"direct-range.test": ["198.51.100.7"], "outside.test": ["203.0.113.9"]},
        "fallbackAction": "proxy", "domainStrategy": "IPIfNonMatch"}))
    .unwrap();
    let (outbound, _) = compile_xray_outbound_config_with_options(
        client("node"),
        &routes,
        10890,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions::default(),
    )
    .unwrap();
    // App proxy traffic re-enters the provider policy through a loopback.
    let overlay: RouteModel = serde_json::from_value(json!({
        "rules": [{"action": "block", "domains": ["full:blocked.test"], "ips": []}],
        "dnsServers": ["192.0.2.53"], "fallbackAction": "proxy", "domainStrategy": "IPIfNonMatch"}))
    .unwrap();
    let profile = compile_profile(
        json!({
            "outbounds": [client("proxy"),
                {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}}],
            "dns": {"servers": ["192.0.2.53"], "hosts": {"loopback-range.test": "127.0.0.1"}},
            "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
                {"type": "field", "ip": ["127.0.0.0/8"], "outboundTag": "direct"}]}}),
        Some(&overlay),
        10890,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions::default(),
        None,
    )
    .unwrap();
    // Proxy mode with automatic IP preference dials direct names AsIs; the
    // DnsHosts pin is the only address the pinned name has.
    let pinned: RouteModel = serde_json::from_value(json!({
        "rules": [{"action": "direct", "domains": ["full:pinned-direct.test"], "ips": []}],
        "dnsServers": ["192.0.2.53"],
        "staticHosts": {"pinned-direct.test": ["127.0.0.1"]},
        "fallbackAction": "proxy"}))
    .unwrap();
    let (automatic_ip, _) = compile_xray_outbound_config_with_options(
        client("node"),
        &pinned,
        10890,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions {
            preferred_ip: PreferredIp::Automatic,
            ..RuntimeOptions::default()
        },
    )
    .unwrap();
    // Per-app routing with several targets: each target's apps share a rule of their own.
    let per_app = compile_profile(
        json!({"outbounds": [client("proxy"),
            {"tag": "direct", "protocol": "freedom", "settings": {}}]}),
        None,
        10890,
        PacketBackend::XrayTun,
        1500,
        &serde_json::from_value::<RuntimeOptions>(json!({
            "perAppMode": "proxyOnly",
            "perAppProcesses": ["/opt/listed", "/opt/blocked", "/opt/direct"],
            "perAppTargets": [{"process": "/opt/blocked", "target": "block"},
                {"process": "/opt/direct", "target": "direct"}]}))
        .unwrap(),
        None,
    )
    .unwrap();
    json!({
        "outbound": serde_json::from_slice::<Value>(&outbound).unwrap(),
        "profile": serde_json::from_slice::<Value>(&profile.config).unwrap(),
        "automatic-ip": serde_json::from_slice::<Value>(&automatic_ip).unwrap(),
        "per-app": serde_json::from_slice::<Value>(&per_app.config).unwrap(),
    })
}

#[test]
fn go_router_fixture_matches_the_compiler() {
    let expected = compiled_fixtures();
    if std::env::var_os("ELARNI_UPDATE_FIXTURES").is_some() {
        std::fs::write(
            FIXTURE,
            serde_json::to_string_pretty(&expected).unwrap() + "\n",
        )
        .unwrap();
    }
    let committed: Value =
        serde_json::from_str(&std::fs::read_to_string(FIXTURE).unwrap()).unwrap();
    assert_eq!(
        committed, expected,
        "stale fixture: run ELARNI_UPDATE_FIXTURES=1 cargo test -p elarni-domain go_router_fixture"
    );
}
