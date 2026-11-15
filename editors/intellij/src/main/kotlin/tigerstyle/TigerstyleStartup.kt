package tigerstyle

import com.intellij.openapi.project.Project
import com.intellij.openapi.startup.ProjectActivity
import com.intellij.platform.lsp.api.LspClient
import com.intellij.platform.lsp.api.LspClientManager
import com.intellij.platform.lsp.api.LspClientManagerListener
import com.intellij.platform.lsp.api.LspServerState

internal class TigerstyleStartup : ProjectActivity {
    override suspend fun execute(project: Project) {
        LspClientManager
            .getInstance(project)
            .addListener(
                object : LspClientManagerListener {
                    override fun serverStateChanged(lspClient: LspClient) {
                        if (lspClient.descriptor !is TigerstyleLspClientDescriptor) {
                            return
                        }

                        if (lspClient.state != LspServerState.Running) {
                            return
                        }

                        pushConfiguration(lspClient)
                    }
                },
                TigerstyleSession.instance(project),
                false,
            )
    }
}
