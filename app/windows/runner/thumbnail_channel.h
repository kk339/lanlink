#ifndef RUNNER_THUMBNAIL_CHANNEL_H_
#define RUNNER_THUMBNAIL_CHANNEL_H_

#include <flutter/binary_messenger.h>

// Registers the "lanlink/thumbnail" method channel.
//
// The Dart side asks for ONE frame of a video file; we hand the request to
// Windows' own shell thumbnail service (the same provider Explorer uses), so no
// decoder is bundled and the result matches what the user sees in Explorer.
//
// Kept in the runner rather than a plugin package: it is ~150 lines, uses only
// system DLLs, and adding a plugin would add a second CMake project for no gain.
void RegisterThumbnailChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_THUMBNAIL_CHANNEL_H_
