# wifi-walk

An interactive Wi-Fi walk test for macOS. Walk through a building and stop
wherever you want a reading: a room, a corridor, or right under an access
point. Type a label, and wifi-walk takes a few samples of what your Mac sees
and appends them to a CSV file.

```
Location: Room 210
[1] Room 210  sampling...
    RSSI -71 dBm (min -73, max -70)  SNR 21 dB  FAIR
    connected to AP-07 (a0:b1:c2:d3:e4:71)  5 GHz ch 36/80 MHz  144.0 Mbps  11ax

Location [Room 210]: Stairwell east
[2] Stairwell east  sampling...
    RSSI -80 dBm (min -82, max -78)  SNR 11 dB  POOR
    connected to AP-03 (a0:b1:c2:d3:e6:31)  2.4 GHz ch 6/20 MHz  26.0 Mbps  11ax
    ! roamed while sampling: AP-07 (a0:b1:c2:d3:e4:71) -> AP-03 (a0:b1:c2:d3:e6:31)
```

Requires macOS (it uses `wdutil`, which needs `sudo`) and zsh, the default
shell. There's nothing to install.

```sh
curl -O https://raw.githubusercontent.com/pu-shd/wifi-walk/main/wifi-walk.sh
chmod +x wifi-walk.sh
./wifi-walk.sh
```

## Labelling stops: location or AP

`-p` sets what wifi-walk asks for at each stop:

| `-p`       | You type                                      | Good for                                    |
|------------|-----------------------------------------------|---------------------------------------------|
| `location` | a place: `Room 210`, `3F east stairwell`      | finding dead zones (default)                |
| `ap`       | the AP you're standing nearest to, e.g. its label number | checking each AP's coverage and roaming |
| `both`     | a place, then the nearest AP (Enter to skip)  | both                                        |

Labelling by AP is worth doing when the APs are numbered on site. Every AP is a
fixed, known point, so a walk from AP to AP gives repeatable readings that
anyone can retake later without a floor plan. It also tells you whether your
Mac is using the AP you're standing next to:

- **With an AP map** (`-m`, below) and a visible BSSID, wifi-walk names the AP
  you're connected to and warns if it isn't the one you're standing at. That
  usually means a sticky client or an AP that's down.
- **Without one,** it warns when the signal is weaker than -60 dBm while you're
  standing next to an AP. At that distance, the AP serving you should be much
  stronger, so you're probably on a farther AP.

## Commands at the prompt

| Input     | Action                                                   |
|-----------|----------------------------------------------------------|
| *label*   | sample a new stop                                        |
| Enter     | sample the previous stop again                           |
| `#text`   | attach a note to the previous stop (`#dead spot by door`) |
| `w`       | watch mode: one line per sample, flags roams; any key returns |
| `?`       | help                                                     |
| `q`       | quit and print the weakest stops                         |

Watch mode is handy while you walk between stops. It shows when, and where,
your Mac roams. To start in watch mode, use `-w`.

## Options

```
-o FILE   CSV output (default ~/Desktop/wifi-walk-YYYYmmdd-HHMMSS.csv; appends)
-p MODE   location | ap | both
-m FILE   AP map (bssid,ap_name per line)
-n N      samples per stop (default 3)
-i SEC    seconds between samples (default 1)
-w        start in watch mode
-c N      stop watch mode after N samples
-B        no bell on poor signal
```

Signal ratings: good is -67 dBm or better (the usual target for voice and
video), fair is down to -75 dBm, and poor is anything weaker. When you're on a
poor stop, the terminal bell rings so you notice without looking at the screen.

## AP map

The map only works where macOS shows the BSSID, which current versions don't
(see the next section). It's kept for older macOS versions and in case Apple
relaxes the restriction.

The map is a CSV file of BSSID-to-name pairs. A BSSID prefix matches every
radio and SSID on that AP, so you need only one line per AP. See
[`examples/ap-map.csv`](examples/ap-map.csv).

```
a0:b1:c2:d3:e4:7, AP-07
a0:b1:c2:d3:e5:a, AP-12
```

Get the BSSIDs from your wireless controller. If macOS shows them, you can
also take them from the `bssid` column of an earlier walk.

## macOS hides the BSSID

Since about macOS 14.5, `wdutil` prints `<redacted>` in place of the SSID and
BSSID, even under `sudo`. This has been confirmed on macOS 26 (Tahoe). Apple
treats these values as location data. When they're hidden, wifi-walk tells you
at startup and falls back as follows:

- It treats a channel change as a roam, since neighbouring APs are normally on
  different channels.
- In `-p ap` mode, it uses the weak-signal check described above.
- Everything else (RSSI, noise, SNR, channel utilisation, rate, PHY mode,
  MCS) is recorded as usual.

## Output

One CSV row per sample:

```
timestamp,mode,point,sample,location,nearest_ap,connected_ap,bssid,ssid,band_ghz,
channel,width_mhz,rssi_dbm,noise_dbm,snr_db,cca_pct,tx_rate_mbps,phy_mode,mcs,nss,
security,note
```

- `mode` is `survey` (a stop), `watch`, or `note`.
- `point` groups the samples taken at one stop.
- If `wdutil` fails partway through a walk, the row is still written, and
  `note` holds the error.

Free-text cells are quoted and protected against spreadsheet formula
injection. Running again with the same `-o` file appends to it.

## Tests

`wdutil` and `sudo` are mocked (`tests/mocks`) and fed from captured-format
fixtures (`tests/fixtures`), so the suite runs anywhere zsh does:

```sh
zsh tests/run.zsh                    # natively (macOS or Linux)
docker-compose run --rm --build test # in a container
```

CI runs both, on macOS and Linux.

## License

MIT
