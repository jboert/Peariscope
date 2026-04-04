package com.peariscope.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DesktopWindows
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.compose.ui.platform.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.common.InputImage
import com.peariscope.R
import com.peariscope.network.NetworkManager
import com.peariscope.network.SavedHosts
import com.peariscope.ui.theme.PearGreen
import com.peariscope.ui.theme.PearGlow
import java.util.concurrent.Executors

@Composable
fun ConnectScreen(
    networkManager: NetworkManager,
    onConnected: () -> Unit,
    onHost: () -> Unit = {},
    onSettings: () -> Unit = {}
) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("peariscope", Context.MODE_PRIVATE) }
    var connectionCode by remember { mutableStateOf("") }
    var savedHosts by remember { mutableStateOf(SavedHosts.loadAll(prefs)) }
    var suggestions by remember { mutableStateOf<List<String>>(emptyList()) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var otaStatus by remember { mutableStateOf(networkManager.otaStatus) }
    var otaVersion by remember { mutableStateOf(networkManager.otaVersion) }
    var showScanner by remember { mutableStateOf(false) }
    var renamingHost by remember { mutableStateOf<SavedHosts.Host?>(null) }
    var renameText by remember { mutableStateOf("") }
    val clipboardManager = LocalClipboardManager.current

    // Camera permission
    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasCameraPermission = granted
        if (granted) showScanner = true
    }

    // Listen for connection state changes — chain with existing callback
    // (MainActivity sets onConnectionStateChanged for screen transitions)
    DisposableEffect(networkManager) {
        val prevCallback = networkManager.onConnectionStateChanged
        networkManager.onConnectionStateChanged = {
            prevCallback?.invoke()
            errorMessage = networkManager.lastError
            otaStatus = networkManager.otaStatus
            otaVersion = networkManager.otaVersion
        }
        onDispose {
            networkManager.onConnectionStateChanged = prevCallback
        }
    }

    // QR Scanner sheet
    if (showScanner) {
        QRScannerSheet(
            onCodeScanned = { code ->
                showScanner = false
                val displayCode = extractCode(code)
                connectionCode = displayCode
                SavedHosts.save(prefs, displayCode)
                savedHosts = SavedHosts.loadAll(prefs)
                networkManager.connect(displayCode)
            },
            onDismiss = { showScanner = false }
        )
        return
    }

    Box(modifier = Modifier.fillMaxSize()) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Hero section
        item {
            Spacer(modifier = Modifier.height(48.dp))
            HeroSection()
            Spacer(modifier = Modifier.height(32.dp))
        }

        // Seed phrase input
        item {
            SeedPhraseInput(
                value = connectionCode,
                onValueChange = { newValue ->
                    connectionCode = newValue
                    suggestions = BIP39.completions(newValue)
                },
                onConnect = {
                    val trimmed = connectionCode.trim()
                    if (trimmed.isNotEmpty()) {
                        SavedHosts.save(prefs, trimmed)
                        savedHosts = SavedHosts.loadAll(prefs)
                        networkManager.connect(trimmed)
                    }
                },
                modifier = Modifier.padding(horizontal = 24.dp)
            )
        }

        // BIP39 suggestions
        if (suggestions.isNotEmpty()) {
            item {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = 24.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    items(suggestions.take(8)) { word ->
                        SuggestionChip(word) {
                            connectionCode = applySuggestion(connectionCode, word)
                            suggestions = emptyList()
                        }
                    }
                }
            }
        }

        // Quick actions — Scan QR + Paste (matches iOS)
        item {
            Spacer(modifier = Modifier.height(16.dp))
            Row(
                modifier = Modifier.padding(horizontal = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                QuickActionButton(
                    icon = Icons.Default.CameraAlt,
                    title = "Scan QR",
                    modifier = Modifier.weight(1f)
                ) {
                    if (hasCameraPermission) {
                        showScanner = true
                    } else {
                        permissionLauncher.launch(Manifest.permission.CAMERA)
                    }
                }

                QuickActionButton(
                    icon = Icons.Default.ContentPaste,
                    title = "Paste",
                    modifier = Modifier.weight(1f)
                ) {
                    clipboardManager.getText()?.text?.let { text ->
                        if (text.isNotEmpty()) connectionCode = text
                    }
                }

                QuickActionButton(
                    icon = Icons.Default.DesktopWindows,
                    title = "Host",
                    modifier = Modifier.weight(1f)
                ) {
                    onHost()
                }
            }
        }

        // OTA update status
        if (otaStatus != NetworkManager.OtaStatus.IDLE) {
            item {
                Spacer(modifier = Modifier.height(12.dp))
                OtaStatusBanner(otaStatus, otaVersion, networkManager.otaError)
            }
        }

        // Error message
        if (errorMessage != null) {
            item {
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    text = errorMessage ?: "",
                    color = Color.Red,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 24.dp)
                )
            }
        }

        // Recent connections
        if (savedHosts.isNotEmpty()) {
            item {
                Spacer(modifier = Modifier.height(24.dp))
                Text(
                    text = "RECENT",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.Gray,
                    letterSpacing = 1.sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 28.dp, bottom = 8.dp)
                )
            }

            items(savedHosts) { host ->
                SavedHostRow(
                    host = host,
                    onClick = {
                        connectionCode = host.code
                        SavedHosts.save(prefs, host.code)
                        savedHosts = SavedHosts.loadAll(prefs)
                        networkManager.connect(host.code)
                    },
                    onPin = {
                        SavedHosts.togglePin(prefs, host.code)
                        savedHosts = SavedHosts.loadAll(prefs)
                    },
                    onRename = {
                        renameText = host.name
                        renamingHost = host
                    },
                    onDelete = {
                        SavedHosts.remove(prefs, host.code)
                        savedHosts = SavedHosts.loadAll(prefs)
                    },
                    modifier = Modifier.padding(horizontal = 24.dp)
                )
            }
        }

        // Footer
        item {
            Spacer(modifier = Modifier.height(32.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Powered by", fontSize = 10.sp, color = Color(0xFF555555))
                Text("Pear Runtime", fontSize = 10.sp, color = Color(0xFF555555))
            }
            Spacer(modifier = Modifier.height(16.dp))
        }
    }

    // Settings gear — top right
    IconButton(
        onClick = onSettings,
        modifier = Modifier
            .align(Alignment.TopEnd)
            .statusBarsPadding()
            .padding(end = 12.dp, top = 8.dp)
            .size(48.dp)
    ) {
        Icon(
            Icons.Default.Settings,
            contentDescription = "Settings",
            tint = Color.Gray,
            modifier = Modifier.size(22.dp)
        )
    }
    } // end Box

    // Rename dialog
    if (renamingHost != null) {
        AlertDialog(
            onDismissRequest = { renamingHost = null },
            title = { Text("Rename") },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    placeholder = { Text("Name") },
                    singleLine = true
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    if (renameText.isNotEmpty()) {
                        SavedHosts.rename(prefs, renamingHost!!.code, renameText)
                        savedHosts = SavedHosts.loadAll(prefs)
                    }
                    renamingHost = null
                }) { Text("Save") }
            },
            dismissButton = {
                TextButton(onClick = { renamingHost = null }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun HeroSection() {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        // App icon with glow — matches iOS ZStack with Circle glow + AppLogo
        Box(contentAlignment = Alignment.Center) {
            Box(
                modifier = Modifier
                    .size(72.dp)
                    .clip(CircleShape)
                    .background(PearGlow)
            )
            // App logo (pear + telescope, no background)
            Icon(
                painter = painterResource(id = R.drawable.app_logo),
                contentDescription = "Peariscope",
                modifier = Modifier.size(56.dp),
                tint = Color.Unspecified
            )
        }
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = "PEARISCOPE",
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 2.sp,
            color = Color.White
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "Connect to a remote desktop",
            fontSize = 13.sp,
            color = Color.Gray
        )
    }
}

@Composable
private fun SeedPhraseInput(
    value: String,
    onValueChange: (String) -> Unit,
    onConnect: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.weight(1f),
            placeholder = { Text("Enter seed phrase...", color = Color.Gray, fontSize = 14.sp) },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Default.Key,
                    contentDescription = null,
                    tint = Color.Gray,
                    modifier = Modifier.size(18.dp)
                )
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                imeAction = ImeAction.Go,
                autoCorrect = false
            ),
            keyboardActions = KeyboardActions(onGo = { onConnect() }),
            shape = RoundedCornerShape(12.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = PearGreen,
                unfocusedBorderColor = Color(0xFF333333),
                focusedContainerColor = Color(0xFF1C1C1E),
                unfocusedContainerColor = Color(0xFF1C1C1E),
                cursorColor = PearGreen,
                focusedTextColor = Color.White,
                unfocusedTextColor = Color.White
            )
        )

        FilledIconButton(
            onClick = onConnect,
            enabled = value.isNotEmpty(),
            modifier = Modifier.size(52.dp),
            shape = RoundedCornerShape(12.dp),
            colors = IconButtonDefaults.filledIconButtonColors(
                containerColor = if (value.isNotEmpty()) PearGreen else Color(0xFF333333),
                contentColor = if (value.isNotEmpty()) Color.Black else Color.Gray
            )
        ) {
            Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = "Connect")
        }
    }
}

@Composable
private fun SuggestionChip(word: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = PearGreen.copy(alpha = 0.12f)
    ) {
        Text(
            text = word,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = PearGreen
        )
    }
}

@Composable
private fun QuickActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(14.dp),
        color = Color(0xFF1C1C1E)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(icon, contentDescription = title, tint = PearGreen, modifier = Modifier.size(24.dp))
            Text(title, fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Color.Gray)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SavedHostRow(
    host: SavedHosts.Host,
    onClick: () -> Unit,
    onPin: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier
) {
    var showMenu by remember { mutableStateOf(false) }

    Box(modifier = modifier.fillMaxWidth()) {
        Surface(
            onClick = onClick,
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(14.dp),
            color = Color(0xFF1C1C1E)
        ) {
            Row(
                modifier = Modifier
                    .padding(horizontal = 14.dp, vertical = 12.dp)
                    .combinedClickable(
                        onClick = onClick,
                        onLongClick = { showMenu = true }
                    ),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                // Desktop icon circle — matches iOS
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(PearGreen.copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.Default.DesktopWindows,
                        contentDescription = null,
                        tint = PearGreen,
                        modifier = Modifier.size(16.dp)
                    )
                }

                // Name + time ago
                Column(modifier = Modifier.weight(1f)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp)
                    ) {
                        if (host.pinned) {
                            Icon(
                                Icons.Default.PushPin,
                                contentDescription = null,
                                tint = PearGreen,
                                modifier = Modifier.size(8.dp)
                            )
                        }
                        Text(
                            text = host.name,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            color = Color.White,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        // Status dot
                        Box(
                            modifier = Modifier
                                .size(5.dp)
                                .clip(CircleShape)
                                .background(hostStatusColor(host))
                        )
                    }
                    Text(
                        text = timeAgo(host.lastConnected),
                        fontSize = 11.sp,
                        color = Color.Gray
                    )
                }

                // Chevron
                Icon(
                    Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = null,
                    tint = Color(0xFF444444),
                    modifier = Modifier.size(16.dp)
                )
            }
        }

        // Context menu (long-press) — matches iOS context menu
        DropdownMenu(
            expanded = showMenu,
            onDismissRequest = { showMenu = false }
        ) {
            DropdownMenuItem(
                text = { Text(if (host.pinned) "Unpin" else "Pin to Top") },
                leadingIcon = {
                    Icon(
                        if (host.pinned) Icons.Default.PushPin else Icons.Outlined.PushPin,
                        contentDescription = null, modifier = Modifier.size(18.dp)
                    )
                },
                onClick = { showMenu = false; onPin() }
            )
            DropdownMenuItem(
                text = { Text("Rename") },
                leadingIcon = {
                    Icon(Icons.Default.Edit, contentDescription = null, modifier = Modifier.size(18.dp))
                },
                onClick = { showMenu = false; onRename() }
            )
            DropdownMenuItem(
                text = { Text("Remove", color = Color.Red) },
                leadingIcon = {
                    Icon(Icons.Default.Delete, contentDescription = null, tint = Color.Red, modifier = Modifier.size(18.dp))
                },
                onClick = { showMenu = false; onDelete() }
            )
        }
    }
    Spacer(modifier = Modifier.height(6.dp))
}

// MARK: - QR Scanner

@Composable
private fun QRScannerSheet(
    onCodeScanned: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var scannedCode by remember { mutableStateOf<String?>(null) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(48.dp))

        Text("Scan QR Code", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Color.White)
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            "Point your camera at the host's QR code",
            fontSize = 14.sp, color = Color.Gray
        )
        Spacer(modifier = Modifier.height(24.dp))

        // Camera preview
        Box(
            modifier = Modifier
                .padding(horizontal = 24.dp)
                .aspectRatio(1f)
                .clip(RoundedCornerShape(16.dp))
        ) {
            AndroidView(
                factory = { ctx ->
                    val previewView = PreviewView(ctx)
                    val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                    cameraProviderFuture.addListener({
                        val cameraProvider = cameraProviderFuture.get()
                        val preview = Preview.Builder().build().also {
                            it.setSurfaceProvider(previewView.surfaceProvider)
                        }
                        val imageAnalysis = ImageAnalysis.Builder()
                            .setTargetResolution(Size(1280, 720))
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()
                        val scanner = BarcodeScanning.getClient()
                        imageAnalysis.setAnalyzer(Executors.newSingleThreadExecutor()) { imageProxy ->
                            @androidx.camera.core.ExperimentalGetImage
                            val mediaImage = imageProxy.image
                            if (mediaImage != null && scannedCode == null) {
                                val image = InputImage.fromMediaImage(
                                    mediaImage, imageProxy.imageInfo.rotationDegrees
                                )
                                scanner.process(image)
                                    .addOnSuccessListener { barcodes ->
                                        val code = barcodes.firstOrNull()?.rawValue
                                        if (code != null && scannedCode == null) {
                                            scannedCode = code
                                            onCodeScanned(code)
                                        }
                                    }
                                    .addOnCompleteListener { imageProxy.close() }
                            } else {
                                imageProxy.close()
                            }
                        }
                        try {
                            cameraProvider.unbindAll()
                            cameraProvider.bindToLifecycle(
                                lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA,
                                preview, imageAnalysis
                            )
                        } catch (_: Exception) {}
                    }, ContextCompat.getMainExecutor(ctx))
                    previewView
                },
                modifier = Modifier.fillMaxSize()
            )

            // Green border overlay
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color.Transparent)
            )
        }

        if (scannedCode != null) {
            Spacer(modifier = Modifier.height(16.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    color = PearGreen,
                    strokeWidth = 2.dp
                )
                Text(
                    "Connecting: ${scannedCode}",
                    color = Color.Gray, fontSize = 13.sp
                )
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        TextButton(onClick = onDismiss) {
            Text("Cancel", color = PearGreen, fontSize = 16.sp)
        }
        Spacer(modifier = Modifier.height(24.dp))
    }
}

// MARK: - Helpers

private fun hostStatusColor(host: SavedHosts.Host): Color {
    val elapsed = (System.currentTimeMillis() - host.lastConnected) / 1000
    return when {
        elapsed < 300 -> Color.Green
        elapsed < 3600 -> Color.Yellow
        elapsed < 86400 -> Color(0xFFFF8C00) // orange
        else -> Color(0xFF555555)
    }
}

private fun timeAgo(timestamp: Long): String {
    if (timestamp == 0L) return ""
    val elapsed = (System.currentTimeMillis() - timestamp) / 1000
    return when {
        elapsed < 60 -> "Just now"
        elapsed < 3600 -> "${elapsed / 60}m ago"
        elapsed < 86400 -> "${elapsed / 3600}h ago"
        else -> {
            val days = elapsed / 86400
            if (days == 1L) "Yesterday" else "${days}d ago"
        }
    }
}

private fun applySuggestion(code: String, word: String): String {
    val words = code.split(" ").toMutableList()
    if (words.isNotEmpty()) {
        words[words.lastIndex] = word
    } else {
        words.add(word)
    }
    return words.joinToString(" ") + " "
}

private fun extractCode(scanned: String): String {
    if (scanned.startsWith("peariscope://relay?")) {
        try {
            val uri = android.net.Uri.parse(scanned)
            val code = uri.getQueryParameter("code")
            if (!code.isNullOrEmpty()) return code
        } catch (_: Exception) {}
    }
    return scanned
}

/**
 * BIP39 autocomplete helper.
 */
object BIP39 {
    private val words: List<String> by lazy { BIP39_WORDS }

    fun completions(input: String): List<String> {
        val parts = input.split(" ")
        val lastWord = parts.lastOrNull()?.lowercase()?.trim() ?: return emptyList()
        if (lastWord.isEmpty()) return emptyList()
        if (input.endsWith(" ") && words.contains(lastWord)) return emptyList()
        return words.filter { it.startsWith(lastWord) }.take(8)
    }

    fun isValidWord(word: String): Boolean = words.contains(word.lowercase())
}

@Composable
private fun OtaStatusBanner(
    status: NetworkManager.OtaStatus,
    version: String?,
    error: String?
) {
    val bgColor: Color
    val fgColor: Color
    val text: String
    val showSpinner: Boolean

    when (status) {
        NetworkManager.OtaStatus.DOWNLOADING -> {
            bgColor = Color(0xFF1565C0).copy(alpha = 0.12f)
            fgColor = Color(0xFF1565C0)
            text = "Downloading update..."
            showSpinner = true
        }
        NetworkManager.OtaStatus.READY -> {
            bgColor = Color(0xFF2E7D32).copy(alpha = 0.12f)
            fgColor = Color(0xFF2E7D32)
            text = "v${version ?: "?"} ready \u2014 restart to apply"
            showSpinner = false
        }
        NetworkManager.OtaStatus.APPLIED -> {
            bgColor = Color(0xFF2E7D32).copy(alpha = 0.12f)
            fgColor = Color(0xFF2E7D32)
            text = "Updated to v${version ?: "?"}"
            showSpinner = false
        }
        NetworkManager.OtaStatus.FAILED -> {
            bgColor = Color(0xFFE65100).copy(alpha = 0.12f)
            fgColor = Color(0xFFE65100)
            text = "Update failed: ${error ?: "unknown"}"
            showSpinner = false
        }
        else -> return
    }

    Row(
        modifier = Modifier
            .padding(horizontal = 24.dp)
            .fillMaxWidth()
            .background(bgColor, RoundedCornerShape(10.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        if (showSpinner) {
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 2.dp,
                color = fgColor
            )
        }
        Text(
            text = text,
            color = fgColor,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium
        )
    }
}
