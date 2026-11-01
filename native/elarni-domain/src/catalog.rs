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

#[cfg(test)]
mod tests {
    use super::*;

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
