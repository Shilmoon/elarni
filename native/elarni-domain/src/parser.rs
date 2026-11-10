use std::collections::{BTreeMap, HashSet};

use percent_encoding::percent_decode_str;
use thiserror::Error;
use url::{Host, Url};

use crate::model::{
    CanonicalHy2Endpoint, Hy2Bandwidth, Hy2Obfuscation, Hy2PortHop, ParsedHy2, SecretRef,
};

const KNOWN_KEYS: &[&str] = &[
    "alpn",
    "auth",
    "down",
    "fp",
    "hop-interval",
    "insecure",
    "mportHopInt",
    "obfs",
    "obfs-password",
    "port",
    "ports",
    "security",
    "sni",
    "up",
];

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ParseError {
    #[error("URI is invalid")]
    InvalidUri,
    #[error("scheme must be hysteria2 or hy2")]
    InvalidScheme,
    #[error("host is required")]
    MissingHost,
    #[error("explicit non-zero port is required")]
    InvalidPort,
    #[error("authentication is required")]
    MissingAuthentication,
    #[error("conflicting authentication fields")]
    ConflictingAuthentication,
    #[error("duplicate known parameter: {0}")]
    DuplicateParameter(String),
    #[error("conflicting aliases: {0} and {1}")]
    ConflictingAliases(&'static str, &'static str),
    #[error("unsafe TLS relaxation is forbidden")]
    UnsafeTls,
    #[error("unsupported security mode")]
    UnsupportedSecurity,
    #[error("invalid port hopping interval")]
    InvalidHopInterval,
    #[error("invalid port hopping set")]
    InvalidPortSet,
    #[error("unsupported obfuscation")]
    UnsupportedObfuscation,
    #[error("obfuscation password is required")]
    MissingObfuscationPassword,
    #[error("secret reference is invalid")]
    InvalidSecretRef,
    #[error("percent-encoded text is not UTF-8")]
    InvalidEncoding,
}

pub fn parse_hy2_uri(
    input: &str,
    authentication_ref: SecretRef,
    obfuscation_ref: Option<SecretRef>,
) -> Result<ParsedHy2, ParseError> {
    authentication_ref
        .validate()
        .map_err(|_| ParseError::InvalidSecretRef)?;
    if let Some(reference) = &obfuscation_ref {
        reference
            .validate()
            .map_err(|_| ParseError::InvalidSecretRef)?;
    }

    if input.len() > 64 * 1024 || input.chars().any(char::is_control) {
        return Err(ParseError::InvalidUri);
    }
    let url = Url::parse(input).map_err(|_| ParseError::InvalidUri)?;
    if !matches!(url.scheme(), "hysteria2" | "hy2") {
        return Err(ParseError::InvalidScheme);
    }

    let host = match url.host().ok_or(ParseError::MissingHost)? {
        Host::Domain(domain) => domain.to_ascii_lowercase(),
        Host::Ipv4(address) => address.to_string(),
        Host::Ipv6(address) => address.to_string(),
    };
    let port = url
        .port()
        .filter(|port| *port != 0)
        .ok_or(ParseError::InvalidPort)?;

    let mut query = BTreeMap::<String, Vec<String>>::new();
    for (key, value) in url.query_pairs() {
        query
            .entry(key.into_owned())
            .or_default()
            .push(value.into_owned());
    }
    for key in KNOWN_KEYS {
        if query.get(*key).is_some_and(|values| values.len() > 1) {
            return Err(ParseError::DuplicateParameter((*key).to_owned()));
        }
    }

    reject_alias_conflict(&query, "port", "ports")?;
    reject_alias_conflict(&query, "mportHopInt", "hop-interval")?;

    if query
        .get("insecure")
        .and_then(|values| values.first())
        .is_some_and(|value| matches!(value.as_str(), "1" | "true" | "yes"))
    {
        return Err(ParseError::UnsafeTls);
    }
    if query
        .get("security")
        .and_then(|values| values.first())
        .is_some_and(|value| !value.is_empty() && value != "tls")
    {
        return Err(ParseError::UnsupportedSecurity);
    }

    let user_auth = decode_userinfo(&url)?;
    let query_auth = single(&query, "auth").filter(|value| !value.is_empty());
    let authentication = match (user_auth, query_auth) {
        (Some(user), Some(query)) if user != query => {
            return Err(ParseError::ConflictingAuthentication);
        }
        (Some(user), _) => user,
        (None, Some(query)) => query.to_owned(),
        (None, None) => return Err(ParseError::MissingAuthentication),
    };

    let ports = single(&query, "port")
        .or_else(|| single(&query, "ports"))
        .map(str::to_owned);
    if let Some(value) = &ports {
        validate_port_set(value)?;
    }
    let hop_interval = single(&query, "mportHopInt")
        .or_else(|| single(&query, "hop-interval"))
        .map(|value| {
            value
                .parse::<u32>()
                .ok()
                .filter(|value| (5..=3600).contains(value))
                .ok_or(ParseError::InvalidHopInterval)
        })
        .transpose()?;
    if hop_interval.is_some() && ports.is_none() {
        return Err(ParseError::InvalidPortSet);
    }

    let obfs = single(&query, "obfs").filter(|value| !value.is_empty());
    let obfs_password = single(&query, "obfs-password")
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let obfuscation = match (obfs, obfs_password.as_deref(), obfuscation_ref) {
        (None, None, _) => None,
        (Some("salamander"), Some(_), Some(password_ref)) => Some(Hy2Obfuscation {
            kind: "salamander".to_owned(),
            password_ref,
        }),
        (Some("salamander"), Some(_), None) => return Err(ParseError::InvalidSecretRef),
        (Some("salamander"), None, _) => return Err(ParseError::MissingObfuscationPassword),
        (Some(_), _, _) => return Err(ParseError::UnsupportedObfuscation),
        (None, Some(_), _) => return Err(ParseError::UnsupportedObfuscation),
    };

    let value = |key: &str| {
        single(&query, key)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    let (alpn, server_name, fingerprint) = (value("alpn"), value("sni"), value("fp"));
    let (upload, download) = (value("up"), value("down"));
    let known = KNOWN_KEYS.iter().copied().collect::<HashSet<_>>();
    let unknown_parameters = query
        .into_iter()
        .filter(|(key, _)| !known.contains(key.as_str()))
        .collect();
    let alpn = alpn
        .unwrap_or_default()
        .split(',')
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect();
    let display_name = url
        .fragment()
        .filter(|value| !value.is_empty())
        .map(str::to_owned);

    Ok(ParsedHy2 {
        endpoint: CanonicalHy2Endpoint {
            schema_version: 1,
            host,
            port,
            server_name,
            alpn,
            fingerprint,
            obfuscation,
            bandwidth: Hy2Bandwidth { upload, download },
            port_hop: ports.map(|ports| Hy2PortHop {
                ports,
                interval_seconds: hop_interval,
            }),
            secret_ref: authentication_ref,
            display_name,
            unknown_parameters,
        },
        authentication,
        obfuscation_password: obfs_password,
    })
}

fn reject_alias_conflict(
    query: &BTreeMap<String, Vec<String>>,
    first: &'static str,
    second: &'static str,
) -> Result<(), ParseError> {
    if query.contains_key(first) && query.contains_key(second) {
        return Err(ParseError::ConflictingAliases(first, second));
    }
    Ok(())
}

fn single<'a>(query: &'a BTreeMap<String, Vec<String>>, key: &str) -> Option<&'a str> {
    query.get(key)?.first().map(String::as_str)
}

fn decode_userinfo(url: &Url) -> Result<Option<String>, ParseError> {
    if url.username().is_empty() && url.password().is_none() {
        return Ok(None);
    }
    let mut encoded = url.username().to_owned();
    if let Some(password) = url.password() {
        encoded.push(':');
        encoded.push_str(password);
    }
    percent_decode_str(&encoded)
        .decode_utf8()
        .map(|value| Some(value.into_owned()))
        .map_err(|_| ParseError::InvalidEncoding)
}

fn validate_port_set(value: &str) -> Result<(), ParseError> {
    if value.is_empty() || value.len() > 512 {
        return Err(ParseError::InvalidPortSet);
    }
    for segment in value.split(',') {
        let mut bounds = segment.split('-');
        let first = parse_nonzero_port(bounds.next().unwrap_or_default())?;
        if let Some(second) = bounds.next() {
            let second = parse_nonzero_port(second)?;
            if first > second || bounds.next().is_some() {
                return Err(ParseError::InvalidPortSet);
            }
        }
    }
    Ok(())
}

fn parse_nonzero_port(value: &str) -> Result<u16, ParseError> {
    // Xray reads the port set as written: no leading '+', which Rust's parse accepts.
    if !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ParseError::InvalidPortSet);
    }
    value
        .parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .ok_or(ParseError::InvalidPortSet)
}
