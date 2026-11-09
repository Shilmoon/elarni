//! Provider configurations retain their routing graph; Elarni owns local resources.
use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::compiler::{
    CompileError, apply_outbound_runtime, compile_owned_config, compile_routes, has_ip_rules,
    is_client_protocol, normalize_legacy_reality_names,
};
use crate::model::{PacketBackend, PreferredIp, ProfileDnsMode, RouteModel, RuntimeOptions};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileEndpoint {
    pub host: String,
    pub port: u16,
    pub address_path: String,
    pub stream_path: Option<String>,
    pub endpoint_string: bool,
    pub physical: bool,
    pub supports_tcp_probe: bool,
    pub addresses: Vec<String>,
    pub domain_strategy: String,
}

pub struct CompiledProfile {
    pub config: Vec<u8>,
    pub endpoints: Vec<ProfileEndpoint>,
}

// Xray's "localhost" server asks the system resolver, and its "+local" schemes dial outside
// routing, over sockets the platform keeps outside the tunnel: lookups would reach the ISP.
fn without_system_resolver(dns: &Value) -> Value {
    let mut dns = dns.clone();
    if let Some(servers) = dns.get_mut("servers").and_then(Value::as_array_mut) {
        servers.retain(|server| {
            !server
                .as_str()
                .or_else(|| server["address"].as_str())
                .is_some_and(|address| {
                    address.eq_ignore_ascii_case("localhost")
                        || address.split_once(':').is_some_and(|(scheme, _)| {
                            scheme.to_ascii_lowercase().ends_with("+local")
                        })
                })
        });
    }
    dns
}

pub fn compile_profile(
    mut profile: Value,
    routes: Option<&RouteModel>,
    socks_port: u16,
    backend: PacketBackend,
    mtu: u16,
    runtime: &RuntimeOptions,
    preferred_ip: Option<PreferredIp>,
) -> Result<CompiledProfile, CompileError> {
    crate::compiler::reject_ambiguous_keys(&profile)?;
    let groups = apply_group_selections(&mut profile)?;
    let root = profile
        .as_object_mut()
        .ok_or(CompileError::InvalidOutbound)?;
    if root.get("transport").is_some_and(|value| {
        !value.is_null() && value.as_object().is_none_or(|object| !object.is_empty())
    }) {
        return Err(CompileError::InvalidOutbound);
    }
    // These sections are supplied by the app, never activated from a subscription.
    // Reverse would let the provider open connections into this device.
    for field in ["log", "api", "env", "transport", "metrics", "reverse"] {
        root.remove(field);
    }
    const SUPPORTED: &[&str] = &[
        "remarks",
        "name",
        "inbounds",
        "outbounds",
        "dns",
        "routing",
        "observatory",
        "burstObservatory",
        "policy",
        "stats",
        "fakeDns",
        "fakedns",
    ];
    if root.keys().any(|key| !SUPPORTED.contains(&key.as_str())) {
        return Err(CompileError::InvalidOutbound);
    }
    normalize_legacy_reality_names(&mut profile)?;
    migrate_removed_keys(&mut profile)?;
    let mut outbounds = profile["outbounds"]
        .as_array()
        .cloned()
        .filter(|items| !items.is_empty() && items.len() <= 1024)
        .ok_or(CompileError::InvalidOutbound)?;
    let reserved_tags: BTreeSet<String> = outbounds
        .iter()
        .filter_map(|outbound| outbound["tag"].as_str().map(str::to_owned))
        .collect();
    let mut tags = BTreeSet::new();
    for (index, outbound) in outbounds.iter_mut().enumerate() {
        crate::compiler::strip_vless_reverse(outbound);
        let object = outbound
            .as_object_mut()
            .ok_or(CompileError::InvalidOutbound)?;
        let protocol = object
            .get("protocol")
            .and_then(Value::as_str)
            .ok_or(CompileError::InvalidOutbound)?;
        if !is_client_protocol(protocol)
            && !matches!(protocol, "freedom" | "blackhole" | "dns" | "loopback")
        {
            return Err(CompileError::InvalidOutbound);
        }
        if object
            .get("tag")
            .is_none_or(|value| value.is_null() || value == "")
        {
            let mut tag = format!("provider-{index}");
            while reserved_tags.contains(&tag) || tags.contains(&tag) {
                tag.push('-');
            }
            object.insert("tag".into(), json!(tag));
        }
        let tag = object["tag"]
            .as_str()
            .filter(|tag| !tag.is_empty() && tag.len() <= 256 && !tag.chars().any(char::is_control))
            .ok_or(CompileError::InvalidOutbound)?;
        if !tags.insert(tag.to_owned()) {
            return Err(CompileError::InvalidOutbound);
        }
    }
    validate_dependencies(&outbounds, &tags)?;
    let first_tag = outbounds[0]["tag"].clone();
    let prefix = (0..)
        .map(|index| {
            if index == 0 {
                "elarni-".to_owned()
            } else {
                format!("elarni{index}-")
            }
        })
        .find(|prefix| tags.iter().all(|tag| !tag.starts_with(prefix)))
        .unwrap();
    let mut outbound_runtime = runtime.clone();
    outbound_runtime.preferred_ip = preferred_ip.unwrap_or(PreferredIp::Automatic);
    let mut fragments = Vec::new();
    if runtime.fragmentation_enabled || runtime.mux_enabled {
        let mut unfragmented = outbound_runtime.clone();
        unfragmented.fragmentation_enabled = false;
        let mut first = true;
        for (index, outbound) in outbounds.iter_mut().enumerate() {
            if !outbound["protocol"]
                .as_str()
                .is_some_and(is_client_protocol)
            {
                continue;
            }
            // With select groups the user's choices carry traffic; otherwise the first outbound does.
            let primary = if groups.is_empty() {
                first
            } else {
                outbound["tag"]
                    .as_str()
                    .is_some_and(|tag| groups.contains(tag))
            };
            first = false;
            let tag = format!("{prefix}fragment-{index}");
            // A failed attempt may have changed part of the outbound.
            let mut candidate = outbound.clone();
            match apply_outbound_runtime(&mut candidate, &outbound_runtime, &tag) {
                Ok(fragment) => {
                    *outbound = candidate;
                    fragments.extend(fragment);
                }
                // Backups that cannot carry fragments still connect without them.
                Err(CompileError::UnsupportedFragmentation) if !primary => {
                    apply_outbound_runtime(outbound, &unfragmented, &tag)?;
                }
                Err(error) => return Err(error),
            }
        }
    }
    let proxy_tag = format!("{prefix}proxy");
    let reentry_tag = format!("{prefix}provider");
    let defaults: RouteModel =
        serde_json::from_value(json!({"rules": [], "dnsServers": ["1.1.1.1"]}))
            .map_err(|_| CompileError::InvalidRoute)?;
    // No provider outbound is passed to this builder: standalone defaults must
    // not overwrite its mux, target strategy, DNS or default route.
    let mut owned_runtime = runtime.clone();
    // Apply the process gate only after the provider graph and app overlay merge.
    owned_runtime.per_app_mode = crate::model::PerAppMode::Off;
    owned_runtime.fragmentation_enabled = false;
    owned_runtime.preferred_ip = preferred_ip.unwrap_or(PreferredIp::Automatic);
    if runtime.profile_dns_mode == ProfileDnsMode::Default {
        owned_runtime.use_dns_from_json = false;
    }
    let provider_dns = profile
        .get("dns")
        .filter(|value| !value.is_null())
        .map(without_system_resolver);
    let provider_dns = provider_dns.as_ref();
    let inherit_mode =
        runtime.profile_dns_mode == ProfileDnsMode::Inherit && runtime.use_dns_from_json;
    // An enabled routing profile's DNS outranks the provider's, as in Happ.
    let routing_dns = inherit_mode && routes.is_some_and(|routes| routes.dns_policy.is_some());
    let inherit_dns_settings = inherit_mode && !routing_dns;
    // With no server left, Xray falls back to the system resolver too.
    let inherit_dns = inherit_dns_settings
        && provider_dns.is_some_and(|dns| {
            dns["servers"]
                .as_array()
                .is_some_and(|servers| !servers.is_empty())
        });
    let bytes = compile_owned_config(
        json!({"tag": "elarni-proxy", "protocol": "blackhole", "settings": {}}),
        if inherit_dns {
            &defaults
        } else {
            routes.unwrap_or(&defaults)
        },
        socks_port,
        backend,
        mtu,
        &owned_runtime,
    )?;
    let mut owned: Value =
        serde_json::from_slice(&bytes).map_err(|_| CompileError::InvalidOutbound)?;
    let ingress: Vec<Value> = owned["inbounds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["tag"].clone())
        .collect();
    let mut provider_ingress = ingress.clone();
    provider_ingress.push(json!(reentry_tag));
    let old_ingress: BTreeSet<String> = profile["inbounds"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| item["tag"].as_str().map(str::to_owned))
        .collect();

    let mut routing = profile
        .get("routing")
        .filter(|value| !value.is_null())
        .cloned()
        .unwrap_or_else(|| json!({}));
    let routing_object = routing.as_object_mut().ok_or(CompileError::InvalidRoute)?;
    // Routing policy is independent of the provider DNS inheritance mode.
    if let Some(strategy) = routes.and_then(|routes| routes.domain_strategy) {
        routing_object.insert("domainStrategy".into(), json!(strategy));
    }
    let mut balancer_tags = BTreeSet::new();
    if let Some(balancers) = routing_object
        .get("balancers")
        .filter(|value| !value.is_null())
    {
        for balancer in balancers.as_array().ok_or(CompileError::InvalidRoute)? {
            let tag = balancer["tag"]
                .as_str()
                .filter(|tag| !tag.is_empty())
                .ok_or(CompileError::InvalidRoute)?;
            if !balancer_tags.insert(tag.to_owned()) {
                return Err(CompileError::InvalidRoute);
            }
            if let Some(fallback) = balancer
                .get("fallbackTag")
                .filter(|value| !value.is_null() && *value != "")
                && !fallback.as_str().is_some_and(|tag| tags.contains(tag))
            {
                return Err(CompileError::InvalidRoute);
            }
        }
    }
    let mut provider_rules = match routing_object.remove("rules") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(rules)) => rules,
        _ => return Err(CompileError::InvalidRoute),
    };
    for rule in &mut provider_rules {
        let rule = rule.as_object_mut().ok_or(CompileError::InvalidRoute)?;
        // A webhook makes the core POST to any URL or local socket. Xray matches keys
        // case-insensitively and also folds U+212A (Kelvin sign) to k.
        rule.retain(|key, _| {
            !key.chars()
                .flat_map(char::to_lowercase)
                .eq("webhook".chars())
        });
        let outbound = rule
            .get("outboundTag")
            .and_then(Value::as_str)
            .filter(|tag| !tag.is_empty());
        let balancer = rule
            .get("balancerTag")
            .and_then(Value::as_str)
            .filter(|tag| !tag.is_empty());
        if !matches!((outbound, balancer), (Some(tag), None) if tags.contains(tag))
            && !matches!((outbound, balancer), (None, Some(tag)) if balancer_tags.contains(tag))
        {
            return Err(CompileError::InvalidRoute);
        }
        if let Some(inbound_tags) = rule.get("inboundTag") {
            let inbound_tags = inbound_tags.as_array().ok_or(CompileError::InvalidRoute)?;
            let listener = |tag: &Value| tag.as_str().is_some_and(|tag| old_ingress.contains(tag));
            if inbound_tags.iter().any(listener) {
                // Elarni's listeners replace the provider's as a whole: a rule for
                // every provider listener covers all Elarni traffic, while one for
                // only some of them has no Elarni counterpart.
                let every = old_ingress.iter().all(|old| {
                    inbound_tags
                        .iter()
                        .any(|tag| tag.as_str() == Some(old.as_str()))
                });
                let mut mapped: Vec<Value> = inbound_tags
                    .iter()
                    .filter(|tag| !listener(tag))
                    .cloned()
                    .collect();
                if every {
                    mapped.extend(provider_ingress.clone());
                }
                if mapped.is_empty() {
                    // Removed below; an empty inboundTag would match every inbound.
                    rule.clear();
                    continue;
                }
                rule.insert("inboundTag".into(), json!(mapped));
            }
        }
    }
    provider_rules.retain(|rule| rule != &json!({}));
    // Expand selectors against provider members before app helper outbounds are added.
    if let Some(balancers) = routing_object.get_mut("balancers") {
        for balancer in balancers.as_array_mut().ok_or(CompileError::InvalidRoute)? {
            let selectors = balancer["selector"]
                .as_array()
                .ok_or(CompileError::InvalidRoute)?;
            let members: Vec<&String> = tags
                .iter()
                .filter(|tag| {
                    selectors.iter().any(|selector| {
                        selector
                            .as_str()
                            .is_some_and(|selector| selector_matches(tag, selector))
                    })
                })
                .collect();
            if members.is_empty() {
                return Err(CompileError::InvalidRoute);
            }
            balancer["selector"] = json!(
                members
                    .into_iter()
                    .map(|tag| format!("elarni-exact:{tag}"))
                    .collect::<Vec<_>>()
            );
        }
    }
    let mut rules = Vec::new();
    // Keep DNS interception and explicit bootstrap routing from the owned configuration.
    for rule in owned["routing"]["rules"].as_array().unwrap() {
        if rule["outboundTag"] == "elarni-dns"
            || rule["outboundTag"]
                .as_str()
                .is_some_and(|tag| tag.starts_with("elarni-dns-bootstrap-"))
        {
            let mut rule = rule.clone();
            rename_owned_refs(&mut rule, &prefix);
            rules.push(rule);
        }
    }
    if let Some(routes) = routes {
        let mut overlay = compile_routes(&routes.rules, routes.fallback_action)?;
        if routes.fallback_action.is_none() {
            overlay.pop();
        }
        for rule in &mut overlay {
            rule["inboundTag"] = json!(ingress);
            rename_owned_refs(rule, &prefix);
        }
        rules.extend(overlay);
    }
    rules.extend(provider_rules);
    // An explicit rule preserves Xray's original first-outbound fallback even
    // after generated helpers are appended, including after loopback re-entry.
    rules.push(json!({"type": "field", "network": "tcp,udp", "outboundTag": first_tag}));
    // That rule always matches, so Xray's IPIfNonMatch retry with resolved IPs
    // never runs; resolving on demand lets hostnames reach IP rules.
    if has_ip_rules(&rules)
        && routing_object
            .get("domainStrategy")
            .and_then(Value::as_str)
            .is_some_and(|strategy| strategy.eq_ignore_ascii_case("IPIfNonMatch"))
    {
        routing_object.insert("domainStrategy".into(), json!("IPOnDemand"));
    }
    routing_object.insert("rules".into(), json!(rules));

    for helper in owned["outbounds"].as_array().unwrap().iter().skip(1) {
        let mut helper = helper.clone();
        rename_owned_refs(&mut helper, &prefix);
        outbounds.push(helper);
    }
    outbounds.extend(fragments);
    outbounds.push(
        json!({"tag": proxy_tag, "protocol": "loopback", "settings": {"inboundTag": reentry_tag}}),
    );
    owned["outbounds"] = json!(outbounds);
    owned["routing"] = routing;
    if inherit_dns && let Some(dns) = provider_dns {
        if !dns.is_object() {
            return Err(CompileError::InvalidDns);
        }
        owned["dns"] = dns.clone();
        // Lookups other than A and AAAA follow the inherited resolvers too.
        let (forwarder, forward) = (format!("{prefix}dns"), format!("{prefix}dns-forward"));
        for outbound in owned["outbounds"].as_array_mut().unwrap() {
            if outbound["tag"] == forwarder.as_str() {
                outbound["settings"] = crate::compiler::dns_forward_settings(&dns["servers"]);
            } else if outbound["tag"] == forward.as_str() {
                outbound["settings"]["inboundTag"] = dns
                    .get("tag")
                    .filter(|tag| tag.is_string())
                    .cloned()
                    .unwrap_or(json!(""));
            }
        }
    } else if let Some(dns) = provider_dns {
        // Provider hosts may be the only address of its own servers, whichever DNS
        // replaces the provider's; the app's and routing profile's hosts still win.
        let hosts = dns
            .as_object()
            .ok_or(CompileError::InvalidDns)?
            .get("hosts");
        if let Some(hosts) = hosts.filter(|hosts| !hosts.is_null()) {
            if !owned["dns"]["hosts"].is_object() {
                owned["dns"]["hosts"] = json!({});
            }
            let owned_hosts = owned["dns"]["hosts"].as_object_mut().unwrap();
            for (name, address) in hosts.as_object().ok_or(CompileError::InvalidDns)? {
                owned_hosts
                    .entry(name.clone())
                    .or_insert_with(|| address.clone());
            }
        }
    }
    for section in [
        "observatory",
        "burstObservatory",
        "policy",
        "stats",
        "fakeDns",
        "fakedns",
    ] {
        if matches!(section, "fakeDns" | "fakedns") && !inherit_dns_settings {
            continue;
        }
        if let Some(value) = profile.get(section).filter(|value| !value.is_null()) {
            if !matches!(section, "fakeDns" | "fakedns") && !value.is_object() {
                return Err(CompileError::InvalidOutbound);
            }
            if section == "policy" {
                // The tunnel's inbound counters win; the provider's other system stats stay.
                let system = owned["policy"].get("system").cloned();
                owned[section] = value.clone();
                if let Some(Value::Object(system)) = system {
                    if !owned[section]["system"].is_object() {
                        owned[section]["system"] = json!({});
                    }
                    for (key, flag) in system {
                        owned[section]["system"][key] = flag;
                    }
                }
                // Elarni's listeners use level 0; the user's idle timeout outlives the copy.
                if !owned[section]["levels"].is_object() {
                    owned[section]["levels"] = json!({});
                }
                if !owned[section]["levels"]["0"].is_object() {
                    owned[section]["levels"]["0"] = json!({});
                }
                owned[section]["levels"]["0"]["connIdle"] = json!(runtime.connection_idle_seconds);
            } else {
                // One spelling only: Xray folds both to the same field and keeps the last.
                let target = if section == "fakedns" {
                    "fakeDns"
                } else {
                    section
                };
                owned[target] = value.clone();
            }
        }
    }
    for section in ["observatory", "burstObservatory"] {
        if let Some(selectors) = owned[section].get("subjectSelector") {
            let selectors = selectors.as_array().ok_or(CompileError::InvalidRoute)?;
            let members: Vec<&String> = tags
                .iter()
                .filter(|tag| {
                    selectors.iter().any(|selector| {
                        selector
                            .as_str()
                            .is_some_and(|selector| selector_matches(tag, selector))
                    })
                })
                .collect();
            owned[section]["subjectSelector"] = json!(
                members
                    .into_iter()
                    .map(|tag| format!("elarni-exact:{tag}"))
                    .collect::<Vec<_>>()
            );
        }
    }
    // Xray picks FakeDNS by name as Go's EqualFold matches it, so "FakeDNS" counts too.
    let fake_dns = |name: Option<&str>| {
        name.is_some_and(|name| {
            name.chars()
                .flat_map(char::to_lowercase)
                .map(|c| if c == '\u{17F}' { 's' } else { c })
                .eq("fakedns".chars())
        })
    };
    if owned["dns"]["servers"].as_array().is_some_and(|servers| {
        servers
            .iter()
            .any(|server| fake_dns(server.as_str()) || fake_dns(server["address"].as_str()))
    }) {
        for inbound in owned["inbounds"].as_array_mut().unwrap() {
            inbound["sniffing"] = fake_dns_sniffing();
        }
    }
    crate::compiler::close_with_app(&mut owned);
    crate::compiler::apply_per_app_routing(&mut owned, runtime, &prefix)?;
    let endpoints = profile_endpoints(&owned)?;
    Ok(CompiledProfile {
        config: serde_json::to_vec(&owned).map_err(|_| CompileError::InvalidOutbound)?,
        endpoints,
    })
}

// Domestic and AAAA answers stay real IPs, so domain rules need the other
// sniffers too. Xray overrides fake IPs fully even with routeOnly.
pub(crate) fn fake_dns_sniffing() -> Value {
    json!({"enabled": true, "destOverride": ["fakedns", "http", "tls", "quic"], "routeOnly": true})
}

// Clash select groups remain user choices. Resolve aliases against an immutable
// copy so choosing a nested group cannot overwrite another group's source.
// Returns the group tags, which now hold the selected members.
fn apply_group_selections(profile: &mut Value) -> Result<BTreeSet<String>, CompileError> {
    let Some(groups) = profile
        .as_object_mut()
        .ok_or(CompileError::InvalidOutbound)?
        .remove("elarniGroups")
    else {
        return Ok(BTreeSet::new());
    };
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Group {
        name: String,
        #[serde(rename = "type")]
        kind: String,
        options: Vec<String>,
        selected: String,
    }
    let groups: Vec<Group> =
        serde_json::from_value(groups).map_err(|_| CompileError::InvalidOutbound)?;
    if groups.len() > 1024 {
        return Err(CompileError::InvalidOutbound);
    }
    let outbounds = profile["outbounds"]
        .as_array_mut()
        .ok_or(CompileError::InvalidOutbound)?;
    let mut originals = BTreeMap::new();
    for outbound in outbounds.iter() {
        let tag = outbound["tag"]
            .as_str()
            .ok_or(CompileError::InvalidOutbound)?;
        if originals.insert(tag.to_owned(), outbound.clone()).is_some() {
            return Err(CompileError::InvalidOutbound);
        }
    }
    let mut choices = BTreeMap::new();
    let mut options = BTreeMap::new();
    for group in groups {
        if group.kind != "select"
            || group.options.is_empty()
            || group.options.len() > 1024
            || !group.options.contains(&group.selected)
            || !originals.contains_key(&group.name)
            || group.options.iter().any(|tag| !originals.contains_key(tag))
            || choices.insert(group.name.clone(), group.selected).is_some()
        {
            return Err(CompileError::InvalidOutbound);
        }
        options.insert(group.name, group.options);
    }
    fn visit<'a>(
        name: &'a str,
        groups: &'a BTreeMap<String, Vec<String>>,
        stack: &mut BTreeSet<&'a str>,
        done: &mut BTreeSet<&'a str>,
    ) -> Result<(), CompileError> {
        if done.contains(name) {
            return Ok(());
        }
        if !stack.insert(name) {
            return Err(CompileError::InvalidOutbound);
        }
        if let Some(options) = groups.get(name) {
            for next in options {
                if groups.contains_key(next) {
                    visit(next, groups, stack, done)?;
                }
            }
        }
        stack.remove(name);
        done.insert(name);
        Ok(())
    }
    let mut done = BTreeSet::new();
    for name in choices.keys() {
        visit(name, &options, &mut BTreeSet::new(), &mut done)?;
    }
    for outbound in outbounds {
        let tag = outbound["tag"].as_str().unwrap().to_owned();
        if choices.contains_key(&tag) {
            let mut target = tag.as_str();
            while let Some(next) = choices.get(target) {
                target = next;
            }
            *outbound = originals[target].clone();
            outbound["tag"] = json!(tag);
        }
    }
    Ok(choices.into_keys().collect())
}

fn selector_matches(tag: &str, selector: &str) -> bool {
    selector
        .strip_prefix("elarni-exact:")
        .map_or_else(|| tag.starts_with(selector), |exact| tag == exact)
}

fn rename_owned_refs(value: &mut Value, prefix: &str) {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                if matches!(key.as_str(), "tag" | "outboundTag" | "dialerProxy")
                    && let Some(tag) = child.as_str().and_then(|tag| tag.strip_prefix("elarni-"))
                {
                    *child = json!(format!("{prefix}{tag}"));
                } else {
                    rename_owned_refs(child, prefix);
                }
            }
        }
        Value::Array(values) => values
            .iter_mut()
            .for_each(|value| rename_owned_refs(value, prefix)),
        _ => {}
    }
}

// Xray 26.10.29 removed outbound proxySettings for sockopt.dialerProxy, which dials the same
// chain. A plain (not transport-layer) proxy never carried a WireGuard bind socket, so it goes.
fn migrate_removed_keys(config: &mut Value) -> Result<(), CompileError> {
    let outbounds = config.get_mut("outbounds").and_then(Value::as_array_mut);
    for object in outbounds
        .into_iter()
        .flatten()
        .filter_map(Value::as_object_mut)
    {
        if object.get("protocol").and_then(Value::as_str) == Some("hysteria") {
            migrate_udp_hop(object);
        }
        let Some(proxy) = object.remove("proxySettings") else {
            continue;
        };
        let Some(tag) = nonempty_tag(proxy.get("tag")) else {
            continue;
        };
        if matches!(
            object.get("protocol").and_then(Value::as_str),
            Some("wireguard" | "amneziawg")
        ) && proxy["transportLayer"] != true
        {
            continue;
        }
        let mut socket = object
            .entry("streamSettings")
            .or_insert(Value::Null)
            .take()
            .as_object()
            .cloned()
            .unwrap_or_default();
        let mut sockopt = socket
            .remove("sockopt")
            .and_then(|value| value.as_object().cloned())
            .unwrap_or_default();
        if nonempty_tag(sockopt.get("dialerProxy")).is_some() {
            return Err(CompileError::InvalidOutbound);
        }
        sockopt.insert("dialerProxy".into(), json!(tag));
        socket.insert("sockopt".into(), Value::Object(sockopt));
        object.insert("streamSettings".into(), Value::Object(socket));
    }
    Ok(())
}

// The same release dropped quicParams.udpHop without an error. Its udphop mask hops the same
// ports from a new local socket each time. It dials, and Xray applies masks last to first.
fn migrate_udp_hop(outbound: &mut serde_json::Map<String, Value>) {
    let Some(mask) = outbound
        .get_mut("streamSettings")
        .and_then(|stream| stream.get_mut("finalmask"))
        .and_then(Value::as_object_mut)
    else {
        return;
    };
    let Some(hop) = mask
        .get_mut("quicParams")
        .and_then(Value::as_object_mut)
        .and_then(|quic| quic.remove("udpHop"))
    else {
        return;
    };
    if mask["quicParams"]
        .as_object()
        .is_some_and(serde_json::Map::is_empty)
    {
        mask.remove("quicParams");
    }
    let ports = hop
        .get("ports")
        .filter(|ports| !ports.is_null() && *ports != "" && *ports != 0);
    let udp = mask.get("udp").and_then(Value::as_array);
    let has_hop = udp.into_iter().flatten().any(|item| {
        item["type"]
            .as_str()
            .is_some_and(|kind| kind.eq_ignore_ascii_case("udphop"))
    });
    let Some(ports) = ports.filter(|_| !has_hop && (udp.is_some() || mask.get("udp").is_none()))
    else {
        return;
    };
    let mut settings = serde_json::Map::new();
    settings.insert("mode".into(), json!("intervalLocal,intervalRemote"));
    if let Some(interval) = hop.get("interval").filter(|value| !value.is_null()) {
        settings.insert("interval".into(), interval.clone());
    }
    settings.insert("remotePorts".into(), ports.clone());
    let udp = mask.entry("udp").or_insert_with(|| json!([]));
    udp.as_array_mut()
        .unwrap()
        .push(json!({"type": "udphop", "settings": settings}));
}

fn validate_dependencies(outbounds: &[Value], tags: &BTreeSet<String>) -> Result<(), CompileError> {
    let mut edges = BTreeMap::new();
    for outbound in outbounds {
        let dependencies = outbound_dependencies(outbound);
        if dependencies.iter().any(|tag| !tags.contains(*tag)) {
            return Err(CompileError::InvalidOutbound);
        }
        edges.insert(outbound["tag"].as_str().unwrap(), dependencies);
    }
    fn visit<'a>(
        tag: &'a str,
        edges: &BTreeMap<&'a str, Vec<&'a str>>,
        active: &mut BTreeSet<&'a str>,
        done: &mut BTreeSet<&'a str>,
    ) -> Result<(), CompileError> {
        if done.contains(tag) {
            return Ok(());
        }
        if !active.insert(tag) {
            return Err(CompileError::InvalidOutbound);
        }
        if let Some(next) = edges.get(tag) {
            for tag in next {
                visit(tag, edges, active, done)?;
            }
        }
        active.remove(tag);
        done.insert(tag);
        Ok(())
    }
    let mut done = BTreeSet::new();
    for origin in edges.keys() {
        visit(origin, &edges, &mut BTreeSet::new(), &mut done)?;
    }
    Ok(())
}

fn nonempty_tag(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str).filter(|tag| !tag.is_empty())
}

fn outbound_dependencies(outbound: &Value) -> Vec<&str> {
    let mut result = Vec::new();
    if let Some(tag) = nonempty_tag(outbound.pointer("/streamSettings/sockopt/dialerProxy")) {
        result.push(tag);
    }
    if outbound.pointer("/streamSettings/sockopt/penetrate") != Some(&Value::Bool(true))
        && let Some((download, _)) = download_settings(&outbound["streamSettings"], "")
        && let Some(tag) = nonempty_tag(download.pointer("/sockopt/dialerProxy"))
    {
        result.push(tag);
    }
    result
}

fn is_physical_dependency(
    tag: Option<&str>,
    outbounds: &[Value],
    visited: &mut BTreeSet<String>,
) -> bool {
    let Some(tag) = tag else {
        return true;
    };
    if !visited.insert(tag.to_owned()) {
        return false;
    }
    let Some(outbound) = outbounds.iter().find(|outbound| outbound["tag"] == tag) else {
        return false;
    };
    outbound["protocol"] == "freedom"
        && outbound
            .pointer("/settings/redirect")
            .is_none_or(|redirect| {
                redirect.is_null()
                    || redirect == ""
                    || redirect
                        .as_str()
                        .is_some_and(|value| value.starts_with(':'))
            })
        && outbound_dependencies(outbound)
            .into_iter()
            .all(|tag| is_physical_dependency(Some(tag), outbounds, visited))
}

pub fn profile_endpoints(config: &Value) -> Result<Vec<ProfileEndpoint>, CompileError> {
    let mut migrated = config.clone();
    migrate_removed_keys(&mut migrated)?;
    let config = &migrated;
    let mut endpoints = Vec::new();
    let outbounds = config["outbounds"]
        .as_array()
        .ok_or(CompileError::InvalidOutbound)?;
    for (index, outbound) in outbounds.iter().enumerate() {
        let redirect = outbound
            .pointer("/settings/redirect")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty());
        let freedom_redirect = outbound["protocol"] == "freedom" && redirect.is_some();
        if !outbound["protocol"]
            .as_str()
            .is_some_and(is_client_protocol)
            && !freedom_redirect
        {
            continue;
        }
        let dependency = nonempty_tag(outbound.pointer("/streamSettings/sockopt/dialerProxy"));
        let physical = is_physical_dependency(dependency, outbounds, &mut BTreeSet::new());
        let base = format!("/outbounds/{index}");
        let stream_path = outbound
            .get("streamSettings")
            .filter(|value| value.is_object())
            .map(|_| format!("{base}/streamSettings"));
        let settings = &outbound["settings"];
        if freedom_redirect {
            let redirect = redirect.unwrap();
            if redirect.starts_with(':') {
                continue;
            }
            let url = url::Url::parse(&format!("tcp://{redirect}"))
                .map_err(|_| CompileError::InvalidOutbound)?;
            if !url.username().is_empty()
                || url.password().is_some()
                || !url.path().is_empty()
                || url.query().is_some()
                || url.fragment().is_some()
            {
                return Err(CompileError::InvalidOutbound);
            }
            let host = url
                .host_str()
                .ok_or(CompileError::InvalidOutbound)?
                .trim_matches(['[', ']'])
                .to_owned();
            let port = url.port().ok_or(CompileError::InvalidOutbound)?;
            endpoints.push(ProfileEndpoint {
                host,
                port,
                address_path: format!("{base}/settings/redirect"),
                stream_path: stream_path.clone(),
                endpoint_string: true,
                physical,
                supports_tcp_probe: false,
                addresses: Vec::new(),
                domain_strategy: String::new(),
            });
        } else if matches!(
            outbound["protocol"].as_str(),
            Some("wireguard" | "amneziawg")
        ) {
            for (peer_index, peer) in settings["peers"]
                .as_array()
                .ok_or(CompileError::InvalidOutbound)?
                .iter()
                .enumerate()
            {
                let endpoint = peer["endpoint"]
                    .as_str()
                    .ok_or(CompileError::InvalidOutbound)?;
                let url = url::Url::parse(&format!("udp://{endpoint}"))
                    .map_err(|_| CompileError::InvalidOutbound)?;
                if !url.username().is_empty()
                    || url.password().is_some()
                    || !url.path().is_empty()
                    || url.query().is_some()
                    || url.fragment().is_some()
                {
                    return Err(CompileError::InvalidOutbound);
                }
                let host = url
                    .host_str()
                    .ok_or(CompileError::InvalidOutbound)?
                    .trim_matches(['[', ']'])
                    .to_owned();
                let port = url
                    .port()
                    .filter(|port| *port != 0)
                    .ok_or(CompileError::InvalidOutbound)?;
                endpoints.push(ProfileEndpoint {
                    host,
                    port,
                    address_path: format!("{base}/settings/peers/{peer_index}/endpoint"),
                    stream_path: None,
                    endpoint_string: true,
                    physical,
                    supports_tcp_probe: false,
                    addresses: Vec::new(),
                    domain_strategy: String::new(),
                });
            }
        } else {
            let server_path = if settings.get("address").is_some_and(Value::is_string) {
                format!("{base}/settings")
            } else {
                let field = if settings.get("vnext").is_some() {
                    "vnext"
                } else {
                    "servers"
                };
                if settings[field]
                    .as_array()
                    .is_none_or(|servers| servers.len() != 1)
                {
                    return Err(CompileError::InvalidOutbound);
                }
                format!("{base}/settings/{field}/0")
            };
            let server = config
                .pointer(&server_path)
                .ok_or(CompileError::InvalidOutbound)?;
            append_endpoint(
                &mut endpoints,
                server,
                server_path,
                stream_path.clone(),
                physical,
            )?;
        }
        if let Some(stream_path) = stream_path
            && let Some((download, path)) =
                download_settings(&outbound["streamSettings"], &stream_path)
        {
            if download_settings(download, "").is_some() {
                return Err(CompileError::InvalidOutbound);
            }
            let dependency = if outbound.pointer("/streamSettings/sockopt/penetrate")
                == Some(&Value::Bool(true))
            {
                dependency
            } else {
                nonempty_tag(download.pointer("/sockopt/dialerProxy"))
            };
            let physical = is_physical_dependency(dependency, outbounds, &mut BTreeSet::new());
            append_endpoint(&mut endpoints, download, path.clone(), Some(path), physical)?;
        }
    }
    // First matching key wins, as in a linear search; built once for all endpoints.
    let mut hosts = BTreeMap::new();
    for (key, value) in config["dns"]["hosts"].as_object().into_iter().flatten() {
        hosts
            .entry(
                key.strip_prefix("full:")
                    .unwrap_or(key)
                    .to_ascii_lowercase(),
            )
            .or_insert(value);
    }
    for endpoint in &mut endpoints {
        endpoint.addresses = bootstrap_addresses(&hosts, &endpoint.host, &mut BTreeSet::new());
        let index = endpoint
            .address_path
            .split('/')
            .nth(2)
            .and_then(|value| value.parse::<usize>().ok())
            .ok_or(CompileError::InvalidOutbound)?;
        let outbound = &outbounds[index];
        let stream = endpoint
            .stream_path
            .as_ref()
            .and_then(|path| config.pointer(path));
        let network = stream
            .and_then(|value| {
                value
                    .get("method")
                    .filter(|method| !method.is_null())
                    .or_else(|| value.get("network"))
            })
            .and_then(Value::as_str)
            .unwrap_or("raw")
            .to_ascii_lowercase();
        endpoint.supports_tcp_probe = !matches!(
            outbound["protocol"].as_str(),
            Some("hysteria" | "tuic" | "wireguard" | "amneziawg")
        ) && matches!(
            network.as_str(),
            "raw" | "tcp" | "ws" | "websocket" | "httpupgrade" | "grpc" | "xhttp" | "splithttp"
        ) && !(matches!(network.as_str(), "xhttp" | "splithttp")
            && stream.is_some_and(|value| {
                value["security"] == "tls" && value["tlsSettings"]["alpn"] == json!(["h3"])
            }));
        // Penetrate makes an XHTTP download dial like the main stream; WireGuard peers dial none.
        let stream = if endpoint.stream_path.is_some()
            && outbound.pointer("/streamSettings/sockopt/penetrate") == Some(&Value::Bool(true))
        {
            outbound.get("streamSettings")
        } else {
            stream
        };
        endpoint.domain_strategy = endpoint_strategy(outbound, stream)
            .unwrap_or("AsIs")
            .to_owned();
        // A WireGuard peer has no stream path; its bind socket dials with the outbound's sockopt.
        let mut dependency = stream
            .or_else(|| outbound.get("streamSettings"))
            .and_then(|value| nonempty_tag(value.pointer("/sockopt/dialerProxy")));
        let mut seen = BTreeSet::new();
        while endpoint.domain_strategy.eq_ignore_ascii_case("AsIs") {
            let Some(tag) = dependency else {
                break;
            };
            if !seen.insert(tag) {
                break;
            }
            let Some(helper) = outbounds
                .iter()
                .find(|item| item["tag"] == tag && item["protocol"] == "freedom")
            else {
                break;
            };
            endpoint.domain_strategy = endpoint_strategy(helper, helper.get("streamSettings"))
                .unwrap_or("AsIs")
                .to_owned();
            dependency = nonempty_tag(helper.pointer("/streamSettings/sockopt/dialerProxy"));
        }
    }
    Ok(endpoints)
}

fn endpoint_strategy<'a>(outbound: &'a Value, stream: Option<&'a Value>) -> Option<&'a str> {
    let socket_strategy =
        stream.and_then(|value| nonempty_tag(value.pointer("/sockopt/domainStrategy")));
    if matches!(
        outbound["protocol"].as_str(),
        Some("wireguard" | "amneziawg" | "freedom")
    ) {
        // Xray's freedom reads targetStrategy first; WireGuard has only domainStrategy.
        nonempty_tag(outbound.pointer("/settings/targetStrategy"))
            .filter(|_| outbound["protocol"] == "freedom")
            .or_else(|| nonempty_tag(outbound.pointer("/settings/domainStrategy")))
            .or(socket_strategy)
    } else {
        socket_strategy
    }
}

/// Hints kept per endpoint; each endpoint carries its own copy.
const MAX_BOOTSTRAP_ADDRESSES: usize = 64;

fn bootstrap_addresses(
    hosts: &BTreeMap<String, &Value>,
    host: &str,
    seen: &mut BTreeSet<String>,
) -> Vec<String> {
    if let Ok(address) = host.parse::<std::net::IpAddr>() {
        return vec![address.to_string()];
    }
    let host = host.to_ascii_lowercase();
    if !seen.insert(host.clone()) || seen.len() > 64 {
        return Vec::new();
    }
    let Some(value) = hosts.get(&host) else {
        return Vec::new();
    };
    let values: Vec<&str> = match value {
        Value::String(value) => vec![value],
        Value::Array(values) => values.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    };
    let mut addresses = BTreeSet::new();
    for value in values {
        addresses.extend(bootstrap_addresses(hosts, value, seen));
        if addresses.len() >= MAX_BOOTSTRAP_ADDRESSES {
            break;
        }
    }
    addresses
        .into_iter()
        .take(MAX_BOOTSTRAP_ADDRESSES)
        .collect()
}

pub fn pin_config(
    config: Value,
    resolved: &BTreeMap<String, String>,
) -> Result<Value, CompileError> {
    pin_selected_config(config, resolved, None)
}

fn pin_selected_config(
    mut config: Value,
    resolved: &BTreeMap<String, String>,
    only: Option<&BTreeSet<String>>,
) -> Result<Value, CompileError> {
    migrate_removed_keys(&mut config)?;
    for endpoint in profile_endpoints(&config)?
        .into_iter()
        .filter(|endpoint| endpoint.physical)
    {
        let protocol = endpoint
            .address_path
            .split('/')
            .nth(2)
            .and_then(|index| config.pointer(&format!("/outbounds/{index}/protocol")))
            .and_then(Value::as_str);
        // WG resolves its outer peer during device startup, and a dial strategy
        // resolves through Xray's DNS, which the tunnel may route through this
        // same server. Reuse the physical lookup so neither becomes a bootstrap
        // dependency.
        if only.is_some_and(|hosts| !hosts.contains(&endpoint.host))
            && !matches!(protocol, Some("wireguard" | "amneziawg"))
            && endpoint.domain_strategy.eq_ignore_ascii_case("AsIs")
        {
            continue;
        }
        let address = resolved
            .get(&endpoint.address_path)
            .or_else(|| resolved.get(&endpoint.host))
            .map(String::as_str)
            .unwrap_or(&endpoint.host)
            .parse::<std::net::IpAddr>()
            .map_err(|_| CompileError::InvalidOutbound)?;
        if let Some(path) = &endpoint.stream_path {
            let stream = config
                .pointer_mut(path)
                .and_then(Value::as_object_mut)
                .ok_or(CompileError::InvalidOutbound)?;
            let security = stream
                .get("security")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let peer_key = match security.as_str() {
                "tls" => Some("tlsSettings"),
                "reality" => Some("realitySettings"),
                _ => None,
            };
            let mut http_host = endpoint.host.clone();
            if let Some(peer_key) = peer_key {
                let peer = stream
                    .entry(peer_key)
                    .or_insert_with(|| json!({}))
                    .as_object_mut()
                    .ok_or(CompileError::InvalidOutbound)?;
                if peer
                    .get("serverName")
                    .is_none_or(|value| value.is_null() || value == "")
                {
                    peer.insert("serverName".into(), json!(endpoint.host));
                }
                http_host = peer["serverName"]
                    .as_str()
                    .ok_or(CompileError::InvalidOutbound)?
                    .to_owned();
            }
            let network = stream
                .get("method")
                .filter(|value| !value.is_null())
                .or_else(|| stream.get("network"))
                .and_then(Value::as_str)
                .unwrap_or("raw")
                .to_ascii_lowercase();
            let transport = match network.as_str() {
                "ws" | "websocket" => Some(("wsSettings", "host")),
                "httpupgrade" => Some(("httpupgradeSettings", "host")),
                "xhttp" | "splithttp" => Some((
                    if stream.contains_key("xhttpSettings") {
                        "xhttpSettings"
                    } else {
                        "splithttpSettings"
                    },
                    "host",
                )),
                "grpc" | "gun" => Some(("grpcSettings", "authority")),
                _ => None,
            };
            if let Some((transport, field)) = transport {
                let settings = stream
                    .entry(transport)
                    .or_insert_with(|| json!({}))
                    .as_object_mut()
                    .ok_or(CompileError::InvalidOutbound)?;
                // Xray drops a legacy WebSocket headers.Host once host is set.
                let legacy_host = transport == "wsSettings"
                    && settings
                        .get("headers")
                        .and_then(Value::as_object)
                        .is_some_and(|headers| {
                            headers.iter().any(|(key, value)| {
                                key.eq_ignore_ascii_case("host")
                                    && value.as_str().is_some_and(|host| !host.is_empty())
                            })
                        });
                // Xray folds key case, so a provider's Host or Authority counts as set.
                if !legacy_host
                    && settings
                        .iter()
                        .filter(|(key, _)| key.eq_ignore_ascii_case(field))
                        .all(|(_, value)| value.is_null() || value == "")
                {
                    settings.insert(field.into(), json!(http_host));
                }
            }
        }
        let value = config
            .pointer_mut(&endpoint.address_path)
            .ok_or(CompileError::InvalidOutbound)?;
        *value = if endpoint.endpoint_string {
            json!(std::net::SocketAddr::new(address, endpoint.port).to_string())
        } else {
            json!(address.to_string())
        };
    }
    Ok(config)
}

// Unresolvable physical hops cannot safely be left to resolve after the tunnel
// captures DNS. Keep their tags as closed routes and remove them from pools.
pub fn prepare_config(
    mut config: Value,
    resolved: &BTreeMap<String, String>,
    unavailable: &BTreeSet<String>,
    pin: bool,
    pin_hosts: &BTreeSet<String>,
) -> Result<Value, CompileError> {
    migrate_removed_keys(&mut config)?;
    let endpoints = profile_endpoints(&config)?;
    let mut failed = BTreeSet::new();
    for endpoint in endpoints.iter().filter(|endpoint| {
        endpoint.physical
            && (unavailable.contains(&endpoint.host)
                || unavailable.contains(&endpoint.address_path))
    }) {
        let index = endpoint
            .address_path
            .split('/')
            .nth(2)
            .and_then(|value| value.parse::<usize>().ok())
            .ok_or(CompileError::InvalidOutbound)?;
        failed.insert(
            config["outbounds"][index]["tag"]
                .as_str()
                .ok_or(CompileError::InvalidOutbound)?
                .to_owned(),
        );
    }
    let outbounds = config["outbounds"]
        .as_array_mut()
        .ok_or(CompileError::InvalidOutbound)?;
    loop {
        let old_count = failed.len();
        for outbound in outbounds.iter() {
            if outbound_dependencies(outbound)
                .iter()
                .any(|tag| failed.contains(*tag))
            {
                failed.insert(
                    outbound["tag"]
                        .as_str()
                        .ok_or(CompileError::InvalidOutbound)?
                        .to_owned(),
                );
            }
        }
        if failed.len() == old_count {
            break;
        }
    }
    for outbound in outbounds.iter_mut() {
        if outbound["tag"]
            .as_str()
            .is_some_and(|tag| failed.contains(tag))
        {
            *outbound = json!({"tag": outbound["tag"], "protocol": "blackhole", "settings": {}});
        }
    }
    if !failed.is_empty() {
        let mut empty_pools = BTreeMap::new();
        if let Some(balancers) = config["routing"]
            .get_mut("balancers")
            .and_then(Value::as_array_mut)
        {
            for balancer in balancers.iter_mut() {
                let selectors = balancer["selector"]
                    .as_array_mut()
                    .ok_or(CompileError::InvalidRoute)?;
                let removed = selectors
                    .iter()
                    .filter_map(Value::as_str)
                    .find_map(|selector| failed.iter().find(|tag| selector_matches(tag, selector)))
                    .cloned();
                selectors.retain(|selector| {
                    !selector.as_str().is_some_and(|selector| {
                        failed.iter().any(|tag| selector_matches(tag, selector))
                    })
                });
                if selectors.is_empty() {
                    // A surviving explicit fallback still serves an empty pool.
                    let fallback = balancer["fallbackTag"]
                        .as_str()
                        .filter(|tag| !tag.is_empty() && !failed.contains(*tag))
                        .map(str::to_owned);
                    let target = fallback.or(removed).ok_or(CompileError::InvalidRoute)?;
                    empty_pools.insert(
                        balancer["tag"]
                            .as_str()
                            .ok_or(CompileError::InvalidRoute)?
                            .to_owned(),
                        target,
                    );
                }
            }
            balancers.retain(|balancer| {
                !balancer["tag"]
                    .as_str()
                    .is_some_and(|tag| empty_pools.contains_key(tag))
            });
        }
        if let Some(rules) = config["routing"]["rules"].as_array_mut() {
            for rule in rules {
                if let Some(target) = rule["balancerTag"]
                    .as_str()
                    .and_then(|tag| empty_pools.get(tag))
                    .cloned()
                {
                    rule.as_object_mut()
                        .ok_or(CompileError::InvalidRoute)?
                        .remove("balancerTag");
                    rule["outboundTag"] = json!(target);
                }
            }
        }
        for section in ["observatory", "burstObservatory"] {
            if let Some(selectors) = config[section]
                .get_mut("subjectSelector")
                .and_then(Value::as_array_mut)
            {
                selectors.retain(|selector| {
                    !selector.as_str().is_some_and(|selector| {
                        failed.iter().any(|tag| selector_matches(tag, selector))
                    })
                });
            }
        }
        // Do not report a usable tunnel when its only client path is closed. A
        // client counts only if routing reaches it: a rule, a balancer or the default.
        let outbounds = config["outbounds"].as_array().unwrap();
        let rules: Vec<&Value> = config["routing"]["rules"]
            .as_array()
            .into_iter()
            .flatten()
            .collect();
        let mut routed: BTreeSet<&str> = rules
            .iter()
            .filter_map(|rule| rule["outboundTag"].as_str())
            .chain(
                outbounds
                    .first()
                    .and_then(|outbound| outbound["tag"].as_str()),
            )
            .collect();
        for balancer in config["routing"]["balancers"]
            .as_array()
            .into_iter()
            .flatten()
        {
            if !rules
                .iter()
                .any(|rule| rule["balancerTag"] == balancer["tag"])
            {
                continue;
            }
            routed.extend(balancer["fallbackTag"].as_str());
            for selector in balancer["selector"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                routed.extend(
                    outbounds
                        .iter()
                        .filter_map(|outbound| outbound["tag"].as_str())
                        .filter(|tag| selector_matches(tag, selector)),
                );
            }
        }
        let usable_client = outbounds.iter().any(|outbound| {
            outbound["protocol"]
                .as_str()
                .is_some_and(is_client_protocol)
                && outbound["tag"]
                    .as_str()
                    .is_some_and(|tag| routed.contains(tag))
        });
        let direct_tags: BTreeSet<&str> = outbounds
            .iter()
            .filter(|outbound| outbound["protocol"] == "freedom")
            .filter_map(|outbound| outbound["tag"].as_str())
            .collect();
        let explicit_direct = config["routing"]["rules"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|rule| {
                rule["outboundTag"]
                    .as_str()
                    .is_some_and(|tag| direct_tags.contains(tag))
                    && rule["network"] == "tcp,udp"
                    // Any other matcher leaves the remaining traffic on the closed path.
                    && rule.as_object().is_some_and(|rule| {
                        rule.keys().all(|key| {
                            matches!(
                                key.as_str(),
                                "type" | "network" | "inboundTag" | "outboundTag" | "ruleTag"
                            )
                        })
                    })
            });
        if !usable_client && !explicit_direct {
            return Err(CompileError::InvalidOutbound);
        }
    }
    if pin {
        pin_config(config, resolved)
    } else {
        let static_hosts = endpoints
            .iter()
            .filter(|endpoint| !endpoint.addresses.is_empty())
            .map(|endpoint| endpoint.host.clone())
            .chain(pin_hosts.iter().cloned())
            .collect();
        pin_selected_config(config, resolved, Some(&static_hosts))
    }
}

fn append_endpoint(
    result: &mut Vec<ProfileEndpoint>,
    server: &Value,
    path: String,
    stream_path: Option<String>,
    physical: bool,
) -> Result<(), CompileError> {
    let host = server["address"]
        .as_str()
        .filter(|host| {
            !host.is_empty() && host.len() <= 253 && !host.chars().any(char::is_whitespace)
        })
        .ok_or(CompileError::InvalidOutbound)?
        .to_owned();
    let port = server["port"]
        .as_u64()
        .filter(|port| (1..=65535).contains(port))
        .ok_or(CompileError::InvalidOutbound)? as u16;
    result.push(ProfileEndpoint {
        host,
        port,
        address_path: format!("{path}/address"),
        stream_path,
        endpoint_string: false,
        physical,
        supports_tcp_probe: false,
        addresses: Vec::new(),
        domain_strategy: String::new(),
    });
    Ok(())
}

pub(crate) fn download_settings<'a>(stream: &'a Value, path: &str) -> Option<(&'a Value, String)> {
    let network = stream
        .get("method")
        .filter(|value| !value.is_null())
        .or_else(|| stream.get("network"))
        .and_then(Value::as_str)
        .unwrap_or("raw");
    if !matches!(network.to_ascii_lowercase().as_str(), "xhttp" | "splithttp") {
        return None;
    }
    let key = if stream.get("xhttpSettings").is_some_and(Value::is_object) {
        "xhttpSettings"
    } else {
        "splithttpSettings"
    };
    let (settings, suffix) =
        if let Some(extra) = stream[key].get("extra").filter(|value| !value.is_null()) {
            (extra, "/extra")
        } else {
            (&stream[key], "")
        };
    settings
        .get("downloadSettings")
        .filter(|value| !value.is_null())
        .map(|value| (value, format!("{path}/{key}{suffix}/downloadSettings")))
}
