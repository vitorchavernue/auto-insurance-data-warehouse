"""Command line.

    python -m insurance_dw deploy                 # create SeguroLegado and SeguroDW from scratch
    python -m insurance_dw seed                   # legacy system as it is on 30/09/2026
    python -m insurance_dw run --as-of 2026-09-30 --mode full
    python -m insurance_dw activity               # one month of business in the legacy system
    python -m insurance_dw run --as-of 2026-10-31 # incremental run
    python -m insurance_dw benchmark --year 2026 --closing 2026-10-31
    python -m insurance_dw demo                   # all of the above, in order

Exit code 1 when a run does not pass the data quality gate (schedulers stop the chain),
2 when it stopped with an error.
"""

from __future__ import annotations

import argparse
import json
from datetime import date

from insurance_dw import benchmark, deploy, run
from insurance_dw.seed import FIRST_LOAD, MONTH_LATER

EXIT = {"passed": 0, "failed": 1, "error": 2}


def _print_run(result: dict) -> int:
    print(json.dumps({k: str(v) for k, v in result.items() if k in ("run_id", "as_of_date", "mode", "status", "error_message")}))
    return EXIT.get(result["status"], 2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="insurance_dw")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("deploy", help="create both databases and run every SQL script")
    seed = sub.add_parser("seed", help="fill the legacy system (state on the day of the first load)")
    seed.add_argument("--scale", type=float, default=1.0)
    act = sub.add_parser("activity", help="apply one month of business to the legacy system")
    act.add_argument("--scale", type=float, default=1.0)
    run_p = sub.add_parser("run", help="load the warehouse and run the data quality gate")
    run_p.add_argument("--as-of", type=date.fromisoformat, default=None)
    run_p.add_argument("--mode", choices=["incremental", "full"], default="incremental")
    bench = sub.add_parser("benchmark", help="legacy report vs warehouse: time, reads and identical numbers")
    bench.add_argument("--year", type=int, default=2026)
    bench.add_argument("--closing", type=date.fromisoformat, default=MONTH_LATER)
    demo = sub.add_parser("demo", help="deploy, first load, one month of activity, incremental load, benchmark")
    demo.add_argument("--scale", type=float, default=1.0)
    args = parser.parse_args(argv)

    if args.command == "deploy":
        deploy.deploy()
        print("SeguroLegado and SeguroDW created")
        return 0
    if args.command == "seed":
        print(json.dumps(deploy.load_legacy(args.scale)))
        return 0
    if args.command == "activity":
        print(json.dumps(deploy.apply_month_of_activity(args.scale)))
        return 0
    if args.command == "run":
        return _print_run(run.run_etl(args.as_of, args.mode))
    if args.command == "benchmark":
        result = benchmark.run_benchmark(args.year, args.closing)
        summary = {"legacy": result["legacy"], "warehouse": result["warehouse"], "differences": len(result["differences"])}
        print(json.dumps(summary))
        return 0 if not result["differences"] else 1
    if args.command == "demo":
        deploy.deploy()
        deploy.load_legacy(args.scale)
        codes = [_print_run(run.run_etl(FIRST_LOAD, "full"))]
        deploy.apply_month_of_activity(args.scale)
        codes.append(_print_run(run.run_etl(MONTH_LATER, "incremental")))
        result = benchmark.run_benchmark(MONTH_LATER.year, MONTH_LATER)
        codes.append(0 if not result["differences"] else 1)
        return max(codes)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
