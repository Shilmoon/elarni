use serde_json::{Value, json};

use crate::compiler::{compile_xray_outbound_config, compile_xray_outbound_config_with_options};
use crate::model::{PacketBackend, RouteModel, RuntimeOptions};

fn routes() -> RouteModel {
    serde_json::from_value(json!({"rules": [], "dnsServers": ["192.0.2.53"]})).unwrap()
}

fn outbound() -> Value {
    json!({
        "protocol": "vless",
        "sendThrough": "Provider display name",
        "tag": "provider-tag",
        "proxySettings": null,
        "settings": {
            "address": "proxy.example.com", "port": 443,
            "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"
        },
        "streamSettings": {
            "network": "tcp", "security": "tls",
            "tlsSettings": {"serverName": "tls.example.com", "allowInsecure": false}
        }
    })
}

#[test]
fn vless_compiles_modern_and_legacy_endpoint_shapes() {
    let modern = outbound();
    let mut legacy = outbound();
    legacy["settings"] = json!({"vnext": [{
        "address": "proxy.example.com", "port": 443,
        "users": [{"id": "00000000-0000-4000-8000-000000000001", "encryption": "none"}]
    }]});
    for source in [modern, legacy] {
        let (bytes, host) = compile_xray_outbound_config(source.clone(), &routes(), 1080).unwrap();
        let config: Value = serde_json::from_slice(&bytes).unwrap();
        let proxy = &config["outbounds"][0];
        assert_eq!(host, "proxy.example.com");
        assert_eq!(proxy["settings"], source["settings"]);
        assert_eq!(proxy["streamSettings"], source["streamSettings"]);
        assert_eq!(proxy["tag"], "elarni-proxy");
        assert!(proxy.get("sendThrough").is_none());
        assert!(proxy.get("proxySettings").is_none());
        assert_eq!(config["inbounds"][0]["listen"], "127.0.0.1");
        assert_eq!(config["inbounds"][0]["settings"]["udp"], true);
        assert_eq!(
            config["routing"]["rules"]
                .as_array()
                .unwrap()
                .last()
                .unwrap()["outboundTag"],
            "elarni-block"
        );
    }
}

#[test]
fn vless_reality_normalizes_legacy_names_without_replacing_current_sni() {
    for current_name in [None, Some("current.example.com")] {
        let mut source = outbound();
        let mut reality = json!({
            "serverNames": ["legacy.example.com"], "target": null, "dest": null,
            "fingerprint": "chrome", "password": "fixture-key", "shortId": "01234567"
        });
        if let Some(name) = current_name {
            reality["serverName"] = json!(name);
        }
        source["streamSettings"] =
            json!({"network": "tcp", "security": "reality", "realitySettings": reality});
        let (bytes, _) = compile_xray_outbound_config(source, &routes(), 1080).unwrap();
        let config: Value = serde_json::from_slice(&bytes).unwrap();
        let normalized = &config["outbounds"][0]["streamSettings"]["realitySettings"];
        assert_eq!(
            normalized["serverName"],
            current_name.unwrap_or("legacy.example.com")
        );
        assert_eq!(normalized["password"], "fixture-key");
        assert_eq!(normalized["shortId"], "01234567");
        for removed in ["serverNames", "target", "dest"] {
            assert!(normalized.get(removed).is_none());
        }
    }
}

#[test]
fn vless_vision_keeps_runtime_mux_off_and_reverse_is_removed() {
    let options = RuntimeOptions {
        mux_enabled: true,
        ..RuntimeOptions::default()
    };
    let mut modern = outbound();
    modern["settings"]["flow"] = json!("xtls-rprx-vision");
    modern["settings"]["reverse"] = json!({"tag": "portal"});
    let mut legacy = outbound();
    legacy["settings"] = json!({"vnext": [{"address": "proxy.example.com", "port": 443, "users": [{
        "id": "00000000-0000-4000-8000-000000000001", "encryption": "none",
        "flow": "xtls-rprx-vision", "reverse": {"tag": "portal"}
    }]}]});
    for source in [modern, legacy] {
        let (bytes, _) = compile_xray_outbound_config_with_options(
            source,
            &routes(),
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &options,
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&bytes).unwrap();
        // Vision servers reject mux connections that carry TCP.
        assert_eq!(config["outbounds"][0]["mux"]["enabled"], false);
        // VLESS reverse lets the server open connections into this device.
        assert!(!String::from_utf8(bytes).unwrap().contains("\"reverse\""));
    }
}

#[test]
fn routing_dns_hosts_beyond_32_compile() {
    let hosts: serde_json::Map<String, Value> = (0..40)
        .map(|index| (format!("host{index}.example.com"), json!(["192.0.2.1"])))
        .collect();
    let routes: RouteModel = serde_json::from_value(
        json!({"rules": [], "dnsServers": ["192.0.2.53"], "staticHosts": hosts}),
    )
    .unwrap();
    let (bytes, _) = compile_xray_outbound_config(outbound(), &routes, 1080).unwrap();
    let config: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        config["dns"]["hosts"]["host39.example.com"],
        json!(["192.0.2.1"])
    );
}

#[test]
fn vless_runtime_options_add_mux_and_supported_tls_fragmentation() {
    let options = RuntimeOptions {
        mux_enabled: true,
        fragmentation_enabled: true,
        ..RuntimeOptions::default()
    };
    let (bytes, _) = compile_xray_outbound_config_with_options(
        outbound(),
        &routes(),
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &options,
    )
    .unwrap();
    let config: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(config["outbounds"][0]["mux"]["enabled"], true);
    assert_eq!(
        config["outbounds"][0]["streamSettings"]["sockopt"]["dialerProxy"],
        "elarni-fragment"
    );
    let fragment = config["outbounds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|outbound| outbound["tag"] == "elarni-fragment")
        .unwrap();
    assert_eq!(fragment["settings"]["fragment"]["packets"], "tlshello");

    let mut source = outbound();
    source["mux"] = json!({"enabled": false});
    source["streamSettings"]["network"] = json!("ws");
    assert!(
        compile_xray_outbound_config_with_options(
            source.clone(),
            &routes(),
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &options,
        )
        .is_err()
    );
    let (bytes, _) = compile_xray_outbound_config_with_options(
        source,
        &routes(),
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &RuntimeOptions {
            mux_enabled: true,
            ..RuntimeOptions::default()
        },
    )
    .unwrap();
    let config: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(config["outbounds"][0]["mux"]["enabled"], false);
}

#[test]
fn vless_xhttp_tls_and_reality_support_fragmentation() {
    let options = RuntimeOptions {
        fragmentation_enabled: true,
        ..RuntimeOptions::default()
    };
    for security in ["tls", "reality"] {
        let mut source = outbound();
        source["streamSettings"]["network"] = json!("xhttp");
        // URI imports serialize unset Xray pointer fields as null.
        source["streamSettings"]["method"] = Value::Null;
        source["streamSettings"]["sockopt"] = Value::Null;
        source["streamSettings"]["security"] = json!(security);
        source["streamSettings"]["xhttpSettings"] = json!({"path": "/fixture", "mode": "auto"});
        let (bytes, _) = compile_xray_outbound_config_with_options(
            source.clone(),
            &routes(),
            1080,
            PacketBackend::NativeTun2Proxy,
            1500,
            &options,
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&bytes).unwrap();
        let stream = &config["outbounds"][0]["streamSettings"];
        assert_eq!(stream["network"], "xhttp");
        assert_eq!(stream["security"], security);
        assert_eq!(
            stream["xhttpSettings"],
            source["streamSettings"]["xhttpSettings"]
        );
        assert_eq!(stream["sockopt"]["dialerProxy"], "elarni-fragment");
        let helper = config["outbounds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|outbound| outbound["tag"] == "elarni-fragment")
            .unwrap();
        assert_eq!(helper["settings"]["fragment"]["packets"], "tlshello");
    }
}

#[test]
fn vless_native_and_xray_tun_backends_keep_the_socks_listener() {
    for backend in [PacketBackend::NativeTun2Proxy, PacketBackend::XrayTun] {
        let (bytes, _) = compile_xray_outbound_config_with_options(
            outbound(),
            &routes(),
            1080,
            backend,
            1400,
            &RuntimeOptions::default(),
        )
        .unwrap();
        let config: Value = serde_json::from_slice(&bytes).unwrap();
        let inbounds = config["inbounds"].as_array().unwrap();
        assert!(
            inbounds
                .iter()
                .any(|inbound| inbound["protocol"] == "socks" && inbound["port"] == 1080)
        );
        let tun = inbounds.iter().find(|inbound| inbound["protocol"] == "tun");
        if backend == PacketBackend::XrayTun {
            assert_eq!(tun.unwrap()["settings"]["mtu"], 1400);
        } else {
            assert!(tun.is_none());
        }
    }
}

#[test]
fn vless_rejects_unsupported_outbound_fields_and_missing_hosts() {
    for invalid in [
        json!({"protocol": "vless", "settings": {}}),
        json!({"protocol": "vless", "settings": {"address": ""}}),
        json!({"protocol": "trojan", "settings": {"address": "proxy.example.com"}}),
    ] {
        assert!(compile_xray_outbound_config(invalid, &routes(), 1080).is_err());
    }
    for (field, value) in [
        ("unknown", json!(true)),
        ("proxySettings", json!({"tag": "untrusted"})),
    ] {
        let mut source = outbound();
        source[field] = value;
        assert!(compile_xray_outbound_config(source, &routes(), 1080).is_err());
    }
}

#[test]
fn client_protocols_preserve_modern_and_legacy_server_settings() {
    for protocol in ["vmess", "trojan", "shadowsocks", "socks", "http"] {
        for server_field in [None, Some("servers")] {
            let server = json!({"address": "proxy.example.com", "port": 443,
                "user": "fixture-user", "pass": "fixture-password"});
            let settings = match server_field {
                Some(field) => json!({field: [server]}),
                None => server,
            };
            let source = json!({"protocol": protocol, "settings": settings,
                "streamSettings": {"network": "ws", "security": "tls",
                    "tlsSettings": {"serverName": "peer.example.com"},
                    "wsSettings": {"path": "/fixture", "host": "cdn.example.com"}}});
            let (bytes, host) =
                compile_xray_outbound_config(source.clone(), &routes(), 1080).unwrap();
            let config: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(host, "proxy.example.com");
            assert_eq!(config["outbounds"][0]["protocol"], protocol);
            assert_eq!(config["outbounds"][0]["settings"], settings);
            assert_eq!(
                config["outbounds"][0]["streamSettings"],
                source["streamSettings"]
            );
        }
    }
}

#[test]
fn wireguard_preserves_peers_and_uses_the_remote_endpoint() {
    let source = json!({"protocol": "wireguard", "settings": {
        "secretKey": "fixture-key", "address": ["10.7.0.2/32"], "mtu": 1380,
        "peers": [{"publicKey": "fixture-peer", "endpoint": "[2001:db8::1]:51820",
            "allowedIPs": ["0.0.0.0/0", "::/0"], "keepAlive": 25}]
    }});
    let (bytes, host) = compile_xray_outbound_config(source.clone(), &routes(), 1080).unwrap();
    assert_eq!(host, "2001:db8::1");
    let config: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(config["outbounds"][0]["settings"], source["settings"]);
}
