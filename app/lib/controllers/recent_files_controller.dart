/// The recent-files controller (spec §4.3 / §5.4).
///
/// Owns the **UI state** of the recent-files page — the aggregated list, the
/// search query and the active category tab — and derives the visible + grouped
/// lists through the pure selectors [buildRecentFiles], [filterByQuery],
/// [matchesKind] and [groupByLocalDay]. None of that logic is re-implemented
/// here (spec §8.8: logic left in a controller is logic a test cannot reach).
///
/// The existence probe is async at the port ([PlatformPorts.exists]) but the
/// selector input is a **synchronous** predicate: the controller awaits the
/// candidate paths once and wraps the result in a `Set` (§4.3 / A2-18).
///
/// Layering (spec §8.1): imports only `dart:async`, `package:flutter/foundation`
/// and this package's `domain/**`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/async_value.dart';
import '../domain/models.dart';
import '../domain/platform_ports.dart';
import '../domain/selectors.dart';
import '../domain/session_repository.dart';
import '../domain/source_availability.dart';

/// Drives the recent-files page.
class RecentFilesController extends ChangeNotifier {
  /// Wires the controller to the two ports it reads.
  RecentFilesController({
    required SessionRepository repo,
    required PlatformPorts platform,
  })  : _repo = repo,
        _platform = platform {
    _sub = _repo.events.listen(_onRepoEvent);
  }

  /// The window in which a burst of repository events is folded into **one**
  /// [load] (0.2.50).
  ///
  /// 250 ms is chosen to sit under the eye: after a burst the page is up to a
  /// quarter-second stale, which nobody can see, and a 80-file batch costs one
  /// reload instead of eighty. The window is **fixed, not restarted** by each
  /// event (see [_onRepoEvent]) — a restarting tail would let a transfer that
  /// keeps arriving postpone the refresh indefinitely, and a 最近文件 page that
  /// never updates *during* the transfer is the bug this page used to have in
  /// the other direction.
  static const Duration kReloadCoalesceWindow = Duration(milliseconds: 250);

  final SessionRepository _repo;
  final PlatformPorts _platform;

  /// The **shared** "is this file still on disk?" judgement (0.2.48).
  ///
  /// This page used to own the only copy of the rule — a `Set` of paths it had
  /// stat'ed itself — while the conversation's 文件 tab probed nothing and the
  /// timeline only looked at `failed` messages. The same file therefore got three
  /// different verdicts. The rule now lives in [SourceAvailability] and all three
  /// surfaces read it; what stays here is one instance, filled by one [load].
  final SourceAvailability _sources = SourceAvailability();

  late final StreamSubscription<RepoEvent> _sub;
  bool _disposed = false;

  /// Pending coalesced reload, or `null` when none is scheduled.
  Timer? _reload;

  AsyncValue<List<RecentFileItem>> _all = const Loading<List<RecentFileItem>>();
  String _query = '';
  FileKind _tab = FileKind.any;

  /// Every aggregated row, `messageCreatedAt` descending. `Loading` until [load].
  AsyncValue<List<RecentFileItem>> get all => _all;

  /// The current file-name search query (raw).
  String get query => _query;

  /// The active category tab.
  FileKind get tab => _tab;

  /// The rows matching the current tab **and** query, order preserved.
  List<RecentFileItem> get visible {
    final List<RecentFileItem> base =
        _all.valueOrNull ?? const <RecentFileItem>[];
    final List<RecentFileItem> byTab = <RecentFileItem>[
      for (final RecentFileItem item in base)
        if (matchesKind(item, _tab)) item,
    ];
    return filterByQuery(byTab, _query);
  }

  /// [visible] grouped by local day (`yyyy-MM-dd`), newest group first.
  Map<String, List<RecentFileItem>> get grouped => groupByLocalDay(visible);

  /// A repository event arrived: schedule **one** [load] for the whole burst.
  ///
  /// Replaces `events.listen((_) => unawaited(load()))`, which was the second
  /// half of the 0.2.50 卡顿 report: a multi-select send of N files pushes N
  /// events, and each one re-read **the entire database** (every conversation →
  /// every message → every attachment → a `stat` per distinct path) for a page
  /// that is not even on screen most of the time — this controller is created
  /// with the shell (`shell_page.dart`) and outlives every module switch.
  ///
  /// The first event of a window arms a timer and every further event in that
  /// window is absorbed by it. That gives "at most one reload per window" with
  /// no way to starve: a sustained stream (a folder arriving for minutes) still
  /// refreshes every 250 ms instead of never.
  void _onRepoEvent(RepoEvent event) {
    if (_disposed || _reload != null) {
      return;
    }
    _reload = Timer(kReloadCoalesceWindow, () {
      _reload = null;
      unawaited(load());
    });
  }

  /// Aggregates every conversation → message → attachment (§5.4).
  ///
  /// Archived conversations are included (§4.3 / E5): history is never hidden.
  Future<void> load() async {
    try {
      final List<Conversation> conversations =
          _repo.conversations(includeArchived: true);
      final List<ChatMessage> messages = <ChatMessage>[];
      final List<FileAttachment> files = <FileAttachment>[];
      for (final Conversation conversation in conversations) {
        final List<ChatMessage> history = _repo.history(conversation.id);
        messages.addAll(history);
        for (final ChatMessage message in history) {
          files.addAll(_repo.filesOf(message.id));
        }
      }

      // One stat per distinct path, through the shared judgement (0.2.48) — the
      // same call the 文件 tab and the timeline make, so 「已不在原位置」 here means
      // exactly what 「源文件不可用」 there means.
      await _sources.probeFiles(files, _platform);

      _all = Data<List<RecentFileItem>>(
        buildRecentFiles(
          conversations: conversations,
          messages: messages,
          files: files,
          isOnDisk: _sources.isOnDisk,
        ),
      );
    } catch (error) {
      _all = Failure<List<RecentFileItem>>(error);
    }
    _notify();
  }

  /// Sets the search query (case-insensitive file-name substring).
  void setQuery(String query) {
    if (_query == query) {
      return;
    }
    _query = query;
    _notify();
  }

  /// Switches the category tab.
  void setTab(FileKind kind) {
    if (_tab == kind) {
      return;
    }
    _tab = kind;
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
    _reload?.cancel();
    _reload = null;
    _sub.cancel();
    super.dispose();
  }
}
