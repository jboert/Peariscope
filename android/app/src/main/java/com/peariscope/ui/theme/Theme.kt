package com.peariscope.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val PearGreen = Color(0xFF4ADE80)
val PearGreenDark = Color(0xFF22C55E)
val PearGlow = Color(0x334ADE80)

private val DarkColorScheme = darkColorScheme(
    primary = PearGreen,
    onPrimary = Color.Black,
    secondary = PearGreenDark,
    background = Color(0xFF0A0A0A),
    surface = Color(0xFF141414),
    surfaceVariant = Color(0xFF1E1E1E),
    onBackground = Color.White,
    onSurface = Color.White,
    onSurfaceVariant = Color(0xFFAAAAAA),
    outline = Color(0xFF333333),
)

@Composable
fun PeariscopeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColorScheme,
        content = content
    )
}
