#!/usr/bin/env python3
"""Generates a large synthetic DBML schema for performance testing.
Usage: scripts/gen-stress.py [tables] [refs] > stress.dbml"""
import random, sys

tables = int(sys.argv[1]) if len(sys.argv) > 1 else 400
refs = int(sys.argv[2]) if len(sys.argv) > 2 else 600
random.seed(7)
types = ["uuid", "varchar", "integer", "bigint", "boolean", "timestamptz", "jsonb", "text", "decimal(10,2)"]
groups = 12
names = [f"t{i:04d}_{random.choice(['users','orders','items','events','logs','stats','offers','rewards'])}" for i in range(tables)]
for i, n in enumerate(names):
    print(f"Table {n} [headercolor: #{random.randint(0x303030, 0xd0d0d0):06x}] {{")
    print("  id uuid [pk, default: `uuidv7()`]")
    for c in range(random.randint(8, 20)):
        note = f", note: 'column {c} of {n}'" if random.random() < 0.2 else ""
        print(f"  col_{c} {random.choice(types)} [not null{note}]")
    print(f"  Note: 'synthetic table {i}'")
    print("}\n")
for _ in range(refs):
    a = random.randrange(1, tables)
    b = random.randrange(0, a)  # mostly a DAG, like real schemas
    print(f"Ref: {names[a]}.col_0 > {names[b]}.id")
for g in range(groups):
    members = names[g::groups]
    print(f"TableGroup group_{g} {{\n  " + "\n  ".join(members) + "\n}")
