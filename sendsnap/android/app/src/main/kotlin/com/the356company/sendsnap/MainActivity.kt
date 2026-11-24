package com.the356company.sendsnap

import android.app.DownloadManager
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.the356company.sendsnap/file_utils"
    private val DIRECT_P2P_CHANNEL = "com.the356company.sendsnap/direct_p2p"
    private val AIR_GESTURE_CHANNEL = "com.the356company.sendsnap/air_gesture"
    private val AIR_GESTURE_EVENTS_CHANNEL = "com.the356company.sendsnap/air_gesture_events"
    private var multicastLock: WifiManager.MulticastLock? = null
    private var sharedFilePaths: ArrayList<String> = ArrayList()
    private var wifiDirectManager: WifiDirectManager? = null
    private var nsdManager: NsdDiscoveryManager? = null
    private var directP2pChannel: MethodChannel? = null
    private var airGestureManager: AirGestureManager? = null
    private var airGestureEventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleSendIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSendIntent(intent)
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            MethodChannel(messenger, CHANNEL).invokeMethod("onFilesShared", sharedFilePaths)
        }
    }

    private fun handleSendIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (Intent.ACTION_SEND == action) {
            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            } ?: intent.data

            uri?.let {
                val path = resolveUriToFilePath(it)
                if (path != null) {
                    sharedFilePaths = arrayListOf(path)
                }
            }
        } else if (Intent.ACTION_SEND_MULTIPLE == action) {
            val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }

            val paths = ArrayList<String>()
            uris?.forEach { uri ->
                resolveUriToFilePath(uri)?.let { paths.add(it) }
            }
            sharedFilePaths = paths
        } else if (Intent.ACTION_VIEW == action) {
            val uri = intent.data
            uri?.let {
                val path = resolveUriToFilePath(it)
                if (path != null) {
                    sharedFilePaths = arrayListOf(path)
                }
            }
        }
    }

    private fun resolveUriToFilePath(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.path
        }
        // If content URI, try resolving the direct file path from MediaStore first (zero-copy)
        if (uri.scheme == "content") {
            try {
                val proj = arrayOf(MediaStore.MediaColumns.DATA)
                contentResolver.query(uri, proj, null, null, null)?.use { cursor ->
                    val dataCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                    if (dataCol != -1 && cursor.moveToFirst()) {
                        val realPath = cursor.getString(dataCol)
                        if (!realPath.isNullOrBlank()) {
                            val f = File(realPath)
                            if (f.exists() && f.canRead()) {
                                return f.absolutePath
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        try {
            var displayName = "shared_${System.currentTimeMillis()}"
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex != -1 && cursor.moveToFirst()) {
                    val name = cursor.getString(nameIndex)
                    if (!name.isNullOrBlank()) {
                        displayName = name
                    }
                }
            }

            val cacheDir = File(cacheDir, "shared_incoming")
            if (!cacheDir.exists()) cacheDir.mkdirs()
            val destFile = File(cacheDir, displayName)

            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output)
                }
            }
            return destFile.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            return null
        }
    }

    private fun queryInstalledApps(): List<Map<String, Any>> {
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolveInfos = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                launcherIntent,
                PackageManager.ResolveInfoFlags.of(0L)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(launcherIntent, 0)
        }

        val allApps = mutableListOf<Map<String, Any>>()
        val userApps = mutableListOf<Map<String, Any>>()
        val seenPackages = mutableSetOf<String>()

        for (info in resolveInfos) {
            val activityInfo = info.activityInfo ?: continue
            val appInfo = activityInfo.applicationInfo ?: continue
            val pkgName = appInfo.packageName ?: continue
            if (!seenPackages.add(pkgName)) continue

            val apkPath = appInfo.publicSourceDir?.takeIf { it.isNotBlank() } ?: appInfo.sourceDir
            if (apkPath.isNullOrBlank()) continue
            val apkFile = File(apkPath)
            if (!apkFile.exists() || !apkFile.canRead()) continue

            val rawLabel = try {
                packageManager.getApplicationLabel(appInfo).toString().trim()
            } catch (_: Exception) {
                pkgName
            }
            val cleanBase = rawLabel.replace(Regex("[/\\\\:*?\"<>|]"), "_").ifEmpty { pkgName }
            val displayApkName = if (cleanBase.lowercase().endsWith(".apk")) cleanBase else "$cleanBase.apk"

            val lastUpdateMs = try {
                val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.getPackageInfo(pkgName, PackageManager.PackageInfoFlags.of(0L))
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.getPackageInfo(pkgName, 0)
                }
                pkgInfo.lastUpdateTime
            } catch (_: Exception) {
                apkFile.lastModified()
            }

            val entry = mapOf<String, Any>(
                "path" to apkFile.absolutePath,
                "name" to displayApkName,
                "packageName" to pkgName,
                "size" to apkFile.length(),
                "modified" to lastUpdateMs,
                "isInstalledApp" to true
            )
            allApps.add(entry)

            val isPureSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
                (appInfo.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
            if (!isPureSystem) {
                userApps.add(entry)
            }
        }

        val result = if (userApps.isNotEmpty()) userApps else allApps
        return result.sortedBy { (it["name"] as String).lowercase() }
    }

    private fun queryMediaStoreFiles(type: String): List<Map<String, Any>> {
        val list = mutableListOf<Map<String, Any>>()
        val typeLower = type.lowercase()
        val isRecent = typeLower == "recents" || typeLower == "recent"
        val isDocs = typeLower == "documents" || typeLower == "docs" || typeLower == "document" || typeLower == "doc"
        val isArchives = typeLower == "archives" || typeLower == "archive"

        val uri = when {
            typeLower in listOf("videos", "video") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            typeLower in listOf("photos", "images", "photo", "image") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            typeLower in listOf("audio") -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            isRecent || isDocs || isArchives -> MediaStore.Files.getContentUri("external")
            else -> null
        } ?: return list

        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED
        )

        val selection = when {
            isRecent -> "${MediaStore.MediaColumns.SIZE} > 0 AND ${MediaStore.MediaColumns.DISPLAY_NAME} NOT LIKE '.%'"
            isDocs -> {
                val docExtensions = listOf(
                    "%.pdf", "%.doc", "%.docx", "%.xls", "%.xlsx", "%.ppt", "%.pptx",
                    "%.txt", "%.csv", "%.rtf", "%.md", "%.json", "%.xml", "%.yaml", "%.yml",
                    "%.html", "%.epub", "%.mobi", "%.odt", "%.ods", "%.odp",
                    "%.dwg", "%.dxf", "%.stl", "%.obj", "%.step", "%.stp",
                    "%.sldprt", "%.sldasm", "%.blend", "%.psd", "%.ai",
                    "%.py", "%.dart", "%.js", "%.ts", "%.java", "%.kt", "%.cpp", "%.c", "%.sql"
                )
                val extConditions = docExtensions.joinToString(" OR ") {
                    "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE '$it'"
                }
                "${MediaStore.MediaColumns.SIZE} > 0 AND ($extConditions)"
            }
            isArchives -> {
                val archiveExtensions = listOf(
                    "%.zip", "%.rar", "%.7z", "%.tar", "%.gz", "%.bz2", "%.xz", "%.iso",
                    "%.apk", "%.xapk", "%.apkm", "%.aab", "%.exe", "%.msi", "%.dmg",
                    "%.deb", "%.rpm", "%.bin"
                )
                val extConditions = archiveExtensions.joinToString(" OR ") {
                    "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE '$it'"
                }
                "${MediaStore.MediaColumns.SIZE} > 0 AND ($extConditions)"
            }
            else -> null
        }
        val sortOrder = "${MediaStore.MediaColumns.DATE_MODIFIED} DESC LIMIT 150"
        try {
            contentResolver.query(uri, projection, selection, null, sortOrder)?.use { cursor ->
                val idCol = cursor.getColumnIndex(MediaStore.MediaColumns._ID)
                val dataCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                val nameCol = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                val modCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_MODIFIED)

                while (cursor.moveToNext()) {
                    val id = if (idCol != -1) cursor.getLong(idCol) else 0L
                    val path = if (dataCol != -1) cursor.getString(dataCol) else null
                    val name = if (nameCol != -1) cursor.getString(nameCol) else null
                    val size = if (sizeCol != -1) cursor.getLong(sizeCol) else 0L
                    val mod = if (modCol != -1) cursor.getLong(modCol) * 1000L else System.currentTimeMillis()

                    val finalName = if (!name.isNullOrBlank()) name else (if (path != null) File(path).name else "file_$id")
                    val finalPath = if (!path.isNullOrBlank()) path else ContentUris.withAppendedId(uri, id).toString()

                    list.add(
                        mapOf(
                            "path" to finalPath,
                            "name" to finalName,
                            "size" to size,
                            "modified" to mod
                        )
                    )
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return list
    }

    private fun openDocumentsUI(folderPath: String): Boolean {
        val folder = File(folderPath)
        if (!folder.exists()) {
            try { folder.mkdirs() } catch (_: Exception) {}
        }
        try {
            val externalStoragePath = Environment.getExternalStorageDirectory().absolutePath
            val relativePath = if (folderPath.startsWith(externalStoragePath)) {
                folderPath.removePrefix(externalStoragePath).trimStart('/')
            } else {
                "Download/SendSnap"
            }
            val docId = "primary:$relativePath"
            val uri = DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", docId)

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            val resolvedActivities = packageManager.queryIntentActivities(intent, 0)
                .filter { it.activityInfo.packageName != applicationContext.packageName }

            val docUiActivity = resolvedActivities.firstOrNull { it.activityInfo.packageName == "com.android.documentsui" }
                ?: resolvedActivities.firstOrNull()

            if (docUiActivity != null) {
                intent.setPackage(docUiActivity.activityInfo.packageName)
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {}

        try {
            val dmIntent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (dmIntent.resolveActivity(packageManager) != null) {
                startActivity(dmIntent)
                return true
            }
        } catch (_: Exception) {}

        return false
    }

    private fun openOemFileManager(folderPath: String): Boolean {
        val folder = File(folderPath)
        if (!folder.exists()) {
            try { folder.mkdirs() } catch (_: Exception) {}
        }

        val knownPackages = arrayOf(
            "com.mi.android.globalFileexplorer",   // Xiaomi / Redmi / Poco
            "com.google.android.apps.nfiles",      // Files by Google
            "com.sec.android.app.myfiles",         // Samsung My Files
            "com.oneplus.filemanager",             // OnePlus
            "com.coloros.filemanager",             // Oppo / Realme
            "com.huawei.hidisk"                    // Huawei
        )

        for (pkg in knownPackages) {
            try {
                val launchIntent = packageManager.getLaunchIntentForPackage(pkg) ?: continue
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                launchIntent.putExtra("explorer_path", folderPath)
                launchIntent.putExtra("path", folderPath)
                launchIntent.putExtra("folder_path", folderPath)
                launchIntent.putExtra("current_directory", folderPath)
                launchIntent.putExtra("current_dir", folderPath)
                launchIntent.putExtra("KEY_FOLDER_PATH", folderPath)
                launchIntent.putExtra("start_dir", folderPath)
                launchIntent.putExtra("root", folderPath)

                try {
                    val fileUri = FileProvider.getUriForFile(
                        this,
                        "${applicationContext.packageName}.fileprovider",
                        folder
                    )
                    launchIntent.setDataAndType(fileUri, "resource/folder")
                    launchIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: Exception) {}

                startActivity(launchIntent)
                return true
            } catch (_: Exception) {}
        }

        return openDocumentsUI(folderPath)
    }

    private fun openFileManagerAtFolder(folderPath: String, filePath: String?): Boolean {
        val folder = File(folderPath)
        if (!folder.exists()) {
            try { folder.mkdirs() } catch (_: Exception) {}
        }

        // 1. Android System Intent Resolver ("Just once" / "Always") via ACTION_VIEW_DOWNLOADS
        try {
            val dmIntent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("folder_path", folderPath)
                putExtra("path", folderPath)
                putExtra("explorer_path", folderPath)
            }
            if (dmIntent.resolveActivity(packageManager) != null) {
                startActivity(dmIntent)
                return true
            }
        } catch (_: Exception) {}

        // 2. DocumentsContract directory view without hardcoded package (allows system resolver)
        try {
            val externalStoragePath = Environment.getExternalStorageDirectory().absolutePath
            val relativePath = if (folderPath.startsWith(externalStoragePath)) {
                folderPath.removePrefix(externalStoragePath).trimStart('/')
            } else {
                "Download/SendSnap"
            }
            val docId = "primary:$relativePath"
            val uri = DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", docId)

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {}

        // 3. Fallbacks
        if (openDocumentsUI(folderPath)) return true
        return openOemFileManager(folderPath)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPackageInstalled" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    val installed = try {
                        packageManager.getPackageInfo(pkg, 0)
                        true
                    } catch (_: Exception) {
                        false
                    }
                    result.success(installed)
                }
                "openFileWithPackage" -> {
                    val path = call.argument<String>("path")
                    val pkg = call.argument<String>("package") ?: ""
                    if (path == null) {
                        result.error("INVALID_ARGS", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(path)
                        val extension = MimeTypeMap.getFileExtensionFromUrl(file.name)
                        val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "*/*"
                        val uri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            if (pkg.isNotEmpty()) {
                                setPackage(pkg)
                            }
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_ERROR", "Could not open file with package: ${e.message}", null)
                    }
                }
                "getInitialSharedFiles" -> {
                    val list = ArrayList(sharedFilePaths)
                    sharedFilePaths.clear()
                    result.success(list)
                }
                "queryMediaFiles" -> {
                    val mediaType = call.argument<String>("type") ?: "videos"
                    Thread {
                        val items = queryMediaStoreFiles(mediaType)
                        runOnUiThread {
                            result.success(items)
                        }
                    }.start()
                }
                "queryInstalledApps" -> {
                    Thread {
                        val apps = try {
                            queryInstalledApps()
                        } catch (_: Exception) {
                            emptyList<Map<String, Any>>()
                        }
                        runOnUiThread {
                            result.success(apps)
                        }
                    }.start()
                }
                "resolveUri" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr != null) {
                        Thread {
                            val resolved = resolveUriToFilePath(Uri.parse(uriStr))
                            runOnUiThread {
                                result.success(resolved)
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "uri is required", null)
                    }
                }
                "copyFromContentUri" -> {
                    val contentUri = call.argument<String>("uri")
                    val destPath = call.argument<String>("destPath")
                    if (contentUri == null || destPath == null) {
                        result.error("INVALID_ARGS", "uri and destPath are required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = Uri.parse(contentUri)
                        val inputStream = contentResolver.openInputStream(uri)
                        if (inputStream == null) {
                            result.error("STREAM_ERROR", "Could not open input stream for URI: $contentUri", null)
                            return@setMethodCallHandler
                        }
                        val destFile = File(destPath)
                        destFile.parentFile?.mkdirs()
                        val outputStream = FileOutputStream(destFile)
                        inputStream.use { input ->
                            outputStream.use { output ->
                                input.copyTo(output)
                            }
                        }
                        result.success(destFile.absolutePath)
                    } catch (e: Exception) {
                        result.error("COPY_ERROR", "Failed to copy from content URI: ${e.message}", null)
                    }
                }
                "openDocumentsUI" -> {
                    val path = call.argument<String>("path")
                        ?: (Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath + "/SendSnap")
                    try {
                        val opened = openDocumentsUI(path)
                        result.success(opened)
                    } catch (e: Exception) {
                        result.error("DOCUMENTS_UI_ERROR", "Could not open DocumentsUI: ${e.message}", null)
                    }
                }
                "openOemFileManager" -> {
                    val path = call.argument<String>("path")
                        ?: (Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath + "/SendSnap")
                    try {
                        val opened = openOemFileManager(path)
                        result.success(opened)
                    } catch (e: Exception) {
                        result.error("OEM_FM_ERROR", "Could not open OEM file manager: ${e.message}", null)
                    }
                }
                "openFileManager" -> {
                    val path = call.argument<String>("path")
                        ?: (Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath + "/SendSnap")
                    val filePath = call.argument<String>("filePath")
                    try {
                        val opened = openFileManagerAtFolder(path, filePath)
                        result.success(opened)
                    } catch (e: Exception) {
                        result.error("OPEN_ERROR", "Could not open file manager: ${e.message}", null)
                    }
                }
                "openFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGS", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(path)
                        val extension = MimeTypeMap.getFileExtensionFromUrl(file.name)
                        val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "*/*"
                        
                        val uri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider", 
                            file
                        )
                        
                        val intent = Intent(Intent.ACTION_VIEW)
                        intent.setDataAndType(uri, mimeType)
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_ERROR", "Could not open file: ${e.message}", null)
                    }
                }
                "acquireMulticastLock" -> {
                    try {
                        if (multicastLock == null) {
                            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifiManager.createMulticastLock("SendSnapMulticastLock").apply {
                                setReferenceCounted(true)
                            }
                        }
                        if (multicastLock?.isHeld != true) {
                            multicastLock?.acquire()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCK_ERROR", "Failed to acquire multicast lock: ${e.message}", null)
                    }
                }
                "releaseMulticastLock" -> {
                    try {
                        if (multicastLock?.isHeld == true) {
                            multicastLock?.release()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCK_ERROR", "Failed to release multicast lock: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        setupDirectP2pChannel(flutterEngine)
        setupAirGestureChannel(flutterEngine)
    }

    private fun setupDirectP2pChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DIRECT_P2P_CHANNEL)
        directP2pChannel = channel

        val directMgr = wifiDirectManager ?: WifiDirectManager(applicationContext).also {
            wifiDirectManager = it
        }
        val nsdMgr = nsdManager ?: NsdDiscoveryManager(applicationContext).also {
            nsdManager = it
        }

        directMgr.onPeerFound = { peerMap ->
            runOnUiThread {
                directP2pChannel?.invokeMethod("onWifiDirectDeviceFound", peerMap)
            }
        }
        directMgr.onHotspotReady = { hotspotMap ->
            runOnUiThread {
                directP2pChannel?.invokeMethod("onDirectHotspotReady", hotspotMap)
            }
        }
        directMgr.onConnectionChanged = { connected, goIp ->
            runOnUiThread {
                directP2pChannel?.invokeMethod(
                    "onDirectConnectionChanged",
                    mapOf("connected" to connected, "goIp" to (goIp ?: ""))
                )
            }
        }
        directMgr.onWifiStateChanged = { enabled ->
            runOnUiThread {
                directP2pChannel?.invokeMethod("onWifiStateChanged", enabled)
            }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getDirectStatus" -> {
                    result.success(directMgr.getStatus())
                }
                "openWifiPanel" -> {
                    result.success(directMgr.openWifiPanel(this))
                }
                "openHotspotSettings" -> {
                    result.success(directMgr.openHotspotSettings(this))
                }
                "startNsdAdvertising" -> {
                    val id = call.argument<String>("id") ?: ""
                    val name = call.argument<String>("name") ?: "SendSnap Device"
                    val port = call.argument<Int>("port") ?: 53318
                    val deviceType = call.argument<String>("deviceType") ?: "android"
                    if (id.isEmpty()) {
                        result.success(false)
                    } else {
                        nsdMgr.registerService(id, name, port, deviceType)
                        result.success(true)
                    }
                }
                "stopNsdAdvertising" -> {
                    nsdMgr.unregisterService()
                    result.success(true)
                }
                "startNsdDiscovery" -> {
                    val localId = call.argument<String>("localId") ?: ""
                    nsdMgr.startDiscovery(
                        localId = localId,
                        onFound = { deviceMap ->
                            runOnUiThread {
                                directP2pChannel?.invokeMethod("onNsdDeviceFound", deviceMap)
                            }
                        },
                        onLost = { lostId ->
                            runOnUiThread {
                                directP2pChannel?.invokeMethod("onNsdDeviceLost", lostId)
                            }
                        }
                    )
                    result.success(true)
                }
                "stopNsdDiscovery" -> {
                    nsdMgr.stopDiscovery()
                    result.success(true)
                }
                "startWifiDirectAdvertising" -> {
                    val id = call.argument<String>("id") ?: ""
                    val name = call.argument<String>("name") ?: "SendSnap Device"
                    val port = call.argument<Int>("port") ?: 53318
                    val airToken = call.argument<String>("airToken")
                    var replied = false
                    directMgr.startAdvertising(id, name, port, airToken) { success, error ->
                        runOnUiThread {
                            if (!replied) {
                                replied = true
                                result.success(mapOf("success" to success, "error" to (error ?: "")))
                            }
                        }
                    }
                }
                "stopWifiDirectAdvertising" -> {
                    directMgr.stopAdvertising()
                    result.success(true)
                }
                "startWifiDirectDiscovery" -> {
                    val isPassive = call.argument<Boolean>("isPassive") ?: false
                    result.success(directMgr.startDiscovery(isPassive))
                }
                "setWifiDirectDiscoveryPace" -> {
                    val isPassive = call.argument<Boolean>("isPassive") ?: false
                    directMgr.setDiscoveryPace(isPassive)
                    result.success(true)
                }
                "stopWifiDirectDiscovery" -> {
                    directMgr.stopDiscovery()
                    result.success(true)
                }
                "connectWifiDirectPeer" -> {
                    val ssid = call.argument<String>("ssid")
                    val passphrase = call.argument<String>("passphrase")
                    val deviceAddress = call.argument<String>("deviceAddress")
                    val goIp = call.argument<String>("goIp")
                    val port = call.argument<Int>("port") ?: 53318
                    var replied = false
                    directMgr.connectToPeer(ssid, passphrase, deviceAddress, goIp, port) { success, ip, error ->
                        runOnUiThread {
                            if (!replied) {
                                replied = true
                                result.success(
                                    mapOf(
                                        "success" to success,
                                        "goIp" to (ip ?: ""),
                                        "error" to (error ?: "")
                                    )
                                )
                            }
                        }
                    }
                }
                "disconnectWifiDirect" -> {
                    directMgr.disconnectDirect()
                    result.success(true)
                }
                "ensureLanWifiRouting" -> {
                    val enable = call.argument<Boolean>("enable") ?: true
                    result.success(directMgr.ensureLanWifiRouting(enable))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupAirGestureChannel(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val manager = airGestureManager ?: AirGestureManager(applicationContext, this).also {
            airGestureManager = it
        }

        EventChannel(messenger, AIR_GESTURE_EVENTS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    airGestureEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    airGestureEventSink = null
                    manager.stop()
                }
            }
        )

        MethodChannel(messenger, AIR_GESTURE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> {
                    result.success(manager.isSupported())
                }
                "start" -> {
                    manager.start(
                        onFrame = { frameMap ->
                            runOnUiThread {
                                airGestureEventSink?.success(frameMap)
                            }
                        },
                        onError = { errorMsg ->
                            runOnUiThread {
                                airGestureEventSink?.error("AIR_GESTURE_ERROR", errorMsg, null)
                            }
                        },
                    )
                    result.success(true)
                }
                "stop" -> {
                    manager.stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        try {
            airGestureManager?.dispose()
            airGestureManager = null
        } catch (_: Exception) {}
        airGestureEventSink = null
        try {
            wifiDirectManager?.dispose()
            wifiDirectManager = null
        } catch (_: Exception) {}
        try {
            nsdManager?.dispose()
            nsdManager = null
        } catch (_: Exception) {}
        directP2pChannel = null
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
