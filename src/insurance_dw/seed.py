"""Synthetic data for the legacy policy system (SeguroLegado).

What it builds: a small but realistic auto insurer. Brokers, customers, vehicles, annual policies
with renewals and cancellations, claims with their reserve, payment and recovery movements, and
the typing errors a system in production for 15 years accumulates.

Why it works as a timeline: every policy, claim and correction has the date it happened. The
timeline is then "photographed" at a date. The photo of 30/09/2026 is what the legacy system holds
on the day of the first load into the warehouse; the difference to the photo of 31/10/2026 is one
month of business activity, used by the incremental run.

Everything comes from a fixed random seed, so every run (and every CI build) sees the same data.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from decimal import Decimal

FIRST_LOAD = date(2026, 9, 30)  # the day of the first load into the warehouse
MONTH_LATER = date(2026, 10, 31)  # one month of activity later (incremental run)
PORTFOLIO_START = date(2023, 1, 1)  # first policies of the portfolio
BROKERS_SINCE = datetime(2022, 6, 1, 9, 0)

# Customers per state (share of the portfolio) and the cities they live in
STATES = {
    "SP": (0.36, ["São Paulo", "Campinas", "Barueri", "Santos", "Ribeirão Preto", "Guarulhos"]),
    "RJ": (0.14, ["Rio de Janeiro", "Niterói", "Duque de Caxias"]),
    "MG": (0.11, ["Belo Horizonte", "Uberlândia", "Contagem"]),
    "PR": (0.08, ["Curitiba", "Londrina", "Maringá"]),
    "RS": (0.07, ["Porto Alegre", "Caxias do Sul"]),
    "BA": (0.06, ["Salvador", "Feira de Santana"]),
    "SC": (0.05, ["Florianópolis", "Joinville"]),
    "GO": (0.05, ["Goiânia", "Anápolis"]),
    "PE": (0.04, ["Recife", "Olinda"]),
    "DF": (0.04, ["Brasília"]),
}
HIGH_THEFT_STATES = {"SP", "RJ"}  # theft premiums and frequencies are higher in the big capitals

FIRST_NAMES = (
    "ANA BRUNO CARLA DANIEL EDUARDO FERNANDA GABRIEL HELENA IGOR JULIANA LUCAS MARIANA NICOLAS PATRICIA "
    "RAFAEL SABRINA THIAGO VANESSA WAGNER LARISSA RODRIGO CAMILA FELIPE BEATRIZ GUSTAVO LETICIA MARCELO "
    "ALINE DIEGO PRISCILA"
).split()
LAST_NAMES = (
    "SILVA SANTOS OLIVEIRA SOUZA RODRIGUES FERREIRA ALVES PEREIRA LIMA GOMES COSTA RIBEIRO MARTINS "
    "CARVALHO ALMEIDA LOPES SOARES FERNANDES VIEIRA BARBOSA ROCHA DIAS NASCIMENTO ANDRADE MOREIRA NUNES "
    "MARQUES MACHADO MENDES FREITAS"
).split()

# Vehicle models per category: (make, model, FIPE table value of a new vehicle)
MODELS = {
    "AUTO": [
        ("VOLKSWAGEN", "GOL 1.0", 62000),
        ("FIAT", "ARGO 1.3", 78000),
        ("CHEVROLET", "ONIX 1.0 TURBO", 88000),
        ("HYUNDAI", "HB20 1.0", 80000),
        ("TOYOTA", "COROLLA 2.0", 145000),
        ("JEEP", "COMPASS 1.3T", 165000),
        ("HONDA", "CIVIC 2.0", 140000),
        ("RENAULT", "KWID 1.0", 60000),
    ],
    "MOTO": [
        ("HONDA", "CG 160 FAN", 16000),
        ("HONDA", "BIZ 125", 14500),
        ("YAMAHA", "FAZER 250", 23000),
        ("HONDA", "CB 500F", 38000),
        ("YAMAHA", "FACTOR 150", 15000),
        ("BMW", "G 310 R", 33000),
    ],
    "CAMINHAO": [
        ("VOLKSWAGEN", "DELIVERY 11.180", 290000),
        ("MERCEDES-BENZ", "ACCELO 1016", 310000),
        ("VOLVO", "FH 540", 780000),
        ("SCANIA", "R 450", 720000),
    ],
}
CATEGORY_SHARE = {"AUTO": 0.58, "MOTO": 0.32, "CAMINHAO": 0.10}
# How the category was typed by hand over the years (the warehouse maps all of them back)
CATEGORY_TYPED = {
    "AUTO": ["AUTO"] * 8 + ["Auto", "AUTOMOVEL", "auto "],
    "MOTO": ["MOTO"] * 7 + ["MOTOCICLETA", "Moto", " MOTO"],
    "CAMINHAO": ["CAMINHAO"] * 6 + ["CAMINHÃO", "Caminhao"],
}

PRODUCTS = {
    1: "AUTO ESSENCIAL",
    2: "AUTO COMPLETO",
    3: "MOTO ROUBO E FURTO",
    4: "CAMINHAO FROTA",
}
PRODUCT_COVERAGES = {
    1: ["ROUBO", "TERCEIROS"],
    2: ["ROUBO", "COLISAO", "TERCEIROS", "VIDROS"],
    3: ["ROUBO", "TERCEIROS"],  # third-party liability is optional for motorcycles
    4: ["ROUBO", "COLISAO", "TERCEIROS"],
}

# Claims per year of exposure, by coverage (theft by vehicle category)
THEFT_FREQUENCY = {"AUTO": 0.015, "MOTO": 0.06, "CAMINHAO": 0.02}
OTHER_FREQUENCY = {"COLISAO": 0.07, "TERCEIROS": 0.03, "VIDROS": 0.09}

# Columns of each legacy table, in insert order; KEYS = how many leading columns form the primary key
TABLES = {
    "Corretor": ["CdCorretor", "NmCorretor", "NrSusep", "SgUf", "FlAtivo", "DtAlteracao"],
    "Produto": ["CdProduto", "DsProduto", "DtAlteracao"],
    "Segurado": ["CdSegurado", "NmSegurado", "NrCpf", "DtNascimento", "SgUf", "NmCidade", "DtAlteracao"],
    "Veiculo": [
        "CdVeiculo",
        "CdSegurado",
        "NrPlaca",
        "CdFipe",
        "NmMarca",
        "NmModelo",
        "NrAnoModelo",
        "DsCategoria",
        "VlFipe",
        "DtAlteracao",
    ],
    "Apolice": [
        "NrApolice",
        "CdSegurado",
        "CdVeiculo",
        "CdCorretor",
        "CdProduto",
        "DtEmissao",
        "DtInicioVigencia",
        "DtFimVigencia",
        "DtCancelamento",
        "NrApoliceAnterior",
        "DtAlteracao",
    ],
    "ApoliceCobertura": ["NrApolice", "CdCobertura", "VlImportanciaSegurada", "VlPremioLiquido", "DtAlteracao"],
    "Sinistro": [
        "NrSinistro",
        "NrApolice",
        "CdCobertura",
        "DtOcorrencia",
        "DtAviso",
        "DsCausa",
        "SgUfOcorrencia",
        "CdSituacao",
        "DtAlteracao",
    ],
    "SinistroMovimento": ["NrSinistro", "NrSequencia", "DtMovimento", "TpMovimento", "VlMovimento", "DtAlteracao"],
}
KEYS = {"ApoliceCobertura": 2, "SinistroMovimento": 2}  # every other table has a one-column key


@dataclass
class World:
    """The whole timeline of the insurer; snapshot() turns it into legacy table rows at a date."""

    brokers: list[dict] = field(default_factory=list)
    customers: list[dict] = field(default_factory=list)
    vehicles: list[dict] = field(default_factory=list)
    policies: list[dict] = field(default_factory=list)
    claims: list[dict] = field(default_factory=list)
    orphan_movements: list[dict] = field(default_factory=list)


# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------
def money(value: float) -> Decimal:
    return Decimal(str(round(value, 2))).quantize(Decimal("0.01"))


def at_business_hours(day: date, rng: random.Random) -> datetime:
    """A moment during office hours on that day (when the legacy system records changes)."""
    return datetime.combine(day, time(rng.randint(8, 18), rng.randint(0, 59), rng.randint(0, 59)))


def end_of(day: date) -> datetime:
    return datetime.combine(day, time(23, 59, 59))


def one_year_after(day: date) -> date:
    """Annual policy term. A policy starting on 29/02 ends on 01/03 of the next year."""
    try:
        return day.replace(year=day.year + 1)
    except ValueError:
        return date(day.year + 1, 3, 1)


def cpf_check_digits(first9: str) -> str:
    """Brazilian CPF check digits (modulo 11)."""
    digits = [int(c) for c in first9]
    for weight_start in (10, 11):
        total = sum(d * w for d, w in zip(digits, range(weight_start, 1, -1), strict=False))
        rest = total % 11
        digits.append(0 if rest < 2 else 11 - rest)
    return "".join(str(d) for d in digits[9:])


def new_cpf(rng: random.Random) -> str:
    first9 = "".join(str(rng.randint(0, 9)) for _ in range(9))
    if len(set(first9)) == 1:  # 111.111.111-xx and similar are invalid by rule
        first9 = "1" + first9[1:-1] + "2"
    return first9 + cpf_check_digits(first9)


def typed_cpf(cpf: str, rng: random.Random) -> str:
    """How the CPF was typed: digits only, with punctuation, or as a number that lost its leading zeros."""
    roll = rng.random()
    if cpf.startswith("0") and roll < 0.5:
        return str(int(cpf))
    if roll < 0.65:
        return cpf
    return f"{cpf[:3]}.{cpf[3:6]}.{cpf[6:9]}-{cpf[9:]}"


def typed_birth_date(born: date, rng: random.Random) -> str | None:
    """Birth date stored as text, in the formats different screens used over the years."""
    roll = rng.random()
    if roll < 0.70:
        return born.strftime("%d/%m/%Y")
    if roll < 0.90:
        return born.isoformat()
    if roll < 0.95:
        return "00/00/0000"
    return None


def fipe_code(category: str, model: tuple, model_year: int) -> str:
    """A stable code per model and year, in the style of the FIPE price table."""
    return f"{list(MODELS).index(category) + 1:02d}{MODELS[category].index(model):02d}{model_year % 100:02d}-{model_year % 7}"


def plate(rng: random.Random) -> str:
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    first = "".join(rng.choice(letters) for _ in range(3))
    return f"{first}{rng.randint(0, 9)}{rng.choice(letters)}{rng.randint(0, 99):02d}"  # Mercosul format: ABC1D23


# ---------------------------------------------------------------------------------------------
# The timeline
# ---------------------------------------------------------------------------------------------
def generate(scale: float = 1.0, seed: int = 42) -> World:
    rng = random.Random(seed)
    world = World()
    states = list(STATES)
    state_weights = [STATES[s][0] for s in states]

    # 1. Brokers. A few big brokers sell most policies (as in the real market)
    for broker_id in range(1, 61):
        world.brokers.append(
            {
                "id": broker_id,
                "name": f"{rng.choice(LAST_NAMES)} {rng.choice(['CORRETORA DE SEGUROS', 'SEGUROS LTDA', 'CORRETAGEM'])}",
                "susep": f"{rng.randint(10, 99)}.{rng.randint(100000, 999999)}",
                "state": rng.choices(states, state_weights)[0],
                "weight": 1 / broker_id**0.8,
                "deactivated_at": None,
            }
        )
    for broker in rng.sample(world.brokers[30:], 2):  # two small brokers stop working with the insurer in October
        broker["deactivated_at"] = at_business_hours(date(2026, 10, rng.randint(5, 25)), rng)
    broker_weights = [b["weight"] for b in world.brokers]

    # 2. Customers, their vehicles and their policies (with renewals and cancellations)
    policy_number, claim_number, vehicle_id = 7_000_000, 9_000_000, 0
    n_customers = int(15_000 * scale)
    for customer_id in range(1, n_customers + 1):
        state = rng.choices(states, state_weights)[0]
        cpf = new_cpf(rng)
        customer = {
            "id": customer_id,
            "name": f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)} {rng.choice(LAST_NAMES)}",
            "cpf_typed": typed_cpf(cpf, rng),
            "cpf_fixed": None,
            "fixed_at": None,
            "birth": typed_birth_date(date(rng.randint(1950, 2004), rng.randint(1, 12), rng.randint(1, 28)), rng),
            "state": state,
            "city": rng.choice(STATES[state][1]),
            "move": None,
            "created_at": None,
        }
        # Planted defects: CPF with wrong check digits (1%), state typed wrong or left blank (0.5%)
        if rng.random() < 0.01:
            wrong = cpf[:10] + str((int(cpf[10]) + 1) % 10)
            customer["cpf_typed"] = wrong
            if rng.random() < 0.3:  # some are corrected at the branch in October
                customer["cpf_fixed"] = cpf
        if rng.random() < 0.005:
            customer["state"] = rng.choice(["XX", ""])
        broker = rng.choices(world.brokers, broker_weights)[0]

        for _ in range(2 if rng.random() < 0.08 else 1):
            vehicle_id += 1
            category = rng.choices(list(CATEGORY_SHARE), list(CATEGORY_SHARE.values()))[0]
            make, model, new_value = rng.choice(MODELS[category])
            model_year = rng.randint(2010, 2026)
            fipe = new_value * max(0.35, 1 - 0.055 * (2026 - model_year)) * rng.uniform(0.95, 1.05)
            vehicle = {
                "id": vehicle_id,
                "customer_id": customer_id,
                "plate": plate(rng),
                "fipe_code": fipe_code(category, (make, model, new_value), model_year),
                "make": make,
                "model": model,
                "year": model_year,
                "category": category,
                "typed_category": rng.choice(CATEGORY_TYPED[category]),
                "fipe": money(fipe),
                "created_at": None,
            }
            world.vehicles.append(vehicle)

            # First policy starts any day of the portfolio; renewals follow until a cancellation or a lapse
            start = PORTFOLIO_START + timedelta(days=rng.randint(0, (MONTH_LATER - PORTFOLIO_START).days))
            issued = at_business_hours(start - timedelta(days=rng.randint(0, 10)), rng)
            previous = None
            if category == "AUTO":
                product = 2 if rng.random() < 0.55 else 1
            else:
                product = 3 if category == "MOTO" else 4
            while issued.date() <= MONTH_LATER:
                policy_number += 1
                end = one_year_after(start)
                cancel, cancel_recorded = None, None
                if rng.random() < 0.07:  # cancelled during the term (e.g. unpaid premium), often recorded weeks later
                    cancel = start + timedelta(days=rng.randint(30, 330))
                    cancel_recorded = at_business_hours(cancel + timedelta(days=rng.randint(0, 25)), rng)
                policy = {
                    "number": policy_number,
                    "customer_id": customer_id,
                    "vehicle_id": vehicle_id,
                    "broker_id": broker["id"],
                    "product": product,
                    "issued": issued,
                    "start": start,
                    "end": end,
                    "cancel": cancel,
                    "cancel_recorded": cancel_recorded,
                    "previous": previous,
                    "coverages": [],
                }
                for coverage in PRODUCT_COVERAGES[product]:
                    if product == 3 and coverage == "TERCEIROS" and rng.random() < 0.5:
                        continue
                    sum_insured, premium = _price(coverage, category, float(vehicle["fipe"]), state, rng)
                    if rng.random() < 0.004:  # planted defect: premium recorded as zero
                        premium = Decimal("0.00")
                    policy["coverages"].append({"code": coverage, "sum_insured": sum_insured, "premium": premium})
                world.policies.append(policy)
                customer["created_at"] = customer["created_at"] or issued - timedelta(hours=rng.randint(1, 48))
                vehicle["created_at"] = vehicle["created_at"] or issued - timedelta(minutes=rng.randint(5, 120))

                # Claims of this policy
                for coverage in policy["coverages"]:
                    if coverage["premium"] <= 0:
                        continue
                    for claim in _claims(policy, coverage, category, float(vehicle["fipe"]), state, rng):
                        claim_number += 1
                        claim["number"] = claim_number
                        world.claims.append(claim)

                if cancel or rng.random() > 0.75:  # 75% of the customers renew
                    break
                previous = policy_number
                start = end
                issued = at_business_hours(end - timedelta(days=rng.randint(5, 20)), rng)

        # Customers who move in October (new address = new risk region, kept as history in the warehouse)
        if rng.random() < 0.015 and customer["created_at"] and customer["created_at"].date() <= FIRST_LOAD:
            new_state = rng.choices(states, state_weights)[0]
            customer["move"] = {
                "at": at_business_hours(date(2026, 10, rng.randint(1, 30)), rng),
                "state": new_state,
                "city": rng.choice(STATES[new_state][1]),
            }
        if customer["cpf_fixed"]:
            customer["fixed_at"] = at_business_hours(date(2026, 10, rng.randint(1, 30)), rng)
        world.customers.append(customer)

    # 3. Planted defects in claims: claim typed with a policy number that does not exist (half fixed in October)
    visible = [c for c in world.claims if c["reported_at"].date() <= FIRST_LOAD]
    for claim in rng.sample(visible, min(15, len(visible))):
        claim["typed_policy"] = claim["policy"] + 1_000_000
        if rng.random() < 0.5:
            claim["fixed_at"] = at_business_hours(date(2026, 10, rng.randint(1, 30)), rng)
    # ... and payments recorded against a claim number that does not exist
    for i in range(1, 21):
        when = at_business_hours(date(2026, rng.randint(1, 9), rng.randint(1, 28)), rng)
        world.orphan_movements.append(
            {"claim": 99_000_000 + i, "seq": 1, "at": when, "type": "PAG", "amount": money(rng.uniform(800, 9000))}
        )
    return world


def _price(coverage: str, category: str, fipe: float, state: str, rng: random.Random) -> tuple[Decimal, Decimal]:
    """Sum insured and net premium of a coverage (simplified rating)."""
    noise = rng.uniform(0.9, 1.1)
    if coverage == "ROUBO":
        rate = {"AUTO": 0.025, "MOTO": 0.065, "CAMINHAO": 0.018}[category]
        if state in HIGH_THEFT_STATES:
            rate *= 1.35
        return money(fipe), money(fipe * rate * noise)
    if coverage == "COLISAO":
        return money(fipe), money(fipe * (0.025 if category == "CAMINHAO" else 0.03) * noise)
    if coverage == "TERCEIROS":
        if category == "CAMINHAO":
            return money(500_000), money(rng.uniform(1500, 3000))
        return money(100_000), money(rng.uniform(350, 900))
    return money(5_000), money(rng.uniform(150, 280))  # VIDROS (glass)


def _claims(policy: dict, coverage: dict, category: str, fipe: float, state: str, rng: random.Random) -> list[dict]:
    """Claims of one coverage during the policy term, each with its movements."""
    effective_end = policy["cancel"] or policy["end"]
    days = (effective_end - policy["start"]).days
    if days <= 0:
        return []
    if coverage["code"] == "ROUBO":
        frequency = THEFT_FREQUENCY[category] * (1.5 if state in HIGH_THEFT_STATES else 1.0)
    else:
        frequency = OTHER_FREQUENCY[coverage["code"]]
    probability = frequency * days / 365
    count = 0
    if rng.random() < probability:
        count = 2 if rng.random() < probability * 0.15 else 1

    claims = []
    for _ in range(count):
        occurred = policy["start"] + timedelta(days=rng.randint(0, days - 1))
        if rng.random() < 0.004:  # planted defect: occurrence typed before the policy started
            occurred = policy["start"] - timedelta(days=rng.randint(3, 40))
        reported = at_business_hours(occurred + timedelta(days=min(60, int(rng.expovariate(1 / 4)))), rng)
        reported = max(reported, policy["issued"] + timedelta(hours=1))  # a claim is never recorded before its policy
        if reported.date() > MONTH_LATER:
            continue
        movements, status, closed_at = _movements(coverage["code"], fipe, reported, rng)
        cause = {
            "ROUBO": rng.choice(["ROUBO", "ROUBO", "FURTO"]),
            "COLISAO": "COLISAO",
            "TERCEIROS": "DANOS A TERCEIROS",
            "VIDROS": "QUEBRA DE VIDRO",
        }[coverage["code"]]
        claims.append(
            {
                "policy": policy["number"],
                "typed_policy": None,
                "fixed_at": None,
                "coverage": coverage["code"],
                "occurred": occurred,
                "reported_at": reported,
                "cause": cause,
                "state": state if state in STATES else rng.choice(list(STATES)),
                "status": status,
                "closed_at": closed_at,
                "movements": movements,
            }
        )
    return claims


def _movements(coverage: str, fipe: float, reported: datetime, rng: random.Random) -> tuple[list[dict], str, datetime]:
    """Claim lifecycle: opening reserve, then denial, vehicle recovered, or payment (and salvage).

    AVI = opening reserve, AJU = reserve adjustment, PAG = payment, SAL = salvage/recovery.
    Incurred cost = payments + reserve still open - recoveries.
    """
    estimate = {
        "ROUBO": fipe,
        "COLISAO": fipe * rng.uniform(0.15, 0.6),
        "TERCEIROS": rng.uniform(2000, 40000),
        "VIDROS": rng.uniform(300, 1500),
    }[coverage]
    estimate = money(estimate)
    moves = [{"at": reported + timedelta(minutes=rng.randint(5, 90)), "type": "AVI", "amount": estimate}]
    decision = reported + timedelta(days=rng.randint(10, 60), hours=rng.randint(0, 6))

    if rng.random() < 0.08:  # denied: the reserve is released
        moves.append({"at": decision, "type": "AJU", "amount": -estimate})
        return _numbered(moves), "N", decision
    if coverage == "ROUBO" and rng.random() < 0.30:  # vehicle found before payment
        found = reported + timedelta(days=rng.randint(3, 25))
        moves.append({"at": found, "type": "AJU", "amount": -estimate})
        if rng.random() < 0.4:  # repairs of the recovered vehicle
            repairs = money(fipe * rng.uniform(0.1, 0.25))
            moves.append({"at": found + timedelta(days=rng.randint(5, 20)), "type": "PAG", "amount": repairs})
        return _numbered(moves), "R", moves[-1]["at"]

    paid = estimate if coverage == "ROUBO" else money(float(estimate) * rng.uniform(0.7, 1.3))
    if coverage == "COLISAO" and rng.random() < 0.25:  # partial payment first, the rest at the end of the repair
        first = money(float(paid) * 0.4)
        moves.append({"at": reported + timedelta(days=rng.randint(3, 9)), "type": "PAG", "amount": first})
        moves.append({"at": decision, "type": "PAG", "amount": paid - first})
    else:
        moves.append({"at": decision, "type": "PAG", "amount": paid})
    moves.append({"at": decision + timedelta(minutes=1), "type": "AJU", "amount": -estimate})
    closed = decision + timedelta(minutes=1)
    if coverage == "ROUBO" and rng.random() < 0.12:  # stolen vehicle found after payment and sold at auction
        salvage = money(fipe * rng.uniform(0.25, 0.45))
        moves.append({"at": decision + timedelta(days=rng.randint(20, 120)), "type": "SAL", "amount": salvage})
    return _numbered(moves), "P", closed


def _numbered(moves: list[dict]) -> list[dict]:
    moves.sort(key=lambda m: m["at"])
    for seq, move in enumerate(moves, start=1):
        move["seq"] = seq
    return moves


# ---------------------------------------------------------------------------------------------
# Photograph of the legacy tables at a date
# ---------------------------------------------------------------------------------------------
def snapshot(world: World, day: date) -> dict[str, list[tuple]]:
    """What the legacy system holds at the end of `day`: only what already happened, as it was typed."""
    cut = end_of(day)
    rows: dict[str, list[tuple]] = {table: [] for table in TABLES}

    for b in world.brokers:
        inactive = b["deactivated_at"] is not None and b["deactivated_at"] <= cut
        changed = b["deactivated_at"] if inactive else BROKERS_SINCE
        rows["Corretor"].append((b["id"], b["name"], b["susep"], b["state"], "N" if inactive else "S", changed))
    for product_id, name in PRODUCTS.items():
        rows["Produto"].append((product_id, name, BROKERS_SINCE))

    for c in world.customers:
        if c["created_at"] is None or c["created_at"] > cut:
            continue
        state, city, changed, cpf = c["state"], c["city"], c["created_at"], c["cpf_typed"]
        if c["move"] and c["move"]["at"] <= cut:
            state, city, changed = c["move"]["state"], c["move"]["city"], c["move"]["at"]
        if c["fixed_at"] and c["fixed_at"] <= cut:
            cpf, changed = c["cpf_fixed"], max(changed, c["fixed_at"])
        rows["Segurado"].append((c["id"], c["name"], cpf, c["birth"], state, city, changed))

    for v in world.vehicles:
        if v["created_at"] is None or v["created_at"] > cut:
            continue
        rows["Veiculo"].append(
            (
                v["id"],
                v["customer_id"],
                v["plate"],
                v["fipe_code"],
                v["make"],
                v["model"],
                v["year"],
                v["typed_category"],
                v["fipe"],
                v["created_at"],
            )
        )

    for p in world.policies:
        if p["issued"] > cut:
            continue
        cancelled = p["cancel"] if p["cancel_recorded"] and p["cancel_recorded"] <= cut else None
        changed = p["cancel_recorded"] if cancelled else p["issued"]
        rows["Apolice"].append(
            (
                p["number"],
                p["customer_id"],
                p["vehicle_id"],
                p["broker_id"],
                p["product"],
                p["issued"],
                datetime.combine(p["start"], time()),
                datetime.combine(p["end"], time()),
                datetime.combine(cancelled, time()) if cancelled else None,
                p["previous"],
                changed,
            )
        )
        for cov in p["coverages"]:
            rows["ApoliceCobertura"].append((p["number"], cov["code"], cov["sum_insured"], cov["premium"], p["issued"]))

    for c in world.claims:
        if c["reported_at"] > cut:
            continue
        moves = [m for m in c["movements"] if m["at"] <= cut]
        status = c["status"] if c["closed_at"] <= cut else "A"
        changed = max([c["reported_at"]] + [m["at"] for m in moves])
        policy = c["policy"]
        if c["typed_policy"]:
            fixed = c["fixed_at"] is not None and c["fixed_at"] <= cut
            policy = c["policy"] if fixed else c["typed_policy"]
            if fixed:
                changed = max(changed, c["fixed_at"])
        rows["Sinistro"].append(
            (
                c["number"],
                policy,
                c["coverage"],
                datetime.combine(c["occurred"], time()),
                c["reported_at"],
                c["cause"],
                c["state"],
                status,
                changed,
            )
        )
        for m in moves:
            rows["SinistroMovimento"].append((c["number"], m["seq"], m["at"], m["type"], m["amount"], m["at"]))

    for m in world.orphan_movements:
        if m["at"] <= cut:
            rows["SinistroMovimento"].append((m["claim"], m["seq"], m["at"], m["type"], m["amount"], m["at"]))
    return rows


def changes(world: World, before: date, after: date) -> dict[str, list[tuple]]:
    """Rows that are new or different in the legacy system between two dates (one month of activity)."""
    old, new = snapshot(world, before), snapshot(world, after)
    result = {}
    for table, rows in new.items():
        width = KEYS.get(table, 1)
        previous = {row[:width]: row for row in old[table]}
        result[table] = [row for row in rows if previous.get(row[:width]) != row]
    return result
