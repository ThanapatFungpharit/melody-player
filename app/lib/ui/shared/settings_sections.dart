import "dart:io";

import "package:flutter/material.dart";

import "../app_state.dart";
import "../../application/models.dart";
import "../../application/package_runtime.dart";
import "../../core/media.dart";
import "../../platform/features.dart";
import "dialogs.dart";
import "theme.dart";

/// A settings group: header metadata plus its fields.
class SettingsSection {
  const SettingsSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.mobileTitle,
    required this.mobileSubtitle,
    required this.body,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String mobileTitle;
  final String mobileSubtitle;
  final Widget body;
  final bool destructive;
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.section, {super.key});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(section.icon, color: scheme.primary, size: 21),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(
                section.title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                section.subtitle,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _label(BuildContext context, String text) => Text(
  text,
  style: TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

Widget _note(BuildContext context, String text) => Text(
  text,
  style: TextStyle(
    fontSize: 12,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

Widget _infoBox(
  BuildContext context,
  IconData icon,
  Widget child, {
  Color? background,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: background ?? scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Icon(
          icon,
          size: 20,
          color: background == null ? scheme.onSurfaceVariant : scheme.primary,
        ),
        Expanded(child: child),
      ],
    ),
  );
}

/// A settings dropdown. Options with an entry in [descriptions] show it
/// under their name in the menu; the closed field shows only the name. A null
/// [onChanged] shows the setting disabled.
Widget _dropdown(
  String label,
  String value,
  List<(String, String)> options,
  ValueChanged<String>? onChanged, {
  String? helper,
  Map<String, String> descriptions = const {},
}) => DropdownButtonFormField<String>(
  initialValue: options.any((option) => option.$1 == value)
      ? value
      : options.first.$1,
  isExpanded: true,
  itemHeight: descriptions.isEmpty ? kMinInteractiveDimension : null,
  decoration: InputDecoration(
    labelText: label,
    helperText: helper,
    helperMaxLines: 3,
  ),
  selectedItemBuilder: (context) => [
    for (final (_, text) in options)
      Text(text, overflow: TextOverflow.ellipsis),
  ],
  items: [
    for (final (key, text) in options)
      DropdownMenuItem(
        value: key,
        child: descriptions[key] == null
            ? Text(text)
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(text),
                    Builder(
                      builder: (context) => Text(
                        descriptions[key]!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
  ],
  onChanged: onChanged == null
      ? null
      : (value) {
          if (value != null) onChanged(value);
        },
);

SettingsSection downloadSettings(
  BuildContext context,
  MelodyApp app, {
  required bool mobile,
}) {
  final settings = app.settingsDraft;
  final draft = settings.draft;
  final android = Platform.isAndroid;
  final folder = draft.downloadDirectory;
  return SettingsSection(
    icon: Icons.download_for_offline_rounded,
    title: "Download defaults",
    subtitle:
        "Control where audio is saved and how new downloads are processed.",
    mobileTitle: "Downloads",
    mobileSubtitle: "Folder, format, quality and speed",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        TextFormField(
          key: ValueKey("folder:$folder"),
          initialValue: folder,
          readOnly: android || mobile,
          decoration: InputDecoration(
            labelText: "Music & download folder",
            prefixIcon: const Icon(Icons.folder_rounded),
            helperText: android
                ? "Choose any folder inside Music. Changes apply when you save."
                : mobile
                ? "Choose a folder. Changes apply when you save."
                : "Type a path or choose a folder. Changes apply when you save.",
            helperMaxLines: 3,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: "Choose folder",
                  onPressed: () => pickMusicFolder(app),
                  icon: const Icon(Icons.drive_folder_upload_rounded),
                ),
                IconButton(
                  tooltip: android ? "Open in Files" : "Open in file manager",
                  onPressed: () => _openMusicFolder(app),
                  icon: const Icon(Icons.open_in_new_rounded),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          onChanged: (value) => draft.downloadDirectory = value,
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              // Wide enough for the format descriptions in its menu.
              width: 300,
              child: _dropdown(
                "Audio format",
                draft.audioFormat,
                [
                  for (final format in DownloadFormat.values)
                    (format.codec, format.label),
                ],
                (value) =>
                    settings.update((draft) => draft.audioFormat = value),
                helper: draft.downloadFormat.reason,
                descriptions: {
                  for (final format in DownloadFormat.values)
                    format.codec: format.reason,
                },
              ),
            ),
            SizedBox(
              width: 220,
              child: _dropdown(
                "Audio quality",
                draft.audioQuality,
                const [
                  ("best", "Best available"),
                  ("320", "320 kbps"),
                  ("256", "256 kbps"),
                  ("192", "192 kbps"),
                  ("128", "128 kbps"),
                ],
                (value) =>
                    settings.update((draft) => draft.audioQuality = value),
                helper: draft.downloadFormat.lossless
                    ? "Lossless formats keep the source quality"
                    : null,
              ),
            ),
            SizedBox(
              width: 220,
              child: _dropdown(
                "Keep download history",
                "${draft.downloadHistoryDays}",
                [
                  for (final days in downloadHistoryChoices)
                    (
                      "$days",
                      switch (days) {
                        0 => "Forever",
                        1 => "1 day",
                        7 => "1 week",
                        _ => "$days days",
                      },
                    ),
                ],
                (value) => settings.update(
                  (draft) => draft.downloadHistoryDays = int.parse(value),
                ),
                helper: "Finished downloads are then cleared",
              ),
            ),
          ],
        ),
        Row(
          children: [
            const Expanded(
              child: Text(
                "Concurrent downloads",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              "${draft.concurrentDownloads} at a time",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
        Slider(
          value: draft.concurrentDownloads.toDouble(),
          min: 1,
          max: 8,
          divisions: 7,
          label: "${draft.concurrentDownloads} simultaneous",
          onChanged: (value) => settings.update(
            (draft) => draft.concurrentDownloads = value.round(),
          ),
        ),
        _infoBox(
          context,
          Icons.restart_alt_rounded,
          _note(
            context,
            "Format, quality, and speed changes apply after restarting "
            "Melody. A new folder applies right away.",
          ),
          background: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.09),
        ),
      ],
    ),
  );
}

/// Opens the folder shown in the settings. A folder typed or chosen but not
/// saved yet is opened only if it already exists; saving creates it.
void _openMusicFolder(MelodyApp app) {
  final draft = app.settingsDraft.draft.downloadDirectory.trim();
  final saved = app.settings.downloadDirectory;
  if (draft.isEmpty || draft == saved) {
    openFolder(app, saved);
  } else if (Directory(draft).existsSync()) {
    openFolder(app, draft);
  } else {
    app.showMessage("Save settings to create $draft.");
  }
}

SettingsSection appearanceSettings(BuildContext context, MelodyApp app) {
  final settings = app.settingsDraft;
  final draft = settings.draft;
  final scheme = Theme.of(context).colorScheme;
  return SettingsSection(
    icon: Icons.tune_rounded,
    title: "Appearance",
    subtitle: "Set the mood for your music.",
    mobileTitle: "Appearance",
    mobileSubtitle: "Theme, accent, startup and notifications",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        _label(context, "DISPLAY"),
        _dropdown("Theme", draft.theme, const [
          ("system", "Use system setting"),
          ("dark", "Dark"),
          ("light", "Light"),
        ], (value) => settings.previewAppearance(theme: value)),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              const Text(
                "Accent color",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final MapEntry(key: name, value: color)
                      in themePalettes.entries)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => settings.previewAppearance(accent: name),
                      child: SizedBox(
                        width: 72,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Column(
                            spacing: 4,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    width: name == draft.accentColor ? 3 : 1,
                                    color: name == draft.accentColor
                                        ? scheme.onSurface
                                        : scheme.outlineVariant,
                                  ),
                                ),
                              ),
                              Text(
                                "${name[0].toUpperCase()}${name.substring(1)}",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: name == draft.accentColor
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 18),
        _label(context, "STARTUP & PLAYBACK"),
        SwitchListTile(
          value: draft.resumeSession,
          onChanged: (value) =>
              settings.update((draft) => draft.resumeSession = value),
          title: const Text("Resume queue and playback state"),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: draft.skipLoadingDelay,
          onChanged: (value) =>
              settings.update((draft) => draft.skipLoadingDelay = value),
          title: const Text("Open as soon as the library is ready"),
          subtitle: const Text(
            "Skip the three-second minimum loading screen on your next launch.",
          ),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: draft.normalizeLoudness,
          onChanged: (value) =>
              settings.update((draft) => draft.normalizeLoudness = value),
          title: const Text("Normalize loudness"),
          subtitle: const Text(
            "Play songs at a similar volume. Your files and volume setting "
            "are not changed.",
          ),
          contentPadding: EdgeInsets.zero,
        ),
        _dropdown(
          "Target loudness",
          "${draft.loudnessTarget}",
          [
            for (final target in loudnessTargetChoices)
              (
                "$target",
                switch (target) {
                  -11 => "Loud ($target LUFS)",
                  -14 => "Normal ($target LUFS)",
                  -23 => "Quiet ($target LUFS, broadcast)",
                  _ => "$target LUFS",
                },
              ),
          ],
          draft.normalizeLoudness
              ? (value) => settings.update(
                  (draft) => draft.loudnessTarget = int.parse(value),
                )
              : null,
          helper: app.services.loudness.maxBoostDb > 0
              ? "Quiet tracks are raised by up to "
                    "${app.services.loudness.maxBoostDb.round()} dB, as far "
                    "as their peaks allow."
              : "Tracks quieter than the target play as they are on this "
                    "device. A lower target evens out more tracks.",
        ),
        if (draft.normalizeLoudness) _note(context, settings.loudnessStatus),
        const Divider(height: 18),
        _label(context, "NOTIFICATIONS"),
        SwitchListTile(
          value: draft.notifications,
          onChanged: (value) =>
              settings.update((draft) => draft.notifications = value),
          title: const Text("Notify when tracks change"),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: draft.autoFocalPointLiveNotifications,
          onChanged: PlatformFeatures.systemMediaControls
              ? (value) => settings.update(
                  (draft) => draft.autoFocalPointLiveNotifications = value,
                )
              : null,
          title: const Text("Auto Focal Point for Live Notifications"),
          subtitle: PlatformFeatures.systemMediaControls
              ? null
              : const Text(
                  "Not available: Linux has no system media controls.",
                ),
          contentPadding: EdgeInsets.zero,
        ),
        _dropdown(
          "Android notification shortcuts",
          draft.notificationActionPair,
          const [
            ("shuffle_favorite", "Shuffle + Favorite"),
            ("shuffle_repeat", "Shuffle + Repeat"),
            ("repeat_favorite", "Repeat + Favorite"),
          ],
          PlatformFeatures.notificationShortcuts
              ? (value) => settings.update(
                  (draft) => draft.notificationActionPair = value,
                )
              : null,
          helper: PlatformFeatures.notificationShortcuts
              ? "Choose two controls beside playback and track skipping."
              : "Available on Android only. Other system media controls have "
                    "no custom buttons.",
        ),
      ],
    ),
  );
}

SettingsSection youtubeSettings(BuildContext context, MelodyApp app) {
  final settings = app.settingsDraft;
  final (status, problem) = settings.cookieStatus();
  final scheme = Theme.of(context).colorScheme;
  final configured =
      !settings.removeCookieRequested &&
      settings.pendingCookie == null &&
      settings.savedCookieAvailable;
  return SettingsSection(
    icon: Icons.smart_display_rounded,
    title: "$youtubeMusicName access",
    subtitle: "Use your $youtubeMusicName account.",
    mobileTitle: youtubeMusicName,
    mobileSubtitle: "Account access and cookies",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        const Text(
          "$youtubeMusicName cookies",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        _infoBox(
          context,
          Icons.cookie_outlined,
          Text(
            status,
            style: TextStyle(
              fontSize: 12,
              color: problem
                  ? scheme.error
                  : settings.pendingCookie != null
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () => pickCookieFile(app),
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(
                settings.pendingCookie != null
                    ? "Choose another file"
                    : configured
                    ? "Replace file"
                    : "Upload cookie file",
              ),
            ),
            TextButton.icon(
              onPressed: settings.hasCookie ? settings.removeCookie : null,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text("Remove"),
            ),
          ],
        ),
        _note(context, "Upload a cookies.txt file exported from your browser."),
      ],
    ),
  );
}

SettingsSection maintenanceSettings(BuildContext context, MelodyApp app) {
  final settings = app.settingsDraft;
  Widget runtimeControls(PackageRuntime runtime, String title) {
    final checking = settings.isChecking(runtime);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        _infoBox(
          context,
          Icons.memory_rounded,
          _note(context, settings.packageStatusText(runtime)),
        ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: checking
                  ? null
                  : () => settings.checkForUpdate(runtime),
              icon: const Icon(Icons.update_rounded),
              label: Text(
                checking
                    ? "Checking for ${runtime.info.label} updates…"
                    : "Check for updates",
              ),
            ),
            if (settings.canInstallUpdate(runtime))
              FilledButton.icon(
                onPressed: () => settings.installUpdate(runtime),
                icon: const Icon(Icons.system_update_alt_rounded),
                label: const Text("Install update"),
              ),
          ],
        ),
      ],
    );
  }

  return SettingsSection(
    icon: Icons.build_circle_rounded,
    title: "Maintenance",
    subtitle: "Keep the music engines and library records healthy.",
    mobileTitle: "Maintenance",
    mobileSubtitle: "Engine updates and library cleanup",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        runtimeControls(
          app.services.ytMusic,
          "YouTube Music engine (ytmusicapi)",
        ),
        const Divider(height: 18),
        runtimeControls(app.services.ytDlp, "Download engine (yt-dlp)"),
        const Divider(height: 18),
        const Text(
          "Library cleanup",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        _note(
          context,
          "Remove links to deleted tracks, then review tracks whose audio is missing and "
          "music files that are not in your library. Nothing is deleted until you choose.",
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: settings.cleaningUp
                ? null
                : () async {
                    final report = await settings.cleanUpLibrary();
                    if (report != null && context.mounted) {
                      await showCleanupReport(context, app, report);
                    }
                  },
            icon: const Icon(Icons.cleaning_services_rounded),
            label: const Text("Clean up library"),
          ),
        ),
      ],
    ),
  );
}

SettingsSection dataManagementSettings(BuildContext context, MelodyApp app) {
  final scheme = Theme.of(context).colorScheme;
  Widget action(
    String title,
    String description,
    String label,
    IconData icon,
    String key,
  ) => Container(
    width: 260,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        _note(context, description),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
          onPressed: () => showDataActionDialog(context, app, key),
          icon: Icon(icon),
          label: Text(label),
        ),
      ],
    ),
  );
  return SettingsSection(
    icon: Icons.delete_sweep_rounded,
    title: "Reset / Data Management",
    subtitle:
        "Remove only the local data you choose. Every action asks for confirmation.",
    mobileTitle: "Data management",
    mobileSubtitle: "Clear or reset local data",
    destructive: true,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        if (PlatformFeatures.appDataFolder) _dataFolder(context, app),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            action(
              "Clear Library",
              "Remove every library track and all playlists. Downloaded audio is deleted; "
                  "imported files stay on disk.",
              "Clear library",
              Icons.library_music_rounded,
              "library",
            ),
            action(
              "Clear Playlists",
              "Delete user-created playlists while keeping every library track.",
              "Clear playlists",
              Icons.queue_music_rounded,
              "playlists",
            ),
            action(
              "Reset Settings",
              "Restore appearance, playback, download, and session settings to defaults.",
              "Reset settings",
              Icons.restart_alt_rounded,
              "settings",
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.error),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 5,
                  children: [
                    Row(
                      spacing: 8,
                      children: [
                        Icon(Icons.warning_amber_rounded, color: scheme.error),
                        Text(
                          "Reset Everything",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: scheme.error,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      "Clear the library and playlists, empty the playback queue, and restore all "
                      "settings. Audio files, download history, and search history are preserved.",
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  minimumSize: const Size(0, 52),
                ),
                onPressed: () =>
                    showDataActionDialog(context, app, "everything"),
                icon: const Icon(Icons.delete_forever_rounded),
                label: const Text("Reset everything"),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Where Melody keeps its databases, caches, lyrics, and cookies, with ways
/// to open or copy it.
Widget _dataFolder(BuildContext context, MelodyApp app) {
  final folder = app.services.paths.dataDirectory;
  return _infoBox(
    context,
    Icons.folder_special_rounded,
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        const Text(
          "App data folder",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        SelectableText(
          folder,
          style: const TextStyle(fontSize: 12, fontFamily: "monospace"),
        ),
        _note(
          context,
          "Library and settings databases, saved lyrics, cookies, and "
          "caches. Close Melody before changing files here; the cache "
          "folder is safe to delete.",
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => openFolder(app, folder),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text("Open folder"),
            ),
            TextButton.icon(
              onPressed: () => copyFolderPath(app, folder),
              icon: const Icon(Icons.copy_rounded),
              label: const Text("Copy path"),
            ),
          ],
        ),
      ],
    ),
  );
}
