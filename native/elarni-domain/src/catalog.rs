//! Server identity of the same configurations consumed by the compiler.
use serde_json::{Value, json};

/// Display metadata is not server identity. Everything below the profile root
/// remains significant (including group names, credentials and bind addresses).
pub fn identity(mut config: Value) -> Value {
    if let Some(root) = config.as_object_mut() {
        root.remove("name");
        root.remove("remarks");
    }
    config
}

pub fn node_identity(config: Value) -> Value {
    let mut config = identity(config);
    if config.get("protocol").is_some() {
        config = json!({"outbounds": [config]});
    }
    if let Some(groups) = config.get_mut("elarniGroups").and_then(Value::as_array_mut) {
        for group in groups {
            if let Some(group) = group.as_object_mut() {
                group.remove("selected");
            }
        }
    }
    if config.as_object().is_some_and(|root| root.len() == 1)
        && let Some(members) = config.get_mut("outbounds").and_then(Value::as_array_mut)
        && members.len() == 1
        && let Some(member) = members[0].as_object_mut()
    {
        // A wrapped bare outbound keeps its display metadata on the member.
        for field in ["tag", "name", "remarks"] {
            member.remove(field);
        }
    }
    config
}

/// Panels such as 3x-ui send one of a REALITY server's valid shortIds at random
/// on each fetch. A refreshed config that differs from the stored one only there
/// (display metadata aside) keeps the stored shortIds, so the refresh leaves the
/// running tunnel alone; any other change returns `config` as it came.
pub fn keep_short_ids(previous: &Value, config: Value) -> Value {
    let mut kept = config.clone();
    adopt_short_ids(&mut kept, previous);
    if identity(kept.clone()) == identity(previous.clone()) {
        kept
    } else {
        config
    }
}

fn adopt_short_ids(config: &mut Value, previous: &Value) {
    match (config, previous) {
        (Value::Object(config), Value::Object(previous)) => {
            for (key, value) in config.iter_mut() {
                if let Some(old) = previous.get(key) {
                    adopt_short_ids(value, old);
                }
            }
            if let (Some(Value::Object(reality)), Some(Value::Object(old))) = (
                config.get_mut("realitySettings"),
                previous.get("realitySettings"),
            ) {
                match old.get("shortId") {
                    Some(id) => reality.insert("shortId".into(), id.clone()),
                    None => reality.remove("shortId"),
                };
            }
        }
        (Value::Array(config), Value::Array(previous)) => {
            for (value, old) in config.iter_mut().zip(previous) {
                adopt_short_ids(value, old);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_refresh_that_only_rotates_the_reality_short_id_keeps_the_stored_one() {
        // As a 3x-ui JSON subscription sends it.
        let server = |short_id: &str| {
            json!({"remarks":"NL","outbounds":[
                {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"nl.example.com","port":443,
                    "users":[{"id":"00000000-0000-4000-8000-000000000001","encryption":"none"}]}]},
                 "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
                    "serverName":"example.com","publicKey":"key-1","shortId":short_id,"fingerprint":"chrome"}}},
                {"tag":"direct","protocol":"freedom"}]})
        };
        let stored = server("0a1b");
        assert_eq!(keep_short_ids(&stored, server("c2d3")), stored);
        // Display metadata follows the provider; the shortId stays.
        let mut renamed = server("c2d3");
        renamed["remarks"] = json!("NL 2 GB left");
        let mut expected = stored.clone();
        expected["remarks"] = json!("NL 2 GB left");
        assert_eq!(keep_short_ids(&stored, renamed), expected);
        let mut bare = server("");
        bare["outbounds"][0]["streamSettings"]["realitySettings"]
            .as_object_mut()
            .unwrap()
            .remove("shortId");
        assert_eq!(keep_short_ids(&bare, server("c2d3")), bare);
        // Any other change takes the new values, shortId included.
        for (pointer, value) in [
            (
                "/outbounds/0/settings/vnext/0/address",
                json!("de.example.com"),
            ),
            ("/outbounds/0/settings/vnext/0/port", json!(8443)),
            (
                "/outbounds/0/settings/vnext/0/users/0/id",
                json!("00000000-0000-4000-8000-000000000002"),
            ),
            (
                "/outbounds/0/streamSettings/realitySettings/publicKey",
                json!("key-2"),
            ),
            (
                "/outbounds/0/streamSettings/realitySettings/serverName",
                json!("example.org"),
            ),
        ] {
            let mut changed = server("c2d3");
            *changed.pointer_mut(pointer).unwrap() = value;
            assert_eq!(
                keep_short_ids(&stored, changed.clone()),
                changed,
                "{pointer}"
            );
        }
    }

    #[test]
    fn identity_preserves_nested_semantics_and_ignores_only_display_metadata() {
        assert_eq!(
            identity(json!({"name":"A","outbounds":[]})),
            identity(json!({"remarks":"B","outbounds":[]}))
        );
        assert_ne!(
            identity(json!({"groups":[{"name":"A"}]})),
            identity(json!({"groups":[{"name":"B"}]}))
        );
        assert_ne!(
            identity(json!({"sendThrough":"a"})),
            identity(json!({"sendThrough":"b"}))
        );
    }

    #[test]
    fn stable_matching_tolerates_single_outbound_wrapping_and_preserves_binding() {
        let outbound = json!({"tag":"display","protocol":"vless","settings":{"id":"secret"}});
        assert_eq!(
            node_identity(outbound.clone()),
            node_identity(json!({"remarks":"Renamed","outbounds":[outbound.clone()]}))
        );
        let mut rebound = outbound.clone();
        rebound["sendThrough"] = json!("192.0.2.1");
        assert_ne!(node_identity(outbound), node_identity(rebound));
    }

    // The importer wraps a bare outbound and keeps its remarks as the name.
    #[test]
    fn renaming_a_wrapped_single_outbound_keeps_its_identity() {
        let named =
            |name: &str| json!({"remarks":name,"protocol":"vless","settings":{"id":"secret"}});
        assert_eq!(
            node_identity(json!({"outbounds":[named("Server A")]})),
            node_identity(json!({"outbounds":[named("Server B")]}))
        );
        assert_eq!(
            node_identity(named("Server A")),
            node_identity(json!({"outbounds":[named("Server A")]}))
        );
    }
}
