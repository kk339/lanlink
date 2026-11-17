/// Per-conversation **suppressed failure ids** — the messages a conversation's
/// 未发送成功 banner must stop counting.
///
/// Two provenances, one job:
/// * **dismissed** — the user pressed the banner's ✕ ("这一批我看到了，别再提醒我");
/// * **handled** — a 全部重试 run already re-sent that message successfully
///   (re-sending creates a **new** message and leaves the old row `failed`, so
///   without this record the old row would be counted again).
///
/// Both answer the same question — *should this failed row be counted?* — so the
/// controller asks one method ([suppresses]) and never cares which set the id
/// came from. They are stored apart only so the origin stays diagnosable in the
/// file (and so a future "恢复提示" can undo one without the other).
///
/// ## Why this object exists at all (the two bugs it has now fixed)
///
/// **0.2.30 — it must outlive a conversation visit.** 0.2.26 kept the dismissed
/// ids in a `Set` **on the `ConversationController`**, and the controller is
/// rebuilt for every conversation selection
/// (`DetailPane._reconcileConversation`), so leaving the thread and coming back
/// threw them away ("退出这个会话界面重新进来，还是会显示全部重试").
///
/// **0.2.33 — it must outlive the process.** 0.2.30 made it process-wide and
/// declared "restart brings the banner back" to be acceptable. The user disagreed,
/// and he was right: *"虽然会话退出再进来没有了，但是我退出软件重新进还是有的"*.
/// A dismissal is a judgement about messages that still exist in the history — it
/// has no reason to expire just because the process did. So the state is
/// **persisted** (see [configure] / [load]) and survives a restart.
///
/// What still re-arms the banner is a **new** failure: ids are per message, so a
/// drop that happens later produces ids nobody has suppressed. "Ignore what I can
/// see" never becomes "never remind me again".
///
/// ## Layering
///
/// **Pure Dart** (M4 §8.1): no `package:flutter/*`, no `dart:io`, no
/// `path_provider`. Persistence is injected as two functions — a reader and a
/// writer — and the actual file lives behind them, wired in
/// `bootstrap/create_deps_native.dart`. That keeps this class unit-testable with
/// a `String` in memory and keeps the Web build (which never calls [configure])
/// working unchanged.
///
/// **Deliberately not a `ChangeNotifier`:** the banner disappears because
/// `ConversationController.dismissUnsent` notifies *after* the write, exactly once
/// per tap. Making the store listenable would give the same repaint two owners.
library;

import 'dart:async';
import 'dart:convert';

/// Reads the persisted document, or `null`/`''` when there is none yet.
typedef DismissalReader = Future<String?> Function();

/// Replaces the persisted document with [data].
typedef DismissalWriter = Future<void> Function(String data);

/// Receives one diagnostic line (a corrupt file, a failed write). Never throws.
typedef DismissalLog = void Function(String message);

/// The default cap on remembered ids, across every conversation (0.2.33).
///
/// Two thousand ids at ~90 bytes each in the file is comfortably under 200 KB —
/// big enough that a normal user never reaches it (a conversation would need two
/// thousand ignored failures), small enough that the document stays a file, not a
/// liability. When it is exceeded the **oldest** ids are dropped first.
const int kMaxSuppressedIds = 2000;

/// The `version` written into the document. A future format change can migrate on
/// read instead of guessing from the shape.
const int _kDocumentVersion = 1;

/// Where an id came from — only used for storage / diagnostics.
enum _Kind { dismissed, handled }

/// One remembered id, in global insertion order (the eviction order).
class _Entry {
  const _Entry(this.kind, this.conversationId, this.messageId);

  final _Kind kind;
  final String conversationId;
  final String messageId;
}

/// The record of which failed messages each conversation's banner ignores.
///
/// One instance per process in production —
/// [UnsentDismissalStore.shared], handed to every `ConversationController` — but
/// the constructor is public so a test can own an isolated one (and give it its
/// own in-memory file).
class UnsentDismissalStore {
  /// Creates an empty store.
  ///
  /// [read] / [write] are the persistence seam; leave them out for a memory-only
  /// store (the Web build, and every existing test). [maxEntries] caps how many
  /// ids are remembered ([kMaxSuppressedIds]).
  UnsentDismissalStore({
    DismissalReader? read,
    DismissalWriter? write,
    DismissalLog? log,
    this.maxEntries = kMaxSuppressedIds,
  })  : _read = read,
        _write = write,
        _log = log ?? _noopLog;

  /// The store the app uses: one per process, shared by every conversation.
  ///
  /// Created **without** persistence; `create_deps_native.dart` calls
  /// [configure] + [load] once at boot, before the first frame, so the very first
  /// conversation already sees the restored dismissals.
  static final UnsentDismissalStore shared = UnsentDismissalStore();

  /// How many ids may be remembered in total (see [kMaxSuppressedIds]).
  final int maxEntries;

  DismissalReader? _read;
  DismissalWriter? _write;
  DismissalLog _log;

  /// conversation id → ids the user dismissed with the ✕.
  final Map<String, Set<String>> _dismissed = <String, Set<String>>{};

  /// conversation id → ids a 全部重试 run already re-sent successfully.
  final Map<String, Set<String>> _handled = <String, Set<String>>{};

  /// Every remembered id, oldest first — the eviction order (0.2.33).
  final List<_Entry> _order = <_Entry>[];

  /// The save that is running right now, if any (see [_requestSave]).
  Future<void>? _activeSave;

  /// Whether a save was requested while one was already running.
  bool _pendingSave = false;

  // ── wiring ────────────────────────────────────────────────────────────────

  /// Attaches (or replaces) the persistence seam.
  ///
  /// Called once at boot from `create_deps_native.dart`. It is deliberately not a
  /// constructor argument: [shared] has to exist as a `static final` before the
  /// app-data directory is known. Calling it again is allowed (it just swaps the
  /// functions) — nothing in the app does.
  void configure({
    required DismissalReader read,
    required DismissalWriter write,
    DismissalLog? log,
  }) {
    _read = read;
    _write = write;
    if (log != null) {
      _log = log;
    }
  }

  /// Loads the persisted document, **union**-merging it into what is in memory.
  ///
  /// Never throws and never clears anything on failure — the whole point is that
  /// the app must start. Four outcomes:
  /// * no reader configured (Web, tests) → nothing happens;
  /// * nothing stored yet → nothing happens;
  /// * read threw / the document is corrupt or of an unknown version → the
  ///   failure is logged and the store keeps what it has (an empty set at boot);
  ///   **the bad file is left alone**, so a transient problem does not destroy the
  ///   user's dismissals — the next successful dismissal simply overwrites it;
  /// * parsed → the ids are merged in (a dismissal that landed while the read was
  ///   in flight is kept, not clobbered).
  Future<void> load() async {
    final DismissalReader? reader = _read;
    if (reader == null) {
      return;
    }
    String? raw;
    try {
      raw = await reader();
    } on Object catch (error) {
      // A read failure is not a reason to lose the session: start empty and let
      // the next dismissal write a fresh document.
      _log('忽略状态读取失败，按空集合继续：$error');
      return;
    }
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    List<_Entry> restored;
    try {
      restored = _decode(raw);
    } on Object catch (error) {
      // Deliberately **not** rewritten: if the file is unreadable the honest move
      // is to leave it (the user's ids may still be recoverable) and retry next
      // launch, not to overwrite it with an empty document.
      _log('忽略状态文件损坏，按空集合继续（未覆盖原文件）：$error');
      return;
    }
    for (final _Entry entry in restored) {
      _insert(entry);
    }
    _enforceCap();
  }

  /// Awaits the write that is in flight (test / shutdown convenience).
  ///
  /// Writes are fire-and-forget in the UI path on purpose (a dismissal must never
  /// wait on the disk to feel instant), so a test that wants to inspect the
  /// document calls this first.
  Future<void> flush() async {
    for (int guard = 0; guard < 64; guard++) {
      final Future<void>? active = _activeSave;
      if (active != null) {
        await active;
        continue;
      }
      if (!_pendingSave) {
        return;
      }
      await _requestSave();
    }
  }

  // ── reads ─────────────────────────────────────────────────────────────────

  /// The ids the user dismissed with the ✕ in [conversationId].
  ///
  /// Returned as an **unmodifiable snapshot**, so a caller cannot mutate the
  /// store's own set through a getter.
  Set<String> dismissedFor(String conversationId) =>
      Set<String>.unmodifiable(_dismissed[conversationId] ?? const <String>{});

  /// The ids a 全部重试 run already re-sent in [conversationId].
  Set<String> handledFor(String conversationId) =>
      Set<String>.unmodifiable(_handled[conversationId] ?? const <String>{});

  /// Whether [messageId] was dismissed with the ✕.
  bool isDismissed({
    required String conversationId,
    required String messageId,
  }) =>
      _dismissed[conversationId]?.contains(messageId) ?? false;

  /// Whether [messageId] was already re-sent by a 全部重试 run.
  bool isHandled({
    required String conversationId,
    required String messageId,
  }) =>
      _handled[conversationId]?.contains(messageId) ?? false;

  /// Whether the banner must **not** count [messageId] any more.
  ///
  /// The single question `ConversationController._countsAsUnsent` asks; both
  /// provenances answer it identically (see the library doc for why they are
  /// stored apart anyway).
  bool suppresses({
    required String conversationId,
    required String messageId,
  }) =>
      isDismissed(conversationId: conversationId, messageId: messageId) ||
      isHandled(conversationId: conversationId, messageId: messageId);

  /// How many ids [conversationId] suppresses (0 when none).
  int countFor(String conversationId) =>
      (_dismissed[conversationId]?.length ?? 0) +
      (_handled[conversationId]?.length ?? 0);

  /// How many conversations hold anything (test / diagnostics).
  int get length => <String>{..._dismissed.keys, ..._handled.keys}.length;

  /// How many ids are remembered in total (the number [maxEntries] caps).
  int get entryCount => _order.length;

  /// The conversation ids that hold anything, in insertion order.
  Iterable<String> get conversationIds =>
      <String>{..._dismissed.keys, ..._handled.keys};

  // ── writes ────────────────────────────────────────────────────────────────

  /// Ignores [messageIds] in [conversationId]; returns how many were **new**.
  ///
  /// Idempotent: dismissing an id twice adds nothing the second time, which is
  /// what makes a stale frame's duplicate tap harmless. Persists asynchronously
  /// (see [_requestSave]) — the caller never waits on the disk.
  int dismiss({
    required String conversationId,
    required Iterable<String> messageIds,
  }) =>
      _insertAll(_Kind.dismissed, conversationId, messageIds);

  /// Records that a 全部重试 run already re-sent [messageIds] in
  /// [conversationId]; returns how many were **new** (0.2.33: these ids now
  /// survive a restart too — a successful batch retry is the same statement as a
  /// dismissal: "these old rows are dealt with").
  int markHandled({
    required String conversationId,
    required Iterable<String> messageIds,
  }) =>
      _insertAll(_Kind.handled, conversationId, messageIds);

  /// Forgets everything recorded for [conversationId]. Returns whether there was
  /// anything.
  bool forgetConversation(String conversationId) {
    final bool hadDismissed = _dismissed.remove(conversationId) != null;
    final bool hadHandled = _handled.remove(conversationId) != null;
    if (!hadDismissed && !hadHandled) {
      return false;
    }
    _order.removeWhere((_Entry e) => e.conversationId == conversationId);
    _requestSave();
    return true;
  }

  /// Drops remembered ids of [conversationId] that are **no longer failed**.
  ///
  /// [relevant] is the set of message ids in that conversation that are still
  /// `failed` / `canceled` (the only rows the banner can ever count). Anything
  /// remembered but absent from it — the message was deleted, or it left the
  /// failed state for good — is dropped, and the conversation's entry disappears
  /// once it is empty. That is the one honest way this record can shrink: a
  /// suppression must never be forgotten while its message is still on screen as
  /// 失败, because that is exactly the "它又冒出来了" bug.
  ///
  /// Cheap enough to call on every successful [ConversationController.load].
  Future<void> pruneConversation(
    String conversationId, {
    required Set<String> relevant,
  }) async {
    final Set<String>? dismissed = _dismissed[conversationId];
    final Set<String>? handled = _handled[conversationId];
    if (dismissed == null && handled == null) {
      return;
    }
    bool changed = false;
    for (final Set<String>? ids in <Set<String>?>[dismissed, handled]) {
      if (ids == null) {
        continue;
      }
      final int before = ids.length;
      ids.removeWhere((String id) => !relevant.contains(id));
      changed = changed || ids.length != before;
    }
    if (!changed) {
      return;
    }
    if (dismissed != null && dismissed.isEmpty) {
      _dismissed.remove(conversationId);
    }
    if (handled != null && handled.isEmpty) {
      _handled.remove(conversationId);
    }
    _order.removeWhere((_Entry e) =>
        e.conversationId == conversationId && !relevant.contains(e.messageId));
    await _requestSave();
  }

  /// Drops every record (test isolation; nothing in the app calls it).
  ///
  /// [persist] also rewrites the document — off by default so a test can wipe its
  /// store without pretending to the persistence layer that the user deleted
  /// everything.
  void clearAll({bool persist = false}) {
    _dismissed.clear();
    _handled.clear();
    _order.clear();
    if (persist) {
      _requestSave();
    }
  }

  // ── document ──────────────────────────────────────────────────────────────

  /// The document as it is written to disk.
  ///
  /// Shape (0.2.33):
  /// ```json
  /// {
  ///   "version": 1,
  ///   "dismissed": [{"conversationId": "c-a", "messageId": "m-1"}],
  ///   "handled":   [{"conversationId": "c-a", "messageId": "m-2"}]
  /// }
  /// ```
  /// A flat, ordered array of pairs rather than a nested map: it keeps the global
  /// insertion order (which is the eviction order), it is trivially readable when
  /// the user sends us the file, and a malformed entry can be rejected without
  /// throwing away the rest.
  String encode() => jsonEncode(<String, Object?>{
        'version': _kDocumentVersion,
        'dismissed': <Object?>[
          for (final _Entry e in _order)
            if (e.kind == _Kind.dismissed) _encodeEntry(e),
        ],
        'handled': <Object?>[
          for (final _Entry e in _order)
            if (e.kind == _Kind.handled) _encodeEntry(e),
        ],
      });

  static Map<String, Object?> _encodeEntry(_Entry e) => <String, Object?>{
        'conversationId': e.conversationId,
        'messageId': e.messageId,
      };

  /// Parses [raw] into entries in document order. Throws on anything unreadable —
  /// the caller turns that into "keep what we have, log, do not overwrite".
  List<_Entry> _decode(String raw) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('顶层不是对象');
    }
    final Object? version = decoded['version'];
    if (version is! int || version > _kDocumentVersion) {
      throw FormatException('未知的 version：$version');
    }
    final List<_Entry> entries = <_Entry>[];
    for (final (String key, _Kind kind) in <(String, _Kind)>[
      ('dismissed', _Kind.dismissed),
      ('handled', _Kind.handled),
    ]) {
      final Object? list = decoded[key];
      if (list == null) {
        continue;
      }
      if (list is! List<Object?>) {
        throw FormatException('$key 不是数组');
      }
      for (final Object? item in list) {
        if (item is! Map<String, Object?>) {
          continue; // one bad entry never costs the rest of the file
        }
        final Object? conversationId = item['conversationId'];
        final Object? messageId = item['messageId'];
        if (conversationId is! String ||
            conversationId.isEmpty ||
            messageId is! String ||
            messageId.isEmpty) {
          continue;
        }
        entries.add(_Entry(kind, conversationId, messageId));
      }
    }
    return entries;
  }

  // ── internals ─────────────────────────────────────────────────────────────

  int _insertAll(
    _Kind kind,
    String conversationId,
    Iterable<String> messageIds,
  ) {
    final Map<String, Set<String>> target =
        kind == _Kind.dismissed ? _dismissed : _handled;
    int added = 0;
    for (final String messageId in messageIds) {
      if (messageId.isEmpty) {
        continue;
      }
      if (_insert(_Entry(kind, conversationId, messageId), into: target)) {
        added++;
      }
    }
    if (added > 0) {
      _enforceCap();
      _requestSave();
    }
    return added;
  }

  /// Adds [entry] unless the same (kind, conversation, message) is already known.
  bool _insert(_Entry entry, {Map<String, Set<String>>? into}) {
    final Map<String, Set<String>> target = into ??
        (entry.kind == _Kind.dismissed ? _dismissed : _handled);
    final Set<String> ids =
        target.putIfAbsent(entry.conversationId, () => <String>{});
    if (!ids.add(entry.messageId)) {
      return false;
    }
    // The id may already be remembered under the *other* provenance (a message
    // can be dismissed and later re-sent by a bulk run). `_order` must still hold
    // one entry per (kind, id) pair, which `_insert` above guarantees per set.
    _order.add(entry);
    return true;
  }

  /// Drops the oldest ids until [maxEntries] is respected (0.2.33).
  void _enforceCap() {
    if (_order.length <= maxEntries) {
      return;
    }
    final int overflow = _order.length - maxEntries;
    for (final _Entry entry in _order.take(overflow)) {
      final Map<String, Set<String>> target =
          entry.kind == _Kind.dismissed ? _dismissed : _handled;
      final Set<String>? ids = target[entry.conversationId];
      if (ids == null) {
        continue;
      }
      ids.remove(entry.messageId);
      if (ids.isEmpty) {
        target.remove(entry.conversationId);
      }
    }
    _order.removeRange(0, overflow);
  }

  /// Schedules one asynchronous write of [encode].
  ///
  /// Fire-and-forget by design: a tap must repaint on the next frame, not after a
  /// disk round-trip. Saves coalesce — while one write is in flight every further
  /// request merely sets [_pendingSave], so a bulk run that handles twenty ids
  /// still writes about once.
  Future<void> _requestSave() {
    final DismissalWriter? writer = _write;
    if (writer == null) {
      return Future<void>.value();
    }
    _pendingSave = true;
    final Future<void>? active = _activeSave;
    if (active != null) {
      return active;
    }
    final Future<void> run = _drainSaves();
    _activeSave = run;
    // Cleared in `whenComplete`, not inside `_drainSaves`: the drain returns its
    // future before it finishes (its first `await` yields), so clearing from
    // inside the loop could wipe the reference to a save that is still running.
    unawaited(run.whenComplete(() {
      if (identical(_activeSave, run)) {
        _activeSave = null;
      }
    }));
    return run;
  }

  Future<void> _drainSaves() async {
    final DismissalWriter? writer = _write;
    if (writer == null) {
      _pendingSave = false;
      return;
    }
    while (_pendingSave) {
      _pendingSave = false;
      final String data = encode();
      try {
        await writer(data);
      } on Object catch (error) {
        // A failed write must never touch the UI or throw into the caller: the
        // in-memory state is already correct for this session.
        _log('忽略状态写入失败（本会话仍生效）：$error');
      }
    }
  }

  static void _noopLog(String message) {}

  @override
  String toString() =>
      'UnsentDismissalStore(${_dismissed.length} dismissed / '
      '${_handled.length} handled conversation(s), ${_order.length} id(s))';
}
