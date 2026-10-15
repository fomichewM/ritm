"""«Ритм» — сервер сообщества (ТЗ v2 §7, сборка B5; чат/пуши — B6).

FastAPI + PostgreSQL. Вход — Sign in with Apple (identityToken проверяется по
JWKS Apple), дальше свой JWT на 30 дней + refresh. На сервере только агрегаты
дня (сон %, восстановление %, нагрузка дня/недели, тренировки).

Настройки — переменные окружения (файл /opt/ritm-api/.env, права 600):
  RITM_DB_DSN, RITM_JWT_SECRET, RITM_BUNDLE_ID, RITM_TEST_LOGIN (0/1),
  RITM_RATE_PER_MIN (60), RITM_TEAM_MAX (50), RITM_TEAMS_PER_USER (10).
"""

import base64
import collections
import datetime as dt
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import secrets
import threading
import time
import zoneinfo
from contextlib import asynccontextmanager
from typing import Annotated, Literal

import httpx
import jwt
import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.chat import Apns, Hub, later, preview

# ───────────────────────── настройки ─────────────────────────

def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


APPLE_ISS = "https://appleid.apple.com"
APPLE_JWKS_URL = _env("RITM_APPLE_JWKS_URL", "https://appleid.apple.com/auth/keys")
CONSENT_VERSION = "2026-10-16"
ACCESS_TTL = dt.timedelta(days=30)
REFRESH_TTL = dt.timedelta(days=90)
TZ = zoneinfo.ZoneInfo("Europe/Moscow")
METRICS = {  # метрика → (столбец, переключатель публикации)
    "strain_day": ("strain_day", "share_strain"),
    "sleep": ("sleep_pct", "share_sleep"),
    "recovery": ("recovery", "share_recovery"),
    "strain_week": ("strain_week", "share_strain"),
}
WORKOUT_TYPES = {
    "run", "walk", "cycling", "strength", "swim", "yoga", "hiit", "cardio",
    "sport", "hike", "row", "ski", "dance", "stretch", "other",
}
EMOJIS = ("👍", "🔥", "💪")
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


class Settings:
    def __init__(self) -> None:
        self.dsn = _env("RITM_DB_DSN", "postgresql:///ritm")
        self.secret = _env("RITM_JWT_SECRET")
        self.bundle = _env("RITM_BUNDLE_ID", "com.oporagroup.ritm")
        self.test_login = _env("RITM_TEST_LOGIN", "0") == "1"
        self.rate = int(_env("RITM_RATE_PER_MIN", "60"))
        self.team_max = int(_env("RITM_TEAM_MAX", "50"))
        self.teams_per_user = int(_env("RITM_TEAMS_PER_USER", "10"))
        self.auth_rate = int(_env("RITM_AUTH_PER_MIN", "20"))
        self.msg_rate = int(_env("RITM_MSG_PER_MIN", "60"))
        if len(self.secret) < 32:
            raise RuntimeError("RITM_JWT_SECRET не задан или короче 32 символов")


# ───────────────────────── JWKS Apple ─────────────────────────

class AppleJWKS:
    """Ключи Apple с кэшем на час; неизвестный kid — одно обновление."""

    def __init__(self, url: str = APPLE_JWKS_URL) -> None:
        self.url = url
        self._keys: dict[str, jwt.PyJWK] = {}
        self._at = 0.0
        self._lock = threading.Lock()

    def _load(self) -> None:
        r = httpx.get(self.url, timeout=10)
        r.raise_for_status()
        self._keys = {k["kid"]: jwt.PyJWK(k) for k in r.json()["keys"]}
        self._at = time.time()

    def key(self, kid: str) -> jwt.PyJWK | None:
        with self._lock:
            if not self._keys or time.time() - self._at > 3600 or kid not in self._keys:
                if kid in self._keys and time.time() - self._at < 60:
                    return self._keys[kid]
                try:
                    self._load()
                except Exception:
                    if not self._keys:
                        raise HTTPException(503, "apple_keys_unavailable")
            return self._keys.get(kid)


def verify_apple_token(token: str, raw_nonce: str, jwks, bundle: str) -> dict:
    """Проверка identityToken: подпись (JWKS), aud, iss, exp, nonce."""
    try:
        kid = jwt.get_unverified_header(token).get("kid", "")
    except jwt.PyJWTError:
        raise HTTPException(401, "bad_token")
    key = jwks.key(kid)
    if key is None:
        raise HTTPException(401, "unknown_key")
    try:
        claims = jwt.decode(
            token, key.key, algorithms=["RS256"], audience=bundle, issuer=APPLE_ISS,
            options={"require": ["exp", "iat", "sub", "aud", "iss"]}, leeway=30,
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "token_expired")
    except jwt.InvalidAudienceError:
        raise HTTPException(401, "bad_audience")
    except jwt.InvalidIssuerError:
        raise HTTPException(401, "bad_issuer")
    except jwt.PyJWTError:
        raise HTTPException(401, "bad_signature")
    # Клиент передаёт Apple SHA-256 от одноразовой строки, серверу — саму строку.
    want = hashlib.sha256(raw_nonce.encode()).hexdigest()
    if not raw_nonce or claims.get("nonce") not in (want,):
        raise HTTPException(401, "bad_nonce")
    return claims


# ───────────────────────── лимит запросов ─────────────────────────

class RateLimiter:
    def __init__(self) -> None:
        self._hits: dict[str, collections.deque] = collections.defaultdict(collections.deque)
        self._lock = threading.Lock()

    def hit(self, key: str, limit: int, window: float = 60.0) -> bool:
        now = time.monotonic()
        with self._lock:
            q = self._hits[key]
            while q and now - q[0] > window:
                q.popleft()
            if len(q) >= limit:
                return False
            q.append(now)
            return True

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()


# ───────────────────────── входные модели ─────────────────────────

class AppleIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    identity_token: str = Field(max_length=8000)
    nonce: str = Field(min_length=16, max_length=128)
    display_name: str | None = Field(None, max_length=40)


class TestIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=40)


class RefreshIn(BaseModel):
    refresh_token: str = Field(max_length=200)


class MeIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    display_name: str | None = Field(None, min_length=1, max_length=40)
    avatar_emoji: str | None = Field(None, max_length=8)


class ConsentIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    version: str = Field(max_length=20)
    processing: bool
    share_team: bool


class SharingIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    sleep: bool | None = None
    recovery: bool | None = None
    strain: bool | None = None
    workouts: bool | None = None
    photo: bool | None = None


class WorkoutIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    type: str
    minutes: int = Field(ge=1, le=1440)
    strain: float | None = Field(None, ge=0, le=21)
    end_ts: int | None = Field(None, ge=1_600_000_000, le=4_000_000_000)

    @field_validator("type")
    @classmethod
    def _t(cls, v: str) -> str:
        return v if v in WORKOUT_TYPES else "other"


class SummaryIn(BaseModel):
    # extra="forbid": пульс, ВСР и прочее сервер не примет даже по ошибке.
    model_config = ConfigDict(extra="forbid")
    sleep_pct: int | None = Field(None, ge=0, le=100)
    recovery: int | None = Field(None, ge=0, le=100)
    strain_day: float | None = Field(None, ge=0, le=21)
    strain_week: float | None = Field(None, ge=0, le=200)
    workouts: list[WorkoutIn] = Field(default_factory=list, max_length=20)


class TeamIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=40)
    emoji: str = Field("🏃", min_length=1, max_length=8)


class JoinIn(BaseModel):
    code: str = Field(min_length=4, max_length=12)


class ReactIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    summary_id: int
    item: int = Field(ge=-1, le=19)
    emoji: Literal["👍", "🔥", "💪"]


# ───────────────────────── приложение ─────────────────────────

class MessageIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1, max_length=500)

    @field_validator("text")
    @classmethod
    def _strip(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("empty")
        return v


class DeviceIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    token: str = Field(pattern=r"^[0-9a-fA-F]{32,200}$")
    sandbox: bool = False


class MuteIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    muted: bool


def create_app(settings: Settings | None = None, jwks=None) -> FastAPI:
    s = settings or Settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.pool.open(wait=True)
        with app.state.pool.connection() as c:
            c.execute(pathlib.Path(__file__).with_name("schema.sql").read_text())
        yield
        app.state.pool.close()

    app = FastAPI(title="ritm", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.s = s
    app.state.jwks = jwks or AppleJWKS()
    app.state.rl = RateLimiter()
    app.state.hub = Hub()
    app.state.apns = Apns(s.bundle)
    app.state.pool = ConnectionPool(s.dsn, min_size=1, max_size=5, open=False,
                                    kwargs={"row_factory": dict_row, "autocommit": False})

    def db():
        with app.state.pool.connection() as c:
            yield c

    DB = Annotated[psycopg.Connection, Depends(db)]

    def client_ip(req: Request) -> str | None:
        ip = req.headers.get("x-real-ip") or (req.headers.get("x-forwarded-for") or "").split(",")[0].strip()
        ip = ip or (req.client.host if req.client else "")
        try:
            return str(ipaddress.ip_address(ip))
        except ValueError:
            return None

    # ── токены ──
    def issue(c: psycopg.Connection, uid: int) -> dict:
        now = dt.datetime.now(dt.UTC)
        access = jwt.encode({"sub": str(uid), "typ": "access", "iat": now, "exp": now + ACCESS_TTL},
                            s.secret, algorithm="HS256")
        refresh = secrets.token_urlsafe(32)
        c.execute("INSERT INTO refresh_tokens(token_hash,user_id,expires_at) VALUES(%s,%s,%s)",
                  (hashlib.sha256(refresh.encode()).hexdigest(), uid, now + REFRESH_TTL))
        c.execute("DELETE FROM refresh_tokens WHERE user_id=%s AND expires_at<now()", (uid,))
        return {"access_token": access, "refresh_token": refresh,
                "expires_in": int(ACCESS_TTL.total_seconds())}

    def current_user(c: DB, authorization: Annotated[str | None, Header()] = None) -> dict:
        if not authorization or not authorization.lower().startswith("bearer "):
            raise HTTPException(401, "no_token")
        try:
            claims = jwt.decode(authorization[7:], s.secret, algorithms=["HS256"],
                                options={"require": ["exp", "sub"]})
        except jwt.PyJWTError:
            raise HTTPException(401, "bad_token")
        if claims.get("typ") != "access":
            raise HTTPException(401, "bad_token")
        u = c.execute("SELECT * FROM users WHERE id=%s", (int(claims["sub"]),)).fetchone()
        if u is None:
            raise HTTPException(401, "no_user")
        if not app.state.rl.hit(f"u{u['id']}", s.rate):
            raise HTTPException(429, "rate_limited")
        return u

    User = Annotated[dict, Depends(current_user)]

    def latest_consent(c, uid):
        return c.execute("SELECT version, accepted_at FROM consents WHERE user_id=%s "
                         "AND processing AND share_team ORDER BY id DESC LIMIT 1", (uid,)).fetchone()

    def consented(c: DB, u: User) -> dict:
        lc = latest_consent(c, u["id"])
        if lc is None or lc["version"] != CONSENT_VERSION:
            raise HTTPException(403, "consent_required")
        return u

    Member = Annotated[dict, Depends(consented)]

    def me_json(c, u) -> dict:
        lc = latest_consent(c, u["id"])
        has_photo = c.execute("SELECT 1 FROM avatars WHERE user_id=%s", (u["id"],)).fetchone() is not None
        return {
            "id": u["id"], "display_name": u["display_name"], "avatar_emoji": u["avatar_emoji"],
            "has_photo": has_photo,
            "sharing": {"sleep": u["share_sleep"], "recovery": u["share_recovery"],
                        "strain": u["share_strain"], "workouts": u["share_workouts"],
                        "photo": u["share_photo"]},
            "consent_version": lc["version"] if lc else None,
            "consent_required": CONSENT_VERSION,
            "needs_consent": lc is None or lc["version"] != CONSENT_VERSION,
        }

    # ── служебное ──
    @app.get("/health")
    def health(c: DB):
        c.execute("SELECT 1")
        return {"status": "ok", "db": "ok", "test_login": s.test_login}

    @app.exception_handler(psycopg.errors.CheckViolation)
    async def _check(_req, _exc):
        return JSONResponse({"detail": "bad_value"}, status_code=422)

    # ── вход ──

    def login_sub(c, sub: str, name: str | None) -> dict:
        u = c.execute("SELECT * FROM users WHERE apple_sub=%s", (sub,)).fetchone()
        if u is None:
            u = c.execute("INSERT INTO users(apple_sub, display_name) VALUES(%s,%s) RETURNING *",
                          (sub, (name or "").strip()[:40])).fetchone()
        elif name and not u["display_name"]:
            u = c.execute("UPDATE users SET display_name=%s WHERE id=%s RETURNING *",
                          (name.strip()[:40], u["id"])).fetchone()
        out = issue(c, u["id"])
        out["user"] = me_json(c, u)
        c.commit()
        return out

    @app.post("/auth/apple")
    def auth_apple(body: AppleIn, req: Request, c: DB):
        if not app.state.rl.hit(f"ip{client_ip(req)}", s.auth_rate):
            raise HTTPException(429, "rate_limited")
        claims = verify_apple_token(body.identity_token, body.nonce, app.state.jwks, s.bundle)
        return login_sub(c, "apple:" + claims["sub"], body.display_name)


    @app.post("/auth/test")
    def auth_test(body: TestIn, req: Request, c: DB):
        # Только для e2e: в проде выключено (RITM_TEST_LOGIN=0) → 404.
        if not s.test_login:
            raise HTTPException(404, "Not Found")
        if not app.state.rl.hit(f"ip{client_ip(req)}", s.auth_rate):
            raise HTTPException(429, "rate_limited")
        return login_sub(c, "test:" + secrets.token_hex(8), body.name)


    @app.post("/auth/refresh")
    def auth_refresh(body: RefreshIn, c: DB):
        h = hashlib.sha256(body.refresh_token.encode()).hexdigest()
        row = c.execute("DELETE FROM refresh_tokens WHERE token_hash=%s RETURNING user_id, expires_at",
                        (h,)).fetchone()
        if row is None or row["expires_at"] < dt.datetime.now(dt.UTC):
            c.commit()
            raise HTTPException(401, "bad_refresh")
        out = issue(c, row["user_id"])
        c.commit()
        return out

    # ── профиль ──
    @app.get("/me")
    def get_me(u: User, c: DB):
        return me_json(c, u)


    @app.put("/me")
    def put_me(body: MeIn, u: User, c: DB):
        u = c.execute("UPDATE users SET display_name=COALESCE(%s,display_name), "
                      "avatar_emoji=COALESCE(%s,avatar_emoji) WHERE id=%s RETURNING *",
                      (body.display_name.strip() if body.display_name else None,
                       body.avatar_emoji, u["id"])).fetchone()
        c.commit()
        return me_json(c, u)


    @app.post("/me/consent")
    def post_consent(body: ConsentIn, u: User, c: DB, req: Request):
        if body.version != CONSENT_VERSION:
            raise HTTPException(409, "consent_version_outdated")
        if not (body.processing and body.share_team):
            raise HTTPException(422, "both_checkboxes_required")
        c.execute("INSERT INTO consents(user_id,version,processing,share_team,ip) VALUES(%s,%s,%s,%s,%s)",
                  (u["id"], body.version, True, True, client_ip(req)))
        c.commit()
        return me_json(c, u)


    @app.put("/me/sharing")
    def put_sharing(body: SharingIn, u: User, c: DB):
        u = c.execute(
            "UPDATE users SET share_sleep=COALESCE(%s,share_sleep), share_recovery=COALESCE(%s,share_recovery),"
            " share_strain=COALESCE(%s,share_strain), share_workouts=COALESCE(%s,share_workouts),"
            " share_photo=COALESCE(%s,share_photo) WHERE id=%s RETURNING *",
            (body.sleep, body.recovery, body.strain, body.workouts, body.photo, u["id"])).fetchone()
        # Выключенное не хранится: стираем уже присланные значения.
        if not u["share_sleep"]:
            c.execute("UPDATE daily_summary SET sleep_pct=NULL WHERE user_id=%s", (u["id"],))
        if not u["share_recovery"]:
            c.execute("UPDATE daily_summary SET recovery=NULL WHERE user_id=%s", (u["id"],))
        if not u["share_strain"]:
            c.execute("UPDATE daily_summary SET strain_day=NULL, strain_week=NULL WHERE user_id=%s", (u["id"],))
        if not u["share_workouts"]:
            c.execute("UPDATE daily_summary SET workouts_json='[]' WHERE user_id=%s", (u["id"],))
        if not u["share_photo"]:
            c.execute("DELETE FROM avatars WHERE user_id=%s", (u["id"],))
        c.commit()
        return me_json(c, u)

    @app.put("/me/photo")
    async def put_photo(req: Request, u: User, c: DB):
        if not u["share_photo"]:
            raise HTTPException(409, "photo_sharing_off")
        data = await req.body()
        if len(data) > 256 * 1024 or not data.startswith(b"\xff\xd8"):
            raise HTTPException(422, "jpeg_up_to_256kb")
        c.execute("INSERT INTO avatars(user_id,jpeg) VALUES(%s,%s) ON CONFLICT(user_id) "
                  "DO UPDATE SET jpeg=EXCLUDED.jpeg, updated_at=now()", (u["id"], data))
        c.commit()
        return {"ok": True}

    @app.get("/users/{uid}/photo")
    def get_photo(uid: int, u: User, c: DB):
        row = c.execute(
            "SELECT a.jpeg FROM avatars a JOIN users x ON x.id=a.user_id AND x.share_photo "
            "WHERE a.user_id=%s AND (a.user_id=%s OR EXISTS (SELECT 1 FROM team_members m1 "
            "JOIN team_members m2 ON m1.team_id=m2.team_id WHERE m1.user_id=%s AND m2.user_id=a.user_id))",
            (uid, u["id"], u["id"])).fetchone()
        if row is None:
            raise HTTPException(404, "Not Found")
        return Response(bytes(row["jpeg"]), media_type="image/jpeg",
                        headers={"Cache-Control": "private, max-age=3600"})

    @app.delete("/me")
    def delete_me(u: User, c: DB):
        uid = u["id"]
        # Команды, где пользователь владелец: владельцем становится самый
        # давний участник; пустая команда удаляется.
        for t in c.execute("SELECT team_id FROM team_members WHERE user_id=%s AND role='owner'", (uid,)).fetchall():
            nxt = c.execute("SELECT user_id FROM team_members WHERE team_id=%s AND user_id<>%s "
                            "ORDER BY joined_at, user_id LIMIT 1", (t["team_id"], uid)).fetchone()
            if nxt:
                c.execute("UPDATE team_members SET role='owner' WHERE team_id=%s AND user_id=%s",
                          (t["team_id"], nxt["user_id"]))
                c.execute("UPDATE teams SET owner_id=%s WHERE id=%s", (nxt["user_id"], t["team_id"]))
            else:
                c.execute("DELETE FROM teams WHERE id=%s", (t["team_id"],))
        # Полное удаление: каскадом уходят итоги, реакции, согласия, токены, фото.
        c.execute("DELETE FROM users WHERE id=%s", (uid,))
        c.commit()
        return {"deleted": True}

    # ── итоги дня ──


    @app.put("/summary/{day}")
    def put_summary(day: dt.date, body: SummaryIn, u: Member, c: DB):
        today = dt.datetime.now(TZ).date()
        if not (today - dt.timedelta(days=30) <= day <= today + dt.timedelta(days=1)):
            raise HTTPException(422, "date_out_of_range")
        w = [x.model_dump(exclude_none=True) for x in body.workouts] if u["share_workouts"] else []
        c.execute(
            "INSERT INTO daily_summary(user_id,date,sleep_pct,recovery,strain_day,strain_week,workouts_json,updated_at)"
            " VALUES(%s,%s,%s,%s,%s,%s,%s,now()) ON CONFLICT(user_id,date) DO UPDATE SET"
            " sleep_pct=EXCLUDED.sleep_pct, recovery=EXCLUDED.recovery, strain_day=EXCLUDED.strain_day,"
            " strain_week=EXCLUDED.strain_week, workouts_json=EXCLUDED.workouts_json, updated_at=now()",
            (u["id"], day,
             body.sleep_pct if u["share_sleep"] else None,
             body.recovery if u["share_recovery"] else None,
             round(body.strain_day, 1) if u["share_strain"] and body.strain_day is not None else None,
             round(body.strain_week, 1) if u["share_strain"] and body.strain_week is not None else None,
             json.dumps(w)))
        c.commit()
        return {"ok": True, "date": day.isoformat()}

    # ── команды ──


    def check_team_quota(c, uid):
        n = c.execute("SELECT count(*) AS n FROM team_members WHERE user_id=%s", (uid,)).fetchone()["n"]
        if n >= s.teams_per_user:
            raise HTTPException(409, "too_many_teams")

    def team_json(c, t, uid) -> dict:
        n = c.execute("SELECT count(*) AS n FROM team_members WHERE team_id=%s", (t["id"],)).fetchone()["n"]
        role = c.execute("SELECT role FROM team_members WHERE team_id=%s AND user_id=%s",
                         (t["id"], uid)).fetchone()
        return {"id": t["id"], "name": t["name"], "emoji": t["emoji"], "invite_code": t["invite_code"],
                "members": n, "role": role["role"] if role else None}

    @app.post("/teams")
    def create_team(body: TeamIn, u: Member, c: DB):
        check_team_quota(c, u["id"])
        for _ in range(10):
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(6))
            try:
                with c.transaction():
                    t = c.execute("INSERT INTO teams(name,emoji,owner_id,invite_code) VALUES(%s,%s,%s,%s) RETURNING *",
                                  (body.name.strip(), body.emoji, u["id"], code)).fetchone()
                break
            except psycopg.errors.UniqueViolation:
                continue
        else:
            raise HTTPException(503, "code_busy")
        c.execute("INSERT INTO team_members(team_id,user_id,role) VALUES(%s,%s,'owner')", (t["id"], u["id"]))
        c.commit()
        return team_json(c, t, u["id"])

    @app.post("/teams/join")
    def join_team(body: JoinIn, u: Member, c: DB):
        if not app.state.rl.hit(f"join{u['id']}", 20, 3600):
            raise HTTPException(429, "rate_limited")
        code = body.code.strip().upper().replace(" ", "").replace("-", "")
        t = c.execute("SELECT * FROM teams WHERE invite_code=%s FOR UPDATE", (code,)).fetchone()
        if t is None:
            raise HTTPException(404, "bad_code")
        if c.execute("SELECT 1 FROM team_members WHERE team_id=%s AND user_id=%s", (t["id"], u["id"])).fetchone():
            return team_json(c, t, u["id"])
        check_team_quota(c, u["id"])
        n = c.execute("SELECT count(*) AS n FROM team_members WHERE team_id=%s", (t["id"],)).fetchone()["n"]
        if n >= s.team_max:
            raise HTTPException(409, "team_full")
        c.execute("INSERT INTO team_members(team_id,user_id) VALUES(%s,%s)", (t["id"], u["id"]))
        c.commit()
        return team_json(c, t, u["id"])

    def member_team(c, tid, uid) -> dict:
        t = c.execute("SELECT t.* FROM teams t JOIN team_members m ON m.team_id=t.id "
                      "WHERE t.id=%s AND m.user_id=%s", (tid, uid)).fetchone()
        if t is None:  # чужая команда: не подтверждаем, что она есть
            raise HTTPException(404, "Not Found")
        return t

    @app.delete("/teams/{tid}/members/me")
    def leave_team(tid: int, u: User, c: DB):
        t = member_team(c, tid, u["id"])
        c.execute("DELETE FROM team_members WHERE team_id=%s AND user_id=%s", (tid, u["id"]))
        nxt = c.execute("SELECT user_id FROM team_members WHERE team_id=%s ORDER BY joined_at, user_id LIMIT 1",
                        (tid,)).fetchone()
        if nxt is None:
            c.execute("DELETE FROM teams WHERE id=%s", (tid,))
        elif t["owner_id"] == u["id"]:
            c.execute("UPDATE team_members SET role='owner' WHERE team_id=%s AND user_id=%s", (tid, nxt["user_id"]))
            c.execute("UPDATE teams SET owner_id=%s WHERE id=%s", (nxt["user_id"], tid))
        c.commit()
        return {"left": True}

    def parse_day(date: str | None) -> dt.date:
        if not date:
            return dt.datetime.now(TZ).date()
        try:
            return dt.date.fromisoformat(date)
        except ValueError:
            raise HTTPException(422, "bad_date")

    def board(c, tid: int, uid: int, period: str, metric: str, day: dt.date) -> list[dict]:
        col, flag = METRICS[metric]
        if period == "day" or metric == "strain_week":
            # «Нагрузка недели» — итог недели на последний день окна.
            cur_from, cur_to = day, day
            prev_from, prev_to = day - dt.timedelta(days=1), day - dt.timedelta(days=1)
            if period == "week":
                prev_from = prev_to = day - dt.timedelta(days=7)
        else:
            cur_from, cur_to = day - dt.timedelta(days=6), day
            prev_from, prev_to = day - dt.timedelta(days=13), day - dt.timedelta(days=7)
        rows = c.execute(
            f"""SELECT u.id, u.display_name, u.avatar_emoji, u.{flag} AS shared,
                       (u.share_photo AND a.user_id IS NOT NULL) AS has_photo,
                       (SELECT avg({col})::float FROM daily_summary d WHERE d.user_id=u.id
                          AND d.date BETWEEN %s AND %s AND {col} IS NOT NULL) AS value,
                       (SELECT avg({col})::float FROM daily_summary d WHERE d.user_id=u.id
                          AND d.date BETWEEN %s AND %s AND {col} IS NOT NULL) AS prev,
                       (SELECT max(updated_at) FROM daily_summary d WHERE d.user_id=u.id) AS synced_at
                FROM team_members m JOIN users u ON u.id=m.user_id
                LEFT JOIN avatars a ON a.user_id=u.id
                WHERE m.team_id=%s""",
            (cur_from, cur_to, prev_from, prev_to, tid)).fetchall()
        out = []
        for r in rows:
            me = r["id"] == uid
            hidden = not r["shared"]
            v = None if hidden else r["value"]
            p = None if hidden else r["prev"]
            if v is not None:
                v = round(v, 1) if metric.startswith("strain") else round(v)
            if p is not None:
                p = round(p, 1) if metric.startswith("strain") else round(p)
            out.append({"user_id": r["id"], "name": r["display_name"] or "Участник",
                        "emoji": r["avatar_emoji"], "has_photo": bool(r["has_photo"]),
                        "value": v, "prev": p, "hidden": hidden, "me": me,
                        "synced_at": r["synced_at"].isoformat() if r["synced_at"] else None})
        vals = sorted({x["value"] for x in out if x["value"] is not None}, reverse=True)
        for x in out:
            x["place"] = (1 + sum(1 for v in vals if v > x["value"])) if x["value"] is not None else None
        out.sort(key=lambda x: (x["place"] is None, x["place"] or 0, x["name"]))
        return out

    @app.get("/teams")
    def list_teams(u: Member, c: DB, metric: Literal["strain_day", "sleep", "recovery", "strain_week"] = "strain_day",
                   date: str | None = None):
        day = parse_day(date)
        res = []
        for t in c.execute("SELECT t.* FROM teams t JOIN team_members m ON m.team_id=t.id "
                           "WHERE m.user_id=%s ORDER BY m.joined_at", (u["id"],)).fetchall():
            j = team_json(c, t, u["id"])
            mine = next((r for r in board(c, t["id"], u["id"], "day", metric, day) if r["me"]), None)
            j["my_place"] = mine["place"] if mine else None
            res.append(j)
        return {"teams": res, "metric": metric, "date": day.isoformat()}

    @app.get("/teams/{tid}/leaderboard")
    def leaderboard(tid: int, u: Member, c: DB, period: Literal["day", "week"] = "day",
                    metric: Literal["strain_day", "sleep", "recovery", "strain_week"] = "strain_day",
                    date: str | None = None):
        t = member_team(c, tid, u["id"])
        day = parse_day(date)
        return {"team": team_json(c, t, u["id"]), "period": period, "metric": metric,
                "date": day.isoformat(), "rows": board(c, tid, u["id"], period, metric, day)}

    @app.get("/teams/{tid}/feed")
    def feed(tid: int, u: Member, c: DB, date: str | None = None):
        member_team(c, tid, u["id"])
        day = parse_day(date)
        rows = c.execute(
            """SELECT d.id, d.user_id, d.date, d.sleep_pct, d.recovery, d.workouts_json, d.updated_at,
                      u.display_name, u.avatar_emoji, u.share_sleep, u.share_recovery, u.share_workouts
               FROM daily_summary d JOIN users u ON u.id=d.user_id
               JOIN team_members m ON m.user_id=d.user_id AND m.team_id=%s
               WHERE d.date BETWEEN %s AND %s""",
            (tid, day - dt.timedelta(days=6), day)).fetchall()
        items = []
        for r in rows:
            base = {"summary_id": r["id"], "user_id": r["user_id"], "name": r["display_name"] or "Участник",
                    "emoji": r["avatar_emoji"], "date": r["date"].isoformat(), "me": r["user_id"] == u["id"]}
            sl = r["sleep_pct"] if r["share_sleep"] else None
            rc = r["recovery"] if r["share_recovery"] else None
            if sl is not None or rc is not None:
                items.append({**base, "item": -1, "kind": "night", "sleep_pct": sl, "recovery": rc,
                              "at": r["updated_at"].isoformat()})
            if r["share_workouts"]:
                for i, w in enumerate(r["workouts_json"] or []):
                    at = dt.datetime.fromtimestamp(w["end_ts"], dt.UTC) if w.get("end_ts") else r["updated_at"]
                    items.append({**base, "item": i, "kind": "workout", "type": w.get("type", "other"),
                                  "minutes": w.get("minutes"), "strain": w.get("strain"), "at": at.isoformat()})
        if items:
            ids = list({x["summary_id"] for x in items})
            rx = c.execute("SELECT summary_id, item, emoji, count(*) AS n, bool_or(user_id=%s) AS mine "
                           "FROM reactions WHERE summary_id = ANY(%s) GROUP BY summary_id, item, emoji",
                           (u["id"], ids)).fetchall()
            for x in items:
                x["reactions"] = {e: {"n": 0, "mine": False} for e in EMOJIS}
                for r in rx:
                    if r["summary_id"] == x["summary_id"] and r["item"] == x["item"]:
                        x["reactions"][r["emoji"]] = {"n": r["n"], "mine": r["mine"]}
        items.sort(key=lambda x: x["at"], reverse=True)
        return {"items": items[:100]}


    @app.post("/teams/{tid}/react")
    def react(tid: int, body: ReactIn, u: Member, c: DB):
        member_team(c, tid, u["id"])
        ok = c.execute("SELECT 1 FROM daily_summary d JOIN team_members m ON m.user_id=d.user_id AND m.team_id=%s "
                       "WHERE d.id=%s", (tid, body.summary_id)).fetchone()
        if not ok:
            raise HTTPException(404, "Not Found")
        gone = c.execute("DELETE FROM reactions WHERE summary_id=%s AND item=%s AND user_id=%s AND emoji=%s RETURNING id",
                         (body.summary_id, body.item, u["id"], body.emoji)).fetchone()
        if gone is None:
            c.execute("INSERT INTO reactions(summary_id,item,user_id,emoji) VALUES(%s,%s,%s,%s)",
                      (body.summary_id, body.item, u["id"], body.emoji))
        c.commit()
        return {"on": gone is None}


    # ── B6: страница приглашения (ссылка из «Поделиться») ──
    @app.get("/join", response_class=HTMLResponse)
    def join_page(code: str = ""):
        c = code.upper() if re.fullmatch(r"[A-Za-z0-9]{6}", code or "") else ""
        step = (f"<li>В «Ритме»: <b>Сообщество → ⋯ → Войти по коду</b> и введите <b class=code>{c}</b>.</li>"
                if c else "<li>В «Ритме»: <b>Сообщество → ⋯ → Войти по коду</b> — код пришлёт тот, кто пригласил.</li>")
        return f"""<!doctype html><html lang=ru><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Приглашение в «Ритм»</title>
<style>body{{background:#0E1114;color:#F2F4F6;font:17px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:24px;max-width:560px}}
h1{{font-size:26px;margin:0 0 8px}}p,li{{color:#A7ADB5}}b{{color:#F2F4F6}}.code{{color:#2FD7B5;letter-spacing:3px}}
.card{{background:#1C2026;border-radius:16px;padding:16px 20px;margin:16px 0}}</style></head><body>
<h1>Вас пригласили в «Ритм»</h1><p>«Ритм» — сон, восстановление и нагрузка по браслету WHOOP на iPhone, с командами друзей.</p>
<div class=card><ol>
<li>Установите «Ритм» по ссылке, которую прислал пригласивший (закрытая раздача друзьям).</li>
<li>Откройте приложение, подключите браслет и разрешите доступ к «Здоровью».</li>
<li>Вкладка <b>Сообщество</b> → <b>Войти через Apple</b> → согласие.</li>
{step}
</ol></div>
<p>На сервер уходят только итоги дня (оценка сна, восстановление, нагрузка) и сообщения чата. Пульс, ВСР, ЭКГ и стресс остаются на телефоне.</p>
</body></html>"""

    # ── B6: чат команды ──
    def msg_json(r: dict, uid: int) -> dict:
        gone = r["deleted_at"] is not None
        return {"id": r["id"], "team_id": r["team_id"], "user_id": r["user_id"],
                "name": r["display_name"] or "Участник", "emoji": r["avatar_emoji"],
                "text": None if gone else r["text"], "deleted": gone,
                "at": r["created_at"].isoformat(), "me": r["user_id"] == uid}

    MSG_SQL = ("SELECT m.*, u.display_name, u.avatar_emoji FROM messages m JOIN users u ON u.id=m.user_id ")

    @app.get("/teams/{tid}/messages")
    def get_messages(tid: int, u: Member, c: DB, before: int | None = None, limit: int = 50):
        member_team(c, tid, u["id"])
        limit = max(1, min(limit, 100))
        rows = c.execute(MSG_SQL + "WHERE m.team_id=%s AND (%s::bigint IS NULL OR m.id < %s) "
                         "ORDER BY m.id DESC LIMIT %s", (tid, before, before, limit)).fetchall()
        muted = c.execute("SELECT 1 FROM team_mutes WHERE team_id=%s AND user_id=%s",
                          (tid, u["id"])).fetchone() is not None
        return {"items": [msg_json(r, u["id"]) for r in reversed(rows)], "muted": muted}

    @app.post("/teams/{tid}/messages")
    async def post_message(tid: int, body: MessageIn, u: Member, c: DB):
        t = member_team(c, tid, u["id"])
        if not app.state.rl.hit(f"msg{u['id']}", s.msg_rate):
            raise HTTPException(429, "rate_limited")
        r = c.execute("INSERT INTO messages(team_id,user_id,text) VALUES(%s,%s,%s) RETURNING id",
                      (tid, u["id"], body.text)).fetchone()
        c.commit()
        row = c.execute(MSG_SQL + "WHERE m.id=%s", (r["id"],)).fetchone()
        out = msg_json(row, u["id"])
        await app.state.hub.publish(tid, {"type": "message", **{**out, "me": False}})
        # Пуш — тем, у кого чат этой команды сейчас закрыт и команда не «без звука».
        online = app.state.hub.online(tid)
        devs = [d for d in c.execute(
            "SELECT d.token, d.sandbox, d.user_id FROM devices d JOIN team_members m ON m.user_id=d.user_id "
            "AND m.team_id=%s WHERE d.user_id<>%s AND NOT EXISTS (SELECT 1 FROM team_mutes x "
            "WHERE x.team_id=%s AND x.user_id=d.user_id)", (tid, u["id"], tid)).fetchall()
            if d["user_id"] not in online]
        name = u["display_name"] or "Участник"
        await later(app.state.apns.send(devs, f"{t['emoji']} {t['name']}", f"{name}: {preview(body.text)}",
                                        {"team_id": tid, "message_id": out["id"]}))
        return out

    @app.delete("/teams/{tid}/messages/{mid}")
    async def delete_message(tid: int, mid: int, u: Member, c: DB):
        member_team(c, tid, u["id"])
        r = c.execute("UPDATE messages SET text='', deleted_at=now() WHERE id=%s AND team_id=%s AND user_id=%s "
                      "AND deleted_at IS NULL RETURNING id", (mid, tid, u["id"])).fetchone()
        c.commit()
        if r is None:
            raise HTTPException(404, "Not Found")
        await app.state.hub.publish(tid, {"type": "deleted", "id": mid, "team_id": tid})
        return {"ok": True}

    @app.put("/teams/{tid}/mute")
    def put_mute(tid: int, body: MuteIn, u: Member, c: DB):
        member_team(c, tid, u["id"])
        if body.muted:
            c.execute("INSERT INTO team_mutes VALUES(%s,%s) ON CONFLICT DO NOTHING", (tid, u["id"]))
        else:
            c.execute("DELETE FROM team_mutes WHERE team_id=%s AND user_id=%s", (tid, u["id"]))
        c.commit()
        return {"muted": body.muted}

    @app.put("/me/devices")
    def put_device(body: DeviceIn, u: User, c: DB):
        c.execute("INSERT INTO devices(token,user_id,sandbox) VALUES(%s,%s,%s) ON CONFLICT(token) DO UPDATE "
                  "SET user_id=EXCLUDED.user_id, sandbox=EXCLUDED.sandbox, updated_at=now()",
                  (body.token.lower(), u["id"], body.sandbox))
        c.commit()
        return {"ok": True}

    @app.delete("/me/devices/{token}")
    def delete_device(token: str, u: User, c: DB):
        c.execute("DELETE FROM devices WHERE token=%s AND user_id=%s", (token.lower(), u["id"]))
        c.commit()
        return {"ok": True}

    @app.websocket("/teams/{tid}/chat")
    async def chat_ws(ws: WebSocket, tid: int, token: str = ""):
        # Токен — в строке запроса (заголовки WebSocket из iOS неудобны); только access.
        try:
            claims = jwt.decode(token, s.secret, algorithms=["HS256"], options={"require": ["exp", "sub"]})
            assert claims.get("typ") == "access"
            uid = int(claims["sub"])
        except Exception:
            await ws.close(code=4401)
            return
        with app.state.pool.connection() as c:
            lc = latest_consent(c, uid)
            ok = lc is not None and lc["version"] == CONSENT_VERSION and c.execute(
                "SELECT 1 FROM team_members WHERE team_id=%s AND user_id=%s", (tid, uid)).fetchone()
        if not ok:
            await ws.close(code=4404)
            return
        await ws.accept()
        app.state.hub.join(tid, uid, ws)
        try:
            while True:
                m = await ws.receive_text()
                if m == "ping":
                    await ws.send_text("pong")
        except WebSocketDisconnect:
            pass
        finally:
            app.state.hub.leave(tid, uid, ws)

    return app


if os.environ.get("RITM_DB_DSN"):
    app = create_app()
