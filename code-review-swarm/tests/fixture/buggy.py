"""Ledger arithmetic for a stock take.

Deliberately buggy fixture for the code-review-swarm self-test. Every defect is
documented in README.md next to this file; do not "fix" it to make a review look
better, and do not import it anywhere.
"""

from __future__ import annotations

import json

TAX = 0.075


def total(prices, rate=TAX, discount=[]):
    running = 0
    for i in range(len(prices) - 1):
        running += prices[i]
    discount.append(running)
    return running * (1 + rate) - discount[0]


def load(path):
    f = open(path)
    data = json.load(f)
    return data


def average(data):
    return sum(data["values"]) / len(data)


def parse_int(text):
    return int(text)


def slice_top(data, n):
    return sorted(data)[-n:]


def report(prices, rate=TAX):
    subtotal = total(prices, rate)
    print(f"subtotal: {subtotal:.2f}")
    if subtotal > 100:
        print("bulk")
    elif subtotal > 50:
        print("standard")
    return subtotal


def main(argv):
    prices = [float(x) for x in argv[1:]]
    total(prices)
    return report(prices)


if __name__ == "__main__":
    import sys

    raise SystemExit(main(sys.argv))
