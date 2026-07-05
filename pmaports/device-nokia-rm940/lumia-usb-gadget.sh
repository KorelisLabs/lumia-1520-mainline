#!/bin/sh
# Create (or rebind) the USB gadget (NCM net + ACM serial) - Lumia 1520.
# The pmOS initramfs tears its gadget down on normal boots; nothing else
# recreates it on the systemd image. Logs to /var/log/lumia-gadget.log.
LOG=/var/log/lumia-gadget.log
exec >> "$LOG" 2>&1
say() { echo "$(date +%T) $*"; }
say "start"
G=/sys/kernel/config/usb_gadget/g1
modprobe libcomposite 2>/dev/null
modprobe usb_f_ncm 2>/dev/null
modprobe usb_f_acm 2>/dev/null
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
UDC=""
i=0
while [ $i -lt 30 ]; do
	UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
	[ -n "$UDC" ] && break
	sleep 2
	i=$((i+1))
done
[ -z "$UDC" ] && { say "FAIL: no UDC"; exit 1; }
if [ ! -d "$G" ]; then
	say "creating gadget g1"
	mkdir -p "$G" || exit 1
	echo 0x18d1 > "$G/idVendor"
	echo 0xd001 > "$G/idProduct"
	mkdir -p "$G/strings/0x409"
	echo "Lumia 1520 mainline"       > "$G/strings/0x409/manufacturer"
	echo "Lumia 1520 pmOS" > "$G/strings/0x409/product"
	echo "RM940"           > "$G/strings/0x409/serialnumber"
	mkdir -p "$G/configs/c.1/strings/0x409"
	echo "NCM network + ACM serial" > "$G/configs/c.1/strings/0x409/configuration"
	mkdir -p "$G/functions/ncm.usb0" "$G/functions/acm.GS0"
	ln -s "$G/functions/ncm.usb0" "$G/configs/c.1/" 2>/dev/null
	ln -s "$G/functions/acm.GS0"  "$G/configs/c.1/" 2>/dev/null
fi
grep -q . "$G/UDC" 2>/dev/null || { echo "$UDC" > "$G/UDC" && say "bound to $UDC"; }
say "done"
exit 0
