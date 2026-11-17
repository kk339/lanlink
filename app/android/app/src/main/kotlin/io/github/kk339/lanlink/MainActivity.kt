package io.github.kk339.lanlink

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Parcelable
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

/**
 * Hosts three channels:
 *
 *  * `lanlink/multicast_lock` — Android's Wi-Fi stack filters multicast/broadcast
 *    frames unless a [WifiManager.MulticastLock] is held, so the app cannot
 *    RECEIVE peer discovery announcements without one. The Dart side takes the
 *    lock while discovery runs; [onDestroy] is the last-resort release.
 *  * `lanlink/foreground_service` — the background keep-alive: discovery timers,
 *    sockets and the resident HTTP server all live in the one Dart isolate, which
 *    Android stops scheduling once the app is cached, so peers time us out as
 *    offline. See [LanlinkForegroundService] (docs/13 §4).
 *  * `lanlink/file_picker` — a **streaming** replacement for `file_selector` on
 *    Android. `file_selector_android` reads the picked file into a `byte[]`
 *    sized to the whole file (and again into a Dart `Uint8List`), so picking a
 *    large video kills the process with `OutOfMemoryError`. Here the document is
 *    copied to the app cache in **64 KiB chunks** — the whole file is never in
 *    memory — with progress reported back to Dart. **0.2.53** adds a second
 *    method to the same channel, `pickMedia`: the system **photo picker**
 *    (`ACTION_PICK_IMAGES`, the gallery with the album drop-down) instead of the
 *    file browser, feeding the exact same result path.
 *  * `lanlink/file_actions` — the mobile file actions (M5 §C/§D/§E). Android has
 *    no "show me the file's folder", so the desktop reveal action becomes
 *    **share**, and **open** hands the file to the system viewer / player. Both
 *    go out as a `content://` URI through a [FileProvider] (a `file://` URI would
 *    throw `FileUriExposedException` on Android 7+). **videoThumbnail** extracts a
 *    single scaled frame with [MediaMetadataRetriever] — the whole video is never
 *    read into memory, and a failure is a quiet `null` (the UI keeps the type
 *    icon), never a crash. **0.2.24 added `viewInDownloads`** — see
 *    [viewInDownloads]: it opens the public `Download/lanlink` folder the user's
 *    received files are published into.
 *  * `lanlink/share_inbox` — the **inbound** share (0.2.18). Android's share
 *    sheet hands us `ACTION_SEND` / `ACTION_SEND_MULTIPLE` intents (the manifest
 *    registers both), and this channel carries the `content://` URIs to Dart:
 *    Dart asks once for the launch share (`getInitialShare`) and receives every
 *    later one as a host→Dart `onShare` call from [onNewIntent]. The copy itself
 *    reuses the picker's streaming bridge above (method `copyUris`), so a shared
 *    video is streamed, never loaded.
 *  * `lanlink/public_storage` — **outbound to the user** (0.2.19). A received
 *    file lands in the app's PRIVATE directory, so no file manager, gallery or
 *    USB mount can see it: the user copied the path and could not open it
 *    anywhere. Method `publish` copies the file into the public
 *    `Download/lanlink` collection (`MediaStore.Downloads` on Android 10+,
 *    `IS_PENDING` around the write) and answers the path the platform ACTUALLY
 *    stored — duplicate suffixes included, read back from the provider, never
 *    guessed. See [publishToDownloads].
 */
class MainActivity : FlutterActivity() {
    private val multicastChannelName = "lanlink/multicast_lock"
    private val foregroundChannelName = "lanlink/foreground_service"
    private val pickerChannelName = "lanlink/file_picker"
    private val fileActionsChannelName = "lanlink/file_actions"
    private val shareInboxChannelName = "lanlink/share_inbox"
    private val publicStorageChannelName = "lanlink/public_storage"
    private val folderPickerChannelName = "lanlink/folder_picker"
    private val pickRequestCode = 4311

    /**
     * How many photos 「照片」 may bring back in one go.
     *
     * A **bound, not a promise**: the picker clamps to what the device offers and
     * the user may pick fewer. 100 is the ceiling because every picked URI is
     * copied into the app cache before the message is built, and the app's own
     * batch limits (the folder door) sit in the same range.
     */
    private val mediaPickLimit = 100

    /**
     * Timestamp bounds `takenAtMillis` accepts — 1990-01-01 … 2100-01-01.
     *
     * Outside them the value is not a photo's capture time: it is a provider
     * quirk (seconds read as milliseconds gives the year 57000) or a column that
     * is really "unset". Keeping the system's name is the honest answer.
     */
    private val earliestPlausibleMillis = 631152000000L
    private val latestPlausibleMillis = 4102444800000L

    /**
     * Below this, a `DATE_MODIFIED` value can only be **seconds** — 1973 as
     * milliseconds, i.e. any real photo's seconds value is far smaller and any
     * millisecond value is far larger.
     */
    private val secondsVsMillisFloor = 100000000000L
    private val notificationPermissionRequest = 0x1a12
    private val copyBufferBytes = 64 * 1024
    private val mediaThumbEdge = 512
    private val logTag = "lanlink"

    /**
     * The **default** sub-directory of the public Downloads collection that
     * lanlink uses: `/storage/emulated/0/Download/lanlink` (0.2.19).
     *
     * Two reasons it is a sub-directory rather than `Download` itself: the user
     * can find "everything lanlink put on this phone" in one place, and a name
     * clash can never overwrite a download that belongs to another app.
     *
     * **0.2.29 — this is a default, not the answer.** The user can pick any
     * folder under `Download` ([pickDownloadsFolder]); the chosen name arrives on
     * **every** publish / view call as a relative name and is sanitised by
     * [sanitizeSubdirectory], which falls back to this constant whenever the
     * caller sends nothing usable. Both sides (Dart's
     * `normalizeDownloadsSubdirectory` and this one) must agree on it.
     */
    private val defaultDownloadsSubdirectory = "lanlink"

    /**
     * Request code for `ACTION_OPEN_DOCUMENT_TREE` (0.2.29).
     *
     * Separate from [pickRequestCode] so the two result paths can never be
     * confused: a file pick answered as a folder pick would hand Dart a list of
     * paths where it expects a folder name.
     */
    private val folderPickRequestCode = 4312

    /**
     * Request code for 「发送文件夹」 (0.2.33).
     *
     * A **third** code, not a reuse of [folderPickRequestCode]: that one answers
     * "where should files be saved" and validates `Download`, while this one
     * answers "which folder am I sending" and accepts anything. Sharing a code
     * would put the two rules one `if` apart, which is how a save-folder rule
     * ends up applying to a send (or not applying at all).
     */
    private val sendFolderPickRequestCode = 4313

    /** 「发送文件夹」的展开上限：3 层、200 个文件（0.2.33）。 */
    private val maxFolderSendDepth = 6
    private val maxFolderSendFiles = 200
    private val maxFolderSendCountCap = 2000

    /** Largest duplicate suffix ever tried (`x (999).mp4`); a safety bound only. */
    private val maxDuplicateSuffix = 999

    /**
     * The authority of Android's external-storage **document provider** (0.2.24).
     *
     * `ACTION_VIEW` on a folder needs a `content://` document URI, and the only
     * authority that serves the public storage tree on every stock Android is
     * this one (the same string `DocumentsContract` documents; there is no
     * platform constant for it). The document id below it is
     * `primary:Download/lanlink`.
     */
    private val externalStorageProvider = "com.android.externalstorage.documents"

    // ── multicast lock ──────────────────────────────────────────────────────
    private var multicastLock: WifiManager.MulticastLock? = null

    // ── file picker ─────────────────────────────────────────────────────────
    private var pickerChannel: MethodChannel? = null
    private var pendingPick: MethodChannel.Result? = null

    /**
     * Which door the pending pick came from (0.2.53).
     *
     * `pick` (「文件」, and every desktop caller) answers a `List<String>` of cache
     * paths and **must keep doing so** — that shape is depended on by the whole
     * send path. `pickMedia` (「照片」) answers a `List<Map>` carrying the capture
     * time and the system's display name as well, because only the platform can
     * read those. One shared `pendingPick` and this one flag, so the selection,
     * the streaming copy and the error handling stay a **single** implementation.
     */
    private var pendingPickIsMedia = false

    // ── folder chooser (0.2.29) ─────────────────────────────────────────────
    /** The pending `pick` call, until `onActivityResult` answers it. */
    private var pendingFolderPick: MethodChannel.Result? = null

    /** The pending `pickForSend` call (0.2.33). */
    private var pendingSendFolderPick: MethodChannel.Result? = null

    // ── inbound share (0.2.18) ──────────────────────────────────────────────
    /** The `lanlink/share_inbox` channel, once the engine exists. */
    private var shareChannel: MethodChannel? = null

    /**
     * A share that has **not** been handed to Dart yet.
     *
     * A cold start has no Dart listener at the moment the intent arrives, so the
     * payload waits here until Dart calls `getInitialShare`. Exactly one path
     * delivers any given share: this field, or a push on [shareChannel] — never
     * both (see [handleShareIntent]).
     */
    private var pendingShare: Map<String, Any?>? = null

    /**
     * Whether Dart has already asked for the launch share.
     *
     * It decides **which** delivery path a later share takes: before the call,
     * the payload is parked in [pendingShare]; after it, the payload is pushed
     * as `onShare`. Without this split a share that arrived while the app was
     * starting could be delivered twice (once by each path) and the file would
     * be imported, and later sent, twice.
     */
    private var shareInitialTaken = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, multicastChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            result.success(acquireLock())
                        } catch (error: Exception) {
                            result.error("multicast_lock_failed", error.message, null)
                        }
                    }
                    "release" -> {
                        try {
                            releaseLock()
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("multicast_unlock_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        pickerChannel = MethodChannel(messenger, pickerChannelName)
        pickerChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> startPick(call.argument<String>("mime") ?: "*/*", result)
                // 「照片」 (0.2.53): the system gallery picker, then the SAME
                // result path as `pick` (see `startPickMedia`).
                "pickMedia" -> startPickMedia(result)
                // Inbound share (0.2.18): the SAME streaming copy as `pick`, but
                // for URIs another app handed us instead of ones the user chose.
                "copyUris" -> copyUris(call.argument<List<String>>("uris"), result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, foregroundChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> result.success(startForegroundService())
                    "stop" -> result.success(stopForegroundService())
                    "status" -> result.success(
                        mapOf<String, Any?>(
                            "running" to LanlinkForegroundService.isRunning,
                            "error" to LanlinkForegroundService.lastError,
                        ),
                    )
                    "notificationPermission" -> result.success(notificationGranted())
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(notificationGranted())
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, fileActionsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "share" -> shareFile(call.argument<String>("path"), result)
                    "open" -> openFile(call.argument<String>("path"), result)
                    "viewInDownloads" ->
                        viewInDownloads(
                            call.argument<String>("path"),
                            call.argument<String>("subdirectory"),
                            result,
                        )
                    "videoThumbnail" ->
                        videoThumbnail(
                            call.argument<String>("path"),
                            call.argument<Int>("maxBytes"),
                            result,
                        )
                    else -> result.notImplemented()
                }
            }

        // Inbound share (0.2.18). `getInitialShare` answers **once**: the stored
        // payload is cleared as it is handed over, so a second call (a re-mounted
        // intake, a rebuilt engine) cannot import the same share twice.
        shareChannel = MethodChannel(messenger, shareInboxChannelName)
        shareChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialShare" -> {
                    shareInitialTaken = true
                    val payload = pendingShare
                    pendingShare = null
                    result.success(payload)
                }
                else -> result.notImplemented()
            }
        }

        // Folder chooser (0.2.29). Answers `{result: ok|invalid|cancelled|failed}`
        // (+ `subdirectory` when ok). `ACTION_OPEN_DOCUMENT_TREE` is the only
        // system UI that lets the user move the save folder without turning the
        // publish path into a `content://` URI — see `describeTreeChoice`.
        MethodChannel(messenger, folderPickerChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> startDownloadsFolderPick(result)
                    "pickForSend" -> startSendFolderPick(result)
                    else -> result.notImplemented()
                }
            }

        // Public storage (0.2.19). Answers `{path}` (the path the platform
        // actually wrote, duplicate suffix included) or `{error}` — never a
        // thrown exception, because "the export failed" is a normal outcome the
        // Dart side reports, not a crash.
        MethodChannel(messenger, publicStorageChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "publish" ->
                        publishToDownloads(
                            call.argument<String>("srcPath"),
                            call.argument<String>("displayName"),
                            call.argument<String>("mime"),
                            call.argument<String>("subdirectory"),
                            result,
                        )
                    else -> result.notImplemented()
                }
            }
    }

    // ── inbound share: intent lifecycle (0.2.18) ────────────────────────────

    /**
     * Captures the intent that **launched** the app.
     *
     * Runs **before** `super.onCreate`, because that call brings the Flutter
     * engine up (`configureFlutterEngine`) and Dart may ask for the share at any
     * moment afterwards.
     *
     * `savedInstanceState == null` is the first anti-duplicate guard: after a
     * **process-death restore** the framework replays the original launch intent,
     * and re-importing it would silently duplicate every file the user shared.
     * A restored activity therefore never re-reads it — the copy already exists
     * in the app cache, and the user still has the draft if they had not sent it.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        if (savedInstanceState == null) {
            handleShareIntent(intent)
        }
        super.onCreate(savedInstanceState)
    }

    /**
     * Receives a share **while the app is already running**.
     *
     * `setIntent` is not optional: without it `getIntent()` keeps returning the
     * old intent, so a later `getInitialShare` — or any other reader — would see
     * a stale one.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    /**
     * Turns a share intent into a payload and delivers it to Dart **once**.
     *
     * Two anti-duplicate guards live here and in [onCreate]:
     *  1. the action is **consumed** (`intent.action = null`) before the payload
     *     is handed over, so a repeat delivery of the same `Intent` object — a
     *     configuration change, a re-posted intent, a duplicated `onNewIntent` —
     *     no longer looks like a share and is ignored;
     *  2. `savedInstanceState == null` in [onCreate] (see there).
     *
     * Delivery itself is one-way: before Dart has asked (`shareInitialTaken`),
     * the payload is parked for `getInitialShare`; afterwards it is pushed as
     * `onShare`. A text-only share (`EXTRA_TEXT`, no stream) is **ignored with a
     * log line** in this version — the plan is deliberate, and it must never
     * crash a user who shared a link.
     */
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) {
            return
        }
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return
        }
        val payload = extractSharePayload(intent, action)
        // ★ Guard 1 — consume the action (see the doc above).
        intent.action = null
        if (payload == null) {
            Log.i(
                logTag,
                "share: the intent carries no stream "
                    + "(a text-only share is not supported yet) — ignored",
            )
            return
        }
        val count = (payload["uris"] as? List<*>)?.size ?: 0
        Log.i(logTag, "share: received $count file(s), mime=${payload["mime"]}")
        val channel = shareChannel
        if (shareInitialTaken && channel != null) {
            channel.invokeMethod("onShare", payload)
        } else {
            pendingShare = payload
        }
    }

    /**
     * Builds the fixed payload `{uris, mime, multiple}` from a share intent, or
     * `null` when there is no stream to take.
     *
     * Both shapes are covered — `EXTRA_STREAM` (single Uri / `ArrayList<Uri>`)
     * **and** `clipData`, because senders are inconsistent: `ACTION_SEND_MULTIPLE`
     * from the gallery usually fills both, some file managers only fill
     * `clipData`, and `ACTION_SEND` from a browser sometimes only fills
     * `EXTRA_STREAM`. Duplicates are collapsed by a [LinkedHashSet], which also
     * **preserves the sender's order** — the Dart side returns local paths in
     * that same order.
     */
    @Suppress("DEPRECATION")
    private fun extractSharePayload(intent: Intent, action: String?): Map<String, Any?>? {
        val uris = LinkedHashSet<Uri>()

        fun add(uri: Uri?) {
            if (uri == null) {
                return
            }
            val scheme = uri.scheme ?: return
            if (scheme == "content" || scheme == "file") {
                uris.add(uri)
            }
        }

        if (action == Intent.ACTION_SEND_MULTIPLE) {
            val list: ArrayList<Parcelable>? =
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            list?.forEach { item -> add(item as? Uri) }
        } else {
            add(intent.getParcelableExtra<Parcelable>(Intent.EXTRA_STREAM) as? Uri)
        }
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                add(clip.getItemAt(index).uri)
            }
        }
        if (uris.isEmpty()) {
            return null
        }

        // ⚠ The `content://` read grant arrives with the intent flags and, for a
        // plain `ACTION_SEND`, normally lives as long as this activity — enough
        // for the Dart side to stream the copy. A **persistable** grant (only
        // some providers offer one; MediaStore / Photos do NOT) additionally
        // survives a process restart mid-copy, so it is requested when available.
        // The SecurityException is the expected answer for the common case and is
        // therefore swallowed, not reported.
        val readFlag = Intent.FLAG_GRANT_READ_URI_PERMISSION
        for (uri in uris) {
            if (uri.scheme != "content") {
                continue
            }
            try {
                contentResolver.takePersistableUriPermission(uri, readFlag)
            } catch (_: SecurityException) {
                // Not persistable — the intent grant is enough.
            }
        }

        val first = uris.first()
        val mime =
            intent.type ?: runCatching { contentResolver.getType(first) }.getOrNull() ?: "*/*"
        return mapOf<String, Any?>(
            "uris" to uris.map { uri -> uri.toString() },
            "mime" to mime,
            "multiple" to (action == Intent.ACTION_SEND_MULTIPLE),
        )
    }

    // ── foreground service (background keep-alive, docs/13 §4) ──────────────

    /**
     * Brings [LanlinkForegroundService] up.
     *
     * Answers with `started`/`notification`/`error` instead of throwing, because
     * a refusal here (`ForegroundServiceStartNotAllowedException`, thrown when a
     * service is started from the background on Android 12+) has to become a
     * **visible** warning on the Dart side, not a stack trace in a log nobody
     * reads.
     */
    private fun startForegroundService(): Map<String, Any?> {
        val context: Context = applicationContext
        return try {
            val intent = LanlinkForegroundService.intent(
                context,
                LanlinkForegroundService.ACTION_START,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            mapOf<String, Any?>(
                "started" to true,
                "notification" to notificationGranted(),
                "error" to null,
            )
        } catch (error: Exception) {
            mapOf<String, Any?>(
                "started" to false,
                "notification" to notificationGranted(),
                "error" to (error.message ?: error.javaClass.simpleName),
            )
        }
    }

    /** Stops [LanlinkForegroundService] (best effort — it also dies with us). */
    private fun stopForegroundService(): Map<String, Any?> {
        val context: Context = applicationContext
        val stopped = context.stopService(
            LanlinkForegroundService.intent(
                context,
                LanlinkForegroundService.ACTION_STOP,
            ),
        )
        return mapOf<String, Any?>("stopped" to stopped)
    }

    /**
     * Whether the "lanlink is running" notice can be shown.
     *
     * `true` below Android 13 (no runtime permission exists). A `false` does not
     * stop the keep-alive — the service still runs, the notice is merely
     * invisible — so the caller only softens the message, never the function.
     */
    private fun notificationGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** Asks for POST_NOTIFICATIONS on Android 13+, if not already granted. */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (notificationGranted()) {
            return
        }
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationPermissionRequest,
        )
    }

    // ── share sheet (M5 §E) ─────────────────────────────────────────────────

    /**
     * Hands a local file to the system share sheet.
     *
     * A `file://` URI would throw `FileUriExposedException` on Android 7+, so the
     * path is converted through [FileProvider] (`<applicationId>.fileprovider`,
     * roots in `res/xml/file_paths.xml`) and the receiver is granted read access
     * for this share only. The file's bytes are never read here — only the URI is
     * handed over. A refusal (a path outside the provider roots, a missing file)
     * is reported as an error, never a silent no-op.
     */
    private fun shareFile(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("share_bad_args", "no path to share", null)
            return
        }
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("share_missing", "file not found: $path", null)
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent =
                Intent(Intent.ACTION_SEND).apply {
                    type = contentResolver.getType(uri) ?: "*/*"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    // The clip data plus the flag is the reliable way to grant the
                    // receiving app read access to the URI across the chooser.
                    clipData = ClipData.newUri(contentResolver, "lanlink", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            startActivity(Intent.createChooser(intent, null))
            result.success(null)
        } catch (error: Exception) {
            result.error("share_failed", error.message ?: error.toString(), null)
        }
    }

    /**
     * Hands the file to the system's default viewer / player (ACTION_VIEW).
     *
     * Same `FileProvider` conversion as [shareFile] (a `file://` URI is refused on
     * Android 7+). "No app can open this" is reported as an error, never silent.
     */
    private fun openFile(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("open_bad_args", "no path to open", null)
            return
        }
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("open_missing", "file not found: $path", null)
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent =
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, contentResolver.getType(uri) ?: "*/*")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("open_failed", error.message ?: error.toString(), null)
        }
    }

    /**
     * Opens the public `Download/lanlink` folder in the system file manager
     * (0.2.24) — the Android answer to the desktop's 「打开所在位置」.
     *
     * **What the user asked for.** Since 0.2.19 every received file is published
     * into `/storage/emulated/0/Download/lanlink` ([publishToDownloads]), but the
     * only way to *reach* it was to open a file manager and navigate there by
     * hand. The Dart menu now offers 「在下载里查看」 for a received file, and this
     * is what it calls.
     *
     * **The folder opens, not the file.** `ACTION_VIEW` on a `content://` document
     * URI with `MIME_TYPE_DIR` is the one cross-ROM way to show a directory;
     * "open this file's folder *and select the file*" has no stable public API
     * (some managers honour `EXTRA_INITIAL_URI`, most ignore it), so the file is
     * not pretended to be selected.
     *
     * **`path` is optional (0.2.26).** Two Dart callers reach this method: the
     * attachment menu (0.2.24) which names the received file, and the phone's
     * settings row 「文件保存位置」 (0.2.26) which names **only the folder** — that
     * row has no file behind it, so the Dart side omits the key entirely and this
     * method receives `null`. The path is used for **one** thing, the log line; it
     * never decides where to go (the document id below is always the folder). A
     * caller that cannot name a file must therefore not be forced to invent one:
     * a made-up path would end up in a bug report as if it were real.
     *
     * `EXTRA_INITIAL_URI` is deliberately **not** set: on the ROMs that honour it
     * the document id would have to be the *file*'s id, and on the ones that do
     * not the extra silently does nothing — a cosmetic difference that would make
     * behaviour vary by device for no gain.
     *
     * **Answer shape.** Always `result.success({result: …})`, never
     * `result.error`: "no app can open a folder" is a normal device, and the Dart
     * side has a fallback prepared (copy the path, tell the user). The codes are
     * `opened` / `no_app` / `no_directory` / `unsupported` / `failed`, mapped by
     * `AndroidFileActions.parseViewInDownloadsReply`.
     *
     * [Build.VERSION_CODES.KITKAT] is the floor because
     * [DocumentsContract.buildDocumentUri] arrived in API 19 — below it the intent
     * cannot be built at all, so that is reported instead of crashing.
     */
    private fun viewInDownloads(
        path: String?,
        subdirectory: String?,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.KITKAT) {
            result.success(mapOf<String, Any?>("result" to "unsupported"))
            return
        }
        val folder = sanitizeSubdirectory(subdirectory)
        val directory = publicDownloadsDirectory(folder)
        if (!directory.isDirectory) {
            // Nothing has been received on this phone since 0.2.19 (or the folder
            // was deleted) — opening a non-existent document id would land on an
            // empty or unrelated screen, so this is a reported dead end.
            Log.i(logTag, "viewInDownloads: ${directory.path} is not a directory")
            result.success(mapOf<String, Any?>("result" to "no_directory"))
            return
        }
        val uri =
            DocumentsContract.buildDocumentUri(
                externalStorageProvider,
                "primary:" + Environment.DIRECTORY_DOWNLOADS + "/" + folder,
            )
        val intent =
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                // NEW_TASK because the launch may be served from a context that is
                // not the activity; harmless (and expected) from one.
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        // ⚠ `resolveActivity` is used as an **observation only**, never as a gate.
        // Since Android 11 package-visibility filtering applies to it, so a null
        // answer does NOT prove that no handler exists (DocumentsUI is a system
        // app and is not visible unless the manifest declares it). Gating on it
        // would tell users of perfectly normal phones that their ROM has no file
        // manager. The real test is the start itself: an absent handler throws
        // [ActivityNotFoundException], which is caught below.
        val resolved = intent.resolveActivity(packageManager)
        // One log line, two callers: name the file when there is one, and say
        // "folder only" when the settings row asked (0.2.26). Never print an
        // empty `file=` that reads like a bug.
        val target = if (path.isNullOrEmpty()) "folder only" else "file=$path"
        try {
            startActivity(intent)
            Log.i(
                logTag,
                "viewInDownloads: opened $uri "
                    + "(handler="
                    + (resolved?.flattenToShortString() ?: "not reported")
                    + ", $target)",
            )
            result.success(mapOf<String, Any?>("result" to "opened"))
        } catch (error: ActivityNotFoundException) {
            Log.i(logTag, "viewInDownloads: no activity for $uri")
            result.success(mapOf<String, Any?>("result" to "no_app"))
        } catch (error: Exception) {
            Log.i(
                logTag,
                "viewInDownloads: failed: " + (error.message ?: error.javaClass.simpleName),
            )
            result.success(
                mapOf<String, Any?>(
                    "result" to "failed",
                    "error" to (error.message ?: error.javaClass.simpleName),
                ),
            )
        }
    }

    /**
     * Extracts **one** scaled video frame as JPEG bytes, or `null`.
     *
     * `MediaMetadataRetriever` reads from the path — the whole video is never held
     * in memory; only a single frame is, then it is scaled to at most
     * [mediaThumbEdge] on its long edge and JPEG-compressed. Any failure (no
     * decoder, unreadable file, over [maxBytes]) is a quiet `null` so the UI keeps
     * its type icon — never a crash (M5 §C).
     */
    private fun videoThumbnail(path: String?, maxBytes: Int?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.success(null)
            return
        }
        var retriever: MediaMetadataRetriever? = null
        try {
            if (!File(path).exists()) {
                result.success(null)
                return
            }
            retriever = MediaMetadataRetriever()
            retriever.setDataSource(path)
            val frame = extractFrame(retriever)
            if (frame == null) {
                result.success(null)
                return
            }
            val scaled = scaleDown(frame, mediaThumbEdge)
            val bytes =
                ByteArrayOutputStream().use { out ->
                    scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
                    out.toByteArray()
                }
            if (scaled !== frame) {
                scaled.recycle()
            }
            frame.recycle()
            result.success(if (maxBytes != null && maxBytes > 0 && bytes.size > maxBytes) null else bytes)
        } catch (error: Exception) {
            result.success(null)
        } finally {
            try {
                retriever?.release()
            } catch (_: Exception) {
                // release() can throw if setDataSource never succeeded; ignore.
            }
        }
    }

    /** One frame near t=0, scaled when the API supports it (27+). */
    private fun extractFrame(retriever: MediaMetadataRetriever): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            return retriever.getScaledFrameAtTime(
                0L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                mediaThumbEdge,
                mediaThumbEdge,
            )
        }
        @Suppress("DEPRECATION")
        return retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
    }

    /** Scales [bitmap] so its long edge is at most [maxEdge] (identity if smaller). */
    private fun scaleDown(bitmap: Bitmap, maxEdge: Int): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= maxEdge || longest == 0) {
            return bitmap
        }
        val ratio = maxEdge.toFloat() / longest.toFloat()
        val width = maxOf(1, (bitmap.width * ratio).toInt())
        val height = maxOf(1, (bitmap.height * ratio).toInt())
        return Bitmap.createScaledBitmap(bitmap, width, height, true)
    }

    // ── multicast lock ──────────────────────────────────────────────────────

    /** Takes the lock, returning false (never throwing) when it cannot be had. */
    private fun acquireLock(): Boolean {
        multicastLock?.let { if (it.isHeld) return true }
        val wifi =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return false
        // Same tag and the SAME reference-counting as the foreground service's
        // lock (tag `lanlink`), so the two holders share one framework-level
        // lock correctly: whichever releases first only decrements its own
        // reference. With reference counting switched OFF, either holder's
        // release would drop the Wi-Fi multicast filter for the whole app while
        // the other still believed it held the lock — which is exactly the
        // "we can no longer see anyone" failure.
        val lock = wifi.createMulticastLock("lanlink")
        lock.acquire()
        multicastLock = lock
        return lock.isHeld
    }

    /** Releases the lock if held; safe to call repeatedly. */
    private fun releaseLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    // ── file picker ─────────────────────────────────────────────────────────

    private fun startPick(mime: String, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("pick_busy", "a pick is already in progress", null)
            return
        }
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mime
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        pendingPick = result
        pendingPickIsMedia = false
        launchPick(intent, result)
    }

    /**
     * Picks **photos** with the system gallery picker — the one with the album
     * drop-down / tabs at the top — then takes the same road as [startPick].
     *
     * This exists because `ACTION_OPEN_DOCUMENT` is a *file browser*: the user
     * gets a tree of folders and has to know where the camera saved things.
     * 「照片」 must open the gallery instead, where photos are already grouped by
     * album. The rest is deliberately identical:
     *
     *  * the same [pendingPick] slot (one pick at a time — the busy answer is
     *    `pick_busy`, exactly as before);
     *  * the same [pickRequestCode], so the **existing** `onActivityResult`
     *    branch handles single *and* multi selection and copies every URI into
     *    the cache in 64 KiB chunks. None of that is duplicated here;
     *  * an empty selection stays "cancelled" (an empty list), which is what Dart
     *    already reads as "the user changed their mind".
     *
     * The one deliberate difference is the **result shape** (0.2.53): this door
     * sets [pendingPickIsMedia], so the answer is a list of
     * `{path, displayName, takenAtMillis, mime}` maps instead of bare paths — the
     * capture time cannot be recovered after the copy, and Dart needs it to name
     * `1000055362.jpg` something readable. `pick`'s answer is untouched.
     *
     * **The type is `image/*`, not `*/*`, on purpose.** `ACTION_PICK_IMAGES`
     * documents its type as `image/*` **or** `video/*` and nothing else; a
     * `*/*` intent is outside the contract, and a picker that honours the
     * contract literally would show nothing at all — i.e. the "点了没反应"
     * failure this app has already been bitten by. Videos keep going through
     * 「文件」 (which is `*/*` and shows everything).
     *
     * **Never a dead tap.** The photo picker only exists from Android 13 (API
     * 33) and only when the system media module is present, so it may genuinely
     * be missing. The order of the two answers below matters:
     *
     * 1. `resolveActivity` is asked first, but only as a **log line**: from
     *    Android 11 its answer is filtered by `<package visibility>`, so a `null`
     *    there may equally mean "the picker exists and this app cannot see it".
     *    Trusting that `null` would silently hand every Android 13 phone the
     *    folder browser — deleting the feature this method exists for.
     * 2. The **launch itself is the verdict**: `ActivityNotFoundException` means
     *    "not on this device", and only then does the pick fall back to the
     *    `ACTION_OPEN_DOCUMENT` shape this app already ships (images + videos,
     *    multiple), which every Android version answers. If even that cannot
     *    start, the call answers an explicit error rather than silence.
     */
    private fun startPickMedia(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("pick_busy", "a pick is already in progress", null)
            return
        }
        val photoPicker =
            Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                type = "image/*"
                putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, mediaPickLimit)
            }
        val visible = photoPicker.resolveActivity(packageManager) != null
        Log.i(
            logTag,
            if (visible) {
                "media pick: system photo picker (image/*, max $mediaPickLimit)"
            } else {
                "media pick: picker unresolved (package visibility?) — attempting anyway"
            },
        )
        pendingPick = result
        pendingPickIsMedia = true
        try {
            startActivityForResult(photoPicker, pickRequestCode)
        } catch (error: ActivityNotFoundException) {
            Log.i(logTag, "media pick: no photo picker on this device → folder browser")
            launchPick(openDocumentForMedia(), result)
        }
    }

    /**
     * The fallback chooser for [startPickMedia]: the document browser limited to
     * images and videos, multi-select, exactly the shape `pick` already uses.
     */
    private fun openDocumentForMedia(): Intent =
        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }

    /**
     * Starts [intent] for [pickRequestCode], answering [result] with an explicit
     * error when **no activity on this device can handle it** (`NO_EXPIRY` /
     * a stripped-down OEM build). Without this the slot would be left occupied,
     * every later pick would answer `pick_busy`, and the tap would look ignored.
     */
    private fun launchPick(intent: Intent, result: MethodChannel.Result) {
        try {
            startActivityForResult(intent, pickRequestCode)
        } catch (error: ActivityNotFoundException) {
            pendingPick = null
            pendingPickIsMedia = false
            Log.i(logTag, "pick: no activity for " + intent.action)
            result.error("pick_failed", "这台设备没有可以打开的选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // Let Flutter (and any plugin) see the result first.
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == sendFolderPickRequestCode) {
            val pending = pendingSendFolderPick ?: return
            pendingSendFolderPick = null
            val tree = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (tree == null) {
                // Backing out of the picker is a decision, not an error.
                Log.i(logTag, "send folder: cancelled")
                pending.success(mapOf<String, Any?>("result" to "cancelled"))
                return
            }
            // Walking the tree and copying every file is I/O of unknown length —
            // 200 photos is minutes on a slow card. Never on the UI thread.
            Thread {
                    val reply =
                        try {
                            prepareSendFolder(tree)
                        } catch (error: Exception) {
                            Log.i(
                                logTag,
                                "send folder: failed: " + (error.message ?: error.javaClass.simpleName),
                            )
                            mapOf<String, Any?>(
                                "result" to "failed",
                                "reason" to (error.message ?: error.javaClass.simpleName),
                            )
                        }
                    runOnUiThread { pending.success(reply) }
                }
                .start()
            return
        }
        if (requestCode == folderPickRequestCode) {
            val pending = pendingFolderPick ?: return
            pendingFolderPick = null
            val tree = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (tree == null) {
                // RESULT_CANCELED is the user changing their mind, not an error:
                // Dart answers it with silence (no toast, setting untouched).
                Log.i(logTag, "folder pick: cancelled")
                pending.success(mapOf<String, Any?>("result" to "cancelled"))
                return
            }
            pending.success(describeTreeChoice(tree))
            return
        }
        if (requestCode != pickRequestCode) {
            return
        }
        val result = pendingPick ?: return
        // Read **and clear** both halves of the pending pick together: the result
        // shape is decided by which door opened it (0.2.53), and a flag left
        // behind would answer the next `pick` with the wrong type.
        val isMedia = pendingPickIsMedia
        pendingPick = null
        pendingPickIsMedia = false

        if (resultCode != Activity.RESULT_OK || data == null) {
            // Cancelled — an empty list either way, which is what Dart reads as
            // "the user changed their mind".
            result.success(emptyList<Any?>())
            return
        }
        val uris = mutableListOf<Uri>()
        data.data?.let { uris.add(it) }
        data.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                uris.add(clip.getItemAt(index).uri)
            }
        }
        if (uris.isEmpty()) {
            result.success(emptyList<Any?>())
            return
        }

        // Copy **off** the UI thread: a 400 MB copy would otherwise ANR.
        Thread {
                try {
                    // The copy itself is the SAME call for both doors: media picks
                    // only carry extra facts about each file alongside the path.
                    val reply: Any =
                        if (isMedia) {
                            uris.map { describePickedMedia(it) }
                        } else {
                            uris.map { copyPickedUri(it) }
                        }
                    runOnUiThread { result.success(reply) }
                } catch (error: Exception) {
                    runOnUiThread {
                        result.error("pick_failed", error.message ?: error.toString(), null)
                    }
                }
            }
            .start()
    }

    /**
     * One 「照片」 pick, with the two facts only the platform knows (0.2.53).
     *
     * `path` is the cached copy — identical to what `pick` answers, produced by
     * the same [copyPickedUri]. `displayName` is the name the system reported
     * *before* the copy touched it (the picker calls a photo `1000055362.jpg`),
     * `takenAtMillis` is when the photo was **taken**, and `mime` is what the
     * provider says it is.
     *
     * Why the timestamp has to travel: the cached file's own mtime is the moment
     * of the copy, so a whole batch shares one second and nothing can be
     * reconstructed later. Naming is **not** done here — Dart owns the rules
     * (`lib/domain/media_file_name.dart`), so the rule that decides a file's name
     * is unit-testable without a device.
     */
    private fun describePickedMedia(uri: Uri): Map<String, Any?> {
        val name = displayName(uri)
        val mime = try {
            contentResolver.getType(uri)
        } catch (error: Exception) {
            null
        }
        val path = copyPickedUri(uri)
        return mapOf(
            "path" to path,
            "displayName" to (name ?: File(path).name),
            "takenAtMillis" to takenAtMillis(uri),
            "mime" to (mime ?: ""),
        )
    }

    /**
     * When the photo was **taken**, in milliseconds since the epoch, or `null`.
     *
     * `DATE_TAKEN` first: on a camera photo it is the shutter time, which is what
     * the name should say. It is missing more often than one would hope (saved
     * images, screenshots, re-encoded media, and providers that simply do not
     * expose the column), so `DATE_MODIFIED` is the second chance — still a real
     * MediaStore timestamp of the *photo*, never the cache copy's mtime. When
     * neither answers, the answer is **`null`, not `0`**: `0` means 1970 and
     * would rename the file to `19700101_…`, which is worse than keeping the
     * number the system gave.
     *
     * Both columns are queried through [queryLongQuiet] because an unsupported
     * column makes a provider throw (`IllegalArgumentException`), and a failed
     * lookup must degrade to "no name change", never to a failed pick.
     */
    private fun takenAtMillis(uri: Uri): Long? {
        val taken = queryLongQuiet(uri, MediaStore.MediaColumns.DATE_TAKEN)
        if (taken != null && taken > 0L) {
            Log.i(logTag, "media pick: DATE_TAKEN = $taken")
            return plausibleMillis(taken)
        }
        // DATE_MODIFIED is stored in SECONDS by MediaStore; DATE_TAKEN is millis.
        val modified = queryLongQuiet(uri, MediaStore.MediaColumns.DATE_MODIFIED)
        if (modified != null && modified > 0L) {
            Log.i(logTag, "media pick: no DATE_TAKEN, DATE_MODIFIED = $modified")
            // A handful of providers answer in milliseconds anyway; anything
            // below the millisecond epoch of 1973 can only be seconds, so the
            // two units cannot be confused.
            val millis = if (modified < secondsVsMillisFloor) modified * 1000L else modified
            return plausibleMillis(millis)
        }
        Log.i(logTag, "media pick: no timestamp for this URI")
        return null
    }

    /**
     * [millis] if it can be a real photo timestamp, else `null`.
     *
     * A wrong-but-plausible date is the worst outcome: the name would look
     * authoritative and be wrong. Anything outside 1990…2100 (a provider mixing
     * up seconds and milliseconds lands in the year 57000) is treated as "the
     * platform did not really answer", which keeps the system's own name.
     */
    private fun plausibleMillis(millis: Long): Long? {
        if (millis in earliestPlausibleMillis..latestPlausibleMillis) {
            return millis
        }
        Log.i(logTag, "media pick: implausible timestamp $millis — ignoring it")
        return null
    }

    /** [queryLong] with the provider's refusal turned into `null`. */
    private fun queryLongQuiet(uri: Uri, column: String): Long? =
        try {
            queryLong(uri, column)
        } catch (error: Exception) {
            Log.i(logTag, "media pick: column $column unavailable: " + (error.message ?: "?"))
            null
        }

    /**
     * Streams the picked document into the app cache in [copyBufferBytes] chunks
     * — the file is **never** held in an array sized to the whole thing — and
     * reports byte progress to Dart. Returns the cached path.
     */
    private fun copyPickedUri(uri: Uri): String {
        val directory = File(cacheDir, "lanlink-picked/${UUID.randomUUID()}")
        if (!directory.mkdirs() && !directory.exists()) {
            throw IOException("cannot create the cache directory for the picked file")
        }
        val target = File(directory, sanitize(displayName(uri) ?: "file"))
        val total = declaredSize(uri)
        var copied = 0L
        var reportedAt = 0L

        val source =
            contentResolver.openInputStream(uri)
                ?: throw IOException("the content provider returned no stream")
        source.use { input ->
            FileOutputStream(target).use { output ->
                val buffer = ByteArray(copyBufferBytes)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) {
                        break
                    }
                    output.write(buffer, 0, read)
                    copied += read
                    // Throttle: at most one message per megabyte.
                    if (copied - reportedAt >= 1024L * 1024L) {
                        reportedAt = copied
                        emitProgress(copied, total)
                    }
                }
            }
        }
        emitProgress(copied, if (total > 0) total else copied)
        return target.path
    }

    /**
     * Copies URIs that **another app shared with us** into the app cache
     * (0.2.18), one at a time, and answers with one entry per URI **in the same
     * order**.
     *
     * It is [copyPickedUri] — the same 64 KiB streaming copy, the same progress
     * callback, the same `cache/lanlink-picked/` destination — only the URIs come
     * from a share intent instead of the OS picker. That reuse is the point: the
     * gallery hands us several-hundred-megabyte videos, and a `byte[]` sized to
     * the file is exactly the `OutOfMemoryError` the streaming bridge was built
     * to avoid.
     *
     * A URI that fails does **not** fail the batch: its entry carries `error`
     * while the others still return a `path`. Sharing five photos where one was
     * deleted must still deliver four — and the user must be told which one was
     * dropped (the Dart side turns each `error` into a
     * `ShareImportFailure`).
     *
     * Runs **off** the UI thread (a 400 MB copy would ANR); the reply is posted
     * back to the UI thread, as the channel requires.
     */
    private fun copyUris(rawUris: List<String>?, result: MethodChannel.Result) {
        if (rawUris == null || rawUris.isEmpty()) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        val uris = rawUris.map { raw -> Uri.parse(raw) }
        Thread {
                val entries = ArrayList<Map<String, Any?>>(uris.size)
                for (uri in uris) {
                    entries.add(
                        try {
                            mapOf<String, Any?>(
                                "uri" to uri.toString(),
                                "path" to copyPickedUri(uri),
                            )
                        } catch (error: Exception) {
                            Log.i(
                                logTag,
                                "share: copying ${uri} failed: "
                                    + (error.message ?: error.javaClass.simpleName),
                            )
                            mapOf<String, Any?>(
                                "uri" to uri.toString(),
                                "error" to (error.message ?: error.javaClass.simpleName),
                            )
                        },
                    )
                }
                runOnUiThread { result.success(entries) }
            }
            .start()
    }

    // ── public storage: receive → user-visible Download/lanlink (0.2.19) ────

    /**
     * The answer of one export attempt: either [path] or [error].
     *
     * `path` is the **actual** location, with whatever duplicate suffix the
     * platform ended up using — the Dart side records it verbatim, so
     * 复制文件路径 can only ever hand out a path that opens.
     */
    private class PublishResult(val path: String?, val error: String?)

    /**
     * Copies the received file at `srcPath` into public storage, off the UI
     * thread, and answers `{path}` or `{error}`.
     *
     * **Why a copy at all.** The resident receiver streams an accepted upload
     * into the app's private directory (`/data/user/0/<pkg>/files/lanlink/
     * received`). That file is real, complete and hash-verified, but no file
     * manager, gallery or USB mount can see it — the user copied the path and
     * could not open it anywhere. Downloads is the one place on Android that
     * every one of those surfaces shows.
     *
     * The copy is **64 KiB at a time** ([copyBufferBytes]) in both branches: a
     * 2 GB video must never be materialised in memory, and the receiver already
     * has the file on disk, so streaming is both the safe and the fast choice.
     *
     * A failed export changes nothing: the private file is left alone and the
     * caller reports `{error}` — it must never look like "the file vanished".
     */
    private fun publishToDownloads(
        srcPath: String?,
        displayName: String?,
        mime: String?,
        subdirectory: String?,
        result: MethodChannel.Result,
    ) {
        if (srcPath.isNullOrEmpty()) {
            result.success(mapOf<String, Any?>("error" to "没有源文件路径"))
            return
        }
        val source = File(srcPath)
        if (!source.isFile) {
            result.success(mapOf<String, Any?>("error" to "源文件不存在：$srcPath"))
            return
        }
        val name = sanitize(displayName?.takeIf { it.isNotEmpty() } ?: source.name)
        val type = resolveMimeType(mime, name)
        // 0.2.29 — the folder the user chose. Sanitised here even though Dart
        // already normalised it: this side must not depend on the caller having
        // done it, and an unusable name has to fall back to the default rather
        // than land a file in the wrong tree.
        val folder = sanitizeSubdirectory(subdirectory)
        // Off the UI thread: publishing is a full file copy, and on Android 11+
        // a large one would ANR the activity if it ran on the main thread.
        Thread {
                val outcome =
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            publishWithMediaStore(source, name, type, folder)
                        } else {
                            publishToLegacyDownloads(source, name, folder)
                        }
                    } catch (error: Exception) {
                        PublishResult(
                            null,
                            error.message ?: error.javaClass.simpleName,
                        )
                    }
                runOnUiThread {
                    val path = outcome.path
                    if (path != null) {
                        Log.i(logTag, "publish: $name -> $path (folder=$folder)")
                        result.success(mapOf<String, Any?>("path" to path))
                    } else {
                        val error = outcome.error ?: "未知原因"
                        Log.i(logTag, "publish: $name failed in folder=$folder: $error")
                        result.success(mapOf<String, Any?>("error" to error))
                    }
                }
            }
            .start()
    }

    /**
     * Android 10+ path: insert into `MediaStore.Downloads` with
     * `RELATIVE_PATH = Download/lanlink`, stream the bytes in while the entry is
     * `IS_PENDING = 1`, then flip it to `IS_PENDING = 0`.
     *
     * `IS_PENDING` is what makes this atomic from the outside: until the flag
     * drops, no other app (or the gallery's media scan) can see a half-written
     * file, so a failed or interrupted copy never leaves a corrupt video that
     * looks complete.
     *
     * **Duplicate names are not assumed.** MediaStore renames a clash on many
     * builds — but not reliably on all of them, and the renamed value is
     * whatever *it* decided. So a free name is probed first
     * ([uniqueDisplayName]) to avoid a silent second `x.mp4`, and the real name
     * is read back out of the returned URI afterwards ([queryDisplayName]).
     * Nothing here guesses the final path.
     *
     * On any failure the just-inserted pending entry is **removed**: leaving it
     * would put a 0-byte ghost in the user's 下载 list under the name of a file
     * that never arrived.
     */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun publishWithMediaStore(
        source: File,
        displayName: String,
        mime: String,
        subdirectory: String,
    ): PublishResult {
        val collection =
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val relativePath = Environment.DIRECTORY_DOWNLOADS + "/" + subdirectory
        val requested = uniqueDisplayName(collection, relativePath, displayName)
        val values =
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, requested)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        val uri =
            contentResolver.insert(collection, values)
                ?: return PublishResult(null, "系统 Downloads 拒绝登记这个文件")
        try {
            val output =
                contentResolver.openOutputStream(uri)
                    ?: throw IOException("系统没有给出可写的输出流")
            output.use { out ->
                source.inputStream().use { input -> copyStream(input, out) }
            }
            contentResolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            // Read the name back: this is the only value guaranteed to match
            // what the user will see in 下载.
            val actual = queryDisplayName(uri) ?: requested
            return PublishResult(publicDownloadsPath(actual, subdirectory), null)
        } catch (error: Exception) {
            // Roll back the pending row (see the doc above). A failed delete is
            // swallowed: the pending entry expires on its own and reporting the
            // copy error is what matters.
            try {
                contentResolver.delete(uri, null, null)
            } catch (_: Exception) {
                // Nothing more we can do; the copy error is the real answer.
            }
            return PublishResult(
                null,
                error.message ?: error.javaClass.simpleName,
            )
        }
    }

    /**
     * A [displayName] no existing download in [relativePath] uses.
     *
     * MediaStore's own behaviour on a duplicate `DISPLAY_NAME` varies by build
     * and provider, so the free name is chosen here: `x.mp4` → `x (1).mp4` →
     * `x (2).mp4`, the same shape every file manager shows. The actual name is
     * still read back after the insert, so this is a best-effort *avoidance*,
     * not a promise about what the platform stores.
     */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun uniqueDisplayName(
        collection: Uri,
        relativePath: String,
        displayName: String,
    ): String {
        if (!displayNameExists(collection, relativePath, displayName)) {
            return displayName
        }
        val dot = displayName.lastIndexOf('.')
        val stem = if (dot > 0) displayName.substring(0, dot) else displayName
        val extension = if (dot > 0) displayName.substring(dot) else ""
        for (index in 1..maxDuplicateSuffix) {
            val candidate = "$stem ($index)$extension"
            if (!displayNameExists(collection, relativePath, candidate)) {
                return candidate
            }
        }
        return "$stem (${UUID.randomUUID()})$extension"
    }

    /** Whether [relativePath]/[displayName] is already registered in 下载. */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun displayNameExists(
        collection: Uri,
        relativePath: String,
        displayName: String,
    ): Boolean {
        val selection =
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND " +
                "${MediaStore.MediaColumns.DISPLAY_NAME}=?"
        // `RELATIVE_PATH` is stored with a trailing slash on most builds, but
        // not guaranteed on every provider, so both spellings are probed —
        // missing a duplicate is what produces two identical names in 下载.
        for (path in listOf("$relativePath/", relativePath)) {
            try {
                contentResolver
                    .query(
                        collection,
                        arrayOf(MediaStore.MediaColumns._ID),
                        selection,
                        arrayOf(path, displayName),
                        null,
                    )
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            return true
                        }
                    }
            } catch (_: Exception) {
                // A provider that refuses the query cannot prove absence; try
                // the other spelling, then fall through to "not found".
            }
        }
        return false
    }

    /** The `DISPLAY_NAME` MediaStore actually stored for [uri], or `null`. */
    private fun queryDisplayName(uri: Uri): String? =
        try {
            contentResolver
                .query(
                    uri,
                    arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                    null,
                    null,
                    null,
                )
                ?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) {
                        cursor.getString(0)
                    } else {
                        null
                    }
                }
        } catch (_: Exception) {
            null
        }

    /**
     * Android 9 and below: no `MediaStore.Downloads`, so the file is written
     * straight into the public Downloads directory.
     *
     * Writing there needs `WRITE_EXTERNAL_STORAGE` on those releases. It is
     * declared in the manifest with `maxSdkVersion="28"`; where the OS (or a
     * ROM) refuses it, the write throws and the caller gets `{error}` and keeps
     * the private path — an honest "could not export", never a silent
     * half-success.
     */
    @Suppress("DEPRECATION")
    private fun publishToLegacyDownloads(
        source: File,
        displayName: String,
        subdirectory: String,
    ): PublishResult {
        val directory = publicDownloadsDirectory(subdirectory)
        if (!directory.mkdirs() && !directory.isDirectory) {
            return PublishResult(null, "无法创建公共下载目录 ${directory.path}")
        }
        val dot = displayName.lastIndexOf('.')
        val stem = if (dot > 0) displayName.substring(0, dot) else displayName
        val extension = if (dot > 0) displayName.substring(dot) else ""
        var target = File(directory, displayName)
        var index = 0
        while (target.exists() && index < maxDuplicateSuffix) {
            index += 1
            target = File(directory, "$stem ($index)$extension")
        }
        return try {
            source.inputStream().use { input ->
                FileOutputStream(target).use { out -> copyStream(input, out) }
            }
            PublishResult(target.path, null)
        } catch (error: Exception) {
            // A partial legacy copy would look like a complete download, so it
            // is removed rather than left behind.
            target.delete()
            PublishResult(null, error.message ?: error.javaClass.simpleName)
        }
    }

    /**
     * The public `Download/lanlink` directory on the primary external volume.
     *
     * One place for the path: [publishToLegacyDownloads] creates it,
     * [publicDownloadsPath] names a file inside it, and [viewInDownloads] opens
     * it. Three spellings of the same folder would be three chances for the
     * 「在下载里查看」 menu entry to look for a directory nobody writes to — the
     * failure mode is silent (the entry simply stops appearing), which is why the
     * expression lives here rather than being repeated.
     */
    @Suppress("DEPRECATION")
    private fun publicDownloadsDirectory(subdirectory: String): File =
        File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            subdirectory,
        )

    /**
     * The user-facing absolute path of [displayName] inside
     * `Download/<subdirectory>`.
     */
    private fun publicDownloadsPath(displayName: String, subdirectory: String): String =
        File(publicDownloadsDirectory(subdirectory), displayName).path

    /**
     * A safe `Download/<name>` fragment (0.2.29).
     *
     * Runs on **both** ends of the channel on purpose. Dart normalises before it
     * sends (`normalizeDownloadsSubdirectory`), and this does it again, because
     * the write must not depend on the caller: a hostile or buggy name reaching
     * `RELATIVE_PATH` or `File(parent, child)` is exactly the kind of value that
     * silently puts a user's file somewhere they will never look.
     *
     * Empty / blank / `.` / `..` / control characters / an over-long name all fall
     * back to [defaultDownloadsSubdirectory]; nested names (`素材/2026`) survive,
     * because a folder picked two levels down is a legitimate choice.
     */
    private fun sanitizeSubdirectory(raw: String?): String {
        if (raw.isNullOrBlank()) {
            return defaultDownloadsSubdirectory
        }
        val parts =
            raw.replace('\\', '/')
                .split('/')
                .map { it.trim() }
                .filter { it.isNotEmpty() && it != "." && it != ".." }
        if (parts.isEmpty()) {
            return defaultDownloadsSubdirectory
        }
        val joined = parts.joinToString("/")
        if (joined.length > 200 || joined.any { it.isISOControl() }) {
            return defaultDownloadsSubdirectory
        }
        return joined
    }

    // ── folder chooser (0.2.29) ─────────────────────────────────────────────

    /**
     * Starts `ACTION_OPEN_DOCUMENT_TREE` and parks the reply for
     * `onActivityResult`.
     *
     * The user is choosing **where received files land**. Only folders inside
     * `Download` are accepted ([describeTreeChoice]); everything else is refused
     * with a reason, because the publish step still writes through `MediaStore`
     * with a `RELATIVE_PATH`, and a tree anywhere else could not be expressed
     * that way. Making that trade explicit is the whole design: the alternative —
     * writing into an arbitrary SAF tree — turns the file's identity from a path
     * into a `content://` URI, and every capability that opens, shares or
     * re-sends a received file assumes an absolute path.
     */
    private fun startDownloadsFolderPick(result: MethodChannel.Result) {
        if (pendingFolderPick != null) {
            result.success(
                mapOf<String, Any?>(
                    "result" to "failed",
                    "reason" to "已经有一个选择窗口打开了",
                ),
            )
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            // ACTION_OPEN_DOCUMENT_TREE arrived in API 21.
            result.success(mapOf<String, Any?>("result" to "unsupported"))
            return
        }
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }
        pendingFolderPick = result
        try {
            startActivityForResult(intent, folderPickRequestCode)
        } catch (error: ActivityNotFoundException) {
            // A ROM with the picker stripped out. That is a missing capability,
            // not a bug in our code — say so instead of pretending it failed.
            pendingFolderPick = null
            Log.i(logTag, "folder pick: no activity for ACTION_OPEN_DOCUMENT_TREE")
            result.success(mapOf<String, Any?>("result" to "unsupported"))
        } catch (error: Exception) {
            pendingFolderPick = null
            result.success(
                mapOf<String, Any?>(
                    "result" to "failed",
                    "reason" to (error.message ?: error.javaClass.simpleName),
                ),
            )
        }
    }

    // ── send folder (0.2.33) ───────────────────────────────────────────────

    /**
     * Starts `ACTION_OPEN_DOCUMENT_TREE` for 「发送文件夹」.
     *
     * Same intent as [startDownloadsFolderPick], **opposite validation**: this
     * one accepts any tree the user can reach, because the question is "what do
     * you want to send", not "where should received files go". The two live as
     * separate methods on purpose — see [sendFolderPickRequestCode].
     */
    private fun startSendFolderPick(result: MethodChannel.Result) {
        if (pendingSendFolderPick != null) {
            result.success(
                mapOf<String, Any?>(
                    "result" to "failed",
                    "reason" to "已经有一个选择窗口打开了",
                ),
            )
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            result.success(mapOf<String, Any?>("result" to "unsupported"))
            return
        }
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        pendingSendFolderPick = result
        try {
            startActivityForResult(intent, sendFolderPickRequestCode)
        } catch (error: ActivityNotFoundException) {
            pendingSendFolderPick = null
            Log.i(logTag, "send folder: no activity for ACTION_OPEN_DOCUMENT_TREE")
            result.success(mapOf<String, Any?>("result" to "unsupported"))
        } catch (error: Exception) {
            pendingSendFolderPick = null
            result.success(
                mapOf<String, Any?>(
                    "result" to "failed",
                    "reason" to (error.message ?: error.javaClass.simpleName),
                ),
            )
        }
    }

    /** One entry of the SAF walk. */
    private data class TreeEntry(
        val documentId: String,
        val uri: Uri,
        val name: String,
        val isDirectory: Boolean,
        val size: Long,
        /**
         * Where this file sits inside the picked tree, `/`-separated, without the
         * root's own name (0.2.38).
         *
         * Filled in by [walkTree], not by [childrenOf]: the prefix belongs to the
         * walk that reached this entry, and the query has no idea which branch it
         * is being called for. `""` means "not yet placed", which is also the
         * only value a directory ever has.
         */
        val relativePath: String = "",
    )

    /**
     * Walks [treeUri] and answers what would be sent — **without copying** when
     * the folder is too big.
     *
     * The limits are the ones in `domain/folder_send.dart`
     * (6 levels / 200 files / count up to 2000): they are enforced here because
     * the walk happens here, and the desktop path enforces the same numbers in
     * Dart. Two implementations, one policy — the constants are duplicated, so
     * both are named in the code and pinned by tests.
     *
     * **Nothing is truncated.** When the folder holds more than
     * [maxFolderSendFiles] sendable files this answers `too_many` and **copies
     * nothing at all**: sending 200 of 300 would look exactly like "everything
     * arrived", and the user would find the gap on the other end.
     *
     * Skipped on purpose, and counted: names starting with `.` (the tree's own
     * `.thumbnails`, macOS `._x` fork files) and 0-byte files (a shell the
     * receiver cannot open).
     */
    private fun prepareSendFolder(treeUri: Uri): Map<String, Any?> {
        val folderName = treeFolderName(treeUri)
        val walk = walkTree(treeUri)
        if (walk.available > maxFolderSendFiles || walk.capped) {
            Log.i(
                logTag,
                "send folder: too many files in $folderName " +
                    "(available=${walk.available}${if (walk.capped) "+" else ""})",
            )
            return mapOf(
                "result" to "too_many",
                "availableCount" to walk.available,
                "countCapped" to walk.capped,
                "folderName" to folderName,
                "skippedHidden" to walk.skippedHidden,
                "skippedEmpty" to walk.skippedEmpty,
                "skippedTooDeep" to walk.skippedTooDeep,
            )
        }
        if (walk.files.isEmpty()) {
            return mapOf(
                "result" to "empty",
                "folderName" to folderName,
                "skippedHidden" to walk.skippedHidden,
                "skippedEmpty" to walk.skippedEmpty,
                "skippedTooDeep" to walk.skippedTooDeep,
            )
        }
        // Copy one at a time through the same 64 KiB streaming path as a picked
        // file: a folder of videos must never be materialised in memory, and a
        // single unreadable file must not take the whole batch down.
        //
        // **`relativePaths` (0.2.38) is appended in the same loop as `paths`, and
        // only on success.** That is what makes the two arrays same-order and
        // same-length by construction: a failed copy is skipped from *both*, so
        // Dart can zip them by index. Building it from `walk.files` afterwards
        // would slide the arrays the moment one file failed to copy — and a
        // misaligned pair puts file A in file B's directory, which is worse than
        // the flat send it would be replacing.
        val paths = ArrayList<String>(walk.files.size)
        val relativePaths = ArrayList<String>(walk.files.size)
        var totalBytes = 0L
        var failed = 0
        for (entry in walk.files) {
            try {
                paths.add(copyPickedUri(entry.uri))
                relativePaths.add(entry.relativePath)
                totalBytes += entry.size
            } catch (error: Exception) {
                failed += 1
                Log.i(
                    logTag,
                    "send folder: copying ${entry.name} failed: "
                        + (error.message ?: error.javaClass.simpleName),
                )
            }
        }
        Log.i(
            logTag,
            "send folder: $folderName -> ${paths.size} files, $totalBytes bytes, " +
                "failed=$failed, hidden=${walk.skippedHidden}, empty=${walk.skippedEmpty}",
        )
        return mapOf(
            "result" to if (paths.isEmpty()) "failed" else "ok",
            "paths" to paths,
            // Same order, same length as `paths` — `android_folder_picker.dart`
            // refuses the whole array (and sends flat) if it ever is not.
            "relativePaths" to relativePaths,
            "totalBytes" to totalBytes,
            "skippedHidden" to walk.skippedHidden,
            "skippedEmpty" to walk.skippedEmpty,
            "skippedTooDeep" to walk.skippedTooDeep,
            "failed" to failed,
            "folderName" to folderName,
            "reason" to if (paths.isEmpty()) "文件夹里的文件都没能读取" else null,
        )
    }

    /** The counters and candidates one walk produced. */
    private class TreeWalk {
        val files = ArrayList<TreeEntry>()
        var available = 0
        var skippedHidden = 0
        var skippedEmpty = 0
        var skippedTooDeep = 0
        var capped = false
    }

    /**
     * Breadth-first walk of [treeUri]: children of the root are depth 1, and
     * sub-directories are only entered while `depth < maxFolderSendDepth`.
     *
     * The queue carries a **third** element since 0.2.38: the `/`-separated
     * prefix of the directory being listed, relative to the picked root and
     * without its name. That is what makes each file's position recoverable —
     * `(parentId, depth)` alone loses every directory name the walk entered, so
     * the old two-tuple could only ever produce a flat list.
     *
     * The prefix is built with `/` literally, never `File.separator`: it is the
     * **wire** form (`docs/22` §4.3a), and Android is not Windows anyway — using
     * the platform separator here would produce a value that means one thing on
     * the phone and another on the PC that receives it.
     */
    private fun walkTree(treeUri: Uri): TreeWalk {
        val walk = TreeWalk()
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val queue = ArrayDeque<Triple<String, Int, String>>()
        queue.addLast(Triple(rootId, 0, ""))
        while (queue.isNotEmpty()) {
            val (parentId, depth, relPrefix) = queue.removeFirst()
            for (entry in childrenOf(treeUri, parentId)) {
                if (walk.capped) {
                    return walk
                }
                if (entry.name.startsWith(".")) {
                    walk.skippedHidden += 1
                    continue
                }
                if (entry.isDirectory) {
                    if (depth + 1 <= maxFolderSendDepth) {
                        queue.addLast(Triple(entry.documentId, depth + 1, "$relPrefix${entry.name}/"))
                    } else {
                        walk.skippedTooDeep += 1
                    }
                    continue
                }
                if (entry.size <= 0L) {
                    walk.skippedEmpty += 1
                    continue
                }
                walk.available += 1
                if (walk.available > maxFolderSendCountCap) {
                    walk.capped = true
                    return walk
                }
                if (walk.files.size < maxFolderSendFiles) {
                    walk.files.add(entry.copy(relativePath = "$relPrefix${entry.name}"))
                }
            }
        }
        return walk
    }

    /**
     * The direct children of [parentDocumentId] inside [treeUri].
     *
     * A provider that refuses the query yields an empty list rather than an
     * exception: the walk then reports what it could see, and [prepareSendFolder]
     * turns "nothing usable" into `empty` — the user still gets an answer instead
     * of a crash. (A hard failure of the *first* query surfaces the same way; the
     * distinction between "empty folder" and "provider said no" is not worth a
     * separate wire code, and both end with nothing sent.)
     */
    private fun childrenOf(treeUri: Uri, parentDocumentId: String): List<TreeEntry> {
        val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)
        val projection =
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
            )
        val entries = ArrayList<TreeEntry>()
        try {
            contentResolver.query(childrenUri, projection, null, null, null)
                ?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val documentId = cursor.getString(0) ?: continue
                        val name = cursor.getString(1) ?: continue
                        val mime = cursor.getString(2)
                        val size: Long = if (cursor.isNull(3)) -1L else cursor.getLong(3)
                        entries.add(
                            TreeEntry(
                                documentId = documentId,
                                uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId),
                                name = name,
                                isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR,
                                size = size,
                            ),
                        )
                    }
                }
        } catch (error: Exception) {
            Log.i(
                logTag,
                "send folder: listing $parentDocumentId failed: "
                    + (error.message ?: error.javaClass.simpleName),
            )
        }
        return entries
    }

    /** A human name for the picked tree (the last segment of its document id). */
    private fun treeFolderName(treeUri: Uri): String {
        val id =
            try {
                DocumentsContract.getTreeDocumentId(treeUri)
            } catch (error: Exception) {
                ""
            }
        val tail = id.substringAfterLast(':').trim('/')
        if (tail.isEmpty()) {
            return "文件夹"
        }
        return tail.substringAfterLast('/')
    }

    /**
     * Turns the tree the user picked into `{result, subdirectory}.
     *
     * Validation is deliberately strict, and each rejection says why:
     *
     * * authority must be [externalStorageProvider] — the only provider that maps
     *   onto `/storage/emulated/0/Download` (a cloud provider's tree has no
     *   `RELATIVE_PATH` equivalent);
     * * the document id must be `primary:Download` **or** start with
     *   `primary:Download/` — anything else would publish outside 下载;
     * * the `Download` root itself is **refused**: received files would scatter
     *   among the user's own downloads, and `""` already means "never chosen"
     *   (so accepting it would make "restore default" and "picked the root"
     *   indistinguishable on disk).
     *
     * Nothing is persisted here — this method only *describes* the choice. Dart
     * stores it, which keeps one writer for the settings document.
     */
    private fun describeTreeChoice(uri: Uri): Map<String, Any?> {
        if (uri.authority != externalStorageProvider) {
            return mapOf(
                "result" to "invalid",
                "reason" to "只能选择本机存储里「下载」中的文件夹",
            )
        }
        val documentId =
            try {
                DocumentsContract.getTreeDocumentId(uri)
            } catch (error: Exception) {
                return mapOf(
                    "result" to "invalid",
                    "reason" to "无法识别这个文件夹",
                )
            }
        val root = "primary:" + Environment.DIRECTORY_DOWNLOADS
        if (documentId != root && !documentId.startsWith("$root/")) {
            return mapOf(
                "result" to "invalid",
                "reason" to "只能选择「下载」里的文件夹",
            )
        }
        val relative = documentId.removePrefix(root).trim('/')
        if (relative.isEmpty()) {
            return mapOf(
                "result" to "invalid",
                "reason" to "请选择「下载」里的一个文件夹",
            )
        }
        val subdirectory = sanitizeSubdirectory(relative)
        if (subdirectory != relative) {
            // The name did not survive sanitising (dots, control characters, too
            // long). Accepting it would store one name and write to another.
            return mapOf(
                "result" to "invalid",
                "reason" to "这个文件夹名不能用",
            )
        }
        // Keep the grant across restarts. Best effort: the publish path goes
        // through MediaStore and needs no tree permission, so a ROM that refuses
        // to persist it still saves and publishes correctly.
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (error: Exception) {
            Log.i(
                logTag,
                "folder pick: could not persist ${uri} (${error.message}); " +
                    "MediaStore writes do not need it",
            )
        }
        Log.i(logTag, "folder pick: $documentId -> subdirectory=$subdirectory")
        return mapOf("result" to "ok", "subdirectory" to subdirectory)
    }

    /**
     * The MIME type to register with: the caller's, when it has a real one,
     * otherwise one guessed from the file's extension, otherwise the generic
     * binary type.
     *
     * A wrong type is not cosmetic — the gallery only lists what it can play, and
     * A wildcard MIME or `application/octet-stream` on a video is exactly why a phone
     * gallery would show the file as "unknown" instead of as a video.
     *
     * (Note for whoever edits this comment: never write the MIME wildcard as
     * star-slash-star inside a KDoc. Those three characters close the comment
     * early and turn the rest of it into Kotlin — which is exactly the syntax
     * error this file once shipped with, reported against the line BELOW as
     * "Expecting member declaration".)
     */
    private fun resolveMimeType(declared: String?, fileName: String): String {
        val trimmed = declared?.trim().orEmpty()
        if (trimmed.isNotEmpty() && trimmed != "*/*") {
            return trimmed
        }
        val dot = fileName.lastIndexOf('.')
        if (dot in 0 until fileName.length - 1) {
            val extension = fileName.substring(dot + 1).lowercase()
            val guessed = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            if (!guessed.isNullOrEmpty()) {
                return guessed
            }
        }
        return "application/octet-stream"
    }

    /** Copies [input] to [output] in [copyBufferBytes] chunks (never buffered whole). */
    private fun copyStream(input: InputStream, output: OutputStream) {
        val buffer = ByteArray(copyBufferBytes)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) {
                break
            }
            output.write(buffer, 0, read)
        }
        output.flush()
    }

    private fun emitProgress(done: Long, total: Long) {
        val channel = pickerChannel ?: return
        runOnUiThread {
            channel.invokeMethod("progress", mapOf("done" to done, "total" to total))
        }
    }

    private fun displayName(uri: Uri): String? = queryString(uri, OpenableColumns.DISPLAY_NAME)

    private fun declaredSize(uri: Uri): Long = queryLong(uri, OpenableColumns.SIZE) ?: -1L

    private fun queryString(uri: Uri, column: String): String? {
        contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) {
                return cursor.getString(0)
            }
        }
        return null
    }

    private fun queryLong(uri: Uri, column: String): Long? {
        contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) {
                return cursor.getLong(0)
            }
        }
        return null
    }

    /** Keeps the picked name a safe leaf (no separators, no `..`). */
    private fun sanitize(name: String): String {
        val cleaned = name.replace('\\', '_').replace('/', '_').replace("..", "_")
        return cleaned.ifEmpty { "file" }
    }

    override fun onDestroy() {
        releaseLock()
        super.onDestroy()
    }
}
