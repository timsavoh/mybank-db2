#!/usr/bin/env python3
"""Generate MyBank seed data as Db2 DEL (CSV) files for LOAD.

Deterministic (fixed random seed). Produces customers, accounts, cards, payees,
standing orders, direct debit mandates, loans and ~60 business days of posted
transaction history with matching GL entries, so the ledger invariants hold:

  SUM(GL_ENTRY) = 0
  per control GL: SUM(account ledger balances) + SUM(GL entries) = 0

Usage: python3 generate.py [--customers 10000] [--days 60] [--out data]
"""
import argparse
import csv
import math
import os
import random
import re
from datetime import date, datetime, timedelta
from decimal import Decimal, ROUND_HALF_UP

HERE = os.path.dirname(os.path.abspath(__file__))
CURRENT_BUSINESS_DATE = date(2026, 10, 1)
CENT = Decimal("0.01")

BRANCHES = {  # id: (sort code, town)
    1: ("080101", "London"), 2: ("080102", "London"), 3: ("080201", "Manchester"),
    4: ("080202", "Liverpool"), 5: ("080301", "Leeds"), 6: ("080302", "Sheffield"),
    7: ("080401", "Birmingham"), 8: ("080402", "Nottingham"), 9: ("080501", "Bristol"),
    10: ("080601", "Cardiff"), 11: ("080701", "Newcastle"), 12: ("089999", "London"),
}
OPEN_BRANCHES = [b for b in BRANCHES if b != 6]

PRODUCTS = {  # code: (control GL, overdraft limit, OD allowed)
    "CUR001": ("2110", 250), "CUR002": ("2110", 1500), "CUR003": ("2110", 1000),
    "CUR004": ("2110", 0), "SAV001": ("2120", 0), "SAV002": ("2120", 0),
    "SAV003": ("2120", 0), "LON001": ("1310", 0),
}

FIRST_NAMES = """Oliver George Arthur Noah Muhammad Leo Harry Oscar Archie Henry Theodore Freddie
Jack Charlie Theo Alfie Jacob Thomas Finley Arlo William Lucas Roman Tommy Isaac Teddy Alexander
Olivia Amelia Isla Ava Ivy Freya Lily Florence Mia Willow Rosie Sophia Isabella Grace Daisy Sienna
Poppy Elsie Emily Ella Evelyn Phoebe Sofia Evie Charlotte Harper Matilda Aisha Priya Chloe Ruth
Margaret Susan David John Peter Michael Paul Andrew Karen Helen Janet Gareth Rhys Siobhan Aoife""".split()
LAST_NAMES = """Smith Jones Williams Taylor Brown Davies Evans Wilson Thomas Johnson Roberts Robinson
Thompson Wright Walker White Edwards Hughes Green Hall Lewis Harris Clarke Patel Jackson Wood Turner
Martin Cooper Hill Ward Morris Moore Clark Lee King Baker Harrison Morgan Allen James Scott Phillips
Watson Davis Parker Price Bennett Young Griffiths Mitchell Kelly Cook Carter Richardson Bailey
Collins Bell Shaw Murphy Miller Cox Richards Khan Marshall Anderson Simpson Ellis Adams Singh Begum
Wilkinson Foster Chapman Powell Webb Rogers Gray Mason Ali Hunt Hussain Campbell Matthews Owen
Palmer Holmes Mills Barnes Knight Lloyd Butler Russell Barker Fisher Stevens Jenkins Murray Dixon""".split()
STREETS = """High Street,Station Road,Church Lane,Victoria Road,Green Lane,Manor Road,Park Avenue,
Queens Road,Kings Road,Mill Lane,New Road,School Lane,The Crescent,Grange Road,Chester Road,
Albert Road,York Road,London Road,Springfield Road,Mount Pleasant""".replace("\n", "").split(",")
TITLES = {"M": ["Mr", "Mr", "Mr", "Dr"], "F": ["Mrs", "Ms", "Miss", "Dr"]}

MERCHANT_TEMPLATES = {  # mcc: (name parts, typical amount range, weight)
    "5411": (["Greenleaf Grocers", "Corner Fresh", "Harvest Foods", "Market Basket", "Village Store",
              "Northgate Supermarket", "Daily Pantry", "FreshWay"], (3, 95), 30),
    "5812": (["The Olive Tree", "Bistro Nine", "Copper Kettle", "The Red Lion", "Spice Route",
              "Harbour Kitchen", "Little Italy"], (12, 110), 8),
    "5814": (["Burger Barn", "Fryer Tuck", "Noodle Box", "Pizza Point", "Chicken Shack",
              "Sub Station"], (4, 25), 12),
    "5541": (["Fuelstop", "Roadside Services", "PetroPlus", "Motorway Fuel"], (20, 90), 6),
    "4111": (["City Transit", "Metro Rail", "Bus Link"], (2, 15), 10),
    "4121": (["QuickCab", "RideNow", "Night Taxis"], (6, 40), 4),
    "5732": (["Circuit World", "Gadget Hub", "TechZone"], (15, 600), 2),
    "5311": (["Hartley & Sons", "The Emporium", "Barrow's"], (10, 180), 3),
    "5912": (["Wellcare Pharmacy", "Health Plus Chemist"], (3, 40), 4),
    "5691": (["Threads", "Urban Outfit", "Style Street"], (12, 120), 4),
    "7832": (["Picturehouse", "Odeonic Cinemas"], (8, 30), 2),
    "5999": (["Bits & Bobs", "The Gift Shop", "Online Marketplace"], (5, 80), 8),
    "4829": (["SendAbroad", "QuickTransfer"], (50, 400), 1),
    "6051": (["CoinVault", "CryptoGate"], (50, 900), 1),
    "7995": (["LuckyBet", "Spin Palace", "Grand Stakes"], (10, 300), 1),
}
TOWNS = ["London", "Manchester", "Leeds", "Birmingham", "Bristol", "Cardiff", "Newcastle",
         "Liverpool", "Nottingham", "Sheffield", "Online"]

EMPLOYERS = ["NHS TRUST PAYROLL", "COUNTY COUNCIL", "ACME LOGISTICS LTD", "BRIGHTSIDE RETAIL",
             "NORTHERN RAIL LTD", "UNIVERSITY PAYROLL", "HALCYON SOFTWARE", "GREENFIELD FARMS",
             "CIVIL SERVICE PAY", "METRO BUILDERS LTD"]
DD_ORIGINATORS = [  # (id, name, amount range)
    ("234567", "BRIGHT ENERGY", (45, 160)), ("345678", "AQUA WATER", (25, 60)),
    ("456789", "COUNCIL TAX", (90, 240)), ("567890", "SKYLINE MOBILE", (12, 55)),
    ("678901", "FASTNET BROADBAND", (25, 60)), ("789012", "FITLIFE GYMS", (20, 55)),
    ("890123", "SHIELD INSURANCE", (15, 90)), ("901234", "STREAMFLIX", (6, 18)),
]
PAYEE_NAMES = ["J SMITH", "LANDLORD PROPERTIES", "M PATEL", "S JONES", "ROOFTOP LETTINGS",
               "A KHAN", "CHILDCARE LTD", "R WILSON", "SAVINGS POT", "K BROWN", "PIANO LESSONS"]


def money(x):
    return Decimal(x).quantize(CENT, rounding=ROUND_HALF_UP)


def check_digit(base7: str) -> str:
    """Must match UTIL.ACCOUNT_CHECK_DIGIT."""
    return str(sum(int(d) * (8 - i) for i, d in enumerate(base7, start=1)) % 10)


def luhn_digit(partial: str) -> str:
    total = 0
    for i, ch in enumerate(reversed(partial)):
        d = int(ch)
        if i % 2 == 0:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return str((10 - total % 10) % 10)


def ts(d: date, rnd: random.Random, start_hour=7, end_hour=22) -> str:
    secs = rnd.randint(start_hour * 3600, end_hour * 3600 - 1)
    t = datetime(d.year, d.month, d.day) + timedelta(seconds=secs, microseconds=rnd.randint(0, 999999))
    return t.strftime("%Y-%m-%d-%H.%M.%S.%f")


def last_day_of_month(d: date) -> date:
    nxt = date(d.year + (d.month // 12), d.month % 12 + 1, 1)
    return nxt - timedelta(days=1)


def add_months(d: date, n: int) -> date:
    y, m = divmod(d.month - 1 + n, 12)
    y += d.year
    m += 1
    return date(y, m, min(d.day, last_day_of_month(date(y, m, 1)).day))


class Calendar:
    def __init__(self):
        sql = open(os.path.join(HERE, "01_reference.sql")).read()
        self.holidays = {date.fromisoformat(s) for s in re.findall(r"\(\s*'(\d{4}-\d{2}-\d{2})',\s*'[A-Z]", sql)}

    def is_business_day(self, d):
        return d.weekday() < 5 and d not in self.holidays

    def next_business_day(self, d):
        d += timedelta(days=1)
        while not self.is_business_day(d):
            d += timedelta(days=1)
        return d

    def on_or_after(self, d):
        return d if self.is_business_day(d) else self.next_business_day(d)

    def on_or_before(self, d):
        while not self.is_business_day(d):
            d -= timedelta(days=1)
        return d

    def business_days_before(self, end, n):
        days, d = [], end - timedelta(days=1)
        while len(days) < n:
            if self.is_business_day(d):
                days.append(d)
            d -= timedelta(days=1)
        return list(reversed(days))


class Writer:
    """Collects rows per table and writes Db2 DEL files."""

    def __init__(self, out_dir):
        self.out_dir = out_dir
        os.makedirs(out_dir, exist_ok=True)
        self.files, self.counts = {}, {}

    def row(self, table, values):
        if table not in self.files:
            f = open(os.path.join(self.out_dir, table.lower().replace(".", "_") + ".del"), "w", newline="")
            self.files[table] = (f, csv.writer(f, quoting=csv.QUOTE_MINIMAL))
            self.counts[table] = 0
        self.files[table][1].writerow("" if v is None else str(v) for v in values)
        self.counts[table] += 1

    def close(self):
        for f, _ in self.files.values():
            f.close()


class Ledger:
    """Posts transactions with running balances and balanced GL pairs."""

    def __init__(self, w, rnd):
        self.w, self.rnd = w, rnd
        self.txn_id = 0
        self.gl_id = 0
        self.corr = 0
        self.balances = {}
        self.accounts = {}
        self.last_customer_activity = {}

    def new_corr(self):
        self.corr += 1
        return self.corr

    def post(self, acct, amount, d, txn_type, desc, contra, channel="SYS", corr=None, ref=None,
             cp_name=None, cp_sort=None, cp_acct=None, merchant=None, mcc=None):
        amount = money(amount)
        corr = corr or self.new_corr()
        self.balances[acct["id"]] += amount
        self.txn_id += 1
        self.w.row("TXN.POSTED_TXN", [
            self.txn_id, acct["id"], d.isoformat(), ts(d, self.rnd), txn_type, amount,
            self.balances[acct["id"]], desc[:100], ref, cp_name, cp_sort, cp_acct, merchant, mcc,
            corr, channel])
        control = PRODUCTS[acct["product"]][0]
        for gl, amt in ((contra, amount), (control, -amount)):
            self.gl_id += 1
            self.w.row("GL.GL_ENTRY", [self.gl_id, d.isoformat(), gl, amt, corr, self.txn_id,
                                       desc[:100], ts(d, self.rnd)])
        if channel != "SYS":
            self.last_customer_activity[acct["id"]] = d
        return self.txn_id

    def available(self, acct):
        return self.balances[acct["id"]] + acct["od_limit"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--customers", type=int, default=10000)
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--out", default=os.path.join(HERE, "data"))
    args = ap.parse_args()

    rnd = random.Random(42)
    cal = Calendar()
    w = Writer(args.out)
    ledger = Ledger(w, rnd)
    history = cal.business_days_before(CURRENT_BUSINESS_DATE, args.days)
    start = history[0]

    # ---- merchants
    merchants = []
    mid = 100000
    for mcc, (names, amt_range, weight) in MERCHANT_TEMPLATES.items():
        for name in names:
            for town in rnd.sample(TOWNS, k=min(len(TOWNS), 3 if weight > 5 else 2)):
                mid += 1
                label = name if town == "Online" else f"{name} {town}"
                merchants.append({"id": mid, "name": label[:60], "mcc": mcc, "range": amt_range, "weight": weight})
                w.row("CARD.MERCHANT", [mid, label[:60], mcc, None if town == "Online" else town,
                                        "GB" if rnd.random() > 0.04 else rnd.choice(["FR", "ES", "IE", "US"])])
    merchant_weights = [m["weight"] for m in merchants]

    # ---- customers
    customers = []
    for i in range(1, args.customers + 1):
        sex = rnd.choice("MF")
        first = rnd.choice(FIRST_NAMES)
        last = rnd.choice(LAST_NAMES)
        dob = date(1941, 1, 1) + timedelta(days=rnd.randint(0, 25000))
        age = (CURRENT_BUSINESS_DATE - dob).days // 365
        opened = min(date(2000, 1, 1) + timedelta(days=rnd.randint(0, 9400)), start - timedelta(days=30))
        opened = max(opened, dob + timedelta(days=16 * 366))
        if opened >= start:
            opened = start - timedelta(days=rnd.randint(30, 400))
        r = rnd.random()
        segment = "STU" if age < 23 and r < 0.8 else "PRM" if r < 0.05 else "AFF" if r < 0.2 else "SME" if r < 0.23 else "MAS"
        branch = 6 if opened.year < 2019 and rnd.random() < 0.03 else (12 if rnd.random() < 0.3 else rnd.choice(OPEN_BRANCHES))
        kyc = "V" if rnd.random() < 0.97 else "P"
        c = {"id": i, "no": f"C{1000000 + i}", "first": first, "last": last, "dob": dob, "age": age,
             "segment": segment, "branch": branch, "opened": opened}
        customers.append(c)
        w.row("CUST.CUSTOMER", [i, c["no"], rnd.choice(TITLES[sex]), first, last, dob.isoformat(),
                                f"QQ{i:06d}{'ABCD'[i % 4]}", segment, branch, "A", kyc,
                                1 if rnd.random() < 0.9 else rnd.randint(2, 4), opened.isoformat(),
                                ts(opened, rnd)])
        town = BRANCHES[branch][1]
        postcode = f"{rnd.choice(['LS', 'M', 'B', 'BS', 'CF', 'NE', 'L', 'NG', 'S', 'E', 'N', 'SW'])}{rnd.randint(1, 28)} {rnd.randint(1, 9)}{rnd.choice('ABDEFGHJLNPQRSTUWXYZ')}{rnd.choice('ABDEFGHJLNPQRSTUWXYZ')}"
        w.row("CUST.ADDRESS", [i, i, "H", f"{rnd.randint(1, 240)} {rnd.choice(STREETS)}", None, town,
                               postcode, "GB", opened.isoformat(), None])
        w.row("CUST.CONTACT", [i, "EMAIL", f"{first.lower()}.{last.lower()}{i}@example.com",
                               "Y", ts(opened, rnd)])
        if rnd.random() < 0.85:
            w.row("CUST.CONTACT", [i, "MOBIL", f"07700{rnd.randint(900000, 999999)}", "Y", ts(opened, rnd)])
        w.row("CUST.KYC_CHECK", [i, i, "IDENTITY", "P" if kyc == "V" else "R", rnd.randint(700, 990),
                                 "EXPERIFY", ts(opened, rnd), None])

    # ---- accounts
    accounts = []
    acct_seq = 2000000

    def open_account(cust, product, opened, name, balance, status="A"):
        nonlocal acct_seq
        acct_seq += 1
        base = str(acct_seq)
        branch = cust["branch"]
        a = {"id": len(accounts) + 1, "sort": BRANCHES[branch][0], "no": base + check_digit(base),
             "product": product, "branch": branch, "cust": cust, "name": name, "status": status,
             "od_limit": Decimal(PRODUCTS[product][1]), "opened": opened, "cards": []}
        accounts.append(a)
        ledger.balances[a["id"]] = Decimal(0)
        ledger.accounts[a["id"]] = a
        a["opening"] = money(balance)
        return a

    for c in customers:
        prod = {"STU": "CUR003", "PRM": "CUR002"}.get(c["segment"], "CUR004" if rnd.random() < 0.05 else "CUR001")
        base_income = {"STU": 900, "PRM": 5200, "AFF": 3400, "SME": 2600}.get(c["segment"], 2100)
        c["salary"] = money(base_income * rnd.uniform(0.7, 1.4)) if rnd.random() < 0.88 else Decimal(0)
        c["current"] = open_account(c, prod, c["opened"], f"{c['first'][0]} {c['last']}".upper(),
                                    rnd.uniform(-150, 2500) if prod != "CUR004" else rnd.uniform(0, 600))
        c["savings"] = None
        if rnd.random() < 0.5:
            sprod = "SAV003" if c["opened"].year < 2014 and rnd.random() < 0.3 else ("SAV002" if rnd.random() < 0.25 else "SAV001")
            c["savings"] = open_account(c, sprod, c["opened"] + timedelta(days=rnd.randint(0, 800)),
                                        f"{c['last'].upper()} SAVINGS", rnd.lognormvariate(8.3, 1.1))
            if sprod == "SAV003" and rnd.random() < 0.6:
                c["savings"]["status"] = "D"
                c["savings"]["dormant"] = True
        if rnd.random() < 0.2 and c["segment"] != "STU":
            c["second"] = open_account(c, "CUR001", c["opened"] + timedelta(days=rnd.randint(30, 2000)),
                                       f"{c['last'].upper()} BILLS", rnd.uniform(50, 1200))
        else:
            c["second"] = None
    for a in accounts:
        a["opened"] = min(a["opened"], start - timedelta(days=5))

    # joint holders: 10% of current accounts get a second holder
    joint = {}
    for c in rnd.sample(customers, k=len(customers) // 10):
        other = rnd.choice(customers)
        if other is not c:
            joint[c["current"]["id"]] = other

    # ---- loans (8% of customers)
    loans = []
    for c in rnd.sample([c for c in customers if c["age"] >= 18], k=int(len(customers) * 0.08)):
        principal = money(rnd.choice([2000, 3000, 5000, 7500, 10000, 15000, 20000, 25000]))
        term = rnd.choice([12, 24, 36, 48, 60])
        rate = Decimal(rnd.choice(["6.9", "7.4", "8.9", "11.9", "14.9"]))
        loan_start = start - timedelta(days=rnd.randint(40, 30 * (term - 3)))
        la = open_account(c, "LON001", loan_start, f"LOAN {c['last'].upper()}", 0)
        r = rate / 1200
        payment = money(principal * r / (1 - (1 + r) ** -term))
        schedule, bal = [], principal
        for n in range(1, term + 1):
            interest = money(bal * r)
            princ = bal if n == term else payment - interest
            pay = princ + interest
            bal = money(bal - princ)
            due = cal.on_or_after(add_months(loan_start, n))
            schedule.append({"n": n, "due": due, "payment": pay, "interest": interest, "principal": princ, "bal": bal})
        before = [s for s in schedule if s["due"] < start]
        outstanding_at_start = before[-1]["bal"] if before else principal
        la["opening"] = -outstanding_at_start
        loans.append({"id": len(loans) + 1, "acct": la, "repay": c["current"], "cust": c, "principal": principal,
                      "rate": rate, "term": term, "payment": payment, "start": loan_start, "schedule": schedule})

    # ---- payees, standing orders, mandates
    payees, standing_orders, mandates = [], [], []
    for c in customers:
        for _ in range(rnd.choice([0, 0, 1, 1, 2, 3])):
            base = str(rnd.randint(1000000, 9999999))
            p = {"id": len(payees) + 1, "cust": c, "name": rnd.choice(PAYEE_NAMES),
                 "sort": f"{rnd.randint(10, 99)}{rnd.randint(0, 99):02d}{rnd.randint(0, 99):02d}",
                 "acct": base + check_digit(base), "created": c["opened"] + timedelta(days=rnd.randint(1, 3000))}
            p["created"] = min(p["created"], start - timedelta(days=1))
            payees.append(p)
            w.row("PAY.PAYEE", [p["id"], c["id"], p["name"], p["sort"], p["acct"],
                                f"REF{rnd.randint(1000, 99999)}", p["created"].isoformat(), "Y"])
            if rnd.random() < 0.35:
                day = rnd.randint(1, 28)
                so = {"id": len(standing_orders) + 1, "acct": c["current"], "payee": p, "day": day,
                      "amount": money(rnd.choice([25, 50, 100, 150, 250, 400, 650, 900]))}
                standing_orders.append(so)
        if c["current"]["product"] != "CUR004" or rnd.random() < 0.5:
            for orig in rnd.sample(DD_ORIGINATORS, k=rnd.randint(1, 4)):
                m = {"id": len(mandates) + 1, "acct": c["current"], "orig": orig, "day": rnd.randint(1, 28),
                     "amount": money(rnd.uniform(*orig[2]))}
                mandates.append(m)

    payees_by_cust = {}
    for p in payees:
        payees_by_cust.setdefault(p["cust"]["id"], []).append(p)

    # ---- opening balances brought forward (contra 3100 retained earnings)
    for a in accounts:
        if a["opening"] != 0:
            ledger.post(a, a["opening"], start, "ADJ", "Balance brought forward", "3100")

    # ---- transaction history
    card_accounts = []
    for c in customers:
        cur = c["current"]
        p = {"STU": 0.16, "PRM": 0.18, "AFF": 0.14}.get(c["segment"], 0.10)
        card_accounts.append((cur, p))
    month_ends = {cal.on_or_before(last_day_of_month(d)) for d in history}
    paydays = {cal.on_or_before(date(d.year, d.month, 25)) for d in history}

    def due_on(day_of_month, d, prev):
        """True if a monthly item on day_of_month falls due on business day d."""
        target = date(d.year, d.month, min(day_of_month, last_day_of_month(d).day))
        return prev < target <= d

    prev = start - timedelta(days=1)
    for d in history:
        # salaries
        if d in paydays:
            for c in customers:
                if c["salary"]:
                    ledger.post(c["current"], c["salary"], d, "FPI", "Salary", "1530", channel="SYS",
                                ref="SALARY", cp_name=rnd.choice(EMPLOYERS))
                    if c["savings"] and not c["savings"].get("dormant") and rnd.random() < 0.6:
                        amt = money(c["salary"] * Decimal(rnd.choice(["0.05", "0.1", "0.15"])))
                        corr = ledger.new_corr()
                        ledger.post(c["current"], -amt, d, "XFR", "Transfer to savings", "1900", "MOB", corr)
                        ledger.post(c["savings"], amt, d, "XFR", "Transfer from current", "1900", "MOB", corr)
        # card spending
        for acct, p in card_accounts:
            if rnd.random() < p:
                for _ in range(rnd.choice([1, 1, 1, 2, 2, 3])):
                    m = rnd.choices(merchants, weights=merchant_weights)[0]
                    lo, hi = m["range"]
                    amt = money(min(hi, lo + rnd.expovariate(3 / (hi - lo))))
                    if ledger.available(acct) >= amt:
                        ledger.post(acct, -amt, d, "CARD", m["name"], "1520", "API",
                                    merchant=m["id"], mcc=m["mcc"], cp_name=m["name"])
        # ATM cash
        for c in rnd.sample(customers, k=len(customers) // 35):
            amt = money(rnd.choice([10, 20, 20, 30, 40, 50, 60, 100, 100, 200]))
            if ledger.available(c["current"]) >= amt:
                ledger.post(c["current"], -amt, d, "CASH", "ATM withdrawal", "1100", "BRN")
        # inbound and outbound faster payments
        for c in rnd.sample(customers, k=len(customers) // 60):
            ledger.post(c["current"], money(rnd.uniform(5, 250)), d, "FPI", "Faster payment received",
                        "1510", "SYS", cp_name=rnd.choice(PAYEE_NAMES))
        for c in rnd.sample(customers, k=len(customers) // 45):
            mine = payees_by_cust.get(c["id"], []) if rnd.random() < 0.5 else []
            amt = money(rnd.uniform(10, 400))
            if mine and ledger.available(c["current"]) >= amt:
                p = rnd.choice(mine)
                ledger.post(c["current"], -amt, d, "FPO", f"Payment to {p['name']}", "1510",
                            rnd.choice(["WEB", "MOB", "MOB"]), cp_name=p["name"], cp_sort=p["sort"], cp_acct=p["acct"])
        # standing orders and direct debits
        for so in standing_orders:
            if due_on(so["day"], d, prev):
                ledger.post(so["acct"], -so["amount"], d, "SO", f"SO {so['payee']['name']}", "1510",
                            cp_name=so["payee"]["name"], cp_sort=so["payee"]["sort"], cp_acct=so["payee"]["acct"])
        for m in mandates:
            if due_on(m["day"], d, prev):
                if ledger.available(m["acct"]) >= m["amount"]:
                    ledger.post(m["acct"], -m["amount"], d, "DD", m["orig"][1], "1530", cp_name=m["orig"][1])
                else:
                    ledger.post(m["acct"], Decimal("-10.00"), d, "FEE", "Unpaid direct debit fee", "4100")
        # loan repayments
        for ln in loans:
            for s in ln["schedule"]:
                if s["due"] == d:
                    corr = ledger.new_corr()
                    ledger.post(ln["repay"], -s["principal"], d, "LOAN", "Loan repayment", "1900", corr=corr)
                    ledger.post(ln["acct"], s["principal"], d, "LOAN", "Repayment received", "1900", corr=corr)
                    ledger.post(ln["repay"], -s["interest"], d, "INT", "Loan interest", "4220")
        # month end: premier fees and savings interest
        if d in month_ends:
            for a in accounts:
                if a["product"] == "CUR002":
                    ledger.post(a, Decimal("-12.50"), d, "FEE", "Monthly account fee", "4100")
                elif a["product"].startswith("SAV") and ledger.balances[a["id"]] > 0:
                    rate = {"SAV001": Decimal("2.5"), "SAV002": Decimal("3.75"), "SAV003": Decimal("0.5")}[a["product"]]
                    interest = money(ledger.balances[a["id"]] * rate / 1200)
                    if interest > 0:
                        ledger.post(a, interest, d, "INT", "Interest paid", "5100")
        prev = d

    # ---- write accounts with final balances
    for a in accounts:
        last = ledger.last_customer_activity.get(a["id"])
        if a.get("dormant"):
            last = date(2023, 1, 1) + timedelta(days=rnd.randint(0, 500))
        w.row("ACCT.ACCOUNT", [a["id"], a["sort"], a["no"], a["product"], a["branch"], a["cust"]["id"],
                               a["name"][:60], "GBP", a["status"], ledger.balances[a["id"]], "0.00",
                               a["od_limit"], "0.000000", (CURRENT_BUSINESS_DATE - timedelta(days=1)).isoformat(),
                               last.isoformat() if last else None, a["opened"].isoformat()])
        w.row("ACCT.ACCOUNT_HOLDER", [a["id"], a["cust"]["id"], "P", a["opened"].isoformat()])
        if a["id"] in joint and a["product"].startswith("CUR"):
            w.row("ACCT.ACCOUNT_HOLDER", [a["id"], joint[a["id"]]["id"], "J", a["opened"].isoformat()])

    # ---- cards
    card_seq = 100000000
    for c in customers:
        for acct in [c["current"], c["second"]]:
            if acct is None or rnd.random() > 0.92:
                continue
            card_seq += 1
            partial = "492912" + f"{card_seq:09d}"
            expiry = last_day_of_month(date(2026, 1, 1) + timedelta(days=rnd.randint(0, 1400)))
            status = "E" if expiry < CURRENT_BUSINESS_DATE else ("L" if rnd.random() < 0.005 else "A")
            w.row("CARD.CARD", [card_seq - 100000000, partial + luhn_digit(partial), acct["id"], c["id"], "D",
                                status, expiry.isoformat(), rnd.choice(["1000.00", "1500.00", "1500.00", "3000.00"]),
                                "Y", add_months(expiry, -36).isoformat(), "LOST" if status == "L" else None])

    # ---- standing orders, mandates (next dates on/after the current business date)
    def next_monthly(day):
        d = date(CURRENT_BUSINESS_DATE.year, CURRENT_BUSINESS_DATE.month, day)
        if d < CURRENT_BUSINESS_DATE:
            d = add_months(d, 1)
        return cal.on_or_after(d)

    for so in standing_orders:
        w.row("PAY.STANDING_ORDER", [so["id"], so["acct"]["id"], so["payee"]["id"], so["amount"], "M",
                                     next_monthly(so["day"]).isoformat(), None, "A",
                                     so["payee"]["created"].isoformat(), None, 0])
    for m in mandates:
        w.row("PAY.DD_MANDATE", [m["id"], m["acct"]["id"], m["orig"][0], m["orig"][1],
                                 f"MB{m['id']:010d}", m["amount"], m["day"], next_monthly(m["day"]).isoformat(),
                                 "A", m["acct"]["opened"].isoformat(), None])

    # ---- loans
    for ln in loans:
        paid = [s for s in ln["schedule"] if s["due"] < CURRENT_BUSINESS_DATE]
        remaining = [s for s in ln["schedule"] if s["due"] >= CURRENT_BUSINESS_DATE]
        outstanding = paid[-1]["bal"] if paid else ln["principal"]
        w.row("LOAN.LOAN", [ln["id"], ln["acct"]["id"], ln["repay"]["id"], ln["cust"]["id"], ln["principal"],
                            ln["rate"], ln["term"], ln["payment"], ln["start"].isoformat(),
                            remaining[0]["due"].isoformat() if remaining else None, outstanding, "0.00", 0,
                            "A" if remaining else "P"])
        for s in ln["schedule"]:
            w.row("LOAN.REPAYMENT_SCHEDULE", [ln["id"], s["n"], s["due"].isoformat(), s["payment"], s["interest"],
                                              s["principal"], s["bal"], "P" if s["due"] < CURRENT_BUSINESS_DATE else "D"])
            if start <= s["due"] < CURRENT_BUSINESS_DATE:
                w.row("LOAN.REPAYMENT", [ln["id"], s["payment"], s["due"].isoformat(), "S", None])

    # ---- daily balance snapshots are left to the batch job; write the latest only
    w.close()
    # LOAD with explicit ids does not advance sequences or identity columns
    restarts = {
        "CUST.CUSTOMER": ("CUSTOMER_ID", args.customers + 1),
        "CUST.ADDRESS": ("ADDRESS_ID", args.customers + 1),
        "CUST.KYC_CHECK": ("KYC_ID", args.customers + 1),
        "ACCT.ACCOUNT": ("ACCOUNT_ID", len(accounts) + 1),
        "CARD.CARD": ("CARD_ID", card_seq - 100000000 + 1),
        "PAY.PAYEE": ("PAYEE_ID", len(payees) + 1),
        "PAY.STANDING_ORDER": ("SO_ID", len(standing_orders) + 1),
        "PAY.DD_MANDATE": ("MANDATE_ID", len(mandates) + 1),
        "LOAN.LOAN": ("LOAN_ID", len(loans) + 1),
        "TXN.POSTED_TXN": ("TXN_ID", ledger.txn_id + 1),
        "GL.GL_ENTRY": ("GL_ENTRY_ID", ledger.gl_id + 1),
    }
    with open(os.path.join(args.out, "_restart.sql"), "w") as f:
        f.write(f"ALTER SEQUENCE CUST.SEQ_CUSTOMER_NO RESTART WITH {1000001 + args.customers}@\n")
        f.write(f"ALTER SEQUENCE ACCT.SEQ_ACCOUNT_NO RESTART WITH {acct_seq + 1}@\n")
        f.write(f"ALTER SEQUENCE CARD.SEQ_CARD_NO RESTART WITH {card_seq + 1}@\n")
        f.write(f"ALTER SEQUENCE TXN.SEQ_CORRELATION RESTART WITH {ledger.corr + 1}@\n")
        for table, (col, n) in restarts.items():
            f.write(f"ALTER TABLE {table} ALTER COLUMN {col} RESTART WITH {n}@\n")

    total = sum(ledger.balances.values())
    print(f"history {history[0]} .. {history[-1]} ({len(history)} business days)")
    for t, n in sorted(w.counts.items()):
        print(f"  {t:28s} {n:>9,}")
    print(f"  net customer balances       {total:>12,}")


if __name__ == "__main__":
    main()
