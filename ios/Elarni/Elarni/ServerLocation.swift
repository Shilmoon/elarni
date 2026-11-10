import Foundation

/// A provider's label, never measured server geolocation.
struct ServerLocation: Hashable {
  let code: String
  let name: String
  var flag: String { String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar($0.value - 65 + 0x1F1E6) })) }
  static func displayName(_ name: String) -> String {
    guard fromName(name) != nil else { return name }
    let cleaned = name.replacingOccurrences(of: "[\\x{1F1E6}-\\x{1F1FF}]{2}", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? fromName(name)!.name : cleaned
  }
  private final class Cached: NSObject {
    let location: ServerLocation?
    init(_ location: ServerLocation?) { self.location = location }
  }
  private static let cache: NSCache<NSString, Cached> = {
    let cache = NSCache<NSString, Cached>(); cache.countLimit = 4096; return cache
  }()
  // EU is a CLDR grouping, not an ISO region, but providers label servers with its flag.
  private static let codes = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }).union(["EU"])
  private static let names: [(String, String)] = codes.flatMap { code in
    [Locale(identifier: "en"), Locale(identifier: "ru")].compactMap { locale in
      locale.localizedString(forRegionCode: code).map { ($0, code) }
    }
  } + [("Евросоюз", "EU"), ("UK", "GB"), ("UAE", "AE"), ("ОАЭ", "AE")]
  // The desktop's abbreviations, which the region list lacks.
  private static let aliases = ["UK": "GB", "UAE": "AE"]
  // US places whose names contain a country or territory name, as on the desktop.
  private static let places = try! NSRegularExpression(
    pattern: "(?<![\\p{L}\\p{N}])(?:new jersey|jersey city|new mexico|нью-джерси|нью-мексико)(?![\\p{L}\\p{N}])", options: .caseInsensitive)
  private static let expressions: [(NSRegularExpression, String)] = names.compactMap { name, code in
    let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
    return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { ($0, code) }
  }
  // One pass that finds whether any name occurs: most server names hold none, and then the patterns above need not run.
  private static let anyName = try? NSRegularExpression(
    pattern: "(?<![\\p{L}\\p{N}])(?:" + names.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|") + ")(?![\\p{L}\\p{N}])",
    options: .caseInsensitive)
  private static let labelCache: NSCache<NSString, NSSet> = {
    let cache = NSCache<NSString, NSSet>(); cache.countLimit = 4096; return cache
  }()
  /// An ISO country code, such as the exit country a trace reports.
  static func fromCode(_ code: String) -> ServerLocation? {
    codes.contains(code) ? ServerLocation(code: code, name: Locale.current.localizedString(forRegionCode: code) ?? code) : nil
  }
  static func fromName(_ name: String) -> ServerLocation? {
    if let saved = cache.object(forKey: name as NSString) { return saved.location }
    let location = parse(name)
    cache.setObject(Cached(location), forKey: name as NSString)
    return location
  }
  /// A Russian label anywhere, a chain's entry included.
  static func russianEntry(_ name: String) -> Bool { labels(name).contains("RU") }
  private static func parse(_ name: String) -> ServerLocation? {
    let found = labels(name)
    guard found.count == 1, let code = found.first else { return nil }
    return ServerLocation(code: code, name: Locale.current.localizedString(forRegionCode: code) ?? code)
  }
  private static func labels(_ name: String) -> Set<String> {
    if let saved = labelCache.object(forKey: name as NSString) as? Set<String> { return saved }
    let found = readLabels(name)
    labelCache.setObject(found as NSSet, forKey: name as NSString)
    return found
  }
  private static func readLabels(_ name: String) -> Set<String> {
    var found = Set<String>()
    let scalars = Array(name.unicodeScalars)
    if scalars.count > 1 {
      for index in 0..<(scalars.count - 1) where (0x1F1E6...0x1F1FF).contains(scalars[index].value) && (0x1F1E6...0x1F1FF).contains(scalars[index + 1].value) {
        let code = String(UnicodeScalar(scalars[index].value - 0x1F1E6 + 65)!) + String(UnicodeScalar(scalars[index + 1].value - 0x1F1E6 + 65)!)
        if codes.contains(code) { found.insert(code) }
      }
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = trimmed.range(of: "^(?:\\[|\\()?([A-Z]{2,3})(?=$|[\\s\\]\\)\\-_|•])", options: .regularExpression) {
      let label = String(trimmed[range]).trimmingCharacters(in: CharacterSet(charactersIn: "[("))
      let code = aliases[label] ?? label
      // CF labels Cloudflare in provider names, not the Central African Republic.
      if code != "CF", codes.contains(code) { found.insert(code) }
      else if code.count == 3, let label = Locale(identifier: "en").localizedString(forRegionCode: code) {
        // Foundation recognizes ISO alpha-3 labels. Resolve their English
        // region name to the same alpha-2 identifiers used for native flags.
        found.formUnion(codes.filter { Locale(identifier: "en").localizedString(forRegionCode: $0) == label })
      }
    }
    let unplaced = places.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name), withTemplate: " ")
    let range = NSRange(unplaced.startIndex..<unplaced.endIndex, in: unplaced)
    if anyName?.firstMatch(in: unplaced, range: range) != nil || anyName == nil {
      for (regex, code) in expressions where regex.firstMatch(in: unplaced, range: range) != nil { found.insert(code) }
    }
    // The EU flag often accompanies a member country, which is more specific.
    if found.count > 1 { found.remove("EU") }
    return found
  }
}
