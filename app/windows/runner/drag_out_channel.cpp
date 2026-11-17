#include "drag_out_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <objidl.h>
#include <ole2.h>
#include <oleidl.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

// NOTE: this file is deliberately ASCII-only. MSVC without /utf-8 reads source
// as the ANSI code page, so a non-ASCII byte in a comment can break the build.
//
// What this file is, in one paragraph: the smallest honest Windows drag **source**
// there is. A drag source is three things -- an `IDataObject` that can hand the
// dropped target the payload (`CF_HDROP`, i.e. a `DROPFILES` header followed by a
// double-NUL-terminated list of wide paths), an `IDropSource` that answers "keep
// going / drop / cancel" while the mouse moves, and a call to `DoDragDrop`, which
// is the modal loop that actually talks to Explorer. Everything else in this file
// is validation, ownership bookkeeping and one switchable diagnostic line.
//
// **Why `DROPEFFECT_COPY` and nothing else.** Explorer's own default for a drag
// inside one volume is MOVE: drop a file from `C:\Users\x\Downloads` onto
// `C:\Users\x\Desktop` and the original is gone. The file the user drags out of
// this app is a *received* file that the conversation still refers to (open /
// reveal / resend all point at it), so a move would silently break the message it
// came from. Declaring COPY as the only allowed effect is what makes the shell
// copy instead.
//
// **What COPY does *not* guarantee (corrected 0.2.48).** It is an offer, not a
// lock: `dwEffect` tells the target which effects we *permit*, and every
// well-behaved shell target (Explorer included) picks from that set -- which is
// why an ordinary drag to the Desktop is a copy. But a target is free to ignore
// the offer entirely: it already holds absolute paths from `CF_HDROP`, so it can
// just `MoveFile` them (WinRAR's "delete source after archiving", third-party
// "move to folder" shell extensions). Nothing on the source side can prevent
// that.
//
// So the real safeguard is not this flag -- it is the post-drag existence check
// on the Dart side (`ConversationController`), which turns "the file is gone"
// into a visible `sourceUnavailable` state instead of a dead click. Keep both:
// the flag makes move *unlikely*, the check makes it *harmless*.

namespace {

using Microsoft::WRL::ComPtr;

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

// One switch for the whole file: `set LANLINK_DRAG_OUT_LOG=1` (any value except
// "0") and every drag prints its paths, the allowed effect and the final effect
// to the debugger and to the console when one is attached (`flutter run`).
//
// It exists because the interesting half of this feature -- "does the file
// actually land on the desktop?" -- cannot be asserted from a unit test: it is
// Explorer's answer, not ours. With the log on, a user's report comes back with
// the paths and the effect in it.
bool DragLogEnabled() {
  static int cached = -1;  // -1 = not asked yet; GetEnvironmentVariableW per
                           // drag would be a syscall in the middle of a gesture.
  if (cached < 0) {
    wchar_t value[8] = {};
    const DWORD written =
        GetEnvironmentVariableW(L"LANLINK_DRAG_OUT_LOG", value, 8);
    cached = (written > 0 && value[0] != L'0') ? 1 : 0;
  }
  return cached == 1;
}

// UTF-16 -> UTF-8, for the console copy of a log line.
std::string Utf8Of(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int needed = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                         static_cast<int>(wide.size()), nullptr,
                                         0, nullptr, nullptr);
  if (needed <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      utf8.data(), needed, nullptr, nullptr);
  return utf8;
}

void DragLog(const std::wstring& line) {
  if (!DragLogEnabled()) {
    return;
  }
  // The debugger / DebugView copy: works in a release build with no console.
  OutputDebugStringW(L"[lanlink drag] ");
  OutputDebugStringW(line.c_str());
  OutputDebugStringW(L"\n");
  // The console copy: `flutter run`, or CreateAndAttachConsole when a debugger is
  // present. fprintf (not fwprintf) so this never fights the narrow `fprintf`
  // calls `win32_window.cpp` already makes on the same stream.
  const std::string utf8 = Utf8Of(line);
  fprintf(stderr, "[lanlink drag] %s\n", utf8.c_str());
  fflush(stderr);
}

// UTF-8 (Dart's String) -> UTF-16 (Win32). The app lives under a path with
// Chinese characters, so a byte-widen would corrupt every path.
std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int needed = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                         static_cast<int>(utf8.size()), nullptr,
                                         0);
  if (needed <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      wide.data(), needed);
  return wide;
}

// ---------------------------------------------------------------------------
// The payload: CF_HDROP
// ---------------------------------------------------------------------------

// Builds the `DROPFILES` block OLE hands to the drop target.
//
// Field by field (the values are the whole contract):
//   * `pFiles` = `sizeof(DROPFILES)` -- offset of the file list from the start of
//     the block. It is *this struct's* size, not a fixed 20: the struct is 20
//     bytes on x86/x64 (DWORD + POINT{LONG,LONG} + BOOL + BOOL) and writing it
//     out of `sizeof` is what keeps the list aligned if the SDK ever changes it.
//   * `fWide` = TRUE -- the list is UTF-16, not ANSI. Forced, because the paths
//     come from Dart as UTF-16-ish wide strings and an ANSI list would mangle
//     every non-ASCII name on a Chinese Windows.
//   * `pt` = {0,0} -- the drop point, in screen coordinates. The shell does not
//     use it for a `CF_HDROP` drop; zero is the conventional value.
//   * `fNC` = FALSE -- the drop did not happen on a non-client area.
// The list itself is each path followed by its own NUL, then **one more NUL** to
// terminate the sequence ("double NUL"), which is what the shell scans for.
HGLOBAL BuildDropFiles(const std::vector<std::wstring>& paths) {
  SIZE_T characters = 1;  // the terminating NUL of the whole list
  for (const std::wstring& path : paths) {
    characters += path.size() + 1;  // path + its own NUL
  }
  const SIZE_T bytes = sizeof(DROPFILES) + characters * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
  if (memory == nullptr) {
    return nullptr;
  }
  auto* files = static_cast<DROPFILES*>(GlobalLock(memory));
  if (files == nullptr) {
    GlobalFree(memory);
    return nullptr;
  }
  files->pFiles = sizeof(DROPFILES);
  files->pt.x = 0;
  files->pt.y = 0;
  files->fNC = FALSE;
  files->fWide = TRUE;
  auto* list = reinterpret_cast<wchar_t*>(reinterpret_cast<BYTE*>(files) +
                                          sizeof(DROPFILES));
  for (const std::wstring& path : paths) {
    // `size() + 1` wide characters: the text **and** its NUL.
    memcpy(list, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
    list += path.size() + 1;
  }
  *list = L'\0';  // the second NUL (GMEM_ZEROINIT already did it; be explicit)
  GlobalUnlock(memory);
  return memory;
}

// ---------------------------------------------------------------------------
// IEnumFORMATETC -- the "what can you offer?" answer
// ---------------------------------------------------------------------------

// One format, `CF_HDROP`, on `TYMED_HGLOBAL`. Explorer asks `QueryGetData` in
// practice, but a target is allowed to enumerate instead, and an `E_NOTIMPL`
// there would make an otherwise working drop fail for no reason. `Next` is the
// only method with real behaviour.
class DropFormatEnumerator final : public IEnumFORMATETC {
 public:
  explicit DropFormatEnumerator(const FORMATETC& format) : format_(format) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) {
      return E_INVALIDARG;
    }
    *object = nullptr;
    if (iid == IID_IUnknown || iid == IID_IEnumFORMATETC) {
      *object = static_cast<IEnumFORMATETC*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&references_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const LONG remaining = InterlockedDecrement(&references_);
    if (remaining == 0) {
      delete this;
    }
    return static_cast<ULONG>(remaining);
  }

  HRESULT STDMETHODCALLTYPE Next(ULONG count, FORMATETC* formats,
                                 ULONG* fetched) override {
    if (formats == nullptr) {
      return E_INVALIDARG;
    }
    ULONG written = 0;
    if (index_ == 0 && count > 0) {
      *formats = format_;
      written = 1;
      index_ = 1;
    }
    if (fetched != nullptr) {
      *fetched = written;
    }
    return written == count ? S_OK : S_FALSE;
  }

  HRESULT STDMETHODCALLTYPE Skip(ULONG count) override {
    index_ += count;
    return index_ > 1 ? S_FALSE : S_OK;
  }

  HRESULT STDMETHODCALLTYPE Reset() override {
    index_ = 0;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Clone(IEnumFORMATETC** clone) override {
    if (clone == nullptr) {
      return E_INVALIDARG;
    }
    auto* copy = new DropFormatEnumerator(format_);
    copy->index_ = index_;
    *clone = copy;
    return S_OK;
  }

 private:
  ~DropFormatEnumerator() = default;

  LONG references_ = 1;
  FORMATETC format_{};
  ULONG index_ = 0;
};

// ---------------------------------------------------------------------------
// IDataObject
// ---------------------------------------------------------------------------

// Offers exactly one format -- `CF_HDROP` -- and refuses everything else.
//
// **Why so minimal.** A drag source only has to answer what it advertises: the
// target asks `QueryGetData(CF_HDROP)`, sees `S_OK`, and then calls `GetData`
// once. Implementing the remaining methods (advise sinks, `SetData`,
// `GetDataHere`) would be dead code with a maintenance cost and no user-visible
// behaviour.
class DragDataObject final : public IDataObject {
 public:
  explicit DragDataObject(std::vector<std::wstring> paths)
      : paths_(std::move(paths)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) {
      return E_INVALIDARG;
    }
    *object = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDataObject) {
      *object = static_cast<IDataObject*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&references_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const LONG remaining = InterlockedDecrement(&references_);
    if (remaining == 0) {
      delete this;
    }
    return static_cast<ULONG>(remaining);
  }

  // The target's "give me the files" call. Builds a fresh HGLOBAL per call:
  // ownership of a `STGMEDIUM`'s handle passes to the caller, which frees it with
  // `ReleaseStgMedium`, so handing out a shared block would be a double free.
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format,
                                    STGMEDIUM* medium) override {
    if (format == nullptr || medium == nullptr) {
      return E_INVALIDARG;
    }
    if (!IsHdropFormat(format) || paths_.empty()) {
      return DV_E_FORMATETC;
    }
    HGLOBAL block = BuildDropFiles(paths_);
    if (block == nullptr) {
      return STG_E_MEDIUMFULL;
    }
    medium->tymed = TYMED_HGLOBAL;
    medium->hGlobal = block;
    medium->pUnkForRelease = nullptr;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC* format,
                                        STGMEDIUM* medium) override {
    (void)format;
    (void)medium;
    return E_NOTIMPL;  // only TYMED_HGLOBAL is offered, and that cannot be
                       // rendered into a caller's buffer
  }

  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* format) override {
    if (format == nullptr) {
      return E_INVALIDARG;
    }
    return IsHdropFormat(format) && !paths_.empty() ? S_OK : DV_E_FORMATETC;
  }

  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC* input,
                                                  FORMATETC* output) override {
    (void)input;
    if (output != nullptr) {
      // NULL means "the format you passed is already canonical".
      output->ptd = nullptr;
    }
    return DATA_S_SAMEFORMATETC;
  }

  HRESULT STDMETHODCALLTYPE SetData(FORMATETC* format, STGMEDIUM* medium,
                                    BOOL release) override {
    (void)format;
    (void)medium;
    (void)release;
    return E_NOTIMPL;  // a drag source never accepts data back
  }

  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction,
                                          IEnumFORMATETC** enumerator) override {
    if (enumerator == nullptr) {
      return E_INVALIDARG;
    }
    *enumerator = nullptr;
    if (direction != DATADIR_GET) {
      return E_NOTIMPL;  // DATADIR_SET: nothing to set
    }
    if (paths_.empty()) {
      return S_FALSE;
    }
    *enumerator = new DropFormatEnumerator(HdropFormat());
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC* format, DWORD flags,
                                    IAdviseSink* sink,
                                    DWORD* connection) override {
    (void)format;
    (void)flags;
    (void)sink;
    (void)connection;
    return OLE_E_ADVISENOTSUPPORTED;
  }

  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD connection) override {
    (void)connection;
    return OLE_E_ADVISENOTSUPPORTED;
  }

  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA** enumerator) override {
    (void)enumerator;
    return OLE_E_ADVISENOTSUPPORTED;
  }

 private:
  ~DragDataObject() = default;

  // Whether [format] is the one thing we offer: `CF_HDROP` over `TYMED_HGLOBAL`,
  // as a whole object (`DVASPECT_CONTENT`). `lindex` is deliberately **not**
  // checked: -1 is the conventional value for "not a thumbnail", but a target is
  // free to ask with 0, and refusing that would break a drop that would otherwise
  // work.
  static bool IsHdropFormat(const FORMATETC* format) {
    return format->cfFormat == CF_HDROP &&
           (format->tymed & TYMED_HGLOBAL) != 0 &&
           format->dwAspect == DVASPECT_CONTENT;
  }

  static FORMATETC HdropFormat() {
    FORMATETC format{};
    format.cfFormat = static_cast<CLIPFORMAT>(CF_HDROP);
    format.ptd = nullptr;
    format.dwAspect = DVASPECT_CONTENT;
    format.lindex = -1;
    format.tymed = TYMED_HGLOBAL;
    return format;
  }

  LONG references_ = 1;
  std::vector<std::wstring> paths_;
};

// ---------------------------------------------------------------------------
// IDropSource
// ---------------------------------------------------------------------------

// The two answers OLE needs while the mouse is down. Both are the standard ones
// and both matter:
//   * `QueryContinueDrag` -- Esc cancels; releasing every mouse button drops.
//     Cancelling on Esc is what the user expects from every other drag in
//     Windows, and getting the button test wrong is how a drag gets stuck.
//   * `GiveFeedback` -- "draw your own drag image": returning
//     `DRAGDROP_S_USEDEFAULTCURSORS` lets OLE paint the + / no-drop cursors,
//     which is the whole visual feedback for a file drag.
class DragSource final : public IDropSource {
 public:
  DragSource() = default;

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) {
      return E_INVALIDARG;
    }
    *object = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDropSource) {
      *object = static_cast<IDropSource*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&references_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const LONG remaining = InterlockedDecrement(&references_);
    if (remaining == 0) {
      delete this;
    }
    return static_cast<ULONG>(remaining);
  }

  HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape_pressed,
                                              DWORD key_state) override {
    if (escape_pressed) {
      return DRAGDROP_S_CANCEL;
    }
    if ((key_state & (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON)) == 0) {
      return DRAGDROP_S_DROP;
    }
    // S_OK = keep dragging. Returning DRAGDROP_S_DROP here instead would end the
    // drag on the first mouse-move callback.
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD effect) override {
    (void)effect;
    return DRAGDROP_S_USEDEFAULTCURSORS;
  }

 private:
  ~DragSource() = default;

  LONG references_ = 1;
};

// ---------------------------------------------------------------------------
// Channel state
// ---------------------------------------------------------------------------

// The channel must outlive this function, so it lives here.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
HWND g_window = nullptr;
// S_OK / S_FALSE ("already initialised on this thread") / a failure. Recorded
// once at registration: `OleInitialize` is per-thread, and the method handler runs
// on the same (platform) thread, so asking again per drag would only add noise.
HRESULT g_ole_result = E_UNEXPECTED;

// "0x00000001" style hex, for the log and for error messages.
std::wstring HexOf(DWORD value) {
  wchar_t buffer[16] = {};
  swprintf_s(buffer, L"0x%08lX", static_cast<unsigned long>(value));
  return std::wstring(buffer);
}

// Maps what `DoDragDrop` reported to the four words the Dart side understands.
//
// `move` is in the list **on purpose** even though this drag source only allows
// `DROPEFFECT_COPY`: if a target ever answered MOVE anyway, the file may have been
// carried away, and the Dart side has to see that as a broken contract rather than
// as a silent success. Everything else (`LINK`, several bits at once, the
// `DRAGDROP_S_*` codes with a non-zero effect) degrades to `none`, which means
// "nothing was copied" and is never mistaken for a copy.
const char* EffectWord(HRESULT result, DWORD effect) {
  if (effect == DROPEFFECT_COPY) {
    return "copy";
  }
  if (effect == DROPEFFECT_MOVE) {
    return "move";
  }
  if (result == DRAGDROP_S_CANCEL) {
    return "canceled";
  }
  return "none";
}

}  // namespace

void RegisterDragOutChannel(flutter::BinaryMessenger* messenger, HWND window) {
  if (g_channel) {
    return;  // registered once per engine
  }
  g_window = window;
  // `main.cpp` already put this thread in an STA (`CoInitializeEx`), so the
  // expected answer here is S_FALSE -- "OLE was already available". A real failure
  // is remembered and reported per call instead of being swallowed: a drag that
  // cannot start must say so, never fail silently.
  g_ole_result = OleInitialize(nullptr);

  g_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "lanlink/drag_out",
          &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "startDrag") {
          result->NotImplemented();
          return;
        }
        if (FAILED(g_ole_result)) {
          DragLog(L"startDrag refused: OleInitialize failed " +
                  HexOf(static_cast<DWORD>(g_ole_result)));
          result->Error("ole_init_failed",
                        "OleInitialize failed, the drag loop is unavailable",
                        flutter::EncodableValue(static_cast<int32_t>(
                            static_cast<DWORD>(g_ole_result))));
          return;
        }
        // Args: a map with `paths` (List<String>). Required, because a drag with
        // no payload is not a drag.
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("bad_args", "expected a map");
          return;
        }
        const auto paths_it =
            arguments->find(flutter::EncodableValue("paths"));
        if (paths_it == arguments->end()) {
          result->Error("bad_args", "missing paths");
          return;
        }
        const auto* paths = std::get_if<flutter::EncodableList>(&paths_it->second);
        if (paths == nullptr || paths->empty()) {
          result->Error("bad_args", "paths must be a non-empty list");
          return;
        }

        std::vector<std::wstring> wide_paths;
        wide_paths.reserve(paths->size());
        for (const flutter::EncodableValue& entry : *paths) {
          const auto* path = std::get_if<std::string>(&entry);
          if (path == nullptr || path->empty()) {
            result->Error("bad_args", "every path must be a non-empty string");
            return;
          }
          std::wstring wide = Utf8ToWide(*path);
          if (wide.empty()) {
            result->Error("bad_args", "path is not valid UTF-8");
            return;
          }
          // A file that is not there cannot be dropped. This is a race guard only
          // (the Dart side checks first, and refuses to start at all): the file
          // can still vanish between that check and this line.
          if (GetFileAttributesW(wide.c_str()) == INVALID_FILE_ATTRIBUTES) {
            DragLog(L"skipped a path that is gone: " + wide);
            continue;
          }
          wide_paths.push_back(std::move(wide));
        }
        if (wide_paths.empty()) {
          DragLog(L"startDrag refused: no path on disk");
          result->Error("no_paths", "none of the paths exists on disk");
          return;
        }

        DragLog(L"startDrag paths=" +
                std::to_wstring(static_cast<unsigned long>(wide_paths.size())));
        for (size_t index = 0; index < wide_paths.size(); ++index) {
          DragLog(L"  path[" + std::to_wstring(static_cast<unsigned long>(index)) +
                  L"]=" + wide_paths[index]);
        }
        DragLog(L"allowed=DROPEFFECT_COPY (copy only: a move would take the "
                L"file away from the message it belongs to)");

        ComPtr<IDataObject> data_object;
        data_object.Attach(new DragDataObject(std::move(wide_paths)));
        ComPtr<IDropSource> drop_source;
        drop_source.Attach(new DragSource());

        DWORD effect = DROPEFFECT_NONE;
        // The modal loop. `SHDoDragDrop` is the shell's wrapper around OLE's own
        // `DoDragDrop`: same protocol, but it takes the window that owns the drag
        // (OLE's version infers one from the capture). It pumps messages --
        // including this window's `WM_PAINT` -- while the mouse is down, so the app
        // keeps looking alive; it returns when the user drops (with the effect the
        // target accepted), presses Esc (`DRAGDROP_S_CANCEL`) or the drag is
        // aborted.
        const HRESULT drag_result =
            SHDoDragDrop(g_window, data_object.Get(), drop_source.Get(),
                         DROPEFFECT_COPY, &effect);

        DragLog(L"result hr=" + HexOf(static_cast<DWORD>(drag_result)) +
                L" effect=" + HexOf(effect) + L" -> " +
                Utf8ToWide(EffectWord(drag_result, effect)));

        if (FAILED(drag_result)) {
          result->Error("drag_failed", "SHDoDragDrop failed",
                        flutter::EncodableValue(static_cast<int32_t>(
                            static_cast<DWORD>(drag_result))));
          return;
        }
        result->Success(
            flutter::EncodableValue(std::string(EffectWord(drag_result, effect))));
      });
}
