import datetime as dt

import psycopg
import os

from conftest import BUNDLE, login, today
from app.main import CONSENT_VERSION

D = lambda k=0: (today() - dt.timedelta(days=k)).isoformat()  # noqa: E731


# ───────── вход Apple ─────────

def test_apple_valid(client, jwks):
    r = client.post("/auth/apple", json={"identity_token": jwks.token(), "nonce": "n" * 32, "display_name": "Миша"})
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["user"]["display_name"] == "Миша" and j["user"]["needs_consent"] is True
    # тот же Apple ID — тот же пользователь
    r2 = client.post("/auth/apple", json={"identity_token": jwks.token(), "nonce": "n" * 32})
    assert r2.json()["user"]["id"] == j["user"]["id"]
    me = client.get("/me", headers={"Authorization": "Bearer " + r2.json()["access_token"]})
    assert me.status_code == 200 and me.json()["display_name"] == "Миша"


def test_apple_expired(client, jwks):
    r = client.post("/auth/apple", json={"identity_token": jwks.token(exp_in=-3600), "nonce": "n" * 32})
    assert r.status_code == 401 and r.json()["detail"] == "token_expired"


def test_apple_foreign_aud(client, jwks):
    r = client.post("/auth/apple", json={"identity_token": jwks.token(aud="com.evil.app"), "nonce": "n" * 32})
    assert r.status_code == 401 and r.json()["detail"] == "bad_audience"


def test_apple_bad_iss_signature_nonce_kid(client, jwks):
    assert client.post("/auth/apple", json={"identity_token": jwks.token(iss="https://evil"), "nonce": "n" * 32}).status_code == 401
    r = client.post("/auth/apple", json={"identity_token": jwks.token(key=jwks.other), "nonce": "n" * 32})
    assert r.status_code == 401 and r.json()["detail"] == "bad_signature"
    r = client.post("/auth/apple", json={"identity_token": jwks.token(), "nonce": "x" * 32})
    assert r.status_code == 401 and r.json()["detail"] == "bad_nonce"
    r = client.post("/auth/apple", json={"identity_token": jwks.token(kid="nope"), "nonce": "n" * 32})
    assert r.status_code == 401
    assert client.post("/auth/apple", json={"identity_token": "garbage", "nonce": "n" * 32}).status_code == 401


def test_refresh_rotates(client, jwks):
    j = client.post("/auth/apple", json={"identity_token": jwks.token(), "nonce": "n" * 32}).json()
    r = client.post("/auth/refresh", json={"refresh_token": j["refresh_token"]})
    assert r.status_code == 200 and r.json()["refresh_token"] != j["refresh_token"]
    assert client.post("/auth/refresh", json={"refresh_token": j["refresh_token"]}).status_code == 401


def test_no_token_and_test_login_off(make):
    c = make(RITM_TEST_LOGIN="0")
    assert c.get("/me").status_code == 401
    assert c.get("/me", headers={"Authorization": "Bearer abc"}).status_code == 401
    assert c.post("/auth/test", json={"name": "x"}).status_code == 404
    assert c.get("/health").json()["test_login"] is False


# ───────── согласие ─────────

def test_consent_required_and_stored(client):
    h = login(client, consent=False)
    assert client.post("/teams", json={"name": "Бег"}, headers=h).status_code == 403
    assert client.put(f"/summary/{D()}", json={"sleep_pct": 90}, headers=h).status_code == 403
    assert client.post("/me/consent", json={"version": CONSENT_VERSION, "processing": True, "share_team": False}, headers=h).status_code == 422
    assert client.post("/me/consent", json={"version": "2020-01-01", "processing": True, "share_team": True}, headers=h).status_code == 409
    r = client.post("/me/consent", json={"version": CONSENT_VERSION, "processing": True, "share_team": True},
                    headers={**h, "X-Real-IP": "203.0.113.7"})
    assert r.status_code == 200 and r.json()["consent_version"] == CONSENT_VERSION and not r.json()["needs_consent"]
    with psycopg.connect(os.environ["RITM_DB_DSN"]) as db:
        row = db.execute("SELECT version, host(ip) FROM consents").fetchone()
    assert row == (CONSENT_VERSION, "203.0.113.7")
    assert client.post("/teams", json={"name": "Бег"}, headers=h).status_code == 200


# ───────── команды, коды, лимиты ─────────

def test_team_create_join_code(client):
    a, b = login(client, "Миша"), login(client, "Женя")
    t = client.post("/teams", json={"name": "Утренний бег", "emoji": "🏃"}, headers=a).json()
    assert len(t["invite_code"]) == 6 and t["role"] == "owner" and t["members"] == 1
    assert client.post("/teams/join", json={"code": "ZZZZZZ"}, headers=b).status_code == 404
    j = client.post("/teams/join", json={"code": t["invite_code"].lower()}, headers=b)
    assert j.status_code == 200 and j.json()["members"] == 2 and j.json()["role"] == "member"
    # повторный вход по коду не дублирует
    assert client.post("/teams/join", json={"code": t["invite_code"]}, headers=b).json()["members"] == 2
    ts = client.get("/teams", headers=b).json()["teams"]
    assert [x["name"] for x in ts] == ["Утренний бег"]


def test_team_max_50(make):
    c = make(RITM_TEAM_MAX="50")
    owner = login(c, "Владелец")
    code = c.post("/teams", json={"name": "Большая"}, headers=owner).json()["invite_code"]
    for i in range(49):
        assert c.post("/teams/join", json={"code": code}, headers=login(c, f"u{i}")).status_code == 200
    r = c.post("/teams/join", json={"code": code}, headers=login(c, "лишний"))
    assert r.status_code == 409 and r.json()["detail"] == "team_full"


def test_ten_teams_per_user(client):
    h = login(client)
    for i in range(10):
        assert client.post("/teams", json={"name": f"К{i}"}, headers=h).status_code == 200
    r = client.post("/teams", json={"name": "одиннадцатая"}, headers=h)
    assert r.status_code == 409 and r.json()["detail"] == "too_many_teams"
    other = login(client, "Другой")
    code = client.post("/teams", json={"name": "Чужая"}, headers=other).json()["invite_code"]
    assert client.post("/teams/join", json={"code": code}, headers=h).json()["detail"] == "too_many_teams"


def test_rate_limit_60_per_min(client):
    h = login(client)  # вход + согласие = 1 запрос с токеном
    codes = [client.get("/me", headers=h).status_code for _ in range(60)]
    assert codes.count(200) == 59 and codes[-1] == 429


def test_foreign_team_404(client):
    a, b = login(client, "А"), login(client, "Б")
    t = client.post("/teams", json={"name": "Своя"}, headers=a).json()
    for url in (f"/teams/{t['id']}/leaderboard", f"/teams/{t['id']}/feed", "/teams/99999/leaderboard"):
        assert client.get(url, headers=b).status_code in (403, 404)
    assert client.post(f"/teams/{t['id']}/react", json={"summary_id": 1, "item": -1, "emoji": "👍"}, headers=b).status_code == 404
    assert client.delete(f"/teams/{t['id']}/members/me", headers=b).status_code == 404


def test_leave_team_transfers_owner(client):
    a, b = login(client, "А"), login(client, "Б")
    t = client.post("/teams", json={"name": "К"}, headers=a).json()
    client.post("/teams/join", json={"code": t["invite_code"]}, headers=b)
    assert client.delete(f"/teams/{t['id']}/members/me", headers=a).status_code == 200
    assert client.get("/teams", headers=b).json()["teams"][0]["role"] == "owner"
    client.delete(f"/teams/{t['id']}/members/me", headers=b)
    assert client.get("/teams", headers=b).json()["teams"] == []


# ───────── итоги и рейтинг ─────────

def _team2(client):
    a, b = login(client, "Миша"), login(client, "Женя")
    t = client.post("/teams", json={"name": "Друзья"}, headers=a).json()
    client.post("/teams/join", json={"code": t["invite_code"]}, headers=b)
    return a, b, t["id"]


def test_summary_validation_only_aggregates(client):
    a, _, _ = _team2(client)
    ok = {"sleep_pct": 91, "recovery": 78, "strain_day": 12.44, "strain_week": 70.2,
          "workouts": [{"type": "run", "minutes": 46, "strain": 10.0}]}
    assert client.put(f"/summary/{D()}", json=ok, headers=a).status_code == 200
    for bad in ({"hr": 60}, {"rmssd": 50}, {"sleep_pct": 120}, {"strain_day": 25},
                {"workouts": [{"type": "run", "minutes": 30, "avg_hr": 150}]}):
        assert client.put(f"/summary/{D()}", json=bad, headers=a).status_code == 422, bad
    assert client.put(f"/summary/{D(40)}", json=ok, headers=a).status_code == 422


def test_leaderboard_day_week_4_metrics(client):
    a, b, tid = _team2(client)
    client.put("/me/sharing", json={"workouts": True}, headers=a)
    for k, (sa, ra, xa, wa) in enumerate([(91, 78, 12.4, 70.2), (80, 60, 10.0, 60.0)]):
        client.put(f"/summary/{D(k)}", json={"sleep_pct": sa, "recovery": ra, "strain_day": xa, "strain_week": wa}, headers=a)
    client.put(f"/summary/{D()}", json={"sleep_pct": 85, "recovery": 90, "strain_day": 8.1, "strain_week": 80.5}, headers=b)
    expect = {"strain_day": (12.4, 8.1), "sleep": (91, 85), "recovery": (78, 90), "strain_week": (70.2, 80.5)}
    for m, (va, vb) in expect.items():
        rows = client.get(f"/teams/{tid}/leaderboard", params={"metric": m, "period": "day", "date": D()}, headers=b).json()["rows"]
        byname = {r["name"]: r for r in rows}
        assert byname["Миша"]["value"] == va and byname["Женя"]["value"] == vb, (m, rows)
        assert rows[0]["place"] == 1 and rows[1]["place"] == 2 and rows[0]["value"] >= rows[1]["value"]
    # стрелка к вчера
    r = {x["name"]: x for x in client.get(f"/teams/{tid}/leaderboard", params={"metric": "strain_day", "date": D()}, headers=b).json()["rows"]}
    assert r["Миша"]["prev"] == 10.0 and r["Женя"]["prev"] is None and r["Женя"]["me"] is True
    # неделя: среднее за 7 дней
    w = {x["name"]: x for x in client.get(f"/teams/{tid}/leaderboard", params={"metric": "sleep", "period": "week", "date": D()}, headers=b).json()["rows"]}
    assert w["Миша"]["value"] == round((91 + 80) / 2) and w["Женя"]["value"] == 85
    ws = {x["name"]: x for x in client.get(f"/teams/{tid}/leaderboard", params={"metric": "strain_week", "period": "week", "date": D()}, headers=b).json()["rows"]}
    assert ws["Миша"]["value"] == 70.2
    lst = client.get("/teams", params={"metric": "recovery", "date": D()}, headers=a).json()["teams"]
    assert lst[0]["my_place"] == 2


def test_sharing_toggle_hides_metric(client):
    a, b, tid = _team2(client)
    client.put(f"/summary/{D()}", json={"sleep_pct": 91, "recovery": 78, "strain_day": 12.4}, headers=a)
    s = client.put("/me/sharing", json={"recovery": False}, headers=a).json()["sharing"]
    assert s == {"sleep": True, "recovery": False, "strain": True, "workouts": False, "photo": False}
    r = {x["name"]: x for x in client.get(f"/teams/{tid}/leaderboard", params={"metric": "recovery", "date": D()}, headers=b).json()["rows"]}
    assert r["Миша"]["value"] is None and r["Миша"]["hidden"] is True and r["Миша"]["place"] is None
    # сервер стёр значение, новое не сохраняет
    client.put(f"/summary/{D()}", json={"sleep_pct": 91, "recovery": 80, "strain_day": 12.4}, headers=a)
    with psycopg.connect(os.environ["RITM_DB_DSN"]) as db:
        assert db.execute("SELECT recovery FROM daily_summary").fetchone() == (None,)
    # другие метрики видны
    r = {x["name"]: x for x in client.get(f"/teams/{tid}/leaderboard", params={"metric": "sleep", "date": D()}, headers=b).json()["rows"]}
    assert r["Миша"]["value"] == 91
    feed = client.get(f"/teams/{tid}/feed", params={"date": D()}, headers=b).json()["items"]
    assert feed[0]["recovery"] is None and feed[0]["sleep_pct"] == 91


def test_feed_workouts_and_reactions(client):
    a, b, tid = _team2(client)
    w = [{"type": "run", "minutes": 46, "strain": 12.4, "end_ts": int(dt.datetime.now().timestamp()) - 7200}]
    client.put(f"/summary/{D()}", json={"strain_day": 13.0, "workouts": w}, headers=a)
    feed = client.get(f"/teams/{tid}/feed", params={"date": D()}, headers=b).json()["items"]
    assert all(x["kind"] != "workout" for x in feed)  # тренировки по умолчанию не публикуются
    client.put("/me/sharing", json={"workouts": True}, headers=a)
    client.put(f"/summary/{D()}", json={"strain_day": 13.0, "workouts": w}, headers=a)
    feed = client.get(f"/teams/{tid}/feed", params={"date": D()}, headers=b).json()["items"]
    wk = [x for x in feed if x["kind"] == "workout"][0]
    assert wk["name"] == "Миша" and wk["type"] == "run" and wk["minutes"] == 46 and wk["strain"] == 12.4
    body = {"summary_id": wk["summary_id"], "item": wk["item"], "emoji": "🔥"}
    assert client.post(f"/teams/{tid}/react", json=body, headers=b).json() == {"on": True}
    wk = [x for x in client.get(f"/teams/{tid}/feed", params={"date": D()}, headers=a).json()["items"] if x["kind"] == "workout"][0]
    assert wk["reactions"]["🔥"] == {"n": 1, "mine": False}
    assert client.post(f"/teams/{tid}/react", json=body, headers=b).json() == {"on": False}
    assert client.post(f"/teams/{tid}/react", json={**body, "emoji": "❤️"}, headers=b).status_code == 422


def test_delete_me_removes_row(client):
    a, b, tid = _team2(client)
    client.put(f"/summary/{D()}", json={"strain_day": 12.4}, headers=a)
    client.put(f"/summary/{D()}", json={"strain_day": 8.0}, headers=b)
    assert len(client.get(f"/teams/{tid}/leaderboard", params={"date": D()}, headers=b).json()["rows"]) == 2
    assert client.delete("/me", headers=a).json() == {"deleted": True}
    rows = client.get(f"/teams/{tid}/leaderboard", params={"date": D()}, headers=b).json()["rows"]
    assert [r["name"] for r in rows] == ["Женя"]
    assert client.get("/me", headers=a).status_code == 401
    with psycopg.connect(os.environ["RITM_DB_DSN"]) as db:
        n = {t: db.execute(f"SELECT count(*) FROM {t}").fetchone()[0] for t in ("users", "consents", "daily_summary", "refresh_tokens")}
        own = db.execute("SELECT owner_id FROM teams").fetchone()[0]
    assert n == {"users": 1, "consents": 1, "daily_summary": 1, "refresh_tokens": 1}
    assert client.get("/teams", headers=b).json()["teams"][0]["role"] == "owner" and own is not None


def test_photo_only_after_toggle(client):
    a, b, tid = _team2(client)
    jpg = b"\xff\xd8\xff\xe0" + b"0" * 100
    assert client.put("/me/photo", content=jpg, headers=a).status_code == 409
    client.put("/me/sharing", json={"photo": True}, headers=a)
    assert client.put("/me/photo", content=jpg, headers=a).status_code == 200
    me_id = client.get("/me", headers=a).json()["id"]
    assert client.get(f"/users/{me_id}/photo", headers=b).content == jpg
    stranger = login(client, "Чужой")
    assert client.get(f"/users/{me_id}/photo", headers=stranger).status_code == 404
    client.put("/me/sharing", json={"photo": False}, headers=a)
    assert client.get(f"/users/{me_id}/photo", headers=b).status_code == 404


def test_schema_has_no_vitals(client):
    bad = ("hr", "pulse", "heart", "hrv", "rmssd", "sdnn", "ecg", "stress", "bio", "age", "spo2", "rhr", "temp")
    with psycopg.connect(os.environ["RITM_DB_DSN"]) as db:
        cols = db.execute("SELECT table_name, column_name FROM information_schema.columns "
                          "WHERE table_schema='public'").fetchall()
    for t, c in cols:
        for w in bad:
            assert not (c == w or c.startswith(w + "_") or c.endswith("_" + w) or t.startswith(w)), (t, c)
