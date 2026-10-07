import "package:flutter/material.dart";

class NavigationDestinationInfo {
  const NavigationDestinationInfo(this.label, this.selectedIcon, this.icon);

  final String label;
  final IconData selectedIcon;
  final IconData icon;
}

const navigationDestinations = [
  NavigationDestinationInfo("Home", Icons.home_rounded, Icons.home_outlined),
  NavigationDestinationInfo(
    "Search",
    Icons.search_rounded,
    Icons.search_rounded,
  ),
  NavigationDestinationInfo(
    "Library",
    Icons.library_music_rounded,
    Icons.library_music_outlined,
  ),
  NavigationDestinationInfo(
    "Playlists",
    Icons.album_rounded,
    Icons.album_outlined,
  ),
];
