# Supermicro IPMI Fan Control

A smart, automated fan control script for Supermicro servers with IPMI support. This script monitors CPU temperatures and dynamically adjusts fan speeds to maintain optimal cooling while minimizing noise.

## Features

- **Ultra-Quiet Operation**: Maintains 15% fan speed for normal temperatures (below 70°C)
- **Temperature-Based Control**: Automatically adjusts fan speeds based on CPU temperature
- **Per-Zone Fan Curves**: Independent fan curves for CPU fans (Zone 0) and peripheral fans (Zone 1)
- **Safety First**: Multiple safety mechanisms including emergency thresholds and automatic failover
- **Systemd Integration**: Runs as a service with automatic startup
- **Detailed Logging**: Comprehensive logs with automatic rotation

## Hardware Requirements

- Supermicro server motherboard with IPMI support
- IPMI accessible via `ipmitool`
- Linux-based operating system

## Software Requirements

- `ipmitool` - IPMI management utility
- `bash` 4.3 or later - Shell scripting environment
- Root/sudo access

## Quick Start

### 1. Install Dependencies

```bash
# Debian/Ubuntu
sudo apt update
sudo apt install ipmitool

# RHEL/CentOS/Rocky
sudo yum install ipmitool
```

### 2. Install the Script

```bash
# Copy the script to system location
sudo cp supermicro-fan-control.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/supermicro-fan-control.sh

# Install the systemd service
sudo cp supermicro-fan-control.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### 3. Test the Script

Before enabling as a service, test manually:

```bash
# Run the script in foreground to verify it works
sudo /usr/local/bin/supermicro-fan-control.sh

# Watch the output for a few minutes
# Press Ctrl+C to stop
```

### 4. Enable the Service

```bash
# Enable and start the service
sudo systemctl enable supermicro-fan-control.service
sudo systemctl start supermicro-fan-control.service

# Check status
sudo systemctl status supermicro-fan-control.service

# Monitor logs
sudo tail -f /var/log/fan-control.log
```

## Fan Curve Configuration

The script supports **per-zone fan curves**, allowing independent speed profiles for CPU fans and peripheral/case fans. Both zones are driven by CPU temperature, but each can respond at different duty cycle levels.

This is useful when case fans (Zone 1) are louder than CPU fans (Zone 0) and you want them to run at lower RPMs.

### Default Curves

**Zone 0 -- CPU fans (`CPU_FAN_CURVE`):**

| Temperature Range | Fan Speed | Notes |
|-------------------|-----------|-------|
| < 70°C            | 15%       | Almost silent, normal operation |
| 70-75°C           | 60%       | High load cooling |
| 75-80°C           | 70%       | Very high load |
| 80-85°C           | 80%       | Near emergency threshold |
| 85-90°C           | 90%       | Critical temperatures |
| >= 90°C           | 100%      | Maximum cooling |

**Zone 1 -- Peripheral fans (`SYS_FAN_CURVE`):**

| Temperature Range | Fan Speed | Notes |
|-------------------|-----------|-------|
| < 70°C            | 15%       | Almost silent, normal operation |
| 70-75°C           | 45%       | Moderate cooling (quieter than CPU zone) |
| 75-80°C           | 60%       | High load |
| 80-85°C           | 75%       | Near emergency threshold |
| 85-90°C           | 90%       | Critical temperatures |
| >= 90°C           | 100%      | Maximum cooling |

**Emergency Threshold**: 95°C (triggers 100% fan speed on both zones and safety shutdown)

> **Note:** Both zones use CPU temperature as their input. Supermicro X10/X11 boards do not expose per-zone temperature sensors through IPMI in a way that maps cleanly to peripheral devices, so CPU temperature drives both curves.

### Customising the Fan Curves

Edit `CPU_FAN_CURVE` and `SYS_FAN_CURVE` in [supermicro-fan-control.sh](supermicro-fan-control.sh):

#### Example: Quieter Case Fans

Keep CPU fans responsive while running case fans at minimal speed until temperatures are high:

```bash
declare -A CPU_FAN_CURVE=(
    [0]=15      # Below 40°C: 15%
    [40]=20     # 40-50°C: 20%
    [50]=30     # 50-60°C: 30%
    [60]=45     # 60-70°C: 45%
    [70]=60     # 70-75°C: 60%
    [75]=75     # 75-80°C: 75%
    [80]=90     # 80-85°C: 90%
    [85]=100    # Above 85°C: 100%
)

declare -A SYS_FAN_CURVE=(
    [0]=15      # Below 60°C: 15%
    [60]=15     # 60-70°C: 15%
    [70]=25     # 70-75°C: 25%
    [75]=40     # 75-80°C: 40%
    [80]=60     # 80-85°C: 60%
    [85]=100    # Above 85°C: 100%
)
```

#### Example: Performance Profile

For maximum cooling across both zones:

```bash
declare -A CPU_FAN_CURVE=(
    [0]=25      # Below 35°C: 25%
    [35]=30     # 35-45°C: 30%
    [45]=40     # 45-55°C: 40%
    [55]=55     # 55-65°C: 55%
    [65]=70     # 65-75°C: 70%
    [75]=85     # 75-80°C: 85%
    [80]=100    # Above 80°C: 100%
)

declare -A SYS_FAN_CURVE=(
    [0]=25      # Below 35°C: 25%
    [35]=30     # 35-45°C: 30%
    [45]=40     # 45-55°C: 40%
    [55]=55     # 55-65°C: 55%
    [65]=70     # 65-75°C: 70%
    [75]=85     # 75-80°C: 85%
    [80]=100    # Above 80°C: 100%
)
```

### Backwards Compatibility

If you are upgrading from a version that used a single `FAN_CURVE` variable, you have two options:

1. **Migrate** (recommended): Copy your `FAN_CURVE` values to `CPU_FAN_CURVE`, then create a less aggressive `SYS_FAN_CURVE` for your case fans.
2. **Keep the old variable**: If `FAN_CURVE` is defined in the script, it automatically overrides both `CPU_FAN_CURVE` and `SYS_FAN_CURVE`, so existing deployments continue to work without changes.

After modifying the fan curves:

```bash
sudo systemctl restart supermicro-fan-control.service
sudo tail -f /var/log/fan-control.log
```

## Configuration Options

Edit [supermicro-fan-control.sh](supermicro-fan-control.sh) to customize:

| Setting | Default | Description |
|---------|---------|-------------|
| `LOG_FILE` | `/var/log/fan-control.log` | Log file location |
| `MAX_LOG_SIZE` | `10485760` (10MB) | Maximum log size before rotation |
| `PRIMARY_SENSORS` | `("CPU1 Temp" "CPU2 Temp")` | Temperature sensors to monitor |
| `FAN_ZONES` | `(0 1)` | Fan zones to control |
| `POLL_INTERVAL` | `10` | Temperature check interval (seconds) |
| `EMERGENCY_TEMP` | `95` | Emergency shutdown temperature (°C) |
| `CPU_FAN_CURVE` | Ultra-quiet profile | Fan curve for Zone 0 (CPU fans) |
| `SYS_FAN_CURVE` | Quieter than CPU curve | Fan curve for Zone 1 (peripheral fans) |

## Safety Features

1. **Emergency Threshold Protection**: If temps exceed 95°C, fans go to 100% and script exits to auto mode
2. **Sensor Failure Protection**: If sensors fail to read, fans revert to automatic BMC control (and set to 100% if auto mode restoration also fails)
3. **Service Stop Safety**: When service stops, automatic fan control is restored
4. **Per-Zone Safety**: Both zones enforce minimum speed and emergency thresholds independently
5. **Conservative Design**: 15% minimum fan speed ensures adequate airflow at all times
6. **Log Rotation**: Automatic log rotation prevents disk space issues

## Monitoring

### View Current Status

```bash
# Check service status
sudo systemctl status supermicro-fan-control.service

# View recent logs
sudo journalctl -u supermicro-fan-control.service -n 50

# Monitor live logs
sudo tail -f /var/log/fan-control.log
```

### Check Temperatures and Fan Speeds

```bash
# View CPU temperatures
ipmitool sensor | grep -i temp

# View fan speeds (RPM)
ipmitool sensor | grep -i fan

# Monitor in real-time
watch -n 2 'ipmitool sensor | grep -E "(Temp|FAN)"'
```

### Example Log Output

```
[2025-11-12 10:30:00] [INFO] Starting main control loop (polling every 10 seconds)
[2025-11-12 10:30:00] [INFO] Controlling Zone 0 (CPU fans) and Zone 1 (Peripheral fans) with per-zone curves
[2025-11-12 10:30:00] [INFO] Zone 0 (CPU) curve: 0°C:15% 35°C:15% ... 90°C:100%
[2025-11-12 10:30:00] [INFO] Zone 1 (Peripheral) curve: 0°C:15% 35°C:15% ... 90°C:100%
[2025-11-12 10:30:00] [INFO] Temperature: 45°C | Zone 0 (CPU): 0% -> 15%
[2025-11-12 10:30:00] [INFO] Temperature: 45°C | Zone 1 (Peripheral): 0% -> 15%
[2025-11-12 10:31:00] [INFO] Temperature: 45°C | Zone 0 (CPU): 15% | Zone 1 (Peripheral): 15% (stable)
[2025-11-12 10:35:00] [INFO] Temperature: 72°C | Zone 0 (CPU): 15% -> 60%
[2025-11-12 10:35:00] [INFO] Temperature: 72°C | Zone 1 (Peripheral): 15% -> 45%
```

## Manual IPMI Control

### Enable Manual Fan Control

```bash
sudo ipmitool raw 0x30 0x45 0x01 0x01
```

### Set Fan Speed for Specific Zones

```bash
# Zone 0 (CPU fans) to 50% (0x7F = 127 = 50%)
sudo ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x7F

# Zone 1 (Peripheral fans) to 50%
sudo ipmitool raw 0x30 0x70 0x66 0x01 0x01 0x7F
```

### Return to Automatic Mode

```bash
sudo ipmitool raw 0x30 0x01 0x01
```

### Hex Conversion Reference

| % | Hex | Decimal |
|---|-----|---------|
| 15% | 0x26 | 38 |
| 20% | 0x33 | 51 |
| 25% | 0x3F | 63 |
| 30% | 0x4C | 76 |
| 40% | 0x66 | 102 |
| 50% | 0x7F | 127 |
| 60% | 0x99 | 153 |
| 70% | 0xB2 | 178 |
| 80% | 0xCC | 204 |
| 90% | 0xE5 | 229 |
| 100% | 0xFF | 255 |

## Troubleshooting

### Service Won't Start

```bash
# Check for errors
sudo journalctl -u supermicro-fan-control.service -n 50

# Verify ipmitool works
sudo ipmitool sensor get "CPU1 Temp"

# Test manual fan control
sudo ipmitool raw 0x30 0x45 0x01 0x01
sudo ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x33
```

### Fans Not Responding

```bash
# Enable manual mode
sudo ipmitool raw 0x30 0x45 0x01 0x01

# Test Zone 0 at 100%
sudo ipmitool raw 0x30 0x70 0x66 0x01 0x00 0xFF
sleep 3

# Test Zone 1 at 100%
sudo ipmitool raw 0x30 0x70 0x66 0x01 0x01 0xFF
sleep 3

# Return to auto mode
sudo ipmitool raw 0x30 0x01 0x01
```

### High CPU Usage

The script is designed to be lightweight and should use minimal CPU. If you see high usage:

```bash
# Check polling interval (default: 10 seconds)
grep POLL_INTERVAL /usr/local/bin/supermicro-fan-control.sh
```

### Script Exits Unexpectedly

Check logs for errors:

```bash
sudo tail -100 /var/log/fan-control.log
sudo journalctl -u supermicro-fan-control.service -n 100
```

Common causes:
- Temperature sensors become unreadable
- IPMI commands failing
- Emergency temperature threshold exceeded

## Expected Noise Levels

With the ultra-quiet default configuration (Zone 1 runs at lower duty than Zone 0 between 70-85°C):

| Temperature | Zone 0 (CPU) | Zone 1 (Peripheral) | Noise Level |
|-------------|-------------|---------------------|-------------|
| < 70°C      | 15%         | 15%                 | Almost silent |
| 70-75°C     | 60%         | 45%                 | Loud (CPU fans ramp first) |
| 75-80°C     | 70%         | 60%                 | Very loud |
| 80-85°C     | 80%         | 75%                 | Extremely loud |
| 85-90°C     | 90%         | 90%                 | Extremely loud |
| >= 90°C     | 100%        | 100%                | Maximum |

## Uninstalling

```bash
# Stop and disable the service
sudo systemctl stop supermicro-fan-control.service
sudo systemctl disable supermicro-fan-control.service

# Remove files
sudo rm /usr/local/bin/supermicro-fan-control.sh
sudo rm /etc/systemd/system/supermicro-fan-control.service
sudo rm /var/log/fan-control.log*

# Reload systemd
sudo systemctl daemon-reload

# Return IPMI to automatic mode
sudo ipmitool raw 0x30 0x01 0x01
```

## How It Works

1. **Initialization**: Script enables manual fan control mode via IPMI
2. **Monitoring**: Every 10 seconds (configurable), reads CPU temperatures from both CPUs
3. **Calculation**: Uses the maximum temperature to look up each zone's target duty from its fan curve
4. **Control**: Sends IPMI commands to set each fan zone to its independently calculated speed
5. **Safety**: Continuously monitors for emergency conditions and sensor failures
6. **Cleanup**: On exit, returns fans to automatic IPMI control mode

## Architecture

- **Zone 0**: CPU fans (directly cooling processors)
- **Zone 1**: Peripheral/System fans (case airflow)
- **Control Strategy**: Each zone uses its own fan curve; CPU fans can ramp independently of peripheral fans
- **Temperature Source**: Maximum temperature from CPU1 and CPU2 sensors

## Contributing

Feel free to submit issues, fork the repository, and create pull requests for any improvements.

## License

See [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built for Supermicro X10/X11 generation motherboards
- Inspired by the need for quieter home lab servers
- Uses IPMI raw commands for granular fan control

## Support

If you encounter issues:

1. Check the troubleshooting section above
2. Review logs: `/var/log/fan-control.log`
3. Test IPMI commands manually
4. Verify sensor readings with `ipmitool sensor`
5. Open an issue with details about your hardware and error messages

---

**Warning**: This script takes control of your server's fan speeds. While it includes multiple safety features, use at your own risk. Monitor temperatures carefully after installation to ensure proper cooling for your specific hardware and workload.
