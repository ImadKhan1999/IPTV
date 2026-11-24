package com.imadlabs.iptv

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.speech.RecognizerIntent
import android.util.Rational
import androidx.core.content.FileProvider
import java.io.File
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
    private var voiceResult: MethodChannel.Result? = null

    companion object {
        private const val VOICE_REQUEST = 4101
    }

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
                    "voiceSupported" -> result.success(voiceIntent().resolveActivity(packageManager) != null)
                    "voiceSearch" -> startVoiceSearch(call.argument<String>("prompt"), result)
                    "abis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "deviceName" -> result.success(deviceName())
                    "installApk" -> result.success(installApk(call.argument<String>("path")!!))
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun voiceIntent() = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
    }

    /** Opens the system speech recogniser (the remote's mic on Android TV) and returns the text. */
    private fun startVoiceSearch(prompt: String?, result: MethodChannel.Result) {
        voiceResult?.success(null)
        voiceResult = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(
                voiceIntent().apply { if (prompt != null) putExtra(RecognizerIntent.EXTRA_PROMPT, prompt) },
                VOICE_REQUEST,
            )
        } catch (e: Exception) {
            voiceResult = null
            result.success(null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VOICE_REQUEST) {
            val text = if (resultCode == RESULT_OK) {
                data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            } else {
                null
            }
            voiceResult?.success(text)
            voiceResult = null
        }
    }

    /** Hands a downloaded update to the system installer. */
    private fun installApk(path: String): Boolean = try {
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
        true
    } catch (e: Exception) {
        false
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

    /** The name the person gave this device (Settings > About > Device name), else the model. */
    private fun deviceName(): String {
        val named = try {
            android.provider.Settings.Global.getString(contentResolver, "device_name")
        } catch (e: Exception) {
            null
        }
        if (!named.isNullOrBlank()) return named
        val model = Build.MODEL ?: "Android device"
        val maker = Build.MANUFACTURER ?: ""
        return if (maker.isNotBlank() && !model.startsWith(maker, ignoreCase = true)) "$maker $model" else model
    }
}
