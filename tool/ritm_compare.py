#!/usr/bin/env python3
"""«Ритм» — сверка колец/сна с официальным экспортом WHOOP (ТЗ v3 §8).

Тот же расчёт, что lib/ritm/ritm_compare.dart (экран «Сверка с WHOOP»):
выравнивание по дате пробуждения (±2 ч), «чистые» дни, допуски §8.2,
MAE/смещение/медиана/r/доля в допуске, калибровочная ⅔ и проверочная ⅓ по
времени, совпадение зон. Только стандартная библиотека, без сети.

Команды:
  compare  --whoop DIR|ZIP --ritm ritm_export.csv [--md OUT.md] [--json OUT.json]
  calibrate --whoop DIR|ZIP --ritm ritm_export.csv [--json OUT.json]
            θ = {a, b} Восстановления и {s, k} Нагрузки МНК по калибровочной
            трети, проверка на проверочной (§8.3 п. 2; k_s, d — в B4¾)
  synth    --out DIR [--days 90] [--seed 7]
            синтетический экспорт WHOOP + «Экспорт для сверки» (фикстура
            test/fixtures/ritm_compare и проверка движка сверки)

Δ = Ритм − WHOOP. Пример:
  python3 whoop_reconcile.py compare --whoop ../whoop_export --ritm ritm_export.csv \
      --md B4h_calibration.md
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
import math
import os
import random
import sys
import zipfile

# ── допуски §8.2 (как kCmpMetrics в Dart) ───────────────────────────────────
# key: (title, unit, tab, required, dp, tol{mae,bias,r,within,share})
METRICS = [
    ("recovery", "Восстановление", "%", "rings", True, 0, dict(mae=8, bias=4, r=0.85)),
    ("strain", "Нагрузка", "", "rings", True, 1, dict(mae=1.5, bias=0.8, r=0.90)),
    ("hrv", "ВСР", "мс", "rings", True, 0, dict(mae=8, bias=4, r=0.85, within=10, share=0.80)),
    ("rhr", "Пульс покоя", "уд/мин", "rings", True, 0, dict(mae=2, bias=1, r=0.90, within=3, share=0.85)),
    ("resp", "Дыхание", "/мин", "rings", True, 1, dict(mae=0.8, bias=0.5, r=0.70)),
    ("temp", "Температура (знак)", "°C", "rings", False, 1, dict(share=0.75)),
    ("sleep_pct", "Сон", "%", "rings", True, 0, dict(mae=5, bias=3, r=0.90)),
    ("tst", "Время сна", "мин", "sleep", True, 0, dict(mae=15, bias=10, r=0.90)),
    ("onset", "Отбой", "мин", "sleep", False, 0, dict(mae=15, bias=10, within=15, share=0.85)),
    ("wake", "Подъём", "мин", "sleep", False, 0, dict(mae=15, bias=10, within=15, share=0.85)),
    ("in_bed", "В кровати", "мин", "sleep", False, 0, dict(mae=15)),
    ("eff", "Эффективность", "%", "sleep", False, 0, dict(mae=3, bias=2)),
    ("light", "Лёгкий", "мин", "sleep", False, 0, dict(mae=25, bias=15)),
    ("deep", "Глубокий", "мин", "sleep", False, 0, dict(mae=25, bias=15)),
    ("rem", "Быстрый", "мин", "sleep", False, 0, dict(mae=25, bias=15)),
    ("awake", "Бодрствование", "мин", "sleep", False, 0, dict(mae=25, bias=15)),
    ("need", "Потребность", "мин", "sleep", False, 0, dict(mae=20, bias=10, r=0.80)),
    ("debt", "Долг", "мин", "sleep", False, 0, dict(mae=20, bias=10)),
    ("consistency", "Регулярность", "%", "sleep", False, 0, dict(mae=8, r=0.70)),
]
MET = {m[0]: m for m in METRICS}

RITM_COLS = [
    "day", "onset", "wake", "rhr_sleep_mean", "rhr_trough30", "rmssd_sws_last",
    "rmssd_night_mean", "resp", "temp_dev", "tst_min", "in_bed_min", "eff",
    "light_min", "deep_min", "rem_min", "awake_min", "need_min", "debt_min",
    "consistency", "sleep_pct", "recovery", "strain", "observed_frac",
    "hr_valid_frac", "max_gap_min", "strength", "sws_found", "watch_min",
    "rec_zbar", "strain_load", "v_hist",
]

STRENGTH = ["weightlifting", "powerlifting", "functional fitness", "strength",
            "crossfit", "f45", "barry", "pilates", "yoga", "climbing", "силов"]


# ── чтение ──────────────────────────────────────────────────────────────────
def _num(s):
    s = (s or "").strip().replace("%", "").replace(",", ".")
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def _ts(s):
    s = (s or "").strip()
    if not s:
        return None
    for f in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(s[:19], f)
        except ValueError:
            pass
    return None


def _day(d):
    return d.strftime("%Y-%m-%d")


def _rows(text):
    if text.startswith("\ufeff"):
        text = text[1:]
    r = list(csv.reader(io.StringIO(text)))
    r = [x for x in r if any(c.strip() for c in x)]
    if not r:
        return [], []
    return [h.strip().lower() for h in r[0]], r[1:]


def _col(head, names):
    for n in names:
        if n in head:
            return head.index(n)
    return -1


def _at(r, i):
    return r[i] if 0 <= i < len(r) else ""


def file_kind(text):
    head, _ = _rows(text)
    if "recovery score %" in head or "day strain" in head:
        return "cycles"
    if "activity strain" in head or "workout start time" in head:
        return "workouts"
    if "question text" in head or "answered yes" in head:
        return "journal"
    if "nap" in head or "sleep performance %" in head:
        return "sleeps"
    return None


def _cycle_day(wake, start):
    if wake is not None:
        return _day(wake)
    if start is None:
        return None
    d = start + dt.timedelta(days=1) if start.hour >= 12 else start
    return _day(d)


def _sleep_fields(head, r):
    n = lambda names: _num(_at(r, _col(head, names)))
    return dict(
        onset=_ts(_at(r, _col(head, ["sleep onset"]))),
        wake=_ts(_at(r, _col(head, ["wake onset"]))),
        perf=n(["sleep performance %"]),
        resp=n(["respiratory rate (rpm)", "respiratory rate"]),
        asleep=n(["asleep duration (min)"]),
        in_bed=n(["in bed duration (min)"]),
        light=n(["light sleep duration (min)"]),
        deep=n(["deep (sws) duration (min)", "deep sleep duration (min)"]),
        rem=n(["rem duration (min)", "rem sleep duration (min)"]),
        awake=n(["awake duration (min)"]),
        need=n(["sleep need (min)"]),
        debt=n(["sleep debt (min)"]),
        eff=n(["sleep efficiency %"]),
        consistency=n(["sleep consistency %"]),
    )


def parse_cycles(text):
    head, rows = _rows(text)
    out = []
    for r in rows:
        n = lambda names: _num(_at(r, _col(head, names)))
        sf = _sleep_fields(head, r)
        start = _ts(_at(r, _col(head, ["cycle start time"])))
        day = _cycle_day(sf["wake"], start)
        if day is None:
            continue
        out.append(dict(
            day=day, start=start,
            recovery=n(["recovery score %"]),
            rhr=n(["resting heart rate (bpm)", "resting heart rate"]),
            hrv=n(["heart rate variability (ms)", "heart rate variability (rmssd) (ms)"]),
            skin_temp=n(["skin temp (celsius)", "skin temp (fahrenheit)"]),
            strain=n(["day strain"]),
            sleep=sf,
        ))
    out.sort(key=lambda c: c["day"])
    return out


def parse_workouts(text):
    head, rows = _rows(text)
    out = []
    for r in rows:
        st = _ts(_at(r, _col(head, ["workout start time"])))
        if st is None:
            continue
        out.append(dict(
            start=st,
            name=_at(r, _col(head, ["activity name"])).strip(),
            strain=_num(_at(r, _col(head, ["activity strain"]))),
        ))
    return out


def load_whoop(path):
    """Каталог или zip экспорта WHOOP → {'cycles': [...], 'workouts': [...], 'files': set}."""
    texts = {}
    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for f in files:
                if f.lower().endswith(".csv"):
                    with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                        texts[f] = fh.read()
                elif f.lower().endswith(".zip"):
                    texts.update(_zip_texts(os.path.join(root, f)))
    elif path.lower().endswith(".zip"):
        texts = _zip_texts(path)
    else:
        with open(path, encoding="utf-8", errors="replace") as fh:
            texts[os.path.basename(path)] = fh.read()
    out = dict(cycles=[], workouts=[], files=set())
    for t in texts.values():
        k = file_kind(t)
        if k is None:
            continue
        out["files"].add(k)
        if k == "cycles":
            out["cycles"] = parse_cycles(t)
        elif k == "workouts":
            out["workouts"] = parse_workouts(t)
    return out


def _zip_texts(p):
    res = {}
    with zipfile.ZipFile(p) as z:
        for n in z.namelist():
            if n.lower().endswith(".csv"):
                res[os.path.basename(n)] = z.read(n).decode("utf-8", errors="replace")
    return res


def load_ritm(path):
    with open(path, encoding="utf-8") as fh:
        head, rows = _rows(fh.read())
    # заголовок «Экспорта для сверки» — в нижнем регистре и так
    out = []
    for r in rows:
        g = lambda c: _at(r, head.index(c)).strip() if c in head else ""
        day = g("day")
        if not day:
            continue
        v = {}
        for c in RITM_COLS[3:]:
            if c in ("strength", "sws_found", "v_hist"):
                continue
            try:
                v[c] = float(g(c)) if g(c) else None
            except ValueError:
                v[c] = None
        out.append(dict(day=day, onset=_ts(g("onset")), wake=_ts(g("wake")),
                        strength=g("strength") == "true", sws_found=g("sws_found") == "true",
                        v_hist=g("v_hist"), v=v))
    return out


# ── сверка ──────────────────────────────────────────────────────────────────
RITM_KEY = dict(recovery="recovery", strain="strain", hrv="rmssd_sws_last",
                rhr="rhr_sleep_mean", resp="resp", temp="temp_dev", sleep_pct="sleep_pct",
                tst="tst_min", in_bed="in_bed_min", eff="eff", light="light_min",
                deep="deep_min", rem="rem_min", awake="awake_min", need="need_min",
                debt="debt_min", consistency="consistency")
WHOOP_SLEEP_KEY = dict(resp="resp", sleep_pct="perf", tst="asleep", in_bed="in_bed",
                       eff="eff", light="light", deep="deep", rem="rem", awake="awake",
                       need="need", debt="debt", consistency="consistency")


def _median(xs):
    if not xs:
        return None
    s = sorted(xs)
    m = len(s) // 2
    return s[m] if len(s) % 2 else (s[m - 1] + s[m]) / 2


def pearson(x, y):
    n = len(x)
    if n < 5:
        return None
    mx, my = sum(x) / n, sum(y) / n
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    sxx = sum((a - mx) ** 2 for a in x)
    syy = sum((b - my) ** 2 for b in y)
    if sxx <= 0 or syy <= 0:
        return None
    return sxy / math.sqrt(sxx * syy)


def _clock_min(t, day):
    if t is None:
        return None
    d0 = dt.datetime.strptime(day, "%Y-%m-%d")
    return (t - d0).total_seconds() / 60.0


def _trunc_min(td):
    s = td.total_seconds() / 60.0
    return int(s)  # к нулю, как Duration.inMinutes в Dart


def stat(cells, tol, sign=False):
    if not cells:
        return dict(n=0, mae=None, bias=None, median=None, r=None, share=None)
    if sign:
        s = [c for c in cells if abs(c[0]) >= 0.1]
        if not s:
            return dict(n=0, mae=None, bias=None, median=None, r=None, share=None)
        same = sum(1 for a, b in s if (a > 0) == (b > 0))
        return dict(n=len(s), mae=None, bias=None, median=None, r=None, share=same / len(s))
    d = [b - a for a, b in cells]
    n = len(d)
    share = None
    if tol.get("within") is not None:
        share = sum(1 for x in d if abs(x) <= tol["within"] + 1e-9) / n
    return dict(n=n, mae=sum(abs(x) for x in d) / n, bias=sum(d) / n, median=_median(d),
                r=pearson([c[0] for c in cells], [c[1] for c in cells]), share=share)


def passes(s, t, mult=1.0):
    if s["n"] < 3:
        return False
    if t.get("mae") is not None and (s["mae"] is None or s["mae"] > t["mae"] * mult + 1e-9):
        return False
    if t.get("bias") is not None and (s["bias"] is None or abs(s["bias"]) > t["bias"] * mult + 1e-9):
        return False
    if t.get("r") is not None and s["r"] is not None and s["r"] < t["r"] - 1e-9:
        return False
    if t.get("share") is not None and (s["share"] is None or s["share"] < t["share"] - 1e-9):
        return False
    return True


def zone_rec(v):
    return 2 if v >= 67 else (1 if v >= 34 else 0)


def zone_sleep(v):
    return 2 if v >= 85 else (1 if v >= 70 else 0)


def compare(whoop, ours):
    by_day = {d["day"]: d for d in ours}
    strength_w = {_day(w["start"]) for w in whoop["workouts"]
                  if any(k in w["name"].lower() for k in STRENGTH)}
    temp_dev, hist = {}, []
    for c in whoop["cycles"]:
        t = c["skin_temp"]
        base = _median(hist[-30:]) if len(hist) >= 3 else None
        temp_dev[c["day"]] = None if t is None or base is None else t - base
        if t is not None:
            hist.append(t)
    rows, seen = [], set()
    for c in reversed(whoop["cycles"]):
        if c["day"] in seen:
            continue
        seen.add(c["day"])
        o = by_day.get(c["day"])
        if o is None:
            continue
        ww = c["sleep"]["wake"]
        align = ww is not None and o["wake"] is not None and abs(_trunc_min(ww - o["wake"])) > 120
        ov = o["v"]
        obs = ov.get("observed_frac")
        hv = ov.get("hr_valid_frac")
        gap = ov.get("max_gap_min")
        dirty = []
        if (1 if obs is None else obs) < 0.85:
            dirty.append("observed")
        if (1 if hv is None else hv) < 0.80:
            dirty.append("hr_valid")
        if (0 if gap is None else gap) > 120:
            dirty.append("gap")
        cells = {}
        for key, *_ in METRICS:
            if key == "onset":
                a, b = _clock_min(c["sleep"]["onset"], c["day"]), _clock_min(o["onset"], c["day"])
            elif key == "wake":
                a, b = _clock_min(c["sleep"]["wake"], c["day"]), _clock_min(o["wake"], c["day"])
            else:
                if key in ("recovery", "strain", "hrv", "rhr"):
                    a = c[key]
                elif key == "temp":
                    a = temp_dev.get(c["day"])
                else:
                    a = c["sleep"][WHOOP_SLEEP_KEY[key]]
                b = ov.get(RITM_KEY[key])
            if a is not None and b is not None and not math.isnan(a) and not math.isnan(b):
                cells[key] = (a, b)
        rows.append(dict(day=c["day"], align_fail=align,
                         strength=o["strength"] or c["day"] in strength_w,
                         dirty=dirty, cells=cells))
    rows.sort(key=lambda r: r["day"])
    for r in rows:
        r["clean"] = not r["align_fail"] and not r["dirty"]
    clean = [r["day"] for r in rows if r["clean"]]
    k = (len(clean) * 2) // 3
    valid_from = None if not clean or k >= len(clean) else clean[k]
    prelim = len(clean) < 30
    mult = 1.5 if prelim else 1.0
    results = {}
    for key, title, unit, tab, req, dp, tol in METRICS:
        allc, cal, val = [], [], []
        for r in rows:
            cell = r["cells"].get(key)
            ok = r["clean"] and (key != "strain" or not r["strength"])
            if cell is None or not ok:
                continue
            allc.append(cell)
            (val if valid_from is not None and r["day"] >= valid_from else cal).append(cell)
        sign = key == "temp"
        sa, sv = stat(allc, tol, sign), stat(val, tol, sign)
        results[key] = dict(all=sa, calib=stat(cal, tol, sign), valid=sv,
                            pass_=passes(sa, tol, mult) and passes(sv, tol, mult))

    def agree(key, z):
        xs = [r["cells"][key] for r in rows if r["clean"] and key in r["cells"]]
        if not xs:
            return None
        return sum(1 for a, b in xs if z(a) == z(b)) / len(xs)

    rec = [r["cells"]["recovery"][1] for r in rows if r["clean"] and "recovery" in r["cells"]]
    dist = None
    if rec:
        dist = [sum(1 for v in rec if zone_rec(v) == z) / len(rec) for z in (2, 1, 0)]
    return dict(rows=rows, results=results, clean_days=len(clean),
                align_fail=sum(1 for r in rows if r["align_fail"]), valid_from=valid_from,
                preliminary=prelim, mult=mult, rec_zone_agree=agree("recovery", zone_rec),
                sleep_zone_agree=agree("sleep_pct", zone_sleep), rec_dist=dist)


def _rd(x):
    if x is None:
        return None
    return math.copysign(math.floor(abs(x) * 1000 + 0.5), x) / 1000


def report_json(rep):
    st = lambda s: {k: (_rd(v) if k != "n" else v) for k, v in s.items()}
    return dict(
        clean_days=rep["clean_days"], align_fail=rep["align_fail"], valid_from=rep["valid_from"],
        preliminary=rep["preliminary"], rec_zone_agree=_rd(rep["rec_zone_agree"]),
        sleep_zone_agree=_rd(rep["sleep_zone_agree"]),
        metrics={k: dict(all=st(v["all"]), calib=st(v["calib"]), valid=st(v["valid"]),
                         pass_=v["pass_"]) for k, v in rep["results"].items()},
    )


def pass_tab(rep, tab):
    for key, title, unit, t, req, dp, tol in METRICS:
        if t == tab and req and not rep["results"][key]["pass_"]:
            return False
    if tab == "rings" and (rep["rec_zone_agree"] is None or rep["rec_zone_agree"] < 0.8):
        return False
    return True


def _f(x, dp=1):
    if x is None:
        return "—"
    return f"{x:.{dp}f}".replace(".", ",")


def report_md(rep, title="Сверка «Ритм» × WHOOP", src=""):
    L = [f"# {title}", ""]
    if src:
        L += [src, ""]
    L += [f"Чистых дней: **{rep['clean_days']}**, исключено по выравниванию (±2 ч): {rep['align_fail']}; "
          f"проверочная треть с {rep['valid_from'] or '—'}; "
          + ("**предварительно** (< 30 чистых дней, допуски MAE/смещения ×1,5)" if rep["preliminary"] else "окончательно"),
          ""]
    for tab, name in (("rings", "Кольца (B4½)"), ("sleep", "Сон (B4¾)")):
        L += [f"## {name} — {'ПРОХОДИТ' if pass_tab(rep, tab) else 'НЕ ПРОХОДИТ'}", "",
              "| Показатель | обяз. | n (все/пров.) | MAE все | MAE пров. | смещение | медиана Δ | r | доля в допуске | допуск MAE / смещ. / r | итог |",
              "|---|---|---|---|---|---|---|---|---|---|---|"]
        for key, t, unit, tb, req, dp, tol in METRICS:
            if tb != tab:
                continue
            r = rep["results"][key]
            a, v = r["all"], r["valid"]
            tol_s = " / ".join(_f(tol.get(x), 2 if x == "r" else 1) for x in ("mae", "bias", "r"))
            share = _f(a["share"] * 100, 0) + " %" if a["share"] is not None else "—"
            L.append(f"| {t} {('(' + unit + ')') if unit else ''} | {'да' if req else ''} | {a['n']}/{v['n']} | "
                     f"{_f(a['mae'], 2)} | {_f(v['mae'], 2)} | {_f(a['bias'], 2)} | {_f(a['median'], 2)} | "
                     f"{_f(a['r'], 2)} | {share} | {tol_s} | {'зелёный' if r['pass_'] else ('нет данных' if a['n'] == 0 else 'красный')} |")
        L.append("")
    L += [f"Совпадение зоны Восстановления: {_f((rep['rec_zone_agree'] or 0) * 100, 0)} % (нужно ≥ 80 %); "
          f"зоны Сна: {_f((rep['sleep_zone_agree'] or 0) * 100, 0)} %.", ""]
    if rep["rec_dist"]:
        g, y, r = rep["rec_dist"]
        L += [f"Распределение наших зон Восстановления: зел. {_f(g*100,0)} % / жёлт. {_f(y*100,0)} % / кр. {_f(r*100,0)} % "
              "(ориентир WHOOP ≈ 40/45/15 ±10 п.п., справочно).", ""]
    L += ["## По дням", "", "Δ = Ритм − WHOOP; ✗ — вне допуска дня; флаги: align — подъём разошёлся > 2 ч, "
          "observed/hr_valid/gap — «грязная» ночь, strength — силовая (Нагрузка не сверяется).", "",
          "| День | флаги | Восст. W/Р/Δ | Нагр. W/Р/Δ | ВСР W/Р/Δ | Пульс W/Р/Δ | Дых. Δ | Сон% W/Р/Δ | TST Δ |",
          "|---|---|---|---|---|---|---|---|---|"]
    m = rep["mult"]

    def cell(r, key, full=True):
        c = r["cells"].get(key)
        if c is None:
            return "—"
        a, b = c
        d = b - a
        tol = MET[key][6]
        lim = tol.get("within", tol.get("mae"))
        bad = lim is not None and abs(d) > lim * m + 1e-9
        dp = MET[key][5]
        s = (f"{_f(a, dp)}/{_f(b, dp)}/" if full else "") + ("+" if d > 0 else "") + _f(d, dp)
        return s + (" ✗" if bad else "")

    for r in rep["rows"]:
        flags = ",".join((["align"] if r["align_fail"] else []) + r["dirty"] + (["strength"] if r["strength"] else []))
        L.append(f"| {r['day']} | {flags} | {cell(r,'recovery')} | {cell(r,'strain')} | {cell(r,'hrv')} | "
                 f"{cell(r,'rhr')} | {cell(r,'resp',False)} | {cell(r,'sleep_pct')} | {cell(r,'tst',False)} |")
    return "\n".join(L) + "\n"


# ── калибровка θ (§8.3 п. 2): {a, b} и {s, k} ──────────────────────────────
def _linreg(x, y):
    n = len(x)
    mx, my = sum(x) / n, sum(y) / n
    sxx = sum((a - mx) ** 2 for a in x)
    if sxx <= 0:
        return None
    a = sum((p - mx) * (q - my) for p, q in zip(x, y)) / sxx
    return a, my - a * mx


def _load_from_hist(h, k, c=0.15):
    bins = [int(x) for x in h.split(";") if x.strip() != ""]
    tot = 0.0
    for i, n in enumerate(bins):
        if i == 0 or n == 0:
            continue
        v = min(1.1, (i - 0.5) * 0.05)
        tot += n * c * (math.exp(k * v) - 1)
    return tot


def _strain(load, s):
    return 21 * (2 / math.pi) * math.atan(max(0.0, load) / s)


def calibrate(whoop, ours):
    rep = compare(whoop, ours)
    by_day = {d["day"]: d for d in ours}
    vf = rep["valid_from"]
    wc = {c["day"]: c for c in whoop["cycles"]}
    res = {}
    # Восстановление: logit(R_whoop/100) = a·z̄ + b — МНК по калибровочной трети.
    cal, val = [], []
    for r in rep["rows"]:
        o = by_day[r["day"]]
        z = o["v"].get("rec_zbar")
        w = wc[r["day"]]["recovery"]
        if not r["clean"] or z is None or w is None:
            continue
        p = min(0.99, max(0.01, w / 100))
        (val if vf and r["day"] >= vf else cal).append((z, math.log(p / (1 - p)), w))
    if len(cal) >= 5:
        ab = _linreg([c[0] for c in cal], [c[1] for c in cal])
        if ab:
            a, b = ab
            mae = lambda xs: sum(abs(100 / (1 + math.exp(-(a * z + b))) - w) for z, _, w in xs) / len(xs) if xs else None
            res["recovery"] = dict(a=round(a, 4), b=round(b, 4), n_cal=len(cal), n_val=len(val),
                                   mae_cal=_rd(mae(cal)), mae_val=_rd(mae(val)))
    # Нагрузка: сетка k, для каждого k — s по МНК (одномерный поиск), без силовых.
    cal, val = [], []
    for r in rep["rows"]:
        o = by_day[r["day"]]
        w = wc[r["day"]]["strain"]
        if not r["clean"] or r["strength"] or w is None or not o["v_hist"]:
            continue
        (val if vf and r["day"] >= vf else cal).append((o["v_hist"], w))
    if len(cal) >= 5:
        best = None
        for k10 in range(15, 61):
            k = k10 / 10
            loads = [_load_from_hist(h, k) for h, _ in cal]
            for s in [x * 2.0 for x in range(5, 200)]:
                err = sum((_strain(L, s) - w) ** 2 for L, (_, w) in zip(loads, cal))
                if best is None or err < best[0]:
                    best = (err, k, s)
        _, k, s = best
        mae = lambda xs: sum(abs(_strain(_load_from_hist(h, k), s) - w) for h, w in xs) / len(xs) if xs else None
        res["strain"] = dict(k=k, s=s, n_cal=len(cal), n_val=len(val), mae_cal=_rd(mae(cal)), mae_val=_rd(mae(val)))
    return res


# ── синтетика (фикстура) ────────────────────────────────────────────────────
def synth(out, days=90, seed=7):
    """Синтетический экспорт WHOOP + наш экспорт с известными ошибками.

    Проверяет движок сверки (выравнивание, флаги, трети, допуски, паритет
    Dart = Python), а НЕ сходство наших формул с WHOOP — истины здесь нет.
    """
    rnd = random.Random(seed)
    os.makedirs(out, exist_ok=True)
    start = dt.date(2026, 7, 1)
    cyc_rows, sl_rows, wk_rows, jr_rows, our_rows = [], [], [], [], []
    for i in range(days):
        day = start + dt.timedelta(days=i)
        onset = dt.datetime.combine(day - dt.timedelta(days=1), dt.time(23, 0)) + dt.timedelta(minutes=rnd.randint(-50, 60))
        tst = rnd.randint(330, 500)
        in_bed = tst + rnd.randint(15, 60)
        wake = onset + dt.timedelta(minutes=in_bed)
        rhr = round(52 + rnd.gauss(0, 2.5))
        hrv = round(max(15, 58 + rnd.gauss(0, 9)))
        resp = round(14.6 + rnd.gauss(0, 0.4), 1)
        need = 480 + rnd.randint(-20, 40)
        perf = min(100, round(tst / need * 100))
        rec = max(1, min(99, round(55 + (hrv - 58) * 2.2 - (rhr - 52) * 3 + rnd.gauss(0, 6))))
        strain = round(max(2, min(20, 9 + rnd.gauss(0, 3.5))), 1)
        temp = round(33.6 + rnd.gauss(0, 0.25), 1)
        light, deep, rem = round(tst * 0.52), round(tst * 0.2), tst - round(tst * 0.52) - round(tst * 0.2)
        f = lambda t: t.strftime("%Y-%m-%d %H:%M:%S")
        cyc_rows.append([f(onset), f(wake + dt.timedelta(hours=16)), "UTC+05:00", rec, rhr, hrv, temp, 95.5,
                         strain, 2100, 160, 70, f(onset), f(wake), perf, resp, tst, in_bed, light, deep, rem,
                         in_bed - tst, need, max(0, need - 480), round(tst / in_bed * 100), rnd.randint(60, 90)])
        sl_rows.append([f(onset), f(wake + dt.timedelta(hours=16)), "UTC+05:00", f(onset), f(wake), perf, resp,
                        tst, in_bed, light, deep, rem, in_bed - tst, need, max(0, need - 480),
                        round(tst / in_bed * 100), rnd.randint(60, 90), "false"])
        strength = i % 11 == 5
        if i % 3 == 0 or strength:
            ws = wake + dt.timedelta(hours=10)
            wk_rows.append([f(onset), f(wake + dt.timedelta(hours=16)), "UTC+05:00", f(ws), f(ws + dt.timedelta(minutes=50)),
                            50, "Weightlifting" if strength else "Running", round(strain * 0.8, 1), 450, 170, 140,
                            10, 20, 30, 25, 15, "false" if strength else "true"])
        if i % 4 == 0:
            jr_rows.append([f(onset), f(wake + dt.timedelta(hours=16)), "UTC+05:00", "Have any alcoholic drinks?", "false", ""])
        # наш день: известные ошибки + особые дни
        e = lambda s: rnd.gauss(0, s)
        o_wake = wake + dt.timedelta(minutes=round(e(6)))
        if i == 40:
            o_wake = wake + dt.timedelta(hours=3)  # align_fail
        obs = 0.97
        if i in (12, 63):
            obs = 0.6  # «грязная» ночь
        vh = [0] * 24
        vh[0], vh[2], vh[5], vh[9], vh[14] = 500, 400, 200, 60, int(max(0, strain * 3))
        our_rows.append(dict(
            day=_day(day), onset=f(onset + dt.timedelta(minutes=round(e(8)))), wake=f(o_wake),
            rhr_sleep_mean=round(rhr + 0.4 + e(1.2), 1), rhr_trough30=round(rhr - 2.5 + e(1), 1),
            rmssd_sws_last=round(hrv + 1.5 + e(5), 1), rmssd_night_mean=round(hrv * 0.85 + e(5), 1),
            resp=round(resp + e(0.35), 1), temp_dev=round(temp - 33.6 + e(0.1), 2),
            tst_min=round(tst + 6 + e(10)), in_bed_min=in_bed, eff=round(tst / in_bed * 100 + e(1.5), 1),
            light_min=round(light + e(20)), deep_min=round(deep + 10 + e(15)), rem_min=round(rem - 8 + e(15)),
            awake_min=in_bed - tst, need_min=round(need + e(12)), debt_min=round(max(0, need - 480) + e(10)),
            consistency=round(75 + e(6)), sleep_pct=round(min(100, perf + e(3))),
            recovery=round(max(0, min(100, rec + 1 + e(5)))),
            strain=round(max(0, strain - (2.5 if strength else 0) + e(0.9)), 1),
            observed_frac=obs, hr_valid_frac=0.95, max_gap_min=10, strength="false",
            sws_found="true", watch_min=0, rec_zbar=round(((rec / 100) and math.log(max(0.01, min(0.99, rec / 100)) / (1 - max(0.01, min(0.99, rec / 100)))) - 0.35) / 1.2 + e(0.15), 3),
            strain_load="", v_hist=";".join(map(str, vh)),
        ))
    H_C = ["Cycle start time", "Cycle end time", "Cycle timezone", "Recovery score %", "Resting heart rate (bpm)",
           "Heart rate variability (ms)", "Skin temp (celsius)", "Blood oxygen %", "Day Strain", "Energy burned (cal)",
           "Max HR (bpm)", "Average HR (bpm)", "Sleep onset", "Wake onset", "Sleep performance %", "Respiratory rate (rpm)",
           "Asleep duration (min)", "In bed duration (min)", "Light sleep duration (min)", "Deep (SWS) duration (min)",
           "REM duration (min)", "Awake duration (min)", "Sleep need (min)", "Sleep debt (min)", "Sleep efficiency %",
           "Sleep consistency %"]
    H_S = ["Cycle start time", "Cycle end time", "Cycle timezone", "Sleep onset", "Wake onset", "Sleep performance %",
           "Respiratory rate (rpm)", "Asleep duration (min)", "In bed duration (min)", "Light sleep duration (min)",
           "Deep (SWS) duration (min)", "REM duration (min)", "Awake duration (min)", "Sleep need (min)",
           "Sleep debt (min)", "Sleep efficiency %", "Sleep consistency %", "Nap"]
    H_W = ["Cycle start time", "Cycle end time", "Cycle timezone", "Workout start time", "Workout end time",
           "Duration (min)", "Activity name", "Activity Strain", "Energy burned (cal)", "Max HR (bpm)",
           "Average HR (bpm)", "HR Zone 1 %", "HR Zone 2 %", "HR Zone 3 %", "HR Zone 4 %", "HR Zone 5 %", "GPS enabled"]
    H_J = ["Cycle start time", "Cycle end time", "Cycle timezone", "Question text", "Answered yes", "Notes"]
    for name, h, rows in (("physiological_cycles.csv", H_C, cyc_rows[::-1]), ("sleeps.csv", H_S, sl_rows[::-1]),
                          ("workouts.csv", H_W, wk_rows[::-1]), ("journal_entries.csv", H_J, jr_rows[::-1])):
        with open(os.path.join(out, name), "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh, lineterminator="\n")
            w.writerow(h)
            w.writerows(rows)
    with open(os.path.join(out, "ritm_export.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(RITM_COLS)
        for r in our_rows:
            w.writerow([r.get(c, "") for c in RITM_COLS])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("compare", "calibrate"):
        p = sub.add_parser(name)
        p.add_argument("--whoop", required=True)
        p.add_argument("--ritm", required=True)
        p.add_argument("--md")
        p.add_argument("--json")
    p = sub.add_parser("synth")
    p.add_argument("--out", required=True)
    p.add_argument("--days", type=int, default=90)
    p.add_argument("--seed", type=int, default=7)
    a = ap.parse_args(argv)
    if a.cmd == "synth":
        synth(a.out, a.days, a.seed)
        print(f"синтетика: {a.days} дней → {a.out}")
        return 0
    whoop = load_whoop(a.whoop)
    if not whoop["cycles"]:
        print("В экспорте WHOOP нет physiological_cycles.csv — сверять нечего", file=sys.stderr)
        return 2
    ours = load_ritm(a.ritm)
    if a.cmd == "compare":
        rep = compare(whoop, ours)
        if a.md:
            with open(a.md, "w", encoding="utf-8") as fh:
                fh.write(report_md(rep, src=f"WHOOP: {a.whoop} ({', '.join(sorted(whoop['files']))}); Ритм: {a.ritm}"))
        js = report_json(rep)
        if a.json:
            with open(a.json, "w", encoding="utf-8") as fh:
                json.dump(js, fh, ensure_ascii=False, indent=1, sort_keys=True)
        print(f"чистых дней {rep['clean_days']}, кольца: {'ПРОХОДИТ' if pass_tab(rep, 'rings') else 'НЕ ПРОХОДИТ'}, "
              f"сон: {'ПРОХОДИТ' if pass_tab(rep, 'sleep') else 'НЕ ПРОХОДИТ'}")
        return 0
    res = calibrate(whoop, ours)
    print(json.dumps(res, ensure_ascii=False, indent=1))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(res, fh, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
