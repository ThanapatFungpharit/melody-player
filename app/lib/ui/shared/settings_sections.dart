import "dart:io";

import "package:flutter/material.dart";

import "../../app/app_state.dart";
import "../../core/media.dart";
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
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
          child: Icon(section.icon, color: scheme.primary, size: 24),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(section.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text(section.subtitle, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _label(BuildContext context, String text) => Text(
  text,
  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
);

Widget _note(BuildContext context, String text) =>
    Text(text, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant));

Widget _infoBox(BuildContext context, IconData icon, Widget child, {Color? background}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: background ?? scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Icon(icon, size: 20, color: background == null ? scheme.onSurfaceVariant : scheme.primary),
        Expanded(child: child),
      ],
    ),
  );
}

Widget _dropdown(
  String label,
  String value,
  List<(String, String)> options,
  ValueChanged<String> onChanged, {
  String? helper,
}) => DropdownButtonFormField<String>(
  initialValue: options.any((option) => option.$1 == value) ? value : options.first.$1,
  decoration: InputDecoration(
    labelText: label,
    helperText: helper,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
  ),
  items: [for (final (key, text) in options) DropdownMenuItem(value: key, child: Text(text))],
  onChanged: (value) {
    if (value != null) onChanged(value);
  },
);

SettingsSection downloadSettings(BuildContext context, MelodyApp app, {required bool mobile}) {
  final settings = app.settingsDraft;
  final draft = settings.draft;
  final android = Platform.isAndroid;
  final folder = android ? (app.services.paths.publicMusicDirectory ?? draft.downloadDirectory) : draft.downloadDirectory;
  return SettingsSection(
    icon: Icons.download_for_offline_rounded,
    title: "Download defaults",
    subtitle: "Control where audio is saved and how new downloads are processed.",
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
            helperText: mobile
                ? (android
                      ? "Completed tracks are saved in the public Music/Melody folder"
                      : "Managed music folder on this device")
                : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onChanged: (value) => draft.downloadDirectory = value,
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 220,
              child: _dropdown("Audio format", draft.audioFormat, const [
                ("mp3", "MP3"),
                ("m4a", "M4A"),
                ("opus", "Opus"),
              ], (value) => settings.update((draft) => draft.audioFormat = value)),
            ),
            SizedBox(
              width: 220,
              child: _dropdown("Audio quality", draft.audioQuality, const [
                ("best", "Best available"),
                ("320", "320 kbps"),
                ("256", "256 kbps"),
                ("192", "192 kbps"),
                ("128", "128 kbps"),
              ], (value) => settings.update((draft) => draft.audioQuality = value)),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  const Text("Concurrent downloads", style: TextStyle(fontWeight: FontWeight.bold)),
                  _note(context, "Balance speed against network and CPU usage."),
                ],
              ),
            ),
            Text(
              "${draft.concurrentDownloads} workers",
              style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ),
        Slider(
          value: draft.concurrentDownloads.toDouble(),
          min: 1,
          max: 8,
          divisions: 7,
          label: "${draft.concurrentDownloads} simultaneous",
          onChanged: (value) => settings.update((draft) => draft.concurrentDownloads = value.round()),
        ),
        _infoBox(
          context,
          Icons.restart_alt_rounded,
          _note(context, "Download changes apply after restarting Melody."),
          background: Theme.of(context).colorScheme.primaryContainer,
        ),
      ],
    ),
  );
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
          decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              const Text("Accent color", style: TextStyle(fontWeight: FontWeight.bold)),
              _note(context, "Choose a color for controls and highlights."),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final MapEntry(key: name, value: color) in themePalettes.entries)
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
                                    color: name == draft.accentColor ? scheme.onSurface : scheme.outlineVariant,
                                  ),
                                ),
                              ),
                              Text(
                                "${name[0].toUpperCase()}${name.substring(1)}",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: name == draft.accentColor ? FontWeight.bold : FontWeight.normal,
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
          onChanged: (value) => settings.update((draft) => draft.resumeSession = value),
          title: const Text("Resume queue and playback state"),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: draft.skipLoadingDelay,
          onChanged: (value) => settings.update((draft) => draft.skipLoadingDelay = value),
          title: const Text("Open as soon as the library is ready"),
          subtitle: const Text("Skip the three-second minimum loading screen on your next launch."),
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(height: 18),
        _label(context, "NOTIFICATIONS"),
        SwitchListTile(
          value: draft.notifications,
          onChanged: (value) => settings.update((draft) => draft.notifications = value),
          title: const Text("Notify when tracks change"),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: draft.autoFocalPointLiveNotifications,
          onChanged: (value) => settings.update((draft) => draft.autoFocalPointLiveNotifications = value),
          title: const Text("Auto Focal Point for Live Notifications"),
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
          (value) => settings.update((draft) => draft.notificationActionPair = value),
          helper: "Choose two controls beside playback and track skipping.",
        ),
      ],
    ),
  );
}

SettingsSection youtubeSettings(BuildContext context, MelodyApp app) {
  final settings = app.settingsDraft;
  final (status, problem) = settings.cookieStatus();
  final scheme = Theme.of(context).colorScheme;
  final configured = !settings.removeCookieRequested &&
      settings.pendingCookie == null &&
      app.settings.cookieFile.isNotEmpty &&
      File(app.settings.cookieFile).existsSync();
  return SettingsSection(
    icon: Icons.smart_display_rounded,
    title: "$youtubeMusicName access",
    subtitle: "$youtubeMusicName is Melody’s default and only music source.",
    mobileTitle: youtubeMusicName,
    mobileSubtitle: "Account access and cookies",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        const Text("$youtubeMusicName cookies", style: TextStyle(fontWeight: FontWeight.bold)),
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
        _note(
          context,
          "Upload a UTF-8 Netscape cookies.txt export. Melody validates it and copies it to "
          "private app storage; it never reads browser cookie databases. The same flow works "
          "on desktop and Android.",
        ),
      ],
    ),
  );
}

SettingsSection maintenanceSettings(BuildContext context, MelodyApp app) {
  final settings = app.settingsDraft;
  return SettingsSection(
    icon: Icons.build_circle_rounded,
    title: "Maintenance",
    subtitle: "Keep the download engine and library records healthy.",
    mobileTitle: "Maintenance",
    mobileSubtitle: "yt-dlp updates and library cleanup",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        const Text("Download engine (yt-dlp)", style: TextStyle(fontWeight: FontWeight.bold)),
        _infoBox(context, Icons.memory_rounded, _note(context, settings.ytDlpStatusText())),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: settings.checkingYtDlp ? null : settings.checkForUpdate,
              icon: const Icon(Icons.update_rounded),
              label: Text(settings.checkingYtDlp ? "Checking for yt-dlp updates…" : "Check for updates"),
            ),
            if (settings.canInstallUpdate)
              FilledButton.icon(
                onPressed: settings.installUpdate,
                icon: const Icon(Icons.system_update_alt_rounded),
                label: const Text("Install update"),
              ),
          ],
        ),
        const Divider(height: 18),
        const Text("Library cleanup", style: TextStyle(fontWeight: FontWeight.bold)),
        _note(
          context,
          "Remove favorites and history that point to deleted tracks, and find audio files in "
          "the music folder that are not in your library. Files are never deleted.",
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: settings.cleaningUp
                ? null
                : () async {
                    final report = await settings.cleanUpLibrary();
                    if (report != null && context.mounted) await showCleanupReport(context, app, report);
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
  Widget action(String title, String description, String label, IconData icon, String key) => Container(
    width: 260,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
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
    subtitle: "Remove only the local data you choose. Every action asks for confirmation.",
    mobileTitle: "Data management",
    mobileSubtitle: "Clear or reset local data",
    destructive: true,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            action(
              "Clear Library",
              "Remove every library track and all playlists. Audio files stay on disk.",
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
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: scheme.error),
                        ),
                      ],
                    ),
                    Text(
                      "Clear the library and playlists, empty the playback queue, and restore all "
                      "settings. Audio files, download history, and search history are preserved.",
                      style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
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
                onPressed: () => showDataActionDialog(context, app, "everything"),
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
