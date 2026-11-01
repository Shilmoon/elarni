import Darwin
import Foundation

struct UtunDescriptorCandidate: Equatable {
  let descriptor: Int32
  let interfaceName: String
}

enum UtunDescriptorResolverError: Error {
  case unavailable
  case ambiguous
}

enum UtunDescriptorResolver {
  private static let scanLimit: rlim_t = 16_384

  static func candidates() -> [UtunDescriptorCandidate] {
#if os(iOS)
    // iOS uses the public NEPacketTunnelFlow bridge, never borrowed descriptors.
    return []
#else
    var limits = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return [] }
    let upperBound = Int(min(limits.rlim_cur, scanLimit))
    return (0..<upperBound).compactMap { candidate(descriptor: Int32($0)) }
#endif
  }

  static func resolve() throws -> UtunDescriptorCandidate {
    let matches = candidates()
    guard !matches.isEmpty else { throw UtunDescriptorResolverError.unavailable }
    guard matches.count == 1 else { throw UtunDescriptorResolverError.ambiguous }
    return matches[0]
  }

  private static func candidate(descriptor: Int32) -> UtunDescriptorCandidate? {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFSOCK else { return nil }

    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    var length = socklen_t(name.count)
    let status = name.withUnsafeMutableBytes { buffer in
      getsockopt(descriptor, 2, 2, buffer.baseAddress, &length)
    }
    guard status == 0, length > 0, length <= name.count else { return nil }
    let interfaceName = String(cString: name)
    let suffix = interfaceName.dropFirst(4)
    guard interfaceName.hasPrefix("utun"), !suffix.isEmpty,
          suffix.allSatisfy(\.isNumber) else { return nil }
    return UtunDescriptorCandidate(
      descriptor: descriptor,
      interfaceName: interfaceName
    )
  }
}
