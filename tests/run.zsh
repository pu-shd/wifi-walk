#!/bin/zsh
# Test suite for wifi-walk.sh. wdutil and sudo are replaced by the stand-ins in
# tests/mocks, fed from tests/fixtures. Exits non-zero unless every test ran
# and passed; a run with zero assertions is a failure.

emulate -R zsh
setopt pipe_fail no_unset

HERE=${0:A:h}
SCRIPT=${HERE:h}/wifi-walk.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wifi-walk-test.XXXXXX")
trap 'rm -rf $TMP' EXIT

integer PASS=0 FAIL=0 TESTS=0
CUR=

# Mock knobs for the next run(); reset after each.
REDACT=0 IP_VERBOSE=0 IP_MODE=
# run SEQ [args...] <<< input   -> sets RC, OUT (stdout+stderr), CSV, IPLOG
run() {
  local seq=$1; shift
  rm -f $TMP/state*(N) $TMP/log.csv
  OUT=$(env -i PATH="$HERE/mocks:/usr/bin:/bin" HOME=$TMP/home TMPDIR=$TMP NO_COLOR=1 \
        WIFI_WALK_WDUTIL=$HERE/mocks/wdutil WIFI_WALK_IPCONFIG=$HERE/mocks/ipconfig \
        MOCK_FIXTURES=$HERE/fixtures MOCK_STATE=$TMP/state MOCK_WDUTIL_SEQ="$seq" \
        MOCK_REDACT=$REDACT MOCK_IPCONFIG_VERBOSE=$IP_VERBOSE MOCK_IPCONFIG_MODE=$IP_MODE \
        zsh $SCRIPT -o $TMP/log.csv -i 0 -B "$@" 2>&1)
  RC=$?
  CSV=$(cat $TMP/log.csv 2>/dev/null || true)
  IPLOG=$(cat $TMP/state.ipconfig 2>/dev/null || true)
  REDACT=0 IP_VERBOSE=0 IP_MODE=
}
setverbose_calls() {  # expected sequence, e.g. "1 0" or ""
  local got=${(j: :)${(M)${(@f)IPLOG}:#setverbose *}#setverbose }
  [[ $got == $1 ]] && ok || fail "setverbose calls '$got', expected '$1'"
}

# count_lines TEXT PATTERN
count_lines() { REPLY=${#${(@M)${(@f)1}:#$~2}} }
lines_eq() {  # PATTERN N: number of output lines matching PATTERN
  count_lines "$OUT" "$1"
  (( REPLY == $2 )) && ok || fail "$REPLY output lines match '$1', expected $2"
}

t() { CUR=$1; (( ++TESTS )); print -r -- "- $1" }
ok()   { (( ++PASS )) }
fail() { (( ++FAIL )); print -r -- "  FAIL [$CUR]: $1"; print -r -- "$OUT" | sed 's/^/    | /' | head -40 }

expect_rc()   { (( RC == $1 )) && ok || fail "exit code $RC, expected $1" }
has()         { [[ $OUT == *"$1"* ]] && ok || fail "output lacks: $1" }
lacks()       { [[ $OUT != *"$1"* ]] && ok || fail "output unexpectedly has: $1" }
csv_has()     { [[ $CSV == *"$1"* ]] && ok || fail "csv lacks: $1"$'\n'"$CSV" }
csv_rows() {  # mode count
  count_lines "$CSV" "*,$1,*"; local n=$REPLY
  (( n == $2 )) && ok || fail "csv has $n '$1' rows, expected $2"$'\n'"$CSV"
}
# csv_col ROW_MATCH COLUMN_NAME EXPECTED: value of a column in the first row
# containing ROW_MATCH (simple split; only for rows without quoted commas)
csv_col() {
  local -a hdr row; local line i
  hdr=(${(s:,:)${${(f)CSV}[1]}})
  for line in ${(f)CSV}; do [[ $line == *"$1"* ]] && break; line=; done
  [[ -n $line ]] || { fail "no csv row matching $1"; return }
  row=("${(@s:,:)line}")
  i=${hdr[(i)$2]}
  [[ ${row[i]:-} == $3 ]] && ok || fail "column $2 is '${row[i]:-}', expected '$3' in: $line"
}

HDR=timestamp,mode,point,sample,location,nearest_ap,connected_ap,bssid,ssid,band_ghz,channel,width_mhz,rssi_dbm,noise_dbm,snr_db,cca_pct,tx_rate_mbps,phy_mode,mcs,nss,security,note

cat > $TMP/map.csv <<'EOF'
# bssid,ap_name
A0-B1-C2-D3-E4-7, AP-07
a0:b1:c2:d3:e5:a , AP-12
not a map line
a0:b1:c2:d3:e4:05,AP-05
EOF

print "wifi-walk tests"

t "syntax"
zsh -n $SCRIPT && ok || fail "zsh -n failed"

t "help and version"
run ap07-good -h; expect_rc 0; has "Usage: wifi-walk.sh"; has "-p MODE"
run ap07-good -V; expect_rc 0; has "wifi-walk.sh 1."

t "option validation"
run ap07-good -p room </dev/null;  expect_rc 1; has "-p must be location, ap or both"
run ap07-good -n 0 </dev/null;     expect_rc 1; has "-n must be a positive integer"
run ap07-good -i abc </dev/null;   expect_rc 1; has "-i must be a number"
run ap07-good -x </dev/null;       expect_rc 1; has "unknown option -x"
run ap07-good extra </dev/null;    expect_rc 1; has "unexpected argument: extra"
run ap07-good -m $TMP/nope </dev/null; expect_rc 1; has "cannot read AP map"

t "location mode: samples, parsing and re-sample on Enter"
run ap07-good <<< $'Room A\n\nq'
expect_rc 0
[[ ${${(f)CSV}[1]} == $HDR ]] && ok || fail "bad header: ${${(f)CSV}[1]}"
csv_rows survey 6
has "[1] Room A"; has "[2] Room A"
has "RSSI -55 dBm (min -55, max -55)  SNR 37 dB  GOOD"
has "connected to a0:b1:c2:d3:e4:71  5 GHz ch 36/80 MHz  864.0 Mbps  11ax"
csv_col ",survey,2,3," location "Room A"
csv_col ",survey,1,1," bssid a0:b1:c2:d3:e4:71
csv_col ",survey,1,1," ssid ExampleNet
csv_col ",survey,1,1," rssi_dbm -55
csv_col ",survey,1,1," noise_dbm -92
csv_col ",survey,1,1," snr_db 37
csv_col ",survey,1,1," cca_pct 12
csv_col ",survey,1,1," band_ghz 5
csv_col ",survey,1,1," channel 36
csv_col ",survey,1,1," width_mhz 80
csv_col ",survey,1,1," mcs 9
csv_col ",survey,1,1," security "WPA2 Enterprise"
has "Summary: 2 stop(s)"

t "Enter before any label does not sample"
run ap07-good <<< $'\nq'
expect_rc 0; has "Type a label first"; csv_rows survey 0

t "ratings: fair, poor, and weakest-first summary"
run "ap07-good ap07-good ap07-good ap07-weak ap07-weak ap12-fair ap12-fair" -n 2 <<< $'Lobby\nBasement\nAttic\nq'
expect_rc 0
has "-78 dBm"; has "POOR"; has "-70 dBm"; has "FAIR"
has "2.4 GHz ch 6/20 MHz"
[[ $OUT == *"Weakest stops:"*"-78 dBm  Basement"*"-70 dBm  Attic"*"-55 dBm  Lobby"* ]] && ok || fail "summary not ordered weakest first"

t "AP mode with map: sticky client is flagged"
run ap07-good -p ap -m $TMP/map.csv <<< $'AP-12\nap-07\nq'
expect_rc 0
has "Loaded 3 AP map entries"; has "skipping line without a comma: not a map line"
has "near AP AP-12"
has "connected to AP-07 (a0:b1:c2:d3:e4:71)"
has "nearest AP is AP-12 but connected to AP-07"
csv_col ",survey,1,1," nearest_ap AP-12
csv_col ",survey,1,1," connected_ap AP-07
csv_col ",survey,1,1," location ""
# second stop matches (case-insensitively): only one sticky warning overall
lines_eq "*nearest AP is*" 1

t "longest-prefix map match and BSSID zero-padding"
run unpadded -m $TMP/map.csv <<< $'Hall\nq'
expect_rc 0
csv_col ",survey,1,1," bssid a0:b1:c2:d3:e4:05
csv_col ",survey,1,1," connected_ap AP-05

t "unmapped BSSID falls back to the address"
run unmapped -m $TMP/map.csv <<< $'Hall\nq'
has "connected to 02:aa:bb:cc:dd:ee  6 GHz ch 37/160 MHz"
csv_col ",survey,1,1," connected_ap ""

t "both mode"
run ap12-good -p both -m $TMP/map.csv <<< $'Room 101\nAP-12\nRoom 102\n\nq'
expect_rc 0
has "[1] Room 101 · near AP AP-12"; has "[2] Room 102"
lacks "nearest AP is"
csv_col ",survey,1,1," location "Room 101"
csv_col ",survey,1,1," nearest_ap AP-12
csv_col ",survey,2,1," nearest_ap ""

t "roam during a stop is reported"
run "ap07-good ap07-good ap12-good ap12-good" -m $TMP/map.csv <<< $'Corridor\nq'
expect_rc 0
has "roamed while sampling: AP-07 (a0:b1:c2:d3:e4:71) -> AP-12 (a0:b1:c2:d3:e5:a1)"
run "ap07-good ap07-good" <<< $'Corridor\nq'
lacks "roamed"

t "watch mode flags roams and honours -c"
run "ap07-good ap07-good ap07-good ap12-good ap12-good" -w -c 4 -m $TMP/map.csv <<< $'q'
expect_rc 0
csv_rows watch 4
has "Watch mode ended (4 samples)."
lines_eq "*ROAM*" 1
has " -52 dBm [############        ]  AP-12 (a0:b1:c2:d3:e5:a1)  ch 149  1200.0 Mbps  ROAM"

t "watch mode from the prompt uses the last location"
run ap07-good -c 2 <<< $'Stairwell\nw\nq'
expect_rc 0
has "Watch mode (Stairwell)"
csv_col ",watch,2,1," location Stairwell

t "notes"
run ap07-good <<< $'#before any stop\nRoom 5\n#dead spot, by the door\nq'
expect_rc 0
has "no stop to attach a note to yet"; has "Noted."
csv_rows note 1
csv_has ',note,1,,Room 5,,,,,,,,,,,,,,,,,"dead spot, by the door"'

t "CSV quoting and formula guard"
run ap07-good -n 1 <<< $'Hall, "East"\n=SUM(A1)\nq'
expect_rc 0
csv_has ',survey,1,1,"Hall, ""East""",'
csv_has ",survey,2,1,'=SUM(A1),"

t "disconnected Wi-Fi: warned, logged, not counted as signal"
run disconnected -n 2 <<< $'Closet\nq'
expect_rc 0
has "Wi-Fi is not connected"; has "connect before starting (or use -b yes)"; lacks "Turn it on"; setverbose_calls ""; has "no signal: not connected to Wi-Fi"
csv_rows survey 2
csv_col ",survey,1,1," rssi_dbm ""
csv_col ",survey,1,1," bssid ""

t "hidden BSSID: one warning, channel-based roams, near-AP heuristic"
run redacted -b no -m $TMP/map.csv <<< $'A\nB\nq'
expect_rc 0
lines_eq "*hiding the BSSID*" 1; has "hiding the BSSID (<redacted>)"
has "the AP map can't be used"
has "connected to AP on ch 36  5 GHz"
csv_col ",survey,1,1," bssid "<redacted>"
csv_col ",survey,1,1," connected_ap ""
run "redacted redacted redacted-ch149 redacted-ch149" -b no -c 3 -w <<< 'q'
lines_eq "*ROAM*" 1
run "redacted redacted redacted-ch149" -b no -p ap <<< $'7\nq'
has "roamed while sampling: AP on ch 36 -> AP on ch 149"
has "only -67 dBm next to AP 7: probably connected to a farther AP, or 7 is down"
run redacted -b no -p ap <<< $'7\nq'
lacks "next to AP"

t "BSSID source: wdutil when visible, ipconfig untouched"
run ap07-good <<< $'A\nq'
expect_rc 0; setverbose_calls ""; lacks "hiding the BSSID"; lacks "Turn it on"

t "BSSID source: ipconfig already verbose"
REDACT=1 IP_VERBOSE=1
run ap07-good -m $TMP/map.csv <<< $'A\nq'
expect_rc 0; setverbose_calls ""; lacks "Turn it on"; lacks "hiding the BSSID"
csv_col ",survey,1,1," bssid a0:b1:c2:d3:e4:71
csv_col ",survey,1,1," ssid ExampleNet
csv_col ",survey,1,1," connected_ap AP-07

t "BSSID source: ipconfig verbose with consent, restored on exit"
REDACT=1
run "ap07-good ap07-good ap12-good" -m $TMP/map.csv -n 2 <<< $'y\nCorridor\nq'
expect_rc 0; setverbose_calls "1 0"
has "Turn it on for this walk? [Y/n]"; has "BSSID visible via ipconfig."; lacks "hiding the BSSID"
has "roamed while sampling: AP-07 (a0:b1:c2:d3:e4:71) -> AP-12 (a0:b1:c2:d3:e5:a1)"
csv_col ",survey,1,2," connected_ap AP-12
REDACT=1
run ap07-good -b yes <<< $'A\nq'
expect_rc 0; setverbose_calls "1 0"; lacks "Turn it on"
csv_col ",survey,1,1," bssid a0:b1:c2:d3:e4:71

t "BSSID source: verbose restored when terminated"
REDACT=1
OUT=$(print q | env -i PATH="$HERE/mocks:/usr/bin:/bin" HOME=$TMP/home NO_COLOR=1 \
      WIFI_WALK_WDUTIL=$HERE/mocks/wdutil WIFI_WALK_IPCONFIG=$HERE/mocks/ipconfig \
      MOCK_FIXTURES=$HERE/fixtures MOCK_STATE=$TMP/state5 MOCK_WDUTIL_SEQ=ap07-good MOCK_REDACT=1 \
      zsh -c "zsh $SCRIPT -o $TMP/kill.csv -b yes -w -i 2 & p=\$!; sleep 1; kill -TERM \$p; wait \$p" 2>&1); RC=$?
IPLOG=$(<$TMP/state5.ipconfig)
expect_rc 130; setverbose_calls "1 0"; has "Summary:"

t "BSSID source: declined, -b no, failed, or stuck -> channel fallback"
REDACT=1
run ap07-good <<< $'n\nA\nq'
expect_rc 0; setverbose_calls ""; has "hiding the BSSID (<redacted>)"; has "connected to AP on ch 36"
REDACT=1
run ap07-good -b no <<< $'A\nq'
expect_rc 0; setverbose_calls ""; lacks "Turn it on"; has "hiding the BSSID"
REDACT=1 IP_MODE=fail-setverbose
run ap07-good -b yes <<< $'A\nq'
expect_rc 0; has "ipconfig setverbose failed"; has "hiding the BSSID"; has "connected to AP on ch 36"
REDACT=1 IP_MODE=stuck
run ap07-good -b yes <<< $'A\nq'
expect_rc 0; setverbose_calls "1 0"; has "ipconfig still hides the BSSID (<redacted>)"; has "hiding the BSSID"
csv_col ",survey,1,1," bssid "<redacted>"

t "BSSID source: ipconfig breaking mid-walk falls back per sample, warns once"
REDACT=1 IP_VERBOSE=1
run ap07-good -b yes <<< $'A\nq'
expect_rc 0; csv_col ",survey,1,1," bssid a0:b1:c2:d3:e4:71
# ipconfig works at startup, then stops revealing the BSSID
REDACT=1 IP_VERBOSE=1 IP_MODE=break-after-1
run ap07-good -b no -n 2 <<< $'A\nB\nq'
expect_rc 0
lines_eq "*ipconfig stopped showing the BSSID*" 1
has "connected to AP on ch 36"
csv_col ",survey,2,2," bssid "<redacted>"

t "BSSID source: -b yes while disconnected enables ipconfig for later"
run "disconnected ap07-good" -b yes -n 1 <<< $'A\nq'
expect_rc 0; setverbose_calls "1 0"
REDACT=1
run "disconnected ap07-good" -b yes -n 1 <<< $'A\nq'
expect_rc 0; csv_col ",survey,1,1," bssid a0:b1:c2:d3:e4:71

t "-b validation"
run ap07-good -b maybe </dev/null; expect_rc 1; has "-b must be ask, yes or no"

t "wdutil failure at startup is fatal"
run FAIL <<< $'q'
expect_rc 1; has "wdutil failed: wdutil: must be run as root"

t "wdutil failure mid-walk is logged, not fatal"
run "ap07-good FAIL" -n 1 <<< $'Room\nq'
expect_rc 0; has "no signal: wdutil: must be run as root"
csv_has "wdutil: must be run as root"

t "appends to an existing log, refuses foreign files"
run ap07-good -n 1 <<< $'One\nq'
cp $TMP/log.csv $TMP/keep.csv
OUT=$(env -i PATH="$HERE/mocks:/usr/bin:/bin" HOME=$TMP/home NO_COLOR=1 WIFI_WALK_WDUTIL=$HERE/mocks/wdutil WIFI_WALK_IPCONFIG=$HERE/mocks/ipconfig \
      MOCK_FIXTURES=$HERE/fixtures MOCK_STATE=$TMP/state2 MOCK_WDUTIL_SEQ=ap07-good \
      zsh $SCRIPT -o $TMP/keep.csv -i 0 -n 1 <<< $'Two\nq' 2>&1); RC=$?
expect_rc 0
CSV=$(<$TMP/keep.csv)
count_lines "$CSV" "timestamp,*"; (( REPLY == 1 )) && ok || fail "header duplicated"
csv_rows survey 2
print "a,b,c" > $TMP/foreign.csv
OUT=$(env -i PATH="$HERE/mocks:/usr/bin:/bin" HOME=$TMP/home WIFI_WALK_WDUTIL=$HERE/mocks/wdutil WIFI_WALK_IPCONFIG=$HERE/mocks/ipconfig \
      MOCK_FIXTURES=$HERE/fixtures MOCK_STATE=$TMP/state3 MOCK_WDUTIL_SEQ=ap07-good \
      zsh $SCRIPT -o $TMP/foreign.csv <<< 'q' 2>&1); RC=$?
expect_rc 1; has "is not a wifi-walk.sh log"

t "default output goes to ~/Desktop when present"
mkdir -p $TMP/home/Desktop
OUT=$(cd $TMP && env -i PATH="$HERE/mocks:/usr/bin:/bin" HOME=$TMP/home WIFI_WALK_WDUTIL=$HERE/mocks/wdutil WIFI_WALK_IPCONFIG=$HERE/mocks/ipconfig \
      MOCK_FIXTURES=$HERE/fixtures MOCK_STATE=$TMP/state4 MOCK_WDUTIL_SEQ=ap07-good \
      zsh $SCRIPT -i 0 -n 1 <<< $'X\nq' 2>&1); RC=$?
expect_rc 0
local -a made=($TMP/home/Desktop/wifi-walk-<->-<->.csv(N))
(( ${#made} == 1 )) && ok || fail "no log created on Desktop"

t "EOF on stdin quits cleanly with a summary"
run ap07-good -n 1 <<< 'Only stop'
expect_rc 0; has "Summary: 1 stop(s)"

print
print -r -- "$TESTS tests, $PASS assertions passed, $FAIL failed"
(( TESTS > 0 && PASS > 0 && FAIL == 0 ))
