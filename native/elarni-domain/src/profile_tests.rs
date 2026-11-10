use crate::model::{PacketBackend, PreferredIp, RouteModel, RuntimeOptions};
use crate::profile::compile_profile;
use serde_json::{Value, json};

pub(crate) fn node(tag: &str, address: &str) -> Value {
    json!({"tag": tag, "protocol": "vless", "settings": {
        "address": address, "port": 443, "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"
    }, "streamSettings": {"network": "raw", "security": "tls", "tlsSettings": {"serverName": "peer.example.com"}}})
}

fn compile(profile: Value, routes: Option<&RouteModel>) -> Value {
    let result = compile_profile(
        profile,
        routes,
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions::default(),
        None,
    )
    .unwrap();
    serde_json::from_slice(&result.config).unwrap()
}

#[test]
fn app_domain_strategy_overrides_provider_independently_of_dns_and_backend() {
    use crate::model::ProfileDnsMode;
    for provider in [None, Some("AsIs"), Some("IPIfNonMatch"), Some("IPOnDemand")] {
        for requested in [None, Some("AsIs"), Some("IPIfNonMatch"), Some("IPOnDemand")] {
            for provider_dns in [false, true] {
                for mode in [
                    ProfileDnsMode::Inherit,
                    ProfileDnsMode::Routing,
                    ProfileDnsMode::Default,
                ] {
                    for backend in [PacketBackend::NativeTun2Proxy, PacketBackend::XrayTun] {
                        let mut profile = json!({"outbounds": [node("provider", "edge.example.com")], "routing": {"rules": []}});
                        if let Some(strategy) = provider {
                            profile["routing"]["domainStrategy"] = json!(strategy);
                        }
                        if provider_dns {
                            profile["dns"] = json!({"servers": ["192.0.2.53"]});
                        }
                        let routes: RouteModel = serde_json::from_value(json!({"rules": [], "dnsServers": ["198.51.100.53"], "domainStrategy": requested})).unwrap();
                        let runtime = RuntimeOptions {
                            profile_dns_mode: mode,
                            ..RuntimeOptions::default()
                        };
                        for overlay in [None, Some(&routes)] {
                            let compiled = compile_profile(
                                profile.clone(),
                                overlay,
                                1080,
                                backend,
                                1500,
                                &runtime,
                                None,
                            )
                            .unwrap();
                            let config: Value = serde_json::from_slice(&compiled.config).unwrap();
                            let expected = overlay.and(requested).or(provider);
                            assert_eq!(
                                config["routing"]["domainStrategy"],
                                json!(expected),
                                "provider={provider:?}, requested={requested:?}, overlay={}, provider_dns={provider_dns}, mode={mode:?}, backend={backend:?}",
                                overlay.is_some()
                            );
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn tuic_endpoints_are_udp_and_preserve_tls_identity_when_pinned() {
    let source = json!({"outbounds":[{"tag":"proxy","protocol":"tuic","settings":{
        "address":"tuic.example.com","port":443,"uuid":"00000000-0000-4000-8000-000000000001",
        "password":"synthetic"},"streamSettings":{"security":"tls","tlsSettings":{"alpn":["h3"]}}}]});
    let config = compile(source, None);
    let endpoints = crate::profile::profile_endpoints(&config).unwrap();
    assert_eq!(endpoints.len(), 1);
    assert!(!endpoints[0].supports_tcp_probe);
    let pinned = crate::profile::pin_config(
        config,
        &[("tuic.example.com".into(), "2001:db8::1".into())].into(),
    )
    .unwrap();
    assert_eq!(pinned["outbounds"][0]["settings"]["address"], "2001:db8::1");
    assert_eq!(
        pinned["outbounds"][0]["streamSettings"]["tlsSettings"]["serverName"],
        "tuic.example.com"
    );
    assert_eq!(
        pinned["outbounds"][0]["streamSettings"]["tlsSettings"]["alpn"],
        json!(["h3"])
    );
}

#[test]
fn per_app_policy_gates_tun_then_preserves_provider_and_app_routing() {
    use crate::model::PerAppMode;
    let profile = json!({
        "inbounds":[{"tag":"provider-in"}],
        "outbounds":[node("elarni-apps-0", "edge.example.com"),
            {"tag":"reject", "protocol":"blackhole", "settings":{}}],
        "routing":{"rules":[{"type":"field", "inboundTag":["provider-in"],
            "domain":["full:provider.example"], "outboundTag":"reject"}]}
    });
    let routes: RouteModel = serde_json::from_value(json!({"rules":[{
        "action":"block", "domains":["full:blocked.example"], "ips":[]}],
        "dnsServers":["1.1.1.1"]}))
    .unwrap();
    for mode in [PerAppMode::Bypass, PerAppMode::ProxyOnly] {
        let runtime = RuntimeOptions {
            per_app_mode: mode,
            per_app_processes: vec!["curl".into(), "C:/Apps/Browser/browser.exe".into()],
            ..RuntimeOptions::default()
        };
        let result = compile_profile(
            profile.clone(),
            Some(&routes),
            1080,
            PacketBackend::XrayTun,
            1500,
            &runtime,
            None,
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&result.config).unwrap();
        let rules = after_own_subnet_block(&config);
        let entry = rules[0]["outboundTag"].as_str().unwrap();
        assert_ne!(entry, "elarni-apps-0");
        assert_eq!(rules[0]["port"], 53);
        // In "Only listed" a flow whose owner the lookup could not find ("-1") stays proxied.
        let mut listed = runtime.per_app_processes.clone();
        if mode == PerAppMode::ProxyOnly {
            listed.push("-1".into());
        }
        assert_eq!(rules[1]["process"], json!(listed));
        assert_eq!(rules[1]["inboundTag"], json!(["elarni-tun"]));
        assert_eq!(rules[2]["outboundTag"] == entry, mode == PerAppMode::Bypass);
        // The connections view names the per-app rule that took a connection.
        for (rule, tag) in rules.iter().zip([
            "elarni-per-app-dns",
            "elarni-per-app-listed-0",
            "elarni-per-app-other",
        ]) {
            assert_eq!(rule["ruleTag"], tag);
        }
        assert_eq!(
            rules[1]["outboundTag"] == entry,
            mode == PerAppMode::ProxyOnly
        );
        for domain in ["full:provider.example", "full:blocked.example"] {
            let rule = rules
                .iter()
                .find(|r| r["domain"] == json!([domain]))
                .unwrap();
            let ingress = rule["inboundTag"].as_array().unwrap();
            assert!(ingress.contains(&json!(entry)));
            assert!(ingress.contains(&json!("elarni-socks")));
            assert!(!ingress.contains(&json!("elarni-tun")));
        }
        let loopback = config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|outbound| outbound["tag"] == entry)
            .unwrap();
        assert_eq!(loopback["protocol"], "loopback");
        assert_eq!(loopback["settings"]["inboundTag"], entry);
        assert!(
            compile_profile(
                profile.clone(),
                None,
                1080,
                PacketBackend::NativeTun2Proxy,
                1500,
                &runtime,
                None
            )
            .is_err()
        );
    }
}

// The TUN's own-subnet block (compiler.rs block_tun_own_subnets) precedes the per-app gate.
fn after_own_subnet_block(config: &Value) -> &[Value] {
    let rules = config["routing"]["rules"].as_array().unwrap();
    assert_eq!(rules[0]["inboundTag"], json!(["elarni-tun"]));
    assert_eq!(rules[0]["port"], "1-52,54-65535");
    let block = config["outbounds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|outbound| outbound["tag"] == rules[0]["outboundTag"])
        .unwrap();
    assert_eq!(block["protocol"], "blackhole");
    &rules[1..]
}

fn per_app_runtime(targets: Value) -> RuntimeOptions {
    serde_json::from_value(json!({
        "perAppMode": "bypass",
        "perAppProcesses": ["curl", "game.exe", "telegram", "browser", "steam"],
        "perAppTargets": targets,
    }))
    .unwrap()
}

fn compile_per_app(runtime: &RuntimeOptions) -> Result<Value, crate::compiler::CompileError> {
    let profile = json!({"outbounds":[node("proxy", "edge.example.com"),
        {"tag":"direct", "protocol":"freedom", "settings":{}}]});
    let result = compile_profile(
        profile,
        None,
        1080,
        PacketBackend::XrayTun,
        1500,
        runtime,
        None,
    )?;
    let mut config: Value = serde_json::from_slice(&result.config).unwrap();
    config["endpoints"] = json!(
        result
            .endpoints
            .iter()
            .map(|e| e.host.clone())
            .collect::<Vec<_>>()
    );
    Ok(config)
}

// Each listed app can have its own target; the others keep the mode's.
#[test]
fn per_app_targets_send_each_listed_app_to_its_own_outbound() {
    let server = json!({"outbounds":[node("proxy", "nl.example.com"), {"tag":"direct", "protocol":"freedom", "settings":{}}]});
    let config = compile_per_app(&per_app_runtime(json!([
        {"process":"game.exe", "target":"block"},
        {"process":"telegram", "target":"server", "server": server},
        {"process":"browser", "target":"proxy", "proxy":"socks://127.0.0.1:1088"},
        {"process":"steam", "target":"routing"},
    ])))
    .unwrap();
    let rules = after_own_subnet_block(&config);
    let reentry = rules[0]["outboundTag"].as_str().unwrap();
    assert_eq!(rules[0]["port"], 53);
    let target = |process: &str| {
        let rule = rules
            .iter()
            .find(|rule| rule["process"] == json!([process]))
            .unwrap();
        assert_eq!(rule["inboundTag"], json!(["elarni-tun"]));
        rule["outboundTag"].as_str().unwrap().to_owned()
    };
    let outbound = |tag: &str| {
        config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["tag"] == tag)
            .unwrap()
            .clone()
    };
    assert_eq!(outbound(&target("game.exe"))["protocol"], "blackhole");
    assert_eq!(target("steam"), reentry);
    // Xray refuses two rules with one tag.
    let tags: Vec<&str> = rules
        .iter()
        .filter_map(|rule| rule["ruleTag"].as_str())
        .collect();
    let unique: std::collections::HashSet<&&str> = tags.iter().collect();
    assert_eq!(unique.len(), tags.len(), "{tags:?}");
    // Unlisted targets keep the mode's: bypass sends them directly.
    assert_eq!(target("curl"), "elarni-direct");
    let nl = outbound(&target("telegram"));
    assert_eq!(
        (nl["protocol"].as_str(), nl["settings"]["address"].as_str()),
        (Some("vless"), Some("nl.example.com"))
    );
    assert!(nl["tag"] != "proxy" && nl["tag"] != "elarni-proxy");
    let local = outbound(&target("browser"));
    assert_eq!(local["protocol"], "socks");
    assert_eq!(
        local["settings"]["servers"],
        json!([{"address":"127.0.0.1", "port":1088}])
    );
    assert_eq!(rules.last().unwrap()["outboundTag"], "proxy");
    let remaining = rules
        .iter()
        .position(|rule| {
            rule["inboundTag"] == json!(["elarni-tun"])
                && rule.get("process").is_none()
                && rule.get("port").is_none()
        })
        .unwrap();
    assert!(
        rules[..remaining]
            .iter()
            .filter(|rule| rule.get("process").is_some())
            .count()
            == 5
    );
    assert_eq!(rules[remaining]["outboundTag"], reentry);
    // The other server's address is pinned like the selected one's.
    assert!(
        config["endpoints"]
            .as_array()
            .unwrap()
            .contains(&json!("nl.example.com"))
    );
    // A mode that is off ignores targets.
    let mut off = per_app_runtime(json!([{"process":"game.exe", "target":"block"}]));
    off.per_app_mode = crate::model::PerAppMode::Off;
    assert!(
        compile_per_app(&off).unwrap()["routing"]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .all(|rule| rule.get("process").is_none())
    );
}

// "-1" names the owner of a flow the lookup could not find. In "Only listed" that flow
// could belong to a listed app, so it must not go direct.
#[test]
fn only_listed_keeps_unattributed_flows_in_the_tunnel() {
    use crate::model::PerAppMode;
    let mut runtime = per_app_runtime(json!([
        {"process":"curl", "target":"direct"}, {"process":"game.exe", "target":"block"},
        {"process":"telegram", "target":"direct"}, {"process":"browser", "target":"direct"},
        {"process":"steam", "target":"direct"},
    ]));
    runtime.per_app_mode = PerAppMode::ProxyOnly;
    let config = compile_per_app(&runtime).unwrap();
    let rules = after_own_subnet_block(&config);
    let reentry = &rules[0]["outboundTag"];
    let miss = rules
        .iter()
        .find(|rule| rule["process"] == json!(["-1"]))
        .unwrap();
    assert_eq!(miss["inboundTag"], json!(["elarni-tun"]));
    assert_eq!(miss["outboundTag"], *reentry);
    // Unlisted apps still go direct.
    assert_eq!(
        rules
            .iter()
            .find(|rule| rule["inboundTag"] == json!(["elarni-tun"])
                && rule.get("process").is_none()
                && rule.get("port").is_none())
            .unwrap()["outboundTag"],
        "elarni-direct"
    );
    // Bypass already proxies what no rule names.
    runtime.per_app_mode = PerAppMode::Bypass;
    let config = compile_per_app(&runtime).unwrap();
    assert!(
        config["routing"]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .all(|rule| !rule["process"]
                .as_array()
                .is_some_and(|names| names.contains(&json!("-1"))))
    );
}

#[test]
fn per_app_targets_refuse_what_they_cannot_honour() {
    let chained = json!({"outbounds":[{"tag":"hop", "protocol":"vless", "settings": node("x", "nl.example.com")["settings"],
        "streamSettings":{"sockopt":{"dialerProxy":"direct"}}}, {"tag":"direct", "protocol":"freedom", "settings":{}}]});
    for targets in [
        json!([{"process":"notlisted", "target":"block"}]),
        json!([{"process":"curl", "target":"block"}, {"process":"curl", "target":"direct"}]),
        json!([{"process":"curl", "target":"tor"}]),
        json!([{"process":"curl", "target":"server"}]),
        json!([{"process":"curl", "target":"block", "proxy":"socks://127.0.0.1:1088"}]),
        json!([{"process":"curl", "target":"server", "server": chained}]),
        json!([{"process":"curl", "target":"server", "server": {"outbounds":[{"tag":"direct", "protocol":"freedom", "settings":{}}]}}]),
        json!([{"process":"curl", "target":"proxy", "proxy":"socks://192.0.2.1:1080"}]),
        json!([{"process":"curl", "target":"proxy", "proxy":"socks://user:pass@127.0.0.1:1088"}]),
        json!([{"process":"curl", "target":"proxy", "proxy":"ftp://127.0.0.1:21"}]),
        json!([{"process":"curl", "target":"proxy", "proxy":"socks://127.0.0.1"}]),
        // Elarni's own SOCKS listener would loop.
        json!([{"process":"curl", "target":"proxy", "proxy":"socks://127.0.0.1:1080"}]),
    ] {
        assert!(
            compile_per_app(&per_app_runtime(targets.clone())).is_err(),
            "{targets}"
        );
    }
    assert!(
        serde_json::from_value::<RuntimeOptions>(
            json!({"perAppTargets":[{"process":"curl", "target":"block", "extra":1}]})
        )
        .is_err()
    );
    // Credentials in a server target stay out of debug output.
    let runtime = per_app_runtime(
        json!([{"process":"curl", "target":"server", "server": node("proxy", "nl.example.com")}]),
    );
    assert!(!format!("{runtime:?}").contains("00000000-0000-4000-8000-000000000001"));
    assert!(
        compile_per_app(&runtime).is_ok(),
        "a bare outbound is a server target too"
    );
}

#[test]
fn tcp_probe_eligibility_uses_the_endpoint_transport() {
    for (protocol, stream, supported) in [
        ("vless", json!({}), true),
        ("vmess", json!({"network": "tcp"}), true),
        ("trojan", json!({"network": "ws"}), true),
        ("shadowsocks", json!({"network": "raw"}), true),
        ("socks", json!({}), true),
        ("http", json!({}), true),
        ("vless", json!({"network": "websocket"}), true),
        ("vless", json!({"network": "httpupgrade"}), true),
        ("vless", json!({"network": "grpc"}), true),
        ("vless", json!({"method": null, "network": "grpc"}), true),
        ("vless", json!({"method": null, "network": "kcp"}), false),
        ("vless", json!({"network": "kcp"}), false),
        ("vless", json!({"network": "mKCP"}), false),
        ("vless", json!({"network": "quic"}), false),
        ("vless", json!({"network": "unknown"}), false),
        ("vless", json!({"network": "hysteria"}), false),
        ("hysteria", json!({}), false),
        ("hysteria", json!({"network": "hysteria"}), false),
        ("vless", json!({"network": "raw", "method": "kcp"}), false),
        ("vless", json!({"network": "kcp", "method": "raw"}), true),
        (
            "vless",
            json!({"network": "xhttp", "security": "tls", "tlsSettings": {"alpn": ["h3"]}}),
            false,
        ),
        (
            "vless",
            json!({"network": "splithttp", "security": "tls", "tlsSettings": {"alpn": ["h3"]}}),
            false,
        ),
        (
            "vless",
            json!({"network": "xhttp", "security": "tls", "tlsSettings": {"alpn": ["h2", "h3"]}}),
            true,
        ),
        (
            "vless",
            json!({"network": "xhttp", "security": "reality", "tlsSettings": {"alpn": ["h3"]}}),
            true,
        ),
    ] {
        let mut outbound = node("edge", "edge.example.com");
        outbound["protocol"] = json!(protocol);
        outbound["streamSettings"] = stream.clone();
        let endpoints =
            crate::profile::profile_endpoints(&json!({"outbounds": [outbound]})).unwrap();
        assert_eq!(
            serde_json::to_value(&endpoints[0]).unwrap()["supportsTcpProbe"],
            supported,
            "{protocol} {stream}"
        );
    }
    for protocol in ["wireguard", "amneziawg"] {
        let config = json!({"outbounds": [{"protocol": protocol, "settings": {"peers": [{"endpoint": "edge.example.com:51820"}]}}]});
        assert!(!crate::profile::profile_endpoints(&config).unwrap()[0].supports_tcp_probe);
    }
    let mut destination = node("destination", "destination.example.com");
    destination["proxySettings"] = json!({"tag": "edge"});
    let mut edge = node("edge", "edge.example.com");
    edge["streamSettings"]["network"] = json!("kcp");
    let endpoints =
        crate::profile::profile_endpoints(&json!({"outbounds": [destination, edge]})).unwrap();
    let physical = endpoints.iter().find(|endpoint| endpoint.physical).unwrap();
    assert_eq!(physical.host, "edge.example.com");
    assert!(!physical.supports_tcp_probe);
}

#[test]
fn provider_default_and_address_family_survive_without_overrides() {
    let source = node("default", "2001:db8::1");
    let config = compile(
        json!({"outbounds": [source.clone()], "dns": {"servers": ["2001:db8::53"]}}),
        None,
    );
    assert_eq!(config["outbounds"][0], source);
    assert!(config["outbounds"][0].get("targetStrategy").is_none());
    assert_eq!(config["dns"]["servers"], json!(["2001:db8::53"]));
    let last = config["routing"]["rules"]
        .as_array()
        .unwrap()
        .last()
        .unwrap();
    assert_eq!(last["outboundTag"], "default");
    assert_eq!(config["inbounds"][0]["listen"], "127.0.0.1");
}

#[test]
fn clash_select_groups_resolve_nested_user_choices_without_mutating_members() {
    let mut profile = json!({"outbounds": [node("one", "one.example.com"), node("two", "two.example.com"),
        {"tag": "PROXY", "protocol": "blackhole"}, {"tag": "NESTED", "protocol": "blackhole"}],
        "elarniGroups": [
            {"name": "PROXY", "type": "select", "options": ["one", "NESTED"], "selected": "NESTED"},
            {"name": "NESTED", "type": "select", "options": ["two"], "selected": "two"}],
        "routing": {"rules": [{"type": "field", "network": "tcp,udp", "outboundTag": "PROXY"}]}});
    let compiled = compile(profile.clone(), None);
    assert_eq!(
        compiled["outbounds"][0]["settings"]["address"],
        "one.example.com"
    );
    assert_eq!(
        compiled["outbounds"][2]["settings"]["address"],
        "two.example.com"
    );
    assert_eq!(compiled["outbounds"][2]["tag"], "PROXY");
    assert!(compiled.get("elarniGroups").is_none());
    profile["elarniGroups"][1]["options"] = json!(["PROXY"]);
    profile["elarniGroups"][1]["selected"] = json!("PROXY");
    assert!(
        compile_profile(
            profile,
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &RuntimeOptions::default(),
            None
        )
        .is_err()
    );
}

#[test]
fn fake_dns_servers_enable_sniffing_in_any_case() {
    // Xray matches the server name case-insensitively, as Go's EqualFold does.
    for name in ["FakeDNS", "fa\u{212A}edns"] {
        for server in [json!(name), json!({"address": name})] {
            let profile = json!({"outbounds": [node("server", "server.example.com")], "dns": {"servers": [server]},
                "fakedns": [{"ipPool": "198.18.0.0/15", "poolSize": 256}]});
            assert_eq!(
                compile(profile, None)["inbounds"][0]["sniffing"],
                json!({"enabled": true, "destOverride": ["fakedns", "http", "tls", "quic"], "routeOnly": true}),
                "{name}"
            );
        }
    }
}

#[test]
fn provider_dns_inherits_independently_of_app_routing_rules() {
    let profile = json!({"outbounds": [node("server", "server.example.com")], "dns": {"servers": ["fakedns", "2001:db8::53"]},
        "fakedns": [{"ipPool": "198.18.0.0/15", "poolSize": 256}]});
    let routes: RouteModel = serde_json::from_value(json!({"rules": [{"action": "block", "domains": ["full:blocked.example.com"], "ips": []}], "dnsServers": ["192.0.2.53"]})).unwrap();
    let inherited = compile(profile.clone(), Some(&routes));
    assert_eq!(
        inherited["dns"]["servers"],
        json!(["fakedns", "2001:db8::53"])
    );
    assert_eq!(
        inherited["inbounds"][0]["sniffing"],
        json!({"enabled": true, "destOverride": ["fakedns", "http", "tls", "quic"], "routeOnly": true})
    );
    for (mode, expected) in [
        (crate::model::ProfileDnsMode::Routing, "192.0.2.53"),
        (crate::model::ProfileDnsMode::Default, "1.1.1.1"),
    ] {
        let options = RuntimeOptions {
            profile_dns_mode: mode,
            ..RuntimeOptions::default()
        };
        let compiled = compile_profile(
            profile.clone(),
            Some(&routes),
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &options,
            None,
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&compiled.config).unwrap();
        assert_eq!(config["dns"]["servers"], json!([expected]));
        assert!(config.get("fakedns").is_none());
        assert!(
            config["routing"]["rules"]
                .as_array()
                .unwrap()
                .iter()
                .any(|rule| rule["domain"] == json!(["full:blocked.example.com"]))
        );
    }
}

// Xray's "localhost" server, and a DNS block with no servers at all, ask the system
// resolver over a socket the platform keeps outside the tunnel: the ISP's DNS.
#[test]
fn inherited_provider_dns_never_uses_the_system_resolver() {
    // "+local" schemes dial outside routing too; plain tcp:// is routed.
    let profile = json!({"outbounds": [node("server", "server.example.com")],
        "dns": {"servers": ["localhost", {"address": "LocalHost", "domains": ["geosite:private"]}, "192.0.2.53",
            "tcp+local://192.0.2.54", {"address": "HTTPS+Local://dns.example/dns-query"},
            "h2c+local://dns.example/dns-query", "quic+local://dns.example", "tcp://192.0.2.55"]}});
    assert_eq!(
        compile(profile, None)["dns"]["servers"],
        json!(["192.0.2.53", "tcp://192.0.2.55"])
    );
    for dns in [
        json!({"servers": ["localhost"], "hosts": {"private.provider": "192.0.2.3"}}),
        json!({"servers": ["tcp+local://192.0.2.54"], "hosts": {"private.provider": "192.0.2.3"}}),
        json!({"servers": [], "hosts": {"private.provider": "192.0.2.3"}}),
        json!({"hosts": {"private.provider": "192.0.2.3"}}),
    ] {
        let profile = json!({"outbounds": [node("server", "private.provider")], "dns": dns});
        let config = compile(profile, None);
        let servers = config["dns"]["servers"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        assert!(
            !servers.is_empty(),
            "{dns}: no servers means the system resolver"
        );
        assert!(
            servers.iter().all(|server| {
                let address = server.as_str().or(server["address"].as_str()).unwrap_or("");
                !address.eq_ignore_ascii_case("localhost") && !address.contains("+local")
            }),
            "{dns}: {servers:?}"
        );
        assert_eq!(
            config["dns"]["hosts"]["private.provider"],
            json!("192.0.2.3"),
            "{dns}"
        );
    }
}

// The provider's hosts may be the only address of its own servers in every mode
// that replaces its DNS servers.
#[test]
fn provider_hosts_survive_every_dns_mode_that_replaces_its_servers() {
    let profile = json!({"outbounds": [node("server", "private.provider")],
        "dns": {"servers": ["192.0.2.53"], "hosts": {"private.provider": "192.0.2.3"}}});
    let routes: RouteModel = serde_json::from_value(
        json!({"rules": [], "dnsServers": ["198.51.100.53"], "staticHosts": {"private.provider": ["198.51.100.3"]}}),
    )
    .unwrap();
    for mode in [
        crate::model::ProfileDnsMode::Routing,
        crate::model::ProfileDnsMode::Default,
    ] {
        let options = RuntimeOptions {
            profile_dns_mode: mode,
            ..RuntimeOptions::default()
        };
        for (routes, expected) in [
            (None, json!("192.0.2.3")),
            (Some(&routes), json!(["198.51.100.3"])),
        ] {
            let compiled = compile_profile(
                profile.clone(),
                routes,
                1080,
                PacketBackend::NativeTun2Proxy,
                1500,
                &options,
                None,
            )
            .unwrap();
            let config: Value = serde_json::from_slice(&compiled.config).unwrap();
            assert_ne!(config["dns"]["servers"], json!(["192.0.2.53"]), "{mode:?}");
            assert_eq!(
                config["dns"]["hosts"]["private.provider"], expected,
                "{mode:?}"
            );
        }
    }
}

// Imported routing profiles always carry a DNS policy; the fallback route models
// above do not, so only an enabled profile takes DNS over from the provider.
#[test]
fn enabled_routing_profile_dns_outranks_provider_dns_and_keeps_provider_hosts() {
    let profile = json!({"outbounds": [node("server", "private.provider")],
        "dns": {"servers": ["fakedns", "192.0.2.53"], "hosts": {"private.provider": "192.0.2.3", "shared.example.com": "192.0.2.4"}},
        "fakedns": [{"ipPool": "198.18.0.0/15", "poolSize": 256}]});
    let routes: RouteModel = serde_json::from_value(json!({"rules": [], "dnsServers": ["198.51.100.53", "203.0.113.53"],
        "staticHosts": {"shared.example.com": ["198.51.100.4"]},
        "dnsPolicy": {"remote": {"address": "198.51.100.53"}, "domestic": {"address": "203.0.113.53"}}})).unwrap();
    let config = compile(profile.clone(), Some(&routes));
    assert_eq!(
        config["dns"]["servers"],
        json!([{"address": "198.51.100.53", "timeoutMs": 2000}, {"address": "203.0.113.53"}])
    );
    assert_eq!(
        config["dns"]["hosts"]["shared.example.com"],
        json!(["198.51.100.4"])
    );
    assert!(config.get("fakeDns").is_none());
    assert!(
        !config["inbounds"][0]["sniffing"]["destOverride"]
            .as_array()
            .is_some_and(|sniffers| sniffers.contains(&json!("fakedns")))
    );
    // The provider's hosts may be the only address of its own servers.
    assert_eq!(config["dns"]["hosts"]["private.provider"], "192.0.2.3");
    assert_eq!(
        crate::profile::profile_endpoints(&config).unwrap()[0].addresses,
        vec!["192.0.2.3"]
    );
    let mut invalid = profile;
    invalid["dns"]["hosts"] = json!(["192.0.2.3"]);
    assert!(
        compile_profile(
            invalid,
            Some(&routes),
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &RuntimeOptions::default(),
            None,
        )
        .is_err()
    );
}

#[test]
fn profile_runtime_fragmentation_and_mux_apply_without_forcing_ipv4() {
    let options = RuntimeOptions {
        fragmentation_enabled: true,
        fragment_packets: "1-3".into(),
        fragment_length: "50-150".into(),
        fragment_interval: "2-5".into(),
        mux_enabled: true,
        ..RuntimeOptions::default()
    };
    let compiled = compile_profile(
        json!({"outbounds": [node("server", "server.example.com")]}),
        None,
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &options,
        None,
    )
    .unwrap();
    let config: Value = serde_json::from_slice(&compiled.config).unwrap();
    let client = &config["outbounds"][0];
    assert_eq!(client["mux"]["enabled"], true);
    let fragment_tag = &client["streamSettings"]["sockopt"]["dialerProxy"];
    let helper = config["outbounds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["tag"] == *fragment_tag)
        .unwrap();
    assert_eq!(
        helper["settings"]["fragment"],
        json!({"packets":"1-3", "length":"50-150", "interval":"2-5"})
    );
    assert_eq!(helper["settings"]["domainStrategy"], "AsIs");
    assert!(compiled.endpoints[0].physical);
    for invalid in ["0", "200-100", "1-65536", "1-2-3", "-1"] {
        let mut bad = options.clone();
        bad.fragment_length = invalid.into();
        assert!(
            compile_profile(
                json!({"outbounds": [node("server", "server.example.com")]}),
                None,
                1080,
                PacketBackend::NativeTun2Proxy,
                1500,
                &bad,
                None
            )
            .is_err()
        );
    }
}

// Xray resolves a dial strategy through its own DNS, which the tunnel routes
// through this same server; the platform's lookup must replace it.
#[test]
fn servers_dialed_with_a_domain_strategy_use_the_platform_lookup() {
    let fragmented = RuntimeOptions {
        fragmentation_enabled: true,
        ..RuntimeOptions::default()
    };
    let mut socket = node("server", "server.example.com");
    socket["streamSettings"]["sockopt"] = json!({"domainStrategy": "UseIPv6"});
    for (outbound, runtime, preferred, pinned) in [
        (
            node("server", "server.example.com"),
            &fragmented,
            Some(PreferredIp::Ipv4),
            true,
        ),
        (
            node("server", "server.example.com"),
            &fragmented,
            Some(PreferredIp::Ipv6),
            true,
        ),
        (socket, &RuntimeOptions::default(), None, true),
        (
            node("server", "server.example.com"),
            &fragmented,
            None,
            false,
        ),
    ] {
        let compiled = compile_profile(
            json!({"outbounds": [outbound]}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            runtime,
            preferred,
        )
        .unwrap();
        let path = compiled.endpoints[0].address_path.clone();
        let prepared = crate::profile::prepare_config(
            serde_json::from_slice(&compiled.config).unwrap(),
            &[(path.clone(), "192.0.2.10".into())].into(),
            &Default::default(),
            false,
            &Default::default(),
        )
        .unwrap();
        let address = if pinned {
            "192.0.2.10"
        } else {
            "server.example.com"
        };
        assert_eq!(prepared.pointer(&path).unwrap(), address, "{preferred:?}");
        assert_eq!(
            prepared["outbounds"][0]["streamSettings"]["tlsSettings"]["serverName"],
            "peer.example.com"
        );
    }
}

// Common provider profiles pair a fragmentable primary with WS, chained or
// Trojan backups; those backups connect without fragments.
#[test]
fn fragmentation_skips_backups_that_cannot_carry_it() {
    let options = RuntimeOptions {
        fragmentation_enabled: true,
        mux_enabled: true,
        ..RuntimeOptions::default()
    };
    let mut ws = node("ws", "ws.example.com");
    ws["streamSettings"]["network"] = json!("ws");
    let mut chained = node("chained", "chained.example.com");
    chained["proxySettings"] = json!({"tag": "ws"});
    let mut trojan = node("trojan", "trojan.example.com");
    trojan["protocol"] = json!("trojan");
    let backups = [ws, chained, trojan];
    let mut outbounds = vec![node("primary", "primary.example.com")];
    outbounds.extend(backups.iter().cloned());
    let compiled = compile_profile(
        json!({"outbounds": outbounds}),
        None,
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &options,
        None,
    )
    .unwrap();
    let config: Value = serde_json::from_slice(&compiled.config).unwrap();
    let tagged = |tag: &str| {
        config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|outbound| outbound["tag"] == tag)
            .unwrap()
            .clone()
    };
    assert!(tagged("primary")["streamSettings"]["sockopt"]["dialerProxy"].is_string());
    for backup in &backups {
        let tag = backup["tag"].as_str().unwrap();
        let mut stream = backup["streamSettings"].clone();
        if tag == "chained" {
            stream["sockopt"] = json!({"dialerProxy": "ws"});
        }
        assert_eq!(tagged(tag)["streamSettings"], stream, "{tag}");
    }
    assert_eq!(tagged("ws")["mux"]["enabled"], true);
    // The primary still needs it.
    assert!(
        compile_profile(
            json!({"outbounds": backups.iter().rev().cloned().collect::<Vec<_>>()}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &options,
            None,
        )
        .is_err()
    );
}

#[test]
fn fragmentation_follows_the_selected_group_member_not_the_first_outbound() {
    use crate::compiler::CompileError;
    let options = RuntimeOptions {
        fragmentation_enabled: true,
        ..RuntimeOptions::default()
    };
    let mut trojan = node("B", "trojan.example.com");
    trojan["protocol"] = json!("trojan");
    let profile = |members: [Value; 2], selected: &str| {
        let options: Vec<Value> = members.iter().map(|member| member["tag"].clone()).collect();
        json!({
            "outbounds": [members[0], members[1], {"tag": "PROXY", "protocol": "blackhole"}],
            "elarniGroups": [{"name": "PROXY", "type": "select", "options": options, "selected": selected}],
            "routing": {"rules": [{"type": "field", "network": "tcp,udp", "outboundTag": "PROXY"}]}
        })
    };
    let compile = |profile: Value| {
        compile_profile(
            profile,
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &options,
            None,
        )
    };
    // The selected server carries all traffic, so it needs fragmentation.
    assert!(matches!(
        compile(profile([node("A", "a.example.com"), trojan.clone()], "B")),
        Err(CompileError::UnsupportedFragmentation)
    ));
    // An unselected member is a backup, wherever it sits.
    let compiled = compile(profile([trojan, node("A", "a.example.com")], "A")).unwrap();
    let config: Value = serde_json::from_slice(&compiled.config).unwrap();
    let proxy = config["outbounds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|outbound| outbound["tag"] == "PROXY")
        .unwrap();
    assert!(proxy["streamSettings"]["sockopt"]["dialerProxy"].is_string());
}

#[test]
fn xhttp_fragmentation_covers_effective_download_stream_and_preserves_socket_options() {
    let options = RuntimeOptions {
        fragmentation_enabled: true,
        ..RuntimeOptions::default()
    };
    for penetrate in [false, true] {
        let mut upload = node("elarni-server", "upload.example.com");
        upload["streamSettings"]["method"] = json!("XHTTP");
        upload["streamSettings"]["sockopt"] = json!({"penetrate": penetrate, "tcpNoDelay": true});
        upload["streamSettings"]["splithttpSettings"] = json!({
            "downloadSettings": {"security": "none"},
            "extra": {"downloadSettings": {
                "address": "download.example.com", "port": 443, "method": null, "network": "splithttp", "security": "tls",
                "tlsSettings": {"serverName": "download.example.com"},
                "sockopt": {"tcpNoDelay": false}
            }}
        });
        let download_path = "/streamSettings/splithttpSettings/extra/downloadSettings";
        if penetrate {
            upload.pointer_mut(download_path).unwrap()["sockopt"]["dialerProxy"] = json!("ignored");
        }
        let compiled = compile_profile(
            json!({"outbounds": [upload]}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &options,
            None,
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&compiled.config).unwrap();
        let stream = &config["outbounds"][0]["streamSettings"];
        let tag = &stream["sockopt"]["dialerProxy"];
        assert_eq!(tag, "elarni1-fragment-0");
        assert_eq!(stream["sockopt"]["tcpNoDelay"], true);
        let download = config["outbounds"][0].pointer(download_path).unwrap();
        assert_eq!(
            download["sockopt"]["dialerProxy"],
            if penetrate {
                json!("ignored")
            } else {
                tag.clone()
            }
        );
        assert_eq!(download["sockopt"]["tcpNoDelay"], false);
        assert_eq!(
            download["tlsSettings"]["serverName"],
            "download.example.com"
        );
        assert_eq!(compiled.endpoints.len(), 2);
        assert!(compiled.endpoints.iter().all(|endpoint| endpoint.physical));
        assert!(
            config["outbounds"]
                .as_array()
                .unwrap()
                .iter()
                .any(|outbound| outbound["tag"] == *tag
                    && outbound["settings"]["fragment"]["packets"] == "tlshello")
        );
    }
}

#[test]
fn xhttp_fragmentation_rejects_plaintext_http3_and_existing_chains() {
    use crate::compiler::{CompileError, apply_outbound_runtime};
    let options = RuntimeOptions {
        fragmentation_enabled: true,
        ..RuntimeOptions::default()
    };
    let mut upload = node("upload", "upload.example.com");
    upload["streamSettings"]["network"] = json!("xhttp");
    upload["streamSettings"]["method"] = Value::Null;
    upload["streamSettings"]["xhttpSettings"] = json!({"downloadSettings": {
        "address": "download.example.com", "port": 443, "network": "xhttp", "security": "tls",
        "tlsSettings": {"alpn": ["h2"]}, "sockopt": {}
    }});
    for (path, value) in [
        ("/streamSettings/security", json!("none")),
        ("/streamSettings/tlsSettings", json!({"alpn": ["h3"]})),
        (
            "/streamSettings/sockopt",
            json!({"dialerProxy": "existing"}),
        ),
        (
            "/proxySettings",
            json!({"tag": "existing", "transportLayer": true}),
        ),
        (
            "/streamSettings/xhttpSettings/downloadSettings/security",
            json!("none"),
        ),
        (
            "/streamSettings/xhttpSettings/downloadSettings/tlsSettings",
            json!({"alpn": ["h3"]}),
        ),
        (
            "/streamSettings/xhttpSettings/downloadSettings/sockopt",
            json!({"dialerProxy": "existing"}),
        ),
    ] {
        let mut source = upload.clone();
        let (parent, key) = path.rsplit_once('/').unwrap();
        source.pointer_mut(parent).unwrap()[key] = value.clone();
        assert_eq!(
            apply_outbound_runtime(&mut source, &options, "fragment").unwrap_err(),
            CompileError::UnsupportedFragmentation,
            "{path}"
        );
        // The same provider settings remain untouched with fragmentation off.
        let mut disabled = upload.clone();
        disabled.pointer_mut(parent).unwrap()[key] = value;
        let stream = disabled["streamSettings"].clone();
        assert!(
            apply_outbound_runtime(&mut disabled, &RuntimeOptions::default(), "fragment")
                .unwrap()
                .is_none()
        );
        assert_eq!(disabled["streamSettings"], stream);
    }
}

// The tunnel reads its inbound counters; a provider's own system stats stay on beside them.
#[test]
fn provider_system_stats_survive_the_tunnel_counters() {
    for backend in [PacketBackend::NativeTun2Proxy, PacketBackend::XrayTun] {
        let result = compile_profile(
            json!({"outbounds": [node("elarni-proxy", "one.example.com")],
                "policy": {"system": {"statsOutboundUplink": true, "statsInboundUplink": false}}}),
            None,
            1080,
            backend,
            1500,
            &RuntimeOptions::default(),
            None,
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&result.config).unwrap();
        assert_eq!(
            config["policy"]["system"],
            json!({"statsOutboundUplink": true, "statsInboundUplink": true, "statsInboundDownlink": true}),
            "{backend:?}"
        );
    }
}

// Subscriptions often ship a policy block; Elarni's listeners keep the user's idle timeout.
#[test]
fn provider_policy_keeps_the_user_idle_timeout() {
    let runtime = RuntimeOptions {
        connection_idle_seconds: 600,
        ..RuntimeOptions::default()
    };
    for (policy, level) in [
        (
            json!({"levels": {"0": {"handshake": 4, "connIdle": 30}, "8": {"connIdle": 5}}}),
            json!({"handshake": 4, "connIdle": 600, "downlinkOnly": 0}),
        ),
        (
            json!({"levels": {"8": {"connIdle": 5}}}),
            json!({"connIdle": 600, "downlinkOnly": 0}),
        ),
        (
            json!({"system": {"statsOutboundUplink": true}}),
            json!({"connIdle": 600, "downlinkOnly": 0}),
        ),
        (
            json!({"levels": null}),
            json!({"connIdle": 600, "downlinkOnly": 0}),
        ),
    ] {
        let result = compile_profile(
            json!({"outbounds": [node("server", "one.example.com")], "policy": policy.clone()}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &runtime,
            None,
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&result.config).unwrap();
        assert_eq!(config["policy"]["levels"]["0"], level, "{policy}");
        if let Some(other) = policy["levels"].get("8") {
            assert_eq!(config["policy"]["levels"]["8"], *other, "{policy}");
        }
    }
}

// A connection closes with the app (Xray keeps it 1 s by default); a profile's own downlinkOnly wins.
#[test]
fn connections_close_with_the_app_unless_the_profile_says_otherwise() {
    let compile = |profile: Value| -> Value {
        let result = compile_profile(
            profile,
            None,
            1080,
            PacketBackend::XrayTun,
            1500,
            &RuntimeOptions::default(),
            None,
        )
        .unwrap();
        serde_json::from_slice(&result.config).unwrap()
    };
    let plain = compile(json!({"outbounds": [node("elarni-proxy", "one.example.com")]}));
    assert_eq!(plain["policy"]["levels"]["0"]["downlinkOnly"], 0);
    let provider = compile(
        json!({"outbounds": [node("elarni-proxy", "one.example.com")],
        "policy": {"levels": {"0": {"handshake": 6}}}}),
    );
    assert_eq!(
        provider["policy"]["levels"]["0"],
        json!({"handshake": 6, "connIdle": RuntimeOptions::default().connection_idle_seconds, "downlinkOnly": 0})
    );
    let own = compile(
        json!({"outbounds": [node("elarni-proxy", "one.example.com")],
        "policy": {"levels": {"0": {"downlinkOnly": 5}}}}),
    );
    assert_eq!(own["policy"]["levels"]["0"]["downlinkOnly"], 5);
}

#[test]
fn balancers_and_observatories_only_select_provider_members() {
    let config = compile(
        json!({"outbounds": [node("elarni-proxy", "one.example.com"), node("two", "two.example.com")],
            "routing": {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "network": "tcp,udp", "balancerTag": "pool"}],
                "balancers": [{"tag": "pool", "selector": [""], "strategy": {"type": "leastPing"}}]},
            "observatory": {"subjectSelector": [""], "probeURL": "https://probe.example.com/health", "probeInterval": "30s"}
        }),
        None,
    );
    assert_eq!(config["routing"]["domainStrategy"], "IPIfNonMatch");
    assert_eq!(
        config["routing"]["balancers"][0]["selector"],
        json!(["elarni-exact:elarni-proxy", "elarni-exact:two"])
    );
    assert_eq!(
        config["observatory"]["subjectSelector"],
        json!(["elarni-exact:elarni-proxy", "elarni-exact:two"])
    );
    assert_eq!(config["outbounds"][0]["tag"], "elarni-proxy");
    assert!(
        config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .any(|outbound| outbound["tag"] == "elarni1-dns")
    );
    assert_eq!(config["routing"]["rules"][0]["outboundTag"], "elarni1-dns");
}

#[test]
fn explicit_rules_overlay_provider_policy_without_adding_a_block_fallback() {
    let routes: RouteModel = serde_json::from_value(json!({"rules": [{"action": "block", "domains": ["full:blocked.example.com"], "ips": []}], "dnsServers": ["192.0.2.53"]})).unwrap();
    let config = compile(
        json!({"outbounds": [node("provider-default", "one.example.com")],
        "routing": {"rules": [{"type": "field", "domain": ["full:provider.example.com"], "outboundTag": "provider-default"}]}}),
        Some(&routes),
    );
    let rules = config["routing"]["rules"].as_array().unwrap();
    assert_eq!(rules[1]["outboundTag"], "elarni-block");
    assert_eq!(rules[1]["inboundTag"], json!(["elarni-socks"]));
    assert_eq!(rules[2]["domain"], json!(["full:provider.example.com"]));
    assert_eq!(rules.last().unwrap()["outboundTag"], "provider-default");
}

#[test]
fn chained_destinations_and_xhttp_download_hosts_have_distinct_endpoint_locations() {
    let mut chained = node("destination", "chained.example.com");
    chained["proxySettings"] = json!({"tag": "edge"});
    let mut edge = node("edge", "edge.example.com");
    edge["streamSettings"]["network"] = json!("xhttp");
    edge["streamSettings"]["xhttpSettings"] = json!({"path": "/up", "extra": {"downloadSettings": {
        "address": "download.example.com", "port": 8443, "network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "download-peer.example.com"}
    }}});
    let result = compile_profile(
        json!({"outbounds": [chained.clone(), edge.clone()]}),
        None,
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions::default(),
        None,
    )
    .unwrap();
    assert_eq!(result.endpoints.len(), 3);
    assert_eq!(result.endpoints[0].host, "chained.example.com");
    assert!(!result.endpoints[0].physical);
    assert!(result.endpoints[1].physical);
    assert_eq!(result.endpoints[2].host, "download.example.com");
    assert_eq!(result.endpoints[2].port, 8443);
    let config: Value = serde_json::from_slice(&result.config).unwrap();
    for endpoint in result.endpoints {
        assert_eq!(
            config.pointer(&endpoint.address_path).unwrap(),
            &json!(endpoint.host)
        );
    }
    chained.as_object_mut().unwrap().remove("proxySettings");
    chained["streamSettings"]["sockopt"] = json!({"dialerProxy": "edge"});
    assert_eq!(config["outbounds"][0], chained);
    assert_eq!(config["outbounds"][1], edge);

    edge["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["tlsSettings"]["alpn"] =
        json!(["h3"]);
    let endpoints = crate::profile::profile_endpoints(&json!({"outbounds": [edge]})).unwrap();
    assert!(endpoints[0].supports_tcp_probe);
    assert!(!endpoints[1].supports_tcp_probe);
}

// Xray 26.10.29 refuses an outbound proxySettings and names sockopt.dialerProxy instead.
#[test]
fn proxy_settings_chains_compile_to_dialer_proxies() {
    let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let wireguard = |tag: &str, proxy: Value| {
        json!({"tag": tag, "protocol": "wireguard", "proxySettings": proxy, "settings": {
            "secretKey": format!("{key}="), "address": ["10.0.0.2/32"],
            "peers": [{"endpoint": format!("{tag}.example:51820"), "publicKey": format!("{key}=")}]}})
    };
    let mut plain = node("plain", "plain.example.com");
    plain["proxySettings"] = json!({"tag": "edge"});
    let mut layered = node("layered", "layered.example.com");
    layered["proxySettings"] = json!({"tag": "edge", "transportLayer": true});
    let mut unset = node("unset", "unset.example.com");
    unset["proxySettings"] = json!({"tag": ""});
    let profile = json!({"outbounds": [plain, layered, unset,
        wireguard("wg-plain", json!({"tag": "edge"})),
        wireguard("wg-layered", json!({"tag": "edge", "transportLayer": true})),
        node("edge", "edge.example.com")]});
    let config = compile(profile.clone(), None);
    assert!(
        !config.to_string().contains("proxySettings"),
        "{}",
        config["outbounds"]
    );
    let tagged = |tag: &str| {
        config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|outbound| outbound["tag"] == tag)
            .unwrap()
            .clone()
    };
    for tag in ["plain", "layered", "wg-layered"] {
        assert_eq!(
            tagged(tag)["streamSettings"]["sockopt"]["dialerProxy"],
            "edge",
            "{tag}"
        );
    }
    // Xray never carried a WireGuard bind socket or an empty tag through a plain proxy.
    for tag in ["unset", "wg-plain"] {
        assert!(
            tagged(tag)
                .pointer("/streamSettings/sockopt/dialerProxy")
                .is_none(),
            "{tag}"
        );
    }
    // The endpoint analysis sees the chain the core will dial.
    let endpoints = crate::profile::profile_endpoints(&profile).unwrap();
    let physical = |host: &str| {
        endpoints
            .iter()
            .find(|endpoint| endpoint.host == host)
            .unwrap()
            .physical
    };
    assert!(!physical("plain.example.com"));
    assert!(!physical("wg-layered.example"));
    assert!(physical("wg-plain.example"));
    let resolved = endpoints
        .iter()
        .filter(|endpoint| endpoint.physical)
        .map(|endpoint| (endpoint.address_path.clone(), "192.0.2.1".to_owned()))
        .collect();
    let prepared = crate::profile::prepare_config(
        profile,
        &resolved,
        &Default::default(),
        false,
        &Default::default(),
    )
    .unwrap();
    assert!(!prepared.to_string().contains("proxySettings"));
}

// Stored Hysteria2 profiles hop ports in quicParams.udpHop, which Xray 26.10.29 drops silently.
#[test]
fn quic_params_port_hopping_compiles_to_the_udphop_mask() {
    let hysteria = |tag: &str, mask: Value| {
        json!({"tag": tag, "protocol": "hysteria", "settings": {"version": 2, "address": format!("{tag}.example.com"), "port": 443},
            "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "peer.example.com"},
                "hysteriaSettings": {"version": 2, "auth": "secret"}, "finalmask": mask}})
    };
    let salamander = json!({"type": "salamander", "settings": {"password": "obfs"}});
    let existing = json!({"type": "UDPHop", "settings": {"mode": "perConnRemote", "remotePorts": "30000-30009"}});
    let config = compile(
        json!({"outbounds": [
            hysteria("both", json!({"quicParams": {"congestion": "brutal", "brutalUp": "10 Mbps",
                "udpHop": {"ports": "20000-20009", "interval": 15}}, "udp": [salamander]})),
            hysteria("only", json!({"quicParams": {"udpHop": {"ports": "443,8443"}}})),
            hysteria("unhopped", json!({"quicParams": {"udpHop": {"interval": 15}}})),
            hysteria("current", json!({"quicParams": {"udpHop": {"ports": "20000-20009"}}, "udp": [existing]})),
        ]}),
        None,
    );
    let mask = |tag: &str| {
        config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|outbound| outbound["tag"] == tag)
            .unwrap()["streamSettings"]["finalmask"]
            .clone()
    };
    assert_eq!(
        mask("both"),
        json!({"quicParams": {"congestion": "brutal", "brutalUp": "10 Mbps"}, "udp": [salamander,
            {"type": "udphop", "settings": {"mode": "intervalLocal,intervalRemote", "interval": 15, "remotePorts": "20000-20009"}}]})
    );
    assert_eq!(
        mask("only"),
        json!({"udp": [{"type": "udphop", "settings": {"mode": "intervalLocal,intervalRemote", "remotePorts": "443,8443"}}]})
    );
    // Without ports Xray never hopped; a profile that already has the mask keeps it.
    assert_eq!(mask("unhopped"), json!({}));
    assert_eq!(mask("current"), json!({"udp": [existing]}));
}

#[test]
fn broken_chains_and_duplicate_tags_are_rejected_before_activation() {
    let mut first = node("one", "one.example.com");
    first["proxySettings"] = json!({"tag": "two"});
    let mut second = node("two", "two.example.com");
    second["proxySettings"] = json!({"tag": "one"});
    for profile in [
        json!({"outbounds": [first.clone()]}),
        json!({"outbounds": [first, second]}),
        json!({"outbounds": [node("same", "one.example.com"), node("same", "two.example.com")]}),
    ] {
        assert!(
            compile_profile(
                profile,
                None,
                1080,
                PacketBackend::NativeTun2Proxy,
                1500,
                &RuntimeOptions::default(),
                None
            )
            .is_err()
        );
    }
}

#[test]
fn app_resources_are_owned_and_ip_override_is_explicit() {
    let profile = json!({"outbounds": [node("default", "one.example.com")],
        "inbounds": [{"tag": "untrusted", "listen": "0.0.0.0", "port": 22, "protocol": "socks"}],
        "env": {"xray.location.asset": "/untrusted"}, "api": {"tag": "admin"}, "log": {"access": "/untrusted.log"}});
    let result = compile_profile(
        profile,
        None,
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions::default(),
        Some(PreferredIp::Ipv6),
    )
    .unwrap();
    let config: Value = serde_json::from_slice(&result.config).unwrap();
    assert_eq!(config["inbounds"].as_array().unwrap().len(), 1);
    assert_eq!(config["inbounds"][0]["port"], 1080);
    assert!(config.get("api").is_none());
    assert!(config.get("env").is_none());
    assert_eq!(config["log"]["access"], "none");
    assert!(config["outbounds"][0].get("targetStrategy").is_none());
}

#[test]
fn grpc_url_import_shape_preserves_authority_when_pinned() {
    for security in ["none", "tls", "reality"] {
        for authority in ["", "virtual.example.com"] {
            let source = json!({
                "protocol": "vless", "tag": "proxy",
                "settings": {"vnext": [{"address": "edge.example.com", "port": 443,
                    "users": [{"id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}]}]},
                // The Go URL importer emits null for the unused method alias.
                "streamSettings": {"network": "grpc", "method": null, "security": security,
                    "tlsSettings": {"serverName": "tls.example.com", "alpn": ["h2"]},
                    "realitySettings": {"serverName": "reality.example.com", "publicKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
                    "grpcSettings": {"serviceName": "fixture/service", "authority": authority, "multiMode": true}}
            });
            let config = compile(json!({"outbounds": [source]}), None);
            let pinned = crate::profile::pin_config(
                config,
                &[("edge.example.com".into(), "192.0.2.5".into())].into(),
            )
            .unwrap();
            let outbound = &pinned["outbounds"][0];
            assert_eq!(outbound["settings"]["vnext"][0]["address"], "192.0.2.5");
            let grpc = &outbound["streamSettings"]["grpcSettings"];
            let expected = if !authority.is_empty() {
                authority
            } else if security == "tls" {
                "tls.example.com"
            } else if security == "reality" {
                "reality.example.com"
            } else {
                "edge.example.com"
            };
            assert_eq!(
                grpc["authority"], expected,
                "gRPC virtual host changed after pinning ({security})"
            );
            assert_eq!(grpc["serviceName"], "fixture/service");
            assert_eq!(grpc["multiMode"], true);
            assert_eq!(
                outbound["streamSettings"]["tlsSettings"]["serverName"],
                "tls.example.com"
            );
            assert_eq!(
                outbound["streamSettings"]["tlsSettings"]["alpn"],
                json!(["h2"])
            );
            assert_eq!(
                outbound["streamSettings"]["realitySettings"]["serverName"],
                "reality.example.com"
            );
        }
    }
}

#[test]
fn provider_profiles_cannot_open_reverse_connections() {
    let mut modern = node("modern", "one.example.com");
    modern["settings"]["reverse"] = json!({"tag": "portal"});
    let mut legacy = node("legacy", "two.example.com");
    legacy["settings"] = json!({"vnext": [{"address": "two.example.com", "port": 443, "users": [{
        "id": "00000000-0000-4000-8000-000000000001", "encryption": "none", "reverse": {"tag": "portal2"}
    }]}]});
    let config = compile(
        json!({"outbounds": [modern, legacy], "reverse": {"bridges": [{"tag": "bridge", "domain": "r.example.com"}]}}),
        None,
    );
    assert!(
        !serde_json::to_string(&config)
            .unwrap()
            .contains("\"reverse\"")
    );
}

// Xray decodes keys case-insensitively, folds U+017F to s and U+212A to k, and
// lets the last duplicate win; such keys would slip past exact-key checks here.
#[test]
fn provider_keys_xray_reads_differently_are_rejected() {
    let compile_result = |profile: Value| {
        compile_profile(
            profile,
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &RuntimeOptions::default(),
            None,
        )
    };
    let mut reverse = node("default", "one.example.com");
    reverse["settings"]["Reverse"] = json!({"tag": "portal"});
    let mut folded_settings = node("default", "one.example.com");
    let settings = folded_settings["settings"].take();
    folded_settings
        .as_object_mut()
        .unwrap()
        .insert("Settings".to_owned(), settings);
    for profile in [
        json!({"outbounds": [reverse]}),
        json!({"outbounds": [folded_settings]}),
        json!({"outbounds": [node("default", "one.example.com")], "routing": {
            "rules": [{"outboundTag": "default", "domain": ["example.com"]}],
            "rule\u{17F}": [{"inboundTag": ["r"], "outboundTag": "default"}]}}),
        json!({"outbounds": [node("default", "one.example.com")],
            "dns": {"servers": ["1.1.1.1"], "Servers": ["localhost"]}}),
        json!({"outbounds": [node("default", "one.example.com")], "routing": {"rules": [
            {"outboundTag": "default", "webhoo\u{212A}": {"url": "http://192.168.1.2/x"}}]}}),
    ] {
        assert!(
            compile_result(profile.clone()).is_err(),
            "accepted {profile}"
        );
    }
    let mut headers = node("default", "one.example.com");
    headers["streamSettings"] =
        json!({"network": "ws", "wsSettings": {"headers": {"Host": "cdn.example.com"}}});
    assert!(
        compile_result(json!({"outbounds": [headers]})).is_ok(),
        "ordinary map keys stay accepted"
    );
}

#[test]
fn provider_fake_dns_uses_one_key_spelling() {
    let pool = json!([{"ipPool": "198.20.0.0/16", "poolSize": 100}]);
    let config = compile(
        json!({"outbounds": [node("default", "one.example.com")], "fakedns": pool}),
        None,
    );
    assert!(config.get("fakedns").is_none());
    assert_eq!(config["fakeDns"], pool);
}

#[test]
fn provider_rules_cannot_send_webhooks() {
    let config = compile(
        json!({"outbounds": [node("default", "one.example.com")], "routing": {"rules": [
            {"outboundTag": "default", "domain": ["example.com"],
             "webhook": {"url": "/var/run/docker.sock:/v1.43/volumes/prune"}},
            {"outboundTag": "default", "Webhook": {"url": "http://192.168.1.1/x"}}
        ]}}),
        None,
    );
    let text = serde_json::to_string(&config).unwrap();
    assert!(!text.to_ascii_lowercase().contains("webhook"));
    assert!(text.contains("example.com"), "the rule itself stays");
}

#[test]
fn pinning_keeps_a_legacy_websocket_host_header() {
    let mut source = node("default", "one.example.com");
    source["streamSettings"]["network"] = json!("ws");
    source["streamSettings"]["wsSettings"] =
        json!({"path": "/ws", "headers": {"Host": "cdn.example.com"}});
    let config = compile(json!({"outbounds": [source]}), None);
    let pinned = crate::profile::pin_config(
        config,
        &[("one.example.com".into(), "192.0.2.1".into())].into(),
    )
    .unwrap();
    let websocket = &pinned["outbounds"][0]["streamSettings"]["wsSettings"];
    // Xray ignores headers.Host once host is set, which breaks CDN fronting.
    assert!(
        websocket
            .get("host")
            .is_none_or(|host| host == "cdn.example.com")
    );
    assert_eq!(websocket["headers"]["Host"], "cdn.example.com");
}

#[test]
fn pinning_preserves_tls_identity_and_http_authority_on_modern_and_legacy_endpoints() {
    for network in ["raw", "ws", "grpc", "httpupgrade", "xhttp"] {
        let mut source = node("default", "one.example.com");
        source["streamSettings"]["network"] = json!(network);
        source["streamSettings"]["tlsSettings"] =
            json!({"echConfigList": "fixture-ech", "pinnedPeerCertSha256": "fixture-pin"});
        let config = compile(json!({"outbounds": [source]}), None);
        let pinned = crate::profile::pin_config(
            config,
            &[("one.example.com".into(), "192.0.2.1".into())].into(),
        )
        .unwrap();
        assert_eq!(pinned["outbounds"][0]["settings"]["address"], "192.0.2.1");
        assert_eq!(
            pinned["outbounds"][0]["streamSettings"]["tlsSettings"]["serverName"],
            "one.example.com"
        );
        assert_eq!(
            pinned["outbounds"][0]["streamSettings"]["tlsSettings"]["pinnedPeerCertSha256"],
            "fixture-pin"
        );
        if network == "ws" {
            assert_eq!(
                pinned["outbounds"][0]["streamSettings"]["wsSettings"]["host"],
                "one.example.com"
            );
        }
        if network == "grpc" {
            assert_eq!(
                pinned["outbounds"][0]["streamSettings"]["grpcSettings"]["authority"],
                "one.example.com"
            );
        }
    }
    let mut legacy = node("default", "one.example.com");
    legacy["settings"] = json!({"vnext": [{"address": "one.example.com", "port": 443, "users": [{"id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}]}]});
    let config = compile(json!({"outbounds": [legacy]}), None);
    let pinned = crate::profile::pin_config(
        config,
        &[("one.example.com".into(), "2001:db8::1".into())].into(),
    )
    .unwrap();
    assert_eq!(
        pinned["outbounds"][0]["settings"]["vnext"][0]["address"],
        "2001:db8::1"
    );
}

#[test]
fn pinning_keeps_chained_destinations_remote_and_handles_fragment_helpers() {
    let mut first = node("destination", "remote.example.com");
    first["proxySettings"] = json!({"tag": "edge"});
    let config = compile(
        json!({"outbounds": [first, node("edge", "edge.example.com")]}),
        None,
    );
    let pinned = crate::profile::pin_config(
        config,
        &[("edge.example.com".into(), "192.0.2.10".into())].into(),
    )
    .unwrap();
    assert_eq!(
        pinned["outbounds"][0]["settings"]["address"],
        "remote.example.com"
    );
    assert_eq!(pinned["outbounds"][1]["settings"]["address"], "192.0.2.10");
    let mut first = node("default", "edge.example.com");
    first["streamSettings"]["sockopt"] = json!({"dialerProxy": "fragment"});
    let config = json!({"outbounds": [first, {"tag": "fragment", "protocol": "freedom", "settings": {"fragment": {"packets": "tlshello"}}}]});
    assert!(crate::profile::profile_endpoints(&config).unwrap()[0].physical);
    assert!(crate::profile::pin_config(config.clone(), &Default::default()).is_err());
    let pinned = crate::profile::pin_config(
        config,
        &[("edge.example.com".into(), "192.0.2.10".into())].into(),
    )
    .unwrap();
    assert_eq!(pinned["outbounds"][0]["settings"]["address"], "192.0.2.10");
}

#[test]
fn unavailable_balancer_members_close_their_routes_without_disabling_healthy_members() {
    let config = compile(
        json!({"outbounds": [node("bad", "bad.example.com"), node("good", "good.example.com")],
        "routing": {"rules": [{"type":"field", "network":"tcp,udp", "balancerTag":"pool"}],
            "balancers":[{"tag":"pool", "selector":[""], "strategy":{"type":"random"}}]},
        "observatory":{"subjectSelector":[""], "probeURL":"https://probe.example.com"}}),
        None,
    );
    let prepared = crate::profile::prepare_config(
        config.clone(),
        &[("good.example.com".into(), "192.0.2.2".into())].into(),
        &["bad.example.com".into()].into(),
        true,
        &Default::default(),
    )
    .unwrap();
    assert_eq!(prepared["outbounds"][0]["protocol"], "blackhole");
    assert!(prepared["outbounds"][0].get("streamSettings").is_none());
    assert_eq!(prepared["outbounds"][1]["settings"]["address"], "192.0.2.2");
    assert_eq!(
        prepared["routing"]["balancers"][0]["selector"],
        json!(["elarni-exact:good"])
    );
    assert_eq!(
        prepared["observatory"]["subjectSelector"],
        json!(["elarni-exact:good"])
    );
    assert!(
        crate::profile::prepare_config(
            config,
            &Default::default(),
            &["bad.example.com".into(), "good.example.com".into()].into(),
            false,
            &Default::default()
        )
        .is_err()
    );
}

#[test]
fn an_unreachable_selected_member_closes_the_tunnel_even_with_an_unrouted_sibling() {
    // The group carries all traffic; the other member exists but nothing routes to it.
    let config = compile(
        json!({"outbounds": [node("A", "a.example.com"), node("B", "b.example.com"), {"tag": "PROXY", "protocol": "blackhole"}],
        "elarniGroups": [{"name": "PROXY", "type": "select", "options": ["A", "B"], "selected": "A"}],
        "routing": {"rules": [{"type": "field", "network": "tcp,udp", "outboundTag": "PROXY"}]}}),
        None,
    );
    let prepare = |unavailable: &str| {
        crate::profile::prepare_config(
            config.clone(),
            &[
                ("b.example.com".into(), "192.0.2.2".into()),
                ("a.example.com".into(), "192.0.2.1".into()),
            ]
            .into(),
            &[unavailable.into()].into(),
            true,
            &Default::default(),
        )
    };
    assert!(prepare("b.example.com").is_ok());
    assert!(
        prepare("a.example.com").is_err(),
        "a tunnel whose only routed server is unreachable was reported usable"
    );
}

#[test]
fn wireguard_physical_peers_pin_without_changing_optional_or_chained_endpoints() {
    for protocol in ["wireguard", "amneziawg"] {
        for (address, socket) in [
            ("192.0.2.2", "192.0.2.2:51820"),
            ("2001:db8::2", "[2001:db8::2]:51820"),
        ] {
            let peer = json!({"tag":"wg", "protocol":protocol, "settings":{
                "peers":[{"endpoint":"edge.example.com:51820"}]}});
            let mut chained = peer.clone();
            chained["tag"] = json!("chained");
            chained["proxySettings"] = json!({"tag":"other", "transportLayer":true});
            let config = json!({"outbounds":[peer, node("other", "edge.example.com"), chained]});
            let prepared = crate::profile::prepare_config(
                config.clone(),
                &[(
                    "/outbounds/0/settings/peers/0/endpoint".into(),
                    address.into(),
                )]
                .into(),
                &Default::default(),
                false,
                &Default::default(),
            )
            .unwrap();
            assert_eq!(
                prepared["outbounds"][0]["settings"]["peers"][0]["endpoint"],
                socket
            );
            assert_eq!(prepared["outbounds"][1], config["outbounds"][1]);
            let mut migrated = config["outbounds"][2].clone();
            migrated.as_object_mut().unwrap().remove("proxySettings");
            migrated["streamSettings"] = json!({"sockopt": {"dialerProxy": "other"}});
            assert_eq!(prepared["outbounds"][2], migrated);
            assert!(
                crate::profile::prepare_config(
                    config,
                    &Default::default(),
                    &Default::default(),
                    false,
                    &Default::default(),
                )
                .is_err()
            );
        }
    }
}

#[test]
fn wireguard_peers_behind_a_plain_proxy_act_like_direct_peers() {
    // Xray dials a WireGuard peer from its own bind socket; a plain proxySettings never carries it.
    for protocol in ["wireguard", "amneziawg"] {
        let config = json!({"outbounds":[{"tag":"wg", "protocol":protocol, "proxySettings":{"tag":"other"},
            "settings":{"peers":[{"endpoint":"edge.example.com:51820"}]}}, node("other", "proxy.example.com")]});
        let prepared = crate::profile::prepare_config(
            config.clone(),
            &[(
                "/outbounds/0/settings/peers/0/endpoint".into(),
                "192.0.2.2".into(),
            )]
            .into(),
            &Default::default(),
            false,
            &Default::default(),
        )
        .unwrap();
        assert_eq!(
            prepared["outbounds"][0]["settings"]["peers"][0]["endpoint"], "192.0.2.2:51820",
            "{protocol}"
        );
        // So an unresolvable plain-proxy hop closes only itself.
        let prepared = crate::profile::prepare_config(
            config,
            &[(
                "/outbounds/0/settings/peers/0/endpoint".into(),
                "192.0.2.2".into(),
            )]
            .into(),
            &["proxy.example.com".to_owned()].into(),
            false,
            &Default::default(),
        )
        .unwrap_or_else(|error| panic!("{protocol}: {error:?}"));
        assert_eq!(prepared["outbounds"][0]["protocol"], protocol);
        assert_eq!(
            prepared["outbounds"][1]["protocol"], "blackhole",
            "{protocol}"
        );
    }
}

#[test]
fn failed_hops_close_chains_and_empty_pools_use_their_explicit_fallback() {
    let mut chained = node("chained", "remote.example.com");
    chained["proxySettings"] = json!({"tag":"edge"});
    let config = compile(
        json!({"outbounds": [chained, node("edge", "missing.example.com"), node("fallback", "working.example.com")],
        "routing":{"rules":[{"type":"field", "network":"tcp,udp", "balancerTag":"pool"}],
            "balancers":[{"tag":"pool", "selector":["chained"], "fallbackTag":"fallback", "strategy":{"type":"random"}}]}}),
        None,
    );
    let prepared = crate::profile::prepare_config(
        config,
        &Default::default(),
        &["missing.example.com".into()].into(),
        false,
        &Default::default(),
    )
    .unwrap();
    assert_eq!(prepared["outbounds"][0]["protocol"], "blackhole");
    assert_eq!(prepared["outbounds"][1]["protocol"], "blackhole");
    assert!(
        prepared["routing"]["balancers"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(prepared["routing"]["rules"][1]["outboundTag"], "fallback");
}

// Every endpoint copies its hints, so one huge provider list must not multiply.
#[test]
fn static_endpoint_dns_hints_are_bounded() {
    let addresses: Vec<String> = (0..1000)
        .map(|index| format!("10.0.{}.{}", index / 256, index % 256))
        .collect();
    let config = compile(
        json!({"outbounds":[node("server", "big.provider")],
        "dns":{"hosts":{"big.provider": addresses}, "servers":["1.1.1.1"]}}),
        None,
    );
    let endpoints = crate::profile::profile_endpoints(&config).unwrap();
    assert_eq!(endpoints[0].addresses.len(), 64);
}

#[test]
fn static_endpoint_dns_hints_work_without_system_dns_and_preserve_tls_names() {
    let config = compile(
        json!({"outbounds":[node("server", "private.provider")],
        "dns":{"hosts":{"private.provider":"alias.provider", "full:alias.provider":["192.0.2.3", "2001:db8::3"]}, "servers":["1.1.1.1"]}}),
        None,
    );
    let endpoints = crate::profile::profile_endpoints(&config).unwrap();
    assert_eq!(endpoints[0].addresses, vec!["192.0.2.3", "2001:db8::3"]);
    let prepared = crate::profile::prepare_config(
        config,
        &[("private.provider".into(), "2001:db8::3".into())].into(),
        &Default::default(),
        false,
        &Default::default(),
    )
    .unwrap();
    assert_eq!(
        prepared["outbounds"][0]["settings"]["address"],
        "2001:db8::3"
    );
    assert_eq!(
        prepared["outbounds"][0]["streamSettings"]["tlsSettings"]["serverName"],
        "peer.example.com"
    );
}

#[test]
fn download_destinations_follow_effective_extra_and_transport_layer_dependencies() {
    let mut upload = node("upload", "upload.example.com");
    upload["streamSettings"]["method"] = json!("XHTTP");
    upload["streamSettings"]["xhttpSettings"] = json!({"downloadSettings":{"address":"ignored.example.com", "port":443},
        "extra":{"downloadSettings":{"address":"download.example.com", "port":8443, "network":"xhttp", "sockopt":{"dialerProxy":"edge"}}}});
    let config = json!({"outbounds":[upload.clone(), node("edge", "edge.example.com")]});
    let manifest = crate::profile::profile_endpoints(&config).unwrap();
    assert_eq!(manifest.len(), 3);
    assert_eq!(manifest[1].host, "download.example.com");
    assert!(!manifest[1].physical);
    upload["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]
        .as_object_mut()
        .unwrap()
        .remove("address");
    assert!(crate::profile::profile_endpoints(&json!({"outbounds":[upload]})).is_err());
    let mut bad = node("bad", "bad.example.com");
    bad["proxySettings"] = json!({"tag":"edge", "transportLayer":true});
    bad["streamSettings"]["sockopt"] = json!({"dialerProxy":"other"});
    assert!(compile_profile(json!({"outbounds":[bad, node("edge", "edge.example.com"), node("other", "other.example.com")]}),
        None,1080,PacketBackend::NativeTun2Proxy,1500,&RuntimeOptions::default(),None).is_err());
}

#[test]
fn direct_group_remains_usable_when_unused_proxy_names_cannot_resolve() {
    let config = compile(
        json!({"outbounds":[node("unused", "missing.example.com"), {"tag":"direct", "protocol":"freedom"}],
        "routing":{"rules":[{"type":"field", "network":"tcp,udp", "outboundTag":"direct"}]}}),
        None,
    );
    let prepared = crate::profile::prepare_config(
        config,
        &Default::default(),
        &["missing.example.com".into()].into(),
        true,
        &Default::default(),
    )
    .unwrap();
    assert_eq!(prepared["routing"]["rules"][1]["outboundTag"], "direct");
}

// A direct rule that matches only some traffic leaves the rest blackholed.
#[test]
fn narrow_direct_rules_do_not_keep_a_tunnel_whose_proxy_cannot_resolve() {
    use crate::model::PerAppMode;
    let prepare = |profile: Value, mode: PerAppMode| {
        let runtime = RuntimeOptions {
            per_app_mode: mode,
            per_app_processes: vec!["curl".into()],
            ..RuntimeOptions::default()
        };
        let compiled = compile_profile(
            profile,
            None,
            1080,
            PacketBackend::XrayTun,
            1500,
            &runtime,
            None,
        )
        .unwrap();
        crate::profile::prepare_config(
            serde_json::from_slice(&compiled.config).unwrap(),
            &Default::default(),
            &["missing.example.com".into()].into(),
            true,
            &Default::default(),
        )
    };
    let private = json!({"outbounds":[node("proxy", "missing.example.com"), {"tag":"direct", "protocol":"freedom"}],
        "routing":{"rules":[{"type":"field", "network":"tcp,udp", "ip":["geoip:private"], "outboundTag":"direct"}]}});
    assert!(prepare(private, PerAppMode::Off).is_err());
    let proxy = json!({"outbounds":[node("proxy", "missing.example.com")]});
    assert!(prepare(proxy.clone(), PerAppMode::Bypass).is_err());
    // Only the listed apps used the proxy; every other app still connects.
    assert!(prepare(proxy, PerAppMode::ProxyOnly).is_ok());
}

#[test]
fn core_matched_hosts_pin_even_when_optional_system_pinning_is_off() {
    let config = json!({"outbounds":[node("one", "edge.provider.test")]});
    let prepared = crate::profile::prepare_config(
        config,
        &[("edge.provider.test".into(), "192.0.2.8".into())].into(),
        &Default::default(),
        false,
        &["edge.provider.test".into()].into(),
    )
    .unwrap();
    assert_eq!(prepared["outbounds"][0]["settings"]["address"], "192.0.2.8");
}

#[test]
fn freedom_redirects_are_physical_endpoints_and_port_only_redirects_keep_the_host() {
    let mut proxy = node("one", "unused.example.com");
    proxy["proxySettings"] = json!({"tag":"redirect", "transportLayer":true});
    let mut config = json!({"outbounds":[proxy, {"tag":"redirect", "protocol":"freedom", "settings":{"redirect":"redirect.example.com:0", "domainStrategy":"ForceIPv6"}}]});
    let endpoints = crate::profile::profile_endpoints(&config).unwrap();
    assert_eq!(endpoints.len(), 2);
    assert!(!endpoints[0].physical);
    assert!(endpoints[1].physical);
    assert_eq!(endpoints[1].domain_strategy, "ForceIPv6");
    let pinned = crate::profile::pin_config(
        config.clone(),
        &[("redirect.example.com".into(), "2001:db8::9".into())].into(),
    )
    .unwrap();
    assert_eq!(
        pinned["outbounds"][1]["settings"]["redirect"],
        "[2001:db8::9]:0"
    );
    assert_eq!(
        pinned["outbounds"][0]["settings"]["address"],
        "unused.example.com"
    );
    config["outbounds"][1]["settings"]["redirect"] = json!(":8443");
    let endpoints = crate::profile::profile_endpoints(&config).unwrap();
    assert_eq!(endpoints.len(), 1);
    assert!(endpoints[0].physical);
    assert_eq!(endpoints[0].domain_strategy, "ForceIPv6");
}

#[test]
fn shared_host_endpoints_pin_and_fail_independently_by_address_family() {
    let mut v4 = node("v4", "shared.example.com");
    let mut v6 = node("v6", "shared.example.com");
    v4["streamSettings"]["sockopt"] = json!({"domainStrategy":"ForceIPv4"});
    v6["streamSettings"]["sockopt"] = json!({"domainStrategy":"ForceIPv6"});
    let config = json!({"outbounds":[v4,v6]});
    let endpoints = crate::profile::profile_endpoints(&config).unwrap();
    assert_eq!(endpoints[0].domain_strategy, "ForceIPv4");
    assert_eq!(endpoints[1].domain_strategy, "ForceIPv6");
    let resolved = [
        (endpoints[0].address_path.clone(), "192.0.2.4".into()),
        (endpoints[1].address_path.clone(), "2001:db8::6".into()),
    ]
    .into();
    let pinned = crate::profile::pin_config(config.clone(), &resolved).unwrap();
    assert_eq!(pinned["outbounds"][0]["settings"]["address"], "192.0.2.4");
    assert_eq!(pinned["outbounds"][1]["settings"]["address"], "2001:db8::6");
    let prepared = crate::profile::prepare_config(
        config,
        &resolved,
        &[endpoints[1].address_path.clone()].into(),
        true,
        &Default::default(),
    )
    .unwrap();
    assert_eq!(prepared["outbounds"][0]["protocol"], "vless");
    assert_eq!(prepared["outbounds"][1]["protocol"], "blackhole");
}

// The explicit first-outbound fallback always matches, so a provider's
// IPIfNonMatch retry never runs; IP rules must resolve hostnames on demand.
#[test]
fn provider_ip_rules_resolve_hostnames_ahead_of_the_explicit_fallback() {
    let ip_rule = json!({"type": "field", "ip": ["192.0.2.0/24"], "outboundTag": "direct"});
    let domain_rule =
        json!({"type": "field", "domain": ["full:direct.example"], "outboundTag": "direct"});
    let profile = |strategy: &str, rule: &Value| {
        json!({"outbounds": [node("proxy", "edge.example.com"), {"tag": "direct", "protocol": "freedom"}],
            "routing": {"domainStrategy": strategy, "rules": [rule]}})
    };
    let mut listed_ip = ip_rule.clone();
    listed_ip["ip"] = json!("192.0.2.0/24");
    for (strategy, rule, expected) in [
        ("IPIfNonMatch", &ip_rule, "IPOnDemand"),
        ("ipifnonmatch", &ip_rule, "IPOnDemand"),
        ("IPIfNonMatch", &listed_ip, "IPOnDemand"),
        ("IPIfNonMatch", &domain_rule, "IPIfNonMatch"),
        ("AsIs", &ip_rule, "AsIs"),
    ] {
        assert_eq!(
            compile(profile(strategy, rule), None)["routing"]["domainStrategy"],
            expected,
            "{strategy} {rule}"
        );
    }
    let routes: RouteModel = serde_json::from_value(
        json!({"rules": [{"action": "direct", "domains": [], "ips": ["198.51.100.0/24"]}],
        "dnsServers": ["192.0.2.53"], "domainStrategy": "IPIfNonMatch"}),
    )
    .unwrap();
    assert_eq!(
        compile(profile("AsIs", &domain_rule), Some(&routes))["routing"]["domainStrategy"],
        "IPOnDemand"
    );
    // Xray reads these keys case-insensitively; the check above reads them exactly.
    for rejected in [
        json!({"outbounds": [node("proxy", "edge.example.com"), {"tag": "direct", "protocol": "freedom"}],
            "routing": {"DomainStrategy": "IPIfNonMatch", "rules": [ip_rule]}}),
        json!({"outbounds": [node("proxy", "edge.example.com"), {"tag": "direct", "protocol": "freedom"}],
            "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
                {"type": "field", "IP": ["192.0.2.0/24"], "outboundTag": "direct"}]}}),
    ] {
        assert!(
            compile_profile(
                rejected.clone(),
                None,
                1080,
                PacketBackend::NativeTun2Proxy,
                1500,
                &RuntimeOptions::default(),
                None
            )
            .is_err(),
            "accepted {rejected}"
        );
    }
}

// Server IP type picks the family of the server address only; proxied
// destinations reach the server as hostnames unless the provider says otherwise.
#[test]
fn profile_ip_preference_leaves_target_strategies_to_the_provider() {
    let mut own = node("own", "two.example.com");
    own["targetStrategy"] = json!("UseIPv6");
    for preference in [PreferredIp::Ipv4, PreferredIp::Ipv6, PreferredIp::Automatic] {
        let result = compile_profile(
            json!({"outbounds": [node("plain", "one.example.com"), own.clone()]}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &RuntimeOptions::default(),
            Some(preference),
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&result.config).unwrap();
        assert!(
            config["outbounds"][0].get("targetStrategy").is_none(),
            "{preference:?}"
        );
        assert_eq!(
            config["outbounds"][1]["targetStrategy"], "UseIPv6",
            "{preference:?}"
        );
    }
}

// Elarni's listeners replace the provider's as a whole, so only a rule that
// names every provider listener applies to all Elarni traffic.
#[test]
fn provider_rules_for_some_listeners_do_not_widen_to_every_elarni_listener() {
    let config = compile(
        json!({
            "inbounds": [{"tag": "socks-in", "protocol": "socks"}, {"tag": "dns-in", "protocol": "dokodemo-door"}],
            "outbounds": [node("proxy", "edge.example.com"), {"tag": "dns-out", "protocol": "dns"},
                {"tag": "block", "protocol": "blackhole"},
                {"tag": "loop", "protocol": "loopback", "settings": {"inboundTag": "loop-in"}}],
            "routing": {"rules": [
                {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out"},
                {"type": "field", "inboundTag": ["socks-in", "loop-in"], "domain": ["full:some.example"], "outboundTag": "block"},
                {"type": "field", "inboundTag": ["dns-in", "socks-in"], "domain": ["full:every.example"], "outboundTag": "block"}]}
        }),
        None,
    );
    let rules = config["routing"]["rules"].as_array().unwrap();
    let rule = |domain: &str| {
        rules
            .iter()
            .find(|rule| rule["domain"] == json!([domain]))
            .unwrap()
    };
    assert!(
        rules.iter().all(|rule| rule["outboundTag"] != "dns-out"),
        "{rules:?}"
    );
    assert_eq!(rule("full:some.example")["inboundTag"], json!(["loop-in"]));
    assert_eq!(
        rule("full:every.example")["inboundTag"],
        json!(["elarni-socks", "elarni-provider"])
    );
}

// Xray reads stream keys case-insensitively, so pinning must not read them differently:
// a miscased field it relies on is refused, and a provider's Host or Authority is kept.
#[test]
fn pinning_and_xray_agree_on_miscased_stream_keys() {
    for stream in [
        json!({"network": "raw", "security": "tls", "tlsSettings": {"ServerName": "front.example.com"}}),
        json!({"network": "raw", "Security": "tls"}),
        json!({"Network": "ws", "security": "tls", "wsSettings": {"path": "/p"}}),
        json!({"network": "ws", "security": "tls", "WsSettings": {"path": "/p"}}),
        json!({"network": "ws", "security": "tls", "wsSettings": {"Headers": {"Host": "cdn.example.com"}}}),
    ] {
        let mut source = node("default", "one.example.com");
        source["streamSettings"] = stream.clone();
        let compiled = compile_profile(
            json!({"outbounds": [source]}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &RuntimeOptions::default(),
            None,
        );
        assert!(compiled.is_err(), "{stream} compiled");
    }
    for (network, transport, field) in [
        ("ws", "wsSettings", "Host"),
        ("grpc", "grpcSettings", "Authority"),
    ] {
        let mut source = node("default", "one.example.com");
        source["streamSettings"]["network"] = json!(network);
        source["streamSettings"][transport][field] = json!("cdn.example.com");
        let pinned = crate::profile::pin_config(
            compile(json!({"outbounds": [source]}), None),
            &[("one.example.com".into(), "192.0.2.1".into())].into(),
        )
        .unwrap();
        let settings = &pinned["outbounds"][0]["streamSettings"][transport];
        assert_eq!(settings, &json!({field: "cdn.example.com"}), "{network}");
    }
}

#[test]
fn endpoints_and_xray_agree_on_miscased_server_keys() {
    let id = "00000000-0000-4000-8000-000000000001";
    let download = json!({"address": "download.example", "port": 443, "network": "xhttp", "security": "tls",
        "tlsSettings": {"serverName": "download.example"}, "xhttpSettings": {"path": "/x"}});
    let xhttp = |settings: Value| {
        json!({"tag": "proxy", "protocol": "vless",
            "settings": {"address": "upload.example", "port": 443, "id": id, "encryption": "none"},
            "streamSettings": {"network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "upload.example"},
                "xhttpSettings": settings}})
    };
    let profile = |outbound: Value| {
        compile_profile(
            json!({"outbounds": [outbound]}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &RuntimeOptions::default(),
            None,
        )
    };
    // Xray dials a flat Address instead of vnext, and reads download settings in any case.
    for outbound in [
        json!({"tag": "proxy", "protocol": "vless", "settings": {"Address": "other.example", "port": 8443, "id": id, "encryption": "none",
            "vnext": [{"address": "one.example", "port": 443, "users": [{"id": id, "encryption": "none"}]}]}}),
        xhttp(json!({"path": "/x", "mode": "packet-up", "DownloadSettings": download})),
        xhttp(json!({"path": "/x", "mode": "packet-up", "Extra": {"downloadSettings": download}})),
    ] {
        assert!(profile(outbound.clone()).is_err(), "{outbound} compiled");
    }
    let hosts: Vec<String> = profile(xhttp(
        json!({"path": "/x", "mode": "packet-up", "downloadSettings": download}),
    ))
    .unwrap()
    .endpoints
    .into_iter()
    .map(|endpoint| endpoint.host)
    .collect();
    assert_eq!(hosts, ["upload.example", "download.example"]);
}

#[test]
fn wireguard_hints_and_reality_names_follow_xray() {
    let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let compile = |outbound: Value| {
        compile_profile(
            json!({"outbounds": [outbound]}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &RuntimeOptions::default(),
            None,
        )
    };
    // Xray's WireGuard reads only domainStrategy; targetStrategy belongs to freedom.
    for protocol in ["wireguard", "amneziawg"] {
        let endpoints = compile(json!({"tag": "wg", "protocol": protocol, "settings": {
            "secretKey": format!("{key}="), "address": ["10.0.0.2/32"],
            "peers": [{"endpoint": "wg.example:51820", "publicKey": format!("{key}=")}],
            "targetStrategy": "ForceIPv6", "domainStrategy": "ForceIPv4"}}))
        .unwrap()
        .endpoints;
        assert_eq!(endpoints[0].domain_strategy, "ForceIPv4", "{protocol}");
        // Its sockopt only reaches the bind socket, and penetrate is an XHTTP option.
        let endpoints = compile(json!({"tag": "wg", "protocol": protocol, "settings": {
            "secretKey": format!("{key}="), "address": ["10.0.0.2/32"],
            "peers": [{"endpoint": "wg.example:51820", "publicKey": format!("{key}=")}]},
            "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6", "penetrate": true}}}))
        .unwrap()
        .endpoints;
        assert_eq!(endpoints[0].domain_strategy, "AsIs", "{protocol} penetrate");
        // A dialerProxy or transport-layer proxy carries WireGuard's bind socket; Xray ignores a plain proxy.
        for (dial, strategy) in [
            (json!({"proxySettings": {"tag": "helper"}}), "AsIs"),
            (
                json!({"proxySettings": {"tag": "helper", "transportLayer": true}}),
                "ForceIPv6",
            ),
            (
                json!({"streamSettings": {"sockopt": {"dialerProxy": "helper"}}}),
                "ForceIPv6",
            ),
        ] {
            let mut wg = json!({"tag": "wg", "protocol": protocol, "settings": {
                "secretKey": format!("{key}="), "address": ["10.0.0.2/32"],
                "peers": [{"endpoint": "wg.example:51820", "publicKey": format!("{key}=")}]}});
            wg.as_object_mut()
                .unwrap()
                .extend(dial.as_object().unwrap().clone());
            let endpoints = compile_profile(
                json!({"outbounds": [wg,
                    {"tag": "helper", "protocol": "freedom", "settings": {"domainStrategy": "ForceIPv6"}}]}),
                None,
                1080,
                PacketBackend::NativeTun2Proxy,
                1500,
                &RuntimeOptions::default(),
                None,
            )
            .unwrap()
            .endpoints;
            assert_eq!(endpoints[0].domain_strategy, strategy, "{protocol} {dial}");
        }
    }
    // Xray reads a null Dest or Target as a REALITY server and refuses the client.
    let reality = |name: &str| {
        let mut proxy = node("proxy", "vless.example");
        proxy["streamSettings"] = json!({"network": "raw", "security": "reality", "realitySettings": {
            "fingerprint": "chrome", "publicKey": key, "shortId": "01234567", "serverName": "sni.example", name: null}});
        compile(proxy)
    };
    for name in ["Dest", "Target"] {
        assert!(reality(name).is_err(), "{name}");
    }
    for name in ["dest", "target"] {
        assert!(reality(name).is_ok(), "{name}");
    }
}

#[test]
fn endpoints_and_xray_agree_on_miscased_dial_keys() {
    use crate::compiler::CompileError;
    let compile = |outbounds: Value, runtime: &RuntimeOptions| {
        compile_profile(
            json!({"outbounds": outbounds}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            runtime,
            None,
        )
    };
    let plain = RuntimeOptions::default();
    let fragmented = RuntimeOptions {
        fragmentation_enabled: true,
        ..RuntimeOptions::default()
    };
    let muxed = RuntimeOptions {
        mux_enabled: true,
        ..RuntimeOptions::default()
    };
    let penetrate = |key: &str| {
        let mut upload = node("proxy", "upload.example");
        upload["streamSettings"] = json!({"network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "upload.example"},
            "sockopt": {key: true}, "xhttpSettings": {"path": "/x", "mode": "packet-up", "downloadSettings": {
                "address": "download.example", "port": 8443, "network": "xhttp", "security": "tls",
                "tlsSettings": {"serverName": "download.example"}, "xhttpSettings": {"path": "/x"},
                "sockopt": {"dialerProxy": "edge"}}}});
        json!([upload, node("edge", "edge.example")])
    };
    let target = |key: &str| {
        json!([node("proxy", "vless.example"), {"tag": "redirect", "protocol": "freedom",
            "settings": {"redirect": "redirect.example:443", key: "ForceIPv6", "domainStrategy": "ForceIPv4"}}])
    };
    let alpn = |key: &str| {
        let mut upload = node("proxy", "upload.example");
        upload["streamSettings"] = json!({"network": "xhttp", "security": "tls",
            "tlsSettings": {"serverName": "upload.example", key: ["h3"]}, "xhttpSettings": {"path": "/x", "mode": "packet-up"}});
        json!([upload])
    };
    let flow = |key: &str| {
        let mut vision = node("proxy", "vless.example");
        vision["settings"][key] = json!("xtls-rprx-vision");
        json!([vision])
    };
    let mux = |key: &str| {
        let mut proxy = node("proxy", "vless.example");
        proxy[key] = json!({"enabled": false});
        json!([proxy])
    };
    // Xray reads each of these in any case: penetration, the freedom target strategy,
    // HTTP/3, the Vision flow and the provider's own mux choice.
    for (outbounds, runtime) in [
        (penetrate("Penetrate"), &plain),
        (target("TargetStrategy"), &plain),
        (alpn("ALPN"), &fragmented),
        (flow("Flow"), &muxed),
        (mux("Mux"), &muxed),
    ] {
        assert!(
            compile(outbounds.clone(), runtime).is_err(),
            "{outbounds} compiled"
        );
    }
    let endpoint = |outbounds, host: &str| {
        compile(outbounds, &plain)
            .unwrap()
            .endpoints
            .into_iter()
            .find(|endpoint| endpoint.host == host)
            .unwrap()
    };
    assert!(endpoint(penetrate("penetrate"), "download.example").physical);
    assert_eq!(
        endpoint(target("targetStrategy"), "redirect.example").domain_strategy,
        "ForceIPv6"
    );
    assert!(!endpoint(alpn("alpn"), "upload.example").supports_tcp_probe);
    assert!(matches!(
        compile(alpn("alpn"), &fragmented),
        Err(CompileError::UnsupportedFragmentation)
    ));
    for outbounds in [flow("flow"), mux("mux")] {
        let config: Value =
            serde_json::from_slice(&compile(outbounds, &muxed).unwrap().config).unwrap();
        let proxy = config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|outbound| outbound["tag"] == "proxy")
            .unwrap();
        assert_eq!(proxy["mux"], json!({"enabled": false}));
    }
}

#[test]
fn endpoints_and_xray_agree_on_miscased_chaining_keys() {
    let id = "00000000-0000-4000-8000-000000000001";
    let profile = |outbounds: Value| {
        compile_profile(
            json!({"outbounds": outbounds}),
            None,
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &RuntimeOptions::default(),
            None,
        )
    };
    let redirect = |key: &str| {
        json!([{"tag": "proxy", "protocol": "vless", "settings": {"address": "vless.example", "port": 443, "id": id, "encryption": "none"}},
            {"tag": "redirect", "protocol": "freedom", "settings": {key: "203.0.113.5:443"}}])
    };
    let download = json!({"address": "download.example", "port": 8443, "network": "xhttp", "security": "tls",
        "tlsSettings": {"serverName": "download.example"}, "xhttpSettings": {"path": "/x"}});
    let chained = |key: &str| {
        json!([{"tag": "proxy", "protocol": "vless", "settings": {"address": "upload.example", "port": 443, "id": id, "encryption": "none"},
                "streamSettings": {"network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "upload.example"},
                    "xhttpSettings": {"path": "/x", "mode": "packet-up", "downloadSettings": download}},
                "proxySettings": {"tag": "edge", key: true}},
            {"tag": "edge", "protocol": "vless", "settings": {"address": "edge.example", "port": 443, "id": id, "encryption": "none"}}])
    };
    // Xray dials a freedom Redirect and chains a TransportLayer proxy in any case.
    for outbounds in [
        redirect("Redirect"),
        redirect("REDIRECT"),
        chained("TransportLayer"),
    ] {
        assert!(profile(outbounds.clone()).is_err(), "{outbounds} compiled");
    }
    let hosts = |outbounds| -> Vec<String> {
        profile(outbounds)
            .unwrap()
            .endpoints
            .into_iter()
            .map(|endpoint| endpoint.host)
            .collect()
    };
    assert_eq!(
        hosts(redirect("redirect")),
        ["vless.example", "203.0.113.5"]
    );
    assert_eq!(
        hosts(chained("transportLayer")),
        ["upload.example", "download.example", "edge.example"]
    );
}

// Inherited provider DNS also decides where lookups other than A and AAAA go.
#[test]
fn dns_outbound_forwards_other_query_types_to_the_inherited_resolver() {
    let config = compile(
        json!({"outbounds": [node("provider", "edge.example.com")],
            "dns": {"tag": "provider-dns", "servers": [
                "fakedns", {"address": "tcp://9.9.9.9:5353"}, "8.8.8.8"]}}),
        None,
    );
    let outbounds = config["outbounds"].as_array().unwrap();
    let dns = outbounds
        .iter()
        .find(|outbound| outbound["protocol"] == "dns")
        .unwrap();
    assert_eq!(dns["settings"]["address"], "9.9.9.9");
    assert_eq!(dns["settings"]["port"], 5353);
    assert_eq!(dns["settings"]["network"], "tcp");
    let forward = outbounds
        .iter()
        .find(|outbound| outbound["tag"] == dns["streamSettings"]["sockopt"]["dialerProxy"])
        .unwrap();
    assert_eq!(forward["protocol"], "loopback");
    assert_eq!(forward["settings"]["inboundTag"], "provider-dns");
}

// A resolver that skips fallback answers only its own domains, so lookups of other
// names must not reach it, often directly, as a domestic resolver.
#[test]
fn dns_outbound_skips_a_resolver_limited_to_its_domains() {
    let domestic = json!({"address": "223.5.5.5", "domains": ["domain:cn"], "skipFallback": true});
    for (servers, address) in [
        (json!([domestic, "8.8.8.8"]), "8.8.8.8"),
        (json!([domestic, "https://dns.google/dns-query"]), "1.1.1.1"),
    ] {
        let config = compile(
            json!({"outbounds": [node("provider", "edge.example.com")], "dns": {"servers": servers}}),
            None,
        );
        let dns = config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|outbound| outbound["protocol"] == "dns")
            .unwrap();
        assert_eq!(dns["settings"]["address"], address, "{servers}");
    }
}

// Listing "-1" gives unidentified traffic (WSL, virtual machines, closed sockets) a target
// of its own, in either mode, instead of the one "Only listed" adds.
#[test]
fn listed_unknown_owner_takes_its_own_target() {
    use crate::model::PerAppMode;
    let mut runtime = per_app_runtime(json!([{"process":"-1", "target":"direct"}]));
    runtime.per_app_processes = vec!["-1".into(), "telegram".into()];
    for mode in [PerAppMode::ProxyOnly, PerAppMode::Bypass] {
        runtime.per_app_mode = mode;
        let config = compile_per_app(&runtime).unwrap();
        let unknown: Vec<&Value> = config["routing"]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|rule| {
                rule["process"]
                    .as_array()
                    .is_some_and(|names| names.contains(&json!("-1")))
            })
            .collect();
        assert_eq!(unknown.len(), 1, "{mode:?}");
        assert_eq!(unknown[0]["process"], json!(["-1"]), "{mode:?}");
        assert_eq!(unknown[0]["outboundTag"], "elarni-direct", "{mode:?}");
    }
    // Listed without a target, it follows the mode like any listed app.
    runtime.per_app_targets.clear();
    runtime.per_app_mode = PerAppMode::Bypass;
    let config = compile_per_app(&runtime).unwrap();
    let rules = config["routing"]["rules"].as_array().unwrap();
    let listed = rules
        .iter()
        .find(|rule| rule.get("process").is_some())
        .unwrap();
    assert_eq!(listed["process"], json!(runtime.per_app_processes));
    assert_eq!(listed["outboundTag"], "elarni-direct");
}

// "children:<rule>" also takes the programs a listed app starts. A program listed on its own
// keeps its own target: every app's direct rule comes before any rule that matches parents.
#[test]
fn per_app_children_rules_follow_the_direct_ones() {
    let mut runtime = per_app_runtime(json!([
        {"process":"children:/opt/claude/claude", "target":"routing"},
        {"process":"/home/u/.local/bin/claude-code", "target":"direct"}
    ]));
    runtime.per_app_processes = vec![
        "children:/opt/claude/claude".into(),
        "/home/u/.local/bin/claude-code".into(),
        "telegram".into(),
    ];
    let config = compile_per_app(&runtime).unwrap();
    let listed: Vec<&Value> = config["routing"]["rules"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|rule| {
            rule["ruleTag"]
                .as_str()
                .is_some_and(|tag| tag.starts_with("elarni-per-app-listed-"))
        })
        .collect();
    let processes: Vec<&Value> = listed.iter().map(|rule| &rule["process"]).collect();
    assert_eq!(
        processes,
        [
            &json!(["/opt/claude/claude"]),
            &json!(["/home/u/.local/bin/claude-code"]),
            &json!(["telegram"]),
            &json!(["children:/opt/claude/claude"]),
        ]
    );
    assert_eq!(listed[0]["outboundTag"], listed[3]["outboundTag"]);
    assert_eq!(listed[1]["outboundTag"], "elarni-direct");
    for invalid in ["children:", "children:-1", "children:children:/opt/x"] {
        runtime.per_app_processes = vec![invalid.into()];
        runtime.per_app_targets.clear();
        assert!(compile_per_app(&runtime).is_err(), "{invalid}");
    }
}
