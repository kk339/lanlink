/// Optional override for the SQLite native library.
///
/// On **Android** the app needs `sqlite3_flutter_libs`, which bundles a
/// `libsqlite3.so`; `package:sqlite3` 2.x cannot load a system one there, so
/// without that plugin opening the database throws.
///
/// That same plugin also declares a **Windows** platform, where it ships a
/// `sqlite3.dll` next to the executable — and `package:sqlite3` 2.x prefers
/// `sqlite3.dll` over the system `winsqlite3.dll`. Left alone, adding it for
/// Android would silently switch the desktop provider. So [configureSqlite]
/// **pins Windows back to the system `winsqlite3.dll` by default**, keeping the
/// desktop path exactly what it is today. Pass a non-null [windowsDllPath] only
/// to force a different library.
library;

import 'dart:ffi';

import 'package:sqlite3/open.dart';

/// The Windows SQLite DLL used today — pinned so it stays that way.
const String _windowsSystemDll = 'winsqlite3.dll';

/// Pins the SQLite library used on Windows to [windowsDllPath].
///
/// Defaults to the system `winsqlite3.dll`, so adding `sqlite3_flutter_libs`
/// (for Android) cannot change the Windows provider. Only Windows is affected;
/// on every other OS this does nothing.
void configureSqlite({String? windowsDllPath = _windowsSystemDll}) {
  if (windowsDllPath == null) {
    return;
  }
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(windowsDllPath),
  );
}
