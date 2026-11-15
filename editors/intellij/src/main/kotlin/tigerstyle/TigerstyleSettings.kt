package tigerstyle

import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.components.service

internal val PREFERENCES = listOf("filesystemFirst", "editorFirst", "editorOnly")

@Service(Service.Level.APP)
@State(name = "TigerstyleSettings", storages = [Storage("tigerstyle.xml")])
internal class TigerstyleSettings : PersistentStateComponent<TigerstyleSettings.Stored> {
    internal class Stored {
        @JvmField
        var binaryPath: String = ""

        @JvmField
        var configurationPreference: String = "filesystemFirst"

        @JvmField
        var extendSelect: String = ""

        @JvmField
        var fixOnSave: Boolean = false

        @JvmField
        var ignore: String = ""

        @JvmField
        var preview: Boolean = false

        @JvmField
        var select: String = ""
    }

    private var stored = Stored()

    var binaryPath: String
        get() = stored.binaryPath
        set(value) {
            stored.binaryPath = value
        }

    var configurationPreference: String
        get() = stored.configurationPreference
        set(value) {
            stored.configurationPreference = value
        }

    var extendSelect: String
        get() = stored.extendSelect
        set(value) {
            stored.extendSelect = value
        }

    var fixOnSave: Boolean
        get() = stored.fixOnSave
        set(value) {
            stored.fixOnSave = value
        }

    var ignore: String
        get() = stored.ignore
        set(value) {
            stored.ignore = value
        }

    var preview: Boolean
        get() = stored.preview
        set(value) {
            stored.preview = value
        }

    var select: String
        get() = stored.select
        set(value) {
            stored.select = value
        }

    fun configuration(): Map<String, Any> {
        val configuration = mutableMapOf<String, Any>(
            "configurationPreference" to stored.configurationPreference,
            "extendSelect" to selectors(stored.extendSelect),
            "fixOnSave" to stored.fixOnSave,
            "ignore" to selectors(stored.ignore),
            "preview" to stored.preview,
        )

        val replacement = selectors(stored.select)

        if (replacement.isNotEmpty()) {
            configuration["select"] = replacement
        }

        return configuration
    }

    override fun getState(): Stored = stored

    override fun loadState(state: Stored) {
        stored = state
    }

    companion object {
        fun instance(): TigerstyleSettings = service()
    }
}

internal fun selectors(text: String): List<String> =
    text.split(',').map(String::trim).filter(String::isNotEmpty)
