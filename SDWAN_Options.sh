#!/bin/bash

##
# SD-WAN Testing:
#   - Add Latency to an interface
#   - Remove Latency from an interface
#   - Shutdown an interface
#   - Enable an interface
##

# Modify with your WAN Interface Names
wan1="ens19"
wan2="ens20"

function add_latency_wan1() {
    echo ""
	clear
	echo "Adding 300ms of Latency to: $wan1"
	tc qdisc add dev $wan1 root netem delay 300ms
	echo ""
}

function add_latency_wan2() {
    echo ""
	clear
	echo "Adding 300ms of Latency to: $wan2"
	tc qdisc add dev $wan2 root netem delay 300ms
	echo ""
}

function clear_latency_wan1() {
    echo ""
	clear
	echo "Clearing latency from: $wan1"
	tc qdisc del dev $wan1 root netem
	echo ""
}

function clear_latency_wan2() {
    echo ""
	clear
	echo "Clearing latency from: $wan2"
	tc qdisc del dev $wan2 root netem
    echo ""
}

function shutdown_wan1() {
    echo ""
	clear
	echo "Shutting down interface $wan1"
	ip link set dev $wan1 down
	echo ""
}

function shutdown_wan2() {
    echo ""
	clear
	echo "Shutting down interface $wan2"
	ip link set dev $wan2 down
	echo ""
}

function enable_interfaces() {
	echo ""
	clear
	echo "Enabling both interfaces"
	ip link set dev $wan1 up
	ip link set dev $wan2 up
	echo ""
}

##
# Color  Variables
##
green='\e[32m'
blue='\e[34m'
clear='\e[0m'

##
# Color Functions
##

ColorGreen(){
	echo -ne $green$1$clear
}
ColorBlue(){
	echo -ne $blue$1$clear
}

clear

menu(){
echo -ne "
$(ColorGreen 'SD-WAN Test Options:')
$(ColorGreen '1)') Add Latency to WAN1
$(ColorGreen '2)') Add Latency to WAN2
$(ColorGreen '3)') Clear Latency from WAN1
$(ColorGreen '4)') Clear Latency from WAN2
$(ColorGreen '5)') Shutdown WAN1
$(ColorGreen '6)') Shutdown WAN2
$(ColorGreen '7)') Enable All Interfaces
$(ColorGreen '0)') Exit
$(ColorGreen 'Choose an option:') "
        read a
        case $a in
	        1) add_latency_wan1 ; menu ;;
	        2) add_latency_wan2 ; menu ;;
	        3) clear_latency_wan1 ; menu ;;
			4) clear_latency_wan2 ; menu ;;
	        5) shutdown_wan1 ; menu ;;
	        6) shutdown_wan2 ; menu ;;
			7) enable_interfaces ; menu ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option."$clear; WrongCommand;;
        esac
}

# Call the menu function
menu
