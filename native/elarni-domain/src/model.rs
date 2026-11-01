use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SecretRef {
    pub id: String,
}

impl SecretRef {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.id.is_empty() || self.id.len() > 128 {
            return Err("secret reference length must be 1..=128");
        }
        if !self
            .id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err("secret reference contains unsupported characters");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CanonicalHy2Endpoint {
    pub schema_version: u32,
    pub host: String,
    pub port: u16,
    pub server_name: Option<String>,
    pub alpn: Vec<String>,
    pub fingerprint: Option<String>,
    pub obfuscation: Option<Hy2Obfuscation>,
    pub bandwidth: Hy2Bandwidth,
    pub port_hop: Option<Hy2PortHop>,
    pub secret_ref: SecretRef,
    pub display_name: Option<String>,
    pub unknown_parameters: BTreeMap<String, Vec<String>>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Hy2Bandwidth {
    pub upload: Option<String>,
    pub download: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Hy2PortHop {
    pub ports: String,
    pub interval_seconds: Option<u32>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Hy2Obfuscation {
    pub kind: String,
    pub password_ref: SecretRef,
}

pub struct ParsedHy2 {
    pub endpoint: CanonicalHy2Endpoint,
    pub authentication: String,
    pub obfuscation_password: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SecretMaterial {
    pub secret_ref: SecretRef,
    pub value: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RouteAction {
    Proxy,
    Direct,
    Block,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum RouteDomainStrategy {
    AsIs,
    #[serde(rename = "IPIfNonMatch")]
    IpIfNonMatch,
    #[serde(rename = "IPOnDemand")]
    IpOnDemand,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PacketBackend {
    #[default]
    NativeTun2Proxy,
    XrayTun,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum PreferredIp {
    Ipv4,
    Ipv6,
    Automatic,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ProfileDnsMode {
    #[default]
    Inherit,
    Routing,
    Default,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum PerAppMode {
    #[default]
    Off,
    Bypass,
    ProxyOnly,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeOptions {
    #[serde(default)]
    pub per_app_mode: PerAppMode,
    #[serde(default)]
    pub per_app_processes: Vec<String>,
    /// Listed apps with their own target; the others take the mode's.
    #[serde(default)]
    pub per_app_targets: Vec<PerAppTarget>,
    #[serde(default)]
    pub fragmentation_enabled: bool,
    #[serde(default = "default_fragment_packets")]
    pub fragment_packets: String,
    #[serde(default = "default_fragment_length")]
    pub fragment_length: String,
    #[serde(default = "default_fragment_interval")]
    pub fragment_interval: String,
    #[serde(default)]
    pub mux_enabled: bool,
    #[serde(default = "default_preferred_ip")]
    pub preferred_ip: PreferredIp,
    #[serde(default = "default_connection_idle")]
    pub connection_idle_seconds: u32,
    #[serde(default = "default_true")]
    pub sniffing_enabled: bool,
    #[serde(default)]
    pub http_inbound_enabled: bool,
    #[serde(default)]
    pub http_port: Option<u16>,
    #[serde(default)]
    pub allow_lan: bool,
    #[serde(default)]
    pub inbound_auth: Option<InboundAuth>,
    #[serde(default = "default_true")]
    pub use_dns_from_json: bool,
    #[serde(default)]
    pub profile_dns_mode: ProfileDnsMode,
}

impl Default for RuntimeOptions {
    fn default() -> Self {
        Self {
            per_app_mode: PerAppMode::Off,
            per_app_processes: Vec::new(),
            per_app_targets: Vec::new(),
            fragmentation_enabled: false,
            fragment_packets: default_fragment_packets(),
            fragment_length: default_fragment_length(),
            fragment_interval: default_fragment_interval(),
            mux_enabled: false,
            preferred_ip: PreferredIp::Ipv4,
            connection_idle_seconds: default_connection_idle(),
            sniffing_enabled: true,
            http_inbound_enabled: false,
            http_port: None,
            allow_lan: false,
            inbound_auth: None,
            use_dns_from_json: true,
            profile_dns_mode: ProfileDnsMode::Inherit,
        }
    }
}

/// `target` is direct, routing, block, server (with `server`: a node's outbound, or a
/// profile whose first outbound carries it) or proxy (with `proxy`: a socks:// or
/// http:// URL on this device).
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PerAppTarget {
    pub process: String,
    pub target: String,
    #[serde(default)]
    pub server: Option<serde_json::Value>,
    #[serde(default)]
    pub proxy: Option<String>,
}

// A server target carries its credentials.
impl std::fmt::Debug for PerAppTarget {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "PerAppTarget({}, {})", self.process, self.target)
    }
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InboundAuth {
    pub username: String,
    pub password: String,
}

impl std::fmt::Debug for InboundAuth {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("InboundAuth([REDACTED])")
    }
}

fn default_preferred_ip() -> PreferredIp {
    PreferredIp::Ipv4
}

fn default_fragment_packets() -> String {
    "tlshello".into()
}
fn default_fragment_length() -> String {
    "100-200".into()
}
fn default_fragment_interval() -> String {
    "0-1".into()
}

fn default_connection_idle() -> u32 {
    300
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RouteRule {
    pub action: RouteAction,
    pub domains: Vec<String>,
    pub ips: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RouteModel {
    pub rules: Vec<RouteRule>,
    pub dns_servers: Vec<String>,
    #[serde(default)]
    pub static_hosts: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub fallback_action: Option<RouteAction>,
    #[serde(default)]
    pub domain_strategy: Option<RouteDomainStrategy>,
    #[serde(default)]
    pub fake_dns: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dns_policy: Option<DnsPolicy>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DnsResolver {
    pub address: String,
    #[serde(default)]
    pub bootstrap_ips: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DnsPolicy {
    pub remote: DnsResolver,
    pub domestic: DnsResolver,
    // None preserves legacy ordered fallback; Some selects domestic only for
    // these explicit domains, with remote as the default for everything else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub domestic_domains: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CompileRequest {
    pub endpoint: CanonicalHy2Endpoint,
    pub authentication: SecretMaterial,
    pub obfuscation_password: Option<SecretMaterial>,
    pub routes: RouteModel,
    pub socks_port: u16,
    #[serde(default)]
    pub packet_backend: PacketBackend,
    #[serde(default = "default_tun_mtu")]
    pub tun_mtu: u16,
    #[serde(default)]
    pub runtime: RuntimeOptions,
}

fn default_tun_mtu() -> u16 {
    1500
}
