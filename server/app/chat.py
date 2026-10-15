"""«Ритм» B6 — чат команды: рассылка по WebSocket (один процесс, без Redis)
и пуши APNs тем, у кого чат закрыт.

APNs — token-based (.p8). Ключ лежит только на сервере: RITM_APNS_KEY_PATH,
RITM_APNS_KEY_ID, RITM_APNS_TEAM_ID (+ RITM_BUNDLE_ID). Без ключа пуши не
уходят, но записываются в журнал (`sent`) — так их проверяют тесты.
"""
from __future__ import annotations

import asyncio
import collections
import os
import time

import jwt


class Hub:
    """Открытые чаты: команда → набор (user_id, websocket)."""

    def __init__(self) -> None:
        self.rooms: dict[int, set] = collections.defaultdict(set)

    def join(self, tid: int, uid: int, ws) -> None:
        self.rooms[tid].add((uid, ws))

    def leave(self, tid: int, uid: int, ws) -> None:
        self.rooms[tid].discard((uid, ws))
        if not self.rooms[tid]:
            self.rooms.pop(tid, None)

    def online(self, tid: int) -> set[int]:
        return {u for u, _ in self.rooms.get(tid, ())}

    async def publish(self, tid: int, payload: dict) -> int:
        n = 0
        for uid, ws in list(self.rooms.get(tid, ())):
            try:
                await ws.send_json(payload)
                n += 1
            except Exception:
                self.rooms[tid].discard((uid, ws))
        return n


class Apns:
    """Отправка пушей. Без ключа — только журнал."""

    def __init__(self, bundle: str) -> None:
        self.bundle = bundle
        self.key_path = os.environ.get("RITM_APNS_KEY_PATH", "")
        self.key_id = os.environ.get("RITM_APNS_KEY_ID", "")
        self.team_id = os.environ.get("RITM_APNS_TEAM_ID", "")
        self.sent: collections.deque = collections.deque(maxlen=200)
        self._jwt: tuple[float, str] | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.key_path and self.key_id and self.team_id and os.path.exists(self.key_path))

    def _token(self) -> str:
        now = time.time()
        if self._jwt and now - self._jwt[0] < 40 * 60:  # Apple: обновлять не чаще 20 мин, не реже 60
            return self._jwt[1]
        key = open(self.key_path).read()
        t = jwt.encode({"iss": self.team_id, "iat": int(now)}, key, algorithm="ES256",
                       headers={"kid": self.key_id})
        self._jwt = (now, t)
        return t

    async def send(self, devices: list[dict], title: str, body: str, data: dict) -> int:
        payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default",
                           "thread-id": f"team-{data.get('team_id')}"}, **data}
        for d in devices:
            self.sent.append({"token": d["token"][-6:], "title": title, "body": body, **data})
        if not self.enabled or not devices:
            return 0
        import httpx  # http2 — пакет h2
        ok = 0
        async with httpx.AsyncClient(http2=True, timeout=10) as cl:
            for d in devices:
                host = "api.sandbox.push.apple.com" if d["sandbox"] else "api.push.apple.com"
                r = await cl.post(f"https://{host}/3/device/{d['token']}", json=payload, headers={
                    "authorization": "bearer " + self._token(), "apns-topic": self.bundle,
                    "apns-push-type": "alert", "apns-priority": "10"})
                ok += r.status_code == 200
        return ok


def preview(text: str, n: int = 120) -> str:
    t = " ".join(text.split())
    return t if len(t) <= n else t[: n - 1] + "…"


async def later(coro) -> None:
    """Пуш не задерживает ответ отправителю."""
    asyncio.get_running_loop().create_task(coro)
