#!/usr/bin/env python3
# Lumia 1520 battery telemetry: self-calibrating VADC readout.
# Voltage is accurate (two-point on-chip calibration). Battery-pack temp is
# estimated from the thermistor with a standard 100k/B3435 NTC curve -- treat
# as approximate until the BV-4BW thermistor spec is confirmed. PMIC die temp
# is exact. Needs no SMBB, so it does not touch the USB PHY.
import glob, os, math
def rd(p):
    try: return open(p).read().strip()
    except: return None
D="/sys/bus/iio/devices/iio:device1"
def raw(ch):
    v=rd(f"{D}/in_voltage{ch}_raw");  return int(v) if v else None
def inp(ch):
    v=rd(f"{D}/in_voltage{ch}_input"); return int(v) if v else None
r625,i625 = raw(9), inp(9)
r1250,i1250 = raw(10), inp(10)
if None in (r625,i625,r1250,i1250):
    print("VADC references not readable -- is the vadc up?"); raise SystemExit
m=(i1250-i625)/(r1250-r625)
to_uv=lambda r: i625 + m*(r-r625)
vbat = to_uv(raw(6))*3/1e6
print(f"Battery voltage : {vbat:.3f} V")
# thermistor: ratiometric against VDD_VADC (ch15), 100k NTC pullup, B=3435
vdd = inp(15) or 1800000
vth = to_uv(raw(48))
try:
    ratio = vth/(vdd-vth)
    r_ntc = 100000*ratio
    t = 1/(1/298.15 + math.log(r_ntc/100000)/3435) - 273.15
    print(f"Battery temp    : {t:.1f} C (approx, 100k/B3435 NTC assumed)")
except Exception:
    print(f"Battery therm   : {vth/1e6:.3f} V (raw)")
die=inp(8)
if die is not None: print(f"PMIC die temp   : {die/1000:.1f} C")
for ps in sorted(glob.glob("/sys/class/power_supply/*")):
    n=os.path.basename(ps); t=rd(f"{ps}/type")
    if t=="Battery":
        print(f"Charger [{n}]    : status={rd(ps+'/status')} present={rd(ps+'/present')} health={rd(ps+'/health')}")
    elif t=="USB":
        print(f"USB input [{n}]  : online={rd(ps+'/online')}")
else:
    if not glob.glob("/sys/class/power_supply/smbb*"):
        print("Charge status   : (SMBB disabled -- charge/present/health not available)")
