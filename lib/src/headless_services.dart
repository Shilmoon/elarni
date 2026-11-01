// Flutter's wire error shape is retained at the controller boundary. A headless
// caller supplies platformIO; native window channels are unavailable here.
class PlatformException implements Exception {
  PlatformException({
    required this.code,
    this.message,
    this.details,
    this.stacktrace,
  });
  final String code;
  final String? message;
  final dynamic details;
  final String? stacktrace;
  @override
  String toString() => 'PlatformException($code)';
}

class MethodCall {
  const MethodCall(this.method, [this.arguments]);
  final String method;
  final dynamic arguments;
}

class MethodChannel {
  const MethodChannel(this.name);
  final String name;
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async =>
      throw UnsupportedError('Native desktop channel unavailable: $method');
  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    dynamic arguments,
  ]) async =>
      throw UnsupportedError('Native desktop channel unavailable: $method');
  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? handler) {
    if (handler != null)
      throw UnsupportedError('Native desktop channel unavailable');
  }
}
