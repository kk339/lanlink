/// The settings controller (spec §4.4 / §4.6).
///
/// Owns the three V1 settings (device name / save directory / receive mode) and
/// their persistence, plus the cross-port alias change of §4.6. A write that
/// fails surfaces an error in place — it never silently falls back (§4.4).
///
/// Layering (spec §8.1): imports only `dart:async`, `package:flutter/foundation`
/// and this package's `domain/**`.
library;

import 'package:flutter/foundation.dart';

import '../domain/async_value.dart';
import '../domain/downloads_folder.dart' show normalizeDownloadsSubdirectory;
import '../domain/models.dart';
import '../domain/peer_discovery.dart';
import '../domain/platform_ports.dart';
import '../domain/transfer_service.dart';

/// Drives the settings page and the receive-mode toggle.
class SettingsController extends ChangeNotifier {
  /// Wires the controller to the three ports it touches.
  SettingsController({
    required PlatformPorts platform,
    required PeerDiscovery discovery,
    required TransferService transfer,
  })  : _platform = platform,
        _discovery = discovery,
        _transfer = transfer;

  final PlatformPorts _platform;
  final PeerDiscovery _discovery;
  final TransferService _transfer;

  bool _disposed = false;
  AsyncValue<AppSettings> _settings = const Loading<AppSettings>();
  String? _error;

  /// The persisted settings, `Loading` until [load] resolves.
  AsyncValue<AppSettings> get settings => _settings;

  /// Whether the persisted settings have loaded.
  ///
  /// Gates the receive-mode write entry and lets the UI disable the switch
  /// **honestly** while loading: writing before the load would `copyWith` on the
  /// empty fallback ([_current]) and clobber `alias` / `saveDirectory` — and an
  /// empty save directory means received files have nowhere to land.
  bool get ready => _settings.valueOrNull != null;

  /// Whether the receiver accepts uploads (single source: [TransferService]).
  bool get accepting => _transfer.accepting;

  /// The last localised error, or `null` (cleared on the next success).
  String? get error => _error;

  /// Loads the settings from the platform port.
  Future<void> load() async {
    try {
      _settings = Data<AppSettings>(await _platform.loadSettings());
    } catch (error) {
      _settings = Failure<AppSettings>(error);
    }
    _notify();
  }

  /// P1-1 / §4.6: change the device name across **both** ports, then persist.
  ///
  /// The certificate directory is alias-independent (§8.2), so this does not
  /// change the fingerprint. A failure on either port or on the save is
  /// surfaced, not swallowed.
  Future<void> applyAlias(String alias) async {
    try {
      await _discovery.setAlias(alias);
      await _transfer.setAlias(alias);
      await _persist(_current.copyWith(alias: alias));
    } catch (error) {
      _fail('改名失败：$error');
      return;
    }
    _succeed();
  }

  /// Changes the received-files directory: **apply it to the running receiver
  /// first, then persist it** (0.2.23).
  ///
  /// The order is the whole fix. Until 0.2.23 this only called `_persist`, so
  /// the settings page showed the new path while `LanTransferService` kept
  /// writing to the one it had captured at construction — a restart was
  /// required, and nothing said so.
  ///
  /// Applying first also makes the failure honest: when the transport refuses
  /// the directory (not writable, not creatable), the exception travels to the
  /// error banner and **nothing is persisted**, so the stored setting and the
  /// receiver stay in agreement (both still the old directory). Persisting first
  /// and applying second is exactly how the UI ends up showing a path that is
  /// not the one in effect.
  Future<void> setSaveDirectory(String directory) async {
    if (!ready) {
      // Writing now would `copyWith` on the empty fallback and blank the alias.
      // The UI does not offer the editor before the load resolves, so this is
      // defence in depth (same rule as [setAccepting]).
      return;
    }
    final String previous = _current.saveDirectory;
    try {
      await _transfer.setSaveDirectory(directory);
    } on SaveDirectoryException catch (error) {
      _fail('保存位置没有改：${error.reason}');
      return;
    } catch (error) {
      _fail('保存位置没有改：$error');
      return;
    }
    try {
      await _persist(_current.copyWith(saveDirectory: directory));
    } catch (error) {
      // The receiver has already moved, so leaving it there while the stored
      // setting says otherwise is the very defect this method exists to remove
      // — in the other direction. Put the receiver back (best effort) and say
      // plainly what happened.
      try {
        await _transfer.setSaveDirectory(previous);
      } on Object {
        _fail('保存位置保存失败：$error'
            '（而且没能切回原来的目录，请重新选一次）');
        return;
      }
      _fail('保存位置保存失败：$error');
      return;
    }
    _succeed();
  }

  /// 0.2.29: the folder inside `Download` that received files land in.
  ///
  /// Nothing is *applied* to a running object the way [setSaveDirectory] has to
  /// re-open the receiver: the publish step reads
  /// `PlatformPorts.receivedSubdirectory`, which this save refreshes (that field
  /// is updated by `SystemPlatformPorts.saveSettings` **after** a successful
  /// write). So the whole operation is "persist, then adopt" — and a failed write
  /// leaves both the document and the live folder on the old value, which is what
  /// makes the UI's 「设置不变」 promise in [SettingsBody] true rather than hopeful.
  ///
  /// [subdirectory] is normalised first (`''` / `'  '` / `'..'` all mean the
  /// shipped default), so the stored value can never be a blank that a later
  /// reader has to guess about.
  Future<void> setReceivedSubdirectory(String subdirectory) async {
    if (!ready) {
      return;
    }
    final String normalized = normalizeDownloadsSubdirectory(subdirectory);
    if (normalized == _current.receivedSubdirectory) {
      // Nothing to write. Keeping the document untouched also keeps 「恢复默认」
      // from touching the disk when it is already the default.
      _succeed();
      return;
    }
    try {
      await _persist(_current.copyWith(receivedSubdirectory: normalized));
    } catch (error) {
      _fail('保存位置没有改：$error');
      return;
    }
    _succeed();
  }

  /// P0-7: toggles the receiver mode and remembers it as the default.
  ///
  /// The **single** receive-mode write entry (the rail and the settings switch
  /// both go through here). Refuses to write before [load] has resolved: the
  /// base state would be the empty fallback, so persisting would blank the alias
  /// and the save directory. The UI disables the switch until then, so this is
  /// defence in depth, not the primary guard.
  Future<void> setAccepting(bool value) async {
    if (!ready) {
      return;
    }
    try {
      await _transfer.setAccepting(value);
      await _persist(_current.copyWith(acceptByDefault: value));
    } catch (error) {
      _fail('切换接收模式失败：$error');
      return;
    }
    _succeed();
  }

  /// Dismisses the current error.
  void clearError() {
    _error = null;
    _notify();
  }

  AppSettings get _current =>
      _settings.valueOrNull ??
      // The pre-load placeholder. It is **never persisted** — every write entry
      // bails on `!ready` first (`setAccepting`, `setSaveDirectory`) — so the
      // field values here are unobservable; they only have to be non-null so the
      // `copyWith` base does not explode. `acceptByDefault` is left at the model
      // default (0.2.25: on) instead of being pinned to `false`, so the receive
      // default is stated in exactly one place.
      const AppSettings(alias: '', saveDirectory: '');

  /// Persists [next] and adopts it as the new state.
  ///
  /// Throws [SettingsWriteException] (and the port's own errors) upward — the
  /// caller decides how to surface them (§8.5).
  Future<void> _persist(AppSettings next) async {
    await _platform.saveSettings(next);
    _settings = Data<AppSettings>(next);
  }

  void _succeed() {
    _error = null;
    _notify();
  }

  void _fail(String message) {
    _error = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
