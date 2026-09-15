import re
from pathlib import Path


def process_file(path):
    content = path.read_text("utf-8")
    content = content.replace("app.shell.navigate", "app.navigation.navigate")
    content = content.replace("app.shell._build_shell", "app.navigation._build_shell")
    path.write_text(content, "utf-8")


def main():
    root = Path("src/musicplayer/ui")
    for d in ["pages", "components", "desktop", "mobile"]:
        for f in (root / d).glob("*.py"):
            if f.name != "__init__.py":
                process_file(f)

    # Now let's fix app.py
    app_py = Path("src/musicplayer/app.py")
    app_content = app_py.read_text("utf-8")

    # Replace class MusicPlayerApp(...) with class MusicPlayerApp:
    app_content = re.sub(
        r"class MusicPlayerApp\([^)]+\):", "class MusicPlayerApp:", app_content
    )

    # In __init__, we need to instantiate the components
    # Find `self._build_shell()`
    instantiations = """
        self.navigation = NavigationShell(self)
        self.player_bar = PlayerBar(self)
        self.context_panel = ContextPanel(self)
        self.shared = SharedUIComponents(self)
        self.home_page = HomePage(self)
        self.search_page = SearchPage(self)
        self.library_page = LibraryPage(self)
        self.playlists_page = PlaylistsPage(self)
        self.queue_page = QueuePage(self)
        self.downloads_page = DownloadsPage(self)
        self.settings_page = SettingsPage(self)
        self.navigation._build_shell()
"""
    app_content = app_content.replace("self._build_shell()", instantiations.strip())

    # Also replace other self calls in app.py that now belong to components
    # e.g., self._initialize_search_page() -> self.search_page._initialize_search_page()
    app_content = app_content.replace(
        "self._initialize_search_page()", "self.search_page._initialize_search_page()"
    )
    app_content = app_content.replace(
        "self._initialize_library_page()",
        "self.library_page._initialize_library_page()",
    )
    app_content = app_content.replace(
        "self._initialize_playlists_page()",
        "self.playlists_page._initialize_playlists_page()",
    )

    # _cancel_playlist_import_retry
    app_content = app_content.replace(
        "self._cancel_playlist_import_retry()",
        "self.playlists_page._cancel_playlist_import_retry()",
    )

    # _refresh_download_badge
    app_content = app_content.replace(
        "self._refresh_download_badge()", "self.context_panel._refresh_download_badge()"
    )

    # _refresh_context_panel
    app_content = app_content.replace(
        "self._refresh_context_panel()", "self.context_panel._refresh_context_panel()"
    )

    # _refresh_library_list
    app_content = app_content.replace(
        "self._refresh_library_list()", "self.library_page._refresh_library_list()"
    )

    # _continue_playlist_import
    app_content = app_content.replace(
        "self._continue_playlist_import(",
        "self.playlists_page._continue_playlist_import(",
    )

    # playlist_import_session
    app_content = app_content.replace(
        "self.playlist_import_session", "self.playlists_page.playlist_import_session"
    )

    # _refresh_player_progress, _refresh_player_volume, _refresh_player
    app_content = app_content.replace(
        "self._refresh_player_progress()", "self.player_bar._refresh_player_progress()"
    )
    app_content = app_content.replace(
        "self._refresh_player_volume()", "self.player_bar._refresh_player_volume()"
    )
    app_content = app_content.replace(
        "self._refresh_player()", "self.player_bar._refresh_player()"
    )

    # _show_message and _show_error and _submit_background are still on MusicPlayerApp!
    # So they stay as self._show_message

    # What about _reapply_accent? It's in shared!
    app_content = app_content.replace(
        "self._reapply_accent()", "self.shared._reapply_accent()"
    )

    # _theme_mode, _time_greeting etc were imported from ui.components.common?
    # Yes, they are helper functions imported in app.py. So they are just local names.

    # Let's save app.py
    app_py.write_text(app_content, "utf-8")


if __name__ == "__main__":
    main()
