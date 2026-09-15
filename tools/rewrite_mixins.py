import re
from pathlib import Path

COMPONENTS = {
    "shared": [
        "_play_collection",
        "_queue_collection",
        "_playlist_card",
        "_context_header",
        "_page_header",
        "_time_greeting",
        "_empty_state",
        "_track_title",
        "_track_credit",
        "_artwork",
        "_download_detail",
        "_format_bytes",
        "_format_duration",
        "_theme_mode",
        "_accent_hex",
        "_reapply_accent",
        "_is_mobile_platform",
        "_responsive_grid",
    ],
    "shell": ["navigate", "_build_shell", "resize", "keyboard"],
    "player_bar": [
        "_refresh_player",
        "_refresh_player_progress",
        "_refresh_player_volume",
    ],
    "context_panel": [
        "_open_queue_panel",
        "_open_downloads_panel",
        "_open_settings_panel",
        "_close_context_panel",
        "_refresh_context_panel",
        "_refresh_download_badge",
    ],
    "home_page": [
        "_home_view",
        "_track_shelf",
        "_track_card",
        "_card_hover",
        "_home_collections",
    ],
    "search_page": [
        "_search_view",
        "_available_search_track",
        "_initialize_search_page",
        "_search_result_card",
        "_search_submit",
        "_search_changed",
    ],
    "library_page": [
        "_library_view",
        "_refresh_library_list",
        "_initialize_library_page",
        "_toggle_favorite",
        "_toggle_current_favorite",
        "_track_details_dialog",
        "_add_to_playlist",
    ],
    "playlists_page": [
        "_playlists_view",
        "_open_playlist",
        "_play_playlist",
        "_initialize_playlists_page",
        "_continue_playlist_import",
        "_abandon_playlist_import",
        "_cancel_playlist_import_retry",
    ],
    "queue_page": ["_queue_view"],
    "downloads_page": ["_downloads_view", "_download_changed"],
    "settings_page": ["_settings_view"],
}

# The pages that become components
COMPONENT_CLASSES = {
    "HomePage": "home_page",
    "SearchPage": "search_page",
    "LibraryPage": "library_page",
    "PlaylistsPage": "playlists_page",
    "QueuePage": "queue_page",
    "DownloadsPage": "downloads_page",
    "SettingsPage": "settings_page",
    "PlayerBar": "player_bar",
    "ContextPanel": "context_panel",
    "SharedUIComponents": "shared",
    "NavigationShell": "shell",
}

APP_PROPERTIES = [
    "page",
    "views",
    "settings",
    "store",
    "manager",
    "library",
    "playback",
    "providers",
    "downloads",
    "thumbnails",
    "workers",
    "tasks",
    "file_picker",
    "data_directory",
    "_show_message",
    "_show_error",
    "_submit_background",
    "active_panel",
    "selected_navigation",
    "pending_download_actions",
    "_download_play_requests",
]


def find_owner(method_name):
    for comp, methods in COMPONENTS.items():
        if method_name in methods:
            return comp
    if method_name in APP_PROPERTIES:
        return "app"  # root app property
    return None


def process_page_file(path: Path):
    content = path.read_text("utf-8")

    # 1. Update imports
    content = content.replace(
        "from musicplayer.ui._app_protocol import AppProtocol",
        "from musicplayer.app import MusicPlayerApp",
    )
    content = content.replace("_Base = AppProtocol", "_Base = object")

    # 2. Find the class
    class_match = re.search(r"class (\w+)\(_Base\):", content)
    if not class_match:
        class_match = re.search(r"class (\w+)\(object\):", content)
    if not class_match:
        return
    class_name = class_match.group(1)
    comp_name = COMPONENT_CLASSES.get(class_name)

    # Replace class def
    content = re.sub(
        r"class " + class_name + r"\(_Base\):\n",
        f'class {class_name}:\n    def __init__(self, app: "MusicPlayerApp"):\n        self.app = app\n\n',
        content,
    )
    content = re.sub(
        r"class " + class_name + r"\(object\):\n",
        f'class {class_name}:\n    def __init__(self, app: "MusicPlayerApp"):\n        self.app = app\n\n',
        content,
    )

    # 3. Replace self.X with self.app.X or self.app.comp.X
    def replacer(m):
        attr = m.group(1)
        if attr in COMPONENTS.get(comp_name, []):
            return f"self.{attr}"
        owner = find_owner(attr)
        if owner == "app":
            return f"self.app.{attr}"
        elif owner:
            return f"self.app.{owner}.{attr}"
        return f"self.app.{attr}"  # fallback to app

    # Be careful not to replace self.app
    # We regex replace self\.(?!app\b)(\w+)
    content = re.sub(r"self\.(?!app\b)(\w+)", replacer, content)

    path.write_text(content, "utf-8")


def process_view_file(path: Path):
    content = path.read_text("utf-8")

    # Update imports
    content = content.replace(
        "from musicplayer.ui._app_protocol import AppProtocol",
        "from musicplayer.app import MusicPlayerApp",
    )

    # Find which view this is. Usually def _something_view(app: AppProtocol):
    # Or in mobile shell: def __init__(self, app: AppProtocol):

    # For views, we want them to take the app directly as MusicPlayerApp,
    # and they can access the components via app.home_page, etc.
    # Wait, the plan says:
    # "ui/desktop/home.py will change from def _home_view(app: AppProtocol): to def _home_view(home_page: 'HomePage'):"
    # Actually, it's MUCH simpler if the view builders just take `app: "MusicPlayerApp"` and then do `app.home_page._track_shelf`!
    # Because then we only change `app._track_shelf` to `app.home_page._track_shelf`.
    # Let's do that! It is strictly better and easier.

    content = content.replace("app: AppProtocol", 'app: "MusicPlayerApp"')
    content = content.replace('app: "AppProtocol"', 'app: "MusicPlayerApp"')

    def replacer(m):
        attr = m.group(1)
        owner = find_owner(attr)
        if owner == "app":
            return f"app.{attr}"
        elif owner:
            return f"app.{owner}.{attr}"
        return f"app.{attr}"

    content = re.sub(
        r"app\.(?!shared\b|shell\b|player_bar\b|context_panel\b|home_page\b|search_page\b|library_page\b|playlists_page\b|queue_page\b|downloads_page\b|settings_page\b)(\w+)",
        replacer,
        content,
    )

    path.write_text(content, "utf-8")


def main():
    root = Path("src/musicplayer/ui")

    # Process pages and components
    for d in ["pages", "components"]:
        for f in (root / d).glob("*.py"):
            if f.name not in ["__init__.py", "tasks.py", "common.py"]:
                print(f"Processing page/component: {f}")
                process_page_file(f)

    # common.py doesn't have a class, it just has functions that used to take app
    common_path = root / "components" / "common.py"
    if common_path.exists():
        print(f"Processing view: {common_path}")
        process_view_file(common_path)

    # Process views
    for d in ["desktop", "mobile"]:
        for f in (root / d).glob("*.py"):
            if f.name != "__init__.py":
                print(f"Processing view: {f}")
                process_view_file(f)


if __name__ == "__main__":
    main()
