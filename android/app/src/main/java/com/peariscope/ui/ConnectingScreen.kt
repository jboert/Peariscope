package com.peariscope.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.peariscope.network.NetworkManager
import com.peariscope.ui.theme.PearGreen
import kotlinx.coroutines.delay

@Composable
fun ConnectingScreen(
    networkManager: NetworkManager,
    onCancel: () -> Unit
) {
    var elapsed by remember { mutableIntStateOf(0) }

    // Elapsed timer
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            elapsed++
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Spinner
            CircularProgressIndicator(
                color = PearGreen,
                modifier = Modifier.size(40.dp),
                strokeWidth = 3.dp
            )

            Spacer(modifier = Modifier.height(8.dp))

            // Title
            Text(
                "Connecting",
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )

            // Status
            Text(
                "Looking for peer on the DHT...",
                fontSize = 13.sp,
                color = Color.Gray
            )

            // Elapsed time
            val timeText = if (elapsed < 60) "${elapsed}s" else "${elapsed / 60}m ${elapsed % 60}s"
            Text(
                timeText,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                color = Color.White.copy(alpha = 0.3f)
            )

            // Error
            networkManager.lastError?.let { error ->
                Text(
                    error,
                    fontSize = 11.sp,
                    color = Color.Red,
                    modifier = Modifier.padding(horizontal = 32.dp)
                )
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Cancel button
            OutlinedButton(
                onClick = onCancel,
                shape = RoundedCornerShape(20.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = Color.Gray
                )
            ) {
                Text("Cancel", fontSize = 14.sp)
            }
        }
    }
}
