/// Native (desktop/VM) branch of the platform seam.
///
/// `create_deps.dart` picks this file when `dart.library.io` **exists**
/// (spec §3.4). It is the one place allowed to reach the `data/real/**`
/// adapters, which in turn wrap `lanlink_core` / `lanlink_store` / `dart:io`
/// (§8.1) — those imports never reach the Web build because this file is not
/// parsed there.
///
/// **T02 scope:** the real adapters. This opens the database and the certificate
/// directory, loads the persisted settings (alias / save directory / accept
/// default), then constructs `SqliteSessionRepository`, `LanTransferService`,
/// `LanPeerDiscovery` and `SystemPlatformPorts` (spec §3.4 / §5.1 / §8.2).
library;

import 'dart:async';
import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:lanlink_store/lanlink_store.dart' as store;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../controllers/outbox_pump.dart';
import '../controllers/transfer_orchestrator.dart';
import '../data/real/android_foreground_service.dart';
import '../data/real/android_public_storage.dart';
import '../data/real/android_share_inbox.dart';
import '../data/real/app_log.dart';
import '../data/real/lan_peer_discovery.dart';
import '../data/real/lan_transfer_service.dart';
import '../data/real/picked_cache.dart';
import '../data/real/sqlite_session_repository.dart';
import '../data/real/system_platform_ports.dart';
import '../domain/clock.dart';
import '../domain/id_factory.dart';
import '../domain/received_file_publisher.dart';
import '../domain/unsent_dismissal_store.dart';
import 'app_deps.dart';

/// Builds the desktop [AppDeps].
///
/// Everything mutable at start-up (alias / save directory / accept default) is
/// seeded from the persisted settings; the certificate directory is deliberately
/// **alias-independent** so renaming does not change the fingerprint (§8.2).
Future<AppDeps> createAppDeps() async {
  final lanlinkDirectory = await _lanlinkDirectory();
  await Directory(lanlinkDirectory).create(recursive: true);

  // On-device diagnostics. The offline/freeze bug reproduces only for the user,
  // so the evidence has to land in a file they can send back: every discovery
  // and transfer callback logs here, plus the event-loop watchdog below. None of
  // this is on the UI's critical path.
  //
  // Two destinations: the private directory (always writable — the guaranteed
  // copy) and, on Android, the app's **external** files directory
  // (`/Android/data/<pkg>/files`), which the file manager and USB can read —
  // without it the user cannot retrieve the log at all. A destination that
  // cannot be written is skipped, never fatal; the start-up line below names the
  // ones that worked.
  final List<String> logPaths = <String>[
    p.join(lanlinkDirectory, 'lanlink.log'),
  ];
  final Directory? externalLogDirectory = await _externalLogDirectory();
  if (externalLogDirectory != null) {
    logPaths.add(p.join(externalLogDirectory.path, 'lanlink.log'));
  }
  final AppLog log = await AppLog.openMany(logPaths);

  // Belt-and-braces: `AppLog.log` already swallows every failure, but the
  // callbacks handed to the discovery/transfer/keep-alive layers are wrapped
  // too — no layer may be able to take the app down by logging. (The shipped
  // crash was exactly that: a throw from the log reached `createAppDeps` and
  // stopped the app from starting at all.)
  void onDiagnostic(String message) {
    try {
      log.log(message);
    } on Object {
      // Diagnostics never break a caller.
    }
  }

  final config = AppConfig(
    tcpPort: kDefaultPort,
    udpPort: kDefaultPort,
    multicastGroup: kMulticastGroup,
    certDirectory: p.join(lanlinkDirectory, 'certs'),
    databasePath: p.join(lanlinkDirectory, 'lanlink.db'),
    // The receiver's **landing** directory, not the user's destination.
    //
    // On Android this is `/data/user/0/<pkg>/files/lanlink/received`, which the
    // file manager cannot open — which is why 0.2.19 added the publish step
    // below: verified bytes are copied to `Download/lanlink` and the private
    // copy is dropped. So on a phone the setting that matters is the platform's
    // Downloads collection, and `saveDirectory` is only a staging area (the
    // settings page therefore no longer offers it for editing — 0.2.23).
    // On desktop this IS the destination, and it stays editable, now taking
    // effect immediately (`LanTransferService.setSaveDirectory`).
    defaultSaveDirectory: p.join(lanlinkDirectory, 'received'),
    settingsPath: p.join(lanlinkDirectory, 'settings.json'),
  );

  const Clock clock = SystemClock();
  final IdFactory ids = RandomIdFactory();

  final platform = SystemPlatformPorts(
    settingsPath: config.settingsPath,
    defaultAlias: _defaultAlias(),
    defaultSaveDirectory: config.defaultSaveDirectory,
  );

  // Settings first: alias / save directory / accept default seed the servers.
  final settings = await platform.loadSettings();

  // Certificate directory is alias-independent (§8.2): renaming never changes
  // the fingerprint — peers keep recognising this device.
  final certificate = await DeviceCertificate.loadOrCreate(
    directory: Directory(config.certDirectory),
    commonName: 'lanlink',
  );

  // Opening creates the database on first run; a missing history DB is normal
  // (§8.5). The store and the repository share one id generator so ids stay
  // unique — the repository serves `openActive` / `archiveConversation` through
  // the store's own `ConversationsDao` (the frozen facade has neither).
  final database = store.LanlinkDatabase.openFile(config.databasePath);
  final storeIds = store.RandomIdGenerator();
  final sessionStore = store.SessionStore(db: database, ids: storeIds);
  final repo = SqliteSessionRepository(
    db: database,
    sessionStore: sessionStore,
    clock: clock,
    ids: storeIds,
  );

  // 0.2.19 — received files must land where the user can actually find them.
  // The receiver still streams into the private `lanlink/received` directory
  // (untouched: that is core's landing point, and changing it would put a
  // several-hundred-megabyte write on the critical path of every upload), so a
  // publish step runs **after** verification: copy into `Download/lanlink`, then
  // drop the private copy. `AndroidPublicStorage` answers `null` on desktop and
  // iOS — nothing to do there — so this one wiring serves both platforms and
  // desktop behaviour stays exactly as it was in 0.2.18.
  final ReceivedFilePublisher publisher = ReceivedFilePublisher(
    storage: const AndroidPublicStorage(),
    deleteLocalFile: _deleteFileQuietly,
    onLog: onDiagnostic,
    // 0.2.29: read the folder **at publish time** from the port, which caches
    // whatever the settings document last said. Capturing `settings.receivedSubdirectory`
    // here would freeze the value at launch, so picking a new folder would only
    // take effect after a restart — the 0.2.23 defect in a new place.
    subdirectory: () => platform.receivedSubdirectory,
  );

  // The receiver starts in whatever state the settings document says — and since
  // 0.2.25 that default is **on** ("接收模式默认开着就行"). `loadSettings` is also
  // where a pre-0.2.25 document is migrated once (`settingsVersion < 2` ⇒
  // `acceptByDefault` becomes on, then the document is rewritten as v2), so by
  // the time this line runs `settings.acceptByDefault` is already the migrated
  // value. Nothing here needs to know about the version.
  final transfer = LanTransferService(
    certificate: certificate,
    clock: clock,
    alias: settings.alias,
    tcpPort: config.tcpPort,
    saveDirectory: settings.saveDirectory,
    acceptUploads: settings.acceptByDefault,
    publisher: publisher,
    onLog: onDiagnostic,
  );

  // Android-only background keep-alive (docs/13 §4): without a foreground
  // service Android freezes this app's single Dart isolate once it is cached, so
  // the 5s announcements stop and every peer times us out as offline. Its life
  // is the app's — started with discovery (Scope 1), never from device boot — and
  // it is a no-op on every non-Android platform.
  final keepAlive = AndroidForegroundService(onLog: log.log);

  // Pick the multicast egress explicitly. A phone's cellular link (`rmnet*`,
  // CGNAT'd into 10/8) and a machine's virtual adapters (Hyper-V/VMware) are
  // both "private-looking", so they used to win this race and send our
  // announcements out of a NIC no LAN peer can hear (`local_interfaces.dart`
  // now skips them). The full candidate list and the verdict go to the log, so
  // "which NIC did it pick, and why" is answerable after the fact.
  final LocalInterface? egress =
      await selectDefaultMulticastInterface(onLog: log.log);

  final discovery = LanPeerDiscovery(
    certificate: certificate,
    // Relaxed from the 30s default: a 5s announce interval leaves only six
    // misses of head-room, which a busy/sleeping peer can hit even while a live
    // TCP transfer is flowing. 60s is the "relaxed threshold" half; the
    // "hysteresis" half is inherent — any single contact brings a peer back
    // online instantly, so the state only ever errs toward "online", never
    // toward flapping. (The keep-alive fix also feeds the registry from TCP, so
    // an active transfer refreshes `lastSeen` regardless.)
    registry: PeerRegistry(offlineAfter: const Duration(seconds: 60)),
    clock: clock,
    selfPort: config.tcpPort,
    alias: settings.alias,
    registrations: transfer.registrations,
    group: config.multicastGroup,
    udpPort: config.udpPort,
    multicastInterface: egress?.address,
    // Re-pick on a network change: the boot-time choice goes stale when adapters
    // appear/disappear, and a stale egress means nobody on the LAN hears us.
    egressSelector: () => chooseDefaultMulticastInterface(onLog: log.log),
    onLog: onDiagnostic,
    keepAlive: keepAlive,
  );

  // The event-loop watchdog: a timer that only fires when the isolate is free,
  // so its overshoot IS the stall. It reports only > 1s, so a healthy run stays
  // quiet while a real freeze is recorded with its length — the one probe that
  // answers "did the app stop running?" without guessing where to instrument.
  // Fire-and-forget for the whole app lifetime (nothing closes it, on purpose:
  // it exists to observe, not to be observed).
  EventLoopWatchdog(
    onLag: (Duration lag) => onDiagnostic(
      'EVENT-LOOP LAG ${lag.inMilliseconds}ms — the isolate was blocked; '
      'timers and announcements were delayed',
    ),
  ).start();

  // The start-up line names the log destination(s) that actually opened, so the
  // user can find the file without asking us — and names the ones that did not,
  // so a missing second copy is visible rather than silent.
  final List<String> skippedLogPaths = <String>[
    for (final candidate in logPaths)
      if (!log.openedPaths.contains(candidate)) candidate,
  ];
  log.log('lanlink start: alias="${settings.alias}" '
      // Which folder received files will land in (0.2.29). Without it, "my file
      // went to the wrong place" cannot be answered from the log the user sends.
      'receivedFolder=${settings.receivedSubdirectory} '
      'tcp=${config.tcpPort} udp=${config.udpPort} '
      'egress=${egress == null ? 'os-default' : '${egress.name} '
          'idx=${egress.index} ${egress.addressText}'} '
      'log=${log.openedPaths.join(' | ')}'
      '${skippedLogPaths.isEmpty ? '' : ' '
          '(unwritable, skipped: ${skippedLogPaths.join(', ')})'}');

  // One orchestrator for the whole app (O3): it subscribes to
  // `transfer.received` at construction, so building it once here keeps the
  // inbound-recording path (§5.3) alive for the app's lifetime — never per page.
  final orchestrator = TransferOrchestrator(repo: repo, transfer: transfer);

  // Inbound shares (0.2.18): the files Android's share sheet hands us. It is a
  // no-op off Android (`isSupported` is `Platform.isAndroid`), so the desktop
  // build wires the same object and simply never receives anything. The share
  // itself is **never** sent automatically — `ShareIntake` in `ui/shell/` only
  // stages it and the user presses 发送.
  final shareInbox = AndroidShareInbox(onLog: onDiagnostic);

  // 0.2.23 — reclaim the temporary copies Android makes of every picked or
  // shared file (`cache/lanlink-picked/<uuid>/`, one full copy each; a 1 GB
  // video left 1 GB behind forever). The **launch sweep** is the backstop for
  // every copy that outlived the session that made it: a crash, a force-stop, a
  // draft the user simply abandoned.
  //
  // ★ 0.2.52 — **except the copies a queued message still needs.**
  //
  // The sweep used to be unconditional, on the premise that nothing in that
  // directory is ever the only copy of anything. The premise has exactly one
  // exception and it is the offline queue: a `pending` message has not been sent
  // yet, so its copy in the cache **is** the only bytes this app can still
  // upload — and `pending` is deliberately preserved across a restart. Deleting
  // it at boot therefore made the queue a lie: the row went on saying 排队中 for
  // a file *we* had removed, the resume dialled anyway, and the failure said
  // 「失败」 with no reason at all.
  //
  // `sweepLaunchCopies` reads the retention set straight from the repository
  // (non-terminal outgoing messages → their `localPath`s) and hands it to
  // `clear`, which matches it at per-send-directory granularity. The store is
  // already open here — it was opened at the top of this function, and the query
  // is a plain synchronous read that runs before the first frame — so no
  // ordering gymnastics are needed. If the queue cannot be read, nothing is
  // deleted (a locked database must not empty a retention set).
  //
  // Deliberately **not awaited**: a cache sweep must never delay the first
  // frame, and nothing in that path throws.
  final pickedCache = PickedFileCache(onLog: onDiagnostic);
  unawaited(
    sweepLaunchCopies(cache: pickedCache, repo: repo, onLog: onDiagnostic),
  );

  // 0.2.33 — the 未发送成功 banner must stay closed across a **restart**.
  // The report was exact: *"虽然会话退出再进来没有了，但是我退出软件重新进还是有的"*.
  // 0.2.30 fixed the conversation switch (the store became process-wide) and
  // called "restart brings it back" acceptable; that was wrong — the failed
  // messages are still in the history, so the user's "这一批我处理过了" has no
  // reason to expire with the process.
  //
  // This is the **only** place that touches the file: `UnsentDismissalStore` is
  // pure Dart and receives the two functions below. Same directory as
  // `settings.json`, so everything this app remembers lives in one folder.
  final String dismissalsPath =
      p.join(lanlinkDirectory, 'unsent_dismissals.json');
  UnsentDismissalStore.shared.configure(
    read: () => _readTextFile(dismissalsPath),
    write: (String data) => _writeTextFile(dismissalsPath, data),
    log: onDiagnostic,
  );
  // Awaited on purpose (unlike the cache sweep): the very first conversation must
  // already know what the user dismissed last time, and this is one small file.
  // Failure can never block startup — `load` logs and continues with an empty
  // set — but it is also wrapped, because a broken start-up is unrecoverable for
  // the user while a missing dismissal is a minor annoyance.
  try {
    await UnsentDismissalStore.shared.load();
  } on Object catch (error) {
    onDiagnostic('忽略状态加载失败，按空集合继续：$error');
  }

  // 0.2.54 — the addresses the user typed by hand come back by themselves.
  //
  // ## What "come back" has to mean
  //
  // Two things, and only one of them is about the settings document. (1) The
  // addresses are seeded into discovery's live re-dial set, so the 25 s heartbeat
  // picks them up; (2) **one probe pass runs now**, because a stale device list is
  // what the user actually sees: without it the peer reappears up to 25 s later,
  // and the 60 s registry deadline means a cold start could even show nothing at
  // all for a moment. Both are deliberately off the startup path:
  //
  // * seeding is synchronous bookkeeping (a map insert per address);
  // * the pass dials serially with a 3 s deadline per address, so it is
  //   `unawaited` — a machine whose peer is off must not wait 3 s before the
  //   first frame;
  // * every failure is a log line, never a startup failure. An address that does
  //   not answer is **kept** (that is the whole point of the heartbeat), so a
  //   dead entry costs one timeout per pass and nothing else.
  //
  // ## The keep-alive, for the same reason
  //
  // `ensureRunning()` used to be reached only from `rejoin()` / `start()`, i.e.
  // from a discovery layer that came up. A hand-typed address is exactly the case
  // where discovery never starts — and on Android that means no foreground
  // service and no wake lock, so the heartbeat would be frozen the moment the user
  // switches apps, silently. It is re-asserted here, best effort: the adapter
  // folds any failure into `multicastWarning` (visible in 本机信息), and no
  // permission or manifest entry is added — this is the service the app already
  // ships.
  discovery.seedManualTargets(settings.manualPeers);
  if (settings.manualPeers.isNotEmpty) {
    onDiagnostic('lanlink: re-armed ${settings.manualPeers.length} manual '
        'address(es) from settings');
    unawaited(_replayManualTargets(discovery, onDiagnostic));
    unawaited(discovery.ensureKeepAlive());
  }

  final AppDeps deps = AppDeps(
    repo: repo,
    discovery: discovery,
    transfer: transfer,
    platform: platform,
    clock: clock,
    ids: ids,
    config: config,
    orchestrator: orchestrator,
    // 0.2.40 — the offline queue's consumer, wired with the same on-device log
    // as everything else: "why is this still 排队中" has to be answerable from
    // the file the user sends back, and the pump is the only component that
    // knows what it tried.
    outbox: OutboxPump(
      repo: repo,
      discovery: discovery,
      orchestrator: orchestrator,
      // 0.2.52 — the platform port is how the pump answers "is this queued
      // message's source still on disk?" before it dials. See `_resume`.
      platform: platform,
      clock: clock,
      onLog: onDiagnostic,
    ),
    shareInbox: shareInbox,
    pickedCache: pickedCache,
  );
  // Started here, next to the other app-lifetime resources, because it must
  // observe discovery and the app lifecycle from the very first frame: a message
  // queued in an earlier process has to be resumed as soon as its peer
  // announces, not once some page happens to be opened. `main()` has already run
  // `WidgetsFlutterBinding.ensureInitialized()`, which `start()` requires (it
  // registers a lifecycle observer).
  deps.outbox.start();
  return deps;
}

/// Reads a small UTF-8 text file, or `null` when it does not exist yet (0.2.33).
///
/// A **missing** file is the normal first-launch case, not an error: it is
/// reported as `null` so the store starts empty without logging anything. Every
/// other failure (permissions, a directory in the way…) is thrown and becomes one
/// log line inside the store — the caller must never see it.
Future<String?> _readTextFile(String path) async {
  final File file = File(path);
  if (!await file.exists()) {
    return null;
  }
  return file.readAsString();
}

/// Replaces a small UTF-8 text file (0.2.33).
///
/// Plain `writeAsString(flush: true)`, the same write `SystemPlatformPorts` uses
/// for `settings.json`: the document is a few kilobytes and written in one call,
/// and a torn write is a case the reader already survives (it logs, keeps the
/// session's in-memory state and tries again next launch). A temporary file plus a
/// rename would buy very little here and adds a failure mode of its own
/// (`File.rename` over an existing file on Windows).
///
/// Errors are **thrown**, not swallowed: `UnsentDismissalStore` turns them into a
/// log line, which keeps this file free of policy.
Future<void> _writeTextFile(String path, String data) async {
  final File file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(data, flush: true);
}

/// Deletes a file after it has been published to public storage (0.2.19).
///
/// Runs on the **Dart** side on purpose: the platform port's only job is to put
/// the bytes somewhere visible, and keeping the removal here means a bug in the
/// export can never delete the user's only copy.
///
/// A missing file is not an error (an already-removed copy is the desired end
/// state), and a failure is **not** rethrown: the public copy is already the one
/// on record, so a leftover private file wastes space but loses nothing. The
/// caller (`ReceivedFilePublisher`) turns a thrown error into a log line.
Future<void> _deleteFileQuietly(String path) async {
  final File file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
}

/// One heartbeat pass over the addresses just seeded from settings (0.2.54).
///
/// Fire-and-forget by contract: it must never delay the first frame, and it must
/// never be able to fail startup. It is `heartbeatOnce()` — the very routine the
/// 25 s timer calls — rather than a second dialler, so "what a replayed address
/// does" and "what a heartbeat does" cannot drift apart. A reachable address puts
/// its peer into the registry (that is what makes the device appear); an
/// unreachable one produces no error anywhere, is **kept**, and is retried on the
/// next tick.
Future<void> _replayManualTargets(
  LanPeerDiscovery discovery,
  void Function(String message) onDiagnostic,
) async {
  try {
    await discovery.heartbeatOnce();
  } on Object catch (error) {
    // Not reachable through the probe's own contract (it never throws), but this
    // call sits on a startup path: one log line beats an unhandled async error.
    onDiagnostic('手动地址首次探测失败（不影响启动，之后每 25 秒重试）：$error');
  }
}

/// The base application-data directory for this user.
///
/// **Android / iOS**: `path_provider`'s **app-support** directory — an
/// app-private, writable location. `Platform.environment` carries neither
/// `LOCALAPPDATA` nor `XDG_DATA_HOME` on a phone, and the filesystem root is
/// read-only, so the desktop formula below would yield an unwritable
/// `/lanlink` (`FileSystemException … errno = 30`).
///
/// **Windows / macOS / Linux**: **deliberately unchanged** — the same
/// `%LOCALAPPDATA%\lanlink` (or `$XDG_DATA_HOME/lanlink`) an existing install
/// already uses, so upgrading never moves the database, certificates or
/// settings out from under the user.
Future<String> _lanlinkDirectory() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'lanlink');
  }
  final environment = Platform.environment;
  final base = environment['LOCALAPPDATA'] ??
      environment['XDG_DATA_HOME'] ??
      Directory.current.path;
  return p.join(base, 'lanlink');
}

/// The app's **external** files directory on Android — the one the file manager
/// and USB can read (`/Android/data/<pkg>/files`) — or `null` where there is
/// none.
///
/// Only ever used as a **secondary** log destination: the private copy is the
/// guaranteed one, so any failure here just means "no second copy" and must not
/// affect start-up.
Future<Directory?> _externalLogDirectory() async {
  if (!Platform.isAndroid) {
    return null;
  }
  try {
    return await getExternalStorageDirectory();
  } on Object {
    // No external storage mounted, or the platform refused: skip the copy.
    return null;
  }
}

/// This machine's default display name.
///
/// `Platform.localHostname` is not guaranteed on every platform, so a failure
/// to read it must not abort startup — fall back to the app name.
String _defaultAlias() {
  try {
    final hostname = Platform.localHostname;
    if (hostname.isNotEmpty) {
      return hostname;
    }
  } on Object {
    // Fall through to the constant default.
  }
  return 'lanlink';
}
