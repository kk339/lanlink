/// The three-pane shell's shared UI state (design §2 — the single source of
/// truth for "current module + middle-pane selection + right tab + narrow
/// detail state").
///
/// It lives in `ui/` and extends [ChangeNotifier], so it introduces no state
/// management library and does not touch the frozen `controllers/` (design
/// §2.2). [ShellPage] creates the one instance and hands it to `NavRail` /
/// `ListPane` / `DetailPane`; all three read from it, so the highlighted middle
/// row and the right pane can never disagree (PRD E16).
///
/// **Layering (design §9.6):** imports only `package:flutter/foundation` and
/// this package's `domain/**` — never `dart:io` / `dart:ffi` / `lanlink_core` /
/// `lanlink_store`.
library;

import 'package:flutter/foundation.dart';

import '../../controllers/conversation_controller.dart';
import '../../domain/models.dart';
import '../../domain/session_repository.dart';
import 'shell_module.dart';

/// The shell's current module, selections, right tab and narrow-window mode.
class ShellController extends ChangeNotifier {
  /// The controller of the conversation currently open in the detail pane, or
  /// `null` (0.2.41).
  ///
  /// **Why the shell has to hold it.** On a phone the conversation's overflow menu
  /// (⋯) lives in `phone_shell`, while the multi-select state lives on the
  /// per-conversation [ConversationController] (see the note in that class: the
  /// selection must die with the conversation). The two are siblings, so the shell
  /// keeps the one reference that lets 「多选」 reach it. `DetailPane` owns the
  /// lifetime: it sets this when it creates the controller and clears it when it
  /// disposes one — never the other way round.
  ConversationController? conversationController;

  /// Creates the shell state.
  ///
  /// [initialModule] / [initialPeer] / [initialFileId] / [initialFileMessageId]
  /// are the test/deep-link entry points (production leaves them at their
  /// defaults) so each old widget test can still mount one widget and assert
  /// (design §8.1). When [initialPeer] is given it is selected immediately,
  /// which resolves (or opens) the active conversation.
  ShellController({
    required SessionRepository repo,
    ShellModule initialModule = ShellModule.conversations,
    PeerDevice? initialPeer,
    String? initialFileId,
    String? initialFileMessageId,
  })  : _repo = repo,
        _module = initialModule {
    if (initialPeer != null) {
      _selectPeer(initialPeer);
    }
    if (initialFileId != null) {
      _selectedFileId = initialFileId;
      _selectedFileMessageId = initialFileMessageId;
    }
  }

  final SessionRepository _repo;

  ShellModule _module;
  String? _selectedFingerprint;
  String? _selectedConversationId;
  String? _selectedFileId;
  String? _selectedFileMessageId;
  RightTab _rightTab = RightTab.messages;
  String _conversationQuery = '';
  bool _detailVisible = false;

  /// Phone only: whether the conversations module's search field is revealed.
  ///
  /// Collapsed by default (M5c §3 — "usually 1–3 devices", so an always-on
  /// search box is a desktop habit); the phone shell reveals it from its ⋮ menu.
  /// The desktop keeps the field always visible (`ListPane.showHeader`) and never
  /// reads this.
  bool _conversationSearchVisible = false;

  /// The active module (drives the middle pane body and the rail highlight).
  ShellModule get module => _module;

  /// Conversation module: the middle-pane selected row's device fingerprint
  /// (`null` = nothing selected). **The one key shared by the highlight and the
  /// right pane** (PRD E16).
  String? get selectedFingerprint => _selectedFingerprint;

  /// Conversation module: the conversation shown on the right (resolved from
  /// the selected peer via `openActive`).
  String? get selectedConversationId => _selectedConversationId;

  /// Recent-files module: the middle-pane selected row (drives the file
  /// detail on the right).
  String? get selectedFileId => _selectedFileId;

  /// The message the selected recent file belongs to.
  String? get selectedFileMessageId => _selectedFileMessageId;

  /// The right pane tab within the conversation module.
  RightTab get rightTab => _rightTab;

  /// Conversation module: the local device-name filter (PRD §3.4-④).
  String get conversationQuery => _conversationQuery;

  /// Narrow windows only: `true` = show the right pane, `false` = the list.
  /// Ignored on wide/compact windows (they always show both).
  bool get detailVisible => _detailVisible;

  /// Phone only: whether the conversations module's search field is shown
  /// (see [_conversationSearchVisible]).
  bool get conversationSearchVisible => _conversationSearchVisible;

  /// Switches the left-rail module.
  ///
  /// **Never clears any module's selection**, so switching away and back returns
  /// to where you were (design §2.4 / PRD E16). The phone-only search field is
  /// re-collapsed on a module change (M5c §3).
  void selectModule(ShellModule value) {
    if (_module == value) {
      return;
    }
    _module = value;
    _conversationSearchVisible = false;
    notifyListeners();
  }

  /// Phone only: shows / hides the conversations module's search field (M5c §3).
  void toggleConversationSearch() {
    _conversationSearchVisible = !_conversationSearchVisible;
    notifyListeners();
  }

  /// Selects a middle-pane device row: remembers the fingerprint, resolves (or
  /// opens) its active conversation, and shows the detail on a narrow window.
  void selectPeer(PeerDevice peer) {
    _selectPeer(peer);
    notifyListeners();
  }

  /// Selects a recent-file row for the right-pane file detail.
  void selectRecentFile({required String fileId, required String messageId}) {
    _selectedFileId = fileId;
    _selectedFileMessageId = messageId;
    _detailVisible = true;
    notifyListeners();
  }

  /// Clears every selection (all modules).
  void clearSelection() {
    if (_selectedFingerprint == null &&
        _selectedConversationId == null &&
        _selectedFileId == null &&
        _selectedFileMessageId == null) {
      return;
    }
    _selectedFingerprint = null;
    _selectedConversationId = null;
    _selectedFileId = null;
    _selectedFileMessageId = null;
    notifyListeners();
  }

  /// Switches the right-pane tab (messages ⇄ files).
  void setRightTab(RightTab value) {
    if (_rightTab == value) {
      return;
    }
    _rightTab = value;
    notifyListeners();
  }

  /// Sets the device-name filter of the conversation module.
  void setConversationQuery(String value) {
    if (_conversationQuery == value) {
      return;
    }
    _conversationQuery = value;
    notifyListeners();
  }

  /// Narrow windows: list → detail.
  void openDetail() {
    if (_detailVisible) {
      return;
    }
    _detailVisible = true;
    notifyListeners();
  }

  /// Narrow windows: detail → list.
  ///
  /// Only flips the display flag — the module and every selection are kept, so
  /// the row is still highlighted on return (design §6.1).
  void closeDetail() {
    if (!_detailVisible) {
      return;
    }
    _detailVisible = false;
    notifyListeners();
  }

  void _selectPeer(PeerDevice peer) {
    _selectedFingerprint = peer.fingerprint;
    _selectedConversationId =
        _repo.openActive(deviceFingerprint: peer.fingerprint).id;
    _detailVisible = true;
  }
}
