import 'package:flutter/foundation.dart';

/// Dead-simple tagged logger. Nova has no UI to surface errors in, so keeping
/// log lines consistent matters for adb-side debugging.
class NovaLog {
  const NovaLog();

  void d(Object? msg) => _emit('D', msg);
  void i(Object? msg) => _emit('I', msg);
  void w(Object? msg) => _emit('W', msg);
  void e(Object? msg, [Object? error, StackTrace? stack]) {
    _emit('E', msg);
    if (error != null) _emit('E', error);
    if (stack != null) _emit('E', stack);
  }

  void _emit(String level, Object? msg) {
    if (kReleaseMode && level == 'D') return;
    debugPrint('[nova/$level] $msg');
  }
}

const NovaLog log = NovaLog();
