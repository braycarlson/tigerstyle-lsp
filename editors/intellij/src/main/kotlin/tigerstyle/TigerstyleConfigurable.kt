package tigerstyle

import com.intellij.openapi.options.Configurable
import com.intellij.openapi.project.ProjectManager
import com.intellij.openapi.ui.ComboBox
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent
import javax.swing.JPanel

internal class TigerstyleConfigurable : Configurable {
    private val binary = JBTextField()
    private val extendSelect = JBTextField()
    private val fixOnSave = JBCheckBox("Apply the safe fixes on save")
    private val ignore = JBTextField()
    private val preference = ComboBox(PREFERENCES.toTypedArray())
    private val preview = JBCheckBox("Turn on the rules still in preview")
    private val select = JBTextField()

    override fun apply() {
        val settings = TigerstyleSettings.instance()
        val restart = binary.text.trim() != settings.binaryPath

        settings.binaryPath = binary.text.trim()
        settings.configurationPreference = preference.item
        settings.extendSelect = extendSelect.text.trim()
        settings.fixOnSave = fixOnSave.isSelected
        settings.ignore = ignore.text.trim()
        settings.preview = preview.isSelected
        settings.select = select.text.trim()

        ProjectManager.getInstance().openProjects.forEach { project ->
            if (restart) {
                restartTigerstyle(project)
            } else {
                configurationChanged(project)
            }
        }
    }

    override fun createComponent(): JComponent = FormBuilder
        .createFormBuilder()
        .addLabeledComponent(JBLabel("Server binary:"), binary, true)
        .addTooltip("Leave empty to look up `$BINARY_NAME` on PATH.")
        .addLabeledComponent(JBLabel("Configuration preference:"), preference, true)
        .addTooltip("How these settings layer against the tigerstyle.toml hierarchy.")
        .addComponent(preview)
        .addComponent(fixOnSave)
        .addTooltip("The client must support workspace/applyEdit.")
        .addLabeledComponent(JBLabel("Extend select:"), extendSelect, true)
        .addTooltip("Rules that run beside the default set, separated by commas.")
        .addLabeledComponent(JBLabel("Ignore:"), ignore, true)
        .addTooltip("Rules that are turned off, separated by commas.")
        .addLabeledComponent(JBLabel("Select:"), select, true)
        .addTooltip("Rules that replace the default set. An empty field leaves the set alone.")
        .addComponentFillVertically(JPanel(), 0)
        .panel

    override fun getDisplayName(): String = "TigerStyle"

    override fun isModified(): Boolean {
        val settings = TigerstyleSettings.instance()

        return binary.text.trim() != settings.binaryPath ||
            preference.item != settings.configurationPreference ||
            extendSelect.text.trim() != settings.extendSelect ||
            fixOnSave.isSelected != settings.fixOnSave ||
            ignore.text.trim() != settings.ignore ||
            preview.isSelected != settings.preview ||
            select.text.trim() != settings.select
    }

    override fun reset() {
        val settings = TigerstyleSettings.instance()

        binary.text = settings.binaryPath
        extendSelect.text = settings.extendSelect
        fixOnSave.isSelected = settings.fixOnSave
        ignore.text = settings.ignore
        preference.item = settings.configurationPreference
        preview.isSelected = settings.preview
        select.text = settings.select
    }
}
