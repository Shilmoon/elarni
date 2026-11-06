# Subscription providers

Elarni fetches subscriptions with the User-Agent `Elarni/<version> (Xray; <OS>)`,
where the OS is `Windows`, `macOS`, `Linux`, `Android` or `iOS`, for example
`Elarni/0.5.0 (Xray; Android)`. It also sends `X-Device-OS`. Panel rules that
pick a response by client, such as Remnawave response rules, can match the
`Elarni/` prefix. A subscription's User agent setting replaces the header.

Elarni applies Happ-style routing from the `Routing` header and from routing
lines in the body. When a response carries `elarni://routing/` links, only those
apply and `happ://` or `incy://` links are ignored, so one response can carry
routing for Happ and for Elarni side by side. Some panels, such as 3x-ui, send
their Happ routing to every client.
