import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

# Manual integration script, not a pytest module: it needs a live service and
# the `requests` package, which is not a project dependency.
collect_ignore = ["test_consume_manual.py"]
