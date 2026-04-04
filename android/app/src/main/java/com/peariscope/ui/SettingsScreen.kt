package com.peariscope.ui

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.peariscope.host.HostSession

@Composable
fun SettingsScreen(
    hostSession: HostSession,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val prefs = context.getSharedPreferences("peariscope", Context.MODE_PRIVATE)

    var pinText by remember { mutableStateOf(hostSession.pinCode) }
    var autoHost by remember { mutableStateOf(prefs.getBoolean("autoHost", false)) }
    var autoStart by remember { mutableStateOf(prefs.getBoolean("autoStartOnBoot", false)) }
    var bitrateIndex by remember { mutableIntStateOf(
        when (prefs.getInt("bitrate", 12_000_000)) {
            4_000_000 -> 0
            8_000_000 -> 1
            12_000_000 -> 2
            20_000_000 -> 3
            else -> 2
        }
    )}
    var fpsIndex by remember { mutableIntStateOf(
        when (prefs.getInt("fps", 60)) {
            30 -> 0
            60 -> 1
            else -> 1
        }
    )}
    var requirePin by remember { mutableStateOf(hostSession.requirePin) }
    var skipPinOnReconnect by remember { mutableStateOf(prefs.getBoolean("skipPinOnReconnect", false)) }

    val bitrateOptions = listOf("4 Mbps" to 4_000_000, "8 Mbps" to 8_000_000, "12 Mbps" to 12_000_000, "20 Mbps" to 20_000_000)
    val fpsOptions = listOf("30 fps" to 30, "60 fps" to 60)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0A0A0A))
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
        ) {
            // Header
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp)
                    .padding(top = 36.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onBack) {
                    Icon(
                        Icons.Default.ArrowBack,
                        contentDescription = "Back",
                        tint = Color.White
                    )
                }
                Text(
                    "Settings",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    modifier = Modifier.padding(start = 8.dp)
                )
            }

            Column(
                modifier = Modifier.padding(horizontal = 24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // --- Security Section ---
                SectionHeader("SECURITY")

                // PIN toggle
                SettingsToggle(
                    icon = Icons.Default.Lock,
                    title = "Require PIN",
                    subtitle = "Viewers must enter a PIN to connect",
                    checked = requirePin,
                    onCheckedChange = {
                        requirePin = it
                        hostSession.requirePin = it
                        prefs.edit().putBoolean("requirePin", it).apply()
                    }
                )

                if (requirePin) {
                    SettingsToggle(
                        icon = Icons.Default.Refresh,
                        title = "Skip PIN on Reconnect",
                        subtitle = "Auto-approve peers that already passed PIN",
                        checked = skipPinOnReconnect,
                        onCheckedChange = {
                            skipPinOnReconnect = it
                            prefs.edit().putBoolean("skipPinOnReconnect", it).apply()
                        }
                    )
                }

                // PIN input
                if (requirePin) {
                    SettingsCard {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                "HOST PIN",
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold,
                                color = Color.White.copy(alpha = 0.4f),
                                letterSpacing = 2.sp
                            )
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                OutlinedTextField(
                                    value = pinText,
                                    onValueChange = { newVal ->
                                        val filtered = newVal.filter { it.isDigit() }
                                        pinText = filtered
                                        if (filtered.length >= 6) {
                                            hostSession.updatePin(filtered)
                                        }
                                    },
                                    modifier = Modifier.weight(1f),
                                    textStyle = LocalTextStyle.current.copy(
                                        fontSize = 24.sp,
                                        fontWeight = FontWeight.Bold,
                                        fontFamily = FontFamily.Monospace,
                                        color = PearGreen,
                                        textAlign = TextAlign.Center,
                                        letterSpacing = 4.sp
                                    ),
                                    singleLine = true,
                                    colors = OutlinedTextFieldDefaults.colors(
                                        unfocusedBorderColor = Color.White.copy(alpha = 0.1f),
                                        focusedBorderColor = PearGreen.copy(alpha = 0.5f),
                                        cursorColor = PearGreen
                                    ),
                                    shape = RoundedCornerShape(8.dp)
                                )
                                IconButton(
                                    onClick = {
                                        val newPin = String.format("%06d", java.security.SecureRandom().nextInt(1000000))
                                        pinText = newPin
                                        hostSession.updatePin(newPin)
                                    },
                                    modifier = Modifier.size(40.dp)
                                ) {
                                    Icon(Icons.Default.Refresh, "Random", tint = Color.White.copy(alpha = 0.5f), modifier = Modifier.size(20.dp))
                                }
                            }
                            Text(
                                "Minimum 6 digits",
                                fontSize = 11.sp,
                                color = Color.White.copy(alpha = 0.3f)
                            )
                        }
                    }
                }

                // --- Startup Section ---
                SectionHeader("STARTUP")

                SettingsToggle(
                    icon = Icons.Default.PlayArrow,
                    title = "Auto-host on launch",
                    subtitle = "Start hosting automatically when app opens",
                    checked = autoHost,
                    onCheckedChange = {
                        autoHost = it
                        prefs.edit().putBoolean("autoHost", it).apply()
                    }
                )

                SettingsToggle(
                    icon = Icons.Default.PowerSettingsNew,
                    title = "Start on boot",
                    subtitle = "Launch Peariscope when device powers on",
                    checked = autoStart,
                    onCheckedChange = {
                        autoStart = it
                        prefs.edit().putBoolean("autoStartOnBoot", it).apply()
                    }
                )

                // --- Quality Section ---
                SectionHeader("STREAM QUALITY")

                // Bitrate
                SettingsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Bitrate", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color.White)
                        Text("Higher = sharper but uses more bandwidth", fontSize = 11.sp, color = Color.White.copy(alpha = 0.4f))
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                            bitrateOptions.forEachIndexed { index, (label, value) ->
                                val selected = bitrateIndex == index
                                OutlinedButton(
                                    onClick = { bitrateIndex = index; prefs.edit().putInt("bitrate", value).apply() },
                                    modifier = Modifier.weight(1f),
                                    shape = RoundedCornerShape(8.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        containerColor = if (selected) PearGreen.copy(alpha = 0.2f) else Color.Transparent,
                                        contentColor = if (selected) PearGreen else Color.White.copy(alpha = 0.5f)
                                    ),
                                    border = ButtonDefaults.outlinedButtonBorder.copy(
                                        brush = Brush.linearGradient(
                                            listOf(
                                                if (selected) PearGreen.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.1f),
                                                if (selected) PearGreen.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.1f)
                                            )
                                        )
                                    ),
                                    contentPadding = PaddingValues(horizontal = 4.dp, vertical = 8.dp)
                                ) {
                                    Text(label, fontSize = 10.sp)
                                }
                            }
                        }
                    }
                }

                // FPS
                SettingsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Frame Rate", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color.White)
                        Text("Higher = smoother but more CPU/bandwidth", fontSize = 11.sp, color = Color.White.copy(alpha = 0.4f))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                            fpsOptions.forEachIndexed { index, (label, value) ->
                                val selected = fpsIndex == index
                                OutlinedButton(
                                    onClick = { fpsIndex = index; prefs.edit().putInt("fps", value).apply() },
                                    modifier = Modifier.weight(1f),
                                    shape = RoundedCornerShape(8.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        containerColor = if (selected) PearGreen.copy(alpha = 0.2f) else Color.Transparent,
                                        contentColor = if (selected) PearGreen else Color.White.copy(alpha = 0.5f)
                                    ),
                                    border = ButtonDefaults.outlinedButtonBorder.copy(
                                        brush = Brush.linearGradient(
                                            listOf(
                                                if (selected) PearGreen.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.1f),
                                                if (selected) PearGreen.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.1f)
                                            )
                                        )
                                    ),
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp)
                                ) {
                                    Text(label, fontSize = 12.sp)
                                }
                            }
                        }
                    }
                }

                // --- Accessibility Section ---
                SectionHeader("REMOTE CONTROL")

                SettingsCard {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Icon(Icons.Default.TouchApp, contentDescription = null, tint = PearGreen, modifier = Modifier.size(24.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Input Injection", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color.White)
                            Text(
                                if (com.peariscope.input.InputInjectorService.isRunning) "Enabled" else "Disabled — enable in Accessibility settings",
                                fontSize = 11.sp,
                                color = if (com.peariscope.input.InputInjectorService.isRunning) PearGreen else Color(0xFFFBBF24)
                            )
                        }
                        if (!com.peariscope.input.InputInjectorService.isRunning) {
                            TextButton(onClick = {
                                context.startActivity(Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            }) {
                                Text("Enable", color = PearGreen, fontSize = 12.sp)
                            }
                        }
                    }
                }

                Spacer(Modifier.height(32.dp))
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        title,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        color = Color.White.copy(alpha = 0.4f),
        letterSpacing = 2.sp,
        modifier = Modifier.padding(top = 8.dp)
    )
}

@Composable
private fun SettingsCard(content: @Composable () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White.copy(alpha = 0.06f))
    ) {
        Box(modifier = Modifier.padding(16.dp)) {
            content()
        }
    }
}

@Composable
private fun SettingsToggle(
    icon: ImageVector,
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    SettingsCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Icon(icon, contentDescription = null, tint = PearGreen, modifier = Modifier.size(24.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color.White)
                Text(subtitle, fontSize = 11.sp, color = Color.White.copy(alpha = 0.4f))
            }
            Switch(
                checked = checked,
                onCheckedChange = onCheckedChange,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = Color.White,
                    checkedTrackColor = PearGreen,
                    uncheckedThumbColor = Color.White.copy(alpha = 0.6f),
                    uncheckedTrackColor = Color.White.copy(alpha = 0.1f)
                )
            )
        }
    }
}
