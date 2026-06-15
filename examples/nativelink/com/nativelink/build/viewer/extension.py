class NativelinkBuildViewerExtension:
    def on_startup(self, ext_id):
        self._ext_id = ext_id

    def on_shutdown(self):
        self._ext_id = None

