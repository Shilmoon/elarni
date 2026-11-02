use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::compiler::{compile_xray_config, compile_xray_outbound_config_with_options};
use crate::model::{
    CompileRequest, PacketBackend, RouteModel, RuntimeOptions, SecretMaterial, SecretRef,
};
use crate::parser::parse_hy2_uri;
use crate::routing::decode_routing;

pub const ELARNI_ABI_VERSION: u32 = 1;
pub const ELARNI_SCHEMA_MIN: u32 = 1;
pub const ELARNI_SCHEMA_MAX: u32 = 1;
// A change preview carries every node's compiled config twice; large
// subscriptions with long routing lists exceed 8 MiB.
pub(crate) const MAX_REQUEST_BYTES: usize = 64 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 12 * 1024 * 1024;

pub type ElarniStatus = u32;
pub const ELARNI_STATUS_OK: ElarniStatus = 0;
pub const ELARNI_STATUS_INVALID_ARGUMENT: ElarniStatus = 1;
pub const ELARNI_STATUS_UNSUPPORTED_VERSION: ElarniStatus = 2;
pub const ELARNI_STATUS_REQUEST_TOO_LARGE: ElarniStatus = 3;
pub const ELARNI_STATUS_RESPONSE_TOO_LARGE: ElarniStatus = 4;
pub const ELARNI_STATUS_CANCELLED: ElarniStatus = 5;
pub const ELARNI_STATUS_PARSE_ERROR: ElarniStatus = 6;
pub const ELARNI_STATUS_COMPILE_ERROR: ElarniStatus = 7;
pub const ELARNI_STATUS_PANIC: ElarniStatus = 255;

#[repr(C)]
pub struct ElarniBuffer {
    pub data: *mut u8,
    pub len: usize,
    pub capacity: usize,
}

impl Default for ElarniBuffer {
    fn default() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
            capacity: 0,
        }
    }
}

pub struct ElarniHandle {
    cancelled: AtomicBool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RequestEnvelope {
    schema_version: u32,
    operation: String,
    payload: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RoutingRequest {
    content: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompileUriRequest {
    uri: String,
    authentication_ref: SecretRef,
    obfuscation_ref: Option<SecretRef>,
    routes: RouteModel,
    socks_port: u16,
    #[serde(default)]
    packet_backend: PacketBackend,
    #[serde(default = "default_tun_mtu")]
    tun_mtu: u16,
    #[serde(default)]
    runtime: RuntimeOptions,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompileOutboundRequest {
    outbound: Value,
    routes: RouteModel,
    socks_port: u16,
    #[serde(default)]
    packet_backend: PacketBackend,
    #[serde(default = "default_tun_mtu")]
    tun_mtu: u16,
    #[serde(default)]
    runtime: RuntimeOptions,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompileProfileRequest {
    profile: Value,
    routes: Option<RouteModel>,
    socks_port: u16,
    #[serde(default)]
    packet_backend: PacketBackend,
    #[serde(default = "default_tun_mtu")]
    tun_mtu: u16,
    #[serde(default)]
    runtime: RuntimeOptions,
    preferred_ip: Option<crate::model::PreferredIp>,
}

fn default_tun_mtu() -> u16 {
    1500
}

#[unsafe(no_mangle)]
pub extern "C" fn elarni_abi_version() -> u32 {
    ELARNI_ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn elarni_schema_min() -> u32 {
    ELARNI_SCHEMA_MIN
}

#[unsafe(no_mangle)]
pub extern "C" fn elarni_schema_max() -> u32 {
    ELARNI_SCHEMA_MAX
}

#[unsafe(no_mangle)]
pub extern "C" fn elarni_handle_new() -> *mut ElarniHandle {
    Box::into_raw(Box::new(ElarniHandle {
        cancelled: AtomicBool::new(false),
    }))
}

/// # Safety
/// `handle` must be null or a pointer returned by `elarni_handle_new` that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_handle_free(handle: *mut ElarniHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// # Safety
/// `handle` must point to a live Elarni handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_cancel(handle: *mut ElarniHandle) -> ElarniStatus {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ELARNI_STATUS_INVALID_ARGUMENT;
    };
    handle.cancelled.store(true, Ordering::Release);
    ELARNI_STATUS_OK
}

/// # Safety
/// `buffer` must be null or point to a buffer returned by this library and not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_buffer_free(buffer: ElarniBuffer) {
    if !buffer.data.is_null() && buffer.capacity >= buffer.len {
        drop(unsafe { Vec::from_raw_parts(buffer.data, buffer.len, buffer.capacity) });
    }
}

/// # Safety
/// `handle` and `output` must be live writable pointers. `request` must point to `request_len`
/// readable bytes for this call. Input and output memory must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_request(
    handle: *mut ElarniHandle,
    request: *const u8,
    request_len: usize,
    output: *mut ElarniBuffer,
) -> ElarniStatus {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ELARNI_STATUS_INVALID_ARGUMENT;
    };
    let Some(output) = (unsafe { output.as_mut() }) else {
        return ELARNI_STATUS_INVALID_ARGUMENT;
    };
    *output = ElarniBuffer::default();
    if request.is_null() || request_len == 0 {
        return ELARNI_STATUS_INVALID_ARGUMENT;
    }
    if request_len > MAX_REQUEST_BYTES {
        return ELARNI_STATUS_REQUEST_TOO_LARGE;
    }
    if handle.cancelled.swap(false, Ordering::AcqRel) {
        return ELARNI_STATUS_CANCELLED;
    }

    let request = unsafe { slice::from_raw_parts(request, request_len) };
    let result = catch_unwind(AssertUnwindSafe(|| execute(request)));
    let (status, response) = match result {
        Ok(value) => value,
        Err(_) => (
            ELARNI_STATUS_PANIC,
            json!({"error": "internal panic contained"}),
        ),
    };
    let Ok(mut bytes) = serde_json::to_vec(&response) else {
        return ELARNI_STATUS_PANIC;
    };
    if bytes.len() > MAX_RESPONSE_BYTES {
        return ELARNI_STATUS_RESPONSE_TOO_LARGE;
    }
    output.data = bytes.as_mut_ptr();
    output.len = bytes.len();
    output.capacity = bytes.capacity();
    std::mem::forget(bytes);
    status
}

fn execute(request: &[u8]) -> (ElarniStatus, Value) {
    let envelope: RequestEnvelope = match serde_json::from_slice(request) {
        Ok(envelope) => envelope,
        Err(_) => {
            return (
                ELARNI_STATUS_INVALID_ARGUMENT,
                json!({"error": "invalid request envelope"}),
            );
        }
    };
    if !(ELARNI_SCHEMA_MIN..=ELARNI_SCHEMA_MAX).contains(&envelope.schema_version) {
        return (
            ELARNI_STATUS_UNSUPPORTED_VERSION,
            json!({
                "error": "unsupported schema version",
                "schemaMin": ELARNI_SCHEMA_MIN,
                "schemaMax": ELARNI_SCHEMA_MAX
            }),
        );
    }
    match envelope.operation.as_str() {
        "catalogIdentity" => (
            ELARNI_STATUS_OK,
            json!({"identity": crate::catalog::node_identity(envelope.payload).to_string()}),
        ),
        "keepShortIds" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                previous: Value,
                config: Value,
            }
            let Ok(payload) = serde_json::from_value::<Payload>(envelope.payload) else {
                return (
                    ELARNI_STATUS_INVALID_ARGUMENT,
                    json!({"error": "invalid short id payload"}),
                );
            };
            (
                ELARNI_STATUS_OK,
                json!({"config": crate::catalog::keep_short_ids(&payload.previous, payload.config)}),
            )
        }
        "profileEndpoints" | "prepareConfig" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                config: Value,
                #[serde(default)]
                resolved: std::collections::BTreeMap<String, String>,
                #[serde(default)]
                unavailable: std::collections::BTreeSet<String>,
                #[serde(default)]
                pin: bool,
                #[serde(default, rename = "pinHosts")]
                pin_hosts: std::collections::BTreeSet<String>,
            }
            let Ok(payload) = serde_json::from_value::<Payload>(envelope.payload) else {
                return (
                    ELARNI_STATUS_INVALID_ARGUMENT,
                    json!({"error": "invalid endpoint payload"}),
                );
            };
            if envelope.operation == "profileEndpoints" {
                match crate::profile::profile_endpoints(&payload.config) {
                    Ok(endpoints) => (
                        ELARNI_STATUS_OK,
                        json!({"schemaVersion": 1, "endpoints": endpoints}),
                    ),
                    Err(error) => (
                        ELARNI_STATUS_COMPILE_ERROR,
                        json!({"error": error.to_string()}),
                    ),
                }
            } else {
                match crate::profile::prepare_config(
                    payload.config,
                    &payload.resolved,
                    &payload.unavailable,
                    payload.pin,
                    &payload.pin_hosts,
                ) {
                    Ok(config) => (
                        ELARNI_STATUS_OK,
                        json!({"schemaVersion": 1, "config": config}),
                    ),
                    Err(error) => (
                        ELARNI_STATUS_COMPILE_ERROR,
                        json!({"error": error.to_string()}),
                    ),
                }
            }
        }
        "parseManagedDomains" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct Payload {
                text: String,
                match_mode: crate::routing::ManagedMatchMode,
            }
            let Ok(payload) = serde_json::from_value::<Payload>(envelope.payload) else {
                return (
                    ELARNI_STATUS_INVALID_ARGUMENT,
                    json!({"code":"invalidPayload"}),
                );
            };
            match crate::routing::parse_managed_domains(&payload.text, payload.match_mode) {
                Ok(domains) => (
                    ELARNI_STATUS_OK,
                    json!({"schemaVersion":1, "domains":domains}),
                ),
                Err(_) => (
                    ELARNI_STATUS_PARSE_ERROR,
                    json!({"code":"invalidManagedDomains"}),
                ),
            }
        }
        "mergeManagedRouting" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                profile: crate::routing::HappRoutingProfile,
                lists: std::collections::BTreeMap<String, Vec<String>>,
            }
            let Ok(payload) = serde_json::from_value::<Payload>(envelope.payload) else {
                return (
                    ELARNI_STATUS_INVALID_ARGUMENT,
                    json!({"code":"invalidPayload"}),
                );
            };
            match crate::routing::merge_managed_routing(&payload.profile, &payload.lists) {
                Ok(routes) => (
                    ELARNI_STATUS_OK,
                    json!({"schemaVersion":1, "routeModel":routes}),
                ),
                Err(_) => (
                    ELARNI_STATUS_PARSE_ERROR,
                    json!({"code":"invalidManagedRouting"}),
                ),
            }
        }
        "decodeRouting" => {
            let payload: RoutingRequest = match serde_json::from_value(envelope.payload) {
                Ok(payload) => payload,
                Err(_) => {
                    return (
                        ELARNI_STATUS_INVALID_ARGUMENT,
                        json!({"code": "invalidPayload", "error": "invalid routing payload"}),
                    );
                }
            };
            match decode_routing(&payload.content) {
                Ok(import) => (
                    ELARNI_STATUS_OK,
                    json!({"schemaVersion": 1, "import": import}),
                ),
                Err(error) => (
                    ELARNI_STATUS_PARSE_ERROR,
                    json!({"code": "invalidRouting", "error": error.to_string()}),
                ),
            }
        }
        "decodeBase64Text" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                text: String,
            }
            let Ok(payload) = serde_json::from_value::<Payload>(envelope.payload) else {
                return (
                    ELARNI_STATUS_INVALID_ARGUMENT,
                    json!({"code":"invalidPayload"}),
                );
            };
            match crate::routing::decode_base64_text(&payload.text) {
                Some(text) => (ELARNI_STATUS_OK, json!({"schemaVersion":1, "text":text})),
                None => (ELARNI_STATUS_PARSE_ERROR, json!({"code":"invalidBase64"})),
            }
        }
        "compileHy2Uri" => {
            let payload: CompileUriRequest = match serde_json::from_value(envelope.payload) {
                Ok(payload) => payload,
                Err(_) => {
                    return (
                        ELARNI_STATUS_INVALID_ARGUMENT,
                        json!({"error": "invalid compile URI payload"}),
                    );
                }
            };
            let parsed = match parse_hy2_uri(
                &payload.uri,
                payload.authentication_ref,
                payload.obfuscation_ref,
            ) {
                Ok(parsed) => parsed,
                Err(error) => {
                    return (
                        ELARNI_STATUS_PARSE_ERROR,
                        json!({"error": error.to_string()}),
                    );
                }
            };
            let endpoint_host = parsed.endpoint.host.clone();
            let authentication_ref = parsed.endpoint.secret_ref.clone();
            let obfuscation_password = parsed.obfuscation_password.map(|value| SecretMaterial {
                secret_ref: parsed
                    .endpoint
                    .obfuscation
                    .as_ref()
                    .expect("parser requires obfuscation metadata")
                    .password_ref
                    .clone(),
                value,
            });
            let request = CompileRequest {
                endpoint: parsed.endpoint,
                authentication: SecretMaterial {
                    secret_ref: authentication_ref,
                    value: parsed.authentication,
                },
                obfuscation_password,
                routes: payload.routes,
                socks_port: payload.socks_port,
                packet_backend: payload.packet_backend,
                tun_mtu: payload.tun_mtu,
                runtime: payload.runtime,
            };
            match compile_xray_config(&request) {
                Ok(config) => (
                    ELARNI_STATUS_OK,
                    json!({
                        "schemaVersion": 1,
                        "configUtf8": String::from_utf8_lossy(&config),
                        "endpointHost": endpoint_host
                    }),
                ),
                Err(error) => (
                    ELARNI_STATUS_COMPILE_ERROR,
                    json!({"error": error.to_string()}),
                ),
            }
        }
        "compileProfile" => {
            let Ok(payload) = serde_json::from_value::<CompileProfileRequest>(envelope.payload)
            else {
                return (
                    ELARNI_STATUS_INVALID_ARGUMENT,
                    json!({"error": "invalid profile compile payload"}),
                );
            };
            match crate::profile::compile_profile(
                payload.profile,
                payload.routes.as_ref(),
                payload.socks_port,
                payload.packet_backend,
                payload.tun_mtu,
                &payload.runtime,
                payload.preferred_ip,
            ) {
                Ok(result) => (
                    ELARNI_STATUS_OK,
                    json!({
                        "schemaVersion": 1, "configUtf8": String::from_utf8_lossy(&result.config),
                        "endpoints": result.endpoints,
                    }),
                ),
                Err(error) => (
                    ELARNI_STATUS_COMPILE_ERROR,
                    json!({"error": error.to_string()}),
                ),
            }
        }
        "compileOutbound" => {
            let payload: CompileOutboundRequest = match serde_json::from_value(envelope.payload) {
                Ok(payload) => payload,
                Err(_) => {
                    return (
                        ELARNI_STATUS_INVALID_ARGUMENT,
                        json!({"error": "invalid outbound compile payload"}),
                    );
                }
            };
            match compile_xray_outbound_config_with_options(
                payload.outbound,
                &payload.routes,
                payload.socks_port,
                payload.packet_backend,
                payload.tun_mtu,
                &payload.runtime,
            ) {
                Ok((config, endpoint_host)) => (
                    ELARNI_STATUS_OK,
                    json!({
                        "schemaVersion": 1,
                        "configUtf8": String::from_utf8_lossy(&config),
                        "endpointHost": endpoint_host
                    }),
                ),
                Err(error) => (
                    ELARNI_STATUS_COMPILE_ERROR,
                    json!({"error": error.to_string()}),
                ),
            }
        }
        _ => (
            ELARNI_STATUS_INVALID_ARGUMENT,
            json!({"error": "unknown operation"}),
        ),
    }
}
