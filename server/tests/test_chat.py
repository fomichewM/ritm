"""B6: чат команды — WebSocket ≤ 3 с, удаление своего, лимиты, пуши закрытым."""
import time

from conftest import login


def _team2(client):
    a, b = login(client, "Миша"), login(client, "Женя")
    t = client.post("/teams", json={"name": "Друзья", "emoji": "🏃"}, headers=a).json()
    client.post("/teams/join", json={"code": t["invite_code"]}, headers=b)
    return a, b, t["id"]


def _tok(h):
    return h["Authorization"][7:]


def test_message_delivered_over_websocket_within_3s(client):
    a, b, tid = _team2(client)
    with client.websocket_connect(f"/teams/{tid}/chat?token={_tok(b)}") as ws:
        ws.send_text("ping")
        assert ws.receive_text() == "pong"
        t0 = time.monotonic()
        r = client.post(f"/teams/{tid}/messages", json={"text": "  Привет, бежим в 7?  "}, headers=a)
        assert r.status_code == 200, r.text
        got = ws.receive_json()
        dt = time.monotonic() - t0
    assert got["type"] == "message" and got["text"] == "Привет, бежим в 7?" and got["name"] == "Миша"
    assert dt < 3, dt
    print(f"WS: доставка за {dt * 1000:.0f} мс")


def test_history_and_delete_own_only(client):
    a, b, tid = _team2(client)
    m1 = client.post(f"/teams/{tid}/messages", json={"text": "раз"}, headers=a).json()
    client.post(f"/teams/{tid}/messages", json={"text": "два"}, headers=b)
    assert client.delete(f"/teams/{tid}/messages/{m1['id']}", headers=b).status_code == 404
    with client.websocket_connect(f"/teams/{tid}/chat?token={_tok(b)}") as ws:
        assert client.delete(f"/teams/{tid}/messages/{m1['id']}", headers=a).status_code == 200
        assert ws.receive_json() == {"type": "deleted", "id": m1["id"], "team_id": tid}
    items = client.get(f"/teams/{tid}/messages", headers=b).json()["items"]
    assert [(x["text"], x["deleted"], x["me"]) for x in items] == [(None, True, False), ("два", False, True)]


def test_validation_and_rate_limit(make):
    c = make(RITM_MSG_PER_MIN=3)
    a, _, tid = _team2(c)
    assert c.post(f"/teams/{tid}/messages", json={"text": "x" * 501}, headers=a).status_code == 422
    assert c.post(f"/teams/{tid}/messages", json={"text": "   "}, headers=a).status_code == 422
    assert c.post(f"/teams/{tid}/messages", json={"text": "a", "photo": "x"}, headers=a).status_code == 422
    codes = [c.post(f"/teams/{tid}/messages", json={"text": "a"}, headers=a).status_code for _ in range(4)]
    assert codes == [200, 200, 200, 429]


def test_foreign_team_closed(client):
    a, b, tid = _team2(client)
    x = login(client, "Чужой")
    assert client.get(f"/teams/{tid}/messages", headers=x).status_code == 404
    assert client.post(f"/teams/{tid}/messages", json={"text": "эй"}, headers=x).status_code == 404
    import pytest
    from starlette.websockets import WebSocketDisconnect
    with pytest.raises(WebSocketDisconnect) as e:
        with client.websocket_connect(f"/teams/{tid}/chat?token={_tok(x)}") as ws:
            ws.receive_text()
    assert e.value.code == 4404
    with pytest.raises(WebSocketDisconnect) as e:
        with client.websocket_connect(f"/teams/{tid}/chat?token=bad") as ws:
            ws.receive_text()
    assert e.value.code == 4401


def test_push_only_to_closed_chat_and_not_muted(client):
    a, b, tid = _team2(client)
    c3 = login(client, "Оля")
    code = client.get("/teams", headers=a).json()["teams"][0]["invite_code"]
    client.post("/teams/join", json={"code": code}, headers=c3)
    for h, tok in ((a, "a" * 64), (b, "b" * 64), (c3, "c" * 64)):
        assert client.put("/me/devices", json={"token": tok}, headers=h).status_code == 200
    apns = client.app.state.apns
    apns.sent.clear()
    # Женя: чат открыт → пуша нет; Оля: закрыт → пуш; автору — никогда.
    with client.websocket_connect(f"/teams/{tid}/chat?token={_tok(b)}") as ws:
        client.post(f"/teams/{tid}/messages", json={"text": "Кто на пробежку?"}, headers=a)
        ws.receive_json()
        time.sleep(.2)
    assert [p["token"] for p in apns.sent] == ["cccccc"]
    assert apns.sent[0]["title"] == "🏃 Друзья" and apns.sent[0]["body"] == "Миша: Кто на пробежку?"
    # Оля выключила пуши этой команды → ей не приходит; Женя закрыл чат → приходит.
    assert client.put(f"/teams/{tid}/mute", json={"muted": True}, headers=c3).json() == {"muted": True}
    apns.sent.clear()
    client.post(f"/teams/{tid}/messages", json={"text": "Я!"}, headers=a)
    time.sleep(.2)
    assert [p["token"] for p in apns.sent] == ["bbbbbb"]
    assert client.get(f"/teams/{tid}/messages", headers=c3).json()["muted"] is True


def test_delete_me_removes_messages_and_devices(client):
    import os

    import psycopg
    a, b, tid = _team2(client)
    client.put("/me/devices", json={"token": "d" * 64}, headers=b)
    client.post(f"/teams/{tid}/messages", json={"text": "пока"}, headers=b)
    assert client.delete("/me", headers=b).status_code == 200
    assert client.get(f"/teams/{tid}/messages", headers=a).json()["items"] == []
    with psycopg.connect(os.environ["RITM_DB_DSN"]) as db:
        assert db.execute("SELECT count(*) FROM devices").fetchone()[0] == 0


def test_join_page_russian_and_safe(client):
    r = client.get("/join?code=abc234")
    assert r.status_code == 200 and "text/html" in r.headers["content-type"]
    assert "Вас пригласили в «Ритм»" in r.text and "ABC234" in r.text
    bad = client.get('/join?code=<script>alert(1)</script>')
    assert "<script>alert" not in bad.text and "код пришлёт тот, кто пригласил" in bad.text
