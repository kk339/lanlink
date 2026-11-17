#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <cstdio>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// The smallest window the three-pane shell may be dragged down to.
//
// These two numbers are MEASURED ON THE REAL RUNNER WINDOW, NOT CHOSEN. They
// answer the P3 note in docs/21 (remaining work) section 2.7 -- "the window can
// be dragged arbitrarily small, and the three-pane layout overflows by 3.4 px at
// some width". The fix for that note is deliberately NOT a layout change: it is
// to stop the window from ever reaching a size the layout was never designed
// for.
//
// How they were measured: `flutter build windows --debug`, launch the runner,
// open a real conversation, then sweep the CLIENT area one pixel at a time with
// SetWindowPos and read it back. A debug build paints a RenderFlex overflow as a
// yellow/black band, so counting those pixels per frame finds the exact size at
// which the layout first breaks. Every sweep was confirmed twice -- once on the
// real window (real fonts, real content) and once in a widget test, which
// cross-checks the number because the two paths use different text metrics.
//
// Width -- 784. NOTE: the 3.4 px overflow the note describes did NOT reproduce
// here. The client width was swept 1280 -> 704 in 1 px steps with a real
// conversation open, and 1400 -> 380 in widget tests across 13 states, DPR
// 1.25-2.0 and text scale 1.15-1.5: no width overflows. So the width has no
// measured overflow boundary; what it has is a DESIGN floor. Below
// kNarrowBreakpoint (760, ui/shell/shell_module.dart) the shell is no longer
// three panes at all -- it degrades to the two-level phone shell with a bottom
// navigation bar. Staying above that floor plus the same 24 px margin gives
// 760 + 24 = 784, already a multiple of 8, and it keeps the window out of the
// sizes the note was about. At 784 the middle pane is the compact 280 and the
// conversation column still gets 424 px, above the design's kDetailMinWidth
// (360).
//
// Height -- 480. The same downward sweep DOES find a real boundary: 316 is the
// shortest client height that lays out clean, and at 315 the navigation rail
// overflows by exactly 1 px. That number came out identical on the real window
// (measured at 1280 and at 784 wide) and in the widget test, which is what makes
// it trustworthy. 316 + 24 = 340, and 344 would be the bare 8-aligned minimum --
// but at 344 the thread shows about 1.5 bubbles, which is too cramped, so the
// shipped floor is 480: still 8-aligned, and it fits the conversation header, a
// full composer and three bubbles (checked against screenshots of the real
// window).
//
// Both values are DIPs (96 dpi). WindowSizeForContent converts them to the
// physical, frame-included rectangle that ptMinTrackSize wants.
constexpr int kMinimumContentWidth = 784;
constexpr int kMinimumContentHeight = 480;

using AdjustWindowRectExForDpiFn = BOOL(WINAPI*)(LPRECT, DWORD, BOOL, DWORD,
                                                 UINT);

// Returns the window size (frame included, physical pixels) whose client
// area is |client_width| x |client_height| DIPs on |window|'s monitor.
//
// ptMinTrackSize is a window rectangle, so the non-client frame has to be
// added back -- and because that frame itself grows with the DPI, the
// addition has to happen at the monitor's scale instead of at a fixed 96 dpi.
SIZE WindowSizeForContent(HWND window, int client_width, int client_height) {
  const UINT dpi = FlutterDesktopGetDpiForHWND(window);
  const double scale_factor = dpi / 96.0;
  RECT rect = {0, 0, Scale(client_width, scale_factor),
               Scale(client_height, scale_factor)};
  const DWORD style = static_cast<DWORD>(GetWindowLongPtr(window, GWL_STYLE));
  const DWORD ex_style =
      static_cast<DWORD>(GetWindowLongPtr(window, GWL_EXSTYLE));

  // `AdjustWindowRectExForDpi` is the DPI-correct way to size the frame, but it
  // only exists from Windows 10 1607 on, so it is resolved at run time rather
  // than linked against.
  static const AdjustWindowRectExForDpiFn adjust_for_dpi =
      reinterpret_cast<AdjustWindowRectExForDpiFn>(GetProcAddress(
          GetModuleHandle(L"user32.dll"), "AdjustWindowRectExForDpi"));
  BOOL adjusted = FALSE;
  if (adjust_for_dpi != nullptr) {
    adjusted = adjust_for_dpi(&rect, style, FALSE, ex_style, dpi);
  }
  if (!adjusted) {
    // Older Windows: `AdjustWindowRectEx` answers for this process at 96 dpi,
    // so scale both the client box and the frame it adds.
    RECT base = {0, 0, client_width, client_height};
    if (AdjustWindowRectEx(&base, style, FALSE, ex_style)) {
      const int frame_width = (base.right - base.left) - client_width;
      const int frame_height = (base.bottom - base.top) - client_height;
      rect = {0, 0,
              Scale(client_width, scale_factor) +
                  Scale(frame_width, scale_factor),
              Scale(client_height, scale_factor) +
                  Scale(frame_height, scale_factor)};
    }
  }

  SIZE size;
  size.cx = rect.right - rect.left;
  size.cy = rect.bottom - rect.top;
  return size;
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_GETMINMAXINFO: {
      // The window may not be dragged (or maximized/restored) smaller than the
      // size at which the three-pane layout still fits -- see
      // kMinimumContentWidth / kMinimumContentHeight.
      //
      // The default handler is asked first so that everything else in the
      // structure (the maximum tracking size, the maximized position/size) keeps
      // Windows' own answer; only the minimum tracking size is clamped.
      const LRESULT result = DefWindowProc(hwnd, message, wparam, lparam);
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const SIZE minimum = WindowSizeForContent(
          hwnd, kMinimumContentWidth, kMinimumContentHeight);
      info->ptMinTrackSize.x = minimum.cx;
      info->ptMinTrackSize.y = minimum.cy;

      // Report the clamp once (per size), because "the window stops shrinking"
      // is otherwise only observable by dragging it -- with the number printed
      // here, `flutter run` (or a console run of the debug build) shows the
      // physical rectangle Windows was given, e.g.
      //   lanlink: minimum window 800x519 physical (content 784x480 at dpi 96)
      // which is how the value was verified against the real window.
      static SIZE reported = {0, 0};
      if (minimum.cx != reported.cx || minimum.cy != reported.cy) {
        reported = minimum;
        fprintf(stderr,
                "lanlink: minimum window %ldx%ld physical (content %dx%d at "
                "dpi %u)\n",
                minimum.cx, minimum.cy, kMinimumContentWidth,
                kMinimumContentHeight, FlutterDesktopGetDpiForHWND(hwnd));
        fflush(stderr);
      }
      return result;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
