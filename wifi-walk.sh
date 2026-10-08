#!/bin/zsh
# wifi-walk: interactive Wi-Fi walk test for macOS.
#
# Walk a building, stop somewhere (a room, a corridor, under an AP), type a
# label, and wifi-walk takes a few samples of what your Mac sees: signal,
# noise, SNR, channel, rate, and which AP (BSSID) it is actually connected to.
# Every sample is appended to a CSV file for later analysis.

emulate -R zsh
setopt pipe_fail no_unset extended_glob
zmodload zsh/datetime

readonly VERSION=1.0.0
readonly PROG=${0:t}

# RSSI thresholds (dBm). -67 is the usual floor for voice/video; -75 is
# roughly where data starts to suffer.
readonly GOOD=-67 FAIR=-75
# Standing next to the AP you're connected to should beat this comfortably.
readonly NEAR_AP_RSSI=-60

readonly CSV_HEADER=timestamp,mode,point,sample,location,nearest_ap,connected_ap,bssid,ssid,band_ghz,channel,width_mhz,rssi_dbm,noise_dbm,snr_db,cca_pct,tx_rate_mbps,phy_mode,mcs,nss,security,note

WDUTIL=${WIFI_WALK_WDUTIL:-/usr/bin/wdutil}
OUT=
PROMPT_MODE=location
MAP_FILE=
SAMPLES=3
INTERVAL=1
START_WATCH=0
COUNT=0
BELL=1

typeset -gA W S AP_MAP
typeset -ga SUDO P_LABEL P_RSSI
POINT=0
LAST_LOC=
LAST_NEAR=
KEEPALIVE=

usage() {
  cat <<EOF
Usage: $PROG [options]

Interactive Wi-Fi walk test for macOS. At each stop, type a label and press
Enter; $PROG takes several samples and appends them to a CSV file.

Options:
  -o FILE   CSV output (default: ~/Desktop/wifi-walk-YYYYmmdd-HHMMSS.csv);
            appended to if it already exists
  -p MODE   what to ask at each stop (default: location)
              location  a place, e.g. "3rd floor, east stairwell"
              ap        the AP you are standing nearest to (e.g. the number on
                        its label); flagged if you seem to be connected to a
                        different AP (by name with -m, else by weak signal)
              both      ask for both
  -m FILE   AP map, one "bssid,ap_name" per line, used to name the AP you are
            connected to. A prefix such as "a0:b1:c2:d3:e4:" matches every
            radio/SSID on that AP. Lines starting with # are ignored.
            Needs a visible BSSID, which recent macOS may hide.
  -n N      samples per stop (default: $SAMPLES)
  -i SEC    seconds between samples (default: $INTERVAL)
  -w        start in watch mode
  -c N      in watch mode, stop after N samples (default: until a key press)
  -B        no terminal bell on poor signal
  -h        show this help
  -V        show version

At the prompt:
  <label>   sample a new stop
  Enter     sample the previous stop again
  #<text>   attach a note to the previous stop
  w         watch mode: sample continuously and flag roams; any key returns
  ?         this help
  q         quit and print a summary

Signal: RSSI >= $GOOD dBm good, >= $FAIR dBm fair, otherwise poor.
EOF
}

die()  { print -ru2 -- "$PROG: $*"; exit 1 }
warn() { print -ru2 -- "$PROG: warning: $*" }

# Colours only on a terminal, and never when NO_COLOR is set.
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_GOOD=$'\e[32m' C_FAIR=$'\e[33m' C_POOR=$'\e[31m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_GOOD= C_FAIR= C_POOR= C_DIM= C_BOLD= C_OFF=
fi

now() { strftime -s REPLY '%Y-%m-%dT%H:%M:%S%z' $EPOCHSECONDS }

trim() { REPLY=${${1##[[:space:]]#}%%[[:space:]]#} }

# Lowercase, ":"-separated, zero-padded. Anything that isn't a MAC address
# (e.g. "<redacted>", "None") is returned unchanged.
norm_bssid() {
  local b=${(L)1//-/:}
  local -a o=(${(s.:.)b})
  if (( ${#o} == 6 )) && [[ ${(j::)o} == [0-9a-f]## ]]; then
    REPLY=${(j.:.)${(l:2::0:)o}}
  else
    REPLY=$1
  fi
}

# One CSV field in REPLY. Free-text fields are guarded against spreadsheet
# formula injection.
csv_field() {
  local v=$1 text=${2:-0}
  if (( text )) && [[ $v == [=+@]* ]]; then v="'$v"; fi
  if [[ $v == *[,\"$'\n'$'\r']* ]]; then v="\"${v//\"/\"\"}\""; fi
  REPLY=$v
}

csv_row() {
  local -a out
  local i=0 f
  # 1-based positions of free-text columns: location, nearest_ap, note
  for f in "$@"; do
    (( ++i ))
    csv_field "$f" $(( i == 5 || i == 6 || i == 22 ))
    out+=("$REPLY")
  done
  print -r -- "${(j:,:)out}" >> $OUT
}

load_map() {
  local line b name n=0
  [[ -r $MAP_FILE ]] || die "cannot read AP map: $MAP_FILE"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line == [[:space:]]#(\#*|) ]] && continue
    if [[ $line != *,* ]]; then warn "AP map: skipping line without a comma: $line"; continue; fi
    trim "${line%%,*}"; b=${(L)REPLY//-/:}
    trim "${line#*,}";  name=$REPLY
    if [[ -z $b || -z $name ]]; then warn "AP map: skipping incomplete line: $line"; continue; fi
    AP_MAP[$b]=$name
    (( ++n ))
  done < $MAP_FILE
  (( n )) || die "AP map has no usable entries: $MAP_FILE"
  print -r -- "Loaded $n AP map entr$( (( n == 1 )) && print y || print ies) from $MAP_FILE"
}

# Longest-prefix match of a BSSID against the AP map.
ap_name() {
  local b=$1 k best=
  REPLY=
  for k in ${(k)AP_MAP}; do
    [[ $b == ${k}* && ${#k} -gt ${#best} ]] && best=$k
  done
  [[ -n $best ]] && REPLY=${AP_MAP[$best]}
  return 0
}

# Run wdutil and parse the WIFI section into W. Returns 1 if wdutil failed.
read_wifi() {
  W=()
  local out line in_wifi=0
  if ! out=$("${SUDO[@]}" "$WDUTIL" info 2>&1); then
    W[error]=${${out%%$'\n'*}:-wdutil exited with an error}
    return 1
  fi
  for line in "${(@f)out}"; do
    if [[ $line == WIFI[[:space:]]# ]]; then in_wifi=1; continue; fi
    (( in_wifi )) || continue
    [[ $line == [A-Z]* ]] && break        # next section header
    if [[ $line =~ '^[[:space:]]+([^:]*[^:[:space:]])[[:space:]]*:[[:space:]]*(.*)$' ]]; then
      [[ -n ${W[${match[1]}]:-} ]] || W[${match[1]}]=${match[2]}
    fi
  done
  (( ${#W} )) || W[error]="no WIFI section in wdutil output"
  return 0
}

# Take one sample, fill S, and log it.
sample() {
  local mode=$1 point=$2 n=$3 loc=$4 near=$5
  S=()
  now; S[ts]=$REPLY
  read_wifi
  if [[ -n ${W[error]:-} ]]; then
    S[error]=${W[error]}
  else
    local v
    v=${W[RSSI]:-};  v=${v%% *}; [[ $v == -<1-> ]] && S[rssi]=$v
    v=${W[Noise]:-}; v=${v%% *}; [[ $v == -<1-> ]] && S[noise]=$v
    v=${W[CCA]:-};   v=${v%% *}; [[ $v == <-> ]] && S[cca]=$v
    v=${W[Tx Rate]:-}; v=${v%% *}; [[ $v == [0-9.]## ]] && S[rate]=$v
    S[ssid]=${${W[SSID]:-}:#None}
    S[phy]=${W[PHY Mode]:-}
    S[mcs]=${W[MCS Index]:-}
    S[nss]=${W[NSS]:-}
    S[security]=${W[Security]:-}
    norm_bssid "${W[BSSID]:-}"; S[bssid]=$REPLY
    [[ ${S[bssid]} == None ]] && S[bssid]=
    if [[ -n ${S[rssi]:-} && -n ${S[noise]:-} ]]; then
      S[snr]=$(( S[rssi] - S[noise] ))
    fi
    # wdutil reports channels like "5g36/80": band, channel, width
    v=${W[Channel]:-}
    if [[ $v =~ '^([0-9])g([0-9]+)/([0-9]+)' ]]; then
      S[band]=${match[1]/2/2.4} S[channel]=${match[2]} S[width]=${match[3]}
    else
      S[channel]=$v
    fi
    # S[apkey] identifies the serving AP for roam detection: the BSSID, or,
    # when macOS hides it, the channel (a change of channel means a new AP).
    if [[ ${S[bssid]} == *:*:*:*:*:* ]]; then
      ap_name "${S[bssid]}"; S[ap]=$REPLY S[apkey]=${S[bssid]}
    else
      [[ -n ${S[rssi]:-} ]] && S[apkey]="ch ${S[channel]:-?}"
    fi
  fi
  csv_row "${S[ts]}" $mode $point $n "$loc" "$near" "${S[ap]:-}" "${S[bssid]:-}" \
    "${S[ssid]:-}" "${S[band]:-}" "${S[channel]:-}" "${S[width]:-}" "${S[rssi]:-}" \
    "${S[noise]:-}" "${S[snr]:-}" "${S[cca]:-}" "${S[rate]:-}" "${S[phy]:-}" \
    "${S[mcs]:-}" "${S[nss]:-}" "${S[security]:-}" "${S[error]:-}"
}

# Sets REPLY to good/fair/poor and RATING_COLOR.
rate_rssi() {
  if   (( $1 >= GOOD )); then REPLY=good RATING_COLOR=$C_GOOD
  elif (( $1 >= FAIR )); then REPLY=fair RATING_COLOR=$C_FAIR
  else                        REPLY=poor RATING_COLOR=$C_POOR
  fi
}

# Human name for the connected AP: map name, else BSSID, else its channel.
ap_label() {
  if [[ ${S[apkey]:-} == ch\ * ]]; then
    REPLY="AP on ${S[apkey]}"
  else
    REPLY=${S[ap]:-${S[bssid]:-unknown AP}}
    [[ -n ${S[ap]:-} ]] && REPLY+=" ${C_DIM}(${S[bssid]})${C_OFF}"
  fi
  return 0
}

bssid_hidden() { [[ -n ${S[rssi]:-} && ${S[apkey]:-} == ch\ * ]] }

survey_point() {
  local loc=$1 near=$2 i sum=0 ok=0 min=0 max=-200 avg snr_sum=0 roams= key=
  (( ++POINT ))
  local title=${loc:-}
  [[ -n $near ]] && title+="${title:+ · }near AP $near"
  print -rn -- "${C_BOLD}[$POINT] $title${C_OFF}  sampling"
  for (( i = 1; i <= SAMPLES; i++ )); do
    (( i > 1 )) && sleep $INTERVAL
    sample survey $POINT $i "$loc" "$near"
    print -n .
    [[ -n ${S[rssi]:-} ]] || continue
    (( ++ok, sum += S[rssi], snr_sum += ${S[snr]:-0} ))
    (( S[rssi] < min )) && min=${S[rssi]}
    (( S[rssi] > max )) && max=${S[rssi]}
    if [[ ${S[apkey]} != $key ]]; then
      ap_label
      roams+="${key:+ -> }$REPLY"
      key=${S[apkey]}
    fi
  done
  print

  if (( ! ok )); then
    print -r -- "    ${C_POOR}no signal: ${S[error]:-not connected to Wi-Fi}${C_OFF}"
    P_LABEL+=("$title") P_RSSI+=(-100)
    (( BELL )) && [[ -t 1 ]] && print -n $'\a'
    return
  fi

  printf -v avg '%.0f' $(( 1.0 * sum / ok ))
  rate_rssi $avg
  local rating=$REPLY color=$RATING_COLOR
  print -r -- "    RSSI ${color}${avg} dBm${C_OFF} ${C_DIM}(min $min, max $max)${C_OFF}  SNR $(( snr_sum / ok )) dB  ${color}${(U)rating}${C_OFF}"
  local chan=${S[channel]:-?}
  [[ -n ${S[band]:-} ]] && chan="${S[band]} GHz ch ${S[channel]}/${S[width]} MHz"
  ap_label
  print -r -- "    connected to $REPLY  $chan  ${S[rate]:-?} Mbps  ${S[phy]:-}"
  [[ $roams == *' -> '* ]] && print -r -- "    ${C_FAIR}! roamed while sampling: $roams${C_OFF}"
  if [[ -n $near && -n ${S[ap]:-} ]]; then
    [[ ${(L)near} == ${(L)S[ap]} ]] ||
      print -r -- "    ${C_FAIR}! nearest AP is $near but connected to ${S[ap]} (sticky client, or $near is down?)${C_OFF}"
  elif [[ -n $near ]] && (( avg < NEAR_AP_RSSI )); then
    # Without a named serving AP, signal strength is the tell: standing
    # next to the AP you are connected to should read well above this.
    print -r -- "    ${C_FAIR}! only $avg dBm next to AP $near: probably connected to a farther AP, or $near is down${C_OFF}"
  fi
  P_LABEL+=("$title") P_RSSI+=($avg)
  [[ $rating == poor ]] && (( BELL )) && [[ -t 1 ]] && print -n $'\a'
  return 0
}

watch_mode() {
  local n=0 prev= key bar len rating pad=
  (( ++POINT ))
  print -r -- "Watch mode${LAST_LOC:+ ($LAST_LOC)}: sampling every ${INTERVAL}s. Press any key to stop."
  while :; do
    (( ++n ))
    sample watch $POINT $n "$LAST_LOC" ""
    now; local t=${REPLY[12,19]}
    if [[ -z ${S[rssi]:-} ]]; then
      print -r -- "$t  ${C_POOR}no signal: ${S[error]:-not connected}${C_OFF}"
    else
      rate_rssi ${S[rssi]}
      # bar: -90 dBm = empty, -30 dBm = 20 blocks
      len=$(( (S[rssi] + 90) / 3 )); (( len < 0 )) && len=0; (( len > 20 )) && len=20
      bar=${(l:len::#:)pad}${(l:20-len:: :)pad}
      ap_label
      local line="$t  ${RATING_COLOR}${(l:4:)S[rssi]} dBm [$bar]${C_OFF}  $REPLY  ch ${S[channel]:-?}  ${S[rate]:-?} Mbps"
      [[ -n $prev && ${S[apkey]} != $prev ]] && line+="  ${C_FAIR}${C_BOLD}ROAM${C_OFF}"
      prev=${S[apkey]}
      print -r -- "$line"
    fi
    (( COUNT && n >= COUNT )) && break
    if [[ -t 0 ]]; then
      read -s -t $INTERVAL -k 1 key && break
    else
      sleep $INTERVAL
    fi
  done
  print -r -- "Watch mode ended ($n samples)."
}

summary() {
  print
  print -r -- "${C_BOLD}Summary${C_OFF}: $POINT stop(s), log: $OUT"
  (( ${#P_RSSI} )) || return 0
  local -a rows
  local i r
  for (( i = 1; i <= ${#P_RSSI}; i++ )); do
    rows+=("$(printf '%03d' $(( -P_RSSI[i] )))"$'\t'"${P_LABEL[i]}")
  done
  print -r -- "Weakest stops:"
  for r in ${${(O)rows}[1,5]}; do
    rate_rssi -${r%%$'\t'*}
    print -r -- "  ${RATING_COLOR}$(( -${r%%$'\t'*} )) dBm${C_OFF}  ${r#*$'\t'}"
  done
}

cleanup() { [[ -n $KEEPALIVE ]] && kill $KEEPALIVE 2>/dev/null; KEEPALIVE= }

ask() {  # prompt varname -> 1 on EOF
  print -rn -- "$1"
  IFS= read -r $2 || { print; return 1 }
}

main() {
  local opt
  while getopts ':o:p:m:n:i:c:wBhV' opt; do
    case $opt in
      o) OUT=$OPTARG ;;
      p) PROMPT_MODE=$OPTARG ;;
      m) MAP_FILE=$OPTARG ;;
      n) SAMPLES=$OPTARG ;;
      i) INTERVAL=$OPTARG ;;
      c) COUNT=$OPTARG ;;
      w) START_WATCH=1 ;;
      B) BELL=0 ;;
      h) usage; exit 0 ;;
      V) print -r -- "$PROG $VERSION"; exit 0 ;;
      :) die "-$OPTARG needs a value (see -h)" ;;
      *) die "unknown option -$OPTARG (see -h)" ;;
    esac
  done
  (( OPTIND > $# )) || die "unexpected argument: ${@[OPTIND]} (see -h)"
  [[ $PROMPT_MODE == (location|ap|both) ]] || die "-p must be location, ap or both"
  [[ $SAMPLES == <1-> ]] || die "-n must be a positive integer"
  [[ $COUNT == <-> ]] || die "-c must be a non-negative integer"
  [[ $INTERVAL == ([0-9]##(.[0-9]#|)|.[0-9]##) ]] || die "-i must be a number of seconds"

  [[ $OSTYPE == darwin* || -n ${WIFI_WALK_WDUTIL:-} ]] || die "macOS only (needs wdutil)"
  [[ -x $WDUTIL ]] || die "wdutil not found at $WDUTIL"

  if [[ -z $OUT ]]; then
    local stamp dir=$PWD
    strftime -s stamp '%Y%m%d-%H%M%S' $EPOCHSECONDS
    [[ -d $HOME/Desktop ]] && dir=$HOME/Desktop
    OUT=$dir/wifi-walk-$stamp.csv
  fi
  if [[ ! -s $OUT ]]; then
    print -r -- $CSV_HEADER >> $OUT || die "cannot write $OUT"
  elif [[ $(head -n 1 -- $OUT) != $CSV_HEADER ]]; then
    die "$OUT exists but is not a $PROG log; choose another file with -o"
  fi

  [[ -n $MAP_FILE ]] && load_map

  trap cleanup EXIT
  trap 'cleanup; summary; exit 130' INT TERM

  if (( EUID != 0 )); then
    print "wdutil needs administrator rights; sudo may ask for your password."
    sudo -v || die "sudo failed"
    SUDO=(sudo -n)
    # keep the sudo timestamp fresh until we exit
    { while sleep 50; do kill -0 $$ 2>/dev/null && sudo -n -v 2>/dev/null || exit; done } </dev/null >/dev/null 2>&1 &!
    KEEPALIVE=$!
  fi

  # Fail now, not at the first stop, if wdutil doesn't work.
  read_wifi || die "wdutil failed: ${W[error]}"
  [[ -z ${W[error]:-} ]] || die "could not read Wi-Fi state: ${W[error]}"
  if [[ ${W[RSSI]:-0 dBm} == 0* ]]; then
    warn "Wi-Fi is not connected; samples will be empty until it is"
  else
    norm_bssid "${W[BSSID]:-}"
    [[ $REPLY == *:*:*:*:*:* ]] ||
      warn "macOS is hiding the BSSID (${W[BSSID]:-blank}); roams will be inferred from channel changes${MAP_FILE:+ and the AP map can't be used}"
  fi

  print -r -- "Logging to $OUT"
  print -r -- "Type a label and press Enter at each stop; ? for help, q to quit."
  (( START_WATCH )) && watch_mode

  local in near
  while :; do
    print
    case $PROMPT_MODE in
      ap) ask "Nearest AP${LAST_NEAR:+ [$LAST_NEAR]}: " in || break ;;
      *)  ask "Location${LAST_LOC:+ [$LAST_LOC]}: " in || break ;;
    esac
    trim "$in"; in=$REPLY
    case $in in
      q|Q|quit|exit) break ;;
      \?|help) usage; continue ;;
      w|W) watch_mode; continue ;;
      \#*)
        if (( ! POINT )); then warn "no stop to attach a note to yet"; continue; fi
        trim "${in#\#}"; local note=$REPLY
        now; csv_row "$REPLY" note $POINT "" "$LAST_LOC" "$LAST_NEAR" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "$note"
        print -r -- "Noted."
        continue ;;
      '')
        if [[ -z $LAST_LOC && -z $LAST_NEAR ]]; then print "Type a label first (or q to quit)."; continue; fi
        survey_point "$LAST_LOC" "$LAST_NEAR"; continue ;;
    esac
    case $PROMPT_MODE in
      location) LAST_LOC=$in LAST_NEAR= ;;
      ap)       LAST_NEAR=$in LAST_LOC= ;;
      both)
        LAST_LOC=$in
        ask "Nearest AP (Enter to skip): " near || break
        trim "$near"; LAST_NEAR=$REPLY ;;
    esac
    survey_point "$LAST_LOC" "$LAST_NEAR"
  done

  cleanup
  summary
}

main "$@"
