#!/usr/bin/env python3
"""Check the actual dependency-free native queue; no Android runtime or profile."""
from pathlib import Path
import subprocess
import tempfile

app = Path(__file__).resolve().parents[1]
queue = app / "android/app/src/main/java/dev/animusstudio/alkion/LatestBodyEvaluation.java"
check = app / "tool/CharacterBodyBridgeCheck.java"
with tempfile.TemporaryDirectory(prefix="alkion-body-bridge-") as output:
    subprocess.run(["javac", "--release", "17", "-d", output, str(queue), str(check)], check=True)
    subprocess.run(["java", "-cp", output, "dev.animusstudio.alkion.CharacterBodyBridgeCheck"], check=True)
