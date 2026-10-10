#!/usr/bin/env python3
"""Draws a mock Indian Registration Certificate for any plate, to test the RC step with.

  scripts/mock-rc.py KA01AB1234 --make "Hyundai Motor India Ltd" --model "Creta SX" --colour Red --fuel Diesel
  scripts/mock-rc.py KA01AB1234 --push        # also copies it to the connected phone's Pictures

Fields you leave out are made up from the plate, so the same plate always gives the same RC.
Fake data for testing only: not a real document, and it says so on the card.
"""
import argparse, hashlib, subprocess, sys
from datetime import date, timedelta
from PIL import Image, ImageDraw, ImageFont

ap = argparse.ArgumentParser()
ap.add_argument("plate")
ap.add_argument("--make"); ap.add_argument("--model"); ap.add_argument("--colour"); ap.add_argument("--fuel")
ap.add_argument("--owner"); ap.add_argument("--out"); ap.add_argument("--push", action="store_true")
a = ap.parse_args()

plate = "".join(c for c in a.plate.upper() if c.isalnum())
h = int(hashlib.sha256(plate.encode()).hexdigest(), 16)
pick = lambda xs, k=0: xs[(h >> k) % len(xs)]
cars = [("MARUTI SUZUKI INDIA LTD", "SWIFT VXI", "PETROL"), ("HYUNDAI MOTOR INDIA LTD", "CRETA SX", "DIESEL"),
        ("TATA MOTORS LTD", "NEXON XZ+", "PETROL"), ("HONDA CARS INDIA LTD", "CITY ZX", "PETROL"),
        ("MAHINDRA & MAHINDRA LTD", "XUV700 AX5", "DIESEL"), ("TOYOTA KIRLOSKAR MOTOR", "INNOVA CRYSTA", "DIESEL")]
mk, md, fu = pick(cars)
make = (a.make or mk).upper(); model = (a.model or md).upper(); fuel = (a.fuel or fu).upper()
colour = (a.colour or pick(["WHITE", "SILVER", "GREY", "BLACK", "RED", "BLUE"], 5)).upper()
owner = (a.owner or pick(["RAHUL KUMAR", "SUNITA NAIR", "ANIL SHARMA", "PRIYA RAO", "VIKRAM MEHTA"], 9)).upper()
reg = date.today() - timedelta(days=365 * (1 + (h >> 11) % 5) + (h >> 13) % 300)
upto = reg + timedelta(days=365 * 15)
alnum = "ABCDEFGHJKLMNPRSTUVWXYZ0123456789"
tail = lambda n, k: "".join(alnum[(h >> (k + 3 * i)) % len(alnum)] for i in range(n))
chassis = "MA3" + tail(14, 2); engine = "K12" + tail(9, 40)
d = lambda x: x.strftime("%d-%m-%Y")

def font(bold, size):
    return ImageFont.truetype(f"/usr/share/fonts/truetype/dejavu/DejaVuSans{'-Bold' if bold else ''}.ttf", size)

im = Image.new("RGB", (1100, 760), "#f3eedc"); g = ImageDraw.Draw(im)
g.rectangle([12, 12, 1087, 747], outline="#2a5d4a", width=4)
g.text((550, 48), "CERTIFICATE OF REGISTRATION", font=font(1, 38), fill="#1c3d31", anchor="mm")
g.text((550, 88), "FORM 23  ·  SAMPLE FOR TESTING, NOT A REAL DOCUMENT", font=font(0, 18), fill="#8a2a2a", anchor="mm")
rows = [("Regn. No.", plate), ("Date of Regn.", d(reg)), ("Regn. Valid Upto", d(upto)), ("Owner Name", owner),
        ("Maker", make), ("Model", model), ("Fuel", fuel), ("Colour", colour), ("Chassis No.", chassis), ("Engine No.", engine)]
y = 135
for k, v in rows:
    g.text((70, y), k, font=font(0, 26), fill="#333")
    g.text((410, y), v, font=font(k == "Regn. No.", 34 if k == "Regn. No." else 28), fill="black")
    y += 58
out = a.out or f"mock-rc-{plate}.png"
im.save(out)
print(out, "|", plate, make, model, fuel, colour, owner)
if a.push:
    subprocess.run(["adb", "push", out, f"/sdcard/Pictures/{out.split('/')[-1]}"], check=True)
    subprocess.run(["adb", "shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d",
                    f"file:///sdcard/Pictures/{out.split('/')[-1]}"], stdout=subprocess.DEVNULL)
