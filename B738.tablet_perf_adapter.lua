-- Adapter between the upstream 4.05.35 Tablet globals and the stand-alone
-- performance core.  The public zibomod plugin remains unchanged.

dofile("B738.tablet_perf_core.lua")
local core = B738_upstream_perf_core
local adapter = {}

local variant_ref = find_dataref("zibomod/b737_variant")
local legacy_variant_ref = find_dataref("laminar/B738/73x")
local sfp_ref = find_dataref("laminar/B738/sfp")
local departure_altitude_ref = find_dataref("laminar/B738/pfd/ref_rwy_altitude")
local destination_altitude_ref = find_dataref("laminar/B738/pfd/des_rwy_altitude")
local runway_slope_ref = find_dataref("laminar/B738/fms/rw_slope")

local original_page_takeoff = nil
local original_cmd_takeoff = nil
local original_cmd_takeoff2 = nil
local original_page_landing = nil
local original_cmd_landing2 = nil
local runway_cache = nil
local runway_cache_path = nil
local last_departure_icao = nil

local function round(value)
    return core.round(value)
end

local function read_number(reference, fallback)
    local ok, value = pcall(function() return reference + 0 end)
    if ok and type(value) == "number" then return value end
    value = tonumber(reference)
    if value ~= nil then return value end
    return fallback
end

local function normalize_qnh(value)
    if value > 40 then return math.floor(value) end
    return value
end

local function qnh_hpa(value)
    value = normalize_qnh(value)
    if value <= 40 then return math.floor(value * 33.8639) end
    return value
end

local function reported_variant()
    local aircraft_variant = read_number(variant_ref, -1)
    local variant = core.variant_from_aircraft_id(aircraft_variant)
    if aircraft_variant < 0 then
        local legacy_variant = read_number(legacy_variant_ref, -1)
        if legacy_variant == 1 then aircraft_variant, variant = 1, 4
        elseif legacy_variant == 2 then aircraft_variant, variant = 2, 2 end
    end
    return aircraft_variant, variant
end

local function takeoff_variant()
    local aircraft_variant, variant = reported_variant()
    -- LevelUp can select the 900ER/SFP configuration through the livery
    -- setting while the shared plugin still reports the 737-900 airframe ID.
    -- Keep landing on the reported airframe, but make takeoff rating selection
    -- and calculation use the same 900ER 27K/24K/22K rating family.
    if aircraft_variant == 1 and read_number(sfp_ref, 0) ~= 0 then
        variant = 5
    end
    return aircraft_variant, variant
end

local function split_words(line_text)
    local words = {}
    for word in string.gmatch(line_text or "", "%S+") do
        words[#words + 1] = word
    end
    return words
end

local function runway_key(icao, runway)
    return string.upper(tostring(icao or "")) .. ":" .. string.upper(tostring(runway or ""))
end

local function load_runways()
    local path = tostring(file_path or "") .. "B738X_rnw.dat"
    if runway_cache ~= nil and runway_cache_path == path then return runway_cache end
    local rows = {}
    local file = io.open(path, "r")
    if file ~= nil then
        for line_text in file:lines() do
            local words = split_words(line_text)
            if #words >= 11 and words[1] ~= "I" and #words[1] == 4 then
                local row = {
                    icao = words[1], runway = words[2],
                    start_lat = tonumber(words[3]), start_lon = tonumber(words[4]),
                    end_lat = tonumber(words[5]), end_lon = tonumber(words[6]),
                    length_m = tonumber(words[7]), heading = tonumber(words[8]),
                    displaced_m = tonumber(words[10]) or 0,
                    elevation_ft = tonumber(words[12] or words[11]),
                }
                if row.length_m ~= nil and row.heading ~= nil then
                    rows[runway_key(row.icao, row.runway)] = row
                end
            end
        end
        file:close()
    end
    for _, row in pairs(rows) do
        for _, reciprocal in pairs(rows) do
            if row.icao == reciprocal.icao and row.runway ~= reciprocal.runway and
                    row.start_lat == reciprocal.end_lat and row.start_lon == reciprocal.end_lon and
                    row.end_lat == reciprocal.start_lat and row.end_lon == reciprocal.start_lon and
                    row.elevation_ft ~= nil and reciprocal.elevation_ft ~= nil and
                    row.elevation_ft >= 0 and reciprocal.elevation_ft >= 0 and row.length_m > 0 then
                row.slope_percent = ((reciprocal.elevation_ft - row.elevation_ft) * 0.3048 / row.length_m) * 100
                break
            end
        end
    end
    runway_cache = rows
    runway_cache_path = path
    return rows
end

local function runway_from_lists(icao, runway, landing)
    local rows = load_runways()
    local result = rows[runway_key(icao, runway)]
    if result ~= nil then return result end
    local names = landing and perf_des_rwy_list or perf_ref_rwy_lst
    local lengths = landing and perf_des_rwy_list_len or perf_ref_rwy_list_len
    local headings = landing and perf_des_rwy_list_hdg or perf_ref_rwy_list_hdg
    local count = landing and perf_des_rwy_num or perf_ref_rwy_lst_num
    for index = 1, count or 0 do
        if names[index] == runway then
            return {
                icao = icao,
                runway = runway,
                length_m = tonumber(lengths[index]) or 0,
                heading = tonumber(headings[index]) or (tonumber(string.sub(runway, 1, 2)) or 0) * 10,
                displaced_m = 0,
                elevation_ft = read_number(landing and destination_altitude_ref or departure_altitude_ref, 0),
                slope_percent = landing and 0 or read_number(runway_slope_ref, 0),
            }
        end
    end
    return nil
end

local function selected_takeoff_runway()
    if perf_rwy <= 0 or perf_rwy > perf_ref_rwy_lst_num then return nil end
    return runway_from_lists(B738DR_ref_list_rwy_icao, perf_ref_rwy_lst[perf_rwy], false)
end

local function selected_landing_runway()
    if perf_lnd_rwy <= 0 or perf_lnd_rwy > perf_des_rwy_num then return nil end
    return runway_from_lists(B738DR_des_list_rwy_icao, perf_des_rwy_list[perf_lnd_rwy], true)
end

local function wind_component(direction, speed, heading)
    if speed == 0 then return 0 end
    if direction < 0 then return speed end
    return round(speed * math.cos(math.rad(direction - heading)))
end

local function takeoff_inputs_complete()
    return perf_weight >= 25000 and perf_weight <= 100000 and
        perf_cg >= 6 and perf_cg <= 36 and
        perf_rwy > 0 and perf_rwy <= perf_ref_rwy_lst_num and
        perf_intx == 1 and selected_takeoff_runway() ~= nil
end

local function clear_takeoff_result()
    perf_takeoff_err = 0
    perf_takeoff_windshear = 0
    perf_takeoff_full_valid = 0
    perf_takeoff_full_rating = 0
    perf_takeoff_full_n1 = 0
    perf_takeoff_full_v1 = 0
    perf_takeoff_full_vr = 0
    perf_takeoff_full_v2 = 0
    perf_takeoff_atm_valid = 0
    perf_takeoff_atm_rating = 0
    perf_takeoff_atm_seltemp = 0
    perf_takeoff_atm_n1 = 0
    perf_takeoff_atm_v1 = 0
    perf_takeoff_atm_vr = 0
    perf_takeoff_atm_v2 = 0
    perf_takeoff_max_wt = 0
    perf_takeoff_vref40 = 0
    perf_takeoff_flaps = 0
    perf_takeoff_trim = -1
    perf_takeoff_rating = 0
end

function adapter.refresh_takeoff_runways()
    B738DR_jbr_opt737 = 1
    jbr_find_rwy_timer = 0
    local icao = tostring(B738DR_ref_list_rwy_icao or "")
    if icao == last_departure_icao and perf_ref_rwy_lst_num > 0 then return end
    last_departure_icao = icao
    perf_ref_rwy_num = 0
    perf_ref_rwy_list = {}
    perf_ref_rwy_list_len = {}
    perf_ref_rwy_list_hdg = {}
    perf_ref_rwy_lst_num = 0
    perf_ref_rwy_lst = {}
    perf_ref_rwy_intx_num = {}
    perf_ref_rwy_intx = {}
    local encoded = tostring(B738DR_ref_list_rwy or "")
    local count = math.floor(string.len(encoded) / 3)
    for index = 1, count do
        local position = ((index - 1) * 3) + 1
        local runway = string.sub(encoded, position, position + 2)
        if runway ~= "" and string.match(runway, "%S") ~= nil then
            perf_ref_rwy_num = perf_ref_rwy_num + 1
            perf_ref_rwy_lst_num = perf_ref_rwy_lst_num + 1
            perf_ref_rwy_list[perf_ref_rwy_num] = runway
            perf_ref_rwy_list_len[perf_ref_rwy_num] = B738DR_ref_list_rwy_len[index - 1]
            perf_ref_rwy_list_hdg[perf_ref_rwy_num] = B738DR_ref_list_rwy_hdg[index - 1]
            perf_ref_rwy_lst[perf_ref_rwy_lst_num] = runway
            perf_ref_rwy_intx_num[perf_ref_rwy_lst_num] = 1
            perf_ref_rwy_intx[perf_ref_rwy_lst_num] = { "FULL" }
        end
    end
    perf_rwy = perf_ref_rwy_lst_num > 0 and 1 or 0
    perf_intx = perf_ref_rwy_lst_num > 0 and 1 or 0
    clear_takeoff_result()
end

local function requested_rating(variant)
    local numeric = tonumber(string.match(perf_rtg or "", "(%d+)"))
    if perf_rtg == "OPTIMUM" then return 0, false end
    if perf_rtg == "WINDSHEAR" then return core.full_thrust_rating(variant), true end
    return numeric, false
end

function adapter.calculate_takeoff()
    clear_takeoff_result()
    perf_qnh = normalize_qnh(perf_qnh)
    if not takeoff_inputs_complete() then return end
    local runway = selected_takeoff_runway()
    local _, variant = takeoff_variant()
    if runway == nil or variant == nil or runway.length_m <= 0 then
        perf_takeoff_err = 1
        perf_takeoff_rating = 1
        return
    end
    local rating, windshear = requested_rating(variant)
    if rating == nil then
        perf_takeoff_err = 1
        perf_takeoff_rating = 1
        return
    end
    local input = {
        variant = variant,
        runway_length_m = round(runway.length_m),
        runway_slope_percent = runway.slope_percent or 0,
        headwind_kt = wind_component(perf_wind_dir, perf_wind_spd, runway.heading),
        dry = perf_cond == "DRY",
        oat_c = perf_oat,
        pressure_altitude_ft = (runway.elevation_ft or 0) + (1013 - qnh_hpa(perf_qnh)) * 27,
        takeoff_weight_t = perf_weight / 1000,
        flaps = perf_flap == "OPTIMUM" and 0 or tonumber(perf_flap),
        option_1 = perf_ac ~= "OFF",
        option_2 = perf_ai == "ENG" or perf_ai == "ENG/WING",
        option_3 = perf_ai == "WING" or perf_ai == "ENG/WING",
        requested_rating = rating,
        requested_assumed_temp_c = 0,
        cg_percent = perf_cg,
    }
    local ok, result = pcall(core.calculate_takeoff, input)
    if not ok or result == nil or not result.full.valid then
        perf_takeoff_err = 1
        perf_takeoff_rating = 1
        return
    end
    if windshear then
        result.windshear = true
        result.assumed.valid = false
        result.full.vr = result.full.v2
    end
    perf_takeoff_windshear = result.windshear and 1 or 0
    perf_takeoff_full_valid = result.full.valid and 1 or 0
    perf_takeoff_full_rating = result.full.rating or 0
    perf_takeoff_full_n1 = result.full.n1_percent or 0
    perf_takeoff_full_v1 = result.full.v1 or 0
    perf_takeoff_full_vr = result.full.vr or 0
    perf_takeoff_full_v2 = result.full.v2 or 0
    perf_takeoff_atm_valid = result.assumed.valid and 1 or 0
    perf_takeoff_atm_rating = result.assumed.rating or 0
    perf_takeoff_atm_seltemp = result.assumed.temperature_c or 0
    perf_takeoff_atm_n1 = result.assumed.n1_percent or 0
    perf_takeoff_atm_v1 = result.assumed.v1 or 0
    perf_takeoff_atm_vr = result.assumed.vr or 0
    perf_takeoff_atm_v2 = result.assumed.v2 or 0
    perf_takeoff_max_wt = result.maximum_takeoff_weight_t or 0
    perf_takeoff_vref40 = result.vref40 or 0
    perf_takeoff_flaps = result.selected_flaps or 0
    perf_takeoff_trim = result.stabilizer_trim or -1
    perf_takeoff_full = perf_takeoff_atm_valid ~= 0 and 0 or 1
    perf_takeoff_rating = 1
end

function adapter.page_takeoff()
    perf_qnh = normalize_qnh(perf_qnh)
    original_page_takeoff()
    if page == 1 then
        local qnh_text
        if perf_qnh <= 40 then qnh_text = string.format("%5.2f IN HG", perf_qnh)
        else qnh_text = string.format("%4.0f HPA", perf_qnh) end
        line[7] = "       " .. spaces_after(qnh_text, 14)
        line[9] = ""
        line_g[9] = ""
        B738DR_tab_line_manip[9] = 0
        if takeoff_inputs_complete() then
            line_g[9] = "                           CALCULATE >"
            B738DR_tab_line_manip[9] = 1
        end
    elseif page == 2 and perf_takeoff_rating ~= 0 and perf_takeoff_err == 0 then
        local displayed_rating = perf_takeoff_full == 0 and perf_takeoff_atm_rating or perf_takeoff_full_rating
        line_s[8] = " TOGW     R-" .. tostring(displayed_rating) .. "K  SEL TMP"
    end
end

function adapter.cmd_takeoff(cmd)
    if cmd == 9 then adapter.calculate_takeoff()
    else original_cmd_takeoff(cmd) end
end

function adapter.cmd_takeoff2(cmd)
    if cmd == 9 then
        local _, variant = takeoff_variant()
        local ratings = core.rating_family(variant)
        if perf_rtg == "OPTIMUM" and #ratings > 0 then
            perf_rtg = "R" .. tostring(ratings[1]) .. "K"
        else
            local advanced = false
            for index = 1, #ratings do
                if perf_rtg == "R" .. tostring(ratings[index]) .. "K" then
                    if index < #ratings then
                        perf_rtg = "R" .. tostring(ratings[index + 1]) .. "K"
                    else
                        perf_rtg = "WINDSHEAR"
                    end
                    advanced = true
                    break
                end
            end
            if not advanced then perf_rtg = "OPTIMUM" end
        end
        display_update = 1
        clear_takeoff_result()
    elseif cmd == 11 then
        if perf_flap == "1" then perf_flap = "5"
        elseif perf_flap == "5" then perf_flap = "10"
        elseif perf_flap == "10" then perf_flap = "15"
        elseif perf_flap == "15" then perf_flap = "25"
        elseif perf_flap == "25" then perf_flap = "OPTIMUM"
        else perf_flap = "1" end
        display_update = 1
        clear_takeoff_result()
    else
        original_cmd_takeoff2(cmd)
    end
end

local function refresh_landing_runways()
    perf_lnd_arpt = B738DR_des_list_rwy_icao
    perf_des_rwy_num = 0
    perf_des_rwy_list = {}
    perf_des_rwy_list_len = {}
    perf_des_rwy_list_hdg = {}
    local encoded = tostring(B738DR_des_list_rwy or "")
    local count = math.floor(string.len(encoded) / 3)
    for index = 1, count do
        local position = ((index - 1) * 3) + 1
        local runway = string.sub(encoded, position, position + 2)
        if runway ~= "" and string.match(runway, "%S") ~= nil then
            perf_des_rwy_num = perf_des_rwy_num + 1
            perf_des_rwy_list[perf_des_rwy_num] = runway
            perf_des_rwy_list_len[perf_des_rwy_num] = B738DR_des_list_rwy_len[index - 1]
            perf_des_rwy_list_hdg[perf_des_rwy_num] = B738DR_des_list_rwy_hdg[index - 1]
        end
    end
end

local function landing_condition()
    if perf_lnd_cond == "POOR" then return 3 end
    if perf_lnd_cond == "MEDIUM" then return 2 end
    if perf_lnd_cond == "GOOD" or perf_lnd_cond == "WET" then return 1 end
    return 0
end

local function landing_reversers()
    if perf_lnd_reverse == "ONE" then return 1 end
    if perf_lnd_reverse == "NOT AVAIL" or perf_lnd_reverse == "NO CREDIT" then return 2 end
    return 0
end

local function format_distance(value)
    if B738DR_fmc_units == 0 then return string.format("%5dFT", round(value * 3.28083989501)) end
    return string.format("%4dM", round(value))
end

local function set_distance_line(row, label, value, state, selected)
    line_s[row] = label
    local text = "                               " .. format_distance(value)
    if selected then
        if state <= 1 then line_g[row] = text else line_a[row] = text end
    else
        if state <= 1 then line_s[row] = line_s[row] .. format_distance(value)
        else line_a[row] = text end
    end
end

function adapter.page_landing()
    perf_lnd_qnh = normalize_qnh(perf_lnd_qnh)
    if perf_lnd_arpt == "" or perf_lnd_rwy == 0 or perf_lnd_weight < 40000 then
        max_page = 1
    else
        max_page = 2
    end
    if page == 1 then
        original_page_landing()
        local qnh_text
        if perf_lnd_qnh <= 40 then qnh_text = string.format("%5.2f IN HG", perf_lnd_qnh)
        else qnh_text = string.format("%4.0f HPA", perf_lnd_qnh) end
        line[7] = "       " .. spaces_after(qnh_text, 14)
        return
    end
    refresh_landing_runways()
    line_c[0] = "        PERFORMANCE LANDING           "
    line_s[0] = "                                " .. num_pages(page, 2)
    local runway = selected_landing_runway()
    local aircraft_variant, variant = reported_variant()
    if variant == 0 then variant = 3 end
    if runway == nil or variant == nil or perf_lnd_weight < 25000 then
        line[1] = " CALCULATION ERROR"
        return
    end
    local headwind = wind_component(perf_lnd_wind_dir, perf_lnd_wind_spd, runway.heading)
    perf_lnd_head_wind = -headwind
    local input = {
        variant = variant,
        flaps = tonumber(perf_lnd_flap),
        condition = landing_condition(),
        landing_weight_kg = perf_lnd_weight,
        pressure_altitude_ft = (runway.elevation_ft or 0) + (1013 - qnh_hpa(perf_lnd_qnh)) * 27,
        headwind_kt = headwind,
        runway_slope_percent = runway.slope_percent or 0,
        oat_c = perf_lnd_oat,
        vref_add_kt = perf_lnd_vref_add,
        reversers = landing_reversers(),
        manual_speedbrakes = false,
    }
    local ok, result = pcall(core.calculate_landing, input)
    local lda = runway.length_m - math.max(0, runway.displaced_m or 0)
    if not ok or result == nil or lda <= 0 then
        line[1] = " CALCULATION ERROR"
        return
    end
    local mm = result.distances[0]
    local ab1 = result.distances[1]
    local ab2 = result.distances[2]
    local ab3 = result.distances[3]
    local ma = result.distances[4]
    local ad = result.air_distance_m
    local selected = perf_lnd_brks
    local selected_distance = selected == "MAX MANUAL" and mm or selected == "AB2" and ab2 or
        selected == "AB3" and ab3 or selected == "MAX AUTO" and ma or ab1
    local states = {
        ["mm"] = mm > lda and 2 or 1, ["ab1"] = ab1 > lda and 2 or 1,
        ["ab2"] = ab2 > lda and 2 or 1, ["ab3"] = ab3 > lda and 2 or 1,
        ["ma"] = ma > lda and 2 or 1,
    }
    local selected_keys = {
        ["MAX MANUAL"] = "mm", ["AB1"] = "ab1", ["AB2"] = "ab2",
        ["AB3"] = "ab3", ["MAX AUTO"] = "ma",
    }
    local selected_key = selected_keys[selected]
    if selected_key ~= nil then
        for name in pairs(states) do if name ~= selected_key then states[name] = 0 end end
    end
    set_distance_line(1, " LAND WEIGHT       MAX MANUAL: ", mm, states.mm, selected == "MAX MANUAL")
    set_distance_line(2, "                   AUTO BRK 1: ", ab1, states.ab1, selected == "AB1")
    local units = B738DR_fmc_units == 0 and "LB" or "KG"
    local weight = B738DR_fmc_units == 0 and perf_lnd_weight * KGS_LBS or perf_lnd_weight
    line[2] = string.format("  %6d %s", round(weight), units)
    local vref = core.calculate_vref(aircraft_variant, perf_lnd_weight, input.flaps)
    if vref == nil then line[1] = " CALCULATION ERROR" return end
    local vref_label = spaces_after("VREF" .. perf_lnd_flap .. "+" .. tostring(perf_lnd_vref_add), 9)
    set_distance_line(3, "  " .. vref_label .. "        AUTO BRK 2: ", ab2, states.ab2, selected == "AB2")
    set_distance_line(4, "                   AUTO BRK 3: ", ab3, states.ab3, selected == "AB3")
    line[4] = string.format("   %3d KT", vref + perf_lnd_vref_add)
    set_distance_line(5, " LDA:                MAX AUTO: ", ma, states.ma, selected == "MAX AUTO")
    line[5] = "      " .. format_distance(lda)
    line_s[6] = " AD:  " .. format_distance(ad)
    local scale = 594 / lda
    B738DR_perf_ab1 = ab1 * scale
    B738DR_perf_ab2 = ab2 * scale
    B738DR_perf_ab3 = ab3 * scale
    B738DR_perf_ma = ma * scale
    B738DR_perf_mm = mm * scale
    B738DR_perf_ad = ad * scale
    B738DR_perf_on_rwy = math.max(0, selected_distance - ad) * scale
    B738DR_perf_out_rwy = math.max(0, selected_distance - lda) * scale
    B738DR_perf_ab1_state = states.ab1
    B738DR_perf_ab2_state = states.ab2
    B738DR_perf_ab3_state = states.ab3
    B738DR_perf_ma_state = states.ma
    B738DR_perf_mm_state = states.mm
    for index = 1, 9 do B738DR_tab_line_manip[index] = 0 end
end

function adapter.cmd_landing2(cmd)
    if cmd == 4 then
        if perf_lnd_cond == "DRY" then perf_lnd_cond = "GOOD"
        elseif perf_lnd_cond == "GOOD" or perf_lnd_cond == "WET" then perf_lnd_cond = "MEDIUM"
        elseif perf_lnd_cond == "MEDIUM" then perf_lnd_cond = "POOR"
        else perf_lnd_cond = "DRY" end
        display_update = 1
    elseif cmd == 15 then
        if perf_lnd_reverse == "NOT AVAIL" or perf_lnd_reverse == "NO CREDIT" then perf_lnd_reverse = "BOTH"
        elseif perf_lnd_reverse == "BOTH" then perf_lnd_reverse = "ONE"
        else perf_lnd_reverse = "NOT AVAIL" end
        display_update = 1
    else
        original_cmd_landing2(cmd)
    end
end

function adapter.install()
    original_page_takeoff = page_perf_takeof
    original_cmd_takeoff = cmd_perf_takeoff
    original_cmd_takeoff2 = cmd_perf_takeoff2
    original_page_landing = page_perf_land
    original_cmd_landing2 = cmd_perf_land2
    jbr_opt = adapter.refresh_takeoff_runways
    jbr_opt_calculate = adapter.calculate_takeoff
    page_perf_takeof = adapter.page_takeoff
    cmd_perf_takeoff = adapter.cmd_takeoff
    cmd_perf_takeoff2 = adapter.cmd_takeoff2
    page_perf_land = adapter.page_landing
    cmd_perf_land2 = adapter.cmd_landing2
    print("Upstream Tablet takeoff/landing performance patch loaded")
end

B738_upstream_perf_adapter = adapter
return adapter
