// check-core links no libXray, so boundary markers have no recorder to reach.
enum DiagnosticLog {
  static func record(_ kind: String, _ values: [String: Int64] = [:]) {}
}
