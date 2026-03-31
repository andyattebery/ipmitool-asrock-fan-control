#!/usr/bin/env bash

FAN='0x3a'

FAN_SET_MODE='0xd8'
FAN_GET_MODE='0xd9'
FAN_MODE_AUTO_VALUE='0x00'
FAN_MODE_MANUAL_VALUE='0x01'
FAN_MODE_CUSTOM_VALUE='0x02'

FAN_SET_DUTY_PERCENTAGE='0xd6'
FAN_GET_SAVED_DUTY_PERCENTAGE='0xd7'
FAN_GET_CURRENT_DUTY_PERCENTAGE='0xda'

FAN_NA_VALUE='1e'

get_rpm() {
  impitool_sensor_fan_output=$(ipmitool sensor | grep FAN)
  echo "$impitool_sensor_fan_output" | column --table --separator '|' --table-columns 'FAN,RPM' --table-hide '-'
}

get_current_duty_percentage() {
  results=$(ipmitool raw $FAN $FAN_GET_CURRENT_DUTY_PERCENTAGE)

  # echo $results
  display_raw_fan_data "$results" "DUTY %"
}

get_saved_duty_percentage() {
  results=$(ipmitool raw $FAN $FAN_GET_SAVED_DUTY_PERCENTAGE)

  # echo $results
  display_raw_fan_data "$results" "DUTY %"
}

set_duty_percentage() {
  local fan_index=$1
  local duty_percentage=$2

  if [ -z "$fan_index" ] || [ -z "$duty_percentage" ]; then
    echo "Usage: set_duty <fan_index 1-16> <duty_percentage 0-100>"
    return 1
  fi

  if [ "$fan_index" -lt 1 ] || [ "$fan_index" -gt 16 ] 2>/dev/null; then
    echo "Error: fan_index must be between 1 and 16"
    return 1
  fi

  if [ "$duty_percentage" -lt 0 ] || [ "$duty_percentage" -gt 100 ] 2>/dev/null; then
    echo "Error: duty_percentage must be between 0 and 100"
    return 1
  fi

  local arr_index=$(( fan_index - 1 ))

  # Read current fan modes and set target fan to manual
  local current_modes=$(ipmitool raw $FAN $FAN_GET_MODE)
  IFS=' ' read -ra modes <<< "$current_modes"
  modes[$arr_index]="01"
  local mode_args=""
  for m in "${modes[@]}"; do
    mode_args+="0x$m "
  done
  ipmitool raw $FAN $FAN_SET_MODE $mode_args

  # Read current duty values and set target fan's duty
  local current_duty=$(ipmitool raw $FAN $FAN_GET_CURRENT_DUTY_PERCENTAGE)
  IFS=' ' read -ra duties <<< "$current_duty"
  duties[$arr_index]=$(printf '%02x' "$duty_percentage")
  local duty_args=""
  for d in "${duties[@]}"; do
    duty_args+="0x$d "
  done
  ipmitool raw $FAN $FAN_SET_DUTY_PERCENTAGE $duty_args
}

display_raw_fan_data() {
  IFS=' ' read -ra RESULTS <<< "$1"
  for i in "${!RESULTS[@]}"; do
    value="${RESULTS[$i]}"

    output+="FAN$(($i + 1))"
    # echo -n -e "$(($i + 1))\t"
    if [ $value == $FAN_NA_VALUE ]; then
      # printf "N/A\n"
      printf -v output '%b N/A\n' "$output"
    else
      # printf "%d\n" "0x$value"
      printf -v output '%b %d\n' "$output" "0x$value"
    fi
  done

  echo -e "$output" | column --table --table-columns "FAN,${2:-VALUE}"
}

help() {
    cat << "HELP_TXT"
ipmitool-asrock-fan-control <action>

Supported Actions:
- show_rpm
- show_current_duty
- show_saved_duty
- set_duty <fan_index> <duty_percentage>
    fan_index: 1-16 (1 = FAN1)
    duty_percentage: 0-100
    Automatically switches the target fan to manual mode.

HELP_TXT
}

# https://stackoverflow.com/questions/13280131/hexadecimal-to-decimal-in-shell-script

# readarray -t RESULT <<< "$results"

case "$1" in
    show_rpm ) get_rpm;;
    show_current_duty ) get_current_duty_percentage;;
    show_saved_duty ) get_saved_duty_percentage;;
    set_duty ) set_duty_percentage "$2" "$3";;
    * ) help;;
esac
