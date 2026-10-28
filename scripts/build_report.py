"""Builds the Insurance Performance report (PBIR format) and its designed page backgrounds from one layout spec.

Report as code: every page, visual, position and format is defined here, so a layout change is a
reviewed diff instead of clicks. Each visual gets a frame drawn in the page background (SVG for
design tools, PNG for Power BI) at exactly the same position (Power BI 1280x720 = SVG 1920x1080 / 1.5).

    python scripts/build_report.py            # write the report pages and the SVG backgrounds
    python scripts/build_report.py --render   # also render the PNG backgrounds (needs Playwright)
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "powerbi"
REPORT = ROOT / "InsurancePerformance.Report"
OUT = REPORT / "definition"
RES = REPORT / "StaticResources" / "RegisteredResources"
DESIGN = ROOT / "design"
VC_SCHEMA = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/2.4.0/schema.json"
PAGE_SCHEMA = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/2.1.0/schema.json"
PAGES_SCHEMA = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.1.0/schema.json"
REPORT_SCHEMA = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/report/3.3.0/schema.json"
VERSION_SCHEMA = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/versionMetadata/1.0.0/schema.json"
PLATFORM_SCHEMA = "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json"
S = 1.5  # Power BI px -> design px

# ------------------------------------------------------------------ design tokens (wine + graphite, dark)
# A dark graphite canvas with a wine accent: the colour of the insurer's brand, and different from the
# other dashboards of the portfolio. Gold is the second series colour (premium), stone the third.
SHELL_900, SHELL_800, SHELL_700 = "#0E0B0C", "#161114", "#1F181C"
WINE_700, WINE_500, WINE_300 = "#9F1239", "#E11D48", "#FDA4AF"
GOLD = "#F2B544"
PANEL, CARD, CARD_ALT, LINE = "#130F11", "#1C1619", "#241C21", "#34292F"
INK, MUTED, CHIP = "#F5EEF0", "#A8999F", "#2B1F26"
GREEN = "#34D399"
THEME = {
    "name": "Insurance Performance (dark)",
    "dataColors": [WINE_500, GOLD, "#D6D3D1", GREEN, "#A78BFA", "#FB923C", "#78716C", WINE_300],
    "foreground": INK,
    "foregroundNeutralSecondary": MUTED,
    "foregroundNeutralTertiary": "#6F6268",
    "background": CARD,
    "backgroundLight": CARD_ALT,
    "backgroundNeutral": LINE,
    "tableAccent": WINE_500,
    "good": GREEN,
    "neutral": GOLD,
    "bad": WINE_500,
    "maximum": WINE_500,
    "center": "#7A2A44",
    "minimum": CARD,
    "textClasses": {
        "label": {"color": INK},
        "callout": {"color": INK},
        "title": {"color": INK},
        "header": {"color": INK},
    },
}

# Line icons, 24x24: shield, gauge, percent, people, car, banknote, magnifier, map pin ...
ICONS = {
    "home": '<path d="M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.9-4.3-1.7-7.5-5.3-7.5-9.9V6z"/><path d="M8.8 12.2l2.2 2.2 4.3-4.6"/>',
    "overview": '<path d="M4 16a8 8 0 1 1 16 0"/><path d="M12 16l4.5-5"/><circle cx="12" cy="16" r="1.5"/><path d="M4 20h16"/>',
    "ratio": '<circle cx="7.5" cy="7.5" r="2.5"/><circle cx="16.5" cy="16.5" r="2.5"/><path d="M18.5 5.5l-13 13"/>',
    "brokers": '<circle cx="9" cy="8" r="3"/><path d="M3.5 19.5a5.5 5.5 0 0 1 11 0"/><circle cx="17" cy="9" r="2.4"/>'
    '<path d="M15.6 14.1a4.5 4.5 0 0 1 5.4 4.4"/>',
    "claims": '<path d="M5 15.5v-4L7.2 6.8h9.6L19 11.5v4"/><path d="M3.5 15.5h17"/><path d="M5 11.5h14"/>'
    '<circle cx="7.7" cy="16.6" r="1.9"/><circle cx="16.3" cy="16.6" r="1.9"/>',
    "coin": '<rect x="2.5" y="6.5" width="19" height="11" rx="1.5"/><circle cx="12" cy="12" r="2.6"/><path d="M6 9.5v5M18 9.5v5"/>',
    "policy": '<path d="M7 3.5h7l4 4v13H7z"/><path d="M14 3.5v4h4M9.5 12h6M9.5 15.5h6"/>',
    "target": '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="4.2"/><circle cx="12" cy="12" r="0.9"/>',
    "trend": '<path d="M3 7l6 6 4-4 8 8"/><path d="M15 17h6v-6"/>',
    "renew": '<path d="M19 12a7 7 0 0 1-12.2 4.7M5 12a7 7 0 0 1 12.2-4.7"/><path d="M17.5 3.5v3.8h-3.8M6.5 20.5v-3.8h3.8"/>',
    "search": '<circle cx="11" cy="11" r="6"/><path d="M15.5 15.5 20 20"/>',
    "pin": '<path d="M12 21s-6.5-6-6.5-11a6.5 6.5 0 0 1 13 0c0 5-6.5 11-6.5 11z"/><circle cx="12" cy="10" r="2.3"/>',
    "clock": '<circle cx="12" cy="13.5" r="7"/><path d="M12 13.5V10M10 3.5h4M18 7l1.5-1.5"/>',
    "vault": '<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><circle cx="12" cy="12" r="3.5"/>'
    '<path d="M12 8.5v1.2M12 14.3v1.2M15.5 12h-1.2M9.7 12H8.5M6 19.5v1.5M18 19.5v1.5"/>',
    "pulse": '<path d="M3 12h4l2.5-6 5 12 2.5-6h4"/>',
    "filter": '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
    "calendar": '<rect x="4" y="5.5" width="16" height="15" rx="2"/><path d="M4 10h16M8.5 3.5v4M15.5 3.5v4"/>'
    '<circle cx="12" cy="15" r="1.6"/>',
}


def icon(name, x, y, size, stroke, width=1.8, ident=None):
    k = size / 24
    gid = f' id="{ident}"' if ident else ""
    return (
        f'<g{gid} transform="translate({x:.1f} {y:.1f}) scale({k:.4f})" fill="none" stroke="{stroke}" '
        f'stroke-width="{width:.2f}" stroke-linecap="round" stroke-linejoin="round">{ICONS[name]}</g>'
    )


# ------------------------------------------------------------------ PBIR query helpers
def lit(value):
    return {"expr": {"Literal": {"Value": value}}}


def text(value):
    return lit("'" + value.replace("'", "''") + "'")


def num(value):
    return lit(f"{value}D")


def color(hex_):
    return {"solid": {"color": text(hex_)}}


def m(prop, entity):
    return {"Measure": {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def c(entity, prop):
    return {"Column": {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def proj(field, display=None):
    kind = "Measure" if "Measure" in field else "Column"
    entity, prop = field[kind]["Expression"]["SourceRef"]["Entity"], field[kind]["Property"]
    p = {"field": field, "queryRef": f"{entity}.{prop}", "nativeQueryRef": prop}
    if display:
        p["displayName"] = display
    return p


def in_filter(name, entity, prop, values):
    """Visual-level filter: column in (values)."""
    return {
        "name": name,
        "field": c(entity, prop),
        "type": "Categorical",
        "filter": {
            "Version": 2,
            "From": [{"Name": "t", "Entity": entity, "Type": 0}],
            "Where": [
                {
                    "Condition": {
                        "In": {
                            "Expressions": [{"Column": {"Expression": {"SourceRef": {"Source": "t"}}, "Property": prop}}],
                            "Values": [[{"Literal": {"Value": "'" + v + "'"}}] for v in values],
                        }
                    }
                }
            ],
        },
    }


# ------------------------------------------------------------------ fields used by the pages
# Measures live in the fact tables of the semantic model (see powerbi/InsurancePerformance.SemanticModel)
EARNED = m("Earned Premium", "Earned Premium")
WRITTEN = m("Written Premium", "Written Premium")
POLICIES = m("Policies Written", "Written Premium")
INCURRED = m("Incurred Claims", "Claim Movements")
LOSS_RATIO = m("Loss Ratio", "Claim Movements")
LR_TARGET = m("Loss Ratio Target", "Claim Movements")
LR_PY = m("Loss Ratio PY", "Claim Movements")
LR_DELTA = m("Loss Ratio vs PY (pp)", "Claim Movements")
RESULT = m("Technical Result", "Claim Movements")
CLAIMS = m("Claim Count", "Claims")
REPORTED = m("Claims Reported", "Claims")
FREQUENCY = m("Claim Frequency", "Claims")
SEVERITY = m("Average Claim Cost", "Claims")
RESERVE = m("Open Reserve", "Claims")
LAG = m("Average Report Lag (days)", "Claims")
THEFT = m("Theft Claims", "Claims")
RECOVERY = m("Theft Recovery Rate", "Claims")
RENEWAL = m("Renewal Rate", "Renewals")
YEAR = c("Date", "Year")
YEAR_MONTH = c("Date", "Year Month")
MONTH = c("Date", "Month")

# ------------------------------------------------------------------ page model
NAV = [
    ("home", "Home", "Cover"),
    ("overview", "Overview", "Portfolio overview"),
    ("ratio", "LossRatio", "Loss ratio drivers"),
    ("brokers", "Brokers", "Broker performance"),
    ("claims", "Claims", "Claims and theft"),
]
X0, X1, Y0, Y1 = 88, 1256, 84, 700  # content area (Power BI px)
HALF = round((X1 - X0 - 12) / 2)
THIRD = round((X1 - X0 - 24) / 3)


class Page:
    def __init__(self, name, display, title, subtitle, nav):
        self.name, self.display, self.title, self.subtitle, self.nav = name, display, title, subtitle, nav
        self.visuals, self.frames, self.z = [], [], 0

    def frame(self, vid, x, y, w, h, kind="chart", icon_name=None):
        self.frames.append({"id": vid, "x": x, "y": y, "w": w, "h": h, "kind": kind, "icon": icon_name})

    def add(self, vid, x, y, w, h, visual, filters=None):
        self.z += 1
        cont = {
            "$schema": VC_SCHEMA,
            "name": vid,
            "position": {"x": x, "y": y, "z": self.z * 1000, "width": w, "height": h, "tabOrder": self.z * 1000},
            "visual": visual,
        }
        if filters:
            cont["filterConfig"] = {"filters": filters}
        self.visuals.append(cont)


def container(title=None, subtitle=None, pad_left=20):
    """Transparent container: the frame drawn in the background is the card."""
    objs = {
        "background": [{"properties": {"show": lit("false")}}],
        "border": [{"properties": {"show": lit("false")}}],
        "dropShadow": [{"properties": {"show": lit("false")}}],
        "visualHeader": [{"properties": {"show": lit("false")}}],
        "padding": [{"properties": {"top": num(10), "bottom": num(8), "left": num(pad_left), "right": num(14)}}],
    }
    if title:
        objs["title"] = [
            {
                "properties": {
                    "show": lit("true"),
                    "text": text(title),
                    "fontColor": color(INK),
                    "fontSize": num(11),
                    "bold": lit("true"),
                    "fontFamily": text("Segoe UI Semibold"),
                }
            }
        ]
        if subtitle:
            objs["subTitle"] = [
                {"properties": {"show": lit("true"), "text": text(subtitle), "fontColor": color(MUTED), "fontSize": num(9)}}
            ]
    else:
        objs["title"] = [{"properties": {"show": lit("false")}}]
    return objs


def link_button(page, vid, x, y, w, h, target, tooltip):
    """Invisible button over an icon or tile drawn in the background: navigates to another page."""
    page.add(
        vid,
        x,
        y,
        w,
        h,
        {
            "visualType": "actionButton",
            "objects": {
                "icon": [{"properties": {"shapeType": text("blank")}, "selector": {"id": "default"}}],
                "fill": [{"properties": {"show": lit("false")}, "selector": {"id": "default"}}],
                "outline": [
                    {"properties": {"show": lit("false"), "transparency": num(100), "weight": num(0)}},
                    {
                        "properties": {"show": lit("false"), "transparency": num(100), "weight": num(0)},
                        "selector": {"id": "default"},
                    },
                ],
                "text": [{"properties": {"show": lit("false")}, "selector": {"id": "default"}}],
            },
            "visualContainerObjects": {
                "title": [{"properties": {"show": lit("false")}}],
                "background": [{"properties": {"show": lit("false")}}],
                "border": [{"properties": {"show": lit("false")}}],
                "visualLink": [
                    {
                        "properties": {
                            "show": lit("true"),
                            "type": text("PageNavigation"),
                            "navigationSection": text(target),
                            "tooltip": text(tooltip),
                        }
                    }
                ],
            },
        },
    )


def nav_buttons(page):
    for i, (_, target, label) in enumerate(NAV):
        if target != page.name:
            link_button(page, f"nav_{target}", 8, 108 + i * 64, 48, 48, target, label)


def card(page, vid, x, y, w, h, field, label, icon_name, font=20):
    """KPI card. Display units "auto": R$ 123.8M fits a narrow card; ratios are not affected."""
    page.frame(vid, x, y, w, h, "kpi", icon_name)
    page.add(
        vid,
        x,
        y,
        w,
        h,
        {
            "visualType": "card",
            "query": {"queryState": {"Values": {"projections": [proj(field, label)]}}},
            "objects": {
                "labels": [
                    {
                        "properties": {
                            "color": color(INK),
                            "fontSize": num(font),
                            "labelDisplayUnits": num(0),
                            "labelPrecision": num(1),
                            "fontFamily": text("Segoe UI Semibold"),
                        }
                    }
                ],
                "categoryLabels": [{"properties": {"show": lit("true"), "color": color(MUTED), "fontSize": num(9)}}],
            },
            "visualContainerObjects": container(pad_left=14),
        },
    )


def chart(
    page,
    vid,
    x,
    y,
    w,
    h,
    kind,
    category,
    values,
    title,
    subtitle=None,
    series=None,
    tooltips=None,
    sort=None,
    filters=None,
    labels=False,
    colors=None,
):
    page.frame(vid, x, y, w, h, "chart")
    state = {"Category": {"projections": [proj(category)]}, "Y": {"projections": [proj(v, d) for v, d in values]}}
    if series:
        state["Series"] = {"projections": [proj(series)]}
    if tooltips:
        state["Tooltips"] = {"projections": [proj(t, d) for t, d in tooltips]}
    query = {"queryState": state}
    if sort:
        query["sortDefinition"] = {"sort": [{"field": sort[0], "direction": sort[1]}], "isDefaultSort": False}
    objects = {
        "labels": [{"properties": {"show": lit("true" if labels else "false"), "color": color(INK), "fontSize": num(9)}}],
        "legend": [
            {
                "properties": {
                    "show": lit("true" if (len(values) > 1 or series) else "false"),
                    "position": text("TopRight"),
                    "labelColor": color(MUTED),
                }
            }
        ],
        "valueAxis": [{"properties": {"gridlineColor": color(LINE), "fontSize": num(9), "labelColor": color(MUTED)}}],
        "categoryAxis": [{"properties": {"fontSize": num(9), "showAxisTitle": lit("false"), "labelColor": color(MUTED)}}],
    }
    if colors and not series:
        objects["dataPoint"] = [
            {"properties": {"fill": color(col)}, "selector": {"metadata": proj(v)["queryRef"]}}
            for (v, _), col in zip(values, colors, strict=False)
        ]
    if kind == "lineChart":
        objects["lineStyles"] = [{"properties": {"strokeWidth": num(3)}}]
    if kind == "clusteredBarChart":
        objects["categoryAxis"][0]["properties"]["maxMarginFactor"] = num(45)
    page.add(
        vid,
        x,
        y,
        w,
        h,
        {"visualType": kind, "query": query, "objects": objects, "visualContainerObjects": container(title, subtitle)},
        filters,
    )


def table(page, vid, x, y, w, h, columns, title, subtitle=None, sort=None, kind="tableEx", rows=None, cols=None, filters=None):
    page.frame(vid, x, y, w, h, "chart")
    if kind == "tableEx":
        state = {"Values": {"projections": [proj(f, d) for f, d in columns]}}
    else:  # matrix
        state = {
            "Rows": {"projections": [proj(rows)]},
            "Columns": {"projections": [proj(cols)]},
            "Values": {"projections": [proj(f, d) for f, d in columns]},
        }
    query = {"queryState": state}
    if sort:
        query["sortDefinition"] = {"sort": [{"field": sort[0], "direction": sort[1]}], "isDefaultSort": False}
    page.add(
        vid,
        x,
        y,
        w,
        h,
        {
            "visualType": kind,
            "query": query,
            "objects": {
                "columnHeaders": [
                    {
                        "properties": {
                            "fontColor": color(WINE_300),
                            "backColor": color(CHIP),
                            "fontSize": num(9),
                            "bold": lit("true"),
                        }
                    }
                ],
                "values": [
                    {
                        "properties": {
                            "fontSize": num(9),
                            "fontColor": color(INK),
                            "backColorPrimary": color(CARD),
                            "backColorSecondary": color(CARD_ALT),
                        }
                    }
                ],
                "rowHeaders": [{"properties": {"fontColor": color(INK), "backColor": color(CARD), "fontSize": num(9)}}],
                "total": [{"properties": {"fontColor": color(INK), "backColor": color(CHIP)}}],
                "subTotals": [{"properties": {"rowSubtotals": lit("false"), "columnSubtotals": lit("false")}}],
                "grid": [
                    {
                        "properties": {
                            "gridHorizontalColor": color(LINE),
                            "gridVerticalColor": color(LINE),
                            "outlineColor": color(LINE),
                        }
                    }
                ],
            },
            "visualContainerObjects": container(title, subtitle),
        },
        filters,
    )


def slicer(page, vid, x, y, w, h, field, title, icon_name="filter"):
    page.frame(vid, x, y, w, h, "control", icon_name)
    page.add(
        vid,
        x,
        y,
        w,
        h,
        {
            "visualType": "slicer",
            "query": {"queryState": {"Values": {"projections": [proj(field)]}}},
            "objects": {
                "data": [{"properties": {"mode": text("Dropdown")}}],
                "header": [{"properties": {"show": lit("false")}}],
                "items": [{"properties": {"fontColor": color(INK), "background": color(CARD_ALT)}}],
            },
            "visualContainerObjects": container(title),
        },
    )


def kpi_row(page, start_x, cards):
    """Cards side by side from start_x to the right edge of the content area."""
    n = len(cards)
    w = int((X1 - start_x - (n - 1) * 12) / n)
    for i, (vid, field, label, icon_name) in enumerate(cards):
        card(page, vid, start_x + i * (w + 12), Y0, w, 92, field, label, icon_name)


# ------------------------------------------------------------------ pages
def cover():
    p = Page("Home", "Home", "", "", "home")
    p.kind = "cover"
    w = round((X1 - X0 - 36) / 4)
    for i, (_, target, label) in enumerate(NAV[1:]):
        link_button(p, f"go_{target}", X0 + i * (w + 12), 560, w, 96, target, label)
    return p


def overview():
    """Is the portfolio profitable? Premium, claims and loss ratio month by month."""
    p = Page(
        "Overview",
        "Portfolio overview",
        "Portfolio Overview",
        "Premium, claims and loss ratio of the auto portfolio · use the year filter to compare periods",
        "overview",
    )
    slicer(p, "f_year", X0, Y0, 150, 92, YEAR, "Year", "calendar")
    kpi_row(
        p,
        X0 + 162,
        [
            ("k_written", WRITTEN, "Written premium", "policy"),
            ("k_earned", EARNED, "Earned premium", "coin"),
            ("k_incurred", INCURRED, "Incurred claims", "claims"),
            ("k_lr", LOSS_RATIO, "Loss ratio", "ratio"),
            ("k_freq", FREQUENCY, "Claims per 100 vehicles", "pulse"),
            ("k_sev", SEVERITY, "Average claim cost", "target"),
        ],
    )
    chart(
        p,
        "lr_month",
        X0,
        188,
        HALF,
        252,
        "lineChart",
        YEAR_MONTH,
        [(LOSS_RATIO, "Loss ratio"), (LR_TARGET, "Target")],
        "Loss ratio by month",
        "Incurred claims / earned premium · pricing target 70%",
        sort=(YEAR_MONTH, "Ascending"),
    )
    chart(
        p,
        "money_month",
        X0 + HALF + 12,
        188,
        HALF,
        252,
        "clusteredColumnChart",
        YEAR_MONTH,
        [(EARNED, "Earned premium"), (INCURRED, "Incurred claims")],
        "Earned premium and incurred claims",
        "Premium is earned day by day; claims are recorded when reserved, paid or recovered",
        sort=(YEAR_MONTH, "Ascending"),
        colors=[GOLD, WINE_500],
    )
    row3 = [
        ("lr_product", c("Product", "Product"), LOSS_RATIO, "Loss ratio by product", "Against the 70% pricing target"),
        (
            "earned_category",
            c("Vehicle Profile", "Vehicle Category"),
            EARNED,
            "Earned premium by vehicle",
            "Where the premium comes from",
        ),
        ("lr_coverage", c("Coverage", "Coverage"), LOSS_RATIO, "Loss ratio by coverage", "Theft, collision, liability and glass"),
    ]
    for i, (vid, cat, value, title, sub) in enumerate(row3):
        chart(
            p,
            vid,
            X0 + i * (THIRD + 12),
            452,
            THIRD,
            Y1 - 452,
            "clusteredBarChart",
            cat,
            [(value, title.split(" by ")[0].capitalize())],
            title,
            sub,
            sort=(value, "Descending"),
            labels=True,
            colors=[GOLD if value is EARNED else WINE_500],
        )
    return p


def loss_ratio():
    """Where does the loss ratio come from? Vehicle, coverage, state and value band."""
    p = Page(
        "LossRatio",
        "Loss ratio drivers",
        "Loss Ratio Drivers",
        "Which vehicles, coverages and states drive the claim cost, and how the year compares with the last",
        "ratio",
    )
    slicer(p, "f_year", X0, Y0, 150, 92, YEAR, "Year", "calendar")
    slicer(p, "f_coverage", X0 + 162, Y0, 190, 92, c("Coverage", "Coverage"), "Coverage", "filter")
    kpi_row(
        p,
        X0 + 364,
        [
            ("k_lr", LOSS_RATIO, "Loss ratio", "ratio"),
            ("k_lr_py", LR_PY, "Same period last year", "calendar"),
            ("k_delta", LR_DELTA, "Change vs last year", "trend"),
            ("k_result", RESULT, "Premium minus claims", "coin"),
        ],
    )
    table(
        p,
        "matrix",
        X0,
        188,
        HALF,
        252,
        [(LOSS_RATIO, "Loss ratio")],
        "Loss ratio by vehicle and coverage",
        "Where the premium does not pay for the claims",
        kind="pivotTable",
        rows=c("Vehicle Profile", "Vehicle Category"),
        cols=c("Coverage", "Coverage"),
    )
    chart(
        p,
        "lr_state",
        X0 + HALF + 12,
        188,
        HALF,
        252,
        "clusteredBarChart",
        c("Geography", "State"),
        [(LOSS_RATIO, "Loss ratio")],
        "Loss ratio by state",
        "Customer address at the start of the policy",
        tooltips=[(EARNED, "Earned premium"), (INCURRED, "Incurred claims")],
        sort=(LOSS_RATIO, "Descending"),
        labels=True,
        colors=[WINE_500],
    )
    chart(
        p,
        "lr_band",
        X0,
        452,
        HALF,
        Y1 - 452,
        "clusteredColumnChart",
        c("Vehicle Profile", "Value Band"),
        [(LOSS_RATIO, "Loss ratio")],
        "Loss ratio by vehicle value (FIPE)",
        "Market value of the vehicle (FIPE table) by category",
        series=c("Vehicle Profile", "Vehicle Category"),
        sort=(c("Vehicle Profile", "Value Band"), "Ascending"),
    )
    chart(
        p,
        "lr_yoy",
        X0 + HALF + 12,
        452,
        HALF,
        Y1 - 452,
        "lineChart",
        MONTH,
        [(LOSS_RATIO, "Loss ratio"), (LR_PY, "Last year")],
        "This year against last year",
        "Same months compared, closed months only",
        sort=(MONTH, "Ascending"),
    )
    return p


def brokers():
    """Which brokers bring profitable and loyal business?"""
    p = Page(
        "Brokers",
        "Broker performance",
        "Broker Performance",
        "Production, result and retention of each broker · the basis of the commission negotiation",
        "brokers",
    )
    slicer(p, "f_year", X0, Y0, 150, 92, YEAR, "Year", "calendar")
    slicer(p, "f_product", X0 + 162, Y0, 190, 92, c("Product", "Product"), "Product", "filter")
    kpi_row(
        p,
        X0 + 364,
        [
            ("k_written", WRITTEN, "Written premium", "policy"),
            ("k_policies", POLICIES, "Policies issued", "brokers"),
            ("k_renewal", RENEWAL, "Renewal rate", "renew"),
            ("k_lr", LOSS_RATIO, "Loss ratio", "ratio"),
        ],
    )
    left = 700
    table(
        p,
        "scorecard",
        X0,
        188,
        left,
        Y1 - 188,
        [
            (c("Broker", "Broker"), "Broker"),
            (c("Broker", "Broker State"), "State"),
            (WRITTEN, "Written premium"),
            (POLICIES, "Policies"),
            (LOSS_RATIO, "Loss ratio"),
            (RENEWAL, "Renewal rate"),
        ],
        "Broker scorecard",
        "Sorted by written premium · a high loss ratio with a low renewal rate needs a review",
        sort=(WRITTEN, "Descending"),
    )
    right_x, right_w = X0 + left + 12, X1 - X0 - left - 12
    chart(
        p,
        "top_brokers",
        right_x,
        188,
        right_w,
        252,
        "clusteredBarChart",
        c("Broker", "Broker"),
        [(WRITTEN, "Written premium")],
        "Written premium by broker",
        "A few large brokers sell most of the portfolio",
        sort=(WRITTEN, "Descending"),
        colors=[GOLD],
    )
    chart(
        p,
        "renewal_month",
        right_x,
        452,
        right_w,
        Y1 - 452,
        "lineChart",
        YEAR_MONTH,
        [(RENEWAL, "Renewal rate")],
        "Renewal rate by month",
        "Policies renewed at the end of their term",
        sort=(YEAR_MONTH, "Ascending"),
        colors=[GREEN],
    )
    return p


def claims():
    """How claims behave: frequency, cost, report lag, theft and recovery."""
    p = Page(
        "Claims",
        "Claims and theft",
        "Claims and Theft",
        "Frequency, cost and status of the claims · theft and robbery with the share of vehicles found",
        "claims",
    )
    slicer(p, "f_year", X0, Y0, 150, 92, YEAR, "Year", "calendar")
    kpi_row(
        p,
        X0 + 162,
        [
            ("k_claims", CLAIMS, "Claims", "claims"),
            ("k_freq", FREQUENCY, "Claims per 100 vehicles", "pulse"),
            ("k_sev", SEVERITY, "Average claim cost", "target"),
            ("k_lag", LAG, "Days to report", "clock"),
            ("k_recovery", RECOVERY, "Stolen vehicles found", "search"),
            ("k_reserve", RESERVE, "Open reserve", "vault"),
        ],
    )
    chart(
        p,
        "by_cause",
        X0,
        188,
        THIRD,
        252,
        "clusteredBarChart",
        c("Claims", "Cause"),
        [(CLAIMS, "Claims")],
        "Claims by cause",
        "Denied claims are not counted",
        sort=(CLAIMS, "Descending"),
        labels=True,
        colors=[WINE_500],
    )
    chart(
        p,
        "by_status",
        X0 + THIRD + 12,
        188,
        THIRD,
        252,
        "clusteredColumnChart",
        c("Claims", "Status"),
        [(REPORTED, "Claims reported")],
        "Claims by status",
        "Paid, open, denied or vehicle recovered",
        sort=(REPORTED, "Descending"),
        labels=True,
        colors=[GOLD],
    )
    chart(
        p,
        "theft_state",
        X0 + 2 * (THIRD + 12),
        188,
        THIRD,
        252,
        "clusteredBarChart",
        c("Geography", "State"),
        [(THEFT, "Theft claims")],
        "Theft and robbery by state",
        "Where it happened · tooltip: share of vehicles found",
        tooltips=[(RECOVERY, "Vehicles found")],
        sort=(THEFT, "Descending"),
        labels=True,
        colors=[WINE_500],
    )
    chart(
        p,
        "freq_month",
        X0,
        452,
        HALF,
        Y1 - 452,
        "lineChart",
        YEAR_MONTH,
        [(FREQUENCY, "Claims per 100 vehicles")],
        "Claim frequency by vehicle category",
        "Claims per 100 vehicle-years of cover, by month of occurrence",
        series=c("Vehicle Profile", "Vehicle Category"),
        sort=(YEAR_MONTH, "Ascending"),
    )
    table(
        p,
        "open_claims",
        X0 + HALF + 12,
        452,
        HALF,
        Y1 - 452,
        [
            (c("Claims", "Claim Number"), "Claim"),
            (c("Coverage", "Coverage"), "Coverage"),
            (c("Geography", "State Code"), "State"),
            (c("Claims", "Occurred Date"), "Occurred"),
            (RESERVE, "Open reserve"),
        ],
        "Largest open claims",
        "Work list for the claims team",
        sort=(RESERVE, "Descending"),
        filters=[in_filter("open_only", "Claims", "Status", ["Open"])],
    )
    return p


# ------------------------------------------------------------------ SVG backgrounds
def defs():
    return f"""<defs>
  <linearGradient id="shell" x1="0" y1="0" x2="1920" y2="1080" gradientUnits="userSpaceOnUse">
    <stop stop-color="{SHELL_900}"/><stop offset="0.6" stop-color="{SHELL_800}"/><stop offset="1" stop-color="{SHELL_700}"/>
  </linearGradient>
  <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">
    <stop stop-color="{WINE_300}"/><stop offset="1" stop-color="{WINE_700}"/>
  </linearGradient>
  <radialGradient id="glow" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(1840 60) scale(900)">
    <stop stop-color="{WINE_500}" stop-opacity="0.18"/><stop offset="1" stop-color="{WINE_500}" stop-opacity="0"/>
  </radialGradient>
  <pattern id="dots" x="0" y="0" width="24" height="24" patternUnits="userSpaceOnUse">
    <circle cx="2" cy="2" r="1.1" fill="#FFFFFF" fill-opacity="0.045"/>
  </pattern>
</defs>"""


FONT = "Inter, Segoe UI, sans-serif"


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def shell(active):
    """Dark canvas with a dotted texture, slim navigation rail with a wine ring on the active page."""
    out = [
        '<rect id="Background" width="1920" height="1080" fill="url(#shell)"/>',
        '<rect id="Glow" width="1920" height="1080" fill="url(#glow)"/>',
        '<rect id="Dots" width="1920" height="1080" fill="url(#dots)"/>',
        '<g id="Navigation rail">',
        '<g id="Brand mark"><circle cx="48" cy="54" r="26" fill="none" stroke="url(#accent)" stroke-width="2.5"/>'
        + icon("home", 33, 39, 30, WINE_300, 2)
        + "</g>",
        f'<rect x="30" y="98" width="36" height="1.5" fill="{LINE}"/>',
    ]
    for i, (name, _, label) in enumerate(NAV):
        cy = (108 + i * 64 + 24) * S
        if name == active:
            out.append(
                f'<circle id="Active {label}" cx="48" cy="{cy:.0f}" r="27" fill="{CHIP}" stroke="{WINE_500}" stroke-width="2"/>'
                f'<rect x="0" y="{cy - 18:.0f}" width="4" height="36" rx="2" fill="{WINE_500}"/>'
            )
            out.append(icon(name, 33, cy - 15, 30, WINE_300, 2, f"Icon {label}"))
        else:
            out.append(icon(name, 33, cy - 15, 30, MUTED, 1.8, f"Icon {label}"))
    out.append("</g>")
    out.append(
        f'<rect id="Content panel" x="{72 * S}" y="{8 * S}" width="{(1272 - 72) * S}" height="{(712 - 8) * S}" rx="18" '
        f'fill="{PANEL}" stroke="{LINE}" stroke-width="1.5"/>'
    )
    return out


def page_header(page):
    return [
        '<g id="Header">',
        f'<circle cx="{109 * S}" cy="{35 * S}" r="{15 * S}" fill="{CHIP}" stroke="{LINE}" stroke-width="1.5"/>',
        icon(page.nav, 109 * S - 12.5, 35 * S - 12.5, 25, WINE_300, 2, "Header icon"),
        f'<rect id="Data badge" x="{990 * S}" y="{26 * S}" width="{260 * S}" height="{28 * S}" rx="{14 * S}" '
        f'fill="none" stroke="{WINE_700}" stroke-width="1.5"/>',
        f'<circle cx="{1004 * S}" cy="{40 * S}" r="5" fill="{WINE_500}"/>',
        f'<text x="{1014 * S}" y="{40 * S + 7}" font-family="{FONT}" font-size="19" font-weight="600" fill="{WINE_300}">'
        "SeguroDW · closed through Oct 2026</text>",
        f'<text id="Page title" x="{132 * S}" y="{37 * S}" font-family="{FONT}" font-size="28" font-weight="700" fill="{INK}">'
        f"{esc(page.title)}</text>",
        f'<text id="Page subtitle" x="{132 * S}" y="{58 * S}" font-family="{FONT}" font-size="17" fill="{MUTED}">'
        f"{esc(page.subtitle)}</text>",
        f'<rect x="{X0 * S}" y="{76 * S}" width="{(X1 - X0) * S}" height="1.5" fill="{LINE}"/>',
        f'<rect x="{X0 * S}" y="{76 * S - 0.5}" width="90" height="2.5" fill="url(#accent)"/>',
        "</g>",
    ]


def frames_svg(page):
    """Dark cards, hairline border, wine top rule on KPIs, round icon badges."""
    out = ['<g id="Frames">']
    for f in page.frames:
        x, y, w, h = f["x"] * S, f["y"] * S, f["w"] * S, f["h"] * S
        out.append(f'<g id="Frame {f["id"]}">')
        out.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="14" fill="{CARD}" '
            f'stroke="{LINE}" stroke-width="1.5"/>'
        )
        if f["kind"] == "kpi":
            out.append(f'<rect x="{x + 20:.1f}" y="{y:.1f}" width="56" height="3" rx="1.5" fill="url(#accent)"/>')
        if f["kind"] in ("kpi", "control") and f["icon"]:
            cx, cy = x + w - 32, y + 32
            out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="18" fill="{CHIP}" stroke="{LINE}" stroke-width="1.2"/>')
            out.append(icon(f["icon"], cx - 11, cy - 11, 22, WINE_300, 1.9))
        if f["kind"] == "chart":
            out.append(f'<circle cx="{x + 20:.1f}" cy="{y + 31:.1f}" r="4" fill="{WINE_500}"/>')
        out.append("</g>")
    out.append("</g>")
    return out


def cover_svg():
    """Cover: a shield protecting a car, orbited by the four questions the dashboard answers."""
    tiles = []
    descriptions = [
        "Premium, claims, loss ratio",
        "Vehicle, coverage, state",
        "Production and retention",
        "Frequency, cost, theft",
    ]
    w = round((X1 - X0 - 36) / 4)
    for i, (name, _, label) in enumerate(NAV[1:]):
        x, y, tw, th = (X0 + i * (w + 12)) * S, 560 * S, w * S, 96 * S
        tiles.append(
            f'<g id="Tile {label}"><rect x="{x}" y="{y}" width="{tw}" height="{th}" rx="16" fill="{CARD}" '
            f'stroke="{LINE}" stroke-width="1.5"/>'
            f'<rect x="{x + 24}" y="{y}" width="64" height="3" rx="1.5" fill="url(#accent)"/>'
            f'<circle cx="{x + 62}" cy="{y + th / 2}" r="34" fill="{CHIP}" stroke="{WINE_700}" stroke-width="1.5"/>'
            + icon(name, x + 43, y + th / 2 - 19, 38, WINE_300, 1.9)
            + f'<text x="{x + 114}" y="{y + 64}" font-family="{FONT}" font-size="23" font-weight="600" fill="{INK}">'
            f"{label.capitalize()}</text>"
            f'<text x="{x + 114}" y="{y + 96}" font-family="{FONT}" font-size="17" fill="{MUTED}">{descriptions[i]}</text>'
            f'<path d="M{x + tw - 30} {y + th / 2 - 9} l9 9 -9 9" stroke="{WINE_500}" stroke-width="3" fill="none" '
            'stroke-linecap="round" stroke-linejoin="round"/></g>'
        )

    # Illustration: shield with a car, dashed orbit and four small badges (premium, ratio, brokers, claims)
    cx, cy = 1500, 400
    shield = (
        f"M{cx} {cy - 230} L{cx + 190} {cy - 160} V{cy - 10} C{cx + 190} {cy + 120} {cx + 100} {cy + 200} {cx} {cy + 250} "
        f"C{cx - 100} {cy + 200} {cx - 190} {cy + 120} {cx - 190} {cy - 10} V{cy - 160} Z"
    )
    car = (
        f'<g id="Car" transform="translate({cx - 120} {cy - 70}) scale(10)" fill="none" stroke="{WINE_300}" '
        'stroke-width="0.85" stroke-linecap="round" stroke-linejoin="round">' + ICONS["claims"] + "</g>"
    )
    badges = []
    for k, (name, angle) in enumerate((("coin", 200), ("ratio", 330), ("brokers", 30), ("pulse", 150))):
        bx = cx + 300 * math.cos(math.radians(angle))
        by = cy + 230 * math.sin(math.radians(angle))
        badges.append(
            f'<g id="Badge {k}"><circle cx="{bx:.0f}" cy="{by:.0f}" r="40" fill="{CARD}" stroke="{WINE_700}" stroke-width="2"/>'
            + icon(name, bx - 20, by - 20, 40, GOLD if k % 2 == 0 else WINE_300, 1.9)
            + "</g>"
        )
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
{defs()}
<rect id="Background" width="1920" height="1080" fill="url(#shell)"/>
<rect id="Glow" width="1920" height="1080" fill="url(#glow)"/>
<rect id="Dots" width="1920" height="1080" fill="url(#dots)"/>
<g id="Illustration">
<ellipse id="Orbit" cx="{cx}" cy="{cy}" rx="300" ry="230" fill="none" stroke="{LINE}" stroke-width="2" stroke-dasharray="6 10"/>
<path id="Shield glow" d="{shield}" fill="{WINE_500}" fill-opacity="0.08" transform="translate(0 10)"/>
<path id="Shield" d="{shield}" fill="{CARD}" stroke="url(#accent)" stroke-width="4"/>
{car}
{"".join(badges)}
</g>
<g id="Brand"><circle cx="168" cy="186" r="36" fill="none" stroke="url(#accent)" stroke-width="3"/>
{icon("home", 146, 164, 44, WINE_300, 2)}
<text x="228" y="196" font-family="{FONT}" font-size="26" font-weight="600" letter-spacing="4" fill="{WINE_300}">AUTO INSURANCE</text></g>
<text id="Title" x="128" y="400" font-family="{FONT}" font-size="92" font-weight="800" fill="{INK}">Insurance</text>
<text id="Title accent" x="128" y="500" font-family="{FONT}" font-size="92" font-weight="800" fill="{WINE_500}">Performance</text>
<rect x="132" y="540" width="120" height="4" rx="2" fill="url(#accent)"/>
<text id="Subtitle" x="132" y="600" font-family="{FONT}" font-size="26" fill="{MUTED}">Premium, claims and loss ratio of the auto portfolio, from the SeguroDW warehouse</text>
<g id="Navigation tiles">{"".join(tiles)}</g>
<text id="Footer" x="132" y="1030" font-family="{FONT}" font-size="18" fill="{MUTED}" fill-opacity="0.7">Power BI · PBIP / TMDL · DAX · fed by the pbi views of the SQL Server data warehouse</text>
</svg>"""


def page_svg(page):
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">', defs()]
    parts += shell(page.nav) + page_header(page) + frames_svg(page) + ["</svg>"]
    return "\n".join(parts)


# ------------------------------------------------------------------ write everything
def image_background(file_name):
    return {
        "image": {
            "image": {
                "name": text(file_name),
                "url": {
                    "expr": {
                        "ResourcePackageItem": {"PackageName": "RegisteredResources", "PackageType": 1, "ItemName": file_name}
                    }
                },
                "scaling": text("Fit"),
            }
        },
        "transparency": num(0),
    }


def dump(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def render_png(svgs: dict[str, str]) -> None:
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page(viewport={"width": 1920, "height": 1080})
        for slug, svg in svgs.items():
            page.set_content(f"<html><body style='margin:0'>{svg}</body></html>")
            page.screenshot(path=str(RES / f"bg_{slug}.png"), clip={"x": 0, "y": 0, "width": 1920, "height": 1080})
        browser.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--render", action="store_true", help="render the PNG backgrounds with Playwright")
    args = parser.parse_args()
    pages = [cover(), overview(), loss_ratio(), brokers(), claims()]
    DESIGN.mkdir(parents=True, exist_ok=True)
    RES.mkdir(parents=True, exist_ok=True)
    svgs = {}
    for i, p in enumerate(pages):
        slug = f"{i}_{p.name}"
        svgs[slug] = cover_svg() if getattr(p, "kind", "") == "cover" else page_svg(p)
        (DESIGN / f"bg_{slug}.svg").write_text(svgs[slug], encoding="utf-8")
        if p.name != "Home":
            nav_buttons(p)
    if args.render:
        render_png(svgs)

    # Pages and visuals (folders are rebuilt from scratch so a removed visual does not linger)
    pages_dir = OUT / "pages"
    if pages_dir.exists():
        shutil.rmtree(pages_dir)
    for i, p in enumerate(pages):
        img = f"bg_{i}_{p.name}.png"
        page_json = {
            "$schema": PAGE_SCHEMA,
            "name": p.name,
            "displayName": p.display,
            "displayOption": "FitToPage",
            "height": 720,
            "width": 1280,
            "objects": {
                "background": [{"properties": image_background(img)}],
                "outspace": [{"properties": {"color": color(SHELL_900), "transparency": num(0)}}],
            },
        }
        dump(pages_dir / p.name / "page.json", page_json)
        for v in p.visuals:
            dump(pages_dir / p.name / "visuals" / v["name"] / "visual.json", v)
    dump(pages_dir / "pages.json", {"$schema": PAGES_SCHEMA, "pageOrder": [p.name for p in pages], "activePageName": "Home"})

    # Theme, background images and the report definition
    theme_file = "InsuranceTheme.json"
    dump(RES / theme_file, THEME)
    items = [{"name": f"bg_{i}_{p.name}.png", "path": f"bg_{i}_{p.name}.png", "type": "Image"} for i, p in enumerate(pages)]
    items.append({"name": theme_file, "path": theme_file, "type": "BaseTheme"})
    dump(
        OUT / "report.json",
        {
            "$schema": REPORT_SCHEMA,
            "themeCollection": {
                "customTheme": {
                    "name": theme_file,
                    "reportVersionAtImport": {"visual": "1.8.95", "report": "2.0.95", "page": "1.3.95"},
                    "type": "RegisteredResources",
                }
            },
            "objects": {"outspacePane": [{"properties": {"expanded": lit("false")}}]},
            "resourcePackages": [{"name": "RegisteredResources", "type": "RegisteredResources", "items": items}],
            "settings": {"useEnhancedTooltips": False},
        },
    )
    dump(OUT / "version.json", {"$schema": VERSION_SCHEMA, "version": "2.0.0"})
    (REPORT / "definition.pbir").write_text(
        json.dumps(
            {"version": "4.0", "datasetReference": {"byPath": {"path": "../InsurancePerformance.SemanticModel"}}}, indent=2
        ),
        encoding="utf-8",
    )
    platform = REPORT / ".platform"
    if not platform.exists():
        import uuid

        dump(
            platform,
            {
                "$schema": PLATFORM_SCHEMA,
                "metadata": {"type": "Report", "displayName": "InsurancePerformance"},
                "config": {"version": "2.0", "logicalId": str(uuid.uuid4())},
            },
        )
    print("pages:", [(p.display, len(p.visuals)) for p in pages])


if __name__ == "__main__":
    main()
