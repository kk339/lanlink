/// Per-conversation **composer drafts** — the text a user typed but did not
/// send (0.2.27).
///
/// **The defect this answers** (user report, verbatim): *"输入框那里，如果我输入了
/// 一些东西但是没点发送，换到下一个会话再回来，输入的东西就没了"*. `ConversationThread`
/// used to own the composer's [TextEditingController] in its `State`, and the
/// State is **rebuilt** on every conversation switch (`DetailPane` keys the
/// thread per conversation id and builds a new `ConversationController` per
/// selection), so the text went away with it.
///
/// **Why a store and not just a longer-lived widget:** the surviving state has to
/// outlive *every* object that belongs to one conversation — the thread's State,
/// the controller, and even the `DetailPane` itself (on a narrow window, going
/// back to the list unmounts the detail pane entirely). Only something that
/// lives for the **process** can hold "the text I typed in conversation A" while
/// the user is looking at conversation B. So this is a plain in-memory map keyed
/// by conversation id, owned above the UI layer.
///
/// **Deliberately memory-only, deliberately not a `ChangeNotifier`.**
/// * Not persisted: a draft is a *transient* intention. Writing it to the
///   database would mean a half-typed sentence survives a restart and reappears
///   days later, which is a different (and slightly alarming) product.
/// * Not listenable: the composer already owns the only widget that must repaint
///   (`TextField`), and a `notifyListeners()` per keystroke would rebuild the
///   whole thread — timeline, banners and all — for a character the field itself
///   is already drawing. [save] is therefore a silent write.
///
/// **Layering (M4 §8.1):** pure Dart, no `package:flutter/*`, no `dart:io`. It is
/// reachable from a controller and unit-testable with no widget tree.
library;

/// The in-memory store of un-sent composer text, keyed by conversation id.
///
/// One instance per process in production —
/// [ComposerDraftStore.shared], handed to every `ConversationController` — but
/// nothing forces that: the constructor is public so a test (or a future
/// multi-window build) can own its own.
class ComposerDraftStore {
  /// Creates an empty store.
  ComposerDraftStore();

  /// The store the app uses: one per process, shared by every conversation.
  ///
  /// **Why a shared default rather than a parameter threaded down from the
  /// shell:** `ConversationController` is built by `DetailPane` **per
  /// selection**, and the widget tree offers no app-lifetime holder that the
  /// thread can reach without a new package. A single instance on the domain
  /// layer is the smallest thing that is genuinely process-wide, and it stays
  /// *injectable* (the constructor above), which is what keeps it testable and
  /// keeps the widget layer free of any global.
  static final ComposerDraftStore shared = ComposerDraftStore();

  /// conversation id → the exact text the user left in that composer.
  ///
  /// Invariant: **no entry ever holds a blank string** (see [save]), so
  /// "id is a key of this map" means "this conversation has a real draft".
  final Map<String, String> _drafts = <String, String>{};

  /// The draft of [conversationId], or `''` when it has none.
  ///
  /// Empty string (not `null`) on purpose: the one consumer is a
  /// `TextEditingController`, whose "no draft" value *is* the empty string, and
  /// a nullable result would only push that `.orEmpty` conversion to every call
  /// site.
  String draftFor(String conversationId) => _drafts[conversationId] ?? '';

  /// Whether [conversationId] holds a draft at all.
  ///
  /// Equivalent to `draftFor(id).isNotEmpty` by the store's invariant, but
  /// spelled out where the question is "is there anything to restore?" rather
  /// than "what is it?".
  bool hasDraft(String conversationId) =>
      (_drafts[conversationId] ?? '').isNotEmpty;

  /// Stores [text] as [conversationId]'s draft — **silently**, no notification.
  ///
  /// **Whitespace-only (or empty) text is not a draft**: it removes the entry
  /// instead. A composer the user emptied must come back *empty*, and leaving
  /// `'   '` behind would restore three invisible spaces and (worse) count as
  /// "has a draft" for anything asking that question later.
  ///
  /// The **raw** text is stored — not a trimmed copy — so a restored draft is
  /// character-for-character what the user typed (a trailing space there is a
  /// typo the user can still fix, and silently editing it would be worse).
  void save({required String conversationId, required String text}) {
    if (text.trim().isEmpty) {
      _drafts.remove(conversationId);
      return;
    }
    _drafts[conversationId] = text;
  }

  /// Forgets [conversationId]'s draft. Returns whether there was one.
  ///
  /// Called when the text has become a message ([ConversationController
  /// .sendText]) — including a send that then **fails**: the text is already a
  /// bubble in the timeline, so putting it back in the composer would offer to
  /// send it twice.
  bool clear(String conversationId) => _drafts.remove(conversationId) != null;

  /// How many conversations currently hold a draft (test / diagnostics).
  int get length => _drafts.length;

  /// The ids that currently hold a draft, in insertion order (test convenience).
  Iterable<String> get conversationIds => _drafts.keys;

  /// Drops every draft (test isolation; nothing in the app calls it).
  void clearAll() => _drafts.clear();

  @override
  String toString() => 'ComposerDraftStore(${_drafts.length} draft(s))';
}
