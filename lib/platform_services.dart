// The desktop controller also runs in a standalone Dart process without Flutter.
export 'src/headless_services.dart'
    if (dart.library.ui) 'package:flutter/services.dart';
