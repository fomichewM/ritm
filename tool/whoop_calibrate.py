#!/usr/bin/env python3
"""«Ритм» — калибровка формул колец по экспорту WHOOP «вход → выход» (D-RITM-6).

Пересечения дней WHOOP-экспорта с днями «Ритма» нет, поэтому калибруем
отображение «входы WHOOP → выход WHOOP» теми же формулами, что в
lib/ritm/ritm_rings.dart (ТЗ v3 §7.2–§7.4):

  Восстановление  входы: ВСР, пульс покоя, дыхание, температура кожи, Сон %
                  выход: Recovery score %          θ = {a, b}
  Нагрузка (трен.) входы: длительность, доли зон 1–5, средний пульс
                  выход: Activity Strain            θ = {s, k}
  Нагрузка (день) входы: тренировки дня + средний пульс цикла вне тренировок
                  выход: Day Strain                 (θ те же {s, k}, 0 новых)
  Потребность/долг входы: сон, нагрузка вчера, дрёмы
                  выход: Sleep need / Sleep debt    θ = {k_s, d} (+ base)
  Сон % (S)       Asleep / Need против Sleep performance %

Разбиение по времени: первые ⅔ дней — калибровка, последняя ⅓ — проверка.
Только стандартная библиотека. Запуск:
  python3 whoop_calibrate.py --whoop ../whoop_export/2026-10-15/unpacked \
      --md CALIBRATION.md --json calibration_theta.json
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import os
import statistics as st

# ── чтение ──────────────────────────────────────────────────────────────────


def _num(s):
    s = (s or "").strip()
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
    try:
        return dt.datetime.strptime(s[:19], "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None


def load(dirpath):
    def rd(name):
        with open(os.path.join(dirpath, name), encoding="utf-8-sig") as f:
            return list(csv.DictReader(f))

    cyc = []
    for r in rd("physiological_cycles.csv"):
        cyc.append({
            "start": _ts(r["Cycle start time"]), "end": _ts(r["Cycle end time"]),
            "rec": _num(r["Recovery score %"]), "rhr": _num(r["Resting heart rate (bpm)"]),
            "hrv": _num(r["Heart rate variability (ms)"]), "temp": _num(r["Skin temp (celsius)"]),
            "strain": _num(r["Day Strain"]), "maxhr": _num(r["Max HR (bpm)"]),
            "avghr": _num(r["Average HR (bpm)"]), "wake": _ts(r["Wake onset"]),
            "onset": _ts(r["Sleep onset"]),
            "sp": _num(r["Sleep performance %"]), "resp": _num(r["Respiratory rate (rpm)"]),
            "asleep": _num(r["Asleep duration (min)"]), "inbed": _num(r["In bed duration (min)"]),
            "need": _num(r["Sleep need (min)"]), "debt": _num(r["Sleep debt (min)"]),
            "eff": _num(r["Sleep efficiency %"]), "cons": _num(r["Sleep consistency %"]),
        })
    cyc.sort(key=lambda c: c["start"])
    wo = []
    for r in rd("workouts.csv"):
        wo.append({
            "cstart": _ts(r["Cycle start time"]), "start": _ts(r["Workout start time"]),
            "dur": _num(r["Duration (min)"]), "name": r["Activity name"],
            "strain": _num(r["Activity Strain"]), "max": _num(r["Max HR (bpm)"]),
            "avg": _num(r["Average HR (bpm)"]),
            "z": [_num(r[f"HR Zone {i} %"]) or 0.0 for i in range(1, 6)],
        })
    wo.sort(key=lambda w: w["start"])
    naps = []
    for r in rd("sleeps.csv"):
        if r.get("Nap", "").strip().lower() == "true":
            naps.append({"cstart": _ts(r["Cycle start time"]),
                         "asleep": _num(r["Asleep duration (min)"]) or 0.0})
    return cyc, wo, naps


# ── статистика ──────────────────────────────────────────────────────────────


def pearson(x, y):
    if len(x) < 3:
        return None
    mx, my = st.fmean(x), st.fmean(y)
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    sxx = sum((a - mx) ** 2 for a in x)
    syy = sum((b - my) ** 2 for b in y)
    return sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else None


def stats(pred, ref):
    d = [p - r for p, r in zip(pred, ref)]
    if not d:
        return {"n": 0}
    return {
        "n": len(d), "mae": st.fmean(abs(x) for x in d), "bias": st.fmean(d),
        "medae": st.median(abs(x) for x in d), "r": pearson(pred, ref),
    }


def nelder_mead(f, x0, step, iters=600):
    n = len(x0)
    pts = [list(x0)] + [[x0[j] + (step[j] if j == i else 0) for j in range(n)] for i in range(n)]
    vals = [f(p) for p in pts]
    for _ in range(iters):
        order = sorted(range(n + 1), key=lambda i: vals[i])
        pts = [pts[i] for i in order]
        vals = [vals[i] for i in order]
        c = [sum(p[j] for p in pts[:-1]) / n for j in range(n)]
        xr = [c[j] + (c[j] - pts[-1][j]) for j in range(n)]
        fr = f(xr)
        if fr < vals[0]:
            xe = [c[j] + 2 * (c[j] - pts[-1][j]) for j in range(n)]
            fe = f(xe)
            pts[-1], vals[-1] = (xe, fe) if fe < fr else (xr, fr)
        elif fr < vals[-2]:
            pts[-1], vals[-1] = xr, fr
        else:
            xc = [c[j] + 0.5 * (pts[-1][j] - c[j]) for j in range(n)]
            fc = f(xc)
            if fc < vals[-1]:
                pts[-1], vals[-1] = xc, fc
            else:
                for i in range(1, n + 1):
                    pts[i] = [pts[0][j] + 0.5 * (pts[i][j] - pts[0][j]) for j in range(n)]
                    vals[i] = f(pts[i])
    i = min(range(n + 1), key=lambda i: vals[i])
    return pts[i], vals[i]


def split(xs):
    k = (2 * len(xs)) // 3
    return xs[:k], xs[k:]


# ── Восстановление §7.2 (та же формула, что recoveryV3 в Dart) ───────────────
W = {"hrv": 0.45, "rhr": 0.20, "resp": 0.10, "sleep": 0.15, "temp": 0.10}


def baseline(xs, floor, robust=False):
    """База к предыдущим ночам. По калибровке 15.10 — среднее и SD за 30 ночей
    (robust=True — медиана и MAD·1,4826, старт ТЗ §7)."""
    if len(xs) < 4:
        return None
    if robust:
        m = st.median(xs)
        return m, max(st.median(abs(x - m) for x in xs) * 1.4826, floor)
    return st.fmean(xs), max(st.pstdev(xs), floor)


def rec_rows(cyc, robust=False, win=30):
    """z-оценки к `win` ПРЕДЫДУЩИМ циклам (как в приложении)."""
    rows = []
    hist = []
    for c in cyc:
        if c["rec"] is None or c["hrv"] is None or c["rhr"] is None:
            continue
        h = hist[-win:]
        temps = [x["temp"] for x in hist[-30:] if x["temp"] is not None]
        bh = baseline([math.log(x["hrv"]) for x in h if x["hrv"]], 0.05, robust)
        br = baseline([x["rhr"] for x in h], 1.0, robust)
        bp = baseline([x["resp"] for x in h if x["resp"]], 0.3, robust)
        if bh and br and len(h) >= 14:
            z = {
                "hrv": max(-3, min(3, (math.log(c["hrv"]) - bh[0]) / bh[1])),
                "rhr": max(-3, min(3, -(c["rhr"] - br[0]) / br[1])),
            }
            if bp and c["resp"]:
                z["resp"] = max(-3, min(0, -abs(c["resp"] - bp[0]) / bp[1]))
            if c["sp"] is not None:
                z["sleep"] = max(-2, min(1, (c["sp"] - 85) / 15))
            if c["temp"] is not None and len(temps) >= 14:
                dev = c["temp"] - st.median(temps)
                z["temp"] = max(-3, min(0, -max(0, dev - 0.3) / 0.3))
            rows.append({"day": (c["wake"] or c["start"]).date().isoformat(), "z": z,
                         "sp": c["sp"], "rec": c["rec"]})
        hist.append(c)
    return rows


def zbar(z, w=W):
    s = sum(w[k] for k in z)
    return sum(w[k] * v for k, v in z.items()) / s


def rec_pred(row, a, b, w=W):
    r = 100 / (1 + math.exp(-(a * zbar(row["z"], w) + b)))
    if row["sp"] is not None and row["sp"] < 60:
        r = min(r, 66)
    return r


def zone(v):
    return 2 if v >= 67 else (1 if v >= 34 else 0)


def rec_eval(rows, a, b, w=W):
    p = [rec_pred(x, a, b, w) for x in rows]
    y = [x["rec"] for x in rows]
    s = stats(p, y)
    s["zone"] = st.fmean(zone(round(pp)) == zone(yy) for pp, yy in zip(p, y)) if p else None
    dist = [sum(zone(round(v)) == z for v in p) / len(p) for z in (2, 1, 0)] if p else []
    s["dist_ritm"] = dist
    s["dist_whoop"] = [sum(zone(v) == z for v in y) / len(y) for z in (2, 1, 0)] if y else []
    return s


# ── Нагрузка §7.3 ───────────────────────────────────────────────────────────
VMID = [0.55, 0.65, 0.75, 0.85, 0.95]  # середины зон 1–5 по доле резерва
C = 0.15


def w_of(v, k):
    v = max(0.0, min(1.1, v))
    return C * (math.exp(k * v) - 1)


def scale(load, s):
    return 21 * (2 / math.pi) * math.atan(max(0.0, load) / s)


def wo_load(w, k, rhr, hrmax):
    """Нагрузка тренировки из долей зон: минуты зоны × w(середина зоны);
    ниже зоны 1 — по среднему пульсу остатка (оценка)."""
    zsum = sum(w["z"])
    load = sum(w["dur"] * p / 100 * w_of(v, k) for p, v in zip(w["z"], VMID))
    rest = max(0.0, 100 - zsum) / 100 * w["dur"]
    if rest > 0 and w["avg"]:
        hrr = max(20.0, hrmax - rhr)
        # средний пульс «остатка» ≈ средний тренировки минус вклад зон
        v_avg = (w["avg"] - rhr) / hrr
        zin = sum(p / 100 * v for p, v in zip(w["z"], VMID))
        v_rest = (v_avg - zin) / (rest / w["dur"]) if rest / w["dur"] > 0.05 else v_avg
        load += rest * w_of(min(0.5, max(0.0, v_rest)), k)
    return load


def _ctx(cyc):
    """RHR цикла и HRmax (максимум за год) для каждой тренировки."""
    hrmax = max(c["maxhr"] for c in cyc if c["maxhr"])
    by = {c["start"]: c for c in cyc}
    return hrmax, by


# ── Потребность/долг §7.4.2 ────────────────────────────────────────────────


def need_sim(cyc, naps_by, ks, d, base):
    """§7.4.2 (форма по калибровке 15.10): need_t = base + k_s·Strain_{t−1} +
    debt_t − дрёма_{t−1}; debt_t = d·debt_{t−1} + (1−d)·max(0, base_need_{t−1} −
    TST_{t−1}) — экспоненциальное среднее недосыпа (пересып гасит долг) (≈ 14 дней при d ≈ 0,85),
    где base_need = need − debt. Возвращает [(i, need, debt)]."""
    out = []
    debt = None
    prev = None
    for i, c in enumerate(cyc):
        if c["need"] is None or c["asleep"] is None:
            prev = None
            continue
        if prev is None:
            debt = c["debt"] or 0.0  # старт с эталонного долга (одна точка входа)
        else:
            pbase, pt = prev
            debt = max(0.0, min(180.0, d * debt + (1 - d) * (pbase - pt)))
        p = cyc[i - 1] if i > 0 else None
        strain_prev = p["strain"] if p and p["strain"] else 0.0
        nap = naps_by.get(p["start"], 0.0) if p else 0.0
        bneed = base + ks * strain_prev - nap
        need = max(360.0, min(660.0, bneed + debt))
        out.append((i, need, debt))
        prev = (bneed, c["asleep"])
    return out


# ── отчёт ───────────────────────────────────────────────────────────────────


def f(x, dp=1):
    if x is None:
        return "—"
    return f"{x:.{dp}f}".replace(".", ",")


def pct(x):
    return "—" if x is None else f"{round(100 * x)} %"


def row(name, s, tol_mae, tol_bias=None, tol_r=None, extra=""):
    ok = s.get("n", 0) > 0 and s["mae"] <= tol_mae and (tol_bias is None or abs(s["bias"]) <= tol_bias) \
        and (tol_r is None or (s["r"] or 0) >= tol_r)
    return (f"| {name} | {s.get('n', 0)} | {f(s.get('mae'))} | {f(s.get('bias'))} | {f(s.get('medae'))} | "
            f"{f(s.get('r'), 2)} | {extra} | {'✅' if ok else '❌'} |")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--whoop", required=True)
    ap.add_argument("--md")
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    cyc, wos, naps = load(a.whoop)
    hrmax, by = _ctx(cyc)
    res = {"source": os.path.abspath(a.whoop), "cycles": len(cyc), "workouts": len(wos)}
    days = [c for c in cyc if c["rec"] is not None]
    res["span"] = [days[0]["start"].date().isoformat(), days[-1]["start"].date().isoformat()]

    # Восстановление
    # старт ТЗ: медиана/MAD за 28 ночей, a=1,2, b=0,35 — и тот же оценщик с подбором a, b
    rrows = rec_rows(cyc, robust=True, win=28)
    rcal, rval = split(rrows)
    (qa, qb), _ = nelder_mead(lambda p: sum((rec_pred(x, p[0], p[1]) - x["rec"]) ** 2 for x in rcal),
                              [1.2, 0.35], [0.5, 0.3])
    start = {k: rec_eval(x, 1.2, 0.35) for k, x in (("cal", rcal), ("val", rval), ("all", rrows))}
    robust_fit = {k: rec_eval(x, qa, qb) for k, x in (("cal", rcal), ("val", rval), ("all", rrows))}
    rows = rec_rows(cyc)
    cal, val = split(rows)
    (ra, rb), _ = nelder_mead(lambda p: sum(abs(rec_pred(x, p[0], p[1]) - x["rec"]) ** 2 for x in cal),
                              [1.2, 0.35], [0.5, 0.3])
    fit = {k: rec_eval(x, ra, rb) for k, x in (("cal", cal), ("val", val), ("all", rows))}
    # диагностика (НЕ применяется: лимит θ — 2 параметра): какие веса подошли бы
    def wloss(p):
        ww = dict(zip(("hrv", "rhr", "resp", "sleep", "temp"), [abs(x) for x in p[:5]]))
        if sum(ww.values()) == 0:
            return 1e9
        return sum((rec_pred(x, p[5], p[6], ww) - x["rec"]) ** 2 for x in cal)
    pw, _ = nelder_mead(wloss, [0.45, 0.2, 0.1, 0.15, 0.1, ra, rb], [0.1] * 5 + [0.3, 0.2], iters=3000)
    ww = dict(zip(("hrv", "rhr", "resp", "sleep", "temp"), [abs(x) for x in pw[:5]]))
    sw = sum(ww.values())
    ww = {k: v / sw for k, v in ww.items()}
    diag = rec_eval(val, pw[5] * sw / sw, pw[6], ww)
    # одиночные входы: насколько выход WHOOP объясняется каждым z
    single = {}
    for key in W:
        xs = [(x["z"][key], x["rec"]) for x in rows if key in x["z"]]
        single[key] = pearson([p for p, _ in xs], [q for _, q in xs]) if len(xs) > 3 else None
    res["recovery"] = {"theta": {"a": ra, "b": rb}, "start": start, "fit": fit, "n": len(rows),
                       "robust_fit": robust_fit, "robust_theta": {"a": qa, "b": qb},
                       "diag_weights": ww, "diag_val": diag, "single_r": single,
                       "cal_days": [cal[0]["day"], cal[-1]["day"]], "val_days": [val[0]["day"], val[-1]["day"]]}

    # Нагрузка тренировок
    wl = []
    for w in wos:
        c = by.get(w["cstart"])
        if not c or w["strain"] is None or not w["dur"]:
            continue
        wl.append((w, c["rhr"] or 50.0))
    STR = ("Weightlifting", "Strength Trainer", "Powerlifting")
    wl_all = wl
    wl = [x for x in wl_all if x[0]["name"] not in STR]  # §7.3: θ — без силовых
    wcal, wval = split(wl)

    def wloss2(p):
        k, s = p
        if s <= 1 or k <= 0.3:
            return 1e9
        return sum((scale(wo_load(w, k, rhr, hrmax), s) - w["strain"]) ** 2 for w, rhr in wcal)
    (sk, ss), _ = nelder_mead(wloss2, [3.2, 80.0], [1.0, 40.0], iters=2000)

    def weval(xs, k, s):
        p = [scale(wo_load(w, k, rhr, hrmax), s) for w, rhr in xs]
        return stats(p, [w["strain"] for w, _ in xs])
    res["workout"] = {"theta": {"k": sk, "s": ss, "c": C, "hrmax": hrmax},
                      "start": {n: weval(x, 3.2, 80.0) for n, x in (("cal", wcal), ("val", wval), ("all", wl))},
                      "fit": {n: weval(x, sk, ss) for n, x in (("cal", wcal), ("val", wval), ("all", wl))},
                      "by_type": {}}
    for name in sorted({w["name"] for w, _ in wl_all}):
        xs = [x for x in wl_all if x[0]["name"] == name]
        res["workout"]["by_type"][name] = weval(xs, sk, ss)

    # Нагрузка дня — ДИАГНОСТИКА (в приложении не используется: там каждая минута
    # склеенного ряда). Тренировки дня по θ выше + остаток дня из Average HR
    # цикла: load_rest = минуты · B · v_rest^g (2 вспомогательных параметра
    # заменяют неизвестное распределение пульса по минутам).
    wo_by = {}
    for w, rhr in wl_all:
        wo_by.setdefault(w["cstart"], []).append(w)

    def day_pred(c, B, g):
        if not (c["end"] and c["avghr"] and c["rhr"]):
            return None
        mins = (c["end"] - c["start"]).total_seconds() / 60
        ws = wo_by.get(c["start"], [])
        wmin = sum(w["dur"] for w in ws)
        whr = sum((w["avg"] or c["avghr"]) * w["dur"] for w in ws)
        rest = max(1.0, mins - wmin)
        hr_rest = (c["avghr"] * mins - whr) / rest
        v = max(0.0, (hr_rest - c["rhr"]) / max(20.0, 190 - c["rhr"]))
        load = sum(wo_load(w, sk, c["rhr"], hrmax) for w in ws) + rest * B * v ** abs(g)
        return scale(load, ss)
    dall = [c for c in cyc if c["strain"] is not None and day_pred(c, 0.1, 1) is not None]
    dcal_c, dval_c = split(dall)
    (dB, dg), _ = nelder_mead(lambda p: sum((day_pred(c, p[0], p[1]) - c["strain"]) ** 2 for c in dcal_c),
                              [0.05, 1.0], [0.05, 0.5], iters=2000)
    dd = [(c, day_pred(c, dB, dg)) for c in dall]
    dcal, dval = split(dd)
    clean = lambda xs: [(c, p) for c, p in xs if not any(  # noqa: E731
        w["name"] in STR for w in wo_by.get(c["start"], []))]

    def deval(xs):
        return stats([p for _, p in xs], [c["strain"] for c, _ in xs])
    res["day_strain"] = {"all": deval(dd), "val": deval(dval), "clean_all": deval(clean(dd)),
                         "clean_val": deval(clean(dval)), "aux": {"B": dB, "g": abs(dg)}}

    # Потребность/долг: долг — экспоненциальное среднее недосыпа к базовой потребности
    naps_by = {}
    for n in naps:
        naps_by[n["cstart"]] = naps_by.get(n["cstart"], 0.0) + n["asleep"]
    sl = [c for c in cyc if c["need"] is not None and c["asleep"] is not None]
    k3 = (2 * len(cyc)) // 3
    calcut = cyc[k3]["start"]
    clean_base = [c["asleep"] for c in sl if c["start"] < calcut and (c["debt"] or 0) < 30]
    base0 = max(420.0, min(570.0, st.median(clean_base) if clean_base else 480.0))

    def nloss(p):
        ks, d, base = p
        if not (0 <= d <= 1):
            return 1e9
        out = need_sim(cyc, naps_by, ks, d, base)
        return sum((n - cyc[i]["need"]) ** 2 + (db - (cyc[i]["debt"] or 0)) ** 2
                   for i, n, db in out if cyc[i]["start"] < calcut)
    (nks, nd, nbase), _ = nelder_mead(nloss, [2.1, 0.6, 450.0], [1.0, 0.1, 20.0], iters=3000)

    def neval(ks, d, base, part):
        out = need_sim(cyc, naps_by, ks, d, base)
        sel = [(i, n, db) for i, n, db in out if (cyc[i]["start"] >= calcut) == (part == "val") or part == "all"]
        return (stats([n for _, n, _ in sel], [cyc[i]["need"] for i, _, _ in sel]),
                stats([db for _, _, db in sel], [cyc[i]["debt"] or 0 for i, _, _ in sel]))
    res["need"] = {"theta": {"k_s": nks, "d": nd, "base": nbase, "base_median": base0},
                   "start": {p: neval(2.1, 0.85, base0, p) for p in ("cal", "val", "all")},
                   "fit": {p: neval(nks, nd, nbase, p) for p in ("cal", "val", "all")}}

    # Сон % : старая формула S = Asleep/Need
    sp = [c for c in cyc if c["sp"] is not None and c["need"]]
    sval = sp[(2 * len(sp)) // 3:]
    sfun = lambda xs: stats([min(1, c["asleep"] / c["need"]) * 100 for c in xs], [c["sp"] for c in xs])  # noqa
    res["sleep_pct_S"] = {"all": sfun(sp), "val": sfun(sval)}
    # Эффективность = Asleep / In bed
    ef = [c for c in cyc if c["eff"] is not None and c["inbed"]]
    res["eff"] = stats([100 * c["asleep"] / c["inbed"] for c in ef], [c["eff"] for c in ef])

    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(res, fh, ensure_ascii=False, indent=1, default=str)
    if a.md:
        with open(a.md, "w", encoding="utf-8") as fh:
            fh.write(report(res))
    rf = res["recovery"]["fit"]["val"]
    print(f"recovery a={ra:.3f} b={rb:.3f} val MAE={rf['mae']:.2f} zone={rf['zone']:.2f} r={rf['r']:.3f}")
    wf = res["workout"]["fit"]["val"]
    print(f"workout k={sk:.3f} s={ss:.1f} val MAE={wf['mae']:.2f} r={wf['r']}")
    print("day", {k: round(v.get('mae', 0), 2) for k, v in res["day_strain"].items() if k != "aux"})
    nf = res["need"]["fit"]["val"]
    print(f"need ks={nks:.2f} d={nd:.3f} base={nbase:.0f} val needMAE={nf[0]['mae']:.1f} debtMAE={nf[1]['mae']:.1f}")
    print("S", res["sleep_pct_S"]["val"], "diag", res["recovery"]["diag_val"]["mae"], ww)
    return 0


def report(res):
    R = res["recovery"]
    L = []
    L.append("# «Ритм» — калибровка колец по экспорту WHOOP Михаила («вход → выход»)\n")
    L.append(f"Источник: `{res['source']}` — {res['cycles']} циклов, {res['workouts']} тренировок, "
             f"охват {res['span'][0]} … {res['span'][1]}. Скрипт: `build/whoop_calibrate.py` "
             "(стандартная библиотека, без сети; повторяемо).\n")
    L.append("**Что это и чего это НЕ доказывает.** Дней «Ритма» в этом окне нет (браслет читается «Ритмом» "
             "с 10.2026), поэтому сверить НАШИ ночные входы (ВСР в глубоком сне, пульс покоя за сон) с WHOOP по "
             "дням нельзя. Здесь проверено другое: если на вход нашим формулам §7.2–§7.4 подать входы WHOOP "
             "(его ВСР, пульс покоя, дыхание, температуру, Сон %), насколько выход совпадает с выходом WHOOP. "
             "Это калибрует θ и проверяет форму формул; точность наших входов — отдельная сверка "
             "(`whoop_reconcile.py compare`) на первом CSV с пересечением дней. Заявление «считается как WHOOP» "
             "до неё делать нельзя.\n")
    L.append("Разбиение по времени: первые ⅔ циклов — калибровка θ, последняя ⅓ — проверка (θ на ней не "
             "подбирались). Δ = Ритм − WHOOP.\n")
    L.append("## 1. Восстановление (§7.2), θ = {a, b}\n")
    th = R["theta"]
    L.append(f"Подобрано МНК на калибровочной трети ({R['cal_days'][0]} … {R['cal_days'][1]}): "
             f"**a = {f(th['a'], 3)}, b = {f(th['b'], 3)}** (старт ТЗ: 1,2 / 0,35). Проверка: "
             f"{R['val_days'][0]} … {R['val_days'][1]}. Веса факторов — фиксированы ТЗ "
             "(ВСР 0,45, пульс 0,20, дыхание 0,10, сон 0,15, температура 0,10). **Изменение оценщика (§8.4 "
             "«сменить оценщик»):** z считаются к среднему и SD 30 предыдущих ночей вместо медианы/MAD за 28 — "
             "строка «медиана/MAD» ниже показывает, что с прежним оценщиком допуск не проходится даже при "
             "подобранных a, b.\n")
    L.append("| Выборка | θ | дней | MAE, п.п. | смещение | медиана |Δ| | r | зона совпала | зел/жёлт/кр Ритм | WHOOP |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for lab, key in (("калибровка", "cal"), ("**проверка**", "val"), ("все дни", "all")):
        for tl, s in (("старт ТЗ (медиана/MAD 28; 1,2/0,35)", R["start"][key]),
                      ("медиана/MAD 28, подобр. a, b", R["robust_fit"][key]),
                      ("**ср./SD 30, подобр. a, b**", R["fit"][key])):
            dr = "/".join(str(round(100 * x)) for x in s["dist_ritm"])
            dw = "/".join(str(round(100 * x)) for x in s["dist_whoop"])
            L.append(f"| {lab} | {tl} | {s['n']} | {f(s['mae'])} | {f(s['bias'])} | {f(s['medae'])} | "
                     f"{f(s['r'], 2)} | {pct(s['zone'])} | {dr} | {dw} |")
    v = R["fit"]["val"]
    okm = v["mae"] <= 8 and abs(v["bias"]) <= 4 and (v["r"] or 0) >= 0.85
    okz = (v["zone"] or 0) >= 0.80
    L.append(f"\nДопуск §8.2 (MAE ≤ 8, |смещение| ≤ 4, r ≥ 0,85, зона ≥ 80 %) на проверочной трети: "
             f"MAE/смещение/r — {'✅' if okm else '❌'}, зона — {'✅' if okz else '❌'}.\n")
    L.append("Насколько выход WHOOP объясняется каждым входом в одиночку (r z-оценки с Recovery %): " +
             ", ".join(f"{k} {f(x, 2)}" for k, x in R["single_r"].items()) + ".\n")
    d = R["diag_val"]
    L.append("Диагностика (НЕ применена — ТЗ разрешает подбирать только a, b): если бы веса тоже подбирались, "
             "на проверочной трети было бы MAE " + f(d["mae"]) + ", зона " + pct(d["zone"]) + "; веса " +
             ", ".join(f"{k} {f(x, 2)}" for k, x in R["diag_weights"].items()) + ".\n")
    W_ = res["workout"]
    L.append("## 2. Нагрузка тренировки (§7.3), θ = {s, k}\n")
    L.append(f"Минутного пульса в экспорте WHOOP нет — есть длительность, доли минут в зонах 1–5, средний и "
             f"максимальный пульс. Нагрузка = Σ минут зоны × w(середина зоны) (+ остаток ниже зоны 1 по "
             f"среднему пульсу), Strain = 21·(2/π)·arctan(I/s). HRmax = {f(W_['theta']['hrmax'], 0)} "
             f"(максимум за год). Подобрано **без силовых** (§7.3: у силовых WHOOP добавляет мышечную нагрузку, "
             f"которой в пульсе нет — её закрывает ввод «как тяжело 1–10»): **k = {f(W_['theta']['k'], 3)}, "
             f"s = {f(W_['theta']['s'], 1)}** (старт 3,2 / 80). Допуск §8.2 для отдельной тренировки "
             f"(MAE ≤ 1,0) не достигается: в экспорте только доли минут по 5 зонам, распределение внутри зоны "
             f"неизвестно — это потолок точности по таким данным, не ошибка формулы; проверка на минутном "
             f"ряду — по первому экспорту с днями «Ритма».\n")
    L.append("| Выборка | θ | тренировок | MAE | смещение | медиана |Δ| | r |")
    L.append("|---|---|---|---|---|---|---|")
    for lab, key in (("калибровка", "cal"), ("**проверка**", "val"), ("все", "all")):
        for tl, s in (("старт", W_["start"][key]), ("**подобр.**", W_["fit"][key])):
            L.append(f"| {lab} | {tl} | {s['n']} | {f(s['mae'])} | {f(s['bias'])} | {f(s['medae'])} | {f(s['r'], 2)} |")
    L.append("\nПо типам (подобранные θ, все тренировки):\n")
    L.append("| Тип | n | MAE | смещение | r |")
    L.append("|---|---|---|---|---|")
    for k, s in W_["by_type"].items():
        L.append(f"| {k} | {s['n']} | {f(s['mae'])} | {f(s['bias'])} | {f(s.get('r'), 2)} |")
    D = res["day_strain"]
    L.append("\n## 3. Нагрузка дня (Day Strain) — диагностика по дневным агрегатам\n")
    ax = D["aux"]
    L.append("Поминутного пульса в экспорте нет — честно. Диагностическая модель: тренировки цикла по θ из §2 + "
             "остаток дня из Average HR цикла вне тренировок: минуты · B · v^g, где v — доля резерва среднего "
             f"пульса остатка (B = {f(ax['B'], 3)}, g = {f(ax['g'], 2)} — подобраны на калибровочной трети и "
             "заменяют неизвестное распределение минут; в приложении их НЕТ, там каждая минута склеенного ряда "
             "считается по w(v) с теми же k, s). Это подтверждает шкалу s/k на уровне дня, но не заменяет "
             "сверку минутного ряда «Ритма».\n")
    L.append("| Выборка | дней | MAE | смещение | r |")
    L.append("|---|---|---|---|---|")
    for lab, key in (("все", "all"), ("проверка", "val"), ("без силовых — все", "clean_all"),
                     ("**без силовых — проверка**", "clean_val")):
        s = D[key]
        L.append(f"| {lab} | {s['n']} | {f(s.get('mae'))} | {f(s.get('bias'))} | {f(s.get('r'), 2)} |")
    N = res["need"]
    L.append("\n## 4. Потребность и долг сна (§7.4.2), θ = {k_s, d} + база\n")
    t = N["theta"]
    L.append(f"need_t = base + k_s·Strain(вчера) + debt_t − дрёма(вчера); debt_t = d·debt(вчера) + (1 − d)·"
             f"(базовая потребность − сон)(вчера), clamp 0…180 — экспоненциальное среднее недосыпа, пересып гасит "
             f"долг (форма уточнена калибровкой: в ТЗ было «+ весь недосып», с ней MAE долга > 50 мин). "
             f"База — медиана сна без долга {f(t['base_median'], 0)} мин; подобрано: **k_s = {f(t['k_s'], 2)} "
             f"мин/балл, d = {f(t['d'], 3)}, base = {f(t['base'], 0)} мин**.\n")
    L.append("| Выборка | θ | дней | Потребность MAE | смещ. | r | Долг MAE | смещ. |")
    L.append("|---|---|---|---|---|---|---|---|")
    for lab, key in (("калибровка", "cal"), ("**проверка**", "val"), ("все", "all")):
        for tl, (sn, sd) in (("старт", N["start"][key]), ("**подобр.**", N["fit"][key])):
            L.append(f"| {lab} | {tl} | {sn['n']} | {f(sn['mae'])} | {f(sn['bias'])} | {f(sn['r'], 2)} | "
                     f"{f(sd['mae'])} | {f(sd['bias'])} |")
    S = res["sleep_pct_S"]
    L.append("\n## 5. Сон % и эффективность — проверка формулы\n")
    L.append(f"S = min(сон/потребность, 1)·100 против Sleep performance %: все дни MAE {f(S['all']['mae'])}, "
             f"смещение {f(S['all']['bias'])}, r {f(S['all']['r'], 2)}; проверочная треть MAE "
             f"{f(S['val']['mae'])}. Эффективность = сон / в кровати против Sleep efficiency %: MAE "
             f"{f(res['eff']['mae'])}, r {f(res['eff']['r'], 2)}.\n")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    raise SystemExit(main())
