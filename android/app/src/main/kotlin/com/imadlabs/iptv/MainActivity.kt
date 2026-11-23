package com.imadlabs.iptv

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI. The "imadlabs/platform" channel tells Flutter whether it runs on a TV
 * and handles picture-in-picture, which Flutter cannot do on its own.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var autoPip = false
    private var pipAspect = Rational(16, 9)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "imadlabs/platform").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTv" -> result.success(isTv())
                    "pipSupported" -> result.success(pipSupported())
                    "enterPip" -> {
                        updateAspect(call.argument<Int>("width"), call.argument<Int>("height"))
                        result.success(enterPip())
                    }
                    "setAutoPip" -> {
                        autoPip = call.argument<Boolean>("enabled") == true
                        updateAspect(call.argument<Int>("width"), call.argument<Int>("height"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun isTv(): Boolean {
        val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        return ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) && !isTv()

    private fun updateAspect(w: Int?, h: Int?) {
        if (w != null && h != null && w > 0 && h > 0) {
            // Android only accepts ratios between 1:2.39 and 2.39:1.
            val r = (w.toFloat() / h).coerceIn(0.42f, 2.38f)
            pipAspect = Rational((r * 1000).toInt(), 1000)
        }
    }

    private fun enterPip(): Boolean {
        if (!pipSupported()) return false
        return try {
            enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(pipAspect).build())
        } catch (e: Exception) {
            false
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPip) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }
}
