package tigerstyle

import com.intellij.openapi.Disposable
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.service
import com.intellij.openapi.project.Project

@Service(Service.Level.PROJECT)
internal class TigerstyleSession : Disposable {
    override fun dispose() = Unit

    companion object {
        fun instance(project: Project): TigerstyleSession = project.service()
    }
}
