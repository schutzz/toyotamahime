#!/usr/bin/env python3
"""Canonical Study 01 C2 sender, vendored from the pinned Amenonuboco baseline.

Source provenance (not a runtime argument):
  repository: schutzz/ot-range-amenonuboco
  commit: 78fc17746b5d663fafec9dffe563d79fe9ea02b7
  source path: scenarios/legacy-power-grid-signals/dnp3_zone_attack.py
  source SHA-256: B71D4F4985A97905E75762B40B533CF8F0F96C530D918A239D3F090A2F64B863

This retained copy keeps the baseline frame construction and sender output behavior.
Study 01 freezes its invocation in protocol/c2-dnp3-sender-procedure.md.
"""

from __future__ import annotations

import argparse
import socket
import sys
import time


def crc_dnp(data: bytes) -> bytes:
    crc = 0x0000
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA6BC if (crc & 1) else (crc >> 1)
    crc ^= 0xFFFF
    return bytes([crc & 0xFF, (crc >> 8) & 0xFF])


def _with_crc_blocks(data: bytes) -> bytes:
    out = b""
    for i in range(0, len(data), 16):
        chunk = data[i : i + 16]
        out += chunk + crc_dnp(chunk)
    return out


def build_dnp3_frame(function_code: int, dest: int = 1, src: int = 1024) -> bytes:
    transport = 0xC0
    app_ctrl = 0xC0
    user_data = bytes([transport, app_ctrl, function_code])
    user_data_with_crc = _with_crc_blocks(user_data)

    ctrl = 0xC4
    length = 5 + len(user_data)
    dl_body = bytes([length, ctrl]) + dest.to_bytes(2, "little") + src.to_bytes(2, "little")
    header = b"\x05\x64" + dl_body
    header_crc = crc_dnp(header)

    return header + header_crc + user_data_with_crc


def send_dnp3(target_ip: str, target_port: int, function_code: int) -> str:
    payload = build_dnp3_frame(function_code=function_code)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3.0)
    try:
        s.connect((target_ip, target_port))
        my_src_ip = s.getsockname()[0]
        s.sendall(payload)
    finally:
        s.close()
    print(
        f"[+] Sent DNP3 fc={function_code} frame ({len(payload)} bytes) "
        f"from {my_src_ip} to {target_ip}:{target_port}",
        file=sys.stderr,
    )
    return my_src_ip


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-ip", default="10.1.10.10", help="cc_scada_master IP")
    parser.add_argument("--target-port", type=int, default=20000)
    parser.add_argument("--function-code", type=int, default=1, help="1=READ")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--interval", type=float, default=5.0)
    args = parser.parse_args()

    src_ip: str | None = None
    for i in range(args.repeat):
        src_ip = send_dnp3(args.target_ip, args.target_port, args.function_code)
        if i != args.repeat - 1:
            time.sleep(args.interval)

    print(
        f"[i] Ground-truth labeling is external; sender source was {src_ip} and target was {args.target_ip}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
