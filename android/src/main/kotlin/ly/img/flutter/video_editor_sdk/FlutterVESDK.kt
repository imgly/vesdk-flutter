package ly.img.flutter.video_editor_sdk

import android.app.Activity
import androidx.annotation.NonNull
import android.content.Intent
import android.net.Uri
import android.util.Log

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import ly.img.android.AuthorizationException

import ly.img.android.IMGLY
import ly.img.android.VESDK
import ly.img.android.pesdk.VideoEditorSettingsList
import ly.img.android.pesdk.backend.model.state.LoadSettings
import ly.img.android.pesdk.kotlin_extension.continueWithExceptions
import ly.img.android.pesdk.utils.UriHelper
import ly.img.android.sdk.config.*
import ly.img.android.pesdk.backend.encoder.Encoder
import ly.img.android.pesdk.backend.model.EditorSDKResult
import ly.img.android.serializer._3.IMGLYFileWriter

import org.json.JSONObject
import java.io.File

import ly.img.flutter.imgly_sdk.FlutterIMGLY

/** FlutterVESDK */
class FlutterVESDK: FlutterIMGLY() {

  companion object {
    // This number must be unique. It is public to allow client code to change it if the same value is used elsewhere.
    var EDITOR_RESULT_ID = 29065
  }

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    super.onAttachedToEngine(flutterPluginBinding)

    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "video_editor_sdk")
    channel.setMethodCallHandler(this)
    IMGLY.initSDK(flutterPluginBinding.applicationContext)
    IMGLY.authorize()
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    if (call.method == "openEditor") {
      var config = call.argument<MutableMap<String, Any>>("configuration")
      var video: String? = null
      val serialization = call.argument<String>("serialization")

      if (config != null) {
        config = this.resolveAssets(config)
      }
      config = config as? HashMap<String, Any>

      val videoValues = call.argument<String>("video")
      if (videoValues != null) {
        video = EmbeddedAsset(videoValues).resolvedURI
      }

      if(video != null) {
        this.result = result
        this.present(asset = video, config = config, serialization = serialization)
      } else {
        result.error("Invalid video location.", "The video can not be nil.", null)
      }
    } else if (call.method == "unlock") {
      val license = call.argument<String>("license")
      this.result = result
      this.resolveLicense(license)
    } else {
      result.notImplemented()
    }
  }

  /**
   * Configures and presents the editor.
   *
   * @param asset The video source as *String* which should be loaded into the editor.
   * @param config The *Configuration* to configure the editor with as if any.
   * @param serialization The serialization to load into the editor if any.
   */
  override fun present(asset: String, config: HashMap<String, Any>?, serialization: String?) {
    val settingsList = VideoEditorSettingsList()

    currentSettingsList = settingsList
    currentConfig = ConfigLoader.readFrom(config ?: mapOf()).also {
      it.applyOn(settingsList)
    }

    settingsList.configure<LoadSettings> { loadSettings ->
      asset.also {
        if (it.startsWith("data:")) {
          loadSettings.source = UriHelper.createFromBase64String(it.substringAfter("base64,"))
        } else {
          val potentialFile = continueWithExceptions { File(it) }
          if (potentialFile?.exists() == true) {
            loadSettings.source = Uri.fromFile(potentialFile)
          } else {
            loadSettings.source = ConfigLoader.parseUri(it)
          }
        }
      }
    }

    readSerialisation(settingsList, serialization, false)
    startEditor(settingsList, EDITOR_RESULT_ID)
  }

  /**
   * Unlocks the SDK with a stringified license.
   *
   * @param license The license as a *String*.
   */
  override fun unlockWithLicense(license: String) {
    try {
      VESDK.initSDKWithLicenseData(license)
      IMGLY.authorize()
      this.result?.success(null)
    } catch (e: AuthorizationException) {
      this.result?.error("Invalid license", "The license must be valid.", e.message)
    }
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    val intentData = try {
      data?.let { EditorSDKResult(it) }
    } catch (e: EditorSDKResult.NotAnImglyResultException) {
      null
    } ?: return false // If intentData is null the result is not from us.

    if (resultCode == Activity.RESULT_CANCELED && requestCode == EDITOR_RESULT_ID) {
      currentActivity?.runOnUiThread {
        this.result?.success(null)
      }
      return true
    } else if (resultCode == Activity.RESULT_OK && requestCode == EDITOR_RESULT_ID) {
      val settingsList = intentData.settingsList
      val serializationConfig = currentConfig?.export?.serialization
      val resultUri = intentData.resultUri
      val sourceUri = intentData.sourceUri

      val serialization: Any? = if (serializationConfig?.enabled == true) {
        skipIfNotExists {
          settingsList.let { settingsList ->
            if (serializationConfig.embedSourceImage == true) {
              Log.i("ImglySDK", "EmbedSourceImage is currently not supported by the Android SDK")
            }
            when (serializationConfig.exportType) {
              SerializationExportType.FILE_URL -> {
                val uri = serializationConfig.filename?.let {
                  Uri.parse(it)
                } ?: Uri.fromFile(File.createTempFile("serialization", ".json"))
                Encoder.createOutputStream(uri).use { outputStream ->
                  IMGLYFileWriter(settingsList).writeJson(outputStream)
                }
                uri.toString()
              }
              SerializationExportType.OBJECT -> {
                jsonToMap(JSONObject(IMGLYFileWriter(settingsList).writeJsonAsString())) as Any?
              }
            }
          }
        } ?: run {
          Log.i("ImglySDK", "You need to include 'backend:serializer' Module, to use serialisation!")
          null
        }
      } else {
        null
      }

      val map = mutableMapOf<String, Any?>()
      map["video"] = resultUri.toString()
      map["hasChanges"] = (sourceUri?.path != resultUri?.path)
      map["serialization"] = serialization
      currentActivity?.runOnUiThread {
        this.result?.success(map)
      }
      return true
    }
    return false
  }
}
