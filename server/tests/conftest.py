"""Тесты сервера «Ритма» (B5). Нужна пустая временная база PostgreSQL:
RITM_TEST_DSN=postgresql://ritm@/ritm_test pytest -q tests
"""
import datetime as dt
import hashlib
import os
import time

import jwt
import psycopg
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

os.environ.setdefault("RITM_JWT_SECRET", "t" * 48)
os.environ["RITM_DB_DSN"] = os.environ.get("RITM_TEST_DSN", "postgresql:///ritm_test")
os.environ["RITM_TEST_LOGIN"] = "1"
os.environ["RITM_AUTH_PER_MIN"] = "1000"

from app.main import CONSENT_VERSION, Settings, create_app  # noqa: E402

BUNDLE = "com.oporagroup.ritm"


class FakeJWKS:
    """Поддельные ключи «Apple»: свой RSA-ключ с kid=test1."""

    def __init__(self):
        self.priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        jwk = jwt.algorithms.RSAAlgorithm.to_jwk(self.priv.public_key(), as_dict=True)
        jwk.update(kid="test1", alg="RS256", use="sig")
        self.keys = {"test1": jwt.PyJWK(jwk)}

    def key(self, kid):
        return self.keys.get(kid)

    def token(self, sub="000123.abc", nonce="n" * 32, aud=BUNDLE, iss="https://appleid.apple.com",
              exp_in=600, kid="test1", key=None):
        now = int(time.time())
        claims = {"iss": iss, "aud": aud, "sub": sub, "iat": now - 5, "exp": now + exp_in,
                  "nonce": hashlib.sha256(nonce.encode()).hexdigest()}
        return jwt.encode(claims, key or self.priv, algorithm="RS256", headers={"kid": kid})


@pytest.fixture(scope="session")
def jwks():
    return FakeJWKS()


@pytest.fixture()
def make(jwks):
    """make(**env) → TestClient с чистой базой."""
    clients = []

    def _make(**env):
        old = {k: os.environ.get(k) for k in env}
        os.environ.update({k: str(v) for k, v in env.items()})
        try:
            app = create_app(Settings(), jwks=jwks)
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        c = TestClient(app)
        c.__enter__()
        clients.append(c)
        with psycopg.connect(os.environ["RITM_DB_DSN"], autocommit=True) as db:
            db.execute("TRUNCATE users, teams, team_members, daily_summary, reactions, consents, messages, devices, team_mutes, "
                       "refresh_tokens, avatars RESTART IDENTITY CASCADE")
        return c

    yield _make
    for c in clients:
        c.__exit__(None, None, None)


@pytest.fixture()
def client(make):
    return make()


def login(c, name="Миша", consent=True):
    r = c.post("/auth/test", json={"name": name})
    assert r.status_code == 200, r.text
    h = {"Authorization": "Bearer " + r.json()["access_token"]}
    if consent:
        r2 = c.post("/me/consent", json={"version": CONSENT_VERSION, "processing": True, "share_team": True}, headers=h)
        assert r2.status_code == 200, r2.text
    return h


def today():
    import zoneinfo
    return dt.datetime.now(zoneinfo.ZoneInfo("Europe/Moscow")).date()
