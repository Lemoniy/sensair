# Sensair

Bedroom air quality sensor for Home Assistant, built on ESPHome and an ESP32-C3:
CO2 (SCD41), temperature and humidity (SHT41), VOC/NOx index (SGP41) and an OLED display.

## Installation

- **Browser:** open the [Sensair installer](https://lemoniy.github.io/sensair/) in Chrome or Edge,
  connect the ESP32-C3 via USB and click "Install".
- **Windows without Chrome/Edge:** download `sensair-installer-windows.zip` from the
  [latest release](https://github.com/Lemoniy/sensair/releases/latest), unzip it and
  double-click `Install-Sensair.cmd`.

Both install the firmware and set up the WiFi. Home Assistant then discovers the device.

## Files

| File | Purpose |
|---|---|
| `sensair.yaml` | Release firmware, contains no secrets |
| `sensair-dev.yaml` | Local development build with your own `secrets.yaml` |
| `sensair-test.yaml` | Connectivity test without sensors |
| `sensair-automation.yaml` | Example Home Assistant automations |
| `static/` | Browser installer page |
| `installer/windows/` | Windows command-line installer |

## License

Sensair is free for non-commercial use:

- Firmware, scripts and other code: [PolyForm Noncommercial 1.0.0](LICENSE.md)
- Documentation, images and hardware design files: [CC BY-NC-SA 4.0](LICENSE-CC-BY-NC-SA-4.0.txt)

Commercial use, including selling devices built from this project, requires a separate license.
Please get in touch via [GitHub](https://github.com/Lemoniy).
