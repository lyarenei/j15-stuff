# Records one Wi-Fi signal sample per INTERVAL_S of robot movement, taken from
# the planner log's BodyPose lines on stdin, as CSV job files in DIR.
# Plain POSIX awk: runs with the robot's busybox awk and with macOS awk.
# Parameters come in with -v; see wifimap.sh.

function secs(   a) {
    split($2, a, ":")
    return a[1] * 3600 + a[2] * 60 + a[3]
}

# Signal level in dBm from WIRELESS, empty when there is none (-256 = no value).
function read_dbm(   line, a, d) {
    d = ""
    while ((getline line < WIRELESS) > 0) {
        split(line, a, " ")
        if (a[1] == IFACE ":") { d = a[4]; break }
    }
    close(WIRELESS)
    sub(/\.$/, "", d)
    if (d + 0 <= -256) d = ""
    return d
}

# Sets bssid and freq; both stay empty when not connected.
function read_link(   line, a) {
    bssid = ""; freq = ""
    while ((IW_CMD | getline line) > 0) {
        split(line, a, " ")
        if (a[1] == "Connected") { bssid = tolower(a[3]); sub(/\(.*/, "", bssid) }
        if (a[1] == "freq:") freq = a[2]
    }
    close(IW_CMD)
}

function start_job(   e) {
    if (out != "") close(out)
    "date +%s" | getline e
    close("date +%s")
    out = DIR "/job-" e ".csv"
    job_epoch = e + 0
    job_abs = abs
    print "t,x_mm,y_mm,theta_deg,dbm,bssid,freq_mhz" > out
    fflush(out)
    if (PRUNE_CMD != "") system(PRUNE_CMD)
    last_link = -1e9
}

/UpdatePose - BodyPose / {
    # glog times have no date: count seconds across midnight (MMDD changes).
    md = substr($1, 2)
    abs = secs() + day
    if (have_t && md != last_md) { day += 86400; abs += 86400 }
    last_md = md
    if (have_t && abs < last_seen) next
    last_seen = abs
    have_t = 1

    if (out != "" && abs - last_sample < INTERVAL_S) next
    if (out == "" || abs - last_sample > JOB_GAP_S) start_job()
    last_sample = abs

    s = substr($0, index($0, "BodyPose ") + 9)
    gsub(/,/, "", s)
    split(s, v, " ")

    if (abs - last_link >= BSSID_EVERY_S) { read_link(); last_link = abs }

    print (job_epoch + int(abs - job_abs)) "," v[1] "," v[2] "," v[3] "," read_dbm() "," bssid "," freq > out
    if (abs - last_flush >= FLUSH_S) { fflush(out); last_flush = abs }
}

END { if (out != "") close(out) }
