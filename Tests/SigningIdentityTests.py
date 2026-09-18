import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("signing", Path(__file__).parents[1] / "Tools/select-development-identity.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
a, b, legacy = "A" * 40, "B" * 40, "C" * 40
one = f'1) {a} "Apple Development: Example (TEAM)"\n2) {legacy} "Vorssaint Utils Signing"'
two = one + f'\n3) {b} "Apple Development: Other (OTHER)"'
assert module.select_identity(one) == a
assert module.select_identity(two, installed="Apple Development: Example (TEAM)") == a
assert module.select_identity(two, requested=b.lower()) == b
for listing, requested, installed in [
    ("", "", ""), (two, "", ""), (one, "Vorssaint Utils Signing", ""),
    (one, b, ""), (one, "", "Apple Development: Missing (MISSING)"),
    (f'1) {legacy} "Vorssaint Utils Signing"', "", ""),
]:
    try:
        module.select_identity(listing, requested, installed)
        raise AssertionError("Unsafe signer fallback accepted")
    except ValueError:
        pass
print("PASS: Apple Development selection, continuity, ambiguity and no legacy fallback")
