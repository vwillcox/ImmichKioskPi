"""A media_player for whatever the phone paired to the kiosk is playing.

The Pi is an A2DP sink for the phone and controls it over Bluetooth AVRCP. That
control already exists on the host in deploy/screen_control.py, which exposes it
over localhost; this wraps those endpoints as a Home Assistant entity.

A real media_player entity — rather than a switch — is what makes proper voice
control possible: Alexa's PlaybackController maps onto play/pause/next/previous,
so "next track on kiosk" works as a phrase instead of turning on a fake switch.
It also gives working transport controls on dashboards and in the app.
"""

from __future__ import annotations

import logging
from datetime import timedelta

import voluptuous as vol

from homeassistant.components.media_player import (
    PLATFORM_SCHEMA as MEDIA_PLAYER_PLATFORM_SCHEMA,
    MediaPlayerDeviceClass,
    MediaPlayerEntity,
    MediaPlayerEntityFeature,
    MediaPlayerState,
)
from homeassistant.const import CONF_NAME, CONF_URL
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.util import dt as dt_util

_LOGGER = logging.getLogger(__name__)

# The phone reports progress continuously; polling faster than this gains
# nothing and just makes work for the Pi.
SCAN_INTERVAL = timedelta(seconds=10)

DEFAULT_URL = "http://127.0.0.1:8765"

PLATFORM_SCHEMA = MEDIA_PLAYER_PLATFORM_SCHEMA.extend(
    {
        vol.Optional(CONF_NAME, default="Kiosk"): cv.string,
        vol.Optional(CONF_URL, default=DEFAULT_URL): cv.string,
    }
)


async def async_setup_platform(hass, config, async_add_entities, discovery_info=None):
    async_add_entities(
        [KioskMediaPlayer(hass, config[CONF_NAME], config[CONF_URL].rstrip("/"))],
        update_before_add=True,
    )


class KioskMediaPlayer(MediaPlayerEntity):
    _attr_device_class = MediaPlayerDeviceClass.SPEAKER
    _attr_should_poll = True
    # Each group unlocks a different set of voice commands: transport gives
    # "next"/"pause", turn on/off gives "turn off <name>", and volume gives
    # "set <name> to 4" / "turn it up".
    _attr_supported_features = (
        MediaPlayerEntityFeature.PLAY
        | MediaPlayerEntityFeature.PAUSE
        | MediaPlayerEntityFeature.STOP
        | MediaPlayerEntityFeature.NEXT_TRACK
        | MediaPlayerEntityFeature.PREVIOUS_TRACK
        | MediaPlayerEntityFeature.TURN_ON
        | MediaPlayerEntityFeature.TURN_OFF
        | MediaPlayerEntityFeature.VOLUME_SET
        | MediaPlayerEntityFeature.VOLUME_STEP
    )

    def __init__(self, hass, name, url):
        self.hass = hass
        self._attr_name = name
        self._attr_unique_id = f"kiosk_media_{url}"
        self._url = url
        self._data: dict = {}
        self._position_at = None

    @property
    def state(self):
        # Nothing paired is "off" rather than "idle": there is no player at all,
        # not a player sitting idle.
        if not self._data.get("connected"):
            return MediaPlayerState.OFF
        status = self._data.get("status")
        if status == "playing":
            return MediaPlayerState.PLAYING
        if status == "paused":
            return MediaPlayerState.PAUSED
        return MediaPlayerState.IDLE

    @property
    def media_title(self):
        return self._data.get("title")

    @property
    def media_artist(self):
        return self._data.get("artist")

    @property
    def media_album_name(self):
        return self._data.get("album")

    @property
    def media_duration(self):
        return _ms_to_s(self._data.get("duration"))

    @property
    def media_position(self):
        return _ms_to_s(self._data.get("position"))

    @property
    def media_position_updated_at(self):
        return self._position_at

    @property
    def volume_level(self):
        # None while paused — AVRCP volume lives on the streaming transport,
        # which BlueZ only creates while audio is actually flowing.
        v = self._data.get("volume")
        return v / 100 if isinstance(v, (int, float)) else None

    async def _request(self, path):
        session = async_get_clientsession(self.hass)
        try:
            async with session.get(f"{self._url}{path}", timeout=10) as r:
                return await r.json(content_type=None)
        except Exception as err:  # noqa: BLE001 - a dead endpoint shouldn't raise
            _LOGGER.debug("kiosk media request %s failed: %s", path, err)
            return None

    async def async_update(self):
        data = await self._request("/media")
        if data is None:
            # Keep the last known track rather than flapping to unknown on one
            # missed poll, but stop claiming it is connected.
            self._data = {**self._data, "connected": False}
            return
        self._data = data
        self._position_at = dt_util.utcnow()

    async def _command(self, action):
        data = await self._request(f"/media/{action}")
        if data is not None:
            self._data = data
            self._position_at = dt_util.utcnow()
        self.async_write_ha_state()

    async def async_media_play(self):
        await self._command("play")

    async def async_media_pause(self):
        await self._command("pause")

    async def async_media_stop(self):
        await self._command("stop")

    async def async_media_next_track(self):
        await self._command("next")

    async def async_media_previous_track(self):
        await self._command("previous")

    # "Turn off" is the natural way to ask for silence out loud, so map it onto
    # pause rather than leaving it unsupported.
    async def async_turn_on(self):
        await self._command("play")

    async def async_turn_off(self):
        await self._command("pause")

    async def async_set_volume_level(self, volume):
        await self._command(f"volume?value={round(volume * 100)}")

    async def async_volume_up(self):
        await self._step_volume(+10)

    async def async_volume_down(self):
        await self._step_volume(-10)

    async def _step_volume(self, delta):
        current = self._data.get("volume")
        if current is None:
            _LOGGER.debug("no active stream; cannot step volume")
            return
        await self._command(f"volume?value={max(0, min(100, current + delta))}")


def _ms_to_s(value):
    """AVRCP reports milliseconds; Home Assistant wants seconds."""
    return round(value / 1000) if isinstance(value, (int, float)) else None
