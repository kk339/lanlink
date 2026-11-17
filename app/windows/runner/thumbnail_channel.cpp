#include "thumbnail_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// NOTE: this file is deliberately ASCII-only. MSVC without /utf-8 reads source
// as the ANSI code page, so a non-ASCII byte in a comment can break the build.

namespace {

using Microsoft::WRL::ComPtr;

// UTF-8 (Dart's String) -> UTF-16 (Win32). This project lives under a path with
// Chinese characters, so a naive byte-widen would corrupt every path.
std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int needed = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      wide.data(), needed);
  return wide;
}

// HBITMAP -> PNG bytes, through WIC (no GDI+ dependency).
bool EncodePng(HBITMAP bitmap, std::vector<uint8_t>* out) {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
    return false;
  }
  ComPtr<IWICBitmap> frame;
  if (FAILED(factory->CreateBitmapFromHBITMAP(bitmap, nullptr,
                                              WICBitmapIgnoreAlpha, &frame))) {
    return false;
  }
  ComPtr<IStream> stream;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
    return false;
  }
  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) {
    return false;
  }
  ComPtr<IWICBitmapFrameEncode> frame_encode;
  ComPtr<IPropertyBag2> properties;
  if (FAILED(encoder->CreateNewFrame(&frame_encode, &properties)) ||
      FAILED(frame_encode->Initialize(properties.Get())) ||
      FAILED(frame_encode->WriteSource(frame.Get(), nullptr)) ||
      FAILED(frame_encode->Commit()) || FAILED(encoder->Commit())) {
    return false;
  }
  STATSTG stat{};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) {
    return false;
  }
  const ULONG size = stat.cbSize.LowPart;
  if (size == 0) {
    return false;
  }
  LARGE_INTEGER begin{};
  if (FAILED(stream->Seek(begin, STREAM_SEEK_SET, nullptr))) {
    return false;
  }
  out->resize(size);
  ULONG read = 0;
  if (FAILED(stream->Read(out->data(), size, &read)) || read != size) {
    out->clear();
    return false;
  }
  return true;
}

// One shell thumbnail for `path` at about `size` px. Empty on any failure, which
// the Dart side treats as "no frame" and falls back to the type icon.
std::vector<uint8_t> ExtractFrame(const std::wstring& path, int size) {
  std::vector<uint8_t> result;
  ComPtr<IShellItemImageFactory> factory;
  if (FAILED(SHCreateItemFromParsingName(path.c_str(), nullptr,
                                         IID_PPV_ARGS(&factory)))) {
    return result;
  }
  SIZE requested{};
  requested.cx = size;
  requested.cy = size;
  HBITMAP bitmap = nullptr;
  // THUMBNAILONLY is the important flag: without it the shell silently falls
  // back to the file's **icon**, and the UI would draw that icon at 240px --
  // the very "large empty block" this channel exists to remove. With it, a file
  // the system cannot thumbnail **fails here**, and the Dart side falls back to
  // the type icon at its normal size instead.
  // BIGGERSIZEOK: the provider may return a larger, better cached thumbnail.
  const SIIGBF flags =
      static_cast<SIIGBF>(SIIGBF_THUMBNAILONLY | SIIGBF_BIGGERSIZEOK);
  if (FAILED(factory->GetImage(requested, flags, &bitmap)) ||
      bitmap == nullptr) {
    return result;
  }
  EncodePng(bitmap, &result);
  DeleteObject(bitmap);
  return result;
}

// The channel must outlive this function, so it lives here.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

void RegisterThumbnailChannel(flutter::BinaryMessenger* messenger) {
  if (g_channel) {
    return;  // registered once per engine
  }
  g_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "lanlink/thumbnail",
          &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "videoFrame") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("bad_args", "expected a map");
          return;
        }
        const auto path_it =
            arguments->find(flutter::EncodableValue("path"));
        if (path_it == arguments->end()) {
          result->Error("bad_args", "missing path");
          return;
        }
        const auto* path = std::get_if<std::string>(&path_it->second);
        if (path == nullptr || path->empty()) {
          result->Error("bad_args", "path must be a non-empty string");
          return;
        }
        int size = 640;
        const auto size_it = arguments->find(flutter::EncodableValue("size"));
        if (size_it != arguments->end()) {
          if (const auto* as_int =
                  std::get_if<int32_t>(&size_it->second)) {
            size = *as_int;
          }
        }
        // The engine already initialised COM on this thread; tolerate the
        // "already initialised with a different mode" result.
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

        // Runs on the platform thread: a cold thumbnail for a large video can
        // take a moment. The Dart side caches per path, so this happens once per
        // file; a hitch here shows up as a single dropped frame, never a stall.
        std::vector<uint8_t> bytes = ExtractFrame(Utf8ToWide(*path), size);
        if (bytes.empty()) {
          // Not an error: the UI falls back to the type icon on null.
          result->Success(flutter::EncodableValue());
          return;
        }
        result->Success(flutter::EncodableValue(bytes));
      });
}
