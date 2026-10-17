#!/usr/bin/env python3
"""Independent verification; requires gostcrypto==1.2.5. Never handles credentials."""
import ctypes
from pathlib import Path
import subprocess
import tempfile
from gostcrypto import gosthash

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="hh-streebog-") as directory:
    lib = Path(directory) / "streebog.dylib"
    subprocess.run(["clang", "-dynamiclib", str(root / "HHVacancyCBR/HHVacancyCBR/Vendor/Streebog/Bridge.c"), "-o", str(lib)], check=True)
    digest = ctypes.CDLL(str(lib)).hh_streebog512
    digest.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p]
    vectors = [
        b"012345678901234567890123456789012345678901234567890123456789012",
        bytes.fromhex("d1e520e2e5f2f0e82c20d1f2f0e8e1eee6e820e2edf3f6e82c20e2e5fef2fa20f120eceef0ff20f1f2f0e5ebe0ece820ede020f5f0e0e1f0fbff20efebfaeafb20c8e3eef0e5e2fb"),
    ] + [bytes(i % 251 for i in range(n)) for n in [0, 1, 63, 64, 65, 128, 129, 1024, 65536]]
    for data in vectors:
        output = ctypes.create_string_buffer(64)
        digest(data, len(data), output)
        assert output.raw.hex() == gosthash.new("streebog512", data=bytearray(data)).hexdigest(), len(data)
    print(f"PASS: {len(vectors)} RFC / boundary / long-message vectors match gostcrypto")
