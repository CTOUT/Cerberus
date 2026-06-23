# TODO

## Broaden sensor support beyond k10temp

Currently `get_temp()` is hardcoded to the `k10temp` driver, which covers the
AMD Opteron X3000-series APUs found in the HPE ProLiant MicroServer Gen10.
Other platforms use different kernel drivers and `sensors -j` output structures.

**Current query:**
```bash
sensors -j \
  | jq -r 'to_entries[]
           | select(.key | startswith("k10temp"))
           | .value.temp1.temp1_input
           | round'
```

**Known drivers / platforms that would need mapping:**

| Driver | Platform |
|---|---|
| `k10temp` | AMD Opteron X3000-series (Gen10), Ryzen, EPYC |
| `coretemp` | Intel Core / Xeon |
| `zenpower` | AMD Zen — alternative to k10temp on some boards |
| `nct6775` / `nct6779` | Nuvoton Super I/O (common on desktop motherboards) |

The field path within the adapter object also varies — e.g. Intel `coretemp`
exposes per-core inputs (`Core 0`, `Core 1`, …) and a `Package id 0` aggregate,
while k10temp exposes `Tctl`/`Tdie`/`temp1` depending on the generation.

**Suggested approach:**
- Auto-detect the available thermal adapter from `sensors -j` output
- Extract the most appropriate package/die temperature for that adapter
- Fall back gracefully with a clear log message if no supported driver is found
- Make the adapter key and field path overridable via `cerberus.env` for
  platforms not yet covered

**Contributor note:**
This work requires live `sensors -j` output from each target platform to verify
the correct adapter key and field path. If you are running Cerberus on hardware
other than the HPE Gen10, please open an issue with the output of:
```bash
sensors -j 2>/dev/null | jq 'keys'
sensors -j 2>/dev/null | jq 'to_entries[] | {key: .key, fields: (.value | keys)}'
```
