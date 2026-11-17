/// The middle pane's `已归档` body (design §1.3 / §1.4; rewritten from
/// `archived_page`).
///
/// A **read-only** list of the threads the user archived — e.g. after a peer
/// reinstalled and its certificate fingerprint changed (E5). Archiving hides a
/// thread from the conversations list; it must never make history feel lost, so
/// this is the visible entry point that keeps it findable (Q8 / U11). There is
/// deliberately **no** restore / delete action and no navigation into the
/// thread.
///
/// It re-derives nothing — the archived slice is read straight from
/// `SessionRepository.conversations(includeArchived: true)` filtered by
/// `isArchived`, and rows use the shared `ui/format.dart` copy.
///
/// **Layering (design §9.6):** imports only `package:flutter/**` and this
/// package's `domain/**` + sibling `ui/**`; never `dart:io` / `dart:ffi` /
/// `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/session_repository.dart';
import '../format.dart';
import '../scope.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';

/// The read-only list of archived threads.
class ArchivedList extends StatefulWidget {
  /// Creates the archived list.
  const ArchivedList({super.key});

  @override
  State<ArchivedList> createState() => _ArchivedListState();
}

class _ArchivedListState extends State<ArchivedList> {
  SessionRepository? _repo;
  StreamSubscription<RepoEvent>? _sub;
  List<Conversation> _archived = const <Conversation>[];

  /// The id of the row the pointer is currently over, or `null`.
  String? _hovered;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_repo != null) {
      return;
    }
    final SessionRepository repo = context.deps.repo;
    _repo = repo;
    // The first read is synchronous; build() follows immediately.
    _reload();
    // Keep the list live: archiving (or fresh history) from elsewhere is
    // reflected without a manual refresh.
    _sub = repo.events.listen((RepoEvent _) {
      if (!mounted) {
        return;
      }
      setState(_reload);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Re-derives the archived slice from the repository (read-only).
  void _reload() {
    final SessionRepository? repo = _repo;
    if (repo == null) {
      return;
    }
    _archived = <Conversation>[
      for (final Conversation conversation
          in repo.conversations(includeArchived: true))
        if (conversation.isArchived) conversation,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_archived.isEmpty) {
      // Distinct empty copy (loading ≠ empty; here "looked, none").
      return const EmptyState(
        title: '还没有归档的会话',
        message: '对方更换设备或重装后，旧会话会显示在这里',
        icon: Icons.archive_outlined,
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: <Widget>[
        _readOnlyNote(),
        for (final Conversation conversation in _archived) _row(conversation),
      ],
    );
  }

  /// A one-line note making the read-only contract explicit (Q8 / U11).
  Widget _readOnlyNote() {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        '以下会话已归档，仅作查看，历史不会被删除。',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _row(Conversation conversation) {
    final bool hovered = _hovered == conversation.id;
    // The row is deliberately read-only (Q8) — it has no tap and no ink — but a
    // subtle hover highlight keeps it from feeling dead on desktop (PRD §2.5).
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = conversation.id),
      onExit: (_) => setState(() => _hovered = null),
      child: AnimatedContainer(
        duration: kTransitionDuration,
        color: hovered ? hoverFill(Theme.of(context)) : Colors.transparent,
        child: ListTile(
          leading: const Icon(Icons.archive_outlined),
          title: Text(
            _titleFor(conversation),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _subtitleFor(conversation),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // No onTap: the entry is read-only (Q8); the lock marks it as not
          // actionable rather than opening a dead route.
          trailing: const Icon(Icons.lock_outline),
        ),
      ),
    );
  }

  /// The row title: the peer's alias when known, else a short fingerprint.
  String _titleFor(Conversation conversation) {
    final String? fingerprint = conversation.deviceFingerprint;
    if (fingerprint == null) {
      // A history-only thread with no device (spec §4.2): it never appears on
      // the conversations list, so it can only be reached here.
      return '本机会话';
    }
    final PeerDevice? device = _repo?.device(fingerprint);
    final String? alias = device?.alias;
    if (alias != null && alias.isNotEmpty) {
      return alias;
    }
    return _shorten(fingerprint);
  }

  /// The row subtitle: the last preview and its local timestamp, when present.
  String _subtitleFor(Conversation conversation) {
    final String preview = conversation.lastPreview?.trim() ?? '';
    final DateTime? at = conversation.lastMessageAt;
    if (at == null) {
      return preview.isEmpty ? '无消息记录' : preview;
    }
    final String when = dateTimeText(at);
    return preview.isEmpty ? when : '$preview · $when';
  }

  String _shorten(String fingerprint) => fingerprint.length <= 12
      ? fingerprint
      : '${fingerprint.substring(0, 12)}…';
}
