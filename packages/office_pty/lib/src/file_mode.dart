import 'dart:io';

import 'package:ffi/ffi.dart';

import 'native.dart' as c;

/// Sets a file's permission bits (dart:io can't): `chmodSync(path, 0x180)` is `chmod 600`. False
/// when it couldn't (and always on Windows, which has no such bits).
bool chmodSync(String path, int mode) {
  if (Platform.isWindows) return false;
  return using((arena) => c.chmod(path.toNativeUtf8(allocator: arena), mode) == 0);
}
