# Security policy

## Supported versions

Security fixes go into the latest release. Update to it before reporting.

## Reporting a vulnerability

Do not open a public issue. Report privately through GitHub:
[report a vulnerability](https://github.com/Shilmoon/elarni/security/advisories/new)
(the repository's **Security** tab, then **Advisories**). Include the
affected platform and version, steps to reproduce, and the impact you observed.
The report stays private until a fix is released.

Elarni has one maintainer: expect a first reply within a week, on a best-effort
basis. Reproduce the problem yourself before reporting; unverified tool output
is closed without a fix.

Examples of what to report:

- traffic, DNS or IPv6 leaking outside the tunnel when the app reports it as connected
- exposure of stored profiles, subscription URLs, keys or credentials
- local-control endpoints reachable by other users or processes
- code execution or file writes from a crafted link, subscription or configuration

Problems in upstream Xray-core, tun2proxy or other dependencies that also
affect their own releases should go to those projects as well.
