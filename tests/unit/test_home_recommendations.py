from __future__ import annotations

import unittest
from types import SimpleNamespace
from typing import cast
from unittest.mock import Mock, patch

from musicplayer.app import MusicPlayerApp
from musicplayer.application.models import SearchResult
from musicplayer.application.providers import ProviderError
from musicplayer.ui.pages.home import HomePage


def result(number: int) -> SearchResult:
    return SearchResult(
        id=f"video{number}",
        title=f"Track {number}",
        uploader="Artist",
        duration=0,
        thumbnail="",
        url=f"https://music.youtube.com/watch?v=video{number}",
        source="YouTube Music",
    )


class HomeRecommendationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.app = SimpleNamespace(
            manager=SimpleNamespace(find_track_by_source=Mock(return_value=None)),
            providers=SimpleNamespace(recommendations=Mock()),
            store=SimpleNamespace(
                get=Mock(return_value=["one", "two"]),
                favorite_track_ids=Mock(return_value=frozenset()),
            ),
            playback=SimpleNamespace(current_track_id="one"),
            tasks=object(),
            selected_navigation=1,
        )
        self.app.manager.get_track = Mock(
            side_effect=lambda track_id: SimpleNamespace(
                source=f"https://music.youtube.com/watch?v={track_id}123"
            )
        )
        self.home = HomePage(cast(MusicPlayerApp, self.app))

    def test_refresh_rotates_lead_seed_and_keeps_it_on_render(self) -> None:
        with patch("musicplayer.ui.pages.home.run_io", return_value=True) as submit:
            self.home._ensure_recommendations()
            first = self.home._recommendation_seed_urls[0]
            self.home._ensure_recommendations()
            self.assertEqual(submit.call_count, 1)
            self.home._reload_recommendations()
            self.assertNotEqual(self.home._recommendation_seed_urls[0], first)
            self.home._ensure_recommendations()
            self.assertEqual(submit.call_count, 2)

    def test_results_are_deduplicated_shuffled_and_paged(self) -> None:
        items = [result(index) for index in range(19)]
        self.app.providers.recommendations.return_value = items + [items[1]]
        with patch("musicplayer.ui.pages.home.random.shuffle") as shuffle:
            fetched = self.home._fetch_recommendations(("seed-a", "seed-b"))
        self.assertEqual(len(fetched), 19)
        self.assertEqual(self.app.providers.recommendations.call_count, 4)
        shuffle.assert_called_once_with(fetched)
        self.home.recommendations = fetched
        self.assertEqual(len(self.home._visible_recommendations()), 8)
        self.home._change_recommendation_page(1)
        self.assertEqual(self.home._visible_recommendations(), fetched[8:16])
        self.home._change_recommendation_page(1)
        self.assertEqual(self.home._visible_recommendations(), fetched[16:])
        self.home._change_recommendation_page(1)
        self.assertEqual(self.home.recommendation_page, 2)
        self.assertIsNotNone(self.home._recommendation_navigation())

    def test_one_failed_radio_mix_keeps_results_from_the_other(self) -> None:
        self.app.providers.recommendations.side_effect = [
            ProviderError("Unavailable"),
            [result(1), result(2)],
            [result(1), result(2)],
        ]
        self.assertEqual(len(self.home._fetch_recommendations(("seed-a", "seed-b"))), 2)

    def test_duplicate_heavy_mixes_fetch_larger_batches(self) -> None:
        self.app.providers.recommendations.side_effect = [
            [result(index) for index in range(24)],
            [result(index) for index in range(24)],
            [result(index) for index in range(48)],
        ]
        self.app.manager.find_track_by_source.side_effect = lambda url: (
            object() if url.endswith("video0") else None
        )

        fetched = self.home._fetch_recommendations(("seed-a", "seed-b"))

        self.assertEqual(len(fetched), 47)
        self.assertEqual(
            [
                call.kwargs["limit"]
                for call in self.app.providers.recommendations.call_args_list
            ],
            [24, 24, 48],
        )

    def test_short_mixes_get_one_larger_probe_then_stop(self) -> None:
        self.app.providers.recommendations.return_value = [result(1)]
        self.home._fetch_recommendations(("seed-a", "seed-b"))
        self.assertEqual(
            [
                call.kwargs["limit"]
                for call in self.app.providers.recommendations.call_args_list
            ],
            [24, 24, 48, 48],
        )

    def test_short_first_batch_can_find_more_on_larger_fetch(self) -> None:
        self.app.providers.recommendations.side_effect = [
            [result(index) for index in range(10)],
            [result(index) for index in range(40)],
        ]
        fetched = self.home._fetch_recommendations(("seed-a",))
        self.assertEqual(len(fetched), 40)
        self.assertEqual(self.app.providers.recommendations.call_count, 2)

    def test_stale_request_cannot_replace_refreshed_results(self) -> None:
        self.home._recommendation_request = 2
        self.home.recommendations = [result(1)]
        self.home._finish_recommendations(1, [result(2)])
        self.assertEqual(self.home.recommendations, [result(1)])


if __name__ == "__main__":
    unittest.main()
