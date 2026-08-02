#!/usr/bin/env python3
"""Validate a YAML document against a JSON Schema (draft 2020-12).

Usage: schema_check.py <schema.yaml> <document.yaml>

This is the REAL structural validator for inventory/inventory.yaml — it parses
both files with PyYAML and validates the document against the schema with the
reference `jsonschema` library (the same engine check-jsonschema wraps).

Structural checks only. Semantic rules (unique names, path overlaps, ...) are
enforced by validate_inventory() in lib/common.sh.

Exit codes: 0 = valid, 1 = invalid, 2 = usage / parse / schema error.
"""

import sys

try:
    import yaml
    import jsonschema
    from jsonschema import exceptions as jsonschema_exceptions
except ImportError as exc:  # pragma: no cover - environment check path
    print(f"error: missing Python dependency: {exc}", file=sys.stderr)
    print(
        "Install with: sudo apt-get install -y python3-jsonschema python3-yaml",
        file=sys.stderr,
    )
    sys.exit(2)

MAX_ERRORS = 50


def load_yaml(path: str):
    with open(path, "r", encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def format_path(path) -> str:
    if not path:
        return "."
    return "/".join(str(part) for part in path)


def main(argv) -> int:
    if len(argv) != 3:
        print("usage: schema_check.py <schema.yaml> <document.yaml>", file=sys.stderr)
        return 2

    schema_path, doc_path = argv[1], argv[2]
    try:
        schema = load_yaml(schema_path)
        document = load_yaml(doc_path)
    except Exception as exc:  # YAML syntax or read error
        print(f"error: cannot parse YAML: {exc}", file=sys.stderr)
        return 2

    try:
        validator_cls = jsonschema.validators.validator_for(schema)
        validator_cls.check_schema(schema)  # the schema itself must be valid
    except jsonschema_exceptions.SchemaError as exc:
        print(f"error: schema file is not a valid JSON Schema: {exc.message}", file=sys.stderr)
        return 2

    validator = validator_cls(schema)
    errors = list(validator.iter_errors(document))
    if not errors:
        schema_id = schema.get("$id", schema_path)
        print(f"schema check OK: {doc_path} conforms to {schema_id}")
        return 0

    for error in errors[:MAX_ERRORS]:
        print(f"  [{format_path(error.absolute_path)}] {error.message}", file=sys.stderr)
    total = len(errors)
    if total > MAX_ERRORS:
        print(f"  ... and {total - MAX_ERRORS} more error(s)", file=sys.stderr)
    print(f"schema check FAILED: {total} structural issue(s)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
