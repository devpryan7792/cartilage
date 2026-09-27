"""
Execution wrapper for python -m kurogane.
"""

import sys
from .cli import main

if __name__ == "__main__":
    sys.exit(main())
