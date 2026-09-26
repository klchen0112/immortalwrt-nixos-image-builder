{
  inputs = {
    immortalwrt-imagebuilder.url = "github:codgician/nix-immortalwrt-imagebuilder";
  };
  outputs =
    {
      self,
      nixpkgs,
      immortalwrt-imagebuilder,
    }:
    let
      common = [
        "arptables-nft"
        "iptables-nft"
        "ip6tables-nft"

        "kmod-arptables"
        "kmod-br-netfilter"
        "kmod-mdio-netlink"
        "kmod-nf-nat"
        "kmod-nf-nat6"
        "kmod-nf-nathelper"
        "kmod-nf-nathelper-extra"
        "kmod-nf-nathelper-rtsp"
        "kmod-nfnetlink"
        "kmod-nfnetlink-cthelper"
        "kmod-nfnetlink-cttimeout"
        "kmod-nfnetlink-log"
        "kmod-nfnetlink-queue"
        "kmod-nf-ipvs"
        "kmod-nf-ipvs-ftp"
        "kmod-nf-ipvs-sip"
        "kmod-nlmon"
        "kmod-nft-arp"
        "kmod-nft-bridge"
        "kmod-nft-compat"
        "kmod-nft-connlimit"
        "kmod-nft-dup-inet"
        "kmod-nft-netdev"
        "kmod-nft-queue"
        "kmod-nft-socket"
        "kmod-nft-tproxy"
        "kmod-nft-xfrm"
        "kmod-nft-offload"

        "kmod-tls"
        "kmod-sched-mqprio"
        "kmod-sched-connmark"
        "kmod-tcp-bbr"

        "luci-i18n-base-zh-cn"
        "luci-i18n-firewall-zh-cn"
        "luci-proto-wireguard"
        "luci-theme-argon"

        "ca-bundle"
        "htop"
        "minicom"

        "avahi-daemon-service-ssh"
        "avahi-daemon-service-http"
        "avahi-utils"
        "wsdd2"

        "dosfstools"
        "f2fs-tools"
        "f2fsck"

        "luci-app-uhttpd"
        "luci-i18n-uhttpd-zh-cn"
        "wget-ssl"
        "libopenssl-legacy"
        "tmux"
        "rsync"
        "rsyncd"
      ];
      tools = [
        "-ethtool"
        "ethtool-full"

        "vim"
        "vim-runtime"

        "telnet-bsd"
        "bind-host"
        "bind-dig"
        "iperf3"
        "lscpu"
        "lsblk"

        "httping"
        "tcping"
        "pppoe-discovery"
        "tcpdump"

        "picocom"
      ];
      proxy = [
        "-dnsmasq"
        "dnsmasq-full"
        "ip-full"
        "mosdns"
        "haveged"
      ];
      usb = [
        "kmod-usb2"
        "kmod-usb3"
        "usbutils"
        "uhubctl"
        "kmod-fs-ntfs3"
        "ntfs3-mount"
        "exfat-fsck"
        "exfat-mkfs"
        "kmod-fs-exfat"

        "kmod-usb-storage"
        "kmod-usb-storage-extras"
        "kmod-usb-storage-uas"
        "kmod-usb-serial"

        "kmod-usb-acm"
        "kmod-usb-core"
        "kmod-usb-hid"
        "kmod-usb-ehci"
        "kmod-usb-ohci"
        "kmod-usb-uhci"
        "kmod-usb-wdm"

        "kmod-usb-net"
        "kmod-usb-net-ipheth"
        "kmod-usb-net-rndis"
      ];
      statistics = [
        "luci-app-statistics"
        "luci-i18n-statistics-zh-cn"
        "collectd-mod-netlink"
        "collectd-mod-irq"
        "collectd-mod-disk"
        "collectd-mod-cpu"
        "collectd-mod-cpufreq"
        "collectd-mod-df"
        "collectd-mod-interface"
        "collectd-mod-processes"
        "collectd-mod-uptime"
        "collectd-mod-vmem"
        "collectd-mod-email"
        "collectd-mod-ethstat"
        "collectd-mod-conntrack"
        "collectd-mod-dhcpleases"
        "collectd-mod-syslog"
        "collectd-mod-write-http"
        "collectd-mod-ping"
        "collectd-mod-dns"
        "collectd-mod-memory"
        "collectd-mod-thermal"
        "collectd-mod-sensors"
        "collectd-mod-smart"
        "smartmontools"
        "smartmontools-drivedb"
      ];
      zram = [
        "kmod-zram"
        "zram-swap"
      ];
    in
    {
      packages.x86_64-linux.cudy-tr3000 =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;

          profiles = immortalwrt-imagebuilder.lib.profiles { inherit pkgs; };

          config = profiles.identifyProfile "cudy_tr3000-256mb-v1" // {
            # add package to include in the image, ie. packages that you don't
            # want to install manually later
            packages = common ++ tools ++ proxy ++ usb ++ statistics ++ zram;
          };
        in
        immortalwrt-imagebuilder.lib.build config;
    };
}
