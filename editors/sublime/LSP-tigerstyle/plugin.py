from LSP.plugin import AbstractPlugin, register_plugin, unregister_plugin


class Tigerstyle(AbstractPlugin):
    @classmethod
    def name(cls) -> str:
        return 'tigerstyle'


def plugin_loaded() -> None:
    register_plugin(Tigerstyle)


def plugin_unloaded() -> None:
    unregister_plugin(Tigerstyle)
