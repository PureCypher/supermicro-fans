#!/bin/bash
################################################################################
# Supermicro IPMI Fan Control Script
#
# This script monitors CPU temperatures and adjusts fan speeds accordingly
# to maintain optimal cooling while minimizing noise.
#
# Hardware: Supermicro server with IPMI support
# Requirements: ipmitool
################################################################################

set -euo pipefail

# Require bash 4.3+ for associative array namerefs (local -n)
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "ERROR: bash 4.3 or later required (found ${BASH_VERSION})" >&2
    exit 1
fi

################################################################################
# CONFIGURATION
################################################################################

# Logging
LOG_FILE="/var/log/fan-control.log"
MAX_LOG_SIZE=10485760  # 10MB in bytes

# Temperature sensor to monitor (we'll use the maximum of CPU1 and CPU2)
PRIMARY_SENSORS=("CPU1 Temp" "CPU2 Temp")

# Fan zones to control
# Zone 0: CPU fans
# Zone 1: Peripheral/System fans
FAN_ZONES=(0 1)

# Polling interval in seconds
POLL_INTERVAL=10

# Emergency safety threshold (revert to auto mode if exceeded)
# Set to 95°C (well below the 102°C high critical threshold for safety margin)
EMERGENCY_TEMP=95

# Per-zone fan curves: temperature -> duty cycle percentage
# Both zones use CPU temperature as input, but can respond at different levels
# CPU safe operating range: 10-97°C (based on sensor thresholds)

# Zone 0 (CPU fans: FAN1, FAN2, etc.)
declare -A CPU_FAN_CURVE=(
    [0]=15      # Below 35°C: 15%
    [35]=15     # 35-40°C: 15%
    [40]=15     # 40-45°C: 15%
    [45]=15     # 45-50°C: 15%
    [50]=15     # 50-55°C: 15%
    [55]=15     # 55-60°C: 15%
    [60]=15     # 60-65°C: 15%
    [65]=15     # 65-70°C: 15%
    [70]=60     # 70-75°C: 60%
    [75]=70     # 75-80°C: 70%
    [80]=80     # 80-85°C: 80%
    [85]=90     # 85-90°C: 90%
    [90]=100    # Above 90°C: 100%
)

# Zone 1 (Peripheral/system fans: FANA, FANB, etc.)
# Less aggressive than CPU fans by default to reduce case fan noise
declare -A SYS_FAN_CURVE=(
    [0]=15      # Below 35°C: 15%
    [35]=15     # 35-40°C: 15%
    [40]=15     # 40-45°C: 15%
    [45]=15     # 45-50°C: 15%
    [50]=15     # 50-55°C: 15%
    [55]=15     # 55-60°C: 15%
    [60]=15     # 60-65°C: 15%
    [65]=15     # 65-70°C: 15%
    [70]=45     # 70-75°C: 45%
    [75]=60     # 75-80°C: 60%
    [80]=75     # 80-85°C: 75%
    [85]=90     # 85-90°C: 90%
    [90]=100    # Above 90°C: 100%
)

# Backwards compatibility: if the legacy FAN_CURVE is defined (e.g. from an
# older version of this script), it overrides both per-zone curves above.
# To use per-zone curves, remove or comment out any FAN_CURVE definition.
# declare -A FAN_CURVE=(...)

# IPMI commands
IPMI_ENABLE_MANUAL="0x30 0x45 0x01 0x01"
IPMI_SET_FAN_ZONE="0x30 0x70 0x66 0x01"

# Alternative method to return to auto mode (using standard IPMI command)
# Note: The raw 0x30 0x45 0x01 0x00 command failed on your system,
# so we'll use the fan mode command instead
IPMI_ENABLE_AUTO_ALT="raw 0x30 0x01 0x01"

# State tracking
CURRENT_CPU_DUTY=0
CURRENT_PERIPHERAL_DUTY=0
LAST_TEMP=0
MANUAL_MODE_ACTIVE=false

# Apply legacy FAN_CURVE if defined (backwards compatibility)
if declare -p FAN_CURVE &>/dev/null; then
    for _key in "${!FAN_CURVE[@]}"; do
        CPU_FAN_CURVE[$_key]=${FAN_CURVE[$_key]}
        SYS_FAN_CURVE[$_key]=${FAN_CURVE[$_key]}
    done
    unset _key
fi

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Logging function with timestamp
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"

    # Rotate log if it gets too large
    if [[ -f "${LOG_FILE}" ]] && [[ $(stat -f%z "${LOG_FILE}" 2>/dev/null || stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0) -gt ${MAX_LOG_SIZE} ]]; then
        mv "${LOG_FILE}" "${LOG_FILE}.old"
        log "INFO" "Log rotated due to size"
    fi
}

# Convert percentage to hex value
percent_to_hex() {
    local percent=$1
    local decimal
    decimal=$(( (percent * 255) / 100 ))
    printf "0x%02x" "${decimal}"
}

# Get temperature from IPMI sensor
get_sensor_temp() {
    local sensor_name="$1"
    local temp

    # Get temperature value, handling potential errors
    temp=$(ipmitool sensor get "${sensor_name}" 2>/dev/null | \
           grep "Sensor Reading" | \
           awk '{print $4}' | \
           cut -d'.' -f1)

    # Return 0 if sensor reading failed
    if [[ -z "${temp}" ]] || [[ ! "${temp}" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "${temp}"
    fi
}

# Get maximum temperature from primary sensors
get_max_temp() {
    local max_temp=0
    local temp

    for sensor in "${PRIMARY_SENSORS[@]}"; do
        temp=$(get_sensor_temp "${sensor}")
        if [[ ${temp} -gt ${max_temp} ]]; then
            max_temp=${temp}
        fi
    done

    echo "${max_temp}"
}

# Calculate fan duty based on temperature using the specified fan curve
# Pass the curve name (CPU_FAN_CURVE or SYS_FAN_CURVE) as second argument
calculate_fan_duty() {
    local temp=$1
    local -n _curve=$2
    local duty=15  # Default minimum

    # Find appropriate duty cycle from fan curve (sorted thresholds)
    local -a _sorted_keys
    mapfile -t _sorted_keys < <(printf '%s\n' "${!_curve[@]}" | sort -n)
    for threshold in "${_sorted_keys[@]}"; do
        if [[ ${temp} -ge ${threshold} ]]; then
            duty=${_curve[${threshold}]}
        fi
    done

    echo "${duty}"
}

# Enable manual fan control mode
enable_manual_mode() {
    if ! ipmitool raw ${IPMI_ENABLE_MANUAL} >/dev/null 2>&1; then
        log "ERROR" "Failed to enable manual fan control mode"
        return 1
    fi
    MANUAL_MODE_ACTIVE=true
    log "INFO" "Manual fan control mode enabled"
    return 0
}

# Return to automatic fan control (using alternative method)
enable_auto_mode() {
    log "INFO" "Attempting to return to automatic fan control mode"

    # Try the standard fan mode command
    if ipmitool ${IPMI_ENABLE_AUTO_ALT} >/dev/null 2>&1; then
        MANUAL_MODE_ACTIVE=false
        log "INFO" "Automatic fan control mode restored (using fan mode command)"
        return 0
    fi

    # If that fails, set fans to 100% as a safety measure
    log "WARN" "Could not restore auto mode, setting fans to 100% for safety"
    set_all_fans_duty 100
    return 1
}

# Set fan duty cycle for a specific zone
set_fan_duty_zone() {
    local zone=$1
    local duty_percent=$2
    local duty_hex
    duty_hex=$(percent_to_hex "${duty_percent}")

    # Set the specific zone
    if ! ipmitool raw ${IPMI_SET_FAN_ZONE} "0x0${zone}" "${duty_hex}" >/dev/null 2>&1; then
        log "ERROR" "Failed to set fan duty for zone ${zone} to ${duty_percent}%"
        return 1
    fi

    # Update state tracking
    if [[ ${zone} -eq 0 ]]; then
        CURRENT_CPU_DUTY=${duty_percent}
    elif [[ ${zone} -eq 1 ]]; then
        CURRENT_PERIPHERAL_DUTY=${duty_percent}
    fi

    return 0
}

# Set fan duty cycle for all zones (emergency/safety function)
set_all_fans_duty() {
    local duty_percent=$1
    local success=true

    for zone in "${FAN_ZONES[@]}"; do
        if ! set_fan_duty_zone "${zone}" "${duty_percent}"; then
            success=false
        fi
    done

    if ${success}; then
        return 0
    else
        return 1
    fi
}

# Emergency handler for critical temperatures
handle_emergency() {
    local temp=$1
    log "CRITICAL" "Emergency temperature threshold exceeded: ${temp}°C (threshold: ${EMERGENCY_TEMP}°C)"
    log "CRITICAL" "Setting fans to 100% and reverting to automatic mode"

    # Set all fans to 100% first
    set_all_fans_duty 100
    sleep 2

    # Try to enable auto mode
    enable_auto_mode

    # Exit the script
    exit 1
}

# Cleanup function called on script exit
cleanup() {
    log "INFO" "Fan control script shutting down"

    if ${MANUAL_MODE_ACTIVE}; then
        log "INFO" "Restoring automatic fan control mode"
        enable_auto_mode || true
    fi

    log "INFO" "Fan control script stopped"
    exit 0
}

# Trap signals for graceful shutdown
trap cleanup SIGTERM SIGINT SIGHUP

################################################################################
# PRE-FLIGHT CHECKS
################################################################################

preflight_checks() {
    log "INFO" "Starting pre-flight checks"

    # Check if running as root
    if [[ ${EUID} -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi

    # Check if ipmitool is installed
    if ! command -v ipmitool >/dev/null 2>&1; then
        log "ERROR" "ipmitool is not installed. Install it with: apt-get install ipmitool"
        exit 1
    fi

    # Check if we can read sensors
    log "INFO" "Checking sensor availability"
    local sensor_ok=false
    for sensor in "${PRIMARY_SENSORS[@]}"; do
        local temp
        temp=$(get_sensor_temp "${sensor}")
        if [[ ${temp} -gt 0 ]]; then
            log "INFO" "  ${sensor}: ${temp}°C"
            sensor_ok=true
        else
            log "WARN" "  ${sensor}: Unable to read"
        fi
    done

    if ! ${sensor_ok}; then
        log "ERROR" "Unable to read any primary temperature sensors"
        exit 1
    fi

    # Check if we can enable manual mode
    if ! enable_manual_mode; then
        log "ERROR" "Unable to enable manual fan control mode"
        exit 1
    fi

    # Test setting fan speed for both zones
    log "INFO" "Testing fan control (setting zone 0 to 30%, zone 1 to 25%)"
    if ! set_fan_duty_zone 0 30; then
        log "ERROR" "Unable to set fan duty cycle for zone 0 (CPU)"
        enable_auto_mode
        exit 1
    fi
    if ! set_fan_duty_zone 1 25; then
        log "ERROR" "Unable to set fan duty cycle for zone 1 (Peripheral)"
        enable_auto_mode
        exit 1
    fi

    sleep 2

    log "INFO" "Pre-flight checks completed successfully"
}

################################################################################
# MAIN CONTROL LOOP
################################################################################

main_loop() {
    log "INFO" "Starting main control loop (polling every ${POLL_INTERVAL} seconds)"
    log "INFO" "Controlling Zone 0 (CPU fans) and Zone 1 (Peripheral fans) with per-zone curves"

    # Log active fan curves at startup
    local cpu_curve_str="" sys_curve_str=""
    for _t in $(echo "${!CPU_FAN_CURVE[@]}" | tr ' ' '\n' | sort -n); do
        cpu_curve_str+="${_t}°C:${CPU_FAN_CURVE[$_t]}% "
    done
    for _t in $(echo "${!SYS_FAN_CURVE[@]}" | tr ' ' '\n' | sort -n); do
        sys_curve_str+="${_t}°C:${SYS_FAN_CURVE[$_t]}% "
    done
    log "INFO" "Zone 0 (CPU) curve: ${cpu_curve_str}"
    log "INFO" "Zone 1 (Peripheral) curve: ${sys_curve_str}"

    while true; do
        # Get current maximum temperature
        local current_temp
        current_temp=$(get_max_temp)

        # Check if sensor reading is valid
        if [[ ${current_temp} -eq 0 ]]; then
            log "ERROR" "Unable to read temperature sensors - reverting to auto mode for safety"
            enable_auto_mode
            exit 1
        fi

        # Check for emergency condition
        if [[ ${current_temp} -ge ${EMERGENCY_TEMP} ]]; then
            handle_emergency "${current_temp}"
        fi

        # Calculate per-zone target duties from their respective curves
        local cpu_target sys_target
        cpu_target=$(calculate_fan_duty "${current_temp}" CPU_FAN_CURVE)
        sys_target=$(calculate_fan_duty "${current_temp}" SYS_FAN_CURVE)

        local changes_made=false

        # Update Zone 0 (CPU fans) if duty has changed
        if [[ ${cpu_target} -ne ${CURRENT_CPU_DUTY} ]]; then
            log "INFO" "Temperature: ${current_temp}°C | Zone 0 (CPU): ${CURRENT_CPU_DUTY}% -> ${cpu_target}%"
            if ! set_fan_duty_zone 0 "${cpu_target}"; then
                log "ERROR" "Failed to set CPU fan duty - reverting to auto mode for safety"
                enable_auto_mode
                exit 1
            fi
            changes_made=true
        fi

        # Update Zone 1 (Peripheral fans) if duty has changed
        if [[ ${sys_target} -ne ${CURRENT_PERIPHERAL_DUTY} ]]; then
            log "INFO" "Temperature: ${current_temp}°C | Zone 1 (Peripheral): ${CURRENT_PERIPHERAL_DUTY}% -> ${sys_target}%"
            if ! set_fan_duty_zone 1 "${sys_target}"; then
                log "ERROR" "Failed to set Peripheral fan duty - reverting to auto mode for safety"
                enable_auto_mode
                exit 1
            fi
            changes_made=true
        fi

        # Periodic stable status log (roughly every 60 seconds)
        if ! ${changes_made}; then
            if [[ $(($(date +%s) % 60)) -lt ${POLL_INTERVAL} ]]; then
                log "INFO" "Temperature: ${current_temp}°C | Zone 0 (CPU): ${cpu_target}% | Zone 1 (Peripheral): ${sys_target}% (stable)"
            fi
        fi

        LAST_TEMP=${current_temp}
        sleep "${POLL_INTERVAL}"
    done
}

################################################################################
# SCRIPT ENTRY POINT
################################################################################

main() {
    log "INFO" "=========================================="
    log "INFO" "Supermicro Fan Control Script Starting"
    log "INFO" "=========================================="

    # Run pre-flight checks
    preflight_checks

    # Start main control loop
    main_loop
}

# Run main function
main
