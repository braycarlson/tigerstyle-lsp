package tigerstyle

import com.intellij.notification.NotificationAction
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.options.ShowSettingsUtil
import com.intellij.openapi.project.Project

private const val GROUP = "TigerStyle"

internal object TigerstyleNotifications {
    fun missingBinary(project: Project, tried: String) {
        val notification = group()?.createNotification(
            "TigerStyle server not found",
            "Tried $tried. Point the plugin at the binary under Settings | Tools | TigerStyle.",
            NotificationType.WARNING,
        ) ?: return

        notification
            .addAction(
                NotificationAction.createSimple("Open settings") {
                    ShowSettingsUtil
                        .getInstance()
                        .showSettingsDialog(project, TigerstyleConfigurable::class.java)
                },
            )
            .notify(project)
    }

    fun versionSkew(project: Project, plugin: String, server: String) {
        group()
            ?.createNotification(
                "TigerStyle versions disagree",
                "The plugin is $plugin and the server is $server. A stale server carries " +
                    "a different rule set than the plugin documents; rebuild and reinstall it.",
                NotificationType.WARNING,
            )
            ?.notify(project)
    }
}

private fun group() = NotificationGroupManager.getInstance().getNotificationGroup(GROUP)
