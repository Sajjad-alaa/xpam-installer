# Network device account tests

`netdev_emulator.py` is an SSH command-line emulator of FortiGate, PAN-OS, Cisco IOS/ASA/NX-OS, Junos,
Huawei VRP and H3C Comware with a real local-user database (one port per vendor, 2201-2208; the admin
account is `admin` with the password in `EMU_PASSWORD`). It is a test tool only: real devices may
answer differently, so a new vendor or OS version should also be checked on a real device.

- `drivers_test.py`: the vendor drivers (`apps/libs/ansible/modules_utils/network_device.py`) for every
  operation; run it in a container of the core image with the driver copied to `/work`.
- `e2e.py`: XPAM's real automations (push, discovery, change secret, remove) and just-in-time accounts,
  in a core container connected to a throwaway database (never the live one).

```bash
docker network create xpam-nettest
docker run -d --name netemu --network xpam-nettest -e EMU_PASSWORD=<random> \
  -v $PWD/netdev_emulator.py:/emu.py:ro --entrypoint /opt/py3/bin/python xpam/core:<version> -u /emu.py
```
