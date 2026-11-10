import Foundation
import NetworkExtension

enum TunnelSettingsFactory {
  /// LAN discovery (multicast, the limited broadcast) reaches no device through the tunnel, so it
  /// stays on the physical network unless Block traffic without VPN keeps everything inside.
  static let discoveryRoutes = ["224.0.0.0/4", "255.255.255.255/32", "ff00::/8"]
  /// The tunnel's own address ranges, as `make` sets them: a connection from them runs through it.
  static let tunnelPrefixes = ["192.0.2.0/30", "2001:db8::/126"]

  static func make(plan: TunnelPlan, excludedEndpointAddresses: [String], keepDiscovery: Bool = false) throws -> NEPacketTunnelNetworkSettings {
    guard !excludedEndpointAddresses.isEmpty || plan.outboundFormat == .xrayProfile else { throw SettingsError.missingEndpointExclusion }
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")
    settings.mtu = NSNumber(value: plan.mtu)
    let runtime = plan.runtimeSettings
    let discovery = keepDiscovery ? [] : discoveryRoutes

    let ipv4 = NEIPv4Settings(addresses: ["192.0.2.2"], subnetMasks: ["255.255.255.252"])
    ipv4.includedRoutes = runtime.includedRoutes.compactMap(ipv4Route)
    let ipv4Exclusions = excludedEndpointAddresses + runtime.excludedRoutes +
      (runtime.hideVPNIcon ? ["0.0.0.0/8"] : []) + discovery
    ipv4.excludedRoutes = ipv4Exclusions.compactMap { address in
      if address.contains("/") { return ipv4Route(address) }
      guard address.contains(".") else { return nil }
      return NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255")
    }
    // Preferred IP only picks the server address family; routing both families
    // keeps the other one from leaking around the tunnel.
    settings.ipv4Settings = ipv4

    let ipv6 = NEIPv6Settings(addresses: ["2001:db8::2"], networkPrefixLengths: [126])
    ipv6.includedRoutes = runtime.includedRoutes.compactMap(ipv6Route)
    let ipv6Exclusions = excludedEndpointAddresses + runtime.excludedRoutes +
      (runtime.hideVPNIcon ? ["::/128"] : []) + discovery
    ipv6.excludedRoutes = ipv6Exclusions.compactMap { address in
      if address.contains("/") { return ipv6Route(address) }
      guard address.contains(":") else { return nil }
      return NEIPv6Route(destinationAddress: address, networkPrefixLength: 128)
    }
    settings.ipv6Settings = ipv6

    let dns = NEDNSSettings(servers: plan.dnsServers)
    dns.matchDomains = [""]
    settings.dnsSettings = dns
    return settings
  }

  static func endpointAddresses(_ candidates: [String], strategy: String, preferredIP: String) -> [String] {
    let ipv4 = candidates.filter { !$0.contains(":") }
    let ipv6 = candidates.filter { $0.contains(":") }
    if preferredIP == "ipv4" { return ipv4 }
    if preferredIP == "ipv6" { return ipv6 }
    switch strategy.lowercased() {
    case "forceipv4": return ipv4
    case "forceipv6": return ipv6
    case "useipv4": return ipv4.isEmpty ? candidates : ipv4
    case "useipv6": return ipv6.isEmpty ? candidates : ipv6
    case "useipv4v6", "forceipv4v6": return ipv4 + ipv6
    case "useipv6v4", "forceipv6v4": return ipv6 + ipv4
    default: return candidates
    }
  }

  private static func ipv4Route(_ cidr: String) -> NEIPv4Route? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, parts[0].contains("."),
          let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
    let mask = (0..<4).map { byte -> String in
      let bits = min(8, max(0, prefix - byte * 8))
      return String(bits == 0 ? 0 : 256 - (1 << (8 - bits)))
    }.joined(separator: ".")
    return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: mask)
  }

  private static func ipv6Route(_ cidr: String) -> NEIPv6Route? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, parts[0].contains(":"),
          let prefix = Int(parts[1]), (0...128).contains(prefix) else { return nil }
    return NEIPv6Route(destinationAddress: String(parts[0]), networkPrefixLength: NSNumber(value: prefix))
  }
}

enum SettingsError: Error { case missingEndpointExclusion }
