package ly.img.flutter.video_editor_sdk

import android.app.Activity
import androidx.annotation.NonNull
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.annotation.WorkerThread

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import ly.img.android.AuthorizationException

import ly.img.android.IMGLY
import ly.img.android.VESDK
import ly.img.android.pesdk.VideoEditorSettingsList
import ly.img.android.pesdk.backend.decoder.VideoSource
import ly.img.android.pesdk.backend.model.state.LoadSettings
import ly.img.android.pesdk.kotlin_extension.continueWithExceptions
import ly.img.android.pesdk.utils.UriHelper
import ly.img.android.sdk.config.*
import ly.img.android.pesdk.backend.encoder.Encoder
import ly.img.android.pesdk.backend.model.EditorSDKResult
import ly.img.android.pesdk.backend.model.VideoPart
import ly.img.android.pesdk.backend.model.state.VideoCompositionSettings
import ly.img.android.pesdk.backend.model.state.manager.SettingsList
import ly.img.android.pesdk.backend.model.state.manager.StateHandler
import ly.img.android.pesdk.ui.activity.VideoEditorActivity
import ly.img.android.pesdk.utils.ThreadUtils
import ly.img.android.serializer._3.IMGLYFileWriter

import org.json.JSONObject
import java.io.File

import ly.img.flutter.imgly_sdk.FlutterIMGLY
import java.util.UUID

/** FlutterVESDK */
class FlutterVESDK: FlutterIMGLY() {

  companion object {
    // This number must be unique. It is public to allow client code to change it if the same value is used elsewhere.
    var EDITOR_RESULT_ID = 29064

    /** A closure to modify a *VideoEditorSettingsList* before the editor is opened. */
    var editorWillOpenClosure: ((settingsList: VideoEditorSettingsList) -> Unit)? = null

    /** A closure allowing access to the *StateHandler* before the editor is exporting. */
    var editorWillExportClosure: ((stateHandler: StateHandler) -> Unit)? = null
  }

  private var resolveManually: Boolean = false
  private var currentEditorUID: String = UUID.randomUUID().toString()
  private var settingsLists: MutableMap<String, SettingsList> = mutableMapOf()

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    super.onAttachedToEngine(binding)

    channel = MethodChannel(binding.binaryMessenger, "video_editor_sdk")
    channel.setMethodCallHandler(this)
    IMGLY.initSDK(binding.applicationContext)
    IMGLY.authorize()
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    if (this.result != null) {
      result.error("Multiple requests.", "Cancelled due to multiple requests.", null)
      return
    }

    if (call.method == "openEditor") {
      var config = call.argument<MutableMap<String, Any>>("configuration")
      val serialization = call.argument<String>("serialization")

      if (config != null) {
        config = this.resolveAssets(config)
      }
      config = config as? HashMap<String, Any>

      val video = call.argument<MutableMap<String, Any>>("video")
      if (video != null) {
        val videoSegments = video["segments"] as ArrayList<*>?
        val videosList = video["videos"] as ArrayList<String>?
        val videoSource = video["video"] as String?
        val size = video["size"] as? MutableMap<String, Double>

        this.result = result

        if (videoSource != null) {
          this.present(videoSource.let { EmbeddedAsset(it).resolvedURI }, config, serialization)
        } else if (videosList != null) {
          val videos = videosList?.mapNotNull { EmbeddedAsset(it).resolvedURI }
          this.present(videos, config, serialization, size)
        } else {
          this.present(videoSegments, config, serialization, size)
        }
      } else {
        result.error("VE.SDK", "The video must not be null", null)
      }
    } else if (call.method == "unlock") {
      val license = call.argument<String>("license")
      this.result = result
      this.resolveLicense(license)
    } else if (call.method == "release") {
      val identifier = call.argument<String>("identifier")
      if (identifier == null) {
        result.error("VE.SDK", "The identifier must not be null", null)
      } else {
        this.result = result
        this.releaseTemporaryData(identifier)
      }
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
    val configuration = ConfigLoader.readFrom(config ?: mapOf())
    val serializationEnabled = configuration.export?.serialization?.enabled == true
    val exportVideoSegments = configuration.export?.video?.segments == true
    val createTemporaryFiles = serializationEnabled || exportVideoSegments
    resolveManually = exportVideoSegments

    val settingsList = VideoEditorSettingsList(createTemporaryFiles)
    configuration.applyOn(settingsList)
    currentConfig = configuration

    settingsList.configure<LoadSettings> { loadSettings ->
      asset.also {
        loadSettings.source = retrieveURI(it)
      }
    }

    editorWillOpenClosure?.invoke(settingsList)
    readSerialisation(settingsList, serialization, false)
    applyTheme(settingsList, configuration.theme)
    startEditor(settingsList, EDITOR_RESULT_ID, FlutterVESDKActivity::class.java)
  }

  /**
   * Configures and presents the editor.
   *
   * @param videos The video sources as *List<*>* which should be loaded into the editor.
   * @param config The *Configuration* to configure the editor with as if any.
   * @param serialization The serialization to load into the editor if any.
   */
  private fun present(videos: List<*>?, config: HashMap<String, Any>?, serialization: String?, size: Map<String, Any>?) {
    val videoArray = deserializeVideoParts(videos)
    var source = resolveSize(size)

    val configuration = ConfigLoader.readFrom(config ?: mapOf())
    val serializationEnabled = configuration.export?.serialization?.enabled == true
    val exportVideoSegments = configuration.export?.video?.segments == true
    val createTemporaryFiles = serializationEnabled || exportVideoSegments
    resolveManually = exportVideoSegments

    val settingsList = VideoEditorSettingsList(createTemporaryFiles)
    configuration.applyOn(settingsList)
    currentConfig = configuration

    if (videoArray.isNotEmpty()) {
      if (source == null) {
        if (size != null) {
          result?.error("VE.SDK", "Invalid video size: width and height must be greater than zero.", null)
          return
        }
        val video = videoArray.first()
        source = video.videoSource.getSourceAsUri()
      }

      settingsList.configure<VideoCompositionSettings> { loadSettings ->
        videoArray.forEach {
          loadSettings.addCompositionPart(it)
        }
      }
    } else {
      if (source == null) {
        result?.error("VE.SDK", "A video composition without assets must have a specific size.", null)
        this.result = null
        return
      }
    }

    settingsList.configure<LoadSettings> {
      it.source = source
    }

    editorWillOpenClosure?.invoke(settingsList)
    readSerialisation(settingsList, serialization, false)
    applyTheme(settingsList, configuration.theme)
    startEditor(settingsList, EDITOR_RESULT_ID, FlutterVESDKActivity::class.java)
  }

  private fun releaseTemporaryData(identifier: String) {
    val settingsList = settingsLists[identifier]
    if (settingsList != null) {
      settingsList.release()
      settingsLists.remove(identifier)
    }
    this.result?.success(null)
    this.result = null
  }

  private fun retrieveURI(source: String) : Uri {
    return if (source.startsWith("data:")) {
      UriHelper.createFromBase64String(source.substringAfter("base64,"))
    } else {
      val potentialFile = continueWithExceptions { File(source) }
      if (potentialFile?.exists() == true) {
        Uri.fromFile(potentialFile)
      } else {
        ConfigLoader.parseUri(source)
      }
    }
  }

  private fun resolveSize(size: Map<String, Any>?) : Uri? {
    val height = size?.get("height") as? Double ?: 0.0
    val width = size?.get("width") as? Double ?: 0.0
    if (height == 0.0 || width == 0.0) {
      return null
    }
    return LoadSettings.compositionSource(width.toInt(), height.toInt(), 60)
  }

  private fun serializeVideoSegments(settingsList: SettingsList): List<*> {
    val compositionParts = mutableListOf<MutableMap<String, Any?>>()
    settingsList[VideoCompositionSettings::class].videos.forEach {
      val source = it.videoSource.getSourceAsUri().toString()
      val trimStart = it.trimStartInNano / 1000000000.0f
      val trimEnd = it.trimEndInNano / 1000000000.0f

      val videoPart = mutableMapOf<String, Any?>(
        "videoUri" to source,
        "startTime" to trimStart.toDouble(),
        "endTime" to trimEnd.toDouble()
      )
      compositionParts.add(videoPart)
    }
    return compositionParts
  }

  private fun deserializeVideoParts(videos: List<*>?) : List<VideoPart> {
    val parts = emptyList<VideoPart>().toMutableList()

    videos?.forEach {
      if (it is String) {
        val videoPart = VideoPart(retrieveURI(EmbeddedAsset(it).resolvedURI))
        parts.add(videoPart)
      } else if (it is Map<*, *>) {
        val uri = it["videoUri"] as String?
        val trimStart = it["startTime"] as Double?
        val trimEnd = it["endTime"] as Double?

        if (uri != null) {
          val videoPart = VideoPart(retrieveURI(EmbeddedAsset(uri).resolvedURI))
          if (trimStart != null) {
            videoPart.trimStartInNanoseconds = (trimStart * 1000000000.0f).toLong()
          }
          if (trimEnd != null) {
            videoPart.trimEndInNanoseconds = (trimEnd * 1000000000.0f).toLong()
          }
          parts.add(videoPart)
        }
      }
    }
    return parts
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
      this.result = null
    } catch (e: AuthorizationException) {
      this.result?.error("VE.SDK", "The license is invalid.", e.message)
      this.result = null
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
        this.result = null
      }
      return true
    } else if (resultCode == Activity.RESULT_OK && requestCode == EDITOR_RESULT_ID) {
      ThreadUtils.runAsync {
        val serializationConfig = currentConfig?.export?.serialization
        val resultUri = intentData.resultUri
        val sourceUri = intentData.sourceUri

        var serialization: Any? = null
        val settingsList = intentData.settingsList

        if (serializationConfig?.enabled == true) {
          skipIfNotExists {
            settingsList.let { settingsList ->
              serialization = when (serializationConfig.exportType) {
                SerializationExportType.FILE_URL -> {
                  val uri = serializationConfig.filename?.let {
                    Uri.parse("$it.json")
                  } ?: Uri.fromFile(File.createTempFile("serialization-" + UUID.randomUUID().toString(), ".json"))
                  Encoder.createOutputStream(uri).use { outputStream ->
                    IMGLYFileWriter(settingsList).writeJson(outputStream)
                  }
                  uri.toString()
                }
                SerializationExportType.OBJECT -> {
                  jsonToMap(JSONObject(IMGLYFileWriter(settingsList).writeJsonAsString()))
                }
              }
            }
          } ?: run {
            Log.e("IMG.LY SDK", "You need to include 'backend:serializer' Module, to use serialisation!")
          }
        }

        var segments: List<*>? = null
        val canvasSize = sourceUri?.let { VideoSource.create(it).fetchFormatInfo()?.size }
        val sizeMap = mutableMapOf<String, Any>()
        if (canvasSize != null && canvasSize.height >= 0 && canvasSize.width >= 0) {
          sizeMap["height"] = canvasSize.height.toDouble()
          sizeMap["width"] = canvasSize.width.toDouble()
        }

        if (resolveManually) {
          settingsLists[currentEditorUID] = settingsList
          segments = serializeVideoSegments(settingsList)
        }

        val map = mutableMapOf<String, Any?>()
        map["video"] = resultUri.toString()
        map["hasChanges"] = (sourceUri?.path != resultUri?.path)
        map["serialization"] = serialization
        map["segments"] = segments
        map["identifier"] = currentEditorUID
        map["videoSize"] = sizeMap

        currentActivity?.runOnUiThread {
          this.result?.success(map)
          this.result = null
        }
        if (!resolveManually) {
          settingsList.release()
        }
        resolveManually = false
      }
      return true
    }
    return false
  }
}

/** A *VideoEditorActivity* used for the native interfaces. */
class FlutterVESDKActivity: VideoEditorActivity() {
  @WorkerThread
  override fun onExportStart(stateHandler: StateHandler) {
    FlutterVESDK.editorWillExportClosure?.invoke(stateHandler)

    super.onExportStart(stateHandler)
  }
}
