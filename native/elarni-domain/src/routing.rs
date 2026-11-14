use std::collections::{BTreeMap, BTreeSet};
use std::net::IpAddr;

use base64::{Engine as _, engine::general_purpose};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use thiserror::Error;
use url::Url;

use crate::model::{RouteAction, RouteDomainStrategy, RouteModel, RouteRule};

pub const MAX_ROUTING_INPUT_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_ROUTING_TARGETS: usize = 100_000;
pub const MAX_DNS_HOSTS: usize = 4_096;
const MAX_URL_BYTES: usize = 8 * 1024;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ManagedMatchMode {
    Exact,
    Subdomains,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ManagedDestination {
    Block,
    Direct,
    Proxy,
    Dns,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ManagedSource {
    pub id: String,
    pub url: String,
    pub destination: ManagedDestination,
    pub match_mode: ManagedMatchMode,
}

pub fn parse_managed_domains(
    input: &str,
    mode: ManagedMatchMode,
) -> Result<Vec<String>, RoutingError> {
    if input.len() > MAX_ROUTING_INPUT_BYTES {
        return Err(RoutingError::TooLarge);
    }
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    for line in input.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.chars().any(|c| {
            c.is_whitespace()
                || c.is_control()
                || (c.is_ascii() && !(c.is_alphanumeric() || c == '-' || c == '.'))
        }) {
            return Err(RoutingError::InvalidField("managedDomain"));
        }
        let url::Host::Domain(domain) =
            url::Host::parse(line).map_err(|_| RoutingError::InvalidField("managedDomain"))?
        else {
            return Err(RoutingError::InvalidField("managedDomain"));
        };
        if domain.len() > 253
            || domain.split('.').any(|label| {
                label.is_empty()
                    || label.len() > 63
                    || label.starts_with('-')
                    || label.ends_with('-')
                    || !label
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            })
        {
            return Err(RoutingError::InvalidField("managedDomain"));
        }
        let target = format!(
            "{}:{domain}",
            match mode {
                ManagedMatchMode::Exact => "full",
                ManagedMatchMode::Subdomains => "domain",
            }
        );
        if seen.insert(target.clone()) {
            result.push(target);
        }
        if result.len() > MAX_ROUTING_TARGETS {
            return Err(RoutingError::TooLarge);
        }
    }
    Ok(result)
}

pub fn merge_managed_routing(
    profile: &HappRoutingProfile,
    lists: &BTreeMap<String, Vec<String>>,
) -> Result<RouteModel, RoutingError> {
    let mut routes = profile.to_route_model()?;
    if lists.keys().any(|id| {
        !profile
            .managed_sources
            .iter()
            .any(|source| &source.id == id)
    }) {
        return Err(RoutingError::InvalidField("ManagedSources"));
    }
    for source in &profile.managed_sources {
        let Some(domains) = lists.get(&source.id) else {
            continue;
        };
        // Revalidate persisted normalized data at the native trust boundary.
        let prefix = match source.match_mode {
            ManagedMatchMode::Exact => "full:",
            ManagedMatchMode::Subdomains => "domain:",
        };
        for domain in domains {
            let raw = domain
                .strip_prefix(prefix)
                .ok_or(RoutingError::InvalidField("managedDomain"))?;
            if parse_managed_domains(raw, source.match_mode)? != [domain.clone()] {
                return Err(RoutingError::InvalidField("managedDomain"));
            }
        }
        let domains = deduplicate(domains);
        if domains.is_empty() {
            continue;
        }
        let action = match source.destination {
            ManagedDestination::Block => RouteAction::Block,
            ManagedDestination::Direct => RouteAction::Direct,
            ManagedDestination::Proxy => RouteAction::Proxy,
            ManagedDestination::Dns => {
                let policy = routes
                    .dns_policy
                    .as_mut()
                    .ok_or(RoutingError::InvalidField("DNS"))?;
                let existing = policy.domestic_domains.get_or_insert_with(Vec::new);
                existing.extend(domains);
                *existing = deduplicate(existing);
                continue;
            }
        };
        routes.rules.push(RouteRule {
            action,
            domains,
            ips: vec![],
        });
    }
    validate_effective_targets(&routes)?;
    crate::compiler::validate_routing_model(&routes)
        .map_err(|_| RoutingError::InvalidField("compiler"))?;
    Ok(routes)
}

pub fn validate_effective_targets(routes: &RouteModel) -> Result<(), RoutingError> {
    let count = routes
        .rules
        .iter()
        .map(|rule| rule.domains.len() + rule.ips.len())
        .sum::<usize>()
        + routes
            .dns_policy
            .as_ref()
            .and_then(|policy| policy.domestic_domains.as_ref())
            .map_or(0, Vec::len);
    if count > MAX_ROUTING_TARGETS
        || routes.rules.len() > 128
        || encoded_len(routes)? > 8 * 1024 * 1024
    {
        return Err(RoutingError::TooLarge);
    }
    Ok(())
}

// The size of the model as JSON, without building the JSON.
fn encoded_len(routes: &RouteModel) -> Result<usize, RoutingError> {
    struct Count(usize);
    impl std::io::Write for Count {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0 += bytes.len();
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut count = Count(0);
    serde_json::to_writer(&mut count, routes).map_err(|_| RoutingError::InvalidJson)?;
    Ok(count.0)
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum DnsType {
    DoH,
    DoU,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum DomainStrategy {
    AsIs,
    IPIfNonMatch,
    IPOnDemand,
}

impl From<DomainStrategy> for RouteDomainStrategy {
    fn from(value: DomainStrategy) -> Self {
        match value {
            DomainStrategy::AsIs => Self::AsIs,
            DomainStrategy::IPIfNonMatch => Self::IpIfNonMatch,
            DomainStrategy::IPOnDemand => Self::IpOnDemand,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub enum RouteOrder {
    #[serde(rename = "block-direct-proxy")]
    BlockDirectProxy,
    #[serde(rename = "block-proxy-direct")]
    #[default]
    BlockProxyDirect,
    #[serde(rename = "direct-block-proxy")]
    DirectBlockProxy,
    #[serde(rename = "direct-proxy-block")]
    DirectProxyBlock,
    #[serde(rename = "proxy-block-direct")]
    ProxyBlockDirect,
    #[serde(rename = "proxy-direct-block")]
    ProxyDirectBlock,
}

impl RouteOrder {
    fn actions(self) -> [RouteAction; 3] {
        use RouteAction::{Block, Direct, Proxy};
        match self {
            Self::BlockDirectProxy => [Block, Direct, Proxy],
            Self::BlockProxyDirect => [Block, Proxy, Direct],
            Self::DirectBlockProxy => [Direct, Block, Proxy],
            Self::DirectProxyBlock => [Direct, Proxy, Block],
            Self::ProxyBlockDirect => [Proxy, Block, Direct],
            Self::ProxyDirectBlock => [Proxy, Direct, Block],
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(untagged)]
pub enum LastUpdated {
    Text(String),
    Unix(u64),
}

// Other clients add fields of their own (GeositeHash, UseTags, UpdateUrl); they are ignored.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct HappRoutingProfile {
    #[serde(
        rename = "ManagedSources",
        default,
        skip_serializing_if = "Vec::is_empty"
    )]
    pub managed_sources: Vec<ManagedSource>,
    #[serde(rename = "Name", default)]
    pub name: Option<String>,
    #[serde(
        rename = "GlobalProxy",
        default = "default_true",
        deserialize_with = "deserialize_text_bool",
        serialize_with = "serialize_text_bool"
    )]
    pub global_proxy: bool,
    #[serde(rename = "RouteOrder", default)]
    pub route_order: RouteOrder,
    #[serde(rename = "RemoteDNSType", default = "default_dns_type")]
    pub remote_dns_type: DnsType,
    #[serde(rename = "RemoteDNSDomain", default)]
    pub remote_dns_domain: String,
    #[serde(rename = "RemoteDNSIP", alias = "RemoteDNSIp", default)]
    pub remote_dns_ip: String,
    #[serde(rename = "RemoteDns", default)]
    pub legacy_remote_dns: String,
    #[serde(rename = "DomesticDNSType", default = "default_dns_type")]
    pub domestic_dns_type: DnsType,
    #[serde(rename = "DomesticDNSDomain", default)]
    pub domestic_dns_domain: String,
    #[serde(rename = "DomesticDNSIP", alias = "DomesticDNSIp", default)]
    pub domestic_dns_ip: String,
    #[serde(rename = "DomesticDns", default)]
    pub legacy_domestic_dns: String,
    #[serde(
        rename = "DomesticDNSDomains",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub domestic_dns_domains: Option<Vec<String>>,
    #[serde(rename = "Geoipurl", alias = "GeoipUrl", default)]
    pub geoip_url: String,
    #[serde(rename = "Geositeurl", alias = "GeositeUrl", default)]
    pub geosite_url: String,
    #[serde(rename = "LastUpdated", default)]
    pub last_updated: Option<LastUpdated>,
    #[serde(rename = "DnsHosts", default)]
    pub dns_hosts: BTreeMap<String, String>,
    #[serde(rename = "DirectSites", default)]
    pub direct_sites: Vec<String>,
    #[serde(rename = "DirectIp", default)]
    pub direct_ip: Vec<String>,
    #[serde(rename = "ProxySites", default)]
    pub proxy_sites: Vec<String>,
    #[serde(rename = "ProxyIp", default)]
    pub proxy_ip: Vec<String>,
    #[serde(rename = "BlockSites", default)]
    pub block_sites: Vec<String>,
    #[serde(rename = "BlockIp", default)]
    pub block_ip: Vec<String>,
    #[serde(rename = "DomainStrategy", default = "default_domain_strategy")]
    pub domain_strategy: DomainStrategy,
    #[serde(
        rename = "FakeDNS",
        alias = "FakeDns",
        default,
        deserialize_with = "deserialize_text_bool",
        serialize_with = "serialize_text_bool"
    )]
    pub fake_dns: bool,
    #[serde(
        rename = "UseChunkFiles",
        alias = "useChunkFiles",
        // Elarni: reduced unless the profile opts out; full RU geofiles cost ~90 MB and Apple refuses them.
        default = "default_true",
        deserialize_with = "deserialize_text_bool",
        serialize_with = "serialize_text_bool"
    )]
    pub use_chunk_files: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "action"
)]
// ponytail: serialized once at the FFI boundary; box fields if this becomes long-lived.
#[allow(clippy::large_enum_variant)]
pub enum RoutingImport {
    Add {
        activate: bool,
        profile: HappRoutingProfile,
        route_model: RouteModel,
    },
    Off,
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum RoutingError {
    #[error("routing input is empty")]
    Empty,
    #[error("routing input exceeds the size limit")]
    TooLarge,
    #[error("unsupported routing link")]
    UnsupportedLink,
    #[error("invalid routing base64")]
    InvalidBase64,
    #[error("invalid routing JSON")]
    InvalidJson,
    #[error("invalid routing field: {0}")]
    InvalidField(&'static str),
}

pub fn decode_routing(input: &str) -> Result<RoutingImport, RoutingError> {
    if input.len() > MAX_ROUTING_INPUT_BYTES {
        return Err(RoutingError::TooLarge);
    }
    let input = input.trim();
    if input.is_empty() {
        return Err(RoutingError::Empty);
    }
    // Providers also send the bare command and links without a scheme.
    let command = [
        "happ://routing/",
        "incy://routing/",
        "elarni://routing/",
        "://routing/",
    ]
    .iter()
    .find_map(|prefix| input.strip_prefix(prefix));
    if command == Some("off") || input.eq_ignore_ascii_case("off") {
        return Ok(RoutingImport::Off);
    }
    // Happ's query form: .../add?data=<base64>, the base64 possibly percent-encoded.
    let query = |value: &str| -> Result<Vec<u8>, RoutingError> {
        let data = percent_encoding::percent_decode_str(value)
            .decode_utf8()
            .map_err(|_| RoutingError::InvalidBase64)?;
        decode_base64(&data)
    };

    let (activate, payload) =
        if let Some(payload) = command.and_then(|value| value.strip_prefix("add/")) {
            (false, decode_base64(payload)?)
        } else if let Some(payload) = command.and_then(|value| value.strip_prefix("onadd/")) {
            (true, decode_base64(payload)?)
        } else if let Some(payload) = command.and_then(|value| value.strip_prefix("add?data=")) {
            (false, query(payload)?)
        } else if let Some(payload) = command.and_then(|value| value.strip_prefix("onadd?data=")) {
            (true, query(payload)?)
        } else if command.is_some()
            || input.starts_with("happ://")
            || input.starts_with("incy://")
            || input.starts_with("elarni://")
        {
            return Err(RoutingError::UnsupportedLink);
        } else if input.starts_with('{') {
            (false, input.as_bytes().to_vec())
        } else {
            (false, decode_base64(input)?)
        };

    if payload.len() > MAX_ROUTING_INPUT_BYTES {
        return Err(RoutingError::TooLarge);
    }
    // Defaults fill missing fields and other fields are ignored, so JSON without one of the
    // profile's own fields (a server config, `{}`) would pass; every app tries pasted text as
    // routing first.
    let keys: BTreeMap<String, serde::de::IgnoredAny> =
        serde_json::from_slice(&payload).map_err(|_| RoutingError::InvalidJson)?;
    let own = profile_field_names();
    if !keys.keys().any(|key| own.contains(&key.as_str())) {
        return Err(RoutingError::InvalidJson);
    }
    let mut profile: HappRoutingProfile =
        serde_json::from_slice(&payload).map_err(|_| RoutingError::InvalidJson)?;
    profile.fill_happ_defaults();
    let route_model = profile.to_route_model()?;
    crate::compiler::validate_routing_model(&route_model)
        .map_err(|_| RoutingError::InvalidField("compiler"))?;
    Ok(RoutingImport::Add {
        activate,
        profile,
        route_model,
    })
}

impl HappRoutingProfile {
    /// Happ's default profile "fills in missing or incorrect parameters"; its header example
    /// and routing builders leave the DNS fields out and the name empty.
    fn fill_happ_defaults(&mut self) {
        if self.name.as_deref() == Some("") {
            self.name = None;
        }
        fill_dns(
            &mut self.remote_dns_type,
            &mut self.remote_dns_domain,
            &mut self.remote_dns_ip,
            &self.legacy_remote_dns,
            ("https://cloudflare-dns.com/dns-query", "1.1.1.1"),
        );
        fill_dns(
            &mut self.domestic_dns_type,
            &mut self.domestic_dns_domain,
            &mut self.domestic_dns_ip,
            &self.legacy_domestic_dns,
            ("https://dns.google/dns-query", "8.8.8.8"),
        );
    }

    pub fn to_route_model(&self) -> Result<RouteModel, RoutingError> {
        self.validate()?;
        let mut rules = Vec::with_capacity(3);
        for action in self.route_order.actions() {
            let (domains, ips) = match action {
                RouteAction::Direct => (&self.direct_sites, &self.direct_ip),
                RouteAction::Proxy => (&self.proxy_sites, &self.proxy_ip),
                RouteAction::Block => (&self.block_sites, &self.block_ip),
            };
            let domains = deduplicate(
                &domains
                    .iter()
                    .map(|site| punycode_site(site))
                    .collect::<Vec<_>>(),
            );
            let ips = deduplicate(
                &ips.iter()
                    .map(|ip| negation_beside_code(ip))
                    .collect::<Vec<_>>(),
            );
            if !domains.is_empty() || !ips.is_empty() {
                rules.push(RouteRule {
                    action,
                    domains,
                    ips,
                });
            }
        }

        let remote_ip = preferred_ip(&self.remote_dns_ip, &self.legacy_remote_dns);
        let domestic_ip = preferred_ip(&self.domestic_dns_ip, &self.legacy_domestic_dns);
        let dns_servers = vec![
            dns_server(self.remote_dns_type, &self.remote_dns_domain, remote_ip),
            dns_server(
                self.domestic_dns_type,
                &self.domestic_dns_domain,
                domestic_ip,
            ),
        ];
        let resolver = |address: &String, ip: &str, kind: DnsType| crate::model::DnsResolver {
            address: address.clone(),
            bootstrap_ips: if kind == DnsType::DoH && !ip.is_empty() {
                vec![ip.to_owned()]
            } else {
                vec![]
            },
        };
        let dns_policy = Some(crate::model::DnsPolicy {
            remote: resolver(&dns_servers[0], remote_ip, self.remote_dns_type),
            domestic: resolver(&dns_servers[1], domestic_ip, self.domestic_dns_type),
            domestic_domains: self.domestic_dns_domains.as_ref().map(|domains| {
                deduplicate(
                    &domains
                        .iter()
                        .map(|site| punycode_site(site))
                        .collect::<Vec<_>>(),
                )
            }),
        });
        let static_hosts = self
            .dns_hosts
            .iter()
            .map(|(host, address)| (host.to_ascii_lowercase(), vec![address.clone()]))
            .collect();
        Ok(RouteModel {
            rules,
            dns_servers,
            static_hosts,
            fallback_action: Some(if self.global_proxy {
                RouteAction::Proxy
            } else {
                RouteAction::Direct
            }),
            domain_strategy: Some(self.domain_strategy.into()),
            fake_dns: self.fake_dns,
            dns_policy,
        })
    }

    fn validate(&self) -> Result<(), RoutingError> {
        let mut source_ids = BTreeSet::new();
        if self.managed_sources.len() > 125 {
            return Err(RoutingError::TooLarge);
        }
        for source in &self.managed_sources {
            if source.id.is_empty()
                || source.id.len() > 128
                || !source
                    .id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
                || !source_ids.insert(&source.id)
                || source.url.is_empty()
            {
                return Err(RoutingError::InvalidField("ManagedSources"));
            }
            validate_url(&source.url, "ManagedSources")?;
        }
        if self.domestic_dns_domains.as_ref().is_some_and(|domains| {
            domains.len() > MAX_ROUTING_TARGETS
                || domains.iter().any(|domain| {
                    domain.is_empty()
                        || domain.len() > 512
                        || domain.chars().any(char::is_whitespace)
                        || domain.parse::<IpAddr>().is_ok()
                        || domain.contains('/')
                })
        }) {
            return Err(RoutingError::InvalidField("DomesticDNSDomains"));
        }
        if self
            .name
            .as_ref()
            .is_some_and(|name| name.is_empty() || name.len() > 128)
        {
            return Err(RoutingError::InvalidField("Name"));
        }
        validate_url(&self.geoip_url, "Geoipurl")?;
        validate_url(&self.geosite_url, "Geositeurl")?;
        validate_dns(
            self.remote_dns_type,
            &self.remote_dns_domain,
            preferred_ip(&self.remote_dns_ip, &self.legacy_remote_dns),
            "RemoteDNS",
        )?;
        validate_dns(
            self.domestic_dns_type,
            &self.domestic_dns_domain,
            preferred_ip(&self.domestic_dns_ip, &self.legacy_domestic_dns),
            "DomesticDNS",
        )?;
        if self.dns_hosts.len() > MAX_DNS_HOSTS {
            return Err(RoutingError::InvalidField("DnsHosts"));
        }
        for (host, address) in &self.dns_hosts {
            if host.is_empty()
                || host.len() > 253
                || !host.is_ascii()
                || address.parse::<IpAddr>().is_err()
            {
                return Err(RoutingError::InvalidField("DnsHosts"));
            }
        }
        let lists = [
            &self.direct_sites,
            &self.direct_ip,
            &self.proxy_sites,
            &self.proxy_ip,
            &self.block_sites,
            &self.block_ip,
        ];
        if lists.iter().map(|items| items.len()).sum::<usize>()
            + self.domestic_dns_domains.as_ref().map_or(0, Vec::len)
            > MAX_ROUTING_TARGETS
        {
            return Err(RoutingError::InvalidField("rules"));
        }
        if lists.iter().flat_map(|items| items.iter()).any(|target| {
            target.is_empty() || target.len() > 512 || target.chars().any(char::is_whitespace)
        }) {
            return Err(RoutingError::InvalidField("rules"));
        }
        for (field, ips) in [
            ("DirectIp", &self.direct_ip),
            ("ProxyIp", &self.proxy_ip),
            ("BlockIp", &self.block_ip),
        ] {
            if !ips.iter().all(|ip| crate::compiler::valid_ip_target(ip)) {
                return Err(RoutingError::InvalidField(field));
            }
        }
        Ok(())
    }
}

/// Xray reads a leading `!` like one before the code (`!geoip:ru` is
/// `geoip:!ru`), but geofile reducers find codes only after the prefix.
fn negation_beside_code(target: &str) -> String {
    let rest = target.trim_start_matches('!');
    let split = if rest.starts_with("geoip:") {
        Some("geoip:".len())
    } else if rest.starts_with("ext:") || rest.starts_with("ext-ip:") {
        // ext:<file>:<code>
        rest.find(':')
            .and_then(|first| rest[first + 1..].find(':').map(|second| first + second + 2))
    } else {
        None
    };
    let Some(split) = split else {
        return target.to_owned();
    };
    let (head, code) = rest.split_at(split);
    let bare = code.trim_start_matches('!');
    let negations = target.len() - rest.len() + code.len() - bare.len();
    format!("{head}{}{bare}", if negations % 2 == 1 { "!" } else { "" })
}

/// TLS and DNS carry punycode names, so a non-ASCII site never matches as
/// written; managed lists convert the same way.
fn punycode_site(target: &str) -> String {
    if target.is_ascii() {
        return target.to_owned();
    }
    let (prefix, name) = match target.split_once(':') {
        Some((prefix @ ("domain" | "full" | "keyword"), name)) => (format!("{prefix}:"), name),
        None => (String::new(), target),
        Some(_) => return target.to_owned(),
    };
    // Happ suffix lists write domain:.рф.
    let (dot, name) = name
        .strip_prefix('.')
        .map_or(("", name), |name| (".", name));
    match url::Host::parse(name) {
        Ok(url::Host::Domain(domain)) => format!("{prefix}{dot}{domain}"),
        _ => target.to_owned(),
    }
}

fn decode_base64(input: &str) -> Result<Vec<u8>, RoutingError> {
    for engine in [
        &general_purpose::STANDARD,
        &general_purpose::STANDARD_NO_PAD,
        &general_purpose::URL_SAFE,
        &general_purpose::URL_SAFE_NO_PAD,
    ] {
        if let Ok(decoded) = engine.decode(input) {
            return Ok(decoded);
        }
    }
    Err(RoutingError::InvalidBase64)
}

/// Provider "base64:" texts (titles, announcements) in any alphabet or padding.
pub fn decode_base64_text(input: &str) -> Option<String> {
    let input = input.trim();
    if input.is_empty() {
        return None;
    }
    String::from_utf8(decode_base64(input).ok()?).ok()
}

fn validate_url(value: &str, field: &'static str) -> Result<(), RoutingError> {
    if value.is_empty() {
        return Ok(());
    }
    if value.len() > MAX_URL_BYTES {
        return Err(RoutingError::InvalidField(field));
    }
    let url = Url::parse(value).map_err(|_| RoutingError::InvalidField(field))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(RoutingError::InvalidField(field));
    }
    Ok(())
}

fn validate_dns(
    kind: DnsType,
    domain: &str,
    ip: &str,
    field: &'static str,
) -> Result<(), RoutingError> {
    // For DoH the IP only spares resolving the server's own name.
    if (kind == DnsType::DoU || !ip.is_empty()) && ip.parse::<IpAddr>().is_err() {
        return Err(RoutingError::InvalidField(field));
    }
    if kind == DnsType::DoH {
        let url = Url::parse(domain).map_err(|_| RoutingError::InvalidField(field))?;
        if url.scheme() != "https"
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
        {
            return Err(RoutingError::InvalidField(field));
        }
    }
    Ok(())
}

/// The names serde reads for the profile's fields, aliases included, exactly as spelled. The
/// derived code passes them to `deserialize_struct`; this deserializer stops there.
fn profile_field_names() -> &'static [&'static str] {
    use serde::de::Visitor;
    struct Names;
    #[derive(Debug)]
    struct Found(&'static [&'static str]);
    impl std::fmt::Display for Found {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter.write_str("routing profile field names")
        }
    }
    impl std::error::Error for Found {}
    impl serde::de::Error for Found {
        fn custom<T: std::fmt::Display>(_: T) -> Self {
            Found(&[])
        }
    }
    impl<'de> Deserializer<'de> for Names {
        type Error = Found;
        fn deserialize_any<V: Visitor<'de>>(self, _: V) -> Result<V::Value, Found> {
            Err(Found(&[]))
        }
        fn deserialize_struct<V: Visitor<'de>>(
            self,
            _: &'static str,
            fields: &'static [&'static str],
            _: V,
        ) -> Result<V::Value, Found> {
            Err(Found(fields))
        }
        serde::forward_to_deserialize_any! {
            bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string bytes
            byte_buf option unit unit_struct newtype_struct seq tuple tuple_struct map enum
            identifier ignored_any
        }
    }
    match HappRoutingProfile::deserialize(Names) {
        Err(Found(names)) => names,
        Ok(_) => &[],
    }
}

/// One DNS side: a type without its value takes the value that is there (old profiles carry
/// only the legacy IP), and a side with neither takes Happ's default. Values that are there
/// are validated as written.
fn fill_dns(
    kind: &mut DnsType,
    domain: &mut String,
    ip: &mut String,
    legacy_ip: &str,
    (default_domain, default_ip): (&str, &str),
) {
    let has_ip = !preferred_ip(ip, legacy_ip).is_empty();
    match kind {
        DnsType::DoH if domain.is_empty() && has_ip => *kind = DnsType::DoU,
        DnsType::DoU if !has_ip && !domain.is_empty() => *kind = DnsType::DoH,
        _ if domain.is_empty() && !has_ip => {
            *kind = DnsType::DoH;
            *domain = default_domain.to_owned();
            *ip = default_ip.to_owned();
        }
        _ => {}
    }
}

fn dns_server(kind: DnsType, domain: &str, ip: &str) -> String {
    match kind {
        DnsType::DoH => domain.to_owned(),
        DnsType::DoU => ip.to_owned(),
    }
}

fn preferred_ip<'a>(current: &'a str, legacy: &'a str) -> &'a str {
    if current.is_empty() { legacy } else { current }
}

fn deduplicate(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values
        .iter()
        .filter(|value| seen.insert((*value).clone()))
        .cloned()
        .collect()
}

fn default_true() -> bool {
    true
}

fn default_dns_type() -> DnsType {
    DnsType::DoH
}

fn default_domain_strategy() -> DomainStrategy {
    DomainStrategy::IPIfNonMatch
}

fn deserialize_text_bool<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Value {
        Bool(bool),
        Text(String),
    }
    match Value::deserialize(deserializer)? {
        Value::Bool(value) => Ok(value),
        Value::Text(value) if value == "true" => Ok(true),
        Value::Text(value) if value == "false" => Ok(false),
        Value::Text(_) => Err(serde::de::Error::custom("expected true or false")),
    }
}

fn serialize_text_bool<S>(value: &bool, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    serializer.serialize_str(if *value { "true" } else { "false" })
}
