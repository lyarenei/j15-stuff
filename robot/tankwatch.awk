# Estimates the dock tank levels from data_node and manager log lines on stdin.
# Plain POSIX awk: runs with the robot's busybox awk and with macOS awk.
# Parameters come in with -v; see tankwatch.sh.

function now(   t) {
    if (FIXED_NOW + 0 > 0) return FIXED_NOW + 0
    "date +%s" | getline t
    close("date +%s")
    return t + 0
}

function pct(used, cap,   r) {
    r = 100 - used / cap * 100
    if (r < 0) r = 0
    if (r > 100) r = 100
    return int(r + 0.5)
}

function tank_json(used, cap, since,   p) {
    p = pct(used, cap)
    return sprintf("{\"used_ml\":%d,\"capacity_ml\":%d,\"remaining_pct\":%d,\"low\":%s,\"reset\":%d}",
        int(used + 0.5), cap, p, (p < LOW_PCT) ? "true" : "false", since)
}

function write_state(   tmp) {
    tmp = STATE_FILE ".tmp"
    printf "{\"version\":1,\"updated\":%d,\"clean\":%s,\"dirty\":%s}\n",
        now(), tank_json(clean, CLEAN_CAPACITY_ML, clean_reset),
        tank_json(dirty, DIRTY_CAPACITY_ML, dirty_reset) > tmp
    close(tmp)
    system("mv -f '" tmp "' '" STATE_FILE "'")
}

function load_state(   line, s) {
    clean = 0; dirty = 0
    clean_reset = now(); dirty_reset = clean_reset
    if ((getline line < STATE_FILE) <= 0) { close(STATE_FILE); return }
    close(STATE_FILE)
    if (match(line, /"clean":\{"used_ml":[0-9]+/)) {
        s = substr(line, RSTART, RLENGTH); sub(/.*:/, "", s); clean = s + 0
    }
    if (match(line, /"dirty":\{"used_ml":[0-9]+/)) {
        s = substr(line, RSTART, RLENGTH); sub(/.*:/, "", s); dirty = s + 0
    }
    if (match(line, /"clean":\{[^}]*"reset":[0-9]+/)) {
        s = substr(line, RSTART, RLENGTH); sub(/.*:/, "", s); clean_reset = s + 0
    }
    if (match(line, /"dirty":\{[^}]*"reset":[0-9]+/)) {
        s = substr(line, RSTART, RLENGTH); sub(/.*:/, "", s); dirty_reset = s + 0
    }
}

function calibrate(what, est) {
    system("echo \"$(date '+%Y-%m-%d %H:%M:%S') " what " est_used_ml=" int(est + 0.5) "\" >> '" CAL_LOG "'")
}

# Seconds since midnight of the line's time, continuing past midnight.
function line_time(   a, t) {
    split($2, a, ":")
    t = a[1] * 3600 + a[2] * 60 + a[3] + day
    if (have_t && t < last_t - 43200) { day += 86400; t += 86400 }
    return t
}

function advance(t,   dt) {
    if (have_t && t > last_t) {
        dt = t - last_t
        clean += flow * dt * FLOW_ML_PER_UNIT_S
        if (refill) clean += dt * REFILL_ML_PER_S
        if (pump) dirty += dt * DIRTY_ML_PER_PUMP_S
    }
    if (!have_t || t > last_t) last_t = t
    have_t = 1
}

# Sets FROM and TO from "<key>:A->B" in the line.
function change(key,   p, s, v) {
    p = index($0, key ":")
    if (!p) return 0
    s = substr($0, p + length(key) + 1)
    if (!match(s, /^[0-9]+->[0-9]+/)) return 0
    split(substr(s, 1, RLENGTH), v, "->")
    FROM = v[1] + 0; TO = v[2] + 0
    return 1
}

function check_resets(   changed) {
    if ((getline junk < RESET_CLEAN) >= 0) {
        close(RESET_CLEAN)
        system("rm -f '" RESET_CLEAN "'")
        clean = 0; clean_reset = now(); changed = 1
    }
    if ((getline junk < RESET_DIRTY) >= 0) {
        close(RESET_DIRTY)
        system("rm -f '" RESET_DIRTY "'")
        dirty = 0; dirty_reset = now(); changed = 1
    }
    if (changed) write_state()
}

BEGIN {
    load_state()
    write_state()
}

/^#tick/ { check_resets(); next }

index($0, "kWaterTankLackWater") {
    n = now()
    if (n - last_empty >= 600 || !last_empty) {
        last_empty = n
        calibrate("clean_empty", clean)
        clean = CLEAN_CAPACITY_ML
        write_state()
    }
    next
}

/^[IWEF][0-9]+ / {
    t = line_time()

    if (index($0, "regiser success")) {
        flow = 0; pump = 0; refill = 0
        last_t = t; have_t = 1
        write_state()
    } else if (change("_procStationWashData - water_pump_flow")) {
        advance(t)
        flow = TO
        if (TO == 0 && FROM > 0) write_state()
    } else if (change("_procStationWashData - supply_water_robot_status")) {
        advance(t)
        refill = (TO == 1)
        if (FROM == 1 && TO != 1) write_state()
    } else if (change("_procStationWashData - pump_station_status")) {
        advance(t)
        pump = (TO == 1)
        if (FROM == 1 && TO != 1) write_state()
    } else if (change("_printStationSensor - is_sewage_abnormal")) {
        if (FROM == 1 && TO == 0) {
            advance(t)
            dirty = 0; dirty_reset = now()
            write_state()
        }
    } else if (change("_printStationSensor - is_sewage_full")) {
        if (FROM == 0 && TO == 1) {
            advance(t)
            calibrate("dirty_full", dirty)
            dirty = DIRTY_CAPACITY_ML
            write_state()
        }
    }

    if (t - last_check >= 1 || t < last_check) {
        last_check = t
        check_resets()
    }
}

END { write_state() }
