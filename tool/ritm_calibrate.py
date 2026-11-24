#!/usr/bin/env python3
"""«Ритм» — калибровка θ по CSV WHOOP (ТЗ v3 §8.3 п. 2): {a, b} Восстановления
и {s, k} Нагрузки МНК по калибровочной трети, проверка на проверочной.
Обёртка над tool/ritm_compare.py calibrate (один код сверки на всё).

  python3 tool/ritm_calibrate.py --whoop DIR|ZIP --ritm ritm_export.csv [--json theta.json]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ritm_compare  # noqa: E402

if __name__ == "__main__":
    sys.exit(ritm_compare.main(["calibrate", *sys.argv[1:]]))
