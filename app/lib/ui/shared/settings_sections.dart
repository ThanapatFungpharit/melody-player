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
    final color = section.destructive ? scheme.error : scheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(Radii.medium),
          ),
          child: Icon(section.icon, color: color, size: 21),
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

// ---------------------------------------------------------------------------
// Shared building blocks
// ---------------------------------------------------------------------------

const _sectionDivider = Divider(height: 8);

/// Wraps a field that opens a section. Its floating label sits partly above
/// the field, where the mobile section's expansion tile would clip it. With
/// the tile's own top padding of 3, the field sits 12 below the tile's header.
Widget _topField(Widget field) =>
    Padding(padding: const EdgeInsets.only(top: 9), child: field);

/// An all-caps group label inside a section.
Widget _label(BuildContext context, String text) => Text(
  text,
  style: TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

/// A bold title for a group of related controls.
Widget _heading(String text) =>
    Text(text, style: const TextStyle(fontWeight: FontWeight.bold));

/// A title for one control, with its current value at the far end.
Widget _valueHeading(BuildContext context, String title, String value) => Row(
  children: [
    Expanded(child: _heading(title)),
    Text(
      value,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  ],
);

/// Controls that belong together, closer to each other than a section's
/// separate settings are.
Widget _group(List<Widget> children) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  spacing: 10,
  children: children,
);

/// Two fields sharing a row, stacked when each would be too narrow to read.
Widget _fieldPair(Widget first, Widget second) => LayoutBuilder(
  builder: (context, constraints) => constraints.maxWidth < 400
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [first, second],
        )
      : Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Expanded(child: first),
            Expanded(child: second),
          ],
        ),
);

/// A title and description with the button they explain: beside them, or
/// beneath them when there is no room.
Widget _actionRow(Widget title, Widget description, Widget action) {
  final text = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 4,
    children: [title, description],
  );
  return LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < 440
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [text, action],
          )
        : Row(
            spacing: 16,
            children: [
              Expanded(child: text),
              action,
            ],
          ),
  );
}

/// Small secondary text explaining a setting.
Widget _note(BuildContext context, String text) => Text(
  text,
  style: TextStyle(
    fontSize: 12,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

/// Buttons laid out in a row that wraps on narrow screens.
Widget _buttonRow(List<Widget> buttons) =>
    Wrap(spacing: 10, runSpacing: 10, children: buttons);

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
      borderRadius: BorderRadius.circular(Radii.medium),
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
    for (final (_, optionLabel) in options)
      Text(optionLabel, overflow: TextOverflow.ellipsis),
  ],
  items: [
    for (final (optionKey, optionLabel) in options)
      DropdownMenuItem(
        value: optionKey,
        child: switch (descriptions[optionKey]) {
          null => Text(optionLabel),
          final description => _describedOption(optionLabel, description),
        },
      ),
  ],
  onChanged: onChanged == null
      ? null
      : (selected) {
          if (selected != null) onChanged(selected);
        },
);

/// A dropdown menu entry with a secondary description line.
Widget _describedOption(String optionLabel, String description) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 8),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(optionLabel),
      Builder(
        builder: (context) => Text(
          description,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  ),
);

/// A settings text field. It is rebuilt when [value] changes from outside.
Widget _textFormField(
  String label,
  String value,
  ValueChanged<String>? onChanged, {
  String? helper,
  Widget? prefixIcon,
  Widget? suffixIcon,
  bool readOnly = false,
}) => TextFormField(
  key: ValueKey("$label:$value"),
  initialValue: value,
  readOnly: readOnly,
  decoration: InputDecoration(
    labelText: label,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    helperText: helper,
    helperMaxLines: 3,
  ),
  onChanged: onChanged,
);

String _capitalize(String word) =>
    word.isEmpty ? word : "${word[0].toUpperCase()}${word.substring(1)}";

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

const _audioQualityOptions = [
  ("best", "Best available"),
  ("320", "320 kbps"),
  ("256", "256 kbps"),
  ("192", "192 kbps"),
  ("128", "128 kbps"),
];

String _historyLabel(int days) => switch (days) {
  0 => "Forever",
  1 => "1 day",
  7 => "1 week",
  _ => "$days days",
};

SettingsSection downloadSettings(
  BuildContext context,
  MelodyApp app, {
  required bool mobile,
}) {
  final controls = app.settingsControls;
  final current = app.settings;
  final android = Platform.isAndroid;
  final folderHelper = android
      ? "Choose any folder inside Music."
      : mobile
      ? "Choose a folder."
      : "Type a path or choose a folder.";

  return SettingsSection(
    icon: Icons.download_for_offline_rounded,
    title: "Download defaults",
    subtitle: "Where new downloads are saved and how they're processed.",
    mobileTitle: "Downloads",
    mobileSubtitle: "Folder, format, quality and speed",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      // Room for each field's floating label beneath the helper text above it.
      spacing: 20,
      children: [
        _topField(
          _textFormField(
            "Music & download folder",
            controls.folderField,
            controls.typeMusicFolder,
            readOnly: android || mobile,
            prefixIcon: const Icon(Icons.folder_rounded),
            helper: folderHelper,
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
                  onPressed: () => openFolder(app, current.downloadDirectory),
                  icon: const Icon(Icons.open_in_new_rounded),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
        if (controls.musicFolderChanged)
          _buttonRow([
            FilledButton.icon(
              onPressed: () => applyMusicFolder(context, app),
              icon: const Icon(Icons.drive_file_move_rounded),
              label: Text(
                controls.tracksToMove > 0
                    ? "Move library here"
                    : "Use this folder",
              ),
            ),
            TextButton(
              onPressed: () =>
                  controls.chooseMusicFolder(current.downloadDirectory),
              child: const Text("Keep current folder"),
            ),
          ]),
        // Full width, since its menu describes each format.
        _dropdown(
          "Audio format",
          current.audioFormat,
          [
            for (final format in DownloadFormat.values)
              (format.codec, format.label),
          ],
          (value) => controls.update((next) => next.audioFormat = value),
          helper: current.downloadFormat.reason,
          descriptions: {
            for (final format in DownloadFormat.values)
              format.codec: format.reason,
          },
        ),
        _fieldPair(
          _dropdown(
            "Audio quality",
            current.audioQuality,
            _audioQualityOptions,
            (value) => controls.update((next) => next.audioQuality = value),
            helper: current.downloadFormat.lossless
                ? "Lossless formats keep the source quality"
                : null,
          ),
          _dropdown(
            "Keep download history",
            "${current.downloadHistoryDays}",
            [
              for (final days in downloadHistoryChoices)
                ("$days", _historyLabel(days)),
            ],
            (value) => controls.update(
              (next) => next.downloadHistoryDays = int.parse(value),
            ),
            helper: "Finished downloads are then cleared",
          ),
        ),
        _group([
          _valueHeading(
            context,
            "Concurrent downloads",
            "${current.concurrentDownloads} at a time",
          ),
          Slider(
            value: current.concurrentDownloads.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            label: "${current.concurrentDownloads} simultaneous",
            padding: const EdgeInsets.symmetric(vertical: 8),
            onChanged: (value) => controls.update(
              (next) => next.concurrentDownloads = value.round(),
            ),
          ),
        ]),
        _note(context, "These apply to downloads that start from now on."),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------

const _themeOptions = [
  ("system", "Use system setting"),
  ("dark", "Dark"),
  ("light", "Light"),
];

const _notificationShortcutOptions = [
  ("shuffle_favorite", "Shuffle + Favorite"),
  ("shuffle_repeat", "Shuffle + Repeat"),
  ("repeat_favorite", "Repeat + Favorite"),
];

String _loudnessTargetLabel(int target) => switch (target) {
  -11 => "Loud ($target LUFS)",
  -14 => "Normal ($target LUFS)",
  -23 => "Quiet ($target LUFS, broadcast)",
  _ => "$target LUFS",
};

/// One selectable accent color. The selected one carries a check, so the
/// choice doesn't rest on color alone, and each names itself in a tooltip.
class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = _capitalize(name);
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: touchTarget,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: selected ? 2 : 1,
                    color: selected ? scheme.onSurface : scheme.outlineVariant,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check_rounded, size: 20, color: onColor)
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

SettingsSection appearanceSettings(BuildContext context, MelodyApp app) {
  final controls = app.settingsControls;
  final current = app.settings;

  final loudness = app.services.loudness;
  final maxBoostDb = loudness.maxBoostDb.round();
  final loudnessHelper = loudness.limiterHeadroomDb > 0
      ? "Quiet tracks are boosted by up to $maxBoostDb dB, with a limiter "
            "to prevent clipping."
      : loudness.maxBoostDb > 0
      ? "Quiet tracks are boosted by up to $maxBoostDb dB, as far as their "
            "peaks allow."
      : "Quiet tracks aren't boosted on this device. A lower target evens "
            "out more tracks.";

  return SettingsSection(
    icon: Icons.tune_rounded,
    title: "Appearance",
    subtitle: "Set the mood for your music.",
    mobileTitle: "Appearance",
    mobileSubtitle: "Theme, accent, startup and playback",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        _label(context, "DISPLAY"),
        _dropdown(
          "Theme",
          current.theme,
          _themeOptions,
          (value) => controls.update((next) => next.theme = value),
        ),
        _group([
          _valueHeading(
            context,
            "Accent color",
            _capitalize(current.accentColor),
          ),
          Wrap(
            children: [
              for (final MapEntry(key: name, value: color)
                  in themePalettes.entries)
                _AccentSwatch(
                  name: name,
                  color: color,
                  selected: name == current.accentColor,
                  onTap: () =>
                      controls.update((next) => next.accentColor = name),
                ),
            ],
          ),
        ]),
        _sectionDivider,
        _label(context, "STARTUP & PLAYBACK"),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              value: current.resumeSession,
              onChanged: (value) =>
                  controls.update((next) => next.resumeSession = value),
              title: const Text("Resume queue and playback state"),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              value: current.normalizeLoudness,
              onChanged: (value) =>
                  controls.update((next) => next.normalizeLoudness = value),
              title: const Text("Normalize loudness"),
              subtitle: const Text(
                "Play songs at a similar volume. Your files and volume "
                "setting stay the same.",
              ),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
        _dropdown(
          "Target loudness",
          "${current.loudnessTarget}",
          [
            for (final target in loudnessTargetChoices)
              ("$target", _loudnessTargetLabel(target)),
          ],
          current.normalizeLoudness
              ? (value) => controls.update(
                  (next) => next.loudnessTarget = int.parse(value),
                )
              : null,
          helper: loudnessHelper,
        ),
        if (current.normalizeLoudness) _note(context, controls.loudnessStatus),
        if (PlatformFeatures.notificationShortcuts) ...[
          _sectionDivider,
          _label(context, "NOTIFICATIONS"),
          _dropdown(
            "Android notification shortcuts",
            current.notificationActionPair,
            _notificationShortcutOptions,
            (value) =>
                controls.update((next) => next.notificationActionPair = value),
            helper: "Choose two controls beside playback and track skipping.",
          ),
        ],
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Music source
// ---------------------------------------------------------------------------

const _regularYoutubeLimits =
    "With regular $youtubeName, searches may return music videos, covers, "
    "remixes, or unrelated videos. Details can be incomplete, and duplicates "
    "are harder to spot because each video counts as its own track. Lyrics are "
    "often missing, mixes open on $youtubeMusicName, and availability varies "
    "by region.";

const _musicSourceDescriptions = {
  "youtube_music": "Official songs, with artists and album artwork.",
  "youtube": "Every video on $youtubeName, with less reliable details.",
};

SettingsSection youtubeSettings(BuildContext context, MelodyApp app) {
  final controls = app.settingsControls;
  final current = app.settings;
  return SettingsSection(
    icon: Icons.smart_display_rounded,
    title: "Music source and access",
    subtitle: "Where music comes from, and your $youtubeName account.",
    mobileTitle: "Music source",
    mobileSubtitle: "${current.musicSource.label}, account access",
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        _topField(
          _dropdown(
            "Search and download from",
            current.musicSource.id,
            [
              for (final source in MusicSource.values)
                (source.id, source.label),
            ],
            (value) => controls.update(
              (next) => next.musicSource = MusicSource.parse(value),
            ),
            descriptions: _musicSourceDescriptions,
            helper:
                "Applies to new searches and downloads. Your library, "
                "playlists, and queue aren't affected.",
          ),
        ),
        _infoBox(
          context,
          Icons.info_outline_rounded,
          _note(context, _regularYoutubeLimits),
        ),
        _sectionDivider,
        _group([
          _heading("$youtubeName cookies"),
          _infoBox(
            context,
            Icons.cookie_outlined,
            _note(context, controls.cookieStatus),
          ),
          _note(
            context,
            "Upload a cookies.txt file exported from your browser.",
          ),
          _buttonRow([
            FilledButton.icon(
              onPressed: () => pickCookieFile(app),
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(
                controls.savedCookieAvailable
                    ? "Replace file"
                    : "Upload cookie file",
              ),
            ),
            TextButton.icon(
              onPressed: controls.savedCookieAvailable
                  ? () => app.run(controls.removeCookie)
                  : null,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text("Remove"),
            ),
          ]),
        ]),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Maintenance
// ---------------------------------------------------------------------------

/// Status and update buttons for one bundled engine.
Widget _engineControls(
  BuildContext context,
  MelodyApp app,
  PackageRuntime runtime,
  String title,
) {
  final controls = app.settingsControls;
  final checking = controls.isChecking(runtime);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 10,
    children: [
      _heading(title),
      _infoBox(
        context,
        Icons.memory_rounded,
        _note(context, controls.packageStatusText(runtime)),
      ),
      _note(
        context,
        "This version of Melody supports ${runtime.info.label} "
        "${runtime.info.supported}. Newer releases need a Melody update.",
      ),
      _buttonRow([
        OutlinedButton.icon(
          onPressed: checking ? null : () => controls.checkForUpdate(runtime),
          icon: const Icon(Icons.update_rounded),
          label: Text(
            checking
                ? "Checking for ${runtime.info.label} updates…"
                : "Check for updates",
          ),
        ),
        if (controls.canInstallUpdate(runtime))
          FilledButton.icon(
            onPressed: () => controls.installUpdate(runtime),
            icon: const Icon(Icons.system_update_alt_rounded),
            label: const Text("Install update"),
          ),
      ]),
    ],
  );
}

SettingsSection maintenanceSettings(BuildContext context, MelodyApp app) {
  final controls = app.settingsControls;

  Future<void> cleanUpLibrary() async {
    final report = await controls.cleanUpLibrary();
    if (report != null && context.mounted) {
      await showCleanupReport(context, app, report);
    }
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
        _engineControls(
          context,
          app,
          app.services.ytMusic,
          "$youtubeMusicName engine (ytmusicapi)",
        ),
        _sectionDivider,
        _engineControls(
          context,
          app,
          app.services.ytDlp,
          "Download engine (yt-dlp)",
        ),
        _sectionDivider,
        _group([
          _heading("Library cleanup"),
          _note(
            context,
            "Remove links to deleted tracks, then review missing audio and "
            "files that aren't in your library. Nothing is deleted until you "
            "choose.",
          ),
          _buttonRow([
            OutlinedButton.icon(
              onPressed: controls.cleaningUp ? null : cleanUpLibrary,
              icon: const Icon(Icons.cleaning_services_rounded),
              label: const Text("Clean up library"),
            ),
          ]),
        ]),
        if (app.services.lyricsEmbedder != null) ...[
          _sectionDivider,
          _group([
            _heading("Lyrics in files"),
            _note(
              context,
              "Save lyrics inside older tracks' files so they go wherever "
              "the file goes. New downloads already include them.",
            ),
            _buttonRow([
              OutlinedButton.icon(
                onPressed: controls.writingLyrics
                    ? null
                    : () => app.run(controls.writeLyricsIntoFiles),
                icon: const Icon(Icons.lyrics_rounded),
                label: Text(
                  controls.writingLyrics
                      ? "Writing lyrics…"
                      : "Write lyrics into files",
                ),
              ),
            ]),
          ]),
        ],
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Data management
// ---------------------------------------------------------------------------

/// The individual reset actions. [actionKey] is what
/// [showDataActionDialog] receives.
const _dataActions = [
  (
    actionKey: "library",
    title: "Library",
    description:
        "Remove all tracks and playlists. Downloaded audio is deleted; "
        "imported files stay on disk.",
    buttonLabel: "Clear library",
    icon: Icons.library_music_rounded,
  ),
  (
    actionKey: "playlists",
    title: "Playlists",
    description: "Delete your playlists. Library tracks are kept.",
    buttonLabel: "Clear playlists",
    icon: Icons.queue_music_rounded,
  ),
  (
    actionKey: "settings",
    title: "Settings",
    description: "Restore all settings to their defaults.",
    buttonLabel: "Reset settings",
    icon: Icons.restart_alt_rounded,
  ),
];

SettingsSection dataManagementSettings(BuildContext context, MelodyApp app) {
  final scheme = Theme.of(context).colorScheme;
  return SettingsSection(
    icon: Icons.delete_sweep_rounded,
    title: "Data management",
    subtitle: "Clear or reset local data. Every action asks first.",
    mobileTitle: "Data management",
    mobileSubtitle: "Clear or reset local data",
    destructive: true,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        if (PlatformFeatures.appDataFolder) _dataFolder(context, app),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            for (final (index, dataAction) in _dataActions.indexed) ...[
              if (index > 0) const Divider(),
              _actionRow(
                _heading(dataAction.title),
                _note(context, dataAction.description),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.error,
                  ),
                  onPressed: () =>
                      showDataActionDialog(context, app, dataAction.actionKey),
                  icon: Icon(dataAction.icon),
                  label: Text(dataAction.buttonLabel),
                ),
              ),
            ],
          ],
        ),
        _resetEverythingCard(context, app),
      ],
    ),
  );
}

Widget _resetEverythingCard(BuildContext context, MelodyApp app) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: scheme.errorContainer,
      borderRadius: BorderRadius.circular(Radii.large),
      border: Border.all(color: scheme.error),
    ),
    child: _actionRow(
      Row(
        spacing: 8,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          Expanded(
            child: Text(
              "Start over",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
      Text(
        "Clear the library and playlists, delete every downloaded and imported "
        "audio file in the library, empty the queue, and reset all settings. "
        "Download and search history are kept.",
        style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
      ),
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.error,
          foregroundColor: scheme.onError,
        ),
        onPressed: () => showDataActionDialog(context, app, "everything"),
        icon: const Icon(Icons.delete_forever_rounded),
        label: const Text("Reset everything"),
      ),
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
        _heading("App data folder"),
        SelectableText(
          folder,
          style: const TextStyle(fontSize: 12, fontFamily: "monospace"),
        ),
        _note(
          context,
          "Databases, lyrics, cookies, and caches. Close Melody before "
          "changing files here. The cache folder is safe to delete.",
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
