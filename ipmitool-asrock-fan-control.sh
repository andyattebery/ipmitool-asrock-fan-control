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
  fan_index=$1
  duty_percentage=$2

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

HELP_TXT
}

# https://stackoverflow.com/questions/13280131/hexadecimal-to-decimal-in-shell-script

# readarray -t RESULT <<< "$results"

case "$1" in
    show_rpm ) get_rpm;;
    show_current_duty ) get_current_duty_percentage;;
    show_saved_duty ) get_saved_duty_percentage;;
    * ) help;;
esac
