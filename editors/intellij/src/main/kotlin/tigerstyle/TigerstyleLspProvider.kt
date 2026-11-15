package tigerstyle

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.configurations.PathEnvironmentVariableUtil
import com.intellij.ide.plugins.PluginManagerCore
import com.intellij.openapi.extensions.PluginId
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.platform.lsp.api.LspClient
import com.intellij.platform.lsp.api.LspClientManager
import com.intellij.platform.lsp.api.LspIntegrationProvider
import com.intellij.platform.lsp.api.LspServerListener
import com.intellij.platform.lsp.api.ProjectWideLspClientDescriptor
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import org.eclipse.lsp4j.ConfigurationItem
import org.eclipse.lsp4j.DidChangeConfigurationParams
import org.eclipse.lsp4j.InitializeResult

internal const val BINARY_NAME = "tigerstyle-lsp"

internal const val PLUGIN_ID = "com.braycarlson.tigerstyle"

internal const val SECTION = "tigerstyle"

internal val SUPPORTED_EXTENSIONS = setOf(
    "cjs",
    "cts",
    "go",
    "js",
    "jsx",
    "mjs",
    "mts",
    "odin",
    "py",
    "pyi",
    "rs",
    "ts",
    "tsx",
    "zig",
)

private val warned = AtomicBoolean(false)

internal class TigerstyleLspIntegrationProvider : LspIntegrationProvider {
    override fun fileOpened(
        project: Project,
        file: VirtualFile,
        clientStarter: LspIntegrationProvider.LspClientStarter,
    ) {
        if (file.extension !in SUPPORTED_EXTENSIONS) {
            return
        }

        clientStarter.ensureClientStarted(TigerstyleLspClientDescriptor(project))
    }
}

internal fun restartTigerstyle(project: Project) {
    LspClientManager
        .getInstance(project)
        .stopAndRestartClientsIfNeeded(TigerstyleLspIntegrationProvider::class.java)
}

internal fun configurationChanged(project: Project) {
    LspClientManager
        .getInstance(project)
        .getClients(TigerstyleLspIntegrationProvider::class.java)
        .forEach(::pushConfiguration)
}

internal fun pushConfiguration(client: LspClient) {
    client.sendNotification { language ->
        language
            .workspaceService
            .didChangeConfiguration(DidChangeConfigurationParams(emptyMap<String, Any>()))
    }
}

internal fun pluginVersion(): String =
    PluginManagerCore.getPlugin(PluginId.getId(PLUGIN_ID))?.version ?: "unknown"

internal class TigerstyleLspClientDescriptor(project: Project) :
    ProjectWideLspClientDescriptor(project, "tigerstyle") {
    override fun isSupportedFile(file: VirtualFile): Boolean = file.extension in SUPPORTED_EXTENSIONS

    override fun createCommandLine(): GeneralCommandLine {
        val configured = TigerstyleSettings.instance().binaryPath.trim()

        if (configured.isEmpty()) {
            if (PathEnvironmentVariableUtil.findInPath(BINARY_NAME) == null) {
                TigerstyleNotifications.missingBinary(project, "`$BINARY_NAME` on PATH")
            }

            return GeneralCommandLine(BINARY_NAME, "server")
        }

        if (!File(configured).canExecute()) {
            TigerstyleNotifications.missingBinary(project, configured)
        }

        return GeneralCommandLine(configured, "server")
    }

    override fun getWorkspaceConfiguration(item: ConfigurationItem): Any? {
        if (item.section != SECTION) {
            return null
        }

        return TigerstyleSettings.instance().configuration()
    }

    override val lspServerListener: LspServerListener = object : LspServerListener {
        override fun serverInitialized(params: InitializeResult) {
            val server = params.serverInfo?.version ?: return
            val plugin = pluginVersion()

            if (agree(plugin, server) || !warned.compareAndSet(false, true)) {
                return
            }

            TigerstyleNotifications.versionSkew(project, plugin, server)
        }
    }
}

private fun agree(plugin: String, server: String): Boolean = minor(plugin) == minor(server)

private fun minor(version: String): String = version.split('.').take(2).joinToString(".")
