use std::collections::BTreeSet;
use std::net::IpAddr;

use serde_json::{Value, json};
use thiserror::Error;

use crate::model::{
    CompileRequest, PacketBackend, PreferredIp, RouteAction, RouteDomainStrategy, RouteRule,
    RuntimeOptions,
};

#[derive(Debug, Error, Eq, PartialEq)]
pub enum CompileError {
    #[error("schema version is unsupported")]
    SchemaVersion,
    #[error("secret reference mismatch")]
    SecretReference,
    #[error("secret is empty")]
    EmptySecret,
    #[error("SOCKS port must be non-zero")]
    InvalidSocksPort,
    #[error("listener ports or credentials are invalid; LAN access requires authentication")]
    InvalidInbound,
    #[error("TUN MTU is invalid")]
    InvalidTunMtu,
    #[error("route target is invalid")]
    InvalidRoute,
    #[error("DNS server is invalid")]
    InvalidDns,
    #[error("static host mapping is invalid")]
    InvalidStaticHost,
    #[error("obfuscation secret is missing or mismatched")]
    ObfuscationSecret,
    #[error("selected outbound is invalid")]
    InvalidOutbound,
    #[error("fragmentation is unsupported by the selected outbound")]
    UnsupportedFragmentation,
    #[error("fragmentation packet, length or interval bounds are invalid")]
    InvalidFragmentation,
    #[error("connection idle timeout is invalid")]
    InvalidConnectionIdle,
}

pub fn compile_xray_config(request: &CompileRequest) -> Result<Vec<u8>, CompileError> {
    if request.endpoint.schema_version != 1 {
        return Err(CompileError::SchemaVersion);
    }
    if request.socks_port == 0 {
        return Err(CompileError::InvalidSocksPort);
    }
    request
        .endpoint
        .secret_ref
        .validate()
        .map_err(|_| CompileError::SecretReference)?;
    if request.authentication.secret_ref != request.endpoint.secret_ref {
        return Err(CompileError::SecretReference);
    }
    if request.authentication.value.is_empty() {
        return Err(CompileError::EmptySecret);
    }

    let mut stream_settings = json!({
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
            "allowInsecure": false
        },
        "hysteriaSettings": {
            "version": 2,
            "auth": request.authentication.value
        }
    });
    let stream = stream_settings.as_object_mut().expect("JSON object");
    let tls = stream
        .get_mut("tlsSettings")
        .and_then(Value::as_object_mut)
        .expect("TLS object");
    if let Some(server_name) = &request.endpoint.server_name {
        tls.insert("serverName".to_owned(), json!(server_name));
    }
    if !request.endpoint.alpn.is_empty() {
        tls.insert("alpn".to_owned(), json!(request.endpoint.alpn));
    }
    if let Some(fingerprint) = &request.endpoint.fingerprint {
        tls.insert("fingerprint".to_owned(), json!(fingerprint));
    }

    if request.endpoint.port_hop.is_some()
        || request.endpoint.bandwidth.upload.is_some()
        || request.endpoint.bandwidth.download.is_some()
        || request.endpoint.obfuscation.is_some()
    {
        let mut final_mask = serde_json::Map::new();
        if request.endpoint.bandwidth.upload.is_some()
            || request.endpoint.bandwidth.download.is_some()
        {
            let mut quic = serde_json::Map::new();
            quic.insert("congestion".to_owned(), json!("brutal"));
            if let Some(upload) = &request.endpoint.bandwidth.upload {
                quic.insert("brutalUp".to_owned(), json!(upload));
            }
            if let Some(download) = &request.endpoint.bandwidth.download {
                quic.insert("brutalDown".to_owned(), json!(download));
            }
            final_mask.insert("quicParams".to_owned(), Value::Object(quic));
        }
        let mut udp_masks = Vec::new();
        if let Some(obfuscation) = &request.endpoint.obfuscation {
            let secret = request
                .obfuscation_password
                .as_ref()
                .filter(|secret| secret.secret_ref == obfuscation.password_ref)
                .filter(|secret| !secret.value.is_empty())
                .ok_or(CompileError::ObfuscationSecret)?;
            udp_masks.push(json!({
                "type": "salamander",
                "settings": {"password": secret.value}
            }));
        }
        if let Some(hop) = &request.endpoint.port_hop {
            // Hysteria hops from a new local socket too. The mask dials, and Xray
            // applies masks last to first with only the first allowed to dial.
            let mut settings = serde_json::Map::new();
            settings.insert("mode".to_owned(), json!("intervalLocal,intervalRemote"));
            if let Some(interval) = hop.interval_seconds {
                settings.insert("interval".to_owned(), json!(interval));
            }
            settings.insert("remotePorts".to_owned(), json!(hop.ports));
            udp_masks.push(json!({"type": "udphop", "settings": settings}));
        }
        if !udp_masks.is_empty() {
            final_mask.insert("udp".to_owned(), json!(udp_masks));
        }
        stream.insert("finalmask".to_owned(), Value::Object(final_mask));
    }

    let proxy_outbound = json!({
        "tag": "elarni-proxy",
        "protocol": "hysteria",
        "settings": {
            "version": 2,
            "address": request.endpoint.host,
            "port": request.endpoint.port
        },
        "streamSettings": stream_settings
    });
    compile_owned_config(
        proxy_outbound,
        &request.routes,
        request.socks_port,
        request.packet_backend,
        request.tun_mtu,
        &request.runtime,
    )
}

pub fn compile_xray_outbound_config(
    outbound: Value,
    routes: &crate::model::RouteModel,
    socks_port: u16,
) -> Result<(Vec<u8>, String), CompileError> {
    compile_xray_outbound_config_for_backend(
        outbound,
        routes,
        socks_port,
        PacketBackend::NativeTun2Proxy,
        1500,
    )
}

pub fn compile_xray_outbound_config_for_backend(
    outbound: Value,
    routes: &crate::model::RouteModel,
    socks_port: u16,
    packet_backend: PacketBackend,
    tun_mtu: u16,
) -> Result<(Vec<u8>, String), CompileError> {
    compile_xray_outbound_config_with_options(
        outbound,
        routes,
        socks_port,
        packet_backend,
        tun_mtu,
        &RuntimeOptions::default(),
    )
}

pub fn compile_xray_outbound_config_with_options(
    mut outbound: Value,
    routes: &crate::model::RouteModel,
    socks_port: u16,
    packet_backend: PacketBackend,
    tun_mtu: u16,
    runtime: &RuntimeOptions,
) -> Result<(Vec<u8>, String), CompileError> {
    if socks_port == 0 {
        return Err(CompileError::InvalidSocksPort);
    }
    let endpoint_host = normalize_client_outbound(&mut outbound)?;
    outbound["tag"] = json!("elarni-proxy");
    let config = compile_owned_config(
        outbound,
        routes,
        socks_port,
        packet_backend,
        tun_mtu,
        runtime,
    )?;
    Ok((config, endpoint_host))
}

/// Checks one client outbound and drops what a compiled config sets itself; returns its endpoint host.
fn normalize_client_outbound(outbound: &mut Value) -> Result<String, CompileError> {
    reject_ambiguous_keys(outbound)?;
    normalize_legacy_reality_names(outbound)?;
    let object = outbound
        .as_object_mut()
        .ok_or(CompileError::InvalidOutbound)?;
    const ALLOWED: &[&str] = &[
        "protocol",
        "sendThrough",
        "tag",
        "settings",
        "streamSettings",
        "proxySettings",
        "mux",
        "targetStrategy",
    ];
    if object.keys().any(|key| !ALLOWED.contains(&key.as_str()))
        || object
            .get("proxySettings")
            .is_some_and(|value| !value.is_null())
    {
        return Err(CompileError::InvalidOutbound);
    }
    let protocol = object
        .get("protocol")
        .and_then(Value::as_str)
        .filter(|value| is_client_protocol(value))
        .ok_or(CompileError::InvalidOutbound)?;
    let settings = object
        .get("settings")
        .and_then(Value::as_object)
        .ok_or(CompileError::InvalidOutbound)?;
    if protocol == "hysteria" && settings.get("version").and_then(Value::as_i64) != Some(2) {
        return Err(CompileError::InvalidOutbound);
    }
    let endpoint_host = outbound_host(settings).ok_or(CompileError::InvalidOutbound)?;
    object.remove("sendThrough");
    object.remove("proxySettings");
    Ok(endpoint_host)
}

pub(crate) fn normalize_legacy_reality_names(value: &mut Value) -> Result<(), CompileError> {
    match value {
        Value::Object(object) => {
            if let Some(reality) = object
                .get_mut("realitySettings")
                .and_then(Value::as_object_mut)
            {
                for key in ["target", "dest"] {
                    if reality.get(key).is_some_and(Value::is_null) {
                        reality.remove(key);
                    }
                }
                if let Some(server_names) = reality.remove("serverNames") {
                    let current_name = reality
                        .get("serverName")
                        .and_then(Value::as_str)
                        .filter(|name| !name.is_empty());
                    if current_name.is_none() && !server_names.is_null() {
                        let legacy_name = server_names
                            .as_array()
                            .and_then(|names| names.first())
                            .and_then(Value::as_str)
                            .filter(|name| !name.is_empty())
                            .ok_or(CompileError::InvalidOutbound)?;
                        reality.insert("serverName".to_owned(), json!(legacy_name));
                    }
                }
            }
            for child in object.values_mut() {
                normalize_legacy_reality_names(child)?;
            }
        }
        Value::Array(values) => {
            for child in values {
                normalize_legacy_reality_names(child)?;
            }
        }
        _ => {}
    }
    Ok(())
}

pub(crate) fn is_client_protocol(protocol: &str) -> bool {
    matches!(
        protocol,
        "vless"
            | "vmess"
            | "trojan"
            | "shadowsocks"
            | "socks"
            | "http"
            | "hysteria"
            | "tuic"
            | "wireguard"
            | "amneziawg"
    )
}

pub(crate) fn outbound_host(settings: &serde_json::Map<String, Value>) -> Option<String> {
    let server = if settings.get("address").is_some_and(Value::is_string) {
        settings
    } else if let Some(servers) = settings.get("vnext").or_else(|| settings.get("servers")) {
        let servers = servers.as_array()?;
        if servers.len() != 1 {
            return None;
        }
        servers.first()?.as_object()?
    } else {
        let endpoint = settings
            .get("peers")?
            .as_array()?
            .first()?
            .get("endpoint")?
            .as_str()?;
        let url = url::Url::parse(&format!("udp://{endpoint}")).ok()?;
        url.port().filter(|port| *port != 0)?;
        return url
            .host_str()
            .map(|host| host.trim_matches(['[', ']']).to_owned());
    };
    server
        .get("port")?
        .as_u64()
        .filter(|port| (1..=65535).contains(port))?;
    server
        .get("address")?
        .as_str()
        .filter(|host| {
            !host.is_empty() && host.len() <= 253 && !host.chars().any(char::is_whitespace)
        })
        .map(str::to_owned)
}

/// Xray fields this crate finds, strips or validates by their exact spelling.
const CHECKED_KEYS: &[&str] = &[
    "address",
    "alpn",
    "balancerTag",
    "balancers",
    "burstObservatory",
    "dest",
    "dialerProxy",
    "dns",
    "domainStrategy",
    "downloadSettings",
    "extra",
    "fallbackTag",
    "flow",
    "grpcSettings",
    "headers",
    "hosts",
    "httpupgradeSettings",
    "inboundTag",
    "inbounds",
    "ip",
    "method",
    "mux",
    "network",
    "observatory",
    "outboundTag",
    "outbounds",
    "penetrate",
    "protocol",
    "proxySettings",
    "realitySettings",
    "redirect",
    "reverse",
    "routing",
    "rules",
    "security",
    "selector",
    "sendThrough",
    "serverName",
    "serverNames",
    "servers",
    "settings",
    "sockopt",
    "splithttpSettings",
    "streamSettings",
    "subjectSelector",
    "tag",
    "target",
    "targetStrategy",
    "tlsSettings",
    "transportLayer",
    "users",
    "vnext",
    "wsSettings",
    "xhttpSettings",
];

/// Xray's encoding/json matches keys case-insensitively, also folds U+017F to s
/// and U+212A to k, and lets the last duplicate win. Provider JSON whose keys Xray
/// would read differently from this crate's exact-key checks is rejected.
pub(crate) fn reject_ambiguous_keys(value: &Value) -> Result<(), CompileError> {
    match value {
        Value::Object(object) => {
            let mut seen = std::collections::BTreeSet::new();
            for (key, child) in object {
                let folded: String = key
                    .chars()
                    .flat_map(char::to_lowercase)
                    .map(|c| if c == '\u{17F}' { 's' } else { c })
                    .collect();
                let miscased = CHECKED_KEYS
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case(key) && name != key);
                if (!key.is_ascii() && folded.is_ascii()) || miscased || !seen.insert(folded) {
                    return Err(CompileError::InvalidOutbound);
                }
                reject_ambiguous_keys(child)?;
            }
        }
        Value::Array(items) => items.iter().try_for_each(reject_ambiguous_keys)?,
        _ => {}
    }
    Ok(())
}

/// VLESS reverse lets the server open connections into this device; a client
/// never needs it, so provider settings cannot enable it.
pub(crate) fn strip_vless_reverse(outbound: &mut Value) {
    if outbound["protocol"] != "vless" {
        return;
    }
    let Some(settings) = outbound.get_mut("settings").and_then(Value::as_object_mut) else {
        return;
    };
    settings.remove("reverse");
    for server in settings
        .get_mut("vnext")
        .and_then(Value::as_array_mut)
        .into_iter()
        .flatten()
    {
        for user in server
            .get_mut("users")
            .and_then(Value::as_array_mut)
            .into_iter()
            .flatten()
        {
            if let Some(user) = user.as_object_mut() {
                user.remove("reverse");
            }
        }
    }
}

fn has_vless_flow(outbound: &Value) -> bool {
    let flow = |value: &Value| value["flow"].as_str().is_some_and(|flow| !flow.is_empty());
    let settings = &outbound["settings"];
    flow(settings)
        || settings["vnext"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|server| server["users"].as_array().into_iter().flatten().any(flow))
}

pub(crate) fn apply_outbound_runtime(
    proxy_outbound: &mut Value,
    runtime: &RuntimeOptions,
    fragment_tag: &str,
) -> Result<Option<Value>, CompileError> {
    fn range(value: &str, min: u16, max: u16) -> bool {
        if value.len() > 11 {
            return false;
        }
        let parts: Vec<_> = value.split('-').collect();
        if parts.is_empty()
            || parts.len() > 2
            || parts
                .iter()
                .any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
        {
            return false;
        }
        match (
            parts[0].parse::<u16>(),
            parts[parts.len() - 1].parse::<u16>(),
        ) {
            (Ok(low), Ok(high)) => low >= min && low <= high && high <= max,
            _ => false,
        }
    }
    if (runtime.fragment_packets != "tlshello" && !range(&runtime.fragment_packets, 1, 65535))
        || !range(&runtime.fragment_length, 1, 65535)
        || !range(&runtime.fragment_interval, 0, 1000)
    {
        return Err(CompileError::InvalidFragmentation);
    }
    let fragment_outbound = if runtime.fragmentation_enabled {
        if proxy_outbound["protocol"] != "vless"
            || proxy_outbound
                .pointer("/proxySettings/tag")
                .and_then(Value::as_str)
                .is_some_and(|tag| !tag.is_empty())
        {
            return Err(CompileError::UnsupportedFragmentation);
        }
        let mut paths = vec!["/streamSettings".to_owned()];
        if let Some((_, path)) =
            crate::profile::download_settings(&proxy_outbound["streamSettings"], "/streamSettings")
        {
            paths.push(path);
        }
        let penetrate =
            proxy_outbound.pointer("/streamSettings/sockopt/penetrate") == Some(&Value::Bool(true));
        for path in paths {
            let stream = proxy_outbound
                .pointer_mut(&path)
                .and_then(Value::as_object_mut)
                .ok_or(CompileError::UnsupportedFragmentation)?;
            let network = stream
                .get("method")
                .filter(|value| !value.is_null())
                .or_else(|| stream.get("network"))
                .and_then(Value::as_str)
                .unwrap_or("tcp")
                .to_ascii_lowercase();
            let security = stream
                .get("security")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let xhttp = matches!(network.as_str(), "xhttp" | "splithttp");
            if (!matches!(network.as_str(), "tcp" | "raw") && !xhttp)
                || !matches!(security.as_str(), "tls" | "reality")
                || (xhttp
                    && security == "tls"
                    && stream.get("tlsSettings").and_then(|tls| tls.get("alpn"))
                        == Some(&json!(["h3"])))
            {
                return Err(CompileError::UnsupportedFragmentation);
            }
            // XHTTP can use a separate download connection; penetrate makes it
            // inherit the upload socket options instead.
            if penetrate && path != "/streamSettings" {
                continue;
            }
            let socket = stream.entry("sockopt").or_insert_with(|| json!({}));
            if socket.is_null() {
                *socket = json!({});
            }
            let socket = socket
                .as_object_mut()
                .ok_or(CompileError::UnsupportedFragmentation)?;
            if socket
                .get("dialerProxy")
                .is_some_and(|value| !value.is_null() && value != "")
            {
                return Err(CompileError::UnsupportedFragmentation);
            }
            socket.insert("dialerProxy".to_owned(), json!(fragment_tag));
        }
        Some(json!({
            "tag": fragment_tag, "protocol": "freedom",
            "settings": {
                "domainStrategy": target_strategy(runtime.preferred_ip),
                "fragment": {"packets": runtime.fragment_packets, "length": runtime.fragment_length, "interval": runtime.fragment_interval}
            }
        }))
    } else {
        None
    };
    if proxy_outbound["protocol"] == "vless" && proxy_outbound.get("mux").is_none_or(Value::is_null)
    {
        // Vision servers break mux connections that carry TCP.
        let enabled = runtime.mux_enabled && !has_vless_flow(proxy_outbound);
        proxy_outbound["mux"] = json!({"enabled": enabled});
    }
    Ok(fragment_outbound)
}

/// Xray answers only A and AAAA itself. Other lookups go to the first resolver with an
/// address, along the route of Xray's own queries: the forward loopback re-enters as its
/// DNS tag. HTTPS records stay empty because their address hints bypass FakeDNS. An empty
/// network keeps each query's own, so a TCP retry of a truncated answer is not truncated again.
pub(crate) fn dns_forward_settings(servers: &Value) -> Value {
    let (address, port, network) = servers
        .as_array()
        .into_iter()
        .flatten()
        .find_map(dns_forward_target)
        .unwrap_or_else(|| ("1.1.1.1".to_owned(), 53, ""));
    json!({"address": address, "port": port, "network": network, "rules": [
        {"action": "hijack", "qType": "1,28"},
        {"action": "return", "qType": "64,65"},
        {"action": "direct"}
    ]})
}

// A server's IP address, or the IP host of a DoH or DoQ URL on port 53, where the public
// resolvers that serve those by IP also answer. One that skips fallback serves only its domains.
fn dns_forward_target(server: &Value) -> Option<(String, u16, &'static str)> {
    if server["skipFallback"] == true {
        return None;
    }
    let address = server.as_str().or_else(|| server["address"].as_str())?;
    if let Ok(ip) = address.parse::<IpAddr>() {
        let port = server["port"]
            .as_u64()
            .and_then(|port| u16::try_from(port).ok())
            .filter(|port| *port != 0)
            .unwrap_or(53);
        return Some((ip.to_string(), port, ""));
    }
    let url = url::Url::parse(address).ok()?;
    // Hosts of schemes such as tcp:// stay opaque text in the URL parser.
    let ip = url
        .host_str()?
        .trim_start_matches('[')
        .trim_end_matches(']')
        .parse::<IpAddr>()
        .ok()?;
    if url.scheme().starts_with("tcp") {
        return Some((ip.to_string(), url.port().unwrap_or(53), "tcp"));
    }
    Some((ip.to_string(), 53, ""))
}

pub(crate) fn compile_owned_config(
    mut proxy_outbound: Value,
    routes: &crate::model::RouteModel,
    socks_port: u16,
    packet_backend: PacketBackend,
    tun_mtu: u16,
    runtime: &RuntimeOptions,
) -> Result<Vec<u8>, CompileError> {
    let mut default_dns_routes;
    let routes = if runtime.use_dns_from_json {
        routes
    } else {
        default_dns_routes = routes.clone();
        default_dns_routes.dns_servers = vec!["1.1.1.1".to_owned()];
        default_dns_routes.dns_policy = None;
        default_dns_routes.fake_dns = false;
        &default_dns_routes
    };
    strip_vless_reverse(&mut proxy_outbound);
    let fragment_outbound =
        apply_outbound_runtime(&mut proxy_outbound, runtime, "elarni-fragment")?;
    if !(1280..=9000).contains(&tun_mtu) {
        return Err(CompileError::InvalidTunMtu);
    }
    crate::routing::validate_effective_targets(routes).map_err(|_| CompileError::InvalidRoute)?;
    let mut routing_rules = compile_routes(&routes.rules, routes.fallback_action)?;
    // The DNS client's own rules below match by inbound first and never resolve a name.
    let ip_rules = has_ip_rules(&routing_rules);
    let mut dns_servers = routes
        .dns_servers
        .iter()
        .map(|server| {
            if server.parse::<IpAddr>().is_ok()
                || url::Url::parse(server)
                    .is_ok_and(|url| url.scheme() == "https" && url.host_str().is_some())
            {
                Ok(json!(server))
            } else {
                Err(CompileError::InvalidDns)
            }
        })
        .collect::<Result<Vec<_>, _>>()?;
    if dns_servers.is_empty() || dns_servers.len() > 4 {
        return Err(CompileError::InvalidDns);
    }
    if routes.static_hosts.len() > crate::routing::MAX_DNS_HOSTS {
        return Err(CompileError::InvalidStaticHost);
    }
    let mut static_hosts = routes
        .static_hosts
        .iter()
        .map(|(domain, addresses)| {
            if domain.is_empty()
                || domain.len() > 253
                || !domain.is_ascii()
                || addresses.is_empty()
                || addresses.len() > 4
            {
                return Err(CompileError::InvalidStaticHost);
            }
            let addresses = addresses
                .iter()
                .map(|address| {
                    address
                        .parse::<IpAddr>()
                        .map(|_| address.clone())
                        .map_err(|_| CompileError::InvalidStaticHost)
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok((domain.to_ascii_lowercase(), json!(addresses)))
        })
        .collect::<Result<serde_json::Map<String, Value>, _>>()?;

    let mut dns_bootstrap_outbounds = Vec::new();
    if let Some(policy) = &routes.dns_policy {
        dns_servers.clear();
        for (index, resolver) in [&policy.remote, &policy.domestic].into_iter().enumerate() {
            let url = url::Url::parse(&resolver.address).ok();
            if resolver.address.parse::<IpAddr>().is_err()
                && !url.as_ref().is_some_and(|url| {
                    url.scheme() == "https"
                        && url.host_str().is_some()
                        && url.username().is_empty()
                        && url.password().is_none()
                        && url.fragment().is_none()
                })
            {
                return Err(CompileError::InvalidDns);
            }
            // Without a bootstrap IP the proxy resolves a DoH server's name; any
            // other route would make Xray's DNS resolve that name through itself.
            let named_doh = url.as_ref().is_some_and(|url| {
                url.scheme() == "https" && matches!(url.host(), Some(url::Host::Domain(_)))
            });
            if !resolver.bootstrap_ips.is_empty() || named_doh {
                let host = url
                    .as_ref()
                    .filter(|url| url.scheme() == "https")
                    .and_then(|url| url.host_str())
                    .ok_or(CompileError::InvalidDns)?;
                let port = url
                    .as_ref()
                    .and_then(|url| url.port_or_known_default())
                    .ok_or(CompileError::InvalidDns)?;
                let mut settings = json!({"domainStrategy": "AsIs"});
                if !resolver.bootstrap_ips.is_empty() {
                    if resolver.bootstrap_ips.len() != 1
                        || resolver
                            .bootstrap_ips
                            .iter()
                            .any(|ip| ip.parse::<IpAddr>().is_err())
                    {
                        return Err(CompileError::InvalidDns);
                    }
                    let addresses = json!(resolver.bootstrap_ips);
                    if static_hosts
                        .get(host)
                        .is_some_and(|existing| existing != &addresses)
                    {
                        return Err(CompileError::InvalidDns);
                    }
                    static_hosts.insert(host.to_owned(), addresses);
                    let address = resolver.bootstrap_ips[0]
                        .parse::<IpAddr>()
                        .map_err(|_| CompileError::InvalidDns)?;
                    settings["redirect"] =
                        json!(std::net::SocketAddr::new(address, port).to_string());
                }
                let tag = format!("elarni-dns-bootstrap-{index}");
                dns_bootstrap_outbounds.push(json!({
                    "tag": tag,
                    "protocol": "freedom",
                    "settings": settings,
                    "targetStrategy": "AsIs",
                    "streamSettings": {"sockopt": {"dialerProxy": "elarni-proxy"}}
                }));
                routing_rules.insert(
                    dns_bootstrap_outbounds.len() - 1,
                    json!({
                        "type": "field", "network": "tcp", "port": port,
                        "inboundTag": ["elarni-dns-client"],
                        "domain": [format!("full:{host}")], "outboundTag": tag
                    }),
                );
            }
            let mut server = json!({"address": resolver.address});
            if index == 0 {
                // Xray waits 4 s for a stalled resolver before the next one or an answer.
                server["timeoutMs"] = json!(2000);
                // Like DoH above, the remote resolver's own UDP queries take the proxy whatever
                // the fallback; an HTTP proxy carries no UDP.
                if resolver.address.parse::<IpAddr>().is_ok()
                    && proxy_outbound["protocol"] != "http"
                {
                    routing_rules.insert(
                        0,
                        json!({
                            "type": "field", "network": "tcp,udp", "port": 53,
                            "inboundTag": ["elarni-dns-client"],
                            "ip": [resolver.address], "outboundTag": "elarni-proxy"
                        }),
                    );
                }
            }
            if let Some(domains) = &policy.domestic_domains {
                if domains.len() > crate::routing::MAX_ROUTING_TARGETS
                    || domains.iter().any(|domain| {
                        domain.is_empty()
                            || domain.len() > 512
                            || unreadable_geodata(domain)
                            || invalid_regexp(domain)
                            || domain.chars().any(char::is_whitespace)
                            || domain.parse::<IpAddr>().is_ok()
                            || domain.contains('/')
                    })
                {
                    return Err(CompileError::InvalidDns);
                }
                if index == 1 {
                    server["domains"] = json!(domains);
                    server["skipFallback"] = json!(true);
                }
            }
            dns_servers.push(server);
        }
    }

    if routes.fake_dns {
        dns_servers.insert(0, json!("fakedns"));
    }
    let domain_strategy = match routes.domain_strategy.unwrap_or(RouteDomainStrategy::AsIs) {
        RouteDomainStrategy::AsIs => "AsIs",
        // The explicit fallback always matches, so Xray would never retry with
        // resolved IPs; resolving on demand lets hostnames reach IP rules.
        RouteDomainStrategy::IpIfNonMatch if ip_rules => "IPOnDemand",
        RouteDomainStrategy::IpIfNonMatch => "IPIfNonMatch",
        RouteDomainStrategy::IpOnDemand => "IPOnDemand",
    };
    if !(30..=3_600).contains(&runtime.connection_idle_seconds) {
        return Err(CompileError::InvalidConnectionIdle);
    }
    let sniffing = if routes.fake_dns {
        crate::profile::fake_dns_sniffing()
    } else {
        json!({"enabled": runtime.sniffing_enabled, "destOverride": ["http", "tls", "quic"], "routeOnly": true})
    };

    if runtime.allow_lan && runtime.inbound_auth.is_none() {
        return Err(CompileError::InvalidInbound);
    }
    if runtime.inbound_auth.as_ref().is_some_and(|auth| {
        !(1..=255).contains(&auth.username.len()) || !(1..=255).contains(&auth.password.len())
    }) {
        return Err(CompileError::InvalidInbound);
    }
    let listen = if runtime.allow_lan {
        "0.0.0.0"
    } else {
        "127.0.0.1"
    };
    let mut socks_settings = json!({"auth": "noauth", "udp": true});
    let mut http_settings = json!({});
    if let Some(auth) = &runtime.inbound_auth {
        let accounts = json!([{"user": auth.username, "pass": auth.password}]);
        socks_settings["auth"] = json!("password");
        socks_settings["accounts"] = accounts.clone();
        http_settings["accounts"] = accounts;
    }
    let socks_inbound = json!({
            "tag": "elarni-socks",
            "listen": listen,
            "port": socks_port,
            "protocol": "socks",
            "settings": socks_settings,
            "sniffing": sniffing
    });
    let mut inbounds = vec![socks_inbound];
    if packet_backend == PacketBackend::XrayTun {
        inbounds.insert(
            0,
            json!({
                "tag": "elarni-tun",
                "port": 0,
                "protocol": "tun",
                "settings": {
                    "name": "elarni-tun",
                    "mtu": tun_mtu
                },
                "sniffing": sniffing
            }),
        );
    }
    if runtime.http_inbound_enabled {
        let http_port = runtime
            .http_port
            .or_else(|| socks_port.checked_add(1))
            .filter(|port| *port != 0 && *port != socks_port)
            .ok_or(CompileError::InvalidInbound)?;
        inbounds.push(json!({
            "tag": "elarni-http",
            "listen": listen,
            "port": http_port,
            "protocol": "http",
            "settings": http_settings,
            "sniffing": sniffing
        }));
    }
    let mut outbounds = vec![
        proxy_outbound,
        json!({
            "tag": "elarni-direct",
            "protocol": "freedom",
            "settings": {"domainStrategy": target_strategy(runtime.preferred_ip)},
            "targetStrategy": target_strategy(runtime.preferred_ip)
        }),
        json!({
            "tag": "elarni-block",
            "protocol": "blackhole",
            "settings": {"response": {"type": "none"}}
        }),
    ];
    outbounds.extend(dns_bootstrap_outbounds);
    outbounds.extend(fragment_outbound);
    outbounds.push(json!({
        "tag": "elarni-dns-forward",
        "protocol": "loopback",
        "settings": {"inboundTag": "elarni-dns-client"}
    }));
    outbounds.push(json!({
        "tag": "elarni-dns",
        "protocol": "dns",
        "streamSettings": {"sockopt": {"dialerProxy": "elarni-dns-forward"}},
        "settings": dns_forward_settings(&json!(dns_servers))
    }));
    routing_rules.insert(
        0,
        json!({
            "type": "field",
            "network": "tcp,udp",
            "port": 53,
            "inboundTag": ["elarni-socks", "elarni-http", "elarni-tun"],
            "outboundTag": "elarni-dns"
        }),
    );
    let mut config = json!({
        "log": {
            "access": "none",
            "error": "none",
            "loglevel": "none"
        },
        "dns": {
            "tag": "elarni-dns-client",
            "queryStrategy": query_strategy(runtime.preferred_ip),
            // An expired answer is served while it refreshes; without a bound Xray never
            // cleans its cache.
            "serveStale": true,
            "serveExpiredTTL": 3600,
            "servers": dns_servers,
            "hosts": static_hosts,
            "disableFallbackIfMatch": routes.dns_policy.as_ref()
                .is_some_and(|policy| policy.domestic_domains.is_some()),
            "useSystemHosts": false
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "routing": {
            "domainStrategy": domain_strategy,
            "rules": routing_rules
        },
        "policy": {
            "levels": {
                "0": {"connIdle": runtime.connection_idle_seconds}
            }
        }
    });
    if routes.fake_dns {
        config["fakeDns"] = json!([{"ipPool": "198.18.0.0/15", "poolSize": 65535}]);
    }
    // The tunnel tells a dead server from an idle one by these counters.
    config["stats"] = json!({});
    config["policy"]["system"] = json!({
        "statsInboundUplink": true,
        "statsInboundDownlink": true
    });
    close_with_app(&mut config);
    apply_per_app_routing(&mut config, runtime, "elarni-")?;
    block_tun_own_subnets(&mut config, "elarni-block");
    serde_json::to_vec(&config).map_err(|_| CompileError::InvalidRoute)
}

/// The TUN's own subnets: Android's VpnService (Platform.kt) and the desktop TUN
/// (windows_tun_config.go) hold their resolver there. Nothing else answers in them, so a
/// Private DNS probe on 853 or a subnet broadcast (NetBIOS, Spotify discovery) would
/// leave by a rule for private ranges and hang until its timeout.
const TUN_OWN_SUBNETS: [&str; 3] = [
    "198.51.100.252/30",
    "fdfe:dcba:9876::/126",
    "fd76:6f75:7465::/126",
];

/// Ends TUN traffic to its own subnets, except DNS, ahead of every other rule, the
/// per-app gate included.
pub(crate) fn block_tun_own_subnets(config: &mut Value, block_tag: &str) {
    let Some(tun_tag) = config["inbounds"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|inbound| inbound["protocol"] == "tun")
        .and_then(|inbound| inbound["tag"].as_str())
        .map(str::to_owned)
    else {
        return;
    };
    if let Some(rules) = config["routing"]["rules"].as_array_mut() {
        rules.insert(
            0,
            json!({"type": "field", "inboundTag": [tun_tag], "network": "tcp,udp",
                "ip": TUN_OWN_SUBNETS, "port": "1-52,54-65535", "outboundTag": block_tag}),
        );
    }
}

/// A per-app proxy target: SOCKS5 or HTTP on this device, without credentials.
fn per_app_proxy_outbound(text: &str, config: &Value) -> Result<Value, CompileError> {
    let url = url::Url::parse(text).map_err(|_| CompileError::InvalidRoute)?;
    let protocol = match url.scheme() {
        "socks" | "socks5" => "socks",
        "http" => "http",
        _ => return Err(CompileError::InvalidRoute),
    };
    // socks:// hosts are opaque to the URL parser, so it never reads them as IPs.
    let host = match url.host_str().map(|host| host.trim_matches(['[', ']'])) {
        Some(host) if host.eq_ignore_ascii_case("localhost") => "127.0.0.1".to_owned(),
        Some(host) => host
            .parse::<IpAddr>()
            .ok()
            .filter(IpAddr::is_loopback)
            .ok_or(CompileError::InvalidRoute)?
            .to_string(),
        None => return Err(CompileError::InvalidRoute),
    };
    let port = url
        .port_or_known_default()
        .filter(|port| *port != 0)
        .ok_or(CompileError::InvalidRoute)?;
    if !url.username().is_empty()
        || url.password().is_some()
        || !matches!(url.path(), "" | "/")
        || url.query().is_some()
        || url.fragment().is_some()
        // One of this config's own listeners would loop.
        || config["inbounds"].as_array().into_iter().flatten()
            .any(|inbound| inbound["port"].as_u64() == Some(u64::from(port)))
    {
        return Err(CompileError::InvalidRoute);
    }
    Ok(json!({"protocol": protocol, "settings": {"servers": [{"address": host, "port": port}]}}))
}

/// A per-app server target: a node's outbound, or its profile's first one.
fn per_app_server_outbound(server: &Value) -> Result<Value, CompileError> {
    let mut outbound = match server.get("outbounds") {
        Some(outbounds) => outbounds
            .get(0)
            .cloned()
            .ok_or(CompileError::InvalidOutbound)?,
        None => server.clone(),
    };
    strip_vless_reverse(&mut outbound);
    outbound
        .as_object_mut()
        .ok_or(CompileError::InvalidOutbound)?
        .remove("tag");
    // shortcut: a chained server (dialerProxy) cannot be a per-app target, and the target
    // skips fragmentation and mux settings; copy its dependencies and runtime when users need them.
    if !outbound
        .pointer("/streamSettings/sockopt/dialerProxy")
        .is_none_or(Value::is_null)
    {
        return Err(CompileError::InvalidOutbound);
    }
    normalize_client_outbound(&mut outbound)?;
    Ok(outbound)
}

/// Xray keeps a proxied connection up to `downlinkOnly` (1 s) after the app closes its side, so a burst of short
/// connections holds hundreds of TLS sessions. Close with the app, as the mihomo clients do, unless the profile sets
/// its own value. The cost: an app that half-closes and then waits for the reply loses it.
pub(crate) fn close_with_app(config: &mut Value) {
    let Some(policy) = config
        .as_object_mut()
        .map(|root| root.entry("policy").or_insert_with(|| json!({})))
    else {
        return;
    };
    let Some(levels) = policy
        .as_object_mut()
        .map(|policy| policy.entry("levels").or_insert_with(|| json!({})))
    else {
        return;
    };
    if let Some(level) = levels
        .as_object_mut()
        .map(|levels| levels.entry("0").or_insert_with(|| json!({})))
        .and_then(Value::as_object_mut)
    {
        level.entry("downlinkOnly").or_insert(json!(0));
    }
}

/// `prefix` names this config's own direct and block outbounds.
pub(crate) fn apply_per_app_routing(
    config: &mut Value,
    runtime: &RuntimeOptions,
    prefix: &str,
) -> Result<(), CompileError> {
    use crate::model::PerAppMode;
    if runtime.per_app_processes.len() > 256
        || runtime.per_app_processes.iter().any(|name| {
            name.is_empty()
                || name.len() > 1024
                || name.trim() != name
                || name.chars().any(char::is_control)
        })
    {
        return Err(CompileError::InvalidRoute);
    }
    let mut targeted = BTreeSet::new();
    for item in &runtime.per_app_targets {
        let payload = match item.target.as_str() {
            "direct" | "routing" | "block" => item.server.is_none() && item.proxy.is_none(),
            "server" => item.server.is_some() && item.proxy.is_none(),
            "proxy" => item.server.is_none() && item.proxy.is_some(),
            _ => false,
        };
        if !payload
            || !runtime.per_app_processes.contains(&item.process)
            || !targeted.insert(item.process.as_str())
        {
            return Err(CompileError::InvalidRoute);
        }
    }
    if runtime.per_app_mode == PerAppMode::Off {
        return Ok(());
    }
    let tun_tag = config["inbounds"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|inbound| inbound["protocol"] == "tun")
        .and_then(|inbound| inbound["tag"].as_str())
        .ok_or(CompileError::InvalidInbound)?
        .to_owned();
    if runtime.per_app_processes.is_empty() {
        return Err(CompileError::InvalidRoute);
    }
    // Re-enter the existing policy after matching the originating process. This
    // retains provider balancers, app overrides, DNS capture and local listeners.
    let serialized = config.to_string();
    let reentry = (0..)
        .map(|index| format!("elarni-apps-{index}"))
        .find(|tag| !serialized.contains(&format!("\"{tag}\"")))
        .unwrap();
    let rules = config["routing"]["rules"]
        .as_array_mut()
        .ok_or(CompileError::InvalidRoute)?;
    for rule in rules.iter_mut() {
        if let Some(tags) = rule["inboundTag"].as_array_mut() {
            for tag in tags {
                if *tag == tun_tag {
                    *tag = json!(reentry);
                }
            }
        }
    }
    let direct_tag = format!("{prefix}direct");
    let block_tag = format!("{prefix}block");
    let (selected, remaining) = match runtime.per_app_mode {
        PerAppMode::Bypass => (direct_tag.as_str(), reentry.as_str()),
        PerAppMode::ProxyOnly => (reentry.as_str(), direct_tag.as_str()),
        PerAppMode::Off => unreachable!(),
    };
    // Apps with the same target share one rule, in the order they were listed.
    let mut extra = Vec::new();
    let mut groups: Vec<(String, Vec<&str>)> = Vec::new();
    for item in &runtime.per_app_targets {
        let tag = match item.target.as_str() {
            "direct" => direct_tag.clone(),
            "routing" => reentry.clone(),
            "block" => block_tag.clone(),
            kind => {
                let mut outbound = match kind {
                    "server" => per_app_server_outbound(item.server.as_ref().unwrap())?,
                    _ => per_app_proxy_outbound(item.proxy.as_ref().unwrap(), config)?,
                };
                let found = extra
                    .iter()
                    .find(|(_, existing): &&(String, Value)| *existing == outbound);
                match found {
                    Some((tag, _)) => tag.clone(),
                    None => {
                        let tag = (0..)
                            .map(|index| format!("{prefix}app-{index}"))
                            .find(|tag| {
                                !serialized.contains(&format!("\"{tag}\""))
                                    && extra.iter().all(|(used, _)| used != tag)
                            })
                            .unwrap();
                        outbound["tag"] = json!(tag);
                        extra.push((tag.clone(), outbound));
                        tag
                    }
                }
            }
        };
        match groups.iter_mut().find(|(existing, _)| *existing == tag) {
            Some((_, processes)) => processes.push(&item.process),
            None => groups.push((tag, vec![&item.process])),
        }
    }
    let mut others: Vec<&str> = runtime
        .per_app_processes
        .iter()
        .map(String::as_str)
        .filter(|name| !targeted.contains(name))
        .collect();
    // "-1" names the owner of a flow the lookup could not find, on every platform; a listed
    // app's flow must not leave the tunnel for that. Listing "-1" gives it a target instead.
    if runtime.per_app_mode == PerAppMode::ProxyOnly
        && !runtime.per_app_processes.iter().any(|name| name == "-1")
    {
        others.push("-1");
    }
    if !others.is_empty() {
        groups.push((selected.to_owned(), others));
    }
    let outbounds = config["outbounds"]
        .as_array()
        .ok_or(CompileError::InvalidOutbound)?;
    if groups.iter().any(|(tag, _)| *tag == block_tag)
        && outbounds
            .iter()
            .all(|outbound| outbound["tag"] != block_tag.as_str())
    {
        return Err(CompileError::InvalidOutbound);
    }
    let mut gate = vec![
        json!({"type":"field", "inboundTag":[tun_tag], "network":"tcp,udp",
        "port":53, "outboundTag":reentry}),
    ];
    gate.extend(groups.iter().map(|(tag, processes)| {
        json!({"type":"field", "inboundTag":[tun_tag],
        "network":"tcp,udp", "process":processes, "outboundTag":tag})
    }));
    gate.push(
        json!({"type":"field", "inboundTag":[tun_tag], "network":"tcp,udp",
        "outboundTag":remaining}),
    );
    config["routing"]["rules"]
        .as_array_mut()
        .ok_or(CompileError::InvalidRoute)?
        .splice(0..0, gate);
    let outbounds = config["outbounds"]
        .as_array_mut()
        .ok_or(CompileError::InvalidOutbound)?;
    outbounds.extend(extra.into_iter().map(|(_, outbound)| outbound));
    outbounds
        .push(json!({"tag":reentry, "protocol":"loopback", "settings":{"inboundTag":reentry}}));
    Ok(())
}

pub(crate) fn validate_routing_model(
    routes: &crate::model::RouteModel,
) -> Result<(), CompileError> {
    // Compile with a blocking outbound: routing validation needs no endpoint or credentials.
    compile_owned_config(
        json!({"protocol": "blackhole", "settings": {}}),
        routes,
        1080,
        PacketBackend::NativeTun2Proxy,
        1500,
        &crate::model::RuntimeOptions::default(),
    )
    .map(|_| ())
}

/// Xray reads a rule's `ip` as a list or as one comma-separated string.
pub(crate) fn has_ip_rules(rules: &[Value]) -> bool {
    rules.iter().any(|rule| {
        rule.get("ip").is_some_and(|ips| {
            ips.as_array().is_some_and(|ips| !ips.is_empty())
                || ips.as_str().is_some_and(|ips| !ips.is_empty())
        })
    })
}

/// Apps resolve through Xray's DNS; IPv6 answers would take them past an IPv4 preference.
fn query_strategy(preferred_ip: PreferredIp) -> &'static str {
    match preferred_ip {
        PreferredIp::Ipv4 => "UseIPv4",
        PreferredIp::Ipv6 | PreferredIp::Automatic => "UseIP",
    }
}

fn target_strategy(preferred_ip: PreferredIp) -> &'static str {
    match preferred_ip {
        PreferredIp::Ipv4 => "ForceIPv4",
        PreferredIp::Ipv6 => "ForceIPv6",
        PreferredIp::Automatic => "AsIs",
    }
}

// Xray refuses to load a geodata reference without its file, code or an attribute after '@',
// and a dotless rule with a dot (common/geodata/rule_parser.go); a negation may stand on either side.
fn unreadable_geodata(target: &str) -> bool {
    let target = target.trim_start_matches('!');
    if let Some(substring) = target.strip_prefix("dotless:") {
        return substring.contains('.');
    }
    let code = if let Some(code) = target
        .strip_prefix("geoip:")
        .or_else(|| target.strip_prefix("geosite:"))
    {
        code
    } else if let Some(reference) = ["ext:", "ext-ip:", "ext-domain:", "ext-site:"]
        .iter()
        .find_map(|prefix| target.strip_prefix(prefix))
    {
        match reference.split_once(':') {
            Some((file, code)) if !file.is_empty() => code,
            _ => return true,
        }
    } else {
        return false;
    };
    let code = code.trim_start_matches('!');
    code.is_empty() || code.starts_with('@') || code.ends_with('@') || code.contains("@@")
}

// Xray compiles a `regexp:` rule with Go's regexp package and refuses the whole config on an error.
// This follows Go's regexp/syntax parser (Perl flags).
// shortcut: `\p{Name}` accepts any name; a Unicode table list would catch unknown names.
pub(crate) fn invalid_regexp(target: &str) -> bool {
    let Some(pattern) = target.strip_prefix("regexp:") else {
        return false;
    };
    go_regexp_valid(&pattern.chars().collect::<Vec<_>>()).is_none()
}

#[derive(Clone, Copy, PartialEq)]
enum Last {
    Nothing,
    Operand,
    Repeat,
    Lazy,
}

// Some(()) when Go compiles the pattern.
fn go_regexp_valid(chars: &[char]) -> Option<()> {
    let (mut depth, mut last, mut i) = (0usize, Last::Nothing, 0usize);
    while i < chars.len() {
        match chars[i] {
            '\\' if chars.get(i + 1) == Some(&'Q') => {
                // \Q...\E, or \Q to the end, is literal text.
                let rest = &chars[i + 2..];
                let end = (0..rest.len())
                    .find(|&k| rest[k] == '\\' && rest.get(k + 1) == Some(&'E'))
                    .unwrap_or(rest.len());
                if end > 0 {
                    last = Last::Operand;
                }
                i += 2 + end + if end < rest.len() { 2 } else { 0 };
                continue;
            }
            '\\' => {
                i = escape(chars, i + 1, false)?.0;
                last = Last::Operand;
                continue;
            }
            '[' => {
                i = class(chars, i + 1)?;
                last = Last::Operand;
                continue;
            }
            '(' if chars.get(i + 1) == Some(&'?') => {
                let (next, group) = group_flags(chars, i + 2)?;
                depth += usize::from(group);
                last = Last::Nothing;
                i = next;
                continue;
            }
            '(' => {
                depth += 1;
                last = Last::Nothing;
            }
            ')' => {
                depth = depth.checked_sub(1)?;
                last = Last::Operand;
            }
            '|' => last = Last::Nothing,
            '*' | '+' | '?' => last = repeat(last, chars[i] == '?')?,
            '{' => match counted(chars, i + 1).ok()? {
                Some(next) => {
                    last = repeat(last, false)?;
                    i = next;
                    continue;
                }
                None => last = Last::Operand,
            },
            _ => last = Last::Operand,
        }
        i += 1;
    }
    (depth == 0).then_some(())
}

fn repeat(last: Last, question: bool) -> Option<Last> {
    match last {
        Last::Operand => Some(Last::Repeat),
        Last::Repeat if question => Some(Last::Lazy),
        _ => None,
    }
}

// After "{": the index past {n}, {n,} or {n,m}; None when it isn't a repeat (a literal '{'
// then); an error for counts Go refuses (over 1000, or max below min).
fn counted(chars: &[char], mut i: usize) -> Result<Option<usize>, ()> {
    let number = |i: &mut usize| {
        let start = *i;
        while chars.get(*i).is_some_and(char::is_ascii_digit) {
            *i += 1;
        }
        (*i > start).then(|| {
            chars[start..*i]
                .iter()
                .collect::<String>()
                .parse::<u32>()
                .unwrap_or(u32::MAX)
        })
    };
    let Some(min) = number(&mut i) else {
        return Ok(None);
    };
    let max = if chars.get(i) == Some(&',') {
        i += 1;
        if chars.get(i) == Some(&'}') {
            None
        } else {
            let Some(max) = number(&mut i) else {
                return Ok(None);
            };
            Some(max)
        }
    } else {
        Some(min)
    };
    if chars.get(i) != Some(&'}') {
        return Ok(None);
    }
    if min > 1000 || max.is_some_and(|max| max > 1000 || max < min) {
        return Err(());
    }
    Ok(Some(i + 1))
}

// After "(?": flags, "P<name>" or "<name>". The index past the header and whether it opens a group.
fn group_flags(chars: &[char], mut i: usize) -> Option<(usize, bool)> {
    let named = match chars.get(i) {
        Some('P') if chars.get(i + 1) == Some(&'<') => Some(i + 2),
        Some('<') => Some(i + 1),
        _ => None,
    };
    if let Some(start) = named {
        let end = start + chars[start..].iter().position(|&c| c == '>')?;
        let name = &chars[start..end];
        return (!name.is_empty() && name.iter().all(|&c| c == '_' || c.is_ascii_alphanumeric()))
            .then_some((end + 1, true));
    }
    let (mut negated, mut flag_since_sign) = (false, false);
    loop {
        match *chars.get(i)? {
            'i' | 'm' | 's' | 'U' => flag_since_sign = true,
            '-' if !negated => (negated, flag_since_sign) = (true, false),
            c @ (':' | ')') if !negated || flag_since_sign => return Some((i + 1, c == ':')),
            _ => return None,
        }
        i += 1;
    }
}

// After "[": the index past the closing ']'.
fn class(chars: &[char], mut i: usize) -> Option<usize> {
    if chars.get(i) == Some(&'^') {
        i += 1;
    }
    let mut first = true;
    loop {
        let c = *chars.get(i)?;
        if c == ']' && !first {
            return Some(i + 1);
        }
        first = false;
        // [:alpha:] ends at the next ":]"; without one the '[' is a literal.
        if c == '['
            && chars.get(i + 1) == Some(&':')
            && let Some(end) = (i + 2..chars.len().saturating_sub(1))
                .find(|&k| chars[k] == ':' && chars[k + 1] == ']')
        {
            let name: String = chars[i + 2..end].iter().collect();
            const POSIX: [&str; 14] = [
                "alnum", "alpha", "ascii", "blank", "cntrl", "digit", "graph", "lower", "print",
                "punct", "space", "upper", "word", "xdigit",
            ];
            if !POSIX.contains(&name.strip_prefix('^').unwrap_or(&name)) {
                return None;
            }
            i = end + 2;
            continue;
        }
        if c == '\\' && chars.get(i + 1).is_some_and(|c| "dDsSwWpP".contains(*c)) {
            i = escape(chars, i + 1, true)?.0;
            continue;
        }
        let (next, low) = class_char(chars, i)?;
        i = next;
        if chars.get(i) == Some(&'-') && chars.get(i + 1).is_some_and(|&c| c != ']') {
            let (next, high) = class_char(chars, i + 1)?;
            if high < low {
                return None;
            }
            i = next;
        }
    }
}

fn class_char(chars: &[char], i: usize) -> Option<(usize, u32)> {
    match *chars.get(i)? {
        '\\' => {
            let (next, value) = escape(chars, i + 1, true)?;
            Some((next, value?))
        }
        c => Some((i + 1, c as u32)),
    }
}

// After "\": the index past the escape and the character it stands for (None for a class or an
// assertion). Inside a class only character escapes and \d \s \w \p are allowed.
fn escape(chars: &[char], i: usize, in_class: bool) -> Option<(usize, Option<u32>)> {
    let c = *chars.get(i)?;
    let hex = |s: &[char]| u32::from_str_radix(&s.iter().collect::<String>(), 16).ok();
    match c {
        'A' | 'z' | 'b' | 'B' if !in_class => Some((i + 1, None)),
        'd' | 'D' | 's' | 'S' | 'w' | 'W' => Some((i + 1, None)),
        'p' | 'P' => match chars.get(i + 1)? {
            '{' => {
                let end = i + 2 + chars[i + 2..].iter().position(|&c| c == '}')?;
                let name = &chars[i + 2..end];
                let name = name.strip_prefix(&['^']).unwrap_or(name);
                (!name.is_empty()).then_some((end + 1, None))
            }
            _ => Some((i + 2, None)),
        },
        '1'..='7' if !chars.get(i + 1).is_some_and(|c| ('0'..='7').contains(c)) => None,
        '0'..='7' => {
            let mut end = i + 1;
            while end < i + 3 && chars.get(end).is_some_and(|c| ('0'..='7').contains(c)) {
                end += 1;
            }
            Some((
                end,
                u32::from_str_radix(&chars[i..end].iter().collect::<String>(), 8).ok(),
            ))
        }
        'x' if chars.get(i + 1) == Some(&'{') => {
            let end = i + 2 + chars[i + 2..].iter().position(|&c| c == '}')?;
            let digits = &chars[i + 2..end];
            let value = (!digits.is_empty() && digits.iter().all(char::is_ascii_hexdigit))
                .then(|| hex(digits))
                .flatten()
                .filter(|&v| v <= 0x10FFFF)?;
            Some((end + 1, Some(value)))
        }
        'x' => {
            let digits = chars.get(i + 1..i + 3)?;
            digits
                .iter()
                .all(char::is_ascii_hexdigit)
                .then(|| (i + 3, hex(digits)))
        }
        'a' => Some((i + 1, Some(7))),
        'f' => Some((i + 1, Some(12))),
        'n' => Some((i + 1, Some(10))),
        'r' => Some((i + 1, Some(13))),
        't' => Some((i + 1, Some(9))),
        'v' => Some((i + 1, Some(11))),
        c if c.is_ascii() && !c.is_ascii_alphanumeric() => Some((i + 1, Some(c as u32))),
        _ => None,
    }
}

pub(crate) fn valid_ip_target(target: &str) -> bool {
    // Xray accepts negated IP rules and external geodata references.
    let target = target.trim_start_matches('!');
    if ["geoip:", "ext:", "ext-ip:"]
        .iter()
        .any(|prefix| target.starts_with(prefix))
    {
        return true;
    }
    let (address, prefix) = target
        .split_once('/')
        .map_or((target, None), |(ip, prefix)| (ip, Some(prefix)));
    let Ok(address) = address.parse::<IpAddr>() else {
        return false;
    };
    // Xray reads IPv4-mapped IPv6 addresses as IPv4.
    let ipv4 = match address {
        IpAddr::V4(_) => true,
        IpAddr::V6(address) => address.to_ipv4_mapped().is_some(),
    };
    // Rust's parse also accepts a leading '+', which Xray rejects.
    prefix.is_none_or(|prefix| {
        prefix.bytes().all(|b| b.is_ascii_digit())
            && prefix
                .parse::<u8>()
                .is_ok_and(|prefix| prefix <= if ipv4 { 32 } else { 128 })
    })
}

pub(crate) fn compile_routes(
    rules: &[RouteRule],
    fallback_action: Option<RouteAction>,
) -> Result<Vec<Value>, CompileError> {
    if rules.len() > 128 {
        return Err(CompileError::InvalidRoute);
    }
    let mut target_count = 0usize;
    let mut result = Vec::with_capacity(rules.len() + 1);
    for rule in rules {
        if rule.domains.is_empty() && rule.ips.is_empty() {
            return Err(CompileError::InvalidRoute);
        }
        target_count = target_count
            .checked_add(rule.domains.len() + rule.ips.len())
            .ok_or(CompileError::InvalidRoute)?;
        if target_count > crate::routing::MAX_ROUTING_TARGETS {
            return Err(CompileError::InvalidRoute);
        }
        let mut claimed = BTreeSet::new();
        for target in rule.domains.iter().chain(&rule.ips) {
            if target.is_empty()
                || target.len() > 512
                || unreadable_geodata(target)
                || invalid_regexp(target)
                || !claimed.insert(target.clone())
            {
                return Err(CompileError::InvalidRoute);
            }
        }
        if !rule.ips.iter().all(|target| valid_ip_target(target)) {
            return Err(CompileError::InvalidRoute);
        }
        let outbound = match rule.action {
            RouteAction::Proxy => "elarni-proxy",
            RouteAction::Direct => "elarni-direct",
            RouteAction::Block => "elarni-block",
        };
        // Action lists are alternatives; Xray ANDs fields within a single rule.
        if !rule.domains.is_empty() {
            let domains: Vec<_> = rule
                .domains
                .iter()
                .map(|domain| {
                    // Happ suffix lists use domain:.ru; Xray expects domain:ru.
                    domain
                        .strip_prefix("domain:.")
                        .map_or_else(|| domain.clone(), |suffix| format!("domain:{suffix}"))
                })
                .collect();
            result.push(json!({"type": "field", "outboundTag": outbound, "domain": domains}));
        }
        if !rule.ips.is_empty() {
            result.push(json!({"type": "field", "outboundTag": outbound, "ip": rule.ips}));
        }
    }
    let fallback = match fallback_action.unwrap_or(RouteAction::Block) {
        RouteAction::Proxy => "elarni-proxy",
        RouteAction::Direct => "elarni-direct",
        RouteAction::Block => "elarni-block",
    };
    result.push(json!({
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": fallback
    }));
    Ok(result)
}
