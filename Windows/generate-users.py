#!/usr/bin/env python3
"""Generates roles/Users/users.csv with fake Middelfart Racing employees.

    ./generate-users.py         25 users per department
    ./generate-users.py 40      40 per department

Seeded, and stable when the count grows: raising it only appends users, so
re-deploying never renames anyone who already exists. Names are ASCII
(ae/oe/aa) because deploy.sh refuses non-ASCII files under roles/.
"""
import csv
import random
import sys
from pathlib import Path

# department -> (OU below OU=Users, titles; the first one goes to one person only)
DEPARTMENTS = {
    "IT":     ("OU=IT,OU=Administration",     ["IT-chef", "Systemadministrator", "IT-supporter", "Netvaerksadministrator"]),
    "HR":     ("OU=HR,OU=Administration",     ["HR-chef", "HR-konsulent", "Loenadministrator", "HR-partner"]),
    "Finans": ("OU=Finans,OU=Administration", ["Oekonomichef", "Bogholder", "Controller", "Regnskabsassistent"]),
    "Lager":  ("OU=Lager",                    ["Lagerchef", "Lagermedarbejder", "Truckfoerer", "Lagerassistent"]),
}

GIVEN = """Anders Anne Birgitte Bo Camilla Christian Dorthe Emil Emma Frederik Gitte
Hanne Henrik Ida Jakob Jens Jesper Julie Karen Kasper Lars Laura Lise Mads Maja
Malene Martin Mette Mikkel Morten Niels Nanna Ole Pernille Peter Rasmus Sofie
Soeren Susanne Thomas Tina Troels Ulla Viktor""".split()

SURNAMES = """Andersen Bach Berg Christensen Dahl Eriksen Frederiksen Hansen Holm
Iversen Jakobsen Jensen Joergensen Juhl Kjaer Kristensen Larsen Lund Madsen
Mikkelsen Moeller Nielsen Olsen Pedersen Poulsen Rasmussen Schmidt Soerensen
Thomsen Vestergaard""".split()


def generate(per_department):
    pairs = [(g, s) for g in GIVEN for s in SURNAMES]
    random.Random(2026).shuffle(pairs)  # full shuffle, so a prefix is stable
    departments = list(DEPARTMENTS)
    seen, rows = set(), []
    for i, (given, surname) in enumerate(pairs[: per_department * len(departments)]):
        dept = departments[i % len(departments)]
        ou, titles = DEPARTMENTS[dept]
        nth = i // len(departments)  # position within the department
        title = titles[0] if nth == 0 else titles[1 + nth % (len(titles) - 1)]

        base = (given[:2] + surname[:3]).lower()  # h5 style, lowercase: milau
        sam, n = base, 1
        while sam in seen:
            n += 1
            sam = f"{base}{n}"
        seen.add(sam)
        rows.append({"sam": sam, "given_name": given, "surname": surname,
                     "department": dept, "title": title, "ou": ou})
    return rows


if __name__ == "__main__":
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 25
    rows = generate(count)
    assert len({r["sam"] for r in rows}) == len(rows), "duplicate sam"
    assert generate(count + 5)[: len(rows)] == rows, "growing the count renamed users"

    out = Path(__file__).parent / "roles" / "Users" / "users.csv"
    out.parent.mkdir(exist_ok=True)
    with out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys(), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} users to {out}")
