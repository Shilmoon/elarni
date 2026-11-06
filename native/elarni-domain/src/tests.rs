use crate::model::{InboundAuth, ParsedHy2, SecretRef};
use crate::parser::{ParseError, parse_hy2_uri};

fn reference(id: &str) -> SecretRef {
    SecretRef { id: id.to_owned() }
}

fn parse(uri: &str) -> Result<ParsedHy2, ParseError> {
    parse_hy2_uri(
        uri,
        reference("profile.auth"),
        Some(reference("profile.obfs")),
    )
}

fn assert_parse_error(uri: &str, expected: ParseError) {
    // ParsedHy2 deliberately has no Debug implementation exposing its secrets.
    assert_eq!(parse(uri).err(), Some(expected), "URI: {uri}");
}

#[test]
fn parses_both_schemes_with_secure_defaults() {
    for scheme in ["hy2", "hysteria2"] {
        let parsed = parse(&format!("{scheme}://test-secret@EXAMPLE.COM:443")).unwrap();
        let endpoint = parsed.endpoint;
        assert_eq!(parsed.authentication, "test-secret");
        assert_eq!(parsed.obfuscation_password, None);
        assert_eq!(endpoint.schema_version, 1);
        assert_eq!(endpoint.host, "example.com");
        assert_eq!(endpoint.port, 443);
        assert_eq!(endpoint.secret_ref, reference("profile.auth"));
        assert_eq!(endpoint.server_name, None);
        assert!(endpoint.alpn.is_empty());
        assert_eq!(endpoint.obfuscation, None);
        assert_eq!(endpoint.port_hop, None);
        assert!(endpoint.unknown_parameters.is_empty());
    }
}

#[test]
fn parses_ipv4_and_ipv6_hosts() {
    for (authority, host) in [
        ("192.0.2.1:443", "192.0.2.1"),
        ("[2001:db8::1]:65535", "2001:db8::1"),
    ] {
        assert_eq!(
            parse(&format!("hy2://secret@{authority}"))
                .unwrap()
                .endpoint
                .host,
            host
        );
    }
}

#[test]
fn decodes_userinfo_and_query_authentication() {
    for uri in [
        "hy2://user:p%40ss%3Aword@example.com:443",
        "hy2://example.com:443?auth=user%3Ap%40ss%3Aword",
        "hy2://user:p%40ss%3Aword@example.com:443?auth=user%3Ap%40ss%3Aword",
    ] {
        assert_eq!(parse(uri).unwrap().authentication, "user:p@ss:word");
    }
}

#[test]
fn rejects_missing_and_conflicting_authentication() {
    for uri in ["hy2://example.com:443", "hy2://example.com:443?auth="] {
        assert_parse_error(uri, ParseError::MissingAuthentication);
    }
    assert_parse_error(
        "hy2://first@example.com:443?auth=second",
        ParseError::ConflictingAuthentication,
    );
}

#[test]
fn rejects_invalid_uri_scheme_and_ports() {
    for (uri, error) in [
        ("not a URI", ParseError::InvalidUri),
        ("https://secret@example.com:8443", ParseError::InvalidScheme),
        ("hy2://secret@example.com", ParseError::InvalidPort),
        ("hy2://secret@example.com:0", ParseError::InvalidPort),
        ("hy2://secret@example.com:65536", ParseError::InvalidUri),
        ("hy2://%FF@example.com:443", ParseError::InvalidEncoding),
    ] {
        assert_parse_error(uri, error);
    }
}

#[test]
fn rejects_control_characters_and_oversized_input() {
    for control in ['\0', '\n', '\r', '\t', '\u{7f}'] {
        assert_parse_error(
            &format!("hy2://secret@example.com:443#{control}"),
            ParseError::InvalidUri,
        );
    }
    let prefix = "hy2://secret@example.com:443#";
    let at_limit = format!("{prefix}{}", "x".repeat(64 * 1024 - prefix.len()));
    assert!(parse(&at_limit).is_ok());
    assert_parse_error(&(at_limit + "x"), ParseError::InvalidUri);
}

#[test]
fn rejects_duplicate_security_and_transport_parameters() {
    for key in [
        "auth",
        "insecure",
        "security",
        "sni",
        "alpn",
        "fp",
        "obfs",
        "obfs-password",
        "port",
        "ports",
        "mportHopInt",
        "hop-interval",
        "up",
        "down",
    ] {
        assert_parse_error(
            &format!("hy2://secret@example.com:443?{key}=first&{key}=second"),
            ParseError::DuplicateParameter(key.to_owned()),
        );
    }
    assert_parse_error(
        "hy2://secret@example.com:443?auth=secret&%61uth=secret",
        ParseError::DuplicateParameter("auth".to_owned()),
    );
}

#[test]
fn rejects_conflicting_port_hopping_aliases() {
    for (query, first, second) in [
        ("port=443&ports=443", "port", "ports"),
        (
            "mportHopInt=5&hop-interval=5",
            "mportHopInt",
            "hop-interval",
        ),
    ] {
        assert_parse_error(
            &format!("hy2://secret@example.com:443?{query}"),
            ParseError::ConflictingAliases(first, second),
        );
    }
}

#[test]
fn rejects_tls_relaxation_and_non_tls_security() {
    for value in ["1", "true", "yes"] {
        assert_parse_error(
            &format!("hy2://secret@example.com:443?insecure={value}"),
            ParseError::UnsafeTls,
        );
    }
    assert_parse_error(
        "hy2://secret@example.com:443?security=none",
        ParseError::UnsupportedSecurity,
    );
    assert!(parse("hy2://secret@example.com:443?security=tls&insecure=0").is_ok());
}

#[test]
fn preserves_transport_options_and_repeated_unknown_parameters() {
    let parsed = parse(
        "hy2://secret@example.com:443?sni=tls.example.com&alpn=h3%2C%2Ch2&fp=chrome\
         &up=10%20Mbps&down=100%20Mbps&custom=one&custom=two#Office",
    )
    .unwrap();
    let endpoint = parsed.endpoint;
    assert_eq!(endpoint.server_name.as_deref(), Some("tls.example.com"));
    assert_eq!(endpoint.alpn, ["h3", "h2"]);
    assert_eq!(endpoint.fingerprint.as_deref(), Some("chrome"));
    assert_eq!(endpoint.bandwidth.upload.as_deref(), Some("10 Mbps"));
    assert_eq!(endpoint.bandwidth.download.as_deref(), Some("100 Mbps"));
    assert_eq!(endpoint.display_name.as_deref(), Some("Office"));
    assert_eq!(endpoint.unknown_parameters.len(), 1);
    assert_eq!(endpoint.unknown_parameters["custom"], ["one", "two"]);
}

#[test]
fn accepts_port_hopping_aliases_and_interval_boundaries() {
    for ports_key in ["port", "ports"] {
        for interval_key in ["mportHopInt", "hop-interval"] {
            for interval in [5, 3600] {
                let uri = format!(
                    "hy2://secret@example.com:443?{ports_key}=1,443-445,65535&{interval_key}={interval}"
                );
                let hop = parse(&uri).unwrap().endpoint.port_hop.unwrap();
                assert_eq!(hop.ports, "1,443-445,65535");
                assert_eq!(hop.interval_seconds, Some(interval));
            }
        }
    }
    let hop = parse("hy2://secret@example.com:443?ports=443")
        .unwrap()
        .endpoint
        .port_hop
        .unwrap();
    assert_eq!(hop.interval_seconds, None);
}

#[test]
fn rejects_invalid_port_sets() {
    for ports in [
        "", "0", "65536", "445-443", "443-", "-443", "1-2-3", "443,", "443,,444", "abc",
    ] {
        assert_parse_error(
            &format!("hy2://secret@example.com:443?ports={ports}"),
            ParseError::InvalidPortSet,
        );
    }
    // All segments are valid, but the full set exceeds the 512-byte limit.
    let ports = vec!["443"; 129].join(",");
    assert_parse_error(
        &format!("hy2://secret@example.com:443?ports={ports}"),
        ParseError::InvalidPortSet,
    );
}

#[test]
fn rejects_invalid_or_unpaired_hopping_intervals() {
    for interval in ["", "0", "4", "3601", "-5", "5.0", "4294967296"] {
        assert_parse_error(
            &format!("hy2://secret@example.com:443?ports=443&hop-interval={interval}"),
            ParseError::InvalidHopInterval,
        );
    }
    assert_parse_error(
        "hy2://secret@example.com:443?hop-interval=5",
        ParseError::InvalidPortSet,
    );
}

#[test]
fn keeps_authentication_and_obfuscation_secrets_out_of_endpoint_json() {
    let parsed = parse(
        "hy2://test-auth-secret@example.com:443?obfs=salamander&obfs-password=test-obfs-secret",
    )
    .unwrap();
    assert_eq!(parsed.authentication, "test-auth-secret");
    assert_eq!(
        parsed.obfuscation_password.as_deref(),
        Some("test-obfs-secret")
    );
    let obfuscation = parsed.endpoint.obfuscation.as_ref().unwrap();
    assert_eq!(obfuscation.kind, "salamander");
    assert_eq!(obfuscation.password_ref, reference("profile.obfs"));
    let serialized = serde_json::to_string(&parsed.endpoint).unwrap();
    assert!(!serialized.contains("test-auth-secret"));
    assert!(!serialized.contains("test-obfs-secret"));
    let restored = serde_json::from_str(&serialized).unwrap();
    assert_eq!(parsed.endpoint, restored);
}

#[test]
fn rejects_incomplete_and_unsupported_obfuscation() {
    for (query, error) in [
        ("obfs=salamander", ParseError::MissingObfuscationPassword),
        (
            "obfs=salamander&obfs-password=",
            ParseError::MissingObfuscationPassword,
        ),
        (
            "obfs=unknown&obfs-password=secret",
            ParseError::UnsupportedObfuscation,
        ),
        ("obfs-password=secret", ParseError::UnsupportedObfuscation),
    ] {
        assert_parse_error(&format!("hy2://secret@example.com:443?{query}"), error);
    }
    assert_eq!(
        parse_hy2_uri(
            "hy2://secret@example.com:443?obfs=salamander&obfs-password=secret",
            reference("profile.auth"),
            None,
        )
        .err(),
        Some(ParseError::InvalidSecretRef),
    );
}

#[test]
fn validates_secret_reference_length_and_character_boundaries() {
    for id in [
        "a".to_owned(),
        "Profile_1.auth-key".to_owned(),
        "a".repeat(128),
    ] {
        assert!(reference(&id).validate().is_ok());
    }
    for id in [
        "".to_owned(),
        "a".repeat(129),
        "a/b".to_owned(),
        "a b".to_owned(),
        "a\n".to_owned(),
        "пароль".to_owned(),
    ] {
        assert!(reference(&id).validate().is_err());
        assert_eq!(
            parse_hy2_uri("hy2://secret@example.com:443", reference(&id), None).err(),
            Some(ParseError::InvalidSecretRef),
        );
        assert_eq!(
            parse_hy2_uri(
                "hy2://secret@example.com:443",
                reference("valid"),
                Some(reference(&id))
            )
            .err(),
            Some(ParseError::InvalidSecretRef),
        );
    }
}

#[test]
fn inbound_auth_debug_never_discloses_credentials() {
    let auth = InboundAuth {
        username: "test-private-user".to_owned(),
        password: "test-private-password".to_owned(),
    };
    for debug in [format!("{auth:?}"), format!("{auth:#?}")] {
        assert!(!debug.contains(&auth.username));
        assert!(!debug.contains(&auth.password));
        assert!(debug.contains("REDACTED"));
    }
}

use crate::compiler::{CompileError, compile_xray_config};
use crate::ffi::*;
use crate::model::{CompileRequest, PacketBackend, RouteAction, RuntimeOptions, SecretMaterial};
use crate::routing::{
    HappRoutingProfile, ManagedMatchMode, RoutingImport, decode_routing, merge_managed_routing,
    parse_managed_domains,
};
use base64::{Engine as _, engine::general_purpose};
use serde_json::{Value, json};
use std::collections::BTreeMap;

fn routing_profile() -> Value {
    json!({"RemoteDNSType":"DoU", "RemoteDNSIP":"1.1.1.1",
        "DomesticDNSType":"DoU", "DomesticDNSIP":"8.8.8.8"})
}

fn compile_request() -> CompileRequest {
    let parsed = parse("hy2://fixture-auth@proxy.example.com:443?sni=tls.example.com&alpn=h3%2Ch2&fp=chrome&ports=443-445&hop-interval=30&up=10%20Mbps&down=100%20Mbps&obfs=salamander&obfs-password=fixture-obfs").unwrap();
    CompileRequest {
        endpoint: parsed.endpoint,
        authentication: SecretMaterial {
            secret_ref: reference("profile.auth"),
            value: parsed.authentication,
        },
        obfuscation_password: Some(SecretMaterial {
            secret_ref: reference("profile.obfs"),
            value: parsed.obfuscation_password.unwrap(),
        }),
        routes: serde_json::from_value(json!({"rules":[],"dnsServers":["192.0.2.53"]})).unwrap(),
        socks_port: 10890,
        packet_backend: PacketBackend::NativeTun2Proxy,
        tun_mtu: 1500,
        runtime: RuntimeOptions::default(),
    }
}

fn compiled(request: &CompileRequest) -> Value {
    serde_json::from_slice(&compile_xray_config(request).unwrap()).unwrap()
}

fn tagged<'a>(config: &'a Value, collection: &str, tag: &str) -> &'a Value {
    config[collection]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["tag"] == tag)
        .unwrap()
}

#[test]
fn routing_import_formats_preserve_rules_and_explicit_activation() {
    let mut profile = routing_profile();
    profile["DirectSites"] = json!(["full:example.com", "full:example.com"]);
    let raw = profile.to_string();
    let base64 = general_purpose::STANDARD.encode(&raw);
    for (input, activate) in [
        (raw, false),
        (base64.clone(), false),
        (format!("happ://routing/add/{base64}"), false),
        (format!("happ://routing/onadd/{base64}"), true),
        (format!("incy://routing/add/{base64}"), false),
        (format!("incy://routing/onadd/{base64}"), true),
        (format!("elarni://routing/add/{base64}"), false),
        (format!("elarni://routing/onadd/{base64}"), true),
        (format!("://routing/onadd/{base64}"), true),
    ] {
        let RoutingImport::Add {
            activate: actual,
            route_model,
            ..
        } = decode_routing(&input).unwrap()
        else {
            panic!("expected routing profile")
        };
        assert_eq!(actual, activate);
        assert_eq!(route_model.rules[0].domains, ["full:example.com"]);
        assert_eq!(route_model.fallback_action, Some(RouteAction::Proxy));
    }
    assert!(matches!(
        decode_routing("happ://routing/off").unwrap(),
        RoutingImport::Off
    ));
    assert!(matches!(
        decode_routing("incy://routing/off").unwrap(),
        RoutingImport::Off
    ));
    assert!(matches!(
        decode_routing("elarni://routing/off").unwrap(),
        RoutingImport::Off
    ));
    assert_eq!(
        decode_routing("elarni://routing/unknown"),
        Err(crate::routing::RoutingError::UnsupportedLink)
    );
    for invalid in ["", "happ://routing/unknown", "not base64", "{}"] {
        assert!(decode_routing(invalid).is_err());
    }
    assert!(decode_routing(&" ".repeat(4 * 1024 * 1024 + 1)).is_err());
}

#[test]
fn routing_projection_preserves_order_aliases_dns_and_fallback() {
    let mut value = routing_profile();
    value.as_object_mut().unwrap().remove("RemoteDNSIP");
    value["RemoteDNSIp"] = json!("9.9.9.9");
    value["FakeDns"] = json!("true");
    value["GlobalProxy"] = json!("false");
    value["RouteOrder"] = json!("proxy-block-direct");
    value["ProxySites"] = json!(["proxy.example"]);
    value["BlockSites"] = json!(["block.example"]);
    value["DirectIp"] = json!(["192.0.2.0/24", "192.0.2.0/24"]);
    value["DomesticDNSDomains"] = json!(["full:example.cn", "full:example.cn"]);
    value["DnsHosts"] = json!({"EXAMPLE.TEST":"192.0.2.5"});
    let profile: HappRoutingProfile = serde_json::from_value(value).unwrap();
    let routes = profile.to_route_model().unwrap();
    assert_eq!(
        routes.rules.iter().map(|r| r.action).collect::<Vec<_>>(),
        [RouteAction::Proxy, RouteAction::Block, RouteAction::Direct]
    );
    assert_eq!(routes.rules[2].ips, ["192.0.2.0/24"]);
    assert_eq!(routes.dns_servers, ["9.9.9.9", "8.8.8.8"]);
    assert_eq!(routes.static_hosts["example.test"], ["192.0.2.5"]);
    assert_eq!(
        routes.dns_policy.unwrap().domestic_domains.unwrap(),
        ["full:example.cn"]
    );
    assert!(routes.fake_dns);
    assert_eq!(routes.fallback_action, Some(RouteAction::Direct));
}

#[test]
fn managed_domains_normalize_comments_duplicates_and_match_modes() {
    let text = "# provider list\n Example.COM \nexample.com\nsub.example.com\n";
    assert_eq!(
        parse_managed_domains(text, ManagedMatchMode::Exact).unwrap(),
        ["full:example.com", "full:sub.example.com"]
    );
    assert_eq!(
        parse_managed_domains(text, ManagedMatchMode::Subdomains).unwrap(),
        ["domain:example.com", "domain:sub.example.com"]
    );
    for invalid in [
        "https://example.com",
        "*.example.com",
        "example.com/path",
        "127.0.0.1",
        "a..example",
        "-a.example",
        "a example",
        "example.com\0",
    ] {
        assert!(
            parse_managed_domains(invalid, ManagedMatchMode::Exact).is_err(),
            "accepted {invalid:?}"
        );
    }
}

#[test]
fn managed_merge_routes_destinations_and_revalidates_persisted_data() {
    let mut value = routing_profile();
    value["DomesticDNSDomains"] = json!(["domain:existing.example"]);
    value["ManagedSources"] = json!([
        {"id":"block","url":"https://lists.example/block","destination":"block","matchMode":"subdomains"},
        {"id":"dns","url":"https://lists.example/dns","destination":"dns","matchMode":"exact"}
    ]);
    let profile: HappRoutingProfile = serde_json::from_value(value).unwrap();
    let lists = BTreeMap::from([
        ("block".to_owned(), vec!["domain:ads.example".to_owned()]),
        ("dns".to_owned(), vec!["full:resolver.example".to_owned()]),
    ]);
    let routes = merge_managed_routing(&profile, &lists).unwrap();
    assert_eq!(routes.rules[0].action, RouteAction::Block);
    assert_eq!(routes.rules[0].domains, ["domain:ads.example"]);
    assert_eq!(
        routes.dns_policy.unwrap().domestic_domains.unwrap(),
        ["domain:existing.example", "full:resolver.example"]
    );
    for (id, domain) in [
        ("unknown", "domain:ads.example"),
        ("block", "full:ads.example"),
        ("block", "domain:UPPER.example"),
        ("block", "domain:127.0.0.1"),
    ] {
        assert!(
            merge_managed_routing(
                &profile,
                &BTreeMap::from([(id.to_owned(), vec![domain.to_owned()])])
            )
            .is_err()
        );
    }
}

#[test]
fn routing_rejects_invalid_cidrs_dns_and_source_identities() {
    for (key, invalid) in [
        ("DirectIp", json!(["192.0.2.0/33"])),
        ("BlockIp", json!(["2001:db8::/129"])),
        ("DomesticDNSDomains", json!(["192.0.2.1"])),
        ("RemoteDNSIP", json!("invalid")),
        (
            "ManagedSources",
            json!([{"id":"../bad","url":"https://lists.example/a","destination":"direct","matchMode":"exact"}]),
        ),
    ] {
        let mut value = routing_profile();
        value[key] = invalid;
        assert!(
            decode_routing(&value.to_string()).is_err(),
            "accepted {key}"
        );
    }
    let mut request = compile_request();
    request.routes.rules = vec![crate::model::RouteRule {
        action: RouteAction::Direct,
        domains: (0..100_001).map(|i| format!("full:{i}.example")).collect(),
        ips: vec![],
    }];
    assert_eq!(
        compile_xray_config(&request).unwrap_err(),
        CompileError::InvalidRoute
    );
}

// Geofile reducers find codes only after the geoip: or ext: prefix; Xray reads a
// leading ! the same as one before the code.
#[test]
fn routing_moves_geo_negation_next_to_the_code() {
    let mut value = routing_profile();
    value["DirectIp"] = json!([
        "!geoip:ru",
        "!!geoip:cn",
        "!geoip:!us",
        "!ext:lists/geoip.dat:de",
        "!ext-ip:geoip.dat:private",
        "!192.0.2.0/24"
    ]);
    let profile: HappRoutingProfile = serde_json::from_value(value).unwrap();
    assert_eq!(
        profile.to_route_model().unwrap().rules[0].ips,
        [
            "geoip:!ru",
            "geoip:cn",
            "geoip:us",
            "ext:lists/geoip.dat:!de",
            "ext-ip:geoip.dat:!private",
            "!192.0.2.0/24"
        ]
    );
}

// TLS and DNS carry punycode names, so a site written in Cyrillic never matched.
#[test]
fn routing_converts_non_ascii_sites_to_punycode() {
    let mut value = routing_profile();
    value["DirectSites"] = json!([
        "domain:госуслуги.рф",
        "full:Пример.рф",
        "domain:.рф",
        "госуслуги.рф",
        "regexp:^пример",
        "domain:example.com"
    ]);
    value["DomesticDNSDomains"] = json!(["domain:госуслуги.рф"]);
    let profile: HappRoutingProfile = serde_json::from_value(value).unwrap();
    let routes = profile.to_route_model().unwrap();
    assert_eq!(
        routes.rules[0].domains,
        [
            "domain:xn--c1aapkosapc.xn--p1ai",
            "full:xn--e1afmkfd.xn--p1ai",
            "domain:.xn--p1ai",
            "xn--c1aapkosapc.xn--p1ai",
            "regexp:^пример",
            "domain:example.com"
        ]
    );
    assert_eq!(
        routes.dns_policy.unwrap().domestic_domains.unwrap(),
        ["domain:xn--c1aapkosapc.xn--p1ai"]
    );
}

// Providers need to know which list holds the bad entry.
#[test]
fn routing_names_the_ip_list_that_holds_a_bad_entry() {
    for (key, invalid) in [
        ("DirectIp", "10.0.0.0/33"),
        ("ProxyIp", "example.com"),
        ("BlockIp", "2001:db8::/129"),
    ] {
        let mut value = routing_profile();
        value[key] = json!([invalid]);
        assert_eq!(
            decode_routing(&value.to_string()).unwrap_err(),
            crate::routing::RoutingError::InvalidField(key)
        );
    }
}

// Xray reads IPv4-mapped IPv6 addresses as IPv4, so their prefixes stop at 32.
#[test]
fn ipv4_mapped_cidrs_use_the_ipv4_prefix_bound() {
    for (target, valid) in [
        ("::ffff:192.0.2.0/32", true),
        ("2001:db8::/32", true),
        ("::ffff:192.0.2.0/120", false),
        ("::ffff:0:0/96", false),
    ] {
        assert_eq!(crate::compiler::valid_ip_target(target), valid, "{target}");
        let mut value = routing_profile();
        value["BlockIp"] = json!([target]);
        assert_eq!(
            decode_routing(&value.to_string()).is_ok(),
            valid,
            "{target}"
        );
    }
}

// For DoH the IP only spares resolving the DNS server's own name.
#[test]
fn routing_accepts_doh_without_a_bootstrap_ip() {
    let mut value = routing_profile();
    value["RemoteDNSType"] = json!("DoH");
    value["RemoteDNSDomain"] = json!("https://dns.example/dns-query");
    value["RemoteDNSIP"] = json!("");
    let RoutingImport::Add { route_model, .. } = decode_routing(&value.to_string()).unwrap() else {
        panic!("expected routing profile")
    };
    assert_eq!(route_model.dns_servers[0], "https://dns.example/dns-query");
    assert!(
        route_model
            .dns_policy
            .unwrap()
            .remote
            .bootstrap_ips
            .is_empty()
    );
    value["RemoteDNSType"] = json!("DoU");
    assert!(decode_routing(&value.to_string()).is_err());
}

#[test]
fn compiler_preserves_valid_ip_boundaries_negation_and_geodata_references() {
    let mut request = compile_request();
    let ips = [
        "0.0.0.0/0",
        "192.0.2.1/32",
        "::/0",
        "2001:db8::1/128",
        "!192.0.2.2",
        "geoip:!cn",
        "ext:lists/geoip.dat:cn",
        "ext-ip:geoip.dat:private",
    ];
    request.routes.rules = vec![crate::model::RouteRule {
        action: RouteAction::Direct,
        domains: vec![],
        ips: ips.map(str::to_owned).to_vec(),
    }];
    let config = compiled(&request);
    assert!(
        config["routing"]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .any(|rule| rule["ip"] == json!(ips))
    );
    for invalid in [
        "192.0.2.1/33",
        "2001:db8::1/129",
        "192.0.2.1/-1",
        "192.0.2.1/24/1",
        "not-an-ip",
    ] {
        request.routes.rules[0].ips = vec![invalid.into()];
        assert_eq!(
            compile_xray_config(&request).unwrap_err(),
            CompileError::InvalidRoute
        );
    }
}

#[test]
fn hysteria2_compilation_preserves_transport_tls_and_secret_material() {
    let request = compile_request();
    let config = compiled(&request);
    let proxy = tagged(&config, "outbounds", "elarni-proxy");
    assert_eq!(proxy["protocol"], "hysteria");
    assert_eq!(
        proxy["settings"],
        json!({"version":2,"address":"proxy.example.com","port":443})
    );
    let stream = &proxy["streamSettings"];
    assert_eq!(stream["network"], "hysteria");
    assert_eq!(stream["security"], "tls");
    assert_eq!(
        stream["tlsSettings"],
        json!({"allowInsecure":false,"serverName":"tls.example.com","alpn":["h3","h2"],"fingerprint":"chrome"})
    );
    assert_eq!(stream["hysteriaSettings"]["auth"], "fixture-auth");
    assert_eq!(
        stream["finalmask"]["quicParams"],
        json!({"congestion":"brutal","brutalUp":"10 Mbps","brutalDown":"100 Mbps"})
    );
    // Xray 26.10.29 hops ports in the udphop mask. It dials, and Xray applies masks last to first.
    assert_eq!(
        stream["finalmask"]["udp"],
        json!([
            {"type":"salamander","settings":{"password":"fixture-obfs"}},
            {"type":"udphop","settings":{"mode":"intervalLocal,intervalRemote","interval":30,"remotePorts":"443-445"}}
        ])
    );
    // Hopping alone needs no QUIC parameters.
    let mut request = compile_request();
    request.endpoint.bandwidth = Default::default();
    request.endpoint.obfuscation = None;
    request.endpoint.port_hop.as_mut().unwrap().interval_seconds = None;
    let config = compiled(&request);
    assert_eq!(
        tagged(&config, "outbounds", "elarni-proxy")["streamSettings"]["finalmask"],
        json!({"udp":[{"type":"udphop","settings":{"mode":"intervalLocal,intervalRemote","remotePorts":"443-445"}}]})
    );
    assert_eq!(
        config["routing"]["rules"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["outboundTag"],
        "elarni-block"
    );
}

#[test]
fn hysteria2_compile_rejects_missing_and_mismatched_secrets() {
    let mut request = compile_request();
    request.authentication.secret_ref = reference("wrong.auth");
    assert_eq!(
        compile_xray_config(&request).unwrap_err(),
        CompileError::SecretReference
    );
    request.authentication.secret_ref = reference("profile.auth");
    request.authentication.value.clear();
    assert_eq!(
        compile_xray_config(&request).unwrap_err(),
        CompileError::EmptySecret
    );
    for obfs in [
        None,
        Some(SecretMaterial {
            secret_ref: reference("wrong.obfs"),
            value: "fixture".into(),
        }),
        Some(SecretMaterial {
            secret_ref: reference("profile.obfs"),
            value: String::new(),
        }),
    ] {
        let mut request = compile_request();
        request.obfuscation_password = obfs;
        assert_eq!(
            compile_xray_config(&request).unwrap_err(),
            CompileError::ObfuscationSecret
        );
    }
}

// Without a bootstrap IP the proxy resolves the DoH server's name. Routed any
// other way, Xray's DNS would have to resolve that name through itself.
#[test]
fn doh_without_a_bootstrap_ip_still_reaches_its_server_through_the_proxy() {
    let mut request = compile_request();
    let mut value = routing_profile();
    value["GlobalProxy"] = json!("false");
    value["RemoteDNSType"] = json!("DoH");
    value["RemoteDNSDomain"] = json!("https://remote.example/dns-query");
    value["RemoteDNSIP"] = json!("");
    value["DomesticDNSDomains"] = json!(["full:example.cn"]);
    request.routes = serde_json::from_value::<HappRoutingProfile>(value)
        .unwrap()
        .to_route_model()
        .unwrap();
    let pinned = |config: &Value| {
        config["routing"]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .any(|rule| {
                rule["inboundTag"] == json!(["elarni-dns-client"])
                    && rule["domain"] == json!(["full:remote.example"])
                    && rule["outboundTag"] == "elarni-dns-bootstrap-0"
            })
    };
    let config = compiled(&request);
    assert!(pinned(&config), "{}", config["routing"]["rules"]);
    let bootstrap = tagged(&config, "outbounds", "elarni-dns-bootstrap-0");
    assert_eq!(
        bootstrap["streamSettings"]["sockopt"]["dialerProxy"],
        "elarni-proxy"
    );
    assert!(bootstrap["settings"].get("redirect").is_none());
    assert!(config["dns"]["hosts"].get("remote.example").is_none());
    let profile = crate::profile::compile_profile(
        json!({"outbounds": [{"tag": "server", "protocol": "vless", "settings": {
            "address": "server.example.com", "port": 443,
            "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}}]}),
        Some(&request.routes),
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &request.runtime,
        None,
    )
    .unwrap();
    assert!(pinned(&serde_json::from_slice(&profile.config).unwrap()));
}

#[test]
fn dns_compilation_uses_bootstrap_through_proxy_and_explicit_domestic_rules() {
    let mut request = compile_request();
    let mut value = routing_profile();
    value["RemoteDNSType"] = json!("DoH");
    value["RemoteDNSDomain"] = json!("https://remote.example/dns-query");
    value["RemoteDNSIP"] = json!("192.0.2.1");
    value["DomesticDNSType"] = json!("DoH");
    value["DomesticDNSDomain"] = json!("https://domestic.example/dns-query");
    value["DomesticDNSIP"] = json!("2001:db8::53");
    value["DomesticDNSDomains"] = json!(["full:example.cn"]);
    request.routes = serde_json::from_value::<HappRoutingProfile>(value)
        .unwrap()
        .to_route_model()
        .unwrap();
    let config = compiled(&request);
    assert_eq!(
        config["dns"]["servers"],
        json!([
            {"address":"https://remote.example/dns-query","timeoutMs":2000},
            {"address":"https://domestic.example/dns-query","domains":["full:example.cn"],"skipFallback":true}
        ])
    );
    assert_eq!(
        config["dns"]["hosts"]["remote.example"],
        json!(["192.0.2.1"])
    );
    assert_eq!(config["dns"]["disableFallbackIfMatch"], true);
    for (index, address) in ["192.0.2.1:443", "[2001:db8::53]:443"].iter().enumerate() {
        let bootstrap = tagged(
            &config,
            "outbounds",
            &format!("elarni-dns-bootstrap-{index}"),
        );
        assert_eq!(bootstrap["settings"]["redirect"], *address);
        assert_eq!(
            bootstrap["streamSettings"]["sockopt"]["dialerProxy"],
            "elarni-proxy"
        );
        assert_eq!(bootstrap["targetStrategy"], "AsIs");
    }
    request.routes.dns_policy.as_mut().unwrap().domestic_domains = None;
    let legacy = compiled(&request);
    assert!(legacy["dns"]["servers"][1].get("skipFallback").is_none());
    request.routes.fake_dns = true;
    let fake = compiled(&request);
    assert_eq!(fake["dns"]["servers"][0], "fakedns");
    // Domestic and AAAA answers are real IPs; only sniffing gives them a domain to route by.
    assert_eq!(
        tagged(&fake, "inbounds", "elarni-socks")["sniffing"],
        json!({"enabled": true, "destOverride": ["fakedns", "http", "tls", "quic"], "routeOnly": true})
    );
    request.runtime.use_dns_from_json = false;
    let defaults = compiled(&request);
    assert_eq!(defaults["dns"]["servers"], json!(["1.1.1.1"]));
    assert!(
        !defaults["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value["tag"]
                .as_str()
                .unwrap()
                .starts_with("elarni-dns-bootstrap"))
    );
}

// With a direct fallback, the remote resolver's own plain-UDP queries would follow it and
// cross the ISP in clear. The domestic resolver keeps following the rules.
#[test]
fn plain_udp_remote_resolver_reaches_its_server_through_the_proxy() {
    use crate::compiler::compile_xray_outbound_config_with_options;
    let mut value = routing_profile();
    value["GlobalProxy"] = json!("false");
    let routes = serde_json::from_value::<HappRoutingProfile>(value)
        .unwrap()
        .to_route_model()
        .unwrap();
    let pin = |resolver: &str| {
        json!({"type": "field", "network": "tcp,udp", "port": 53, "inboundTag": ["elarni-dns-client"],
            "ip": [resolver], "outboundTag": "elarni-proxy"})
    };
    let mut request = compile_request();
    request.routes = routes.clone();
    let config = compiled(&request);
    let rules = config["routing"]["rules"].as_array().unwrap();
    assert_eq!(rules[1], pin("1.1.1.1"), "{rules:?}");
    assert_eq!(rules.last().unwrap()["outboundTag"], "elarni-direct");
    assert!(!rules.contains(&pin("8.8.8.8")));
    // The pin matches by inbound first, so it gives hostnames no reason to resolve.
    assert_eq!(config["routing"]["domainStrategy"], "IPIfNonMatch");
    // An HTTP proxy carries no UDP: the resolver would fail instead.
    let (http, _) = compile_xray_outbound_config_with_options(
        json!({"protocol": "http", "settings": {"servers": [{"address": "proxy.example.com", "port": 8080}]}}),
        &routes,
        10890,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions::default(),
    )
    .unwrap();
    let http: Value = serde_json::from_slice(&http).unwrap();
    assert!(
        http["routing"]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .all(|rule| rule["inboundTag"] != json!(["elarni-dns-client"]))
    );
}

// Apps resolve through Xray's DNS: an expired answer is served while it refreshes, and an
// IPv4 preference keeps apps off IPv6 the server may not reach.
#[test]
fn dns_serves_stale_answers_and_follows_an_ipv4_preference() {
    use crate::model::PreferredIp;
    for (preference, strategy) in [
        (PreferredIp::Ipv4, "UseIPv4"),
        (PreferredIp::Ipv6, "UseIP"),
        (PreferredIp::Automatic, "UseIP"),
    ] {
        let mut request = compile_request();
        request.runtime.preferred_ip = preference;
        let config = compiled(&request);
        assert_eq!(config["dns"]["queryStrategy"], strategy, "{preference:?}");
        assert_eq!(config["dns"]["serveStale"], true);
        // Without a bound Xray never cleans its cache.
        assert_eq!(config["dns"]["serveExpiredTTL"], 3600);
        // Blackholing needs no lookup first.
        assert_eq!(
            *tagged(&config, "outbounds", "elarni-block"),
            json!({"tag": "elarni-block", "protocol": "blackhole", "settings": {"response": {"type": "none"}}})
        );
        // A profile keeps its own addressing unless its override names a family.
        for (requested, strategy) in [(None, "UseIP"), (Some(preference), strategy)] {
            let profile = crate::profile::compile_profile(
                json!({"outbounds": [{"tag": "server", "protocol": "vless", "settings": {
                    "address": "server.example.com", "port": 443,
                    "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}}]}),
                None,
                1080,
                PacketBackend::NativeTun2Proxy,
                1500,
                &request.runtime,
                requested,
            )
            .unwrap();
            let profile: Value = serde_json::from_slice(&profile.config).unwrap();
            assert_eq!(
                profile["dns"]["queryStrategy"], strategy,
                "{preference:?} {requested:?}"
            );
            assert_eq!(profile["dns"]["serveStale"], true);
        }
    }
}

// Apple's tunnel tells a dead server from an idle one by these counters,
// whatever the packet backend.
#[test]
fn every_packet_backend_counts_inbound_traffic() {
    let mut request = compile_request();
    for backend in [PacketBackend::NativeTun2Proxy, PacketBackend::XrayTun] {
        request.packet_backend = backend;
        let config = compiled(&request);
        assert_eq!(config["stats"], json!({}), "{backend:?}");
        assert_eq!(
            config["policy"]["system"],
            json!({"statsInboundUplink": true, "statsInboundDownlink": true}),
            "{backend:?}"
        );
    }
}

#[test]
fn runtime_listener_authentication_and_idle_limits_are_enforced() {
    let mut request = compile_request();
    request.runtime.allow_lan = true;
    assert_eq!(
        compile_xray_config(&request).unwrap_err(),
        CompileError::InvalidInbound
    );
    request.runtime.inbound_auth = Some(InboundAuth {
        username: "fixture-user".into(),
        password: "fixture-pass".into(),
    });
    request.runtime.http_inbound_enabled = true;
    request.runtime.http_port = Some(18080);
    request.runtime.connection_idle_seconds = 600;
    let config = compiled(&request);
    for tag in ["elarni-socks", "elarni-http"] {
        let inbound = tagged(&config, "inbounds", tag);
        assert_eq!(inbound["listen"], "0.0.0.0");
        assert_eq!(
            inbound["settings"]["accounts"],
            json!([{"user":"fixture-user","pass":"fixture-pass"}])
        );
    }
    assert_eq!(tagged(&config, "inbounds", "elarni-http")["port"], 18080);
    assert_eq!(config["policy"]["levels"]["0"]["connIdle"], 600);
    assert_eq!(config["policy"]["levels"]["0"]["downlinkOnly"], 0);
    request.runtime.http_port = Some(request.socks_port);
    assert_eq!(
        compile_xray_config(&request).unwrap_err(),
        CompileError::InvalidInbound
    );
    request.runtime.http_port = Some(18080);
    for seconds in [29, 3601] {
        request.runtime.connection_idle_seconds = seconds;
        assert_eq!(
            compile_xray_config(&request).unwrap_err(),
            CompileError::InvalidConnectionIdle
        );
    }
}

struct FfiHandle(*mut ElarniHandle);
impl FfiHandle {
    fn new() -> Self {
        Self(elarni_handle_new())
    }
    fn request(&self, bytes: &[u8]) -> (ElarniStatus, Option<Value>) {
        let mut output = ElarniBuffer::default();
        // This fixture owns the handle, input bytes and output allocation for the call.
        unsafe {
            let status = elarni_request(self.0, bytes.as_ptr(), bytes.len(), &mut output);
            let response = if output.data.is_null() {
                None
            } else {
                Some(std::slice::from_raw_parts(output.data, output.len).to_vec())
            };
            elarni_buffer_free(output);
            (
                status,
                response.map(|bytes| serde_json::from_slice(&bytes).unwrap()),
            )
        }
    }
}
impl Drop for FfiHandle {
    fn drop(&mut self) {
        unsafe { elarni_handle_free(self.0) }
    }
}

#[test]
fn ffi_rejects_invalid_envelopes_versions_and_operations_without_echoing_input() {
    let handle = FfiHandle::new();
    for request in [
        json!({}),
        json!({"schemaVersion":1,"operation":"unknown","payload":{"secret":"fixture-private"}}),
        json!({"schemaVersion":1,"operation":"decodeRouting","payload":{},"unexpected":true}),
    ] {
        let (status, response) = handle.request(&serde_json::to_vec(&request).unwrap());
        assert_eq!(status, ELARNI_STATUS_INVALID_ARGUMENT);
        assert!(!response.unwrap().to_string().contains("fixture-private"));
    }
    assert_eq!(
        handle.request(b"{bad json").0,
        ELARNI_STATUS_INVALID_ARGUMENT
    );
    let (status, response) =
        handle.request(br#"{"schemaVersion":2,"operation":"decodeRouting","payload":{}}"#);
    assert_eq!(status, ELARNI_STATUS_UNSUPPORTED_VERSION);
    assert_eq!(response.unwrap()["schemaMin"], 1);
}

// Every app decodes provider "base64:" titles through this one operation.
#[test]
fn base64_text_decodes_every_alphabet_and_padding_alike() {
    let handle = FfiHandle::new();
    let decode = |text: &str| {
        let request =
            json!({"schemaVersion":1,"operation":"decodeBase64Text","payload":{"text":text}});
        let (status, response) = handle.request(&serde_json::to_vec(&request).unwrap());
        (status == ELARNI_STATUS_OK).then(|| response.unwrap()["text"].as_str().unwrap().to_owned())
    };
    // Encodes with '+', '/' and padding in the standard alphabet.
    let title = "Провайдер ✓?>!";
    for encoded in [
        general_purpose::STANDARD.encode(title),
        general_purpose::STANDARD_NO_PAD.encode(title),
        general_purpose::URL_SAFE.encode(title),
        general_purpose::URL_SAFE_NO_PAD.encode(title),
        format!(" {} \n", general_purpose::STANDARD.encode(title)),
    ] {
        assert_eq!(decode(&encoded).as_deref(), Some(title), "{encoded}");
    }
    for invalid in [
        "%%%",
        "",
        general_purpose::STANDARD.encode([0xff, 0xfe]).as_str(),
    ] {
        assert_eq!(decode(invalid), None, "{invalid}");
    }
}

#[test]
fn ffi_cancellation_is_consumed_once_and_size_errors_have_no_owned_buffer() {
    let handle = FfiHandle::new();
    let valid = br#"{"schemaVersion":1,"operation":"decodeRouting","payload":{"content":"happ://routing/off"}}"#;
    unsafe {
        assert_eq!(elarni_cancel(handle.0), ELARNI_STATUS_OK);
    }
    assert_eq!(handle.request(valid), (ELARNI_STATUS_CANCELLED, None));
    assert_eq!(handle.request(valid).0, ELARNI_STATUS_OK);
    let mut bytes = vec![b' '; crate::ffi::MAX_REQUEST_BYTES];
    assert_eq!(handle.request(&bytes).0, ELARNI_STATUS_INVALID_ARGUMENT);
    bytes.push(b' ');
    assert_eq!(
        handle.request(&bytes),
        (ELARNI_STATUS_REQUEST_TOO_LARGE, None)
    );
    assert_eq!(handle.request(&[]), (ELARNI_STATUS_INVALID_ARGUMENT, None));
    unsafe {
        assert_eq!(
            elarni_request(handle.0, valid.as_ptr(), valid.len(), std::ptr::null_mut()),
            ELARNI_STATUS_INVALID_ARGUMENT
        );
        let mut output = ElarniBuffer::default();
        assert_eq!(
            elarni_request(
                std::ptr::null_mut(),
                valid.as_ptr(),
                valid.len(),
                &mut output
            ),
            ELARNI_STATUS_INVALID_ARGUMENT
        );
        assert!(output.data.is_null());
    }
}

#[test]
fn ffi_compile_hy2_reports_parse_and_compile_errors_and_owned_config() {
    let handle = FfiHandle::new();
    let mut request = json!({"schemaVersion":1,"operation":"compileHy2Uri","payload":{
        "uri":"hy2://fixture-auth@proxy.example.com:443", "authenticationRef":{"id":"profile.auth"},
        "routes":{"rules":[],"dnsServers":["192.0.2.53"]},"socksPort":10890
    }});
    let (status, response) = handle.request(&serde_json::to_vec(&request).unwrap());
    assert_eq!(status, ELARNI_STATUS_OK);
    let response = response.unwrap();
    let config: Value = serde_json::from_str(response["configUtf8"].as_str().unwrap()).unwrap();
    assert_eq!(
        tagged(&config, "outbounds", "elarni-proxy")["settings"]["address"],
        "proxy.example.com"
    );
    request["payload"]["socksPort"] = json!(0);
    assert_eq!(
        handle.request(&serde_json::to_vec(&request).unwrap()).0,
        ELARNI_STATUS_COMPILE_ERROR
    );
    request["payload"]["uri"] = json!("hy2://fixture-auth@proxy.example.com:443?insecure=1");
    let (status, response) = handle.request(&serde_json::to_vec(&request).unwrap());
    assert_eq!(status, ELARNI_STATUS_PARSE_ERROR);
    assert!(!response.unwrap().to_string().contains("fixture-auth"));
}

// Xray retries rules with resolved IPs only when none matched, and the explicit
// fallback always matches, so hostnames would never reach IP rules.
#[test]
fn ip_rules_resolve_hostnames_ahead_of_the_explicit_fallback() {
    use crate::model::{RouteDomainStrategy, RouteRule};
    let mut request = compile_request();
    request.routes.fallback_action = Some(RouteAction::Proxy);
    for (strategy, ips, expected) in [
        (
            Some(RouteDomainStrategy::IpIfNonMatch),
            vec!["192.0.2.0/24"],
            "IPOnDemand",
        ),
        (
            Some(RouteDomainStrategy::IpIfNonMatch),
            vec![],
            "IPIfNonMatch",
        ),
        (
            Some(RouteDomainStrategy::IpOnDemand),
            vec!["192.0.2.0/24"],
            "IPOnDemand",
        ),
        (
            Some(RouteDomainStrategy::AsIs),
            vec!["192.0.2.0/24"],
            "AsIs",
        ),
        (None, vec!["192.0.2.0/24"], "AsIs"),
    ] {
        request.routes.domain_strategy = strategy;
        request.routes.rules = vec![RouteRule {
            action: RouteAction::Direct,
            domains: vec!["full:direct.example".into()],
            ips: ips.iter().map(|ip| ip.to_string()).collect(),
        }];
        assert_eq!(
            compiled(&request)["routing"]["domainStrategy"],
            expected,
            "{strategy:?} {ips:?}"
        );
    }
}

// Server IP type picks the family of the server address only; proxied
// destinations must reach the server as hostnames.
#[test]
fn server_ip_preference_leaves_proxied_destinations_unresolved() {
    use crate::compiler::compile_xray_outbound_config_with_options;
    use crate::model::PreferredIp;
    let vless = json!({"protocol": "vless", "settings": {"address": "proxy.example.com", "port": 443,
        "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}});
    for preference in [PreferredIp::Ipv4, PreferredIp::Ipv6, PreferredIp::Automatic] {
        let mut request = compile_request();
        request.runtime.preferred_ip = preference;
        let (outbound, _) = compile_xray_outbound_config_with_options(
            vless.clone(),
            &request.routes,
            10890,
            PacketBackend::NativeTun2Proxy,
            1500,
            &request.runtime,
        )
        .unwrap();
        for config in [
            compiled(&request),
            serde_json::from_slice(&outbound).unwrap(),
        ] {
            let proxy = tagged(&config, "outbounds", "elarni-proxy");
            assert!(
                proxy
                    .get("targetStrategy")
                    .is_none_or(|strategy| strategy == "AsIs"),
                "{preference:?}: {proxy}"
            );
        }
    }
    // A strategy the outbound itself carries is not the app's preference.
    let mut own = vless;
    own["targetStrategy"] = json!("UseIPv6v4");
    let (config, _) = compile_xray_outbound_config_with_options(
        own,
        &compile_request().routes,
        10890,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions::default(),
    )
    .unwrap();
    let config: Value = serde_json::from_slice(&config).unwrap();
    assert_eq!(
        tagged(&config, "outbounds", "elarni-proxy")["targetStrategy"],
        "UseIPv6v4"
    );
}

// Xray answers only A and AAAA itself. Other lookups go to the first resolver with an
// address, along the route of Xray's own queries; HTTPS records stay empty. A query keeps
// its own network ("" in Xray), so a TCP retry of a truncated answer is not truncated again.
#[test]
fn dns_outbound_forwards_other_query_types_along_the_dns_route() {
    for (servers, address) in [
        (json!(["192.0.2.53", "198.51.100.53"]), "192.0.2.53"),
        (
            json!([
                "https://dns.example/dns-query",
                "https://[2001:db8::53]/dns-query"
            ]),
            "2001:db8::53",
        ),
        (json!(["https://dns.example/dns-query"]), "1.1.1.1"),
    ] {
        let mut request = compile_request();
        request.routes =
            serde_json::from_value(json!({"rules": [], "dnsServers": servers})).unwrap();
        let config = compiled(&request);
        let dns = tagged(&config, "outbounds", "elarni-dns");
        assert_eq!(dns["settings"]["address"], address, "{servers}");
        assert_eq!(dns["settings"]["port"], 53);
        assert_eq!(dns["settings"]["network"], "", "{servers}");
        assert_eq!(
            dns["settings"]["rules"],
            json!([
                {"action": "hijack", "qType": "1,28"},
                {"action": "return", "qType": "64,65"},
                {"action": "direct"}
            ])
        );
        let forward = tagged(
            &config,
            "outbounds",
            dns["streamSettings"]["sockopt"]["dialerProxy"]
                .as_str()
                .unwrap(),
        );
        assert_eq!(forward["protocol"], "loopback");
        assert_eq!(forward["settings"]["inboundTag"], config["dns"]["tag"]);
    }
}

// Xray refuses to load a geodata reference without its code, so the whole config
// failed only at connect.
#[test]
fn rejects_geodata_references_without_a_code() {
    for (key, invalid) in [
        ("DirectIp", json!(["geoip:"])),
        ("BlockIp", json!(["!geoip:"])),
        ("DirectSites", json!(["geosite:"])),
        ("DomesticDNSDomains", json!(["geosite:"])),
    ] {
        let mut value = routing_profile();
        value[key] = invalid.clone();
        assert!(
            decode_routing(&value.to_string()).is_err(),
            "accepted {key} {invalid}"
        );
    }
}

// Xray's geodata parser also needs a file, an attribute after each '@', and no dot in a
// dotless rule; these too failed only at connect.
#[test]
fn rejects_geodata_forms_xray_cannot_read() {
    for (key, invalid) in [
        ("BlockSites", "geosite:@ads"),
        ("BlockSites", "geosite:category-ads@"),
        ("BlockSites", "geosite:category-ads@@ads"),
        ("BlockSites", "ext:custom.dat"),
        ("BlockSites", "ext-site::ads"),
        ("BlockSites", "dotless:a.b"),
        ("DirectIp", "ext:custom.dat"),
        ("DirectIp", "ext::RU"),
        ("DirectIp", "ext-ip:custom.dat:!"),
        ("DomesticDNSDomains", "geosite:@cn"),
    ] {
        let mut value = routing_profile();
        value[key] = json!([invalid]);
        assert!(
            decode_routing(&value.to_string()).is_err(),
            "accepted {key} {invalid}"
        );
    }
    for (key, valid) in [
        ("BlockSites", "geosite:category-ads-all@ads"),
        ("BlockSites", "ext:custom.dat:ads"),
        ("BlockSites", "dotless:intranet"),
        ("BlockSites", "dotless:"),
        ("DirectIp", "ext:custom.dat:!ru"),
    ] {
        let mut value = routing_profile();
        value[key] = json!([valid]);
        assert!(
            decode_routing(&value.to_string()).is_ok(),
            "rejected {key} {valid}"
        );
    }
}

// Xray compiles regexp: rules with Go's regexp package, so a bad pattern failed only at
// connect. Each pattern here was checked against Go's regexp.Compile.
#[test]
fn rejects_regexp_rules_go_cannot_compile() {
    for (key, invalid) in [
        ("BlockSites", "regexp:*.example.com"),
        ("DirectSites", "regexp:(example\\.com"),
        ("ProxySites", "regexp:example\\.com)"),
        ("BlockSites", "regexp:[a-z"),
        ("BlockSites", "regexp:[]"),
        ("BlockSites", "regexp:example\\"),
        ("BlockSites", "regexp:[a\\"),
        ("BlockSites", "regexp:a|+b"),
        ("BlockSites", "regexp:(*)"),
        ("BlockSites", "regexp:?a"),
        ("DomesticDNSDomains", "regexp:(cn"),
    ] {
        let mut value = routing_profile();
        value[key] = json!([invalid]);
        assert!(
            decode_routing(&value.to_string()).is_err(),
            "accepted {key} {invalid}"
        );
    }
    for valid in [
        "regexp:^(.+\\.)?example\\.com$",
        "regexp:(?i)^ads?\\.",
        "regexp:(?P<n>a)|b*",
        "regexp:[]a]",
        "regexp:[^]a]x",
        "regexp:[[:alpha:]](x)",
        "regexp:[[:]]",
        "regexp:[(]\\(",
        "regexp:\\Q(\\E",
        "regexp:^*",
        "regexp:a]{",
    ] {
        let mut value = routing_profile();
        value["BlockSites"] = json!([valid]);
        assert!(
            decode_routing(&value.to_string()).is_ok(),
            "rejected {valid}"
        );
    }
}

// Each verdict is Go's regexp.Compile on the pattern (Go 1.26). `\\p{Nope}` is left out: any
// Unicode class name passes (compiler.rs shortcut).
#[test]
fn regexp_validation_matches_go() {
    for (pattern, compiles) in [
        ("a", true),
        ("a*", true),
        ("a**", false),
        ("a*?", true),
        ("a*??", false),
        ("a+*", false),
        ("a?+", false),
        ("a{2}", true),
        ("a{2}*", false),
        ("a{2}?", true),
        ("a{2}??", false),
        ("a{2,}", true),
        ("a{2,5}", true),
        ("a{5,2}", false),
        ("a{,5}", true),
        ("a{1001}", false),
        ("a{1000}", true),
        ("a{2}{3}", false),
        ("x{", true),
        ("x{a}", true),
        ("{2}", false),
        ("*a", false),
        ("+a", false),
        ("?a", false),
        ("a|*b", false),
        ("a|(?i)*", false),
        ("(?i)*x", false),
        ("(?i)x*", true),
        ("(?i:x)*", true),
        ("(?P<n>x)*", true),
        ("(?<n>x)", true),
        ("(?P<n>x", false),
        ("(?P<>x)", false),
        ("(?P<1a>x)", true),
        ("(?z)", false),
        ("(?)", true),
        ("(?i-s:x)", true),
        ("(?-)", false),
        ("(?i-)", false),
        ("()*", true),
        ("(a)(b)", true),
        ("(a))", false),
        ("((a)", false),
        ("\\é", false),
        ("\\.", true),
        ("\\d+", true),
        ("\\pL", true),
        ("\\p{Greek}", true),
        ("\\PL", true),
        ("\\pZ", true),
        ("\\x7F", true),
        ("\\x{10FFFF}", true),
        ("\\x{110000}", false),
        ("\\xZ", false),
        ("\\x{}", false),
        ("\\1", false),
        ("\\0", true),
        ("\\8", false),
        ("\\123", true),
        ("\\Q*\\E*", true),
        ("\\Q.*", true),
        ("\\Qa\\E+", true),
        ("\\E", false),
        ("[\\Q]", false),
        ("[a]", true),
        ("[]a]", true),
        ("[^]a]", true),
        ("[a-]", true),
        ("[z-a]", false),
        ("[a-\\d]", false),
        ("[[:alpha:]]", true),
        ("[[:nope:]]", false),
        ("[[:^alpha:]]", true),
        ("[\\d]", true),
        ("[\\b]", false),
        ("[\\pL]", true),
        ("[\\é]", false),
        ("[\\.]", true),
        ("[a", false),
        ("a]", true),
        ("^*", true),
        ("$+", true),
        ("\\b*", true),
        ("\\A*", true),
        ("\\z", true),
        ("\\Z", false),
        ("\\e", false),
        ("\\cA", false),
        ("\\N", false),
        ("\\a\\f\\t\\n\\r\\v", true),
        ("\\_", true),
        ("\\-", true),
        ("\\", false),
        (".*\\.example\\.com$", true),
        ("^(www\\.)?example\\.(com|org)$", true),
        ("(?s).*", true),
        ("(?U)a*", true),
        ("(?m)^a$", true),
        ("a|", true),
        ("|", true),
        ("(|a)", true),
    ] {
        assert_eq!(
            !crate::compiler::invalid_regexp(&format!("regexp:{pattern}")),
            compiles,
            "{pattern:?}"
        );
    }
}

// Rust's integer parsing accepts a leading '+', which Xray rejects in a CIDR
// prefix and in a port set, so the whole config failed to start.
#[test]
fn rejects_plus_signs_xray_does_not_read() {
    assert_parse_error(
        "hy2://secret@example.com:443?ports=%2B443-445",
        ParseError::InvalidPortSet,
    );
    let mut value = routing_profile();
    value["DirectIp"] = json!(["10.0.0.0/+8"]);
    assert!(decode_routing(&value.to_string()).is_err());
    let mut request = compile_request();
    request.routes.rules = vec![crate::model::RouteRule {
        action: RouteAction::Direct,
        domains: vec![],
        ips: vec!["10.0.0.0/+8".into()],
    }];
    assert_eq!(
        compile_xray_config(&request).unwrap_err(),
        CompileError::InvalidRoute
    );
}
