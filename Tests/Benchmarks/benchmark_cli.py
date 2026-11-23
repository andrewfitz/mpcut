"""Helpers for comparing the current CLI with the older flat commands."""

import re
import subprocess


def command_help(binary):
    result = subprocess.run([binary, "--help"], capture_output=True, text=True,
                            check=True, timeout=30)
    return result.stdout + result.stderr


def normalize_report(report):
    """Apply the current JSON field naming convention to a legacy report."""
    if isinstance(report, list):
        return [normalize_report(value) for value in report]
    if isinstance(report, dict):
        return {snake_case(key): normalize_report(value) for key, value in report.items()}
    return report


def snake_case(key):
    key = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", key)
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", key).lower()
