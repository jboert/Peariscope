package com.peariscope.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import com.peariscope.host.HostSession
import com.peariscope.host.ScreenCaptureManager

val PearGreen = Color(0xFF4ADE80)

@Composable
fun HostScreen(
    hostSession: HostSession,
    onStop: () -> Unit
) {
    val context = LocalContext.current
    var needsPermission by remember { mutableStateOf(!hostSession.isActive) }
    var stateVersion by remember { mutableIntStateOf(0) }
    var showSettings by remember { mutableStateOf(false) }

    // Listen for state changes
    DisposableEffect(hostSession) {
        hostSession.onStateChanged = { stateVersion++ }
        onDispose { hostSession.onStateChanged = null }
    }

    // Force recomposition on state change (read stateVersion to trigger)
    @Suppress("UNUSED_VARIABLE")
    val version = stateVersion

    // Screen capture permission launcher
    val captureLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            // initializeCapture starts the foreground service with the projection result
            hostSession.initializeCapture(result.resultCode, result.data!!)
            // Small delay for service to initialize MediaProjection
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                hostSession.start()
                needsPermission = false
            }, 300)
        }
    }

    if (showSettings) {
        SettingsScreen(hostSession = hostSession, onBack = { showSettings = false })
        return
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0A0A0A))
    ) {
        // Settings gear — top right
        IconButton(
            onClick = { showSettings = true },
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(top = 40.dp, end = 12.dp)
                .size(44.dp)
        ) {
            Icon(
                Icons.Default.Settings,
                contentDescription = "Settings",
                tint = Color.White.copy(alpha = 0.5f),
                modifier = Modifier.size(22.dp)
            )
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(Modifier.height(48.dp))

            // Status indicator
            if (hostSession.isActive) {
                ActiveHostContent(hostSession, onStop)
            } else {
                IdleHostContent(
                    hostSession = hostSession,
                    onStart = {
                        // Start foreground service first — required before getMediaProjection().
                        // The service will receive the projection result via initializeCapture().
                        val serviceIntent = Intent(context, com.peariscope.host.MediaProjectionService::class.java)
                        context.startForegroundService(serviceIntent)
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            val intent = ScreenCaptureManager.createPermissionIntent(context)
                            captureLauncher.launch(intent)
                        }, 200)
                    }
                )
            }
        }

        // PIN approval dialog
        if (hostSession.pendingPeer != null) {
            PinApprovalDialog(
                peerName = hostSession.pendingPeer!!.name.ifEmpty { hostSession.pendingPeer!!.id.take(16) },
                pinCode = hostSession.pinCode,
                onApprove = { hostSession.approvePeer(hostSession.pendingPeer!!) },
                onReject = { hostSession.rejectPeer() }
            )
        }
    }
}

@Composable
private fun IdleHostContent(onStart: () -> Unit, hostSession: HostSession) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Icon
        Box(
            modifier = Modifier
                .size(80.dp)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(PearGreen.copy(alpha = 0.2f), Color.Transparent)
                    )
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Default.DesktopWindows,
                contentDescription = null,
                modifier = Modifier.size(36.dp),
                tint = PearGreen.copy(alpha = 0.6f)
            )
        }

        Text(
            "Share Your Screen",
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
            color = Color.White
        )

        Text(
            "Viewers will connect to your device\nvia the P2P network",
            fontSize = 14.sp,
            color = Color.White.copy(alpha = 0.5f),
            textAlign = TextAlign.Center,
            lineHeight = 20.sp
        )

        // PIN summary
        if (hostSession.requirePin) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = Color.White.copy(alpha = 0.06f))
            ) {
                Row(
                    modifier = Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Icon(Icons.Default.Lock, contentDescription = null, tint = PearGreen, modifier = Modifier.size(18.dp))
                    Text("PIN: ${hostSession.pinCode}", fontSize = 14.sp, fontFamily = FontFamily.Monospace, color = PearGreen)
                    Spacer(Modifier.weight(1f))
                    Text("Change in settings", fontSize = 10.sp, color = Color.White.copy(alpha = 0.3f))
                }
            }
        }

        Spacer(Modifier.height(4.dp))

        Button(
            onClick = onStart,
            colors = ButtonDefaults.buttonColors(containerColor = PearGreen),
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp)
        ) {
            Text(
                "Start Hosting",
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.Black
            )
        }
    }
}

@Composable
private fun ActiveHostContent(hostSession: HostSession, onStop: () -> Unit) {
    val context = LocalContext.current
    var codeRevealed by remember { mutableStateOf(true) }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        // Status badge
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(PearGreen)
            )
            Text(
                "SHARING",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = PearGreen,
                letterSpacing = 2.sp
            )
        }

        // Stats row
        Row(
            horizontalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            StatBadge("FPS", hostSession.fps.toString())
            StatBadge("Viewers", hostSession.connectedViewers.size.toString())
        }

        // Connection code + QR
        if (hostSession.connectionCode != null) {
            ConnectionCodeCard(
                code = hostSession.connectionCode!!,
                revealed = codeRevealed,
                onToggleReveal = { codeRevealed = !codeRevealed },
                onCopy = {
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(ClipData.newPlainText("Connection Code", hostSession.connectionCode))
                    Toast.makeText(context, "Code copied", Toast.LENGTH_SHORT).show()
                },
                onRegenerate = { hostSession.regenerateCode() }
            )
        } else {
            CircularProgressIndicator(
                modifier = Modifier.size(24.dp),
                strokeWidth = 2.dp,
                color = PearGreen
            )
            Text(
                "Generating connection code...",
                fontSize = 13.sp,
                color = Color.White.copy(alpha = 0.5f)
            )
        }

        Spacer(Modifier.height(8.dp))

        // Accessibility service prompt
        if (!com.peariscope.input.InputInjectorService.isRunning) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = Color(0xFF2A1A00))
            ) {
                Row(
                    modifier = Modifier.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Icon(
                        Icons.Default.TouchApp,
                        contentDescription = null,
                        tint = Color(0xFFFBBF24),
                        modifier = Modifier.size(20.dp)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Remote input disabled",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = Color(0xFFFBBF24)
                        )
                        Text(
                            "Enable Peariscope in Accessibility settings",
                            fontSize = 10.sp,
                            color = Color(0xFFFBBF24).copy(alpha = 0.7f)
                        )
                    }
                    TextButton(
                        onClick = {
                            val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            context.startActivity(intent)
                        },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp)
                    ) {
                        Text("Enable", fontSize = 11.sp, color = Color(0xFFFBBF24))
                    }
                }
            }
        }

        // Stop button
        OutlinedButton(
            onClick = {
                hostSession.stop()
                onStop()
            },
            colors = ButtonDefaults.outlinedButtonColors(contentColor = Color(0xFFEF4444)),
            border = ButtonDefaults.outlinedButtonBorder.copy(
                brush = Brush.linearGradient(listOf(Color(0xFFEF4444), Color(0xFFEF4444)))
            ),
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp)
        ) {
            Icon(Icons.Default.Stop, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Stop Sharing", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun ConnectionCodeCard(
    code: String,
    revealed: Boolean,
    onToggleReveal: () -> Unit,
    onCopy: () -> Unit,
    onRegenerate: () -> Unit
) {
    val words = code.split(" ")

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White.copy(alpha = 0.06f))
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Header with show/hide toggle
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "CONNECTION CODE",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White.copy(alpha = 0.4f),
                    letterSpacing = 2.sp
                )
                IconButton(
                    onClick = onToggleReveal,
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        if (revealed) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                        contentDescription = if (revealed) "Hide" else "Show",
                        tint = Color.White.copy(alpha = 0.4f),
                        modifier = Modifier.size(16.dp)
                    )
                }
            }

            if (revealed) {
                // QR code
                val qrBitmap = remember(code) { generateQrBitmap(code, 200) }
                if (qrBitmap != null) {
                    Image(
                        bitmap = qrBitmap.asImageBitmap(),
                        contentDescription = "QR Code",
                        modifier = Modifier
                            .size(160.dp)
                            .clip(RoundedCornerShape(8.dp))
                    )
                }

                // Words grid
                for (row in words.chunked(3)) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        for (word in row) {
                            Text(
                                word,
                                modifier = Modifier.weight(1f),
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                fontFamily = FontFamily.Monospace,
                                color = PearGreen,
                                textAlign = TextAlign.Center
                            )
                        }
                        repeat(3 - row.size) {
                            Spacer(Modifier.weight(1f))
                        }
                    }
                }
            } else {
                Text(
                    "Code hidden",
                    fontSize = 13.sp,
                    color = Color.White.copy(alpha = 0.3f)
                )
            }

            // Action buttons
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                // Copy button
                OutlinedButton(
                    onClick = onCopy,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(8.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = PearGreen),
                    border = ButtonDefaults.outlinedButtonBorder.copy(
                        brush = Brush.linearGradient(listOf(PearGreen.copy(alpha = 0.3f), PearGreen.copy(alpha = 0.3f)))
                    ),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Copy", fontSize = 12.sp)
                }

                // New code button
                OutlinedButton(
                    onClick = onRegenerate,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(8.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White.copy(alpha = 0.6f)),
                    border = ButtonDefaults.outlinedButtonBorder.copy(
                        brush = Brush.linearGradient(listOf(Color.White.copy(alpha = 0.15f), Color.White.copy(alpha = 0.15f)))
                    ),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("New Code", fontSize = 12.sp)
                }
            }
        }
    }
}

private fun generateQrBitmap(content: String, size: Int): Bitmap? {
    return try {
        val writer = QRCodeWriter()
        val bitMatrix = writer.encode(content, BarcodeFormat.QR_CODE, size, size)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        for (x in 0 until size) {
            for (y in 0 until size) {
                bitmap.setPixel(x, y, if (bitMatrix[x, y]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt())
            }
        }
        bitmap
    } catch (e: Exception) {
        null
    }
}

@Composable
private fun StatBadge(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            value,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            color = Color.White
        )
        Text(
            label,
            fontSize = 11.sp,
            color = Color.White.copy(alpha = 0.4f)
        )
    }
}

@Composable
private fun PinApprovalDialog(
    peerName: String,
    pinCode: String,
    onApprove: () -> Unit,
    onReject: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onReject,
        title = { Text("Viewer Connecting") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("$peerName wants to view your screen.")
                if (pinCode.isNotEmpty()) {
                    Text(
                        "Read this PIN to them:",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        pinCode,
                        fontSize = 32.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace,
                        color = PearGreen,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onApprove) { Text("Approve") }
        },
        dismissButton = {
            TextButton(onClick = onReject) { Text("Reject") }
        }
    )
}
