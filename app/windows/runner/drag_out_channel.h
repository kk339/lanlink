#ifndef RUNNER_DRAG_OUT_CHANNEL_H_
#define RUNNER_DRAG_OUT_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Registers the "lanlink/drag_out" method channel: one method, `startDrag`.
//
// The Dart side hands over the **local paths** of the files the user grabbed and
// the runner runs a real OLE drag-and-drop session (`DoDragDrop`) on them, so a
// file in the conversation can be dropped on the desktop, on Explorer, or into
// another application. The only format offered is `CF_HDROP` and the only
// allowed effect is `DROPEFFECT_COPY` -- see `drag_out_channel.cpp` for why that
// pair is deliberate (it is what keeps a same-volume drop from **moving** the
// user's file away).
//
// `window` is the top-level HWND; OLE needs one to own the modal drag loop.
//
// Everything here is hand-written over `ole32`/`uuid`/`user32` -- no plugin, and
// in particular **no Rust**: this project chose a pure-Dart base deliberately.
void RegisterDragOutChannel(flutter::BinaryMessenger* messenger, HWND window);

#endif  // RUNNER_DRAG_OUT_CHANNEL_H_
