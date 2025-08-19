import subprocess
import os
import sys
from typing import Dict, Optional

# Interface names
WAN1 = "ens19"
WAN2 = "ens20"

# Default settings
DEFAULT_PARAMS = {
    WAN1: {'bandwidth': '100mbit', 'delay': '0ms', 'jitter': '0ms', 'loss': '0%'},
    WAN2: {'bandwidth': '50mbit', 'delay': '30ms', 'jitter': '0ms', 'loss': '0%'}
}

def run_command(cmd: list) -> Optional[str]:
    """Execute a shell command and return its output, handling errors."""
    os.system('clear')
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode().strip()
    except subprocess.CalledProcessError as e:
        print(f"Error executing {' '.join(cmd)}: {e.output.decode().strip()}")
        return None

def get_netem_params(interface: str) -> Dict[str, str]:
    """Retrieve current netem parameters for the interface."""
    output = run_command(["tc", "qdisc", "show", "dev", interface])
    if not output:
        return {'delay': '0ms', 'jitter': '0ms', 'loss': '0%'}
    
    for line in output.splitlines():
        if 'netem' in line:
            parts = line.split()
            params = {}
            i = 0
            while i < len(parts):
                if parts[i] == 'delay':
                    params['delay'] = parts[i+1]
                    if i+2 < len(parts) and parts[i+2].endswith('ms') and not parts[i+2].startswith('loss'):
                        params['jitter'] = parts[i+2]
                        i += 3
                    else:
                        i += 2
                elif parts[i] == 'loss':
                    params['loss'] = parts[i+1]
                    i += 2
                else:
                    i += 1
            params.setdefault('delay', '0ms')
            params.setdefault('jitter', '0ms')
            params.setdefault('loss', '0%')
            return params
    return {'delay': '0ms', 'jitter': '0ms', 'loss': '0%'}

def get_htb_rate(interface: str) -> str:
    """Retrieve current HTB bandwidth rate for the interface."""
    output = run_command(["tc", "class", "show", "dev", interface])
    if not output:
        return 'no limit'
    
    for line in output.splitlines():
        if 'class htb 1:10' in line:
            parts = line.split()
            for i in range(len(parts)):
                if parts[i] == 'rate':
                    return parts[i+1]
    return 'no limit'

def get_interface_status(interface: str) -> str:
    """Retrieve current interface status (UP/DOWN)."""
    output = run_command(["ip", "link", "show", interface])
    if not output:
        return 'UNKNOWN'
    return 'UP' if 'state UP' in output else 'DOWN' if 'state DOWN' in output else 'UNKNOWN'

def setup_qdiscs(interface: str, bandwidth: str, delay: str, jitter: str, loss: str) -> None:
    """Set up HTB and netem qdiscs with specified parameters."""
    subprocess.call(["tc", "qdisc", "del", "dev", interface, "root"], stderr=subprocess.DEVNULL)
    run_command(["tc", "qdisc", "add", "dev", interface, "root", "handle", "1:", "htb", "default", "10"])
    run_command(["tc", "class", "add", "dev", interface, "parent", "1:", "classid", "1:10", "htb", "rate", bandwidth])
    cmd = ["tc", "qdisc", "add", "dev", interface, "parent", "1:10", "handle", "10:", "netem", "delay", delay, jitter, "loss", loss]
    run_command(cmd)

def set_netem(interface: str, delay: Optional[str] = None, jitter: Optional[str] = None, loss: Optional[str] = None) -> None:
    """Change netem parameters, setting up qdiscs if necessary."""
    cmd = ["tc", "qdisc", "change", "dev", interface, "handle", "10:", "netem"]
    current = get_netem_params(interface)
    
    delay = delay or current['delay']
    jitter = jitter or current['jitter']
    loss = loss or current['loss']
    
    cmd += ["delay", delay, jitter, "loss", loss]
    if not run_command(cmd):
        current_rate = get_htb_rate(interface)
        bandwidth = current_rate if current_rate != 'no limit' else DEFAULT_PARAMS[interface]['bandwidth']
        setup_qdiscs(interface, bandwidth, delay, jitter, loss)

def set_htb_rate(interface: str, rate: str) -> None:
    """Change HTB bandwidth rate, setting up qdiscs if necessary."""
    cmd = ["tc", "class", "change", "dev", interface, "parent", "1:", "classid", "1:10", "htb", "rate", rate]
    if not run_command(cmd):
        current_netem = get_netem_params(interface)
        setup_qdiscs(interface, rate, current_netem['delay'], current_netem['jitter'], current_netem['loss'])

def set_interface_status(interface: str, state: str) -> None:
    """Set interface status to up or down."""
    run_command(["ip", "link", "set", interface, state])

def toggle_latency_wan1() -> None:
    """Toggle WAN1 latency between 0ms and 200ms."""
    current = get_netem_params(WAN1)
    new_delay = '200ms' if current['delay'] == '0ms' else '0ms'
    set_netem(WAN1, delay=new_delay, jitter=DEFAULT_PARAMS[WAN1]['jitter'], loss=DEFAULT_PARAMS[WAN1]['loss'])

def toggle_packet_loss_wan2() -> None:
    """Toggle WAN2 packet loss between 0% and 5%."""
    current = get_netem_params(WAN2)
    new_loss = '5%' if current['loss'] == '0%' else '0%'
    set_netem(WAN2, delay=DEFAULT_PARAMS[WAN2]['delay'], jitter=current['jitter'], loss=new_loss)

def toggle_jitter_wan2() -> None:
    """Toggle WAN2 jitter between 1ms and 10ms."""
    current = get_netem_params(WAN2)
    new_jitter = '10ms' if current['jitter'] == '1ms' else '1ms'
    set_netem(WAN2, delay=DEFAULT_PARAMS[WAN2]['delay'], jitter=new_jitter, loss=current['loss'])

def toggle_bandwidth_wan1() -> None:
    """Toggle WAN1 bandwidth between 100mbit and 10mbit."""
    current_rate = get_htb_rate(WAN1)
    new_rate = '10mbit' if current_rate == '100mbit' else '100mbit'
    set_htb_rate(WAN1, new_rate)

def toggle_interface_status_wan2() -> None:
    """Toggle WAN2 interface status between UP and DOWN."""
    current_status = get_interface_status(WAN2)
    new_state = 'down' if current_status == 'UP' else 'up'
    set_interface_status(WAN2, new_state)

def restore_defaults() -> None:
    """Restore default settings for both interfaces."""
    for interface in [WAN1, WAN2]:
        setup_qdiscs(interface, **DEFAULT_PARAMS[interface])
        set_interface_status(interface, 'up')

def clean_up() -> None:
    """Reset all tc settings and set interfaces to UP."""
    for interface in [WAN1, WAN2]:
        subprocess.call(["tc", "qdisc", "del", "dev", interface, "root"], stderr=subprocess.DEVNULL)
        set_interface_status(interface, 'up')

def show_status() -> None:
    """Display current status of WAN1 and WAN2 in a tabulated format."""
    status_wan1 = get_interface_status(WAN1)
    status_wan2 = get_interface_status(WAN2)
    bandwidth_wan1 = get_htb_rate(WAN1)
    bandwidth_wan2 = get_htb_rate(WAN2)
    netem_wan1 = get_netem_params(WAN1)
    netem_wan2 = get_netem_params(WAN2)

    width = 15
    headers = ["Values", "WAN1", "WAN2"]
    rows = [
        ["Status", status_wan1, status_wan2],
        ["Bandwidth", bandwidth_wan1, bandwidth_wan2],
        ["Packet loss", netem_wan1['loss'], netem_wan2['loss']],
        ["Latency", netem_wan1['delay'], netem_wan2['delay']],
        ["Jitter", netem_wan1['jitter'], netem_wan2['jitter']]
    ]

    print(" ".join(h.ljust(width) for h in headers))
    for row in rows:
        print(" ".join(str(v).ljust(width) for v in row))

def display_menu() -> None:
    """Display the menu options."""
    print("\nNetwork Configuration Management Menu:")
    print("1. Toggle latency WAN1 (0ms <-> 200ms)")
    print("2. Toggle packet loss WAN2 (0% <-> 5%)")
    print("3. Toggle jitter WAN2 (1ms <-> 10ms)")
    print("4. Toggle bandwidth limit WAN1 (100mbit <-> 10mbit)")
    print("5. Toggle interface status WAN2 (on <-> off)")
    print("6. Restore default settings")
    print("7. Clean up (reset all tc settings, interface status, and bandwidth limit)")
    print("8. Show current status")
    print("0. Exit")

def main() -> None:
    """Main function to handle user interaction and execute actions."""
    if os.geteuid() != 0:
        print("Error: This script must be run as root")
        sys.exit(1)

    actions = {
        '1': toggle_latency_wan1,
        '2': toggle_packet_loss_wan2,
        '3': toggle_jitter_wan2,
        '4': toggle_bandwidth_wan1,
        '5': toggle_interface_status_wan2,
        '6': restore_defaults,
        '7': clean_up,
        '8': show_status
    }

    while True:
        display_menu()
        choice = input("Select an option (0-8): ").strip()

        if choice == '0':
            print("Exiting...")
            break
        elif choice in actions:
            actions[choice]()
            if choice != '8':  # Do not show status again if 'Show current status' was selected
                show_status()
        else:
            print("Invalid option. Please try again.")

if __name__ == "__main__":
    main()
