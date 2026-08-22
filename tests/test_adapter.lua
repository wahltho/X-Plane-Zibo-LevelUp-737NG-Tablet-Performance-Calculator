local values = {
    ["zibomod/b737_variant"] = -1,
    ["laminar/B738/73x"] = 0,
    ["laminar/B738/sfp"] = 0,
    ["laminar/B738/pfd/ref_rwy_altitude"] = 0,
    ["laminar/B738/pfd/des_rwy_altitude"] = 0,
    ["laminar/B738/fms/rw_slope"] = 0,
}
function find_dataref(name)
    return setmetatable({ name = name }, {
        __add = function(reference) return values[reference.name] end,
    })
end

file_path = "tests/no-such-aircraft/"
B738DR_ref_list_rwy_icao = "TEST"
B738DR_ref_list_rwy = "01 "
B738DR_ref_list_rwy_len = { [0] = 3000 }
B738DR_ref_list_rwy_hdg = { [0] = 10 }
B738DR_des_list_rwy_icao = "TEST"
B738DR_des_list_rwy = "01 "
B738DR_des_list_rwy_len = { [0] = 3000 }
B738DR_des_list_rwy_hdg = { [0] = 10 }
B738DR_jbr_opt737 = 0
B738DR_fmc_units = 1
B738DR_atm_valid = 0
B738DR_tab_line_manip = {}
B738DR_tab_perf_manip = {}
B738DR_perf_ab1 = 0
B738DR_perf_ab2 = 0
B738DR_perf_ab3 = 0
B738DR_perf_ma = 0
B738DR_perf_mm = 0
B738DR_perf_ad = 0
B738DR_perf_on_rwy = 0
B738DR_perf_out_rwy = 0
B738DR_perf_ab1_state = 0
B738DR_perf_ab2_state = 0
B738DR_perf_ab3_state = 0
B738DR_perf_ma_state = 0
B738DR_perf_mm_state = 0

line = {}
line_s = {}
line_g = {}
line_a = {}
line_c = {}
page = 1
max_page = 1
display_update = 0
KGS_LBS = 2.204622622
function spaces_after(value, width) return value .. string.rep(" ", math.max(0, width - #value)) end
function num_pages(current, maximum) return tostring(current) .. "/" .. tostring(maximum) end
function page_perf_takeof() line[9] = "old calculate" end
function cmd_perf_takeoff() end
function cmd_perf_takeoff2() end
function page_perf_land() end
function cmd_perf_land2() end
function jbr_opt() error("old JBriks poll must not run") end
function jbr_opt_calculate() error("old JBriks calculate must not run") end

perf_arpt = ""
perf_rwy = 0
perf_intx = 0
perf_cond = "DRY"
perf_wind_dir = 0
perf_wind_spd = 0
perf_oat = 15
perf_qnh = 1002.8
perf_rtg = "OPTIMUM"
perf_atm = "MAX"
perf_flap = "5"
perf_ac = "AUTO"
perf_ai = "OFF"
perf_weight = 58000
perf_cg = 0
perf_ref_rwy_num = 0
perf_ref_rwy_list = {}
perf_ref_rwy_list_len = {}
perf_ref_rwy_list_hdg = {}
perf_ref_rwy_lst_num = 0
perf_ref_rwy_lst = {}
perf_ref_rwy_intx_num = {}
perf_ref_rwy_intx = {}
perf_takeoff_rating = 0

perf_lnd_arpt = "TEST"
perf_lnd_rwy = 1
perf_lnd_flap = "30"
perf_lnd_brks = "ALL"
perf_lnd_wind_dir = 0
perf_lnd_wind_spd = 0
perf_lnd_oat = 15
perf_lnd_qnh = 1002.8
perf_lnd_weight = 65000
perf_lnd_vref_add = 5
perf_lnd_cond = "DRY"
perf_lnd_reverse = "BOTH"
perf_des_rwy_num = 0
perf_des_rwy_list = {}
perf_des_rwy_list_len = {}
perf_des_rwy_list_hdg = {}

-- XLua 1.3 executes dofile() but does not preserve the loaded chunk's return
-- value. Reproduce that contract for all nested module loads.
local standard_dofile = dofile
function dofile(path)
    standard_dofile(path)
    return nil
end
dofile("B738.tablet_perf_adapter.lua")
assert(B738_upstream_perf_adapter ~= nil)
assert(B738_upstream_perf_core ~= nil)
assert(B738_upstream_perf_data ~= nil)
B738_upstream_perf_adapter.install()
jbr_opt()
page_perf_takeof()
assert(perf_qnh == 1002)
assert(line_g[9] == "")
perf_cg = 25
page_perf_takeof()
assert(string.find(line_g[9], "CALCULATE", 1, true))
cmd_perf_takeoff(9)
assert(perf_takeoff_rating == 1)
assert(perf_takeoff_full_valid == 1)
assert(perf_takeoff_full_rating == 22)
assert(perf_takeoff_full_v1 <= perf_takeoff_full_vr and perf_takeoff_full_vr <= perf_takeoff_full_v2)
assert(perf_takeoff_trim > 0)
page = 2
page_perf_takeof()
assert(line_s[8] == " TOGW     R-22K  SEL TMP")
page = 1

-- A LevelUp 737-900 airframe with the livery SFP option represents the
-- 900ER takeoff configuration even when the shared plugin still reports
-- aircraft variant 1. Rating selection and all 27K/24K/22K calculations agree.
values["zibomod/b737_variant"] = 1
values["laminar/B738/sfp"] = 1
perf_rtg = "OPTIMUM"
cmd_perf_takeoff2(9)
assert(perf_rtg == "R27K")
cmd_perf_takeoff(9)
assert(perf_takeoff_full_valid == 1)
assert(perf_takeoff_full_rating == 27)
page = 2
page_perf_takeof()
assert(line_s[8] == " TOGW     R-27K  SEL TMP")
page = 1
cmd_perf_takeoff2(9)
assert(perf_rtg == "R24K")
cmd_perf_takeoff(9)
assert(perf_takeoff_full_valid == 1 and perf_takeoff_full_rating == 24)
cmd_perf_takeoff2(9)
assert(perf_rtg == "R22K")
cmd_perf_takeoff(9)
assert(perf_takeoff_full_valid == 1 and perf_takeoff_full_rating == 22)
cmd_perf_takeoff2(9)
assert(perf_rtg == "WINDSHEAR")
cmd_perf_takeoff2(9)
assert(perf_rtg == "OPTIMUM")

values["laminar/B738/sfp"] = 0
perf_rtg = "OPTIMUM"
cmd_perf_takeoff2(9)
assert(perf_rtg == "R26K")
cmd_perf_takeoff(9)
assert(perf_takeoff_full_valid == 1)
assert(perf_takeoff_full_rating == 26)

page = 2
page_perf_takeof()
assert(line_s[8] == " TOGW     R-26K  SEL TMP")

-- Legacy LevelUp aircraft IDs are reported through laminar/B738/73x when the
-- shared plugin leaves zibomod/b737_variant at -1.  The -700 must therefore
-- use its 24K/22K/20K family rather than silently falling back to Zibo -800.
values["zibomod/b737_variant"] = -1
values["laminar/B738/73x"] = 2
values["laminar/B738/pfd/ref_rwy_altitude"] = 157
perf_qnh = 1025
perf_oat = 28
perf_weight = 56000
perf_cg = 20.1
perf_rtg = "OPTIMUM"
for _, rating in ipairs({24, 22, 20}) do
    cmd_perf_takeoff2(9)
    assert(perf_rtg == "R" .. tostring(rating) .. "K")
    cmd_perf_takeoff(9)
    assert(perf_takeoff_full_valid == 1 and perf_takeoff_full_rating == rating)
end
cmd_perf_takeoff2(9)
assert(perf_rtg == "WINDSHEAR")
page_perf_land()
assert(perf_lnd_qnh == 1002)
assert(B738DR_perf_mm > 0 and B738DR_perf_ab1 > 0)
assert(string.find(line[4], "KT", 1, true))
print("PASS: upstream Tablet adapter without JBriks runtime")
