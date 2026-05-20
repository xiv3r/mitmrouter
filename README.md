# mitmrouter
Bash script to automate setup of Linux router useful for IoT device traffic analysis and SSL mitm

![Arch](./img/arch.jpg)

## Dependancies

- hostapd
- dnsmasq
- bridge-utils
    - provides `brctl`
- net-tools
    - provides `ifconfig`

## Usage

You may want to disable NetworkManager as it may fight for control of one or more of the network interfaces.

Before running the script, copy `mitmrouter.conf.example` to `mitmrouter.conf` and edit it to set your interface names, Wi-Fi SSID, password, and other details. If `mitmrouter.conf` is missing on first run, the script will auto-create it from the example and exit so you can edit it.

```
./mitmrouter.sh: <up/down>
```

The `./mitmrouter.sh up` command will bring down all the linux router components and then build them back up again

The `./mitmrouter.sh down` command will bring down all the linux router components


