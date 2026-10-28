"""Draws the architecture and the delivery steps of the project as images for the README.

Diagram as code: the layers, steps and numbers are written here once, rendered to SVG (sharp, editable in
any design tool) and to PNG with Playwright (what GitHub shows). Same visual language as the dashboard:
dark graphite canvas, wine accent, gold for results.

    python scripts/build_architecture.py      # writes docs/images/architecture.(svg|png) and delivery_steps.(svg|png)
"""

from __future__ import annotations

from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "docs" / "images"
FONT = "Inter, Segoe UI, sans-serif"
MONO = "JetBrains Mono, Consolas, monospace"

# ------------------------------------------------------------------ palette (same as the dashboard)
BG_1, BG_2 = "#0E0B0C", "#1A1317"
CARD, CARD_2, LINE = "#1C1619", "#241C21", "#3A2E34"
INK, MUTED, DIM = "#F5EEF0", "#B3A4AA", "#7F7077"
WINE, WINE_DARK, ROSE = "#E11D48", "#9F1239", "#FDA4AF"
GOLD, GREEN, BLUE = "#F2B544", "#34D399", "#7DB3FF"

# Line icons, 24x24
ICONS = {
    "db": '<ellipse cx="12" cy="5.5" rx="7" ry="2.8"/><path d="M5 5.5v13c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8v-13"/>'
    '<path d="M5 12c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8"/>',
    "filter": '<path d="M4 5h16l-6 7.5V19l-4 1.5v-8z"/>',
    "star": '<path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"/>',
    "shield": '<path d="M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.9-4.3-1.7-7.5-5.3-7.5-9.9V6z"/><path d="M8.8 12.2l2.2 2.2 4.3-4.6"/>',
    "chart": '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
    "clock": '<circle cx="12" cy="12.5" r="8"/><path d="M12 8v4.5l3 2"/>',
    "code": '<path d="M8 7l-5 5 5 5M16 7l5 5-5 5M13.5 4l-3 16"/>',
    "search": '<circle cx="11" cy="11" r="6"/><path d="M15.5 15.5 20 20"/>',
    "pencil": '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>',
    "check": '<circle cx="12" cy="12" r="8.5"/><path d="M8 12.3l2.6 2.6 5.4-5.6"/>',
    "gauge": '<path d="M4 16a8 8 0 1 1 16 0"/><path d="M12 16l4.5-5"/><circle cx="12" cy="16" r="1.5"/>',
    "play": '<circle cx="12" cy="12" r="8.5"/><path d="M10 8.5l5 3.5-5 3.5z"/>',
}


def icon(name, x, y, size, stroke, width=1.9):
    k = size / 24
    return (
        f'<g transform="translate({x:.1f} {y:.1f}) scale({k:.4f})" fill="none" stroke="{stroke}" '
        f'stroke-width="{width:.2f}" stroke-linecap="round" stroke-linejoin="round">{ICONS[name]}</g>'
    )


def esc(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def txt(x, y, value, size=18, color=INK, weight=400, anchor="start", family=FONT, spacing=0):
    ls = f' letter-spacing="{spacing}"' if spacing else ""
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-family="{family}" font-size="{size}" font-weight="{weight}" '
        f'fill="{color}" text-anchor="{anchor}"{ls}>{esc(value)}</text>'
    )


def wrap(value: str, width_px: float, size: float) -> list[str]:
    """Splits a sentence into lines that fit a width (average Inter glyph = 0.53 x font size)."""
    per_line = max(8, int(width_px / (size * 0.53)))
    lines, current = [], ""
    for word in value.split():
        if len(current) + len(word) + 1 > per_line and current:
            lines.append(current)
            current = word
        else:
            current = f"{current} {word}".strip()
    if current:
        lines.append(current)
    return lines


def paragraph(x, y, value, width, size=16, color=MUTED, leading=1.42):
    out = []
    for i, line in enumerate(wrap(value, width, size)):
        out.append(txt(x, y + i * size * leading, line, size, color))
    return "".join(out), y + len(wrap(value, width, size)) * size * leading


def defs():
    return f"""<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="{BG_1}"/><stop offset="1" stop-color="{BG_2}"/></linearGradient>
  <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0"><stop stop-color="{ROSE}"/><stop offset="1" stop-color="{WINE_DARK}"/></linearGradient>
  <radialGradient id="glow" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(1800 0) scale(900)">
    <stop stop-color="{WINE}" stop-opacity="0.16"/><stop offset="1" stop-color="{WINE}" stop-opacity="0"/></radialGradient>
  <pattern id="dots" width="26" height="26" patternUnits="userSpaceOnUse"><circle cx="2" cy="2" r="1.1" fill="#fff" fill-opacity="0.04"/></pattern>
  <marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
    <path d="M0 0 L10 5 L0 10 z" fill="{ROSE}"/></marker>
  <marker id="arrow-gold" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
    <path d="M0 0 L10 5 L0 10 z" fill="{GOLD}"/></marker>
</defs>"""


def canvas(width, height, body, eyebrow, title, subtitle):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
{defs()}
<rect width="{width}" height="{height}" rx="28" fill="url(#bg)"/>
<rect width="{width}" height="{height}" rx="28" fill="url(#glow)"/>
<rect width="{width}" height="{height}" rx="28" fill="url(#dots)"/>
<g id="Header">
<circle cx="88" cy="78" r="30" fill="none" stroke="url(#accent)" stroke-width="2.5"/>{icon("shield", 70, 60, 36, ROSE, 2)}
{txt(136, 70, eyebrow, 17, ROSE, 600, spacing=4)}
{txt(136, 108, title, 38, INK, 800)}
{txt(width - 60, 70, "SQL Server 2022 · T-SQL · Power BI", 17, MUTED, 500, "end")}
{txt(width - 60, 100, subtitle, 17, DIM, 400, "end")}
<rect x="60" y="138" width="{width - 120}" height="1.5" fill="{LINE}"/><rect x="60" y="137.5" width="120" height="2.5" fill="url(#accent)"/>
</g>
{body}
</svg>"""


def chip(x, y, label, color=ROSE, fill=CARD_2, size=14, pad=12, family=FONT):
    w = len(label) * size * 0.56 + 2 * pad
    return (
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{size + 14}" rx="{(size + 14) / 2}" fill="{fill}" '
        f'stroke="{color}" stroke-opacity="0.55" stroke-width="1.2"/>'
        + txt(x + pad, y + size + 3.5, label, size, color, 600, family=family)
    ), w


# ------------------------------------------------------------------ 1. architecture
LAYERS = [
    {
        "n": "1",
        "icon": "db",
        "name": "Legacy source",
        "schema": "SeguroLegado · OLTP",
        "tech": "SQL Server · compat. 2012",
        "tables": ["Segurado", "Veiculo", "Corretor", "Produto", "Apolice", "ApoliceCobertura", "Sinistro", "SinistroMovimento"],
        "points": [
            "Dates kept as text, categories typed by hand",
            "CPFs that lost their leading zeros",
            "No foreign keys, only primary keys",
            "Reports ran here, against production",
        ],
        "foot": "Read only: the warehouse never writes here",
    },
    {
        "n": "2",
        "icon": "filter",
        "name": "ODS",
        "schema": "ods · 8 tables",
        "tech": "8 MERGE procedures",
        "points": [
            "Incremental by watermark (5-min overlap)",
            "CPF check digits, text dates, code mapping tables",
            "Upsert only when a value changed: re-runs touch 0 rows",
            "Rows that cannot be placed go to etl.rejected_row with reason and money",
            "Every row stamped with the run that changed it",
        ],
        "foot": "Cleaned, typed, current state",
    },
    {
        "n": "3",
        "icon": "star",
        "name": "Star schema",
        "schema": "dw · 7 dimensions · 4 facts",
        "tech": "Kimball · columnstore",
        "dims": ["Date", "Customer · SCD2", "Vehicle", "Broker", "Product", "Coverage", "Geography"],
        "facts": [
            ("Written premium", "transaction"),
            ("Earned premium / month", "snapshot · CCI"),
            ("Claim", "accumulating"),
            ("Claim movement", "transaction · CCI"),
        ],
        "foot": "Only what changed is rebuilt",
    },
    {
        "n": "4",
        "icon": "shield",
        "name": "Quality gate",
        "schema": "dq · 14 checks per run",
        "tech": "reconciled with the source",
        "points": [
            "Written premium = legacy, to the cent",
            "Earned premium = independent recalculation",
            "Claim money = legacy + rejected",
            "No orphan keys, unique grain, SCD2 history consistent",
            "4 info checks for the business teams",
        ],
        "foot": "passed · failed (not released) · error (rolled back)",
    },
    {
        "n": "5",
        "icon": "chart",
        "name": "Consumption",
        "schema": "mart · pbi",
        "tech": "views with business names",
        "points": [
            "4 marts: loss ratio, renewal rate, broker scorecard, theft recovery",
            "11 Power BI feed views, no personal data",
            "Parquet export for the PBIP project",
            "Power BI dashboard: 5 pages, 30 DAX measures",
        ],
        "foot": "One official definition per indicator",
    },
]


def architecture() -> tuple[str, int, int]:
    width, height = 1920, 1340
    parts = []

    # Orchestration band: what runs every night, in order
    oy = 172
    parts.append(
        f'<rect x="60" y="{oy}" width="{width - 120}" height="92" rx="20" fill="{CARD}" stroke="{LINE}" stroke-width="1.5"/>'
    )
    parts.append(f'<circle cx="112" cy="{oy + 46}" r="26" fill="{CARD_2}" stroke="{WINE_DARK}" stroke-width="1.5"/>')
    parts.append(icon("clock", 96, oy + 30, 32, ROSE))
    parts.append(txt(154, oy + 40, "ORCHESTRATION", 14, ROSE, 700, spacing=3))
    parts.append(txt(154, oy + 66, "SQL Server Agent · every night 02:30", 20, INK, 700))
    x = 600
    c, w = chip(x, oy + 30, "EXEC etl.usp_run  ·  one transaction", GOLD, size=15, family=MONO)
    parts.append(c)
    x += w + 26
    steps = ["1  ODS", "2  Dimensions", "3  Facts", "4  Quality gate"]
    for i, s in enumerate(steps):
        c, w = chip(x, oy + 30, s, ROSE, size=15)
        parts.append(c)
        if i < len(steps) - 1:
            parts.append(f'<path d="M{x + w + 6} {oy + 44.5} h16" stroke="{ROSE}" stroke-width="2" marker-end="url(#arrow)"/>')
        x += w + 30
    for label, color in (("passed", GREEN), ("failed", GOLD), ("error → rollback", WINE)):
        c, w = chip(x, oy + 30, label, color, size=14)
        parts.append(c)
        x += w + 10

    # Five layers, left to right
    top, card_h, gap = 300, 660, 52
    card_w = (width - 120 - gap * 4) / 5
    for i, layer in enumerate(LAYERS):
        x = 60 + i * (card_w + gap)
        parts.append(f'<g id="Layer {layer["n"]} {layer["name"]}">')
        parts.append(
            f'<rect x="{x:.1f}" y="{top}" width="{card_w:.1f}" height="{card_h}" rx="22" fill="{CARD}" stroke="{LINE}" stroke-width="1.5"/>'
        )
        parts.append(f'<rect x="{x + 26:.1f}" y="{top}" width="70" height="3.5" rx="1.75" fill="url(#accent)"/>')
        parts.append(
            f'<circle cx="{x + 52:.1f}" cy="{top + 56}" r="28" fill="{CARD_2}" stroke="{WINE_DARK}" stroke-width="1.5"/>'
        )
        parts.append(icon(layer["icon"], x + 35, top + 39, 34, ROSE))
        parts.append(txt(x + card_w - 26, top + 48, f"0{layer['n']}", 30, LINE, 800, "end"))
        parts.append(txt(x + 26, top + 118, layer["name"], 25, INK, 800))
        parts.append(txt(x + 26, top + 146, layer["schema"], 15, ROSE, 600, family=MONO))
        parts.append(txt(x + 26, top + 170, layer["tech"], 15, MUTED))
        parts.append(f'<rect x="{x + 26:.1f}" y="{top + 188}" width="{card_w - 52:.1f}" height="1" fill="{LINE}"/>')
        y = top + 222
        inner = card_w - 52
        if "tables" in layer:
            for k, t in enumerate(layer["tables"]):
                col, row = k % 2, k // 2
                parts.append(
                    f'<rect x="{x + 26 + col * (inner / 2 + 4):.1f}" y="{y + row * 38 - 20}" width="{inner / 2 - 4:.1f}" height="30" '
                    f'rx="8" fill="{CARD_2}" stroke="{LINE}"/>'
                )
                parts.append(txt(x + 36 + col * (inner / 2 + 4), y + row * 38, t, 11.5, INK, 500, family=MONO))
            y += 4 * 38 + 16
        if "dims" in layer:
            parts.append(txt(x + 26, y, "DIMENSIONS", 12, DIM, 700, spacing=2))
            y += 14
            cx, cy = x + 26, y
            for d in layer["dims"]:
                w = len(d) * 13 * 0.56 + 20
                if cx + w > x + card_w - 20:
                    cx, cy = x + 26, cy + 36
                parts.append(
                    f'<rect x="{cx:.1f}" y="{cy}" width="{w:.1f}" height="28" rx="14" fill="{CARD_2}" stroke="{BLUE}" stroke-opacity="0.5"/>'
                )
                parts.append(txt(cx + 10, cy + 19, d, 13, BLUE, 600))
                cx += w + 8
            y = cy + 62
            parts.append(txt(x + 26, y, "FACTS", 12, DIM, 700, spacing=2))
            y += 14
            for name, kind in layer["facts"]:
                parts.append(
                    f'<rect x="{x + 26:.1f}" y="{y}" width="{inner:.1f}" height="46" rx="10" fill="{CARD_2}" stroke="{GOLD}" stroke-opacity="0.45"/>'
                )
                parts.append(txt(x + 40, y + 20, name, 14, INK, 600))
                parts.append(txt(x + 40, y + 38, kind, 12, GOLD, 500))
                y += 54
        for point in layer.get("points", []):
            parts.append(f'<circle cx="{x + 31:.1f}" cy="{y - 5}" r="3.5" fill="{WINE}"/>')
            block, y = paragraph(x + 44, y, point, inner - 22, 15, INK if not point[0].isdigit() else INK)
            parts.append(block)
            y += 12
        # Footer of the card
        parts.append(
            f'<rect x="{x + 18:.1f}" y="{top + card_h - 62}" width="{card_w - 36:.1f}" height="44" rx="12" fill="{CARD_2}"/>'
        )
        block, _ = paragraph(x + 32, top + card_h - 35, layer["foot"], card_w - 64, 13, MUTED)
        parts.append(block)
        parts.append("</g>")
        # Arrow to the next layer
        if i < len(LAYERS) - 1:
            ax = x + card_w + 6
            parts.append(
                f'<path d="M{ax:.1f} {top + card_h / 2} h{gap - 14}" stroke="{ROSE}" stroke-width="2.5" marker-end="url(#arrow)"/>'
            )

    # Bottom: where the code is, and what the project proves
    by = 1000
    half = (width - 120 - 24) / 2
    parts.append(
        f'<rect x="60" y="{by}" width="{half:.1f}" height="300" rx="22" fill="{CARD}" stroke="{LINE}" stroke-width="1.5"/>'
    )
    parts.append(icon("code", 88, by + 26, 30, ROSE))
    parts.append(txt(130, by + 50, "Where the code is", 22, INK, 800))
    rows = [
        (
            "sql/legacy · sql/dw · sql/jobs",
            "T-SQL",
            "2,371 lines",
            "The warehouse itself: tables, 18 procedures, 15 views, Agent job",
            ROSE,
        ),
        ("src/insurance_dw", "Python", "1,098 lines", "Tooling: synthetic legacy data, deploy, run, benchmark, export", GOLD),
        ("tests · .github/workflows", "pytest · CI", "", "Unit, 14 integration tests on SQL Server 2022, Power BI gate", GREEN),
    ]
    y = by + 80
    for path, lang, lines, what, color in rows:
        parts.append(f'<rect x="88" y="{y}" width="{half - 56:.1f}" height="62" rx="10" fill="{CARD_2}"/>')
        parts.append(f'<rect x="88" y="{y}" width="5" height="62" rx="2.5" fill="{color}"/>')
        parts.append(txt(108, y + 26, path, 14, INK, 600, family=MONO))
        parts.append(txt(half + 60 - 200, y + 26, lang, 14, color, 700))
        parts.append(txt(half + 60 - 40, y + 26, lines, 14, MUTED, 500, "end"))
        parts.append(txt(108, y + 49, what, 13.5, MUTED))
        y += 70

    rx = 60 + half + 24
    parts.append(
        f'<rect x="{rx:.1f}" y="{by}" width="{half:.1f}" height="300" rx="22" fill="{CARD}" stroke="{LINE}" stroke-width="1.5"/>'
    )
    parts.append(icon("gauge", rx + 28, by + 26, 30, GOLD))
    parts.append(txt(rx + 70, by + 50, "What the project proves", 22, INK, 800))
    results = [
        ("608×", "fewer reads than the legacy report, same 90 lines"),
        ("0.00", "difference in premium and claim money"),
        ("0", "rows touched when a run is repeated"),
        ("1", "transaction per run: lands whole or rolls back"),
    ]
    kw = (half - 56 - 36) / 4
    for k, (big, small) in enumerate(results):
        kx = rx + 28 + k * (kw + 12)
        parts.append(f'<rect x="{kx:.1f}" y="{by + 82}" width="{kw:.1f}" height="192" rx="14" fill="{CARD_2}"/>')
        parts.append(f'<rect x="{kx + 18:.1f}" y="{by + 82}" width="44" height="3" rx="1.5" fill="{GOLD}"/>')
        parts.append(txt(kx + 18, by + 146, big, 40, GOLD, 800))
        block, _ = paragraph(kx + 18, by + 184, small, kw - 36, 14, MUTED)
        parts.append(block)

    body = "\n".join(parts)
    svg = canvas(
        width,
        height,
        body,
        "ARCHITECTURE",
        "Auto Insurance Data Warehouse",
        "legacy OLTP → ODS → star schema → quality gate → marts and Power BI",
    )
    return svg, width, height


# ------------------------------------------------------------------ 2. delivery steps
STEPS = [
    (
        "search",
        "Assess",
        "Profile the legacy database and time the loss ratio report (5.8 million reads). List the data defects.",
        "sql/legacy",
    ),
    (
        "pencil",
        "Design",
        "ODS next to the legacy system, star schema with one fact per question, address as SCD2. Decisions as ADRs.",
        "docs/adr",
    ),
    (
        "filter",
        "Build the ODS",
        "Incremental MERGE by watermark, set-based cleaning functions, rejected rows with reason and money.",
        "sql/dw 02 · 03 · 05",
    ),
    (
        "star",
        "Build the star",
        "Dimensions with unknown members, 4 facts at their grain, columnstore, rebuild only what changed.",
        "sql/dw 04 · 06 · 07",
    ),
    (
        "shield",
        "Gate the release",
        "Reconcile premium, earned premium and claim money with the source; one transaction, rollback on error.",
        "sql/dw 08 · 10",
    ),
    (
        "check",
        "Prove it",
        "Same 90 lines as the legacy report with 608× fewer reads; 14 integration tests on SQL Server 2022 in CI.",
        "tests · CI",
    ),
    (
        "play",
        "Operate & serve",
        "Nightly Agent job, runbook, business views and the Power BI feed; dashboard with 5 pages.",
        "sql/jobs · powerbi",
    ),
]


def delivery() -> tuple[str, int, int]:
    width, height = 1920, 730
    parts = []
    n = len(STEPS)
    gap = 22
    w = (width - 120 - gap * (n - 1)) / n
    top = 300
    # timeline line with numbered dots
    parts.append(
        f'<rect x="{60 + w / 2:.1f}" y="{top - 46}" width="{width - 120 - w:.1f}" height="3" rx="1.5" fill="url(#accent)"/>'
    )
    phases = [("PLAN", 0, 1), ("BUILD", 2, 4), ("PROVE & RUN", 5, 6)]
    for label, a, b in phases:
        xa = 60 + a * (w + gap)
        xb = 60 + b * (w + gap) + w
        parts.append(
            f'<rect x="{xa:.1f}" y="{top - 112}" width="{xb - xa:.1f}" height="34" rx="17" fill="{CARD}" stroke="{LINE}"/>'
        )
        parts.append(txt((xa + xb) / 2, top - 89, label, 14, ROSE, 700, "middle", spacing=4))
    for i, (ic, title, what, files) in enumerate(STEPS):
        x = 60 + i * (w + gap)
        cx = x + w / 2
        parts.append(f'<circle cx="{cx:.1f}" cy="{top - 44.5}" r="17" fill="{BG_1}" stroke="{ROSE}" stroke-width="2.5"/>')
        parts.append(txt(cx, top - 38, str(i + 1), 16, INK, 800, "middle"))
        parts.append(
            f'<rect x="{x:.1f}" y="{top}" width="{w:.1f}" height="390" rx="20" fill="{CARD}" stroke="{LINE}" stroke-width="1.5"/>'
        )
        parts.append(f'<rect x="{x + 22:.1f}" y="{top}" width="56" height="3" rx="1.5" fill="url(#accent)"/>')
        parts.append(
            f'<circle cx="{x + 50:.1f}" cy="{top + 58}" r="28" fill="{CARD_2}" stroke="{WINE_DARK}" stroke-width="1.5"/>'
        )
        parts.append(icon(ic, x + 33, top + 41, 34, ROSE))
        parts.append(txt(x + 22, top + 128, title, 23, INK, 800))
        block, _ = paragraph(x + 22, top + 166, what, w - 44, 15.5, MUTED, 1.5)
        parts.append(block)
        parts.append(f'<rect x="{x + 16:.1f}" y="{top + 322}" width="{w - 32:.1f}" height="48" rx="12" fill="{CARD_2}"/>')
        parts.append(txt(x + 30, top + 341, "DELIVERABLE", 11, DIM, 700, spacing=2))
        parts.append(txt(x + 30, top + 360, files, 12.5, GOLD, 600, family=MONO))
    body = "\n".join(parts)
    svg = canvas(width, height, body, "HOW IT WAS BUILT", "From assessment to operation", "plan → build → prove → run")
    return svg, width, height


def render(svgs: dict[str, tuple[str, int, int]]) -> None:
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        for name, (svg, w, h) in svgs.items():
            page = browser.new_page(viewport={"width": w, "height": h}, device_scale_factor=1)
            page.set_content(f"<html><body style='margin:0;background:transparent'>{svg}</body></html>")
            page.screenshot(path=str(OUT / f"{name}.png"), clip={"x": 0, "y": 0, "width": w, "height": h}, omit_background=True)
            page.close()
        browser.close()


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    svgs = {"architecture": architecture(), "delivery_steps": delivery()}
    for name, (svg, _, _) in svgs.items():
        (OUT / f"{name}.svg").write_text(svg, encoding="utf-8")
    render(svgs)
    print("written:", ", ".join(f"{n}.svg/.png" for n in svgs))


if __name__ == "__main__":
    main()
