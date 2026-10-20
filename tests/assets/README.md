# Asset tests

- `tools_test.py`: Add many (licence limit, account), Detect platform (emulator Cisco/FortiGate, second
  organization, malformed ids) and Needs attention. Needs the device emulator as `netemu` (env `EMU_PASSWORD`).
- `forms_test.py`: web asset address/port/selectors and the JIT readiness check.

Run them in a core container connected to a throwaway database (never the live one).
