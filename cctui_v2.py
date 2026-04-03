#!/usr/bin/env python3
import curses
import os
import subprocess
import sys

# --- HARDWARE PATHS ---
FAN_MODE = "/sys/devices/platform/aorus_laptop/fan_mode"
MAX_CHARGE = "/sys/devices/platform/aorus_laptop/charge_limit"
RPM_FIXED = "/sys/devices/platform/aorus_laptop/fan_custom_speed"

MODE_LABELS = {
    "0": "Normal",
    "1": "Quiet",
    "2": "Gaming",
    "3": "Custom",
    "4": "Auto",
    "5": "Fixed",
}


def read_file(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except:
        return "?"


def write_file(path, value):
    try:
        with open(path, "w") as f:
            f.write(str(value))
        return True
    except:
        return False


def get_stats():
    """Returns a list of tuples (Label, Value) for vertical rendering."""
    stats = []
    try:
        # 1. CPU & FANS (lm_sensors)
        sns_out = subprocess.check_output(
            "sensors", shell=True, stderr=subprocess.DEVNULL
        ).decode()
        f1, f2 = "0", "0"
        for line in sns_out.split("\n"):
            if "Package id 0:" in line:
                stats.append(("CPU TEMP", line.split()[3]))
            if "fan1:" in line:
                f1 = line.split()[1]
            if "fan2:" in line:
                f2 = line.split()[1]

        # 2. GPU (nvidia-smi)
        gpu_raw = (
            subprocess.check_output(
                "nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits",
                shell=True,
                stderr=subprocess.DEVNULL,
            )
            .decode()
            .strip()
        )
        if gpu_raw.isdigit():
            stats.append(("GPU TEMP", f"+{gpu_raw}.0°C"))

        # 3. PCH (Thermal Zone 1)
        with open("/sys/class/thermal/thermal_zone1/temp", "r") as f:
            pch_raw = int(f.read().strip())
            stats.append(("PCH TEMP", f"+{pch_raw / 1000:.1f}°C"))

        # 4. Fans
        stats.append(("FAN 1", f"{f1} RPM"))
        stats.append(("FAN 2", f"{f2} RPM"))

    except:
        stats.append(("ERROR", "Telemetry Failed"))
    return stats


def draw_loop(stdscr):
    # Setup Colors
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_GREEN, -1)
    curses.init_pair(2, curses.COLOR_RED, -1)
    curses.init_pair(3, curses.COLOR_YELLOW, -1)
    curses.init_pair(4, curses.COLOR_CYAN, -1)

    curses.curs_set(0)
    stdscr.nodelay(True)
    stdscr.timeout(1000)

    while True:
        mode = read_file(FAN_MODE)
        rpm_target = read_file(RPM_FIXED)
        chg = read_file(MAX_CHARGE)
        stats_list = get_stats()

        stdscr.erase()

        # Header
        stdscr.addstr(
            1, 2, "AORUS TELEMETRY (VERTICAL)", curses.A_BOLD | curses.A_UNDERLINE
        )

        # Vertical Stats Column
        start_y = 3
        for i, (label, val) in enumerate(stats_list):
            # Label in Cyan
            stdscr.addstr(start_y + i, 4, f"{label:10}: ", curses.color_pair(4))
            # Value in Bold White
            stdscr.addstr(val, curses.A_BOLD)

        # Control Block (Offset to the right or below)
        m_color = curses.color_pair(4)
        if mode == "1":
            m_color = curses.color_pair(1)
        elif mode == "2":
            m_color = curses.color_pair(2)
        elif mode == "5":
            m_color = curses.color_pair(3)

        ctrl_y = start_y + len(stats_list) + 2
        stdscr.addstr(ctrl_y, 4, "MODE: ", curses.A_BOLD)
        stdscr.addstr(f"{MODE_LABELS.get(mode, mode)}", m_color | curses.A_BOLD)

        stdscr.addstr(
            ctrl_y + 1,
            4,
            f"TARGET:    {rpm_target}%",
            curses.color_pair(3) if mode == "5" else curses.A_DIM,
        )
        stdscr.addstr(ctrl_y + 2, 4, f"BAT LIMIT: {chg}%")

        stdscr.addstr(ctrl_y + 5, 2, "CONTROLS:", curses.color_pair(4))
        stdscr.addstr(ctrl_y + 6, 6, "[F1-F5] Mode Switch | [+/-] RPM | [Q] Quit")

        stdscr.refresh()

        key = stdscr.getch()
        if key == ord("q"):
            break
        elif key == curses.KEY_F1:
            write_file(FAN_MODE, "1")
        elif key == curses.KEY_F2:
            write_file(FAN_MODE, "0")
        elif key == curses.KEY_F3:
            write_file(FAN_MODE, "2")
        elif key == curses.KEY_F4:
            write_file(FAN_MODE, "4")
        elif key == curses.KEY_F5:
            write_file(FAN_MODE, "5")
        elif key in [ord("+"), ord("=")]:
            try:
                curr = int(read_file(RPM_FIXED))
                write_file(RPM_FIXED, max(25, min(100, curr + 5)))
            except:
                pass
        elif key in [ord("-"), ord("_")]:
            try:
                curr = int(read_file(RPM_FIXED))
                write_file(RPM_FIXED, max(25, min(100, curr - 5)))
            except:
                pass


if __name__ == "__main__":
    if os.geteuid() != 0:
        print("Run as root.")
        sys.exit(1)
    curses.wrapper(draw_loop)
