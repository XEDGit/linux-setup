#!/usr/bin/awk -f
#
# tmux-netspeed - network throughput for the tmux status line.
#
# One process per refresh: no shell, no subshells, no tmux round-trips.
# State lives in a small file instead of tmux global options.
#
# Output:  󰇚  1.2M 󰕒  340K
#
# Usage in tmux.conf:
#     #[fg=#00abab,bg=#303030] #(/usr/local/bin/tmux-netspeed) 

function human(b,   u, i) {
    split("B K M G T", u, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1 || b >= 100) return sprintf("%.0f%s", b, u[i])
    return sprintf("%.1f%s", b, u[i])
}

BEGIN {
    # ---- config -------------------------------------------------------
    # Interfaces to ignore: loopback plus the usual container/VM/VPN noise.
    skip  = "^(lo|docker|veth|br-|virbr|tun|tap|wg|vmnet|kube|cni|flannel)"
    width = 6        # field width, so the bar doesn't jitter
    dl    = "v"      # default download glyph, overridden by $1
    ul    = "^"      # default upload glyph, overridden by $2
    # --------------------------------------------------------------------

    if (ARGC > 1) dl = ARGV[1]
    if (ARGC > 2) ul = ARGV[2]
    ARGC = 1                    # don't let awk treat the args as filenames

    dir = ENVIRON["XDG_RUNTIME_DIR"]
    if (dir != "") {
        file = dir "/tmux-netspeed.state"
    } else {
        user = ENVIRON["USER"]
        if (user == "") user = "default"
        file = "/tmp/tmux-netspeed-" user ".state"
    }

    # ---- current counters ----------------------------------------------
    while ((getline line < "/proc/net/dev") > 0) {
        p = index(line, ":")
        if (p == 0) continue
        iface = substr(line, 1, p - 1)
        gsub(/[ \t]/, "", iface)
        if (iface ~ skip) continue
        split(substr(line, p + 1), c)
        rx += c[1]          # rx_bytes
        tx += c[9]          # tx_bytes
    }
    close("/proc/net/dev")

    # Monotonic-ish clock without forking date(1).
    getline uptime < "/proc/uptime"
    close("/proc/uptime")
    split(uptime, t)
    now = t[1]

    # ---- previous counters ---------------------------------------------
    if ((getline prev < file) > 0) {
        split(prev, s)
        dt = now - s[1]
        if (dt > 0.2 && dt < 3600) {
            drx = rx - s[2]
            dtx = tx - s[3]
            if (drx >= 0 && dtx >= 0) {   # guard counter reset / NIC unplug
                rs = drx / dt
                ts = dtx / dt
                ok = 1
            }
        }
    }
    close(file)

    print now, rx, tx > file
    close(file)

    printf "%s %*s %s %*s\n", dl, width, (ok ? human(rs) : "--"), \
                              ul, width, (ok ? human(ts) : "--")
}
