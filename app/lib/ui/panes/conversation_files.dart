/// The right pane's `文件` tab — every attachment of the current conversation
/// (design §1.4 / §4; PRD §4, acceptance E20–E22).
///
/// The list is produced by the pure `domain/selectors.dart::buildConversationFiles`
/// (the "乙" increment): this widget **only renders**. It flattens the loaded
/// history into a `messageId → attachments` map and hands it to the selector, so
/// the row order (newest first, deterministic tie-break) matches the
/// recent-files list by construction — there is no second sorting rule here.
///
/// This is a **different data source** from the middle-pane recent-files list
/// (that one spans all conversations; this one is scoped to the bound
/// conversation), which is exactly what E22 asserts.
///
/// **★ 0.2.48 — this page now asks whether the file is still there.** It used to
/// be the one surface that never probed the disk (the selector's
/// `ConversationFileItem` deliberately carries no `sourceMissing`, and the PRD
/// said the probe belonged to the recent-files page alone). The effect was a
/// three-way disagreement about one file: 最近文件 said 「已不在原位置」, this tab
/// drew an ordinary tappable row, and the timeline only marked it if its message
/// had **failed**. Now the judgement is the shared [SourceAvailability] — the
/// same object the timeline and `RecentFilesController` use — so all three say
/// the same thing, and a row we know is gone is drawn as such (dimmed, labelled
/// 「文件已不在原位置」, exactly like the recent-files row) **and still answers a
/// tap**, instead of being a click that does nothing.
///
/// **Layering (design §9.6):** imports only `package:flutter/**`, this package's
/// `domain/**`, `controllers/**` and sibling `ui/**` — never `dart:io` /
/// `dart:ffi` / `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/conversation_controller.dart';
import '../../domain/models.dart';
import '../../domain/selectors.dart';
import '../../domain/source_availability.dart';
import '../format.dart';
import '../scope.dart';
import '../widgets/empty_state.dart';
import '../widgets/fade_in.dart';
import '../widgets/file_tile.dart';
import '../widgets/loading_state.dart';
import '../widgets/open_local_path.dart';

/// The per-conversation file list.
class ConversationFiles extends StatefulWidget {
  /// Creates the files tab.
  const ConversationFiles({super.key, required this.controller});

  /// The single-conversation controller (owned by `DetailPane`).
  final ConversationController controller;

  @override
  State<ConversationFiles> createState() => _ConversationFilesState();
}

class _ConversationFilesState extends State<ConversationFiles> {
  /// The one judgement of "is this file still on disk?" (0.2.48).
  ///
  /// Per-`State`, not process-wide: `DetailPane` re-keys this page per
  /// conversation (`ValueKey('files-$id')`), so leaving and re-entering the tab
  /// re-reads the disk — which is the honest way to keep the row current, and it
  /// keeps one page's verdict out of another's (and out of the next test in the
  /// same process).
  final SourceAvailability _sources = SourceAvailability();

  /// The `id|path` signature of the attachments last probed, so a rebuild caused
  /// by anything else (a scroll, a hover, a transfer tick) does not re-stat the
  /// whole conversation.
  String _probed = '';

  /// Whether a probe is already walking the list.
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolved here, not in `initState`: `context.deps` needs the `AppScope`
    // above this widget.
    _probeIfNeeded();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(ConversationFiles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) {
      return;
    }
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    _probeIfNeeded();
  }

  /// The history changes (a load finishing, a send recorded, a delete): the set
  /// of files may have changed with it.
  void _onControllerChanged() => _probeIfNeeded();

  /// Probes the conversation's attachments when — and only when — the set of
  /// them changed since the last probe.
  ///
  /// The history arrives **after** this page mounts (`ConversationController
  /// .load` is async), so a probe done once in `didChangeDependencies` would
  /// usually look at an empty list; the controller listener is what catches the
  /// real fill.
  void _probeIfNeeded() {
    if (!mounted || _probing) {
      return;
    }
    final List<FileAttachment> files = _allFiles();
    final String signature = <String>[
      for (final FileAttachment file in files) '${file.id}|${file.localPath}',
    ].join('\u0000');
    if (signature == _probed) {
      return;
    }
    unawaited(_probe(files, signature));
  }

  Future<void> _probe(List<FileAttachment> files, String signature) async {
    _probing = true;
    try {
      await _sources.probeFiles(files, context.deps.platform);
      _probed = signature;
    } finally {
      _probing = false;
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Every attachment of the loaded history, in timeline order.
  List<FileAttachment> _allFiles() {
    final List<ChatMessage> messages =
        widget.controller.messages.valueOrNull ?? const <ChatMessage>[];
    return <FileAttachment>[
      for (final ChatMessage message in messages)
        ...widget.controller.filesOf(message.id),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // A short fade on switch (PRD §2.5); the transparent [Material] hosts the
    // file rows' hover / tap ink above this pane's opaque surface colour.
    return FadeIn(
      child: Material(
        type: MaterialType.transparency,
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (BuildContext context, Widget? child) => _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (widget.controller.messages.isLoading) {
      // Loading ≠ empty (H38): the ready-to-render list is "being assembled".
      return const LoadingState(message: '正在整理本会话文件…', showProgress: false);
    }
    final List<ChatMessage> messages =
        widget.controller.messages.valueOrNull ?? const <ChatMessage>[];
    final Map<String, List<FileAttachment>> filesByMessage =
        <String, List<FileAttachment>>{
      for (final ChatMessage message in messages)
        message.id: widget.controller.filesOf(message.id),
    };
    final List<ConversationFileItem> items = buildConversationFiles(
      messages: messages,
      filesByMessage: filesByMessage,
    );
    if (items.isEmpty) {
      return const EmptyState.conversationFiles();
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: <Widget>[
        for (final ConversationFileItem item in items) _row(context, item),
      ],
    );
  }

  /// One file line: thumbnail / type icon + name + size + direction + time
  /// (E21). Tapping opens the file when its path is known.
  ///
  /// A file the probe found missing is drawn the way every other surface draws
  /// it — dimmed, with 「文件已不在原位置」 in place of the size — and the tap is
  /// still answered (see [_open]): `FileTile` deliberately drops its `InkWell`
  /// for an unavailable row, so the notice has to come from a wrapper, or the row
  /// would be exactly the dead click this release removes.
  Widget _row(BuildContext context, ConversationFileItem item) {
    final String? path = item.file.localPath;
    final bool unavailable = !_sources.isOnDisk(path);
    final ThemeData theme = Theme.of(context);
    final Widget tile = FileTile(
      fileName: item.file.fileName,
      size: item.file.size,
      mime: item.file.mime,
      path: path,
      unavailable: unavailable,
      onTap: path == null ? null : () => unawaited(_open(path)),
      trailing: Text(
        '${directionText(item.direction)} · ${timeText(item.messageCreatedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
    if (!unavailable || path == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: tile,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GestureDetector(
        // The row already says why, so this is not the only feedback — but a tap
        // that is silently ignored is the exact defect 0.2.48 fixes, and this is
        // cheaper than a second `FileTile` flag.
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_open(path)),
        child: tile,
      ),
    );
  }

  /// Opens [path], or says why it cannot.
  ///
  /// One method for both cases (a row the probe believes is there, and one it
  /// knows is not) so there is a single answer for "the user pressed 打开":
  ///  * the file is missing → mark it, repaint the row as unavailable, and say
  ///    「文件已不在原位置，无法打开」 (the wording `showAttachmentDetails` uses for
  ///    the same fact; the label the row prints is the shorter one);
  ///  * the platform refuses to open it → say so, instead of looking ignored.
  ///
  /// The messenger is captured before the first `await` — same rule as
  /// `attachment_menu.dart`, which this deliberately mirrors.
  ///
  /// 2026-11-10：本体搬进了 [openLocalPath]（与设备墙、时间线共用一份实现）。
  Future<void> _open(String path) => openLocalPath(
        context,
        path: path,
        sources: _sources,
        onRepaint: () => setState(() {}),
      );
}
