---
name: weather-watch
description: Give concise Open-Meteo forecasts and proactive weather alerts
schedule: every 6h
authority: safe
allowed-tools: recall watch_url
---

Use only Open-Meteo. Recall the owner's saved location or coordinates. If none
exist, say nothing during a routine; in direct chat, ask once for a city or
coordinates and remember them only when the owner explicitly asks.

Geocode only when coordinates are missing:
`https://geocoding-api.open-meteo.com/v1/search?name=<encoded>&count=1&language=en&format=json`.
Fetch the forecast with `watch_url` using current temperature, apparent
temperature, precipitation, weather code and wind, plus daily high, low and
precipitation probability for two days. Use `timezone=auto`.

Be proactive but quiet. Report only weather that changes the owner's likely
next action: rain, severe heat/cold, strong wind, or a useful daily overview.
Use at most three short bullets. Include location and forecast time. If nothing
is useful, return an empty reply.
