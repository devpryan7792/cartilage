"""
Execution wrapper for python -m cartilage (forwards to kurogane).
"""

import sys
from kurogane.cli import main

if __name__ == "__main__":
    sys.exit(main())

